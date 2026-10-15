-- DATA/SOUND/SOUND.TXT (the S3 sound bank, dethrace s3.c S3SoundBankReadEntry): id -> file name.
-- Each value starts a line; lines not starting with a letter, digit or '-' are skipped.
local M = {}

-- Returns {[id] = {file = 'NAME.WAV', minVolume, maxVolume, minPitch, maxPitch}} (pitch 1.0 = normal).
function M.parse(text)
  local lines = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    line = line:gsub('\r+$', '')
    if line:match('^[%w%-]') then lines[#lines + 1] = line end
  end
  local sounds = {}
  local i = 1
  local function nextLine()
    local l = lines[i]
    i = i + 1
    return l
  end
  while i <= #lines do
    local id = tonumber((nextLine() or ''):match('^(%-?%d+)'))
    if not id then break end
    local typeFlags = nextLine()
    local file = (nextLine() or ''):match('^(%S+)')
    local _priority = nextLine()
    local _repeats = nextLine()
    local vMin, vMax = (nextLine() or ''):match('^(%-?%d+)%s*,%s*(%-?%d+)')
    local pMin, pMax = (nextLine() or ''):match('^([%d%.%-]+)%s*,%s*([%d%.%-]+)')
    local _speed = nextLine()
    local _fx = nextLine()
    local proxies = tonumber((nextLine() or ''):match('^(%-?%d+)'))
    if not (typeFlags and file and proxies) then break end
    for _ = 1, proxies do nextLine() end
    pMin, pMax = tonumber(pMin) or 1, tonumber(pMax) or 1
    sounds[id] = {
      file = file,
      minVolume = tonumber(vMin) or 255, maxVolume = tonumber(vMax) or 255,
      minPitch = pMin ~= 0 and pMin or 1, maxPitch = pMax ~= 0 and pMax or 1,
    }
  end
  return sounds
end

return M
