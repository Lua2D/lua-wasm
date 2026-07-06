# Host shim: run a WASI-targeting lua.wasm under wasmtime (the non-V8
# cross-check engine). Mirrors scripts/wasm-run.mjs: the current directory
# is preopened as '/', '.', and its parent as '..'.
#
#   pip install wasmtime
#   cd tests && python3 ../scripts/wasmtime-run.py ../lua.wasm -e"_port=true" all.lua
#
# wasmtime only accepts the standardized EH encoding (try_table/exnref,
# the Makefile's WASM_EH_ENCODING=standard default); it rejects legacy-EH
# modules at compile time with "legacy_exceptions feature required".
import sys, os
from wasmtime import Config, Engine, Store, Module, Linker, WasiConfig

if len(sys.argv) < 2:
    print("usage: python3 wasmtime-run.py <lua.wasm> [lua args...]", file=sys.stderr)
    sys.exit(2)

cfg = Config()
cfg.wasm_exceptions = True
engine = Engine(cfg)
module = Module.from_file(engine, sys.argv[1])
linker = Linker(engine)
linker.define_wasi()
wasi = WasiConfig()
wasi.argv = ["lua"] + sys.argv[2:]
wasi.inherit_stdout(); wasi.inherit_stderr(); wasi.inherit_env()
wasi.preopen_dir(os.getcwd(), "/")
wasi.preopen_dir(os.getcwd(), ".")
wasi.preopen_dir(os.path.dirname(os.getcwd()) or "/", "..")
store = Store(engine)
store.set_wasi(wasi)
instance = linker.instantiate(store, module)
start = instance.exports(store)["_start"]
try:
    start(store)
    sys.exit(0)
except Exception as e:  # wasmtime raises on both exit() and traps
    msg = str(e)
    if "Exited with i32 exit status" in msg:
        sys.exit(int(msg.split("status")[1].split()[0]))
    print("TRAP:", msg[:400], file=sys.stderr)
    sys.exit(134)
