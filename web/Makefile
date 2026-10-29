# Browser build of the mesen-tmnt4p core. Normally run by scripts/build_web.sh,
# which sets SRC (our Mesen fork, mesen-tmnt4p), OBJ, OUT and BENCH. MESEN_TMNT4P_EMBED: the fork's
# hooks for a front end that runs frames itself.
#   make -f web/Makefile SRC=... OBJ=... OUT=... EMSDK=...            -> $(OUT)/mesen.js + .wasm
#   make -f web/Makefile ... BENCH=... bench-native bench-wasm         -> headless speed harness
WEB := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SRC ?= $(error SRC not set)
OBJ ?= $(error OBJ not set)
OUT ?= $(error OUT not set)
BENCH ?= $(OUT)
EMSDK ?= $(error EMSDK not set)

CORESRC := $(shell cd $(SRC) && find Core Utilities -name '*.cpp')
CSRC := $(shell cd $(SRC) && find SevenZip Lua Utilities -name '*.c')
INC := -I$(SRC) -I$(SRC)/Core -I$(SRC)/Utilities
WASM_OBJ := $(addprefix $(OBJ)/wasm/,$(CORESRC:.cpp=.o) $(CSRC:.c=.o))
NATIVE_OBJ := $(addprefix $(OBJ)/native/,$(CORESRC:.cpp=.o) $(CSRC:.c=.o))

# build paths become relative in the output (__FILE__ in asserts): reproducible, no local paths
PREFIXMAP := -ffile-prefix-map=$(SRC)=mesen-tmnt4p -ffile-prefix-map=$(WEB)=web/

ECXX := $(EMSDK)/upstream/emscripten/em++
ECC := $(EMSDK)/upstream/emscripten/emcc
EFLAGS := -O3 -w -pthread -DMESEN_TMNT4P_EMBED $(INC) $(PREFIXMAP)
NCXX := clang++
NCC := clang
NFLAGS := -O3 -w -m64 -pthread -DMESEN_TMNT4P_EMBED $(INC) $(PREFIXMAP)

# main() runs in a worker (PROXY_TO_PTHREAD); fixed memory so the page's views of it stay valid
WEBLINK := -pthread -sPROXY_TO_PTHREAD -sPTHREAD_POOL_SIZE=8 -sINITIAL_MEMORY=512MB \
	-sENVIRONMENT=web,worker -sEXIT_RUNTIME=0 -sSTACK_SIZE=2MB -sDEFAULT_PTHREAD_STACK_SIZE=2MB \
	-sEXPORTED_FUNCTIONS=_main,_malloc,_web_start,_web_input_ptr,_web_frame_ptr,_web_frame_seq,_web_audio_ptr,_web_audio_capacity,_web_audio_w_ptr,_web_audio_r_ptr,_web_audio_active,_web_fps,_web_frame_ms_avg,_web_frame_ms_max,_web_underruns_ptr,_web_bots,_web_seed,_web_seats,_web_bot_state,_web_bot_error,_web_log_snapshot,_web_log_size,_web_replay,_web_replay_info,_web_replay_error,_web_speed,_web_audio_target \
	-sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAP16,HEAP32,HEAPU32,UTF8ToString
BENCHLINK := -pthread -sPROXY_TO_PTHREAD -sPTHREAD_POOL_SIZE=8 -sALLOW_MEMORY_GROWTH -sINITIAL_MEMORY=256MB \
	-sNODERAWFS=1 -sEXIT_RUNTIME=1 -sSTACK_SIZE=2MB -sDEFAULT_PTHREAD_STACK_SIZE=2MB

web: $(OUT)/mesen.js
bench-native: $(BENCH)/bench-native
bench-wasm: $(BENCH)/bench-wasm.js
.PHONY: web bench-native bench-wasm

$(OUT)/mesen.js: $(WASM_OBJ) $(OBJ)/wasm/web.o $(OBJ)/wasm/bots.o $(OBJ)/wasm/session.o
	@mkdir -p $(OUT)
	$(ECXX) -O3 $(WEBLINK) -o $@ $^

$(BENCH)/bench-wasm.js: $(WASM_OBJ) $(OBJ)/wasm/bench.o $(OBJ)/wasm/bots.o $(OBJ)/wasm/session.o
	@mkdir -p $(BENCH)
	$(ECXX) -O3 $(BENCHLINK) -o $@ $^

$(BENCH)/bench-native: $(NATIVE_OBJ) $(OBJ)/native/bench.o $(OBJ)/native/bots.o $(OBJ)/native/session.o
	@mkdir -p $(BENCH)
	$(NCXX) -O3 -pthread -o $@ $^

$(OBJ)/wasm/web.o $(OBJ)/wasm/bench.o $(OBJ)/wasm/bots.o $(OBJ)/wasm/session.o $(OBJ)/native/bench.o $(OBJ)/native/bots.o $(OBJ)/native/session.o: $(WEB)src/bots.h $(WEB)src/session.h
$(OBJ)/wasm/%.o: $(WEB)src/%.cpp
	@mkdir -p $(dir $@)
	$(ECXX) $(EFLAGS) --std=c++17 -c $< -o $@
$(OBJ)/native/%.o: $(WEB)src/%.cpp
	@mkdir -p $(dir $@)
	$(NCXX) $(NFLAGS) --std=c++17 -c $< -o $@

$(OBJ)/wasm/%.o: $(SRC)/%.cpp
	@mkdir -p $(dir $@)
	$(ECXX) $(EFLAGS) --std=c++17 -c $< -o $@
$(OBJ)/wasm/%.o: $(SRC)/%.c
	@mkdir -p $(dir $@)
	$(ECC) $(EFLAGS) -c $< -o $@
$(OBJ)/native/%.o: $(SRC)/%.cpp
	@mkdir -p $(dir $@)
	$(NCXX) $(NFLAGS) --std=c++17 -c $< -o $@
$(OBJ)/native/%.o: $(SRC)/%.c
	@mkdir -p $(dir $@)
	$(NCC) $(NFLAGS) -c $< -o $@
