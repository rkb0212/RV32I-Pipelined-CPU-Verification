#!/bin/bash
set -euo pipefail

# =============================================================================
# Riviera EDU-compatible flow:
#   - no UVM
#   - no covergroups
#   - no concurrent SVA
#   - plain SystemVerilog + DPI-C only
# =============================================================================

python3 rv32i_subset_asm.py hazard_test.S hazard_test.hex

echo "===================== ASSEMBLY MACHINE CODE ====================="
nl -ba hazard_test.hex

# Build the architectural reference model used by the plain SV testbench.
gcc -shared -fPIC -o libgolden.so golden_model.c

# Remove stale compiled UVM/SVA/coverage units from previous runs.
rm -rf work library.cfg
rm -f fcover*.acdb coverage_final.txt dataset.asdb

vlib work

# IMPORTANT: compile only the RTL and the plain testbench.
# cpu_pkg.sv, cpu_if.sv, cpu_observer.sv, cpu_sva.sv, and cpu_coverage.sv
# are intentionally not compiled in this restricted-license run.
vlog -timescale '1ns/1ns' design.sv testbench.sv

echo ""
echo "===================== RUNNING PLAIN SV ASSEMBLY TEST ====================="
vsim -c -do "vsim +access+rw -sv_lib libgolden work.tb_top; run -all; exit"