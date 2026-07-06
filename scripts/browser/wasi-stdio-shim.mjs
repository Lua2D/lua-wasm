// WASI preview1 stdio shim for running lua.wasm in a browser page.
// Adopted from love-wasi (wasi/host/wasi-shim.mjs), the bring-up that
// audited this repo. Honest minimal surface: args, fd_write, clocks,
// random, proc_exit; everything else auto-stubs to ENOSYS so a new
// dependency surfaces as an errno, not a missing-import crash.

const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_NOSYS = 52;

// One exception class threads proc_exit out of the wasm call stack.
export class WasiExit extends Error {
  constructor(code) { super(`proc_exit(${code})`); this.code = code; }
}

export class WasiPreview1 {
  /**
   * @param {object} opts
   * @param {string[]} opts.args    argv, argv[0] is the program name
   * @param {(text: string) => void} [opts.stdout]  line-buffered fd 1
   * @param {(text: string) => void} [opts.stderr]  line-buffered fd 2
   */
  constructor({ args = ['wasm'], stdout = console.log, stderr = console.error } = {}) {
    this.args = args;
    this.sinks = { 1: { write: stdout, buf: '' }, 2: { write: stderr, buf: '' } };
    this.instance = null;
    this.decoder = new TextDecoder();
    this.encoder = new TextEncoder();
  }

  get memory() { return this.instance.exports.memory; }
  view() { return new DataView(this.memory.buffer); }

  // ---- the calls Lua actually makes ---------------------------------------

  args_sizes_get(argcPtr, sizePtr) {
    const v = this.view();
    v.setUint32(argcPtr, this.args.length, true);
    const bytes = this.args.reduce((n, a) => n + this.encoder.encode(a).length + 1, 0);
    v.setUint32(sizePtr, bytes, true);
    return ERRNO_SUCCESS;
  }

  args_get(argvPtr, bufPtr) {
    const v = this.view();
    const mem = new Uint8Array(this.memory.buffer);
    for (const arg of this.args) {
      v.setUint32(argvPtr, bufPtr, true); argvPtr += 4;
      const b = this.encoder.encode(arg);
      mem.set(b, bufPtr); mem[bufPtr + b.length] = 0;
      bufPtr += b.length + 1;
    }
    return ERRNO_SUCCESS;
  }

  environ_sizes_get(countPtr, sizePtr) {
    const v = this.view();
    v.setUint32(countPtr, 0, true);
    v.setUint32(sizePtr, 0, true);
    return ERRNO_SUCCESS;
  }

  environ_get() { return ERRNO_SUCCESS; }

  fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
    const sink = this.sinks[fd];
    if (!sink) return ERRNO_BADF;
    const v = this.view();
    let written = 0, text = '';
    for (let i = 0; i < iovsLen; i++) {
      const ptr = v.getUint32(iovsPtr + i * 8, true);
      const len = v.getUint32(iovsPtr + i * 8 + 4, true);
      text += this.decoder.decode(new Uint8Array(this.memory.buffer, ptr, len));
      written += len;
    }
    sink.buf += text;                       // line-buffer so hosts get whole lines
    const lines = sink.buf.split('\n');
    sink.buf = lines.pop();
    for (const line of lines) sink.write(line);
    v.setUint32(nwrittenPtr, written, true);
    return ERRNO_SUCCESS;
  }

  fd_read(fd, iovs, iovsLen, nreadPtr) {       // stdin is permanently at EOF
    this.view().setUint32(nreadPtr, 0, true);
    return ERRNO_SUCCESS;
  }

  fd_fdstat_get(fd, statPtr) {                 // 0/1/2 are character devices
    if (!(fd in this.sinks) && fd !== 0) return ERRNO_BADF;
    const v = this.view();
    v.setUint8(statPtr, 2);                    // filetype: character_device
    v.setUint16(statPtr + 2, 0, true);         // flags
    v.setBigUint64(statPtr + 8, 0n, true);     // rights_base
    v.setBigUint64(statPtr + 16, 0n, true);    // rights_inheriting
    return ERRNO_SUCCESS;
  }

  fd_prestat_get() { return ERRNO_BADF; }      // no preopens: ends the scan

  clock_time_get(id, _precision, resPtr) {
    // 0 = realtime, 1 = monotonic; nanoseconds as u64
    const ns = id === 0
      ? BigInt(Date.now()) * 1_000_000n
      : BigInt(Math.round(performance.now() * 1e6));
    this.view().setBigUint64(resPtr, ns, true);
    return ERRNO_SUCCESS;
  }

  random_get(ptr, len) {
    crypto.getRandomValues(new Uint8Array(this.memory.buffer, ptr, len));
    return ERRNO_SUCCESS;
  }

  proc_exit(code) { throw new WasiExit(code); }

  // ---- wiring --------------------------------------------------------------

  /** Import object: implemented calls above, ENOSYS for everything else the
   *  module declares. Call with the compiled module so imports can be listed. */
  importsFor(module) {
    const wasi = {};
    for (const imp of WebAssembly.Module.imports(module)) {
      if (imp.module !== 'wasi_snapshot_preview1') continue;
      wasi[imp.name] = this[imp.name]
        ? this[imp.name].bind(this)
        : () => ERRNO_NOSYS;
    }
    return { wasi_snapshot_preview1: wasi };
  }

  /** Run a command module's _start; returns its exit code. */
  start(instance) {
    this.instance = instance;
    try {
      instance.exports._start();
      return 0;
    } catch (e) {
      if (e instanceof WasiExit) return e.code;
      throw e;
    } finally {
      for (const sink of Object.values(this.sinks))   // flush partial lines
        if (sink.buf) { sink.write(sink.buf); sink.buf = ''; }
    }
  }
}
