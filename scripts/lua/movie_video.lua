-- Play a Mesen movie (.mmo, as play_with_bots.lua records it) and record it as an AVI
-- (scripts/make_video.sh). Run instead of runner.lua (TMNT_SCRIPT): the runner sets the
-- controllers every frame, which would replace the movie's input.
-- Env: MOVIE (the .mmo), VIDEO_OUT (the .avi), VIDEO_FIRST / VIDEO_LAST (optional: movie
-- frames to record, counted from the movie's first frame), TMNT_OUT (log: movie_video.txt).
local movie, avi = os.getenv("MOVIE"), os.getenv("VIDEO_OUT")
local first = tonumber(os.getenv("VIDEO_FIRST") or "") or 0
local last = tonumber(os.getenv("VIDEO_LAST") or "")
local out = os.getenv("TMNT_OUT") or "."
local log = io.open(out .. "/movie_video.txt", "a")
local function say(fmt, ...) log:write(string.format(fmt, ...), "\n"); log:flush() end

if not emu.playMovie(movie) then
  say("could not play %s", movie)
  emu.stop(2)
  return
end
say("playing %s", movie)
-- the movie starts after the first frame (its save state is loaded between frames)
local n, recording, skip = 0, false, 1
emu.addEventCallback(function()
  if skip > 0 then skip = skip - 1; return end
  if not emu.isMoviePlaying() or (last and n > last) then
    if recording then emu.stopVideoRecording() end
    say("movie frames %d, recorded %d-%d", n, first, math.min(n, last or n))
    emu.stop(0)
    return
  end
  if not recording and n >= first then
    recording = emu.startVideoRecording(avi)
    if not recording then say("could not record %s", avi); emu.stop(3); return end
  end
  n = n + 1
end, emu.eventType.endFrame)
