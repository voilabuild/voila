package cli

import (
	"context"
	"net"
	"os"
	"testing"

	voilapb "voila/internal/proto"
	"voila/internal/worker"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
)

func TestWriteLoadRegistryCreds(t *testing.T) {
	root := t.TempDir()
	const url = "https://example.com/registry"
	const tok = "dreg_test"

	if err := WriteRegistryCreds(root, url, tok); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(RegistryCredsPath(root))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("perms = %o, want 0600", info.Mode().Perm())
	}
	rc, err := LoadRegistryCreds(root)
	if err != nil {
		t.Fatal(err)
	}
	if rc.Registry != url || rc.Token != tok {
		t.Fatalf("loaded %+v, want registry=%q token=%q", rc, url, tok)
	}
}

func TestHandoffRegistryCreds_FileOnlyWhenDaemonDown(t *testing.T) {
	root := t.TempDir()
	socket := t.TempDir() + "/missing.sock"
	if err := HandoffRegistryCreds(context.Background(), socket, root, "https://r.example/registry", "dreg_x"); err != nil {
		t.Fatal(err)
	}
	rc, err := LoadRegistryCreds(root)
	if err != nil {
		t.Fatal(err)
	}
	if rc.Token != "dreg_x" {
		t.Fatalf("token = %q", rc.Token)
	}
}

func TestSetRegistryRPC(t *testing.T) {
	root := t.TempDir()
	const url = "https://example.com/registry"
	const tok = "dreg_handoff"

	lis := bufconn.Listen(1024 * 1024)
	hub := worker.NewRegistryHub()
	w := worker.NewWorker(worker.Config{Root: root, Registry: hub})
	srv := grpc.NewServer()
	voilapb.RegisterWorkerServer(srv, w)
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(func() { srv.Stop() })

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
			return lis.Dial()
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	client := voilapb.NewWorkerClient(conn)
	_, err = client.SetRegistry(context.Background(), &voilapb.SetRegistryRequest{
		RegistryUrl: url,
		Token:       tok,
	})
	if err != nil {
		t.Fatal(err)
	}
	if hub.Client() == nil {
		t.Fatal("hub has no client after SetRegistry")
	}
}
