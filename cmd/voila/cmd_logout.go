// cmd_logout.go implements `voila logout`: remove ~/.config/voila/credentials.
package main

import (
	"errors"
	"fmt"
	"os"

	"voila/internal/cli"
)

func cmdLogout(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "logout", cfg.Stderr)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("usage: voila logout")
	}
	if err := cli.DeleteLoginCreds(); err != nil {
		return err
	}
	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}
	fmt.Fprintln(out, "logged out")
	return nil
}
