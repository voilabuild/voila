package main

import (
	"bytes"
	"net"
	"path/filepath"
	"testing"

	"voila/internal/cli"
	voilapb "voila/internal/proto"
	"voila/internal/worker"

	"google.golang.org/grpc"
)

func TestHandoffRegistryCredsViaSocket(t *testing.T) {
	root := t.TempDir()
	socketDir := t.TempDir()
	socket := filepath.Join(socketDir, "voila.sock")

	hub := worker.NewRegistryHub()
	w := worker.NewWorker(worker.Config{Root: root, Registry: hub})
	lis, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	srv := grpc.NewServer()
	voilapb.RegisterWorkerServer(srv, w)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(func() {
		srv.Stop()
		_ = lis.Close()
	})

	t.Setenv("VOILA_REGISTRY", "https://handoff.example/registry")
	t.Setenv("VOILA_REGISTRY_TOKEN", "dreg_socket")

	cfg := Config{
		Root:   root,
		Socket: socket,
		Stdout: &bytes.Buffer{},
		Stderr: &bytes.Buffer{},
	}
	if err := handoffRegistryCreds(cfg, "", socket); err != nil {
		t.Fatal(err)
	}
	rc, err := cli.LoadRegistryCreds(root)
	if err != nil {
		t.Fatal(err)
	}
	if rc.Token != "dreg_socket" {
		t.Fatalf("file token = %q", rc.Token)
	}
	if hub.Client() == nil {
		t.Fatal("daemon hub not updated via SetRegistry")
	}
}
