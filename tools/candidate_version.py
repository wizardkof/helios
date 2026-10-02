#!/usr/bin/env python3
"""Fail-closed Helios candidate version reservation and source lock."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


VERSION_KEY = "HELIOS_KMD_VERSION="
RESERVATION_REF_PREFIX = "refs/helios/candidate-reservations/"
SOURCE_ROOTS = (
    "kmd_render", "umd", "umd12", "umd_common", "kmd_logic", "protocol",
    "metadata", "installer", "packaging/windows", "ci/windows",
    "tools/win-mcp",
    "dxvk-helios", "vkd3d-proton-helios", "icd/mesa",
)
ROOT_FILES = (
    ".github/workflows/windows-stack.yml",
    ".gitmodules",
    "tools/candidate_version.py",
    "tools/sync-metadata.py",
)
EXCLUDED_SOURCE_FILES = {
    "kmd_render/driver-version.env",
    "metadata/candidate-reservation.json",
    "metadata/candidate-history.json",
}
REMOTE_VERIFY_REF_PREFIX = "refs/candidate-version/remote/"


def parse_version(value: str) -> tuple[int, int, int, int]:
    parts = value.split(".")
    if len(parts) != 4 or any(not p.isascii() or not p.isdecimal() for p in parts):
        raise ValueError(f"invalid Helios version {value!r}; expected 22.22.N.0")
    numbers = tuple(int(p) for p in parts)
    if numbers[0] != 22 or numbers[1] != 22 or numbers[3] != 0:
        raise ValueError(f"version {value!r} is outside the Helios 22.22.N.0 line")
    if numbers[2] > 65535:
        raise ValueError("version component N exceeds the Windows 16-bit version field")
    return numbers


def dotted(number: tuple[int, int, int, int]) -> str:
    return ".".join(map(str, number))


def validate_version_set(values: dict) -> None:
    expected = values.get("kmd")
    if not expected:
        raise ValueError("KMD version is missing")
    parse_version(expected)
    if values.get("inf") != expected or values.get("package") != expected:
        raise ValueError("KMD, INF and package versions diverge")
    umds = values.get("umds")
    if not isinstance(umds, list) or len(umds) != 4 or any(v != expected for v in umds):
        raise ValueError("all four Helios UMD versions must match the KMD version")


def validate_source_lock(expected: dict, actual: dict) -> None:
    mismatches = [name for name, value in expected.items() if actual.get(name) != value]
    if mismatches:
        raise ValueError("source lock mismatch: " + ", ".join(mismatches))


def record_immutable_identity(path: Path, identity: dict, sha256: str) -> None:
    if len(sha256) != 64 or any(c not in "0123456789abcdefABCDEF" for c in sha256):
        raise ValueError("artifact SHA256 must be 64 hexadecimal characters")
    expected = {"identity": identity, "sha256": sha256.lower()}
    if path.exists():
        actual = json.loads(path.read_text(encoding="utf-8"))
        if actual != expected:
            raise ValueError("closed artifact identity already exists with different bytes or metadata")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(expected, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    try:
        os.link(temporary, path)
    except FileExistsError:
        actual = json.loads(path.read_text(encoding="utf-8"))
        if actual != expected:
            raise ValueError("concurrent artifact identity collision")
    finally:
        temporary.unlink(missing_ok=True)


def seal_artifact(identity_path: Path, artifact_path: Path, record_path: Path) -> dict:
    identity = json.loads(identity_path.read_text(encoding="utf-8"))
    digest = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
    record_immutable_identity(record_path, identity, digest)
    return {"identity": identity, "sha256": digest}


def _git(root: Path, *args: str, input_bytes: bytes | None = None) -> bytes:
    result = subprocess.run(["git", "-C", str(root), *args], input=input_bytes,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(result.stderr.decode("utf-8", "replace").strip() or "git command failed")
    return result.stdout


def _git_files(root: Path, prefix: str | None = None) -> set[str]:
    args = ["ls-files", "-z"]
    if prefix:
        args += ["--", prefix]
    return {p.decode() for p in _git(root, *args).split(b"\0") if p}


def _worktree_blob(root: Path, git_path: str, source: Path) -> str:
    """Hash a worktree file using the same clean filters as its Git path."""
    return _git(root, "hash-object", f"--path={git_path}", "--", str(source)).decode().strip()


def _hash_file_tree(root: Path, prefix: str) -> list[tuple[str, str]]:
    base = root / prefix
    if not base.exists():
        raise ValueError(f"required source path is missing: {prefix}")
    if not base.is_dir():
        return [(prefix, hashlib.sha256(base.read_bytes()).hexdigest())]
    parent_entry = _git(root, "ls-files", "-s", "-z", "--", prefix)
    has_gitlink = any(row.startswith(b"160000 ") for row in parent_entry.split(b"\0") if row)
    if has_gitlink and not (base / ".git").exists():
        raise ValueError(f"required Git submodule is not initialized: {prefix}")
    nested_repo = (base / ".git").exists() or has_gitlink
    repo = base if nested_repo else root
    scope = None if nested_repo else prefix
    index_args = ["ls-files", "-s", "-z"] + (["--", scope] if scope else [])
    entries = {}
    for row in _git(repo, *index_args).split(b"\0"):
        if not row:
            continue
        metadata, raw_path = row.split(b"\t", 1)
        mode, oid, stage = metadata.decode().split()
        if stage != "0":
            raise ValueError(f"unmerged source path in candidate inputs: {raw_path.decode()}")
        rel = raw_path.decode()
        if not nested_repo:
            rel = rel.removeprefix(prefix + "/")
        entries[rel] = (mode, oid)
    status_args = ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
    if scope:
        status_args += ["--", scope]
    changed = set()
    untracked = set()
    for row in _git(repo, *status_args).split(b"\0"):
        if not row:
            continue
        state, raw_path = row[:2].decode(), row[3:]
        rel = raw_path.decode()
        if not nested_repo:
            rel = rel.removeprefix(prefix + "/")
        changed.add(rel)
        if state == "??":
            untracked.add(rel)
    output = []
    for rel, (mode, oid) in sorted(entries.items()):
        if not nested_repo and f"{prefix}/{rel}" in EXCLUDED_SOURCE_FILES:
            continue
        if mode == "160000":
            output.append((f"{prefix}/{rel}", f"gitlink:{oid}"))
            continue
        source = base / rel if nested_repo else root / prefix / rel
        if not source.is_file() and not source.is_symlink():
            continue
        if rel in changed:
            if source.is_symlink():
                digest = hashlib.sha256(os.readlink(source).encode()).hexdigest()
            else:
                git_path = rel if nested_repo else f"{prefix}/{rel}"
                digest = _worktree_blob(repo, git_path, source)
            if rel not in entries:
                mode = "100755" if stat.S_IMODE(source.stat().st_mode) & 0o111 else "100644"
        else:
            digest = oid
        output.append((f"{prefix}/{rel}", f"{mode}:{digest}"))
    for rel in sorted(untracked - entries.keys()):
        full_rel = f"{prefix}/{rel}"
        if full_rel in EXCLUDED_SOURCE_FILES:
            continue
        source = base / rel if nested_repo else root / prefix / rel
        if source.is_file():
            git_path = rel if nested_repo else full_rel
            digest = _worktree_blob(repo, git_path, source)
            mode = "100755" if stat.S_IMODE(source.stat().st_mode) & 0o111 else "100644"
            output.append((f"{prefix}/{rel}", f"{mode}:{digest}"))
    return output


def source_fingerprint(root: Path) -> str:
    root = root.resolve()
    files = []
    for prefix in SOURCE_ROOTS:
        files.extend(_hash_file_tree(root, prefix))
    for rel in ROOT_FILES:
        path = root / rel
        if path.is_file():
            files.append((rel, _worktree_blob(root, rel, path)))
    digest = hashlib.sha256()
    for name, content_hash in sorted(set(files)):
        digest.update(name.encode())
        digest.update(b"\0")
        digest.update(content_hash.encode())
        digest.update(b"\n")
    return digest.hexdigest()


def _source_commits(root: Path) -> dict[str, str]:
    commits = {"helios": _git(root, "rev-parse", "HEAD").decode().strip()}
    for name, path in (("mesa", "icd/mesa"), ("dxvk", "dxvk-helios"),
                       ("vkd3d", "vkd3d-proton-helios")):
        submodule = root / path
        if not (submodule / ".git").exists():
            raise ValueError(f"required Git submodule is not initialized: {path}")
        top_level = Path(_git(submodule, "rev-parse", "--show-toplevel").decode().strip()).resolve()
        if top_level != submodule.resolve():
            raise ValueError(f"component source path resolves outside its Git submodule: {path}")
        commit = _git(submodule, "rev-parse", "HEAD").decode().strip()
        entries = [row for row in _git(root, "ls-files", "-s", "-z", "--", path).split(b"\0") if row]
        gitlinks = [row for row in entries if row.startswith(b"160000 ")]
        if gitlinks:
            if len(gitlinks) != 1 or gitlinks[0].split(b"\t", 1)[0].decode().split()[1] != commit:
                raise ValueError(f"checked out {name} commit differs from the Helios gitlink: {path}")
        commits[name] = commit
    return commits


def _common_git_dir(root: Path) -> Path:
    raw = _git(root, "rev-parse", "--git-common-dir").decode().strip()
    path = Path(raw)
    return path.resolve() if path.is_absolute() else (root / path).resolve()


def _history_versions(root: Path) -> list[tuple[int, int, int, int]]:
    history = root / "metadata/candidate-history.json"
    if not history.exists():
        return []
    data = json.loads(history.read_text(encoding="utf-8"))
    if data.get("schemaVersion") != 1 or not isinstance(data.get("observed", []), list):
        raise ValueError("invalid metadata/candidate-history.json")
    return [parse_version(row["version"]) for row in data["observed"]]


def _append_reservation_history(root: Path, record: dict) -> None:
    path = root / "metadata/candidate-history.json"
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {
        "schemaVersion": 1, "observed": []
    }
    if data.get("schemaVersion") != 1 or not isinstance(data.get("observed"), list):
        raise ValueError("invalid metadata/candidate-history.json")
    refs = _git(root, "for-each-ref", "--format=%(refname) %(objectname)",
                RESERVATION_REF_PREFIX).decode().splitlines()
    reservations = []
    for line in refs:
        ref, object_id = line.split(" ", 1)
        reservations.append(json.loads(_git(root, "cat-file", "blob", object_id)))
    reservations.append(record)
    seen = set()
    for reservation in reservations:
        version = reservation["version"]
        if version in seen:
            continue
        seen.add(version)
        history_row = {
            "version": version,
            "status": "reserved",
            "sourceFingerprint": reservation["sourceFingerprint"],
            "sourceCommits": reservation["sourceCommits"],
            "reservationDigest": reservation["reservationDigest"],
            "reservationRef": RESERVATION_REF_PREFIX + version,
        }
        matches = [row for row in data["observed"] if row.get("version") == version]
        existing_reservations = [row for row in matches if row.get("status") == "reserved"]
        if existing_reservations and any(row != history_row for row in existing_reservations):
            raise ValueError(f"history already assigns {version} to another source candidate")
        if not existing_reservations:
            data["observed"].append(history_row)
    temporary = path.with_name(path.name + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(data, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def _remote_ref(root: Path, remote: str, version: str) -> str | None:
    ref = RESERVATION_REF_PREFIX + version
    result = subprocess.run(["git", "-C", str(root), "ls-remote", "--refs", remote, ref],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(f"cannot query candidate reservations from remote {remote}: " +
                         result.stderr.decode("utf-8", "replace").strip())
    rows = result.stdout.decode().splitlines()
    if not rows:
        return None
    if len(rows) != 1 or rows[0].split("\t", 1)[1] != ref:
        raise ValueError(f"remote {remote} returned an invalid reservation ref for {version}")
    return rows[0].split("\t", 1)[0]


def _fetch_remote_record(root: Path, remote: str, version: str, object_id: str) -> dict:
    ref = RESERVATION_REF_PREFIX + version
    temporary_ref = REMOTE_VERIFY_REF_PREFIX + version
    fetched = subprocess.run(["git", "-C", str(root), "fetch", "--no-tags", remote,
                              f"+{ref}:{temporary_ref}"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if fetched.returncode:
        raise ValueError(f"cannot fetch remote candidate reservation {ref}: " +
                         fetched.stderr.decode("utf-8", "replace").strip())
    try:
        fetched_oid = _git(root, "rev-parse", "--verify", temporary_ref).decode().strip()
        if fetched_oid != object_id:
            raise ValueError(f"remote candidate reservation {ref} changed during verification")
        return json.loads(_git(root, "cat-file", "blob", fetched_oid))
    finally:
        subprocess.run(["git", "-C", str(root), "update-ref", "-d", temporary_ref],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def _remote_versions(root: Path, remote: str | None) -> list[tuple[int, int, int, int]]:
    if remote is None:
        return []
    result = subprocess.run(["git", "-C", str(root), "ls-remote", "--refs", remote,
                             RESERVATION_REF_PREFIX + "*"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(f"cannot list candidate reservations from remote {remote}: " +
                         result.stderr.decode("utf-8", "replace").strip())
    versions = []
    for line in result.stdout.decode().splitlines():
        _object_id, ref = line.split("\t", 1)
        versions.append(parse_version(ref.removeprefix(RESERVATION_REF_PREFIX)))
    return versions


def _default_remote(root: Path) -> str | None:
    remotes = _git(root, "remote", "-v").decode().splitlines()
    candidates = []
    for row in remotes:
        fields = row.split()
        if len(fields) >= 3 and fields[2] == "(fetch)" and fields[1].rstrip("/").removesuffix(".git").endswith("github.com/wizardkof/helios"):
            candidates.append(fields[0])
    unique = sorted(set(candidates))
    if len(unique) > 1:
        raise ValueError("multiple wizardkof/helios remotes are configured; pass --remote explicitly")
    return unique[0] if unique else None


def _reserved_versions(root: Path, remote: str | None = None) -> list[tuple[int, int, int, int]]:
    refs = _git(root, "for-each-ref", "--format=%(refname)", RESERVATION_REF_PREFIX).decode().splitlines()
    versions = []
    for ref in refs:
        raw = ref.removeprefix(RESERVATION_REF_PREFIX)
        versions.append(parse_version(raw))
    return versions + _remote_versions(root, remote)


def next_version(root: Path, remote: str | None = None) -> str:
    occupied = _history_versions(root) + _reserved_versions(root, remote)
    current = read_version(root)
    occupied.append(parse_version(current))
    n = max(v[2] for v in occupied) + 1
    if n > 65535:
        raise ValueError("Helios candidate version range exhausted")
    return f"22.22.{n}.0"


def read_version(root: Path) -> str:
    path = root / "kmd_render/driver-version.env"
    lines = [line.strip()[len(VERSION_KEY):].strip() for line in path.read_text(encoding="utf-8").splitlines()
             if line.strip().startswith(VERSION_KEY)]
    if len(lines) != 1:
        raise ValueError(f"expected exactly one {VERSION_KEY} entry")
    parse_version(lines[0])
    return lines[0]


def _write_version(root: Path, version: str) -> None:
    path = root / "kmd_render/driver-version.env"
    lines = path.read_text(encoding="utf-8").splitlines()
    output = []
    changed = 0
    for line in lines:
        if line.strip().startswith(VERSION_KEY):
            output.append(VERSION_KEY + version)
            changed += 1
        else:
            output.append(line)
    if changed != 1:
        raise ValueError("driver-version.env must contain exactly one version assignment")
    path.write_text("\n".join(output) + "\n", encoding="utf-8")


def reserve(root: Path, version: str, fingerprint: str | None = None,
            remote: str | None = None) -> dict:
    root = root.resolve()
    parsed = parse_version(version)
    fingerprint = fingerprint or source_fingerprint(root)
    commits = _source_commits(root)
    ref = RESERVATION_REF_PREFIX + version
    existing_blob = subprocess.run(["git", "-C", str(root), "rev-parse", "--verify", ref],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    remote_oid = _remote_ref(root, remote, version) if remote else None
    remote_record = None
    if remote_oid:
        if not existing_blob.returncode and existing_blob.stdout.decode().strip() != remote_oid:
            local_record = json.loads(_git(root, "cat-file", "blob", existing_blob.stdout.decode().strip()))
            remote_record = _fetch_remote_record(root, remote, version, remote_oid)
            if local_record.get("reservationDigest") != remote_record.get("reservationDigest"):
                raise ValueError(f"{version} is reserved remotely for a different source candidate")
        else:
            remote_record = _fetch_remote_record(root, remote, version, remote_oid)
        if (remote_record.get("version") != version or
                remote_record.get("sourceFingerprint") != fingerprint or
                remote_record.get("sourceCommits") != commits):
            raise ValueError(f"{version} is reserved remotely for a different source candidate")
    if existing_blob.returncode and remote_record is None:
        next_free = next_version(root, remote)
        if version != next_free:
            raise ValueError(f"next Helios candidate is {next_free}; refusing to reserve {version}")
    current = read_version(root)
    if parse_version(current) > parsed:
        raise ValueError(f"refusing to move candidate source backward from {current} to {version}")
    if current != version:
        _write_version(root, version)
    if remote_record is not None:
        record = remote_record
    else:
        digest_input = {"version": version, "sourceFingerprint": fingerprint, "sourceCommits": commits}
        reservation_digest = hashlib.sha256(json.dumps(digest_input, sort_keys=True).encode()).hexdigest()
        record = {"schemaVersion": 1, **digest_input, "reservationDigest": reservation_digest,
                  "reservedAtUtc": dt.datetime.now(dt.timezone.utc).isoformat()}
    blob = _git(root, "hash-object", "-w", "--stdin", input_bytes=(json.dumps(record, sort_keys=True) + "\n").encode()).decode().strip()
    zero = "0" * 40
    update = subprocess.run(["git", "-C", str(root), "update-ref", ref, blob, zero],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if update.returncode:
        old_blob = _git(root, "rev-parse", ref).decode().strip()
        old = json.loads(_git(root, "cat-file", "blob", old_blob))
        if old.get("version") != version or old.get("sourceFingerprint") != fingerprint or old.get("sourceCommits") != commits:
            raise ValueError(f"{version} is already permanently reserved for another candidate")
        record = old
    lock = {**record, "reservationRef": ref}
    lock_path = root / "metadata/candidate-reservation.json"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path.write_text(json.dumps(lock, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    _append_reservation_history(root, record)
    if remote and remote_oid is None:
        pushed = subprocess.run(["git", "-C", str(root), "push", "--porcelain", remote,
                                f"{ref}:{ref}"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if pushed.returncode:
            observed_oid = _remote_ref(root, remote, version)
            if observed_oid is None:
                raise ValueError(f"remote candidate reservation push failed for {version}: " +
                                 pushed.stderr.decode("utf-8", "replace").strip())
            observed = json.loads(_git(root, "cat-file", "blob", observed_oid))
            if observed.get("reservationDigest") != record.get("reservationDigest"):
                raise ValueError(f"{version} was concurrently reserved remotely for another source")
    return lock


def verify(root: Path, portable: bool = False, remote: str | None = None,
           require_remote: bool = False) -> dict:
    root = root.resolve()
    version = read_version(root)
    lock_path = root / "metadata/candidate-reservation.json"
    if not lock_path.is_file():
        raise ValueError("candidate source lock is absent; reserve a version before building")
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    if lock.get("version") != version:
        raise ValueError("candidate reservation version differs from driver-version.env")
    fingerprint = source_fingerprint(root)
    if lock.get("sourceFingerprint") != fingerprint:
        raise ValueError("candidate source changed after reservation; reserve a new version "
                         f"(reserved={lock.get('sourceFingerprint')}, actual={fingerprint})")
    current_commits = _source_commits(root)
    for component in ("mesa", "dxvk", "vkd3d"):
        if current_commits.get(component) != lock.get("sourceCommits", {}).get(component):
            raise ValueError(f"candidate source lock {component} commit changed after reservation")
    ref = RESERVATION_REF_PREFIX + version
    expected_digest = hashlib.sha256(json.dumps({
        "version": version,
        "sourceFingerprint": fingerprint,
        "sourceCommits": lock.get("sourceCommits"),
    }, sort_keys=True).encode()).hexdigest()
    if lock.get("reservationDigest") != expected_digest:
        raise ValueError("candidate reservation digest does not match its version and source lock")
    found = subprocess.run(["git", "-C", str(root), "rev-parse", "--verify", ref],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if found.returncode and not portable:
        raise ValueError("local Git reservation ref is absent; only a portable source-locked build may proceed")
    remote_oid = _remote_ref(root, remote, version) if remote else None
    if require_remote and remote_oid is None:
        raise ValueError(f"remote candidate reservation {ref} is absent")
    if remote_oid:
        remote_record = _fetch_remote_record(root, remote, version, remote_oid)
        if remote_record.get("reservationDigest") != expected_digest:
            raise ValueError("remote Git reservation does not match the candidate source lock")
    if not found.returncode:
        blob = found.stdout.decode().strip()
        reserved = json.loads(_git(root, "cat-file", "blob", blob))
        if reserved.get("reservationDigest") != expected_digest:
            raise ValueError("Git reservation does not match the candidate source lock")
    return lock


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("next", "reserve", "verify", "seal"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--version")
    parser.add_argument("--identity-file", type=Path)
    parser.add_argument("--artifact-file", type=Path)
    parser.add_argument("--record-file", type=Path)
    parser.add_argument("--remote", help="Git remote used for atomic reservation coordination")
    parser.add_argument("--require-remote", action="store_true", help="require the reservation ref on --remote")
    parser.add_argument("--portable", action="store_true", help="verify a committed source lock in a fresh CI clone without local reservation refs")
    args = parser.parse_args(argv)
    try:
        reservation_remote = args.remote or _default_remote(args.root)
        if args.action == "next":
            print(next_version(args.root, reservation_remote))
        elif args.action == "reserve":
            lock_path = args.root / "metadata/candidate-reservation.json"
            if args.version is None and lock_path.is_file():
                existing = json.loads(lock_path.read_text(encoding="utf-8"))
                if existing.get("version") == read_version(args.root):
                    try:
                        print(json.dumps(verify(args.root), sort_keys=True))
                        return 0
                    except ValueError:
                        pass
            version = args.version or next_version(args.root, reservation_remote)
            print(json.dumps(reserve(args.root, version, remote=reservation_remote), sort_keys=True))
        elif args.action == "seal":
            if not args.identity_file or not args.artifact_file or not args.record_file:
                raise ValueError("seal requires --identity-file, --artifact-file and --record-file")
            print(json.dumps(seal_artifact(args.identity_file, args.artifact_file, args.record_file), sort_keys=True))
        else:
            print(json.dumps(verify(args.root, portable=args.portable, remote=args.remote,
                                    require_remote=args.require_remote), sort_keys=True))
        return 0
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        print(f"candidate-version: ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
