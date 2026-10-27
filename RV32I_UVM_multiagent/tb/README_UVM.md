# UVM testbench: multi-agent (structure, passive checking, SVA, cache/AXI cross-checks)

UVM files live in `tb/`. `sim/run_uvm_xsim.sh` goes in `sim/`.

    bash sim/run_uvm_xsim.sh                          # cpu_regression_test, full log printed on the terminal
    bash sim/run_uvm_xsim.sh cpu_status_test          # one test (hazard trap halt mem decode pipeline cache status csr runoff reset rand regression known_issue)
    bash sim/run_uvm_xsim.sh cpu_trap_test cpu_mem_test   # several tests, one after another
    bash sim/run_uvm_xsim.sh all                      # every test, with a PASS/FAIL table at the end
    bash sim/run_uvm_xsim.sh cpu_mem_test -log run.log     # log saved to run.log only; terminal shows one PASS/FAIL line
    bash sim/run_uvm_xsim.sh all -v UVM_HIGH          # print every item (retire / mem / AXI / status)
    bash sim/run_uvm_xsim.sh cpu_rand_test +NUM_RAND=500 +RAND_OPS=32 -log rand.log   # random knobs: programs, ops per program (max 48)

Pass = 0 UVM_ERROR, 0 UVM_FATAL, scoreboard saw the runs (unpredicted = 0), and every passive agent saw traffic
(AXI traffic is required for mem, halt, cache, pipeline, status and regression).
`cpu_known_issue_test` is not in `all` or the regression and is EXPECTED TO FAIL on this DUT (see Findings).
`cpu_reset_test` takes `+RST_RAND=<n>` extra random reset points (default 6).

## Structure

    cpu_*_test -> cpu_env
       ctrl_agent   ACTIVE   sequencer -> driver -> [cpu_if] -> DUT        -> cpu_scoreboard      (end state)
       retire_agent passive  monitor <- [retire_if]                       -> cpu_retire_checker  (per instruction)
       mem_agent    passive  monitor <- [mem_if]                          -> cpu_mem_checker     (routing, stalls)
       axi_agent    passive  monitor <- [axi_if]                          -> cpu_axi_checker     (AXI-Lite)
       status_agent passive  monitor <- [cpu_if ports]                    -> cpu_status_checker  (halt/trap/faults)

Only ctrl_agent has a sequencer, so every sequence runs there. The passive agents observe the result.
The probe interfaces are wired to internal DUT nets by `assign`s in `tb_top.sv`; monitors never use DUT paths.

## Files

| File | Role |
|---|---|
| cpu_pkg.sv | package, includes everything in dependency order |
| cpu_if.sv | DUT ports + backdoor load/read functions |
| cpu_probe_if.sv | retire_if, mem_if, axi_if (read-only probes) |
| cpu_functions.sv, cpu_program.sv, cpu_actual.sv | instruction encoders, program item, end-state item |
| cpu_driver.sv, cpu_monitor.sv, cpu_ctrl_agent.sv | active agent |
| cpu_retire_agent.sv, cpu_mem_agent.sv, cpu_axi_agent.sv, cpu_status_agent.sv | each: item + monitor + agent |
| cpu_scoreboard.sv, cpu_checkers.sv | end-state scoreboard; retire / mem / bus / axi / status checkers |
| cpu_env.sv | wires agents to checkers |
| cpu_sequences.sv | ALL sequences: hazard, trap, halt, mem, decode, pipeline, cache, status, rand |
| cpu_tests.sv | ALL tests in one file; cpu_regression_test runs every sequence |
| tb_top.sv | clock, DUT, probe assigns, config_db |

## Sequences and what they exercise

| Sequence / test | Sends | Checked by |
|---|---|---|
| cpu_hazard_seq | forwarding, load-use, BEQ, JAL | golden model, retire |
| cpu_trap_seq | misaligned LW/SW/JAL, handler, MRET | golden model, status |
| cpu_halt_seq | 8 halt cases: ECALL, SW to HALT_CTRL, halt during/after external store and miss, after taken branch, inside a trap handler, back to back | golden model, status (PC frozen) |
| cpu_mem_seq | CSR window, L2/L3/iMC traffic, read-only CSR write, address hole | golden model, mem, AXI |
| cpu_decode_seq (cpu_decode_test) | immediate extremes, every LW/SW offset form, branch taken/not-taken, rd=x0, unsupported opcodes (must act as NOP) | golden model |
| cpu_pipeline_seq (cpu_pipeline_test) | 5 back-to-back ops with no stall, forwarding chains, load-use, stall then resume, stall before a branch | golden model + exact retire spacing (`exp_gap_*`: 1 cycle normally, 2 after load-use, 5 after external store, 8 after iMC load) |
| cpu_cache_seq (cpu_cache_test) | L1/L2/L3/iMC levels, 60 random ops over addresses that alias in L2/L3, boundary addresses | golden model, mem checker reference cache (predicts L2 hit / L3 hit / iMC and the stall for every load), bus checker |
| cpu_status_seq (cpu_status_test) | 18 programs, one per fault output (misaligned, out-of-range, target-misaligned, trap count) each with a legal twin that must NOT raise it | golden model + pinned counts (`exp_misalign/oor/target/traps`) + status checker |
| cpu_csr_seq (cpu_csr_test) | 5 programs: SCRATCH readback, read-only writes ignored, HALT_CTRL bit0=0 does not halt, MTVEC/MEPC low bits forced to 0, MCAUSE/MTVAL/MEPC capture on traps, SW to MEPC then MRET, CYCLE/INSTR counter deltas (pinned 7 / 6) | golden model + pinned ranges (`pin_reg_range`) |
| cpu_runoff_seq (cpu_runoff_test) | PC runs past word 255 and wraps to word 0 (fall-through, branch, JAL) | golden model (same modulo-256 fetch) |
| cpu_reset_seq (cpu_reset_test) | victim program dirties L1/ext/caches/SCRATCH/MEPC/trap, reset hits it N clocks in (10 fixed + random cut points), then a probe program reads everything back: all must be 0 | golden model (probe pinned to 0); victim is not predicted (`abort_at`); bus checker drops the aborted program's partial traffic |
| cpu_known_issue_seq (cpu_known_issue_test) | misaligned LW/SW in the CSR-beyond-window and hole regions, rule: misaligned wins, one fault flag per access | pinned `oor=0` + golden model. FAILS on this DUT |
| cpu_rand_seq | +NUM_RAND programs (default 50) of +RAND_OPS ops: ALU, L1/external LW/SW, forward BEQ/JAL, misaligned accesses, either halt style | golden model, all checkers |

Pinned counts (`exp_*`) are set per program in the sequence and compared by the scoreboard independently of the golden model,
so a bug shared by the DUT and the model cannot hide. -1 means "not pinned".

## Checkers

| Checker | Checks |
|---|---|
| cpu_scoreboard | regs, L1 RAM, external memory, retired count, trap count, fault counts (misaligned / out-of-range / target) vs the golden model and the pinned values |
| cpu_retire_checker | per-instruction retire order/PC and spacing between retires (`exp_gap_default`, `exp_gap_at[i]`; 0 = unchecked) |
| cpu_mem_checker | routing, stall count, and a reference L2/L3 model: expected level (L2/L3/iMC) and stall (iMC 7, store 4, hit 0) per external access |
| cpu_bus_checker | every external store / iMC-served load seen on the mem side appears on the AXI side with the same address+data (multiset compare in check_phase) |
| cpu_axi_checker + SVA in axi_if | responses OKAY, plus assertions: valid held until ready (AW/W/AR/B/R), full WSTRB, one outstanding transaction, no X on control, B/R only after a request, AW before W, response within MAX_LATENCY (24) clocks, addresses word-aligned and inside ADDR_LO..ADDR_HI. Failures print `ERROR ... AXI_SVA` |
| cpu_status_checker | PC must not move while halted; counts halts / traps / flags |

## Scope

The scoreboard (pred_fifo + act_fifo, like the UART one) compares every program with the C++ golden model. Default log: one MATCH/SKIP/MISMATCH line per program plus a CPU_SB SUMMARY. -v UVM_MEDIUM adds the per-program register dump, -v UVM_HIGH adds every memory/AXI/status access. Functional coverage: `cpu_coverage` prints a `COVERAGE` table at the end of every run (hand-counted bins, not covergroups). Architectural bins are counted in the golden model, timing/level bins on the SV side.
The passive agents are white-box probes (the DUT has no bus ports). axi_agent stays passive until the iMC is moved out of design_top.
mem_agent sees l2_hit/l3_hit (probed in tb_top) so the level of each external load is known.
The testbench cannot write data RAM (always_ff driven): programs preload data with SW.
MTVEC is 0 after reset: every program that traps first sets it (set_mtvec). Handlers that skip the faulting instruction use add_skip_handler.

## Findings

- **Misaligned + out-of-range double flag (DUT).** For a misaligned access in the CSR-beyond-window or the address-hole region the DUT raises BOTH the misaligned and the out-of-range flag. Chosen rule: misaligned wins, one fault flag per access (it traps). `cpu_known_issue_test` pins `oor=0` and fails on this DUT. This is a deviation from the chosen rule, flag-only (architectural state still matches); there is no written spec.

## Known gaps

- Nested traps (coverage bin `T_NESTED` stays empty).
- Real xsim run of the new SVAs, coverage and reset test is still needed (developed against Verilator with a stub UVM).
