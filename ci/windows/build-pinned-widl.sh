#!/usr/bin/env bash
set -uo pipefail
repo_root="$(cygpath -m "${1:?repo root required}")"
output="$(cygpath -m "${2:?output dir required}")"
mkdir -p "$output"
source_dir="$output/source"
archive="$output/wine-11.12.tar.xz"
binary="$output/widl.exe"
receipt="$output/widl-build.json"
source_url='https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz'
source_sha='d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc'
status=FAIL
reason=NOT_STARTED
archive_sha=''
binary_sha=''
binary_size=''
version=''
configure_rc=NOT_RUN
build_rc=NOT_RUN
write_receipt() {
  python - "$receipt" "$status" "$reason" "$source_url" "$source_sha" "$archive_sha" "$binary" "$binary_sha" "$binary_size" "$version" "$configure_rc" "$build_rc" <<'PY'
import json, pathlib, sys
(p, status, reason, url, expected, observed, binary, binary_sha, binary_size, version, configure_rc, build_rc) = sys.argv[1:]
pathlib.Path(p).write_text(json.dumps({
  "schemaVersion": 1, "status": status, "reason": reason,
  "source": {"authority": "WineHQ source release", "url": url, "expectedSha256": expected, "observedSha256": observed or None},
  "executable": {"path": binary, "expectedVersion": "11.12", "observedVersion": version or None, "size": int(binary_size) if binary_size else None, "sha256": binary_sha or None},
  "configureExitCode": configure_rc, "buildExitCode": build_rc
}, indent=2) + "\n", encoding="utf-8")
PY
}
fail() { reason="$1"; write_receipt; echo "PINNED_WIDL=FAIL reason=$reason receipt=$receipt" >&2; exit 1; }
python - "$archive" "$source_url" "$source_sha" <<'PY' || fail SOURCE_DOWNLOAD_OR_HASH_FAILED
import hashlib, pathlib, sys, urllib.request
path, url, expected = sys.argv[1:]
target = pathlib.Path(path)
with urllib.request.urlopen(url, timeout=120) as response, target.open('wb') as output:
    while block := response.read(1024 * 1024): output.write(block)
observed = hashlib.sha256(target.read_bytes()).hexdigest()
print(f'SOURCE_SHA256={observed}')
if observed != expected: raise SystemExit('SOURCE_SHA256_MISMATCH')
PY
archive_sha="$source_sha"
python - "$archive" "$source_dir" <<'PY' || fail SOURCE_EXTRACTION_FAILED
import lzma, pathlib, sys, tarfile
archive, destination = map(pathlib.Path, sys.argv[1:])
destination.mkdir(parents=True, exist_ok=True)
with lzma.open(archive, 'rb') as compressed, tarfile.open(fileobj=compressed, mode='r|') as source:
    first = True
    for member in source:
        parts = pathlib.PurePosixPath(member.name).parts
        relative = pathlib.Path(*parts[1:])
        first = False
        if not relative.parts: continue
        target = (destination / relative).resolve()
        if destination.resolve() not in target.parents and target != destination.resolve(): raise SystemExit('ARCHIVE_PATH_TRAVERSAL')
        if member.isdir(): target.mkdir(parents=True, exist_ok=True)
        elif member.isfile():
            target.parent.mkdir(parents=True, exist_ok=True)
            data = source.extractfile(member)
            if data is None: raise SystemExit('ARCHIVE_MEMBER_READ_FAILED')
            with data, target.open('wb') as output:
                while block := data.read(1024 * 1024): output.write(block)
            target.chmod(member.mode & 0o777)
        elif member.issym() or member.islnk(): raise SystemExit('ARCHIVE_LINK_REFUSED')
PY
cd "$source_dir"
./configure --enable-win64 --without-x --disable-tests > "$output/configure.log" 2>&1
configure_rc=$?
[[ "$configure_rc" -eq 0 ]] || fail CONFIGURE_FAILED
make -C tools/widl -j2 > "$output/build.log" 2>&1
build_rc=$?
[[ "$build_rc" -eq 0 ]] || fail WIDL_BUILD_FAILED
built="$source_dir/tools/widl/widl.exe"
[[ -f "$built" ]] || fail WIDL_OUTPUT_MISSING
cp "$built" "$binary" || fail WIDL_COPY_FAILED
binary_sha="$(sha256sum "$binary" | awk '{print $1}')"
binary_size="$(wc -c < "$binary" | tr -d ' ')"
version="$("$binary" -V 2>&1)"
[[ "$version" == *'version 11.12'* ]] || fail WIDL_VERSION_MISMATCH
status=PASS
reason=SOURCE_HASH_AND_EXECUTABLE_VERSION_VERIFIED
write_receipt
printf 'HELIOS_WIDL=%s\n' "$binary" >> "$GITHUB_ENV"
printf '%s\n' "$(dirname "$binary")" >> "$GITHUB_PATH"
echo "PINNED_WIDL=PASS path=$binary version=$version sha256=$binary_sha"
