#!/bin/sh
# The "Agreed" witness: run the official suite twice inside the same
# artifact -- once with every file AOT-compiled, once fully interpreted --
# and diff the observable output. Green here means the compiler and the
# interpreter agree, not merely that each passes on its own.
#
# usage: scripts/differential.sh <lua.wasm> [node] [exclude-list]
# exclude-list: comma-separated files forced to run interpreted in BOTH
# legs (so they are still compared, just not through AOT). Defaults to
# the documented structural exclusions:
#
#   literals -- literals.lua:226 asserts that identical long-string
#   *literals* in one chunk share one address (string.format("%p")):
#   the 5.4.8 parser's chunk-level constant-reuse optimization. luaot
#   materializes each compiled function's constants independently, so
#   the addresses differ. String *equality* is unaffected; the assert
#   checks a memory optimization, not semantics -- and it holds ONLY on
#   the parser path: stock Lua fails the same assert after its own
#   string.dump/load round-trip (witnessed 2026-07-06), which is why
#   upstream's all.lua itself routes literals.lua around its dump/undump
#   dofile via olddofile (all.lua:168). This exclusion is the same
#   maneuver for the same reason.
#
#   (history) gc -- gc.lua:477 asserts ABSOLUTE memory: within 1 KB of
#   a baseline after a full collect, a razor-thin bound that measures
#   heap-size instants, not semantics (suite-bundle.py widens the same
#   assert to m+3 because merely holding the sources as constants
#   shifts it ~1 KB). On the pre-#2 pin it tripped AOT'd on current V8
#   (Node 24 / V8 13.6, Chromium 141 / V8 14.1) in the all-32 artifact,
#   while passing on native, wasmtime (gc-only AND all-32), and Node
#   22/V8 12.4 -- recorded then as AOT rooting a dead value one
#   collection longer under some caller layouts. After the #2 luaot
#   batch (modules regenerated with the lua_callk footer), the trip is
#   no longer reproducible: the all-32 differential with gc.lua AOT'd
#   reports AGREED on Node 24.16 and 24.18 (V8 13.6.233.17, 2026-07-06,
#   this branch). gc.lua therefore runs AOT'd again. If this razor
#   trips anew, exclude it HERE with the failing run recorded -- do not
#   chase the 1 KB bound through codegen without first checking whether
#   the shift is an accounting instant of this kind.
#
#   Witnessed 2026-07-06: with only the literals exclusion, the full
#   suite is byte-identical between legs (all-32 wasm artifact, Node
#   24.16/24.18, 277 output lines).
#
# V8 runs baseline-only (--liftoff-only): its optimizing tier needs more
# memory than small machines have when it decides to optimize the giant
# functions luaot emits, and the witness cares about behavior, not speed.
# (run from the repo root; the suite runs with tests/ as guest cwd)
set -e

WASM=$1
NODE=${2:-node}
# ${3-...} (no colon), deliberately: an explicitly passed "" means
# "exclude nothing" -- only an ABSENT third argument gets the default.
# With ${3:-...} an empty string silently became the default, so an
# exclude-nothing run was impossible to request (issue #30).
EXCLUDE=${3-literals}
[ -n "$WASM" ] || { echo "usage: $0 <lua.wasm> [node]" >&2; exit 2; }
# the legs run with tests/ as cwd; a relative artifact path must survive that
case "$WASM" in /*) ;; *) WASM=$(pwd)/$WASM ;; esac

here=$(cd "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/lua-differential.$$
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

for mode in aot interp; do
  ( cd "$here/tests" && \
    "$NODE" --liftoff-only --no-warnings ../scripts/wasm-run.mjs "$WASM" \
      ../scripts/aot-suite.lua $mode "$EXCLUDE" \
      > "$tmp/$mode.out" 2> "$tmp/$mode.err" ) \
    || { echo "differential: $mode run FAILED"; tail -20 "$tmp/$mode.err"; exit 1; }
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
