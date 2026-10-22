#!/usr/bin/env python3
"""One-shot layout migration: poc -> PRD src/ tree + import path fixes."""
from __future__ import annotations

import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FUSE = ROOT / "poc" / "zig-fuse" / "src"
NBD = ROOT / "poc" / "zig-nbd" / "src"
VOILAD = ROOT / "poc" / "zig-voilad" / "src"

# zig-fuse: basename -> dest dir under src/
FUSE_MAP: dict[str, str] = {
    "constants.zig": "core",
    "hex_util.zig": "core",
    "voila_refkey.zig": "core",
    "voila_tree.zig": "core",
    "voila_paths.zig": "core",
    "voila_index.zig": "core",
    "proto_wire.zig": "codec",
    "voila_manifest_proto.zig": "codec",
    "voila_manifest_json.zig": "codec",
    "posix_util.zig": "sys",
    "voila_store.zig": "store",
    "voila_chunk_index.zig": "store",
    "voila_chunk_load.zig": "store",
    "voila_loader.zig": "store",
    "voila_loader_test.zig": "store",
    "voila_fetch_stats.zig": "store",
    "fixture.zig": "store",
    "voila_ocireg.zig": "registry",
    "voila_http.zig": "registry",
    "voila_registry.zig": "registry",
    "voila_registry_creds.zig": "registry",
    "voila_registry_fetch.zig": "registry",
    "voila_registry_hub.zig": "registry",
    "voila_image_pull.zig": "registry",
    "voila_login_creds.zig": "registry",
    "registry_session.zig": "registry",
    "voila_hub_import.zig": "registry",
    "voila_registry_ref.zig": "registry",
    "voila_registry_ref_test.zig": "registry",
    "mount_exec.zig": "mount",
    "fuse_abi.zig": "mount/fuse",
    "fuse_abi_test.zig": "mount/fuse",
    "fuse_conf_test.zig": "mount/fuse",
    "fuse_libfuse.zig": "mount/fuse",
    "fuse_linux.zig": "mount/fuse",
    "fuse_vfs.zig": "mount/fuse",
    "vfs.zig": "mount/fuse",
    "voila_vfs.zig": "mount/fuse",
    "read_walker.zig": "mount/fuse",
    "voila_resolve.zig": "runtime",
    "container_bind.zig": "runtime/oci",
    "container_chroot.zig": "runtime/oci",
    "container_exec.zig": "runtime/oci",
    "container_lifecycle.zig": "runtime/oci",
    "container_ports.zig": "runtime/oci",
    "container_pty.zig": "runtime/oci",
    "container_run.zig": "runtime/oci",
    "container_run_opts.zig": "runtime/oci",
    "container_store.zig": "runtime/oci",
    "run_attached.zig": "runtime/oci",
    "run_cli_parse.zig": "cli",
    "main.zig": "app",
}

RUNTIME_IFACE = {
    "iface.zig": "runtime",
    "local.zig": "runtime",
    "open.zig": "runtime",
    "remote.zig": "runtime",
    "types.zig": "runtime",
}

NBD_MAP: dict[str, str] = {
    "backend.zig": "mount/erofs_nbd",
    "capacity_wait.zig": "mount/erofs_nbd",
    "constants.zig": "mount/erofs_nbd",
    "erofs_build.zig": "mount/erofs_nbd",
    "fixture_build.zig": "mount/erofs_nbd",
    "hex_util.zig": "mount/erofs_nbd",
    "image_resolve.zig": "mount/erofs_nbd",
    "nbd_blocking.zig": "mount/erofs_nbd",
    "nbd_linux.zig": "mount/erofs_nbd",
    "posix_util.zig": "mount/erofs_nbd",
    "voila_store.zig": "mount/erofs_nbd",
    "voila_tree.zig": "mount/erofs_nbd",
    "voilad_bundle.zig": "mount/erofs_nbd",
    "main.zig": "mount/erofs_nbd",
}

NBD_MANIFEST = {
    "proto_wire.zig": "mount/erofs_nbd/manifest",
    "voila_manifest_proto.zig": "mount/erofs_nbd/manifest",
}

VOILAD_MAP: dict[str, str] = {
    "accept_suite.zig": "daemon",
    "bench_mount.zig": "daemon",
    "chunk_cache.zig": "daemon",
    "contexts.zig": "daemon",
    "erofs_mount.zig": "daemon",
    "events.zig": "daemon",
    "grpc_shim.zig": "daemon/transport",
    "image_totals.zig": "daemon",
    "launch.zig": "daemon",
    "lifecycle.zig": "daemon",
    "main.zig": "daemon",
    "mount_backend.zig": "daemon",
    "registry_creds.zig": "daemon",
    "registry_global.zig": "daemon",
    "ring.zig": "daemon",
    "runtime.zig": "daemon",
    "sync_util.zig": "daemon",
    "voila_resolve.zig": "daemon",
}

IMPORT_RE = re.compile(r'@import\("([^"]+\.zig)"\)')


def rel_import(from_file: Path, to_file: Path) -> str:
    rel = os.path.relpath(to_file, start=from_file.parent)
    if not rel.startswith("."):
        rel = "./" + rel
    return rel.replace("\\", "/")


def build_index() -> dict[str, Path]:
    idx: dict[str, Path] = {}
    src = ROOT / "src"

    def reg(path: Path, key: str | None = None) -> None:
        k = key or path.name
        if k in idx and idx[k] != path:
            # disambiguate by full relative path suffix
            rel = str(path.relative_to(src))
            idx[rel] = path
            idx[f"{path.parent.name}/{k}"] = path
        else:
            idx[k] = path

    for p in src.rglob("*.zig"):
        reg(p)
        rel = str(p.relative_to(src))
        idx[rel] = p
    return idx


def fix_imports_in_file(path: Path, index: dict[str, Path]) -> None:
    text = path.read_text()
    changed = False

    def repl(m: re.Match[str]) -> str:
        nonlocal changed
        spec = m.group(1)
        if spec.startswith("../") or spec.startswith("./"):
            return m.group(0)
        target = index.get(spec)
        if target is None:
            # runtime/open.zig style
            if spec.startswith("runtime/"):
                target = index.get(spec.split("/", 1)[1])
        if target is None:
            return m.group(0)
        new = rel_import(path, target)
        if new != spec:
            changed = True
            return f'@import("{new}")'
        return m.group(0)

    new_text = IMPORT_RE.sub(repl, text)
    # runtime/ subfolder imports
    new_text = new_text.replace('@import("runtime/open.zig")', '@import("../runtime/open.zig")')
    new_text = new_text.replace('@import("runtime/iface.zig")', '@import("../runtime/iface.zig")')
    new_text = new_text.replace('@import("runtime/local.zig")', '@import("../runtime/local/local.zig")')
    new_text = new_text.replace('@import("runtime/remote.zig")', '@import("../runtime/remote/remote.zig")')
    new_text = new_text.replace('@import("runtime/types.zig")', '@import("../runtime/types.zig")')
    if new_text != text:
        path.write_text(new_text)


def copy_file(src: Path, dest_dir: Path) -> Path:
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / src.name
    dest.write_bytes(src.read_bytes())
    return dest


def main() -> None:
    src_root = ROOT / "src"
    if src_root.exists():
        raise SystemExit("src/ already exists — aborting")

    # C shims and fuse config
    c_dest = src_root / "c"
    c_dest.mkdir(parents=True)
    fuse_c = ROOT / "poc" / "zig-fuse" / "c"
    if fuse_c.is_dir():
        for f in fuse_c.iterdir():
            (c_dest / f.name).write_bytes(f.read_bytes())
    for name in ("blake3_shim.h", "zstd_shim.h", "sqlite_shim.h", "fuse3_shim.c", "fuse3_shim.h"):
        s = FUSE / name
        if s.is_file():
            copy_file(s, c_dest)

    voilad_c = VOILAD.parent / "src"
    for name in ("grpc_worker_shim.c", "grpc_worker_shim.h"):
        s = voilad_c / name
        if s.is_file():
            copy_file(s, src_root / "daemon" / "transport")

    for base, dest in FUSE_MAP.items():
        s = FUSE / base
        if not s.is_file():
            if base == "main.zig":
                continue
            raise SystemExit(f"missing {s}")
        copy_file(s, src_root / dest)

    for base, dest in RUNTIME_IFACE.items():
        s = FUSE / "runtime" / base
        copy_file(s, src_root / dest)

    for base, dest in NBD_MAP.items():
        s = NBD / base
        if s.is_file():
            copy_file(s, src_root / dest)

    nbd_manifest = NBD / "manifest"
    if nbd_manifest.is_dir():
        for base, dest in NBD_MANIFEST.items():
            copy_file(nbd_manifest / base, src_root / dest)

    for base, dest in VOILAD_MAP.items():
        s = VOILAD / base
        if s.is_file():
            copy_file(s, src_root / dest)

    # cmd entrypoints placeholders filled later
    (ROOT / "cmd" / "voila").mkdir(parents=True, exist_ok=True)
    (ROOT / "cmd" / "voilad").mkdir(parents=True, exist_ok=True)

    index = build_index()
    for p in src_root.rglob("*.zig"):
        fix_imports_in_file(p, index)

    print("Migration wrote", len(list(src_root.rglob("*.zig"))), "zig files under src/")


if __name__ == "__main__":
    main()
