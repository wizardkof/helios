#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
EXPECTED_ROOT="/home/reliuz/Projetos/Helios"
if [[ "$ROOT" != "$EXPECTED_ROOT" ]]; then
  printf 'REFUSED: unexpected source root: %s\n' "$ROOT" >&2
  exit 64
fi
cd "$ROOT"
CARGO_TARGET_DIR="$ROOT/.fullstack/build/linux/cargo"
export CARGO_TARGET_DIR
CARGO_BIN="${HELIOS_CARGO:-cargo}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ARTIFACTS_ROOT="$ROOT/.fullstack/artifacts"
OUT_ROOT="$(realpath -m -- "${HELIOS_ARTIFACTS_DIR:-$ARTIFACTS_ROOT/p02}")"
case "$OUT_ROOT/" in
  "$ARTIFACTS_ROOT"/*/) ;;
  *) printf 'REFUSED: artifacts must remain below %s\n' "$ARTIFACTS_ROOT" >&2; exit 64 ;;
esac
OUT="$OUT_ROOT/host-tests-$RUN_ID"
mkdir -p "$OUT"
HEAD="$(git rev-parse HEAD)"
BRANCH="$(git branch --show-current)"
PACKAGES=(
  "kmd_logic/Cargo.toml"
  "protocol/Cargo.toml"
  "tools/win-mcp/Cargo.toml"
)
FAILED_CODE=0
TOTAL_RUN_TESTS=0

for manifest in "${PACKAGES[@]}"; do
  name="$(basename "$(dirname "$manifest")")"
  log="$OUT/$name.log"
  printf 'RUN %s (CARGO_TARGET_DIR=%s)\n' "$manifest" "$CARGO_TARGET_DIR"
  if [[ "$manifest" == "tools/win-mcp/Cargo.toml" ]]; then
    HELIOS_LINUX_PROJECT_ROOT="$ROOT" "$CARGO_BIN" test --locked --manifest-path "$manifest" >"$log" 2>&1
    status=$?
  else
    "$CARGO_BIN" test --locked --manifest-path "$manifest" >"$log" 2>&1
    status=$?
  fi
  cat "$log"
  if (( status != 0 )); then
    FAILED_CODE="$status"
    break
  fi
  count="$(sed -nE 's/^running ([0-9]+) tests?$/\1/p' "$log" | awk '{s+=$1} END {print s+0}')"
  if (( count < 1 )); then
    printf 'NOT_PROVEN: %s reported no executed tests\n' "$manifest" >&2
    FAILED_CODE=65
    break
  fi
  TOTAL_RUN_TESTS=$((TOTAL_RUN_TESTS + count))
done

RESULT="PASS"
if (( FAILED_CODE != 0 )); then RESULT="FAIL"; fi
export ROOT OUT RUN_ID HEAD BRANCH CARGO_TARGET_DIR RESULT FAILED_CODE TOTAL_RUN_TESTS
python3 - <<'PY'
import json, os, pathlib, datetime
out = pathlib.Path(os.environ['OUT']) / 'receipt.json'
receipt = {
    'schema_version': 1,
    'task': 'P02',
    'suite': 'host-rust-cpu',
    'result': os.environ['RESULT'],
    'failed_exit_code': int(os.environ['FAILED_CODE']),
    'executed_unit_test_count': int(os.environ['TOTAL_RUN_TESTS']),
    'source_root': os.environ['ROOT'],
    'head': os.environ['HEAD'],
    'branch': os.environ['BRANCH'],
    'cargo_target_dir': os.environ['CARGO_TARGET_DIR'],
    'run_id': os.environ['RUN_ID'],
    'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'logs': sorted(p.name for p in pathlib.Path(os.environ['OUT']).glob('*.log')),
}
out.write_text(json.dumps(receipt, indent=2) + '\n')
PY
printf 'RECEIPT=%s/receipt.json\n' "$OUT"
if (( FAILED_CODE != 0 )); then exit "$FAILED_CODE"; fi
