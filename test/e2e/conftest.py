import os
import shutil
import socket
import subprocess
import threading
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

import pytest
import uvicorn

import registry

REPO = Path(__file__).resolve().parents[2]
VOILA_BIN = os.environ.get("VOILA_BIN", str(REPO / "zig-out/bin/voila"))


@dataclass
class Result:
    rc: int
    out: str
    err: str


@dataclass
class Voila:
    """One machine: a voila binary with its own store and $HOME."""

    root: Path
    env: dict[str, str]

    def run(self, *args: str, check: bool = True, cwd: Path | None = None) -> Result:
        p = subprocess.run(
            [VOILA_BIN, *args], env=self.env, cwd=cwd, capture_output=True, text=True, timeout=300
        )
        res = Result(p.returncode, p.stdout, p.stderr)
        if check and p.returncode != 0:
            pytest.fail(f"voila {' '.join(args)} exited {p.returncode}\n{p.stderr}")
        return res


@dataclass
class Registry:
    url: str
    state: registry.State


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _userns_blocked_by_apparmor() -> bool:
    knob = Path("/proc/sys/kernel/apparmor_restrict_unprivileged_userns")
    if not knob.exists() or knob.read_text().strip() != "1":
        return False
    binary = str(Path(VOILA_BIN).resolve())
    profiles = (f for f in Path("/etc/apparmor.d").glob("*") if f.is_file())
    return not any(binary in f.read_text(errors="ignore") for f in profiles)


@pytest.fixture(scope="session", autouse=True)
def _require_sandbox() -> None:
    if not Path(VOILA_BIN).exists():
        pytest.exit(f"no voila binary at {VOILA_BIN}: run `zig build` or set VOILA_BIN", 2)
    if not os.access("/dev/fuse", os.R_OK | os.W_OK) or shutil.which("fusermount3") is None:
        pytest.skip("needs /dev/fuse and fusermount3", allow_module_level=True)
    if _userns_blocked_by_apparmor():
        pytest.exit(
            f"AppArmor blocks user namespaces for {VOILA_BIN}: only binaries named in an "
            "/etc/apparmor.d profile may create them. Install this build to that path "
            "(install.sh puts it at ~/.local/bin/voila) and set VOILA_BIN to it.",
            2,
        )


@pytest.fixture(scope="session")
def _registry_server() -> Iterator[str]:
    port = _free_port()
    server = uvicorn.Server(uvicorn.Config(registry.app, port=port, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    while not server.started:
        time.sleep(0.01)
    yield f"http://127.0.0.1:{port}"
    server.should_exit = True
    thread.join()


@pytest.fixture
def registry_server(_registry_server: str) -> Registry:
    registry.state = registry.State()
    return Registry(_registry_server, registry.state)


@pytest.fixture
def machine(tmp_path: Path, registry_server: Registry) -> Callable[[str], Voila]:
    """Factory for isolated machines that share the test's registry."""

    def make(name: str) -> Voila:
        home = tmp_path / name / "home"
        root = tmp_path / name / "root"
        home.mkdir(parents=True)
        env = {
            "PATH": os.environ["PATH"],
            "HOME": str(home),
            "VOILA_ROOT": str(root),
            "VOILA_REGISTRY": registry_server.url,
            "VOILA_REGISTRY_TOKEN": "test",
        }
        return Voila(root, env)

    return make


@pytest.fixture
def voila(machine: Callable[[str], Voila]) -> Voila:
    return machine("a")
