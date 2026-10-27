#!/bin/bash
# Usage:  bash sim/run_xsim.sh [tb_design_top | tb_csr_regs | tb_hier | tb_trap | tb_halt | all]
# Compiles dut/*.sv + the chosen tb/*.sv with Vivado xsim (falls back to
# iverilog if xvlog is not installed) and prints a PASS/FAIL line per testbench.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEL="${1:-all}"
[ "$SEL" = "all" ] && SEL="tb_design_top tb_csr_regs tb_hier tb_trap tb_halt"
declare -A PASSMSG=( [tb_design_top]="ALL CHECKS PASSED" [tb_csr_regs]="ALL CSR CHECKS PASSED" [tb_hier]="ALL HIERARCHY CHECKS PASSED" [tb_trap]="ALL TRAP CHECKS PASSED" [tb_halt]="ALL HALT CHECKS PASSED" )
rc=0
for tb in $SEL; do
  OUT="$ROOT/sim/xsim_run/$tb"; rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"
  echo "=== $tb"
  if command -v xvlog >/dev/null 2>&1; then
    N=$(ls "$ROOT"/dut/*.sv 2>/dev/null | wc -l)
    [ "$N" -gt 0 ] || { echo "no .sv files in $ROOT/dut"; rc=1; continue; }
    xvlog -sv "$ROOT"/dut/*.sv "$ROOT/tb/$tb.sv" -log xvlog.log >/dev/null 2>&1
    if grep -q "^ERROR" xvlog.log; then echo "xvlog failed:"; grep "^ERROR" xvlog.log | head; rc=1; continue; fi
    echo "compiled $N dut files + $tb.sv"
    xelab -debug typical "$tb" -s snap -timescale 1ns/1ns -log xelab.log >/dev/null 2>&1
    if grep -q "^ERROR" xelab.log; then echo "xelab failed:"; grep "^ERROR" xelab.log | head; rc=1; continue; fi
    xsim snap -R -log xsim.log >/dev/null 2>&1
    LOG=xsim.log
  else
    iverilog -g2012 -o snap.vvp "$ROOT"/dut/*.sv "$ROOT/tb/$tb.sv" 2>&1 | grep -iv "unique/unique0" ; vvp snap.vvp > run.log 2>&1
    LOG=run.log
  fi
  grep -E "^(PASS|FAIL)|total mem_stall|TIMEOUT" "$LOG"
  if grep -q "${PASSMSG[$tb]}" "$LOG"; then echo ">>> $tb: PASS"; else echo ">>> $tb: FAIL (see $OUT/$LOG)"; rc=1; fi
done
exit $rc
