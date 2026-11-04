#!/usr/bin/env python3
"""Signaling service for online play: browsers in the same room exchange WebRTC connection
setup messages (offers, answers, ICE candidates) through it. Game traffic never passes through
here; once connected, the browsers talk to each other directly.

Python standard library only (a small WebSocket server, RFC 6455), so it needs nothing beyond
python3. Listens on 127.0.0.1; web/serve.py (local testing) or nginx (the site) forwards
/net/ws to it.
  python3 web/netplay/signaling.py [port]      (default 8767)

Names: players don't type names. This server gives each one a name made of two words from the
lists below ("Radical Pizza"), and a token for it; a page that brings its token back (a reload)
gets the same name. Each token is issued once (a random part, signed): another browser given
the same name has a different one. A room keeps each name it has seen for its token. The pages
show only names that come from here, so nobody can put words of their own in front of other
players.

Protocol, JSON text messages:
  -> {"t": "create", "public": <bool>, "token": <str, optional>}
                                             <- {"t": "created", "room": <id>, "id": <your id>, "name", "token", "public", "ice": [...]}
  -> {"t": "join", "room": <id>, "token": <str, optional>}
                                             <- {"t": "joined", "room", "id", "name", "token", "host": <id>, "peers": [<id>...],
                                                "names": {<id>: <name>} (everyone in the room), "public",
                                                "info": the host's info (below; {} before it sends any), "ice": [...]}
                                                the others get {"t": "peer", "id": <new id>, "name"}
                                                a token still held in the room (a reload, or the
                                                same browser in another tab): the older
                                                connection gets {"t": "replaced"} and goes; if it
                                                was the host before the game started, the new
                                                one is the host
  -> {"t": "rename"}                         a different name (ignored once a game started): <- {"t": "renamed", "name", "token"}, the others
                                                get {"t": "name", "id", "name"}
  -> {"t": "signal", "to": <id>, "data": {}} <- {"t": "signal", "from": <id>, "data": {}}   (same room only)
  <- {"t": "left", "id": <id>}   a peer left;   <- {"t": "host", "id": <id>, "public"}   the host left:
                                                    the first remaining one the host listed as in
                                                    the game (else the first remaining one) is the
                                                    host now ("started": a game ran in this
                                                    room, by the host's info)
  The host only:
  -> {"t": "info", "public": <bool>, "rom", "build", "players", "started", "members": [<id>...]}
         what the game list shows (public games only, with the host's name); "public" switches
         listing on or off; "members": the computers in the running game (for host handover)
  -> {"t": "kick", "id": <id>}               that computer gets {"t": "kicked"} and is closed; its
                                                address can't come back into this room (IPv6: its
                                                /64; a second one removed from the same /48 bans
                                                the whole /48 from the room)
  Anyone (in a room or not):
  -> {"t": "list"}  (one answer per 2 s)    <- {"t": "games", "games": [{"room", "name", "rom", "build",
                                                "players", "computers", "started", "age"}...]}  (public, not full,
                                                the host has chosen its ROM)
  (a room lives until its last computer leaves, so its link works for joining a game in progress)
  <- {"t": "error", "msg": <text>}
Room ids are 128 random bits. Nothing is stored; a room lives as long as someone is in it.
Log: stdout (journald under systemd), a summary every 10 minutes and a line per removal or
cut-off (see `report` and `note`).

"ice" is the RTCPeerConnection iceServers list for the browsers, from the environment:
  NET_STUN    STUN URLs, comma-separated (e.g. stun:example.com:3478); none: no STUN
  NET_TURN    TURN URLs, comma-separated (e.g. turn:example.com:3478?transport=udp)
  NET_TURN_SECRET_FILE   coturn's static-auth-secret (use-auth-secret): each connection gets
              its own credentials, valid 6 hours (coturn's REST scheme: username
              "<expiry>:<peer id>", password base64(HMAC-SHA1(secret, username)))
  (systemd: LoadCredential=turn-secret:/etc/... sets $CREDENTIALS_DIRECTORY; the file is read once)
Without any of them (local testing) the list is empty: computers on the same network still connect.
"""
import asyncio, base64, collections, hashlib, hmac, ipaddress, json, os, re, secrets, socket, struct, sys, time

MAX_MESSAGE = 16 * 1024       # bytes per message (a signal; any other: MAX_OTHER)
MAX_OTHER = 2048
MAX_NESTS = 64                # '[' and '{' in a message at most
MAX_PEERS = 8                 # computers per room (four players, the rest watch)
MAX_SEEN = 64                 # ids a room remembers the address of (kick)
MAX_KICKED = 64               # tokens of removed browsers a room keeps out
MAX_BANNED = 256              # addresses (and /48s) kept out of one room (x 500 rooms: memory)
MAX_PER_IP = 10               # connections per address (IPv6: per /64, what one home gets)
MAX_PER_48 = 30               # IPv6: connections per /48 (one tunnel or provider customer can have 65536 /64s)
MAX_LISTED = 50               # games in a list answer
MAX_TOTAL = 500               # connections in all
MAX_PUBLIC_PER_IP = 2         # public games listed per address (more stay unlisted)
MAX_PUBLIC_PER_48 = 4         # IPv6: and per /48
LIST_EVERY = 2.0              # seconds: a connection's 'list' more often than this is ignored (the
                              # page asks every 3 s; the answer is far bigger than the question)
RATE, BURST = 20.0, 60.0      # frames per second per connection (pings too), and the burst allowance
SIGNAL_BURST_FRAMES = 240.0   # signals' own (same rate): a host answering 30 newcomers at once
SIGNAL_PREFIX = re.compile(rb'\{\s*"t"\s*:\s*"signal"')   # how a signal starts ('t' first, as the page sends it)
JOIN_RATE, JOIN_BURST = 0.5, 10.0   # joins per second per address (IPv6: /64), and the burst; per /48: x3
MAX_QUEUED = 64 * 1024        # bytes sent to a client and not taken yet: past that it's cut off
                              # (sending never waits for a client: one reading slowly would hold
                              # up the handler sending to it, another client's)
BEHIND, BEHIND_FOR = 32 * 1024, 5   # and cut off when it still has this much not taken this many
                              # seconds after it got there (one that stops reading can't keep the
                              # lobby's memory: 500 of them)
SIGNAL_ROOM = 4 * 1024        # bytes: a signal goes only if the client's queue stays this far
                              # below BEHIND with it (others flooding it with signals can't get it
                              # cut off; the room for the small messages)
SIGNAL_RATE, SIGNAL_BURST = 16 * 1024, 192 * 1024   # bytes of signals per second to a client from
                              # one address (and from one IPv6 /48), and the burst (a connection's
                              # setup is an offer or answer and a few lists of candidates: a flood
                              # is dropped, the others' signals still get through; kept by the one
                              # it goes to, so connecting again doesn't give more; a home's
                              # computers behind one address share it, answering a newcomer at once)
HOST_GRACE = 10               # seconds: the host's page gone before the game started (a reload,
                              # whose connection closes first): its room and its host role wait
PING_EVERY, IDLE_LIMIT = 30, 90   # seconds: ping, and close when nothing came back for this long
GUID = b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

TURN_LIFETIME = 6 * 3600

# Player names: an adjective and a noun (96 x 102 = 9792 names), in the spirit of the
# turtles (80s/90s slang, ninjas, pizza, sewers, mutants, skateboards, the game's time periods),
# chosen by hand to be harmless in any combination: no word that pairs into anything rude, no
# characters' names. Only these words ever appear as names.
ADJECTIVES = ('Radical', 'Tubular', 'Gnarly', 'Mighty', 'Swift', 'Sneaky', 'Brave', 'Cosmic', 'Turbo', 'Mega',
              'Super', 'Shadow', 'Lucky', 'Rapid', 'Wild', 'Bold', 'Clever', 'Jolly', 'Funky', 'Groovy',
              'Speedy', 'Stealthy', 'Fearless', 'Hungry', 'Sleepy', 'Cheesy', 'Crunchy', 'Spicy', 'Shiny', 'Stormy',
              'Electric', 'Atomic', 'Galactic', 'Silent', 'Rowdy', 'Nimble', 'Daring', 'Mellow', 'Zippy', 'Plucky',
              'Bodacious', 'Righteous', 'Cowabunga', 'Wicked', 'Primo', 'Rad', 'Stoked', 'Shredding', 'Bogus', 'Awesome',
              'Excellent', 'Fresh', 'Mondo', 'Choice', 'Sweet', 'Extreme', 'Hyper', 'Mutant', 'Mutated', 'Teenage',
              'Radioactive', 'Glowing', 'Gooey', 'Slimy', 'Oozy', 'Toxic', 'Subway', 'Rooftop', 'Underground', 'Midnight',
              'Streetwise', 'Masked', 'Hidden', 'Secret', 'Nocturnal', 'Acrobatic', 'Crispy', 'Deep-Dish', 'Half-Shell', 'Shellshocked',
              'Snapping', 'Prehistoric', 'Futuristic', 'Time-Warped', 'Neon', 'Bionic', 'Robo', 'Cyber', 'Blue', 'Red',
              'Orange', 'Purple', 'Green', 'Kung-Fu', 'Karate', 'Surfing')
NOUNS = ('Pizza', 'Shell', 'Sewer', 'Slice', 'Skateboard', 'Turtle', 'Ninja', 'Dojo', 'Manhole', 'Pepperoni',
         'Anchovy', 'Cheese', 'Crust', 'Hoverboard', 'Mushroom', 'Olive', 'Meatball', 'Taco', 'Noodle', 'Dumpling',
         'Pretzel', 'Pickle', 'Waffle', 'Bagel', 'Nacho', 'Burrito', 'Muffin', 'Donut', 'Frisbee', 'Yo-yo',
         'Rocket', 'Comet', 'Thunder', 'Lightning', 'Tornado', 'Volcano', 'Glacier', 'Lantern', 'Compass', 'Kite',
         'Dude', 'Bro', 'Hero', 'Pie', 'Mozzarella', 'Calzone', 'Topping', 'Breadstick', 'Terrapin', 'Tortoise',
         'Snapper', 'Hatchling', 'Lair', 'Hideout', 'Tunnel', 'Alley', 'Fire-Escape', 'Sensei', 'Katana', 'Nunchuck',
         'Sai', 'Bo-Staff', 'Shuriken', 'Kunai', 'Bandana', 'Mask', 'Headband', 'Blackbelt', 'Samurai', 'Ronin',
         'Shogun', 'Grasshopper', 'Halfpipe', 'Kickflip', 'Ollie', 'Surfboard', 'Skater', 'Boombox', 'Arcade', 'Joystick',
         'Cartridge', 'Mixtape', 'Van', 'Blimp', 'Mutagen', 'Ooze', 'Canister', 'Gator', 'Rhino', 'Warthog',
         'Rat', 'Portal', 'Timewarp', 'Pirate', 'Cowboy', 'Dino', 'Raptor', 'Caveman', 'Starbase', 'Robot',
         'Cyborg', 'Reporter')
NAME_KEY = secrets.token_bytes(32)   # signs name tokens; a restart issues new names


def name_of(a, n):
    return f'{ADJECTIVES[a]} {NOUNS[n]}'


def name_token(a, n, nonce=None):
    # (the random part: a token stands for one browser, not for the name, which others get too)
    nonce = nonce or secrets.token_hex(8)
    mac = hmac.new(NAME_KEY, f'{a}.{n}.{nonce}'.encode(), hashlib.sha256).hexdigest()[:20]
    return f'{a}.{n}.{nonce}.{mac}'


def name_from_token(token):
    """(adjective, noun) from a token this server issued, or None"""
    if not isinstance(token, str) or len(token) > 64:
        return None
    if not re.fullmatch(r'[0-9]{1,3}\.[0-9]{1,3}\.[0-9a-f]{16}\.[0-9a-f]{20}', token):
        return None
    parts = token.split('.')
    a, n = int(parts[0]), int(parts[1])
    if a >= len(ADJECTIVES) or n >= len(NOUNS) or not hmac.compare_digest(token, name_token(a, n, parts[2])):
        return None
    return a, n


def same_token(a, b):
    return isinstance(a, str) and isinstance(b, str) and hmac.compare_digest(a.encode(), b.encode())


def give_name(conn, token, taken, owners=None):
    """the token's name if it has one, nobody else in the room uses it, and the room hasn't seen
    it with another token (owners: name -> token); else a new random one with a new token"""
    owners = owners or {}
    pick = name_from_token(token)
    if pick is not None and name_of(*pick) not in taken and same_token(owners.get(name_of(*pick), token), token):
        conn.name, conn.token = name_of(*pick), token
        return
    for _ in range(50):
        pick = (secrets.randbelow(len(ADJECTIVES)), secrets.randbelow(len(NOUNS)))
        if name_of(*pick) not in taken and name_of(*pick) not in owners:
            break
    conn.name = name_of(*pick)
    conn.token = name_token(*pick)


MAX_OWNERS = 64      # names a room keeps for their tokens (held seats go by name; x 500 rooms:
                     # ~20 MB at most, beside the connections, in MemoryMax)
NAME_HOLD = 60       # seconds a gone connection's name stays kept (the page holds its seat 30 s)
OWNERS_PER_IP = 16   # entries one address (IPv6: /64) can have in a room; per /48: 48
OWNERS_PER_48 = 48
HOME_GONE = 4        # gone names one network may have without any of them going for a newcomer


def gone_entry(e):
    """kept for a connection no longer here, and not one the host says is in the game (whose
    lobby connection may have dropped while it plays on)"""
    return e['until'] is not None and not e['member']


def owners(r):
    """the room's kept names: name -> token (those held by a gone connection for NAME_HOLD s)"""
    o, now = r['owners'], time.monotonic()
    for n in [n for n, e in o.items() if gone_entry(e) and e['until'] < now]:
        del o[n]
    return {n: e['token'] for n, e in o.items()}


def own(r, conn):
    """the room keeps conn's name for conn's token while it's here (and NAME_HOLD s after, or while
    the host lists it in the game): another browser given that name gets another. One address
    can't fill the list: past its share it gets no more; a full list loses the oldest gone entry
    of the network with the most gone ones if that's more than a home's (HOME_GONE: no held name
    of a home is pushed out by a crowd of networks), else takes it past MAX_OWNERS while there's
    room for those here. Else none is added (False: it's in the room all the same)"""
    owners(r)
    o = r['owners']
    if conn.name in o:
        o[conn.name].update(token=conn.token, ip=conn.ip, wide=conn.wide, id=conn.id, until=None)
        return True
    # an address at its share: refused (its gone ones are still held: a neighbour's held name
    # mustn't go to make room)
    for key, cap in (('ip', OWNERS_PER_IP), ('wide', OWNERS_PER_48)):
        val = getattr(conn, key)
        if val is not None and sum(1 for e in o.values() if e[key] == val) >= cap:
            return False
    if len(o) >= MAX_OWNERS:
        # (by network: IPv4 address, IPv6 /48; one network's many /64s count as one)
        by_net = collections.defaultdict(list)
        for n, e in o.items():
            if gone_entry(e):
                by_net[e['wide'] or e['ip']].append(n)
        most = max(by_net.values(), key=len, default=[])
        if len(most) > HOME_GONE:
            del o[min(most, key=lambda n: o[n]['until'])]
        elif len(o) >= MAX_OWNERS + MAX_PEERS:
            return False
        # (else kept all the same, past MAX_OWNERS: those here are at most MAX_PEERS; no held name
        # of a home's goes for a crowd of networks with a few each)
    o[conn.name] = {'token': conn.token, 'ip': conn.ip, 'wide': conn.wide, 'id': conn.id, 'until': None, 'member': False}
    return True


def _urls(name):
    return [u.strip() for u in os.environ.get(name, '').split(',') if u.strip()]


def _turn_secret():
    path = os.environ.get('NET_TURN_SECRET_FILE')
    if not path and os.environ.get('CREDENTIALS_DIRECTORY'):
        path = os.path.join(os.environ['CREDENTIALS_DIRECTORY'], 'turn-secret')
    if not path or not os.path.exists(path):
        return None
    with open(path, 'rb') as f:
        return f.read().strip() or None


STUN, TURN, TURN_SECRET = _urls('NET_STUN'), _urls('NET_TURN'), _turn_secret()


def ice_servers(peer_id):
    servers = []
    if STUN:
        servers.append({'urls': STUN})
    if TURN and TURN_SECRET:
        user = f'{int(time.time()) + TURN_LIFETIME}:{peer_id}'
        cred = base64.b64encode(hmac.new(TURN_SECRET, user.encode(), hashlib.sha1).digest()).decode()
        servers.append({'urls': TURN, 'username': user, 'credential': cred})
    return servers


rooms = {}       # room id -> {'host': peer id, 'peers': {peer id: Conn}, 'public': bool, 'info': {...}, 'banned': {address, or IPv6 /48 + '+'}, 'removed48': Counter, 'created'}
per_ip = {}      # address -> open connections (IPv6: per /64, and per /48 too)
join_tokens = {}  # address (or /48) -> (allowance, when): joins and creates (join_allowed)


def join_allowed(conn):
    """a join (or create) from conn's address within its rate: a page joins once per load; one
    address opening and closing connections quickly can't churn a room's names"""
    if conn.ip == '127.0.0.1':
        return True   # (this computer, without a proxy in front: local testing)
    now = time.monotonic()
    if len(join_tokens) > 20000:   # (full allowances are forgotten)
        for k in [k for k, (t, at) in join_tokens.items() if now - at > 60]:
            del join_tokens[k]
    keys = [(conn.ip, JOIN_RATE, JOIN_BURST)] + ([(conn.wide, JOIN_RATE * 3, JOIN_BURST * 3)] if conn.wide else [])
    have = []
    for k, rate, burst in keys:
        t, at = join_tokens.get(k, (burst, now))
        have.append(min(burst, t + (now - at) * rate))
    if any(t < 1 for t in have):
        return False
    for (k, _, _), t in zip(keys, have):
        join_tokens[k] = (t - 1, now)
    return True
total = 0
public_count = {}   # address (and IPv6 /48 + '+') -> public games hosted from there (recount keeps it)


def recount(r):
    """keeps public_count in step with room r: a public game counts for its host's address (and
    /48). Called wherever r['public'] or r's host changes, and before a room goes."""
    host = r['peers'].get(r['host']) if r['public'] and r['host'] in r['peers'] else None
    want = (host.ip, host.wide) if host is not None else None
    have = r.get('counted')
    if want == have:
        return
    for k in have or ():
        if k:
            public_count[k] -= 1
            if not public_count[k]:
                del public_count[k]
    for k in want or ():
        if k:
            public_count[k] = public_count.get(k, 0) + 1
    r['counted'] = want


# The log (stdout: journald under systemd, `journalctl -u tmnt4p-lobby`): a summary every 10
# minutes (connections, rooms, CPU used, what was refused or cut off and from where most), and a
# line for each host removal and each cut-off, at most LOG_LINES of those per period (a flood
# can't fill the log). Addresses as the limits count them: IPv4, or the IPv6 /64.
LOG_EVERY, LOG_LINES, BY_KEY = 600, 50, 1000
stats = collections.Counter()    # events this period
by_key = collections.Counter()   # refusals and cut-offs per address this period
peak = 0                         # most connections at once this period
log_lines = 0


def log(text):
    print('lobby: ' + text, flush=True)


def note(event, key=None, line=None):
    """counts an event for the summary; with key: also against that address; with line: also a
    line of its own (while the period has lines left)"""
    global log_lines
    stats[event] += 1
    # (the addresses kept: at most BY_KEY a period, so refusals from ever new addresses can't
    # fill memory; those seen first stay counted)
    if key and (key in by_key or len(by_key) < BY_KEY):
        by_key[key] += 1
    elif key:
        stats['(from addresses past the first %d, not named)' % BY_KEY] += 1
    if line and log_lines < LOG_LINES:
        log_lines += 1
        log(line)
        if log_lines == LOG_LINES:
            log('(further events this period are only counted, in the summary)')


async def sweep():
    """names kept past their hold go, in rooms nobody joins too (owners() drops them only when
    it's asked: a room filled once and left idle kept them for its life)"""
    while True:
        await asyncio.sleep(NAME_HOLD)
        for r in list(rooms.values()):
            owners(r)


async def report():
    global peak, log_lines
    cpu = time.process_time()
    while True:
        await asyncio.sleep(LOG_EVERY)
        now = time.process_time()
        if not stats and not total and not peak:
            cpu = now
            continue   # a quiet period: no line
        parts = [f'{total} connections now (most {max(peak, total)})', f'{len(rooms)} rooms',
                 f'{sum(1 for r in rooms.values() if r["public"])} public', f'CPU {now - cpu:.1f} s']
        cpu = now
        parts += [f'{k} {v}' for k, v in sorted(stats.items())]
        if by_key:
            parts.append('most from ' + ', '.join(f'{k} ({v})' for k, v in by_key.most_common(3)))
        log(f'last {LOG_EVERY // 60} min: ' + '; '.join(parts))
        stats.clear()
        by_key.clear()
        peak = total
        log_lines = 0


class Closed(Exception):
    pass


class TooFast(Exception):
    pass


def wide_key(key):
    """IPv6: the /48 a /64 key is in (a second, wider limit); None for IPv4"""
    try:
        return str(ipaddress.ip_network(key).supernet(new_prefix=48)) + '+' if ':' in key else None
    except ValueError:
        return None


def abort(writer):
    """closes at once, unsent data and all: close() waits for a client that doesn't read (and
    with a reset: else the kernel would keep the socket and what it holds, uncounted, as long as
    the client keeps its window shut)"""
    try:
        sock = writer.get_extra_info('socket')
        if sock is not None:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
    except Exception:
        pass
    try:
        writer.transport.abort()
    except Exception:
        pass


def addr_key(ip):
    """what limits and bans count by: the address; for IPv6 its /64 (one home has a whole /64,
    so counting single addresses would let one client take every slot or come back after a ban)"""
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    if a.version == 6:
        if a.ipv4_mapped is not None:   # ::ffff:1.2.3.4 is the IPv4 address
            return str(a.ipv4_mapped)
        return str(ipaddress.ip_network(f'{a}/64', strict=False))
    return str(a)


class Conn:
    def __init__(self, reader, writer, ip):
        self.reader, self.writer, self.ip = reader, writer, ip
        self.wide = wide_key(ip)      # IPv6: its /48 (worked out once: it costs)
        self.id = secrets.token_hex(4)
        self.room = None
        self.name = self.token = None
        self.tokens = BURST
        self.sig_tokens, self.sig_last, self.as_signal = SIGNAL_BURST_FRAMES, time.monotonic(), False
        self.last_len = 0
        self.listed = 0.0             # when it last got the game list
        self.sig = {}                 # address (or /48) signalling it -> (bytes allowed, when): SIGNAL_RATE
        self.watch = None             # the check BEHIND_FOR s after it got BEHIND (_write)
        self.renamed = 0.0            # when it last renamed
        self.last = time.monotonic()
        self.heard = time.monotonic()

    async def _write(self, data):
        if self.writer.is_closing():
            return
        try:
            # (queued: never waits here, the caller may be another connection's handler; MAX_QUEUED)
            self.writer.write(data)
            if self.queued() > MAX_QUEUED:
                note('cut off: not reading', self.ip)
                abort(self.writer)   # it stopped reading: its handler ends and cleans up
            elif self.queued() > BEHIND and self.watch is None:
                self.watch = asyncio.get_running_loop().call_later(BEHIND_FOR, self._still_behind)
        except (ConnectionError, RuntimeError):
            pass

    def _still_behind(self):
        self.watch = None
        if self.queued() > BEHIND and not self.writer.is_closing():
            note('cut off: not reading', self.ip)
            abort(self.writer)

    def queued(self):
        try:
            return self.writer.transport.get_write_buffer_size()
        except Exception:
            return 0

    async def send(self, msg):
        data = json.dumps(msg, separators=(',', ':')).encode()
        head = bytes([0x81])
        n = len(data)
        head += bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n) if n < 65536 else bytes([127]) + struct.pack('>Q', n)
        await self._write(head + data)

    async def control(self, opcode, payload=b''):
        await self._write(bytes([0x80 | opcode, len(payload)]) + payload)

    async def receive(self):
        """the next text message (str); answers pings; raises Closed"""
        while True:
            raw = data = None   # (the last frame isn't kept while waiting for the next)
            try:
                b0, b1 = await self.reader.readexactly(2)
                n = b1 & 0x7F
                if n == 126:
                    n = struct.unpack('>H', await self.reader.readexactly(2))[0]
                elif n == 127:
                    n = struct.unpack('>Q', await self.reader.readexactly(8))[0]
                op = b0 & 0x0F
                # clients must mask; no fragmented messages (browsers don't fragment small ones);
                # control frames (close, ping, pong) are 125 bytes at most (RFC 6455)
                if not b1 & 0x80 or not b0 & 0x80 or n > MAX_MESSAGE or (op >= 8 and n > 125):
                    raise Closed()
                mask = await self.reader.readexactly(4)
                raw = await self.reader.readexactly(n)
            except (asyncio.IncompleteReadError, ConnectionError):
                raise Closed()
            except TimeoutError:   # (the kernel dropped it: what was sent wasn't taken in 10 s)
                note('cut off: not reading', self.ip)
                raise Closed()
            # unmasked in one step (a byte at a time in Python costs a lot of CPU)
            data = (int.from_bytes(raw, 'big') ^ int.from_bytes((mask * (n // 4 + 1))[:n], 'big')).to_bytes(n, 'big') if n else b''
            # every frame counts against the rate, pings included, big ones more (a 16 KB one
            # as 5: parsing it costs that much more). Signals have a rate of their own, and past
            # it are dropped, not cut off: others make a page send them (an answer and its
            # candidates for each newcomer: a stream of newcomers would get the host cut off)
            self.as_signal = op == 1 and SIGNAL_PREFIX.match(data) is not None
            if op == 1 and not self.as_signal and n > MAX_OTHER:
                raise Closed()   # (only a signal is big: the others are a few hundred bytes)
            # (nor deep: a frame of nested arrays costs the parser, and re-encoding, far more than
            # its size; a page's has a few dozen brackets at most. And a signal is ASCII: its size
            # forwarded is then known from this one's, dispatch; DEL, though ASCII, goes out as
            # \u007f, six times its size)
            if op == 1 and (data.count(b'[') + data.count(b'{') > MAX_NESTS or (self.as_signal and (not data.isascii() or b'\x7f' in data))):
                raise Closed()
            self.last_len = n
            if self.as_signal:
                if not self.allow(1 + n // 4096, signal=True):
                    note('signals dropped: too many from one client', self.ip)
                    continue
            elif not self.allow(1 + n // 4096):
                raise TooFast()
            self.heard = time.monotonic()
            if op == 1:
                try:
                    return data.decode('utf-8', 'strict')
                except UnicodeDecodeError:
                    raise Closed()
            if op == 8:
                await self.control(8)
                raise Closed()
            if op == 9:
                await self.control(10, bytes(data[:125]))
            elif op != 10:
                raise Closed()   # binary or continuation frames: not part of the protocol

    def allow(self, cost=1, signal=False):
        now = time.monotonic()
        if signal:
            # (past the allowance a signal is dropped and still counted, in debt: as far again in
            # debt and it's cut off, a flood of them would take the lobby's CPU)
            self.sig_tokens = min(SIGNAL_BURST_FRAMES, self.sig_tokens + (now - self.sig_last) * RATE)
            self.sig_last = now
            ok = self.sig_tokens >= cost
            self.sig_tokens -= cost
            if self.sig_tokens < -SIGNAL_BURST_FRAMES:
                raise TooFast()
            return ok
        self.tokens = min(BURST, self.tokens + (now - self.last) * RATE)
        self.last = now
        if self.tokens < cost:
            return False
        self.tokens -= cost
        return True


async def handshake(reader, writer):
    """reads the HTTP upgrade request; returns the client's address, or None (answered with an error)"""
    try:
        head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
        return None
    if len(head) > 8192:
        return None
    lines = head.decode('latin-1').split('\r\n')
    parts = lines[0].split(' ')
    headers = {}
    bad = False
    for line in lines[1:]:
        if ':' in line:
            k, v = line.split(':', 1)
            # a malformed name, or a header twice (X-Real-IP: the first and only one counts)
            if k != k.strip() or not k or k.lower() in headers:
                bad = True
            headers.setdefault(k.strip().lower(), v.strip())

    def refuse(code, text):
        writer.write(f'HTTP/1.1 {code} {text}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'.encode())
        return None

    if bad:
        return refuse(400, 'Bad Request')

    if len(parts) < 2 or parts[0] != 'GET' or parts[1] != '/net/ws' or headers.get('upgrade', '').lower() != 'websocket' \
            or 'sec-websocket-key' not in headers:
        return refuse(400, 'Bad Request')
    # only pages from this site: the Origin must be the host the request was made to
    origin = headers.get('origin', '')
    if origin.split('://', 1)[-1] != headers.get('host', ''):
        return refuse(403, 'Forbidden')
    # behind nginx or serve.py the connection comes from 127.0.0.1; they pass the client's address
    peer = writer.get_extra_info('peername')
    ip = peer[0] if peer else '?'
    if ip in ('127.0.0.1', '::1') and headers.get('x-real-ip'):
        try:
            if '%' in headers['x-real-ip']:
                raise ValueError('scope id')
            ip = str(ipaddress.ip_address(headers['x-real-ip']))
        except ValueError:
            return refuse(400, 'Bad Request')
    accept = base64.b64encode(hashlib.sha1(headers['sec-websocket-key'].encode() + GUID).digest()).decode()
    writer.write(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                  f'Sec-WebSocket-Accept: {accept}\r\n\r\n').encode())
    return ip


async def handle(reader, writer):
    global total, peak
    ip = await handshake(reader, writer)
    ip = addr_key(ip) if ip is not None else None
    wide = wide_key(ip) if ip is not None else None
    full = ip is not None and (total >= MAX_TOTAL and 'refused: lobby full' or per_ip.get(ip, 0) >= MAX_PER_IP and 'refused: address at its limit'
                               or wide and per_ip.get(wide, 0) >= MAX_PER_48 and 'refused: /48 at its limit')
    if ip is None or full:
        note(full or 'refused: bad request', ip)
        if ip is not None:
            # why, then close (the page says it: else it looks like a lost connection)
            text = json.dumps({'t': 'error', 'msg': 'the lobby is full right now' if full == 'refused: lobby full'
                               else 'too many connections from your network'}).encode()
            writer.write(bytes([0x81, len(text)]) + text + b'\x88\x00')
        await close_writer(writer)
        return
    # a small send buffer: a client that doesn't read can't make this hold much for it (the
    # kernel's, counted in the service's memory too, beside BEHIND here: Linux doubles it, 64 KB,
    # about 100 KB a connection at most, 50 MB for 500; any smaller and a newcomer's answers
    # arriving at once would wait here, and signals past the headroom be dropped)
    sock = writer.get_extra_info('socket')
    if sock is not None:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32 * 1024)
            # and what's sent must be taken within 10 s, or the kernel drops the connection (one
            # closed here while its client keeps its window shut would hold its buffer, uncounted)
            sock.setsockopt(socket.IPPROTO_TCP, getattr(socket, 'TCP_USER_TIMEOUT', 18), 10000)
        except OSError:
            pass
    writer.transport.set_write_buffer_limits(high=32 * 1024)
    total += 1
    peak = max(peak, total)
    note('connections')
    for k in (ip, wide) if wide else (ip,):
        per_ip[k] = per_ip.get(k, 0) + 1
    conn = Conn(reader, writer, ip)
    pinger = asyncio.ensure_future(keepalive(conn))
    try:
        while True:
            # (the last message isn't kept while waiting for the next: parsed, a 16 KB signal of
            # short values takes some 200 KB, and 500 idle connections would hold 100 MB of them)
            text = msg = None
            text = await conn.receive()
            try:
                msg = json.loads(text, parse_constant=no_constant, parse_float=finite)
            except (ValueError, RecursionError):
                break
            # (counted as a signal: one, or it goes; and a signal not written as one ('t' first, as the
            # page writes it) goes too: it would skip the signal rules, and be forwarded)
            if not isinstance(msg, dict) or conn.as_signal != (msg.get('t') == 'signal') or not await dispatch(conn, msg):
                break
    except TooFast:
        note('cut off: too many messages', ip, f'cut off for sending too many messages: {ip}')
        await conn.send({'t': 'error', 'msg': 'too many messages'})
    except Closed:
        pass
    except Exception as e:   # a message this code didn't expect: that client goes, the others stay
        note('closed after an error', ip, f'closing a connection ({ip}) after {type(e).__name__}: {e}'[:300])
    finally:
        text = msg = None   # (nor while this one closes: all those refused in one pass close together)
        pinger.cancel()
        if conn.watch is not None:
            conn.watch.cancel()
        try:
            await leave(conn)
            # (one leaving with what was sent to it not taken isn't reading: at once, else its
            # buffers would stay for close_writer's 5 s; and counted until it's closed, so an
            # address can't keep closing ones beyond its limits)
            if conn.queued() > 0:
                abort(writer)
            else:
                await close_writer(writer)
        finally:
            total -= 1
            for k in (ip, wide) if wide else (ip,):
                per_ip[k] -= 1
                if not per_ip[k]:
                    del per_ip[k]


def finite(text):
    # (no number with a point or exponent: the page sends none, and each costs a call here; a
    # frame full of them took the lobby's CPU)
    raise ValueError(text)


def no_constant(name):
    raise ValueError(name)   # NaN, Infinity: not JSON (they'd go on to the other browsers as such)


def clean_text(v, n, allowed=None):
    """a short string for the list: no control or text-direction characters"""
    if not isinstance(v, str) or len(v) > 4 * n:   # (far too long: not worth filtering)
        return ''
    v = ''.join(ch for ch in v if ch.isprintable() and not ('\u202a' <= ch <= '\u202e' or '\u2066' <= ch <= '\u2069'))
    v = v.strip()[:n]
    if allowed is not None and any(ch not in allowed for ch in v):
        return ''
    return v


HEX = set('0123456789abcdef')
BUILD_CHARS = set('0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_:')


def may_list(r, conn):
    """may a game hosted from this connection's address be listed (one address, or one IPv6 /48,
    can't fill the list); r itself doesn't count against it"""
    mine = r.get('counted') or ()
    same = public_count.get(conn.ip, 0) - (conn.ip in mine)
    wide = public_count.get(conn.wide, 0) - (conn.wide in mine) if conn.wide else 0
    return same < MAX_PUBLIC_PER_IP and wide < MAX_PUBLIC_PER_48


def clean_info(msg):
    players = msg.get('players')
    return {
        'rom': clean_text(msg.get('rom'), 40, HEX),
        'build': clean_text(msg.get('build'), 40, BUILD_CHARS),
        'players': players if isinstance(players, int) and not isinstance(players, bool) and 0 <= players <= 4 else 0,
        'started': msg.get('started') is True,
    }


_list_cache = (0.0, None)


def list_answer(now):
    """the 'games' message, made at most once a second (many clients asking cost one answer)"""
    global _list_cache
    if _list_cache[1] is None or now - _list_cache[0] >= 1.0:
        _list_cache = (now, {'t': 'games', 'games': game_list()})
    return _list_cache[1]


def game_list():
    now = time.monotonic()
    games = []
    for room, r in sorted(rooms.items(), key=lambda kv: -kv[1]['created']):
        # (full: a place kept for a host that's away too, join)
        if not r['public'] or len(r['peers']) + (r.get('away') is not None) >= MAX_PEERS or not r['info'].get('rom'):
            continue
        # (nor one with nobody in it, kept a moment for its host's page to come back: whoever joined
        # it from the list would be made the host of a game it didn't mean to host if it doesn't)
        if not r['peers']:
            continue
        games.append(dict(r['info'], room=room, computers=len(r['peers']), age=int(now - r['created'])))
        if len(games) >= MAX_LISTED:
            break
    return games


async def dispatch(conn, msg):
    """handles one message; False closes the connection (unknown or misused message)"""
    t = msg.get('t')
    if conn.room is not None and (conn.room not in rooms or conn.id not in rooms[conn.room]['peers']):
        return True   # (out of its room already, leave() still telling the others: nothing counts)
    if t in ('join', 'create') and conn.room is None and not join_allowed(conn):
        note('joins refused: too many from one address', conn.ip)
        await conn.send({'t': 'error', 'msg': 'too many games joined from your network just now: try again in a minute'})
        return True
    if t == 'create' and conn.room is None:
        room = base64.urlsafe_b64encode(secrets.token_bytes(16)).decode().rstrip('=')
        rooms[room] = r = {'host': conn.id, 'peers': {conn.id: conn}, 'public': False, 'info': {},
                           'banned': set(), 'removed48': collections.Counter(), 'created': time.monotonic(), 'owners': {},
                           'seen': {},   # id -> (address, /48, token) of the room's connections, the last MAX_SEEN (kick)
                           'kicked': set()}   # tokens of those removed (MAX_KICKED at most): kept out by browser too
        r['public'] = msg.get('public') is True and may_list(r, conn)
        recount(r)
        conn.room = room
        give_name(conn, msg.get('token'), set())
        r['seen'][conn.id] = (conn.ip, conn.wide, conn.token)
        own(r, conn)
        note('rooms made')
        if msg.get('public') is True and not r['public']:
            note('public games not listed (address limit)', conn.ip)
            await conn.send({'t': 'public', 'public': False})   # (before 'created': the page says why)
        await conn.send({'t': 'created', 'room': room, 'id': conn.id, 'name': conn.name, 'token': conn.token,
                         'public': rooms[room]['public'], 'ice': ice_servers(conn.id)})
        return True
    if t == 'join' and conn.room is None:
        r = rooms.get(msg.get('room')) if isinstance(msg.get('room'), str) else None
        if r is None or conn.ip in r['banned'] or conn.wide in r['banned']:
            note('joins refused: no such room' if r is None else 'joins refused: removed from that room', conn.ip)
            await conn.send({'t': 'error', 'msg': 'no such game (the host may have left)' if r is None else 'removed from that game'})
            return True
        # the token held here by an older connection: that's this browser's last page (a crash
        # or a lost connection the server hasn't noticed yet). It goes, so this one gets its name
        # back (and with it its seat in the game). Only that browser has the token.
        tok = msg.get('token') if name_from_token(msg.get('token')) is not None else None
        # (one the host removed, back from another address with its token: out all the same)
        if tok is not None and tok in r.get('kicked', ()):
            note('joins refused: removed from that room', conn.ip)
            await conn.send({'t': 'error', 'msg': 'removed from that game'})
            return True
        old = next((c for c in r['peers'].values() if tok is not None and same_token(c.token, tok)), None)
        # (the host's name while it's away: kept for it, it comes back with its token; and its
        # place: others filling the room meanwhile would keep it out, and take its role)
        away = r.get('away')
        back = away is not None and tok is not None and same_token(away[2], tok)
        if len(r['peers']) - (old is not None) + (away is not None and not back) >= MAX_PEERS:
            await conn.send({'t': 'error', 'msg': 'this game is full'})
            return True
        others = [c for c in r['peers'].values() if c is not old]
        taken = {c.name for c in others} | ({away[0]} if away is not None and not back else set())
        give_name(conn, tok, taken, owners(r))
        # (a list full of other networks' names, or this address at its share: in all the same,
        # its name just isn't kept for it once it goes; the others' held names stay)
        own(r, conn)
        r['peers'][conn.id] = conn
        # (so the host can remove it by id after its lobby connection went: it may play on)
        r['seen'][conn.id] = (conn.ip, conn.wide, conn.token)
        if len(r['seen']) > MAX_SEEN:
            # (the oldest not in the game: a flood of joins can't push out one the host may yet
            # remove; at most 8 are listed)
            keep = set(r.get('listed', ())) | set(r.get('members', ()))
            del r['seen'][next(i for i in r['seen'] if i not in keep)]
        conn.room = msg['room']
        # the host's own page back before the game started (a reload; its old connection may
        # be open still, or closed already: then the host's role waited for it): it stays host
        rehost = ((old is not None and r['host'] == old.id) or back) and not r['info'].get('started')
        if rehost:
            r['host'] = conn.id
            r['away'] = None
            # (its address may be at its limit of listed games now: a token is no way round it;
            # 'joined' tells the page)
            if r['public'] and not may_list(r, conn):
                r['public'] = False
                note('public games not listed (address limit)', conn.ip)
        note('joins')
        await conn.send({'t': 'joined', 'room': conn.room, 'id': conn.id, 'name': conn.name, 'token': conn.token,
                         'host': r['host'], 'peers': [c.id for c in others], 'names': {c.id: c.name for c in others},
                         'public': r['public'], 'info': r['info'], 'ice': ice_servers(conn.id)})
        for c in others:
            await c.send({'t': 'peer', 'id': conn.id, 'name': conn.name})
        if old is not None:
            # (a page still open there, in another tab: it says why it left the game)
            await old.send({'t': 'replaced'})
            await leave(old)   # (the room has this one now: it stays, whoever else is left)
            old.writer.close()   # (after what's queued for it; gone for sure in 2 s)
            asyncio.get_running_loop().call_later(2, abort, old.writer)
        if rehost:
            recount(r)
            for c in others:
                if c is not old and c.room == conn.room:
                    await c.send({'t': 'host', 'id': r['host'], 'public': r['public'], 'started': r['info'].get('started') is True})
        return True
    if t == 'signal' and conn.room is not None:
        to = rooms[conn.room]['peers'].get(msg.get('to')) if isinstance(msg.get('to'), str) else None
        if to is not None and to is not conn and isinstance(msg.get('data'), dict):
            out = {'t': 'signal', 'from': conn.id, 'data': msg['data']}
            # (its size as sent: this one's (ASCII, receive) with 'from' for 'to', at most: no
            # encoding here, only for one that goes)
            n = conn.last_len + 2
            now = time.monotonic()
            keys = (conn.ip, conn.wide) if conn.wide else (conn.ip,)
            if len(to.sig) >= 4 * MAX_PEERS and any(k not in to.sig for k in keys):
                # (addresses long gone, mostly: full allowances again)
                to.sig = {k: v for k, v in to.sig.items() if now - v[1] < SIGNAL_BURST / SIGNAL_RATE}
                # still full (many addresses, each signalling once): of the addresses no one in the
                # room has now, the one with the most allowance left goes, and the next (there are
                # at most 14 here: always room; forgetting one gives back the least)
                here = {k for c in rooms[conn.room]['peers'].values() for k in (c.ip, c.wide) if k}
                left = lambda k: to.sig[k][0] + (now - to.sig[k][1]) * SIGNAL_RATE
                while len(to.sig) >= 4 * MAX_PEERS:
                    gone = [k for k in to.sig if k not in here]
                    if not gone:
                        break
                    del to.sig[max(gone, key=left)]
            have = {k: min(SIGNAL_BURST, to.sig[k][0] + (now - to.sig[k][1]) * SIGNAL_RATE) if k in to.sig else SIGNAL_BURST for k in keys}
            ok = all(v >= n for v in have.values()) and to.queued() + n <= BEHIND - SIGNAL_ROOM
            for k, v in have.items():
                to.sig[k] = (v - n if ok else v, now)
            if ok:
                await to.send(out)
            else:
                if to.queued() + n > BEHIND - SIGNAL_ROOM:
                    note('signals dropped: the client is behind', to.ip)
                else:
                    note('signals dropped: too many to one client', conn.ip)
        return True
    if t == 'rename' and conn.room is not None:
        r = rooms[conn.room]
        if r['info'].get('started'):
            return True   # (pages rename only before the game: seats go by name)
        now = time.monotonic()
        if now - conn.renamed < 1:
            return True   # (a click at a time: each goes to the whole room)
        conn.renamed = now
        if same_token(owners(r).get(conn.name), conn.token):
            del r['owners'][conn.name]   # (one entry per connection: renames can't push others out)
        give_name(conn, None, {c.name for c in r['peers'].values()} | ({r['away'][0]} if r.get('away') else set()), owners(r))
        own(r, conn)
        if r['host'] == conn.id and r['info']:
            r['info']['name'] = conn.name   # the game list shows the host's name
        if conn.id in r['seen']:
            r['seen'][conn.id] = (conn.ip, conn.wide, conn.token)   # (its token now: kick)
        await conn.send({'t': 'renamed', 'name': conn.name, 'token': conn.token})
        for c in list(r['peers'].values()):
            if c is not conn:
                await c.send({'t': 'name', 'id': conn.id, 'name': conn.name})
        return True
    if t == 'list':
        now = time.monotonic()
        if now - conn.listed >= LIST_EVERY and conn.queued() <= BEHIND:   # (not to one behind)
            conn.listed = now
            await conn.send(list_answer(now))
        return True
    r = rooms.get(conn.room)
    # from anyone but the host: ignored (it may not know yet that the host changed)
    if t in ('info', 'kick') and (r is None or r['host'] != conn.id):
        return True
    if t == 'info':
        # one address can't fill the list: its games past the first few stay unlisted
        r['public'] = msg.get('public') is True and may_list(r, conn)
        recount(r)
        if msg.get('public') is True and not r['public']:
            note('public games not listed (address limit)', conn.ip)
            await conn.send({'t': 'public', 'public': False})   # the page unticks Public game, and says why
        was_started = r['info'].get('started')
        r['info'] = clean_info(msg)
        r['info']['started'] = r['info']['started'] or bool(was_started)   # a game that ran stays one
        r['info']['name'] = conn.name   # the host's name from here, never from the page
        # who the host says is in the game: only they can become host (pages trust the host to be
        # in a game that runs: it confirms joins). Only ids in this room.
        ids = msg.get('members')
        listed = [i for i in ids[:MAX_PEERS] if isinstance(i, str)] if isinstance(ids, list) else []
        r['members'] = [i for i in listed if i in r['peers']]
        # (their names stay kept while they're listed, here or not: one whose lobby connection
        # dropped plays on, and its seat goes by its name)
        # once a game ran, only a host the last list had in it changes who's kept (a stranger made
        # host, all of the game's computers being out of the lobby, changes nothing: it could keep
        # names forever, and fill the room's list)
        trusted = not was_started or conn.id in r.get('listed', ())
        if trusted:
            r['listed'] = listed
        now = time.monotonic()
        # (one in the game whose name the list had no room for (others filled it): kept now,
        # past MAX_OWNERS: those in a game are 8 at most, and its seat goes by that name)
        for i in listed if trusted else ():
            c = r['peers'].get(i)
            if c is not None and c.name and c.token and c.name not in r['owners'] and len(r['owners']) < MAX_OWNERS + 2 * MAX_PEERS:
                r['owners'][c.name] = {'token': c.token, 'ip': c.ip, 'wide': c.wide, 'id': c.id, 'until': None, 'member': True}
        for e in r['owners'].values() if trusted else ():
            if e['member'] and e['id'] not in listed and e['until'] is not None:
                e['until'] = max(e['until'], now + NAME_HOLD)   # (out of the game now: a while yet)
            e['member'] = e['id'] in listed
        return True
    if t == 'kick':
        # (once a game ran, a host the last list didn't have in it (a stranger made host, all of
        # the game's computers being out of the lobby) removes nobody: it could keep the game's
        # players out of the room when they come back)
        if r['info'].get('started') and conn.id not in r.get('listed', ()):
            return True
        tid = msg.get('id') if isinstance(msg.get('id'), str) else None
        target = r['peers'].get(tid) if tid is not None else None
        # (one whose lobby connection went (it may play on, over its peer connections): kept out
        # all the same, by the address it came from)
        seen = r.get('seen', {}).get(tid)
        addr = (target.ip, target.wide) if target is not None else seen[:2] if seen else None
        before = len(r['banned'])
        # (its browser too, by its token: from another address it'd come back as itself, name and
        # seat; and its kept name goes)
        tok = target.token if target is not None else seen[2] if seen else None
        if addr is not None and tid != conn.id:
            ip, wide = addr
            # (a room's list of addresses kept out: MAX_BANNED at most, so a host removing ever
            # new addresses can't grow it for ever; it still removes them)
            room_left = len(r['banned']) < MAX_BANNED
            if ip != conn.ip and room_left:   # not the host's own address (same home, or testing)
                again = ip in r['banned']   # (another computer of a home removed already)
                r['banned'].add(ip)
                # IPv6: a second /64 removed from one /48 is someone with many /64s: the whole
                # /48 goes (not the host's own /48)
                if wide and wide != conn.wide and not again:
                    r['removed48'][wide] += 1
                    if r['removed48'][wide] >= 2 and wide not in r['banned']:
                        r['banned'].add(wide)
                        note('/48s banned from a room', wide,
                             f'a host ({conn.ip}) banned {wide[:-1]} from a room (a second /64 from it removed)')
        # it, and the room's other connections from its address (it may have come back already
        # under another id: the same browser or home); not its /48's others (other homes of an
        # ISP: a /48 ban only keeps new ones out), never the host's own
        if not tok or tid == conn.id or same_token(tok, conn.token):
            tok = None   # (never the host's own)
        # (and its browser here now under another id, from wherever: it has the same token)
        out = [c for c in r['peers'].values() if c is not conn and (c is target or (addr is not None and c.ip == addr[0] and c.ip != conn.ip)
                                                                   or (tok and c.token and same_token(c.token, tok)))]
        # its browser too, by its token (the same browser back under another id has it too): from
        # another address it'd come back as itself, name and seat; its kept names go. Not the
        # others going with it (a home's other browsers, a shared address's), never the host's own.
        for t in {x for x in [tok] if x}:
            if t not in r['kicked'] and len(r['kicked']) < MAX_KICKED:
                r['kicked'].add(t)
                before = -1   # (something new kept out)
            for n in [n for n, e in r['owners'].items() if e['token'] == t]:
                del r['owners'][n]
        # (said only when it did something: kicks of one long gone, over and over, would fill the log)
        if addr is not None and tid != conn.id and (out or len(r['banned']) != before):
            note('removed by a host', addr[0], f'a host ({conn.ip}) removed {addr[0]} from a room')
        for c in out:
            await leave(c)       # out of the room first: the others hear of it even if it stalls
            await c.send({'t': 'kicked'})
            c.writer.close()
            # gone for sure in 2 s, even if it doesn't read what's left
            asyncio.get_running_loop().call_later(2, abort, c.writer)
        return True
    return False


async def leave(conn):
    r = rooms.get(conn.room)
    if r is None or r['peers'].pop(conn.id, None) is None:
        conn.room = None
        return
    # its name stays kept for it a while (a reload, a seat held for it by name), unless another
    # connection here has it (this browser's next page)
    e = r['owners'].get(conn.name)
    if e is not None and same_token(e['token'], conn.token) and not any(c.name == conn.name for c in r['peers'].values()):
        e['until'] = time.monotonic() + NAME_HOLD
    if r['host'] == conn.id and not r['info'].get('started'):
        # the host before the game started: most likely a reload, whose page comes back in a
        # moment with its token; its room and its role wait for it (else: host_gone)
        r['away'] = (conn.name, time.monotonic() + HOST_GRACE, conn.token)
        room = conn.room
        asyncio.get_running_loop().call_later(HOST_GRACE + 0.1, lambda: asyncio.ensure_future(host_gone(room, r)))
        for c in list(r['peers'].values()):
            await c.send({'t': 'left', 'id': conn.id})
    elif not r['peers'] and r.get('away') is None:   # (the host away: host_gone decides)
        r['public'] = False
        recount(r)
        del rooms[conn.room]
    else:
        new_host = r['host'] == conn.id
        if new_host:
            # one the host listed as in the game, if any: pages trust the host to be in a game
            # that runs (it confirms joins); a stranger in the room can't become host this way
            listed = [i for i in r.get('members', []) if i in r['peers']]
            r['host'] = listed[0] if listed else next(iter(r['peers']))
            # the new host's address may be at its limit of listed games already
            if r['public'] and not may_list(r, r['peers'][r['host']]):
                r['public'] = False
            recount(r)
            if r['info']:
                r['info']['name'] = r['peers'][r['host']].name
        # a copy: others can leave while this one waits to send
        for c in list(r['peers'].values()):
            await c.send({'t': 'left', 'id': conn.id})
            if new_host:
                await c.send({'t': 'host', 'id': r['host'], 'public': r['public'], 'started': r['info'].get('started') is True})
    conn.room = None


async def host_gone(room, r):
    """the host's page didn't come back (leave): the room goes if it's empty, else the host's role"""
    if rooms.get(room) is not r or r.get('away') is None or time.monotonic() < r['away'][1]:
        return
    r['away'] = None
    if not r['peers']:
        r['public'] = False
        recount(r)
        del rooms[room]
        return
    listed = [i for i in r.get('members', []) if i in r['peers']]
    r['host'] = listed[0] if listed else next(iter(r['peers']))
    if r['public'] and not may_list(r, r['peers'][r['host']]):
        r['public'] = False
    recount(r)
    if r['info']:
        r['info']['name'] = r['peers'][r['host']].name
    for c in list(r['peers'].values()):
        await c.send({'t': 'host', 'id': r['host'], 'public': r['public'], 'started': r['info'].get('started') is True})


async def keepalive(conn):
    while True:
        await asyncio.sleep(PING_EVERY)
        if time.monotonic() - conn.heard > IDLE_LIMIT:
            note('cut off: silent')
            abort(conn.writer)   # silent too long: its handler ends and cleans up
            return
        await conn.control(9)


async def close_writer(writer):
    try:
        writer.close()
        await asyncio.wait_for(writer.wait_closed(), 5)
    except Exception:
        pass
    abort(writer)   # still open after 5 s (a client that doesn't read): at once


async def main(host='127.0.0.1', port=8767):
    server = await asyncio.start_server(handle, host, port, limit=16384)
    # a small receive buffer (the connections taken get the listening socket's; Linux doubles
    # it): what clients send faster than it's read here waits in nginx and with them, not in the
    # kernel on this service's memory (megabytes a connection otherwise: a flood from a hundred
    # connections got the service killed at its MemoryMax). A message is 16 KB at most
    for sock in server.sockets:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024)
        except OSError:
            pass
    reporter = asyncio.ensure_future(report())
    sweeper = asyncio.ensure_future(sweep())
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8767
    print(f'signaling on 127.0.0.1:{port}', flush=True)
    asyncio.run(main('127.0.0.1', port))
