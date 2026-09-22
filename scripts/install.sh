#!/bin/sh
# Install the Wiregrid C client, browser UI kit, and source bindings.
#
# Curl a published tag and install the matching release archive:
#
#   curl -fsSL https://raw.githubusercontent.com/Plainwire-development/Wiregrid/v1.0.0/scripts/install.sh | sh
#
# What lands under the prefix:
#   include/wiregrid.h
#   lib/ or lib64/     static library, shared library, pkgconfig/wiregrid.pc
#   share/wiregrid/ui
#       HTML, CSS, and JavaScript copied from priv/ui
#   share/wiregrid/bindings
#       Gleam, LFE, and Erlang sources
#   share/wiregrid/LAYOUT
#       plain-text map of the paths above
#
# Elixir stays a mix dependency of the application that runs the BEAM node.
# Mix compiles the BEAM files there. This script installs the C library, the
# UI kit, and source bindings.
#
# Prefix selection:
#   PREFIX, when set, is used as given.
#   Root with PREFIX unset uses /usr/local when that directory exists.
#   Any other user gets $HOME/.local.
#   On macOS, a Homebrew prefix owned by the current user is used when a
#   system write to /usr/local is the wrong default. Homebrew is not invoked
#   as root.
#
# Archive selection:
#   WIREGRID_TARBALL   use this file, then install it.
#   WIREGRID_VERSION   download this release (a leading v is optional).
#   Otherwise a checkout that contains native/c and priv/ui is built here.
#   An unpacked release tree (include/, lib/, share/wiregrid/) installs those
#   files. A script piped into the shell, with no source tree, downloads the
#   latest GitHub release.
#
# Download URL:
#   https://github.com/Plainwire-development/Wiregrid/releases/download/v<version>/<asset>
# The published asset is wiregrid-<version>-linux-x86_64.tar.gz. Other
# operating systems and CPUs stop before installing a binary that does not
# match the machine. SHA256SUMS is checked when that release asset exists.
# A missing checksums file is reported and the install continues.
#
# The script does not prompt. If the prefix is not writable, it exits.
set -eu

REPO="Plainwire-development/Wiregrid"
SOVERSION="1"
CLEANUP_DIRS=""

die() {
  printf 'install: %s\n' "$1" >&2
  exit 1
}

say() {
  printf 'install: %s\n' "$1"
}

cleanup() {
  for dir in $CLEANUP_DIRS; do
    rm -rf "$dir"
  done
}

trap cleanup EXIT

keep_temp() {
  CLEANUP_DIRS="$CLEANUP_DIRS $1"
}

script_path() {
  if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE:-}" ]; then
    printf '%s\n' "$BASH_SOURCE"
    return 0
  fi
  case "$0" in
    bash | sh | dash | -bash | -sh | -dash | */bash | */sh | */dash) return 1 ;;
  esac
  if [ -f "$0" ]; then
    printf '%s\n' "$0"
    return 0
  fi
  return 1
}

tree_from_script() {
  script=$1
  dir=$(CDPATH= cd "$(dirname "$script")" && pwd) || return 1
  case "$dir" in
    */scripts) dirname "$dir" ;;
    *) printf '%s\n' "$dir" ;;
  esac
}

is_source_tree() {
  [ -n "$1" ] && [ -f "$1/native/c/src/wiregrid.c" ] && [ -d "$1/priv/ui" ]
}

is_release_tree() {
  [ -n "$1" ] &&
    [ -f "$1/include/wiregrid.h" ] &&
    [ -d "$1/share/wiregrid/ui" ] &&
    [ -d "$1/share/wiregrid/bindings" ]
}

normalize_version() {
  v=$1
  case "$v" in
    v*) v=${v#v} ;;
  esac
  printf '%s\n' "$v"
}

read_version() {
  src=$1
  if [ -f "$src/VERSION" ]; then
    tr -d ' \t\r\n' <"$src/VERSION"
    return 0
  fi
  if [ -f "$src/mix.exs" ]; then
    sed -n 's/^[[:space:]]*@version[[:space:]]*"\([^"]*\)".*/\1/p' "$src/mix.exs" | head -n 1
    return 0
  fi
  printf '%s\n' "1.0.0"
}

platform_id() {
  os=$(uname -s)
  cpu=$(uname -m)
  case "$os" in
    Linux) os_name=linux ;;
    Darwin) os_name=darwin ;;
    *) os_name=$(printf '%s' "$os" | tr '[:upper:]' '[:lower:]') ;;
  esac
  case "$cpu" in
    x86_64 | amd64) cpu_name=x86_64 ;;
    aarch64 | arm64) cpu_name=aarch64 ;;
    *) cpu_name=$cpu ;;
  esac
  printf '%s-%s\n' "$os_name" "$cpu_name"
}

asset_name() {
  version=$1
  id=$(platform_id)
  case "$id" in
    linux-x86_64) ;;
    *)
      printf 'install: no published binary for %s.\n' "$(uname -s) $(uname -m)" >&2
      printf 'install: releases publish wiregrid-<version>-linux-x86_64.tar.gz.\n' >&2
      printf 'install: a source checkout builds native/c on this machine.\n' >&2
      return 1
      ;;
  esac
  printf 'wiregrid-%s-%s.tar.gz\n' "$version" "$id"
}

owner_uid() {
  if stat -c '%u' "$1" >/dev/null 2>&1; then
    stat -c '%u' "$1"
  else
    stat -f '%u' "$1"
  fi
}

owns_dir() {
  [ -d "$1" ] || return 1
  [ "$(owner_uid "$1")" = "$(id -u)" ]
}

abs_prefix() {
  path=$1
  case "$path" in
    /*) ;;
    *) path="${invoke_pwd}/${path}" ;;
  esac
  while [ "$path" != "/" ]; do
    case "$path" in
      */) path=${path%/} ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$path"
}

choose_prefix() {
  euid=$(id -u)

  if [ -n "${PREFIX:-}" ]; then
    abs_prefix "$PREFIX"
    return 0
  fi

  # A non-root macOS user who owns the Homebrew prefix should install there.
  # Root keeps the system prefix and does not call brew.
  if [ "$(uname -s)" = "Darwin" ] && [ "$euid" -ne 0 ] && command -v brew >/dev/null 2>&1; then
    brew_prefix=$(brew --prefix 2>/dev/null || true)
    if [ -n "$brew_prefix" ] && owns_dir "$brew_prefix"; then
      abs_prefix "$brew_prefix"
      return 0
    fi
  fi

  if [ "$euid" -eq 0 ] && [ -d /usr/local ]; then
    printf '%s\n' /usr/local
    return 0
  fi

  if [ -z "${HOME:-}" ]; then
    die "HOME is unset. Set PREFIX to the install directory."
  fi
  abs_prefix "${HOME}/.local"
}

lib_name_for() {
  os=$1
  prefix=$2
  name=lib

  if [ "$os" = "Linux" ] && [ -d /usr/lib64 ] && [ ! -L /usr/lib64 ]; then
    case "$prefix" in
      /usr | /usr/local) name=lib64 ;;
    esac
  fi

  if [ -d "${prefix}/lib64" ] && [ ! -e "${prefix}/lib" ]; then
    name=lib64
  fi

  printf '%s\n' "$name"
}

ensure_writable() {
  target=$1
  probe=$target

  if [ -e "$probe" ] && [ ! -d "$probe" ]; then
    die "prefix exists and is not a directory: ${probe}"
  fi

  while [ ! -e "$probe" ]; do
    probe=$(dirname "$probe")
  done

  if [ ! -d "$probe" ] || [ ! -w "$probe" ]; then
    printf 'install: cannot write to %s\n' "$target" >&2
    printf 'install: set PREFIX to a directory your user can write.\n' >&2
    exit 1
  fi
}

on_default_linker_path() {
  prefix=$1
  libdir=$2
  case "$prefix" in
    /usr | /usr/local) return 0 ;;
  esac
  case "$libdir" in
    /lib | /usr/lib | /usr/lib64 | /usr/local/lib | /usr/local/lib64) return 0 ;;
  esac
  return 1
}

print_env_lines() {
  os=$1
  prefix=$2
  libdir=$3

  printf '\n'
  printf 'The prefix is outside the default linker path. Add these lines:\n\n'
  printf 'export PKG_CONFIG_PATH="%s/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"\n' "$libdir"
  if [ "$os" = "Darwin" ]; then
    printf 'export DYLD_LIBRARY_PATH="%s${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"\n' "$libdir"
  else
    printf 'export LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$libdir"
  fi
  printf 'export C_INCLUDE_PATH="%s/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"\n' "$prefix"
  printf '\n'
}

sha256_file() {
  file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$file") || return 1
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 "$file") || return 1
  else
    return 1
  fi
  printf '%s\n' "$out" | awk '{print $1}'
}

verify_checksum() {
  file=$1
  sums=$2
  name=$(basename "$file")
  expected=$(awk -v n="$name" '
    {
      f = $2
      sub(/^\*/, "", f)
      if (f == n) { print $1; exit }
    }
  ' "$sums")
  if [ -z "$expected" ]; then
    die "checksums file has no entry for ${name}."
  fi
  actual=$(sha256_file "$file") || die "checksums file is present and no sha256 tool was found."
  if [ "$actual" != "$expected" ]; then
    die "sha256 mismatch for ${name}."
  fi
  say "verified sha256 for ${name}"
}

checksums_for_tarball() {
  tarball=$1
  if [ -n "${WIREGRID_CHECKSUMS:-}" ]; then
    printf '%s\n' "$WIREGRID_CHECKSUMS"
    return 0
  fi
  beside=$(dirname "$tarball")/SHA256SUMS
  if [ -f "$beside" ]; then
    printf '%s\n' "$beside"
    return 0
  fi
  return 1
}

reject_mismatched_name() {
  tarball=$1
  name=$(basename "$tarball")
  case "$name" in
    wiregrid-*-linux-x86_64.tar.gz)
      if [ "$(platform_id)" != "linux-x86_64" ]; then
        die "this archive is linux-x86_64 and this machine is $(uname -s) $(uname -m)."
      fi
      ;;
  esac
}

unpack_tarball() {
  tarball=$1
  dest=$(mktemp -d "${TMPDIR:-/tmp}/wiregrid-install.XXXXXX") || die "could not create a temp directory."
  keep_temp "$dest"
  tar -xzf "$tarball" -C "$dest" || die "failed to unpack ${tarball}."
  if [ -f "$dest/include/wiregrid.h" ]; then
    PAYLOAD=$dest
    return 0
  fi
  for child in "$dest"/*; do
    if [ -d "$child" ] && [ -f "$child/include/wiregrid.h" ]; then
      PAYLOAD=$child
      return 0
    fi
  done
  die "tarball layout is missing include/wiregrid.h."
}

use_local_tarball() {
  tarball=$1
  [ -f "$tarball" ] || die "tarball not found: ${tarball}"
  reject_mismatched_name "$tarball"
  if sums=$(checksums_for_tarball "$tarball"); then
    [ -f "$sums" ] || die "checksums file not found: ${sums}"
    verify_checksum "$tarball" "$sums"
  else
    say "checksums file is missing; continuing without a sha256 check."
  fi
  unpack_tarball "$tarball"
}

latest_version() {
  api="https://api.github.com/repos/${REPO}/releases/latest"
  body=$(curl -fsSL --retry 3 --retry-delay 1 -H "Accept: application/vnd.github+json" "$api") || return 1
  tag=$(printf '%s\n' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$tag" ] || return 1
  normalize_version "$tag"
}

download_release() {
  version=$1
  [ -n "$version" ] || die "version is empty."
  command -v curl >/dev/null 2>&1 || die "curl is required to download a release."
  asset=$(asset_name "$version") || exit 1
  dest=$(mktemp -d "${TMPDIR:-/tmp}/wiregrid-install.XXXXXX") || die "could not create a temp directory."
  keep_temp "$dest"
  url="https://github.com/${REPO}/releases/download/v${version}/${asset}"
  sums_url="https://github.com/${REPO}/releases/download/v${version}/SHA256SUMS"
  say "downloading ${url}"
  if ! curl -fsSL --retry 3 --retry-delay 1 -o "${dest}/${asset}" "$url"; then
    die "could not download ${url}."
  fi
  if curl -fsSL --retry 3 --retry-delay 1 -o "${dest}/SHA256SUMS" "$sums_url"; then
    verify_checksum "${dest}/${asset}" "${dest}/SHA256SUMS"
  else
    say "checksums file is missing from the release; continuing without a sha256 check."
  fi
  unpack_tarball "${dest}/${asset}"
}

numeric_version() {
  current=$(printf '%s\n' "$1" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  if [ -n "$current" ]; then
    printf '%s\n' "$current"
  else
    printf '%s\n' "1.0.0"
  fi
}

build_library() {
  os=$1
  work=$2
  libdir=$3
  cc=${CC:-cc}
  ar=${AR:-ar}

  command -v "$cc" >/dev/null 2>&1 || die "C compiler '${cc}' was not found."
  command -v "$ar" >/dev/null 2>&1 || die "archiver '${ar}' was not found."

  "$cc" -std=c11 -O2 -Wall -Wextra -fPIC -I "${ROOT}/native/c/include" \
    -c "${ROOT}/native/c/src/wiregrid.c" -o "${work}/wiregrid.o" ||
    die "failed to compile native/c/src/wiregrid.c."

  "$ar" rcs "${work}/libwiregrid.a" "${work}/wiregrid.o" ||
    die "failed to create libwiregrid.a."

  if [ "$os" = "Darwin" ]; then
    current=$(numeric_version "$version")
    "$cc" -dynamiclib \
      -Wl,-install_name,"${libdir}/libwiregrid.${SOVERSION}.dylib" \
      -Wl,-compatibility_version,1.0.0 \
      -Wl,-current_version,"${current}" \
      -o "${work}/libwiregrid.${version}.dylib" \
      "${work}/wiregrid.o" ||
      die "failed to link libwiregrid.${version}.dylib."
  else
    "$cc" -shared \
      -Wl,-soname,"libwiregrid.so.${SOVERSION}" \
      -o "${work}/libwiregrid.so.${version}" \
      "${work}/wiregrid.o" ||
      die "failed to link libwiregrid.so.${version}."
  fi
}

write_pc() {
  libdir=$1
  prefix=$2
  lib_name=$3
  install -d -m 755 "${libdir}/pkgconfig"
  cat >"${libdir}/pkgconfig/wiregrid.pc" <<EOF
prefix=${prefix}
exec_prefix=\${prefix}
libdir=\${prefix}/${lib_name}
includedir=\${prefix}/include

Name: wiregrid
Description: C client ABI for the Wiregrid realtime gateway
Version: ${version}
Libs: -L\${libdir} -lwiregrid
Cflags: -I\${includedir}
EOF
}

write_layout() {
  share=$1
  lib_name=$2
  cat >"${share}/LAYOUT" <<EOF
wiregrid ${version}

This prefix contains the C client, the browser UI kit, and source bindings.
Elixir stays a mix dependency of the application that runs the BEAM node.
Mix compiles the BEAM files for that application. The trees below are the
files this script installed.

include/wiregrid.h
    C client header.

${lib_name}/libwiregrid.a
    Static C library.

${lib_name}/libwiregrid.so* or ${lib_name}/libwiregrid*.dylib
    Shared C library. Link with pkg-config.

${lib_name}/pkgconfig/wiregrid.pc
    pkg-config file. pkg-config --exists wiregrid succeeds when this
    directory is on PKG_CONFIG_PATH, or when the prefix is already on the
    default search path.

share/wiregrid/ui
    HTML, CSS, and JavaScript copied from priv/ui.
    Load wiregrid.css and wiregrid.js from here, or import wiregrid.esm.js.

share/wiregrid/bindings/gleam
    Gleam sources (gleam.toml and src).

share/wiregrid/bindings/lfe
    LFE sources.

share/wiregrid/bindings/erlang
    Erlang sources, including the Gleam FFI module.
    Compile them with erlc from the application that wants them on the code path.
EOF
}

install_built_library() {
  os=$1
  work=$2
  includedir=$3
  libdir=$4
  prefix=$5
  lib_name=$6

  install -d -m 755 "$includedir" "$libdir" "${libdir}/pkgconfig"
  install -m 644 "${ROOT}/native/c/include/wiregrid.h" "${includedir}/wiregrid.h"
  install -m 644 "${work}/libwiregrid.a" "${libdir}/libwiregrid.a"

  if [ "$os" = "Darwin" ]; then
    install -m 755 "${work}/libwiregrid.${version}.dylib" \
      "${libdir}/libwiregrid.${version}.dylib"
    ln -sfn "libwiregrid.${version}.dylib" "${libdir}/libwiregrid.${SOVERSION}.dylib"
    ln -sfn "libwiregrid.${SOVERSION}.dylib" "${libdir}/libwiregrid.dylib"
  else
    install -m 755 "${work}/libwiregrid.so.${version}" \
      "${libdir}/libwiregrid.so.${version}"
    ln -sfn "libwiregrid.so.${version}" "${libdir}/libwiregrid.so.${SOVERSION}"
    ln -sfn "libwiregrid.so.${SOVERSION}" "${libdir}/libwiregrid.so"
  fi

  write_pc "$libdir" "$prefix" "$lib_name"
}

install_source_payload() {
  share=$1
  lib_name=$2
  ui="${share}/ui"
  bind="${share}/bindings"

  rm -rf "$ui" "$bind"
  install -d -m 755 "$ui" "${bind}/gleam" "${bind}/lfe" "${bind}/erlang"
  cp -a "${ROOT}/priv/ui/." "$ui/"
  cp -a "${ROOT}/bindings/gleam/gleam.toml" "${bind}/gleam/gleam.toml"
  cp -a "${ROOT}/bindings/gleam/src" "${bind}/gleam/src"
  cp -a "${ROOT}/bindings/lfe/"*.lfe "${bind}/lfe/"
  if [ -f "${ROOT}/bindings/lfe/README.md" ]; then
    cp -a "${ROOT}/bindings/lfe/README.md" "${bind}/lfe/README.md"
  fi
  cp -a "${ROOT}/src/"*.erl "${bind}/erlang/"
  write_layout "$share" "$lib_name"
}

clear_wiregrid_libs() {
  libdir=$1
  rm -f \
    "$libdir"/libwiregrid.a \
    "$libdir"/libwiregrid.so \
    "$libdir"/libwiregrid.dylib \
    "$libdir"/libwiregrid.so.[0-9]* \
    "$libdir"/libwiregrid.[0-9]*.dylib
}

src_libdir() {
  src=$1
  if [ -d "$src/lib" ] && [ -e "$src/lib/libwiregrid.a" ]; then
    printf '%s\n' "$src/lib"
  elif [ -d "$src/lib64" ] && [ -e "$src/lib64/libwiregrid.a" ]; then
    printf '%s\n' "$src/lib64"
  else
    return 1
  fi
}

require_matching_target() {
  src=$1
  if [ -f "$src/TARGET" ]; then
    target=$(tr -d ' \t\r\n' <"$src/TARGET")
    mine=$(platform_id)
    if [ "$target" != "$mine" ]; then
      die "this archive targets ${target} and this machine is ${mine}."
    fi
  fi
}

install_prebuilt() {
  src=$1
  require_matching_target "$src"
  [ -f "$src/include/wiregrid.h" ] || die "archive is missing include/wiregrid.h."
  [ -d "$src/share/wiregrid/ui" ] || die "archive is missing share/wiregrid/ui."
  [ -d "$src/share/wiregrid/bindings" ] || die "archive is missing share/wiregrid/bindings."
  src_lib=$(src_libdir "$src") || die "archive is missing the static library."

  os=$(uname -s)
  version=$(read_version "$src")
  [ -n "$version" ] || version=1.0.0
  prefix=$(choose_prefix) || exit 1
  lib_name=$(lib_name_for "$os" "$prefix") || exit 1
  libdir="${prefix}/${lib_name}"
  includedir="${prefix}/include"
  share="${prefix}/share/wiregrid"

  ensure_writable "$prefix"
  say "os=${os} prefix=${prefix} libdir=${libdir}"

  install -d -m 755 "$includedir" "$libdir" "$share"
  install -m 644 "$src/include/wiregrid.h" "${includedir}/wiregrid.h"
  clear_wiregrid_libs "$libdir"
  for item in "$src_lib"/*; do
    [ -e "$item" ] || continue
    base=$(basename "$item")
    if [ "$base" = "pkgconfig" ]; then
      continue
    fi
    cp -a "$item" "$libdir/"
  done
  write_pc "$libdir" "$prefix" "$lib_name"

  rm -rf "${share}/ui" "${share}/bindings"
  install -d -m 755 "${share}/ui" "${share}/bindings"
  cp -a "$src/share/wiregrid/ui/." "${share}/ui/"
  cp -a "$src/share/wiregrid/bindings/." "${share}/bindings/"
  write_layout "$share" "$lib_name"
  report_install "$os" "$prefix" "$libdir" "$includedir" "$share"
}

install_from_source() {
  [ -f "${ROOT}/native/c/src/wiregrid.c" ] || die "missing native/c sources under ${ROOT}."
  [ -d "${ROOT}/priv/ui" ] || die "missing priv/ui under ${ROOT}."

  os=$(uname -s)
  version=$(read_version "$ROOT")
  [ -n "$version" ] || version=1.0.0
  prefix=$(choose_prefix) || exit 1
  lib_name=$(lib_name_for "$os" "$prefix") || exit 1
  libdir="${prefix}/${lib_name}"
  includedir="${prefix}/include"
  share="${prefix}/share/wiregrid"

  ensure_writable "$prefix"
  say "os=${os} prefix=${prefix} libdir=${libdir}"

  work=$(mktemp -d "${TMPDIR:-/tmp}/wiregrid-install.XXXXXX") || die "could not create a temp directory."
  keep_temp "$work"
  build_library "$os" "$work" "$libdir"
  install_built_library "$os" "$work" "$includedir" "$libdir" "$prefix" "$lib_name"
  install_source_payload "$share" "$lib_name"
  report_install "$os" "$prefix" "$libdir" "$includedir" "$share"
}

report_install() {
  os=$1
  prefix=$2
  libdir=$3
  includedir=$4
  share=$5

  printf 'installed wiregrid %s\n' "$version"
  printf '  header     %s/wiregrid.h\n' "$includedir"
  printf '  libraries  %s\n' "$libdir"
  printf '  pkgconfig  %s/pkgconfig/wiregrid.pc\n' "$libdir"
  printf '  ui kit     %s/ui\n' "$share"
  printf '  bindings   %s/bindings\n' "$share"
  printf '  layout     %s/LAYOUT\n' "$share"

  if ! on_default_linker_path "$prefix" "$libdir"; then
    print_env_lines "$os" "$prefix" "$libdir"
  fi
}

main() {
  invoke_pwd=$(pwd)

  if [ "$#" -gt 0 ]; then
    die "this script reads PREFIX from the environment and takes no arguments. Usage: PREFIX=/opt/wiregrid scripts/install.sh"
  fi

  case "$(uname -s)" in
    Linux | Darwin) ;;
    *)
      printf 'install: unsupported operating system: %s\n' "$(uname -s)" >&2
      printf 'install: this script supports Linux and macOS (Darwin).\n' >&2
      exit 1
      ;;
  esac

  tree=""
  if script=$(script_path); then
    tree=$(tree_from_script "$script") || tree=""
  fi

  if [ -n "${WIREGRID_TARBALL:-}" ]; then
    use_local_tarball "$WIREGRID_TARBALL"
    install_prebuilt "$PAYLOAD"
  elif [ -n "${WIREGRID_VERSION:-}" ]; then
    ver=$(normalize_version "$WIREGRID_VERSION")
    download_release "$ver"
    install_prebuilt "$PAYLOAD"
  elif is_source_tree "$tree"; then
    ROOT=$tree
    install_from_source
  elif is_release_tree "$tree"; then
    install_prebuilt "$tree"
  else
    ver=$(latest_version) || die "could not read the latest GitHub release. Set WIREGRID_VERSION or WIREGRID_TARBALL."
    download_release "$ver"
    install_prebuilt "$PAYLOAD"
  fi
}

main "$@"
