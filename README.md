# lua.wasm

**Embeddable Lua 5.4 for WebAssembly — the reference interpreter plus ahead-of-time compilation, in one artifact.**

lua.wasm is [PUC-Rio Lua](https://www.lua.org) 5.4.8 built to run inside a WebAssembly host: the stock interpreter for code that arrives at runtime, an ahead-of-time (AOT) compiler for the Lua you already know at build time, and a single `.wasm` module you embed. If you have a wasm host and need a Lua VM in it, this is built for you.

## Why you'd want it

There is no LuaJIT for WebAssembly, and there can't be one as it stands: wasm forbids runtime code generation (no JIT), and LuaJIT's interpreter is hand-written per-architecture assembly with no wasm backend (no fallback). Every Lua-in-wasm is therefore interpreter-class. lua.wasm owns that instead of hiding it, and adds one thing back:

- **Interpreter for dynamic code.** Code that arrives at runtime runs on the stock, well-maintained Lua 5.4 interpreter.
- **AOT for static code.** Modules known when the artifact is built are compiled ahead of time to C by `luaot` and linked in. The speedup belongs to **numeric loops** — up to ~2.6–3.3× over the interpreter, in wasm, on that class — and to it only: game-shaped code (entity-table walks, string building, closure churn) measures ~1×, because its cost is in tables, allocation, and GC, which AOT does not touch. Both classes are measured; the numbers and the runs that produced them are in [`experiments/RESULTS.md`](experiments/RESULTS.md).

And it aims to be a good citizen of a wasm host:

- **One artifact.** One build produces one `.wasm` module, not a constellation of glue files. (AOT modules link statically, so the artifact is per-consumer; what ships is the reproducible pipeline plus a default artifact with nothing baked in.)
- **Plain clang / WASI. No Emscripten.** Lua is portable C and needs no platform emulator. Error handling rides the WebAssembly exception-handling proposal — the artifact compiles as C++ to reach it — so there's no setjmp/longjmp emulator in the way.
- **The VM never blocks.** The host calls in and always gets control back. A long-lived program (a game's main loop) runs as a Lua coroutine that yields once per frame — no threads, no SharedArrayBuffer, no Asyncify.
- **Not a dialect.** It tracks Lua 5.4.8 and stays bit-compatible with upstream. Language changes are out of scope.

## Where it stands

lua.wasm is honest about maturity, so you can trust what it claims.

- **Solid today (verified here):** the native interpreter runs the **full official Lua 5.4 test suite** under the ltests-instrumented build — checked allocator, internal assertions, the C-API battery — passing cleanly. The native `luaot` compiler builds and produces working AOT modules.
- **CI-enforced (re-witnessed on every change** by [`.github/workflows/witness.yml`](.github/workflows/witness.yml)**):** the vendored core is verbatim stock 5.4.8 outside the five declared files (`scripts/verify-stock.sh`); the native ltests-instrumented interpreter passes the **full** official suite — the C-API `testC` battery included, with `tests/libs` built and zero skips; the wasm interpreter passes the **full official suite on two engines** — wasmtime (the first non-V8 engine to run lua.wasm) and Node 24.15+ (V8, default-on exnref) — plus the suite-prefix witness **in three real browser engines** — Chromium (V8 as browsers ship it), Firefox 151 (SpiderMonkey), and WebKit 26.5 (JSC family) — driven via Playwright by `scripts/browser-witness.mjs`, which refuses to report a pass unless the page truly ran in the named engine; the embeddable reactor passes its host-interface witness (`scripts/embed-demo.mjs`) and a 12-check stress battery (`scripts/reactor-stress.mjs`: contained stack overflow, mid-flight program death and replacement, a 50k-frame pump, GC under allocation pressure); and the link-Lua-in consumer shape passes both its witnesses (`examples/embed/`) — a plain-C downstream driving an AOT-compiled module and catching a Lua error across the wasm-EH boundary, plus a C++ downstream catching its own **typed** exception through a real wasm-EH libc++abi with the bundled shim suppressed (`WASM_EH=external`).
- **Witnessed on demand and on every release tag (**[`deep-witness.yml`](.github/workflows/deep-witness.yml)**), all green as of 2026-07-07:** the full-suite AOT build (1.2M lines of generated C, a standard runner suffices) with the AOT/interpreter differential reporting **`AGREED`** — byte-identical suite output between compiled and interpreted Lua across every suite file, `gc.lua` and `big.lua` now included, with one documented structural exclusion (`scripts/differential.sh`: string-literal address identity, a memory optimization upstream's own dump/load path also fails — not observable by programs); the same build on plain llvm.org clang-20 with Makefile defaults; and the benchmark matrix. These re-run when dispatched and on every release tag, not on every push — the heavy tier is deliberate, not continuous.
- **A host-crash on old V8, resolved by engine version:** an external bring-up audit (love-wasi, 2026-07-05, against pin `945f810`) found the suite's to-be-closed/coroutine region **segfaulting the host process** on Node 22. Cross-checking against wasmtime and Chromium 141 shows it to be a V8 12.x-era engine defect (both its EH paths), fixed in current V8: the same artifact and test pass clean there. The artifact was never at fault. Engines in that window (Node 22/23) remain exposed — current Node 22 LTS (22.22.2) now *compiles* the artifact and still crashes the same way (re-witnessed 2026-07-06). Separately, Node 24.0–24.14 refuse the standardized encoding without `--experimental-wasm-exnref`; 24.15 is the first to take it by default, so the floor is stated precisely as **Node ≥ 24.15**. Full triage in [`doc/wasm-audit-2026-07-05.md`](doc/wasm-audit-2026-07-05.md) and its 2026-07-06 addendum.
- **Measured once, not continuously:** the performance numbers come from a specific run recorded in `RESULTS.md`, not an automated benchmark on every change.

Every claimed path is now witnessed: the interpreter paths (native, wasmtime, Node, browser, reactor) and the vendored-core provenance continuously on every change; the AOT paths by green dispatch runs on record.

## Build and run

Toolchain: **clang 20+** with a wasi-libc sysroot (the standardized wasm-EH encoding needs LLVM 20; `zig c++` works as a self-contained clang-20+ — recipe in the Makefile). clang 18/19 can still build the pre-standard encoding via `WASM_EH_ENCODING=legacy`, at the cost of every non-V8 runtime. Running the artifact needs a WASI host with wasm exception handling — **Node ≥ 24.15** (24.0–24.14 only with `--experimental-wasm-exnref`), a current browser, or **wasmtime** (`scripts/wasmtime-run.py`).

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

Errors never unwind into the host, and no call blocks. [`scripts/embed-demo.mjs`](scripts/embed-demo.mjs) is the reference host and the witness for the whole interface; [`scripts/reactor-stress.mjs`](scripts/reactor-stress.mjs) is its adversarial counterpart (contained stack overflow, mid-flight death and replacement, 50k-frame pump, GC pressure). Both run in CI.

That is one consumer shape — a host *wrapping* the finished module. The other is a **C/C++ project targeting wasm32-wasi that links Lua *in***, driving it through `lua.h` inside its own artifact (the shape love-wasm uses). [`doc/embedding.md`](doc/embedding.md) is the contract for it — the flag requirements, the source-drop and `make liblua.a` paths, the internal-vs-external exception runtime, and how `luaot`-compiled modules link in. [`examples/embed/`](examples/embed/) is the worked, CI-run witness: a plain-C downstream that links Lua in, drives an AOT-compiled module, and catches a Lua error across the boundary.

## Lineage

Built on [PUC-Rio's Lua](https://www.lua.org) and [Hugo Musso Gualandi's lua-aot](https://github.com/hugomg/lua-aot-5.4), a research AOT compiler for Lua 5.4. lua.wasm carries that prototype toward a maintained, WebAssembly-targeting artifact — credited, not tracked: it defers to no living upstream and pins to no floating version.
