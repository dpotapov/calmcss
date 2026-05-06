#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/go/calmnative/prebuilt"
tmp="${TMPDIR:-/tmp}/calmcss-go-native-prebuilt"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: build-go-native-prebuilt.sh must run on macOS to produce the Darwin archive with Apple libtool" >&2
  exit 1
fi

rm -rf "$tmp"
mkdir -p "$out"

build_one() {
  local name="$1"
  local target="$2"
  local prefix="$tmp/$name"

  rm -rf "$prefix" "$out/$name"
  zig build -Dtarget="$target" -p "$prefix"
  mkdir -p "$out/$name"
  cp "$prefix/lib/libcalmcss_cgo.a" "$out/$name/libcalmcss_cgo.a"
}

build_one darwin_arm64 aarch64-macos
build_one linux_amd64 x86_64-linux-gnu
build_one linux_arm64 aarch64-linux-gnu
build_one windows_amd64 x86_64-windows-gnu
build_one windows_arm64 aarch64-windows-gnu
