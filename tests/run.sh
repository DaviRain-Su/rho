#!/bin/sh
# Offline test runner. Live/network modules (*_live, t_diag, t_stream_timing)
# stay out of CI — they need provider credentials.
set -eu
root="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
cd "$root"

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
