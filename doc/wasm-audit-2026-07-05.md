# wasm audit — love-wasi bring-up, 2026-07-05

Record of an external audit of the wasm build, produced while bringing lua-wasm
up as the Lua VM for [love-wasi](https://github.com/andy-emerson/love-wasi).
Filed against this repo at pin `945f810`. The original lives in that repo at
`wasi/lua/AUDIT-lua-wasm.md`, alongside the build recipes and witnesses it
cites; this file is the in-tree record and tracks each finding's disposition.

**Provenance.** The audit was a **by-hand, single-engine** report (Node 22 /
V8 12.4, plus a wasmtime attempt blocked by the encoding). The dispositions
below add the cross-engine evidence the audit could not reach: wasmtime 36 and
Chromium 141 (V8 14.1), run scripted against this pin (toolchain: `zig c++` /
clang 20.1.2, via the Makefile recipe in `doc/wasm.md`).

## Findings and disposition

| # | Finding | Disposition |
| - | - | - |
| 1 | `locals.lua` (`<close>` / coroutine region) segfaults the **host** under the wasm build on Node 22; isolation matrix pins it to the engine, not the reporter's toolchain | **Root-caused: V8 12.x-era engine defect, fixed upstream.** The same artifact and detonation sequence pass on wasmtime 36 (full suite, `final OK`) and Chromium 141 — and Node 22 crashes on *both* its EH paths (legacy and its then-experimental exnref). The artifact was never at fault. Disposition: Node ≥ 24 floor (already the README's); old-V8 hosts (Node 22/23) remain exposed by their engine, which no lua-wasm change can fix. Portable one-file repro: `scripts/suite-bundle.py`. |
| 2 | Artifact used the **legacy** wasm-EH encoding; wasmtime rejects it — only browsers/Node could run it | **Done.** Default is now the standardized `try_table`/`exnref` encoding (`WASM_EH_ENCODING=standard`, clang 20+), witnessed: wasmtime runs the full official suite (first non-V8 engine to run lua-wasm), Chromium 141 passes the suite-prefix witness. `legacy` remains a documented bridge knob for clang 18/19. |
| 3 | `LUAW_EXTERNAL_EH` did not exist: embedders needing typed C++ catches could not suppress the bundled `catch(...)` micro-runtime | **Done.** Guard added in `src/onelua.c`; wired to the `WASM_EH=external` Makefile knob. |
| 4 | The micro-shim wins **silently** — linking a real libc++abi without the guard raises no error, leaving you on `catch(...)` semantics unknowingly | **Mitigated.** `WASM_EH=external` removes the shim (missing runtime → link error) and the `wasm` target runs a post-build libc++abi fingerprint check. Documented in `doc/wasm.md`. |
| 5 | Smaller items: no documented way to run the suite under wasm (`_port=true` is required — WASI has no shell); Makefile EH-runtime had no knob; `-e<src>` attached form needed when a chunk starts with `--` | **Done.** All documented in `doc/wasm.md`; the `WASM_EH` knob is implemented in the Makefile. (`WASM_CLANGXX`/`WASM_SYSROOT` were already command-line overridable; the Makefile now says so.) |

## The crash triage in full (finding 1)

The audit's isolation matrix ruled out everything above the engine but had only
one engine to test. The missing cross-checks, run here:

| host | engine | encoding | suite-prefix detonation | full suite |
| - | - | - | - | - |
| native | — | — | pass | pass (ltests, port mode, `final OK`) |
| wasmtime 36 | Cranelift | standard | pass | **pass (`final OK !!!`)** |
| Chromium 141 | V8 14.1 (exnref stable) | standard | pass | not run (stdio-only browser shim) |
| Chromium 141 | V8 14.1 (legacy path) | legacy | pass | not run (same) |
| Node 22 | V8 12.4 (`--experimental-wasm-exnref`) | standard | **host SIGSEGV** | **host SIGSEGV** |
| Node 22 | V8 12.4 (legacy path) | legacy | (audit) **host SIGSEGV** | (audit) **host SIGSEGV** |

Reading: only V8 12.4 crashes, and it crashes on both of its EH paths; the same
module is clean on Cranelift and on V8 14.1 (both paths). That is an engine
defect of that V8 generation, since fixed. No V8 bug to file — it no longer
reproduces on current V8.

The detonation is position-sensitive (the corruption is planted by earlier
suite files and trips in `locals.lua`), so the witness must execute the whole
prefix in order: `scripts/suite-bundle.py` generates a single fs-free script
that does exactly that — it passes native/wasmtime/Chromium and still SIGSEGVs
Node 22, making it the portable repro for any engine question of this shape.

## What the audit confirmed working (recorded for balance)

With love-wasi's own toolchain (clang 18.1.3, self-built wasi-libc sysroot,
wasm-EH libc++abi, `LUAW_EXTERNAL_EH`): a 9/9 step-1 witness on Node and
headless Chromium (pcall/error through a real libc++abi, coroutine error
containment, yield/resume, 5.4 integer semantics, string.pack, GC cycle); the
`MAKE_LIB` reactor passed a 12-check stress battery (contained stack overflow,
table error objects, resident-program replacement, a 50k-frame pump, GC under
load); and suite files `main.lua` (port mode), `gc.lua`, `db.lua`, `calls.lua`,
`strings.lua`, `literals.lua`, `tpack.lua`, `attrib.lua` ran clean before the
`locals.lua` crash point.

## Still open

- **CI witness** — the audit's standing recommendation: run the suite under the
  wasm build in CI (wasmtime + Node) so these claims are re-witnessed on every
  change rather than scripted-but-manual. Already an open goal in the README.
- **Plain clang-20 witness** — the standardized-encoding build is witnessed via
  `zig c++` (clang 20.1.2). Plain `clang++-20` uses the same flags and backend
  and is expected identical, but has not been independently run here.
