"""Authenticated MSYS2 local-archive restoration; no host Linux package installs."""
import hashlib
import subprocess
from pathlib import Path


def command(argv, run, rows):
    result = run(argv, capture_output=True, check=False)
    stdout = result.stdout if isinstance(result.stdout, bytes) else result.stdout.encode()
    stderr = result.stderr if isinstance(result.stderr, bytes) else result.stderr.encode()
    rows.append({"command": argv, "exitCode": result.returncode,
                 "stdout": stdout.decode("utf-8", errors="replace"),
                 "stderr": stderr.decode("utf-8", errors="replace"),
                 "stdoutHex": stdout.hex(), "stderrHex": stderr.hex()})
    return result.returncode, stdout.decode("utf-8", errors="strict")


def validate_metadata(package, text):
    fields = {}
    for line in text.splitlines():
        if " = " in line:
            key, value = line.split(" = ", 1)
            if key in ("pkgname", "pkgver", "arch"):
                if key in fields: raise ValueError("ARCHIVE_METADATA_DUPLICATE")
                fields[key] = value
    prefix = "mingw-w64-i686-" if package["architecture"] == "x86" else "mingw-w64-ucrt-x86_64-"
    if (fields.get("pkgname") != package["name"] or fields.get("pkgver") != package["version"]
            or fields.get("arch") != "any" or not package["name"].startswith(prefix)):
        raise ValueError("ARCHIVE_METADATA_MISMATCH")
    return fields


def authenticate_package(package, path, run=subprocess.run):
    rows = []
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != package["sha256"]:
        raise ValueError("ARCHIVED_PACKAGE_SHA256_MISMATCH")
    code, _ = command(["bash", "/usr/bin/pacman-key", "--verify", str(path)+".sig", str(path)], run, rows)
    if code: raise ValueError("ARCHIVE_SIGNATURE_INVALID: " + repr(rows))
    code, text = command(["bsdtar", "-xOf", str(path), ".PKGINFO"], run, rows)
    if code: raise ValueError("ARCHIVE_METADATA_READ_FAILED: " + repr(rows))
    metadata = validate_metadata(package, text)
    return {"signature": "PASS_TRUSTED_PACMAN_KEYRING", "metadata": metadata, "commands": rows}


def restore_package(package, path, run=subprocess.run):
    rows = []
    row = {"name": package["name"], "version": package["version"], "commands": rows,
           "status": "FAIL", "pacmanExitCode": None, "error": None}
    code, observed = command(["pacman", "-Q", package["name"]], run, rows)
    row["before"] = observed.strip()
    target = package["name"] + " " + package["version"]
    if code != 0 or observed.strip() != target:
        # Explicitly install the authenticated target; --needed may skip a downgrade.
        code, _ = command(["pacman", "-U", "--noconfirm", str(path)], run, rows)
        row["pacmanExitCode"] = code
        if code:
            row["error"] = "PACMAN_INSTALL_FAILED"
            return row
    else:
        row["action"] = "ALREADY_EXACT"
    code, observed = command(["pacman", "-Q", package["name"]], run, rows)
    row["after"] = observed.strip()
    row["queryExitCode"] = code
    if code != 0 or observed.strip() != target:
        row["error"] = "INSTALLED_PACKAGE_IDENTITY_MISMATCH"
        return row
    row["status"] = "PASS"
    return row
