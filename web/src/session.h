// Session logs: everything needed to replay a browser session
// exactly, saved by the player with a button on the page. The emulator starts from power-on and
// nothing else varies from run to run, so the log holds only a seed (power-on work RAM, the bots'
// random numbers), each poll's input (PollInput: the people's pads, the seats), and a work RAM
// hash every second to check a replay against. Text, one line per change:
//   <poll> p <P1> <P2> <P3> <P4>   pads (SNES button bits, hex), when they change
//   <poll> s <seats> <god>         seats ("hb-b": person, bot, out) and god mode, when they change
//   <poll> h <hash>                work RAM hash (FNV-1a 64) at the start of the poll, every 60
//   <poll> end                     the last poll recorded
// The page adds header lines ("key value") before them; the core writes "seed <n>".
#pragma once
#include "pch.h"
#include <mutex>
#include "bots.h"

class Emulator;

uint64_t WramHash(const uint8_t* wram, uint32_t size);
// Power-on work RAM from a seed, after LoadRom and before the first frame. Random like on a real
// console (and Mesen's default), but repeatable: the game never initializes its random number
// ($94), so its starting value comes from here.
void PowerOnRam(Emulator* emu, uint32_t seed);

class SessionRecorder : public InputLog
{
	std::mutex _lock;
	string _text;
	PollInput _last;
	bool _first = true;
	bool _full = false;
	uint32_t _poll = 0;
	const uint8_t* _wram = nullptr;
	uint32_t _wramSize = 0;

public:
	static constexpr size_t MaxSize = 64 << 20;   // ~ a week of play; then recording stops
	void Start(Emulator* emu, uint32_t seed);
	void Poll(uint32_t poll, PollInput& in) override;
	// the log so far (any thread)
	string Snapshot();
};

class SessionReplay : public InputLog
{
	struct Event { uint32_t Poll; char Kind; PollInput In; uint64_t Hash; };
	vector<Event> _events;
	size_t _next = 0;
	PollInput _cur;
	const uint8_t* _wram = nullptr;
	uint32_t _wramSize = 0;

public:
	uint32_t Seed = 0, End = 0;
	vector<std::pair<string, string>> Header;   // "key value" lines, in order
	uint32_t HashesChecked = 0;
	int64_t FirstMismatch = -1, LastMismatch = -1;   // polls of the first/last hash that differed
	uint32_t Mismatches = 0;

	bool Parse(const string& text, string& error);
	void Start(Emulator* emu);
	void Poll(uint32_t poll, PollInput& in) override;
};
