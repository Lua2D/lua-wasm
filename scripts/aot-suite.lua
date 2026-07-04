-- The AOT stress test and differential witness: the official suite with
-- each test file's chunk replaced by its luaot-compiled version baked
-- into the artifact. Run from tests/ against an artifact built with
--   make wasm WASM_AOT="tests/*.lua-except-all.lua"
--
-- Modes (first argument, default "aot"):
--   aot     each file runs via its AOT module (package.preload), falling
--           back to the interpreter for modules not compiled in
--   interp  each file runs interpreted (loadfile), same driver, same order
--
-- Both modes produce byte-identical stdout when AOT and interpreter
-- agree; run accounting goes to stderr so a diff of stdout is the
-- "Agreed" witness. all.lua's own dofile deliberately round-trips every
-- file through dump/undump (which cannot carry an AOT binding by
-- construction), so this driver is a separate scaffold and the vendored
-- tests stay verbatim.
_port = true
debug = nil   -- as all.lua does: tests must require debug when needed

-- mode lives in a global, deliberately: adding even one local to this
-- chunk shifts every stack slot after it, and upstream's gc.lua asserts
-- memory reclamation to within 1KB of a baseline -- tight enough to
-- detect that AOT'd code, under some caller layouts, roots a dead value
-- for one collection longer than the interpreter does (values and
-- results are unaffected; tracked as a known divergence for the luaot
-- maintenance batch). The witness must not perturb what it measures.
MODE, EXCLUDE = ...
MODE = MODE or "aot"
EXCLUDE = EXCLUDE or ""
assert(MODE == "aot" or MODE == "interp", "mode must be 'aot' or 'interp'")

local aot_count, interp_count = 0, 0
local function run (n)
  print("\n***** FILE '" .. n .. "' *****")
  local key = 'aot_' .. n:gsub('%.lua$', ''):gsub('[%.%-]', '_')
  local excluded = EXCLUDE:find(n:gsub('%.lua$', ''), 1, true) ~= nil
  local open = (MODE == "aot" and not excluded) and package.preload[key] or nil
  if open then
    aot_count = aot_count + 1
    return open()
  else
    if MODE == "aot" then
      -- not compiled into this artifact (e.g. the build machine could
      -- not afford the wasm backend's memory on that file); say so --
      -- never silently
      io.stderr:write("interpreted fallback: ", n, "\n")
    end
    interp_count = interp_count + 1
    return assert(loadfile(n))()
  end
end

run('main.lua')                      -- self-skips under _port
require'tracegc'.start()
run('gc.lua')
run('db.lua')
assert(run('calls.lua') == deep and deep)
run('strings.lua')
run('literals.lua')
run('tpack.lua')
assert(run('attrib.lua') == 27)
run('gengc.lua')
assert(run('locals.lua') == 5)
run('constructs.lua')
run('code.lua')
do
  -- big.lua yields from its main chunk; an AOT module's luaopen_ runs
  -- the chunk under lua_call, which cannot host a yield, so this file
  -- runs interpreted in both modes (all.lua also special-cases it)
  print("\n***** FILE 'big.lua' *****")
  local f = coroutine.wrap(assert(loadfile('big.lua')))
  assert(f() == 'b')
  assert(f() == 'a')
end
run('cstack.lua')
run('nextvar.lua')
run('pm.lua')
run('utf8.lua')
run('api.lua')
assert(run('events.lua') == 12)
run('vararg.lua')
run('closure.lua')
run('coroutine.lua')
run('goto.lua')
run('errors.lua')
run('math.lua')
run('sort.lua')
run('bitwise.lua')
assert(run('verybig.lua') == 10); collectgarbage()
run('files.lua')

assert(debug == nil)
io.stderr:write(string.format("mode %s: %d ahead-of-time, %d interpreted\n",
                              MODE, aot_count, interp_count))
print('suite: final OK !!!')
