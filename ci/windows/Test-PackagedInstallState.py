#!/usr/bin/env python3
"""Execute the state regression on scripts extracted from the final setup bytes.

Decodes archive.rs's HLIOSET2 container without executing HeliosSetup.exe.
The only executed payload is the synthetic, non-installing state regression.
"""
import argparse
import hashlib
import json
import lzma
import os
from pathlib import Path
import struct
import subprocess
import tempfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def native_powershell_environment():
    # PS7's module path prevents native PS5.1 from autoloading Get-FileHash.
    # Omit it only in the child; PS5.1 reconstructs its own default module paths.
    return {key: value for key, value in os.environ.items()
            if key.upper() != "PSMODULEPATH"}


def format_native_output(data):
    # Preserve undecodable bytes as escapes; legacy cp1252 consoles must never
    # hide the original failing command behind UnicodeEncodeError.
    return data.decode("utf-8", errors="backslashreplace").encode(
        "ascii", errors="backslashreplace").decode("ascii")


def decode(data):
    require(len(data) >= 64 and data[-8:] == b"HLIOSET2", "Invalid setup footer")
    offset, size, header_size = struct.unpack_from("<QQQ", data, len(data) - 64)
    require(offset >= 64 and offset + size + 64 == len(data) and 4 <= header_size <= size,
            "Invalid container bounds")
    container = data[offset:offset + size]
    digest = hashlib.sha256(container).digest()
    require(digest == data[-40:-8], "Container digest mismatch")
    header = container[:header_size]
    count = struct.unpack_from("<I", header)[0]
    require(0 < count <= 4096, "Invalid entry count")
    entries = []
    names = set()
    cursor = 4
    for _ in range(count):
        require(cursor + 2 <= header_size, "Truncated entry")
        length = struct.unpack_from("<H", header, cursor)[0]
        cursor += 2
        require(length > 0 and cursor + length + 8 <= header_size, "Truncated name/size")
        name = header[cursor:cursor + length].decode("utf-8")
        cursor += length
        file_size = struct.unpack_from("<Q", header, cursor)[0]
        cursor += 8
        require(all(p and p not in (".", "..") and "\\" not in p and ":" not in p
                    for p in name.split("/")), "Unsafe container name")
        require(name.casefold() not in names, "Duplicate container name")
        names.add(name.casefold())
        entries.append((name, file_size))
    require(cursor == header_size, "Trailing header bytes")
    total = sum(size for _, size in entries)
    require(total <= 1024 * 1024 * 1024, "Container exceeds qualification size limit")
    decompressor = lzma.LZMADecompressor()
    raw = decompressor.decompress(container[header_size:], max_length=total + 1)
    require(decompressor.eof and not decompressor.unused_data and len(raw) == total,
            "Invalid XZ framing or payload size")
    files = {}
    cursor = 0
    for name, size in entries:
        files[name] = raw[cursor:cursor + size]
        cursor += size
    manifest = json.loads(files["manifest.json"].decode("utf-8-sig"))
    for row in manifest["files"]:
        contents = files[row["path"]]
        require(len(contents) == row["size"] and
                hashlib.sha256(contents).hexdigest() == row["sha256"].lower(),
                "Manifest hash/size mismatch: " + row["path"])
    return files, digest.hex()


def qualify(setup, receipt):
    require(os.name == "nt", "Packaged schema execution requires Windows PowerShell 5.1")
    setup_data = Path(setup).read_bytes()
    files, digest = decode(setup_data)
    names = ("Install-Helios.ps1", "Verify-Helios.ps1", "Helios-PackageCommon.ps1",
             "Test-HeliosInstallState.ps1")
    # These executable scripts must all be covered by the final manifest.
    manifest = json.loads(files["manifest.json"].decode("utf-8-sig"))
    covered = {r["path"] for r in manifest["files"]}
    require(set(names) <= covered, "Schema scripts missing manifest coverage")
    with tempfile.TemporaryDirectory(prefix="helios-packaged-state-") as temporary:
        directory = Path(temporary)
        for name in names:
            (directory / name).write_bytes(files[name])
        native = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        result = subprocess.run([str(native), "-NoProfile", "-ExecutionPolicy", "Bypass",
                                 "-File", str(directory / names[-1]), "-PackageScripts", temporary,
                                 "-Receipt", str(directory / "state-schema.json")],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=native_powershell_environment())
        if result.returncode:
            failure = dict(status="FAIL", nativeExitCode=result.returncode,
                           stdout=format_native_output(result.stdout), stderr=format_native_output(result.stderr),
                           setupSha256=hashlib.sha256(setup_data).hexdigest(), embeddedPayloadDigest=digest,
                           packagedInstallerSchemaTest="FAIL", setupExecuted=False)
            child_receipt = directory / "state-schema.json"
            if child_receipt.exists():
                failure["nativeReceiptRaw"] = format_native_output(child_receipt.read_bytes())
            Path(receipt).write_text(json.dumps(failure, indent=2) + "\n", encoding="utf-8")
            print(format_native_output(result.stdout))
            print(format_native_output(result.stderr))
            raise RuntimeError("Packaged installer schema test failed, exit=" + str(result.returncode))
        record = json.loads((directory / "state-schema.json").read_text(encoding="utf-8-sig"))
        require(record["status"] == "PASS" and record["process64"] and
                record["powerShellVersion"].startswith("5.1."), "Native schema receipt failed")
        record.update(setupSha256=hashlib.sha256(setup_data).hexdigest(),
                      embeddedPayloadDigest=digest, packagedInstallerSchemaTest="PASS",
                      installStateSchemaStaticGate="PASS", setupExecuted=False)
        Path(receipt).write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        print("PACKAGED_INSTALLER_SCHEMA_TEST=PASS; INSTALL_STATE_SCHEMA_STATIC_GATE=PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--setup", required=True)
    parser.add_argument("--receipt", required=True)
    args = parser.parse_args()
    qualify(args.setup, args.receipt)
