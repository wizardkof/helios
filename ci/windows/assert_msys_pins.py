import json
import subprocess
import sys
from pathlib import Path

pins = json.loads(Path(__file__).with_name("ci-toolchain-pins.json").read_text())["qualifiedObservedTools"]["msys2Packages"]
prefix = "mingw-w64-i686-" if sys.argv[1] == "x86" else "mingw-w64-ucrt-x86_64-"
rows = []
for name, version in pins.items():
    if not (name.startswith(prefix) or name in ("git", "bison", "flex", "msys2-runtime")):
        continue
    row = {"name": name, "expectedVersion": version, "observedVersion": None, "exitCode": None, "status": "NOT_OBSERVED", "error": None}
    try:
        proc = subprocess.run(["pacman", "-Q", name], text=True, capture_output=True, check=False)
        row["exitCode"] = proc.returncode
        row["observedVersion"] = proc.stdout.strip() or proc.stderr.strip()
        row["status"] = "PASS" if proc.returncode == 0 and row["observedVersion"] == f"{name} {version}" else "FAIL"
        if row["status"] == "FAIL":
            row["error"] = "PACKAGE_VERSION_MISMATCH" if proc.returncode == 0 else "PACMAN_QUERY_FAILED"
    except Exception as exc:  # retain every independent package observation
        row["exitCode"] = -1
        row["status"] = "FAIL"
        row["error"] = f"PACMAN_QUERY: {exc}"
    rows.append(row)

receipt = {
    "schemaVersion": 1,
    "status": "PASS" if rows and all(row["status"] == "PASS" for row in rows) else "FAIL",
    "architecture": sys.argv[1],
    "packages": rows,
}
Path(sys.argv[2]).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
print(json.dumps(receipt, sort_keys=True))
if receipt["status"] != "PASS":
    raise SystemExit("MSYS2 package pin validation failed; all package observations were preserved")
