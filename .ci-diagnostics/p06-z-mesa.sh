#!/usr/bin/env bash
set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'
if [[ "${GITHUB_ACTIONS:-}" != true || "${GITHUB_REPOSITORY:-}" != wizardkof/helios ]]; then
  echo 'P06_Z_FORBIDDEN_ACTIONS_CONTEXT' >&2; exit 2
fi
if [[ "${CONTROL_Z_ARCH:?}" != x64 && "${CONTROL_Z_ARCH}" != x86 ]]; then
  echo 'P06_Z_INVALID_MESA_ARCH' >&2; exit 2
fi
case "${CONTROL_Z_ARCH}" in
  x64) [[ "${MSYSTEM:-}" == UCRT64 ]] || exit 2 ;;
  x86) [[ "${MSYSTEM:-}" == MINGW32 ]] || exit 2 ;;
esac
repo="$(cygpath -m "$RUNNER_TEMP")/p06-z-gitlab-source"
receipts="$(cygpath -m "$RUNNER_TEMP")/p06-z-receipts"
mkdir -p "$receipts"
build="$(cygpath -m "$RUNNER_TEMP")/p06-z-mesa-build-${CONTROL_Z_ARCH}"
export HELIOS_MESON_LOCK_ROOT="$(cygpath -m "$RUNNER_TEMP")/p06-z-meson-lock-${CONTROL_Z_ARCH}"
export HELIOS_BUILD_JOBS=4
if [[ -e "$build" ]]; then echo P06_Z_BUILD_DIRECTORY_OCCUPIED >&2;exit 2;fi
python "$repo/ci/windows/meson-isolated.py" setup "$build" "$repo/icd/mesa" \
  --native-file "$repo/ci/windows/mingw-native.ini" \
  "-Dc_args=-include${repo}/icd/win-build/helios_win_compat.h" \
  -Dvulkan-drivers=virtio -Dgallium-drivers=zink \
  "-Dhelios-wdk-include=${repo}/icd/win-build/wdk-include" \
  -Dplatforms=windows -Dvideo-codecs= -Dvulkan-layers= \
  -Degl=disabled -Dgbm=disabled -Dglx=disabled \
  -Dopengl=true -Dgles1=disabled -Dgles2=disabled \
  -Dllvm=disabled -Dshader-cache=disabled -Dzlib=disabled \
  -Dzstd=disabled -Dbuild-tests=false -Dperfetto=false \
  -Dxmlconfig=disabled --buildtype=release 2>&1 | tee "$receipts/mesa-${CONTROL_Z_ARCH}-configure.log"

# Ninja determines generated headers and other prerequisites; compile only
# the actual production renderer translation unit, never link vulkan_virtio.dll.
ninja -C "$build" -t targets all > "$receipts/mesa-${CONTROL_Z_ARCH}-ninja-targets.txt"
python - "$receipts/mesa-${CONTROL_Z_ARCH}-ninja-targets.txt" "$receipts/mesa-${CONTROL_Z_ARCH}-targets.txt" <<'PY'
import pathlib,sys
entries=pathlib.Path(sys.argv[1]).read_text(errors='replace').splitlines()
names=[]
for line in entries:
    target=line.split(': ',1)[0]
    norm=target.replace('\\','/')
    if 'vn_renderer_helios.c.obj' in norm and '/src/virtio/vulkan/' in ('/'+norm):
        names.append(target)
if not names:
    raise SystemExit('P06_Z_MESA_PRODUCTION_OBJECT_NOT_FOUND')
pathlib.Path(sys.argv[2]).write_text('\n'.join(dict.fromkeys(names))+'\n')
print('Z_MESA_NATIVE_TARGETS='+str(len(names)))
PY
while IFS= read -r obj; do
  echo "Z_BUILD_PRODUCTION_TU=${obj}"
  ninja -C "$build" "$obj" 2>&1 | tee -a "$receipts/mesa-${CONTROL_Z_ARCH}-native-compile.log"
done < "$receipts/mesa-${CONTROL_Z_ARCH}-targets.txt"
# Do not upload .obj/.dll or run any installer or GPU tests.
echo "Z_MESA_${CONTROL_Z_ARCH}_NATIVE_COMPILE=PASS" | tee "$receipts/mesa-${CONTROL_Z_ARCH}-result.txt"
