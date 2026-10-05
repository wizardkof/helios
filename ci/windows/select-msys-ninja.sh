#!/usr/bin/env bash
# Shared by the Mesa producer and its minimal consumer control. Native Windows
# consumers must receive the mounted Windows identity with argument conversion off.
helios_select_msys_ninja() {
  local ninja_posix ninja_windows
  export MSYS2_ARG_CONV_EXCL='*'
  ninja_posix="$(command -v ninja.exe || command -v ninja || true)"
  if [[ -z "$ninja_posix" || ! -f "$ninja_posix" ]]; then
    echo 'MSYS2 Ninja was not resolved to an existing file' >&2
    return 1
  fi
  ninja_windows="$(cygpath -m "$ninja_posix")" || return 1
  if [[ -z "$ninja_windows" ]]; then
    echo 'MSYS2 Ninja Windows identity was empty' >&2
    return 1
  fi
  export NINJA="$ninja_windows"
}
