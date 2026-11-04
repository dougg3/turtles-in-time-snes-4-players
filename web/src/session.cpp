// Session logs: recording (page) and replay (bench); format in session.h.
#include "session.h"
#include <algorithm>
#include <cstdlib>
#include <sstream>
#include "Shared/Emulator.h"
#include "Shared/MemoryType.h"

static constexpr uint32_t HashEvery = 60;

uint64_t WramHash(const uint8_t* p, uint32_t size)
{
	uint64_t h = 1469598103934665603ULL;
	for(uint32_t i = 0; i < size; i++) {
		h = (h ^ p[i]) * 1099511628211ULL;
	}
	return h;
}

static bool SameSeats(const PollInput& a, const PollInput& b)
{
	return !memcmp(a.Seats, b.Seats, 4) && a.God == b.God;
}

void PowerOnRam(Emulator* emu, uint32_t seed)
{
	ConsoleMemoryInfo wram = emu->GetMemory(MemoryType::SnesWorkRam);
	uint64_t x = seed;
	for(uint32_t i = 0; i < wram.Size; i++) {
		// splitmix64
		uint64_t z = (x += 0x9E3779B97F4A7C15ULL);
		z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
		z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
		((uint8_t*)wram.Memory)[i] = (uint8_t)(z ^ (z >> 31));
	}
}

void SessionRecorder::Start(Emulator* emu, uint32_t seed)
{
	ConsoleMemoryInfo wram = emu->GetMemory(MemoryType::SnesWorkRam);
	_wram = (const uint8_t*)wram.Memory;
	_wramSize = wram.Size;
	std::lock_guard<std::mutex> l(_lock);
	_text = "seed " + std::to_string(seed) + "\n";
}

void SessionRecorder::Poll(uint32_t poll, PollInput& in)
{
	char line[96];
	string add;
	if(poll % HashEvery == 0 && _wram) {
		snprintf(line, sizeof(line), "%u h %016llx\n", poll, (unsigned long long)WramHash(_wram, _wramSize));
		add += line;
	}
	if(_first || memcmp(in.Masks, _last.Masks, sizeof(in.Masks))) {
		snprintf(line, sizeof(line), "%u p %03x %03x %03x %03x\n", poll, in.Masks[0], in.Masks[1], in.Masks[2], in.Masks[3]);
		add += line;
	}
	if(_first || !SameSeats(in, _last)) {
		snprintf(line, sizeof(line), "%u s %.4s %d\n", poll, in.Seats, in.God ? 1 : 0);
		add += line;
	}
	_first = false;
	_last = in;
	std::lock_guard<std::mutex> l(_lock);
	_poll = poll;
	if(!_full) {
		_text += add;
		_full = _text.size() > MaxSize;
	}
}

void SessionRecorder::BotsRestart(uint32_t poll, uint32_t seed, const char seats[4], bool god)
{
	char line[96];
	snprintf(line, sizeof(line), "%u b %u %.4s %d\n", poll, seed, seats, god ? 1 : 0);
	std::lock_guard<std::mutex> l(_lock);
	if(!_full) {
		_text += line;
	}
}

void SessionRecorder::StateLoaded(uint32_t poll)
{
	std::lock_guard<std::mutex> l(_lock);
	if(!_full) {
		_text += std::to_string(poll) + " x\n";
	}
}

string SessionRecorder::Snapshot()
{
	std::lock_guard<std::mutex> l(_lock);
	return _text + std::to_string(_poll) + (_full ? " end (log full)\n" : " end\n");
}

bool SessionReplay::Parse(const string& text, string& error)
{
	std::istringstream in(text);
	string line;
	PollInput cur;
	bool ended = false;
	int n = 0;
	while(std::getline(in, line)) {
		n++;
		if(line.empty() || line[0] == '#') {
			continue;
		}
		if(!isdigit((unsigned char)line[0])) {
			// header: key value
			size_t sp = line.find(' ');
			Header.push_back({ line.substr(0, sp), sp == string::npos ? "" : line.substr(sp + 1) });
			continue;
		}
		std::istringstream l(line);
		Event e = {};
		string kind;
		l >> e.Poll >> kind;
		if(kind == "p") {
			for(uint32_t& m : cur.Masks) {
				l >> std::hex >> m;
			}
		} else if(kind == "s") {
			string seats;
			int god = 0;
			l >> seats >> god;
			if(seats.size() != 4) {
				error = "line " + std::to_string(n) + ": bad seats";
				return false;
			}
			memcpy(cur.Seats, seats.data(), 4);
			cur.God = god != 0;
		} else if(kind == "h") {
			l >> std::hex >> e.Hash;
		} else if(kind == "b") {
			string seats;
			int god = 0;
			l >> e.Seed >> seats >> god;
			if(seats.size() != 4) {
				error = "line " + std::to_string(n) + ": bad seats";
				return false;
			}
			memcpy(e.In.Seats, seats.data(), 4);
			e.In.God = god != 0;
		} else if(kind == "x") {
			// another computer's state from here on: the replay can't follow
			LoadedAt = e.Poll;
			End = e.Poll ? e.Poll - 1 : 0;
			ended = true;
			break;
		} else if(kind == "end") {
			End = e.Poll;
			ended = true;
			continue;
		} else {
			error = "line " + std::to_string(n) + ": unknown entry";
			return false;
		}
		if(l.fail()) {
			error = "line " + std::to_string(n) + ": unreadable";
			return false;
		}
		e.Kind = kind[0];
		if(e.Kind != 'b') {
			e.In = cur;
		}
		_events.push_back(e);
	}
	auto seed = std::find_if(Header.begin(), Header.end(), [](auto& h) { return h.first == "seed"; });
	if(seed == Header.end()) {
		error = "no seed line";
		return false;
	}
	// strtoul, not stoul: a bad number in a file is an error here, not an exception (none in the web build)
	const char* digits = seed->second.c_str();
	char* end = nullptr;
	unsigned long value = strtoul(digits, &end, 10);
	if(end == digits || *end) {
		error = "bad seed line";
		return false;
	}
	Seed = (uint32_t)value;
	if(!ended) {
		error = "no end line (cut off?)";
		return false;
	}
	return true;
}

void SessionReplay::Start(Emulator* emu)
{
	ConsoleMemoryInfo wram = emu->GetMemory(MemoryType::SnesWorkRam);
	_wram = (const uint8_t*)wram.Memory;
	_wramSize = wram.Size;
}

void SessionReplay::Poll(uint32_t poll, PollInput& in)
{
	for(; _next < _events.size() && _events[_next].Poll <= poll; _next++) {
		const Event& e = _events[_next];
		if(e.Kind == 'b') {
			continue;   // (BotsRestart, before the poll)
		}
		if(e.Kind == 'h') {
			if(e.Poll == poll) {
				HashesChecked++;
				if(WramHash(_wram, _wramSize) != e.Hash) {
					Mismatches++;
					LastMismatch = poll;
					if(FirstMismatch < 0) {
						FirstMismatch = poll;
					}
				}
			}
		} else {
			_cur = e.In;
		}
	}
	in = _cur;
}

bool SessionReplay::BotsRestart(uint32_t poll, uint32_t& seed, PollInput& seats)
{
	// the log has it before the poll's other lines, and Poll(poll - 1) stopped short of them
	for(size_t i = _next; i < _events.size() && _events[i].Poll == poll; i++) {
		if(_events[i].Kind == 'b') {
			seed = _events[i].Seed;
			seats = _events[i].In;
			return true;
		}
	}
	return false;
}
