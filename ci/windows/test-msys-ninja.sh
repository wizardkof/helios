#!/usr/bin/env bash
set -uo pipefail
export MSYS2_ARG_CONV_EXCL='*'
repo_root="$(cygpath -m "${1:?repo root required}")"
receipt="$(cygpath -m "${2:?receipt path required}")"
arch=x64
[[ "${MSYSTEM:-}" == MINGW32 ]] && arch=x86
root="$(cygpath -u "${RUNNER_TEMP:?}")/helios-msys-ninja-control"
root_windows="$(cygpath -m "$root")"
mkdir -p "${root}/source" "${root}/poison"
cat > "${root}/source/meson.build" <<'EOF'
project('helios-msys-ninja-control', 'c')
executable('hello', 'hello.c')
EOF
printf 'int main(void) { return 0; }\n' > "${root}/source/hello.c"
# A native executable makes PATH poisoning observable to Windows Meson.
cat > "${root}/poison/ninja.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(void) {
  const char *path = getenv("HELIOS_NINJA_POISON_MARKER");
  if (!path) return 98;
  FILE *marker = fopen(path, "a");
  if (!marker) return 99;
  fputs("poison\n", marker);
  fclose(marker);
  return 97;
}
EOF
gcc "${root_windows}/poison/ninja.c" -o "${root_windows}/poison/ninja.exe" || exit 1
export HELIOS_NINJA_POISON_MARKER="${root_windows}/poison/used.txt"
python - "${root_windows}/poison/ninja.exe" <<'PY'
import os, pathlib, subprocess, sys
result = subprocess.run([sys.argv[1], "--version"])
marker = pathlib.Path(os.environ["HELIOS_NINJA_POISON_MARKER"])
if result.returncode != 97 or not marker.is_file():
    raise SystemExit("Native poison negative control failed")
marker.unlink()
print("POISON_NEGATIVE_CONTROL=PASS exit=97 marker=OBSERVED_THEN_REMOVED")
PY
poison_negative_rc=$?
[[ "$poison_negative_rc" -eq 0 ]] || exit 1
python "${repo_root}/ci/windows/assert_msys_pins.py" "${arch}" "${receipt}.packages.json"
package_rc=$?
source "${repo_root}/ci/windows/select-msys-ninja.sh"
helios_select_msys_ninja || exit 1
python "${repo_root}/ci/windows/assert_msys_ninja.py" "${arch}" "${NINJA}" "${receipt}.identity.json"
ninja_rc=$?
export PATH="${root}/poison:${PATH}"
meson_outputs=()
run_meson() {
  local label="$1"; shift
  local output rc
  output="$("$@" 2>&1)"; rc=$?
  MESON_RC=$rc
  meson_outputs+=("$label exit=$rc" "$output")
  return 0
}
run_meson setup meson setup --backend=ninja "${root_windows}/build" "${root_windows}/source"
setup_rc=$MESON_RC
if [[ -f "${root}/build/build.ninja" ]]; then
  run_meson compile meson compile -C "${root_windows}/build"; compile_rc=$MESON_RC
  run_meson reconfigure meson setup --reconfigure "${root_windows}/build" "${root_windows}/source"; reconfigure_rc=$MESON_RC
  run_meson recompile meson compile -C "${root_windows}/build"; recompile_rc=$MESON_RC
else
  compile_rc=NOT_RUN; reconfigure_rc=NOT_RUN; recompile_rc=NOT_RUN
fi
poison=false
[[ -e "${root}/poison/used.txt" ]] && poison=true
python - "${receipt}" "${NINJA}" "${MSYSTEM}" "${setup_rc}" "${compile_rc}" "${reconfigure_rc}" "${recompile_rc}" "${poison}" "${package_rc}" "${ninja_rc}" "${meson_outputs[@]}" <<'PY'
import json, pathlib, re, shlex, sys
path, ninja, system, setup, compile_, reconfigure, recompile, poison, package_rc, ninja_rc, *output = sys.argv[1:]
try:
    numeric = [int(value) for value in (setup, compile_, reconfigure, recompile)]
except ValueError:
    numeric = [1]
detected = [match.group(1).strip().strip('"\'') for line in output for match in re.finditer(r"(?m)^Found ninja(?:\.exe)?-1\.13\.2 at (.+)$", line)]
selected = pathlib.Path(ninja).resolve()
meson_matches = bool(detected) and all(pathlib.Path(path).resolve() == selected for path in detected)
backend_commands = [match.group(1).strip() for line in output for match in re.finditer(r"(?m)^INFO: calculating backend command to run: (.+)$", line)]
backend_executables = [shlex.split(command, posix=False)[0].strip('"\'') for command in backend_commands]
backend_matches = len(backend_executables) == 2 and all(pathlib.Path(executable).resolve() == selected for executable in backend_executables)
identity = json.loads(pathlib.Path(path + ".identity.json").read_text())
identity_matches = pathlib.Path(identity["path"]).resolve() == selected and selected.is_absolute() and selected.is_file()
passed = meson_matches and backend_matches and identity_matches and int(package_rc) == 0 and int(ninja_rc) == 0 and len(numeric) == 4 and all(value == 0 for value in numeric) and poison == "false"
pathlib.Path(path).write_text(json.dumps({
  "schemaVersion": 1,
  "status": "PASS" if passed else "FAIL",
  "role": "mesa-msys2-native-ninja",
  "msystem": system,
  "path": ninja or None,
  "selectedByMesonEnvironment": "NINJA",
  "argumentConversionExclusion": "*",
  "mesonDetectedNinjaPaths": detected,
  "mesonDetectedNinjaMatchesIdentity": meson_matches,
  "mesonBackendCommands": backend_commands,
  "mesonBackendExecutables": backend_executables,
  "mesonBackendCommandsMatchIdentity": backend_matches,
  "selectedPathMatchesChecker": identity_matches,
  "packagePinCheckExitCode": int(package_rc),
  "ninjaIdentityCheckExitCode": int(ninja_rc),
  "setup": setup,
  "compile": compile_,
  "reconfigure": reconfigure,
  "recompile": recompile,
  "mesonOutput": output,
  "poisonPathUsed": poison == "true",
  "poisonNegativeControl": "PASS_EXIT_97_MARKER_OBSERVED_THEN_REMOVED",
}, indent=2) + "\n", encoding="utf-8")
if not passed:
    raise SystemExit("MSYS2 consumer identity or execution contract failed")
PY
status_rc=$?
if [[ "$package_rc" -ne 0 || "$ninja_rc" -ne 0 || "$status_rc" -ne 0 || "$setup_rc" -ne 0 || "$compile_rc" != 0 || "$reconfigure_rc" != 0 || "$recompile_rc" != 0 || "$poison" == true ]]; then
  echo "MSYS2 Ninja infrastructure control failed; package receipt=${receipt}.packages.json consumer receipt=${receipt}" >&2
  exit 1
fi
echo 'MSYS2_NINJA_CONSUMER_CONTROL=PASS'
