// Lua host for the bots (bots.h).
#include "bots.h"
#include "Lua/lua.hpp"
#include "Shared/Emulator.h"
#include "Shared/BaseControlDevice.h"
#include "Shared/IControllerHub.h"
#include "Shared/MemoryType.h"

// mesen-tmnt4p (MESEN_TMNT4P_EMBED), SnesCpu::Exec: called before the instruction at SnesExecHookAddr
extern void (*SnesExecHook)(uint16_t y);
extern uint32_t SnesExecHookAddr;

namespace {
// emu.* constants, as far as the script uses them (the values only have to be consistent here)
enum { EvInputPolled, EvEndFrame, EvStateLoaded };
constexpr int MemWram = 1, MemPrgRom = 2, CbExec = 0;
// SNES controller bits (SnesController::Buttons) by their Lua names
const char* const ButtonNames[12] = { "a", "b", "x", "y", "l", "r", "select", "start", "up", "down", "left", "right" };
LuaBots* g_hooked = nullptr;   // the instance behind SnesExecHook
}

LuaBots* LuaBots::Self(lua_State* lua)
{
	return *(LuaBots**)lua_getextraspace(lua);
}

bool LuaBots::Load(Emulator* emu, const string& script, const string& name, uint32_t seed)
{
	_emu = emu;
	ConsoleMemoryInfo wram = emu->GetMemory(MemoryType::SnesWorkRam);
	_wram = (uint8_t*)wram.Memory;
	_wramSize = wram.Size;
	ConsoleMemoryInfo rom = emu->GetMemory(MemoryType::SnesPrgRom);
	_rom = (uint8_t*)rom.Memory;
	_romSize = rom.Size;
	if(!_wram || !_wramSize) {
		Error = "no work RAM";
		return false;
	}

	_lua = luaL_newstate();
	*(LuaBots**)lua_getextraspace(_lua) = this;
	// the libraries Mesen's sandbox gives a script (no io, os, package, debug)
	const luaL_Reg libs[] = {
		{ "_G", luaopen_base }, { LUA_COLIBNAME, luaopen_coroutine }, { LUA_TABLIBNAME, luaopen_table },
		{ LUA_STRLIBNAME, luaopen_string }, { LUA_MATHLIBNAME, luaopen_math }, { LUA_UTF8LIBNAME, luaopen_utf8 },
	};
	for(const luaL_Reg& lib : libs) {
		luaL_requiref(_lua, lib.name, lib.func, 1);
		lua_pop(_lua, 1);
	}

	const luaL_Reg api[] = {
		{ "read", Read }, { "write", Write }, { "setInput", SetInput }, { "getState", GetState },
		{ "addEventCallback", AddEventCallback }, { "addMemoryCallback", AddMemoryCallback },
		{ "seats", GetSeats }, { "drawString", Nothing }, { "displayMessage", Nothing }, { nullptr, nullptr },
	};
	// Lua seeds its generator from the clock: use the given seed instead
	lua_getglobal(_lua, "math");
	lua_getfield(_lua, -1, "randomseed");
	lua_pushinteger(_lua, seed);
	lua_call(_lua, 1, 0);
	lua_pop(_lua, 1);

	luaL_newlib(_lua, api);
	auto constants = [this](const char* table, std::initializer_list<std::pair<const char*, int>> values) {
		lua_newtable(_lua);
		for(auto& v : values) {
			lua_pushinteger(_lua, v.second);
			lua_setfield(_lua, -2, v.first);
		}
		lua_setfield(_lua, -2, table);
	};
	constants("memType", { { "snesWorkRam", MemWram }, { "snesPrgRom", MemPrgRom } });
	constants("eventType", { { "inputPolled", EvInputPolled }, { "endFrame", EvEndFrame }, { "stateLoaded", EvStateLoaded } });
	constants("callbackType", { { "exec", CbExec } });
	lua_setglobal(_lua, "emu");

	if(luaL_loadbufferx(_lua, script.c_str(), script.size(), ("@" + name).c_str(), "t") != LUA_OK || lua_pcall(_lua, 0, 0, 0) != LUA_OK) {
		Fail("load");
		return false;
	}
	return true;
}

void LuaBots::Fail(const char* what)
{
	Error = string(what) + ": " + (lua_isstring(_lua, -1) ? lua_tostring(_lua, -1) : "error");
	lua_pop(_lua, 1);
	printf("bots stopped (%s)\n", Error.c_str());
	for(Override& o : Pads) {
		o = {};
	}
	if(g_hooked == this) {
		SnesExecHook = nullptr;
		g_hooked = nullptr;
	}
}

void LuaBots::Run(int event)
{
	if(!_lua || !Error.empty()) {
		return;
	}
	for(int ref : _callbacks[event]) {
		lua_rawgeti(_lua, LUA_REGISTRYINDEX, ref);
		if(lua_pcall(_lua, 0, 0, 0) != LUA_OK) {
			Fail("callback");
			return;
		}
	}
}

void LuaBots::FrameEnd()
{
	Run(EvEndFrame);
	// setInput only lasts for the poll it was made in (Mesen's providers reset every device first)
	for(Override& o : Pads) {
		o = {};
	}
	Run(EvInputPolled);
}

void LuaBots::StateLoaded()
{
	Run(EvStateLoaded);
}

void LuaBots::ExecHook(uint16_t y)
{
	LuaBots* self = g_hooked;
	if(!self || !self->Error.empty()) {
		return;
	}
	self->_y = y;
	lua_rawgeti(self->_lua, LUA_REGISTRYINDEX, self->_execCallback);
	lua_pushinteger(self->_lua, SnesExecHookAddr);
	lua_pushinteger(self->_lua, 0);
	if(lua_pcall(self->_lua, 2, 0, 0) != LUA_OK) {
		self->Fail("memory callback");
	}
}

// emu.read(address, memType): one byte of work RAM, or of the ROM (the bots read its header
// to tell the game's versions apart)
int LuaBots::Read(lua_State* lua)
{
	LuaBots* self = Self(lua);
	lua_Integer addr = luaL_checkinteger(lua, 1);
	lua_Integer type = luaL_checkinteger(lua, 2) & 0xFF;
	luaL_argcheck(lua, type == MemWram || type == MemPrgRom, 2, "only snesWorkRam or snesPrgRom");
	uint8_t* mem = type == MemWram ? self->_wram : self->_rom;
	uint32_t size = type == MemWram ? self->_wramSize : self->_romSize;
	luaL_argcheck(lua, mem && addr >= 0 && addr < size, 1, "address out of range");
	lua_pushinteger(lua, mem[addr]);
	return 1;
}

// emu.write(address, value, memType) (god mode)
int LuaBots::Write(lua_State* lua)
{
	LuaBots* self = Self(lua);
	lua_Integer addr = luaL_checkinteger(lua, 1);
	lua_Integer value = luaL_checkinteger(lua, 2);
	luaL_argcheck(lua, (luaL_checkinteger(lua, 3) & 0xFF) == MemWram, 3, "only snesWorkRam");
	luaL_argcheck(lua, addr >= 0 && addr < self->_wramSize, 1, "address out of range");
	self->_wram[addr] = (uint8_t)value;
	return 0;
}

// emu.setInput(buttons, _, port, subport): like Mesen, buttons left out (nil) keep the person's
// state; port 0 = P1, port 1 sub-ports 0-2 = P2-P4 (multitap A-C)
int LuaBots::SetInput(lua_State* lua)
{
	LuaBots* self = Self(lua);
	luaL_checktype(lua, 1, LUA_TTABLE);
	lua_Integer port = luaL_checkinteger(lua, 3);
	lua_Integer subport = luaL_optinteger(lua, 4, 0);
	int p = port == 0 ? 0 : (port == 1 && subport >= 0 && subport < 3 ? 1 + (int)subport : -1);
	if(p < 0) {
		return 0;
	}
	Override o;
	for(int bit = 0; bit < 12; bit++) {
		if(lua_getfield(lua, 1, ButtonNames[bit]) != LUA_TNIL) {
			o.Used |= 1 << bit;
			if(lua_toboolean(lua, -1)) {
				o.Mask |= 1 << bit;
			}
		}
		lua_pop(lua, 1);
	}
	self->Pads[p] = o;
	return 0;
}

// emu.getState(): the bots only read "cpu.y", in their exec callback
int LuaBots::GetState(lua_State* lua)
{
	lua_newtable(lua);
	lua_pushinteger(lua, Self(lua)->_y);
	lua_setfield(lua, -2, "cpu.y");
	return 1;
}

int LuaBots::AddEventCallback(lua_State* lua)
{
	LuaBots* self = Self(lua);
	luaL_checktype(lua, 1, LUA_TFUNCTION);
	lua_Integer type = luaL_checkinteger(lua, 2);
	luaL_argcheck(lua, type >= EvInputPolled && type <= EvStateLoaded, 2, "unsupported event");
	lua_pushvalue(lua, 1);
	int ref = luaL_ref(lua, LUA_REGISTRYINDEX);
	self->_callbacks[type].push_back(ref);
	lua_pushinteger(lua, ref);
	return 1;
}

// emu.addMemoryCallback(fn, exec, address): one exec address (the hit check at $03:839D)
int LuaBots::AddMemoryCallback(lua_State* lua)
{
	LuaBots* self = Self(lua);
	luaL_checktype(lua, 1, LUA_TFUNCTION);
	luaL_argcheck(lua, luaL_checkinteger(lua, 2) == CbExec, 2, "only exec callbacks");
	lua_Integer addr = luaL_checkinteger(lua, 3);
	luaL_argcheck(lua, addr >= 0 && addr <= 0xFFFFFF, 3, "address out of range");
	luaL_argcheck(lua, self->_execCallback < 0, 1, "only one exec callback");
	lua_pushvalue(lua, 1);
	self->_execCallback = luaL_ref(lua, LUA_REGISTRYINDEX);
	g_hooked = self;
	SnesExecHookAddr = (uint32_t)addr;
	SnesExecHook = ExecHook;
	lua_pushinteger(lua, self->_execCallback);
	return 1;
}

// emu.seats() -> roles ("h"/"b"/"-" per player), bots' god mode
int LuaBots::GetSeats(lua_State* lua)
{
	LuaBots* self = Self(lua);
	char s[4];
	for(int i = 0; i < 4; i++) {
		char c = self->Seats[i];
		s[i] = c == 'b' || c == '-' ? c : 'h';
	}
	lua_pushlstring(lua, s, 4);
	lua_pushboolean(lua, self->God != 0);
	return 2;
}

int LuaBots::Nothing(lua_State*)
{
	return 0;
}

void WebPads::Apply(BaseControlDevice* device, uint32_t mask)
{
	device->ClearState();
	for(int bit = 0; bit < 12; bit++) {
		device->SetBitValue(bit, (mask >> bit) & 1);
	}
}

bool WebPads::SetInput(BaseControlDevice* device)
{
	// devices come in port order: P1's pad first, so the poll's input is taken and the bots run
	// once per poll, before any pad is set
	if(device->GetPort() == 0) {
		for(int i = 0; i < 4; i++) {
			_in.Masks[i] = _page->Masks[i] & 0xFFF;
			_in.Seats[i] = _page->Seats[i];
		}
		_in.God = _page->God;
		if(_log) {
			_log->Poll(_poll, _in);
		}
		_poll++;
		if(_bots) {
			memcpy(_bots->Seats, _in.Seats, 4);
			_bots->God = _in.God;
			_bots->FrameEnd();
		}
	}
	auto mask = [this](int p) {
		uint32_t m = _in.Masks[p];
		if(_bots) {
			m = (m & ~_bots->Pads[p].Used) | _bots->Pads[p].Mask;
		}
		return m;
	};
	IControllerHub* hub = dynamic_cast<IControllerHub*>(device);
	if(hub) {
		for(int i = 0; i < hub->GetHubPortCount(); i++) {
			shared_ptr<BaseControlDevice> sub = hub->GetController(i);
			if(sub) {
				Apply(sub.get(), i < 3 ? mask(1 + i) : 0);
			}
		}
		hub->RefreshHubState();
	} else if(device->GetPort() == 0) {
		Apply(device, mask(0));
	}
	return true;
}
