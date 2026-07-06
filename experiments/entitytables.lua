-- Entity-tables benchmark: the ECS-ish shape of per-frame game logic.
-- A pool of entities, each a record-style table (hash-part fields) plus
-- membership in array-part lists; every "frame" walks all entities,
-- mutates fields through table reads/writes, and spawns/despawns a
-- deterministic slice so the GC sees steady allocation churn. This is
-- table-access- and GC-bound on purpose: the dispatch luaot removes is
-- a small fraction of the work, unlike the numeric set (issue #10).
--
-- Deterministic: a tiny inline LCG, no math.random, no library state.
-- Expected output (N = 6000): checksum: 184104490.000

local function make_entity (id, seed)
  return {
    id = id,
    x = (seed % 640) + 0.5,
    y = (seed % 480) + 0.25,
    vx = ((seed % 7) - 3) * 0.5,
    vy = ((seed % 5) - 2) * 0.5,
    hp = 100,
    tag = (seed % 3 == 0) and "enemy" or "ally",
  }
end

return function (N)
  N = N or 100
  local POOL = 2000            -- live entities per frame, roughly
  local lcg = 42
  local function rnd (m)       -- deterministic pseudo-random 0..m-1
    lcg = (lcg * 1103515245 + 12345) % 2147483648
    return lcg % m
  end

  local entities = {}          -- array part: the iteration order
  local byid = {}              -- hash part: lookups by key
  local nextid = 1
  for _ = 1, POOL do
    local e = make_entity(nextid, rnd(100000))
    entities[#entities + 1] = e
    byid[e.id] = e
    nextid = nextid + 1
  end

  local checksum = 0.0
  for frame = 1, N do
    -- the walk: every entity, field reads and writes
    for i = 1, #entities do
      local e = entities[i]
      e.x = e.x + e.vx
      e.y = e.y + e.vy
      if e.x < 0 or e.x > 640 then e.vx = -e.vx end
      if e.y < 0 or e.y > 480 then e.vy = -e.vy end
      if e.tag == "enemy" then
        e.hp = e.hp - 1
        if e.hp <= 0 then e.hp = 100 end
      end
    end
    -- churn: despawn a deterministic slice, spawn replacements
    for _ = 1, 50 do
      local i = rnd(#entities) + 1
      local dead = entities[i]
      byid[dead.id] = nil
      local e = make_entity(nextid, rnd(100000))
      nextid = nextid + 1
      entities[i] = e
      byid[e.id] = e
    end
    -- a hash-part lookup pass, as systems that join on id do
    local acc = 0.0
    for i = 1, #entities, 37 do
      local e = byid[entities[i].id]
      if e then acc = acc + e.x + e.y end
    end
    checksum = checksum + acc
    if frame % 100 == 0 then collectgarbage("step") end
  end
  print(string.format("checksum: %.3f", checksum))
end
