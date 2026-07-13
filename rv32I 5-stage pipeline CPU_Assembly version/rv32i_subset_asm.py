#!/usr/bin/env python3
"""Small assembler for the exact RV32I subset implemented by this project.

Supported instructions:
  ADD, SUB, AND, OR, ADDI, LW, SW, BEQ, LUI, JAL, ECALL

It is intentionally project-specific. It lets EDA Playground convert a .S test
program into one 32-bit instruction per line for SystemVerilog $readmemh.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OP = 0x33
OP_IMM = 0x13
LOAD = 0x03
STORE = 0x23
BRANCH = 0x63
LUI = 0x37
JAL = 0x6F
ECALL = 0x00000073

F3_ADD_SUB_ADDI = 0x0
F3_LW_SW = 0x2
F3_BEQ = 0x0
F3_OR = 0x6
F3_AND = 0x7
F7_ADD = 0x00
F7_SUB = 0x20


def fail(line_no: int, message: str) -> "NoReturn":
    raise ValueError(f"line {line_no}: {message}")


def reg(token: str, line_no: int) -> int:
    token = token.strip().lower()
    match = re.fullmatch(r"x(\d+)", token)
    if not match:
        fail(line_no, f"expected register x0..x31, got {token!r}")
    value = int(match.group(1))
    if not 0 <= value <= 31:
        fail(line_no, f"register out of range: {token}")
    return value


def number(token: str, line_no: int) -> int:
    try:
        return int(token.strip(), 0)
    except ValueError:
        fail(line_no, f"invalid immediate {token!r}")


def signed_range(value: int, bits: int, line_no: int, what: str) -> None:
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    if not lo <= value <= hi:
        fail(line_no, f"{what} {value} does not fit signed {bits} bits")


def enc_r(rd: int, funct3: int, rs1: int, rs2: int, funct7: int) -> int:
    return ((funct7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | \
           ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           ((rd & 0x1F) << 7) | OP


def enc_i(opcode: int, rd: int, funct3: int, rs1: int, imm: int) -> int:
    imm12 = imm & 0xFFF
    return (imm12 << 20) | ((rs1 & 0x1F) << 15) | \
           ((funct3 & 0x7) << 12) | ((rd & 0x1F) << 7) | opcode


def enc_s(rs1: int, rs2: int, imm: int) -> int:
    imm12 = imm & 0xFFF
    return (((imm12 >> 5) & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | \
           ((rs1 & 0x1F) << 15) | (F3_LW_SW << 12) | \
           ((imm12 & 0x1F) << 7) | STORE


def enc_b(rs1: int, rs2: int, imm: int) -> int:
    imm13 = imm & 0x1FFF
    return (((imm13 >> 12) & 1) << 31) | (((imm13 >> 5) & 0x3F) << 25) | \
           ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | \
           (F3_BEQ << 12) | (((imm13 >> 1) & 0xF) << 8) | \
           (((imm13 >> 11) & 1) << 7) | BRANCH


def enc_u(rd: int, imm20: int) -> int:
    if not 0 <= imm20 <= 0xFFFFF:
        raise ValueError(f"LUI immediate 0x{imm20:x} does not fit 20 bits")
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | LUI


def enc_j(rd: int, imm: int) -> int:
    imm21 = imm & 0x1FFFFF
    return (((imm21 >> 20) & 1) << 31) | (((imm21 >> 1) & 0x3FF) << 21) | \
           (((imm21 >> 11) & 1) << 20) | (((imm21 >> 12) & 0xFF) << 12) | \
           ((rd & 0x1F) << 7) | JAL


def split_operands(text: str) -> list[str]:
    return [part.strip() for part in text.split(",") if part.strip()]


def parse_source(path: Path) -> tuple[list[tuple[int, int, str]], dict[str, int]]:
    instructions: list[tuple[int, int, str]] = []
    labels: dict[str, int] = {}
    pc = 0

    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        text = raw.split("#", 1)[0].strip()
        if not text:
            continue

        # Permit one or more labels before an instruction.
        while ":" in text:
            label, rest = text.split(":", 1)
            label = label.strip()
            if not re.fullmatch(r"[A-Za-z_.$][\w.$]*", label):
                fail(line_no, f"invalid label {label!r}")
            if label in labels:
                fail(line_no, f"duplicate label {label!r}")
            labels[label] = pc
            text = rest.strip()
            if not text:
                break
        if not text:
            continue

        if text.startswith("."):
            # The project needs only .section, .globl and .option metadata.
            continue

        instructions.append((line_no, pc, text))
        pc += 4

    return instructions, labels


def assemble_line(line_no: int, pc: int, text: str, labels: dict[str, int]) -> int:
    parts = text.split(None, 1)
    mnemonic = parts[0].lower()
    operands = split_operands(parts[1] if len(parts) == 2 else "")

    if mnemonic == "ecall":
        if operands:
            fail(line_no, "ECALL takes no operands")
        return ECALL

    if mnemonic in {"add", "sub", "and", "or"}:
        if len(operands) != 3:
            fail(line_no, f"{mnemonic.upper()} expects rd, rs1, rs2")
        rd, rs1, rs2 = (reg(x, line_no) for x in operands)
        funct3 = {"add": F3_ADD_SUB_ADDI, "sub": F3_ADD_SUB_ADDI,
                  "and": F3_AND, "or": F3_OR}[mnemonic]
        funct7 = F7_SUB if mnemonic == "sub" else F7_ADD
        return enc_r(rd, funct3, rs1, rs2, funct7)

    if mnemonic == "addi":
        if len(operands) != 3:
            fail(line_no, "ADDI expects rd, rs1, immediate")
        rd = reg(operands[0], line_no)
        rs1 = reg(operands[1], line_no)
        imm = number(operands[2], line_no)
        signed_range(imm, 12, line_no, "ADDI immediate")
        return enc_i(OP_IMM, rd, F3_ADD_SUB_ADDI, rs1, imm)

    if mnemonic in {"lw", "sw"}:
        if len(operands) != 2:
            fail(line_no, f"{mnemonic.upper()} expects register, offset(base)")
        match = re.fullmatch(r"(.+)\((x\d+)\)", operands[1].replace(" ", ""), re.I)
        if not match:
            fail(line_no, f"invalid memory operand {operands[1]!r}")
        imm = number(match.group(1), line_no)
        signed_range(imm, 12, line_no, f"{mnemonic.upper()} offset")
        rs1 = reg(match.group(2), line_no)
        if mnemonic == "lw":
            rd = reg(operands[0], line_no)
            return enc_i(LOAD, rd, F3_LW_SW, rs1, imm)
        rs2 = reg(operands[0], line_no)
        return enc_s(rs1, rs2, imm)

    if mnemonic == "beq":
        if len(operands) != 3:
            fail(line_no, "BEQ expects rs1, rs2, label/immediate")
        rs1 = reg(operands[0], line_no)
        rs2 = reg(operands[1], line_no)
        target = labels.get(operands[2])
        imm = target - pc if target is not None else number(operands[2], line_no)
        if imm & 1:
            fail(line_no, "BEQ target offset must be 2-byte aligned")
        signed_range(imm, 13, line_no, "BEQ offset")
        return enc_b(rs1, rs2, imm)

    if mnemonic == "lui":
        if len(operands) != 2:
            fail(line_no, "LUI expects rd, 20-bit immediate")
        rd = reg(operands[0], line_no)
        imm20 = number(operands[1], line_no)
        try:
            return enc_u(rd, imm20)
        except ValueError as exc:
            fail(line_no, str(exc))

    if mnemonic == "jal":
        if len(operands) != 2:
            fail(line_no, "JAL expects rd, label/immediate")
        rd = reg(operands[0], line_no)
        target = labels.get(operands[1])
        imm = target - pc if target is not None else number(operands[1], line_no)
        if imm & 1:
            fail(line_no, "JAL target offset must be 2-byte aligned")
        signed_range(imm, 21, line_no, "JAL offset")
        return enc_j(rd, imm)

    fail(line_no, f"unsupported instruction {mnemonic!r}")


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {Path(sys.argv[0]).name} input.S output.hex", file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    output = Path(sys.argv[2])
    instructions, labels = parse_source(source)
    words = [assemble_line(line_no, pc, text, labels)
             for line_no, pc, text in instructions]

    output.write_text("".join(f"{word:08x}\n" for word in words), encoding="utf-8")
    print(f"Assembled {source} -> {output} ({len(words)} instructions)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as exc:
        print(f"Assembler error: {exc}", file=sys.stderr)
        raise SystemExit(1)
