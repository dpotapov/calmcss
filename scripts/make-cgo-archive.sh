#!/usr/bin/env bash
set -euo pipefail

input="${1:?input archive required}"
output="${2:?output archive required}"
target_os="${3:-}"

mkdir -p "$(dirname "$output")"

if [ -z "$target_os" ]; then
  case "$(uname -s)" in
    Darwin) target_os="darwin" ;;
    *) target_os="other" ;;
  esac
fi

if [ "$target_os" != "darwin" ] && [ "$target_os" != "macos" ]; then
  cp "$input" "$output"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
/usr/bin/ar -x "$input"
chmod u+rw ./*.o
/usr/bin/libtool -static -o "$output" ./*.o
