// Witness and reference host for the embeddable artifact (lua-lib.wasm):
//   node scripts/embed-demo.mjs lua-lib.wasm
// Demonstrates the whole host interface: instantiate the reactor, init
// the VM, run chunks, read errors, and pump a resident program that
// yields once per "frame" -- the never-blocks contract in action.
import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';

const wasi = new WASI({
  version: 'preview1',
  args: ['lua'],
  env: {},
  preopens: { '/': process.cwd(), '.': process.cwd() },
});
const mod = await WebAssembly.compile(await readFile(process.argv[2]));
const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
wasi.initialize(inst);          // reactor: initialize, do not "run"
const e = inst.exports;

const enc = new TextEncoder();
function pushString(s) {
  const bytes = enc.encode(s);
  const ptr = e.luaw_alloc(bytes.length);
  new Uint8Array(e.memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}
function lastError() {
  const p = e.luaw_last_error();
  if (p === 0) return null;
  const m = new Uint8Array(e.memory.buffer);
  let end = p;
  while (m[end] !== 0) end++;
  return new TextDecoder().decode(m.subarray(p, end));
}
function run(code) {
  const [ptr, len] = pushString(code);
  const status = e.luaw_run(ptr, len, 0);
  e.luaw_free(ptr);
  return status;
}

const assert = (cond, what) => { if (!cond) { console.error('FAILED:', what, '--', lastError()); process.exit(1); } };

assert(e.luaw_init() === 0, 'init');
assert(run('print("embedded:", _VERSION, 2^53)') === 0, 'run chunk');
assert(run('this is not lua') !== 0 && lastError().includes('syntax error'), 'syntax error surfaces');
assert(run('error("boom")') !== 0 && lastError().includes('boom'), 'runtime error surfaces');
assert(run('print("still alive after errors")') === 0, 'VM survives errors');

// the never-blocks contract: a "game loop" the host pumps per frame
const [p, n] = pushString(`
  local frame = 0
  while frame < 3 do
    frame = frame + 1
    print("frame", frame)
    coroutine.yield()
  end
  print("program over")
`);
assert(e.luaw_start(p, n, 0) === 0, 'start resident program');
e.luaw_free(p);
let steps = 0;
for (;;) {
  const s = e.luaw_step();
  if (s === 1 /* LUA_YIELD */) { steps++; continue; }
  assert(s === 0, 'step');
  break;
}
assert(steps === 3, `expected 3 yields, got ${steps}`);
assert(e.luaw_step() !== 0 && lastError().includes('no resident program'), 'step after finish reports');
console.log('embed witness: OK (' + steps + ' frames pumped, errors surfaced, VM stable)');
