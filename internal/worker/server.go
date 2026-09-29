package worker

import (
	"net"

	voilapb "voila/internal/proto"

	"google.golang.org/grpc"
)

// Serve registers the Worker gRPC service on srv and serves incoming
// connections on l until the server is stopped (via Shutdown or listener
// close). It blocks; the returned error is whatever grpc.Server.Serve
// returns (typically nil after a clean GracefulStop, or ErrServerStopped
// after Stop).
//
// The Worker records the running server so Shutdown can stop it. A second
// Serve on the same Worker overwrites the recorded server (callers should
// not invoke Serve concurrently).
func (w *Worker) Serve(l net.Listener) error {
	srv := grpc.NewServer()
	voilapb.RegisterWorkerServer(srv, w)
	w.mu.Lock()
	w.server = srv
	w.mu.Unlock()
	return srv.Serve(l)
}

// setServer lets tests inject a fake runServer (e.g. to exercise Shutdown
// without spinning up a real gRPC server). Unused by production callers.
func (w *Worker) setServer(s runServer) {
	w.mu.Lock()
	w.server = s
	w.mu.Unlock()
}
