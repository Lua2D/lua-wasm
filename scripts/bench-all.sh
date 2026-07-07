#!/bin/sh
# Run the full four-cell benchmark matrix (native/wasm x interp/AOT),
# best-of-3 per cell, into experiments/results.csv. Run from repo root.
#
# Prerequisites (built on demand where possible):
#   src/lua, src/luaot        -- make guess
#   lua.wasm                  -- make wasm
#   lua-bench.wasm            -- make wasm WASM_O=lua-bench.wasm WASM_AOT="..."
#   a native AOT bench binary -- built here
#   NODE=/path/to/node >= 24.15  -- wasm host with wasm exception handling
set -e

NODE=${NODE:-node}
# Two workload classes, measured through one harness (issue #10):
# numeric loops (AOT's best case) and game-shaped table/GC/string/closure
# churn (the workload this project exists to serve).
BENCHES="fib:34 nbody:1000000 mandelbrot:1500 spectralnorm:1000 fannkuch:10 entitytables:6000 stringbuild:8000 closurechurn:12000"
SRCS=""
for spec in $BENCHES; do
  b=${spec%:*}
  SRCS="$SRCS experiments/$b.lua"
done

test -x src/lua || make -C src guess >/dev/null
test -f lua.wasm || make wasm >/dev/null
test -f lua-bench.wasm || make wasm WASM_O=lua-bench.wasm WASM_AOT="$SRCS" >/dev/null

# native AOT bench binary: compile each benchmark, generate a registry,
# link into the amalgamation
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
reg="$tmp/reg.c"
{
  echo '#include "lua.h"'; echo '#include "lauxlib.h"'
  for spec in $BENCHES; do b=${spec%:*}; echo "int luaopen_aot_$b(lua_State*L);"; done
  echo 'void luaot_preload(lua_State*L){luaL_getsubtable(L,LUA_REGISTRYINDEX,LUA_PRELOAD_TABLE);'
  for spec in $BENCHES; do b=${spec%:*}; echo "lua_pushcfunction(L,luaopen_aot_$b);lua_setfield(L,-2,\"aot_$b\");"; done
  echo 'lua_pop(L,1);}'
} > "$reg"
objs="$reg"
for spec in $BENCHES; do
  b=${spec%:*}
  ./src/luaot experiments/$b.lua -o "$tmp/$b.c" -m aot_$b
  objs="$objs $tmp/$b.c"
done
gcc -O2 -DLUA_USE_LINUX -DLUA_AOT -Isrc -o "$tmp/lua-aot" src/onelua.c $objs -lm -ldl -Wl,-E

best() { # best-of-3 seconds from the CSV a bench run prints
  # A cell whose three runs ALL fail must kill the script loudly, never
  # write a plausible-looking sentinel into results.csv (issue #29: the
  # old min=999 seed did exactly that, and set -e could not fire from a
  # non-terminal AND-list position inside a command substitution). min
  # starts empty; only a parsed time sets it. The exit propagates: the
  # caller is a plain assignment, so set -e sees the substitution fail.
  min=
  for _ in 1 2 3; do
    t=$("$@" 2>/dev/null | cut -d, -f4) || true
    if [ -n "$t" ]; then
      if [ -z "$min" ] || awk "BEGIN{exit !($t<$min)}"; then min=$t; fi
    fi
  done
  if [ -z "$min" ]; then
    echo "bench-all: cell '$*' produced no successful runs (3/3 failed)" >&2
    exit 1
  fi
  echo "$min"
}

echo "bench,N,native_interp,native_aot,wasm_interp,wasm_aot" > experiments/results.csv
for spec in $BENCHES; do
  b=${spec%:*}; n=${spec#*:}
  ni=$(best ./src/lua scripts/bench.lua ni $b $n)
  na=$(best "$tmp/lua-aot" scripts/bench.lua na $b $n aot_)
  wi=$(best $NODE --no-warnings scripts/wasm-run.mjs lua.wasm scripts/bench.lua wi $b $n)
  wa=$(best $NODE --no-warnings scripts/wasm-run.mjs lua-bench.wasm scripts/bench.lua wa $b $n aot_)
  echo "$b,$n,$ni,$na,$wi,$wa" | tee -a experiments/results.csv
done
