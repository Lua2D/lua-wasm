// Harsher reactor witness: the failure modes love-wasi's pump will lean on.
// Adopted from love-wasi (wasi/lua/witness/reactor-stress.mjs), the
// bring-up that audited this repo -- see doc/wasm-audit-2026-07-05.md.
//   node scripts/reactor-stress.mjs lua-lib.wasm
import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';
const wasi = new WASI({ version: 'preview1', args: ['lua'], env: {}, preopens: {} });
const mod = await WebAssembly.compile(await readFile(process.argv[2]));
const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
wasi.initialize(inst);
const e = inst.exports;
const enc = new TextEncoder(), dec = new TextDecoder();
const push = s => { const b = enc.encode(s); const p = e.luaw_alloc(b.length);
  new Uint8Array(e.memory.buffer, p, b.length).set(b); return [p, b.length]; };
const lastErr = () => { const p = e.luaw_last_error(); if (!p) return null;
  const m = new Uint8Array(e.memory.buffer); let end = p; while (m[end]) end++;
  return dec.decode(m.subarray(p, end)); };
const run = src => { const [p, n] = push(src); const st = e.luaw_run(p, n, 0); e.luaw_free(p); return st; };
const start = src => { const [p, n] = push(src); const st = e.luaw_start(p, n, 0); e.luaw_free(p); return st; };

let fails = 0;
const check = (ok, what) => { console.log(`  [${ok ? 'ok' : 'FAIL'}] ${what}`); if (!ok) fails++; };

check(e.luaw_init() === 0, 'luaw_init');

// 1. C-stack overflow is an error, not a host crash (EH under deep recursion).
{
  const st = run('local function f() return f() + 1 end f()');
  check(st !== 0 && /stack overflow|too many/.test(lastErr() ?? ''),
        `unbounded recursion trapped as Lua error (${(lastErr()||'').slice(0,40)}...)`);
}
// 2. VM still coherent after the overflow.
check(run('assert(2^10 == 1024)') === 0, 'VM sane after stack overflow');

// 3. error() with a table value crossing luaw_run (non-string error objects).
{
  const st = run('error({code=7})');
  check(st !== 0 && (lastErr() ?? '').includes('error object is not a string'),
        'table error object surfaced without corrupting the host boundary');
}

// 4. resident program: yield N times, then error mid-flight; then replace it.
{
  check(start('for i=1,3 do coroutine.yield(i) end error("mid-flight", 0)') === 0, 'luaw_start');
  let yields = 0, st;
  while ((st = e.luaw_step()) === 1 /* LUA_YIELD */) yields++;
  check(yields === 3 && st !== 0 && (lastErr() ?? '').includes('mid-flight'),
        `resident program yielded 3x then failed cleanly (status ${st})`);
  check(start('coroutine.yield("fresh") ; x = 1') === 0 && e.luaw_step() === 1,
        'replacement program starts and yields after predecessor died');
  check(e.luaw_step() === 0, 'replacement program runs to completion');
}

// 5. pump longevity: 50k yields through the external-EH build, GC active.
{
  check(start('local n=0 while n < 50000 do n=n+1 coroutine.yield() end') === 0, 'longevity start');
  let n = 0; const t0 = performance.now();
  while (e.luaw_step() === 1) n++;
  const ms = (performance.now() - t0);
  check(n === 50000, `50k frames pumped (${ms.toFixed(0)}ms, ${(ms*1000/n).toFixed(1)}us/frame)`);
}

// 6. per-frame garbage under pressure: allocate tables each frame, full GC periodically.
{
  check(start(`for i=1,2000 do local t={} for j=1,50 do t[j]={j} end
               if i % 500 == 0 then collectgarbage("collect") end coroutine.yield() end`) === 0, 'gc start');
  let n = 0; while (e.luaw_step() === 1) n++;
  check(n === 2000, `2000 allocating frames with periodic full GC (${n})`);
}

console.log(fails === 0 ? 'REACTOR STRESS PASS' : `REACTOR STRESS FAIL (${fails})`);
process.exit(fails === 0 ? 0 : 1);
