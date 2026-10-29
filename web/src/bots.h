// Bots for the browser version: runs scripts/lua/play_with_bots.lua, the
// same file the desktop bots use, in a small Lua host instead of Mesen's script engine. That
// engine needs Mesen's debugger, which hooks every CPU instruction (~5 ms per frame in
// WebAssembly); the bots themselves cost ~1 ms. The host provides the few emu.* calls the
// script uses and calls its callbacks at the same points in the frame as Mesen does.
#pragma once
#include "pch.h"
#include "Shared/Interfaces/IInputProvider.h"

class Emulator;
class BaseControlDevice;
struct lua_State;

class LuaBots
{
public:
	// seat roles for emu.seats(): "h" person, "b" bot, "-" stays out; and the bots' god mode.
	// Set by WebPads once per poll, before the bots run (from the page, or from a session log).
	char Seats[4] = { 'h', 'h', 'h', 'h' };
	uint8_t God = 0;
	// set when the script failed (load or callback error): the bots stop, people keep playing
	string Error;

	// Load the script (with the emulator lock held, ROM loaded); seed: math.randomseed, so a
	// session log can replay the bots exactly. False + Error on failure.
	bool Load(Emulator* emu, const string& script, const string& name, uint32_t seed);
	// Mesen fires EndFrame and then InputPolled back to back at the end of each frame
	// (SnesPpu at the NMI scanline, then SnesConsole::ProcessEndOfFrame -> UpdateInputState),
	// with nothing run in between; the input provider calls this at that point.
	void FrameEnd();
	// after a save state was loaded (Mesen's stateLoaded event)
	void StateLoaded();
	// the script's controller for player p (0-3), applied over the person's buttons: bits set
	// in Mask replace the buttons in Used
	struct Override { uint32_t Used = 0, Mask = 0; };
	Override Pads[4];

private:
	lua_State* _lua = nullptr;
	Emulator* _emu = nullptr;
	uint8_t* _wram = nullptr;
	uint32_t _wramSize = 0;
	uint8_t* _rom = nullptr;
	uint32_t _romSize = 0;
	uint16_t _y = 0;
	vector<int> _callbacks[3];   // inputPolled, endFrame, stateLoaded (Lua registry refs)
	int _execCallback = -1;

	void Run(int event);
	void Fail(const char* what);
	static void ExecHook(uint16_t y);
	static LuaBots* Self(lua_State* lua);
	static int Read(lua_State* lua);
	static int Write(lua_State* lua);
	static int SetInput(lua_State* lua);
	static int GetState(lua_State* lua);
	static int AddEventCallback(lua_State* lua);
	static int AddMemoryCallback(lua_State* lua);
	static int GetSeats(lua_State* lua);
	static int Nothing(lua_State* lua);
};

// What the page sets, at any time (single words: no lock needed): pad bitmasks (P1-P4) and
// the seats (LuaBots::Seats/God).
struct PageInput
{
	volatile uint32_t Masks[4] = {};
	volatile char Seats[4] = { 'h', 'h', 'h', 'h' };
	volatile uint8_t God = 0;
};

// One poll's input, taken from PageInput once per poll (at P1's pad) so that everything in the
// poll, and the session log, sees the same values.
struct PollInput
{
	uint32_t Masks[4] = {};
	char Seats[4] = { 'h', 'h', 'h', 'h' };
	uint8_t God = 0;
};

// Session log (session.h): sees every poll's input before it is used; a replay replaces it.
class InputLog
{
public:
	virtual ~InputLog() {}
	virtual void Poll(uint32_t poll, PollInput& in) = 0;
};

// The page's pads (P1 = port 1, P2-P4 = multitap A-C), with the bots' overrides on top.
class WebPads : public IInputProvider
{
	const PageInput* _page;
	LuaBots* _bots;
	InputLog* _log;
	PollInput _in;
	uint32_t _poll = 0;
	static void Apply(BaseControlDevice* device, uint32_t mask);

public:
	WebPads(const PageInput* page, LuaBots* bots, InputLog* log = nullptr) : _page(page), _bots(bots), _log(log) {}
	bool SetInput(BaseControlDevice* device) override;
	uint32_t Polls() const { return _poll; }
};
