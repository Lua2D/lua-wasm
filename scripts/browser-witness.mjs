// Browser witness: run a Lua script inside lua.wasm in a real browser engine
// -- Chromium (V8), Firefox (SpiderMonkey), or WebKit (JSC family) -- and
// assert on the transcript. This is the browser leg of the engine matrix in
// doc/wasm-audit-2026-07-05.md; the suite-prefix bundle (scripts/suite-bundle.py)
// is the intended payload, since the audit's host-crash detonated only after
// the whole prefix ran in order.
//
//   node scripts/browser-witness.mjs <lua.wasm> <script.lua> \
//        --engine <chromium|firefox|webkit> [--expect TEXT]
//
// --engine is REQUIRED and never defaults. A witness that silently fell back to
// Chromium would report a V8 result under a non-V8 name, so three independent
// guards enforce that the page actually ran on the requested engine:
//   1. no fallback   -- a browser that will not launch fails the witness; it is
//                       never quietly swapped for a different engine.
//   2. launcher type -- Playwright's own browser type must equal --engine.
//   3. runtime probe -- the page fingerprints its real engine from the
//                       user-agent (Firefox/, Chrome/, or AppleWebKit without a
//                       Chrome token) and must match --engine, else the witness
//                       fails. (Capability probes such as Error.captureStackTrace
//                       drift across engine versions -- it is no longer V8-only --
//                       so the UA is the stable signal; guard 2 is authoritative.)
//
// Requires playwright-core resolvable from the invoking directory and the
// requested browser installed (npx playwright install <engine>). An installed
// browser may be overridden per-engine via CHROMIUM=/FIREFOX=/WEBKIT=<path>;
// each var applies ONLY to its own engine, so it can never cross-wire.
// Adapted from love-wasi's wasi/host/browser-witness.mjs.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const here = dirname(fileURLToPath(import.meta.url));

// --- args: two positionals + --engine (required) + --expect ------------------
const argv = process.argv.slice(2);
let engine, expect = 'SUITE-PREFIX PASS';
const positional = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--engine') engine = argv[++i];
  else if (argv[i] === '--expect') expect = argv[++i];
  else positional.push(argv[i]);
}
const [wasmPath, scriptPath] = positional;

const ENGINES = ['chromium', 'firefox', 'webkit'];
if (!wasmPath || !scriptPath || !engine) {
  console.error('usage: node scripts/browser-witness.mjs <lua.wasm> <script.lua> --engine <chromium|firefox|webkit> [--expect TEXT]');
  process.exit(2);
}
if (!ENGINES.includes(engine)) {
  console.error(`unknown --engine "${engine}"; must be one of: ${ENGINES.join(', ')}`);
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

// --- launch the REQUESTED engine, with no fallback --------------------------
// playwright-core is a dev-only dependency; resolve it from the invoking
// directory so it never has to live in this repo.
const require = createRequire(resolve(process.cwd(), 'noop.js'));
const browserType = require('playwright-core')[engine];   // pw.chromium/.firefox/.webkit

// Per-engine executablePath override; each var applies only to its own engine.
const exeVar = { chromium: 'CHROMIUM', firefox: 'FIREFOX', webkit: 'WEBKIT' }[engine];
const exePath = process.env[exeVar] && existsSync(process.env[exeVar])
  ? process.env[exeVar]
  : undefined;

let browser;
try {
  browser = await browserType.launch(exePath ? { executablePath: exePath } : {});
} catch (e) {
  // GUARD 1: no silent fallback. A missing/unlaunchable engine fails the
  // witness; it never quietly runs a different engine (e.g. Chromium).
  console.error(`FATAL: could not launch ${engine} (no fallback to another engine): ${e.message}`);
  server.close();
  process.exit(3);
}

try {
  // GUARD 2: Playwright's own browser type must match what we asked for.
  const launched = browser.browserType().name();
  if (launched !== engine) {
    console.log(`ENGINE MISMATCH (launcher): requested ${engine}, launched ${launched}`);
    console.log(`BROWSER WITNESS FAIL (${engine})`);
    process.exitCode = 1;
  } else {
    const page = await browser.newPage();
    await page.goto(`${base}/lua-page.html?wasm=/lua.wasm&script=/witness.lua`);
    await page.waitForFunction(() => window.__witness && window.__witness.done,
                               null, { timeout: 120_000 });
    // GUARD 3: fingerprint the ACTUAL engine from inside the page.
    const r = await page.evaluate(() => {
      // UA-token fingerprint, checked in this order: Firefox has "Firefox/";
      // Chromium has "Chrome/" (atop AppleWebKit/537.36); WebKit/Safari has
      // "AppleWebKit/" with no Chrome token. Order matters -- Chromium also
      // reports AppleWebKit, so it must be tested before the bare WebKit case.
      const ua = navigator.userAgent;
      const detected = /Firefox\//.test(ua)          ? 'firefox'
        : /(Chrome|Chromium|Edg)\//.test(ua)         ? 'chromium'
        : /AppleWebKit\//.test(ua)                   ? 'webkit'
        : 'unknown';
      return { exitCode: window.__witness.exitCode, transcript: window.__witness.transcript, detected, ua };
    });
    console.log(r.transcript.split('\n').slice(-8).join('\n'));
    console.log(`(${engine} ${browser.version()}, detected-engine=${r.detected}, exit ${r.exitCode})`);
    const engineOk = r.detected === engine;
    if (!engineOk) console.log(`ENGINE MISMATCH (runtime): requested ${engine}, page ran on ${r.detected} (ua: ${r.ua})`);
    const pass = engineOk && r.exitCode === 0 && r.transcript.includes(expect);
    console.log(pass ? `BROWSER WITNESS PASS (${engine})`
                     : `BROWSER WITNESS FAIL (${engine}${engineOk ? `, expected "${expect}", exit 0` : ', wrong engine'})`);
    process.exitCode = pass ? 0 : 1;
  }
} finally {
  await browser.close();
  server.close();
}
