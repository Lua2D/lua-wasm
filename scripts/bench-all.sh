#!/bin/sh
# Run the full four-cell benchmark matrix (native/wasm x interp/AOT),
# best-of-3 per cell, into experiments/results.csv. Run from repo root.
#
# Prerequisites (built on demand where possible):
#   src/lua, src/luaot        -- make guess
#   lua.wasm                  -- make wasm
#   lua-bench.wasm            -- make wasm WASM_O=lua-bench.wasm WASM_AOT="..."
#   a native AOT bench binary -- built here
#   NODE=/path/to/node >= 24  -- wasm host with wasm exception handling
set -e

NODE=${NODE:-node}
BENCHES="fib:34 nbody:1000000 mandelbrot:1500 spectralnorm:1000 fannkuch:10"
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
  min=999
  for _ in 1 2 3; do
    t=$("$@" 2>/dev/null | cut -d, -f4)
    [ -n "$t" ] && awk "BEGIN{exit !($t<$min)}" && min=$t
  done
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
