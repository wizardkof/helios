#!/usr/bin/env python3
"""Stage a private QEMU + virglrenderer runtime without touching host installs."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(args: list[str]) -> str:
    result = subprocess.run(args, check=True, text=True, capture_output=True)
    return result.stdout + result.stderr


def package(qemu: Path, renderer: Path, output: Path) -> dict[str, object]:
    output = output.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"output directory must be empty: {output}")
    qemu = qemu.resolve(strict=True)
    renderer = renderer.resolve(strict=True)
    if not qemu.is_file() or not renderer.is_file():
        raise ValueError("QEMU and renderer inputs must be regular files")

    needed = run(["readelf", "-d", str(qemu)])
    if "Shared library: [libvirglrenderer.so.1]" not in needed:
        raise ValueError("QEMU does not dynamically require libvirglrenderer.so.1")

    output.mkdir(parents=True, exist_ok=True)
    lib_dir = output / "lib"
    lib_dir.mkdir()
    staged_qemu = output / "qemu-system-x86_64"
    staged_renderer = lib_dir / "libvirglrenderer.so.1"
    shutil.copy2(qemu, staged_qemu)
    shutil.copy2(renderer, staged_renderer)
    run(["patchelf", "--set-rpath", "$ORIGIN/lib", str(staged_qemu)])
    run(["patchelf", "--set-soname", "libvirglrenderer.so.1", str(staged_renderer)])

    dynamic = run(["readelf", "-d", str(staged_qemu)])
    if "Library runpath: [$ORIGIN/lib]" not in dynamic:
        raise ValueError("staged QEMU RUNPATH is not package-relative")
    resolution = run(["ldd", str(staged_qemu)])
    resolved = next(
        (line.split("=>", 1)[1].split("(", 1)[0].strip()
         for line in resolution.splitlines()
         if "libvirglrenderer.so.1 =>" in line),
        None,
    )
    if resolved != str(staged_renderer):
        raise ValueError(f"QEMU resolved renderer outside package: {resolved!r}")

    manifest: dict[str, object] = {
        "schema_version": 1,
        "scope": "private-host-package; no guest, GPU, or runtime launch",
        "files": {
            "qemu-system-x86_64": {
                "sha256": sha256(staged_qemu),
                "source_sha256": sha256(qemu),
            },
            "lib/libvirglrenderer.so.1": {
                "sha256": sha256(staged_renderer),
                "source_sha256": sha256(renderer),
            },
        },
        "qemu_renderer_resolution": resolved,
        "qemu_version": run([str(staged_qemu), "--version"]).splitlines()[0],
        "renderer_source": str(renderer),
        "qemu_source": str(qemu),
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu", type=Path, required=True)
    parser.add_argument("--renderer", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = package(args.qemu, args.renderer, args.out)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"package_host_stack: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
