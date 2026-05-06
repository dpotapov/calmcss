#!/usr/bin/env bash
set -euo pipefail

fixture="${1:-examples/input.html}"
loops="${CALMCSS_BENCH_LOOPS:-100}"

zig build -Doptimize=ReleaseSmall >/dev/null
go build -o zig-out/bin/go-calmcss ./cmd/go-calmcss
go build -o zig-out/bin/wazero-calmcss ./cmd/wazero-calmcss

run() {
  local label="$1"
  shift
  local start
  local end
  start="$(python3 - <<'PY'
import time
print(time.perf_counter_ns())
PY
)"
  for _ in $(seq 1 "$loops"); do
    "$@" "$fixture" >/dev/null
  done
  end="$(python3 - <<'PY'
import time
print(time.perf_counter_ns())
PY
)"
  python3 - "$label" "$loops" "$start" "$end" <<'PY'
import sys
label, loops, start, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
ms = (end - start) / 1_000_000
print(f"{label}: {ms / loops:.3f} ms/run over {loops} runs")
PY
}

rss() {
  local label="$1"
  shift
  local tmp
  tmp="$(mktemp)"
  if /usr/bin/time -l "$@" "$fixture" >/dev/null 2>"$tmp"; then
    local bytes
    bytes="$(awk '/maximum resident set size/ {print $1}' "$tmp" | tail -1)"
    if [ -n "$bytes" ]; then
      python3 - "$label" "$bytes" <<'PY'
import sys
label, bytes_value = sys.argv[1], int(sys.argv[2])
print(f"{label}: peak RSS {bytes_value / 1024 / 1024:.2f} MiB")
PY
    fi
  fi
  rm -f "$tmp"
}

echo "Compilation time"
run "tailwind-js" node scripts/tailwind-bench.mjs
run "zig-native" ./zig-out/bin/calmcss
run "go-cgo" ./zig-out/bin/go-calmcss
run "go-wazero" ./zig-out/bin/wazero-calmcss

echo
echo "Memory"
rss "tailwind-js" node scripts/tailwind-bench.mjs
rss "zig-native" ./zig-out/bin/calmcss
rss "go-cgo" ./zig-out/bin/go-calmcss
rss "go-wazero" ./zig-out/bin/wazero-calmcss

echo
echo "Artifacts"
ls -lh zig-out/bin/calmcss zig-out/bin/go-calmcss zig-out/bin/wazero-calmcss zig-out/wasm/calmcss.wasm zig-out/lib/libcalmcss.a zig-out/lib/libcalmcss_cgo.a
