-- Phase 4 benchmark driver. Runs one benchmark module at one problem
-- size, times the call with os.clock (CPU time), and prints a single
-- CSV line:  <label>,<bench>,<N>,<seconds>
--
--   lua scripts/bench.lua <label> <bench> <N> [aot_prefix]
--
-- With an aot_prefix, the module is required as prefix..bench (its AOT
-- build); otherwise the interpreted source in experiments/ is loaded.
-- The same driver runs native and in wasm, interpreted and AOT'd, so a
-- number is only ever compared against another number this driver made.

local label   = assert(arg[1], "label")
local bench   = assert(arg[2], "bench")
local N       = assert(tonumber(arg[3]), "N")
local aotpref = arg[4]

local main
if aotpref then
  main = assert(package.preload[aotpref .. bench],
                "AOT module not linked in: " .. aotpref .. bench)()
else
  main = assert(loadfile("experiments/" .. bench .. ".lua"))()
end

-- benchmark modules emit their result via print or io.write; swallow
-- both so stdout stays pure CSV (mandelbrot writes a binary PPM image)
local real_print = print
local real_write = io.write
print = function () end
io.write = function () return io.stdout end

collectgarbage(); collectgarbage()
local t0 = os.clock()
main(N)
local dt = os.clock() - t0

print = real_print
io.write = real_write
print(string.format("%s,%s,%d,%.4f", label, bench, N, dt))
