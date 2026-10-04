#!/usr/bin/env python3
"""Record and enforce the MSYS2-native Ninja role used by Mesa's Meson build."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

arch, executable, output = sys.argv[1:]
pins = json.loads(Path(__file__).with_name("ci-toolchain-pins.json").read_text(encoding="utf-8"))
prefix = "mingw-w64-i686-" if arch == "x86" else "mingw-w64-ucrt-x86_64-"
package = prefix + "ninja"
expected_package = pins["qualifiedObservedTools"]["msys2Packages"][package]
package_row = subprocess.run(["pacman", "-Q", package], text=True, capture_output=True)
resolved = Path(executable).resolve() if executable else None
try:
    version = subprocess.run([str(resolved), "--version"], text=True, capture_output=True) if resolved else None
    data = resolved.read_bytes() if resolved and resolved.is_file() else b""
    execution_error = None
except Exception as exc:
    version = None
    data = b""
    execution_error = str(exc)
receipt = {
    "schemaVersion": 1,
    "role": "mesa-msys2-native-ninja",
    "architecture": arch,
    "package": package,
    "expectedPackageVersion": expected_package,
    "observedPackage": package_row.stdout.strip(),
    "packageExitCode": package_row.returncode,
    "path": str(resolved) if resolved else None,
    "versionOutput": ((version.stdout + version.stderr).strip() if version else None),
    "versionExitCode": (version.returncode if version else None),
    "executionError": execution_error,
    "size": len(data) if data else None,
    "sha256": hashlib.sha256(data).hexdigest() if data else None,
}
receipt["status"] = "PASS" if (
    package_row.returncode == 0
    and receipt["observedPackage"] == package + " " + expected_package
    and version is not None
    and version.returncode == 0
    and receipt["versionOutput"] == "1.13.2"
    and data
) else "FAIL"
Path(output).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
print(json.dumps(receipt, sort_keys=True))
if receipt["status"] != "PASS":
    raise SystemExit("MSYS2 Ninja role failed pin validation")
