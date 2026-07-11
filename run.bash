#!/bin/bash
set -e

# Compile the DPI-C golden model.
gcc -shared -fPIC -o libgolden.so golden_model.c

# Create/refresh HDL library.
vlib work

# Compile RTL + UVM TB + SVA + coverage.
vlog -timescale '1ns/1ns' \
     +incdir+$RIVIERA_HOME/vlib/uvm-1.2/src \
     -l uvm_1_2 \
     -err VCP2947 W9 \
     -err VCP2974 W9 \
     -err VCP3003 W9 \
     -err VCP5417 W9 \
     -err VCP6120 W9 \
     -err VCP7862 W9 \
     -err VCP2129 W9 \
     design.sv testbench.sv cpu_sva.sv cpu_coverage.sv

run_test () {
  local test_name="$1"
  local tag="$2"

  echo ""
  echo "===================== RUNNING ${test_name} ====================="
  vsim -c -do "vsim +access+rw +UVM_TESTNAME=${test_name} -sv_lib libgolden; run -all; exit"

  if [ -f fcover.acdb ]; then
    mv -f fcover.acdb "fcover_${tag}.acdb"
  fi
}

run_test cpu_hazard_test hazard
run_test cpu_rand_test rand

# Merge and print the official ACDB coverage/assertion report if ACDB files exist.
if [ -f fcover_hazard.acdb ] && [ -f fcover_rand.acdb ]; then
  echo ""
  echo "===================== MERGED ACDB COVERAGE + ASSERTION REPORT ====================="
  vsimsa -do "acdb merge -i fcover_hazard.acdb -i fcover_rand.acdb -o fcover_merged.acdb; acdb report -i fcover_merged.acdb -o coverage_final.txt -txt -assertions -covers -show covergroups,hierarchy; exit"
  cat coverage_final.txt
else
  echo "WARNING: fcover_hazard.acdb or fcover_rand.acdb not found; skipping merged ACDB report."
fi
