package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"voila/internal/build"
	"voila/internal/chunkstore"
	"voila/internal/cli"
	"voila/internal/dockerfile"
	"voila/internal/imagestore"
)

// cmdBuild implements `voila build [-f file] [-t ref] [--build-arg k=v]
// [--target name] [--no-cache] [context]`.
func cmdBuild(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "build", cfg.Stderr)
	var (
		fileFlag   string
		tagFlag    string
		targetFlag string
		rootFlag   string
		socketFlag string
		noCache    bool
	)
	fs.StringVar(&fileFlag, "f", "", "path to Dockerfile (default: <context>/Dockerfile)")
	fs.StringVar(&tagFlag, "t", "", "name and optional tag for the built image")
	fs.StringVar(&targetFlag, "target", "", "set the target build stage name")
	fs.StringVar(&rootFlag, "root", "", "voila data root directory")
	fs.StringVar(&socketFlag, "socket", "", "worker socket path")
	fs.BoolVar(&noCache, "no-cache", false, "do not use the build cache")
	args, buildArgs := extractBuildArgs(args)
	if err := fs.Parse(args); err != nil {
		return err
	}
	contextDir := "."
	if fs.NArg() > 0 {
		contextDir = fs.Arg(0)
	}
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	socket := cli.ResolveSocket(socketFlag, cfg.Socket, cli.RootExplicit(rootFlag), root)

	return runBuild(cfg, root, socket, contextDir, fileFlag, tagFlag, targetFlag, buildArgs, noCache)
}

func extractBuildArgs(argv []string) ([]string, map[string]string) {
	out := make(map[string]string)
	var filtered []string
	for _, a := range argv {
		if strings.HasPrefix(a, "--build-arg=") {
			k, v, _ := strings.Cut(a[len("--build-arg="):], "=")
			out[k] = v
			continue
		}
		filtered = append(filtered, a)
	}
	return filtered, out
}

func runBuild(cfg Config, root, socket, contextDir, dockerfilePath, tag, target string, buildArgs map[string]string, noCache bool) error {
	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}
	errOut := cfg.Stderr
	if errOut == nil {
		errOut = os.Stderr
	}

	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		return err
	}
	defer store.Close()

	imgStore, err := imagestore.Open(root)
	if err != nil {
		return err
	}
	defer imgStore.Close()

	// Detect if Dockerfile contains RUN (needs daemon).
	if needsDaemon(dockerfilePath, contextDir) {
		if err := cli.TryProbe(socket); err != nil {
			return fmt.Errorf("Dockerfile contains RUN instructions; start `voilad` first (%v)", err)
		}
	}

	b := &build.Builder{
		Store:    store,
		ImgStore: imgStore,
		Out:      out,
		ErrOut:   errOut,
	}
	if needsDaemon(dockerfilePath, contextDir) {
		b.Runner = &build.DaemonRunner{Socket: socket}
	}

	res, err := b.Build(context.Background(), build.Options{
		Tag:        tag,
		Dockerfile: dockerfilePath,
		ContextDir: contextDir,
		Target:     target,
		BuildArgs:  buildArgs,
		NoCache:    noCache,
	})
	if err != nil {
		return err
	}
	if err := build.Persist(imgStore, res); err != nil {
		return err
	}
	fmt.Fprintf(out, " => %s  %s\n", res.Ref, cli.ShortDigest(res.ImageDigest))
	return nil
}

func needsDaemon(dockerfilePath, contextDir string) bool {
	if dockerfilePath == "" {
		dockerfilePath = contextDir + "/Dockerfile"
	}
	f, err := os.Open(dockerfilePath)
	if err != nil {
		return false
	}
	defer f.Close()
	df, err := dockerfile.Parse(f)
	if err != nil {
		return false
	}
	for _, st := range df.Stages {
		for _, inst := range st.Instructions {
			if _, ok := inst.(*dockerfile.Run); ok {
				return true
			}
		}
	}
	return false
}
