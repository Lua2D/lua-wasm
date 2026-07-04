// Host shim: run a WASI-targeting lua.wasm under Node.
//   node scripts/wasm-run.mjs <path/to/lua.wasm> [lua args...]
// The current directory is preopened as both '/' and '.', so Lua sees
// the host working directory as its filesystem root.
import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';

const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error('usage: node scripts/wasm-run.mjs <lua.wasm> [args...]');
  process.exit(2);
}
import { resolve } from 'node:path';
const wasi = new WASI({
  version: 'preview1',
  args: ['lua', ...process.argv.slice(3)],
  env: process.env,
  // the working directory is the guest's world; its parent is reachable
  // as '..' so a script can be run from a sibling directory (the AOT
  // suite driver lives in scripts/ and runs with tests/ as cwd)
  preopens: { '/': process.cwd(), '.': process.cwd(), '..': resolve(process.cwd(), '..') },
  returnOnExit: true,
});
const wasm = await WebAssembly.compile(await readFile(wasmPath));
const instance = await WebAssembly.instantiate(wasm, wasi.getImportObject());
process.exitCode = wasi.start(instance);
