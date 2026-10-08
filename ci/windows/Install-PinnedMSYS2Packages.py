#!/usr/bin/env python3
"""Restore authenticated archives in the MSYS2 runner, preserving exact receipts."""
import hashlib
import json
import os
import platform
import sys
import urllib.request
from pathlib import Path
from msys_archive_restore import authenticate_package, restore_package


def main():
    architecture, cache_dir, receipt_path = sys.argv[1:]
    if architecture not in ("x64", "x86"): raise SystemExit("INVALID_ARCHITECTURE")
    if os.name != "nt": raise SystemExit("REFUSE_NON_WINDOWS_MSYS2_PACKAGE_INSTALL")
    manifest = json.loads(Path(__file__).with_name("ci-toolchain-pins.json").read_text(encoding="utf-8"))
    archive = manifest["msys2ArchivedPackages"]
    pins = manifest["qualifiedObservedTools"]["msys2Packages"]
    cache = Path(cache_dir); cache.mkdir(parents=True, exist_ok=True)
    rows = []
    for package in archive["packages"]:
        if package["architecture"] != architecture: continue
        path = cache / package["file"]
        url = package.get("url", archive["baseUrl"] + ("/ucrt64/" if architecture == "x64" else "/i686/") + package["file"])
        row = {"name": package["name"], "version": package["version"], "url": url,
               "path": str(path), "expectedSha256": package["sha256"], "status": "FAIL", "error": None}
        try:
            if pins.get(package["name"]) != package["version"]: raise ValueError("ARCHIVE_PIN_INCONSISTENT")
            for suffix in ("", ".sig"):
                target = Path(str(path)+suffix)
                if not target.exists():
                    with urllib.request.urlopen(url+suffix, timeout=120) as response, target.open("wb") as output:
                        while block := response.read(1024*1024): output.write(block)
            row["observedSha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            row["authentication"] = authenticate_package(package, path)
            row.update(restore_package(package, path))
        except Exception as exc:
            row["error"] = str(exc)
        rows.append(row)
        # A failed authenticity/install gate stops before another package can mutate the runner.
        if row["status"] != "PASS": break
    receipt = {"schemaVersion": 1, "architecture": architecture,
               "status": "PASS" if rows and all(r["status"]=="PASS" for r in rows) else "FAIL", "packages": rows}
    Path(receipt_path).parent.mkdir(parents=True, exist_ok=True)
    Path(receipt_path).write_text(json.dumps(receipt, indent=2)+"\n", encoding="utf-8")
    print(json.dumps(receipt, sort_keys=True))
    if receipt["status"] != "PASS":
        failed = rows[-1]
        raise SystemExit(failed.get("pacmanExitCode") or 1)

if __name__ == "__main__": main()
