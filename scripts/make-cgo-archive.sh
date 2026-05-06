#!/usr/bin/env bash
set -euo pipefail

input="${1:?input archive required}"
output="${2:?output archive required}"

mkdir -p "$(dirname "$output")"

if [ "$(uname -s)" != "Darwin" ]; then
  cp "$input" "$output"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
/usr/bin/ar -x "$input"
chmod u+rw ./*.o
/usr/bin/libtool -static -o "$output" ./*.o
