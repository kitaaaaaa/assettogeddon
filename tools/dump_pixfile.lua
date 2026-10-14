-- every pixelmap in a .PIX file as raw RGBA plus an index (name w h), for contact_sheet.py
package.path = './?.lua;' .. package.path
local pix = require('src/pix')
local file, palFile, out = arg[1], arg[2], arg[3]
local function rd(p) local f = io.open(p, 'rb') if not f then return nil end local d = f:read('*a') f:close() return d end
local pal = pix.palette(rd(palFile))
local idx = io.open(out .. '/index.txt', 'w')
for i, m in ipairs(pix.parse(rd(file))) do
  local rgba = pix.toRGBA(m, pal)
  if rgba then
    local f = io.open(out .. '/' .. i .. '.rgba', 'wb') f:write(rgba) f:close()
    idx:write(('%d %d %d %s\n'):format(i, m.w, m.h, m.name ~= '' and m.name or '?'))
  end
end
idx:close()
