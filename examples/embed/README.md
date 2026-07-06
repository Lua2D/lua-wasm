# Embed example — linking Lua into a wasm32-wasi artifact

The minimal downstream for issue #11's second consumer shape: a program that
links the Lua core **into its own** wasm32-wasi module and drives it through
`lua.h`, rather than wrapping the finished `lua.wasm`.

It proves the two guarantees the embed contract must hold:

1. **AOT composition** — `game.lua` is AOT-compiled by `src/luaot` and linked
   in; `embed.c` requires it and calls `game.add(2,3)`, so AOT-generated code
   binds correctly against the embedded core.
2. **Error unwinding across the boundary** — `game.boom()` raises a Lua
   `error()` inside that AOT-compiled module; `embed.c` catches it as a
   `lua_pcall` status with the message intact. In the wasm target this exercises
   the wasm-EH machinery.

## Files

| file | role |
| - | - |
| `game.lua` | a stand-in downstream module, AOT-compiled into the artifact |
| `embed.c` | the downstream — plain C, public API only, no `luaw_*` reactor glue |
| `build.sh` | source-drop build under the flag contract, then runs the witness |

## Build & run

```bash
# packaged clang 20:
./build.sh

# hosts without one (zig carries its own clang-20 + wasi sysroot):
WASM_CXX="python3 -m ziglang c++" WASM_SYSROOT= \
  WASM_EXTRA="-Xclang -target-feature -Xclang +exception-handling" ./build.sh
```

Expected last line: `EMBED WITNESS OK`. Running needs Node ≥ 24 (stable
exnref); `RUN=…` overrides the runner, `RUN=:` builds only.

The full flag contract, the `liblua.a` convenience path, and the
external-EH (typed-catch) mode are documented in
[`doc/embedding.md`](../../doc/embedding.md). This example is the internal-EH,
source-drop path; CI runs it as the `embed` job.
