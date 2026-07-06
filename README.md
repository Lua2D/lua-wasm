# lua-wasm

**Embeddable Lua 5.4 for WebAssembly — the reference interpreter plus ahead-of-time compilation, in one artifact.**

lua-wasm is [PUC-Rio Lua](https://www.lua.org) 5.4.8 built to run inside a WebAssembly host: the stock interpreter for code that arrives at runtime, an ahead-of-time (AOT) compiler for the Lua you already know at build time, and a single `.wasm` module you embed. If you have a wasm host and need a Lua VM in it, this is built for you.

## Why you'd want it

There is no LuaJIT for WebAssembly, and there can't be one as it stands: wasm forbids runtime code generation (no JIT), and LuaJIT's interpreter is hand-written per-architecture assembly with no wasm backend (no fallback). Every Lua-in-wasm is therefore interpreter-class. lua-wasm owns that instead of hiding it, and adds one thing back:

- **Interpreter for dynamic code.** Code that arrives at runtime runs on the stock, well-maintained Lua 5.4 interpreter.
- **AOT for static code.** Modules known when the artifact is built are compiled ahead of time to C by `luaot` and linked in — measurably faster on numeric loops (up to ~2.8× over the interpreter, in wasm, on the benchmark set; gains vary by workload). The numbers and the run that produced them are in [`experiments/RESULTS.md`](experiments/RESULTS.md).

And it aims to be a good citizen of a wasm host:

- **One artifact.** One build produces one `.wasm` module, not a constellation of glue files. (AOT modules link statically, so the artifact is per-consumer; what ships is the reproducible pipeline plus a default artifact with nothing baked in.)
- **Plain clang / WASI. No Emscripten.** Lua is portable C and needs no platform emulator. Error handling rides the WebAssembly exception-handling proposal — the artifact compiles as C++ to reach it — so there's no setjmp/longjmp emulator in the way.
- **The VM never blocks.** The host calls in and always gets control back. A long-lived program (a game's main loop) runs as a Lua coroutine that yields once per frame — no threads, no SharedArrayBuffer, no Asyncify.
- **Not a dialect.** It tracks Lua 5.4.8 and stays bit-compatible with upstream. Language changes are out of scope.

## Where it stands

lua-wasm is honest about maturity, so you can trust what it claims.

- **Solid today (verified here):** the native interpreter runs the **full official Lua 5.4 test suite** under the ltests-instrumented build — checked allocator, internal assertions, the C-API battery — passing cleanly. The native `luaot` compiler builds and produces working AOT modules.
- **CI-enforced (re-witnessed on every change** by [`.github/workflows/witness.yml`](.github/workflows/witness.yml)**):** the native ltests-instrumented interpreter passes the official suite; the wasm interpreter passes the **full official suite on two engines** — wasmtime (the first non-V8 engine to run lua-wasm) and Node 24 (V8, stable exnref); the embeddable reactor passes its host-interface witness (`scripts/embed-demo.mjs`).
- **Witnessed by script, not in CI:** the suite-prefix witness in a real Chromium (V8 14.1, via love-wasi's browser harness). AOT-in-wasm and the AOT/interpreter differential check remain witnessed by hand on the maintainer's machine.
- **A host-crash on old V8, resolved by engine version:** an external bring-up audit (love-wasi, 2026-07-05, against pin `945f810`) found the suite's to-be-closed/coroutine region **segfaulting the host process** on Node 22. Cross-checking against wasmtime and Chromium 141 shows it to be a V8 12.x-era engine defect (both its EH paths), fixed in current V8: the same artifact and test pass clean there. The artifact was never at fault. Engines in that window (Node 22/23) remain exposed; the README's Node ≥ 24 floor stands. Full triage in [`doc/wasm-audit-2026-07-05.md`](doc/wasm-audit-2026-07-05.md).
- **Measured once, not continuously:** the performance numbers come from a specific run recorded in `RESULTS.md`, not an automated benchmark on every change.

The native and wasm interpreter paths are under automated witness; the AOT-in-wasm paths are not yet.

## Build and run

Toolchain: **clang 20+** with a wasi-libc sysroot (the standardized wasm-EH encoding needs LLVM 20; `zig c++` works as a self-contained clang-20+ — recipe in the Makefile). clang 18/19 can still build the pre-standard encoding via `WASM_EH_ENCODING=legacy`, at the cost of every non-V8 runtime. Running the artifact needs a WASI host with wasm exception handling — **Node ≥ 24**, a current browser, or **wasmtime** (`scripts/wasmtime-run.py`).

```bash
make wasm                                 # -> lua.wasm (the interpreter, as wasm)
make wasm WASM_AOT="game.lua util.lua"    # -> lua.wasm + those modules AOT-compiled in
node scripts/wasm-run.mjs lua.wasm script.lua
```

An AOT module lands in `package.preload` as `aot_<name>`, so `require("aot_<name>")` runs it at AOT speed.

The native toolchain works as usual: `make guess` builds `src/lua`, `src/luac`, and the `src/luaot` compiler.

[`doc/wasm.md`](doc/wasm.md) is the operational reference for the wasm build: the `WASM_EH` exception-handling runtime knob (internal shim vs. an external libc++abi for embedders needing typed catches), running the official test suite under wasm (`_port=true`), and the sharp edges.

## Embed

`make wasm-lib` builds `lua-lib.wasm`, a wasm *reactor*: the host instantiates it, calls in, and always gets control back. The interface is WASI (stdio arrives as `fd_write`; hook fds 1 and 2 to capture `print`) plus these exports:

| export | contract |
| - | - |
| `luaw_init()` | create the VM (stdlib + any linked AOT modules); 0 on success |
| `luaw_alloc(n)` / `luaw_free(p)` | buffers for passing chunks in |
| `luaw_run(ptr, len, name)` | load + run a chunk to completion; returns a Lua status code (0 = ok) |
| `luaw_start(ptr, len, name)` | load a chunk as the resident program (a coroutine) |
| `luaw_step()` | resume it one step: `LUA_YIELD` (1) = alive, call again next frame; 0 = finished; else failed |
| `luaw_last_error()` | the last error message, or null; valid until the next entry call |

Errors never unwind into the host, and no call blocks. [`scripts/embed-demo.mjs`](scripts/embed-demo.mjs) is the reference host and the witness for the whole interface.

## Lineage

Built on [PUC-Rio's Lua](https://www.lua.org) and [Hugo Musso Gualandi's lua-aot](https://github.com/hugomg/lua-aot-5.4), a research AOT compiler for Lua 5.4. lua-wasm carries that prototype toward a maintained, WebAssembly-targeting artifact — credited, not tracked: it defers to no living upstream and pins to no floating version.
