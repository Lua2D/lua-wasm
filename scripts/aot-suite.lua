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
-- memory reclamation to within 1KB of a baseline -- an absolute-memory
-- razor that incidental stack-layout shifts can trip (it once flagged a
-- since-resolved AOT accounting divergence; history in differential.sh's
-- header). The witness must not perturb what it measures.
MODE, EXCLUDE = ...
MODE = MODE or "aot"
EXCLUDE = EXCLUDE or ""
assert(MODE == "aot" or MODE == "interp", "mode must be 'aot' or 'interp'")

-- Exclusion matching is against DELIMITED entries of the comma-separated
-- list, not a plain substring: a bare find() made "gengc" also exclude
-- "gc" and "verybig" also exclude "big", silently -- the collided file
-- ran interpreted in both legs and the differential stayed vacuously
-- AGREED for it (issue #30). Globals, not chunk locals, for the razor
-- reason MODE's comment gives.
function EXCLUDED (n)
  return ("," .. EXCLUDE .. ","):find("," .. n:gsub('%.lua$', '') .. ",",
                                      1, true) ~= nil
end
PROBED = {}   -- every file the driver ran, for the identity probe below

local aot_count, interp_count, excluded_count = 0, 0, 0
local function run (n)
  print("\n***** FILE '" .. n .. "' *****")
  PROBED[#PROBED + 1] = n
  local key = 'aot_' .. n:gsub('%.lua$', ''):gsub('[%.%-]', '_')
  local excluded = EXCLUDED(n)
  local open = (MODE == "aot" and not excluded) and package.preload[key] or nil
  if open then
    aot_count = aot_count + 1
    return open()
  else
    if MODE == "aot" then
      if excluded then
        -- excluded by request: named on stderr so a leg cannot lose
        -- coverage invisibly (issue #30)
        excluded_count = excluded_count + 1
        io.stderr:write("excluded (interpreted in both legs): ", n, "\n")
      else
        -- not compiled into this artifact (e.g. the build machine could
        -- not afford the wasm backend's memory on that file); say so --
        -- never silently
        io.stderr:write("interpreted fallback: ", n, "\n")
      end
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
  -- big.lua yields from its main chunk, so it cannot go through run()'s
  -- plain call; it is wrapped in a coroutine, as upstream's all.lua does.
  -- The AOT module's luaopen_ runs the chunk via lua_callk (see
  -- luaot_footer.c), so the wrapped C function can host those yields and
  -- the AOT leg runs the compiled chunk like any other file.
  print("\n***** FILE 'big.lua' *****")
  PROBED[#PROBED + 1] = 'big.lua'
  local excluded = EXCLUDED('big.lua')
  local open = (MODE == "aot" and not excluded) and package.preload.aot_big or nil
  local f
  if open then
    aot_count = aot_count + 1
    f = coroutine.wrap(open)
  else
    if MODE == "aot" then
      if excluded then
        excluded_count = excluded_count + 1
        io.stderr:write("excluded (interpreted in both legs): big.lua\n")
      else
        io.stderr:write("interpreted fallback: big.lua\n")
      end
    end
    interp_count = interp_count + 1
    f = coroutine.wrap(assert(loadfile('big.lua')))
  end
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

-- The identity witness (issue #31): every chunk must report the same
-- debug identity (short_src) whether it entered the artifact through
-- luaot or through loadfile. luaot used to bake the build-time input
-- path ("tests/gc.lua") while the runtime leg loads "gc.lua" -- a
-- divergence no suite file happened to print. This probe surfaces it
-- on STDOUT, where the differential's diff enforces it between legs:
-- a call hook captures the chunk's main-body short_src at entry, then
-- aborts the call before the body runs (zero side effects, so files
-- can safely be "re-entered" after the suite; big.lua's yields never
-- happen). It runs after all files, so gc.lua's absolute-memory razor
-- is long past; new names are globals per MODE's comment above.
IDENTITY_HOOK = nil  -- forward declaration, keeps the closure a global
do
  local dbg = require'debug'
  for i = 1, #PROBED do
    local n = PROBED[i]
    local key = 'aot_' .. n:gsub('%.lua$', ''):gsub('[%.%-]', '_')
    local f = (MODE == "aot" and not EXCLUDED(n)) and package.preload[key]
              or assert(loadfile(n))
    local id
    dbg.sethook(function ()
      local info = dbg.getinfo(2, "S")
      if info.what == "main" then
        id = info.short_src
        dbg.sethook()
        error("identity probe: abort before the chunk body runs")
      end
    end, "c")
    pcall(f)
    dbg.sethook()
    print(string.format("chunk identity %s: %s", n, tostring(id)))
  end
end

io.stderr:write(string.format("mode %s: %d ahead-of-time, %d interpreted (%d excluded by request)\n",
                              MODE, aot_count, interp_count, excluded_count))
print('suite: final OK !!!')
