'use strict';
// The page's logic. Loaded before mesen.js, which reads the global Module.
// No innerHTML with outside data: controller names come from the device, so all text goes in
// with textContent (and the Content-Security-Policy forbids inline scripts anyway).
// accepted ROMs (SHA-1 of the clean dump) and the four-player patch for each
const ROMS = {
  '4f8fc0f45023e0339e501054b253c33f479a001a': { name: 'USA', patch: 'tmnt4-4p-patch.bps', fps: 60.0988 },
  '59add584f16b607607348e65c245ca6ad7a5fcb8': { name: 'Europe', patch: 'tmnt4-4p-eu-patch.bps', fps: 50.007 },
  'c4ba9b0fd1b40a228e6bb1170ec227dac5b83ce5': { name: 'Australia', patch: 'tmnt4-4p-au-patch.bps', fps: 50.007 },
  '514e7fb70e1e5e06c5a873262e145a555655d62d': { name: 'Japan', patch: 'tmnt4-4p-jp-patch.bps', fps: 60.0988 },
};
const BUILD = 'dev';   // scripts/build_web.sh puts the repository's commit here
const W = 256, H = 224;
// Mesen SNES controller bits: A B X Y L R Select Start Up Down Left Right
const BIT = { A: 0, B: 1, X: 2, Y: 3, L: 4, R: 5, Select: 6, Start: 7, Up: 8, Down: 9, Left: 10, Right: 11 };
// order used by "Map all", with what each button does in the game
const MAP_ORDER = [['Up', ''], ['Down', ''], ['Left', ''], ['Right', ''],
  ['Y', 'attack'], ['B', 'jump'], ['A', ''], ['X', ''], ['L', ''], ['R', ''], ['Select', 'pause'], ['Start', 'start / join']];
// a mapping: SNES button -> list of bindings (any of them presses it). Keyboard binding:
// KeyboardEvent.code. Gamepad binding: {b: button index}, {a: axis index, d: -1 | 1}, or
// {h: axis index, dir: 'up' | 'down' | 'left' | 'right'} for a hat (below).
const DEFAULT_KB = {
  Up: ['ArrowUp'], Down: ['ArrowDown'], Left: ['ArrowLeft'], Right: ['ArrowRight'],
  B: ['KeyZ'], A: ['KeyX'], Y: ['KeyA'], X: ['KeyS'], L: ['KeyQ'], R: ['KeyW'],
  Start: ['Enter'], Select: ['ShiftLeft', 'ShiftRight'],
};
// standard gamepad layout, Nintendo positions: bottom = B, right = A, left = Y, top = X
const DEFAULT_PAD = {
  B: [{ b: 0 }], A: [{ b: 1 }], Y: [{ b: 2 }], X: [{ b: 3 }], L: [{ b: 4 }, { b: 6 }], R: [{ b: 5 }, { b: 7 }],
  Select: [{ b: 8 }], Start: [{ b: 9 }],
  Up: [{ b: 12 }, { a: 1, d: -1 }], Down: [{ b: 13 }, { a: 1, d: 1 }], Left: [{ b: 14 }, { a: 0, d: -1 }], Right: [{ b: 15 }, { a: 0, d: 1 }],
};
// Pads without the "standard" layout (Chrome on Windows with DirectInput pads, e.g. the Nyko
// Airflo) can report the d-pad as a hat: one axis whose value is the direction, from -1 (up)
// clockwise in steps of 2/7 to 1 (up-left), and about 1.29 (anything above 1) when centered.
// Read as a plain axis it would be "held" when centered, and down/right would barely move it.
const HAT_DIRS = [['up'], ['up', 'right'], ['right'], ['down', 'right'], ['down'], ['down', 'left'], ['left'], ['up', 'left']];
const hatDirs = (v) => (v === undefined || Math.abs(v) > 1.05 ? [] : HAT_DIRS[Math.round((v + 1) * 3.5) & 7]);
const hatAxes = {};   // dev -> Set of axes seen centered (above 1): hats
function noteHats(dev, p) {
  const set = hatAxes[dev] || (hatAxes[dev] = new Set());
  p.axes.forEach((v, i) => { if (Math.abs(v) > 1.05) set.add(i); });
  return set;
}
const STD_NAMES = ['Bottom face', 'Right face', 'Left face', 'Top face', 'L bumper', 'R bumper', 'L trigger', 'R trigger',
  'Select/Back', 'Start', 'L stick press', 'R stick press', 'D-pad up', 'D-pad down', 'D-pad left', 'D-pad right', 'Home'];

const $ = (id) => document.getElementById(id);
// element with optional class and text
function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
const statusEl = $('status');
function status(text, kind) { statusEl.textContent = text; statusEl.className = 'status ' + (kind || ''); }
// a file for the player to save (session log, diagnostics): <prefix>-<local date-time><ext>
function download(prefix, data, ext = '.txt') {
  const now = new Date(), two = (n) => String(n).padStart(2, '0');
  saveFile(`${prefix}-${now.getFullYear()}-${two(now.getMonth() + 1)}-${two(now.getDate())}-${two(now.getHours())}${two(now.getMinutes())}${ext}`,
    data instanceof Blob ? data : new Blob([data], { type: 'text/plain' }));
}
function saveFile(name, blob) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 10000);
}

// ---------- diagnostics: recent messages and raw input, kept in memory (saveDiagnostics) ----------
const T0 = performance.now();
const messages = [], trace = [];   // "<seconds> <text>", newest last
function remember(list, max, text) {
  list.push(((performance.now() - T0) / 1000).toFixed(3).padStart(9) + ' ' + text);
  if (list.length > max) list.splice(0, list.length - max);
}
for (const level of ['warn', 'error']) {
  const orig = console[level].bind(console);
  console[level] = (...args) => { remember(messages, 300, level + ': ' + args.map(String).join(' ')); orig(...args); };
}
addEventListener('error', (e) => remember(messages, 300, `error: ${e.message} (${e.filename}:${e.lineno})`));
addEventListener('unhandledrejection', (e) => remember(messages, 300, 'unhandled: ' + e.reason));

// ---------- emulator module ----------
let ready = false, running = false;
var Module = {
  print: (t) => { console.log('[mesen]', t); remember(messages, 300, 'mesen: ' + t); },
  printErr: (t) => console.warn('[mesen]', t),
  onRuntimeInitialized: () => { ready = true; pushSeats(); startUp(); },
};
if (!crossOriginIsolated) status('This page needs cross-origin isolation (serve it with web/serve.py).', 'bad');

// ---------- ROM: verify, patch, start ----------
async function sha1(bytes) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-1', bytes));
  return [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
}
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  return t;
})();
function crc32(b) { let c = 0xFFFFFFFF; for (let i = 0; i < b.length; i++) c = CRC_TABLE[(c ^ b[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; }

function applyBps(source, patch) {
  let ip = 4;
  const u32 = (o) => (patch[o] | patch[o + 1] << 8 | patch[o + 2] << 16 | patch[o + 3] << 24) >>> 0;
  const num = () => { let data = 0, shift = 1; for (;;) { const x = patch[ip++]; data += (x & 0x7F) * shift; if (x & 0x80) return data; shift *= 128; data += shift; } };
  if (String.fromCharCode(...patch.subarray(0, 4)) !== 'BPS1') throw new Error('not a BPS patch');
  const srcSize = num(), dstSize = num(), metaSize = num();
  ip += metaSize;
  if (source.length !== srcSize) throw new Error('ROM size does not match the patch');
  if (crc32(source) !== u32(patch.length - 12)) throw new Error('ROM checksum does not match the patch');
  const out = new Uint8Array(dstSize);
  let op = 0, srcRel = 0, dstRel = 0;
  const end = patch.length - 12;
  while (ip < end) {
    const d = num(), cmd = d & 3, len = Math.floor(d / 4) + 1;
    if (cmd === 0) { for (let i = 0; i < len; i++, op++) out[op] = source[op]; }
    else if (cmd === 1) { for (let i = 0; i < len; i++) out[op++] = patch[ip++]; }
    else {
      const o = num(), delta = (o & 1 ? -1 : 1) * Math.floor(o / 2);
      if (cmd === 2) { srcRel += delta; for (let i = 0; i < len; i++) out[op++] = source[srcRel++]; }
      else { dstRel += delta; for (let i = 0; i < len; i++) out[op++] = out[dstRel++]; }
    }
  }
  if (crc32(out) !== u32(patch.length - 8)) throw new Error('patched ROM checksum is wrong');
  return out;
}

// the patched ROM, for the desktop emulator (mesen-tmnt4p): tmnt4-4p.sfc, tmnt4-4p-eu.sfc, ...
const romName = (known) => known.patch.replace(/-patch\.bps$/, '.sfc');
async function patchRom(bytes, known) {
  return applyBps(bytes, new Uint8Array(await (await fetch(known.patch)).arrayBuffer()));
}
let running4p = null;   // {known, rom} of the game running, for Download ROM
async function downloadRom(bytes, known) {
  try { saveFile(romName(known), new Blob([await patchRom(bytes, known)], { type: 'application/octet-stream' })); }
  catch (e) { status('Patch failed: ' + e.message, 'bad'); }
}

async function useRom(bytes, remember) {
  if (!ready) { status('Emulator still loading, try again in a moment.', 'bad'); return; }
  if (bytes.length % 1024 === 512) bytes = bytes.subarray(512);   // copier header
  const hash = await sha1(bytes);
  const known = ROMS[hash];
  if (!known) {
    status(`That's not a Turtles in Time ROM this page knows (SHA-1 ${hash.slice(0, 12)}…; USA, Europe, Australia and Japan work).`, 'bad');
    return;
  }
  if (remember) { await saveRom(hash, bytes); showSaved(); }
  // a session log plays back only on the version it was recorded with
  if (replay && hash !== replayRom()) {
    const want = ROMS[replayRom()];
    status(want ? `This session log was recorded with the ${want.name} version. Choose that ROM to play it back.`
      : "This session log was recorded with a version of the game this page doesn't know.", 'bad');
    return;
  }
  status(`ROM verified (${known.name}). Applying the four-player patch…`, 'ok');
  let rom;
  try { rom = await patchRom(bytes, known); } catch (e) { status('Patch failed: ' + e.message, 'bad'); return; }
  running4p = { known, rom };
  try { localStorage.setItem('tmnt4p.lastRom', hash); } catch (e) {}
  session.rom = hash;
  session.fps = known.fps;
  session.rom4p = await sha1(rom);
  await loadBots();
  await startAudio();
  if (replay) startReplay();
  // the session's seed: power-on RAM and the bots' random numbers (in the session log; a
  // playback uses the log's)
  else Module._web_seed(crypto.getRandomValues(new Uint32Array(1))[0]);
  // sound queued ahead of the picture: ?audio=N samples instead of 3072 (64 ms); lower
  // means less delay, higher fewer dropouts on a slow computer (?stats shows them)
  const aq = parseInt(new URLSearchParams(location.search).get('audio'), 10);
  if (aq >= 256 && aq <= 4096) Module._web_audio_target(aq);
  const ptr = Module._malloc(rom.length);
  Module.HEAPU8.set(rom, ptr);
  Module._web_start(ptr, rom.length);
  session.started = new Date().toISOString();
  running = true;
  $('savelog').hidden = !!replay;
  $('playlog2').hidden = false;
  $('getrom').hidden = false;
  $('overlay').classList.add('hidden');
}

// remember the (unpatched) ROMs in this browser, one per version (keyed by SHA-1), so each
// only has to be chosen once
function db() {
  return new Promise((res, rej) => {
    const r = indexedDB.open('tmnt4p', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('files');
    r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
  });
}
const req = (r) => new Promise((res) => { r.onsuccess = () => res(r.result); r.onerror = () => res(null); });
async function saveRom(hash, bytes) {
  try { const d = await db(); await req(d.transaction('files', 'readwrite').objectStore('files').put(bytes.slice(), 'rom:' + hash)); } catch (e) {}
}
// {hash: bytes} of the saved ROMs this page knows
async function loadRoms() {
  const roms = {};
  try {
    const d = await db();
    // older pages saved one ROM, as 'rom': file it under its SHA-1
    const old = await req(d.transaction('files').objectStore('files').get('rom'));
    if (old) {
      const hash = await sha1(new Uint8Array(old));
      if (ROMS[hash]) await saveRom(hash, new Uint8Array(old));
      await req(d.transaction('files', 'readwrite').objectStore('files').delete('rom'));
    }
    const store = d.transaction('files').objectStore('files');
    const [keys, vals] = await Promise.all([req(store.getAllKeys()), req(store.getAll())]);
    (keys || []).forEach((k, i) => { if (k.startsWith('rom:') && ROMS[k.slice(4)]) roms[k.slice(4)] = vals[i]; });
  } catch (e) {}
  return roms;
}
async function forgetRom(hash) {
  try { const d = await db(); await req(d.transaction('files', 'readwrite').objectStore('files').delete('rom:' + hash)); } catch (e) {}
}
// the version a session log was recorded with (logs from before rom-sha1 are all USA)
const replayRom = () => replay.head['rom-sha1'] || Object.keys(ROMS)[0];
// the start screen: a Start button per saved version (the last one played first), each with
// Forget, and Add another version; with none saved, the drop box
let savedRoms = {};
async function showSaved() {
  savedRoms = await loadRoms();
  let last = null;
  try { last = localStorage.getItem('tmnt4p.lastRom'); } catch (e) {}
  const order = Object.keys(ROMS).filter((h) => savedRoms[h]);
  if (order.includes(last)) order.splice(order.indexOf(last), 1), order.unshift(last);
  const list = $('saved');
  list.replaceChildren();
  order.forEach((hash, i) => {
    const row = document.createElement('div');
    row.className = 'savedrom';
    const go = document.createElement('button');
    go.className = i === 0 ? 'primary' : '';
    go.textContent = `Start (${ROMS[hash].name})`;
    go.onclick = () => useRom(new Uint8Array(savedRoms[hash]), false);
    const forget = document.createElement('button');
    forget.className = 'small';
    forget.textContent = 'Forget';
    forget.title = `Deletes the ${ROMS[hash].name} ROM saved in this browser; you can choose it again`;
    forget.onclick = async () => {
      await forgetRom(hash);
      await showSaved();
      status(`Saved ${ROMS[hash].name} ROM deleted.`);
    };
    const get = document.createElement('button');
    get.className = 'small';
    get.textContent = 'Download 4P ROM';
    get.title = `Saves the patched ${ROMS[hash].name} ROM (${romName(ROMS[hash])}), to play in the desktop emulator mesen-tmnt4p (other emulators lack the extra sprites that 3 or 4 players need)`;
    get.onclick = () => downloadRom(new Uint8Array(savedRoms[hash]), ROMS[hash]);
    row.append(go, get, forget);
    list.append(row);
  });
  $('drop').hidden = order.length > 0;
  list.hidden = $('addrom').hidden = !order.length;
  return order;
}
$('addrom').onclick = () => $('file').click();
async function startUp() {
  const order = await showSaved();
  if (!replay) { status(order.length ? '' : 'Choose your ROM to start.'); return; }
  const want = replayRom();
  if (savedRoms[want]) useRom(new Uint8Array(savedRoms[want]), false);
  else if (ROMS[want]) status(`Choose your ${ROMS[want].name} ROM to play back the session log.`, 'ok');
  else status("This session log was recorded with a version of the game this page doesn't know.", 'bad');
}

$('file').onchange = async (e) => { const f = e.target.files[0]; if (f) useRom(new Uint8Array(await f.arrayBuffer()), true); };
const drop = $('drop');
$('overlay').ondragover = (e) => { e.preventDefault(); drop.classList.add('over'); };
$('overlay').ondragleave = () => drop.classList.remove('over');
$('overlay').ondrop = async (e) => {
  e.preventDefault(); drop.classList.remove('over');
  const f = e.dataTransfer.files[0]; if (f) useRom(new Uint8Array(await f.arrayBuffer()), true);
};

// ---------- bots ----------
// scripts/lua/play_with_bots.lua (published as bots.lua) runs in the core's Lua host (web/src/bots.cpp).
// Each player is a person (the device set to that player), a bot, or nobody (not P1). A player
// without a device is a bot unless set to Empty; seatChoice remembers Bot/Empty chosen by hand.
async function loadBots() {
  try {
    const res = await fetch('bots.lua');
    if (!res.ok) throw new Error('bots.lua: HTTP ' + res.status);
    const src = new TextEncoder().encode(await res.text());
    session.bots = await sha1(src);
    const ptr = Module._malloc(src.length);
    Module.HEAPU8.set(src, ptr);
    Module._web_bots(ptr, src.length);
  } catch (e) { console.warn('no bots', e); $('botnote').textContent = 'Bots unavailable (bots.lua could not be loaded).'; }
}
let seatChoice = [null, null, null, null];   // 'b' / '-' chosen by hand, null = automatic
let botGod = false;
try {
  const saved = JSON.parse(localStorage.getItem('tmnt4p.seats'));
  if (saved && Array.isArray(saved.choice) && saved.choice.length === 4) {
    seatChoice = saved.choice.map((c, p) => (c === 'b' || (c === '-' && p >= 1) ? c : null));
    botGod = !!saved.god;
  }
} catch (e) {}
const role = (p) => (deviceOn(p) ? 'h' : seatChoice[p] === '-' ? '-' : 'b');
function pushSeats() {
  if (!ready) return;
  let packed = 0;
  for (let p = 0; p < 4; p++) packed |= role(p).charCodeAt(0) << (p * 8);
  Module._web_seats(packed >>> 0, botGod ? 1 : 0);
  try { localStorage.setItem('tmnt4p.seats', JSON.stringify({ choice: seatChoice, god: botGod })); } catch (e) {}
}

// ---------- session log ----------
// The core records every poll's input (web/src/session.h): with this header it replays the
// session exactly (scripts: build/web-bench/bench-native <4P ROM> --replay <log> bots.lua).
// Only button presses and the player setup are in it; it is saved on the player's computer.
const session = { started: null, rom: '', fps: 60.0988, rom4p: '', bots: 'none' };
// gzipped (about a third of the size; the RAM hashes don't compress) where the browser can
// (CompressionStream: Chrome 80, Firefox 113, Safari 16.4); the replay reads both
async function saveLog() {
  const ptr = Module._web_log_snapshot(), n = Module._web_log_size();
  const body = new TextDecoder().decode(Module.HEAPU8.slice(ptr, ptr + n));
  const head = ['tmnt4p-session 1', 'build ' + BUILD, 'started ' + session.started, 'saved ' + new Date().toISOString(),
    'rom-sha1 ' + session.rom, 'rom4p-sha1 ' + session.rom4p, 'bots-sha1 ' + session.bots];
  const text = head.join('\n') + '\n' + body;
  if (typeof CompressionStream === 'undefined') { download('tmnt4p-session', text); return; }
  const gz = await new Response(new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'))).blob();
  download('tmnt4p-session', gz, '.txt.gz');
}
$('savelog').onclick = saveLog;
$('getrom').onclick = () => { if (running4p) saveFile(romName(running4p.known), new Blob([running4p.rom], { type: 'application/octet-stream' })); };

// ---------- playback of a session log ----------
// The core starts once per page load, so a log chosen here is kept in sessionStorage and the
// page reloads into playback (with the ROM saved in this browser, at once; otherwise after the
// ROM is chosen). The core replays the log's input from its seed (web.cpp); the page shows the
// progress and whether the RAM hashes in the log still match (in sync).
let replay = null;   // {text, head: {key: value}} while playing back
try {
  const text = sessionStorage.getItem('tmnt4p.replay');
  sessionStorage.removeItem('tmnt4p.replay');   // a reload after this plays normally
  if (text) replay = { text, head: logHeader(text), seats: logSeats(text), now: null };
} catch (e) {}
// the log's seat changes: [{poll, seats ("hb-b"), god}]
function logSeats(text) {
  const list = [];
  for (const m of text.matchAll(/^(\d+) s (\S{4}) (\d)$/gm)) list.push({ poll: +m[1], seats: m[2], god: m[3] === '1' });
  return list;
}
function logHeader(text) {
  const head = {};
  for (const line of text.split('\n')) {
    if (/^\d/.test(line)) break;
    const sp = line.indexOf(' ');
    if (sp > 0) head[line.slice(0, sp)] = line.slice(sp + 1);
  }
  return head;
}
async function chooseLog(file) {
  let text;
  try {
    let bytes = new Uint8Array(await file.arrayBuffer());
    if (bytes[0] === 0x1F && bytes[1] === 0x8B) {
      if (typeof DecompressionStream === 'undefined') throw new Error('this browser cannot unpack .gz files');
      bytes = new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
    }
    text = new TextDecoder().decode(bytes);
    if (!text.startsWith('tmnt4p-session') || !/\n\d+ end/.test(text)) throw new Error("that's not a session log");
  } catch (e) { status('Session log: ' + e.message, 'bad'); return; }
  try { sessionStorage.setItem('tmnt4p.replay', text); } catch (e) { status('Session log too big to play back here.', 'bad'); return; }
  location.reload();
}
$('logfile').onchange = (e) => { const f = e.target.files[0]; if (f) chooseLog(f); };
$('playlog').onclick = () => $('logfile').click();
// during play: a second click within 3 s, since it ends the game
let playlogArmed = 0;
$('playlog2').onclick = () => {
  if (Date.now() - playlogArmed < 3000) { $('logfile').click(); return; }
  playlogArmed = Date.now();
  $('playlog2').textContent = 'Ends this game: click again';
  setTimeout(() => { $('playlog2').textContent = 'Play back a log'; }, 3000);
};
function startReplay() {
  const src = new TextEncoder().encode(replay.text);
  const ptr = Module._malloc(src.length);
  Module.HEAPU8.set(src, ptr);
  Module._web_replay(ptr, src.length);
  const warn = [];
  if (replay.head.build !== BUILD) warn.push(`recorded with build ${replay.head.build}, this is ${BUILD}`);
  if (replay.head['bots-sha1'] !== session.bots) warn.push('different bot script');
  if (replay.head['rom-sha1'] && replay.head['rom-sha1'] !== session.rom) warn.push('recorded with another version of the game');
  if (replay.head['rom4p-sha1'] !== session.rom4p) warn.push('different four-player patch');
  $('playwarn').textContent = warn.length ? 'May not replay exactly: ' + warn.join(', ') + '.' : '';
  $('playwarn').hidden = !warn.length;
  $('playbar').hidden = false;
  $('playwhen').textContent = replay.head.started ? 'Recorded ' + new Date(replay.head.started).toLocaleString() : '';
  // the players come from the log (renderPlayers shows them)
  document.querySelector('.panel').classList.add('locked');
  $('botgod').disabled = true;
  $('playnote').hidden = false;
  renderPlayers();
}
let replaySpeed = 1;
function setSpeed(s) {
  replaySpeed = s;
  Module._web_speed(s);
  $('playpause').textContent = s === 0 ? 'Play' : 'Pause';
  $('playfast').classList.toggle('active', s === 4);
}
$('playpause').onclick = () => setSpeed(replaySpeed === 0 ? 1 : 0);
$('playfast').onclick = () => setSpeed(replaySpeed === 4 ? 1 : 4);
$('playstop').onclick = () => location.reload();
const clock = (polls) => { const s = Math.floor(polls / session.fps); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
let lastPlay = '';
function updateReplay() {
  if (!replay || !running) return;
  const info = Module.HEAPU32.subarray(Module._web_replay_info() >> 2, (Module._web_replay_info() >> 2) + 6);
  const [state, poll, end, checked, bad, first] = info;
  let sync;
  if (state === 3) sync = 'Unreadable log: ' + Module.UTF8ToString(Module._web_replay_error());
  else if (bad) sync = `Out of sync from ${clock(first - 1)} (frame ${first - 1}): from there on it differs from what was played`;
  else sync = checked ? `In sync (${checked} checks)` : '';
  const text = `${state === 2 ? 'End of the log' : replaySpeed === 0 ? 'Paused' : 'Playing'} ${clock(poll)} / ${clock(end)}|${sync}`;
  if (text === lastPlay) return;
  lastPlay = text;
  $('playpos').textContent = text.split('|')[0];
  $('playsync').textContent = sync;
  $('playsync').className = bad || state === 3 ? 'bad' : 'ok';
  $('playprog').max = end || 1;
  $('playprog').value = poll;
  if (state === 2) { $('playpause').disabled = true; $('playfast').disabled = true; }
  // the recorded players at this point
  const now = replay.seats.filter((s) => s.poll <= poll).pop() || replay.seats[0];
  if (now && now !== replay.now) { replay.now = now; renderPlayers(); }
}

// ---------- audio ----------
// Mute turns a gain node down: the sound keeps flowing, since the sound card paces the
// emulation (web.cpp). Remembered in localStorage.
let audioCtx, gain;
let muted = false;
try { muted = localStorage.getItem('tmnt4p.muted') === '1'; } catch (e) {}
function setMuted(m) {
  muted = m;
  if (gain) gain.gain.value = muted ? 0 : 1;
  $('mute').textContent = muted ? 'Unmute' : 'Mute';
  $('mute').classList.toggle('active', muted);
  try { localStorage.setItem('tmnt4p.muted', muted ? '1' : '0'); } catch (e) {}
}
$('mute').onclick = () => setMuted(!muted);
setMuted(muted);
async function startAudio() {
  try {
    audioCtx = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' });
    await audioCtx.audioWorklet.addModule('audio.js');
    const node = new AudioWorkletNode(audioCtx, 'snes-audio', { outputChannelCount: [2] });
    node.port.postMessage({
      buffer: Module.HEAPU8.buffer, audioPtr: Module._web_audio_ptr(), capacity: Module._web_audio_capacity(),
      wPtr: Module._web_audio_w_ptr(), rPtr: Module._web_audio_r_ptr(), underrunsPtr: Module._web_underruns_ptr(),
    });
    gain = new GainNode(audioCtx, { gain: muted ? 0 : 1 });
    node.connect(gain).connect(audioCtx.destination);
    audioCtx.resume();   // pending until a click/key if the browser wants a gesture: don't wait
    Module._web_audio_active(audioCtx.state === 'running' ? 1 : 0);
    audioCtx.onstatechange = () => Module._web_audio_active(audioCtx.state === 'running' ? 1 : 0);
  } catch (e) { console.warn('no audio', e); }
}
for (const ev of ['pointerdown', 'keydown']) {
  document.addEventListener(ev, () => { if (audioCtx && audioCtx.state !== 'running') audioCtx.resume(); });
}

// ---------- input ----------
// mappings, saved per device kind: 'kb', or the gamepad's id (so a pad model keeps its mapping)
const padOf = (dev) => navigator.getGamepads()[+dev.slice(3)];
function mapKey(dev) { return dev === 'kb' ? 'kb' : 'pad:' + (padOf(dev) || {}).id; }
function getMap(dev) {
  try { const m = JSON.parse(localStorage.getItem('tmnt4p.map.' + mapKey(dev))); if (m) return m; } catch (e) {}
  if (dev === 'kb') return structuredClone(DEFAULT_KB);
  const map = structuredClone(DEFAULT_PAD);
  // a pad with a hat: its d-pad is the hat, in place of the standard layout's d-pad buttons
  // (12-15), which may be other buttons on such a pad
  const p = padOf(dev);
  if (p && p.mapping !== 'standard') {
    for (const h of noteHats(dev, p)) {
      for (const dir of ['up', 'down', 'left', 'right']) {
        const btn = dir[0].toUpperCase() + dir.slice(1);
        map[btn] = [{ h, dir }, ...map[btn].filter((b) => !('b' in b) || b.b < 12)];
      }
    }
  }
  return map;
}
function setMap(dev, map) {
  try {
    if (map) localStorage.setItem('tmnt4p.map.' + mapKey(dev), JSON.stringify(map));
    else localStorage.removeItem('tmnt4p.map.' + mapKey(dev));
  } catch (e) {}
  kbMap = getMap('kb');
  delete padMaps[dev];
}
let kbMap = getMap('kb');

function keyLabel(code) {
  return code.replace(/^Key/, '').replace(/^Digit/, '').replace('Arrow', '').replace(/(Left|Right)$/, (s) => (code.startsWith('Arrow') ? s : ' ' + s[0]));
}
function bindingLabel(dev, b) {
  if (dev === 'kb') return keyLabel(b);
  if ('h' in b) return 'Hat ' + b.dir;
  if ('b' in b) return ((padOf(dev) || {}).mapping === 'standard' && STD_NAMES[b.b]) || 'Button ' + b.b;
  return (b.a === 0 ? 'Stick left/right' : b.a === 1 ? 'Stick up/down' : 'Axis ' + b.a) + (b.d < 0 ? ' −' : ' +');
}

const keysDown = new Set();
// a tap shorter than a poll still counts: every press is held for at least two polls
const keysLatched = new Map();
const boundKeys = () => new Set(Object.values(kbMap).flat());
addEventListener('keydown', (e) => {
  if (capture) return;   // handled by the mapping dialog
  if (mapperDev) keysDown.add(e.code);   // shown in the dialog (the game gets nothing meanwhile)
  else if (running && boundKeys().has(e.code)) {
    if (!e.repeat) remember(trace, 4000, 'key ' + e.code + ' down');   // game keys only: no typing in the trace
    keysDown.add(e.code); keysLatched.set(e.code, 2); e.preventDefault();
  }
});
addEventListener('keyup', (e) => { if (keysDown.has(e.code) && !e.repeat) remember(trace, 4000, 'key ' + e.code + ' up'); keysDown.delete(e.code); });
addEventListener('blur', () => keysDown.clear());

// device -> player (0-3, or -1 = not playing); the keyboard is device 'kb'. A player has at most
// one device.
const assign = { kb: 0 };
function padName(p) { return p.id.replace(/\s*\(.*?\)\s*/g, ' ').trim() || 'Gamepad'; }
const deviceOn = (p) => Object.keys(assign).find((k) => assign[k] === p && deviceNames()[k]);
// a player a new device can take: no device, and not set to Bot or Empty by hand
function nextFreePlayer() { for (let i = 0; i < 4; i++) if (!deviceOn(i) && !seatChoice[i]) return i; return -1; }
if (seatChoice[0]) assign.kb = nextFreePlayer();   // P1 saved as a bot or empty
addEventListener('gamepadconnected', (e) => {
  const key = 'pad' + e.gamepad.index;
  remember(trace, 4000, `${key} connected: "${e.gamepad.id}" mapping "${e.gamepad.mapping}", ${e.gamepad.buttons.length} buttons, ${e.gamepad.axes.length} axes`);
  if (!(key in assign)) {
    // the first pad takes P1 from the keyboard; the keyboard moves to the next free player
    if (assign.kb === 0 && !Object.keys(assign).some((k) => k.startsWith('pad'))) { assign[key] = 0; assign.kb = nextFreePlayer(); }
    else assign[key] = nextFreePlayer();
  }
  renderPlayers();
});
addEventListener('gamepaddisconnected', (e) => {
  remember(trace, 4000, `pad${e.gamepad.index} disconnected`);
  delete assign['pad' + e.gamepad.index]; renderPlayers();
});

function deviceNames() {
  const names = { kb: 'Keyboard' };
  for (const p of navigator.getGamepads()) if (p) names['pad' + p.index] = padName(p);
  return names;
}
// where a device's buttons go: its player; a device that isn't playing works P1 while P1 is a
// bot (the bots leave the title screen and menus to people)
const target = (dev) => (assign[dev] >= 0 ? assign[dev] : role(0) === 'b' ? 0 : -1);

// one row per player: who plays it (a device, Bot or Empty), and the device's buttons. During a
// playback: the recorded players, as text.
function renderPlayers() {
  const names = deviceNames();
  $('players').replaceChildren();
  if (replay && replay.now) {
    const word = { h: 'Person', b: 'Bot', '-': 'Empty' };
    for (let i = 0; i < 4; i++) {
      const row = el('div', 'player');
      row.append(el('div', 'tag p' + (i + 1), 'P' + (i + 1)), el('div', 'recorded', word[replay.now.seats[i]] || '?'));
      $('players').appendChild(row);
    }
    $('spare').replaceChildren();
    $('botgod').checked = replay.now.god;
    $('p2note').hidden = true;
    return;
  }
  for (let i = 0; i < 4; i++) {
    const dev = deviceOn(i);
    const sel = el('select');
    sel.title = 'Who plays P' + (i + 1);
    for (const [key, name] of Object.entries(names)) {
      const on = assign[key];
      const o = el('option', '', name + (on >= 0 && on !== i ? ` (now P${on + 1})` : '')); o.value = 'dev:' + key; sel.appendChild(o);
    }
    sel.appendChild(Object.assign(el('option', '', 'Bot'), { value: 'b' }));
    // P1 always plays. P2 can stay out of a "1 PLAYER" game (with a multitap, P2-P4 join
    // in the stage with START); "2 PLAYERS" always brings P2 in.
    if (i >= 1) sel.appendChild(Object.assign(el('option', '', 'Empty'), { value: '-' }));
    sel.value = dev ? 'dev:' + dev : role(i);
    sel.onchange = () => {
      for (const k of Object.keys(assign)) if (assign[k] === i) assign[k] = -1;
      if (sel.value.startsWith('dev:')) { assign[sel.value.slice(4)] = i; seatChoice[i] = null; }
      else seatChoice[i] = sel.value;
      renderPlayers();
    };
    const row = el('div', 'player');
    row.append(el('div', 'tag p' + (i + 1), 'P' + (i + 1)), sel);
    if (dev) { const mapBtn = el('button', 'small', 'Buttons'); mapBtn.onclick = () => openMapper(dev, names[dev]); row.appendChild(mapBtn); }
    $('players').appendChild(row);
  }
  // devices that aren't playing: still mappable, and they work P1 while P1 is a bot
  $('spare').replaceChildren();
  for (const [key, name] of Object.entries(names)) {
    if (assign[key] >= 0) continue;
    const row = el('div', 'dev');
    const label = el('span', '', name + (role(0) === 'b' ? ' · menus as P1' : ' · not playing')); label.title = name;
    const mapBtn = el('button', 'small', 'Buttons'); mapBtn.onclick = () => openMapper(key, name);
    row.append(label, mapBtn); $('spare').appendChild(row);
  }
  $('padhint').hidden = navigator.getGamepads().some(Boolean);
  $('p2note').hidden = role(1) !== '-';
  pushSeats();
}

const padActive = (dev, p, b) => {
  if ('h' in b) return hatDirs(p.axes[b.h]).includes(b.dir);
  if ('b' in b) return !!(p.buttons[b.b] && p.buttons[b.b].pressed);
  return !noteHats(dev, p).has(b.a) && (p.axes[b.a] || 0) * b.d > 0.5;
};
const padMaps = {};   // cached per pad index, refreshed when a mapping changes
// SNES buttons a device presses now (bitmask)
function deviceMask(dev) {
  let m = 0;
  if (dev === 'kb') {
    const held = new Set([...keysDown, ...keysLatched.keys()]);
    for (const [btn, codes] of Object.entries(kbMap)) if (codes.some((c) => held.has(c))) m |= 1 << BIT[btn];
  } else {
    const p = padOf(dev);
    if (!p) return 0;
    const map = padMaps[dev] || (padMaps[dev] = getMap(dev));
    for (const [btn, binds] of Object.entries(map)) if (binds.some((b) => padActive(dev, p, b))) m |= 1 << BIT[btn];
  }
  return m;
}
function readInput() {
  const masks = [0, 0, 0, 0];
  // nothing reaches the game while the mapping dialog is open
  if (!mapperDev) {
    for (const dev of Object.keys(deviceNames())) { const pl = target(dev); if (pl >= 0) masks[pl] |= deviceMask(dev); }
  }
  for (const [code, n] of keysLatched) { if (n > 1) keysLatched.set(code, n - 1); else keysLatched.delete(code); }
  return masks;
}

// ---------- button mapping dialog ----------
// One card per SNES button with its bindings (x removes one, + adds one); the cards of the
// buttons pressed now light up, and a line lists the raw inputs (useful with odd pads).
let capture = null;   // {dev, btn, add, baseline, queue} while waiting for a press
let mapperDev = null;
const cards = {};
function openMapper(dev, name) {
  mapperDev = dev;
  keysDown.clear();
  $('mapTitle').textContent = name;
  $('mapper').hidden = false;
  renderMapper();
}
function closeMapper() { capture = null; mapperDev = null; keysDown.clear(); $('mapper').hidden = true; }
function renderMapper() {
  const map = getMap(mapperDev);
  $('mapGrid').replaceChildren();
  for (const [btn, what] of MAP_ORDER) {
    const waiting = capture && capture.btn === btn;
    const card = el('div', 'mapcard' + (waiting ? ' waiting' : ''));
    const head = el('div', 'maphead');
    head.appendChild(el('b', '', btn));
    if (what) head.appendChild(el('small', '', what));
    const chips = el('div', 'chips');
    for (const b of map[btn] || []) {
      const chip = el('button', 'chip', bindingLabel(mapperDev, b) + ' ×');
      chip.title = 'Remove';
      chip.onclick = () => { const m = getMap(mapperDev); m[btn] = m[btn].filter((x) => JSON.stringify(x) !== JSON.stringify(b)); setMap(mapperDev, m); renderMapper(); };
      chips.appendChild(chip);
    }
    if (waiting) chips.appendChild(el('span', 'chip wait', 'press…'));
    else {
      const add = el('button', 'chip add', '+');
      add.title = 'Add a ' + (mapperDev === 'kb' ? 'key' : 'button') + ' for ' + btn;
      add.onclick = () => startCapture([btn], true);
      chips.appendChild(add);
    }
    card.append(head, chips);
    cards[btn] = card;
    $('mapGrid').appendChild(card);
  }
  const what = capture && MAP_ORDER.find((m) => m[0] === capture.btn)[1];
  $('mapPrompt').textContent = capture
    ? `Press the ${mapperDev === 'kb' ? 'key' : 'button'} for ${capture.btn}${what ? ' (' + what + ')' : ''} · Esc or Skip keeps the current one`
    : 'Press buttons to see what they do here (the game gets nothing while this is open). + adds a key or button, × removes one; Map all asks for each button in turn.';
  $('mapSkip').hidden = !capture;
}
// live part of the dialog, every frame: the cards pressed now and the raw inputs
let lastRaw = null;
function updateMapper() {
  if (!mapperDev) return;
  const m = deviceMask(mapperDev);
  for (const [btn] of MAP_ORDER) cards[btn] && cards[btn].classList.toggle('on', !!(m >> BIT[btn] & 1));
  let raw = [];
  if (mapperDev === 'kb') raw = [...keysDown].map(keyLabel);
  else {
    const p = padOf(mapperDev);
    if (p) {
      const hats = noteHats(mapperDev, p);
      p.buttons.forEach((b, i) => { if (b.pressed) raw.push(bindingLabel(mapperDev, { b: i })); });
      p.axes.forEach((v, i) => {
        if (hats.has(i)) { const d = hatDirs(v); if (d.length) raw.push(`Hat ${d.join('-')} (axis ${i})`); }
        else if (Math.abs(v) > 0.5) raw.push(bindingLabel(mapperDev, { a: i, d: Math.sign(v) }));
      });
    }
  }
  const text = 'Pressed now: ' + (raw.join(', ') || 'nothing');
  if (text !== lastRaw) { $('mapRaw').textContent = text; lastRaw = text; }
}
function padSnapshot(dev) {
  const p = padOf(dev);
  return p ? { buttons: p.buttons.map((b) => b.pressed), axes: [...p.axes], hats: p.axes.map((v) => hatDirs(v).join()) } : null;
}
function startCapture(queue, add) {
  if (!queue.length) { capture = null; renderMapper(); return; }
  capture = { dev: mapperDev, btn: queue[0], add: !!add, queue: queue.slice(1), baseline: mapperDev === 'kb' ? null : padSnapshot(mapperDev) };
  renderMapper();
}
function finishCapture(binding) {
  if (binding) {
    const map = getMap(capture.dev);
    // a key or button does one thing: take it away from any other SNES button
    const same = (x) => JSON.stringify(x) === JSON.stringify(binding);
    for (const k of Object.keys(map)) map[k] = map[k].filter((x) => !same(x));
    map[capture.btn] = capture.add ? [...(map[capture.btn] || []), binding] : [binding];
    setMap(capture.dev, map);
  }
  startCapture(capture.queue, capture.add);
}
function pollPadCapture() {
  if (!capture || capture.dev === 'kb') return;
  const p = padOf(capture.dev);
  const base = capture.baseline;
  if (!p || !base) return;
  const hats = noteHats(capture.dev, p);
  // wait until everything held when the prompt appeared is released, then take the first new press
  for (let i = 0; i < p.buttons.length; i++) {
    if (base.buttons[i]) { if (!p.buttons[i].pressed) base.buttons[i] = false; continue; }
    if (p.buttons[i].pressed) { finishCapture({ b: i }); return; }
  }
  for (let i = 0; i < p.axes.length; i++) {
    if (hats.has(i)) {
      const d = hatDirs(p.axes[i]);
      if (base.hats[i]) { if (!d.length) base.hats[i] = ''; continue; }
      if (d.length === 1) { finishCapture({ h: i, dir: d[0] }); return; }   // diagonals: wait for a clean direction
      continue;
    }
    const d = p.axes[i] - base.axes[i];
    if (Math.abs(d) > 0.6 && Math.abs(p.axes[i]) > 0.5) { finishCapture({ a: i, d: Math.sign(p.axes[i]) }); return; }
  }
}
addEventListener('keydown', (e) => {
  if (!capture) { if (e.code === 'Escape' && mapperDev) closeMapper(); return; }
  e.preventDefault(); e.stopPropagation();   // the press is for the dialog, not the game
  if (e.code === 'Escape') { finishCapture(null); return; }
  if (capture.dev === 'kb') finishCapture(e.code);
}, true);

// ---------- diagnostics file ----------
// "Save diagnostics": this browser, its controllers (as the Gamepad API reports them), the page's
// setup, and the recent messages and raw input (trace): for bug reports, mostly odd controllers.
// Saved on the player's computer only. The trace keeps every gamepad button change and every axis
// move of 0.1 or more (the last 4000).
const padPrev = {};
function tracePads() {
  for (const p of navigator.getGamepads()) {
    if (!p) continue;
    const prev = padPrev[p.index], dev = 'pad' + p.index;
    if (!prev || prev.id !== p.id) { padPrev[p.index] = { id: p.id, buttons: p.buttons.map((b) => b.pressed), axes: [...p.axes] }; continue; }
    p.buttons.forEach((b, i) => {
      if (b.pressed !== prev.buttons[i]) { remember(trace, 4000, `${dev} button ${i} ${b.pressed ? 'down' : 'up'} (value ${b.value.toFixed(2)})`); prev.buttons[i] = b.pressed; }
    });
    p.axes.forEach((v, i) => {
      if (Math.abs(v - prev.axes[i]) >= 0.1) {
        const hat = noteHats(dev, p).has(i) ? ` (hat ${hatDirs(v).join('-') || 'centered'})` : '';
        remember(trace, 4000, `${dev} axis ${i} ${prev.axes[i].toFixed(3)} -> ${v.toFixed(3)}${hat}`); prev.axes[i] = v;
      }
    });
  }
}
function saveDiagnostics() {
  const L = [];
  const names = deviceNames();
  L.push('tmnt4p-diagnostics 1', 'build ' + BUILD, 'saved ' + new Date().toISOString(), `page open ${((performance.now() - T0) / 1000).toFixed(0)} s`,
    'user-agent ' + navigator.userAgent,
    `screen ${screen.width}x${screen.height} @${devicePixelRatio}, window ${innerWidth}x${innerHeight}`,
    `cross-origin-isolated ${crossOriginIsolated}, fullscreen ${document.fullscreenEnabled ? 'yes' : 'no'}, emulator ${ready ? 'loaded' : 'not loaded'}, game ${running ? 'running' : 'not started'}`);
  L.push(audioCtx ? `audio ${audioCtx.state}, ${audioCtx.sampleRate} Hz, base latency ${(audioCtx.baseLatency * 1000).toFixed(1)} ms, output latency ${((audioCtx.outputLatency || 0) * 1000).toFixed(1)} ms, muted ${muted}`
    : `audio not started, muted ${muted}`);
  if (running) {
    L.push(`emulation ${Module._web_fps().toFixed(1)} fps, frame ${Module._web_frame_ms_avg().toFixed(1)} ms avg / ${Module._web_frame_ms_max().toFixed(1)} max, audio dropouts ${Module.HEAPU32[Module._web_underruns_ptr() >> 2]} total`);
    L.push(`bots state ${Module._web_bot_state()}` + (Module._web_bot_state() === 2 ? ': ' + Module.UTF8ToString(Module._web_bot_error()) : ''));
  }
  L.push('', '== players');
  for (let i = 0; i < 4; i++) L.push(`P${i + 1}: ${role(i) === 'h' ? names[deviceOn(i)] : role(i) === 'b' ? 'bot' : 'empty'}`);
  L.push(`bots can't lose health: ${botGod}; chosen by hand: ${JSON.stringify(seatChoice)}`);
  L.push('', '== devices (page)');
  for (const [dev, name] of Object.entries(names)) {
    L.push(`${dev} "${name}": player ${assign[dev] >= 0 ? 'P' + (assign[dev] + 1) : 'none'}`);
    const map = getMap(dev);
    L.push('  mapping: ' + MAP_ORDER.map(([btn]) => btn + '=' + ((map[btn] || []).map((b) => bindingLabel(dev, b)).join('/') || '-')).join('  '));
  }
  L.push('', '== gamepads (navigator.getGamepads)');
  const pads = navigator.getGamepads();
  L.push(`${pads.length} slots`);
  for (const p of pads) {
    if (!p) continue;
    L.push(`pad${p.index}: id "${p.id}", mapping "${p.mapping}", connected ${p.connected}, ${p.buttons.length} buttons, ${p.axes.length} axes` +
      (p.vibrationActuator ? ', vibration' : ''));
    L.push('  axes now: ' + p.axes.map((v, i) => `${i}=${v.toFixed(3)}`).join(' '));
    const hats = [...noteHats('pad' + p.index, p)];
    if (hats.length) L.push('  hats (axes seen above 1): ' + hats.join(', '));
    L.push('  buttons pressed now: ' + (p.buttons.map((b, i) => (b.pressed || b.value > 0.01 ? `${i}(${b.value.toFixed(2)})` : '')).filter(Boolean).join(' ') || 'none'));
  }
  let saved = [];
  try { saved = Object.keys(localStorage).filter((k) => k.startsWith('tmnt4p.map.')); } catch (e) {}
  L.push('saved mappings: ' + (saved.join(', ') || 'none'));
  L.push('', '== messages (warnings, errors, emulator output; seconds since the page opened)', ...messages);
  L.push('', '== input trace (seconds since the page opened)', ...trace, '');
  download('tmnt4p-diagnostics', L.join('\n'));
}
$('diag').onclick = saveDiagnostics;
$('mapDiag').onclick = saveDiagnostics;

// ---------- main loop: input out, picture in ----------
const canvas = $('screen'), ctx2d = canvas.getContext('2d');
const image = ctx2d.createImageData(W, H);
// the stats line (speed, audio dropouts) is for debugging: only with ?stats in the address
const showStats = new URLSearchParams(location.search).has('stats');
$('stats').hidden = !showStats;
let lastSeq = -1, shown = 0, shownT = performance.now(), lastUnder = 0, botsFailed = false;
function frame() {
  tracePads();
  pollPadCapture();
  updateMapper();
  updateReplay();
  const masks = readInput();
  if (running) {
    const base = Module._web_input_ptr() >> 2;
    for (let i = 0; i < 4; i++) Module.HEAPU32[base + i] = masks[i];
    const seq = Module._web_frame_seq();
    if (seq !== lastSeq) {
      lastSeq = seq;
      const p = Module._web_frame_ptr();
      image.data.set(Module.HEAPU8.subarray(p, p + W * H * 4));
      ctx2d.putImageData(image, 0, 0);
      shown++;
    }
    const now = performance.now();
    if (now - shownT > 1000) {
      if (showStats) {
        const under = Module.HEAPU32[Module._web_underruns_ptr() >> 2];
        $('stats').textContent = `emulation ${Module._web_fps().toFixed(1)} fps · frame ${Module._web_frame_ms_avg().toFixed(1)} ms avg, ` +
          `${Module._web_frame_ms_max().toFixed(1)} max (budget 16.6) · shown ${(shown * 1000 / (now - shownT)).toFixed(1)} fps · ` +
          `audio ${audioCtx ? audioCtx.state : 'off'}, dropouts ${under - lastUnder}/s`;
        lastUnder = under;
      }
      shown = 0; shownT = now;
      if (Module._web_bot_state() === 2 && !botsFailed) {
        botsFailed = true;
        console.warn('bots stopped:', Module.UTF8ToString(Module._web_bot_error()));
        $('botnote').textContent = 'The bots stopped with an error (details in the browser console).';
      }
    }
  }
  requestAnimationFrame(frame);
}
// ---------- fullscreen ----------
// the screen element alone (picture, or the ROM overlay). iPhone Safari has no element fullscreen:
// no button there.
const screenEl = document.querySelector('.screen');
function toggleFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  else screenEl.requestFullscreen().catch((e) => console.warn('fullscreen refused', e));
}
if (document.fullscreenEnabled) {
  $('fullscreen').hidden = false;
  $('fullscreen').onclick = toggleFullscreen;
  canvas.addEventListener('dblclick', toggleFullscreen);
}
// F: fullscreen, M: mute; unless bound to a game button (Escape leaves fullscreen: the browser does that)
addEventListener('keydown', (e) => {
  if (e.repeat || e.ctrlKey || e.metaKey || e.altKey || capture || mapperDev || boundKeys().has(e.code)) return;
  if (e.target instanceof HTMLInputElement || e.target instanceof HTMLSelectElement) return;
  if (e.code === 'KeyF' && document.fullscreenEnabled) { e.preventDefault(); toggleFullscreen(); }
  if (e.code === 'KeyM') { e.preventDefault(); setMuted(!muted); }
});

$('mapAll').onclick = () => startCapture(MAP_ORDER.map((m) => m[0]));
$('mapSkip').onclick = () => finishCapture(null);
$('mapReset').onclick = () => { setMap(mapperDev, null); capture = null; renderMapper(); };
$('mapDone').onclick = closeMapper;
$('mapper').onclick = (e) => { if (e.target === $('mapper')) closeMapper(); };
$('botgod').checked = botGod;
$('botgod').onchange = () => { botGod = $('botgod').checked; pushSeats(); };
renderPlayers();
requestAnimationFrame(frame);
