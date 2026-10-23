-- Runs TMNT_SCRIPT under pcall; Mesen's test runner hangs silently on Lua errors otherwise.
-- Errors raised later inside callbacks are reported by Mesen itself.
local ok, err = pcall(dofile, os.getenv("TMNT_SCRIPT"))
-- optional extra probe script (TMNT_EXTRA), loaded after the runner
if ok and os.getenv("TMNT_EXTRA") then ok, err = pcall(dofile, os.getenv("TMNT_EXTRA")) end
if not ok then
  local f = io.open((os.getenv("TMNT_OUT") or ".") .. "/error.txt", "w")
  f:write(tostring(err), "\n")
  f:close()
  emu.stop(1)
end
