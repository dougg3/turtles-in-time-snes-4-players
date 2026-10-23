#!/usr/bin/env python3
"""65816 disassembler for the LoROM TMNT IV image.

M/X widths come from a Mesen CDL file when one is given (flags recorded for
every executed instruction); otherwise they are tracked statically through
REP/SEP and marked with '?' when unknown.

Usage:
  dis65816.py ROM ADDR [-n COUNT] [--cdl FILE] [--m 8|16] [--x 8|16]
ADDR is a SNES address like 00:8000 or 008000.
"""
import argparse
import sys

# fmt: off
OPS = [
 ("BRK","imm8"),("ORA","dpxi"),("COP","imm8"),("ORA","sr"),("TSB","dp"),("ORA","dp"),("ASL","dp"),("ORA","dpil"),
 ("PHP","imp"),("ORA","immm"),("ASL","acc"),("PHD","imp"),("TSB","abs"),("ORA","abs"),("ASL","abs"),("ORA","long"),
 ("BPL","rel"),("ORA","dpiy"),("ORA","dpi"),("ORA","sriy"),("TRB","dp"),("ORA","dpx"),("ASL","dpx"),("ORA","dpily"),
 ("CLC","imp"),("ORA","absy"),("INC","acc"),("TCS","imp"),("TRB","abs"),("ORA","absx"),("ASL","absx"),("ORA","longx"),
 ("JSR","abs"),("AND","dpxi"),("JSL","long"),("AND","sr"),("BIT","dp"),("AND","dp"),("ROL","dp"),("AND","dpil"),
 ("PLP","imp"),("AND","immm"),("ROL","acc"),("PLD","imp"),("BIT","abs"),("AND","abs"),("ROL","abs"),("AND","long"),
 ("BMI","rel"),("AND","dpiy"),("AND","dpi"),("AND","sriy"),("BIT","dpx"),("AND","dpx"),("ROL","dpx"),("AND","dpily"),
 ("SEC","imp"),("AND","absy"),("DEC","acc"),("TSC","imp"),("BIT","absx"),("AND","absx"),("ROL","absx"),("AND","longx"),
 ("RTI","imp"),("EOR","dpxi"),("WDM","imm8"),("EOR","sr"),("MVP","move"),("EOR","dp"),("LSR","dp"),("EOR","dpil"),
 ("PHA","imp"),("EOR","immm"),("LSR","acc"),("PHK","imp"),("JMP","abs"),("EOR","abs"),("LSR","abs"),("EOR","long"),
 ("BVC","rel"),("EOR","dpiy"),("EOR","dpi"),("EOR","sriy"),("MVN","move"),("EOR","dpx"),("LSR","dpx"),("EOR","dpily"),
 ("CLI","imp"),("EOR","absy"),("PHY","imp"),("TCD","imp"),("JML","long"),("EOR","absx"),("LSR","absx"),("EOR","longx"),
 ("RTS","imp"),("ADC","dpxi"),("PER","rell"),("ADC","sr"),("STZ","dp"),("ADC","dp"),("ROR","dp"),("ADC","dpil"),
 ("PLA","imp"),("ADC","immm"),("ROR","acc"),("RTL","imp"),("JMP","absi"),("ADC","abs"),("ROR","abs"),("ADC","long"),
 ("BVS","rel"),("ADC","dpiy"),("ADC","dpi"),("ADC","sriy"),("STZ","dpx"),("ADC","dpx"),("ROR","dpx"),("ADC","dpily"),
 ("SEI","imp"),("ADC","absy"),("PLY","imp"),("TDC","imp"),("JMP","absxi"),("ADC","absx"),("ROR","absx"),("ADC","longx"),
 ("BRA","rel"),("STA","dpxi"),("BRL","rell"),("STA","sr"),("STY","dp"),("STA","dp"),("STX","dp"),("STA","dpil"),
 ("DEY","imp"),("BIT","immm"),("TXA","imp"),("PHB","imp"),("STY","abs"),("STA","abs"),("STX","abs"),("STA","long"),
 ("BCC","rel"),("STA","dpiy"),("STA","dpi"),("STA","sriy"),("STY","dpx"),("STA","dpx"),("STX","dpy"),("STA","dpily"),
 ("TYA","imp"),("STA","absy"),("TXS","imp"),("TXY","imp"),("STZ","abs"),("STA","absx"),("STZ","absx"),("STA","longx"),
 ("LDY","immx"),("LDA","dpxi"),("LDX","immx"),("LDA","sr"),("LDY","dp"),("LDA","dp"),("LDX","dp"),("LDA","dpil"),
 ("TAY","imp"),("LDA","immm"),("TAX","imp"),("PLB","imp"),("LDY","abs"),("LDA","abs"),("LDX","abs"),("LDA","long"),
 ("BCS","rel"),("LDA","dpiy"),("LDA","dpi"),("LDA","sriy"),("LDY","dpx"),("LDA","dpx"),("LDX","dpy"),("LDA","dpily"),
 ("CLV","imp"),("LDA","absy"),("TSX","imp"),("TYX","imp"),("LDY","absx"),("LDA","absx"),("LDX","absy"),("LDA","longx"),
 ("CPY","immx"),("CMP","dpxi"),("REP","imm8"),("CMP","sr"),("CPY","dp"),("CMP","dp"),("DEC","dp"),("CMP","dpil"),
 ("INY","imp"),("CMP","immm"),("DEX","imp"),("WAI","imp"),("CPY","abs"),("CMP","abs"),("DEC","abs"),("CMP","long"),
 ("BNE","rel"),("CMP","dpiy"),("CMP","dpi"),("CMP","sriy"),("PEI","dpi"),("CMP","dpx"),("DEC","dpx"),("CMP","dpily"),
 ("CLD","imp"),("CMP","absy"),("PHX","imp"),("STP","imp"),("JML","absil"),("CMP","absx"),("DEC","absx"),("CMP","longx"),
 ("CPX","immx"),("SBC","dpxi"),("SEP","imm8"),("SBC","sr"),("CPX","dp"),("SBC","dp"),("INC","dp"),("SBC","dpil"),
 ("INX","imp"),("SBC","immm"),("NOP","imp"),("XBA","imp"),("CPX","abs"),("SBC","abs"),("INC","abs"),("SBC","long"),
 ("BEQ","rel"),("SBC","dpiy"),("SBC","dpi"),("SBC","sriy"),("PEA","imm16"),("SBC","dpx"),("INC","dpx"),("SBC","dpily"),
 ("SED","imp"),("SBC","absy"),("PLX","imp"),("XCE","imp"),("JSR","absxi"),("SBC","absx"),("INC","absx"),("SBC","longx"),
]
# fmt: on

FIXED_LEN = {
    "imp": 1, "acc": 1, "imm8": 2, "imm16": 3, "dp": 2, "dpx": 2, "dpy": 2, "dpi": 2,
    "dpxi": 2, "dpiy": 2, "dpil": 2, "dpily": 2, "sr": 2, "sriy": 2, "abs": 3, "absx": 3,
    "absy": 3, "absi": 3, "absxi": 3, "absil": 3, "long": 4, "longx": 4, "rel": 2,
    "rell": 3, "move": 3,
}
FMT = {
    "imp": "", "acc": "A", "imm8": "#${:02X}", "imm16": "${:04X}", "dp": "${:02X}",
    "dpx": "${:02X},X", "dpy": "${:02X},Y", "dpi": "(${:02X})", "dpxi": "(${:02X},X)",
    "dpiy": "(${:02X}),Y", "dpil": "[${:02X}]", "dpily": "[${:02X}],Y", "sr": "${:02X},S",
    "sriy": "(${:02X},S),Y", "abs": "${:04X}", "absx": "${:04X},X", "absy": "${:04X},Y",
    "absi": "(${:04X})", "absxi": "(${:04X},X)", "absil": "[${:04X}]", "long": "${:06X}",
    "longx": "${:06X},X",
}
CDL_CODE, CDL_X8, CDL_M8 = 0x01, 0x10, 0x20
TERMINATORS = {"RTS", "RTL", "RTI", "STP"}


def snes_to_file(addr):
    """LoROM: banks $00-$7D/$80-$FF, upper half of each bank maps 32 KiB of ROM."""
    bank, off = (addr >> 16) & 0x7F, addr & 0xFFFF
    if off < 0x8000:
        raise ValueError(f"${addr:06X} is not ROM in LoROM")
    return bank * 0x8000 + (off - 0x8000)


def file_to_snes(fo):
    return ((fo // 0x8000) << 16) | (0x8000 + fo % 0x8000)


def instruction_starts(rom, cdl):
    """Mesen flags every byte of an executed instruction as code, so recover the
    opcode positions by decoding forward from the start of each run of code
    bytes, using the run's recorded M/X flags."""
    d = Disassembler(rom, cdl)
    starts = []
    fo = 0
    while fo < len(cdl):
        if not cdl[fo] & CDL_CODE:
            fo += 1
            continue
        # walk this run
        while fo < len(cdl) and cdl[fo] & CDL_CODE:
            starts.append(fo)
            n = d.decode(file_to_snes(fo), None, None)[0]
            crosses = fo % 0x8000 + n > 0x8000
            fo += n
            if crosses:
                break  # instruction ran past the end of a LoROM bank half: end the run
    return starts


def parse_addr(s):
    return int(s.replace(":", "").replace("$", ""), 16)


class Disassembler:
    def __init__(self, rom, cdl=None):
        self.rom, self.cdl = rom, cdl

    def decode(self, addr, m8, x8):
        """Return (length, text, mnemonic, operand_value, m8, x8) for one instruction.
        m8/x8 may be None (unknown); the returned widths are the state after the instruction."""
        fo = snes_to_file(addr)
        if self.cdl and self.cdl[fo] & CDL_CODE:
            m8 = bool(self.cdl[fo] & CDL_M8)
            x8 = bool(self.cdl[fo] & CDL_X8)
        op = self.rom[fo]
        mn, mode = OPS[op]
        unsure = ""
        if mode == "immm":
            n = 2 if m8 else 3
            unsure = "?" if m8 is None else ""
        elif mode == "immx":
            n = 2 if x8 else 3
            unsure = "?" if x8 is None else ""
        else:
            n = FIXED_LEN[mode]
        b = self.rom[fo + 1:fo + n]
        val = int.from_bytes(b, "little") if b else None
        if mode in ("immm", "immx"):
            text = f"#${val:0{2 * (n - 1)}X}{unsure}"
        elif mode == "rel":
            val = (addr & 0xFF0000) | ((addr + 2 + (val - 256 if val > 127 else val)) & 0xFFFF)
            text = f"${val & 0xFFFF:04X}"
        elif mode == "rell":
            val = (addr & 0xFF0000) | ((addr + 3 + (val - 65536 if val > 32767 else val)) & 0xFFFF)
            text = f"${val & 0xFFFF:04X}"
        elif mode == "move":
            text = f"${b[1]:02X},${b[0]:02X}"
        else:
            text = FMT[mode].format(val) if val is not None else FMT[mode]
        if mn == "REP":
            if val & 0x20: m8 = False
            if val & 0x10: x8 = False
        elif mn == "SEP":
            if val & 0x20: m8 = True
            if val & 0x10: x8 = True
        elif mn in ("PLP", "RTI", "XCE"):
            m8 = x8 = None
        return n, f"{mn} {text}".rstrip(), mn, val, m8, x8

    def listing(self, addr, count, m8=None, x8=None, stop=False):
        lines = []
        for _ in range(count):
            fo = snes_to_file(addr)
            executed = bool(self.cdl and self.cdl[fo] & CDL_CODE)
            n, text, mn, _, m8, x8 = self.decode(addr, m8, x8)
            raw = " ".join(f"{x:02X}" for x in self.rom[fo:fo + n])
            mark = "" if not self.cdl else ("  " if executed else "~ ")
            lines.append(f"{mark}{addr >> 16:02X}:{addr & 0xFFFF:04X}  {raw:<12} {text}")
            if stop and mn in TERMINATORS:
                break
            addr = (addr & 0xFF0000) | ((addr + n) & 0xFFFF)
        return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("addr")
    ap.add_argument("-n", type=int, default=40)
    ap.add_argument("--cdl")
    ap.add_argument("--m", type=int, choices=(8, 16))
    ap.add_argument("--x", type=int, choices=(8, 16))
    ap.add_argument("--stop", action="store_true", help="stop at RTS/RTL/RTI")
    a = ap.parse_args()
    rom = open(a.rom, "rb").read()
    cdl = open(a.cdl, "rb").read() if a.cdl else None
    d = Disassembler(rom, cdl)
    m8 = None if a.m is None else a.m == 8
    x8 = None if a.x is None else a.x == 8
    print("\n".join(d.listing(parse_addr(a.addr), a.n, m8, x8, a.stop)))


if __name__ == "__main__":
    sys.exit(main())
