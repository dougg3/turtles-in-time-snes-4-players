// Browser front end for the mesen-tmnt4p core.
// main() runs in a worker thread (PROXY_TO_PTHREAD) and owns the emulator: it holds the
// emulator lock (Mesen's own emulation thread waits at a frame boundary) and runs frames
// itself. The page talks to it through shared memory only:
//   in:  ROM bytes (web_start), pad bitmasks g_page.Masks[0..3] (P1 = port 1, P2-P4 = multitap
//        A-C), g_audioActive (AudioWorklet consuming the ring), the bots' script (web_bots)
//        and the session's seed (web_seed), both before web_start, and seat roles (web_seats)
//   out: g_frame (256x224 RGBA) + g_frameSeq, audio ring g_audio (stereo int16, 48 kHz)
//        with frame counters g_audioW (written here) / g_audioR (written by the worklet),
//        the session log (web_log_snapshot; session.h)
// Playback (web_replay before web_start): a session log's input replaces the page's, from the log's
// seed, until its end; web_speed pauses (0) or fast-forwards; progress in web_replay_info.
#include "pch.h"
#include <atomic>
#include <chrono>
#include <thread>
#include <emscripten.h>
#include <emscripten/threading.h>
#include "Shared/Emulator.h"
#include "Shared/EmuSettings.h"
#include "Shared/SettingTypes.h"
#include "bots.h"
#include "session.h"
#include "Shared/Interfaces/IAudioDevice.h"
#include "Shared/Audio/SoundMixer.h"
#include "Shared/Interfaces/IConsole.h"
#include "Utilities/VirtualFile.h"
#include "Utilities/FolderUtilities.h"

static constexpr int FrameW = 256, FrameH = 224;
static constexpr uint32_t AudioCapacity = 16384;  // stereo frames (power of 2)
static uint32_t AudioTarget = 3072;     // keep ~64 ms queued (2048 dropped out on the user's PC; ?audio= sets it)

static uint8_t* volatile g_rom = nullptr;
static volatile uint32_t g_romSize = 0;
static PageInput g_page;
static uint8_t g_frame[FrameW * FrameH * 4];
static std::atomic<uint32_t> g_frameSeq;
static int16_t g_audio[AudioCapacity * 2];
static std::atomic<uint32_t> g_audioW, g_audioR;
static volatile uint32_t g_audioActive = 0;
static volatile float g_fps = 0;
static volatile float g_frameMsAvg = 0, g_frameMsMax = 0;   // emulation time per frame (RunFrame + copy)
static volatile uint32_t g_audioUnderruns = 0;               // counted by the AudioWorklet
extern bool VideoDecoderSkipDecode;                          // mesen-tmnt4p (MESEN_TMNT4P_EMBED)
static string g_botScript;                                   // set before web_start
static uint32_t g_seed = 0;                                  // the session's seed (web_seed, before web_start)
static LuaBots g_bots;
static std::atomic<int> g_botState;                          // 0 none, 1 running, 2 stopped (g_bots.Error)
static SessionRecorder g_log;
static string g_replayText;                                  // playback: the log (web_replay)
static SessionReplay g_replay;
static string g_replayError;
// playback progress for the page: state (0 none, 1 playing, 2 ended, 3 log unreadable), poll,
// end poll, hashes checked, hashes that differed, first poll that differed + 1 (0: none)
static volatile uint32_t g_replayInfo[6];
static volatile uint32_t g_speed = 1;                        // frames per paced step; 0 = paused
static volatile bool g_audioSkip = false;                    // fast-forward: drop this frame's sound
static string g_logCopy;                                     // web_log_snapshot's result

class WebAudio : public IAudioDevice
{
public:
	// the mixer only plays to a device that registered itself (as SdlSoundManager does)
	WebAudio(Emulator* emu) { emu->GetSoundMixer()->RegisterAudioDevice(this); }

	void PlayBuffer(int16_t* samples, uint32_t count, uint32_t sampleRate, bool isStereo) override
	{
		if(g_audioSkip) {
			return;
		}
		uint32_t w = g_audioW.load(), r = g_audioR.load();
		for(uint32_t i = 0; i < count && w - r < AudioCapacity; i++, w++) {
			uint32_t pos = (w & (AudioCapacity - 1)) * 2;
			g_audio[pos] = samples[i * 2];
			g_audio[pos + 1] = samples[i * 2 + 1];
		}
		g_audioW.store(w);
	}
	void Stop() override {}
	void Pause() override {}
	void ProcessEndOfFrame() override {}
	string GetAvailableDevices() override { return ""; }
	void SetAudioDevice(string deviceName) override {}
	AudioStatistics GetStatistics() override { return {}; }
};

static void CopyFrame(IConsole* console)
{
	PpuFrameInfo f = console->GetPpuFrame();
	uint16_t* src = (uint16_t*)f.FrameBuffer;
	int scale = f.Width == 512 ? 2 : 1;
	for(int y = 0; y < FrameH; y++) {
		// rows 7-230 of the 239-row buffer are the 224 visible lines
		uint16_t* line = src + (y + 7) * scale * f.Width;
		uint8_t* out = g_frame + y * FrameW * 4;
		for(int x = 0; x < FrameW; x++) {
			uint16_t c = line[x * scale];
			uint8_t r = c & 0x1F, g = (c >> 5) & 0x1F, b = (c >> 10) & 0x1F;
			out[0] = (r << 3) | (r >> 2);
			out[1] = (g << 3) | (g >> 2);
			out[2] = (b << 3) | (b >> 2);
			out[3] = 255;
			out += 4;
		}
	}
	g_frameSeq++;
}

int main()
{
	while(!g_romSize) {
		std::this_thread::sleep_for(std::chrono::milliseconds(10));
	}

	FolderUtilities::SetHomeFolder("/home/web");
	Emulator* emu = new Emulator();
	emu->Initialize(false);

	SnesConfig& snes = emu->GetSettings()->GetSnesConfig();
	snes.Port1.Type = ControllerType::SnesController;
	snes.Port2.Type = ControllerType::Multitap;
	for(int i = 0; i < 4; i++) {
		snes.Port2SubPorts[i].Type = ControllerType::SnesController;
	}
	snes.DisableFrameSkipping = true;
	// replayable sessions (session.h): work RAM comes from the session's seed (PowerOnRam)
	snes.RamPowerOnState = RamState::AllZeros;
	emu->GetSettings()->SetSnesConfig(snes);

	// this loop paces the frames (by the sound card); at 100% speed Mesen would also pace them, by
	// spin-waiting at the end of every frame (Emulator::ProcessEndOfFrame): 0 = unlimited turns that off
	EmulationConfig emuCfg = emu->GetSettings()->GetEmulationConfig();
	emuCfg.EmulationSpeed = 0;
	emu->GetSettings()->SetEmulationConfig(emuCfg);

	AudioConfig audio = emu->GetSettings()->GetAudioConfig();
	audio.SampleRate = 48000;
	audio.DisableDynamicSampleRate = true;
	emu->GetSettings()->SetAudioConfig(audio);

	// the page copies the PPU's frame buffer itself: Mesen's decode thread would only cost a
	// thread and a spin-wait per frame
	VideoDecoderSkipDecode = true;

	emu->SetAudioVideoInitCallback([emu]() -> IAudioDevice* { return new WebAudio(emu); }, []() -> IRenderingDevice* { return nullptr; });
	// the lock is taken before the load (it can be taken again by this thread, as LoadRom does):
	// Mesen's emulation thread starts in LoadRom and would otherwise run frames on its own until
	// we have the lock, a different number each time, before the session log starts
	auto lock = emu->AcquireLock();
	if(!emu->LoadRom(VirtualFile(g_rom, g_romSize, "tmnt4-4p.sfc"), VirtualFile())) {
		printf("LoadRom failed\n");
		return 1;
	}
	printf("ROM loaded\n");

	// input providers belong to the console's control manager: register after the load
	// (Emulator::RegisterInputProvider silently ignores calls made with no console)
	bool replay = !g_replayText.empty();
	if(replay) {
		if(!g_replay.Parse(g_replayText, g_replayError)) {
			g_replayInfo[0] = 3;
			printf("session log: %s\n", g_replayError.c_str());
			return 1;
		}
		g_seed = g_replay.Seed;
		g_replay.Start(emu);
		g_replayInfo[2] = g_replay.End;
		g_replayInfo[0] = 1;
	}
	PowerOnRam(emu, g_seed);
	g_log.Start(emu, g_seed);
	static WebPads input(&g_page, &g_bots, replay ? (InputLog*)&g_replay : &g_log);
	emu->RegisterInputProvider(&input);
	if(!g_botScript.empty()) {
		g_botState = g_bots.Load(emu, g_botScript, "play_with_bots.lua", g_seed) ? 1 : 2;
	}
	IConsole* console = emu->GetConsoleUnsafe();
	using Clock = std::chrono::steady_clock;
	// (before the sound starts; 50.007 Hz for the PAL versions)
	const auto period = std::chrono::nanoseconds((int64_t)(1e9 / console->GetFps()));
	auto next = Clock::now();
	auto fpsStart = Clock::now();
	int fpsFrames = 0;
	float frameMsSum = 0, frameMsMax = 0;
	while(true) {
		if(g_speed == 0 || g_replayInfo[0] == 2) {
			// playback paused or at its end
			std::this_thread::sleep_for(std::chrono::milliseconds(16));
			next = Clock::now();
			continue;
		}
		if(g_audioActive) {
			// paced by the sound card: run a frame whenever the queue runs low. Wait on the
			// worklet's read counter (it notifies every 128 samples) instead of sleeping: timed
			// sleeps in a browser worker can round up to the OS timer tick (15.6 ms on Windows).
			// If the sound stops, each wait ends after 50 ms, so the emulation can't run away.
			uint32_t r;
			while(g_audioW.load() - (r = g_audioR.load()) > AudioTarget) {
				emscripten_futex_wait((volatile void*)&g_audioR, r, 50);
			}
			next = Clock::now();
		} else {
			// no sound yet (browsers start audio only after a click): paced by the clock
			// (timer-tick rounding applies here; it only lasts until the first click)
			std::this_thread::sleep_until(next);
			next += period;
			if(Clock::now() - next > period * 10) {
				next = Clock::now();
			}
			g_audioR.store(g_audioW.load());
		}
		auto start = Clock::now();
		// fast-forward: several frames per step, the sound of the last only (so the sound card
		// keeps pacing the steps)
		uint32_t speed = g_speed, frames = replay ? std::max(1u, speed) : 1;
		for(uint32_t i = 0; i < frames && g_replayInfo[0] != 2; i++) {
			g_audioSkip = i + 1 < frames;
			console->RunFrame();
			if(replay) {
				g_replayInfo[1] = input.Polls();
				g_replayInfo[3] = g_replay.HashesChecked;
				g_replayInfo[4] = g_replay.Mismatches;
				g_replayInfo[5] = (uint32_t)(g_replay.FirstMismatch + 1);
				if(input.Polls() > g_replay.End) {
					g_replayInfo[0] = 2;
				}
			}
		}
		g_audioSkip = false;
		CopyFrame(console);
		if(g_botState == 1 && !g_bots.Error.empty()) {
			g_botState = 2;
		}
		float ms = std::chrono::duration<float, std::milli>(Clock::now() - start).count();
		frameMsSum += ms;
		frameMsMax = std::max(frameMsMax, ms);

		if(++fpsFrames == 60) {
			auto now = Clock::now();
			g_fps = 60 / std::chrono::duration<float>(now - fpsStart).count();
			g_frameMsAvg = frameMsSum / 60;
			g_frameMsMax = frameMsMax;
			frameMsSum = frameMsMax = 0;
			fpsStart = now;
			fpsFrames = 0;
		}
	}
}

extern "C" {
EMSCRIPTEN_KEEPALIVE void web_start(uint8_t* rom, uint32_t size) { g_rom = rom; g_romSize = size; }
EMSCRIPTEN_KEEPALIVE volatile uint32_t* web_input_ptr() { return g_page.Masks; }
EMSCRIPTEN_KEEPALIVE uint8_t* web_frame_ptr() { return g_frame; }
EMSCRIPTEN_KEEPALIVE uint32_t web_frame_seq() { return g_frameSeq.load(); }
EMSCRIPTEN_KEEPALIVE int16_t* web_audio_ptr() { return g_audio; }
EMSCRIPTEN_KEEPALIVE uint32_t web_audio_capacity() { return AudioCapacity; }
EMSCRIPTEN_KEEPALIVE void* web_audio_w_ptr() { return &g_audioW; }
EMSCRIPTEN_KEEPALIVE void* web_audio_r_ptr() { return &g_audioR; }
EMSCRIPTEN_KEEPALIVE void web_audio_active(uint32_t active) { g_audioActive = active; }
EMSCRIPTEN_KEEPALIVE float web_fps() { return g_fps; }
EMSCRIPTEN_KEEPALIVE float web_frame_ms_avg() { return g_frameMsAvg; }
EMSCRIPTEN_KEEPALIVE float web_frame_ms_max() { return g_frameMsMax; }
EMSCRIPTEN_KEEPALIVE volatile uint32_t* web_underruns_ptr() { return &g_audioUnderruns; }
EMSCRIPTEN_KEEPALIVE void web_bots(const char* script, uint32_t size) { g_botScript.assign(script, size); }
EMSCRIPTEN_KEEPALIVE void web_seed(uint32_t seed) { g_seed = seed; }
EMSCRIPTEN_KEEPALIVE void web_audio_target(uint32_t samples) { AudioTarget = samples; }
// roles of P1-P4 ('h' person, 'b' bot, '-' out), one byte each from the low end; god: bots keep their health
EMSCRIPTEN_KEEPALIVE void web_seats(uint32_t roles, uint32_t god)
{
	for(int i = 0; i < 4; i++) {
		g_page.Seats[i] = (char)(roles >> (i * 8));
	}
	g_page.God = god != 0;
}
// the session log so far (session.h): a copy, valid until the next call; size in web_log_size
EMSCRIPTEN_KEEPALIVE const char* web_log_snapshot()
{
	g_logCopy = g_log.Snapshot();
	return g_logCopy.c_str();
}
EMSCRIPTEN_KEEPALIVE uint32_t web_log_size() { return g_logCopy.size(); }
// playback of a session log (text, not gzipped), before web_start
EMSCRIPTEN_KEEPALIVE void web_replay(const char* text, uint32_t size) { g_replayText.assign(text, size); }
EMSCRIPTEN_KEEPALIVE volatile uint32_t* web_replay_info() { return g_replayInfo; }
EMSCRIPTEN_KEEPALIVE const char* web_replay_error() { return g_replayError.c_str(); }
EMSCRIPTEN_KEEPALIVE void web_speed(uint32_t speed) { g_speed = speed; }
EMSCRIPTEN_KEEPALIVE int web_bot_state() { return g_botState.load(); }
EMSCRIPTEN_KEEPALIVE const char* web_bot_error() { return g_botState == 2 ? g_bots.Error.c_str() : ""; }
}
