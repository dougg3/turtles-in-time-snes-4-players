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
// Online play (web_net before web_start): lockstep, see g_net below.
#include "pch.h"
#include <atomic>
#include <chrono>
#include <climits>
#include <sstream>
#include <thread>
#include <emscripten.h>
#include <emscripten/threading.h>
#include "Shared/Emulator.h"
#include "Shared/EmuSettings.h"
#include "Shared/SaveStateManager.h"
#include "Shared/SettingTypes.h"
#include "bots.h"
#include "session.h"
#include "Shared/Interfaces/IAudioDevice.h"
#include "Shared/Audio/SoundMixer.h"
#include "Shared/Interfaces/IConsole.h"
#include "Utilities/VirtualFile.h"
#include "Utilities/FolderUtilities.h"
#include "Utilities/miniz.h"

static constexpr int FrameW = 256, FrameH = 224;
static constexpr uint32_t AudioCapacity = 16384;  // stereo frames (power of 2)
static uint32_t AudioTarget = 3072;     // keep ~64 ms queued (2048 dropped out on the user's PC; ?audio= sets it)

static uint8_t* g_rom = nullptr;
static std::atomic<uint32_t> g_romSize{ 0 };   // set after g_rom (web_start): the core thread starts on it
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
static bool g_logging = false;                               // g_log records this session (not playback, not joined mid-way)
static string g_replayText;                                  // playback: the log (web_replay)
static SessionReplay g_replay;
static string g_replayError;
// playback progress for the page: state (0 none, 1 playing, 2 ended, 3 log unreadable), poll,
// end poll, hashes checked, hashes that differed, first poll that differed + 1 (0: none)
static volatile uint32_t g_replayInfo[6];
static volatile uint32_t g_speed = 1;                        // frames per paced step; 0 = paused
static volatile bool g_audioSkip = false;                    // fast-forward: drop this frame's sound
static string g_logCopy;                                     // web_log_snapshot's result

// Online play, lockstep: every computer runs the same frames from the same input (and the same
// ROM, seed, seats and bots), so they all show the same game. A poll runs only once the input of
// every person's seat for it is known. This thread writes its own seats' input a few polls ahead
// (the input delay, which gives it time to reach the other computers); the page writes the other
// seats' as it arrives (net.js) and wakes this thread. Words of g_net, shared with the page
// (Atomics there; NET_* indexes, also in net.js):
enum : uint32_t {
	NET_ACTIVE = 0,      // 1: online game (set before web_start), 2: running, 3: stopped (left the game)
	NET_DELAY = 1,       // input delay, polls
	NET_LOCAL = 2,       // bit per seat played on this computer
	NET_HUMAN = 3,       // bit per seat played by a person from the start (here or elsewhere)
	NET_SEQ = 4,         // the page adds 1 and notifies after writing input
	NET_POLL = 5,        // the next poll to run
	NET_WAITS = 6,       // polls that had to wait for input, total
	NET_WAIT_MS = 7,     // time spent waiting, total
	NET_LOCAL_SEQ = 8,   // this thread adds 1 and notifies after writing its seats' input (or an event)
	NET_HASHES = 9,      // number of work RAM hashes written so far
	NET_STALL = 10,      // frames to hold back (the page asks when this computer runs ahead of the others)
	NET_GAPS = 11,       // [4] frames by time since the previous frame: < 4 ms, 4-12, 12-21, more (pacing check)
	NET_SEAT_DELAY = 15, // [4] per seat played here: its input delay now, if not 0 (the page adapts it)
	NET_STOPPED = 19,    // why NET_ACTIVE went to 3 here: 1 the state to join from didn't load, 2 an event
	                     //   was missed, 3 the state to get back in sync from didn't load
	NET_HAVE = 20,       // [4] per seat: input known for the polls below this
	NET_PADS = 24,       // [4] per seat: the local pads now (written by the page)
	NET_DROP = 28,       // [4] per seat: from this poll on (if not 0), a bot plays it: its player left
	NET_HASH = 32,       // [64][3]: poll, hash low, hash high: work RAM after that many polls
	NET_JOIN = 224,      // [4] per seat: from this poll on (if not 0), a person plays it: they joined
	                     //   mid-game (of a drop and a join, the later one counts)
	NET_EVENT_AT = 228,  // a poll where every computer starts the bots over (someone joins there)
	NET_EVENT_SEED = 229,//   with this seed
	NET_EVENT_SAVE = 230,//   1: this computer also saves the state there, for the one joining
	NET_EVENT_DONE = 231,// the last event poll handled
	NET_STATE_SIZE = 232,// the saved state's size (web_net_state_ptr), once saved
	NET_EVENT_LOAD = 233,//   1: this computer loads a state there instead (out of sync: start again from
	                     //   the coordinator's state); it waits there until the page has it (web_net_load)
	NET_LOAD_SIZE = 234, // the size of the state to load (web_net_load), once the page has it
	NET_RUSH = 235,      // frames to run extra, without their sound (the page asks when this computer
	                     //   is behind the others): the opposite of NET_STALL
	NET_IN = 256,        // [NetRing][4]: input per poll and seat
};
static constexpr uint32_t NetRing = 256, NetHashRing = 64, NetHashEvery = 60;
static uint32_t g_net[NET_IN + NetRing * 4];
static string g_netState;           // a state saved for a computer joining (NET_EVENT_SAVE)
static string g_netJoinState;       // joining: the state to start from (web_net_join)
static bool g_netJoinBots = false;  // joining: the bots start at the first poll (NetBeforeFrame)
static string g_netLoadState;       // out of sync: the state to load at the event (web_net_load)
static uint32_t g_netJoinPoll = 0;  //   and its poll

// A state from another computer, checked before Mesen reads it: its loader adds each entry's size
// to its position in 32 bits, so a crafted size wraps round (it loops for good, or copies out of
// bounds). Only the compressed form, as Serialize makes it (compression level 1), under Mesen's
// 10 MB; every entry (a printable key ending in 0, a 4-byte size, the value) within the data.
// Into out uncompressed (format byte 0), so it isn't uncompressed twice.
static bool NetCheckState(const string& st, string& out)
{
	out.clear();
	if(st.size() < 9 || st[0] != 1) {
		return false;
	}
	uint32_t dsize, csize;
	memcpy(&dsize, &st[1], 4);
	memcpy(&csize, &st[5], 4);
	if(dsize == 0 || dsize >= 1024 * 1024 * 10 || csize != st.size() - 9) {
		return false;
	}
	out.assign(1 + (size_t)dsize, '\0');
	mz_ulong n = dsize;
	if(mz_uncompress((unsigned char*)&out[1], &n, (const unsigned char*)&st[9], csize) != MZ_OK || n != dsize) {
		out.clear();
		return false;
	}
	const uint8_t* d = (const uint8_t*)out.data();
	size_t i = 1, end = out.size();
	while(i < end) {
		size_t k = i;
		while(k < end && d[k] != 0) {
			if(d[k] <= ' ' || d[k] >= 127) {
				out.clear();
				return false;
			}
			k++;
		}
		if(k == i || end - k < 5) {   // (no key, no 0 at its end, or no room for the size)
			out.clear();
			return false;
		}
		uint32_t v = d[k + 1] | (d[k + 2] << 8) | (d[k + 3] << 16) | ((uint32_t)d[k + 4] << 24);
		if(v > end - (k + 5)) {
			out.clear();
			return false;
		}
		i = k + 5 + v;
	}
	return true;
}

static uint32_t NetLoad(uint32_t i) { return __atomic_load_n(&g_net[i], __ATOMIC_SEQ_CST); }
static void NetStore(uint32_t i, uint32_t v) { __atomic_store_n(&g_net[i], v, __ATOMIC_SEQ_CST); }
static void NetWakePage()
{
	__atomic_fetch_add(&g_net[NET_LOCAL_SEQ], 1, __ATOMIC_SEQ_CST);
	emscripten_futex_wake(&g_net[NET_LOCAL_SEQ], INT_MAX);
}

// a seat's player at poll p: a person from the start, unless they left (NET_DROP) or joined
// later (NET_JOIN); of a drop and a join, the later one counts
static bool NetPerson(int s, uint32_t p, uint32_t human)
{
	uint32_t j = NetLoad(NET_JOIN + s), d = NetLoad(NET_DROP + s);
	bool person = human >> s & 1;
	auto apply = [&](uint32_t at, bool v) {
		if(at && p >= at) {
			person = v;
		}
	};
	if(j <= d) {
		apply(j, true);
		apply(d, false);
	} else {
		apply(d, false);
		apply(j, true);
	}
	return person;
}

// the bots' seats before the script (re)starts mid-game: this poll's, the same on every computer
// (the script reads them as it loads; otherwise they'd be the last poll's here, and the defaults on
// a computer joining)
static void NetBotSeats()
{
	for(int s = 0; s < 4; s++) {
		g_bots.Seats[s] = g_page.Seats[s];
	}
	g_bots.God = g_page.God;
}

// someone joins at this poll: save the state for them (one computer), start the bots over (all);
// or the computers were out of sync: all but one load the one's state here
static void NetEvent(Emulator* emu, uint32_t p)
{
	uint32_t at = NetLoad(NET_EVENT_AT);
	if(!at || NetLoad(NET_EVENT_DONE) == at) {
		return;
	}
	if(p != at) {
		if(p > at) {
			// its bots didn't start over (or its state didn't load) with everyone else's: this
			// computer's game is another one from here, so it stops (the page offers Rejoin)
			printf("online: event at poll %u missed (now %u)\n", at, p);
			NetStore(NET_EVENT_DONE, at);
			NetStore(NET_STOPPED, 2);
			NetStore(NET_ACTIVE, 3);
		}
		return;
	}
	if(NetLoad(NET_EVENT_SAVE)) {
		std::stringstream out;
		emu->Serialize(out, false, 1);
		g_netState = out.str();
		NetStore(NET_STATE_SIZE, (uint32_t)g_netState.size());
		NetWakePage();
	}
	if(NetLoad(NET_EVENT_LOAD)) {
		// (the page clears NET_EVENT_LOAD if the state won't come: then it goes on without it)
		while(NetLoad(NET_EVENT_LOAD) && !NetLoad(NET_LOAD_SIZE) && NetLoad(NET_ACTIVE) != 3) {
			uint32_t seq = NetLoad(NET_SEQ);
			if(NetLoad(NET_LOAD_SIZE)) {
				break;
			}
			emscripten_futex_wait(&g_net[NET_SEQ], seq, 100);
		}
		if(NetLoad(NET_LOAD_SIZE)) {
			string checked;
			bool ok = NetCheckState(g_netLoadState, checked);
			std::stringstream in(checked);
			if(!ok || emu->Deserialize(in, SaveStateManager::FileFormatVersion, false, std::nullopt, false) != DeserializeResult::Success) {
				// (part of it may have loaded: this game is another one now) it stops; the page offers Rejoin
				printf("online: the state to resync from did not load\n");
				NetStore(NET_STOPPED, 3);
				NetStore(NET_ACTIVE, 3);
			} else if(g_logging) {
				g_log.StateLoaded(at);
			}
			g_netLoadState.clear();
			NetStore(NET_LOAD_SIZE, 0);
		}
	}
	if(g_logging) {
		char seats[4] = { g_page.Seats[0], g_page.Seats[1], g_page.Seats[2], g_page.Seats[3] };
		g_log.BotsRestart(at, NetLoad(NET_EVENT_SEED), seats, g_page.God);
	}
	if(!g_botScript.empty()) {
		NetBotSeats();
		g_botState = g_bots.Reload(NetLoad(NET_EVENT_SEED)) ? 1 : 2;
	}
	NetStore(NET_EVENT_DONE, at);
	NetWakePage();
}

// before the frame that ends with poll p: write this computer's input for poll p + delay, wait
// until every person's input for p is known, and hand it to the pads (WebPads reads g_page)
static void NetBeforeFrame(Emulator* emu, uint32_t p)
{
	uint32_t delay = NetLoad(NET_DELAY), local = NetLoad(NET_LOCAL), human = NetLoad(NET_HUMAN);
	bool wrote = false;
	for(int s = 0; s < 4; s++) {
		if(!(local >> s & 1)) {
			continue;
		}
		// the input for poll p + this seat's delay; when the delay grows, the polls in between get
		// the same buttons, and when it shrinks, nothing is written until it catches up
		uint32_t d = NetLoad(NET_SEAT_DELAY + s);
		uint32_t target = p + std::max(1u, std::min(d ? d : delay, NetRing / 4));
		// (the seat's join before its HAVE: the page stores HAVE, then JOIN, so a JOIN seen here
		// comes with its HAVE)
		bool person = NetPerson(s, target, human | local);
		uint32_t have = NetLoad(NET_HAVE + s);
		if(have <= target && person) {
			uint32_t mask = NetLoad(NET_PADS + s) & 0xFFF;
			for(uint32_t q = have; q <= target; q++) {
				NetStore(NET_IN + q % NetRing * 4 + s, mask);
			}
			NetStore(NET_HAVE + s, target + 1);
			wrote = true;
		}
	}
	if(wrote) {
		NetWakePage();
	}
	NetStore(NET_POLL, p);
	// seats whose player left (or joined): from the poll all the computers agreed on
	auto person = [&](int s) { return NetPerson(s, p, human); };
	auto ready = [&]() {
		if(NetLoad(NET_ACTIVE) == 3) {
			return false;
		}
		for(int s = 0; s < 4; s++) {
			if(person(s) && NetLoad(NET_HAVE + s) <= p) {
				return false;
			}
		}
		return true;
	};
	if(!ready()) {
		auto start = std::chrono::steady_clock::now();
		while(true) {
			uint32_t seq = NetLoad(NET_SEQ);
			if(ready()) {
				break;
			}
			emscripten_futex_wait(&g_net[NET_SEQ], seq, 100);
		}
		g_net[NET_WAITS]++;
		g_net[NET_WAIT_MS] += (uint32_t)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
	}
	for(int s = 0; s < 4; s++) {
		g_page.Masks[s] = person(s) ? NetLoad(NET_IN + p % NetRing * 4 + s) : 0;
		if(person(s)) {
			g_page.Seats[s] = 'h';
		} else if(g_page.Seats[s] == 'h') {
			g_page.Seats[s] = 'b';
		}
	}
	// joining: the bots start here, with this poll's seats, as the others' start over here
	if(g_netJoinBots) {
		g_netJoinBots = false;
		NetBotSeats();
		g_botState = g_bots.Load(emu, g_botScript, "play_with_bots.lua", g_seed) ? 1 : 2;
	}
	// only now: a computer can be at the event's poll before it hears of the event, but it can't
	// have the input for it (the coordinator holds that back until everyone knows). After the
	// seats: the bots start over with poll p's seats, as on the computer joining there
	NetEvent(emu, p);
}

// after poll p: every NetHashEvery polls, the work RAM hash, which the page compares between computers
static void NetAfterFrame(Emulator* emu, uint32_t polls)
{
	if(polls % NetHashEvery) {
		return;
	}
	ConsoleMemoryInfo w = emu->GetMemory(MemoryType::SnesWorkRam);
	uint64_t h = WramHash((uint8_t*)w.Memory, w.Size);
	uint32_t n = g_net[NET_HASHES], at = NET_HASH + n % NetHashRing * 3;
	g_net[at] = polls;
	g_net[at + 1] = (uint32_t)h;
	g_net[at + 2] = (uint32_t)(h >> 32);
	NetStore(NET_HASHES, n + 1);
}


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
	while(!g_romSize.load(std::memory_order_acquire)) {
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
	if(!emu->LoadRom(VirtualFile(g_rom, g_romSize.load(), "tmnt4-4p.sfc"), VirtualFile())) {
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
	// joining an online game mid-way: no session log (it couldn't be replayed from power-on)
	bool joining = !g_netJoinState.empty();
	g_log.Start(emu, g_seed);
	g_logging = !replay && !joining;
	static WebPads input(&g_page, &g_bots, replay ? (InputLog*)&g_replay : joining ? nullptr : &g_log);
	emu->RegisterInputProvider(&input);
	if(joining) {
		string checked;
		bool ok = NetCheckState(g_netJoinState, checked);
		std::stringstream in(checked);
		if(!ok || emu->Deserialize(in, SaveStateManager::FileFormatVersion, false, std::nullopt, false) != DeserializeResult::Success) {
			printf("online: the state to join from did not load\n");
			NetStore(NET_STOPPED, 1);
			NetStore(NET_ACTIVE, 3);
		}
		input.SetPolls(g_netJoinPoll);
		g_netJoinState.clear();
		NetStore(NET_EVENT_DONE, g_netJoinPoll);
	}
	if(!g_botScript.empty()) {
		if(joining) {
			// the bots start at the first NetBeforeFrame, with that poll's seats (as the others'
			// bots start over there): a player who left after this computer was let in may have
			// become a bot by then
			g_netJoinBots = true;
		} else {
			g_botState = g_bots.Load(emu, g_botScript, "play_with_bots.lua", g_seed) ? 1 : 2;
		}
	}
	IConsole* console = emu->GetConsoleUnsafe();
	bool net = g_net[NET_ACTIVE] != 0 && !replay;
	if(net) {
		// the first `delay` polls of every person's seat: no buttons, on every computer (joining:
		// ours; the others' come from them)
		uint32_t human = g_net[NET_HUMAN], local = g_net[NET_LOCAL];
		for(int s = 0; s < 4; s++) {
			if(NetPerson(s, input.Polls(), human)) {
				NetStore(NET_HAVE + s, input.Polls() + (joining && !(local >> s & 1) ? 0 : g_net[NET_DELAY]));
			}
		}
		// running: the page may write input now (not over a 3 the page stored meanwhile)
		uint32_t starting = 1;
		__atomic_compare_exchange_n(&g_net[NET_ACTIVE], &starting, 2u, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
	}
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
		if(net) {
			// online: evenly spaced frames. The sound card can take sound in big chunks (40 ms
			// in headless Chrome), which makes frames run in pairs; this computer's input then
			// goes out in pairs too and eats into the input delay's slack. At most 4/3 speed
			// here; the sound still sets the average.
			static auto last = Clock::now();
			static uint32_t never = 0;
			auto earliest = last + period * 3 / 4;
			for(auto now = Clock::now(); now < earliest; now = Clock::now()) {
				emscripten_futex_wait(&never, 0, std::chrono::duration<double, std::milli>(earliest - now).count());
			}
			last = Clock::now();
		}
		if(net && NetLoad(NET_STALL) > 0) {
			// ahead of the others: let a frame's time pass without a frame (and its sound: silence),
			// so this computer falls back for good instead of waiting for input every frame
			__atomic_fetch_sub(&g_net[NET_STALL], 1, __ATOMIC_SEQ_CST);
			if(g_audioActive) {
				uint32_t w = g_audioW.load(), n = (uint32_t)(48000 / console->GetFps());
				for(uint32_t i = 0; i < n && w - g_audioR.load() < AudioCapacity; i++, w++) {
					g_audio[(w & (AudioCapacity - 1)) * 2] = g_audio[(w & (AudioCapacity - 1)) * 2 + 1] = 0;
				}
				g_audioW.store(w);
			}
			continue;
		}
		auto start = Clock::now();
		// fast-forward: several frames per step, the sound of the last only (so the sound card
		// keeps pacing the steps)
		uint32_t speed = g_speed, frames = replay ? std::max(1u, speed) : 1;
		if(net && NetLoad(NET_RUSH) > 0) {
			// behind the others: an extra frame now, its sound dropped, so this computer catches up
			// for good (with the sound as the clock, a frame's sound played would pull it back)
			__atomic_fetch_sub(&g_net[NET_RUSH], 1, __ATOMIC_SEQ_CST);
			frames = 2;
		}
		for(uint32_t i = 0; i < frames && g_replayInfo[0] != 2; i++) {
			g_audioSkip = i + 1 < frames;
			if(net) {
				static auto prev = Clock::now();
				float gap = std::chrono::duration<float, std::milli>(Clock::now() - prev).count();
				prev = Clock::now();
				g_net[NET_GAPS + (gap < 4 ? 0 : gap < 12 ? 1 : gap < 21 ? 2 : 3)]++;
				NetBeforeFrame(emu, input.Polls());
			}
			if(replay && !g_botScript.empty()) {
				// an online session's log: the bots started over here (a join or a resync)
				uint32_t seed;
				PollInput seats;
				if(g_replay.BotsRestart(input.Polls(), seed, seats)) {
					memcpy(g_bots.Seats, seats.Seats, 4);
					g_bots.God = seats.God;
					g_botState = g_bots.Reload(seed) ? 1 : 2;
				}
			}
			console->RunFrame();
			if(net) {
				NetAfterFrame(emu, input.Polls());
			}
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
EMSCRIPTEN_KEEPALIVE void web_start(uint8_t* rom, uint32_t size) { g_rom = rom; g_romSize.store(size, std::memory_order_release); }
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
// online play, before web_start: input delay (polls), seats played here and seats played by people
// (bit per seat); the shared words are at web_net_ptr (g_net)
EMSCRIPTEN_KEEPALIVE void web_net(uint32_t delay, uint32_t localSeats, uint32_t humanSeats)
{
	g_net[NET_DELAY] = std::max(1u, std::min(delay, NetRing / 4));
	g_net[NET_LOCAL] = localSeats & humanSeats & 0xF;
	g_net[NET_HUMAN] = humanSeats & 0xF;
	NetStore(NET_ACTIVE, 1);
}
EMSCRIPTEN_KEEPALIVE uint32_t* web_net_ptr() { return g_net; }
// joining a running online game, before web_start (after web_net): the state saved at `poll`
// by another computer (web_net_state_ptr there)
EMSCRIPTEN_KEEPALIVE void web_net_join(const uint8_t* state, uint32_t size, uint32_t poll)
{
	g_netJoinState.assign((const char*)state, size);
	g_netJoinPoll = poll;
}
EMSCRIPTEN_KEEPALIVE const uint8_t* web_net_state_ptr() { return (const uint8_t*)g_netState.data(); }
// out of sync: the state to load at the event poll (NET_EVENT_LOAD); then NET_LOAD_SIZE is set
EMSCRIPTEN_KEEPALIVE void web_net_load(const uint8_t* state, uint32_t size)
{
	g_netLoadState.assign((const char*)state, size);
	NetStore(NET_LOAD_SIZE, size);
	__atomic_fetch_add(&g_net[NET_SEQ], 1, __ATOMIC_SEQ_CST);
	emscripten_futex_wake(&g_net[NET_SEQ], INT_MAX);
}
EMSCRIPTEN_KEEPALIVE const char* web_bot_error() { return g_botState == 2 ? g_bots.Error.c_str() : ""; }
}
