-- Carmageddon 1's bitmap fonts (DATA/<res>/FONTS/NAME.PIX and NAME.TXT), as dethrace graphics.c LoadFont and
-- displays.c DRPixelmapText use them: the glyphs stacked down one image, glyph (character - offset) at
-- y = height * index, drawn masked (colour 0 is see-through), each followed by the spacing.
local c1text = require('src/c1text')

local M = {}

-- NAME.TXT: height, width, spacing, offset, number of entries, then (width <= 0: proportional) one width per
-- entry. Returns {height, spacing, offset, count, widths = {[index] = w}} or nil.
function M.parseMetrics(text, method)
  local r = c1text.reader(text, method)
  local function int() local l = r:line() return l and tonumber(c1text.firstToken(l) or '') end
  local f = {height = int(), width = int(), spacing = int(), offset = int(), count = int(), widths = {}}
  if not (f.height and f.width and f.spacing and f.offset and f.count) or f.height <= 0 then return nil end
  for i = 0, f.count - 1 do
    f.widths[i] = f.width > 0 and f.width or (int() or 0)
  end
  return f
end

-- The glyphs of a string: {{index, x, w}...} and the total width (C1's DRTextWidth). Characters the font
-- doesn't have are skipped.
function M.layout(font, s)
  local out, x = {}, 0
  for i = 1, #s do
    local index = s:byte(i) - font.offset
    local w = font.widths[index]
    if w and index < font.count then
      out[#out + 1] = {index = index, x = x, w = w}
      x = x + w + font.spacing
    end
  end
  return out, math.max(0, x - font.spacing)
end

return M
