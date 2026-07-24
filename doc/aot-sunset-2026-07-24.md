# AOT sunset — the decision and its evidence (2026-07-24)

This records why lua.wasm is removing its ahead-of-time compiler, and the
measurements that decided it. `v0.1.0` is the last release that includes
AOT; `v0.2.0` removes it. This is a record, not a plan on the grid — the
removal work is tracked as its own issue.

## What AOT was

`luaot` (imported from [lua-aot-5.4](https://github.com/hugomg/lua-aot-5.4),
itself derived from PUC-Rio Lua's `luac.c`/`lvm.c`) compiles a Lua module
to C at build time; the C is linked into the artifact and the module runs
from `package.preload` as `aot_<name>`. It is a build-time, per-consumer
bake-in — the default artifact carries nothing AOT'd. The interpreter is
the reference; the AOT/interpreter differential (`scripts/differential.sh`)
witnessed that the two produce byte-identical output.

## Why the question came up

No consumer uses AOT. The current downstream (love-wasm, a game host) does
not; the incoming one (TallyDB, a database wanting an embedded interpreter
so compute skips serialization) does not. AOT's benefit, as `RESULTS.md`
already documented, belongs to tight numeric loops only — game-shaped code
(tables, allocation, GC) had long measured ~1×. The open question was
whether any *realistic* embedder workload — not a textbook kernel — lands
in the region AOT helps. So three data-plane / edge-compute kernels were
written to find out (`experiments/{dataplane,codec,dsp}.lua`).

## The evidence

**Native (interp vs AOT, `scripts/bench.lua`, best-of-3, seconds):**

| kernel | shape | interp | AOT | speedup |
|---|---|--:|--:|--:|
| dataplane | columnar filtered aggregate + GROUP BY (TallyDB stand-in) | 0.983 | 0.609 | 1.61× |
| codec | FNV-1a hash + LEB128 varint decode | 2.206 | 0.683 | 3.23× |
| dsp | fixed-point FIR / box-blur | 1.700 | 0.701 | 2.43× |

Natively, all three win — they are arithmetic-bound, AOT's favorable
region, unlike the game-shaped set. AOT output is byte-identical to interp.

**In wasm the win collapses, and inverts on one engine.** Measured through
`scripts/browser/bench-page.html` (one module, interp leg loads the source,
AOT leg calls `aot_<name>`; wall-clock around `_start`, best-of-3), across
four real engines:

| engine | dataplane | codec | dsp | avg |
|---|--:|--:|--:|--:|
| Chrome / V8 | 1.16× | 1.15× | 1.08× | 1.13× |
| Safari / JSC | 1.18× | 1.26× | 1.12× | 1.19× |
| Firefox / SpiderMonkey | 0.89× | 0.81× | 0.92× | **0.87× (net loss)** |
| headless Chromium 141 | 1.19× | 1.13× | 1.20× | 1.17× |

The interpreter is steady across all four engines; it is AOT that swings
from +26% to −19%. On SpiderMonkey the generated giant functions are a
pessimization — the "baseline tier → AOT is slower" failure mode
`RESULTS.md` names — and Firefox is a gating engine in the witness matrix.

**Calibration caveat (unresolved).** The same harness, run on the published
kernels, reproduces fannkuch (~1×, consistent) but **not** mandelbrot: it
reports 1.08× on current Chromium 141 where `RESULTS.md` recorded 2.63–3.34×
on Node 24.15 / V8 13.6 (mid-2026). Most likely a newer V8 optimizing the
interpreter's dispatch loop better has closed the gap, but this was not
reproduced under Node ≥ 24.15 (the authoring container had only the crashing
Node 22). Either way it does not change the verdict: even if the textbook
numeric kernel still wins on some V8, **no realistic embedder workload is
pure-scalar mandelbrot** — the workloads a consumer runs are the ~1.1×
column, and negative on Firefox.

## The decision

Remove AOT. The realistic-workload payoff is marginal on V8/JSC and a net
loss on SpiderMonkey; the game-shaped set was already ~1×; the only clear
winner is a workload class no consumer runs. Against that, AOT carries the
whole per-consumer build path, the differential witness, the deep-witness
AOT tier, and ~1,800 lines of imported (MIT, now correctly attributed) C.

Removal also **shrinks the fork toward stock**: the AOT hooks are the only
reason `lvm.c`, `lobject.h`, and `lfunc.c` diverge from PUC-Rio 5.4.8.
Stripping them returns those files to verbatim stock, leaving `luac.c` (the
assert-safe listing rework, unrelated to AOT) as the sole declared
modification — from five modified files to one, which is squarely the
project's "verbatim stock except declared files" identity.

AOT is reintroducible from git history the day a numeric-workload,
V8-targeting consumer actually appears. Until then it is cost without a
consumer, and it goes.
