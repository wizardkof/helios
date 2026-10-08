"""Real MSYS2 downgrade experiment and final canonical pin check, diagnostic only."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request
from msys_archive_restore import authenticate_package, command, run_msys

arch, output = sys.argv[1:]
out = Path(output); out.mkdir(parents=True, exist_ok=True)
rows = []
receipt = {"architecture": arch, "status": "FAIL", "commands": rows,
           "head": os.environ.get("GITHUB_SHA"), "run": os.environ.get("GITHUB_RUN_ID")}
try:
    if os.name != "nt": raise ValueError("REFUSE_NON_WINDOWS_MSYS2")
    here = Path(__file__).parent
    manifest = json.loads((here/"ci-toolchain-pins.json").read_text())
    pkg = next(p for p in manifest["msys2ArchivedPackages"]["packages"] if p["architecture"]==arch and p["name"].endswith("-pkgconf"))
    f = out/pkg["file"]
    for suffix in ("", ".sig"):
        with urllib.request.urlopen(pkg["url"]+suffix, timeout=120) as r:
            Path(str(f)+suffix).write_bytes(r.read())
    receipt["archiveUrl"] = pkg["url"]
    receipt["archiveSha256"] = hashlib.sha256(f.read_bytes()).hexdigest()
    receipt["authentication"] = authenticate_package(pkg, f)
    code, before = command(["pacman", "-Q", pkg["name"]], run_msys, rows)
    receipt["before"] = before.strip()
    if code or before.strip()!=pkg["name"]+" 1~3.0.7-2": raise ValueError("DOWNGRADE_FIXTURE_NOT_MINUS_2")
    code, _ = command(["bash", "/usr/bin/pacman-key", "--list-keys", "5F944B027F7FE2091985AA2EFA11531AA0AA7F57"], run_msys, rows)
    if code: raise ValueError("SIGNER_NOT_IN_NATIVE_KEYRING")
    code, _ = command(["pacman", "-Q", "msys2-keyring"], run_msys, rows)
    if code: raise ValueError("NATIVE_KEYRING_IDENTITY_MISSING")
    code, _ = command(["sha256sum", "/usr/share/pacman/keyrings/msys2.gpg", "/etc/pacman.d/gnupg/pubring.gpg"], run_msys, rows)
    if code: raise ValueError("NATIVE_KEYRING_HASH_MISSING")
    # Measure the original flag rather than asserting what pacman must do.
    code, _ = command(["pacman", "-U", "--noconfirm", "--needed", str(f)], run_msys, rows)
    receipt["originalNeededExit"] = code
    if code: raise ValueError("ORIGINAL_NEEDED_EXPERIMENT_FAILED")
    code, value = command(["pacman", "-Q", pkg["name"]], run_msys, rows)
    receipt["originalNeededAfter"] = value.strip()
    if code: raise ValueError("ORIGINAL_NEEDED_QUERY_FAILED")
    code, _ = command(["pacman", "-S", "--noconfirm", pkg["name"]], run_msys, rows)
    if code: raise ValueError("RESET_DOWNGRADE_FIXTURE_FAILED")
    code, value = command(["pacman", "-Q", pkg["name"]], run_msys, rows)
    if code or value.strip()!=before.strip(): raise ValueError("RESET_FIXTURE_IDENTITY_MISMATCH")
    for iteration in (1, 2):
        target = out/("restore-"+str(iteration)+".json")
        code, _ = command([sys.executable, str(here/"Install-PinnedMSYS2Packages.py"), arch, str(out/"archives"), str(target)], run_msys, rows)
        if code: raise ValueError("RESTORE_FAILED_"+str(iteration))
        observed = json.loads(target.read_text())
        if iteration==2 and any(p.get("action")!="ALREADY_EXACT" for p in observed["packages"]): raise ValueError("RESTORE_NOT_IDEMPOTENT")
    code, _ = command([sys.executable, str(here/"assert_msys_pins.py"), arch, str(out/"assert-msys-pins.json")], run_msys, rows)
    if code: raise ValueError("CANONICAL_PIN_CHECK_FAILED")
    code, value = command(["pacman", "-Q", pkg["name"]], run_msys, rows)
    receipt["after"] = value.strip()
    if code or value.strip()!=pkg["name"]+" "+pkg["version"]: raise ValueError("FINAL_IDENTITY_MISMATCH")
    receipt["status"] = "PASS"
except Exception as exc:
    receipt["error"] = str(exc)
finally:
    (out/"native-preflight.json").write_text(json.dumps(receipt,indent=2)+"\n")
print(json.dumps(receipt))
if receipt["status"]!="PASS": raise SystemExit(1)
