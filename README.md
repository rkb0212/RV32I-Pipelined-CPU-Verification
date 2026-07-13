# RV32I Pipelined CPU Verification

## Overview

This project verifies a custom **32-bit, five-stage RV32I-subset pipelined CPU** using two complementary verification implementations:

1. **UVM verification flow** — constrained-random and directed stimulus, SVA, covergroups, RAL backdoor access, and a DPI-C golden model.
2. **Assembly-driven verification flow** — a directed `.S` program, a Python RV32I-subset assembler, a plain SystemVerilog self-checking testbench, and the same DPI-C golden model.

Both implementations verify architectural correctness and pipeline behavior, but they serve different purposes. The UVM environment provides reuse, regression, functional coverage, and assertion-based checking. The assembly flow provides software-visible control over exact instruction dependencies and demonstrates that a real assembly program can be assembled, loaded into instruction memory, executed by the CPU, and checked against an independent reference model.

> **Instruction-count convention:** the DUT implements 10 functional RV32I instructions—ADD, SUB, AND, OR, ADDI, LW, SW, BEQ, LUI, and JAL—plus ECALL, which is used as the simulation halt instruction. Therefore, coverage reports may show 11 instruction kinds when ECALL is included.

---

## Verification Implementations

| Implementation | Stimulus | Checking | Coverage | Primary purpose |
|---|---|---|---|---|
| UVM/SVA/Coverage | Directed and constrained-random encoded instructions | UVM scoreboard + DPI-C ISS + SVA | Native covergroups and ACDB | Reusable verification environment and regression testing |
| Assembly/Plain SV | Directed `hazard_test.S` program assembled by Python | Plain SV self-checking TB + DPI-C ISS + procedural checks | Manual instruction/event counters | Software-level processor validation and exact hazard sequencing |

The implementations are kept separate because the shared Riviera-PRO EDU license used by EDA Playground may not always make UVM, concurrent SVA, and covergroup features available. The plain SystemVerilog assembly version avoids those licensed features while preserving architectural and pipeline checks.

---

## DUT Description

**File:** `design.sv`

The DUT is a cycle-accurate RV32I-subset processor with the following pipeline:

```text
IF -> ID -> EX -> MEM -> WB
```

### Supported Instructions

| Format | Instructions |
|---|---|
| R-type | ADD, SUB, AND, OR |
| I-type | ADDI, LW |
| S-type | SW |
| B-type | BEQ |
| U-type | LUI |
| J-type | JAL |
| SYSTEM | ECALL, used as simulation halt |

### Architectural Features

- 32-bit datapath and byte-addressed program counter.
- 32 architectural registers, with `x0` hardwired to zero.
- 256-word instruction memory and 256-word data memory.
- R, I, S, B, U, and J immediate decoding.
- ECALL detection and sticky halt behavior.

### Pipeline-Hazard Handling

#### EX/MEM and MEM/WB forwarding

The CPU supports four forwarding paths:

- EX/MEM to `rs1`
- EX/MEM to `rs2`
- MEM/WB to `rs1`
- MEM/WB to `rs2`

EX/MEM load results are excluded from direct forwarding through the `!ex_mem_mem_to_reg` condition, preventing a load address from being incorrectly forwarded as loaded data.

#### Load-use stall

When an instruction immediately consumes the destination of a preceding LW:

- The PC is held.
- IF/ID is held.
- ID/EX is cleared to insert a one-cycle bubble.

#### BEQ and JAL flushing

BEQ and JAL are resolved in the EX stage. On a redirect, the younger instructions in IF/ID and ID/EX are flushed.

#### x0 protection

Writes to `x0` are suppressed in the register-file writeback path and ignored by forwarding logic.

---

## Repository Structure

```text
RV32I-Pipelined-CPU-Verification-main/
├── design.sv
├── cpu_if.sv
├── cpu_pkg.sv
├── cpu_sva.sv
├── cpu_coverage.sv
├── testbench.sv
├── golden_model.c
├── run.bash
├── coverage_final.txt
├── output.txt
└── rv32I 5-stage pipeline CPU_Assembly version/
    ├── design.sv
    ├── testbench.sv
    ├── golden_model.c
    ├── hazard_test.S
    ├── rv32i_subset_asm.py
    ├── hazard_test.hex
    ├── run.bash
    └── output.txt
```

The copies of `cpu_if.sv`, `cpu_pkg.sv`, and `cpu_observer.sv` inside the assembly directory are not compiled by the restricted-license plain-SV run. The active assembly flow compiles only `design.sv` and `testbench.sv`, along with the DPI-C shared library.

---

# Implementation 1: UVM, SVA, Functional Coverage, and DPI-C

## UVM Testbench Architecture

```text
Test
 └── Environment
      ├── Agent
      │    ├── Sequencer
      │    ├── Driver
      │    └── Monitor
      ├── Scoreboard
      └── RAL backdoor model

cpu_sva.sv      --bind--> DUT internal pipeline signals
cpu_coverage.sv --bind--> DUT internal pipeline signals
golden_model.c  <--DPI-C--> UVM driver and scoreboard
```

### Main Files

| File | Role |
|---|---|
| `cpu_if.sv` | External CPU interface containing clock, reset, halt, and PC |
| `cpu_pkg.sv` | UVM transactions, sequences, driver, monitor, scoreboard, RAL, and tests |
| `cpu_sva.sv` | Bound concurrent assertions and cover properties |
| `cpu_coverage.sv` | Bound functional covergroups |
| `golden_model.c` | Non-pipelined architectural reference model |
| `testbench.sv` | UVM top-level and DUT instantiation |
| `run.bash` | DPI build, compilation, test execution, and ACDB merge |

## UVM Stimulus

### Directed hazard sequence

`cpu_hazard_seq` creates a 16-word directed program that targets:

- EX/MEM forwarding
- MEM/WB forwarding
- Load-use stalling
- Store-data forwarding
- Taken BEQ flushing
- JAL flushing and link-register writeback
- LUI behavior
- Attempted write to `x0`
- ECALL halt

### Constrained-random sequence

`cpu_rand_seq` generates 10 programs with randomized register selections, immediate values, arithmetic operations, loads, stores, and branch behavior. Each generated program is loaded into both the DUT and the golden model.

## DPI-C Golden Model

**File:** `golden_model.c`

The reference model is intentionally non-pipelined. It fetches and executes one architectural instruction at a time and therefore acts as an implementation-independent oracle for the pipelined RTL.

It supports:

- ADD, SUB, AND, OR
- ADDI, LW, SW
- BEQ, LUI, JAL
- ECALL halt
- Correct I, S, B, U, and J immediate reconstruction
- Byte-addressed PC behavior
- Word-indexed instruction and data memories
- `x0` enforcement after every instruction

For every UVM program, all 32 registers, all 256 data-memory words, final PC, and halt state are compared against the golden model.

## SVA Checks

**File:** `cpu_sva.sv`

| Assertion | Requirement |
|---|---|
| `AST_HALT_STICKY` | Halt remains asserted until reset |
| `AST_PC_FREEZE` | PC remains stable after halt |
| `AST_PC_WORD_ALIGNED` | PC is always word aligned |
| `AST_REDIRECT_FLUSH` | BEQ/JAL redirect clears ID/EX |
| `AST_LOAD_USE_PC_HOLD` | Load-use stall holds the PC |
| `AST_LOAD_USE_BUBBLE` | Load-use stall inserts an ID/EX bubble |
| `AST_X0_ZERO` | `x0` always remains zero |

Cover properties confirm that branch redirects, jump redirects, load-use stalls, halt, and stall-followed-by-branch scenarios are exercised.

## Functional Coverage

**File:** `cpu_coverage.sv`

| Covergroup | Coverage target |
|---|---|
| `cg_pipeline_events` | Stall, branch, jump, forwarding, halt, and event crosses |
| `cg_rv32i_opcodes` | All implemented RV32I opcodes |
| `cg_rv32i_instrs` | ADD, SUB, AND, OR, ADDI, LW, SW, BEQ, LUI, JAL, and ECALL |
| `cg_forward_paths` | All four individual forwarding paths |

### UVM Regression Results

| Result | Value |
|---|---:|
| Programs compared | 11/11 |
| Register/memory mismatches | 0 |
| SVA failures | 0 |
| RV32I opcode coverage | 100% |
| RV32I instruction-kind coverage | 100% |
| Forwarding-path coverage | 100% |
| Pipeline-event coverage | 90.625% |
| Overall merged ACDB coverage | **97.656%** |

All four forwarding paths were observed:

| Forwarding path | Hits |
|---|---:|
| EX/MEM to `rs1` | 22 |
| EX/MEM to `rs2` | 1 |
| MEM/WB to `rs1` | 21 |
| MEM/WB to `rs2` | 11 |

### Remaining UVM Coverage Gaps

The remaining uncovered bins are event crosses requiring simultaneous conditions:

- Taken BEQ with forwarding active
- JAL with forwarding active
- Load-use stall with an independent forwarding path active

These can be closed with an additional directed coverage-closure sequence.

---

# Implementation 2: Assembly-Driven Verification

## Purpose

The assembly implementation validates the CPU from a software-visible perspective. Instead of directly constructing instruction words inside a UVM sequence, the test is written as a human-readable RISC-V assembly file.

This makes the statement **“wrote a directed assembly test program”** technically accurate because the instruction sequence exists in a separate `.S` source file and is assembled before simulation.

## Assembly Verification Flow

```text
hazard_test.S
      |
      v
rv32i_subset_asm.py
      |
      v
hazard_test.hex
      |
      +--> DUT instr_mem[0:255]
      |
      +--> DPI-C golden model
                 |
                 v
        CPU executes to ECALL
                 |
                 v
 Registers + memory + PC + halt compared
```

The active command in `run.bash` is:

```bash
python3 rv32i_subset_asm.py hazard_test.S hazard_test.hex
```

Therefore, the Python code is used on every run. If assembly fails, `set -euo pipefail` stops the build before simulation.

## Assembly-Version Files

| File | Role |
|---|---|
| `hazard_test.S` | Directed RISC-V assembly test program |
| `rv32i_subset_asm.py` | Two-pass assembler for the implemented RV32I subset |
| `hazard_test.hex` | Generated 32-bit machine-code image, one instruction per line |
| `testbench.sv` | Plain SystemVerilog loader, monitor, checker, and manual coverage collector |
| `golden_model.c` | Same architectural DPI-C reference model |
| `design.sv` | Same pipelined CPU RTL |
| `run.bash` | Assembles, compiles, and runs the test |

## Python RV32I-Subset Assembler

**File:** `rv32i_subset_asm.py`

The assembler supports exactly the CPU subset:

```text
ADD, SUB, AND, OR, ADDI, LW, SW, BEQ, LUI, JAL, ECALL
```

Key capabilities:

- Parses registers `x0` through `x31`.
- Supports signed immediate validation.
- Encodes R, I, S, B, U, and J formats.
- Resolves BEQ and JAL labels in a two-pass flow.
- Rejects unsupported instructions and invalid operand ranges.
- Produces one 32-bit hexadecimal instruction per output line for `$readmemh`.

## Directed Assembly Program

**File:** `hazard_test.S`

The 19-instruction program exercises:

- ADD, SUB, AND, and OR
- ADDI dependencies
- LW followed immediately by a dependent ADD
- SW using a recently produced value
- Taken BEQ with two flushed sequential instructions
- LUI upper-immediate write
- JAL redirect, link-register write, and flushed sequential instruction
- Attempted write to `x0`
- ECALL halt

Representative sections:

```asm
# EX/MEM forwarding
addi x1, x0, 5
addi x2, x1, 3

# Load-use stall
lw   x4, 0(x0)
add  x5, x4, x3

# BEQ flush
beq  x1, x1, branch_target
addi x6, x0, 9
addi x6, x0, 8

# JAL flush and link write
jal  x9, jump_target
addi x10, x0, 111

# x0 hardwiring
addi x0, x0, 99

ecall
```

## Plain-SystemVerilog Self-Checking Testbench

The assembly testbench deliberately avoids UVM, covergroups, and concurrent SVA so it can run when the shared Riviera EDU advanced-verification license is unavailable.

It performs the following operations:

1. Loads `hazard_test.hex` with `$readmemh`.
2. Initializes all instruction-memory locations to NOP and all data-memory locations to zero.
3. Preloads `data_mem[0] = 100` for the LW test.
4. Loads the same instruction and data images into the DPI-C golden model.
5. Runs the golden model to completion.
6. Releases the DUT from reset and waits for ECALL/HALT.
7. Compares all 32 registers.
8. Compares all 256 data-memory words.
9. Compares final PC and halt state.
10. Checks required hazard events and instruction execution.

## Procedural Pipeline Checks

Because concurrent SVA is not used in this version, equivalent cycle-based procedural checks verify:

- PC hold during load-use stall
- Bubble insertion after stall
- ID/EX flush after BEQ/JAL redirect
- Sticky halt behavior
- PC freeze after halt
- PC word alignment
- `x0` hardwiring

Manual event counters track:

- Load-use stalls
- Taken BEQ redirects
- JAL redirects
- EX/MEM forwarding
- MEM/WB forwarding
- Execution of all 10 functional instructions

## Assembly-Test Results

| Result | Value |
|---|---:|
| Assembly instructions generated | 19 |
| Halt cycle | 23 |
| Final PC | `0x00000048` |
| Registers matching golden model | 32/32 |
| Data-memory words matching golden model | 256/256 |
| Load-use stalls observed | 1 |
| Taken BEQ redirects observed | 1 |
| JAL redirects observed | 1 |
| EX/MEM forwarding events observed | 3 |
| MEM/WB forwarding events observed | 3 |
| Functional instructions observed | 10/10 |
| Final test result | **44 passed, 0 failed** |

The assembly test also confirmed:

- `x6` remained zero after the taken BEQ flushed two wrong-path ADDI instructions.
- `x10` remained zero after JAL flushed the following ADDI instruction.
- `x9` received the JAL link address `0x0000003c`.
- `x0` remained zero after `addi x0, x0, 99`.
- `data_mem[1]` received the expected stored value.

---

## How to Run

### A. UVM/SVA/Coverage Version

Run from the repository root:

```bash
chmod +x run.bash
./run.bash
```

Required simulator capabilities:

- SystemVerilog
- UVM 1.2
- DPI-C
- Concurrent SVA
- Functional covergroups and ACDB coverage

The script:

1. Compiles `golden_model.c` into `libgolden.so`.
2. Compiles the RTL, UVM testbench, SVA, and coverage modules.
3. Runs `cpu_hazard_test`.
4. Runs `cpu_rand_test`.
5. Merges ACDB databases.
6. Generates `coverage_final.txt`.

> On a shared EDA Playground Riviera-PRO EDU session, advanced-verification license tokens may be unavailable even when the same project previously ran. In that case, use the assembly/plain-SV flow below or run the UVM flow on Questa, VCS, Xcelium, or a fully licensed Riviera installation.

### B. Assembly/Plain-SystemVerilog Version

Run from the assembly directory:

```bash
cd "rv32I 5-stage pipeline CPU_Assembly version"
chmod +x run.bash
./run.bash
```

The script:

1. Runs the Python assembler.
2. Regenerates `hazard_test.hex` from `hazard_test.S`.
3. Builds `libgolden.so`.
4. Removes stale Riviera work libraries and old coverage databases.
5. Compiles `design.sv` and the plain `testbench.sv`.
6. Runs the self-checking assembly test.

Expected final result:

```text
Implemented instructions observed = 10/10
FINAL RESULT: 44 checks passed, 0 checks failed
TEST PASS: assembly program, hazards, and golden comparison passed
```

---

## Why Both Implementations Are Included

The two environments are complementary rather than redundant:

- The **UVM implementation** demonstrates reusable agents, sequences, RAL, scoreboarding, constrained-random regression, SVA, and coverage closure.
- The **assembly implementation** demonstrates processor validation from the programmer’s view, exact control over instruction dependencies, label-based branch/jump targets, automated machine-code generation, and direct loading into instruction memory.
- Keeping them separate makes each flow easier to understand and avoids coupling the assembly demonstration to a simulator feature license.
- Both reuse the same RTL and independent DPI-C architectural model, allowing their results to be cross-checked consistently.

---

## Verification Summary

### UVM flow

- 11/11 programs matched the DPI-C golden model.
- Zero register, memory, PC, or halt mismatches.
- Seven SVA properties passed with zero failures.
- 100% opcode, instruction-kind, and forwarding-path coverage.
- 97.656% overall merged functional coverage.

### Assembly flow

- A real `.S` program was converted to 19 machine-code words by the Python assembler.
- All 10 functional RV32I instructions were executed.
- Load-use, EX/MEM forwarding, MEM/WB forwarding, BEQ flush, JAL flush, and x0 hardwiring were observed.
- All 32 registers and all 256 memory words matched the DPI-C reference model.
- 44 checks passed with zero failures.

---

## Skills Demonstrated

- SystemVerilog RTL and five-stage pipeline design
- UVM 1.2 testbench architecture
- Directed and constrained-random stimulus
- SystemVerilog Assertions
- Functional coverage and coverage crosses
- RAL and HDL backdoor access
- DPI-C integration with a C architectural model
- RISC-V instruction encoding and immediate decoding
- Assembly-level directed processor testing
- Python-based assembler development
- Hazard, forwarding, stall, flush, and architectural-state debugging
