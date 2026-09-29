// cmd_ps.go implements `voila ps`: a tabular listing of the daemon's
// registered contexts (running, finished, or scheduled). Requires a daemon.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"text/tabwriter"
	"time"

	"voila/internal/cli"
	voilapb "voila/internal/proto"
)

// cmdPs implements `voila ps [-root dir]`. Calls the daemon's List RPC and
// renders the response as a columnar table via text/tabwriter (zero-padded
// columns, space-separated). Columns: ID / IMAGE / STATUS / PID / STARTED /
// EXIT / FETCHED — matching plan §8 / task spec.
func cmdPs(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "ps", cfg.Stderr)
	var (
		rootFlag   string
		socketFlag string
	)
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.StringVar(&socketFlag, "socket", "", "worker socket path (default: $VOILA_SOCKET or /var/run/voila.sock)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("usage: voila ps [-root dir] [-socket path]")
	}
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	socket := cli.ResolveSocket(socketFlag, cfg.Socket, cli.RootExplicit(rootFlag), root)

	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}

	conn, client, err := cli.DialWorker(socket)
	if err != nil {
		return err
	}
	defer conn.Close()

	resp, err := client.List(context.Background(), &voilapb.ListRequest{})
	if err != nil {
		return fmt.Errorf("list: %w", err)
	}
	return renderCtxTable(out, resp.GetContexts())
}

// renderCtxTable renders a slice of ContextInfo as the columnar `voila ps`
// output: ID / IMAGE / STATUS / PID / STARTED / EXIT / FETCHED. Empty slices
// still emit the header line so scripts that grep on a column position keep
// working. An empty ImageRef (OCI-archive ingest with no RepoTags) renders
// "(unnamed)" — without the placeholder text/tabwriter pads the cell with
// spaces and awk's default FS collapses the whitespace, shifting the STATUS
// column. FETCHED renders "<chunks>/<human bytes>" from ContextInfo.stats
// (or "-" when stats is nil / missing).
func renderCtxTable(w io.Writer, contexts []*voilapb.ContextInfo) error {
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tIMAGE\tSTATUS\tPID\tSTARTED\tEXIT\tFETCHED")
	for _, c := range contexts {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%d\t%s\t%s\t%s\n",
			c.GetId(),
			refOrUnnamed(c.GetImageRef()),
			c.GetStatus(),
			c.GetPid(),
			formatStarted(c.GetStartedNs()),
			formatExit(c),
			formatFetched(c),
		)
	}
	return tw.Flush()
}

// formatStarted renders a started_ns (Unix nanoseconds) as a UTC second
// timestamp in RFC3339-ish shape; 0 → "-" (e.g. a Scheduled context that has
// not started yet).
func formatStarted(ns int64) string {
	if ns <= 0 {
		return "-"
	}
	return time.Unix(0, ns).UTC().Format("2006-01-02T15:04:05Z")
}

// formatExit renders an exit code: a non-Finished context shows "-" (the
// proto zero value is also rendered as "-" so consumers can distinguish
// "no exit yet" from "exited 0").
func formatExit(c *voilapb.ContextInfo) string {
	if c.GetStatus() != "finished" {
		return "-"
	}
	return fmt.Sprintf("%d", c.GetExitCode())
}

// formatFetched renders the FETCHED column: "<chunks>/<human bytes>" from
// the context's live/final fetch stats, or "-" when no stats are present
// (e.g. a context with no counting store — an old daemon or a fake launch).
func formatFetched(c *voilapb.ContextInfo) string {
	s := c.GetStats()
	if s == nil {
		return "-"
	}
	return fmt.Sprintf("%d/%s", s.GetChunksFetched(), cli.FormatBytes(s.GetBytesFetched()))
}
