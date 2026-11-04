'use strict';
// Loaded before app.js, whose functions it uses (at run time only).
// Online play: lockstep. Every computer runs the emulator with its own ROM, and all of them run
// the same frames from the same input, so they show the same game.
//   - Lobby: the host gets a link; everyone says how many people play at their computer (one
//     seat each, or 0 to watch) and chooses their ROM; the host starts. Seats go in order: the
//     host's players first (P1...), then each guest's in the order they joined; seats left over
//     are bots (or empty).
//   - The lobby server (web/netplay/signaling.py, at /net/ws) only passes WebRTC connection
//     setup messages between the computers of a room, and hands out STUN/TURN settings; then
//     every pair of computers talks directly (or through TURN). It also keeps the list of public
//     games (Join an online game), from what each room's host tells it, and removes a computer the host
//     asks it to (and every computer in the game drops it, as if it had left).
//   - Each pair has three data channels: 'in' (unordered, no retransmits) carries a seat's input
//     per poll, with every poll the other side hasn't confirmed yet, so a lost packet is covered
//     by the next one; 'ctl' (reliable, JSON) carries hello, ping, start, hashes, joining and
//     leaving; 'st' (reliable) carries a saved state to a computer joining mid-game.
//   - The core (web.cpp g_net) writes this computer's seats' input a few polls ahead (the input
//     delay, adapted to the connection) and waits for every person's input before each poll;
//     this file moves input between the core and the network.
//   - Every second the computers compare work RAM hashes: a difference means they are out of
//     sync (a bug), shown on the page. Only the players' hashes count (a watcher's game is its
//     own): a watcher out of step with the coordinator stops and offers Rejoin (checkHash).
//   - A computer that drops out: the others agree on the poll from which bots play its seats
//     (each reports how far it has that seat's input and passes it on to the others, and the
//     first remaining computer in seat order, the coordinator, picks the furthest).
//   - A computer that joins a game in progress (or comes back): the coordinator gives it free
//     seats (its old ones, by name) from a poll X a moment ahead, saves the state there and
//     sends it over; at X every computer starts its bots over with the same seed (their Lua
//     state can't be copied), and the newcomer starts from the state. The coordinator holds
//     back its own input for X until every computer has confirmed, so none runs past X unaware.
//   - Out of sync (a bug somewhere): the same, but every computer but the coordinator loads the
//     coordinator's state at X, so the game goes on in sync after a moment's pause.
// Names: nobody types one. The lobby server gives each computer a name from its word lists
// ("Radical Pizza") and this page shows only names the lobby server sent (net.lobbyNames), never
// one from another computer's messages: a seat name from the host is used only if it is one of them.
// Messages from peers are data: shown with textContent only, input cut to the 12 SNES bits, and a peer's input is only taken for seats it plays (or seats of a computer
// that left, which every remaining computer passes on).
const NET = {
  ACTIVE: 0, DELAY: 1, LOCAL: 2, HUMAN: 3, SEQ: 4, POLL: 5, WAITS: 6, WAIT_MS: 7, LOCAL_SEQ: 8, HASHES: 9, STALL: 10, GAPS: 11,
  SEAT_DELAY: 15, STOPPED: 19, HAVE: 20, PADS: 24, DROP: 28, HASH: 32, JOIN: 224, EVENT_AT: 228, EVENT_SEED: 229, EVENT_SAVE: 230,
  EVENT_DONE: 231, STATE_SIZE: 232, EVENT_LOAD: 233, LOAD_SIZE: 234, RUSH: 235, IN: 256,
};
const NET_RING = 256, NET_HASH_RING = 64;
const NET_HIST = 4096;      // polls of input kept per seat, to send to a computer that's behind
const NET_GONE_MS = 6000;   // nothing heard from a computer for this long: it left
const net = {
  role: null,          // 'host' | 'guest' | null (not online)
  choosing: false,     // the host is choosing the game's version (no game yet)
  ws: null, id: null, room: null, host: null, ice: [],
  peers: new Map(),    // peer id -> peer (join order)
  members: new Set(),  // computers in the game (playing or watching), besides this one
  name: '', players: null,   // players at this computer: chosen each time (null: not yet), 0 = watch
  rom: null, romBytes: null, bots: null, botsSrc: null, patches: null,
  started: false, go: false, halted: false, joined: false,
  seats: null, owners: null, names: null, delay: 0, seed: 0, mine: [],
  pending: [new Map(), new Map(), new Map(), new Map()],   // per seat: poll -> mask, not yet in the core
  hist: [new Map(), new Map(), new Map(), new Map()],      // per seat: poll -> mask, the last NET_HIST polls
  seatQ: [],           // seat changes (joins, drops) the core doesn't have yet (applySeatChanges)
  seatAt: [0, 0, 0, 0], // per seat: the poll of the last change the core has
  histTop: [0, 0, 0, 0],                                   // per seat: polls below this are in hist
  dropped: [0, 0, 0, 0],                                   // per seat: poll a bot took over (0: none)
  passTo: [0, 0, 0, 0],   // per seat: its input below this poll (a player's before it left, the seat
                          // given to another since) goes on to a computer still behind it (netSend)
  reports: [new Map(), new Map(), new Map(), new Map()],   // per seat of a computer that left: reporter -> how far it has the input
  reportsSince: [0, 0, 0, 0],
  order: [],           // computers in the order they came into the game (the same on every computer): the coordinator is the first one still playing
  everPerson: [false, false, false, false],   // per seat: a person played it at some point (the core makes it a bot, not empty, once they leave)
  events: [],          // joins and resyncs the core hasn't got yet (it hasn't reached the one before): {at, seed, save, load}
  joinOkTo: null,      // joined: {id, at}, the coordinator to tell once this computer runs past the join poll
  admitting: null,     // coordinator: {kind: 'join' | 'resync', id, at, ok: Set of members that confirmed, sent} during an event
  joinInfo: null,      // joining: the coordinator's 'join' message, once confirmed (the state comes per peer: peer.stRx)
  joinOffers: new Map(),   // joining: peer -> the 'join' it sent, until every computer in the game confirms it
  joinAcks: new Map(),     // joining: peer -> the poll of the join it confirmed ('joinack')
  removedIds: new Set(),   // computers the host removed (mineByName)
  wentAt: new Map(),       // computer id -> when its connection here was dropped or it was removed (lobbyOnly)
  preStart: [],        // joining: drops, leaves and delays the game's computers sent before this one runs: {peer, m}
  claims: new Map(),   // coordinator: computer another one says it lost, that this one still hears -> {by, since}
  held: [],            // drop/gone messages from a computer that isn't the coordinator (yet): {from, m, at}
  dropWait: [0, 0, 0, 0],   // coordinator: since when it waits for the input up to a drop poll
  droppedAt: [0, 0, 0, 0],  // per seat: when the drop was decided here (admit)
  inputWait: [0, 0, 0, 0],  // since when the game waits here for a seat's input (0: it doesn't)
  goneWait: [0, 0, 0, 0],   // since when the game waits here for a seat whose player this one lost (checkInput)
  resyncSince: 0,      // when the coordinator said resync (its state should follow)
  inputPoll: -1,       // the poll at the last input check (waiting counts only while it stands still)
  pollSince: 0, lastCheck: 0,   // since when the poll stands still here; the last check (checkInput)
  resyncFrom: null, resyncAt: 0,   // resyncing: the coordinator, whose state comes in, and its poll
  myHashes: new Map(), hashesSeen: 0, desync: null, hashFloor: 0, lastResync: -Infinity, resyncs: 0,
  lastWaits: 0, lastWaitMs: 0, lastInfo: 0, lastPoll: -1, lastPollAt: 0, waitingShown: false,
  leadSum: 0, leadN: 0, stalled: 0, lead: 0,
  early: new Array(18).fill(0),   // how many polls before it was needed each input arrived (-1 = late), this second
  // adaptive input delay, per seat: the delay now (ours, and the others' as they announce it),
  // the least time ahead each seat's input arrived here this second, and for our seats what the
  // others report about theirs
  sdelay: [0, 0, 0, 0], minEarly: [Infinity, Infinity, Infinity, Infinity],
  earlyReports: [new Map(), new Map(), new Map(), new Map()], calm: [0, 0, 0, 0], holdUntil: [0, 0, 0, 0],
  fixedDelay: false,
  public: false, infoSent: '', games: null,
  lobbyNames: new Map(),   // computer id -> its name, from the lobby server only
  lobbyLeft: new Map(),    // computer id -> when the lobby server said its page left (checkSplit)
  lobbyLost: '',           // the line that says this page lost (or never reached) the lobby before a game: it stays (netBlocked)
  noHost: null,            // the host's id, if no connection to its computer could be made (netBlocked)
  lostLinks: new Map(),    // computer id -> {at, said, need}: its connection here broke, before a game here (checkLostLinks)
  lostShown: '', lostButton: false,   // the line a guest shows for them, while it does; the Rejoin button is there for it
  lobbyStarted: false,     // the lobby server says a game ran in this room (only the host's word sets that)
  backMsg: '',         // why this page came back to the start screen (startUp keeps it)
};
// testing, on this computer's own server only (a link to the site can't turn them on):
// ?lag=<ms> holds every message we send for that long (a round trip then costs twice that),
// ?loss=<0-1> drops that share of input packets, ?delay=<frames> (host) fixes the input delay
const NET_Q = new URLSearchParams(['localhost', '127.0.0.1', '[::1]'].includes(location.hostname) ? location.search : '');
const NET_TEST = { lag: Math.min(Math.max(+NET_Q.get('lag') || 0, 0), 1000), loss: Math.min(Math.max(+NET_Q.get('loss') || 0, 0), 0.9) };
function chSend(ch, data, input) {
  if (input && NET_TEST.loss && Math.random() < NET_TEST.loss) return;
  try {
    if (!NET_TEST.lag) { ch.send(data); return; }
    setTimeout(() => { if (ch.readyState === 'open') try { ch.send(data); } catch (e) {} }, NET_TEST.lag);
  } catch (e) { console.warn('send', e); }
}
const netWord = (i) => (Module._web_net_ptr() >> 2) + i;
const H32 = () => Module.HEAP32;
const netLoad = (i) => Atomics.load(H32(), netWord(i));
const netRunning = () => net.started && ready && netLoad(NET.ACTIVE) === 2;

function netStatus(text, kind) { $('netstatus').textContent = text; $('netstatus').className = 'status ' + (kind || ''); }
// a note about something just refused: gone after a while, unless something else was said since
// (a guest's line that stays, netBlocked, is said again then: the note was written over it)
function netNote(text) {
  netStatus(text, 'bad');
  setTimeout(() => {
    if ($('netstatus').textContent !== text) return;
    const blocked = net.role === 'guest' && !net.started && !net.refused && !net.joinInfo ? netBlocked() : '';
    netStatus(blocked, blocked ? 'bad' : '');
  }, 6000);
}
// during the game (the start screen is hidden then): the line under the picture
function netWarn(text, kind) {
  net.warnAt = performance.now();
  $('netwarn').hidden = !text;
  $('netwarn').textContent = text;
  $('netwarn').className = 'netwarn ' + (kind || '');
}
const cleanName = (s) => String(s || '').replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 40);
// a name from another computer's message (seat names): only one the lobby server gave out
// (plus " 2" etc. for a computer with several players), else nothing
function knownName(s) {
  if (typeof s !== 'string') return '';
  const base = s.replace(/ [1-4]$/, '');
  return base === net.name || [...net.lobbyNames.values()].includes(base) ? s : '';
}
// the lobby server's name for this browser comes back after a reload
const nameToken = () => { try { return localStorage.getItem('tmnt4p.nametoken') || undefined; } catch (e) { return undefined; } };
function gotName(name, token) {
  net.name = cleanName(name);
  if (net.id) net.lobbyNames.set(net.id, net.name);
  try { if (typeof token === 'string') localStorage.setItem('tmnt4p.nametoken', token); } catch (e) {}
  $('netme').textContent = net.name;
}

// ---------- lobby server ----------
function netConnect() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/net/ws');
    net.ws = ws;
    ws.onopen = () => resolve();
    ws.onerror = () => reject(new Error('could not reach the lobby server'));
    ws.onclose = () => {
      // (the list of public games: its own line; Close and Join an online game connect again)
      if (!net.role) { clearInterval(net.listTimer); $('netgamelist').replaceChildren(); $('netgamestatus').textContent = 'Lost the connection to the lobby server. Close this and try again.'; if (net.ws === ws) net.ws = null; return; }
      // (refused: the lobby's reason stays shown; Rejoin connects again)
      if (!net.started) { if (!net.refused) { net.lobbyLost = 'Lost the connection to the lobby server. Reload the page to connect again.'; netStatus(net.lobbyLost, 'bad'); } }
      else if (!net.halted) netWarn('Lost the connection to the lobby server: the game goes on, but nobody new can join it.', 'warn');
      renderPeers();
      renderPlayers();
    };
    ws.onmessage = (e) => { let m; try { m = JSON.parse(e.data); } catch (err) { return; } onLobby(m); };
  });
}
// (never one the lobby wouldn't take: it closes the connection of one sending a message over 16 KB)
// (and signals at most as fast as the lobby takes them, a little under: it cuts off a page far
// past them, and others joining fast could steer this one there; past this, they're dropped here)
const SIG_RATE = 18, SIG_BURST = 200;
let sigTokens = SIG_BURST, sigAt = performance.now();
const sig = (msg) => {
  if (!net.ws || net.ws.readyState !== 1) return;
  const text = JSON.stringify(msg), bytes = new TextEncoder().encode(text).length;
  if (bytes > 15000) { console.warn('online: a lobby message too big to send', msg.t); return; }
  // (nor one the lobby would close this page's connection for: deep, or a signal not plain ASCII)
  if ((text.match(/[[{]/g) || []).length > 64 || (msg.t === 'signal' && !/^[\x00-\x7e]*$/.test(text))) {
    console.warn('online: a lobby message the lobby would refuse', msg.t);
    return;
  }
  if (msg.t === 'signal') {
    const now = performance.now(), cost = 1 + Math.floor(bytes / 4096);   // (as the lobby counts it)
    sigTokens = Math.min(SIG_BURST, sigTokens + (now - sigAt) / 1000 * SIG_RATE);
    sigAt = now;
    if (sigTokens < cost) { console.warn('online: too many signals just now, one dropped'); return; }
    sigTokens -= cost;
  }
  net.ws.send(text);
};
// the lobby server made this computer the room's host (not before it answered: no id yet)
// (and while the lobby connection is up: it's what removing someone and letting people in need)
function amHost() { return !!net.id && net.id === net.host && !!net.ws && net.ws.readyState === 1; }
// a game runs here (the lobby says one ran in this room, and a computer here says it's in it):
// not one a guest alone says runs (it could hide the host's Start button)
const gameHere = () => net.lobbyStarted && [...net.peers.values()].some((p) => p.hello && p.hello.game);
// (a game runs, by the lobby's word or the lobby host's: one left out at the start isn't told
// by the lobby, but the host it chose is in the game; another's word doesn't count)
const gameSaid = () => net.lobbyStarted || !!(net.peers.get(net.host) && net.peers.get(net.host).hello && net.peers.get(net.host).hello.game);
// STUN/TURN servers from the lobby: only stun:/turn:/turns: URLs and string credentials
function iceFrom(list) {
  if (!Array.isArray(list)) return [];
  return list.slice(0, 4).map((s) => ({
    urls: (Array.isArray(s.urls) ? s.urls : [s.urls]).filter((u) => typeof u === 'string' && /^(stun|turns?):/.test(u)).slice(0, 4),
    ...(typeof s.username === 'string' ? { username: s.username } : {}),
    ...(typeof s.credential === 'string' ? { credential: s.credential } : {}),
  })).filter((s) => s.urls.length);
}

function onLobby(m) {
  if (m.t === 'created' || m.t === 'joined' || m.t === 'host') { net.public = m.public === true; $('netpublic').checked = net.public; }
  if (m.t === 'created') {
    net.id = m.id; net.room = m.room; net.host = m.id; net.ice = iceFrom(m.ice);
    gotName(m.name, m.token);
    $('netlinktext').value = location.origin + location.pathname + '#r=' + m.room;
    // a reload (by accident) comes back into the same game, its seats found again by name
    try { history.replaceState(null, '', location.pathname + location.search + '#r=' + m.room); } catch (e) {}
    // (Players here chosen before the room was made: kept now, as its change would have)
    try { if (net.players !== null && netRoomId()) sessionStorage.setItem('tmnt4p.players.' + netRoomId(), String(net.players)); } catch (e) {}
    $('netlink').hidden = false;
    netStatus('');
    netSendInfo();   // the game's version, at once: a reload of this page right away takes it back from the lobby
    renderPeers();
  } else if (m.t === 'joined') {
    net.id = m.id; net.room = m.room; net.host = m.host; net.ice = iceFrom(m.ice);
    gotName(m.name, m.token);
    if (m.names && typeof m.names === 'object') for (const [id, name] of Object.entries(m.names)) net.lobbyNames.set(id, cleanName(name));
    net.roomRom = m.info && typeof m.info.rom === 'string' && ROMS[m.info.rom] ? m.info.rom : null;
    net.lobbyStarted = !!(m.info && m.info.started === true);
    net.hostName = net.lobbyNames.get(m.host) || '';
    $('netlinktext').value = location.origin + location.pathname + '#r=' + m.room;
    $('netlink').hidden = false;
    for (const id of m.peers) netPeer(id, true);   // the newcomer calls everyone already there
    // (the host's own page reloaded before the start: the lobby kept it host)
    netStatus(amHost() ? '' : 'Joined. Connecting to the other players…', 'ok');
    netCheckRom();
    renderPeers();
  } else if (m.t === 'peer') {
    net.lobbyNames.set(m.id, cleanName(m.name));
    netPeer(m.id, false);   // during a game too: it may join or watch
    renderPeers();
  } else if (m.t === 'left') {
    // its lobby connection closed; in a game only the peer connection counts (and checkSplit:
    // a computer whose page closed isn't on the other side of a network split)
    if (typeof m.id === 'string') net.lobbyLeft.set(m.id, performance.now());
    // (joining: one of the game's computers may play on without its lobby connection; its peer
    // connection decides, as for the others)
    if (!net.members.has(m.id) && !(!net.started && joiningWith(m.id))) dropPeer(m.id);
  } else if (m.t === 'host') {
    const before = net.hostName;
    if (typeof m.id === 'string') net.host = m.id;
    if (m.started === true) net.lobbyStarted = true;
    net.hostName = net.host === net.id ? net.name : net.lobbyNames.get(net.host) || '';
    // the host left the lobby (not a reload of the host's page: that keeps its name): say who's host now
    // (not over a failed join's message: that one goes with its Rejoin button)
    if (!net.started && net.hostName !== before && ($('netrejoin').hidden || (net.lostButton && ($('netstatus').textContent === net.lostShown || !/Rejoin/.test($('netstatus').textContent))))) {   // (or with checkLostLinks' button there, over its line: it says its own again if it still holds)
      // (made host while a game runs that it isn't in: none of that game's computers is in the
      // lobby; it can't join it, since a newcomer needs the lobby host's ack from another computer)
      if (amHost() && gameHere()) netStatus("The host left, so you're the host now, but this computer can't join the game in progress here. Leave to join or host another game.", 'bad');
      else if (amHost()) netStatus("The host left, so you're the host now: start the game when everyone's ready.", 'ok');
      else if (net.hostName && before) netStatus(`The host left: ${net.hostName} is the host now.`, 'ok');   // (before unknown: joined while the host's page was away, so it's that page back)
    }
    showJoining();   // (the new host's ack may confirm an offer now)
    for (const id of net.joinOffers.keys()) { const p = net.peers.get(id); if (p) stateArrived(p); }
    // (another host now, or the host's page again: the line about no way to the old one goes)
    if (net.noHost && net.noHost !== net.host) { net.noHost = null; if ($('netstatus').textContent.startsWith("Couldn't connect to the host's computer")) net.romKey = null; }
    netCheckRom();
    renderPeers();
    renderPlayers();   // (a new host gets the Remove buttons)
  } else if (m.t === 'signal') {
    const peer = net.peers.get(m.from);
    if (peer) peer.chain = peer.chain.then(() => onSignal(peer, m.data)).catch((e) => console.warn('signal', e));
  } else if (m.t === 'name' && typeof m.id === 'string') {
    net.lobbyNames.set(m.id, cleanName(m.name));
    if (m.id === net.host) net.hostName = net.lobbyNames.get(m.id);   // (a new name isn't a new host)
    renderPeers();
  } else if (m.t === 'renamed') {
    gotName(m.name, m.token);
    renderPeers();
  } else if (m.t === 'games') {
    renderGames(Array.isArray(m.games) ? m.games : []);
  } else if (m.t === 'public' && m.public === false && net.public) {
    // the lobby didn't list it: this network has the most public games it may list already
    net.public = false;
    $('netpublic').checked = false;
    if (net.started) netWarn("This game couldn't be listed: your network already has as many public games as it may list.", 'warn');
    else netNote("This game couldn't be listed: your network already has as many public games as it may list.");
    renderPeers();
  } else if (m.t === 'kicked') {
    netRemoved();
  } else if (m.t === 'replaced') {
    // this browser opened the game again (another tab or window): this page leaves it to that one
    const why = 'This game was opened again in another tab or window of this browser, so this page left it.';
    if (net.ws) net.ws.onclose = null;
    if (!net.started) netBackToStart(why);
    else { ctlAll({ t: 'bye' }); netHalt(why, false); }
  } else if (m.t === 'error') {
    netStatus('Lobby: ' + String(m.msg).slice(0, 200), 'bad');
    // the lobby turned this connection away (it closes it next): say so, not "lost the connection"
    if (/lobby is full|too many connections/.test(m.msg)) {
      const text = `The lobby server can't take this connection: ${/full/.test(m.msg) ? "it's full right now" : 'too many connections from your network'}. Try again in a little while.`;
      if (net.ws) net.ws.onclose = null;
      if (!net.role) { $('netgamestatus').textContent = text; clearInterval(net.listTimer); }
      // (a link's page: the link stays, with Rejoin)
      else if (!net.started && net.role === 'guest') { net.refused = true; netStatus(text.replace('Try again in a little while.', 'Wait a little, then Rejoin.'), 'bad'); $('netrejoin').hidden = false; net.lostButton = false; }
      else if (!net.started) netBackToStart(text);
      return;
    }
    // too many joins from this network just now (the lobby's rate): the link stays, try again
    if (/too many games joined/.test(m.msg)) {
      if (net.role === 'host' && !net.room) { netBackToStart('Too many games hosted or joined from your network just now. Wait a minute, then host again.'); return; }
      net.refused = true;   // (until Rejoin reloads the page)
      netStatus('Too many games joined from your network just now. Wait a minute, then Rejoin.', 'bad');
      $('netrejoin').hidden = false;
      return;
    }
    // the link didn't work (the game is over, or full): offer hosting instead
    if (!net.id && net.role === 'guest' && /full/.test(m.msg)) {
      // (full: a place may come free; the link stays, with Rejoin)
      net.refused = true;
      netStatus('That online game is full right now. Rejoin to try again, or Leave to host or find another.', 'bad');
      $('netrejoin').hidden = false; net.lostButton = false;
      // (Rejoin and Leave load the page again: this lobby connection, in no room, isn't kept open)
      if (net.ws) { net.ws.onclose = null; try { net.ws.close(); } catch (e) {} }
    } else if (!net.id && net.role) {
      netBackToStart(/removed/.test(m.msg) ? 'The host removed you from that game.'
        : 'That online game is ' + (/full/.test(m.msg) ? 'full.' : 'over (everyone left).') + ' You can host a new one, or find another.');
    }
  }
}
// out of the lobby, back to the start screen (before any game started here)
function netBackToStart(text) {
  if (net.ws) { net.ws.onclose = null; try { net.ws.close(); } catch (e) {} net.ws = null; }
  for (const peer of net.peers.values()) { peer.gone = true; try { peer.pc.close(); } catch (e) {} }   // (gone: their closing isn't a lost link)
  net.peers.clear();
  // nothing of that game stays: hosting or joining another starts afresh
  Object.assign(net, { role: null, choosing: false, id: null, host: null, hostName: '', room: null, roomRom: null, lobbyStarted: false, rom: null, romBytes: null, romKey: null,
    joinSince: 0, preStart: [], players: null, public: false, infoSent: '', peersKey: '', lostShown: '', lostButton: false, lobbyLost: '', noHost: null, refused: false, backMsg: text });
  net.lobbyNames.clear(); net.lobbyLeft.clear(); net.lostLinks.clear(); net.joinOffers.clear(); net.joinAcks.clear(); net.removedIds.clear(); net.wentAt.clear();
  $('netpublic').checked = false;
  netShowPlayers();
  $('netchoose').hidden = false;
  $('netbox').hidden = true;
  $('netlink').hidden = true;
  $('nethostonly').hidden = true;
  $('netrejoin').hidden = true;
  $('botgodrow').hidden = false;
  netStatus('');
  $('playlog').hidden = false;
  netDropBox(null);
  try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
  status(text, 'bad');
  showSaved();
  renderPlayers();
}
// the host removed this computer
function netRemoved() {
  if (net.ws) { net.ws.onclose = null; try { net.ws.close(); } catch (e) {} }
  try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
  if (!net.started) { net.id = null; netBackToStart('The host removed you from that game.'); return; }
  netHalt('The host removed you from this game.', false);
}
// the host: take a computer out of the game (lobby or game); the lobby server keeps it out
function netKick(id) {
  if (!amHost() || id === net.id) return;
  sig({ t: 'kick', id });
  ctlAll({ t: 'kick', id });
  kickPeer(id);
}
function kickPeer(id) {
  net.removedIds.add(id);   // (mineByName: whatever state this page has it in, or none)
  net.wentAt.set(id, performance.now());
  const peer = net.peers.get(id);
  if (!peer) return;
  if (net.started && net.members.has(id)) { markGone(peer, 'removed by the host'); try { peer.pc.close(); } catch (e) {} }
  else dropPeer(id);
  renderPlayers();
}
// the host tells the lobby server what the game list shows (when it changes)
function netSendInfo() {
  if (!net.room || !amHost()) return;
  let players = net.players || 0;
  if (net.started) players = [0, 1, 2, 3].filter(personNow).length;
  else players = startLineup().players;   // (those it would seat: another's word alone doesn't fill the list)
  // who is in the game (the lobby hands the host's role only to one of them; joins need the host)
  // (not one let in that doesn't run yet: it couldn't confirm joins)
  // (and, after those still connected, one lost in the last 20 s: if this one stops for a split,
  // its lobby connection closes, and so do those of its side; the host's role should go on to one
  // of the others still in the game. Last: the lobby takes the first listed that's in the room,
  // and a lost one stays there a minute or two)
  const now = performance.now();
  const ok = (p) => p && !(p.joinBy && !p.sending);
  // (those still in the lobby first: the lobby reads 8, and makes host one it lists that it has)
  // (players before watchers: the lobby makes the first one host when this one goes)
  const ids = [...net.members].filter((id) => id !== net.id).sort((a, b) => (net.owners.includes(b) - net.owners.includes(a)) || (net.lobbyLeft.has(a) - net.lobbyLeft.has(b)));
  const members = net.started && !net.halted ? [net.id,
    ...ids.filter((id) => { const p = net.peers.get(id); return ok(p) && !p.gone; }),
    ...ids.filter((id) => { const p = net.peers.get(id); return ok(p) && p.gone && p.lost && now - p.goneAt < 20000; })].slice(0, 8) : [];   // (the lobby reads 8)
  const info = { t: 'info', public: net.public, rom: net.rom || net.roomRom || '', build: BUILD, players: Math.min(players, 4), started: net.started && !net.halted, members };
  const text = JSON.stringify(info);
  if (text === net.infoSent) return;
  net.infoSent = text;
  sig(info);
}

// ---------- the list of public games ----------
function netFindGames() {
  $('netchoose').hidden = true;
  $('netgames').hidden = false;
  $('netgamestatus').textContent = 'Looking for games…';
  const ask = () => { if (!$('netgames').hidden && !net.role) sig({ t: 'list' }); };
  const open = net.ws && net.ws.readyState === 1 ? Promise.resolve() : netConnect();
  open.then(() => { ask(); clearInterval(net.listTimer); net.listTimer = setInterval(ask, 3000); },
    (e) => { $('netgamestatus').textContent = 'Online play unavailable: ' + e.message; });
}
function netCloseGames() {
  clearInterval(net.listTimer);
  $('netgames').hidden = true;
  $('netchoose').hidden = false;
  if (net.ws && !net.role) { net.ws.onclose = null; try { net.ws.close(); } catch (e) {} net.ws = null; }
}
function renderGames(games) {
  const list = $('netgamelist');
  list.replaceChildren();
  let shown = 0;
  for (const g of games.slice(0, 50)) {
    if (!g || typeof g.room !== 'string' || !/^[A-Za-z0-9_-]{10,40}$/.test(g.room)) continue;
    const rom = ROMS[g.rom];
    const players = Math.min(Math.max(parseInt(g.players, 10) || 0, 0), 4);
    const row = el('div', 'netgame');
    const text = el('div');
    text.append(el('b', '', (cleanName(g.name) || 'Someone') + "'s game"),
      el('span', '', ` · ${rom ? rom.name + ' version' : 'unknown version'} · ${players} of 4 playing · ${g.started ? 'in progress' : 'in the lobby'}`));
    const join = el('button', 'small', players >= 4 ? 'Watch' : 'Join');
    // a different page version can't play along (the host's page is newer or older: reload)
    const why = g.build !== BUILD ? 'The host has a different version of this page'
      : !rom ? 'An unknown ROM version' : '';
    if (rom && !savedRoms[g.rom] && !why) text.append(el('span', 'needrom', ` · needs your ${rom.name} ROM`));
    if (why) { join.disabled = true; join.title = why; }
    else if (!savedRoms[g.rom]) join.title = `You'll need your ${rom.name} ROM to play`;
    join.onclick = () => { location.hash = '#r=' + g.room; };   // the hashchange handler loads the game's page
    row.append(text, join);
    list.appendChild(row);
    shown++;
  }
  $('netgamestatus').textContent = shown ? '' : 'No public games right now. Host one, and tick Public game.';
}

// ---------- peers ----------
function netPeer(id, offer) {
  if (net.peers.has(id)) return net.peers.get(id);
  const pc = new RTCPeerConnection({ iceServers: net.ice });
  const peer = {
    id, pc, chain: Promise.resolve(), hello: null, rtt: null, rtts: [], pingN: 0, hashes: new Map(),
    iceQ: [], iceTimer: 0,   // (candidates to send: onicecandidate)
    acked: [0, 0, 0, 0],     // per seat: the polls below this the peer has
    lastSend: [0, 0, 0, 0], lastAny: 0,
    lastHeard: performance.now(), gone: false,
    inCh: pc.createDataChannel('in', { negotiated: true, id: 0, ordered: false, maxRetransmits: 0 }),
    ctl: pc.createDataChannel('ctl', { negotiated: true, id: 1 }),
    st: pc.createDataChannel('st', { negotiated: true, id: 2 }),
  };
  peer.inCh.binaryType = peer.st.binaryType = 'arraybuffer';
  net.peers.set(id, peer);
  // candidates a few at once (a newcomer has one connection to make to each computer in the room:
  // a message per candidate could pass the lobby's rate limit for messages)
  pc.onicecandidate = (e) => {
    peer.iceQ.push(e.candidate ? e.candidate.toJSON() : null);
    if (!peer.iceTimer) {
      peer.iceTimer = setTimeout(() => {
        peer.iceTimer = 0;
        const q = peer.iceQ.splice(0);
        for (let i = 0; i < q.length; i += 16) sig({ t: 'signal', to: id, data: { ice: q.slice(i, i + 16) } });
      }, 50);
    }
  };
  pc.onconnectionstatechange = () => {
    if (['failed', 'closed'].includes(pc.connectionState)) markGone(peer, 'connection ' + pc.connectionState);
    renderPeers();
  };
  peer.ctl.onopen = () => { sendHello(peer); renderPeers(); };
  peer.ctl.onclose = () => markGone(peer, 'channel closed');
  peer.ctl.onmessage = (e) => {
    // (a budget of messages: the game sends a few a second; a computer flooding this page with
    // them, to keep it busy, goes)
    const now = performance.now();
    peer.ctlTokens = Math.min(300, (peer.ctlTokens === undefined ? 300 : peer.ctlTokens) + (now - (peer.ctlAt || now)) / 1000 * 50);
    peer.ctlAt = now;
    // (past it, dropped; and gone if it goes on 2 s: a page waking from a freeze gets a backlog
    // all at once, which isn't a flood)
    if (peer.ctlTokens < 1) {   // (never in debt: a backlog's end, then the next on time, is fine)
      peer.floodSince = peer.floodSince || now;
      if (now - peer.floodSince > 2000 && !peer.gone) { console.warn('online:', peerName(peer.id), 'sent too many messages'); markGone(peer, 'sent too many messages'); try { peer.pc.close(); } catch (err) {} }
      return;
    }
    // (over only once the budget is back some way: a flood keeps it near 0, one at a time let
    // through as it refills; after a backlog, the next ones on time find it refilled)
    if (peer.ctlTokens >= 10) peer.floodSince = 0;
    peer.ctlTokens--;
    peer.lastHeard = now;
    // (the game's are a few KB at most: a big one would only cost parsing)
    if (typeof e.data !== 'string' || e.data.length > 16384) return;
    let m; try { m = JSON.parse(e.data); } catch (err) { return; }
    onCtl(peer, m);
  };
  // (budgets on the other channels too, as for ctl: input ~125 packets a second a seat; a state's
  // pieces come in a run, 1024 for the biggest)
  peer.inCh.onmessage = (e) => { if (overBudget(peer, 'in', 2000, 3000)) return; peer.lastHeard = performance.now(); onInput(peer, e.data); };
  peer.st.onmessage = (e) => { if (overBudget(peer, 'st', 300, 2500)) return; peer.lastHeard = performance.now(); onStateChunk(peer, e.data); };
  peer.offerer = !!offer;   // (onSignal: the one offer, the one answer)
  if (offer) {
    peer.chain = peer.chain.then(async () => {
      await pc.setLocalDescription(await pc.createOffer());
      sig({ t: 'signal', to: id, data: { sdp: pc.localDescription.toJSON() } });
    });
  }
  return peer;
}
async function onSignal(peer, data) {
  if (data.sdp && (data.sdp.type === 'offer' || data.sdp.type === 'answer')) {
    // one offer from the computer that makes the connection (the newcomer), one answer to it:
    // nothing here renegotiates, and answering every offer another sent would spend this page's
    // own rate of lobby messages (the lobby cuts off one sending too many: the host, say)
    if (peer.sdpDone || (data.sdp.type === 'offer') === peer.offerer) return;
    // (and only one like this page's own: one data channel section, a few KB. Another with many
    // sections would make the answer bigger than the lobby takes, and cut this page off it)
    const sdp = String(data.sdp.sdp);
    const m = sdp.split(/\r?\n/).filter((l) => l.startsWith('m='));
    // (its mid is copied into the answer and every candidate this page sends: plain, short)
    const mids = sdp.split(/\r?\n/).filter((l) => l.startsWith('a=mid:'));
    if (sdp.length > 8000 || !/^[\x00-\x7e]*$/.test(sdp) || /[[\]{}]/.test(sdp) || !mids.every((l) => /^a=mid:[A-Za-z0-9_-]{1,16}\r?$/.test(l)) || m.length !== 1 || !/^m=application \S+ \S+ webrtc-datachannel/.test(m[0])) {
      console.warn('online: an offer or answer not like this page\'s, from', peerName(peer.id));
      return;
    }
    peer.sdpDone = true;
    await peer.pc.setRemoteDescription({ type: data.sdp.type, sdp });
    if (data.sdp.type === 'offer') {
      await peer.pc.setLocalDescription(await peer.pc.createAnswer());
      sig({ t: 'signal', to: peer.id, data: { sdp: peer.pc.localDescription.toJSON() } });
    }
  } else if ('ice' in data) {
    // (a list: a few at once, in order; null: no more. 64 from a computer in all: a real one
    // has a few dozen at most)
    for (const c of Array.isArray(data.ice) ? data.ice.slice(0, 64) : [data.ice]) {
      if ((peer.ice = (peer.ice || 0) + 1) > 64) break;
      try { await peer.pc.addIceCandidate(c || undefined); } catch (e) { console.warn('candidate', e); }
    }
  }
}
// a computer's messages on a channel past its budget: dropped; one that keeps on past it 2 s goes
// (a page waking from a freeze gets a backlog all at once, which isn't a flood)
function overBudget(peer, k, rate, burst) {
  const now = performance.now(), b = peer.budgets || (peer.budgets = {});
  const x = b[k] || (b[k] = { tokens: burst, at: now, since: 0 });
  x.tokens = Math.min(burst, x.tokens + (now - x.at) / 1000 * rate);
  x.at = now;
  if (x.tokens < 1) {
    x.since = x.since || now;
    if (now - x.since > 2000 && !peer.gone) { console.warn('online:', peerName(peer.id), 'sent too many messages'); markGone(peer, 'sent too many messages'); try { peer.pc.close(); } catch (e) {} }
    return true;
  }
  if (x.tokens >= burst / 30) x.since = 0;
  x.tokens--;
  return false;
}
// Before a game here: computers whose connection to this one broke, their pages still in the room
// 4 s later (a page that closed or reloaded: the lobby says it left, and that is all). The two
// stay unconnected until one of them joins again, and a guest would wait for a start that never
// comes here (the host can start without it): a guest is told and offered Rejoin (it comes back
// as a newcomer and connects to everyone again); the host is told once to wait for that. A
// guest's line stays while it's so (said again if something else was written over it) and goes
// once it isn't (they left, were removed, or this one became host): net.lostShown is that line,
// net.lostButton whether the Rejoin button is there for it (not for a join that failed before).
function checkLostLinks() {
  const now = performance.now();
  let lost = [];
  for (const [id, e] of net.lostLinks) {
    if (net.started || !net.id || !net.ws || net.ws.readyState !== 1 || !net.lobbyNames.has(id) || net.lobbyLeft.has(id) || net.removedIds.has(id) || net.peers.has(id)) net.lostLinks.delete(id);
    // (need false: a game ran when it broke (as netCheckRom tells: one that ended is none), and it wasn't one of that game's computers: another page
    // waiting, or a stranger that came and cut its connections, doesn't keep this one from joining)
    else if (now - e.at >= 4000 && e.need) lost.push(id);
  }
  const list = (a) => (a.length < 3 ? a.join(' and ') : a.slice(0, -1).join(', ') + ' and ' + a[a.length - 1]);
  // (not over a join the host confirmed: that one comes, whatever another waiting page does)
  const say = lost.length && !net.refused && ![...net.joinOffers.values()].some(joinConfirmed);
  const cur = $('netstatus').textContent;
  if (say && amHost()) {
    // (once each, and not over something else being said: then at the next tick it isn't)
    const fresh = lost.filter((id) => !net.lostLinks.get(id).said);
    if (fresh.length && (!cur || cur === 'Link copied.')) {
      for (const id of fresh) net.lostLinks.get(id).said = true;
      netNote(`Lost the connection to ${list(fresh.map((id) => peerName(id) + "'s computer"))}. ${fresh.length > 1 ? 'They connect' : 'It connects'} again when they press Rejoin (or reload the page).`);
    }
  }
  lost = lost.sort((x, y) => (y === net.host) - (x === net.host)).map((id) => (id === net.host ? `the host's computer (${peerName(id)})` : `${peerName(id)}'s computer`));
  const text = say && !amHost() ? `Lost the connection to ${list(lost)}. Rejoin to connect again.` : '';
  if (text) {
    // (not over another line that offers Rejoin, a join that failed: its button does for both)
    if (cur !== text && (cur === net.lostShown || !/Rejoin/.test(cur))) netStatus(text, 'bad');
    if ($('netrejoin').hidden) { net.lostButton = true; $('netrejoin').hidden = false; }
    net.lostShown = text;
  } else if (net.lostShown) {
    // over: this line goes, and its button (unless what's there now offers Rejoin itself)
    const mine = cur === net.lostShown, button = net.lostButton;
    net.lostShown = ''; net.lostButton = false;
    if (mine) netStatus('');
    if (button && !net.started && !net.refused && !/Rejoin/.test($('netstatus').textContent)) $('netrejoin').hidden = true;
    if (mine && !net.started) { net.romKey = null; netCheckRom(); }   // (what it says otherwise: "Ready…")
  }
}
// a computer that isn't in the game left
function dropPeer(id) {
  const peer = net.peers.get(id);
  if (!peer) return;
  peer.gone = true;
  try { peer.pc.close(); } catch (e) {}
  net.peers.delete(id);
  net.wentAt.set(id, performance.now());
  if (net.admitting && net.admitting.id === id) net.admitting = null;
  renderPeers();
}
// (not to one that takes nothing: what's queued for it would only grow; a few hundred bytes a
// second is what the game sends there)
const ctlSend = (peer, m) => { if (peer.ctl.readyState === 'open' && !peer.gone && peer.ctl.bufferedAmount < 1 << 20) chSend(peer.ctl, JSON.stringify(m)); };
const ctlMembers = (m) => { for (const id of net.members) { const p = net.peers.get(id); if (p) ctlSend(p, m); } };
const ctlAll = (m) => { for (const peer of net.peers.values()) ctlSend(peer, m); };
function sendHello(peer) {
  const rtts = {};
  for (const [id, p] of net.peers) if (p.rtt !== null && !p.gone && Object.keys(rtts).length < 64) rtts[id] = Math.round(p.rtt);   // (those here: a long game's gone ones would only grow it)
  ctlSend(peer, { t: 'hello', rom: net.rom, bots: net.bots, build: BUILD, rtts, players: net.players, game: net.started && !net.halted });
}
function peerName(id) {
  if (id === net.id) return net.name || 'you';
  if (net.lobbyNames.get(id)) return net.lobbyNames.get(id);
  if (id === net.host) return 'the host';
  return 'guest ' + ([...net.peers.keys()].indexOf(id) + 1);
}
// "P3 (Bob)" during the game
function seatName(s) {
  const who = net.names && net.names[s];
  return 'P' + (s + 1) + (who ? ` (${who})` : '');
}

function onCtl(peer, m) {
  if (peer.gone || net.halted) return;   // (halted: its connections close a moment later)
  // joining: what the game's computers decide before this one runs (a drop, someone leaving or
  // removed, a delay) counts once it runs: its game has those seats from the join poll on
  // (a delay may come before the join that makes this one a member: kept even before an offer)
  if (!net.started && (net.joinOffers.size || m.t === 'delay') && ['drop', 'gone', 'delay', 'kick'].includes(m.t) && !(m.t === 'kick' && m.id === net.id)
    && !(m.t === 'delay' && !(Number.isInteger(m.seat) && m.seat >= 0 && m.seat < 4))) {
    // (a delay replaces that computer's earlier one for the seat; at most 32 kept per computer, so
    // another in the room can't push out the game's own messages; 256 in all: the oldest of the
    // computer with the most goes)
    // (and none of a computer that went: they'd count for nothing once this one runs)
    // (the host removing one no confirmed offer names: at once too, a stranger's own offer can't
    // keep it here)
    if (m.t === 'kick' && peer.id === net.host && typeof m.id === 'string' && !joiningWith(m.id, true)) {
      const k = net.peers.get(m.id);
      net.removedIds.add(m.id);
      // (the one whose offer this page holds: that join ends, and is said to, at once)
      if (k && net.joinOffers.has(m.id)) markGone(k, 'removed by the host');
      else kickPeer(m.id);
    }
    const q = net.preStart = net.preStart.filter((e) => !e.peer.gone && net.peers.get(e.peer.id) === e.peer);
    if (m.t === 'delay') { const i = q.findIndex((e) => e.peer === peer && e.m.t === 'delay' && e.m.seat === m.seat); if (i >= 0) q.splice(i, 1); }
    q.push({ peer, m });
    const its = q.filter((e) => e.peer === peer);
    if (its.length > 32) q.splice(q.indexOf(its[0]), 1);
    if (q.length > 256) {
      const n = new Map(); for (const e of q) n.set(e.peer, (n.get(e.peer) || 0) + 1);
      const most = [...n].sort((a, b) => b[1] - a[1])[0][0];
      q.splice(q.findIndex((e) => e.peer === most), 1);
    }
    return;
  }
  if (m.t === 'hello') {
    peer.hello = {
      rom: typeof m.rom === 'string' && ROMS[m.rom] ? m.rom : null, bots: typeof m.bots === 'string' ? m.bots : null,
      build: String(m.build).slice(0, 40), rtts: m.rtts && typeof m.rtts === 'object' && !Array.isArray(m.rtts) ? Object.fromEntries(Object.entries(m.rtts).filter(([, v]) => typeof v === 'number' && v >= 0 && v <= 10000).slice(0, 64)) : {},
      players: m.players === null || m.players === undefined ? null : Math.min(Math.max(parseInt(m.players, 10) || 0, 0), 4), game: !!m.game,
    };
    // the host's version is the room's (kept if this one is made host later: its version stays)
    if (peer.id === net.host && peer.hello.rom) net.roomRom = peer.hello.rom;
    netCheckRom();
    renderPeers();
  } else if (m.t === 'ping') {
    ctlSend(peer, { t: 'pong', n: Number.isFinite(m.n) ? m.n : 0, at: Number.isFinite(m.at) ? m.at : 0 });   // (numbers only)
  } else if (m.t === 'pong' && typeof m.at === 'number') {
    const rtt = performance.now() - m.at;
    if (rtt >= 0 && rtt < 10000) {
      peer.rtts.push(rtt);
      if (peer.rtts.length > 10) peer.rtts.shift();
      const first = peer.rtt === null;
      peer.rtt = Math.min(...peer.rtts.slice(-5));   // the low end: queueing on a busy moment isn't the network
      // (a new link: the host hears of it at once, not at the next hello; startLineup)
      if (first && !net.started) for (const q of net.peers.values()) sendHello(q);
    }
  } else if (m.t === 'start' && peer.id === net.host && !net.started) {
    netBegin(m);
  } else if (m.t === 'hash' && net.members.has(peer.id) && Number.isInteger(m.poll) && typeof m.h === 'string') {
    peer.hashes.set(m.poll, m.h.slice(0, 16));
    if (peer.hashes.size > NET_HASH_RING) peer.hashes.delete(peer.hashes.keys().next().value);
    checkHash(peer, m.poll);
  } else if (m.t === 'gone' && net.started && net.members.has(peer.id) && typeof m.id === 'string' && m.id !== peer.id && m.have && typeof m.have === 'object') {
    // Another computer lost one. Only the coordinator's word makes it gone here, so another
    // player can't end someone's game or take over: the coordinator checks a report itself
    // (claims). How far the sender has that one's seats goes to the coordinator's choice of
    // the drop poll (decideDrops: never past what the coordinator itself has).
    if (m.id === net.id) {
      if (peer.id === coordinator()) netHalt('The other computers lost the connection to this one.', true);
      else hold(peer, m);
      return;
    }
    const g = net.peers.get(m.id);
    if (!g || !net.members.has(m.id)) return;
    const top = netLoad(NET.POLL) + NET_RING;
    for (const [s, have] of Object.entries(m.have)) {
      if (+s >= 0 && +s < 4 && net.owners[+s] === m.id && Number.isInteger(have) && have >= 0 && have <= top) net.reports[+s].set(peer.id, have);
    }
    // (out: it took that one out for holding up a join: it isn't coming back; admit's held seats)
    if (peer.id === coordinator()) markGone(g, m.out === true ? 'taken out by the coordinator (it is not coming back)' : 'the coordinator lost it');
    else if (coordinator() === net.id) { if (!g.gone) claim(peer.id, m.id); }
    else hold(peer, m);
    decideDrops();
  } else if (m.t === 'drop' && net.started && net.members.has(peer.id) && Number.isInteger(m.seat) && m.seat >= 0 && m.seat < 4 && Number.isInteger(m.at) && m.at >= 0) {
    // only the coordinator decides who gets a bot (another player could put one in anyone's seat)
    if (peer.id === coordinator()) applyDrop(m.seat, m.at);
    else hold(peer, m);
  } else if (m.t === 'early' && net.started && net.members.has(peer.id) && net.owners.some((o, s) => o === peer.id && !net.dropped[s]) && Number.isInteger(m.seat) && net.owners[m.seat] === net.id && typeof m.min === 'number') {
    net.earlyReports[m.seat].set(peer.id, { min: Math.min(Math.max(m.min, -1), 60), at: performance.now() });
  } else if (m.t === 'delay' && net.started && Number.isInteger(m.seat) && m.seat >= 0 && m.seat < 4 && net.owners[m.seat] === peer.id && Number.isInteger(m.d)) {
    net.sdelay[m.seat] = Math.min(Math.max(m.d, 1), 60);
  } else if (m.t === 'join' && typeof m.id === 'string' && Number.isInteger(m.at) && m.at >= 0) {
    if (m.id === net.id) { if (!net.started && !net.joinInfo) onJoinMe(peer, m); }
    else if (net.started && net.members.has(peer.id) && peer.id !== coordinator()) hold(peer, m);
    else if (net.started && net.members.has(peer.id) && joinTakesFreeSeats(m)) {
      applyJoin(m, false, peer.id);
      ctlSend(peer, { t: 'joinok', at: m.at });
      // and to the newcomer: it takes a join only once every computer in the game confirmed it,
      // and only from the coordinator that sent it (another member knows X too, and could send
      // a join of its own making first)
      const newcomer = net.peers.get(m.id);
      if (newcomer) ctlSend(newcomer, { t: 'joinack', at: m.at, from: peer.id });
    }
  } else if (m.t === 'joinack' && !net.started && Number.isInteger(m.at) && typeof m.from === 'string') {
    net.joinAcks.set(peer.id, { at: m.at, from: m.from });
    showJoining();
    for (const id of net.joinOffers.keys()) { const p = net.peers.get(id); if (p) stateArrived(p); }
  } else if (m.t === 'desync' && net.started && net.members.has(peer.id) && playsNow(peer.id)) {
    // (from a player only: a watcher out of sync is out of the game alone (checkHash), and a
    // stranger watching a public game mustn't pause it every 10 s)
    startResync();
  } else if (m.t === 'resync' && net.started && net.members.has(peer.id) && Number.isInteger(m.at) && Number.isInteger(m.seed)) {
    // only the coordinator starts a resync (another player can't make this one load its state)
    if (peer.id === coordinator()) applyResync(peer, m);
    else hold(peer, m);
  } else if (m.t === 'joinok' && net.admitting && m.at === net.admitting.at) {
    net.admitting.ok.add(peer.id);
  } else if (m.t === 'kick' && peer.id === net.host && typeof m.id === 'string' && (!net.started || net.members.has(peer.id))) {
    // (in a game, only from a host in it: the lobby can make one outside it host, a stranger
    // when all of the game's computers are out of the lobby)
    if (m.id === net.id) netRemoved();
    else kickPeer(m.id);
  } else if (m.t === 'noreach' && Array.isArray(m.ids) && peer.hello && peer.hello.game && gameSaid()) {
    // not let in: it has no direct connection to some of the game's computers (no relay)
    // (or that computer lost its lobby connection: then nobody new can connect to it. One this
    // page's lobby never named had lost it before this page came; one whose dead connection
    // lingers there looks like the first kind: hence "may")
    const ids = m.ids.filter((id) => typeof id === 'string' && id !== net.id).slice(0, 4);
    const far = ids.filter((id) => net.lobbyNames.has(id) && !net.lobbyLeft.has(id)).map(peerName);
    const away = ids.filter((id) => net.lobbyNames.has(id) && net.lobbyLeft.has(id)).map(peerName);
    const unknown = ids.some((id) => !net.lobbyNames.has(id));
    const why = [far.length ? `this computer can't connect directly to ${far.join(', ')}'s computer (one of your networks may not allow it, or that computer lost its connection to the lobby server)` : '',
      away.length ? `${away.join(', ')}'s computer lost its connection to the lobby server, so it can't connect to new computers` : '',
      unknown ? "a computer in the game lost its connection to the lobby server, so it can't connect to new computers" : ''].filter(Boolean).join('; ');
    if (!net.started && !net.joinOffers.size && ids.length) netStatus(`Can't join yet: ${why}. You'll join if that changes, or once they leave.`, 'bad');
  } else if (m.t === 'seatwait' && peer.hello && peer.hello.game && gameSaid()) {
    // not let in yet: a seat it needs is held for a player who just dropped out
    if (!net.started && !net.joinOffers.size && net.players) netStatus('A game is in progress: waiting for a seat (one is kept for a player who just dropped out, in case they come back; 30 s at most)…', 'ok');
  } else if (m.t === 'split') {
    // it stopped for a network split (checkSplit): lost, on the other side, even though its
    // lobby connection closes too (that's not a page that closed)
    peer.splitHalt = true;
    markGone(peer, 'connection given up: it stopped for a split');
  } else if (m.t === 'bye') {
    // (leave: its player pressed Leave; otherwise its page closed or reloaded: its seat is held a while)
    if (m.leave === true) peer.leftForGood = true;
    markGone(peer, 'left the game');   // (not in a game: it just goes)
  }
}
// pings (round trip on the reliable channel, which is about the same as the input channel's),
// hellos, computers that went quiet during the game, drops, joins, delays
setInterval(() => {
  const now = performance.now();
  for (const peer of net.peers.values()) {
    ctlSend(peer, { t: 'ping', n: ++peer.pingN, at: now });
    if (net.started && !peer.gone && net.members.has(peer.id) && now - peer.lastHeard > NET_GONE_MS) markGone(peer, 'nothing heard for ' + NET_GONE_MS / 1000 + ' s');
    // one that left the game a while ago: its connection is closed (the row stays, for the seats
    // and checkSplit; nothing is sent to it once it's gone; 45 s: past every wait that looks at
    // when it went, and past checkInput's 40 s, so one that only this computer lost isn't told
    // "closed" before this one stops by itself). Else each computer that came and went
    // would leave one open here, and a browser makes only so many (someone joining and leaving a
    // public game over and over)
    if (peer.gone && peer.goneAt && !peer.pcClosed && now - peer.goneAt > 45000) { peer.pcClosed = true; try { peer.pc.close(); } catch (e) {} }
    if (!net.started || !net.members.has(peer.id)) sendHello(peer);
  }
  if (!net.started) renderPeers();
  for (const [id, t] of net.wentAt) if (now - t > 5000) net.wentAt.delete(id);   // (lobbyOnly looks back 5 s)
  checkLostLinks();
  // a join that doesn't complete (the game moved on without this one): say so, offer another try
  // (first: what an expired offer kept goes in the same pass)
  // (an offer goes 70 s after it with no piece of its state yet (the coordinator sends it once
  // its game passes the join's poll: 60 s at most), 30 s after the last piece, 2 min at most)
  let expired = false;
  for (const [id, o] of net.joinOffers) {
    const t = performance.now();
    if ((o.piece ? t - o.last > 30000 : t - o.first > 70000) || t - o.first > 120000) { net.joinOffers.delete(id); expired = true; }
  }
  // (unless a join the host confirmed still comes: another's offer can't hide that one)
  if (!net.started && expired && ![...net.joinOffers.values()].some(joinConfirmed)) {
    net.joinSince = 0;
    netStatus("Couldn't join the game in progress. Rejoin to try again.", 'bad');
    $('netrejoin').hidden = false; net.lostButton = false;   // (this line's button now, not checkLostLinks' to hide)
  }
  // the host, in a game: its panel lists those in the room but not in it (Remove): drawn again
  // when they change
  if (net.started && amHost()) {
    const key = [...net.peers].filter(([id, p]) => !net.members.has(id) && !p.gone).map(([id]) => id).concat(lobbyOnly()).join(' ');
    if (key !== net.roomKey) { net.roomKey = key; renderPlayers(); }
  }
  // a computer out of the lobby that only an offer kept here (as the lobby's 'left' does, once no
  // offer names it: one that went nowhere can't keep a crowd of them)
  for (const id of [...net.peers.keys()]) {
    if (net.lobbyLeft.has(id) && !net.members.has(id) && !(!net.started && joiningWith(id))) dropPeer(id);
  }
  // a state that stopped coming (30 s without a piece), or, joining, one whole with no offer to
  // go with for 30 s: what came of it goes
  for (const p of net.peers.values()) {
    if (p.stRx && (!p.stRx.done || !(net.started ? p.id === net.resyncFrom : net.joinOffers.has(p.id))) && performance.now() - p.stRx.t > 30000) p.stRx = null;
  }
  // the host's page reloaded: it takes the game's version again once the emulator is loaded (it
  // may have heard 'joined' before that, and with no guests nothing else asks again)
  if (!net.started && ready && amHost() && !net.rom) netCheckRom();
  netSendInfo();
  if (!net.started || !ready) return;
  // the core stopped: it couldn't start from the state it was given (joining, or getting back in
  // sync), or it missed an event
  if (!net.halted && netLoad(NET.ACTIVE) === 3) {
    const why = netLoad(NET.STOPPED);
    netHalt(why === 2 ? 'This computer missed a step of the game (someone joining, or getting back in sync) and fell out of step.'
      : why === 3 ? "The game's state (to get back in sync) didn't load on this computer."
      : "The game's state didn't load on this computer.", true);
  }
  // watching, and out of step with the game (checkHash)
  if (!net.halted && net.watchDesync) {
    const now = performance.now();
    if (net.watchDesync.differ) net.watchDesync.since = now;   // (the players differ: their resync comes)
    if (now - net.watchDesync.since > 15000 || now - net.watchDesync.first > 60000) {
      netHalt('This computer fell out of step with the game it was watching (the game goes on for the players).', true);
    } else if ($('netwarn').textContent !== WATCH_NOTE) {
      // (again: another note, a waiting one say, mustn't hide it for good)
      netWarn(WATCH_NOTE, 'warn');
      net.waitingShown = false;
    }
  }
  decideDrops();
  checkJoiners();
  checkSplit();
  checkClaims();
  checkInput();
  admit();
  adaptDelay();
}, 1000);

// those the lobby has in the room with no live connection here (gone, or never made): each takes
// a place in the room all the same, and only the host can free it (Remove). Not one that went
// or was removed in the last 5 s (it said goodbye, was cut off or taken out: the lobby's 'left'
// for its page comes a moment later; if none comes, its page is still there and it shows)
const lobbyOnly = () => !net.ws || net.ws.readyState !== 1 ? [] : [...net.lobbyNames.keys()].filter((id) => {
  const p = net.peers.get(id), now = performance.now();
  if (id === net.id || net.lobbyLeft.has(id) || (p && !p.gone)) return false;
  return !(now - (net.wentAt.get(id) || -1e9) < 5000 || (p && p.goneAt && now - p.goneAt < 5000));
});
function renderPeers() {
  const list = $('netpeers');
  if (!net.role) { list.replaceChildren(); net.peersKey = ''; return; }
  const ver = gameRom();
  $('netver').replaceChildren(...(ver ? ['Game version: ', el('b', '', ROMS[ver].name)] : ["Game version: the host's choice"]));
  // the host's choice for the whole game (a guest hears it at the start)
  if (!net.started) $('botgodrow').hidden = !amHost() && net.role !== 'host';
  const rows = [];
  const row = (who, players, state, rtt, id) => {
    // (players undefined: it hasn't said yet; null: the state says it's choosing)
    const count = players === undefined ? '' : players === null ? (state.startsWith('choosing how many') ? '' : 'choosing how many play') : players ? players + ' player' + (players > 1 ? 's' : '') : 'watching';
    rows.push({ who, text: ' · ' + [count, state, rtt].filter(Boolean).join(' · '), id: id && amHost() ? id : '' });
  };
  row((net.name || 'You') + (amHost() ? ' (you, host)' : ' (you)'), net.players, net.rom ? ROMS[net.rom].name + ' ROM, ready' : 'choose your ROM', '');
  // (the host's lineup: only the host knows it)
  const unlinked = !net.started && amHost() ? startLineup().unlinked : new Map();
  for (const [id, p] of net.peers) {
    const why = notReady(id, p);
    const not = unlinked.get(id);
    const state = p.ctl.readyState !== 'open' ? 'connecting…'
      : !p.hello ? 'connected'
      : p.hello.game ? 'in the game'
      : why ? why
      : not ? `not connected to ${not.map(peerName).join(', ')}'s computer (yet?), so it joins after the start once it is`
      : ROMS[p.hello.rom].name + ' ROM, ready';
    row(peerName(id) + (id === net.host ? ' (host)' : ''), p.hello ? p.hello.players : undefined, state, p.rtt !== null ? `${Math.round(p.rtt)} ms` : '', id);
  }
  for (const id of lobbyOnly()) if (!net.peers.has(id)) row(peerName(id) + (id === net.host ? ' (host)' : ''), undefined, 'in the room, not connected to this computer', '', id);
  // the same rows and buttons as shown: only their text changes (a ping every second)
  const key = rows.map((r) => r.who + '|' + r.id).join('\n');
  if (key === net.peersKey && list.children.length === rows.length) {
    rows.forEach((r, i) => { const span = list.children[i].querySelector('span'); if (span.textContent !== r.text) span.textContent = r.text; });
  } else {
    net.peersKey = key;
    list.replaceChildren();
    for (const r of rows) {
      const d = el('div', 'netpeer');
      d.append(el('b', '', r.who), el('span', '', r.text));
      if (r.id) {
        const b = el('button', 'small', 'Remove');
        b.title = 'Take this computer out of the game; it cannot come back in';
        b.onclick = () => netKick(r.id);
        d.appendChild(b);
      }
      list.appendChild(d);
    }
  }
  const host = amHost() && !net.started && !gameHere();
  $('nethostonly').hidden = !host;
  if (host) {
    const why = startProblems();
    const out = [...net.peers].filter(([id, p]) => notReady(id, p)).map(([id]) => peerName(id));
    const lineup = startLineup();
    const left = lineup.left.filter((id) => !lineup.unlinked.has(id)).map(peerName);
    const apart = [...lineup.unlinked.keys()].map(peerName);
    $('netstart').disabled = why.length > 0;
    $('netstart').title = why.join('; ');
    $('netwhy').textContent = (why.length && net.rom ? 'Waiting: ' + why.join('; ') + '.'
      : !net.rom ? ''
      : out.length ? `Not ready yet: ${out.join(', ')}. Start now and they join the game once ready, or wait for them.`
      : !net.peers.size ? `Send the link to the other players${net.public ? '' : ', or tick Public game so anyone can join'}. Or Start now: they can join later.`
      : apart.length ? '' : "Everyone's ready.") + (left.length && net.rom ? ` More than four players: ${left.join(', ')} ${left.length > 1 ? "don't" : "doesn't"} fit, and join${left.length > 1 ? '' : 's'} with the seats left over once the game runs (or watch${left.length > 1 ? '' : 'es'}).` : '')
      + (apart.length && net.rom ? ` Not connected to every other player's computer yet: ${apart.join(', ')} (see the list). Start now and they join once connected, if their networks allow it, or wait a moment.` : '');
    $('netwhy').textContent = $('netwhy').textContent.trim();
    $('netwhy').className = 'netwhy' + (why.length || out.length || apart.length ? '' : ' ok');
  } else $('netwhy').textContent = '';
}

// ---------- start ----------
// the ROM chosen (useRom calls this instead of starting, until the online game starts)
// The game's version: the host's choice (the one whose ROM is in the game, once it runs). Every
// computer needs the same one, so a guest is only offered that version, and chooses its ROM
// again if the host changes it.
function gameRom() {
  if (net.started) return net.rom;
  // (a guest made host by the lobby keeps the room's version until it chooses its ROM)
  if (amHost() || (net.role === 'host' && !net.id)) return net.rom || net.roomRom || null;
  // the lobby's host (the lobby server says who): it's in any game that runs
  const host = net.peers.get(net.host);
  if (host && host.hello && host.hello.rom) return host.hello.rom;
  return net.roomRom || null;
}
// may this computer use that version now (the ROM buttons and drop box offer only those)
// (a guest made host too: the game's version stays the room's)
const netRomAllowed = (hash) => net.role !== 'guest' || net.started || !gameRom() || hash === gameRom();
// what keeps a guest from any game here, whatever else it does (a line that stays, where
// netCheckRom would say "Ready. Waiting for the host…"): no lobby, or no way to the host's computer
const noHostText = () => `Couldn't connect to the host's computer (${peerName(net.host)}): one of your networks doesn't allow a direct connection. Another network (a phone's hotspot, say) may work.`;
function netBlocked() {
  if (net.lobbyLost) return net.lobbyLost;
  if (net.noHost && net.noHost === net.host && !net.peers.has(net.host) && net.lobbyNames.has(net.host) && !net.lobbyLeft.has(net.host)) return noHostText();
  return '';
}
// a guest: follow the game's version (drop a ROM of another one, take the saved one), and say
// what it needs; only when something changed
function netCheckRom() {
  if (net.started) return;
  // host now (the host left the lobby, or this is the host's page reloaded): the room's version,
  // if this browser has it
  if (amHost()) {
    const want = gameRom();
    if (!net.rom && want && savedRoms[want] && net.romTaking !== want) {
      net.romTaking = want;
      useRom(new Uint8Array(savedRoms[want]), false).finally(() => { net.romTaking = null; });
    }
    return;
  }
  if (net.role !== 'guest') return;
  const want = gameRom(), inGame = gameSaid() && [...net.peers.values()].some((p) => p.hello && p.hello.game);
  // a page of another version can't play with this one (it would wait forever): say so
  const hostPeer = net.peers.get(net.host);
  const otherPage = !!(hostPeer && hostPeer.hello && net.bots && (hostPeer.hello.build !== BUILD || hostPeer.hello.bots !== net.bots));
  if (want && net.rom && net.rom !== want) {
    net.rom = null; net.romBytes = null;
    for (const peer of net.peers.values()) sendHello(peer);
  }
  if (want && !net.rom && savedRoms[want] && net.romTaking !== want) {
    net.romTaking = want;
    useRom(new Uint8Array(savedRoms[want]), false).finally(() => { net.romTaking = null; });
  }
  const key = [want, net.rom, inGame, net.players, otherPage].join('|');
  if (key === net.romKey) return;
  net.romKey = key;
  const name = want && ROMS[want].name;
  netDropBox(want);
  showSaved();
  status('');   // the start screen's own line ("Choose your ROM to start") doesn't apply here
  if (net.joinInfo || net.refused) return;   // (refused: the lobby's reason stays shown)
  const blocked = netBlocked();
  if (blocked) { netStatus(blocked, 'bad'); return; }
  if (otherPage) netStatus("The host has a different version of this page. Reload this page; if that doesn't help, the host should reload theirs.", 'bad');
  else if (!want) netStatus("Waiting for the host to choose the game's version…", 'ok');
  else if (!net.rom) netStatus('');   // the drop box says which ROM
  else if (net.players === null) netStatus(`Choose how many play at this computer (Players here), or 0 to watch, to ${inGame ? 'join the game' : 'be ready'}.`, 'warn');
  else if (inGame) netStatus('A game is in progress: joining it…', 'ok');
  else netStatus('Ready. Waiting for the host to start the game.', 'ok');
}
// the drop box for a guest: the game's version only (want), or any (null)
function netDropBox(want) {
  const name = want && ROMS[want].name;
  $('droptitle').textContent = want ? `Drop your ${name} ROM here` : 'Drop your ROM here';
  $('dropsub').textContent = want ? `This game uses the ${name} version of Turtles in Time (other versions can't play together), .sfc / .smc`
    : 'Teenage Mutant Ninja Turtles IV: Turtles in Time (USA, Europe, Australia or Japan), .sfc / .smc';
  $('dropwhy').hidden = true;
}
async function netRomChosen(hash, bytes) {
  if (hash === net.rom) return;
  if (net.choosing) {
    // the host's version: now the game is made with it
    net.choosing = false;
    net.rom = hash; net.romBytes = bytes;
    $('nethostpick').hidden = true;
    netShowLobby('host');
    try { await netInit(); await netConnect(); sig({ t: 'create', public: net.public, token: nameToken() }); netStatus('Connecting to the lobby…'); }
    catch (e) { netStatus('Online play unavailable: ' + e.message, 'bad'); }
    return;
  }
  if (net.rom && !net.started && (amHost() || net.role === 'host')) {
    netNote(`This game is set to the ${ROMS[net.rom].name} version. Leave it to host one with another version.`);
    return;
  }
  const want = gameRom();
  if (net.role === 'guest' && !net.started && want && hash !== want) {
    netStatus(`That's the ${ROMS[hash].name} version, but this game uses the ${ROMS[want].name} version. Choose your ${ROMS[want].name} ROM (other versions can't play together).`, 'bad');
    return;
  }
  net.rom = hash; net.romBytes = bytes;
  for (const peer of net.peers.values()) sendHello(peer);
  showSaved();   // the mark moves to this version
  renderPeers();
  if (amHost()) netStatus('');   // the line under Start says what's next
  else { net.romKey = null; netCheckRom(); }   // what's next for a guest
}
// why a guest can't play yet ('' = ready): it is left out of the start then, and joins the
// game once it is ready (as anyone joining mid-game), so nobody can hold the others up
function notReady(id, p) {
  if (p.ctl.readyState !== 'open' || !p.hello) return 'still connecting';
  if (!p.hello.rom) return net.rom ? `needs the ${ROMS[net.rom].name} ROM` : 'choosing a ROM';
  if (net.rom && p.hello.rom !== net.rom) return `needs the ${ROMS[net.rom].name} ROM`;
  if (p.hello.build !== BUILD || p.hello.bots !== net.bots) return 'has a different version of this page (reload)';
  if (p.hello.players === null) return 'choosing how many play there';
  return '';
}
const readyPeers = () => [...net.peers].filter(([id, p]) => !notReady(id, p));
// what stops the host from starting
// who starts the game: the host's players, then each ready guest's, in the order they joined, as
// long as they fit in the four seats; one that doesn't joins the game once it runs (the seats left
// over, or it watches), so nobody can keep the others from starting
// (and each one connected to all the others seated: two guests whose networks don't allow a
// direct connection between them would each wait for the other's input from the first frame)
const linked = (a, b) => { const p = net.peers.get(a), q = net.peers.get(b); return !!(p && q && p.hello && q.hello && b in p.hello.rtts && a in q.hello.rtts); };
function startLineup() {
  const seated = [[net.id, net.players || 0]], left = [], unlinked = new Map();
  let players = net.players || 0;
  // (players before watchers: one that watches and can't reach a player is the one left out)
  for (const [id, p] of readyPeers().sort((a, b) => (b[1].hello.players > 0) - (a[1].hello.players > 0))) {
    const not = seated.slice(1).map(([sid]) => sid).filter((sid) => !linked(id, sid));
    if (not.length) { unlinked.set(id, not); left.push(id); continue; }
    if (players + p.hello.players <= 4) { seated.push([id, p.hello.players]); players += p.hello.players; } else left.push(id);
  }
  return { seated, left, players, unlinked };
}
function startProblems() {
  const problems = [];
  if (!net.rom) problems.push('choose the ROM for this game');
  if (net.players === null) problems.push('choose how many play at this computer (Players here)');
  if (!startLineup().players) problems.push('nobody plays');
  return problems;
}
function netStartGame() {
  if (net.started || startProblems().length) return;   // (a second click: the game has started)
  // seats: the host's players, then each ready guest's, in the order they joined
  const owners = [], names = [];
  const everyone = startLineup().seated;
  const ready = everyone.slice(1).map(([pid]) => [pid, net.peers.get(pid)]);
  for (const [id, n] of everyone) {
    for (let k = 0; k < n; k++) { owners.push(id); names.push(peerName(id) + (n > 1 ? ' ' + (k + 1) : '')); }
  }
  while (owners.length < 4) { owners.push(null); names.push(''); }
  const fill = $('netbots').checked ? 'b' : '-';
  // P1 always plays (the game needs P1); an empty P2 is fine in a "1 PLAYER" game
  const seats = owners.map((o, s) => (o ? 'h' : s === 0 ? 'b' : fill));
  // input delay to begin with: half the slowest round trip between any two computers, plus a
  // frame for the frame pacing and a frame of spare; then each computer adapts its own
  // (?delay=N: fixed)
  // (between those that play: a watcher's link doesn't slow the players)
  let worst = 0;
  const plays = new Set(ready.filter(([, p]) => p && p.hello && p.hello.players > 0).map(([id]) => id));
  if (net.players > 0) plays.add(net.id);   // (ready is the guests: this one, the host, apart)
  for (const [id, p] of ready) {
    if (!plays.has(id)) continue;
    if (plays.has(net.id)) worst = Math.max(worst, p.rtt || 0);
    for (const [k, v] of Object.entries(p.hello.rtts)) if (plays.has(k)) worst = Math.max(worst, v);
  }
  const frameMs = 1000 / ROMS[net.rom].fps;
  let delay = Math.min(15, Math.max(2, Math.ceil(worst / 2 / frameMs) + 2));
  const asked = parseInt(NET_Q.get('delay'), 10);
  if (asked >= 1 && asked <= 30) delay = asked;
  const start = {
    t: 'start', rom: net.rom, seed: crypto.getRandomValues(new Uint32Array(1))[0], delay, fixed: asked >= 1 && asked <= 30,
    seats: seats.join(''), owners, names, god: botGod, members: everyone.map(([id]) => id),
  };
  for (const [, p] of ready) ctlSend(p, start);   // the others join once they are ready
  netBegin(start);
}
function validStart(m) {
  return /^[hb-]{4}$/.test(String(m.seats)) && Array.isArray(m.owners) && m.owners.length === 4 && Number.isInteger(m.seed) && Number.isInteger(m.delay);
}
// everything both ways of starting share (the game's start, or joining it mid-way)
function netSetUp(m, delays) {
  net.started = true;
  net.seats = String(m.seats);
  net.owners = m.owners.map((o) => (typeof o === 'string' ? o : null));
  net.names = Array.isArray(m.names) ? [0, 1, 2, 3].map((s) => knownName(m.names[s])) : ['', '', '', ''];
  net.delay = Math.min(Math.max(m.delay, 1), 60);
  net.sdelay = delays || [net.delay, net.delay, net.delay, net.delay];
  net.fixedDelay = !!m.fixed;
  net.mine = [0, 1, 2, 3].filter((s) => net.owners[s] === net.id);
  for (const id of Array.isArray(m.members) ? m.members : []) if (typeof id === 'string' && id !== net.id && net.peers.has(id)) net.members.add(id);
  for (const o of net.owners) if (o && o !== net.id) net.members.add(o);
  // (heard from now on: a link still coming up isn't one long silent)
  for (const id of net.members) { const p = net.peers.get(id); if (p) p.lastHeard = performance.now(); }
  // the start: seat order (the host first); joining: the coordinator's order, which ends with this one
  net.order = [];
  for (const id of Array.isArray(m.order) ? m.order.slice(0, 64) : net.owners) if (typeof id === 'string' && !net.order.includes(id)) net.order.push(id);
  for (const o of net.owners) if (o && !net.order.includes(o)) net.order.push(o);
  if (!net.order.includes(net.id)) net.order.push(net.id);
  net.everPerson = [0, 1, 2, 3].map((s) => net.seats[s] === 'h');
  let local = 0, human = 0;
  for (let s = 0; s < 4; s++) {
    if (net.seats[s] === 'h') human |= 1 << s;
    if (net.owners[s] === net.id) local |= 1 << s;
  }
  // this computer's players go to its seats: the device on local player k plays our k-th seat
  for (const dev of Object.keys(assign)) {
    const k = assign[dev];
    assign[dev] = !net.mine.length ? -1 : k >= 0 && k < net.mine.length ? net.mine[k] : net.mine.length === 1 ? net.mine[0] : -1;
  }
  botGod = !!m.god;
  $('botgod').checked = botGod;
  $('botgodrow').hidden = true;   // set for the whole game: only said when it's on
  $('botgodnote').hidden = !botGod;
  let packed = 0;
  for (let s = 0; s < 4; s++) packed |= net.seats.charCodeAt(s) << (s * 8);
  Module._web_seats(packed >>> 0, botGod ? 1 : 0);
  Module._web_net(net.delay, local, human);
  for (const s of net.mine) Atomics.store(H32(), netWord(NET.SEAT_DELAY + s), net.sdelay[s]);
  document.querySelector('.panel').classList.add('locked');
  netStatus('');
  $('netinfo').hidden = false;
  $('netleave').hidden = false;
  $('playlog2').hidden = true;   // would leave the online game
  $('netrejoin').hidden = true;   // (a join that took long may have offered it)
  renderPlayers();
}
function netBegin(m) {
  if (!validStart(m)) { netStatus('The host sent a start this page does not understand.', 'bad'); return; }
  if (m.rom !== net.rom) {
    netStatus(`The host started with the ${ROMS[m.rom] ? ROMS[m.rom].name : 'unknown'} version: choose that ROM (reload to try again).`, 'bad');
    return;
  }
  net.seed = m.seed >>> 0;
  netSetUp(m);
  // a seat's delay a computer that started first sent before this one did (kept: preStart)
  const early = net.preStart.filter((e) => e.m.t === 'delay');
  net.preStart = [];
  for (const e of early) onCtl(e.peer, e.m);
  // the host: the lobby hears at once that the game runs, and who's in it (should this page go
  // now, the host's role must go to one of them, not wait for this page's reload)
  netSendInfo();
  // Players here changed just as the host started: the host started with what it had heard
  if (net.players !== null && net.players !== net.mine.length) {
    netWarn(`The game started before your change to Players here reached the host: ${net.mine.length ? net.mine.map(seatName).join(', ') + (net.mine.length > 1 ? ' are' : ' is') + ' played here' : 'you are watching'}. To change that, click Leave game, then open the game's link again.`, 'warn');
  }
  net.go = true;
  useRom(net.romBytes, false);
  netLocalLoop();
}
// a free seat of ours for a device that just appeared (nextFreePlayer in app.js)
function netFreeSeat() {
  for (const s of net.mine) if (!deviceOn(s)) return s;
  return net.mine.length === 1 ? net.mine[0] : -1;
}

// ---------- joining a game in progress ----------
// is seat s played by a person now
const personNow = (s) => !!(net.owners[s] && !net.dropped[s]);
// does that computer play a seat now (not one that only watches)
const playsNow = (id) => !!net.owners && net.owners.some((o, s) => o === id && !net.dropped[s]);
// The coordinator lets in one computer at a time: one that has said hello with the game's ROM
// and page, isn't in the game, and is connected to every member (else it couldn't get their
// input). It gets free seats: its old ones if its name matches a player who left, then bots'
// and empty ones (none left: it watches). X = how far the coordinator's own input goes: no
// computer can be past it.
function admit() {
  if (net.halted) return;
  const a = net.admitting;
  if (a) {
    // done once the state went out and every member confirmed: for a join the newcomer too, once
    // it runs; for a resync each member once it loaded the state. Only then the next event (a
    // newcomer that isn't running yet couldn't follow a second join; a member still loading
    // would mix two events)
    const waiting = [...net.members].filter((id) => net.peers.has(id) && !net.peers.get(id).gone && !a.ok.has(id));
    // 20 s from when the state went out (the coordinator may first have to take out a computer
    // that holds it up before X); 60 s at most in all. A resync and a watcher: 90 s (one far
    // behind confirms only once it reaches X; it holds nobody up meanwhile)
    const plays = (id) => net.owners.some((o, s) => o === id && !net.dropped[s]);
    const limit = a.kind === 'resync' && waiting.every((id) => !plays(id)) ? 90000 : 20000;
    if (a.sent && !waiting.length) net.admitting = null;
    else if (performance.now() - (a.sentAt || a.since) > (a.sentAt ? limit : 60000)) {
      // a member that didn't confirm would play on without the newcomer (or the resync): it goes
      console.warn('online: admitting', a.id, 'timed out; not confirmed by', waiting);
      net.admitting = null;
      for (const id of waiting) { const p = net.peers.get(id); ctlSend(p, { t: 'gone', id, have: {} }); markGone(p, 'did not confirm a join'); }
    }
    return;
  }
  if (!netRunning() || net.halted || coordinator() !== net.id || !net.mine.length || net.events.length || eventBusy() || newcomerWaiting()) return;
  // nor while a seat change waits for this core (applySeatChanges): a join's change must be in it
  // before it reaches X, and nothing else may hold it there
  if (net.seatQ.length) return;
  // nor while it may be about to stop for a split (checkSplit): one let in would stop with it
  if ([...net.peers.values()].some((p) => p.gone && p.lost && net.members.has(p.id) && performance.now() - p.goneAt < 6000)) return;
  // not while a seat's player is gone but its seat isn't a bot yet: that seat isn't free yet (one
  // that crashed and came straight back would get another), and a newcomer wouldn't know the
  // computer that left
  if ([0, 1, 2, 3].some((s) => net.owners[s] && net.owners[s] !== net.id && !net.dropped[s] && (!net.peers.has(net.owners[s]) || net.peers.get(net.owners[s]).gone))) return;
  // nor, for 10 s after a drop, while a member still lacks the input of the player who left, up
  // to their drop (it's being passed on to it): a join gives that seat a new owner, and nobody
  // would pass the rest on then. (Not for ever: one that joined after the drop never has it, nor
  // needs it)
  const live = [...net.members].map((id) => net.peers.get(id)).filter((p) => p && !p.gone && !(p.joinBy && !p.sending));
  if ([0, 1, 2, 3].some((s) => net.dropped[s] && performance.now() - net.droppedAt[s] < 10000 && net.owners[s] !== net.id && sendsSeat(s) &&
    live.some((p) => p.acked[s] < net.dropped[s]))) return;
  for (const [id, p] of net.peers) {
    if (net.members.has(id) || p.gone || !p.hello || p.hello.rom !== net.rom || p.hello.build !== BUILD || p.hello.bots !== net.bots || p.hello.players === null) { p.eligibleSince = 0; continue; }
    if (p.ctl.readyState !== 'open' || p.st.readyState !== 'open') continue;
    // it must reach every member that plays: they say hello to it too, so it knows their round
    // trips. (One that can't, 20 s on: it's told which, once; it gets in if that one leaves.) Not
    // the watchers: one mustn't keep a player out, and the newcomer's word mustn't take one out;
    // a watcher that really can't reach it stops (the stuck check: Rejoin)
    // (and the lobby's host, watching or not: a join counts once the host confirms it to the newcomer)
    // (watchers too for its first 15 s: a link that's slow to come up mustn't cost the watcher)
    // (from when this one could be let in, or the watcher came, whichever is later)
    p.eligibleSince = p.eligibleSince || performance.now();
    const watchersToo = (mid) => performance.now() - Math.max(p.eligibleSince, net.peers.get(mid).joinedAt || 0) < 15000;
    const unreached = [...net.members].filter((mid) => net.peers.has(mid) && (net.owners.includes(mid) || mid === net.host || watchersToo(mid)) && !net.peers.get(mid).gone && !(mid in p.hello.rtts));
    // (counted for the same computers: one let in meanwhile gets its own 20 s)
    const key = unreached.join(' ');
    if (key !== p.reachKey) { p.reachKey = key; p.reachWait = performance.now(); p.reachSaid = false; }
    if (unreached.length) {
      if (!p.reachSaid && performance.now() - p.reachWait > 20000) { p.reachSaid = true; ctlSend(p, { t: 'noreach', ids: unreached.slice(0, 4) }); }
      continue;
    }
    // Its name is on a seat whose computer still seems to be here: this browser's last page (a
    // reload, or a crash the others haven't noticed yet, NET_GONE_MS). Wait for that one to go,
    // so this one gets its seats back; 15 s at most.
    const name = net.lobbyNames.get(id);
    const base = (s) => (net.names[s] || '').replace(/ [1-4]$/, '');
    if (name && [0, 1, 2, 3].some((s) => personNow(s) && net.owners[s] !== id && base(s) === name)) {
      if (!p.admitWait) p.admitWait = performance.now();
      if (performance.now() - p.admitWait < 15000) continue;
    }
    // free seats: its own (by name), then bots' and empty ones nobody played, then those of other
    // players who left (kept for them, in case they come back), longest gone first. A seat whose
    // player was lost or whose page closed (not Leave) in the last 30 s is held for them: it is
    // likely coming back (a reload, Rejoin). One that needs it waits for it.
    const now = performance.now();
    const free = [0, 1, 2, 3].filter((s) => !personNow(s));
    // (not one the host removed: back from elsewhere under its name, it isn't given its seat
    // first; one the coordinator took out (stalled) is told its seat is kept, and it is)
    const mineByName = (s) => net.dropped[s] && name && base(s) === name && !net.removedIds.has(net.owners[s]);
    const held = (s) => {
      if (!net.everPerson[s] || !net.dropped[s] || mineByName(s) || now - net.droppedAt[s] >= 30000) return false;
      const o = net.peers.get(net.owners[s]);
      // (not one that pressed Leave, or was removed or taken out: it isn't coming back to it)
      return !(o && (o.leftForGood || o.takenOut));
    };
    const rank = (s) => (mineByName(s) ? 0 : !net.everPerson[s] ? 1 : held(s) ? 3 : 2);
    free.sort((x, y) => rank(x) - rank(y) || (rank(x) === 2 ? (net.droppedAt[x] || 0) - (net.droppedAt[y] || 0) : 0) || x - y);
    if (free.some(held) && free.filter((s) => !held(s)).length < p.hello.players) {
      if (!p.seatWaitSaid) { p.seatWaitSaid = true; ctlSend(p, { t: 'seatwait' }); }   // (it would see only "joining…")
      continue;
    }
    p.seatWaitSaid = false;   // (a later wait for a held seat is told again)
    const seats = free.slice(0, p.hello.players).sort((x, y) => x - y);
    // (not before this core is past each seat's last change: a join waits for that here
    // (applySeatChanges), and this core, with only its own input to wait for, could reach X first)
    if (seats.some((s) => netLoad(NET.POLL) < net.seatAt[s])) return;   // (the next tick: in join order)
    // X: past every drop already decided, so at X every computer's core has made those seats bots
    // (the roles below say so: the newcomer starts there with them)
    const at = Math.max(...net.mine.map((s) => netLoad(NET.HAVE + s)), netLoad(NET.POLL) + 1, ...net.dropped.map((d) => d + 1));
    const names = net.names.slice(), owners = net.owners.slice();
    seats.forEach((s, k) => { names[s] = peerName(id) + (seats.length > 1 ? ' ' + (k + 1) : ''); owners[s] = id; });
    const delay = Math.min(15, Math.max(2, Math.ceil((p.rtt || 50) / 2 / (1000 / session.fps)) + 2));
    // the seats as the core has them at X: a person's; a bot's, or empty if no person ever played
    // it (the core turns a person's seat into a bot's when they leave)
    const roles = [0, 1, 2, 3].map((s) => (seats.includes(s) || personNow(s) ? 'h' : net.seats[s] === '-' && !net.everPerson[s] ? '-' : 'b')).join('');
    const alive = [...net.members].filter((mid) => net.peers.has(mid) && !net.peers.get(mid).gone);
    const msg = {
      t: 'join', id, seats, at, seed: crypto.getRandomValues(new Uint32Array(1))[0], delay, rom: net.rom, god: botGod,
      owners: roles.split('').map((r, s) => (r === 'h' ? owners[s] : null)), names, roles,
      delays: net.sdelay.map((d, s) => (seats.includes(s) ? delay : d)), members: [net.id, ...alive], fixed: net.fixedDelay,
      // (only those still here, in order: the coordinator is the first of them that plays; a long
      // game's many gone ones would push them past the 64 a newcomer takes)
      order: [...net.order.filter((o) => o !== id && (o === net.id || alive.includes(o))), id],
    };
    net.admitting = { kind: 'join', id, at, ok: new Set(), since: performance.now(), sent: false };
    ctlMembers(msg);
    ctlSend(p, msg);
    applyJoin(msg, true, net.id);
    console.warn('online: admitting', peerName(id), 'seats', seats, 'at poll', at);
    return;
  }
}
// every member: from poll `at`, the newcomer plays its seats; the bots start over there
// a join only gives a computer that isn't in the game seats nobody plays (the coordinator picks
// them that way; none for one that watches): one that would take someone's seat is refused
// (a newcomer this computer already lost, it left as it was let in: the join counts all the same,
// every computer's bots start over at X; its seats then go to bots as for anyone who left)
// one let in (by an earlier coordinator) that doesn't run yet: it can't take part in another
// event (it would miss it) until it runs, or the others take it out (checkJoiners)
const newcomerWaiting = () => [...net.members].some((id) => { const p = net.peers.get(id); return p && !p.gone && p.joinBy && !p.sending; });
function joinTakesFreeSeats(m) {
  if (!Array.isArray(m.seats) || m.seats.length > 4 || net.members.has(m.id) || m.id === net.id) return false;
  return m.seats.every((s) => Number.isInteger(s) && s >= 0 && s < 4 && !personNow(s));
}
function applyJoin(m, coordinating, by) {
  const seats = Array.isArray(m.seats) ? m.seats.filter((s) => Number.isInteger(s) && s >= 0 && s < 4) : [];
  const at = m.at >>> 0, d = Math.min(Math.max(m.delay | 0, 1), 60);
  for (const s of seats) {
    net.owners[s] = m.id;
    net.names[s] = knownName(m.names && m.names[s]);
    // (the player who left it: its input, up to its drop, still goes on to a computer behind it;
    // what came here of it stays)
    net.passTo[s] = Math.max(net.passTo[s], Math.min(net.dropped[s], at));
    net.dropped[s] = 0;
    net.reports[s].clear();
    for (const q of [...net.pending[s].keys()]) if (q >= at) net.pending[s].delete(q);
    net.sdelay[s] = d;
    for (let q = at; q < at + d; q++) net.hist[s].set(q, 0);   // (no buttons: applySeatChanges)
    net.seatQ.push({ s, at, d, join: true });
    net.everPerson[s] = true;
  }
  applySeatChanges();
  net.members.add(m.id);
  if (!net.order.includes(m.id)) net.order.push(m.id);
  const p = net.peers.get(m.id);
  // (by: the coordinator that let it in; joinedAt: checkJoiners)
  if (p) {
    p.acked = [at, at, at, at]; p.lastHeard = performance.now(); p.joinBy = by; p.joinedAt = performance.now();
    for (const s of net.mine) ctlSend(p, { t: 'delay', seat: s, d: net.sdelay[s] });
  }
  queueEvent({ at, seed: m.seed >>> 0, save: coordinating, load: false });
  netWarn(seats.length ? `${seats.map(seatName).join(', ')} joining…` : `${peerName(m.id)} is joining to watch…`, 'warn');
  net.waitingShown = true;   // cleared once the game moves on
  renderPlayers();
}
// the coordinator, once the core saved the state at X: send it in pieces (compressed already)
async function sendState() {
  const a = net.admitting;
  if (!a || a.sending || !netLoad(NET.STATE_SIZE) || (a.kind === 'join' && netLoad(NET.EVENT_DONE) !== a.at)) return;
  a.sending = true;
  const size = netLoad(NET.STATE_SIZE), ptr = Module._web_net_state_ptr();
  const raw = Module.HEAPU8.slice(ptr, ptr + size);
  const to = (a.kind === 'join' ? [a.id] : [...net.members]).map((id) => net.peers.get(id)).filter((p) => p && !p.gone);
  await Promise.all(to.map(async (peer) => {
    // the header goes on the same (ordered) channel as the state: the ctl channel could overtake it
    // (a send that throws (a channel closing, a peer that can't take 16 KB pieces) ends this
    // peer's copy: it's taken out like one that didn't confirm)
    try {
      if (peer.st.readyState === 'open') peer.st.send(new Uint32Array([0x3154534E, size, a.at]).buffer);
      let moved = performance.now(), had = peer.st.bufferedAmount;
      for (let o = 0; o < raw.length; o += 16384) {
        // (one that takes nothing for 30 s: its copy ends, else this would wait for good)
        while (peer.st.bufferedAmount > 1 << 20 && peer.st.readyState === 'open' && performance.now() - moved < 30000) {
          await new Promise((r) => setTimeout(r, 10));
          if (peer.st.bufferedAmount < had) moved = performance.now();
          had = peer.st.bufferedAmount;
        }
        if (peer.st.readyState !== 'open' || peer.st.bufferedAmount > 1 << 20) break;
        peer.st.send(raw.slice(o, o + 16384));
      }
    } catch (e) { console.warn('online: sending the state to', peerName(peer.id), e); }
  }));
  a.sent = true;
  a.sentAt = performance.now();
}
// the newcomer: the coordinator's 'join' (seats, X, the game's setup), then the state
function onJoinMe(peer, m) {
  if (!peer.hello || !peer.hello.game) return;   // (from a computer in the game only)
  if (!validStart({ ...m, seats: m.roles }) || m.rom !== net.rom || !net.romBytes) return;
  // (each offer has its own time, from the first from that computer: another in the room saying
  // it's in a game can't keep this page joining for ever, nor time out the real one with an
  // early one of its own)
  const now = performance.now(), old = net.joinOffers.get(peer.id);
  // (none to the host, which can't join another game; none from a computer past its 2 min)
  if (amHost() || (peer.firstOffer && now - peer.firstOffer > 120000)) return;
  peer.firstOffer = peer.firstOffer || now;   // (the 2 min for all its offers: sent again, no more)
  net.joinOffers.set(peer.id, { ...m, from: peer.id, first: peer.firstOffer, last: old ? old.last : now, piece: !!(old && old.piece) });
  net.joinSince = net.joinSince || now;
  showJoining();
  stateArrived(peer);
}
// "Joining…" once the host confirmed an offer (joinConfirmed): another computer in the room
// saying it's in a game can't change what this page shows with offers of its own
function showJoining() {
  if (net.started || ![...net.joinOffers.values()].some(joinConfirmed)) return;
  netStatus('Joining the game in progress…', 'ok');
  if (!net.refused) $('netrejoin').hidden = true;   // (left from a join that went nowhere)
}
// A join is real once the lobby's host confirmed it ('joinack'), or sent it. The lobby makes
// host only a computer the previous host listed as in the game, so the host is in any game
// that runs, and it confirms only its coordinator's joins: another computer in the room can't
// pull this one into a game of its own making (nor block a real join by claiming to be in one).
function joinConfirmed(m) {
  if (!net.peers.has(net.host)) return false;
  const ack = net.joinAcks.get(net.host);
  return m.from === net.host || (!!ack && ack.at === m.at && ack.from === m.from);
}
// A state comes on the 'st' channel: a header (magic, size, poll), then 16 KB pieces. It may
// come before the message that says what it's for (another channel), so it waits per peer.
function onStateChunk(peer, data) {
  // (only a computer in the game sends one: a stranger's would just take memory. Once this one
  // runs, a state comes only from one in the game (a resync: from the coordinator, which may be
  // that before this page sees it is; its header may come before the resync's message);
  // before, from one that says it's in the game (a join's may come before the offer). And only
  // in whole pieces: never more kept than the state's size)
  if (!(data instanceof ArrayBuffer) || peer.gone) return;
  if (net.started ? !net.members.has(peer.id) : !(net.members.has(peer.id) || (peer.hello && peer.hello.game))) return;
  const header = () => {
    const head = data.byteLength === 12 ? new Uint32Array(data) : null;
    if (!head || head[0] !== 0x3154534E || !head[1] || head[1] > 16 << 20) return false;
    peer.stRx = { size: head[1], at: head[2], parts: [], got: 0, done: null, t: performance.now() };
    return true;
  };
  if (!peer.stRx || peer.stRx.done) { header(); return; }
  const rx = peer.stRx;
  // (not the piece that comes next: a new state's header starts afresh, anything else ends it)
  if (data.byteLength !== Math.min(16384, rx.size - rx.got)) { if (!header()) peer.stRx = null; return; }
  rx.t = performance.now();
  const offer = net.joinOffers.get(peer.id);
  if (offer) { offer.last = performance.now(); offer.piece = true; }   // (its state is coming: a slow link takes longer)
  rx.parts.push(new Uint8Array(data));
  rx.got += data.byteLength;
  // (joining: what came of the states of computers whose offer isn't confirmed, 32 MB in all at
  // most, counted as it comes (a header costs nothing): past that, those with no offer go first,
  // then the biggest (a real one's may come before the host's ack))
  if (!net.started) {
    const unconfirmed = [...net.peers.values()].filter((p) => p.stRx && !p.stRx.done && !joinConfirmed(net.joinOffers.get(p.id) || {}))
      .sort((x, y) => (net.joinOffers.has(x.id) - net.joinOffers.has(y.id)) || y.stRx.got - x.stRx.got);
    let held = unconfirmed.reduce((n, p) => n + p.stRx.got, 0);
    while (held > 32 << 20 && unconfirmed.length) { const p = unconfirmed.shift(); held -= p.stRx.got; p.stRx = null; }
    if (!peer.stRx) return;
  }
  if (rx.got < rx.size) return;
  const state = new Uint8Array(rx.size);
  let o = 0;
  for (const part of rx.parts) { state.set(part, o); o += part.length; }
  rx.parts = [];
  rx.done = state;
  stateArrived(peer);
}
function stateArrived(peer) {
  const rx = peer.stRx;
  if (!rx || !rx.done) return;
  const state = rx.done;
  if (peer.id === net.resyncFrom && net.started && rx.at === net.resyncAt) {
    // out of sync: the core waits at the resync poll for this (once the resync is the core's
    // event: before that, the state waits here; pumpEvents comes back for it)
    if (netLoad(NET.EVENT_AT) !== net.resyncAt || !netLoad(NET.EVENT_LOAD)) return;
    peer.stRx = null;
    net.resyncFrom = null;
    const ptr = Module._malloc(state.length);
    Module.HEAPU8.set(state, ptr);
    Module._web_net_load(ptr, state.length);
    Module._free(ptr);
    ctlSend(peer, { t: 'joinok', at: rx.at });   // loaded: the coordinator goes past X, and may start the next event
    return;
  }
  if (net.started) return;
  const m = net.joinOffers.get(peer.id);
  if (!m || rx.at !== m.at >>> 0 || !joinConfirmed(m)) return;   // (the state waits for the confirmations)
  net.joinInfo = m;
  net.joinOffers.clear();
  peer.stRx = null;
  net.seed = m.seed >>> 0;   // the bots start over with it, everywhere
  netSetUp({ ...m, seats: m.roles }, Array.isArray(m.delays) ? m.delays.map((d) => Math.min(Math.max(d | 0, 1), 60)) : null);
  for (let s = 0; s < 4; s++) net.histTop[s] = m.at;
  for (const s of net.mine) net.histTop[s] = m.at;
  net.joined = true;
  const ptr = Module._malloc(state.length);
  Module.HEAPU8.set(state, ptr);
  Module._web_net_join(ptr, state.length, m.at >>> 0);
  Module._free(ptr);
  // what the others decided while this one waited for the state
  const early = net.preStart;
  net.preStart = [];
  for (const e of early) onCtl(e.peer, e.m);
  // fewer free seats than players here
  if (net.players && net.mine.length < net.players) {
    const text = net.mine.length ? `Only ${net.mine.length} of the four seats ${net.mine.length > 1 ? 'were' : 'was'} free: ${net.mine.map(seatName).join(', ')} ${net.mine.length > 1 ? 'are' : 'is'} played here.`
      : 'All four seats are taken: you are watching.';
    netWarn(text, 'warn');
    setTimeout(() => { if ($('netwarn').textContent === text) netWarn(''); }, 15000);
  }
  $('savelog').hidden = true;   // no replayable log for a game joined mid-way
  // once this computer runs past X (sendJoinOk), the coordinator may admit the next one
  net.joinOkTo = { id: peer.id, at: m.at >>> 0 };
  net.joinPoll = m.at >>> 0;   // (checkInput: just after its join, as after an event)
  net.go = true;
  useRom(net.romBytes, false);
  netLocalLoop();
}

// ---------- out of sync: start again from the coordinator's state ----------
// The coordinator picks X as for a join; every other computer confirms (the coordinator's input
// for X waits for that), runs to X, and waits there for the coordinator's state, saved at X.
// At most once every 10 s: if it keeps happening, the cause is worse than a pause can fix.
function startResync() {
  if (!netRunning() || net.halted) return;
  if (coordinator() !== net.id) {
    // (once in 3 s at most: the coordinator resyncs once in 10 at most, and another sending this
    // page desyncs or false hashes fast would have it flood the coordinator, which takes it out)
    const c = net.peers.get(coordinator()), now = performance.now();
    if (c && !(now - (net.desyncSent || 0) < 3000)) { net.desyncSent = now; ctlSend(c, { t: 'desync' }); }
    return;
  }
  const now = performance.now();
  if (net.admitting || net.events.length || eventBusy() || now - net.lastResync < 10000 || !net.mine.length || newcomerWaiting()) return;
  net.lastResync = now;
  const at = Math.max(...net.mine.map((s) => netLoad(NET.HAVE + s)), netLoad(NET.POLL) + 1);
  const seed = crypto.getRandomValues(new Uint32Array(1))[0];
  net.admitting = { kind: 'resync', id: null, at, ok: new Set(), since: now, sent: false };
  ctlMembers({ t: 'resync', at, seed });
  setEvent(at, seed, true, false);
  console.warn('online: resync at poll', at);
}
function applyResync(peer, m) {
  net.resyncFrom = peer.id;
  net.resyncAt = m.at >>> 0;
  net.resyncSince = performance.now();
  setEvent(m.at >>> 0, m.seed >>> 0, false, true);
  stateArrived(peer);   // in case it overtook this message (it confirms once the state is loaded)
}
function setEvent(at, seed, save, load) {
  queueEvent({ at, seed, save, load });
  // the hashes from before X describe the old games
  net.hashFloor = at;
  if (net.watchDesync && net.watchDesync.poll < at) net.watchDesync = null;   // (this resync fixes it)
  net.resyncs++;
  netWarn(`Out of sync: getting back in sync (from frame ${at})…`, 'warn');
  net.resyncNote = at;
}
// The core has one event (join or resync) at a time. A computer that is behind (one watching) can
// hear of the next one before its core reached the last: that one waits here, and the core gets
// no input from its poll on until it's in (netFlush), so it can't run past it.
function eventBusy() { const at = netLoad(NET.EVENT_AT); return !!at && netLoad(NET.EVENT_DONE) !== at; }
function queueEvent(e) { net.events.push(e); pumpEvents(); }
function pumpEvents() {
  if (!net.started || !ready) return;
  while (net.events.length && !eventBusy()) {
    const e = net.events.shift(), h = H32();
    Atomics.store(h, netWord(NET.EVENT_SEED), e.seed >>> 0);
    Atomics.store(h, netWord(NET.EVENT_SAVE), e.save ? 1 : 0);
    Atomics.store(h, netWord(NET.EVENT_LOAD), e.load ? 1 : 0);
    Atomics.store(h, netWord(NET.STATE_SIZE), 0);
    Atomics.store(h, netWord(NET.LOAD_SIZE), 0);
    Atomics.store(h, netWord(NET.EVENT_AT), e.at >>> 0);
    wakeCore();
    netFlush();   // the input it held back
    // a resync's state that came while it waited
    if (e.load && net.resyncFrom && net.peers.has(net.resyncFrom)) stateArrived(net.peers.get(net.resyncFrom));
  }
}
// joined: tell the coordinator once this computer runs past X (it then admits the next one)
function sendJoinOk() {
  const j = net.joinOkTo;
  if (!j || !netRunning() || netLoad(NET.POLL) < j.at) return;
  net.joinOkTo = null;
  const p = net.peers.get(j.id);
  if (p) ctlSend(p, { t: 'joinok', at: j.at });
}

// ---------- input ----------
// seats whose input we send: ours, and those of computers that left (passed on, so every
// remaining computer gets as far as anyone got)
// (an owner this computer doesn't know: it left before this one joined)
const sendsSeat = (s) => !!net.owners[s] && (net.owners[s] === net.id || !net.peers.has(net.owners[s]) || net.peers.get(net.owners[s]).gone);
// input history: the core's ring holds the last NET_RING polls only; a computer that is behind
// (one watching, or one joining) may need older ones
function netRemember() {
  const h = H32();
  for (let s = 0; s < 4; s++) {
    const have = Atomics.load(h, netWord(NET.HAVE + s));
    if (net.histTop[s] < have - NET_RING + 8) net.histTop[s] = have - NET_RING + 8;
    for (let q = net.histTop[s]; q < have; q++) net.hist[s].set(q, Atomics.load(h, netWord(NET.IN + (q % NET_RING) * 4 + s)));
    if (have > net.histTop[s]) net.histTop[s] = have;
    if (net.hist[s].size > NET_HIST + 64) for (const q of net.hist[s].keys()) { if (net.hist[s].size <= NET_HIST) break; net.hist[s].delete(q); }
  }
}
// to the peers: input for every poll a peer hasn't confirmed, and our acks
function netSend() {
  if (!netRunning() || net.halted) return;
  netRemember();
  const now = performance.now();
  const a = net.admitting;
  for (const peer of net.peers.values()) {
    if (peer.gone || peer.inCh.readyState !== 'open' || !net.members.has(peer.id)) continue;
    let sent = false;
    for (let s = 0; s < 4; s++) {
      // (a seat another plays now: the input of the one before, to a computer that hasn't all of it)
      const pass = !sendsSeat(s);
      if (pass && (net.owners[s] === net.id || peer.acked[s] >= net.passTo[s])) continue;
      const have = pass ? Math.min(net.histTop[s], net.passTo[s]) : net.histTop[s];
      const from = Math.max(peer.acked[s], have - NET_HIST + 64, 0);
      let n = Math.min(Math.max(have - from, 0), 200);
      // someone joins at X: our own input for X on goes to a member once it knows (joinok)
      if (a && net.owners[s] === net.id && peer.id !== a.id && !a.ok.has(peer.id)) n = Math.min(n, Math.max(a.at - from, 0));
      // only input this computer has (after a long stall of this page, or one that joined later
      // than the poll asked for, there are gaps): another computer may have it, a guess would desync
      let k = 0;
      while (k < n && net.hist[s].has(from + k)) k++;
      n = k;
      if (!n && now - peer.lastSend[s] < 100) continue;   // nothing new: still a packet now and then, for the acks
      packet(peer, s, from, n);
      peer.lastSend[s] = now;
      sent = true;
    }
    // acks alone, for a computer we send nothing (we play no seat: watching)
    if (!sent && now - peer.lastAny > 50) packet(peer, 255, 0, 0);
  }
}
function packet(peer, s, from, n) {
  if (peer.inCh.bufferedAmount >= 64 << 10) return;   // (one that takes nothing, or a link far behind: each packet has all it lacks, older ones queued add only delay)
  const h = H32();
  const buf = new ArrayBuffer(7 + n * 2 + 16), v = new DataView(buf);
  v.setUint8(0, 1); v.setUint8(1, s); v.setUint32(2, from, true); v.setUint8(6, n);
  for (let i = 0; i < n; i++) v.setUint16(7 + i * 2, net.hist[s].get(from + i), true);
  for (let t = 0; t < 4; t++) {
    // (a join of that seat still queued (applySeatChanges): its HAVE goes back to at + d then,
    // the input from there on is needed again; a higher ack now would stop it coming)
    let ack = Atomics.load(h, netWord(NET.HAVE + t));
    for (const c of net.seatQ) if (c.s === t && c.join) ack = Math.min(ack, c.at + c.d);
    v.setUint32(7 + n * 2 + t * 4, ack, true);
  }
  chSend(peer.inCh, buf, true);
  peer.lastAny = performance.now();
}
function onInput(peer, data) {
  if (!net.started || peer.gone || !(data instanceof ArrayBuffer) || data.byteLength < 7) return;
  const v = new DataView(data);
  const s = v.getUint8(1), from = v.getUint32(2, true), n = v.getUint8(6);
  if (v.getUint8(0) !== 1 || (s > 3 && s !== 255) || data.byteLength !== 7 + n * 2 + 16) return;
  if (!net.members.has(peer.id)) return;   // (one not let in here yet: nothing it sends counts)
  if (!peer.sending) peer.sendingAt = performance.now();   // (checkSplit)
  peer.sending = true;   // it runs the game (a newcomer doesn't send until it does)
  // acks: how far the peer has each seat's input
  // (and of a seat whose input before its last join still goes on to it: netSend, passTo)
  for (let t = 0; t < 4; t++) if (sendsSeat(t) || peer.acked[t] < net.passTo[t]) peer.acked[t] = Math.max(peer.acked[t], v.getUint32(7 + n * 2 + t * 4, true));
  if (s === 255) return;
  // a seat's input: from its owner, or passed on by a computer in the game once the owner left
  // (or the input of the one who had the seat before, below passTo: netSend)
  const passed = net.members.has(peer.id) && !!net.owners[s] && net.owners[s] !== net.id;
  const any = net.owners[s] === peer.id || (passed && sendsSeat(s));
  if (!any && !passed) return;
  // (from what this one has: a sender sends 200 at most from its ack; and never past a seat's
  // drop: nothing after it is used, and a watcher could feed it for the rest of the game)
  const pend = net.pending[s], low = netLoad(NET.HAVE + s);
  let high = any ? low + 1024 : Math.min(low + 1024, net.passTo[s]);
  if (net.dropped[s]) high = Math.min(high, net.dropped[s]);
  // (passed on, it doesn't replace what is here: a poll's input never changes, and one in the game
  // could otherwise play a departed player's seat with input of its own until the drop. Nor
  // does the owner's below passTo: that is the input of the one who had the seat before)
  const own = net.owners[s] === peer.id;
  for (let i = 0; i < n; i++) if (pend.size < 8192 && from + i >= low && from + i < high && ((own && from + i >= net.passTo[s]) || !pend.has(from + i))) pend.set(from + i, v.getUint16(7 + i * 2, true) & 0xFFF);
  netFlush();
}
// received input into the core, in order, as far as it goes
// The core has one join and one drop poll per seat (NET_JOIN, NET_DROP; the later one counts).
// A computer behind the others (one watching, a hidden tab) may not be past a seat's last change
// when the next one comes: written then, it would undo that one for the polls between. So a
// seat's change waits until the core is past the one before, and until its first polls fit in
// the input ring; meanwhile no input goes to the core from its poll on (netFlush).
function applySeatChanges() {
  if (!net.seatQ.length || !netRunning()) return;
  const h = H32(), poll = Atomics.load(h, netWord(NET.POLL)), waits = new Set();
  let wrote = false;
  net.seatQ = net.seatQ.filter((c) => {
    if (waits.has(c.s) || poll < net.seatAt[c.s] || (c.join && c.at + c.d - poll >= NET_RING - 8)) { waits.add(c.s); return true; }
    if (c.join) {
      // its first `d` polls: no buttons (it can't send them in time), like at the start. (Input
      // of a player who left this seat, up to their drop, is in the core already: admit waits)
      for (let q = c.at; q < c.at + c.d; q++) Atomics.store(h, netWord(NET.IN + (q % NET_RING) * 4 + c.s), 0);
      net.histTop[c.s] = c.at + c.d;
      Atomics.store(h, netWord(NET.HAVE + c.s), c.at + c.d);
      Atomics.store(h, netWord(NET.JOIN + c.s), c.at);
    } else Atomics.store(h, netWord(NET.DROP + c.s), c.at);
    net.seatAt[c.s] = c.at;
    wrote = true;
    return false;
  });
  if (wrote) wakeCore();
}
function netFlush() {
  if (!netRunning()) return;
  applySeatChanges();
  const h = H32();
  let wrote = false;
  // an event or a seat change the core doesn't have yet (pumpEvents, applySeatChanges): nothing
  // from its poll on
  let stop = net.events.length ? net.events[0].at : Infinity;
  for (const c of net.seatQ) stop = Math.min(stop, c.at);
  for (let s = 0; s < 4; s++) {
    if (net.owners[s] === net.id || !net.owners[s]) continue;
    const pend = net.pending[s];
    let have = Atomics.load(h, netWord(NET.HAVE + s));
    for (const p of pend.keys()) if (p < have) pend.delete(p);
    // the core still needs the polls from NET_POLL on: don't run over them in the ring
    while (pend.has(have) && have < stop && have - Atomics.load(h, netWord(NET.POLL)) < NET_RING - 8) {
      const early = have - Atomics.load(h, netWord(NET.POLL));
      net.early[Math.min(Math.max(early, -1), 16) + 1]++;
      net.minEarly[s] = Math.min(net.minEarly[s], early);
      Atomics.store(h, netWord(NET.IN + (have % NET_RING) * 4 + s), pend.get(have));
      pend.delete(have);
      have++;
      Atomics.store(h, netWord(NET.HAVE + s), have);
      wrote = true;
    }
  }
  if (wrote) wakeCore();
}
function wakeCore() { const h = H32(); Atomics.add(h, netWord(NET.SEQ), 1); Atomics.notify(h, netWord(NET.SEQ)); }
// send as soon as the core has written our input (it notifies NET_LOCAL_SEQ); timers in a
// background tab can be slowed to once a second, which would hold up everyone
async function netLocalLoop() {
  if (typeof Atomics.waitAsync !== 'function') return;   // the interval below does it
  while (net.started && !net.halted) {
    const h = H32(), i = netWord(NET.LOCAL_SEQ), v = Atomics.load(h, i);
    const r = Atomics.waitAsync(h, i, v, 100);
    if (r.async) await r.value;
    pumpEvents();
    netWritePads();   // (here too: in a hidden tab the timers below slow to once a second, and a key let go must not stay held)
    netSend();
    netFlush();
    sendState();
    sendJoinOk();
  }
}
setInterval(() => {
  if (!net.started || !ready) return;
  pumpEvents(); netWritePads(); netSend(); netFlush(); netHashes(); netLead(); netWaiting(); sendState(); sendJoinOk();
}, 8);

// the local pads, every 8 ms and every frame. One seat here: every device plays it. Several:
// each seat its device (Players panel). Nothing while the page is hidden or the mapping dialog
// is open, so no button stays held.
function netWritePads() {
  if (!net.started || net.halted || !ready || !net.mine.length) return;
  const masks = [0, 0, 0, 0];
  if (!mapperDev && !document.hidden) {
    for (const dev of Object.keys(deviceNames())) {
      const m = deviceMask(dev);
      if (net.mine.length === 1) masks[net.mine[0]] |= m;
      else if (net.mine.includes(assign[dev])) masks[assign[dev]] |= m;
    }
  }
  for (const s of net.mine) Atomics.store(H32(), netWord(NET.PADS + s), masks[s]);
}

// Time sync. A computer that started earlier stays ahead: it then waits for the others' input on
// every frame, with no slack left for the network's ups and downs. How far ahead: our poll
// minus where the slowest other computer is now (its input reaches its delay ahead of its
// poll and took half a round trip to get here). Averaged over a second; more than 3/4 of a
// frame ahead, the core holds back half of it, at least a frame (a frame of silence per frame);
// as far behind, it runs that many extra frames without their sound. Each computer moving half
// its way, they meet in the middle and the input delays come out even.
function netLead() {
  if (!netRunning() || !net.mine.length) return;   // watching: just follow
  const h = H32(), frameMs = 1000 / session.fps;
  let slowest = Infinity;
  for (let s = 0; s < 4; s++) {
    const owner = net.owners[s];
    if (!owner || owner === net.id || net.dropped[s]) continue;
    const peer = net.peers.get(owner);
    if (!peer || peer.gone) continue;
    const travel = peer.rtt !== null ? peer.rtt / 2 / frameMs : 0;
    // its core wrote the input for (its poll + delay) before running its poll: Have = poll + delay + 1
    slowest = Math.min(slowest, Atomics.load(h, netWord(NET.HAVE + s)) - net.sdelay[s] - 1 + travel);
  }
  if (slowest === Infinity) return;
  net.leadSum += Atomics.load(h, netWord(NET.POLL)) - slowest;
  if (++net.leadN < 125) return;   // about a second
  const lead = net.leadSum / net.leadN;
  net.leadSum = net.leadN = 0;
  net.lead = lead;
  if (Math.abs(lead) > 0.75 && Math.abs(lead) < 60 && !Atomics.load(h, netWord(NET.STALL)) && !Atomics.load(h, netWord(NET.RUSH))) {
    const n = Math.min(Math.max(Math.round(Math.abs(lead) / 2), 1), 30);
    Atomics.store(h, netWord(lead > 0 ? NET.STALL : NET.RUSH), n);
    if (lead > 0) net.stalled += n; else net.rushed = (net.rushed || 0) + n;
  }
}

// Adaptive input delay. Every second each computer tells the owner of each seat how early that
// seat's input arrived at the latest (in polls before it was needed: 0 = just in time, the
// core may have waited). The owner adds a frame of delay when anyone got it at 0 or later, and
// takes one away after 3 s in which everyone got it 3 or more polls early. So each computer's
// delay follows its own connection, and a good connection doesn't pay for a slow one.
function adaptDelay() {
  if (!netRunning() || net.halted) return;
  for (let s = 0; s < 4; s++) {
    const owner = net.owners[s];
    if (!owner || owner === net.id || net.dropped[s]) continue;
    const peer = net.peers.get(owner);
    // a computer that only watches runs behind on purpose: its timing says nothing
    if (peer && !peer.gone && net.minEarly[s] !== Infinity && net.mine.length) ctlSend(peer, { t: 'early', seat: s, min: net.minEarly[s] });
    net.minEarly[s] = Infinity;
  }
  if (net.fixedDelay) return;
  const now = performance.now();
  for (const s of net.mine) {
    const fresh = [...net.earlyReports[s]].filter(([id, r]) => now - r.at < 2000 && net.peers.has(id) && !net.peers.get(id).gone).map(([, r]) => r.min);
    if (!fresh.length || now < net.holdUntil[s]) continue;
    const worst = Math.min(...fresh);
    let d = net.sdelay[s];
    if (worst <= 0) { d = Math.min(d + (worst < 0 ? 2 : 1), 15); net.calm[s] = 0; }
    else if (worst >= 3) { if (++net.calm[s] >= 3) { d = Math.max(d - 1, 1); net.calm[s] = 0; } }
    else net.calm[s] = 0;
    if (d !== net.sdelay[s]) {
      net.sdelay[s] = d;
      Atomics.store(H32(), netWord(NET.SEAT_DELAY + s), d);
      net.holdUntil[s] = now + 1500;   // the next reports still describe the old delay
      ctlMembers({ t: 'delay', seat: s, d });
    }
  }
}

// ---------- a computer leaves ----------
// gone for good: its seats get bots, from a poll all remaining computers agree on
function markGone(peer, why) {
  if (peer.gone) return;
  if (!net.started && joiningWith(peer.id)) { goneBeforeJoin(peer, why); return; }
  if (!net.started || !net.members.has(peer.id)) {
    // never connected: their network or this one doesn't allow a direct connection (there's no
    // relay). Said, else the row just goes and a guest would wait for the host forever
    if (why === 'connection failed' && !peer.hello) {
      const who = peerName(peer.id);
      if (peer.id === net.host && !net.started) { net.noHost = peer.id; netStatus(noHostText(), 'bad'); }
      else netNote(`Couldn't connect to ${who}'s computer: one of your networks doesn't allow a direct connection.`);
    }
    // connected, and the connection broke (a computer asleep a moment, a network changed) while
    // its page may still be in the room: nothing here makes it again (checkLostLinks says so)
    if (!net.started && peer.hello && /^(connection |channel closed)/.test(why) && net.lostLinks.size < 16) net.lostLinks.set(peer.id, { at: performance.now(), said: false, need: !!peer.hello.game || !(gameSaid() && [...net.peers.values()].some((p) => p.hello && p.hello.game)) });
    dropPeer(peer.id);
    return;
  }
  peer.wasCoord = coordinator() === peer.id;   // (checkSplit)
  peer.gone = true;
  peer.stRx = null;   // (a state of one that left is of no use: abortResync below if it was the resync's)
  peer.goneAt = performance.now();
  if (peer.id === net.resyncFrom) abortResync(peerName(peer.id) + ' left');
  // (removed by the host, or taken out for holding up a join: it isn't coming back; admit)
  peer.takenOut = /^(removed by the host|did not confirm|the coordinator that let it in|taken out by the coordinator)/.test(why);
  // lost here (its connection failed or went quiet), rather than said goodbye, or taken out by
  // the host's or the coordinator's word. Taken out here for sending no input: lost only if it
  // went quiet towards this computer too (the others stopped talking to this one: it may be the
  // one cut off); one still heard is stuck behind someone else's link, not on another side
  peer.lost = /^(connection |channel closed|nothing heard)/.test(why) || (/^no input/.test(why) && performance.now() - peer.lastHeard > 3000);
  console.warn('online:', peerName(peer.id), 'gone:', why);
  const seats = [0, 1, 2, 3].filter((s) => net.owners[s] === peer.id && !net.dropped[s]);
  if (!seats.length) { renderPeers(); if (net.started) renderPlayers(); return; }   // (a watcher's row on the host)
  const have = {};
  const h = H32();
  for (const s of seats) {
    have[s] = Atomics.load(h, netWord(NET.HAVE + s));
    net.reports[s].set(net.id, have[s]);
    if (!net.reportsSince[s]) net.reportsSince[s] = performance.now();
  }
  if (!net.halted) netWarn(`${seats.map(seatName).join(', ')} left the game: a bot takes over.`, 'warn');
  if (!net.halted) ctlMembers({ t: 'gone', id: peer.id, have, out: peer.takenOut });
  decideDrops();
  replayHeld();   // if that was the coordinator: what the next one said meanwhile counts now
}
// A computer lost (no goodbye, not taken out) may be on the other side of a network split, and
// if both sides played on, each with bots for the other, the game would split in two for good.
// So: once the computers lost in the last 15 s have been lost for 5 s, this side plays on only
// with more than half of the computers with a seat (watchers don't count; nor one let in that
// doesn't run yet), or with
// half and the coordinator from before the losses; otherwise it stops and offers Rejoin, back
// into the game the other side plays. A computer the lobby server says left (its page closed:
// a crash, a reload) isn't on another side: it doesn't count. Two computers: the coordinator
// plays on, the other stops, unless the lobby says the coordinator's page closed.
// And when only watchers are left, nobody plays: the game is over.
function checkSplit() {
  if (!net.started || net.halted || !ready) return;
  const now = performance.now();
  let peers = [...net.members].map((id) => net.peers.get(id)).filter((p) => p && !(p.joinBy && !p.sending && !p.gone));
  // (the lobby's word counts only about when it was lost: its lobby connection may have closed
  // long before, while it played on)
  const closed = (p) => !p.splitHalt && net.lobbyLeft.has(p.id) && Math.abs(net.lobbyLeft.get(p.id) - p.goneAt) < 15000;
  const recent = (p) => p.gone && p.lost && now - p.goneAt < 15000 && !closed(p);
  // A newcomer this computer never heard running, or that only started running around the
  // losses (from NET_GONE_MS before the first), doesn't count either: the other side may not
  // have it (to them it's let in but not running). Both sides must count the same computers, or
  // both could play on (a coordinator frozen while letting one in: the others take it out, and it
  // wakes up and plays on with the newcomer), or both stop. (One that really runs sends its
  // input to every computer, so both sides have heard it.)
  const first = Math.min(...peers.filter(recent).map((p) => p.goneAt));
  peers = peers.filter((p) => !(p.joinBy && (p.sending ? p.sendingAt : Infinity) > first - NET_GONE_MS - 2000));
  // (only those with a seat count: a side of watchers can't play on, and ends by itself below;
  // watchers that drop out together mustn't outnumber the players and stop their game. Both
  // sides know the same seats)
  const seated = (id) => net.owners.includes(id);
  const lost = peers.filter((p) => recent(p) && seated(p.id));
  if (lost.length) {
    if (lost.some((p) => now - p.goneAt < 5000)) return;   // (the lobby's word may still come)
    const here = (seated(net.id) ? 1 : 0) + peers.filter((p) => !p.gone && seated(p.id)).length, total = here + lost.length;
    if (here * 2 > total || (here * 2 === total && !lost.some((p) => p.wasCoord))) return;
    // those still here stop too, unless they're the bigger part with the others (they'd count
    // this one's closed lobby connection as a page that closed, and might play on alone)
    ctlAll({ t: 'split' });
    netHalt(here > 1 ? 'Lost the connection to part of the game (the network between the computers).'
      : total === 2 && [...net.members].filter((id) => { const p = net.peers.get(id); return id !== net.id && p && (!p.gone || recent(p)); }).length === 1 ? "Lost the connection to the other player's computer." : 'Lost the connection to the other players.', true);
    return;
  }
  const plays = (id) => net.owners.some((o, s) => o === id && !net.dropped[s]);
  if (!net.mine.length && ![...net.members].some((id) => net.peers.has(id) && !net.peers.get(id).gone && plays(id))) {
    netHalt('Everyone who was playing has left, so the game is over.', false);
  }
}
// joining: is it one of the computers in the game this one is about to join (from the offers)
function joiningWith(id, confirmed) {
  // (a game's computers are few (8 in the lobby, a few more playing on without it), 4 seats: an
  // offer naming more can't keep more here)
  for (const m of net.joinOffers.values()) {
    if (confirmed && !joinConfirmed(m)) continue;
    if (m.from === id || (Array.isArray(m.members) && m.members.slice(0, 16).includes(id)) || (Array.isArray(m.owners) && m.owners.slice(0, 4).includes(id))) return true;
  }
  return false;
}
// one of them left before this one runs: it stays known (as gone), so this one passes on its
// input and takes the coordinator's drop for its seats once it runs (preStart). The one that
// offered the join: its state won't come; the others take this one out (checkJoiners).
function goneBeforeJoin(peer, why) {
  peer.gone = true;
  peer.goneAt = performance.now();
  peer.lost = /^(connection |channel closed|nothing heard)/.test(why);
  try { peer.pc.close(); } catch (e) {}
  console.warn('online:', peerName(peer.id), 'gone before this computer joined:', why);
  if (net.joinOffers.delete(peer.id) && ![...net.joinOffers.values()].some(joinConfirmed)) {
    net.joinSince = 0;
    netStatus("Couldn't join the game in progress: the computer letting you in left. Rejoin to try again.", 'bad');
    $('netrejoin').hidden = false; net.lostButton = false;
  }
  renderPeers();
}
// A computer let in by a coordinator that left before it started (it didn't get the state, or not
// all of it) can't start now, and everyone would wait for its input. The next coordinator takes it
// out (a bot takes its seats; its page offers Rejoin), 10 s after the old one left (time to start
// if the state did come).
function checkJoiners() {
  if (!netRunning() || net.halted || coordinator() !== net.id) return;
  const now = performance.now();
  for (const id of net.members) {
    const p = net.peers.get(id);
    if (!p || p.gone || p.sending || !p.joinBy || p.joinBy === net.id) continue;
    const by = net.peers.get(p.joinBy);
    if ((by && !by.gone) || now - ((by && by.goneAt) || p.joinedAt) < 10000) continue;
    ctlSend(p, { t: 'gone', id, have: {} });
    markGone(p, 'the coordinator that let it in left before it started');
  }
}
// the resync's state won't come (its coordinator left, or never sent it): the core goes on
// without it (the bots start over all the same); if the games still differ, the hashes say so
// and the next coordinator starts another one
function abortResync(why) {
  if (!net.resyncFrom) return;
  console.warn('online: resync given up:', why);
  net.resyncFrom = null;
  for (const e of net.events) e.load = false;   // (one not in the core yet)
  if (netLoad(NET.EVENT_AT) === net.resyncAt) Atomics.store(H32(), netWord(NET.EVENT_LOAD), 0);
  wakeCore();
}
// A computer that sends no input holds up everyone, even if it answers pings (one that never
// started after joining, or doesn't play). Only the coordinator judges that, and only when the
// game made no progress at all for a while (a slow computer that keeps it moving isn't gone):
// 8 s, or 25 s just after the start, a join or a resync (a computer may still be loading, or
// waiting for a state; before the event's poll nobody waits for a state, so 8 s there). Any
// other computer only watches the coordinator: no input from it for 20 s (40 s after an event),
// and it stops and offers Rejoin (it can't follow this game; it accuses nobody). A resync whose
// state doesn't come within 30 s: the same (the coordinator first takes out, in 8 s and a few
// more for the drop, a computer that holds it up before the resync's poll).
function checkInput() {
  if (!netRunning() || net.halted) return;
  const h = H32(), poll = Atomics.load(h, netWord(NET.POLL)), now = performance.now();
  // (counted from when the core reached the resync's poll: a watcher far behind gets there later)
  if (net.resyncFrom && poll < net.resyncAt) net.resyncSince = now;
  if (net.resyncFrom && now - net.resyncSince > 30000) {
    abortResync('no state after 30 s');
    netHalt("The game's state didn't arrive in time.", true);
    return;
  }
  if (poll !== net.inputPoll) { net.inputPoll = poll; net.inputWait.fill(0); net.goneWait.fill(0); net.pollSince = now; }
  // stuck: the game hasn't gone on here for two minutes, whatever it waits for (nothing else noticed:
  // a change of seats this computer missed, say). Counted while this page runs (not frozen).
  if (!net.pollSince || now - net.lastCheck > 5000) { net.pollSince = now; net.goneWait.fill(0); net.inputWait.fill(0); }   // (a freeze: from now)
  net.lastCheck = now;
  // (well past the takeouts' waits: two computers taken out one after the other take a minute)
  if (!net.resyncFrom && now - net.pollSince > 120000) {
    netHalt("The game stopped here: it waited two minutes for the other computers' input.", true);
    return;
  }
  const at = Atomics.load(h, netWord(NET.EVENT_AT)) || net.joinPoll || 0, recent = at ? poll >= at && poll < at + 120 : poll < 120;
  const coord = coordinator() === net.id;
  // a seat whose player this computer lost (or never had) while the others still hear it: they
  // don't pass its input on, and the coordinator drops it only if they lose it too. 30 s of
  // waiting on it (40 just after an event): this one stops, with Rejoin
  if (!coord && !net.resyncFrom) {
    for (let s = 0; s < 4; s++) {
      const owner = net.owners[s], p = owner && owner !== net.id && !net.dropped[s] ? net.peers.get(owner) : undefined;
      if (!owner || owner === net.id || net.dropped[s] || (p && !p.gone) || Atomics.load(h, netWord(NET.HAVE + s)) > poll || net.seatQ.some((c) => c.s === s)) { net.goneWait[s] = 0; continue; }
      if (!net.goneWait[s]) { net.goneWait[s] = now; continue; }
      if (now - net.goneWait[s] > (recent ? 40000 : 30000)) {
        netHalt(`Lost the connection to ${seatName(s)}'s computer, which the others still have.`, true);
        return;
      }
    }
  }
  for (let s = 0; s < 4; s++) {
    const owner = net.owners[s], peer = owner && owner !== net.id && !net.dropped[s] ? net.peers.get(owner) : null;
    if (!peer || peer.gone || net.resyncFrom || (!coord && owner !== coordinator()) || Atomics.load(h, netWord(NET.HAVE + s)) > poll || net.seatQ.some((c) => c.s === s)) { net.inputWait[s] = 0; continue; }
    if (!net.inputWait[s]) { net.inputWait[s] = now; continue; }
    const limit = coord ? (recent ? 25000 : NET_GONE_MS + 2000) : (recent ? 40000 : 20000);
    if (now - net.inputWait[s] <= limit) continue;
    net.inputWait[s] = 0;
    if (coord) {
      ctlSend(peer, { t: 'gone', id: owner, have: {} });
      markGone(peer, `no input for ${Math.round(limit / 1000)} s`);
      // one at a time, the others' waits start over: once this one's seats are bots the rest may
      // get going (one link broken between two computers holds up both)
      net.inputWait.fill(0);
      return;
    } else {
      netHalt(`The game stopped: nothing from ${peerName(owner)} for ${Math.round(limit / 1000)} s.`, true);
      return;
    }
  }
}
// A drop or gone from a computer that isn't the coordinator here: kept for a while. When the
// coordinator leaves, the next one may speak before this computer noticed it left; once it has,
// that computer's held messages count. At most 8 per computer, for 30 s.
function hold(peer, m) {
  const now = performance.now();
  net.held = net.held.filter((h) => now - h.at < 30000);
  if (net.held.filter((h) => h.from === peer.id).length >= 8) return;
  net.held.push({ from: peer.id, m, at: now });
}
function replayHeld() {
  if (!net.held.length) return;
  const c = coordinator(), now = performance.now();
  const due = net.held.filter((h) => h.from === c && now - h.at < 30000);
  net.held = net.held.filter((h) => h.from !== c && now - h.at < 30000);
  for (const h of due) { const p = net.peers.get(h.from); if (p && !p.gone) onCtl(p, h.m); }
}
// The coordinator, told by another computer that it lost one this one still hears: either that
// one is really leaving (this one stops hearing it too, within NET_GONE_MS), or the link between
// the two broke. Then one of them has to go: the lost one if most computers lost it, otherwise
// the one(s) that said so. So claiming to have lost someone can't take them out of the game.
function claim(by, x) {
  let c = net.claims.get(x);
  if (!c) net.claims.set(x, (c = { by: new Set(), since: performance.now() }));
  c.by.add(by);
}
function checkClaims() {
  if (!net.claims.size) return;
  if (!netRunning() || net.halted || coordinator() !== net.id) { net.claims.clear(); return; }
  const now = performance.now(), alive = (id) => net.members.has(id) && net.peers.has(id) && !net.peers.get(id).gone;
  for (const [x, c] of net.claims) {
    if (!alive(x)) { net.claims.delete(x); continue; }
    if (now - c.since < NET_GONE_MS + 2000) continue;
    net.claims.delete(x);
    // (the players' word: a watcher's claim counts only against itself)
    const seated = (id) => net.owners.includes(id);
    const by = [...c.by].filter(alive);
    const voters = 1 + [...net.members].filter((id) => id !== x && alive(id) && seated(id)).length;   // this one hears it
    // the one that goes hears it first (from here, the coordinator: it stops and offers Rejoin)
    // (and a watcher one player lost goes: losing it costs the game nothing)
    const out = by.filter(seated).length * 2 > voters || (!seated(x) && by.some(seated)) ? [x] : by;
    for (const id of out) {
      const p = net.peers.get(id);
      ctlSend(p, { t: 'gone', id, have: {} });
      markGone(p, id === x ? 'most computers lost it' : 'lost its connection to ' + peerName(x));
    }
  }
}
// The remaining computer that came into the game first (and plays a seat) decides; the others wait
// for its word. By arrival, not by seat: a newcomer that takes P1 (its player left) isn't trusted
// with this before everyone who was there already has gone.
function coordinator() {
  const plays = (o) => !!net.owners && net.owners.some((x, s) => x === o && !net.dropped[s]);
  for (const o of net.order) if (plays(o) && (o === net.id || (net.peers.has(o) && !net.peers.get(o).gone))) return o;
  return net.id;
}
function decideDrops() {
  // (not before this core runs: until then it has no input (NET_HAVE 0), and a drop at 0 is none)
  if (!netRunning() || net.halted || coordinator() !== net.id) return;
  // (a newcomer that doesn't run yet has nothing to report)
  const alive = [net.id, ...[...net.members].filter((id) => net.peers.has(id) && !net.peers.get(id).gone && !(net.peers.get(id).joinBy && !net.peers.get(id).sending))];
  for (let s = 0; s < 4; s++) {
    const owner = net.owners[s], op = owner && net.peers.get(owner);
    // (an owner this computer never knew: gone, as far as it can tell)
    if (net.dropped[s] || !owner || owner === net.id || (op && !op.gone)) continue;
    const reports = net.reports[s];
    // (this computer's own word: what it has now, at least; markGone may have taken it before
    // the core ran)
    reports.set(net.id, Math.max(reports.get(net.id) || 0, Atomics.load(H32(), netWord(NET.HAVE + s))));
    net.reportsSince[s] = net.reportsSince[s] || performance.now();
    // everyone's word, or 8 s: a computer that doesn't answer is gone by then (NET_GONE_MS) and
    // no longer counts. Nobody can have run past what they have, which is at most `at`.
    if (!alive.every((id) => reports.has(id)) && performance.now() - net.reportsSince[s] < NET_GONE_MS + 2000) continue;
    let at = Math.max(...reports.values());
    // Not past the input this computer has: the others pass on what they have (sendsSeat), so
    // it gets here; if it doesn't within 3 s, a report was wrong (it would freeze everyone
    // waiting for input nobody has). From what it has then: a computer that ran further gets
    // back in sync by itself.
    const mine = netLoad(NET.HAVE + s);
    if (at > mine) {
      if (!net.dropWait[s]) net.dropWait[s] = performance.now();
      if (performance.now() - net.dropWait[s] < 3000) continue;
      at = mine;
    }
    ctlMembers({ t: 'drop', seat: s, at });
    applyDrop(s, at);
  }
}
function applyDrop(s, at) {
  if (net.dropped[s] || !at) return;   // (0 would mean no drop: none is ever at 0)
  net.dropped[s] = at;
  net.droppedAt[s] = performance.now();
  net.reportsSince[s] = 0;
  net.dropWait[s] = 0;
  if (net.owners[s] === net.id) { netHalt('The other computers lost the connection to this one.', true); return; }
  net.seatQ.push({ s, at, join: false });
  applySeatChanges();
  renderPlayers();
}
function netHalt(text, rejoin) {
  if (net.halted) return;
  net.halted = true;
  // out of the lobby too: a halted computer can't confirm joins, so it mustn't stay host
  if (net.ws) { net.ws.onclose = null; try { net.ws.close(); } catch (e) {} net.ws = null; }
  if (net.started && ready) Atomics.store(H32(), netWord(NET.ACTIVE), 3);
  netWarn(text + (rejoin ? ' Rejoin to get back in' + (net.mine && net.mine.length ? ' (your seat is kept for you by name).' : '.') : ''), 'bad');
  $('netrejoin').hidden = !rejoin;
  // (a moment later: what was just sent, a split note, goes out first)
  setTimeout(() => { for (const peer of net.peers.values()) { try { peer.pc.close(); } catch (e) {} } }, 500);
}
// waiting for someone: say who, after a moment
function netWaiting() {
  if (!netRunning() || net.halted) return;
  const h = H32(), poll = Atomics.load(h, netWord(NET.POLL)), now = performance.now();
  if (poll !== net.lastPoll) {
    // a waiting or joining note goes once the game moves again (shown for 2 s at least)
    if (net.waitingShown && now - net.warnAt > 2000) { netWarn(''); net.waitingShown = false; }
    net.lastPoll = poll; net.lastPollAt = now;
    return;
  }
  // (nor over a watcher's out-of-step note: checkHash)
  if (now - net.lastPollAt < 500 || net.waitingShown || net.watchDesync) return;
  const who = [];
  for (let s = 0; s < 4; s++) {
    if (net.seatQ.some((c) => c.s === s)) continue;   // (its change isn't in the core yet)
    const join = Atomics.load(h, netWord(NET.JOIN + s)), drop = net.dropped[s];
    let person = net.seats[s] === 'h';
    if (join <= drop) { if (join && poll >= join) person = true; if (drop && poll >= drop) person = false; }
    else { if (drop && poll >= drop) person = false; if (join && poll >= join) person = true; }
    if (person && Atomics.load(h, netWord(NET.HAVE + s)) <= poll) who.push(seatName(s));
  }
  if (who.length) { netWarn(`Waiting for ${who.join(', ')}…`, 'warn'); net.waitingShown = true; }
}

// ---------- in sync? ----------
function netHashes() {
  if (!netRunning()) return;
  const h = H32(), n = Atomics.load(h, netWord(NET.HASHES));
  for (; net.hashesSeen < n; net.hashesSeen++) {
    // (one the core may be writing over now: skipped, with a few to spare)
    if (n - net.hashesSeen > NET_HASH_RING - 4) continue;
    const at = netWord(NET.HASH + (net.hashesSeen % NET_HASH_RING) * 3);
    const poll = h[at], hash = (h[at + 2] >>> 0).toString(16).padStart(8, '0') + (h[at + 1] >>> 0).toString(16).padStart(8, '0');
    net.myHashes.set(poll, hash);
    if (net.myHashes.size > NET_HASH_RING) net.myHashes.delete(net.myHashes.keys().next().value);
    for (const id of net.members) { const peer = net.peers.get(id); if (peer) { ctlSend(peer, { t: 'hash', poll, h: hash }); checkHash(peer, poll); } }
  }
  const now = performance.now();
  if (now - net.lastInfo > 1000) { net.lastInfo = now; netInfo(); }
}
// Players compare with players: a difference starts a resync. A watcher's hashes count for
// nothing (its game is its own: a false one from a stranger watching mustn't pause the game).
// A watcher goes by the coordinator's: out of step with it for 15 s with no resync to fix it
// (watchDesync, checked every second), it stops and offers Rejoin. Not while a player agrees
// with it where the coordinator doesn't: then the players differ, and their resync will come
// (it may wait for an earlier one or a join to finish), 60 s at most in all (a player could
// keep sending it its own hash). In step again: 3 matches in a row.
const WATCH_NOTE = 'Out of step with the game here: checking…';
function checkHash(peer, poll) {
  const mine = net.myHashes.get(poll), theirs = peer.hashes.get(poll);
  if (!mine || !theirs || poll <= net.hashFloor || net.halted) return;
  if (!net.mine.length) {
    const c = net.peers.get(coordinator()), ch = c && c.hashes.get(poll);
    if (!ch) return;   // (the coordinator's for this poll not here yet: its arrival checks)
    // (a player with this one's hash where the coordinator has another: the players differ)
    const players = () => [...net.members].some((id) => id !== c.id && playsNow(id) && net.peers.has(id) && net.peers.get(id).hashes.get(poll) === mine);
    const w = net.watchDesync;
    if (ch !== mine) {
      if (!w) {
        console.warn('online: watching, out of sync with the coordinator at poll', poll);
        net.watchDesync = { poll, okPoll: poll, since: performance.now(), first: performance.now(), ok: 0 };
        netWarn(WATCH_NOTE, 'warn');
        net.waitingShown = false;   // (netWaiting doesn't take it away)
      } else if (poll > w.okPoll) { w.ok = 0; w.okPoll = poll; }   // (a late hash of an older poll changes nothing)
      // (decided again at each newer poll: one poll's agreement doesn't count for good. While
      // the game is held up (a join's state on its way) no newer poll comes: the interval keeps
      // it fresh, up to the 60 s)
      const v = net.watchDesync;
      if (!(poll <= v.diffPoll)) { v.diffPoll = poll; v.differ = false; }
      if (poll === v.diffPoll && players()) { v.since = performance.now(); v.differ = true; }
    } else if (w) {
      // (checkHash runs for each computer's hash of a poll: a poll counts once)
      if (poll > w.okPoll && ++w.ok >= 3) {
        net.watchDesync = null;
        if ($('netwarn').textContent === WATCH_NOTE) netWarn('');
      } else w.okPoll = Math.max(w.okPoll, poll);
    } else checkResyncNote(poll);
    return;
  }
  if (!playsNow(peer.id)) return;
  if (mine !== theirs) {
    if (net.desync === null || poll > net.desync + 600) console.warn('online: out of sync with', peer.id, 'at poll', poll);
    net.desync = poll;
    startResync();
  } else checkResyncNote(poll);
}
function checkResyncNote(poll) {
  if (net.resyncNote && poll > net.resyncNote) {
    net.resyncNote = 0;
    netWarn(`Back in sync (${net.resyncs} time${net.resyncs > 1 ? 's' : ''} this game).`, 'warn');
    net.waitingShown = true;   // cleared once the game moves on
  }
}
function netInfo() {
  const h = H32();
  const waits = Atomics.load(h, netWord(NET.WAITS)), waitMs = Atomics.load(h, netWord(NET.WAIT_MS));
  const frameMs = 1000 / session.fps;
  const pings = [...net.members].map((id) => net.peers.get(id)).filter((p) => p && !p.gone)
    .map((p) => `${peerName(p.id)} ${p.rtt !== null ? Math.round(p.rtt) + ' ms' : '?'}`).join(', ');
  const mine = net.mine.length ? net.sdelay[net.mine[0]] : 0;
  let text = net.mine.length ? `Online · your input delay ${mine} frame${mine > 1 ? 's' : ''} (${Math.round(mine * frameMs)} ms)` : 'Online · watching';
  if (pings) text += ` · ping ${pings}`;
  if (waits - net.lastWaits) text += ` · waited ${waitMs - net.lastWaitMs} ms`;
  if (showStats) {
    if (net.resyncs) text += ` · resynced ${net.resyncs}×`;
    text += ` · delays ${net.sdelay.map((d, s) => (personNow(s) ? 'P' + (s + 1) + ' ' + d : '')).filter(Boolean).join(', ')}` +
      ` · ahead ${net.lead.toFixed(1)}, held back ${net.stalled}, caught up ${net.rushed || 0} · input early by ${net.early.map((n, i) => (n ? `${i - 1}:${n}` : '')).filter(Boolean).join(' ')}`;
  }
  $('netinfo').textContent = text;
  net.lastWaits = waits; net.lastWaitMs = waitMs;
  net.earlyLast = net.early.map((n, i) => (n ? `${i - 1}:${n}` : '')).filter(Boolean).join(' ');
  net.early.fill(0);
}

// for the diagnostics file (app.js): this computer's part in the online game
function netDiagnostics() {
  const L = [`${net.role === 'host' ? 'hosting' : 'joined by link'}; ${amHost() ? 'the host now' : 'a guest'}; ` +
    `${net.started ? (net.halted ? 'stopped' : 'in the game') : 'in the lobby'}${net.joined ? ' (came in mid-game)' : ''}; players here ${net.players}`];
  if (net.started) {
    L.push(`seats ${net.seats}; this computer plays ${net.mine.map((s) => 'P' + (s + 1)).join(' ') || 'none (watching)'}; coordinator: ${coordinator() === net.id ? 'this computer' : 'another computer'}; ` +
      `dropped at ${net.dropped.join('/')}; resyncs ${net.resyncs}`);
    if (ready) L.push(`poll ${netLoad(NET.POLL)}; input delays ${net.sdelay.join('/')}; held back ${net.stalled}, caught up ${net.rushed || 0}; input early by ${net.earlyLast || '-'}`);
  }
  for (const [id, p] of net.peers) {
    const seats = net.owners ? net.owners.map((o, s) => (o === id ? 'P' + (s + 1) : '')).filter(Boolean).join(' ') : '';
    L.push(`computer ${[...net.peers.keys()].indexOf(id) + 1}${id === net.host ? ' (host)' : ''}: ${p.gone ? 'gone' : 'channel ' + p.ctl.readyState}, connection ${p.pc.connectionState}, ` +
      `round trip ${p.rtt === null ? '?' : Math.round(p.rtt) + ' ms'}${net.members.has(id) ? ', in the game' : ''}${seats ? ', seats ' + seats : ''}`);
  }
  return L;
}

// ---------- page (netSetup: called by app.js once the page is set up) ----------
async function netInit() {
  // the bots and the four-player patches, kept: online the core runs these very bytes
  // (loadBots, patchRom), the ones the others compared (net.bots: their hashes, all in one; a
  // site updated meanwhile can't give two computers different games)
  const get = async (f) => {
    try { const res = await fetch(f); return res.ok ? new Uint8Array(await res.arrayBuffer()) : null; } catch (e) { return null; }
  };
  const bots = await get('bots.lua');
  net.botsSrc = bots;
  net.patches = Object.create(null);
  const ids = [bots ? await sha1(bots) : 'none'];
  for (const k of Object.keys(ROMS).sort()) {
    const f = ROMS[k].patch, b = await get(f);
    if (b) net.patches[f] = b;
    ids.push(b ? await sha1(b) : 'none');
  }
  net.bots = await sha1(new TextEncoder().encode(ids.join(' ')));
}
function netShowLobby(role) {
  netCloseGames();   // its lobby connection too: the lobby gets a new one
  net.role = role;
  $('netchoose').hidden = true;
  $('netbox').hidden = false;
  $('playlog').hidden = true;   // playing back a log would leave the online game
  // the host's choice (guests hear it when the game starts); online it can't change in a game
  if (role === 'guest') $('botgodrow').hidden = true;
  showSaved();   // the ROM buttons now say "Use", not "Start"
  renderPlayers();   // this computer's players
}
// this game's room: known from the lobby, or from the address before that
const netRoomId = () => net.room || (/^#r=([A-Za-z0-9_-]{10,40})$/.exec(location.hash) || [])[1] || null;
function netShowPlayers() {
  $('netplayers').value = net.players === null ? '' : String(net.players);
  $('netplayers').classList.toggle('need', net.players === null);
}
function netSetup() {
  // (only once in a room: the lobby closes a connection that asks before that)
  // (a click a second at most, as the lobby takes them: a held Enter repeats)
  let renamed = 0;
  $('netrename').onclick = () => { if (!net.started && net.room && performance.now() - renamed > 1000) { renamed = performance.now(); sig({ t: 'rename' }); } };
  // Players here: chosen for each game (nobody is ready, or let into a game in progress, before
  // that). Kept for this game only (this tab), so a reload mid-game doesn't ask again.
  $('netplayers').onchange = () => {
    const v = $('netplayers').value;
    net.players = v === '' ? null : +v;
    try { if (netRoomId()) sessionStorage.setItem('tmnt4p.players.' + netRoomId(), v); } catch (e) {}
    netShowPlayers();
    for (const peer of net.peers.values()) sendHello(peer);
    netCheckRom();
    renderPeers();
    renderPlayers();
  };
  try {
    const v = netRoomId() && sessionStorage.getItem('tmnt4p.players.' + netRoomId());
    if (v !== null && v !== undefined && v !== false && /^[0-4]$/.test(v)) net.players = +v;
  } catch (e) {}
  netShowPlayers();
  // hosting: first the version (set for the whole game), then the game is made
  $('nethost').onclick = () => {
    if (net.role) return;
    netCloseGames();
    net.role = 'host';
    net.choosing = true;
    $('netchoose').hidden = true;
    $('nethostpick').hidden = false;
    $('playlog').hidden = true;
    status('');
    showSaved();   // "Host with USA" ... and the drop box for another version
  };
  $('netpickcancel').onclick = () => {
    net.choosing = false;
    net.role = null;
    $('nethostpick').hidden = true;
    $('netchoose').hidden = false;
    $('playlog').hidden = false;
    showSaved();
  };
  $('netback').onclick = () => { location.href = location.pathname + location.search; };
  $('netstart').onclick = netStartGame;
  $('netfind').onclick = netFindGames;
  $('netgamesclose').onclick = netCloseGames;
  $('netpublic').onchange = () => { net.public = $('netpublic').checked; netSendInfo(); renderPeers(); };
  $('netrejoin').onclick = () => location.reload();   // the address has the room: back in as a newcomer
  $('netcopy').onclick = () => { navigator.clipboard.writeText($('netlinktext').value).then(() => netStatus('Link copied.', 'ok'), () => $('netlinktext').select()); };
  $('netleave').onclick = () => {
    if (net.started) ctlAll({ t: 'bye', leave: true });
    // (once the goodbyes went out, 1 s at most: else the others hold this one's seats a while)
    const t = performance.now(), go = () => {
      const busy = [...net.peers.values()].some((p) => p.ctl && p.ctl.readyState === 'open' && p.ctl.bufferedAmount > 0);
      if (busy && performance.now() - t < 1000) setTimeout(go, 50);
      else setTimeout(() => { location.href = location.pathname + location.search; }, 150);
    };
    go();
  };
  addEventListener('pagehide', () => { if (net.started) ctlAll({ t: 'bye' }); });
  // hidden or out of focus: no buttons from here at once (after app.js lets go of the keys)
  addEventListener('visibilitychange', () => setTimeout(netWritePads, 0));
  addEventListener('blur', () => setTimeout(netWritePads, 0));
  // A link pasted into a page that is already open changes only the part after '#', which doesn't
  // load the page again: reload it so the link is followed the same way as in a new window.
  addEventListener('hashchange', () => {
    const r = /^#r=([A-Za-z0-9_-]{10,40})$/.exec(location.hash);
    if (replay) return;
    if (r && r[1] !== net.room) location.reload();
    else if (!r && net.room) {
      // Back (or the address changed) away from the game's link: in a game that runs it stays (Leave
      // game leaves it, a bot taking over); otherwise back to the start screen
      if (net.started && !net.halted) { try { history.replaceState(null, '', location.pathname + location.search + '#r=' + net.room); } catch (e) {} }
      else location.reload();
    }
  });
  const m = /^#r=([A-Za-z0-9_-]{10,40})$/.exec(location.hash);
  if (replay) $('netchoose').hidden = true;
  else if (m) {
    netShowLobby('guest');
    (async () => {
      try { await netInit(); await netConnect(); sig({ t: 'join', room: m[1], token: nameToken() }); netStatus('Joining…'); }
      catch (e) { net.lobbyLost = 'Online play unavailable: ' + e.message; netStatus(net.lobbyLost, 'bad'); }
      renderPeers();
    })();
  }
}
