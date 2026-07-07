#!/bin/sh
# Build the embed example for wasm32-wasi via issue #11's recommended
# source-drop path: the downstream (embed.c), its AOT-compiled module
# (game.lua -> aot_game.c), and onelua.c all compile in one build under
# the flag contract documented in doc/embedding.md.
#
# Env knobs:
#   WASM_CXX      wasm C++ driver (default clang++-20). Hosts without a
#                 packaged clang 20:  WASM_CXX="python3 -m ziglang c++"
#   WASM_SYSROOT  sysroot (default /usr; set empty for zig's bundled one)
#   OUT           output file (default embed.wasm)
#   RUN           runner (default: node ../../scripts/wasm-run.mjs); needs
#                 Node >= 24.15 for default-on exnref. Set RUN=: to build only.
#   WASM_EXTRA    extra flags for the driver. The zig c++ driver needs
#                 WASM_EXTRA="-Xclang -target-feature -Xclang +exception-handling"
set -eu
cd "$(dirname "$0")"
ROOT=../..
WASM_CXX="${WASM_CXX:-clang++-20}"
WASM_SYSROOT="${WASM_SYSROOT-/usr}"
WASM_EXTRA="${WASM_EXTRA:-}"
OUT="${OUT:-embed.wasm}"

# 1. Host tool: luaot turns Lua into C. Built natively for the build machine.
make -C "$ROOT/src" guess >/dev/null

# 2. AOT-compile the downstream's Lua module.
"$ROOT/src/luaot" game.lua -o aot_game.c -m aot_game

# 3. Link Lua in (the flag contract; see doc/embedding.md):
#    -DMAKE_LIB           core + libraries, NO luaw_* reactor glue
#    -DLUA_AOT            internal symbols linkable so the AOT module binds
#    -fwasm-exceptions    Lua errors unwind via wasm-EH...
#    onelua.c as C++      ...so onelua.c takes its C++ EH path (the C
#                         setjmp/longjmp route is blocked upstream, #18);
#                         the downstream itself stays plain C.
#    -nostdlib++          onelua.c's bundled catch(...)-only micro-runtime
#                         supplies the EH ABI (internal-EH default).
sysroot_flag=""
[ -n "$WASM_SYSROOT" ] && sysroot_flag="--sysroot=$WASM_SYSROOT"
# shellcheck disable=SC2086
$WASM_CXX $WASM_EXTRA \
  --target=wasm32-wasi $sysroot_flag -O2 -fno-strict-aliasing \
  -fwasm-exceptions -nostdlib++ -mllvm -wasm-use-legacy-eh=false \
  -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS \
  -DLUA_USE_JUMPTABLE=0 -DMAKE_LIB -DLUA_AOT \
  -I"$ROOT/src/wasi" -I"$ROOT/src" \
  -Wl,-z,stack-size=8388608 \
  -x c++ "$ROOT/src/onelua.c" \
  -x c aot_game.c embed.c \
  -lwasi-emulated-signal -lwasi-emulated-process-clocks \
  -o "$OUT"
echo "built $OUT"

# 4. Run it (a WASI command; Node >= 24.15). Expect: EMBED WITNESS OK
RUN="${RUN:-node $ROOT/scripts/wasm-run.mjs}"
# shellcheck disable=SC2086
exec $RUN "$OUT"
