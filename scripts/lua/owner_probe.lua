-- TMNT_EXTRA probe for scripts/owner_audit.sh: log every distinct
-- (owner, kind, instruction address, WRAM address) over a window of frames.
-- owner = player (0-3) owning the object being processed: taken from X at each
-- object-state dispatch (every 'JMP ($0000)' site, table OWNER_JMPS from
-- owner_audit.py jmps), 4 = any other object. Player objects, companions A and B
-- count for their player. Starts OWNER_START frames after load, runs OWNER_FRAMES
-- frames, writes $TMNT_OUT/owner.txt ("<owner> <r|w> <pc> <wram>").
local out = os.getenv("TMNT_OUT") or "."
local startAt = tonumber(os.getenv("OWNER_START") or "1500")
local frames = tonumber(os.getenv("OWNER_FRAMES") or "1800")
local jmps = dofile(os.getenv("OWNER_JMPS"))
local OWNER = { [0x0400] = 0, [0x04E0] = 0, [0x05C0] = 0, [0x0470] = 1, [0x0550] = 1, [0x06A0] = 1,
                [0x0630] = 2, [0x0100] = 2, [0x1530] = 2, [0x0710] = 3, [0x0170] = 3, [0x1640] = 3 }
local WR = emu.memType.snesWorkRam
local n, owner, lastPc = 0, 4, 0
local seen, refs = {}, nil

-- key = ((owner * 2 + write) * 2^24 + pc) * 2^17 + wram (exact in a double)
-- An NMI that arrives while the previous one is still running (lag) interrupts object
-- code: no owner inside it, the interrupted owner back at its RTI (both NMI paths end
-- at $00:8205).
local saved = {}
local NMI_IN = { [0x008174] = true, [0x808174] = true }
local NMI_OUT = { [0x008205] = true, [0x808205] = true }
local function onExec(a)
  lastPc = a
  if jmps[a] then owner = OWNER[emu.getState()["cpu.x"]] or 4
  elseif NMI_IN[a] then saved[#saved + 1] = owner; owner = 4
  elseif NMI_OUT[a] and #saved > 0 then owner = table.remove(saved) end
end
local function onRead(a) seen[((owner * 2) * 2^24 + lastPc) * 2^17 + a] = true end
local function onWrite(a) seen[((owner * 2 + 1) * 2^24 + lastPc) * 2^17 + a] = true end

local function start()
  refs = {
    emu.addMemoryCallback(onExec, emu.callbackType.exec, 0x000000, 0xFFFFFF),
    emu.addMemoryCallback(onRead, emu.callbackType.read, 0x0000, 0x1FFFF, emu.cpuType.snes, WR),
    emu.addMemoryCallback(onWrite, emu.callbackType.write, 0x0000, 0x1FFFF, emu.cpuType.snes, WR),
  }
end

local function finish()
  emu.removeMemoryCallback(refs[1], emu.callbackType.exec, 0x000000, 0xFFFFFF)
  emu.removeMemoryCallback(refs[2], emu.callbackType.read, 0x0000, 0x1FFFF, emu.cpuType.snes, WR)
  emu.removeMemoryCallback(refs[3], emu.callbackType.write, 0x0000, 0x1FFFF, emu.cpuType.snes, WR)
  local f = io.open(out .. "/owner.txt", "w")
  for k in pairs(seen) do
    local a = k % 2^17
    local rest = (k - a) / 2^17
    local pc = rest % 2^24
    local h = (rest - pc) / 2^24
    f:write(string.format("%d %s %06X %05X\n", h // 2, (h % 2 == 1) and "w" or "r", pc, a))
  end
  f:close()
  refs = false
end

emu.addEventCallback(function()
  n = n + 1
  if n == startAt and refs == nil then start()
  elseif refs and n == startAt + frames then finish() end
end, emu.eventType.endFrame)
