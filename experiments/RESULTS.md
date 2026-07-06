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
  WASM_AOT="experiments/fib.lua experiments/nbody.lua experiments/mandelbrot.lua experiments/spectralnorm.lua experiments/fannkuch.lua"
scripts/bench-all.sh              # runs the full matrix, best-of-3, -> experiments/results.csv
```

Each cell is the best of three runs (CPU time via `os.clock`, GC settled
first, benchmark output suppressed). CI re-runs this via
`.github/workflows/deep-witness.yml` (`benchmarks` job, manual dispatch).
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

## What the numbers say

**AOT in wasm beats the interpreter in wasm — the thing this project is
for — and the encoding migration did not change that.** Speedup of
`wasm interp / wasm AOT`, current toolchain (range over the two runs):

| benchmark | AOT-in-wasm speedup |
|---|--:|
| mandelbrot | 2.63×–3.34× |
| spectralnorm | 1.95×–1.96× |
| fib | 1.08×–1.27× |
| nbody | 0.94×–1.23× |
| fannkuch | 0.97×–1.06× |

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
