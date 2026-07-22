-- Closure-churn benchmark: the event-handler / callback shape.
-- Every "frame" creates short-lived closures (handlers capturing
-- locals), registers them, fires them once, and drops them; a slice
-- runs as coroutine bodies (the resident-program shape lua.wasm's
-- reactor promotes). Allocation and collection of upvalues, closures,
-- and coroutines dominate; bytecode dispatch does not (issue #10).
--
-- Deterministic; prints the accumulated handler results.
-- Expected output (N = 12000): acc: 1845093824

return function (N)
  N = N or 100
  local HANDLERS = 500
  local acc = 0
  for frame = 1, N do
    local handlers = {}
    for i = 1, HANDLERS do
      local base = i + frame        -- captured upvalues
      local weight = (i % 16) + 1
      handlers[i] = function (x)
        return (base + x) * weight % 65536
      end
    end
    for i = 1, HANDLERS do
      acc = acc + handlers[i](frame % 128)
    end
    -- coroutine bodies: a few per frame, each yielding once
    for i = 1, 20 do
      local co = coroutine.wrap(function ()
        coroutine.yield(i + frame)
        return 0
      end)
      acc = acc + co()
    end
    acc = acc % 2147483648
  end
  print(string.format("acc: %d", acc))
end
