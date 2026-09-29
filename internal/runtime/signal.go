package runtime

import (
	"fmt"
	"syscall"
)

// signalName returns the symbolic signal name runc's `kill` subcommand
// expects (e.g. "SIGTERM", "SIGKILL"). For signals not in the explicit table,
// it falls back to the decimal value, which runc also accepts. We keep this
// here (not in a build-tagged file) because internal/runtime must build on
// every platform; the constants we use (SIGINT/SIGTERM/SIGKILL/etc.) exist
// identically on every Unix-like SysV-derivative syscall package and are
// unused on the platforms where runc itself is unavailable.
func signalName(s syscall.Signal) string {
	switch s {
	case syscall.SIGHUP:
		return "SIGHUP"
	case syscall.SIGINT:
		return "SIGINT"
	case syscall.SIGQUIT:
		return "SIGQUIT"
	case syscall.SIGILL:
		return "SIGILL"
	case syscall.SIGTRAP:
		return "SIGTRAP"
	case syscall.SIGABRT:
		return "SIGABRT"
	case syscall.SIGBUS:
		return "SIGBUS"
	case syscall.SIGFPE:
		return "SIGFPE"
	case syscall.SIGKILL:
		return "SIGKILL"
	case syscall.SIGUSR1:
		return "SIGUSR1"
	case syscall.SIGSEGV:
		return "SIGSEGV"
	case syscall.SIGUSR2:
		return "SIGUSR2"
	case syscall.SIGPIPE:
		return "SIGPIPE"
	case syscall.SIGALRM:
		return "SIGALRM"
	case syscall.SIGTERM:
		return "SIGTERM"
	case syscall.SIGCHLD:
		return "SIGCHLD"
	case syscall.SIGCONT:
		return "SIGCONT"
	case syscall.SIGSTOP:
		return "SIGSTOP"
	case syscall.SIGTSTP:
		return "SIGTSTP"
	case syscall.SIGTTIN:
		return "SIGTTIN"
	case syscall.SIGTTOU:
		return "SIGTTOU"
	case syscall.SIGURG:
		return "SIGURG"
	case syscall.SIGXCPU:
		return "SIGXCPU"
	case syscall.SIGXFSZ:
		return "SIGXFSZ"
	case syscall.SIGVTALRM:
		return "SIGVTALRM"
	case syscall.SIGPROF:
		return "SIGPROF"
	case syscall.SIGWINCH:
		return "SIGWINCH"
	case syscall.SIGIO:
		return "SIGIO"
	case syscall.SIGSYS:
		return "SIGSYS"
	}
	return fmt.Sprintf("%d", int(s))
}
