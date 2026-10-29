-- Play the 4-player build with bots: you are one player, the script plays the others.
-- The ROM is not changed. Started by scripts/play_with_bots.sh, which sets HUMAN and
-- BOT_GOD below; can also be opened in Mesen's script window. The browser version runs
-- this same file (web/src/bots.cpp): its Lua host supplies emu.seats(),
-- each seat's role chosen in the page (any mix of people, bots and empty seats).
--
-- Needs: mesen-tmnt4p (tools/mesen-tmnt4p), Port 2 = Multitap with controllers on
-- sub-ports A-C. Your pad must be mapped to your player's port (mapping it to all
-- four is fine: the bots' ports are overridden every frame).
--
-- The bots
--   - leave the controllers alone on the title screen and menus (you do the
--     menus; with your pad mapped to every port it works on all of them);
--   - on the turtle select (four-player select active): P3/P4 join with START; all
--     bots confirm a turtle only after you have confirmed yours (you pick first);
--   - in play: walk to the nearest enemy, line up, attack; walk right when the
--     screen is clear; when their player is out, tap START (join / continue);
--   - on the full-screen continue: tap START.
-- Recorder (when REC_DIR is set; needs Mesen's "allow I/O and OS access" script
-- setting): events.log (mode changes, deaths, a status line per second, marks),
-- inputs.txt (all four pads every frame), pads.txt (what the game read, for exact
-- replays), states/<frame>.mss every 10 s (the last
-- hour kept), session.mmo (a Mesen movie of the whole session: scripts/make_video.sh
-- turns it into a video, an exact replay). Mark a moment: press M on the keyboard, or hold L + R + SELECT on your
-- pad for half a second.

local HUMAN = 1            -- your player, 1-4 (play_with_bots.sh sets this line)
local BOT_GOD = false      -- true: the bots' health is kept up
local PLAYERS = 4          -- players taking part (2-4): P1..PLAYERS; the others stay out
local REC_DIR = nil        -- recorder output directory (play_with_bots.sh sets it); nil = off
local VIDEO = nil          -- AVI to record from the start (play_with_bots.sh --video); nil = off
local START_STATE = nil    -- save state to start from (play_with_bots.sh --state); nil = power on

-- who plays which seat, per frame: "h" a person, "b" a bot, "-" stays out. The browser's
-- Lua host has emu.seats() (roles string, bots' god mode), changeable during play; in
-- Mesen it's HUMAN / PLAYERS / BOT_GOD above.
local role, botGod = {}, BOT_GOD
local function updateRoles()
  local s, god
  if emu.seats then s, god = emu.seats() end
  for p = 0, 3 do
    role[p] = s and s:sub(p + 1, p + 1) or (p >= PLAYERS and "-" or p == HUMAN - 1 and "h" or "b")
  end
  botGod = s and god or BOT_GOD
end
updateRoles()

local frame = 0
local ALL_BUTTONS = { "a", "b", "x", "y", "l", "r", "up", "down", "left", "right", "start", "select" }
-- player p (0-3): object slot, info block, controller (port, sub-port)
local SLOT = { [0] = 0x0400, 0x0470, 0x0630, 0x0710 }
local INFO = { [0] = 0x1A80, 0x1AC0, 0x1B20, 0x1B60 }
-- the game's versions: the Japanese one (header region $00) has P4's
-- info block and the landed-hit check elsewhere; Europe/Australia as the USA one
local JAPAN = emu.read(0x7FD9, emu.memType.snesPrgRom) == 0
if JAPAN then INFO[3] = 0x1D70 end
local PAD = { [0] = { 0, 0 }, { 1, 0 }, { 1, 1 }, { 1, 2 } }
local SEL4_STATE, SEL_SESSION, SEL_CONT = 0x1C8C, 0x1C9A, 0x1C9C
local PLAY_MODES = { [0x0A] = true, [0x0B] = true, [0x0C] = true, [0x16] = true,
                     [0x17] = true, [0x18] = true }
local MODE_SELECT, MODE_CONTINUE, MODE_CLEAR = 0x02, 0x0E, 0x0B

local function rd16(a)
  return emu.read(a, emu.memType.snesWorkRam) | (emu.read(a + 1, emu.memType.snesWorkRam) << 8)
end

local function none()
  local t = {}
  for _, b in ipairs(ALL_BUTTONS) do t[b] = false end
  return t
end

-- short presses: held for 2 frames every `period` frames, phase per player
local function tap(p, period)
  return (frame + p * 7) % period < 2
end

-- ---- fighting AI ----
-- Each bot has its own temperament (random per session): how long it sticks to a
-- target, which side it attacks from, how often it jumps or uses the special.
-- Targets: live objects in the enemy slots (11-19), not pizza, not ignored; chosen
-- among the nearest few with a penalty for enemies other bots already chase.
-- Learned per stage: things that can't be hurt (attacked for a while, no health
-- lost, no hit landed: ice blocks, lasers) are ignored for a while; damage taken
-- with no enemy close marks a hazard spot (laser doors) the bots keep out of.
-- Pizza is left for the player (bot or you) with the least health.
-- Blocked while walking (masts, crates): step up or down around it.
local ENEMY0, NENEMY = 0x08D0, 9
local PIZZA = { [0x030] = true, [0x02C] = true }
local IGNORE_FRAMES = 240          -- can't-hurt objects (props and walls are handled
                                   -- separately; this is for enemies that block a lot)
local GIVEUP_FRAMES = 150          -- attacking without effect before giving up
local HAZARD_FRAMES = 3600
local ATTACK_OBJ = { [0x05C0] = 0, [0x06A0] = 1, [0x1530] = 2, [0x1640] = 3 }

local bot = {}
for p = 0, 3 do
  bot[p] = {
    stick = 40 + math.random(0, 80),        -- frames before reconsidering the target
    side = math.random() < 0.5 and -1 or 1, -- preferred side of the enemy
    jumpy = math.random() * 0.25,           -- chance per attack window of a jump attack
    special = math.random() * 0.08,         -- chance of the special (Y+B)
    reach = 22 + math.random(0, 14),        -- attack distance
    target = nil, since = 0, nextLook = 0,
    hitsAt = 0, effortStart = nil, effortHp = nil,
    lastX = nil, stuckFor = 0, detour = 0, detourDir = nil, holdDir = nil, pass = 0,
    hp = nil, combo = 0,
  }
end
local ignoreUntil = {}                     -- [slot..":"..type] = frame
local mem = {}                             -- per object, see updateObjects
local hazards = {}                         -- { x, y, scroll, untilFrame }
local lastScroll, lastProgress, exploreUntil = nil, 0, 0
local STALL_FRAMES, EXPLORE_FRAMES, MOVE_FRAMES = 300, 720, 60
local EXPLORE_MOVES = {
  { "up", "right" }, { "down", "right" }, { "up" }, { "down" },
  { "right", "b" }, { "left" }, { "up", "left" }, { "down", "left" },
}

local function scrollKey() return rd16(0x17A0) .. ":" .. rd16(0x17B0) end

local function updateProgress()
  local sc = scrollKey()
  if sc ~= lastScroll then
    lastScroll, lastProgress, exploreUntil = sc, frame, 0
  elseif exploreUntil == 0 and frame - lastProgress > STALL_FRAMES then
    exploreUntil = frame + EXPLORE_FRAMES
  elseif exploreUntil ~= 0 and frame >= exploreUntil then
    lastProgress, exploreUntil = frame, 0
  end
end

-- landed hits per player (Y = the player's attack object at $03:839D; Japan $03:8374)
emu.addMemoryCallback(function()
  local p = ATTACK_OBJ[emu.getState()["cpu.y"]]
  if p then
    bot[p].hitsAt = frame
    -- a landed hit proves the target can be hurt (bosses keep health elsewhere)
    local t = bot[p].target
    local m = t and mem[t .. ":" .. rd16(t + 0x14)]
    if m then m.hurt = true end
  end
end, emu.callbackType.exec, JAPAN and 0x038374 or 0x03839D)

local function key(slot) return slot .. ":" .. rd16(slot + 0x14) end

-- per object (slot + type), updated once per frame: when it last moved, whether it
-- ever lost health, how long bots have chased it. Scenery = never hurt and not
-- moved for STATIC_FRAMES (laser doors, ice blocks, props): never a target.
local STATIC_FRAMES, CHASE_FRAMES = 240, 900
local function updateObjects()
  local seen = {}
  for k = 0, NENEMY - 1 do
    local e = ENEMY0 + k * 0x70
    local t = rd16(e + 0x14)
    if t ~= 0 and rd16(e) ~= 0 then
      local id = key(e)
      seen[id] = true
      local x, y, hp = rd16(e + 0x08), rd16(e + 0x0C), rd16(e + 0x4A)
      local m = mem[id]
      if not m then m = { first = frame, moved = frame, x = x, y = y, hp = hp, hurt = false, chased = 0 }; mem[id] = m end
      if x ~= m.x or y ~= m.y then m.moved, m.x, m.y = frame, x, y end
      if hp < m.hp then m.hurt = true end
      m.hp = hp
    end
  end
  -- gone: forget it, so a new enemy in the same slot doesn't inherit an ignore
  for id in pairs(mem) do if not seen[id] then mem[id] = nil; ignoreUntil[id] = nil end end
end

local function scenery(id)
  local m = mem[id]
  return m and not m.hurt and frame - m.moved > STATIC_FRAMES
end

-- Electrified walls (the laser doors in the Technodrome and before Tokka/Rahzar,
-- type $0D6) and any object type a bot got electrocuted next to: never a target;
-- bots keep WALL_GAP away from them (by the object's position, whatever the scroll).
local hazardType = { [0x0D6] = true, [0x036] = true }   -- laser doors, Scene 1 lightning thrower
local GROUND_HIT = { [0x152] = true }                   -- Krang (Scene 9 boss)
-- Neon Night-Riders (mode $16): the Foot soldiers in flying vehicles ($13C, after the
-- platform soldiers) glide across their lane high up and are jump-kicked as they reach
-- the foreground: handled apart from the generic airborne case below.
local NEON_FLIER = { [0x13C] = true }
-- ... and the platform soldiers before them ($186, $188, $18A) are fought with normal
-- swings, standing 12 px below their y (a person's 24 hits on them: player y - soldier
-- y = 11-12 in 23, swing within ~50 px either side): they count as being on that line
local NEON_PLATFORM = { [0x186] = true, [0x188] = true, [0x18A] = true }
local WALL_GAP = 40
local walls = {}

local function enemies()
  local list, pizzas = {}, {}
  walls = {}
  for k = 0, NENEMY - 1 do
    local e = ENEMY0 + k * 0x70
    local t = rd16(e + 0x14)
    if t ~= 0 and rd16(e) ~= 0 then
      local id = key(e)
      local h = rd16(e + 0x10)                  -- height above the ground (negative up)
      if h >= 0x8000 then h = h - 0x10000 end
      -- high up: out of reach of ground attacks, except bosses drawn high but hit from
      -- the ground (Krang's android, Scene 9: height about -72)
      local o = { slot = e, x = rd16(e + 0x08), y = rd16(e + 0x0C), hp = rd16(e + 0x4A),
                  air = h < -24 and not GROUND_HIT[t] and not (NEON_FLIER[t] and (rd16(0x0070) & 0xFF) == 0x16),
                  h = h }
      if NEON_PLATFORM[t] and (rd16(0x0070) & 0xFF) == 0x16 then o.y = o.y + 12 end
      if PIZZA[t] then pizzas[#pizzas + 1] = o
      elseif hazardType[t] then walls[#walls + 1] = o
      elseif o.x < 0x110 and not scenery(id) and not (ignoreUntil[id] and frame < ignoreUntil[id])   -- on screen only: enemies wait off it
             and not (o.hp == 0 and not (mem[id] and mem[id].hurt)) then   -- no health, never hurt: a prop (Scene 1's lightning thrower)
        list[#list + 1] = o
      end
    end
  end
  return list, pizzas
end

local function alive(p) return rd16(SLOT[p] + 0x14) ~= 0 and role[p] ~= "-" end

-- the player (human or bot) who most needs a pizza: least health, then fewest lives
local function neediest()
  local best, bh
  for q = 0, 3 do
    if alive(q) then
      local h = rd16(SLOT[q] + 0x4A) * 16 + math.min(15, rd16(INFO[q] + 0x20))
      if not bh or h < bh then best, bh = q, h end
    end
  end
  return best
end

-- the wall whose keep-out zone (x, y) is in
local function nearWall(x, y)
  for _, w in ipairs(walls) do
    if math.abs(x - w.x) < WALL_GAP and math.abs(y - w.y) < 48 then return w end
  end
end

local function nearHazard(x, y, any)
  local w = nearWall(x, y)
  if w then return { x = w.x, y = y, count = 2 } end
  local sc = scrollKey()
  for _, h in ipairs(hazards) do
    if frame < h.untilFrame and h.scroll == sc and (any or h.count >= 2)
       and math.abs(x - h.x) < 30 and math.abs(y - h.y) < 14 then
      return h
    end
  end
end

-- damage with no enemy close: remember the spot (a hazard once hit there twice;
-- run at the end of the frame, before god mode refills health)
local SHOCKED = 0x18                       -- player state: electrocuted (laser doors, walls)
local RUNNING = 0x07                       -- player state: running (after a double press)
local function learnHazard(p)
  local b = bot[p]
  local px, py = rd16(SLOT[p] + 0x08), rd16(SLOT[p] + 0x0C)
  local hp = rd16(SLOT[p] + 0x4A)
  local st = rd16(SLOT[p] + 0x16)
  if st == SHOCKED and b.state ~= SHOCKED then
    -- electrocuted: the prop next to us is an electrified wall from now on. Only
    -- props (no health, never hurt): the nearest object was often a Foot soldier
    -- (the lightning thrower is out of this range), and its whole type stopped
    -- being a target for the rest of the session
    local best, bd
    for k = 0, NENEMY - 1 do
      local e = ENEMY0 + k * 0x70
      local t = rd16(e + 0x14)
      local m = mem[key(e)]
      if t ~= 0 and rd16(e) ~= 0 and not PIZZA[t] and rd16(e + 0x4A) == 0 and not (m and m.hurt) then
        local d = math.abs(rd16(e + 0x08) - px) + math.abs(rd16(e + 0x0C) - py)
        if math.abs(rd16(e + 0x08) - px) < 56 and math.abs(rd16(e + 0x0C) - py) < 40 and (not bd or d < bd) then best, bd = t, d end
      end
    end
    if best then hazardType[best] = true end
    -- and a hazard spot right away, enemies near or not
    local h = nearHazard(px, py, true)
    if h then h.count, h.untilFrame = math.max(h.count, 2), frame + HAZARD_FRAMES
    else hazards[#hazards + 1] = { x = px, y = py, count = 2, scroll = scrollKey(), untilFrame = frame + HAZARD_FRAMES } end
  end
  b.state = st
  if b.hp and hp < b.hp and rd16(SLOT[p] + 0x14) ~= 0 then
    local list = enemies()
    -- any enemy on screen: the damage came from it, whatever the distance (enemies reach
    -- ~60 px; Baxter's beam hit bots 85 px from its nearest part, so spots covered
    -- his arena and the bots stood at their edges); also a projectile next to us
    -- (no health, so not in the list: thrown things)
    local close = #list > 0
    for k = 0, NENEMY - 1 do
      local o = ENEMY0 + k * 0x70
      if not close and rd16(o + 0x14) ~= 0 and rd16(o) ~= 0 and not PIZZA[rd16(o + 0x14)]
         and math.abs(rd16(o + 0x08) - px) < 48 and math.abs(rd16(o + 0x0C) - py) < 24 then close = true end
    end
    if not close then
      local h = nearHazard(px, py, true)
      if h then h.count, h.untilFrame = h.count + 1, frame + HAZARD_FRAMES
      else hazards[#hazards + 1] = { x = px, y = py, count = 1, scroll = scrollKey(), untilFrame = frame + HAZARD_FRAMES } end
    end
  end
  b.hp = hp
end

local function chooseTarget(p, px, py, list)
  local b = bot[p]
  local still = false
  for _, e in ipairs(list) do if e.slot == b.target then still = true end end
  if still and frame < b.nextLook then return end
  local chasers = {}
  for q = 0, 3 do if q ~= p and bot[q].target then chasers[bot[q].target] = (chasers[bot[q].target] or 0) + 1 end end
  local scored = {}
  for _, e in ipairs(list) do
    local d = math.abs(e.x - px) + 2 * math.abs(e.y - py) + 90 * (chasers[e.slot] or 0)
    if nearHazard(e.x, e.y) then d = d + 200 end
    if e.air then d = d + 150 end                     -- flying (Baxter): out of reach for now
    scored[#scored + 1] = { e = e, d = d }
  end
  table.sort(scored, function(u, v) return u.d < v.d end)
  local pick
  if #scored > 0 then
    local r = math.random()
    pick = scored[(r < 0.6 or #scored == 1) and 1 or (r < 0.9 or #scored == 2) and 2 or 3].e
  end
  local slot = pick and pick.slot
  if slot ~= b.target then b.target, b.since, b.effortStart, b.hp0 = slot, frame, nil, pick and pick.hp end
  b.nextLook = frame + b.stick
end

-- give up on a target being attacked without effect
local function checkEffort(p, e, inRange)
  local b = bot[p]
  if not inRange then b.effortStart = nil return end
  if not b.effortStart then b.effortStart, b.effortHp = frame, e.hp return end
  if e.hp < b.effortHp or frame - b.hitsAt < 30 then b.effortStart, b.effortHp = frame, e.hp return end
  if frame - b.effortStart > GIVEUP_FRAMES then
    ignoreUntil[key(e.slot)] = frame + IGNORE_FRAMES
    b.target, b.effortStart = nil, nil
  end
end

-- walking: keep out of hazards, step around obstacles
local function walk(p, t, px, py, dir, wantY)
  local b = bot[p]
  if dir then
    local nx = px + (dir == "right" and 12 or -12)
    if nearHazard(nx, py) and not nearHazard(px, py) then dir = nil end
  end
  if dir then
    if b.holdDir == dir and b.lastX and math.abs(px - b.lastX) < 1 then b.stuckFor = b.stuckFor + 1 else b.stuckFor = 0 end
    if b.stuckFor > 12 and b.detour == 0 then
      b.detour, b.detourY, b.pass = 36, py, 0
      if wantY and math.abs(wantY - py) > 4 then b.detourDir = wantY > py and "down" or "up"
      else b.detourDir = (b.detourDir == "up") and "down" or "up" end
    end
    t[dir] = true
  end
  -- Around an obstacle (terrain, e.g. the dumpster in Alleycat Blues: two bots 10 s in
  -- place in a user's session). The game cancels a whole step that runs into a
  -- blocked tile, both directions, so: straight up or down (the other way if that
  -- doesn't move within 6 frames; backing off sideways if neither does), and once 4 px
  -- away, straight ahead for 24 frames before steering toward wantY again.
  if b.detour > 0 then
    b.detour = b.detour - 1
    t.up, t.down, t.left, t.right = false, false, false, false
    if math.abs(py - b.detourY) >= 4 then
      b.detour, b.pass, b.passDir = 0, 24, b.holdDir
      if dir then t[dir] = true end
    else
      if py == b.detourY and b.detour == 30 then b.detourDir = b.detourDir == "up" and "down" or "up" end
      if py == b.detourY and b.detour <= 24 and b.holdDir then t[b.holdDir == "right" and "left" or "right"] = true
      else t[b.detourDir] = true end
    end
  elseif b.pass > 0 and dir and dir == b.passDir then
    b.pass = b.pass - 1
    t.up, t.down = false, false
  elseif wantY then
    -- not up or down into a hazard zone (it would only have to back out again)
    if wantY > py + 3 and not (nearHazard(px, py + 4) and not nearHazard(px, py)) then t.down = true
    elseif wantY < py - 3 and not (nearHazard(px, py - 4) and not nearHazard(px, py)) then t.up = true end
  end
  b.holdDir, b.lastX, b.lastY = dir, px, py
end

-- the first bot (lower number) other than p chasing slot
local function firstOn(slot, p)
  for q = 0, p - 1 do if bot[q].target == slot then return q end end
  return p
end

-- not attacking: step up/down away from any player standing on top of us
local function apart(p, t, px, py)
  for q = 0, 3 do
    if q ~= p and alive(q) then
      local qx, qy = rd16(SLOT[q] + 0x08), rd16(SLOT[q] + 0x0C)
      if math.abs(qx - px) < 16 and math.abs(qy - py) < 8 then
        local up = (qy > py) or (qy == py and p < q)
        t.up, t.down = up, not up
        return
      end
    end
  end
end

-- toward a nearby electrified wall: no second press soon after a release (two
-- presses make a dash, which slides into the wall), no running, no jumps
local function noDash(p, t)
  local b = bot[p]
  local px, py = rd16(SLOT[p] + 0x08), rd16(SLOT[p] + 0x0C)
  b.held, b.released = b.held or {}, b.released or {}
  local running = rd16(SLOT[p] + 0x16) == RUNNING
  for _, d in ipairs({ "left", "right" }) do
    local ahead = nearWall(px + (d == "right" and 64 or -64), py) or nearWall(px + (d == "right" and 120 or -120), py)
    if t[d] and ahead and (running or (not b.held[d] and frame - (b.released[d] or -999) < 30)) then
      t[d] = false                  -- running stops when let go
    end
    if t[d] then b.held[d] = true
    elseif b.held[d] then b.held[d], b.released[d] = false, frame end
  end
  -- no jumping near one either (a jump carries 25-60 px)
  if t.b and (nearWall(px + 50, py) or nearWall(px + 100, py) or nearWall(px - 50, py) or nearWall(px - 100, py)) then
    t.b = false
  end
  return t
end

local function fight(p)
  local me = SLOT[p]
  local b = bot[p]
  local t = none()
  if rd16(me + 0x14) == 0 then
    t.start = tap(p, 60)      -- out: join / continue
    b.target = nil
    return t
  end
  local px, py = rd16(me + 0x08), rd16(me + 0x0C)
  local list, pizzas = enemies()
  -- standing in a hazard spot: back out (away from its center and up/down)
  -- (backing out takes a quarter second once started: re-deciding every frame at the
  -- zone's edge flip-flopped between "out" and "back to the target")
  if b.outUntil and frame < b.outUntil then
    t[b.outX] = true
    if b.outY then t[b.outY] = true end
    return t
  end
  local h = nearHazard(px, py)
  if h then
    local away = px <= h.x and "left" or "right"
    -- no room that way (screen edge): go past it instead (a moving hazard pinned
    -- bots at the left edge, Scene 1)
    if away == "left" and px < 52 then away = "right" elseif away == "right" and px > 204 then away = "left" end
    t[away] = true
    local vert = not nearWall(px, py) and (py <= h.y and "up" or "down") or nil   -- walls: straight out
    if vert then t[vert] = true end
    b.outUntil, b.outX, b.outY = frame + 15, away, vert
    return t
  end
  if exploreUntil ~= 0 and #list == 0 then   -- stuck with nothing to fight (not: a locked fight)
    local phase = (frame // MOVE_FRAMES + p * 3) % #EXPLORE_MOVES
    for _, k in ipairs(EXPLORE_MOVES[phase + 1]) do t[k] = true end
    t.y = (frame % 12) < 3
    return t
  end
  -- pizza: go for it if we need it most and are hurt; others keep off it
  local needy = neediest() == p
  for _, z in ipairs(pizzas) do
    if needy and rd16(me + 0x4A) < (b.hpMax or 0) - 8 then
      walk(p, t, px, py, (z.x > px + 4) and "right" or (z.x < px - 4) and "left" or nil, z.y)
      return t
    end
  end
  b.hpMax = math.max(b.hpMax or 0, rd16(me + 0x4A))
  chooseTarget(p, px, py, list)
  local e
  for _, o in ipairs(list) do if o.slot == b.target then e = o end end
  if e then
    local m = mem[key(e.slot)]
    if m then
      m.chased = m.chased + 1
      if m.chased > CHASE_FRAMES and not m.hurt and e.hp == 0 then   -- with health it can be hurt: keep at it
        ignoreUntil[key(e.slot)] = frame + IGNORE_FRAMES   -- chased long, never hurt
        b.target, e = nil, nil
      end
    end
  end
  if not e then
    -- nothing to fight on screen: move on to the right (around obstacles), but
    -- not up against the right edge (in a locked room that's where doors are)
    -- each bot stops at its own place (not all at the same x)
    local stopX = 200 - 22 * p
    if px < stopX - 8 then
      walk(p, t, px, py, "right", nil)
      if frame % 90 < 4 then t.b = true end
    elseif px > stopX + 16 then
      walk(p, t, px, py, "left", nil)
    end
    apart(p, t, px, py)
  else
    -- sharing a target: the second bot takes the other side, a third and fourth the
    -- same sides a little higher/lower (still in reach: a lone boss needs everyone)
    local rank = 0
    for q = 0, p - 1 do
      if alive(q) and bot[q].target == e.slot then rank = rank + 1 end
    end
    local function usable(sd, r)            -- that side's spot is on screen, not at a wall
      local x = e.x + sd * r
      return x >= 20 and x <= 236 and not nearWall(x, e.y)
    end
    local side, yOff, reach = b.side, 0, b.reach
    local crowd = #list > 1                  -- spacing only in crowds: a lone boss needs
    if not crowd then rank = 0 end           -- everyone on it (measured: Leatherhead)
    if rank == 0 then
      if (side < 0 and px > e.x) or (side > 0 and px < e.x) then side = px < e.x and -1 or 1 end
    else
      local f = bot[firstOn(e.slot, p)]
      local first = usable(f.side, f.reach) and f.side or -f.side
      side = (rank % 2 == 1) and -first or first
      if rank >= 2 then yOff = rank == 2 and 3 or -3 end
    end
    if crowd and not usable(side, reach) then side = -side end
    local spotX = e.x + side * reach
    local dx = spotX - px
    if NEON_FLIER[rd16(e.slot + 0x14)] and (rd16(0x0070) & 0xFF) == 0x16 then
      -- Neon Night-Riders' fliers glide along their lane (x speed +$1E) and can be hit
      -- as they reach the foreground (approach countdown +$3A at 2 or 1). A person's hits
      -- in a 40-minute session: a jump at the flier from 35-140 px (B + direction), Y near
      -- the top (height about -100). Wait in the lane ahead of them and do the same
      local vx = rd16(e.slot + 0x1E)
      local dir = (vx >= 0x8000) and -1 or 1
      if b.neonFor ~= e.slot then
        -- they reach the foreground around x 156 (coming from the right) / x 100 (from
        -- the left): stand about 33 px beyond that, where they are heading
        b.neonFor = e.slot
        b.neonX = (dir < 0 and 156 - 33 or 100 + 33) + dir * 10 * rank
      end
      local wx = b.neonX - px
      local face = e.x >= px and "right" or "left"
      local ph = rd16(SLOT[p] + 0x10)
      if ph >= 0x8000 then ph = ph - 0x10000 end
      local stage = rd16(e.slot + 0x3A)
      local inLane = math.abs(e.y - py) <= 12
      if ph > -8 and not b.jumpHold then
        walk(p, t, px, py, math.abs(wx) > 4 and (wx > 0 and "right" or "left") or nil, e.y + yOff)
        if math.abs(wx) <= 4 and frame % 16 < 2 then t[face] = true end
        if stage >= 2 and stage <= 3 and inLane and math.abs(e.x - px) <= 100 then
          b.jumpHold = frame + 16                -- jump at it, B held: full height
        end
      end
      if b.jumpHold then
        t[face] = true
        if frame < b.jumpHold then t.b = true end
        if ph < -85 then t.y = true end          -- near the top: kick
        if ph > -8 and frame >= b.jumpHold + 8 then b.jumpHold = nil end
      end
      return t
    end
    if e.air then
      -- flying (Baxter Stockman, Neon Night-Riders' Foot soldiers on their platforms):
      -- ground attacks can't reach. Line up beside it, jump and attack in the air;
      -- if it's too high for a jump, wait nearby and close in when it comes down.
      local ph = rd16(SLOT[p] + 0x10)
      if ph >= 0x8000 then ph = ph - 0x10000 end
      if e.h > -140 then
        local inLane = math.abs(e.y - py) <= 6
        if math.abs(dx) <= 10 and inLane then
          t[e.x >= px and "right" or "left"] = frame % 16 < 2
          if ph > -8 and not b.jumpHold then
            b.jumpHold = frame + 16                          -- jump, B held: full height
          end
          if b.jumpHold and frame < b.jumpHold then t.b = true end
          if ph > -8 and b.jumpHold and frame >= b.jumpHold + 8 then b.jumpHold = nil end
          if ph < -24 and ph <= e.h + 28 then
            t.y = (frame % 4) < 2                            -- level with it: attack
          end
        else
          walk(p, t, px, py, math.abs(dx) > 6 and (dx > 0 and "right" or "left") or nil, e.y + yOff)
        end
        return t
      end
      local wait = e.x + (px < e.x and -1 or 1) * (b.reach + 28)
      if wait < 20 or wait > 236 then wait = e.x + (px < e.x and 1 or -1) * (b.reach + 28) end
      local d = wait - px
      walk(p, t, px, py, math.abs(d) > 8 and (d > 0 and "right" or "left") or nil, e.y)
      if crowd then apart(p, t, px, py) end
      return t
    end
    local inRange = math.abs(e.x - px) <= b.reach + 10 and math.abs(e.y - py) <= 6
    checkEffort(p, e, inRange)
    local dir = math.abs(dx) > 6 and (dx > 0 and "right" or "left") or nil
    -- avoid pizza we shouldn't take
    if not needy then
      for _, z in ipairs(pizzas) do
        if math.abs(z.y - py) < 12 and math.abs(z.x - (px + (dir == "right" and 16 or dir == "left" and -16 or 0))) < 14 then
          walk(p, t, px, py, nil, py + (z.y >= py and -16 or 16))
          return t
        end
      end
    end
    if inRange then
      local face = e.x >= px and "right" or "left"
      if frame % 16 < 2 then t[face] = true end
      b.combo = b.combo + 1
      local r = math.random()
      local wallAhead = nearWall(px + (face == "right" and 48 or -48), py)   -- no lunging into it
      if r < b.special / 60 and not wallAhead then t.y, t.b = true, true    -- costs health: rare
      elseif r < (b.special + b.jumpy) / 8 and frame % 6 == 0 and not wallAhead then t.b = true
      else t.y = (frame % 6) < 3 end
      if math.abs(e.y + yOff - py) > 2 then t[e.y + yOff > py and "down" or "up"] = true end
    else
      walk(p, t, px, py, dir, e.y + yOff)
      if crowd and math.abs(dx) > 48 then apart(p, t, px, py) end   -- not near the target: its line matters
    end
  end
  return t
end

-- ---- turtle select (patches/select4.asm) ----
local function joined(p)
  if p < 2 then return true end
  return (rd16(SEL_SESSION) & (p == 2 and 0x0004 or 0x0008)) ~= 0
end

local function confirmed(p)
  return rd16(INFO[p] + 0x10) ~= 0
end

local function select(p)
  local t = none()
  if not joined(p) then
    if rd16(SEL_CONT) == 0 then t.start = tap(p, 30) end
    return t
  end
  if confirmed(p) then return t end
  -- people pick first: wait until every person has joined and confirmed (if they
  -- never do, the select screen's timer ends it as usual)
  for h = 0, 3 do
    if role[h] == "h" and not (joined(h) and confirmed(h)) then return t end
  end
  t.b = tap(p, 24)
  return t
end

-- ---- per frame ----
emu.addEventCallback(function()
  updateRoles()
  local mode = rd16(0x0070) & 0xFF
  local play = PLAY_MODES[mode]
  if play then updateProgress() end
  for p = 0, 3 do
    if role[p] == "-" then
      -- not taking part: its controller stays silent where it could join or
      -- continue (your pad may be mapped to it)
      if (mode == MODE_SELECT and rd16(SEL4_STATE) == 1) or play or mode == MODE_CONTINUE then
        emu.setInput(none(), 0, PAD[p][1], PAD[p][2])
      end
    elseif role[p] == "b" then
      local t
      if mode == MODE_SELECT and rd16(SEL4_STATE) == 1 then
        t = select(p)
      elseif play then
        t = noDash(p, fight(p))
      elseif mode == MODE_CONTINUE then
        t = none()
        t.start = rd16(SLOT[p] + 0x14) == 0 and tap(p, 60)
      end
      -- other screens (title, menus, game over, ending): controllers left alone, so
      -- your pad works the menus on whichever ports it is mapped to.
      -- Mesen's setInput ignores its 2nd argument: (input, _, port, subport)
      if t then emu.setInput(t, 0, PAD[p][1], PAD[p][2]) end
    end
  end
end, emu.eventType.inputPolled)

-- god mode: full health by turtle (type +$14; ROM table $01:9639, set at spawn by $00:AF72).
-- The HUD bar (info +$22, 0-16) is computed only when health changes ($00:C8AF), from the
-- health right after the hit, so refilling the health alone left a gap in the bar: set the
-- full bar too and flag it for redrawing (info +$2C bit 0), as $00:C8AF does.
-- Not on the stage-clear screen (mode $0B, every stage): there $04:AE64 counts each HUD
-- bar down into the score, a point per segment, and the refill made that count go on
-- forever (user report).
local FULL_HP = { [2] = 80, [4] = 96, [6] = 64, [8] = 48 }   -- Leo, Mike, Don, Raph
local godMax = {}
local function wr16(a, v)
  emu.write(a, v & 0xFF, emu.memType.snesWorkRam)
  emu.write(a + 1, v >> 8, emu.memType.snesWorkRam)
end
emu.addEventCallback(function()
  frame = frame + 1
  if PLAY_MODES[rd16(0x0070) & 0xFF] then
    updateObjects()
    for p = 0, 3 do
      if role[p] == "b" then learnHazard(p) end
    end
  end
  if botGod and (rd16(0x0070) & 0xFF) ~= MODE_CLEAR then
    for p = 0, 3 do
      if role[p] == "b" then
        local slot = SLOT[p]
        local hp, ty = rd16(slot + 0x4A), rd16(slot + 0x14)
        godMax[slot] = math.max(godMax[slot] or 0, hp)
        local full = FULL_HP[ty] or godMax[slot]
        if ty ~= 0 and hp > 0 and (hp < full or rd16(INFO[p] + 0x22) < 16) then
          wr16(slot + 0x4A, full)
          wr16(INFO[p] + 0x22, 16)
          wr16(INFO[p] + 0x2C, rd16(INFO[p] + 0x2C) | 1)
        end
      end
    end
  end
  if frame < 360 then
    emu.drawString(4, 210, string.format("Bots on: you are P%d of %d%s", HUMAN, PLAYERS, BOT_GOD and " (bots: god mode)" or ""),
                   0xFFFFFF, 0x80000000)
  end
end, emu.eventType.endFrame)

-- ---- start state (play_with_bots.sh --state): loaded at the first NMI entry, where
-- the recorder makes its states (states must be loaded inside a CPU exec callback) ----
local startLoadedAt = nil                  -- frame the start state was loaded at
if START_STATE then
  local data = assert(io.open(START_STATE, "rb")):read("a")
  local function loader()
    if startLoadedAt then return end
    startLoadedAt = frame
    emu.loadSavestate(data)
  end
  for _, b in ipairs({ 0x000000, 0x800000 }) do emu.addMemoryCallback(loader, emu.callbackType.exec, b + 0x8174) end
end

-- ---- video (play_with_bots.sh --video): Mesen's AVI recorder, game picture and
-- sound only (no script text); the file is finished when Mesen closes ----
if VIDEO then
  if emu.startVideoRecording then
    emu.startVideoRecording(VIDEO)
  else
    emu.displayMessage("Video", "this Mesen can't record from a script: rebuild it (scripts/setup.sh)")
  end
end

-- ---- recorder ----
if REC_DIR then
  local MODE_NAMES = { [0x02] = "select", [0x03] = "title", [0x04] = "scene card", [0x0A] = "stage",
    [0x0B] = "stage clear", [0x0C] = "stage intro", [0x0D] = "game over", [0x0E] = "continue",
    [0x0F] = "ending", [0x16] = "scene 8", [0x18] = "Shredder tank", [0x19] = "time warp" }
  local CHAR = { [2] = "Leo", [4] = "Mike", [6] = "Don", [8] = "Raph" }
  local STATE_EVERY, STATES_KEPT = 600, 360
  local ev = io.open(REC_DIR .. "/events.log", "a")
  local inp = io.open(REC_DIR .. "/inputs.txt", "a")
  local saved, lastMode, lastInfo, markHeld, markShow = {}, nil, {}, 0, 0
  local marked = false
  local pendingState, pendingName = false, nil
  local function stamp() return os.date("%H:%M:%S") .. string.format(" f%d", frame) end
  local function log(fmt, ...) ev:write(stamp() .. " " .. string.format(fmt, ...) .. "\n") end
  local BUTTON_BITS = { "a", "b", "x", "y", "l", "r", "up", "down", "left", "right", "start", "select" }
  local function mask(t)
    local v = 0
    for i, k in ipairs(BUTTON_BITS) do if t[k] then v = v | (1 << (i - 1)) end end
    return v
  end
  log("session start: you are P%d of %d%s", HUMAN, PLAYERS, BOT_GOD and ", bots god mode" or "")
  local okr, rom = pcall(emu.getRomInfo)
  if okr and rom then log("rom %s sha1 %s", tostring(rom.name), tostring(rom.fileSha1Hash)) end
  inp:write("# frame P1 P2 P3 P4 (bits: a b x y l r up down left right start select)\n")

  -- pads as the game will read them (after the bots' overrides)
  emu.addEventCallback(function()
    local m = {}
    for p = 0, 3 do
      local ok, t = pcall(emu.getInput, PAD[p][1], PAD[p][2])
      m[#m + 1] = string.format("%03X", ok and mask(t) or 0)
    end
    inp:write(frame, " ", table.concat(m, " "), "\n")
    -- mark: M on the keyboard, or L + R + SELECT held on your pad for half a second
    local ok, down = pcall(emu.isKeyPressed, "M")
    local okp, t = pcall(emu.getInput, PAD[HUMAN - 1][1], PAD[HUMAN - 1][2])
    local combo = okp and t.l and t.r and t.select
    if ok and down then markHeld = markHeld + 30 elseif combo then markHeld = markHeld + 1 else markHeld = 0 end
    if markHeld >= 30 and not marked then
      marked = true
      log("MARK (%s)", ok and down and "M key" or "L+R+SELECT")
      pendingState, pendingName = true, string.format("mark_%d.mss", frame)
      markShow = 120
    end
    if markHeld == 0 then marked = false end
  end, emu.eventType.inputPolled)

  local function rd8(a) return emu.read(a, emu.memType.snesWorkRam) end
  emu.addEventCallback(function()
    local mode = rd8(0x70)
    if mode ~= lastMode then
      log("mode %02X %s (scene index %d)", mode, MODE_NAMES[mode] or "", rd8(0x82))
      lastMode = mode
    end
    for p = 0, 3 do
      local st = rd16(INFO[p])
      if lastInfo[p] and st ~= lastInfo[p] then
        log("P%d info state %d -> %d (lives %d)%s", p + 1, lastInfo[p], st, rd16(INFO[p] + 0x20), st == 6 and " GAME OVER" or "")
      end
      lastInfo[p] = st
    end
    if frame % 60 == 0 then
      local t = {}
      for p = 0, 3 do
        local s = SLOT[p]
        if rd16(s + 0x14) ~= 0 then
          t[#t + 1] = string.format("P%d %s st%02X x%d y%d hp%d lives%d", p + 1, CHAR[rd16(s + 0x14)] or "?",
            rd16(s + 0x16), rd16(s + 8), rd16(s + 0xC), rd16(s + 0x4A), rd16(INFO[p] + 0x20))
        else t[#t + 1] = string.format("P%d out", p + 1) end
      end
      log("status mode %02X cam %d | %s", mode, rd16(0x17A0), table.concat(t, " | "))
      ev:flush(); inp:flush()
    end
    if frame % STATE_EVERY == 0 then pendingState, pendingName = true, nil end
    if markShow > 0 then
      markShow = markShow - 1
      emu.drawString(80, 100, "MARKED", 0xFFFF00, 0x80000000)
    end
  end, emu.eventType.endFrame)

  -- what the game read: P1-P4 held/new ($0020-$002F) and combined ($00DC-$00DF),
  -- right after the NMI's joypad routine (JSL $0085E8 returns to $00:81CF); the exact
  -- input for replays (scripts/lua/replay_rec.lua)
  local pads = io.open(REC_DIR .. "/pads.txt", "a")
  pads:write("# frame, then bytes $0020-$002F and $00DC-$00DF (hex) after the joypad read\n")
  local function padlog()
    local t = {}
    for a = 0x20, 0x2F do t[#t + 1] = string.format("%02X", emu.read(a, emu.memType.snesWorkRam)) end
    for a = 0xDC, 0xDF do t[#t + 1] = string.format("%02X", emu.read(a, emu.memType.snesWorkRam)) end
    pads:write(frame, " ", table.concat(t), "\n")
    if frame % 60 == 0 then pads:flush() end
  end
  for _, b in ipairs({ 0x000000, 0x800000 }) do emu.addMemoryCallback(padlog, emu.callbackType.exec, b + 0x81CF) end

  -- save states must be made inside a CPU exec callback: at the NMI entry
  local function snap()
    if not pendingState then return end
    pendingState = false
    local ok, data = pcall(emu.createSavestate)
    if not ok then log("state failed: %s", tostring(data)) return end
    local name = pendingName or string.format("%08d.mss", frame)
    local f = io.open(REC_DIR .. "/states/" .. name, "wb")
    if f then f:write(data); f:close() end
    if not pendingName then
      saved[#saved + 1] = name
      if #saved > STATES_KEPT then os.remove(REC_DIR .. "/states/" .. table.remove(saved, 1)) end
    else
      log("mark state states/%s", name)
    end
  end
  for _, b in ipairs({ 0x000000, 0x800000 }) do emu.addMemoryCallback(snap, emu.callbackType.exec, b + 0x8174) end

  -- movie (session.mmo): a save state, then every frame's input as the game got it
  -- (after the bots' overrides), for an exact replay of the whole session
  -- (scripts/make_video.sh). Started at an NMI entry (needs a save state), after the
  -- --state load; Mesen writes the file when it closes (or a state is loaded).
  local movieStarted = false
  local function movieStart()
    if movieStarted or not emu.startMovieRecording then return end
    if START_STATE and not (startLoadedAt and frame > startLoadedAt) then return end
    movieStarted = true
    if emu.startMovieRecording(REC_DIR .. "/session.mmo") then
      log("movie session.mmo from frame %d", frame)
      local mf = io.open(REC_DIR .. "/movie.txt", "w")
      if mf then mf:write(frame, "\n"); mf:close() end
    else
      log("movie: could not record")
    end
  end
  for _, b in ipairs({ 0x000000, 0x800000 }) do emu.addMemoryCallback(movieStart, emu.callbackType.exec, b + 0x8174) end
  if not emu.startMovieRecording then
    log("movie: this Mesen can't record movies from a script (scripts/setup.sh)")
  end
end
