-- Kill credits and bonuses, per car, ported from dethrace pedestrn.c CheckPedestrianDeathScenario (credits,
-- combo multiplier, splatter / artistic impression / extra style / nice shot) and crush.c CheckPiledriverBonus.
local M = {}

-- Banner ids are C1's fancy head-up indices (displays.c / constants.h); images in loading.c's head-up list.
M.BANNER = {
  splatter = {index = 0, image = 'SPLATTER.PIX', text = 'SPLATTER BONUS'},
  piledriver = {index = 1, image = 'PILEDRIV.PIX', text = 'PILEDRIVER BONUS'},
  extraStyle = {index = 2, image = 'EXTRASTY.PIX', text = 'EXTRA STYLE BONUS'},
  artistic = {index = 3, image = 'ARTISTIC.PIX', text = 'BONUS FOR ARTISTIC IMPRESSION'},
  combo2 = {index = 4, image = '2XCOMBO.PIX', text = '2X COMBO BONUS'},
  combo3 = {index = 5, image = '3XCOMBO.PIX', text = '3X COMBO BONUS'},
  combo4 = {index = 6, image = '4XCOMBO.PIX', text = '4X COMBO BONUS'},
  combo5 = {index = 7, image = '5XCOMBO.PIX', text = '5X COMBO BONUS'},
  niceShot = {index = 8, image = 'BILLIARD.PIX', text = 'NICE SHOT, SIR!'},
  cunningStunt = {index = 9, image = 'POLITE.PIX', text = 'CUNNING STUNT BONUS'},
}

function M.bannerByIndex(index)
  for _, b in pairs(M.BANNER) do if b.index == index then return b end end
  return nil
end

-- Cunning stunt (dethrace car.c): the car went over (upside down at some point) and is back on its wheels for
-- half a second; at most one every 10 s. car: {upY (up . world up), onGround, teleported}.
M.STUNT_CREDITS = 1000  -- replaced by GENERAL.TXT's value (middle skill level)
function M.updateStunt(state, car, now)
  if car.teleported then  -- reset to the track (or similar): not a stunt
    state.wentOver, state.onWheelsSince = false, nil
    return 0, nil
  end
  if car.upY < 0 then state.wentOver = true end
  if state.wentOver and car.upY > 0.85 and car.onGround then
    state.onWheelsSince = state.onWheelsSince or now
    if now - state.onWheelsSince > 500 then
      state.wentOver, state.onWheelsSince = false, nil
      if now - (state.lastStunt or -1e9) > 10000 then
        state.lastStunt = now
        state.credits = state.credits + M.STUNT_CREDITS
        return M.STUNT_CREDITS, M.BANNER.cunningStunt
      end
    end
  else
    state.onWheelsSince = nil
  end
  return 0, nil
end

-- Thresholds for the car's state at the moment of the kill. C1 checks its own physics' angular velocity
-- (|omega.x| or |omega.z| > 5) and attitude (up . world up < 0.1); AC's are measured from the car's motion.
M.TUMBLE_RATE = 2.5      -- rad/s of pitch/roll rotation
M.FLIPPED_ATTITUDE = 0.1 -- car up . world up below this: on its side or roof
M.DRIFT_ANGLE = 25       -- degrees between heading and direction of travel
M.DRIFT_MIN_SPEED = 5    -- m/s

function M.newCarState()
  return {credits = 0, kills = 0, multiplier = 1, lastSplat = -1e9}
end

-- kill: {ped, exploded, side ('front'|'back'|'lside'|'rside'), niceShot}
-- car: {pitchRollRate, attitude, slipAngle, speed, reversing}
-- Returns credits earned and the banner (or nil).
function M.onKill(state, kill, car, now)
  if now - state.lastSplat <= 1000 then
    if state.multiplier < 5 then state.multiplier = state.multiplier + 1 end
  else
    state.multiplier = 1
  end
  state.lastSplat = now
  local credits = kill.ped.def.credits * state.multiplier
  if kill.exploded then credits = credits * 2 end
  local banner
  local drifting = (car.speed or 0) >= M.DRIFT_MIN_SPEED and (car.slipAngle or 0) >= M.DRIFT_ANGLE
  if kill.niceShot then
    credits = credits * 4
    banner = M.BANNER.niceShot
  elseif (car.pitchRollRate or 0) > M.TUMBLE_RATE or (car.attitude or 1) < M.FLIPPED_ATTITUDE or drifting then
    -- C1: tumbling or upside down. Drifting counts too (C1 gives sideways hits while sliding the extra style bonus).
    credits = credits * 4
    banner = M.BANNER.artistic
  elseif kill.side == 'back' and car.reversing then
    credits = credits * 2
    banner = M.BANNER.extraStyle
  elseif state.multiplier > 1 then
    banner = M.BANNER['combo' .. state.multiplier]
  elseif kill.exploded then
    banner = M.BANNER.splatter
  end
  state.credits = state.credits + credits
  state.kills = state.kills + 1
  return credits, banner
end

-- Piledriver: a car hits something while carrying a ped on the side it hit. impactX/Z: unit direction of the
-- impact in car space (x = side, z = look); carried: peds on the car, each with carriedLocal = {x, y, z}.
function M.onImpact(state, carried, impactX, impactZ, speed)
  if speed <= 0.001 * 6900 then return 0, nil end  -- C1: car speed > 0.001 world units per ms
  for _, ped in ipairs(carried) do
    local lx, lz = ped.carriedLocal[1], ped.carriedLocal[3]
    local len = math.sqrt(lx * lx + lz * lz)
    if len > 0 then
      lx, lz = lx / len, lz / len
      -- C1: ped towards the impact point (dot > 0.8) and the impact energy pushing back at it (dot < -0.65);
      -- the energy here is taken as opposite to the impact direction, so the second test is implied.
      if lx * impactX + lz * impactZ > 0.8 then
        local credits = math.floor((math.floor(ped.def.credits / 2) + 12) / 25) * 25
        state.credits = state.credits + credits
        return credits, M.BANNER.piledriver
      end
    end
  end
  return 0, nil
end

-- C1 DoFancyHeadup: a banner replaces the current one unless that one is under 2 s old and ranks higher.
function M.shouldShowBanner(current, currentTime, banner, now)
  return not (current and now - currentTime <= 2000 and current.index > banner.index)
end

return M
