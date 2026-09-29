// cmd_login.go implements `voila login [registry-url]`: persist registry URL
// and API key to ~/.config/voila/credentials and hand them off to voilad.
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"golang.org/x/term"
	"voila/internal/cli"
)

func cmdLogin(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "login", cfg.Stderr)
	var rootFlag string
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 1 {
		return errors.New("usage: voila login [registry-url] [-root dir]")
	}

	in := cfg.Stdin
	if in == nil {
		in = os.Stdin
	}
	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}

	rawURL := ""
	if fs.NArg() == 1 {
		rawURL = fs.Arg(0)
	} else {
		fmt.Fprintf(out, "Registry URL [%s]: ", cli.DefaultRegistryURL)
		line, err := bufio.NewReader(in).ReadString('\n')
		if err != nil {
			return fmt.Errorf("read registry URL: %w", err)
		}
		rawURL = strings.TrimSpace(line)
		if rawURL == "" {
			rawURL = cli.DefaultRegistryURL
		}
	}

	url := cli.NormalizeRegistryURL(rawURL)
	if url == "" {
		return errors.New("registry URL is required")
	}

	token, err := readAPIKey(in, out)
	if err != nil {
		return err
	}
	if token == "" {
		return errors.New("API key is required")
	}

	ctx := context.Background()
	if err := cli.ProbeRegistryAuth(ctx, url, token); err != nil {
		return fmt.Errorf("registry auth check failed: %w", err)
	}
	if err := cli.SaveLoginCreds(url, token); err != nil {
		return err
	}

	root := cli.ResolveRoot(rootFlag, cfg.Root)
	socket := cli.ResolveSocket("", cfg.Socket, cli.RootExplicit(rootFlag), root)
	if err := cli.HandoffRegistryCreds(ctx, socket, root, url, token); err != nil {
		return fmt.Errorf("registry handoff: %w", err)
	}

	fmt.Fprintf(out, "logged in to %s\n", url)
	return nil
}

func readAPIKey(in io.Reader, out io.Writer) (string, error) {
	f, ok := in.(*os.File)
	if ok {
		if term.IsTerminal(int(f.Fd())) {
			fmt.Fprint(out, "API key: ")
			b, err := term.ReadPassword(int(f.Fd()))
			fmt.Fprintln(out)
			if err != nil {
				return "", fmt.Errorf("read API key: %w", err)
			}
			return strings.TrimSpace(string(b)), nil
		}
	}
	fmt.Fprint(out, "API key: ")
	line, err := bufio.NewReader(in).ReadString('\n')
	if err != nil {
		return "", fmt.Errorf("read API key: %w", err)
	}
	return strings.TrimSpace(line), nil
}
