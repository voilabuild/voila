package build

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/dockerfile"
	"voila/internal/imagestore"
	"voila/internal/ingest"
	voilapb "voila/internal/proto"
)

// Runner executes RUN instructions via the worker daemon.
type Runner interface {
	BuildRun(ctx context.Context, spec RunSpec, stdout, stderr io.Writer) (chunkstore.ChunkID, int, error)
}

// RunSpec is the input to a build-time RUN step.
type RunSpec struct {
	RootChunk   chunkstore.ChunkID
	ConfigChunk chunkstore.ChunkID
	Argv        []string
	Env         []string
	Cwd         string
	User        string
}

// Options configures a build.
type Options struct {
	Tag        string
	Dockerfile string
	ContextDir string
	Target     string
	BuildArgs  map[string]string
	NoCache    bool
}

// Result is the outcome of a successful build.
type Result struct {
	Ref                     string
	ImageDigest             []byte
	ConfigChunk             chunkstore.ChunkID
	MergedRootManifestChunk chunkstore.ChunkID
	Layers                  []ingest.LayerResult
	BytesIn                 uint64
	ChunkCount              uint64
}

// Builder orchestrates Dockerfile execution.
type Builder struct {
	Store    chunkstore.ChunkStore
	ImgStore *imagestore.Store
	Runner   Runner
	Out      io.Writer
	ErrOut   io.Writer
}

type stageState struct {
	name        string
	layerTrees  []*ingest.LayerTree
	layers      []ingest.LayerResult
	merged      *ingest.LayerTree
	config      *ImageConfig
	configChunk chunkstore.ChunkID
	rootChunk   chunkstore.ChunkID
	shell       []string
}

// Build executes a Dockerfile and returns the final image result.
func (b *Builder) Build(ctx context.Context, opts Options) (*Result, error) {
	dfPath := opts.Dockerfile
	if dfPath == "" {
		dfPath = filepath.Join(opts.ContextDir, "Dockerfile")
	}
	df, err := os.Open(dfPath)
	if err != nil {
		return nil, fmt.Errorf("open Dockerfile: %w", err)
	}
	defer df.Close()
	file, err := dockerfile.Parse(df)
	if err != nil {
		return nil, fmt.Errorf("parse Dockerfile: %w", err)
	}
	ignore, err := Dockerignore(opts.ContextDir)
	if err != nil {
		return nil, fmt.Errorf("read .dockerignore: %w", err)
	}

	stages := make(map[string]*stageState)
	totalSteps := countSteps(file)
	stepN := 0

	for si, st := range file.Stages {
		stepN++
		if b.Out != nil {
			fmt.Fprintf(b.Out, "Step %d/%d : FROM %s", stepN, totalSteps, st.From.Image)
			if st.From.As != "" {
				fmt.Fprintf(b.Out, " AS %s", st.From.As)
			}
			fmt.Fprintln(b.Out)
		}
		ss, err := b.initStage(ctx, st)
		if err != nil {
			return nil, err
		}
		shell := []string{"/bin/sh", "-c"}
		for _, inst := range st.Instructions {
			if _, ok := inst.(*dockerfile.Onbuild); ok {
				return nil, fmt.Errorf("ONBUILD is not supported in v1")
			}
			if sh, ok := inst.(*dockerfile.Shell); ok {
				shell = sh.Argv
				continue
			}
			stepN++
			if b.Out != nil {
				fmt.Fprintf(b.Out, "Step %d/%d : %s\n", stepN, totalSteps, dockerfile.Canonical(inst))
			}
			if err := b.applyInstruction(ctx, ss, inst, opts, ignore, shell, stages); err != nil {
				return nil, fmt.Errorf("%s: %w", dockerfile.Canonical(inst), err)
			}
		}
		key := stageKey(st)
		stages[key] = ss
		_ = si
	}

	finalKey := "__final__"
	if opts.Target != "" {
		finalKey = opts.Target
	}
	final, ok := stages[finalKey]
	if !ok {
		return nil, fmt.Errorf("target stage %q not found", opts.Target)
	}

	ref := opts.Tag
	if ref == "" {
		ref = fmt.Sprintf("sha256:%x", sha256.Sum256(final.rootChunk[:]))
	}
	return b.finalize(ctx, final, ref)
}

func stageKey(st dockerfile.Stage) string {
	if st.Name != "" {
		return st.Name
	}
	return "__final__"
}

func countSteps(f *dockerfile.File) int {
	n := 0
	for _, s := range f.Stages {
		n += len(s.Instructions) + 1
	}
	return n
}

func (b *Builder) initStage(ctx context.Context, st dockerfile.Stage) (*stageState, error) {
	ss := &stageState{
		name:  st.Name,
		shell: []string{"/bin/sh", "-c"},
	}
	from := st.From.Image
	if strings.EqualFold(from, "scratch") {
		ss.config = NewImageConfig()
		ss.merged = ingest.NewTree()
		ss.layerTrees = []*ingest.LayerTree{}
		return ss, b.refreshManifest(ctx, ss)
	}
	im, rootChunk, err := imagestore.Resolve(b.ImgStore, from)
	if err != nil {
		return nil, fmt.Errorf("resolve FROM %q: %w", from, err)
	}
	cfgRaw, err := b.Store.Get(ctx, idFromBytes(im.GetConfigChunk()))
	if err != nil {
		return nil, fmt.Errorf("read config chunk: %w", err)
	}
	ss.config, err = FromOCI(cfgRaw)
	if err != nil {
		return nil, err
	}
	ss.configChunk = idFromBytes(im.GetConfigChunk())
	ss.rootChunk = rootChunk
	merged, err := ingest.DecodeTree(ctx, b.Store, rootChunk)
	if err != nil {
		return nil, fmt.Errorf("decode base image: %w", err)
	}
	ss.merged = merged
	for _, l := range im.GetProvenanceLayers() {
		lt, err := ingest.DecodeTree(ctx, b.Store, idFromBytes(l.GetRootManifestChunk()))
		if err != nil {
			return nil, fmt.Errorf("decode provenance layer: %w", err)
		}
		ss.layerTrees = append(ss.layerTrees, lt)
		ss.layers = append(ss.layers, ingest.LayerResult{
			RootManifestChunk: idFromBytes(l.GetRootManifestChunk()),
			WhiteoutsCount:    l.GetWhiteoutsCount(),
		})
	}
	return ss, nil
}

func (b *Builder) applyInstruction(
	ctx context.Context,
	ss *stageState,
	inst dockerfile.Instruction,
	opts Options,
	ignore func(string) bool,
	shell []string,
	stages map[string]*stageState,
) error {
	switch v := inst.(type) {
	case *dockerfile.Arg:
		if val, ok := opts.BuildArgs[v.Name]; ok {
			ss.config.setEnv(v.Name, val)
		} else if v.DefaultValue != "" {
			ss.config.setEnv(v.Name, v.DefaultValue)
		}
		return nil
	case *dockerfile.Env:
		ss.config.SetEnv(v.Vars)
		return b.commitConfig(ctx, ss, inst, opts, "")
	case *dockerfile.Workdir:
		ss.config.Config().WorkingDir = v.Path
		return b.commitConfig(ctx, ss, inst, opts, "")
	case *dockerfile.User:
		ss.config.Config().User = v.User
		return b.commitConfig(ctx, ss, inst, opts, "")
	case *dockerfile.Label:
		ss.config.SetLabels(v.Labels)
		return b.commitConfig(ctx, ss, inst, opts, "")
	case *dockerfile.Expose:
		ss.config.SetExposedPorts(v.Ports)
		return b.commitConfig(ctx, ss, inst, opts, "")
	case *dockerfile.Volume:
		ss.config.SetVolumes(v.Paths)
		return b.commitConfig(ctx, ss, inst, opts, "")
	case *dockerfile.StopSignal:
		ss.config.SetStopSignal(v.Signal)
		return b.commitConfig(ctx, ss, inst, opts, "")
	case *dockerfile.Healthcheck:
		return b.commitConfig(ctx, ss, inst, opts, "")
	case *dockerfile.Cmd:
		if len(v.Argv) > 0 {
			ss.config.Config().Cmd = v.Argv
		} else {
			ss.config.Config().Cmd = []string{"/bin/sh", "-c", v.Raw}
		}
		return b.commitConfig(ctx, ss, inst, opts, "")
	case *dockerfile.Entrypoint:
		if len(v.Argv) > 0 {
			ss.config.Config().Entrypoint = v.Argv
		} else {
			ss.config.Config().Entrypoint = []string{"/bin/sh", "-c", v.Raw}
		}
		return b.commitConfig(ctx, ss, inst, opts, "")
	case *dockerfile.Copy:
		if v.From != "" {
			srcStage, ok := stages[v.From]
			if !ok {
				return fmt.Errorf("unknown stage %q in COPY --from", v.From)
			}
			return b.copyFromStage(ctx, ss, srcStage, v.Sources, v.Dest, inst, opts)
		}
		return b.doCopy(ctx, ss, v.Sources, v.Dest, opts, ignore, inst)
	case *dockerfile.Add:
		return b.doCopy(ctx, ss, v.Sources, v.Dest, opts, ignore, inst)
	case *dockerfile.Run:
		return b.doRun(ctx, ss, v, shell, opts)
	default:
		return fmt.Errorf("unsupported instruction %s", inst.Kind())
	}
}

func (b *Builder) commitConfig(ctx context.Context, ss *stageState, inst dockerfile.Instruction, opts Options, extra string) error {
	parentRoot := ss.rootChunk
	if !opts.NoCache {
		if hit, err := b.tryCache(ctx, ss, parentRoot, inst, extra); err != nil {
			return err
		} else if hit {
			return nil
		}
	}
	raw, err := ss.config.Marshal()
	if err != nil {
		return err
	}
	id, err := b.Store.Put(raw)
	if err != nil {
		return err
	}
	ss.configChunk = id
	empty := ingest.NewTree()
	return b.appendLayer(ctx, ss, parentRoot, empty, inst, opts, extra)
}

func resolveCopyDest(dest, workdir string) string {
	dest = strings.TrimSpace(dest)
	switch dest {
	case "", ".", "./":
		return workdir
	}
	if strings.HasPrefix(dest, "/") {
		return dest
	}
	if workdir == "" {
		return "/" + dest
	}
	return path.Join(workdir, dest)
}

func (b *Builder) doCopy(
	ctx context.Context,
	ss *stageState,
	sources []string,
	dest string,
	opts Options,
	ignore func(string) bool,
	inst dockerfile.Instruction,
) error {
	parentRoot := ss.rootChunk
	dest = resolveCopyDest(dest, ss.config.Config().WorkingDir)
	extra := CopyExtra(sources, nil)
	if !opts.NoCache {
		if hit, err := b.tryCache(ctx, ss, parentRoot, inst, extra); err != nil {
			return err
		} else if hit {
			return nil
		}
	}
	res, err := ingest.WalkDir(ctx, b.Store, ingest.WalkDirOptions{
		ContextDir: opts.ContextDir,
		Sources:    sources,
		Dest:       dest,
		Ignore:     ignore,
	})
	if err != nil {
		return err
	}
	return b.appendLayer(ctx, ss, parentRoot, res.Tree, inst, opts, extra)
}

func (b *Builder) copyFromStage(
	ctx context.Context,
	ss *stageState,
	srcStage *stageState,
	sources []string,
	dest string,
	inst dockerfile.Instruction,
	opts Options,
) error {
	parentRoot := ss.rootChunk
	dest = resolveCopyDest(dest, ss.config.Config().WorkingDir)
	extra := CopyExtra(sources, nil)
	if !opts.NoCache {
		if hit, err := b.tryCache(ctx, ss, parentRoot, inst, extra); err != nil {
			return err
		} else if hit {
			return nil
		}
	}
	tree := ingest.NewTree()
	dest = strings.TrimPrefix(dest, "/")
	for _, src := range sources {
		if err := copyNodeFromMerged(srcStage.merged, tree, src, dest); err != nil {
			return err
		}
	}
	return b.appendLayer(ctx, ss, parentRoot, tree, inst, opts, extra)
}

func copyNodeFromMerged(merged *ingest.LayerTree, layer *ingest.LayerTree, src, dest string) error {
	src = strings.TrimPrefix(src, "/")
	dest = strings.TrimPrefix(dest, "/")
	if node := merged.Lookup(src); node != nil && node.Type == ingest.NodeRegular {
		target := path.Join(dest, path.Base(src))
		return graftFile(layer, target, node)
	}
	return copyTreePrefix(merged, layer, src, dest)
}

func copyTreePrefix(merged, layer *ingest.LayerTree, srcPrefix, destPrefix string) error {
	srcPrefix = strings.TrimSuffix(srcPrefix, "/")
	var err error
	merged.EachNode(func(p string, node *ingest.Node) bool {
		if p == "" {
			return true
		}
		if srcPrefix != "" && p != srcPrefix && !strings.HasPrefix(p, srcPrefix+"/") {
			return true
		}
		if node.Type != ingest.NodeRegular {
			return true
		}
		rel := strings.TrimPrefix(p, srcPrefix)
		rel = strings.TrimPrefix(rel, "/")
		target := path.Join(destPrefix, rel)
		err = graftFile(layer, target, node)
		return err == nil
	})
	return err
}

func graftFile(layer *ingest.LayerTree, target string, src *ingest.Node) error {
	parentPath, base := splitPath(target)
	parent := ingestEnsureDir(layer, parentPath)
	node := &ingest.Node{
		Path:    target,
		Name:    base,
		Type:    ingest.NodeRegular,
		Mode:    src.Mode,
		Uid:     src.Uid,
		Gid:     src.Gid,
		Size:    src.Size,
		MtimeNs: src.MtimeNs,
		Xattrs:  src.Xattrs,
		Blocks:  src.Blocks,
		Nlink:   1,
	}
	ingestAttachChild(parent, base, node)
	layer.Put(node)
	return nil
}

func splitPath(clean string) (parent, base string) {
	if clean == "" {
		return "", ""
	}
	parent = path.Dir(clean)
	if parent == "." {
		parent = ""
	}
	base = path.Base(clean)
	return
}

func ingestEnsureDir(tree *ingest.LayerTree, dirPath string) *ingest.Node {
	if dirPath == "" {
		return tree.Root
	}
	if n := tree.Lookup(dirPath); n != nil {
		return n
	}
	parent, base := splitPath(dirPath)
	pn := ingestEnsureDir(tree, parent)
	node := &ingest.Node{
		Path:     dirPath,
		Name:     base,
		Type:     ingest.NodeDir,
		Mode:     0o755,
		Children: make(map[string]*ingest.Node),
		Nlink:    1,
	}
	ingestAttachChild(pn, base, node)
	tree.Put(node)
	return node
}

func ingestAttachChild(parent *ingest.Node, base string, child *ingest.Node) {
	if parent.Children == nil {
		parent.Children = make(map[string]*ingest.Node)
	}
	parent.Children[base] = child
}

func (b *Builder) doRun(ctx context.Context, ss *stageState, run *dockerfile.Run, shell []string, opts Options) error {
	parentRoot := ss.rootChunk
	if !opts.NoCache {
		if hit, err := b.tryCache(ctx, ss, parentRoot, run, ""); err != nil {
			return err
		} else if hit {
			return nil
		}
	}
	if b.Runner == nil {
		return fmt.Errorf("RUN requires a running voilad worker (start with `voilad`)")
	}
	var argv []string
	if len(run.Argv) > 0 {
		argv = run.Argv
	} else {
		argv = append(append([]string{}, shell...), run.Raw)
	}
	layerChunk, code, err := b.Runner.BuildRun(ctx, RunSpec{
		RootChunk:   ss.rootChunk,
		ConfigChunk: ss.configChunk,
		Argv:        argv,
		Env:         ss.config.Config().Env,
		Cwd:         ss.config.Config().WorkingDir,
		User:        ss.config.Config().User,
	}, b.Out, b.ErrOut)
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("RUN command exited with code %d", code)
	}
	lt, err := ingest.DecodeTree(ctx, b.Store, layerChunk)
	if err != nil {
		return err
	}
	return b.appendLayerTree(ctx, ss, parentRoot, lt, layerChunk, run, opts, "")
}

func (b *Builder) tryCache(ctx context.Context, ss *stageState, parentRoot chunkstore.ChunkID, inst dockerfile.Instruction, extra string) (bool, error) {
	key := CacheKey(parentRoot, inst, extra)
	entry, ok := b.ImgStore.LookupBuildCache(key)
	if !ok {
		return false, nil
	}
	lt, err := ingest.DecodeTree(ctx, b.Store, entry.LayerManifest)
	if err != nil {
		return false, nil
	}
	if !ingest.VerifyTreeChunks(ctx, lt, b.Store) {
		return false, nil
	}
	ss.configChunk = entry.ConfigChunk
	if err := b.appendLayerTree(ctx, ss, parentRoot, lt, entry.LayerManifest, inst, Options{}, extra); err != nil {
		return false, err
	}
	return true, nil
}

func (b *Builder) appendLayer(ctx context.Context, ss *stageState, parentRoot chunkstore.ChunkID, tree *ingest.LayerTree, inst dockerfile.Instruction, opts Options, extra string) error {
	chunk, err := ingest.BuildAndStoreLayerManifest(tree, b.Store)
	if err != nil {
		return err
	}
	return b.appendLayerTree(ctx, ss, parentRoot, tree, chunk, inst, opts, extra)
}

func (b *Builder) appendLayerTree(ctx context.Context, ss *stageState, parentRoot chunkstore.ChunkID, tree *ingest.LayerTree, chunk chunkstore.ChunkID, inst dockerfile.Instruction, opts Options, extra string) error {
	ss.layerTrees = append(ss.layerTrees, tree)
	ss.layers = append(ss.layers, ingest.LayerResult{
		RootManifestChunk: chunk,
		WhiteoutsCount:    tree.WhiteoutsN + tree.OpaqueN,
	})
	merged, err := ingest.MergeTrees(ss.layerTrees)
	if err != nil {
		return err
	}
	ss.merged = merged
	if err := b.refreshManifest(ctx, ss); err != nil {
		return err
	}
	if !opts.NoCache {
		key := CacheKey(parentRoot, inst, extra)
		_ = b.ImgStore.StoreBuildCache(key, chunk, ss.configChunk)
	}
	return nil
}

func (b *Builder) refreshManifest(ctx context.Context, ss *stageState) error {
	rootChunk, err := ingest.BuildAndStoreManifest(ss.merged, b.Store)
	if err != nil {
		return err
	}
	ss.rootChunk = rootChunk
	raw, err := ss.config.Marshal()
	if err != nil {
		return err
	}
	id, err := b.Store.Put(raw)
	if err != nil {
		return err
	}
	ss.configChunk = id
	return nil
}

func (b *Builder) finalize(ctx context.Context, ss *stageState, ref string) (*Result, error) {
	dig, err := ss.config.Digest()
	if err != nil {
		return nil, err
	}
	im := imageManifestFromStage(ss, ref, dig)
	chunks, bytes, err := ingest.ClosureStats(ctx, b.Store, im)
	if err != nil {
		return nil, fmt.Errorf("compute image closure stats: %w", err)
	}
	return &Result{
		Ref:                     ref,
		ImageDigest:             dig,
		ConfigChunk:             ss.configChunk,
		MergedRootManifestChunk: ss.rootChunk,
		Layers:                  ss.layers,
		BytesIn:                 bytes,
		ChunkCount:              chunks,
	}, nil
}

func imageManifestFromStage(ss *stageState, ref string, dig []byte) *voilapb.ImageManifest {
	layers := make([]*voilapb.Layer, 0, len(ss.layers))
	for _, l := range ss.layers {
		layers = append(layers, &voilapb.Layer{
			RootManifestChunk: l.RootManifestChunk[:],
			WhiteoutsCount:    l.WhiteoutsCount,
		})
	}
	return &voilapb.ImageManifest{
		ImageRef:                ref,
		ImageDigest:             dig,
		ConfigChunk:             ss.configChunk[:],
		MergedRootManifestChunk: ss.rootChunk[:],
		ProvenanceLayers:        layers,
	}
}

func idFromBytes(b []byte) chunkstore.ChunkID {
	var id chunkstore.ChunkID
	if len(b) >= len(id) {
		copy(id[:], b)
	}
	return id
}

// Persist writes the build result to the image store.
func Persist(imgStore *imagestore.Store, res *Result) error {
	layers := make([]*voilapb.Layer, 0, len(res.Layers))
	for _, l := range res.Layers {
		layers = append(layers, &voilapb.Layer{
			RootManifestChunk: l.RootManifestChunk[:],
			WhiteoutsCount:    l.WhiteoutsCount,
		})
	}
	im := &voilapb.ImageManifest{
		ImageRef:                res.Ref,
		ImageDigest:             res.ImageDigest,
		ConfigChunk:             res.ConfigChunk[:],
		MergedRootManifestChunk: res.MergedRootManifestChunk[:],
		ProvenanceLayers:        layers,
		TotalSize:               res.BytesIn,
		ChunkCount:              res.ChunkCount,
	}
	if err := imgStore.WriteManifestPB(res.Ref, im); err != nil {
		return err
	}
	now := time.Now().UnixNano()
	return imgStore.Upsert(imagestore.Record{
		Ref:                res.Ref,
		ImageDigest:        res.ImageDigest,
		MergedRootManifest: res.MergedRootManifestChunk[:],
		TotalSize:          int64(res.BytesIn),
		ChunkCount:         int64(res.ChunkCount),
		IngestedNS:         now,
		LastUsedNS:         now,
	})
}
