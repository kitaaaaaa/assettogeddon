-- Carmageddon 1 text files: line reading as in the game's GetALineAndDontArgue (dethrace utility.c),
-- including '@' encrypted lines, and its strtok("\t ,/") tokenizer.
local bit = require('bit')

local M = {}

local KEY = {0x6C, 0x1B, 0x99, 0x5F, 0xB9, 0xCD, 0x5F, 0x13, 0xCB, 0x04, 0x20, 0x0E, 0x5E, 0x1C, 0xA1, 0x0E}
local COMMENT_KEY = {0x67, 0xA8, 0xD6, 0x26, 0xB6, 0xDD, 0x45, 0x1B, 0x32, 0x7E, 0x22, 0x13, 0x15, 0xC2, 0x94, 0x37}

-- Decrypts the text after an '@' (trailing CR/LF already removed). method: 1 or 2 (see detectMethod).
function M.decode(s, method)
  local len = #s
  local out = {}
  local key = KEY
  local seed = len % 16
  for i = 1, len do
    if i >= 3 and out[i - 1] == 47 and out[i - 2] == 47 then key = COMMENT_KEY end  -- after "//"
    local ch = s:byte(i)
    if method == 1 then
      if ch == 9 then ch = 0x9F end
      ch = bit.band(bit.bxor(key[seed + 1], (ch - 32) % 256), 0x7F) + 32
      if ch == 0x9F then ch = 9 end
    else
      if ch == 9 then ch = 0x80 end
      local c = (ch - 32) % 256
      if bit.band(c, 0x80) == 0 then ch = bit.bxor(c, bit.band(key[seed + 1], 0x7F)) + 32 end
      if ch == 0x80 then ch = 9 end
    end
    seed = (seed + 7) % 16
    out[i] = ch
  end
  -- string.char in chunks (it takes a limited number of arguments)
  local parts = {}
  for i = 1, #out, 200 do parts[#parts + 1] = string.char(unpack(out, i, math.min(i + 199, #out))) end
  return table.concat(parts)
end

local function rawLines(data)
  local lines = {}
  for line in (data .. '\n'):gmatch('([^\n]*)\n') do
    lines[#lines + 1] = (line:gsub('\r+$', ''))
  end
  return lines
end

-- The game decides between two ciphers from the first line of DATA/GENERAL.TXT.
function M.detectMethod(generalTxt)
  if not generalTxt then return 2 end
  local first = rawLines(generalTxt)[1] or ''
  if first:sub(1, 1) ~= '@' then return 2 end
  return M.decode(first:sub(2), 1):sub(1, 6) == '0.01\t\t' and 1 or 2
end

local ACCEPT_FIRST = {[45] = true, [46] = true, [33] = true, [38] = true, [40] = true, [39] = true, [34] = true}  -- - . ! & ( ' "

local function isAlnum(b)
  return b and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

-- Returns a reader with :line() (next meaningful line, or nil at the end) like the game's line reader:
-- '@' lines are decrypted, leading blanks removed, and lines not starting with a letter, digit or one of
-- - . ! & ( ' " (comments, blank lines) are skipped.
function M.reader(data, method)
  local lines = rawLines(data)
  local i = 0
  local r = {}
  function r:line()
    while true do
      i = i + 1
      local s = lines[i]
      if s == nil then return nil end
      if s:sub(1, 1) == '@' then s = M.decode(s:sub(2), method) end
      s = s:gsub('^[ \t]+', '')
      local b = s:byte(1)
      if isAlnum(b) or ACCEPT_FIRST[b] or (b and b >= 128) then return s end
    end
  end
  function r:rewind() i = 0 end
  return r
end

-- strtok(s, "\t ,/")
function M.tokens(s)
  local t = {}
  for tok in s:gmatch('[^\t ,/]+') do t[#t + 1] = tok end
  return t
end

function M.firstToken(s) return M.tokens(s)[1] end

return M
