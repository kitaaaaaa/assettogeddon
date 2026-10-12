-- Seedable random numbers (Park-Miller MINSTD, exact in doubles), so ped placement and behaviour can be
-- reproduced from a seed (same track = same peds; later: replays and multiplayer sync).
local M = {}

function M.new(seed)
  local state = math.floor(math.abs(seed or 1)) % 2147483647
  if state == 0 then state = 1 end
  return function()
    state = (state * 48271) % 2147483647
    return (state - 1) / 2147483646  -- [0, 1)
  end
end

-- Stable 31-bit hash of a string (track id -> seed).
function M.hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
  return h
end

return M
