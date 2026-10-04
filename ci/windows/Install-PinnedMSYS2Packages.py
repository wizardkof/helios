#!/usr/bin/env python3
"""Fetch and install only the archived MSYS2 packages covered by manifest hashes."""
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

architecture, cache_dir, receipt_path = sys.argv[1:]
manifest = json.loads(Path(__file__).with_name("ci-toolchain-pins.json").read_text(encoding="utf-8"))
pins = manifest["qualifiedObservedTools"]["msys2Packages"]
archive = manifest["msys2ArchivedPackages"]
cache = Path(cache_dir)
cache.mkdir(parents=True, exist_ok=True)
rows = []
for package in archive["packages"]:
    if package["architecture"] != architecture:
        continue
    path = cache / package["file"]
    row = {"name": package["name"], "version": package["version"], "url": archive["baseUrl"] + ("/ucrt64/" if architecture == "x64" else "/i686/") + package["file"], "path": str(path), "expectedSha256": package["sha256"], "observedSha256": None, "status": "NOT_OBSERVED", "error": None}
    try:
        if not path.is_file():
            with urllib.request.urlopen(row["url"], timeout=120) as response, path.open("wb") as output:
                while block := response.read(1024 * 1024):
                    output.write(block)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        row["observedSha256"] = digest
        if digest != package["sha256"]:
            raise RuntimeError("ARCHIVED_PACKAGE_SHA256_MISMATCH")
        result = subprocess.run(["pacman", "-U", "--noconfirm", "--needed", str(path)], text=True, capture_output=True)
        row["pacmanExitCode"] = result.returncode
        row["pacmanOutput"] = (result.stdout + result.stderr)[-12000:]
        if result.returncode:
            raise RuntimeError("PACMAN_INSTALL_FAILED")
        query = subprocess.run(["pacman", "-Q", package["name"]], text=True, capture_output=True)
        row["observedPackage"] = query.stdout.strip() or query.stderr.strip()
        if query.returncode or row["observedPackage"] != f"{package['name']} {package['version']}":
            raise RuntimeError("INSTALLED_PACKAGE_IDENTITY_MISMATCH")
        row["status"] = "PASS"
    except Exception as exc:
        row["status"] = "FAIL"
        row["error"] = str(exc)
    rows.append(row)
receipt = {"schemaVersion": 1, "architecture": architecture, "status": "PASS" if rows and all(row["status"] == "PASS" for row in rows) else "FAIL", "packages": rows}
Path(receipt_path).parent.mkdir(parents=True, exist_ok=True)
Path(receipt_path).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
print(json.dumps(receipt, sort_keys=True))
if receipt["status"] != "PASS":
    raise SystemExit("PINNED_MSYS2_ARCHIVE_INSTALL_FAILED")
