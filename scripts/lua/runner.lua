-- Command-file driven harness for headless Mesen runs.
--
-- Usage: TMNT_CMDS=<file> TMNT_OUT=<dir> Mesen --testRunner runner.lua <rom>
--
-- Command file, one per line ('#' comments):
--   load <file>            load savestate, path relative to repo root (applied at next NMI-handler exec)
--   wait <frames>          run frames with current held input
--   hold <port> <btns|->   set held buttons for port (comma list: a,b,x,y,l,r,up,down,left,right,start,select; '-' = none)
--   tap <port> <btns> [n]  hold buttons for n frames (default 2) then release, then wait 2 frames
--   shot <name>            screenshot -> <out>/<name>.png
--   save <file>            savestate -> <out>/<file> (written at next NMI-handler exec)
--   cdl <name>             PRG ROM CDL bytes -> <out>/<name>.cdl
--   wram <name>            128 KiB WRAM dump -> <out>/<name>.wram
--   oam <name>             544-byte OAM dump -> <out>/<name>.oam
--   cgram <name>           512-byte CGRAM dump -> <out>/<name>.cgram
--   vram <name>            64 KiB VRAM dump -> <out>/<name>.vram
--   ppu <name>             all "ppu.*" values of emu.getState() -> <out>/<name>.ppu
--   peek <addr> <len>      log WRAM bytes (addr is WRAM offset, hex) to run.log
--   watch <r|w> <start> <end> <frames>
--                          log unique (instruction address, WRAM offset, value) for reads/writes
--                          of a WRAM range (hex offsets) over the next N frames -> run.log
--   trace <name> <frames>  binary trace of every executed S-CPU instruction for N frames:
--                          records of <u24 address><u64 master clock> -> <out>/<name>.trace
--   oamrec <name> <frames> record every frame: <u8 OBSEL shadow ($7E1E7E)><u8 STAT77 ($213E)><544 bytes OAM>
--                          -> <out>/<name>.oamrec
--   cpurec <name> <frames> per NMI: "<entry clock> <busy clocks> <lag 0/1>" text lines -> <out>/<name>.cpu
--                          busy = NMI entry ($00:8174) to full-path RTI ($00:8205); lag = NMI arrived while the
--                          previous one was still running (short path at $00:8190)
--   memrec <name> <start> <len> <frames>
--                          record WRAM[start..start+len) every frame (hex start/len) -> <out>/<name>.memrec
--   hooks <name> <frames> <addr> [addr...]
--                          log "<frame> <addr> <master clock> X= Y= A=" whenever a listed address executes -> <out>/<name>.hooks
--   poke <addr> <byte> [byte...]  write WRAM bytes (hex) - experiment only, never touches ROM
--   ai <player> <on|off>   RAM-driven bot for that player (0-1 = ports; 2-3 = P3/P4 via multitap): approach nearest enemy (slots 11-19),
--                          match depth, attack; walk right when no enemies. Overrides hold/tap.
--   god <on|off>           measurement aid: keep each player's health (object +$4A) at the highest
--                          value seen, so players never die. Hits/knockdowns still happen.
--   dmarec <name> <frames> log every general DMA started via $420B: "<frame> <pc> <ch> <$43x0>
--                          <B-bus $43x1> <src bank:addr> <size> <VMADD $2116> <V>" -> <out>/<name>.dma
--                          (V = vblank flag from $4212 at the time of the write)
--   counters reset         reset Mesen's memory access counters
--   counters <name>        WRAM access map -> <out>/<name>.access (1 byte per WRAM byte:
--                          bit0 read, bit1 written since the last reset)
--   peekio <addr> <len>    log S-CPU bus bytes via side-effect-free reads (hex addr, e.g. 4218)
--   mtap <sub> <btns|->    hold buttons on multitap (port 2) sub-port 0-3 (needs Port2 = Multitap)
--   inputlog <name>        from now on, log the input sent to ports 0/1 each frame -> <out>/<name>.inputs
--   replay <file>          from now on, send inputs from an .inputs file (path relative to repo root),
--                          one line per frame: "<p0 mask> <p1 mask>" (hex, bit order = ALL_BUTTONS)
--   framehash <name> <every> <frames>
--                          every N frames write "<frame> <OAM+CGRAM crc> <wram $0000-$1FFF crc>" -> <out>/<name>.hash
--                          (screen buffer reads are not frame-exact in Mesen, so PPU memories are hashed instead)
--   rngpin                 at every NMI entry ($00:8174) set $0094 (idle-loop random source)
--                          to a value derived from the frame number, so runs of ROMs with
--                          different CPU timing see identical randomness (regression testing)
--   bg <command ...>       run a recorder (trace/watch/oamrec/cpurec/memrec) without waiting for it
--   end                    stop emulator

local out = os.getenv("TMNT_OUT") or "."
local root = os.getenv("TMNT_ROOT") or "."
local cmdFile = assert(os.getenv("TMNT_CMDS"), "TMNT_CMDS not set")
local NMI_HANDLER = 0x008174 -- from native NMI vector ($00:FFEA); runs once per frame while NMI is enabled

local cmds = {}
for rawLine in io.lines(cmdFile) do
  local line = rawLine:gsub("#.*", ""):match("^%s*(.-)%s*$")
  if line ~= "" then
    local t = {}
    for w in line:gmatch("%S+") do t[#t + 1] = w end
    cmds[#cmds + 1] = t
  end
end

local log = io.open(out .. "/run.log", "w")
local function say(fmt, ...)
  log:write(string.format(fmt, ...) .. "\n")
  log:flush()
end

local frame = 0
local pc = 1
local waitUntil = 0
local held
local pendingSave, pendingLoad
local tapRelease

local function writeFile(name, data)
  local f = assert(io.open(out .. "/" .. name, "wb"))
  f:write(data)
  f:close()
end

local ALL_BUTTONS = { "a", "b", "x", "y", "l", "r", "up", "down", "left", "right", "start", "select" }

local function parseButtons(s)
  local t = {}
  for _, b in ipairs(ALL_BUTTONS) do t[b] = false end
  if s ~= "-" then
    for b in s:gmatch("[^,]+") do t[b] = true end
  end
  return t
end

held = { [0] = parseButtons("-"), [1] = parseButtons("-") }

-- Simple RAM-driven player bot. Player slots at
-- $0400/$0470, X at +$08 (screen), depth Y at +$0C, enemies in slots 11-19
-- ($08D0 + n*$70) with non-zero type at +$14.
local aiPorts = {}
-- players 2/3 = P3/P4 of the 4-player patch (slots 5/7), driven through multitap
-- sub-ports 1/2 (Port2 must be a Multitap; P2 is then sub-port 0)
local PLAYER_SLOT = { [0] = 0x0400, [1] = 0x0470, [2] = 0x0630, [3] = 0x0710 }

local function rd16(a)
  return emu.read(a, emu.memType.snesWorkRam) | (emu.read(a + 1, emu.memType.snesWorkRam) << 8)
end

-- Some objects in enemy slots can't be beaten by the bot (seen: an orange figure
-- in stages 0/1). Give up on a slot after STUCK_FRAMES of continuous targeting and
-- ignore it for IGNORE_FRAMES.
local STUCK_FRAMES, IGNORE_FRAMES = 360, 1800
local aiTarget = { [0] = {}, [1] = {}, [2] = {}, [3] = {} }
local aiIgnore = {}
local playerGone = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
local godMode = false
local godMax = {}

-- Stuck recovery. Progress = BG1 scroll changing ($17A0 X, $17B0 Y).
-- Some areas need the player at a particular depth before the screen will
-- scroll, so when there is no progress for STALL_FRAMES each player cycles
-- through vertical/diagonal moves (out of phase with each other) for up to
-- EXPLORE_FRAMES, attacking as it goes, then returns to normal seeking.
local STALL_FRAMES, EXPLORE_FRAMES, MOVE_FRAMES = 300, 720, 60
local EXPLORE_MOVES = {
  { "up", "right" }, { "down", "right" }, { "up" }, { "down" },
  { "right", "b" }, { "left" }, { "up", "left" }, { "down", "left" },
}
local lastScroll, lastProgress, exploreUntil = nil, 0, 0

local function updateProgress()
  local sc = rd16(0x17A0) .. ":" .. rd16(0x17B0)
  if sc ~= lastScroll then
    lastScroll, lastProgress, exploreUntil = sc, frame, 0
  elseif exploreUntil == 0 and frame - lastProgress > STALL_FRAMES then
    exploreUntil = frame + EXPLORE_FRAMES
  elseif exploreUntil ~= 0 and frame >= exploreUntil then
    lastProgress, exploreUntil = frame, 0 -- give seeking another go before exploring again
  end
end

local function exploreInput(port, t)
  local phase = (frame // MOVE_FRAMES + port * 3) % #EXPLORE_MOVES
  for _, b in ipairs(EXPLORE_MOVES[phase + 1]) do t[b] = true end
  t.y = (frame % 12) < 3
  return t
end

local function aiInput(port)
  local me = PLAYER_SLOT[port]
  local t = parseButtons("-")
  if rd16(me + 0x14) == 0 then
    -- player not in play (dead / continue prompt): tap Start now and then to rejoin
    playerGone[port] = playerGone[port] + 1
    t.start = playerGone[port] % 60 < 2
    return t
  end
  playerGone[port] = 0
  if exploreUntil ~= 0 then return exploreInput(port, t) end
  local px, py = rd16(me + 0x08), rd16(me + 0x0C)
  local best, bestD, bestSlot
  for k = 0, 8 do
    local e = 0x08D0 + k * 0x70
    if rd16(e + 0x14) ~= 0 and not (aiIgnore[e] and frame < aiIgnore[e]) then
      local ex, ey = rd16(e + 0x08), rd16(e + 0x0C)
      if ex < 0x8000 and ex < 0x110 then
        local d = math.abs(ex - px) + 2 * math.abs(ey - py)
        if not bestD or d < bestD then best, bestD, bestSlot = { ex, ey }, d, e end
      end
    end
  end
  local tg = aiTarget[port]
  if bestSlot ~= tg.slot then
    tg.slot, tg.since = bestSlot, frame
  elseif bestSlot and frame - tg.since > STUCK_FRAMES then
    aiIgnore[bestSlot] = frame + IGNORE_FRAMES
    tg.slot = nil
  end
  if not best then
    t.right = true
    if frame % 90 < 4 then t.b = true end -- hop over obstacles now and then
    return t
  end
  local dx, dy = best[1] - px, best[2] - py
  if dy > 3 then t.down = true elseif dy < -3 then t.up = true end
  local face = dx >= 0 and "right" or "left"
  if math.abs(dx) > 36 then
    t[face] = true
  elseif math.abs(dy) <= 6 then
    if frame % 16 < 2 then t[face] = true end -- keep facing the target
    t.y = (frame % 6) < 3
  end
  return t
end

local function dumpMem(memType, size, name)
  local parts = {}
  for i = 0, size - 1 do parts[#parts + 1] = string.char(emu.read(i, memType)) end
  writeFile(name, table.concat(parts))
end

-- Memory callbacks only report the data address, so track the executing
-- instruction with an exec callback over all ROM while a watch is active.
local watch

local function startWatch(kind, first, last, frames)
  local seen, order = {}, {}
  local lastPc = 0
  local execRef = emu.addMemoryCallback(function(addr) lastPc = addr end,
    emu.callbackType.exec, 0x000000, 0xFFFFFF)
  local memType = emu.memType.snesWorkRam
  local cbType = kind == "w" and emu.callbackType.write or emu.callbackType.read
  local memRef = emu.addMemoryCallback(function(addr, value)
    local key = string.format("%06X %05X %02X", lastPc, addr, value)
    if not seen[key] then
      seen[key] = true
      order[#order + 1] = key
    end
  end, cbType, first, last, emu.cpuType.snes, memType)
  watch = { untilFrame = frame + frames, execRef = execRef, memRef = memRef,
            cbType = cbType, first = first, last = last, memType = memType, order = order, kind = kind }
end

local function finishWatch()
  emu.removeMemoryCallback(watch.execRef, emu.callbackType.exec, 0x000000, 0xFFFFFF)
  emu.removeMemoryCallback(watch.memRef, watch.cbType, watch.first, watch.last, emu.cpuType.snes, watch.memType)
  say("watch %s %05X-%05X: %d unique (pc wram value)", watch.kind, watch.first, watch.last, #watch.order)
  for _, k in ipairs(watch.order) do say("  %s", k) end
  watch = nil
end

local trace
local oamrec
local cpurec
local memrec
local hooks
local mtapHeld = {}
local inputLog, replayLines, replayPos, fhash
local dmarec

local NMI_FULL_RTI = 0x008205 -- RTI reached only by the full (non-reentrant) NMI path
local NMI_LAG_PATH = 0x008190 -- taken when $3C shows the previous NMI has not finished

local function startCpuRec(name, frames)
  local lines, entries = {}, {}
  local refs = {
    emu.addMemoryCallback(function() entries[#entries + 1] = emu.getMasterClock() end,
      emu.callbackType.exec, NMI_HANDLER),
    emu.addMemoryCallback(function()
      local t = table.remove(entries)
      if t then lines[#lines + 1] = string.format("%d %d 0", t, emu.getMasterClock() - t) end
    end, emu.callbackType.exec, NMI_FULL_RTI),
    emu.addMemoryCallback(function()
      local t = table.remove(entries)
      if t then lines[#lines + 1] = string.format("%d 0 1", t) end
    end, emu.callbackType.exec, NMI_LAG_PATH),
  }
  cpurec = { name = name, untilFrame = frame + frames, lines = lines, refs = refs }
end

local function finishCpuRec()
  emu.removeMemoryCallback(cpurec.refs[1], emu.callbackType.exec, NMI_HANDLER)
  emu.removeMemoryCallback(cpurec.refs[2], emu.callbackType.exec, NMI_FULL_RTI)
  emu.removeMemoryCallback(cpurec.refs[3], emu.callbackType.exec, NMI_LAG_PATH)
  writeFile(cpurec.name .. ".cpu", table.concat(cpurec.lines, "\n") .. "\n")
  say("cpurec %s: %d NMIs", cpurec.name, #cpurec.lines)
  cpurec = nil
end

local function recordOam()
  local parts = { string.char(emu.read(0x1E7E, emu.memType.snesWorkRam)),
                  -- snesDebug peeks of PPU registers always return 0 in Mesen, so use a real
                  -- bus read (only side effect: PPU1 open-bus latch)
                  string.char(emu.read(0x213E, emu.memType.snesMemory)) }
  for i = 0, 543 do parts[#parts + 1] = string.char(emu.read(i, emu.memType.snesSpriteRam)) end
  oamrec.file:write(table.concat(parts))
  oamrec.count = oamrec.count + 1
end

local function startTrace(name, frames)
  local recs = {}
  local ref = emu.addMemoryCallback(function(addr)
    recs[#recs + 1] = string.pack("<I3I8", addr, emu.getMasterClock())
  end, emu.callbackType.exec, 0x000000, 0xFFFFFF)
  trace = { name = name, untilFrame = frame + frames, ref = ref, recs = recs }
end

local function finishTrace()
  emu.removeMemoryCallback(trace.ref, emu.callbackType.exec, 0x000000, 0xFFFFFF)
  writeFile(trace.name .. ".trace", table.concat(trace.recs))
  say("trace %s: %d instructions", trace.name, #trace.recs)
  trace = nil
end

local function step()
  while pc <= #cmds and frame >= waitUntil do
    local c = cmds[pc]
    pc = pc + 1
    local background = c[1] == "bg"
    if background then c = { table.unpack(c, 2) } end
    local op = c[1]
    local waitFor = function(n) if not background then waitUntil = frame + n end end
    if op == "wait" then
      waitUntil = frame + tonumber(c[2])
    elseif op == "hold" then
      held[tonumber(c[2])] = parseButtons(c[3])
    elseif op == "tap" then
      local port, n = tonumber(c[2]), tonumber(c[4] or 2)
      held[port] = parseButtons(c[3])
      tapRelease = { port = port, at = frame + n }
      waitUntil = frame + n + 2
    elseif op == "shot" then
      writeFile(c[2] .. ".png", emu.takeScreenshot())
    elseif op == "save" then
      pendingSave = c[2]
      return -- wait for it to be written before continuing
    elseif op == "load" then
      local path = c[2]:sub(1, 1) == "/" and c[2] or (root .. "/" .. c[2])
      local f = assert(io.open(path, "rb"))
      pendingLoad = f:read("a")
      say("frame %d: load requested (%d bytes)", frame, #pendingLoad)
      f:close()
      return
    elseif op == "cdl" then
      local d = emu.getCdlData(emu.memType.snesPrgRom)
      local parts = {}
      for i = 1, #d do parts[i] = string.char(d[i]) end
      writeFile(c[2] .. ".cdl", table.concat(parts))
    elseif op == "wram" then
      dumpMem(emu.memType.snesWorkRam, 0x20000, c[2] .. ".wram")
    elseif op == "cgram" then
      dumpMem(emu.memType.snesCgRam, 512, c[2] .. ".cgram")
    elseif op == "vram" then
      dumpMem(emu.memType.snesVideoRam, 0x10000, c[2] .. ".vram")
    elseif op == "oam" then
      dumpMem(emu.memType.snesSpriteRam, 544, c[2] .. ".oam")
    elseif op == "ppu" then
      local st, keys = emu.getState(), {}
      for k in pairs(st) do if k:sub(1, 4) == "ppu." then keys[#keys + 1] = k end end
      table.sort(keys)
      local f = io.open(out .. "/" .. c[2] .. ".ppu", "w")
      for _, k in ipairs(keys) do f:write(k, "=", tostring(st[k]), "\n") end
      f:close()
    elseif op == "peek" then
      local a, n = tonumber(c[2], 16), tonumber(c[3])
      local b = {}
      for i = 0, n - 1 do b[#b + 1] = string.format("%02X", emu.read(a + i, emu.memType.snesWorkRam)) end
      say("frame %d: peek %05X: %s", frame, a, table.concat(b, " "))
      goto continue
    elseif op == "watch" then
      startWatch(c[2], tonumber(c[3], 16), tonumber(c[4], 16), tonumber(c[5]))
      waitFor(tonumber(c[5]))
    elseif op == "trace" then
      startTrace(c[2], tonumber(c[3]))
      waitFor(tonumber(c[3]))
    elseif op == "oamrec" then
      -- recorders stream to disk so long runs keep Lua memory flat
      oamrec = { name = c[2], untilFrame = frame + tonumber(c[3]), count = 0,
                 file = assert(io.open(out .. "/" .. c[2] .. ".oamrec", "wb")) }
      waitFor(tonumber(c[3]))
    elseif op == "cpurec" then
      startCpuRec(c[2], tonumber(c[3]))
      waitFor(tonumber(c[3]))
    elseif op == "memrec" then
      memrec = { name = c[2], start = tonumber(c[3], 16), len = tonumber(c[4], 16),
                 untilFrame = frame + tonumber(c[5]), count = 0,
                 file = assert(io.open(out .. "/" .. c[2] .. ".memrec", "wb")) }
      waitFor(tonumber(c[5]))
    elseif op == "hooks" then
      local lines, refs, addrs = {}, {}, {}
      for i = 4, #c do
        local a = tonumber(c[i]:gsub(":", ""), 16)
        addrs[#addrs + 1] = a
        refs[#refs + 1] = emu.addMemoryCallback(function()
          local st = emu.getState()
          lines[#lines + 1] = string.format("%d %06X %d X=%04X Y=%04X A=%04X", frame, a, emu.getMasterClock(),
            st["cpu.x"] or 0, st["cpu.y"] or 0, st["cpu.a"] or 0)
        end, emu.callbackType.exec, a)
      end
      hooks = { name = c[2], untilFrame = frame + tonumber(c[3]), lines = lines, refs = refs, addrs = addrs }
      waitFor(tonumber(c[3]))
    elseif op == "poke" then
      local a = tonumber(c[2], 16)
      for i = 3, #c do emu.write(a + i - 3, tonumber(c[i], 16), emu.memType.snesWorkRam) end
    elseif op == "counters" then
      if c[2] == "reset" then
        emu.resetAccessCounters()
      else
        -- Mesen reads these arguments in reverse: effective signature is (memType, counterType),
        -- and the returned table is indexed from 0 (t[addr]).
        local rd = emu.getAccessCounters(emu.memType.snesWorkRam, emu.counterType.readCount)
        local wr = emu.getAccessCounters(emu.memType.snesWorkRam, emu.counterType.writeCount)
        local parts = {}
        for a = 0, 0x1FFFF do
          parts[a + 1] = string.char(((rd[a] or 0) ~= 0 and 1 or 0) | ((wr[a] or 0) ~= 0 and 2 or 0))
        end
        writeFile(c[2] .. ".access", table.concat(parts))
      end
    elseif op == "peekio" then
      local a, n = tonumber(c[2], 16), tonumber(c[3])
      local b = {}
      for i = 0, n - 1 do b[#b + 1] = string.format("%02X", emu.read(a + i, emu.memType.snesDebug)) end
      say("frame %d: peekio %06X: %s", frame, a, table.concat(b, " "))
      goto continue
    elseif op == "inputlog" then
      inputLog = assert(io.open(out .. "/" .. c[2] .. ".inputs", "w"))
    elseif op == "replay" then
      replayLines, replayPos = {}, 1
      for l in io.lines(c[2]:sub(1, 1) == "/" and c[2] or (root .. "/" .. c[2])) do replayLines[#replayLines + 1] = l end
    elseif op == "framehash" then
      fhash = { file = assert(io.open(out .. "/" .. c[2] .. ".hash", "w")), every = tonumber(c[3]),
                untilFrame = frame + tonumber(c[4]) }
      waitFor(tonumber(c[4]))
    elseif op == "mtap" then
      mtapHeld[tonumber(c[2])] = parseButtons(c[3])
    elseif op == "rngpin" then
      emu.addMemoryCallback(function()
        local v = (frame * 0x9E37 + 0x79B9) & 0xFFFF
        emu.write(0x94, v & 0xFF, emu.memType.snesWorkRam)
        emu.write(0x95, v >> 8, emu.memType.snesWorkRam)
      end, emu.callbackType.exec, NMI_HANDLER)
    elseif op == "god" then
      godMode = c[2] == "on"
    elseif op == "ai" then
      aiPorts[tonumber(c[2])] = c[3] == "on" or nil
    elseif op == "dmarec" then
      -- I/O registers are mirrored in banks $00-$3F/$80-$BF and the game uses
      -- DB=$01, so hook every mirror of $420B and $2116/$2117.
      local lines = {}
      local lastPc = 0
      local refs = {}
      local function hook(fn, cbType, a0, a1)
        refs[#refs + 1] = { emu.addMemoryCallback(fn, cbType, a0, a1), cbType, a0, a1 }
      end
      hook(function(a) lastPc = a end, emu.callbackType.exec, 0x000000, 0xFFFFFF)
      local function onMdma(addr, value)
        local dbg = emu.memType.snesDebug
        local v = (emu.read(0x4212, dbg) & 0x80) ~= 0 and 1 or 0
        for ch = 0, 7 do
          if value & (1 << ch) ~= 0 then
            local b = 0x4300 + ch * 16
            local size = emu.read(b + 5, dbg) | (emu.read(b + 6, dbg) << 8)
            lines[#lines + 1] = string.format("%d %06X %d %02X %02X %02X:%04X %d %04X %d", frame, lastPc, ch,
              emu.read(b, dbg), emu.read(b + 1, dbg), emu.read(b + 4, dbg),
              emu.read(b + 2, dbg) | (emu.read(b + 3, dbg) << 8), size == 0 and 65536 or size, dmarec.vmadd, v)
          end
        end
      end
      local function onVmadd(addr, value)
        if addr & 0xFFFF == 0x2116 then dmarec.vmadd = (dmarec.vmadd & 0xFF00) | value
        else dmarec.vmadd = (dmarec.vmadd & 0x00FF) | (value << 8) end
      end
      for _, base in ipairs({ 0x00, 0x80 }) do
        for bank = base, base + 0x3F do
          hook(onMdma, emu.callbackType.write, (bank << 16) | 0x420B, (bank << 16) | 0x420B)
          hook(onVmadd, emu.callbackType.write, (bank << 16) | 0x2116, (bank << 16) | 0x2117)
        end
      end
      dmarec = { name = c[2], untilFrame = frame + tonumber(c[3]), lines = lines, refs = refs, vmadd = 0 }
      waitFor(tonumber(c[3]))
    elseif op == "end" then
      say("end at frame %d", frame)
      emu.stop(0)
      return
    else
      say("unknown command: %s", op)
    end
    say("frame %d: %s", frame, table.concat(c, " "))
    ::continue::
  end
  if pc > #cmds and frame >= waitUntil then
    say("commands exhausted at frame %d", frame)
    emu.stop(0)
  end
end

emu.addEventCallback(function()
  if next(aiPorts) then updateProgress() end
  -- Mesen bug (LuaApi::SetInput pads to 3 args, then lua_settop(4)): the 2nd
  -- argument is ignored and the effective signature is (input, _, port, subport).
  local sent = {}
  for port = 0, 1 do
    local t = aiPorts[port] and aiInput(port) or held[port]
    if replayLines then
      local l = replayLines[replayPos]
      if l then
        local m0, m1 = l:match("(%x+) (%x+)")
        local mask = tonumber(port == 0 and m0 or m1, 16)
        t = {}
        for i, b in ipairs(ALL_BUTTONS) do t[b] = (mask >> (i - 1)) & 1 == 1 end
      end
    end
    sent[port] = t
    emu.setInput(t, 0, port, 0)
  end
  if replayLines then replayPos = replayPos + 1 end
  if inputLog then
    local m = {}
    for port = 0, 1 do
      local v = 0
      for i, b in ipairs(ALL_BUTTONS) do if sent[port][b] then v = v | (1 << (i - 1)) end end
      m[#m + 1] = string.format("%03X", v)
    end
    inputLog:write(table.concat(m, " "), "\n")
  end
  for sub, t in pairs(mtapHeld) do emu.setInput(t, 0, 1, sub) end
  -- AI for P3/P4 (multitap pads 3/4 = port 1 sub-ports 1/2)
  for p = 2, 3 do
    if aiPorts[p] then emu.setInput(aiInput(p), 0, 1, p - 1) end
  end
end, emu.eventType.inputPolled)

emu.addEventCallback(function()
  frame = frame + 1
  if tapRelease and frame >= tapRelease.at then
    held[tapRelease.port] = parseButtons("-")
    tapRelease = nil
  end
  if godMode then
    -- Real health is player object +$4A ($00:C8AF only copies a scaled value to the HUD).
    for _, slot in ipairs({ 0x0400, 0x0470, 0x0630, 0x0710 }) do
      local hp = rd16(slot + 0x4A)
      godMax[slot] = math.max(godMax[slot] or 0, hp)
      if hp > 0 and hp < godMax[slot] then
        emu.write(slot + 0x4A, godMax[slot] & 0xFF, emu.memType.snesWorkRam)
        emu.write(slot + 0x4B, godMax[slot] >> 8, emu.memType.snesWorkRam)
      end
    end
  end
  if watch and frame >= watch.untilFrame then finishWatch() end
  if trace and frame >= trace.untilFrame then finishTrace() end
  if cpurec and frame >= cpurec.untilFrame then finishCpuRec() end
  if hooks and frame >= hooks.untilFrame then
    for i, a in ipairs(hooks.addrs) do emu.removeMemoryCallback(hooks.refs[i], emu.callbackType.exec, a) end
    writeFile(hooks.name .. ".hooks", table.concat(hooks.lines, "\n") .. "\n")
    say("hooks %s: %d hits", hooks.name, #hooks.lines)
    hooks = nil
  end
  if fhash then
    if frame % fhash.every == 0 then
      local function crc(tbl, n)
        local h = 0x811C9DC5
        for i = 1, n do h = ((h ~ tbl[i]) * 0x01000193) & 0xFFFFFFFF end
        return h
      end
      local scr = {}
      for a = 0, 543 do scr[#scr + 1] = emu.read(a, emu.memType.snesSpriteRam) end
      for a = 0, 511 do scr[#scr + 1] = emu.read(a, emu.memType.snesCgRam) end
      -- addresses listed in TMNT_HASH_EXCLUDE ("20-2F,DC-E3", hex) are hashed as 0:
      -- RAM a patch deliberately repurposes, so the rest of the state can still be compared
      if not fhash.excl then
        fhash.excl = {}
        for a0, a1 in (os.getenv("TMNT_HASH_EXCLUDE") or ""):gmatch("(%x+)-(%x+)") do
          for a = tonumber(a0, 16), tonumber(a1, 16) do fhash.excl[a] = true end
        end
      end
      -- TMNT_HASH_MAP ("19DC:0110:4", hex) makes the hash read relocated data from
      -- its new address in place of the original one, so moved state is still compared.
      -- The new addresses themselves must be in TMNT_HASH_EXCLUDE (unused in the original).
      if not fhash.map then
        fhash.map = {}
        for o, n, len in (os.getenv("TMNT_HASH_MAP") or ""):gmatch("(%x+):(%x+):(%x+)") do
          for i = 0, tonumber(len, 16) - 1 do fhash.map[tonumber(o, 16) + i] = tonumber(n, 16) + i end
        end
      end
      local w = {}
      for a = 0, 0x1FFF do
        w[a + 1] = fhash.excl[a] and 0 or emu.read(fhash.map[a] or a, emu.memType.snesWorkRam)
      end
      fhash.file:write(string.format("%d %08X %08X\n", frame, crc(scr, #scr), crc(w, 0x2000)))
    end
    if frame >= fhash.untilFrame then fhash.file:close(); fhash = nil end
  end
  if dmarec and frame >= dmarec.untilFrame then
    for _, r in ipairs(dmarec.refs) do emu.removeMemoryCallback(r[1], r[2], r[3], r[4]) end
    writeFile(dmarec.name .. ".dma", table.concat(dmarec.lines, "\n") .. "\n")
    say("dmarec %s: %d transfers", dmarec.name, #dmarec.lines)
    dmarec = nil
  end
  if memrec then
    local parts = {}
    for i = memrec.start, memrec.start + memrec.len - 1 do
      parts[#parts + 1] = string.char(emu.read(i, emu.memType.snesWorkRam))
    end
    memrec.file:write(table.concat(parts))
    memrec.count = memrec.count + 1
    if frame >= memrec.untilFrame then
      memrec.file:close()
      say("memrec %s: %d frames x %d bytes", memrec.name, memrec.count, memrec.len)
      memrec = nil
    end
  end
  if oamrec then
    recordOam()
    if frame >= oamrec.untilFrame then
      oamrec.file:close()
      say("oamrec %s: %d frames", oamrec.name, oamrec.count)
      oamrec = nil
    end
  end
  if not pendingSave and not pendingLoad then
    -- Mesen drops errors raised inside callbacks, so surface them in run.log
    local ok, err = pcall(step)
    if not ok then
      say("frame %d: ERROR %s", frame, tostring(err))
      emu.stop(1)
    end
  end
end, emu.eventType.endFrame)

emu.addMemoryCallback(function()
  -- errors here would otherwise be dropped by Mesen and leave the run waiting forever
  local ok, err = pcall(function()
    if pendingLoad then
      emu.loadSavestate(pendingLoad)
      pendingLoad = nil
      say("frame %d: state loaded", frame)
    elseif pendingSave then
      local name = pendingSave
      pendingSave = nil
      writeFile(name, emu.createSavestate())
      say("frame %d: saved %s", frame, name)
    end
  end)
  if not ok then
    say("frame %d: ERROR %s", frame, tostring(err))
    emu.stop(1)
  end
end, emu.callbackType.exec, NMI_HANDLER)
