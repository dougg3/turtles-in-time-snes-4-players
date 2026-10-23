-- Headless smoke test: run frames, press Start periodically, dump screenshots + OAM usage.
local out = os.getenv("TMNT_OUT") or "."
local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 120 == 60 then emu.setInput({start = true}, 0) end
  if frame % 300 == 0 then
    local f = io.open(string.format("%s/smoke_%05d.png", out, frame), "wb")
    f:write(emu.takeScreenshot()); f:close()
    local st = emu.getState()
    emu.log(string.format("frame %d pc=%02X:%04X", frame, st["cpu.k"] or 0, st["cpu.pc"] or 0))
  end
  if frame >= 1500 then emu.stop(0) end
end, emu.eventType.endFrame)
