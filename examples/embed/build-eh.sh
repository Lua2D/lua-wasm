#!/bin/sh
# Build and run the external-EH witness (issue #11): Lua with the bundled
# EH micro-shim suppressed (-DLUAW_EXTERNAL_EH), linked against a REAL
# libc++abi built with -fwasm-exceptions, plus a downstream (embed-eh.cpp)
# that throws and catches its own *typed* C++ exception.
#
# The interesting part is step 1. No distro ships a libc++abi built with
# wasm-EH -- zig's own bundled one isn't either (linking it leaves
# __cxa_throw/_Unwind_CallPersonality undefined; witnessed 2026-07-06).
# But zig SHIPS the LLVM runtime sources it builds libc++ from, so we
# compile them ourselves with -fwasm-exceptions: the EH-relevant libc++abi
# translation units plus libunwind's Unwind-wasm.c (the wasm-EH shim that
# provides _Unwind_CallPersonality/__wasm_lpad_context). Both key on
# __WASM_EXCEPTIONS__, which clang defines under -fwasm-exceptions.
# ~17 small objects, seconds to build. This is the same recipe Emscripten
# applies internally, done here for wasi.
#
# Env knobs:
#   ZIG          zig driver command (default: python3 -m ziglang)
#   ZIGLANG_LIB  zig's lib/ dir (default: located via the ziglang package)
#   OUT          output artifact (default embed-eh.wasm)
#   RUN          runner (default: node ../../scripts/wasm-run.mjs; Node>=24).
#                RUN=: builds only. wasmtime works too:
#                RUN="python3 ../../scripts/wasmtime-run.py"
set -eu
cd "$(dirname "$0")"
ROOT=../..
ZIG="${ZIG:-python3 -m ziglang}"
ZLIB="${ZIGLANG_LIB:-$(python3 -c "import ziglang, os; print(os.path.join(os.path.dirname(ziglang.__file__), 'lib'))")}"
OUT="${OUT:-embed-eh.wasm}"

# Target/EH flags shared by every compile here. The -Xclang pair is the
# zig-driver workaround from the Makefile's zig recipe; harmless elsewhere.
TF="--target=wasm32-wasi -O2 -fwasm-exceptions \
    -mllvm -wasm-use-legacy-eh=false \
    -Xclang -target-feature -Xclang +exception-handling"

# ── 1. the wasm-EH libc++abi, from zig's bundled LLVM runtime sources ──
# The EH-relevant TU set (typed matching lives in private_typeinfo.cpp);
# demangling is disabled (smaller, and terminate messages stay mangled),
# threads are off (wasi is single-threaded).
ABI_SRCS="abort_message cxa_aux_runtime cxa_default_handlers cxa_exception \
  cxa_exception_storage cxa_guard cxa_handlers cxa_personality cxa_vector \
  cxa_virtual fallback_malloc private_typeinfo stdlib_exception \
  stdlib_new_delete stdlib_stdexcept stdlib_typeinfo"
mkdir -p abi-build
for s in $ABI_SRCS; do
  # shellcheck disable=SC2086
  $ZIG c++ $TF -std=c++23 \
    -D_LIBCXXABI_BUILDING_LIBRARY -D_LIBCXXABI_HAS_NO_THREADS \
    -DLIBCXXABI_NON_DEMANGLING_TERMINATE -DNDEBUG \
    -I"$ZLIB/libcxxabi/include" -I"$ZLIB/libcxx/src" \
    -c "$ZLIB/libcxxabi/src/$s.cpp" -o "abi-build/$s.o"
done
# shellcheck disable=SC2086
$ZIG cc $TF \
  -D_LIBUNWIND_HAS_NO_THREADS -D_LIBUNWIND_HIDE_SYMBOLS \
  -I"$ZLIB/libunwind/include" -I"$ZLIB/libunwind/src" \
  -c "$ZLIB/libunwind/src/Unwind-wasm.c" -o abi-build/unwind_wasm.o
$ZIG ar rcs libcxxabi-eh.a abi-build/*.o
echo "built libcxxabi-eh.a (wasm-EH libc++abi from zig's bundled sources)"

# ── 2. the witness: Lua (shim suppressed) + typed downstream + real abi ──
# onelua.c as C++ per the flag contract (doc/embedding.md); -nostdlib++
# because the real runtime is supplied explicitly, not by the driver.
# shellcheck disable=SC2086
$ZIG c++ $TF -fno-strict-aliasing -nostdlib++ \
  -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS \
  -DLUA_USE_JUMPTABLE=0 -DMAKE_LIB -DLUAW_EXTERNAL_EH \
  -I"$ROOT/src/wasi" -I"$ROOT/src" \
  -Wl,-z,stack-size=8388608 \
  -x c++ "$ROOT/src/onelua.c" embed-eh.cpp -x none \
  libcxxabi-eh.a \
  -lwasi-emulated-signal -lwasi-emulated-process-clocks \
  -o "$OUT"

# ── 3. the fingerprint gate (same convention as the Makefile's) ──
# For THIS program a silent shim fallback already fails the link (typed
# catch sites need _Unwind_CallPersonality, which only the real runtime
# has); the fingerprint keeps the gate uniform with `make wasm
# WASM_EH=external` anyway.
grep -aq "libc++abi" "$OUT" \
  || { echo "FAIL: libc++abi fingerprint missing in $OUT" >&2; exit 1; }
echo "built $OUT (external EH confirmed: libc++abi fingerprint present)"

# ── 4. run it. Expect: EXTERNAL-EH WITNESS OK ──
RUN="${RUN:-node $ROOT/scripts/wasm-run.mjs}"
# shellcheck disable=SC2086
exec $RUN "$OUT"
