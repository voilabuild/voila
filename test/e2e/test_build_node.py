"""A real Node.js build: npm ci of next, @mui/material, aws-sdk and typescript."""

import resource
from pathlib import Path

from conftest import Voila

APP = Path(__file__).parent / "node-app"


def test_build_and_run_node_app(voila: Voila) -> None:
    voila.run("import", "node:22-bookworm-slim")
    voila.run("build", "-t", "node-app:1", str(APP))
    peak_mb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024
    print(f"voila build peak RSS: {peak_mb} MB")
    assert voila.run("run", "--rm", "node-app:1").out.startswith("ok typescript 5.7.3")
    # #70 measured 5.5 GB on this project.
    assert peak_mb < 1500, f"build peaked at {peak_mb} MB"
