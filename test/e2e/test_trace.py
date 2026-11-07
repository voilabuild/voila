"""VOILA_TRACE: every voila process appends Chrome trace events to one file."""

import json
from pathlib import Path

from conftest import Machine, Voila

BASE = "alpine:3.20"


def load_trace(path: Path) -> list[dict[str, object]]:
    text = path.read_text().rstrip().rstrip(",")
    events: list[dict[str, object]] = json.loads(text + "]")
    return events


def test_trace_covers_run_phases_and_lazy_fetches(machine: Machine, tmp_path: Path) -> None:
    a = machine("a")
    a.run("import", BASE)
    a.run("push", BASE)
    b: Voila = machine("b")
    trace = tmp_path / "trace.json"
    b.env["VOILA_TRACE"] = str(trace)
    res = b.run("run", "--rm", BASE, "--", "cat", "/etc/os-release")
    assert "Alpine" in res.out
    # Trace lines never reach the container's output (the log fd must not be confused with it).
    assert '"ph":' not in res.out + res.err

    events = load_trace(trace)
    names = {e["name"] for e in events}
    for phase in ("voila run", "start FUSE server", "container running", "serving", "fuse read", "http GET chunk"):
        assert phase in names, sorted(str(n) for n in names)
    procs = {str(e["args"]["name"]).split(" (")[0] for e in events if e["name"] == "process_name"}  # type: ignore[index]
    assert {"voila run", "voila container-worker", "voila container-fuse-serve"} <= procs
    spans = [e for e in events if e.get("ph") == "X"]
    assert all(isinstance(e["dur"], int) and e["dur"] >= 0 for e in spans)


def test_no_trace_without_env(voila: Voila, tmp_path: Path) -> None:
    cwd = tmp_path / "cwd"
    cwd.mkdir()
    voila.run("import", BASE)
    voila.run("run", "--rm", BASE, "--", "true", cwd=cwd)
    assert list(cwd.iterdir()) == []
    assert "VOILA_TRACE" not in voila.env
