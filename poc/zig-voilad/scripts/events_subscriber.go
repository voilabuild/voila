//go:build ignore

package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	voilapb "voila/internal/proto"
)

func main() {
	socket := os.Getenv("VOILA_SOCKET")
	if socket == "" {
		fmt.Fprintln(os.Stderr, "VOILA_SOCKET required")
		os.Exit(1)
	}
	timeout := 45 * time.Second
	if v := os.Getenv("EVENTS_TIMEOUT"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			timeout = d
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	conn, err := grpc.DialContext(ctx, "unix://"+socket, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer conn.Close()
	client := voilapb.NewWorkerClient(conn)
	stream, err := client.Events(ctx, &voilapb.EventsRequest{})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	seen := map[voilapb.EventType]bool{}
	var lastCtx string
	for {
		ev, err := stream.Recv()
		if err != nil {
			fmt.Fprintf(os.Stderr, "stream end: %v\n", err)
			if seen[voilapb.EventType_EVENT_TYPE_SCHEDULED] && seen[voilapb.EventType_EVENT_TYPE_STARTED] && seen[voilapb.EventType_EVENT_TYPE_FINISHED] {
				os.Exit(0)
			}
			os.Exit(1)
		}
		lastCtx = ev.GetContextId()
		seen[ev.GetType()] = true
		fmt.Printf("event context=%s type=%v exit=%d ts=%d\n", ev.GetContextId(), ev.GetType(), ev.GetExitCode(), ev.GetTimestampNs())
		if seen[voilapb.EventType_EVENT_TYPE_SCHEDULED] && seen[voilapb.EventType_EVENT_TYPE_STARTED] && seen[voilapb.EventType_EVENT_TYPE_FINISHED] {
			fmt.Printf("events-ok context=%s\n", lastCtx)
			os.Exit(0)
		}
	}
}
