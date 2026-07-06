-- String-building benchmark: the UI-text / serialization shape.
-- Every "frame" formats per-entity labels (string.format), builds rows
-- by concatenation, and serializes a snapshot with table.concat. The
-- cost lives in the string library and the allocator, not in bytecode
-- dispatch, so this bounds what AOT can do for string-bound code
-- (issue #10).
--
-- Deterministic; prints total bytes built and a rolling hash.
-- Expected output (N = 8000): bytes: 84728892  hash: 39897853

return function (N)
  N = N or 100
  local ROWS = 200
  local total = 0
  local hash = 5381
  for frame = 1, N do
    local parts = {}
    for i = 1, ROWS do
      -- format: the label shape (score/coords HUD text)
      local label = string.format("entity %04d hp=%3d pos=(%.1f,%.1f)",
                                  i, (i * 7 + frame) % 100,
                                  (i * 13 + frame) % 640 + 0.5,
                                  (i * 29 + frame) % 480 + 0.5)
      -- concatenation: the incremental row build
      local row = "[" .. frame .. "] " .. label .. " | " ..
                  ((i % 2 == 0) and "visible" or "hidden")
      parts[#parts + 1] = row
    end
    -- serialization: one snapshot string per frame
    local snapshot = table.concat(parts, "\n")
    total = total + #snapshot
    -- rolling hash over a sample so the work cannot be dead-code'd
    for i = 1, #snapshot, 251 do
      hash = (hash * 33 + string.byte(snapshot, i)) % 2147483648
    end
  end
  print(string.format("bytes: %d  hash: %d", total, hash))
end
