#!/usr/bin/env python3
"""GTKWave translation filter for HP 21xx instruction words.

This script reads one value per line from stdin, decodes it as an HP 21xx
instruction word (TR), and writes one mnemonic per line to stdout.

Typical GTKWave usage:
  1. Add your 16-bit TR/disasm_bus signal to the waveform.
  2. Select the signal.
  3. Edit -> Data Format -> Translate Filter Process.
  4. Point GTKWave to this script.

Important:
  * GTKWave expects exactly one output line per input line.
  * stdout is flushed after every line.
"""

from __future__ import annotations

import sys
from typing import Optional


# Comment: Format the raw 10-bit memory operand field as a 6-digit octal address.
def fmt_mem_operand(tr: int) -> str:
    indirect = (tr >> 15) & 0x1
    addr = tr & 0x03FF
    if indirect:
        return f"{addr:06o},I"
    return f"{addr:06o}"


# Comment: Append a sub-mnemonic with a comma separator only when needed.
def append_part(base: str, part: str) -> str:
    if not part:
        return base
    if not base:
        return part
    return f"{base}, {part}"


# Comment: Decode one shift/rotate sub-operation.
def fmt_rotate_shift(code: int, a: int) -> str:
    acc = "B" if a else "A"
    table = {
        0o0: f"{acc}LS",
        0o1: f"{acc}RS",
        0o2: f"R{acc}L",
        0o3: f"R{acc}R",
        0o4: f"{acc}LR",
        0o5: f"ER{acc}",
        0o6: f"EL{acc}",
        0o7: f"{acc}LF",
    }
    return table.get(code & 0x7, "???")


# Comment: Decode the shift/rotate group.
def disasm_srg(tr: int) -> str:
    result = ""

    # Comment: First shift/rotate operation from bits [8:6].
    if (tr >> 9) & 0x1:
        result = append_part(result, fmt_rotate_shift((tr >> 6) & 0x7, (tr >> 11) & 0x1))

    # Comment: CLE when bit 5 is set.
    if (tr >> 5) & 0x1:
        result = append_part(result, "CLE")

    # Comment: SLA or SLB when bit 3 is set.
    if (tr >> 3) & 0x1:
        result = append_part(result, "SLB" if ((tr >> 11) & 0x1) else "SLA")

    # Comment: Final shift/rotate operation from bits [2:0].
    if (tr >> 4) & 0x1:
        result = append_part(result, fmt_rotate_shift(tr & 0x7, (tr >> 11) & 0x1))

    # Comment: A completely empty SRG word is treated as NOP.
    return result if result else "NOP"


# Comment: Decode the alter/skip group.
def disasm_asg(tr: int) -> str:
    acc = "B" if ((tr >> 11) & 0x1) else "A"
    result = ""

    if (tr & 0x03FF) == 0:
        return append_part(result, "NOP")

    top = (tr >> 8) & 0x3
    if top == 0o1:
        result = append_part(result, f"CL{acc}")
    elif top == 0o2:
        result = append_part(result, f"CM{acc}")
    elif top == 0o3:
        result = append_part(result, f"CC{acc}")

    if (tr >> 5) & 0x1:
        result = append_part(result, "SEZ")

    mid = (tr >> 6) & 0x3
    if mid == 0o1:
        result = append_part(result, "CLE")
    elif mid == 0o2:
        result = append_part(result, "CME")
    elif mid == 0o3:
        result = append_part(result, "CCE")

    if (tr >> 4) & 0x1:
        result = append_part(result, f"SS{acc}")
    if (tr >> 3) & 0x1:
        result = append_part(result, f"SL{acc}")
    if (tr >> 2) & 0x1:
        result = append_part(result, f"IN{acc}")
    if (tr >> 1) & 0x1:
        result = append_part(result, f"SZ{acc}")
    if tr & 0x1:
        result = append_part(result, "RSS")

    return result if result else "NOP"


# Comment: Decode the full 16-bit TR word into a mnemonic string.
def mini_disasm(tr: int) -> str:
    ir = (tr >> 10) & 0x3F
    op4 = (ir >> 1) & 0xF
    memop = fmt_mem_operand(tr)

    # Comment: Shift/rotate group and alter/skip group.
    if ((ir >> 2) & 0xF) == 0o00:
        if ir & 0x1:
            return disasm_asg(tr)
        return disasm_srg(tr)

    # Comment: I/O group. Non-I/O 10xxx group is left as ??? just like the SV code.
    if ((ir >> 2) & 0xF) == 0o10:
        if (ir & 0x1) == 0:
            return "???"

        subop = (tr >> 6) & 0x7
        sc = tr & 0x3F
        comma_c = ",C" if ((tr >> 9) & 0x1) else ""
        b_acc = (tr >> 11) & 0x1

        if subop == 0o0:
            if (tr >> 10) & 0x1:
                return f"HLT {sc:02o}{comma_c}"
            return "???"
        if subop == 0o1:
            return f"CLF {sc:02o}" if ((tr >> 9) & 0x1) else f"STF {sc:02o}"
        if subop == 0o2:
            return f"SFC {sc:02o}"
        if subop == 0o3:
            return f"SFS {sc:02o}"
        if subop == 0o4:
            return f"MIB {sc:02o}{comma_c}" if b_acc else f"MIA {sc:02o}{comma_c}"
        if subop == 0o5:
            return f"LIB {sc:02o}{comma_c}" if b_acc else f"LIA {sc:02o}{comma_c}"
        if subop == 0o6:
            return f"OTB {sc:02o}{comma_c}" if b_acc else f"OTA {sc:02o}{comma_c}"
        if subop == 0o7:
            return f"CLC {sc:02o}{comma_c}" if b_acc else f"STC {sc:02o}{comma_c}"
        return "???"

    # Comment: Memory reference instructions.
    table = {
        0o10: "ADA",
        0o11: "ADB",
        0o02: "AND",
        0o12: "CPA",
        0o13: "CPB",
        0o06: "IOR",
        0o07: "ISZ",
        0o05: "JMP",
        0o03: "JSB",
        0o14: "LDA",
        0o15: "LDB",
        0o16: "STA",
        0o17: "STB",
        0o04: "XOR",
    }
    mnemonic = table.get(op4)
    if mnemonic is None:
        return "???"
    return f"{mnemonic} {memop}"


# Comment: Parse one GTKWave input token into an integer TR value.
def parse_value(text: str) -> Optional[int]:
    s = text.strip()
    if not s:
        return None

    # Comment: GTKWave may pass values with unknown/high-impedance digits.
    if any(ch in s for ch in "xXzZuUwW-"):
        return None

    # Comment: Accept common prefixed formats.
    lowered = s.lower()
    try:
        if lowered.startswith("0x"):
            return int(lowered, 16) & 0xFFFF
        if lowered.startswith("0b"):
            return int(lowered, 2) & 0xFFFF
        if lowered.startswith("0o"):
            return int(lowered, 8) & 0xFFFF

        # Comment: If the token is pure binary, parse as binary.
        if set(s) <= {"0", "1"}:
            return int(s, 2) & 0xFFFF

        # Comment: GTKWave commonly feeds hex text to process filters.
        return int(s, 16) & 0xFFFF
    except ValueError:
        return None


# Comment: Main loop for GTKWave translate-filter mode.
def main() -> int:
    for line in sys.stdin:
        tr = parse_value(line)
        if tr is None:
            print("???")
            sys.stdout.flush()
            continue

        print(mini_disasm(tr))
        sys.stdout.flush()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
