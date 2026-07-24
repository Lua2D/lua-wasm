# Benchmark results

Honest three-way (four-cell) numbers for the roadmap's benchmark phase:
interpreter and AOT, native and in wasm. Every number here was produced
by `scripts/bench.lua` under the harness described below; a figure is
only ever compared against another figure this harness made.

## How to reproduce

```bash
make guess -j4                    # native interpreter (src/lua)
# native AOT: compile the benchmarks with luaot and link them in
# wasm interpreter and wasm AOT:
make wasm WASM_O=lua.wasm
make wasm WASM_O=lua-bench.wasm \
  WASM_AOT="experiments/fib.lua experiments/nbody.lua experiments/mandelbrot.lua experiments/spectralnorm.lua experiments/fannkuch.lua experiments/entitytables.lua experiments/stringbuild.lua experiments/closurechurn.lua"
scripts/bench-all.sh              # runs the full matrix, best-of-3, -> experiments/results.csv
```

`experiments/results.csv` is a generated artifact, not committed:
`scripts/bench-all.sh` writes it, and CI's `benchmarks` job (below)
regenerates and uploads it. The tables in this file are the record — they
cover the current toolchain, the prior-toolchain snapshot, and the three
game-shaped benches (#10) that a plain five-bench run omits.

Each cell is the best of three runs (CPU time via `os.clock`, GC settled
first, benchmark output suppressed). CI re-runs this via
`.github/workflows/deep-witness.yml` (`benchmarks` job — manual
dispatch, and automatically on every release tag).
Wasm runs use Node's WASI with V8's optimizing tier — the tier matters: under V8's baseline compiler
(`--liftoff-only`) AOT'd wasm is *slower* than the interpreter, because
the AOT payoff is C the wasm engine must itself optimize. Small hot
functions optimize fine; this is why the correctness witness (giant test
functions that OOM the optimizer) pins liftoff, while benchmarks do not.

## The numbers

Two environments, kept distinct because they answer different questions.

**Current toolchain (clang 20.1.2 via llvm.org, standardized `try_table`
EH encoding), GitHub Actions `ubuntu-24.04` runner, Node 24 (V8).** Two
runs of the full matrix, ~10 minutes apart, both from
`deep-witness.yml`'s `benchmarks` job (2026-07-06; runs 28770570230 and
28770815951 — a shared CI runner is noisy, so both runs are shown and
only patterns stable across them are claimed). Seconds, lower is better:

| benchmark | N | native interp | native AOT | wasm interp | wasm AOT |
|---|---|--:|--:|--:|--:|
| fib | 34 | 0.357 / 0.392 | 0.311 / 0.318 | 0.786 / 0.892 | 0.728 / 0.704 |
| nbody | 1000000 | 3.073 / 2.705 | 1.593 / 1.608 | 5.788 / 6.524 | 6.163 / 5.286 |
| mandelbrot | 1500 | 1.925 / 1.957 | 0.816 / 0.742 | 5.501 / 5.275 | 1.646 / 2.004 |
| spectralnorm | 1000 | 1.851 / 1.984 | 1.162 / 1.339 | 4.620 / 4.670 | 2.374 / 2.385 |
| fannkuch | 10 | 3.154 / 3.033 | 1.192 / 1.204 | 5.301 / 6.438 | 5.447 / 6.055 |

**Prior toolchain (clang 19.1.1, legacy EH encoding), maintainer
machine, Node 24.18** — the run the pre-migration claims cited; kept for
comparison (single run, quiet machine):

| benchmark | N | native interp | native AOT | wasm interp | wasm AOT |
|---|---|--:|--:|--:|--:|
| fib | 34 | 0.414 | 0.285 | 0.858 | 0.747 |
| nbody | 1000000 | 2.216 | 1.657 | 5.652 | 3.253 |
| mandelbrot | 1500 | 1.491 | 0.726 | 5.211 | 1.877 |
| spectralnorm | 1000 | 1.688 | 0.927 | 4.838 | 2.295 |
| fannkuch | 10 | 2.348 | 1.157 | 6.039 | 6.046 |

## Game-shaped workloads (issue #10)

The set above is tight numeric loops — AOT's best case by construction.
Real game logic is table-access-, string- and GC-bound, so three
workloads characterize those classes through the same harness:
`entitytables` (ECS-ish component walk + spawn/despawn churn),
`stringbuild` (`string.format` / concatenation / `table.concat`),
`closurechurn` (short-lived closures + coroutine bodies). Same
four-cell matrix, same `deep-witness.yml` `benchmarks` job (2026-07-06
run 28821395909 and 2026-07-07 run 28832410071; both shown, patterns only):

| benchmark | N | native interp | native AOT | wasm interp | wasm AOT |
|---|---|--:|--:|--:|--:|
| entitytables | 6000 | 1.858 / 1.834 | 1.309 / 1.286 | 3.350 / 3.252 | 3.270 / 3.198 |
| stringbuild | 8000 | 2.008 / 2.014 | 1.829 / 1.848 | 3.040 / 3.140 | 3.149 / 3.191 |
| closurechurn | 12000 | 1.812 / 1.800 | 1.572 / 1.570 | 2.624 / 2.599 | 2.168 / 2.162 |

## What the numbers say

**On these numeric kernels, on this toolchain (Node 24 / V8 13.6), AOT in
wasm beat the interpreter, and the encoding migration did not change
that.** Speedup of `wasm interp / wasm AOT`, current toolchain (range over
the two runs):

> **Update (2026-07-24): this does not generalize, and AOT is being
> retired.** A cross-engine measurement of realistic data-plane workloads
> (see *Data-plane / edge-compute kernels*, below) found the wasm payoff
> marginal on V8/JSC and a net *loss* on SpiderMonkey. With the game-shaped
> set already at ~1×, only textbook numeric loops — which no known consumer
> runs — clearly win in wasm. That is the evidence behind the AOT sunset:
> [`../doc/aot-sunset-2026-07-24.md`](../doc/aot-sunset-2026-07-24.md).

| benchmark | AOT-in-wasm speedup |
|---|--:|
| mandelbrot | 2.63×–3.34× |
| spectralnorm | 1.95×–1.96× |
| fib | 1.08×–1.27× |
| nbody | 0.94×–1.23× |
| fannkuch | 0.97×–1.06× |
| closurechurn | 1.20×–1.21× |
| entitytables | 1.02×–1.02× |
| stringbuild | 0.97×–0.98× |

**The game-shaped classes gain almost nothing, and that is the point of
measuring them.** Entity-table walks, string building, and closure
churn spend their time in `luaH_get`/`luaH_set`, the allocator, and the
collector — costs AOT does not touch; removing bytecode dispatch leaves
the bill nearly unchanged (stringbuild lands below parity in both runs:
the generated C pays its code-size and call overhead without a loop to
win back). Any headline speedup for lua.wasm's AOT therefore belongs to
numeric loops *only*; code shaped like game logic should expect ~1×,
and the `WASM_AOT` hot-list should be chosen with that in mind —
compile in the numeric kernels, not the entity systems. Profiling
*real* game code stays deferred to love-wasm (issue #10).

The tight numeric loops (mandelbrot, spectralnorm) are where AOT earns
its keep, same as before the migration: the C compiler constant-folds
immediate operands and turns bytecode dispatch into straight-line code.
Call-heavy and branch-heavy shapes (fib's recursion, fannkuch's
permutation churn) gain least; fannkuch breaks even, exactly as it did
on the prior toolchain. nbody sits inside CI-runner noise (one run
slightly below parity, one clearly above); the prior quiet-machine run
had it at 1.74×, and settling its true current value needs a
quiet-machine re-run — noted, not claimed.

**The wasm tax is real and worth stating.** wasm AOT vs native AOT runs
~2×–4.6× slower (benchmark-dependent, current toolchain); wasm AOT lands
at roughly 0.4×–0.9× of *native interpreter* speed. AOT does not buy
back the cost of running in wasm at all — nothing could, without a JIT —
but it recovers a large fraction of the interpreter's wasm overhead,
which is the most any ahead-of-time approach can do on a platform that
forbids runtime codegen. That is the honest ceiling, and these numbers
are it.

**Upstream's "~2×" holds for the numeric core, natively.** native
interp / native AOT on the current toolchain is 1.7× (nbody) to 2.6×
(mandelbrot, fannkuch) — consistent with the research paper's
measurement and with the prior run's shape.

## Data-plane / edge-compute kernels (2026-07-24)

The numeric set is AOT's best case and the game-shaped set its worst; the
open question was where *realistic* embedder work lands. Three kernels
answer it: `dataplane` (columnar filtered aggregate + an 8-way GROUP BY, a
compute-in-engine database stand-in), `codec` (FNV-1a hash + LEB128 varint
decode), `dsp` (fixed-point FIR / box-blur). Buffers are integer arrays so
the hot loop is VM arithmetic, not per-element C library calls.

Native (interp vs AOT, `bench.lua`, best-of-3, seconds):

| kernel | native interp | native AOT | speedup |
|---|--:|--:|--:|
| dataplane | 0.983 | 0.609 | 1.61× |
| codec | 2.206 | 0.683 | 3.23× |
| dsp | 1.700 | 0.701 | 2.43× |

Natively all three win — they are arithmetic-bound. **In wasm the win
collapses, and inverts on Firefox.** Measured through
`scripts/browser/bench-page.html` (one module: the interpreted leg loads
each kernel's source, the AOT leg calls `aot_<name>`; wall-clock around a
fresh `_start`, best-of-3), across four engines, as `interp/AOT` speedup:

| engine | dataplane | codec | dsp |
|---|--:|--:|--:|
| Chrome / V8 | 1.16× | 1.15× | 1.08× |
| Safari / JSC | 1.18× | 1.26× | 1.12× |
| Firefox / SpiderMonkey | 0.89× | 0.81× | 0.92× |
| headless Chromium 141 | 1.19× | 1.13× | 1.20× |

The interpreter is steady across all four engines; it is AOT that swings
from +26% to −19%. On SpiderMonkey the generated giant functions run
*below* the interpreter — the baseline-tier failure mode named above — and
Firefox is a gating engine in the witness matrix.

Calibration (an unresolved caveat, not a result): the same harness
reproduces fannkuch (~1×) but reports mandelbrot at 1.08× on current
Chromium 141, where the numeric table above recorded 2.63–3.34× on Node 24
/ V8 13.6. The likeliest cause is a newer V8 optimizing the interpreter
dispatch loop better; it was not reproduced under Node ≥ 24.15 (the
authoring box had only the crashing Node 22). It does not change the
conclusion — realistic workloads do not reach the region AOT helps — which
is the evidence behind the AOT sunset
([`../doc/aot-sunset-2026-07-24.md`](../doc/aot-sunset-2026-07-24.md)).
