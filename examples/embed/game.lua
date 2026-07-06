-- A stand-in "downstream module" that gets AOT-compiled into the artifact.
-- Its point is only to exercise the AOT composition path (issue #11): the
-- downstream runs ./src/luaot on this file, compiles the generated C, and
-- links it against liblua.a / onelua.c. When required it returns a table.
local game = {}

function game.add(a, b)
  return a + b
end

-- Raises a Lua error on purpose, so the host can prove a Lua error unwinds
-- out of AOT-compiled code and is caught across the C boundary.
function game.boom()
  error("kaboom from an AOT-compiled Lua module")
end

return game
