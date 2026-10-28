#!/usr/bin/env python3
"""Builds for the other variants of the game (Europe, Australia, Japan).

The patches are written against the USA ROM. The other variants are the same program
with code and data moved, so a variant build is the USA patch source with every ROM
address translated:

  variants.py align V          byte alignment of the USA ROM and variant V, per 32 KB
                               bank (difflib; cached in build/variants/V/align.json)
  variants.py genmap V         (re)write patches/variants/V.map: every ROM address the
                               patch source names ($BBAAAA, banks $00-$1F), translated.
                               Lines marked "manual" are kept as they are
  variants.py translate V OUT  copy patches/ to OUT with the addresses translated
                               (fails on an address the map doesn't have or marks "?")
  variants.py check V BUILD    compare the variant build's changes with the USA build's

Map kinds: same (the bank is identical), exact (the byte is in an aligned run),
operand (inside bytes that changed because they hold a moved address: the delta of
the aligned bytes on both sides), free (USA free space that is free in V too),
manual (chosen by hand; the note says why), ? (unresolved: the build refuses).
"allow ADDR LEN note" lines: variant bytes a variant-only hook may change (check).

16-bit ROM pointers in the source are written as a16($BBAAAA) so they get translated
too; values copied from the game's own tables are read with read2() from the
variant's clean ROM.
"""
import difflib
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORIG = os.path.join(ROOT, "original")
PATCHES = os.path.join(ROOT, "patches")

VARIANTS = {
    "us": ("USA", "Teenage Mutant Ninja Turtles IV - Turtles in Time (USA).sfc", "4f8fc0f45023e0339e501054b253c33f479a001a"),
    "eu": ("Europe", "Teenage Mutant Hero Turtles IV - Turtles in Time (Europe).sfc",
           "59add584f16b607607348e65c245ca6ad7a5fcb8"),
    "au": ("Australia", "Teenage Mutant Ninja Turtles IV - Turtles in Time (Australia).sfc",
           "c4ba9b0fd1b40a228e6bb1170ec227dac5b83ce5"),
    "jp": ("Japan", "Teenage Mutant Ninja Turtles - Turtles in Time (Japan).sfc",
           "514e7fb70e1e5e06c5a873262e145a555655d62d"),
}
BANK = 0x8000
LITERAL = re.compile(r"\$([0-9A-Fa-f]{6})\b")


def rom(v):
    data = open(os.path.join(ORIG, VARIANTS[v][1]), "rb").read()
    if hashlib.sha1(data).hexdigest() != VARIANTS[v][2]:
        sys.exit("%s: not the expected %s ROM (SHA-1 mismatch)" % (VARIANTS[v][1], VARIANTS[v][0]))
    return data


def snes(o):
    return (o // BANK) << 16 | 0x8000 | (o % BANK)


def file_off(addr):
    """File offset of a ROM address in banks $00-$1F (or their $80 mirrors), else None."""
    bank, off = (addr >> 16) & 0x7F, addr & 0xFFFF
    if bank >= 0x20 or off < 0x8000:
        return None
    return bank * BANK + off - 0x8000


def align(v):
    path = os.path.join(ROOT, "build", "variants", v, "align.json")
    if os.path.exists(path):
        return json.load(open(path))
    us, var = rom("us"), rom(v)
    blocks = []
    for b in range(len(us) // BANK):
        s = b * BANK
        x, y = us[s:s + BANK], var[s:s + BANK]
        if x == y:
            blocks.append([s, s, BANK])
            continue
        print("aligning bank $%02X" % b, file=sys.stderr)
        for i, j, n in difflib.SequenceMatcher(None, x, y, autojunk=False).get_matching_blocks():
            if n >= 4:
                blocks.append([s + i, s + j, n])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(blocks, open(path, "w"))
    return blocks


class Mapper:
    def __init__(self, v):
        self.us, self.var = rom("us"), rom(v)
        self.blocks = sorted(align(v))
        self.starts = [b[0] for b in self.blocks]

    def _block(self, o):
        import bisect
        k = bisect.bisect_right(self.starts, o) - 1
        return self.blocks[k] if k >= 0 else None

    def _delta(self, o):
        b = self._block(o)
        if b and b[0] <= o < b[0] + b[2]:
            return b[1] - b[0]
        return None

    def map(self, o):
        """(variant offset or None, kind)"""
        b = self._block(o)
        if b and b[0] <= o < b[0] + b[2]:
            return o + b[1] - b[0], "same" if b[2] == BANK else "exact"
        # inside changed bytes: the aligned bytes on both sides must agree on the delta
        before = after = None
        for r in range(1, 17):
            if before is None and o - r >= 0 and o - r >= o // BANK * BANK:
                before = self._delta(o - r)
            if after is None and o + r < (o // BANK + 1) * BANK:
                after = self._delta(o + r)
        if before is not None and before == after:
            return o + before, "operand"
        return None, "?"

    def near(self, o, span=48):
        """Variant offset of the instruction at USA offset o when its bytes changed
        (moved operands): the nearest aligned delta whose image has the same opcode."""
        for r in range(1, span):
            for x in (o - r, o + r):
                d = self._delta(x)
                if d is not None and 0 <= o + d < len(self.var) and self.var[o + d] == self.us[o]:
                    return o + d
        return None

    def is_free(self, data, o, n=16):
        return data[o:o + n] == b"\xff" * n


def literals():
    """Every ROM address named in the code (not the comments) of patches/*.asm."""
    found = {}
    for name in sorted(os.listdir(PATCHES)):
        if not name.endswith(".asm"):
            continue
        for n, line in enumerate(open(os.path.join(PATCHES, name)), 1):
            code = line.split(";", 1)[0]
            for m in LITERAL.finditer(code):
                o = file_off(int(m.group(1), 16))
                if o is not None:
                    found.setdefault(o, "%s:%d" % (name, n))
    return found


def map_path(v):
    return os.path.join(PATCHES, "variants", v + ".map")


def read_map(v):
    entries = {}
    if not os.path.exists(map_path(v)):
        return entries
    for line in open(map_path(v)):
        f = line.split("#", 1)[0].split(None, 3)
        if len(f) >= 3 and f[0] != "allow":
            entries[file_off(int(f[0], 16))] = (None if f[1] == "?" else int(f[1], 16), f[2], f[3].strip() if len(f) > 3 else "")
    return entries


def genmap(v):
    m = Mapper(v)
    old = read_map(v)
    allows = [l.rstrip("\n") for l in open(map_path(v)) if l.startswith("allow ")] if os.path.exists(map_path(v)) else []
    lines = []
    bad = 0
    for o, where in sorted(literals().items()):
        a = snes(o)
        if o in old and old[o][1] == "manual":
            t, kind, note = old[o]
            lines.append("%06X %06X manual %s" % (a, t, note))
            continue
        elif m.is_free(m.us, o):
            kind = "free" if m.is_free(m.var, o) else "?"
            t, note = (o if kind == "free" else None), ("USA free space" + ("" if kind == "free" else ", used in this variant"))
        else:
            t, kind = m.map(o)
            note = ""
        if t is None:
            bad += 1
        lines.append("%06X %s %s %s" % (a, "?" if t is None else "%06X" % snes(t), kind, (note or where)))
    os.makedirs(os.path.dirname(map_path(v)), exist_ok=True)
    with open(map_path(v), "w") as f:
        f.write("# USA -> %s ROM addresses (scripts/variants.py genmap %s; \"manual\" lines are kept)\n"
                % (VARIANTS[v][0], v))
        f.write("\n".join(lines + allows) + "\n")
    print("%s: %d addresses, %d unresolved" % (map_path(v), len(lines), bad))


def translate(v, out):
    entries = read_map(v)
    missing = set()

    def sub(m):
        addr = int(m.group(1), 16)
        o = file_off(addr)
        if o is None:
            return m.group(0)
        e = entries.get(o)
        if e is None or e[0] is None:
            missing.add(addr)
            return m.group(0)
        return "$%06X" % (e[0] | (addr & 0x800000))

    os.makedirs(out, exist_ok=True)
    for name in sorted(os.listdir(PATCHES)):
        if not name.endswith(".asm"):
            continue
        with open(os.path.join(out, name), "w") as f:
            for line in open(os.path.join(PATCHES, name)):
                code, sep, comment = line.partition(";")
                f.write(LITERAL.sub(sub, code) + sep + comment)
    if missing:
        sys.exit("unresolved in %s: %s" % (map_path(v), " ".join("$%06X" % a for a in sorted(missing))))


def runs(a, b, limit):
    out, i = [], 0
    while i < limit:
        if a[i] != b[i]:
            j = i
            while j < limit and a[j] != b[j]:
                j += 1
            out.append((i, j))
            i = j
        else:
            i += 1
    return out


def in_free_run(data, o, n=16):
    """o is in a run of at least n $FF bytes (free space, not a $FF inside code)."""
    if data[o] != 0xFF:
        return False
    i = j = o
    while i > 0 and data[i - 1] == 0xFF:
        i -= 1
    while j + 1 < len(data) and data[j + 1] == 0xFF:
        j += 1
    return j + 1 - i >= n


def check(v, build, usa_build):
    """The variant build should change the images of the bytes the USA build changes,
    variant free space, and the places the map's manual lines chose."""
    m = Mapper(v)
    us_p = open(usa_build, "rb").read()
    var_p = open(build, "rb").read()
    n = len(m.us)
    header = set(range(0x7FC0, 0x7FE0))
    placed = {file_off(t) for t, kind, note in read_map(v).values() if kind == "manual" and t is not None}
    entries = read_map(v)
    allowed = set()
    for line in open(map_path(v)):
        f = line.split()
        if len(f) >= 3 and f[0] == "allow":
            a = file_off(int(f[1], 16))
            allowed.update(range(a, a + int(f[2])))
    expect = {}
    unmapped = []
    for i, j in runs(m.us, us_p, n):
        # a long call/jump whose operand changed: the whole operand (a target moved to
        # another bank changes a byte the USA build kept)
        if m.us[i - 1] in (0x22, 0x5C) and j - i < 3:
            j = i + 3
        # a run at (or just after) an address the patch names moves with the map's line
        base = next((u for u in range(i, max(i - 4, 0), -1) if u in entries and entries[u][0] is not None
                     and file_off(entries[u][0]) is not None), None)
        for o in range(i, j):
            if o in header or in_free_run(m.us, o):
                continue
            if base is not None:
                t, kind = file_off(entries[base][0]) + o - base, "map"
            else:
                t, kind = m.map(o)
            if t is None:
                # an operand byte of a moved long call
                for k in (1, 2, 3):
                    if m.us[o - k] in (0x22, 0x5C) and m.near(o - k) is not None:
                        t = m.near(o - k) + k
                        break
            if t is None:
                unmapped.append(o)
            else:
                expect[t] = o
    errors = 0
    for i, j in runs(m.var, var_p, n):
        if i in placed:
            continue
        stray = [o for o in range(i, j) if o not in expect and o not in header and o not in allowed
                 and not in_free_run(m.var, o)]
        if stray:
            errors += 1
            print("unexpected change at $%06X (+%d)" % (snes(stray[0]), len(stray)))
    for o in unmapped:
        print("USA patched byte $%06X has no image in %s" % (snes(o), VARIANTS[v][0]))
    # an image left unchanged is fine when the variant byte already is what the USA
    # build wrote (e.g. a moved operand); list them for a look
    same = [(t, o) for t, o in sorted(expect.items()) if var_p[t] == m.var[t] and us_p[o] != m.us[o]]
    for t, o in same:
        print("  unchanged: USA $%06X %02X->%02X, %s $%06X stays %02X"
              % (snes(o), m.us[o], us_p[o], v, snes(t), m.var[t]))
    # long jumps/calls/accesses in the new code (banks $20-): same layout in both builds,
    # so each operand into the original ROM must be the translation of the USA one (a
    # missed literal, e.g. one built by a macro, still points at the USA address)
    # (instruction starts from the USA build's symbol file: its line-number section)
    starts = set()
    for line in open(usa_build[:-4] + ".sym"):
        f = line.split()
        if len(f) == 2 and ":" in f[0] and ":" in f[1] and len(f[0]) == 7:
            a = int(f[0].replace(":", ""), 16)
            if (a >> 16) & 0x7F >= 0x20:
                starts.add(((a >> 16) & 0x3F) * BANK + (a & 0x7FFF))
    wrong = 0
    for o in sorted(starts):
        if o + 4 > min(len(us_p), len(var_p)):
            continue
        if us_p[o] not in (0x22, 0x5C, 0xAF, 0xBF, 0x8F, 0x9F, 0xCF, 0xDF) or var_p[o] != us_p[o]:
            continue
        a = int.from_bytes(us_p[o + 1:o + 4], "little")
        b = int.from_bytes(var_p[o + 1:o + 4], "little")
        src = file_off(a)
        # (code banks only: elsewhere a match is more likely data that looks like an opcode)
        if src is None or src >= 6 * BANK or a == b and m.map(src)[0] == src:
            continue
        t = m.map(src)[0]
        if t is not None and snes(t) | (a & 0x800000) == b:
            continue
        if a == b:
            wrong += 1
            print("  new code $%06X: operand $%06X not translated (%s: $%s)" % (
                snes(o), a, VARIANTS[v][0], "?" if t is None else "%06X" % snes(t)))
    print("%s: %d unexpected change runs, %d unmapped USA bytes, %d unchanged images, %d untranslated operands"
          % (VARIANTS[v][0], errors, len(unmapped), len(same), wrong))
    return errors == 0 and not unmapped and not wrong


def main():
    if len(sys.argv) < 3 or sys.argv[2] not in VARIANTS or sys.argv[2] == "us":
        sys.exit(__doc__)
    cmd, v = sys.argv[1], sys.argv[2]
    if cmd == "align":
        align(v)
    elif cmd == "genmap":
        genmap(v)
    elif cmd == "translate":
        translate(v, sys.argv[3])
    elif cmd == "check":
        sys.exit(0 if check(v, sys.argv[3], sys.argv[4]) else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
