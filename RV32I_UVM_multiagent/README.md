# RV32I Multi-Agent UVM Verification

A phased, multi-agent UVM 1.2 testbench for a 5-stage RV32I pipelined CPU with an L1 / L2 / L3 cache hierarchy,
an AXI-Lite link to an external-memory controller (iMC), and a CSR block with a trap unit.
Simulator: Vivado xsim 2025.2. Reference model: C++ golden model through DPI-C.

## Layout

| Folder | Contents |
|---|---|
| `dut/` | the CPU (ALU, control unit, regfile, LSU, L1 data memory, L2/L3 caches, iMC, CSR/trap block) |
| `tb/` | UVM testbench (`tb/README_UVM.md` describes every file, sequence and checker) |
| `sim/` | `run_uvm_xsim.sh` (compile + run tests), `run_mutants.sh` (fault injection), `run_xsim.sh` (unit benches) |
| `docs/` | DUT block diagram, multi-agent UVM diagram, C-on-RV32I flow |
| `results/` | logs from real xsim runs: `all.log` (all tests), `ki.log` (known-issue test), `mutants.log` (fault injection) |
| `run_commands.txt` | every command: each test, test knobs, coverage / assertion reports, mutants |

## Testbench structure

    test -> env
      ctrl_agent (active)  sequencer -> driver -> DUT        -> predictor (DPI-C golden model) -> scoreboard (pred vs actual)
      retire_agent         passive monitor -> retire checker   (order, PC, spacing between retires)
      mem_agent            passive monitor -> mem checker      (routing, stalls, reference L2/L3 cache model) -> bus checker
      axi_agent            passive monitor -> axi checker      (+ axi_sva.sv: AXI-Lite protocol assertions)
      status_agent         passive monitor -> status checker   (halt / trap / fault flags)
      cpu_coverage         functional coverage (golden-model bins + live monitor bins)

## Tests (13, all pass on the good DUT)

hazard, trap, halt, mem, decode, pipeline, cache, status, csr, runoff, reset, rand, regression.
`cpu_known_issue_test` is kept out of the regression and is expected to fail (see Findings).

## Results (real xsim 2025.2)

- 13/13 tests pass, 0 UVM_ERROR, 0 UVM_FATAL; regression = 119 programs matched against the golden model.
- 0 AXI assertion failures on the good DUT, with AXI traffic observed (131 writes / 216 reads in the regression).
- Functional coverage in the regression: 196 / 214 bins (91.6%).
- Fault injection: 6 / 6 injected DUT faults detected (load-use stall removed, L2 tag ignored, CSR range off by one,
  iMC latency +1, L3 write strobe, L3 write address) by the scoreboard, retire / mem / bus checkers or the AXI assertions.

## Findings

For a misaligned access in the CSR-beyond-window or the address-hole region, the DUT raises both the misaligned and the
out-of-range fault flag. The chosen rule is "misaligned wins, one flag per access". `cpu_known_issue_test` pins the
out-of-range count to 0 and fails on this DUT in all four cases. Flag-only deviation: architectural state still matches.

## Run

    cd sim
    bash run_uvm_xsim.sh cpu_regression_test -cov -sva      # full regression + coverage + assertion report
    bash run_uvm_xsim.sh all -log all.log                   # every test
    bash run_mutants.sh 2>&1 | tee mutants.log              # fault injection

See `run_commands.txt` for the complete list.
