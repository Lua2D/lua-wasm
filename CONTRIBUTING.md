# Contributing to lua.wasm

This is the human-facing companion to [`AGENTS.md`](AGENTS.md), the working
agreement that governs how work is planned, done, reviewed, and integrated
here. This file gets you building and running the witnesses; AGENTS.md is the
contract — where the two could ever disagree, AGENTS.md wins.

## Build

Native (interpreter and compiler):

```bash
make guess                 # -> src/lua, src/luac
make lua-debug             # -> lua-debug, the ltests-instrumented witness build
```

WebAssembly — needs **clang 20+** with a wasi-libc sysroot (the standardized
wasm-EH encoding needs LLVM 20; no Ubuntu package — use llvm.org apt, or
`zig c++`, a self-contained clang-20+ driver; exact recipes in the Makefile
header):

```bash
make wasm                                 # -> lua.wasm
```

Running the artifact needs a WASI host with wasm exception handling:
**Node ≥ 24.15**, a current browser, or wasmtime.

## Run the witnesses

A change is not done because it compiles; it is done when the witnesses that
cover it are green. From cheapest to heaviest:

```bash
# the deepest witness: full official suite on the ltests build
# (C-API battery needs tests/libs built; stdin must be non-seekable)
make -C tests/libs LUA_DIR=../../src
cd tests && : | ../lua-debug all.lua          # expect 'final OK !!!', zero 'testC not active'

# the wasm artifact, both engines
cd tests && node ../scripts/wasm-run.mjs ../lua.wasm -e"_port=true" all.lua
cd tests && python3 ../scripts/wasmtime-run.py ../lua.wasm -e"_port=true" all.lua
```

CI runs these for you: [`witness.yml`](.github/workflows/witness.yml) on every
pull request and on push to `main` (suite on native + two wasm engines +
Chromium, the embed witnesses, provenance), [`deep-witness.yml`](.github/workflows/deep-witness.yml)
on demand and on every release tag (plain clang-20). A red witness blocks
the merge.

## How work flows

Work runs **align → execute → verify** in passes, each pass either code or
docs, never both — [`AGENTS.md`](AGENTS.md) defines the loop, the roles, and
the review that ends every pass. The practical points:

- **`main` is never committed to directly.** Development happens on a working
  branch; it reaches `main` by pull request as a recorded merge.
- **The last pass before a merge is a doc pass**, so documentation on `main`
  never lags the code.
- **Claims need evidence.** The README states what *is*; wants and hypotheses
  live in the issue tracker, each graded by type, strength, and durability
  (the scales are in AGENTS.md). Don't write a claim the evidence can't
  carry — file an issue instead.
- **Witnesses fail loudly or they're bugs.** A harness that can weaken
  silently (a skipped file, a default swallowed, a sentinel value in a CSV)
  is treated as a correctness defect in its own right.
