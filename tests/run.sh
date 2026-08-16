#!/bin/sh
# Offline test runner. Live/network modules (*_live, t_diag, t_stream_timing)
# stay out of CI — they need provider credentials.
set -eu
root="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Clear stale compiled caches so changes to source modules are picked up.
# Without this, .zo files from a previous build cause linklet mismatch errors.
rm -rf tests/compiled src/ui/compiled src/kernel/compiled \
       src/ai/compiled src/tools/compiled src/ext/compiled \
       src/ext/bundled/compiled src/compiled compiled

# Recompile all test modules and their dependencies up front so the
# individual test runs share a consistent compilation cache.
echo "== compiling test modules =="
for f in tests/t_*.rhm; do
  base="$(basename "$f")"
  case "$base" in
    *_live.rhm|t_diag.rhm|t_stream_timing.rhm) continue ;;
  esac
  raco make "$f" 2>/dev/null || true
done

fail=0
for f in tests/t_*.rhm; do
  base="$(basename "$f")"
  case "$base" in
    *_live.rhm|t_diag.rhm|t_stream_timing.rhm)
      echo "skip $f"
      continue
      ;;
  esac
  echo "== $f =="
  if ! racket "$f"; then
    echo "FAIL $f"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "tests failed"
  exit 1
fi
echo "tests ok"
