#!/usr/bin/env python3
"""Analyze runner.lua instruction traces (<u24 addr><u64 master clock> records).

  trace_tool.py ROM TRACE frames      per-NMI-frame timing and top-level call profile
  trace_tool.py ROM TRACE calls       inclusive master-clock cost of every JSR/JSL target
  trace_tool.py ROM TRACE idle        most-executed addresses (finds idle/wait loops)
  trace_tool.py ROM TRACE stack ADDR  distinct call chains (call-site addresses) reaching ADDR

NTSC frame = 357,368 master clocks (1364 x 262). CPU cycles are 6/8/12 master
clocks depending on the memory region, so master clocks are the honest unit.
"""
import sys
from collections import Counter, defaultdict

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from dis65816 import snes_to_file  # noqa: E402

NMI_HANDLER = 0x008174
FRAME_CLOCKS = 357368
CALLS = {0x20: "JSR", 0x22: "JSL", 0xFC: "JSR"}
RETURNS = {0x60: "RTS", 0x6B: "RTL", 0x40: "RTI"}


def records(path):
    data = open(path, "rb").read()
    for i in range(0, len(data), 11):
        addr = int.from_bytes(data[i:i + 3], "little")
        clk = int.from_bytes(data[i + 3:i + 11], "little")
        yield addr, clk


def opcode(rom, addr):
    try:
        return rom[snes_to_file(addr)]
    except ValueError:
        return None  # executing from RAM


def call_profile(rom, recs):
    """Shadow call stack. Returns {target: [count, inclusive_clocks]}."""
    stack = []  # (target, start_clock)
    prof = defaultdict(lambda: [0, 0])
    pending_call = False
    for i, (addr, clk) in enumerate(recs):
        if pending_call:
            stack.append((addr, clk))
            pending_call = False
        op = opcode(rom, addr)
        if op in CALLS:
            pending_call = True
        elif op in RETURNS and stack:
            # charge up to the return instruction's successor
            tgt, start = stack.pop()
            end = recs[i + 1][1] if i + 1 < len(recs) else clk
            prof[tgt][0] += 1
            prof[tgt][1] += end - start
    return prof


def frames(rom, recs):
    """Split at NMI entries; report busy time = from NMI entry to the last
    instruction before the CPU starts spinning in the most common loop."""
    starts = [i for i, (a, _) in enumerate(recs) if a == NMI_HANDLER]
    out = []
    for n, s in enumerate(starts):
        e = starts[n + 1] if n + 1 < len(starts) else len(recs)
        seg = recs[s:e]
        out.append(seg)
    return out


def main():
    rom = open(sys.argv[1], "rb").read()
    recs = list(records(sys.argv[2]))
    mode = sys.argv[3] if len(sys.argv) > 3 else "frames"
    if mode == "idle":
        c = Counter(a for a, _ in recs)
        for a, n in c.most_common(25):
            print(f"{a >> 16:02X}:{a & 0xFFFF:04X} {n}")
    elif mode == "calls":
        prof = call_profile(rom, recs)
        total = recs[-1][1] - recs[0][1]
        print(f"trace span {total} master clocks = {total / FRAME_CLOCKS:.2f} frames")
        for tgt, (n, clk) in sorted(prof.items(), key=lambda kv: -kv[1][1])[:60]:
            print(f"{tgt >> 16:02X}:{tgt & 0xFFFF:04X} calls={n:5d} incl={clk:9d} "
                  f"({100 * clk / total:5.1f}% of span)")
    elif mode == "stack":
        target = int(sys.argv[4].replace(":", ""), 16)
        chains = Counter()
        stack = []  # call-site addresses
        for addr, _ in recs:
            if addr == target:
                chains[tuple(stack)] += 1
            op = opcode(rom, addr)
            if op in CALLS:
                stack.append(addr)
            elif op in RETURNS and stack:
                stack.pop()
        for chain, n in chains.most_common(20):
            print(f"{n:5d}x  " + " > ".join(f"{a >> 16:02X}:{a & 0xFFFF:04X}" for a in chain))
    elif mode == "frames":
        for n, seg in enumerate(frames(rom, recs)):
            span = (seg[-1][1] - seg[0][1]) if len(seg) > 1 else 0
            print(f"NMI #{n}: {len(seg)} instructions, {span} clocks until next NMI/trace end")
            # top-level calls made directly by the NMI handler (depth 1)
            depth, cur, t0 = 0, None, 0
            pending = False
            for i, (addr, clk) in enumerate(seg):
                if pending:
                    if depth == 1:
                        cur, t0 = addr, clk
                    pending = False
                op = opcode(rom, addr)
                if op in CALLS:
                    depth += 1
                    pending = True
                elif op in RETURNS:
                    if depth == 1 and cur is not None:
                        end = seg[i + 1][1] if i + 1 < len(seg) else clk
                        print(f"    {cur >> 16:02X}:{cur & 0xFFFF:04X} {end - t0:8d} clocks "
                              f"({100 * (end - t0) / FRAME_CLOCKS:5.1f}% frame)")
                        cur = None
                    depth -= 1
                    if depth < 0:
                        print(f"    <return below NMI frame at {addr:06X}, clock {clk - seg[0][1]}>")
                        depth = 0


if __name__ == "__main__":
    main()
