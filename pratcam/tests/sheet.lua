-- usage: luajit sheet.lua <app src dir> <PRATCAM/<driver> dir> <DRRENDER.PAL> <out.png>
package.path = arg[1] .. '/?.lua;' .. package.path
local flic, pix, png = require('flic'), require('pix'), require('png')
local function read(p) local f = assert(io.open(p, 'rb')) local s = f:read('*a') f:close() return s end
local pal = pix.palette(read(arg[3]))
local names = {}
for l in io.popen('ls ' .. arg[2] .. ' | grep -i "\\.fli$"'):lines() do names[#names + 1] = l end
local cols, W, H = 9, 104, 110
local rowsN = math.ceil(#names / cols)
local canvas = {}
for i = 0, cols * W * rowsN * H - 1 do canvas[i] = 0 end
local total, t0 = 0, os.clock()
for n, name in ipairs(names) do
  local f, err = flic.decode(read(arg[2] .. '/' .. name))
  if not f then print('FAIL', name, err) else
    total = total + #f.frames
    print(name, f.w .. 'x' .. f.h, #f.frames .. ' frames', f.period .. ' ms')
    local fr = f.frames[math.ceil(#f.frames / 2)]  -- middle frame
    local cx, cy = ((n - 1) % cols) * W, math.floor((n - 1) / cols) * H
    for y = 0, H - 1 do for x = 0, W - 1 do canvas[(cy + y) * cols * W + cx + x] = fr:byte(y * W + x + 1) end end
  end
end
print('frames', total, 'decode s', os.clock() - t0)
local out = {}
for i = 0, cols * W * rowsN * H - 1 do local c = pal[canvas[i]] out[#out + 1] = string.char(c[1], c[2], c[3], 255) end
local o = io.open(arg[4], 'wb') o:write(png.encode(cols * W, rowsN * H, table.concat(out))) o:close()
