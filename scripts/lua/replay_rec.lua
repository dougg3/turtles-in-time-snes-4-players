-- Replay a play_with_bots recording: load states/<REPLAY_FRAME>.mss and feed the
-- recorded input from that frame on. With pads.txt (recordings since 2026-10-24
-- 10:40): the bytes the game read ($0020-$002F, $00DC-$00DF) are written back right
-- after its joypad routine, so the replay is exact; otherwise inputs.txt is fed to
-- the controllers (P4 may drift: it is read by the ROM's manual multitap read). Logs a
-- status line every 60 frames (compare with events.log) to replay.txt in TMNT_OUT.
-- Env: REPLAY_DIR (recording directory), REPLAY_FRAME (the state's frame),
-- REPLAY_OFFSET (input alignment, default 0), REPLAY_P4_OFFSET (P4's, default -1: P4 is
-- read by the ROM's manual multitap read, a frame after the bots' input took effect).
local dir = os.getenv("REPLAY_DIR")
local base = tonumber(os.getenv("REPLAY_FRAME"))
local offset = tonumber(os.getenv("REPLAY_OFFSET") or "0")
local p4offset = tonumber(os.getenv("REPLAY_P4_OFFSET") or "-1")
local W = emu.memType.snesWorkRam
local function rw(a) return emu.read(a, W) | (emu.read(a + 1, W) << 8) end
local BITS = { "a", "b", "x", "y", "l", "r", "up", "down", "left", "right", "start", "select" }
local PAD = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 1, 2 } }
local SLOT = { 0x0400, 0x0470, 0x0630, 0x0710 }
local inputs = {}
for line in io.lines(dir .. "/inputs.txt") do
  local f, a, b, c, d = line:match("^(%d+) (%x+) (%x+) (%x+) (%x+)")
  if f then inputs[tonumber(f)] = { tonumber(a, 16), tonumber(b, 16), tonumber(c, 16), tonumber(d, 16) } end
end
local padrec = {}
local pf = io.open(dir .. "/pads.txt", "r")
if pf then
  for line in pf:lines() do
    local f, hex = line:match("^(%d+) (%x+)$")
    if f then padrec[tonumber(f)] = hex end
  end
  pf:close()
end
local usePads = next(padrec) ~= nil
local out = assert(io.open((os.getenv("TMNT_OUT") or ".") .. "/replay.txt", "w"))
-- REPLAY_SHOTS="first last": also write every frame first..last (inclusive) as raw
-- RGB (256 x 239) to TMNT_OUT/frames/<frame>.rgb (scripts/rec_video.sh)
local replayEnd = tonumber(os.getenv("REPLAY_END") or "")   -- stop the emulator there
local shotFirst, shotLast = (os.getenv("REPLAY_SHOTS") or ""):match("(%d+) (%d+)")
shotFirst, shotLast = tonumber(shotFirst), tonumber(shotLast)
local loaded, frame = false, nil
local data = assert(io.open(string.format("%s/states/%08d.mss", dir, base), "rb")):read("a")
local function loader()
  if loaded then return end
  emu.loadSavestate(data)
  loaded, frame = true, base
end
for _, b in ipairs({ 0x000000, 0x800000 }) do emu.addMemoryCallback(loader, emu.callbackType.exec, b + 0x8174) end
local function writePads()
  local hex = frame and padrec[frame]
  if not hex then return end
  for i = 0, 15 do emu.write(0x20 + i, tonumber(hex:sub(i * 2 + 1, i * 2 + 2), 16), W) end
  for i = 0, 3 do emu.write(0xDC + i, tonumber(hex:sub(33 + i * 2, 34 + i * 2), 16), W) end
end
if usePads then
  for _, b in ipairs({ 0x000000, 0x800000 }) do emu.addMemoryCallback(writePads, emu.callbackType.exec, b + 0x81CF) end
end
emu.addEventCallback(function()
  if not frame or usePads then return end
  for p = 1, 4 do
    local m = inputs[frame + (p == 4 and p4offset or offset)]
    if not m then return end
    local t = {}
    for i, k in ipairs(BITS) do t[k] = (m[p] >> (i - 1)) & 1 == 1 end
    emu.setInput(t, 0, PAD[p][1], PAD[p][2])
  end
end, emu.eventType.inputPolled)
emu.addEventCallback(function()
  if not frame then return end
  frame = frame + 1
  if shotFirst and frame >= shotFirst and frame <= shotLast then
    local buf = emu.getScreenBuffer()
    local t = {}
    for i = 1, #buf do
      local v = buf[i]
      t[i] = string.char((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    end
    local f = io.open(string.format("%s/frames/%08d.rgb", os.getenv("TMNT_OUT") or ".", frame), "wb")
    f:write(table.concat(t)); f:close()
    if frame == shotLast then emu.stop(0) end
  end
  if replayEnd and frame >= replayEnd then out:flush(); emu.stop(0) end
  if frame % 60 == 0 then
    local t = {}
    for p = 1, 4 do local s = SLOT[p]; t[#t + 1] = string.format("P%d st%02X x%d y%d hp%d", p, rw(s + 0x16), rw(s + 8), rw(s + 0xC), rw(s + 0x4A)) end
    out:write(string.format("f%d status mode %02X cam %d | %s\n", frame, emu.read(0x70, W), rw(0x17A0), table.concat(t, " | ")))
    out:flush()
  end
end, emu.eventType.endFrame)
