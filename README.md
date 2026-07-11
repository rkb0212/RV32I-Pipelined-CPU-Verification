# RV32I-Pipelined-CPU-Verification
## Overview

This project implements a complete UVM-based functional verification environment for a custom RV32I-subset 5-stage pipelined CPU written in SystemVerilog.

The CPU implements a genuine RISC-V RV32I instruction subset with:

- 32-bit datapath, 32 architectural registers (x0 hardwired to zero)
- Byte-addressed PC incrementing by 4 per instruction
- Five instruction formats: R, I, S, B, U, J
- ECALL instruction mapped as simulation halt

The verification environment ensures:

- ISA-level functional correctness via DPI-C C golden model (ISS)
- Pipeline hazard correctness (forwarding, stalling, flushing)
- Protocol compliance via SVA property checkers bound to the DUT
- Functional coverage closure across opcodes, forwarding paths and pipeline events

---

## DUT Description

**File:** `design.sv`

The DUT is a cycle-accurate RV32I-subset 5-stage pipelined processor:

```
IF  →  ID  →  EX  →  MEM  →  WB
```

### Supported Instruction Set

| Format | Instructions |
|--------|-------------|
| R-type | ADD, SUB, AND, OR |
| I-type | ADDI, LW |
| S-type | SW |
| B-type | BEQ |
| U-type | LUI |
| J-type | JAL |
| SYSTEM | ECALL (halt) |

### Pipeline Correctness Features

**EX/MEM and MEM/WB Forwarding**
- Four forwarding paths: EX/MEM→rs1, EX/MEM→rs2, MEM/WB→rs1, MEM/WB→rs2
- EX/MEM load values are explicitly excluded from forwarding (`!ex_mem_mem_to_reg` guard) — prevents forwarding a load *address* as *data*, a subtle correctness requirement
- x0 writes are suppressed at all forwarding mux inputs

**Load-Use Hazard Stalling**
- 1-cycle bubble inserted when a LW result is consumed by the immediately following instruction on either rs1 or rs2
- PC and IF/ID registers held; ID/EX flushed to bubble

**Control Hazard Flushing**
- BEQ and JAL resolved in the EX stage
- Both instructions already in IF/ID and ID/EX are squashed on redirect
- Single `redirect_taken` signal covers both branch and jump cases

**x0 Hardwired to Zero**
- Enforced at register file write (WB stage suppresses writes to x0)
- Enforced at forwarding mux (x0 source always returns 0)
- Verified by SVA property `AST_X0_ZERO`

### Design Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| DATA_W | 32 | Data and register width |
| IMEM_DEPTH | 256 | Instruction memory depth (words) |
| DMEM_DEPTH | 256 | Data memory depth (words) |

---

## UVM Testbench Architecture

```
Test
 └── Env
      ├── Agent
      │    ├── Driver        — backdoor-loads programs, drives reset, waits for halt
      │    ├── Monitor       — RAL backdoor-reads 32 registers + memory after halt
      │    └── Sequencer
      ├── Scoreboard         — DPI-C ISS replay + register/memory state comparison
      ├── RAL (cpu_reg_block) — typed backdoor access to regfile[0:31] and data_mem
      └── cpu_instr_cov      — UVM subscriber sampling per-instruction opcode/rd coverage
```

SVA and functional coverage modules are bound to the DUT separately via `bind`:

```
cpu_sva.sv      ──bind──► simple_cpu_pipelined  (taps internal pipeline signals)
cpu_coverage.sv ──bind──► simple_cpu_pipelined  (taps forwarding mux conditions)
cpu_instr_cov   ◄── program_ap ── cpu_driver    (UVM TLM analysis port)
```

### Interface

**File:** `cpu_if.sv`

Wraps the DUT's external ports (`clk`, `rst_n`, `halt`, `pc_out`). Register file, data memory and instruction memory are accessed by the UVM environment via backdoor HDL paths (`uvm_hdl_deposit` / `uvm_hdl_read`), since the CPU has no external bus interface.

### Transaction

**File:** `cpu_pkg.sv` — `cpu_instr_item`

Encodes all six RV32I instruction formats:

| Format | Encoding function | Fields |
|--------|------------------|--------|
| R-type | `enc_r()` | opcode, rd, funct3, rs1, rs2, funct7 |
| I-type | `enc_i()` | opcode, rd, funct3, rs1, imm[11:0] |
| S-type | `enc_s()` | opcode, rs1, rs2, funct3, imm[11:0] |
| B-type | `enc_b()` | opcode, rs1, rs2, funct3, imm[12:1] |
| U-type | `enc_u()` | opcode, rd, imm[31:12] |
| J-type | `enc_j()` | opcode, rd, imm[20:1] |

### Sequences

**File:** `cpu_pkg.sv`

| Sequence | Type | Purpose |
|----------|------|---------|
| `cpu_rand_seq` | Constrained-random | 10–20 instructions per program; no BEQ/JAL (uncontrolled branches excluded from random) |
| `cpu_hazard_seq` | Directed | 11-instruction hazard-stress program: EX/EX forward, MEM/WB forward, load-use stall, store-data forward, BEQ taken flush, JAL taken flush, LUI |

### DPI-C Golden Model

**File:** `golden_model.c`

A non-pipelined C implementation of the full RV32I-subset ISA used as an independent oracle. The scoreboard replays each program through the golden model after the DUT runs to completion and compares final architectural state register-by-register and word-by-word.

Key implementation details:
- Correct immediate decoders for all five immediate formats (I, S, B, U, J)
- `imm_b()` and `imm_j()` produce byte-addressed offsets matching the RTL
- x0 is zeroed after every step
- `gm_reset()` clears all 256 data memory words — matches the UVM driver's full data memory clear before each program

DPI boundary: `int` (32-bit) on both sides, matching SystemVerilog `int` imports.

### Driver

**File:** `cpu_pkg.sv` — `cpu_driver`

For each program:
1. Asserts reset
2. Backdoor-deposits all 256 data memory words to zero (matching `gm_reset()`)
3. Backdoor-deposits instruction words
4. Backdoor-deposits 8 fixed preload data words (word[0]=100, words[1-7]=0)
5. De-asserts reset, waits for `halt`
6. Waits 5 drain cycles before signalling monitor
7. Waits 15 inter-program gap cycles before next reset

### Monitor

**File:** `cpu_pkg.sv` — `cpu_monitor`

Triggers on `posedge halt`, waits 5 drain cycles, then reads final architectural state via UVM RAL backdoor peek calls:
- 32 register file entries (`regfile[0:31]`) — 32-bit each
- 8 data memory words (`data_mem[0:7]`) — matching preload addresses

### RAL

**File:** `cpu_pkg.sv` — `cpu_reg_block`

| RAL Model | HDL Path | Width | Depth |
|-----------|----------|-------|-------|
| `r[0:31]` | `tb_top.dut.regfile[N]` | 32-bit | 32 registers |
| `dmem` | `tb_top.dut.data_mem` | 32-bit | 256 words |

### Scoreboard

**File:** `cpu_pkg.sv` — `cpu_scoreboard`

Per-program comparison flow:
1. Receive program encoding from driver analysis port
2. Receive final DUT state from monitor analysis port
3. Call `gm_reset()`, load program into ISS, call `gm_run(1000)`
4. Compare all 32 registers and 8 memory words
5. Print full register/memory dump with `actual=` vs `golden=` and `OK`/`MISMATCH` per entry

### SVA Checker

**File:** `cpu_sva.sv`

Seven assertions bound directly to DUT internal signals via `bind`:

| Assertion | Property |
|-----------|---------|
| `AST_HALT_STICKY` | `halt` stays asserted until reset |
| `AST_PC_FREEZE` | PC does not change after `halt` |
| `AST_PC_WORD_ALIGNED` | PC[1:0] == 2'b00 at all times |
| `AST_REDIRECT_FLUSH` | ID/EX is a bubble the cycle after BEQ or JAL redirect |
| `AST_LOAD_USE_PC_HOLD` | PC is held during load-use stall |
| `AST_LOAD_USE_BUBBLE` | ID/EX becomes a bubble during load-use stall |
| `AST_X0_ZERO` | regfile[0] is never non-zero |

Five cover properties verify that all pipeline events are actually exercised:
`COV_BRANCH_TAKEN`, `COV_JUMP_TAKEN`, `COV_LOAD_USE_STALL`, `COV_HALT_REACHED`, `COV_STALL_THEN_BRANCH`

### Functional Coverage

**File:** `cpu_coverage.sv`

Four covergroups bound to the DUT via `bind`:

| Covergroup | What it measures |
|------------|-----------------|
| `cg_pipeline_events` | stall, branch-taken, jump-taken, forwarding, halt; cross: branch×fwd, jump×fwd, stall×fwd |
| `cg_rv32i_opcodes` | All 8 RV32I opcodes exercised through EX stage |
| `cg_rv32i_instrs` | All 11 instruction kinds (ADD/SUB/AND/OR/ADDI/LW/SW/BEQ/LUI/JAL/ECALL) |
| `cg_forward_paths` | All 4 forwarding paths individually (EX/MEM→rs1, EX/MEM→rs2, MEM/WB→rs1, MEM/WB→rs2) |

Forwarding detection in the coverage module mirrors the RTL's forwarding mux conditions exactly, including the `!ex_mem_mem_to_reg` guard that prevents load address forwarding.

### Tests

| Test | Programs | Focus |
|------|----------|-------|
| `cpu_hazard_test` | 1 directed | All pipeline hazard types in one 11-instruction sequence |
| `cpu_rand_test` | 10 random | Datapath coverage: ADD/SUB/AND/OR/ADDI/LW/SW/LUI with constrained-random register and immediate values |

---

## Simulation Results

### Scoreboard

| Test | Programs checked | Mismatches |
|------|-----------------|------------|
| `cpu_hazard_test` | 1 / 1 | 0 |
| `cpu_rand_test` | 10 / 10 | 0 |
| **Total** | **11 / 11** | **0** |

### Hazard Test — Architectural State Verification

The directed hazard sequence exercises five distinct hazard scenarios in 11 instructions:

| Step | Instruction | Hazard type | Expected result |
|------|-------------|-------------|----------------|
| 1 | `ADDI x1, x0, 5` | — | x1=5 |
| 2 | `ADDI x2, x1, 3` | EX/EX forward on x1 | x2=8 |
| 3 | `ADD x3, x2, x1` | EX/EX + MEM/WB forward | x3=13 |
| 4 | `LW x4, 0(x0)` | — | x4=100 (from preload) |
| 5 | `ADD x5, x4, x3` | Load-use stall on x4 | x5=113 |
| 6 | `SW x5, 4(x0)` | Store-data forward on x5 | mem[1]=113 |
| 7 | `BEQ x1, x1, +12` | Always taken → flush next 2 | redirect to step 10 |
| 8 | `ADDI x6, x0, 9` | Must be flushed | x6 stays 0 |
| 9 | `ADDI x6, x0, 8` | Must be flushed | x6 stays 0 |
| 10 | `ADDI x7, x0, 7` | Landing point | x7=7 |
| 11 | `LUI x8, 0x12345` | Upper immediate | x8=0x12345000 |

All register values and memory words matched the DPI-C golden model exactly.

### SVA Assertions

All assertions passed with zero failures across both tests:

```
AST_HALT_STICKY        failures = 0
AST_PC_FREEZE          failures = 0
AST_PC_WORD_ALIGNED    failures = 0
AST_REDIRECT_FLUSH     failures = 0
AST_LOAD_USE_PC_HOLD   failures = 0
AST_LOAD_USE_BUBBLE    failures = 0
AST_X0_ZERO            failures = 0
TOTAL ASSERTION FAILURES = 0
ASSERTION RESULT: PASS
```

Cover event counts (merged across both tests):

```
COV_BRANCH_TAKEN      count = 6
COV_JUMP_TAKEN        count = 11
COV_LOAD_USE_STALL    count = 11
COV_HALT_REACHED      count = 108
COV_STALL_THEN_BRANCH count = 5
```

### Coverage Results (Merged ACDB)

| Covergroup | Coverage | Status |
|------------|----------|--------|
| `cg_rv32i_opcodes` | **100%** | Covered |
| `cg_rv32i_instrs` | **100%** | Covered |
| `cg_forward_paths` | **100%** | Covered |
| `cg_pipeline_events` | 90.6% | Uncovered |
| **Total ACDB** | **97.656%** | — |

**All 4 forwarding paths individually confirmed:**

| Path | Hit count |
|------|-----------|
| EX/MEM → rs1 | 22 |
| EX/MEM → rs2 | 1 |
| MEM/WB → rs1 | 21 |
| MEM/WB → rs2 | 11 |

**All 11 instruction kinds confirmed hit:**
ADD (22), SUB (10), AND (10), OR (10), ADDI (50), LW (11), SW (11), BEQ (11), LUI (1), JAL (11), ECALL (119)

### Remaining Coverage Gaps

Three cross bins in `cg_pipeline_events` are not yet hit:

| Missing bin | Description | Root cause |
|-------------|-------------|------------|
| `<taken, forwarded>` | BEQ taken while a forwarded value was also active | BEQ in hazard test uses register-file values, not forwarded values |
| `<jump, forwarded>` | JAL taken while forwarding was active | JAL writes link to rd, not a data forward scenario |
| `<stall, forwarded>` | Load-use stall cycle coincides with a forwarding path to a different instruction | Requires a 3-instruction overlap not present in current sequences |

These are architecturally meaningful corner cases, not random gaps. All three are closeable with one additional directed closure sequence.

---

## How to Run (EDA Playground — Aldec Riviera-PRO)

### File Setup

Add all files to the EDA Playground project:

| File | Role |
|------|------|
| `design.sv` | DUT — RV32I pipelined CPU |
| `cpu_if.sv` | Interface |
| `cpu_pkg.sv` | UVM package (transactions, sequences, driver, monitor, scoreboard, RAL, tests) |
| `cpu_sva.sv` | SVA checker + bind |
| `cpu_coverage.sv` | Functional coverage + bind |
| `testbench.sv` | Top-level UVM test runner |
| `golden_model.c` | DPI-C ISA reference model |
| `run.bash` | Build and run script |

### Settings

- Simulator: Aldec Riviera-PRO (UVM 1.2, DPI-C)
- Top module: `tb_top`
- Enable UVM 1.2 library
- Enable Run Bash option

### Running

```bash
chmod +x run.bash && ./run.bash
```

The script:
1. Compiles `golden_model.c` into `libgolden.so`
2. Compiles all SystemVerilog (`design.sv`, `testbench.sv`, `cpu_sva.sv`, `cpu_coverage.sv`)
3. Runs `cpu_hazard_test` — saves `fcover_hazard.acdb`
4. Runs `cpu_rand_test` — saves `fcover_rand.acdb`
5. Merges ACDB databases and prints full coverage + assertion report

### Run Options

To run individual tests:
```
+UVM_TESTNAME=cpu_hazard_test
+UVM_TESTNAME=cpu_rand_test
```

---

## Verification Summary

### Achieved

- Full ISA-level functional correctness across 11 programs (1 directed + 10 constrained-random), zero register or memory mismatches
- All 7 SVA protocol assertions pass with zero violations
- All 11 RV32I instruction kinds confirmed exercised (100% `cg_rv32i_instrs`)
- All 8 RV32I opcodes confirmed exercised (100% `cg_rv32i_opcodes`)
- All 4 forwarding paths individually confirmed active (100% `cg_forward_paths`)
- Pipeline events (stall, branch-taken, jump-taken, forwarding) all individually confirmed
- 97.656% overall ACDB coverage closure

### Remaining Gaps

- Three cross bins in `cg_pipeline_events`: `<taken,forwarded>`, `<jump,forwarded>`, `<stall,forwarded>` — require a dedicated closure sequence targeting simultaneous hazard + forwarding scenarios
- LUI exercised only once; more LUI randomization would strengthen upper-immediate coverage
