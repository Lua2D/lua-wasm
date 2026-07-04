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
first, benchmark output suppressed). Wasm runs use Node's WASI with V8's
optimizing tier — the tier matters: under V8's baseline compiler
(`--liftoff-only`) AOT'd wasm is *slower* than the interpreter, because
the AOT payoff is C the wasm engine must itself optimize. Small hot
functions optimize fine; this is why the correctness witness (giant test
functions that OOM the optimizer) pins liftoff, while benchmarks do not.

## The numbers

Environment: x86-64, Lua 5.4.8, clang 19.1.1 (wasm32-wasi,
-fno-strict-aliasing), Node 24.18 (V8). Seconds, lower is better.

| benchmark | N | native interp | native AOT | wasm interp | wasm AOT |
|---|---|--:|--:|--:|--:|
| fib | 34 | 0.414 | 0.285 | 0.858 | 0.747 |
| nbody | 1000000 | 2.216 | 1.657 | 5.652 | 3.253 |
| mandelbrot | 1500 | 1.491 | 0.726 | 5.211 | 1.877 |
| spectralnorm | 1000 | 1.688 | 0.927 | 4.838 | 2.295 |
| fannkuch | 10 | 2.348 | 1.157 | 6.039 | 6.046 |

## What the numbers say

**AOT in wasm beats the interpreter in wasm — the thing this project is
for.** Speedup of `wasm interp / wasm AOT`:

| benchmark | AOT-in-wasm speedup |
|---|--:|
| mandelbrot | 2.78× |
| spectralnorm | 2.11× |
| nbody | 1.74× |
| fib | 1.15× |
| fannkuch | 1.00× |

The tight numeric loops (mandelbrot, spectralnorm, nbody) are where AOT
earns its keep: the C compiler constant-folds immediate operands and
turns bytecode dispatch into straight-line code. Call-heavy and
branch-heavy shapes (fib's recursion, fannkuch's permutation churn) gain
least — the dispatch luaot removes was a smaller fraction of their cost
to begin with, and on 5.4.8 fannkuch-in-wasm breaks even entirely. This
is the same profile upstream reported for native AOT, now confirmed to
survive the trip through wasm.

**The wasm tax is real and worth stating.** wasm AOT vs native AOT runs
2.0×–5.2× slower (benchmark-dependent); wasm AOT lands at 0.4×–0.8× of
*native interpreter* speed. So AOT does not buy back the cost of running
in wasm at all — nothing could, without a JIT — but it recovers a large
fraction of the interpreter's wasm overhead, which is the most any
ahead-of-time approach can do on a platform that forbids runtime
codegen. That is the honest ceiling, and these numbers are it.

**Upstream's "~2×" holds for the numeric core, natively.** native
interp / native AOT is 1.3× (nbody) to 2.1× (mandelbrot, fannkuch),
averaging near 2× on the loop-heavy benchmarks — consistent with the
research paper's measurement, now reproduced in-repo rather than cited.
Numbers above are the 5.4.8 rebase run; the 5.4.3-era run showed the
same shape.
