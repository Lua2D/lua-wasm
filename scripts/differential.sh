#!/bin/sh
# The "Agreed" witness: run the official suite twice inside the same
# artifact -- once with every file AOT-compiled, once fully interpreted --
# and diff the observable output. Green here means the compiler and the
# interpreter agree, not merely that each passes on its own.
#
# usage: scripts/differential.sh <lua.wasm> [node] [exclude-list]
# exclude-list: comma-separated files forced to run interpreted in BOTH
# legs (so they are still compared, just not through AOT) -- the
# documented structural exclusions live here
#
# V8 runs baseline-only (--liftoff-only): its optimizing tier needs more
# memory than small machines have when it decides to optimize the giant
# functions luaot emits, and the witness cares about behavior, not speed.
# (run from the repo root; the suite runs with tests/ as guest cwd)
set -e

WASM=$1
NODE=${2:-node}
EXCLUDE=${3:-}
[ -n "$WASM" ] || { echo "usage: $0 <lua.wasm> [node]" >&2; exit 2; }

here=$(cd "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/lua-differential.$$
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

for mode in aot interp; do
  ( cd "$here/tests" && \
    "$NODE" --liftoff-only --no-warnings ../scripts/wasm-run.mjs "$WASM" \
      ../scripts/aot-suite.lua $mode "$EXCLUDE" \
      > "$tmp/$mode.out" 2> "$tmp/$mode.err" ) \
    || { echo "differential: $mode run FAILED"; tail -5 "$tmp/$mode.err"; exit 1; }
done

# Normalizations, each with its reason. The first three differ between
# any two runs of the SAME mode (pure run nondeterminism); the last is
# the one expected AOT/interpreter divergence: AOT'd calls consume real
# C stack, so stack-overflow boundaries land a few frames earlier. The
# overflow behavior itself -- detection, error, recovery -- is identical
# and still compared; only the measured depth is masked.
for mode in aot interp; do
  sed -e 's/0x[0-9a-fA-F]*//g' \
      -e 's/[0-9][0-9.]* msec\./N msec./g' \
      -e 's/with [0-9]* comparisons/with N comparisons/' \
      -e 's/^test done on .*/test done/' \
      -e 's/random range in [0-9]* calls: .*/random range/' -e 's/short-circuit optimizations (.)/short-circuit optimizations (R)/' \
      -e 's/^random seeds: .*/random seeds: R/' \
      -e 's/^final count:.*/final count: DEPTH/' \
      -e 's/expected stack overflow after [0-9]* calls/expected stack overflow after DEPTH calls/' \
      "$tmp/$mode.out" > "$tmp/$mode.norm"
done

if diff -u "$tmp/interp.norm" "$tmp/aot.norm" > "$tmp/delta"; then
  echo "differential: AGREED ($(wc -l < "$tmp/aot.out") lines of output, byte-identical after documented normalizations)"
else
  echo "differential: DIVERGED"
  head -40 "$tmp/delta"
  exit 1
fi
