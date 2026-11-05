"""Docker-compatible stdin/stdout behaviour: -i, terminals, pipeable listings and flags."""

import fcntl
import os
import pty
import select
import subprocess
import termios
import time

from conftest import VOILA_BIN, Voila

BASE = "alpine:3.20"


def test_interactive_piped_stdin_reaches_eof(voila: Voila) -> None:
    voila.run("import", BASE)
    p = subprocess.run(
        [VOILA_BIN, "run", "--rm", "-i", BASE, "--", "wc", "-l"],
        env=voila.env,
        input="a\nb\nc\n",
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert p.returncode == 0, p.stderr
    assert p.stdout.strip() == "3", p.stdout


def _own_terminal(slave: int) -> None:
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)


def test_interactive_terminal_stdin_is_read_not_stopped(voila: Voila) -> None:
    """`run -i` (no -t) from a terminal: the container reads it instead of getting SIGTTIN."""
    voila.run("import", BASE)
    master, slave = pty.openpty()
    p = subprocess.Popen(
        [VOILA_BIN, "run", "--rm", "-i", BASE, "--", "head", "-n1"],
        env=voila.env,
        stdin=slave,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        preexec_fn=lambda: _own_terminal(slave),
    )
    os.close(slave)
    try:
        time.sleep(1.5)
        os.write(master, b"from-terminal\n")
        out, _ = p.communicate(timeout=30)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
        while select.select([master], [], [], 0)[0]:
            try:
                if not os.read(master, 4096):
                    break
            except OSError:
                break
        os.close(master)
    assert p.returncode == 0
    assert b"from-terminal" in out


def test_run_short_h_sets_hostname(voila: Voila) -> None:
    voila.run("import", BASE)
    res = voila.run("run", "--rm", "-h", "box1", BASE, "--", "hostname")
    assert res.out.strip() == "box1", res.out + res.err


def test_listings_print_to_stdout(voila: Voila) -> None:
    voila.run("import", BASE)
    assert voila.run("ps").out.startswith("ID ")
    assert BASE in voila.run("images").out
    assert voila.run("--version").out.startswith("voila ")


def test_rm_flags(voila: Voila) -> None:
    voila.run("import", BASE)
    voila.run("run", "-d", "--name", "-dash", BASE, "--", "sleep", "300")
    assert voila.run("rm", "--bogus", "x", check=False).rc == 2
    res = voila.run("rm", "-f", "nope", check=False)
    assert res.rc == 1 and "no such container nope" in res.err
    voila.run("rm", "-f", "--", "-dash")
    assert "-dash" not in voila.run("ps").out
