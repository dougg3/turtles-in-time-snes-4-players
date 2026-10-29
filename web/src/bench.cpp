// Headless speed / determinism harness for the mesen-tmnt4p core, built natively (clang) and as
// WebAssembly (run with Node) by `scripts/build_web.sh bench`:
//   bench <rom> <state.mss> <frames> [hashes.txt | -] [script.lua [host]]
// Loads the ROM (multitap in port 2) and the save state, then runs exactly <frames> frames on this
// thread, timing each, every frame rendered. Prints frame-time statistics and a WRAM hash; with
// hashes.txt also writes "<frame> <WRAM hash> <picture hash>" per frame, to compare builds.
// With script.lua, that Lua script runs in the core too (e.g. the bots, to measure their cost):
// in Mesen's script engine (needs its debugger), or with `host` in the page's Lua host (bots.cpp).
//   bench <rom> --replay <session.log> <bots.lua> [--save <poll> <file.mss>]... [--wram <poll> <file>]...
//                                                 [--shot <poll> <file.ppm>]...
// Replays a session log saved in the browser (session.h; <rom> = the patched 4P ROM, bots.lua as
// served then) from power-on, checking the log's work RAM hashes; --save writes a save state
// at the start of that poll (frame), to look at in Mesen; --wram writes the work RAM there (raw
// 128 KB); --shot the picture of the frame before (256x224 PPM).
#include "pch.h"
#include "bots.h"
#include "session.h"
#include <chrono>
#include <cstdio>
#include <unistd.h>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define _exit(c) emscripten_force_exit(c)
#endif
#include "Shared/Emulator.h"
#include "Shared/EmuSettings.h"
#include "Shared/SaveStateManager.h"
#include "Shared/SettingTypes.h"
#include "Shared/Interfaces/IConsole.h"
#include "Shared/DebuggerRequest.h"
#include "Debugger/Debugger.h"
#include "Debugger/ScriptManager.h"
#include <fstream>
#include <sstream>
#include "Utilities/VirtualFile.h"
#include "Utilities/FolderUtilities.h"
#include "Utilities/miniz.h"

using Clock = std::chrono::steady_clock;

static uint64_t Fnv(const uint8_t* p, uint32_t size)
{
	uint64_t h = 1469598103934665603ULL;
	for(uint32_t i = 0; i < size; i++) {
		h = (h ^ p[i]) * 1099511628211ULL;
	}
	return h;
}

static string ReadFile(const string& path)
{
	std::ifstream f(path, std::ios::binary);
	std::stringstream s;
	s << f.rdbuf();
	return s.str();
}

// a gzip file's contents (the page saves session logs gzipped), or the input if it isn't one
static string Gunzip(const string& in)
{
	const uint8_t* p = (const uint8_t*)in.data();
	if(in.size() < 18 || p[0] != 0x1F || p[1] != 0x8B || p[2] != 8) {
		return in;
	}
	size_t pos = 10;
	uint8_t flags = p[3];
	if(flags & 4) {   // FEXTRA
		pos += 2 + (p[pos] | p[pos + 1] << 8);
	}
	for(int bit : { 8, 16 }) {   // FNAME, FCOMMENT: zero-terminated
		if(flags & bit) {
			while(pos < in.size() && p[pos]) {
				pos++;
			}
			pos++;
		}
	}
	if(flags & 2) {   // FHCRC
		pos += 2;
	}
	size_t outLen = 0;
	void* out = pos < in.size() ? tinfl_decompress_mem_to_heap(p + pos, in.size() - pos, &outLen, 0) : nullptr;
	if(!out) {
		return "";
	}
	string text((const char*)out, outLen);
	mz_free(out);
	return text;
}

static int Replay(int argc, char* argv[])
{
	string rom = argv[1];
	SessionReplay log;
	string error;
	if(!log.Parse(Gunzip(ReadFile(argv[3])), error)) {
		printf("session log: %s\n", error.c_str());
		return 1;
	}
	string script = ReadFile(argv[4]);
	vector<std::pair<uint32_t, string>> saves, dumps, shots;
	for(int i = 5; i < argc; i++) {
		if(string(argv[i]) == "--save" && i + 2 < argc) {
			saves.push_back({ (uint32_t)atoi(argv[i + 1]), argv[i + 2] });
			i += 2;
		} else if(string(argv[i]) == "--shot" && i + 2 < argc) {
			shots.push_back({ (uint32_t)atoi(argv[i + 1]), argv[i + 2] });
			i += 2;
		} else if(string(argv[i]) == "--wram" && i + 2 < argc) {
			dumps.push_back({ (uint32_t)atoi(argv[i + 1]), argv[i + 2] });
			i += 2;
		}
	}
	for(auto& [key, value] : log.Header) {
		printf("%s: %s\n", key.c_str(), value.c_str());
	}

	// the same setup as the page (web.cpp)
	FolderUtilities::SetHomeFolder(FolderUtilities::CombinePath(FolderUtilities::GetFolderName(rom), "home"));
	Emulator* emu = new Emulator();
	emu->Initialize(false);
	SnesConfig& snes = emu->GetSettings()->GetSnesConfig();
	snes.Port1.Type = ControllerType::SnesController;
	snes.Port2.Type = ControllerType::Multitap;
	for(int i = 0; i < 4; i++) {
		snes.Port2SubPorts[i].Type = ControllerType::SnesController;
	}
	snes.DisableFrameSkipping = true;
	snes.RamPowerOnState = RamState::AllZeros;
	emu->GetSettings()->SetSnesConfig(snes);
	EmulationConfig& cfg = emu->GetSettings()->GetEmulationConfig();
	cfg.EmulationSpeed = 0;
	emu->GetSettings()->SetEmulationConfig(cfg);

	auto lock = emu->AcquireLock();
	if(!emu->LoadRom(VirtualFile(rom), VirtualFile())) {
		printf("LoadRom failed\n");
		return 1;
	}
	static PageInput page;
	static LuaBots bots;
	static WebPads pads(&page, &bots, &log);
	PowerOnRam(emu, log.Seed);
	log.Start(emu);
	emu->RegisterInputProvider(&pads);
	if(!script.empty() && !bots.Load(emu, script, argv[4], log.Seed)) {
		printf("bots: %s\n", bots.Error.c_str());
		return 1;
	}
	IConsole* console = emu->GetConsoleUnsafe();
	auto t = Clock::now();
	while(pads.Polls() <= log.End) {
		for(auto& [poll, file] : saves) {
			if(poll == pads.Polls()) {
				printf("%s: %s\n", file.c_str(), emu->GetSaveStateManager()->SaveState(file, false) ? "saved" : "FAILED");
			}
		}
		for(auto& [poll, file] : shots) {
			if(poll == pads.Polls()) {
				// as the page shows it (web.cpp CopyFrame): rows 7-230, every other pixel in hi-res
				PpuFrameInfo f = console->GetPpuFrame();
				const uint16_t* src = (const uint16_t*)f.FrameBuffer;
				int scale = f.Width == 512 ? 2 : 1;
				std::ofstream out(file, std::ios::binary);
				out << "P6 256 224 255\n";
				for(int y = 0; y < 224; y++) {
					for(int x = 0; x < 256; x++) {
						uint16_t c = src[(y + 7) * scale * f.Width + x * scale];
						uint8_t rgb[3] = { (uint8_t)((c & 0x1F) << 3), (uint8_t)(((c >> 5) & 0x1F) << 3), (uint8_t)(((c >> 10) & 0x1F) << 3) };
						out.write((const char*)rgb, 3);
					}
				}
			}
		}
		for(auto& [poll, file] : dumps) {
			if(poll == pads.Polls()) {
				ConsoleMemoryInfo w = emu->GetMemory(MemoryType::SnesWorkRam);
				std::ofstream(file, std::ios::binary).write((const char*)w.Memory, w.Size);
			}
		}
		console->RunFrame();
	}
	double sec = std::chrono::duration<double>(Clock::now() - t).count();
	printf("replayed %u polls in %.1f s; %u hashes checked: %s\n", pads.Polls(), sec, log.HashesChecked,
		log.FirstMismatch < 0 ? "all match" : (std::to_string(log.Mismatches) + " differ, polls " + std::to_string(log.FirstMismatch) + " to " + std::to_string(log.LastMismatch)).c_str());
	if(!bots.Error.empty()) {
		printf("bots stopped: %s\n", bots.Error.c_str());
	}
	fflush(stdout);
	_exit(log.FirstMismatch < 0 ? 0 : 2);
}

int main(int argc, char* argv[])
{
	if(argc > 4 && string(argv[2]) == "--replay") {
		return Replay(argc, argv);
	}
	if(argc < 4) {
		printf("usage: bench <rom> <state.mss> <frames> [hashes.txt]\n");
		return 1;
	}
	string rom = argv[1], state = argv[2];
	int n = atoi(argv[3]);

	FolderUtilities::SetHomeFolder(FolderUtilities::CombinePath(FolderUtilities::GetFolderName(rom), "home"));
	Emulator* emu = new Emulator();
	emu->Initialize(false);

	SnesConfig& snes = emu->GetSettings()->GetSnesConfig();
	snes.Port1.Type = ControllerType::SnesController;
	snes.Port2.Type = ControllerType::Multitap;
	for(int i = 0; i < 4; i++) {
		snes.Port2SubPorts[i].Type = ControllerType::SnesController;
	}
	snes.RamPowerOnState = RamState::AllZeros;
	// render every frame: unthrottled, Mesen otherwise skips rendering by wall-clock time,
	// which makes pictures differ from run to run
	snes.DisableFrameSkipping = true;
	emu->GetSettings()->SetSnesConfig(snes);

	EmulationConfig& cfg = emu->GetSettings()->GetEmulationConfig();
	cfg.EmulationSpeed = 0;
	emu->GetSettings()->SetEmulationConfig(cfg);

	if(!emu->LoadRom(VirtualFile(rom), VirtualFile())) {
		printf("LoadRom failed\n");
		return 1;
	}
	// a script loads while the emulator thread runs: loading pauses that thread (DebugBreakHelper),
	// which waits forever if this thread already holds the emulator lock
	string script;
	int scriptId = -1;
	bool host = argc > 6 && string(argv[6]) == "host";
	if(argc > 5) {
		std::ifstream f(argv[5]);
		std::stringstream src;
		src << f.rdbuf();
		script = src.str();
	}
	if(argc > 5 && !host) {
		const char* lua = argv[5];
		DebuggerRequest dbg = emu->GetDebugger(true);
		if(!dbg.GetDebugger() || (scriptId = dbg.GetDebugger()->GetScriptManager()->LoadScript("bench", lua, script, -1)) < 0) {
			printf("LoadScript failed\n");
			return 1;
		}
	}
	// hold the emulator lock (its own thread waits at the frame boundary) and run the frames here;
	// taken before loading the state, or that thread runs a timing-dependent number of frames in
	// between (native and WASM then start one frame apart)
	auto lock = emu->AcquireLock();
	static PageInput page;
	static LuaBots bots;
	static WebPads pads(&page, &bots);
	if(host) {
		// four bots (in Mesen's engine the script decides that itself, from its HUMAN line)
		for(int i = 0; i < 4; i++) {
			page.Seats[i] = 'b';
		}
		emu->RegisterInputProvider(&pads);
		if(!bots.Load(emu, script, argv[5], 1)) {
			printf("bots: %s\n", bots.Error.c_str());
			return 1;
		}
	}
	if(!emu->GetSaveStateManager()->LoadState(state, false)) {
		printf("LoadState failed\n");
		return 1;
	}
	if(host) {
		bots.StateLoaded();
	}
	IConsole* console = emu->GetConsoleUnsafe();
	FILE* hashes = argc > 4 && string(argv[4]) != "-" ? fopen(argv[4], "w") : nullptr;
	vector<double> ms;
	for(int i = 0; i < n; i++) {
		auto t = Clock::now();
		console->RunFrame();
		ms.push_back(std::chrono::duration<double, std::milli>(Clock::now() - t).count());
		if(hashes) {
			PpuFrameInfo f = console->GetPpuFrame();
			ConsoleMemoryInfo w = emu->GetMemory(MemoryType::SnesWorkRam);
			fprintf(hashes, "%d %016llx %016llx\n", i, (unsigned long long)Fnv((uint8_t*)w.Memory, w.Size),
				(unsigned long long)Fnv(f.FrameBuffer, f.FrameBufferSize));
		}
	}
	if(hashes) {
		fclose(hashes);
	}

	if(scriptId >= 0) {
		// Mesen's engine sends print() and errors to the script log, not stdout
		printf("%s", emu->GetDebugger(false).GetDebugger()->GetScriptManager()->GetScriptLog(scriptId).c_str());
	}
	ConsoleMemoryInfo wram = emu->GetMemory(MemoryType::SnesWorkRam);
	double sum = 0;
	int over = 0;
	for(double v : ms) {
		sum += v;
		over += v > 1000.0 / 60.0988;
	}
	vector<double> s = ms;
	std::sort(s.begin(), s.end());
	printf("frames=%d avg_ms=%.2f p50=%.2f p99=%.2f max=%.2f fps=%.1f over16.6ms=%d wram=%016llx\n",
		n, sum / n, s[n / 2], s[n * 99 / 100], s[n - 1], 1000 * n / sum, over,
		(unsigned long long)Fnv((uint8_t*)wram.Memory, wram.Size));
	fflush(stdout);
	_exit(0);
}
