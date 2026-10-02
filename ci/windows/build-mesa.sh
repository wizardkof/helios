#!/usr/bin/env bash
set -euo pipefail

# Every path below is already a Windows path. Without this, MSYS2's argument
# converter rewrites the embedded `-includeD:/...` compiler argument into the
# invalid `-includeD:A:/...` form before Meson sees it.
export MSYS2_ARG_CONV_EXCL='*'

repo_root="$(cygpath -m "${1:?usage: build-mesa.sh REPO_ROOT OUTPUT_DIR [BUILD_DIR] [--clean|--reuse]}")"
output_dir="$(cygpath -m "${2:?usage: build-mesa.sh REPO_ROOT OUTPUT_DIR [BUILD_DIR] [--clean|--reuse]}")"
build_dir="$(cygpath -m "${3:-C:/helios-mesa-build}")"
build_mode="${4:---clean}"

mesa_src="${repo_root}/icd/mesa"
native_file="${repo_root}/ci/windows/mingw-native.ini"
compat_header="${repo_root}/icd/win-build/helios_win_compat.h"

python "${repo_root}/tools/sync-metadata.py" --check

setup_mode=()
case "${build_mode}" in
  --clean)
    rm -rf "${build_dir}"
    ;;
  --reuse)
    if [[ -f "${build_dir}/build.ninja" ]]; then
      setup_mode+=(--reconfigure)
    fi
    ;;
  *)
    printf 'Unknown build mode: %s (expected --clean or --reuse)\n' "${build_mode}" >&2
    exit 2
    ;;
esac
mkdir -p "${output_dir}"

meson setup "${setup_mode[@]}" "${build_dir}" "${mesa_src}" \
  --native-file "${native_file}" \
  "-Dc_args=-include${compat_header}" \
  -Dvulkan-drivers=virtio \
  -Dgallium-drivers=zink \
  "-Dhelios-wdk-include=${repo_root}/icd/win-build/wdk-include" \
  -Dplatforms=windows \
  -Dvideo-codecs= \
  -Dvulkan-layers= \
  -Degl=disabled \
  -Dgbm=disabled \
  -Dglx=disabled \
  -Dopengl=true \
  -Dgles1=disabled \
  -Dgles2=disabled \
  -Dllvm=disabled \
  -Dshader-cache=disabled \
  -Dzlib=disabled \
  -Dzstd=disabled \
  -Dbuild-tests=false \
  -Dperfetto=false \
  -Dxmlconfig=disabled \
  --buildtype=release

meson compile -C "${build_dir}"

cp "${build_dir}/src/virtio/vulkan/vulkan_virtio.dll" "${output_dir}/"
cp "${build_dir}/src/gallium/targets/wgl/libgallium_wgl.dll" "${output_dir}/"
cp "${build_dir}/src/gallium/targets/libgl-gdi/opengl32.dll" "${output_dir}/opengl32-app-local.dll"

# WGL ICD dependencies are resolved by opengl32.dll and do not reliably search
# the private driver directory. Keep the Mesa ICDs self-contained instead of
# silently shipping a MinGW DLL that the Windows loader will not find.
for dll in "${output_dir}/vulkan_virtio.dll" "${output_dir}/libgallium_wgl.dll"; do
  while read -r dependency; do
    case "${dependency,,}" in
      lib*.dll|zlib1.dll)
        printf 'Unexpected non-system dependency in %s: %s\n' "${dll}" "${dependency}" >&2
        exit 1
        ;;
    esac
  done < <(objdump -p "${dll}" | sed -n 's/^[[:space:]]*DLL Name: //p')
done

mkdir -p "${output_dir}/licenses/mesa"
cp -R "${mesa_src}/licenses/." "${output_dir}/licenses/mesa/"

mesa_commit="$(git -C "${mesa_src}" rev-parse HEAD)"
mesa_version="$(git -C "${mesa_src}" describe --tags --always --dirty)"
mesa_dirty="$(git -C "${mesa_src}" status --porcelain=v1 --untracked-files=all)"
if [[ -n "${mesa_dirty}" ]]; then
  printf 'Refusing to package a Mesa worktree that differs from its locked commit.\n%s\n' "${mesa_dirty}" >&2
  exit 1
fi
python - "${output_dir}/source.json" "${mesa_commit}" "${mesa_version}" <<'PY'
import json, pathlib, sys
path, commit, version = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "component": "mesa",
    "upstreamVersion": version,
    "sourceCommit": commit,
}, sort_keys=True, indent=2) + "\n", encoding="utf-8")
PY

{
  for dll in "${output_dir}"/*.dll; do
    echo "=== $(basename "${dll}") ==="
    objdump -p "${dll}" | sed -n 's/^[[:space:]]*DLL Name: /DLL Name: /p'
  done
} > "${output_dir}/imports.txt"

printf 'Mesa artifact staged at %s\n' "${output_dir}"
