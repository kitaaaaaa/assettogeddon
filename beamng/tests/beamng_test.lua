-- Runs the BeamNG extension (and the app inside it) against a mock of the BeamNG GE Lua API: a flat level with
-- a road graph, the player's car driving through the peds. Catches runtime errors without the game.
-- luajit beamng/tests/beamng_test.lua <fake C1 dir>   (from the repo root, after sh beamng/build.sh)
local fakeC1 = assert(arg[1], 'usage: beamng_test.lua <fake C1 dir>')
local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1 print('FAIL: ' .. msg) end end

local BUILD = 'beamng/build/carmapeds'
local TMP = os.tmpname() .. '_bng'
os.execute('mkdir -p "' .. TMP .. '/temp/carmapeds" "' .. TMP .. '/settings"')

-- the virtual file system: the mod's folder, the user's C1 data in it, and the user folder for written files
local function real(p)
  p = p:gsub('/%./', '/'):gsub('/%./', '/')
  if p:sub(1, 1) ~= '/' then p = '/' .. p end
  if p:find('^/carmapeds_data') then return fakeC1 .. p:sub(#'/carmapeds_data' + 1) end
  if p:find('^/temp/') or p:find('^/settings/') then return TMP .. p end
  return BUILD .. p
end
local rawOpen = io.open
io.open = function(p, mode) return rawOpen(real(p), mode) end
function readFile(p) local f = io.open(p, 'r') if not f then return nil end local d = f:read('*a') f:close() return d end
FS = {
  fileExists = function(_, p) local f = io.open(p, 'rb') if f then f:close() return true end return false end,
  directoryExists = function(_, p) return os.execute('test -d "' .. real(p) .. '"') == 0 or os.execute('test -d "' .. real(p) .. '"') == true end,
  directoryCreate = function(_, p) os.execute('mkdir -p "' .. real(p) .. '"') end,
}
local logs = {}
function log(level, tag, msg) logs[#logs + 1] = level .. ' ' .. tostring(msg) end
function jsonEncode(v) local t = {} for k, x in pairs(v) do t[#t + 1] = tostring(k) .. '=' .. tostring(x) end table.sort(t) return table.concat(t, ',') end
-- scared peds barely run here, so the car (driving dead straight, never steering at them) hits some
local savedFiles = {['/settings/carmapeds.json'] = {runSpeed = 0.1, runDistance = 0.5}}
function jsonReadFile(p) return savedFiles[p] end
function jsonWriteFile(p, v) savedFiles[p] = v end
function getCurrentLevelIdentifier() return 'mock_level' end
-- package.path the way the game sets it up (relative to the virtual root): here, relative to the build folder
package.path = BUILD .. '/lua/?.lua;' .. package.path
local origPathFind = package.path
-- the extension prepends 'lua/ge/extensions/carmapeds/?.lua'; make that resolve under the build folder too
package.path = BUILD .. '/lua/ge/extensions/carmapeds/?.lua;' .. package.path

-- BeamNG's vec3 (z up)
local bv = {}
bv.__index = bv
function vec3(x, y, z) return setmetatable({x = x or 0, y = y or 0, z = z or 0}, bv) end
bv.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
bv.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end

-- the level: flat ground at z = 0 in a 120 m wide strip, 3 km long, around a road along y (x = 0): the road graph
local rays = 0
function castRayStatic(pos, dir, len)
  rays = rays + 1
  if dir.z < -0.99 and math.abs(pos.x) < 60 and math.abs(pos.y) < 1500 and pos.z >= 0 and pos.z <= len then return pos.z end
  return len
end
local nodes = {}
for i = 0, 40 do nodes['n' .. i] = {pos = vec3(0, -1000 + 50 * i, 0), radius = 4, links = {}} end
map = {getMap = function() return {nodes = nodes} end}

-- vehicles: the player's car (id 10) and one AI car (id 11)
local vehicles = {}
local function makeVeh(id, x, y)
  local v = {id = id, pos = vec3(x, y, 0.7), vel = vec3(0, 0, 0)}
  function v:getID() return self.id end
  function v:getPosition() return self.pos end
  function v:getVelocity() return self.vel end
  function v:getDirectionVector() return vec3(0, 1, 0) end
  function v:getDirectionVectorUp() return vec3(0, 0, 1) end
  vehicles[#vehicles + 1] = v
  return v
end
local player = makeVeh(10, 0, -900)
makeVeh(11, 600, 0)
be = {
  getPlayerVehicleID = function() return 10 end,
  getObjectCount = function() return #vehicles end,
  getObject = function(_, i) return vehicles[i + 1] end,
  getObjectByID = function(_, id) for _, v in ipairs(vehicles) do if v.id == id then return v end end end,
  getObjectOOBBCenterXYZ = function(_, id) local v = be:getObjectByID(id) return v.pos.x, v.pos.y, v.pos.z end,
  getObjectOOBBHalfAxisXYZ = function(_, id, k)
    if k == 0 then return 0.95, 0, 0 elseif k == 1 then return 0, 2.2, 0 else return 0, 0, 0.7 end
  end,
}
local camPos = vec3(0, -910, 2)
core_camera = {getPosition = function() return camPos end, getForward = function() return vec3(0, 1, 0) end}

-- scene objects: materials and the procedural mesh
local created, meshes, materialsMade = {}, {}, {}
-- a lake beside the road (a WaterBlock, x 20..60, y -500..-300, surface at z = 0.5): the ground there is under water
local lake = {getWorldBox = function() return {minExtents = vec3(20, -500, -3), maxExtents = vec3(60, -300, 0.5)} end}
scenetree = {MissionGroup = {add = function() end},
  findClassObjects = function(class) return class == 'WaterBlock' and {'lake'} or {} end,
  findObject = function(name) return name == 'lake' and lake or nil end}
function createObject(class)
  local o = {class = class, fields = {}}
  function o:setField(k, _, v) self.fields[k] = v end
  function o:registerObject(name) self.name = name if class == 'Material' then materialsMade[name] = self end end
  function o:setPosition() end
  function o:createMesh(m) meshes[#meshes + 1] = m end
  function o:delete() self.deleted = true end
  o.obj = o
  created[#created + 1] = o
  return o
end
local sounds = {}
Engine = {Audio = {playOnce = function(channel, file, opts) sounds[#sounds + 1] = file end}}
function setExtensionUnloadMode() end

-- imgui: just enough to run the windows
local function ptr(v) return {[0] = v} end
ui_imgui = setmetatable({
  BoolPtr = ptr, FloatPtr = ptr,
  ImVec2 = function(x, y) return {x = x, y = y} end,
  ImVec4 = function(x, y, z, w) return {x, y, z, w} end,
  GetMainViewport = function() return {Pos = {x = 0, y = 0}, Size = {x = 1920, y = 1080}} end,
  Begin = function() return true end,
  Button = function() return false end, Checkbox = function() return false end,
  GetFontSize = function() return 16 end,
  CalcTextSize = function(t) return {x = #t * 8, y = 16} end,
  ImTextureHandler = function(p) return {getID = function() return p end} end,
  WindowFlags_NoTitleBar = 1, WindowFlags_NoResize = 2, WindowFlags_NoMove = 4, WindowFlags_NoInputs = 8,
  WindowFlags_NoBackground = 16, WindowFlags_NoSavedSettings = 32, WindowFlags_NoScrollbar = 64,
  WindowFlags_NoFocusOnAppearing = 128, Cond_Always = 1, Cond_FirstUseEver = 2,
}, {__index = function() return function() end end})

-- run it
__carmapedsTest = {}  -- the app's test hook (it finds it through its environment)
local ext = dofile(BUILD .. '/lua/ge/extensions/carmapeds.lua')
ext.onExtensionLoaded()
local dt = 1 / 60
local placed, frames = nil, 0
while not placed and frames < 20000 do  -- loading, exploring, placing
  ext.onUpdate(dt, dt)
  frames = frames + 1
  for _, l in ipairs(logs) do if l:find('placed') then placed = l end end
end
print(('placed after %d frames (%.1f s at 60 fps)'):format(frames, frames / 60))
check(placed ~= nil, 'peds placed')
-- drive the player's car up the road through the peds at 20 m/s for 40 s, the camera behind it
local rays0, t0, meshes0 = rays, os.clock(), #meshes
for _ = 1, 2400 do
  player.pos = vec3(player.pos.x, player.pos.y + 20 * dt, 0.7)
  player.vel = vec3(0, 20, 0)
  camPos = vec3(0, player.pos.y - 10, 2)
  ext.onUpdate(dt, dt)
end
print(('while driving: %.1f raycasts and %.2f ms of Lua per frame, %.1f mesh rebuilds per s'):format((rays - rays0) / 2400,
  (os.clock() - t0) * 1000 / 2400, (#meshes - meshes0) / 40))
local errors = 0
for _, l in ipairs(logs) do if l:find('^E ') then errors = errors + 1 print('log: ' .. l) end end
for _, l in ipairs(logs) do if l:find('explored') or l:find('placed') or l:find('pedestrians') then print('log: ' .. l) end end
check(errors == 0, 'no errors logged')
check(#meshes > 0, 'ped mesh built')
local lastQuads, subs = 0, 0
for _, lod in ipairs(meshes[#meshes]) do for _, sm in ipairs(lod) do subs = subs + 1 lastQuads = lastQuads + #sm.verts / 4 end end
local mats = 0
for _ in pairs(materialsMade) do mats = mats + 1 end
print(('mesh rebuilds %d, last one %d quads in %d submeshes, %d materials, %d sounds'):format(#meshes, lastQuads, subs, mats, #sounds))
check(lastQuads > 0 and mats > 0, 'quads drawn with materials')
check(#sounds > 0, 'sounds played')
local dead = 0
for _, p in ipairs(__carmapedsTest.state().peds) do if p.hitPoints < 0 then dead = dead + 1 end end
local sc = __carmapedsTest.state().scores[0]
print(('dead %d, player credits %s'):format(dead, sc and sc.credits or 'none'))
check(dead > 0 and sc and sc.kills > 0, 'the player\'s car kills peds and scores')
-- a reset (BeamNG's onVehicleResetted) costs the recovery cost; another vehicle's id doesn't touch the player
local before = sc.credits
ext.onVehicleResetted(10)
ext.onUpdate(dt, dt)
local after = __carmapedsTest.state().scores[0].credits
print(('reset: %d -> %d credits'):format(before, after))
check(after - before == -4000, 'a reset costs 4000 credits: ' .. (after - before))
ext.onVehicleResetted(99)
ext.onUpdate(dt, dt)
check(__carmapedsTest.state().scores[0].credits == after, 'an unknown vehicle\'s reset costs nothing')
-- every submesh well formed: 4 verts, uvs, normals per quad, faces referencing them
local bad = 0
for _, lod in ipairs(meshes[#meshes]) do
  for _, sm in ipairs(lod) do
    if #sm.verts ~= #sm.uvs or #sm.verts ~= #sm.normals or #sm.faces ~= #sm.verts / 4 * 6 or not materialsMade[sm.material] then bad = bad + 1 end
    for _, f in ipairs(sm.faces) do if f.v < 0 or f.v >= #sm.verts then bad = bad + 1 end end
  end
end
check(bad == 0, 'submeshes well formed: ' .. bad .. ' bad')
-- a material's texture is a PNG file that was written
local texOk = false
for _, m in pairs(materialsMade) do
  local p = m.fields.colorMap
  if p then local f = io.open(p, 'rb') if f then texOk = f:read(4) == '\137PNG' f:close() end break end
end
check(texOk, 'ped textures written as PNG files')
-- peds stand on the ground (z = 0 in BeamNG) and are upright: the standing peds' sprites run from the ground to
-- the ped height in the data (0.25 C1 units = 1.725 m). (Gibs fall on below the ground before they go.)
local standing = 0
for _, lod in ipairs(meshes[#meshes]) do
  for _, sm in ipairs(lod) do
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(sm.verts) do lo, hi = math.min(lo, v.z), math.max(hi, v.z) end
    if math.abs(lo) < 0.01 and math.abs(hi - 1.725) < 0.01 then standing = standing + #sm.verts / 4 end
  end
end
check(standing > 20, 'standing peds drawn upright on the ground: ' .. standing)
-- the ped area: by default a 1 km square around the middle of the road network (0, 0) (peds go a few metres around
-- the explored points, so 20 m of leeway); none in the lake
local outside, wet, n = 0, 0, 0
for _, p in ipairs(__carmapedsTest.state().peds) do
  n = n + 1
  local x, y = p.path.x[1], p.path.z[1]  -- AC (x, z) = BeamNG (x, y)
  if math.abs(x) > 520 or math.abs(y) > 520 then outside = outside + 1 end
  if x > 20 and x < 60 and y > -500 and y < -300 then wet = wet + 1 end
end
print(('%d peds, %d outside the area, %d in the lake'):format(n, outside, wet))
check(n > 100 and outside == 0, 'peds only in the area')
check(wet == 0, 'no peds in the water')
local tested = false
for _, l in ipairs(logs) do if l:find('self-test', 1, true) then tested = true print('log: ' .. l) end end
check(tested, 'sprite mesh self-test ran')
ext.onClientEndMission()
check(created[#created] and true, 'objects created')
os.execute('rm -rf "' .. TMP .. '"')
print(failures == 0 and 'beamng test passed' or (failures .. ' failure(s)'))
os.exit(failures == 0 and 0 or 1)
