// Browser witness: run a Lua script inside lua.wasm in a real Chromium and
// assert on the transcript. This is the V8-as-shipped leg of the engine
// matrix in doc/wasm-audit-2026-07-05.md -- the suite-prefix bundle
// (scripts/suite-bundle.py) is the intended payload, since the audit's
// host-crash detonated only after the whole prefix ran in order.
//
//   node scripts/browser-witness.mjs <lua.wasm> <script.lua> [--expect TEXT]
//
// Requires playwright-core resolvable from the invoking directory and a
// Chromium; pass one via CHROMIUM=<path>, else Playwright's default install
// locations are probed. Adapted from love-wasi's wasi/host/browser-witness.mjs.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const here = dirname(fileURLToPath(import.meta.url));
const [wasmPath, scriptPath] = process.argv.slice(2);
const expect = process.argv.includes('--expect')
  ? process.argv[process.argv.indexOf('--expect') + 1]
  : 'SUITE-PREFIX PASS';
if (!wasmPath || !scriptPath) {
  console.error('usage: node scripts/browser-witness.mjs <lua.wasm> <script.lua> [--expect TEXT]');
  process.exit(2);
}

// --- static server: fixed routes, zero special headers ----------------------
const routes = {
  '/lua-page.html':        [resolve(here, 'browser/lua-page.html'), 'text/html'],
  '/wasi-stdio-shim.mjs':  [resolve(here, 'browser/wasi-stdio-shim.mjs'), 'text/javascript'],
  '/lua.wasm':             [resolve(wasmPath), 'application/wasm'],
  '/witness.lua':          [resolve(scriptPath), 'text/plain'],
};
const server = createServer(async (req, res) => {
  const route = routes[new URL(req.url, 'http://x').pathname];
  if (!route) { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'content-type': route[1] });
  res.end(await readFile(route[0]));
});
await new Promise(ok => server.listen(0, '127.0.0.1', ok));
const base = `http://127.0.0.1:${server.address().port}`;

// --- chromium ----------------------------------------------------------------
// playwright-core is a dev-only dependency; resolve it from the invoking
// directory so it never has to live in this repo.
const require = createRequire(resolve(process.cwd(), 'noop.js'));
const { chromium } = require('playwright-core');
const executablePath = process.env.CHROMIUM && existsSync(process.env.CHROMIUM)
  ? process.env.CHROMIUM
  : undefined;  // let playwright resolve its own installed chromium

const browser = await chromium.launch(executablePath ? { executablePath } : {});
try {
  const page = await browser.newPage();
  await page.goto(`${base}/lua-page.html?wasm=/lua.wasm&script=/witness.lua`);
  await page.waitForFunction(() => window.__witness && window.__witness.done,
                             null, { timeout: 120_000 });
  const { exitCode, transcript } = await page.evaluate(() => window.__witness);
  console.log(transcript.split('\n').slice(-8).join('\n'));
  const version = browser.version();
  const pass = exitCode === 0 && transcript.includes(expect);
  console.log(`(chromium ${version}, exit ${exitCode})`);
  console.log(pass ? 'BROWSER WITNESS PASS'
                   : `BROWSER WITNESS FAIL (expected "${expect}", exit 0)`);
  process.exitCode = pass ? 0 : 1;
} finally {
  await browser.close();
  server.close();
}
