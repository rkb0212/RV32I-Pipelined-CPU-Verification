#!/bin/bash
# Run the UVM testbench with Vivado xsim.
#
#   bash sim/run_uvm_xsim.sh                         # cpu_regression_test, full log on the terminal
#   bash sim/run_uvm_xsim.sh cpu_trap_test           # one test
#   bash sim/run_uvm_xsim.sh cpu_trap_test cpu_mem_test   # several tests, one after another
#   bash sim/run_uvm_xsim.sh cpu_rand_test +NUM_RAND=500   # any +NAME=VALUE is passed to the simulation
#   bash sim/run_uvm_xsim.sh all                     # every test (see the list below)
#   bash sim/run_uvm_xsim.sh cpu_mem_test -log run.log    # log goes to run.log ONLY (terminal stays quiet)
#   bash sim/run_uvm_xsim.sh all -log all.log -v UVM_HIGH # save the whole log, with every item printed
#
# Options:  -log FILE | -l FILE   save the simulation log to FILE (appended) and do not print it
#           -v LEVEL              UVM_NONE | UVM_LOW (default) | UVM_MEDIUM | UVM_HIGH | UVM_FULL
#           -cov                  after each test, print only its functional-coverage report (tb/cpu_coverage.sv)
#           -sva                  after each test, print only the AXI assertion result (tb/axi_sva.sv)
#           -h                    this help
# Tests:    cpu_hazard_test cpu_trap_test cpu_halt_test cpu_mem_test cpu_decode_test cpu_pipeline_test
#           cpu_cache_test cpu_status_test cpu_csr_test cpu_runoff_test cpu_reset_test cpu_rand_test cpu_regression_test
#           cpu_known_issue_test   (NOT in 'all'; runnable by name; EXPECTED TO FAIL: documents the DUT's double-flag finding)
# Random:   +NUM_RAND=<programs> (default 50)  +RAND_OPS=<ops per program> (default 24, max 48)
# Reset:    +RST_RAND=<n> extra random reset cut points for cpu_reset_test (default 6)
# The golden model (tb/golden_model.cpp) is compiled with xsc and loaded through DPI-C.
# Without -log the full log is printed live; with -log only a one-line PASS/FAIL per test is printed.
# Per-run files (xvlog/xelab/xsim logs) are always kept in sim/uvm_run/ for debugging.
# Needs Vivado xsim (UVM comes with it: -L uvm). Exit code is non-zero if any test fails.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUT_DIR="${DUT_DIR:-$ROOT/dut}"      # override to run against a modified copy of the DUT (see run_mutants.sh)
UVM_DIR="${UVM_DIR:-$ROOT/tb}"
START_DIR="$PWD"
ALL_TESTS="cpu_hazard_test cpu_trap_test cpu_halt_test cpu_mem_test cpu_decode_test cpu_pipeline_test cpu_cache_test cpu_status_test cpu_csr_test cpu_runoff_test cpu_reset_test cpu_rand_test cpu_regression_test"
SHOWCOV=0; SHOWSVA=0; TESTS=""; LOGFILE=""; VERB="UVM_LOW"; PLUSARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -log|-l|--log) LOGFILE="$2"; shift 2 ;;
    -v|--verbosity) VERB="$2"; shift 2 ;;
    -cov|--cov) SHOWCOV=1; shift ;;
    -sva|--sva) SHOWSVA=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
    all) TESTS="$TESTS $ALL_TESTS"; shift ;;
    +*) PLUSARGS+=(-testplusarg "${1#+}"); shift ;;      # e.g. +NUM_RAND=500 -> xsim -testplusarg NUM_RAND=500
    -*) echo "unknown option: $1 (try -h)"; exit 2 ;;
    *) TESTS="$TESTS $1"; shift ;;
  esac
done
[ -z "$TESTS" ] && TESTS="cpu_regression_test"
if [ -n "$LOGFILE" ]; then
  case "$LOGFILE" in /*) ;; *) LOGFILE="$START_DIR/$LOGFILE" ;; esac
  : > "$LOGFILE"                       # start a fresh log file
fi

command -v xvlog >/dev/null 2>&1 || { echo "xvlog not found -- run this inside the Vivado/xsim container"; exit 1; }
BUILD="$ROOT/sim/uvm_run/build"; rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD"

# say(): print to the terminal when no log file is requested; otherwise append to the log file
say() { if [ -n "$LOGFILE" ]; then echo "$@" >> "$LOGFILE"; else echo "$@"; fi; }

# ---- compile + elaborate once (SV, then the C golden model for DPI-C, then elaborate) ----
xvlog -sv -L uvm -i "$UVM_DIR" "$DUT_DIR"/*.sv "$UVM_DIR/cpu_if.sv" "$UVM_DIR/cpu_probe_if.sv" "$UVM_DIR/axi_sva.sv" "$UVM_DIR/cpu_pkg.sv" "$UVM_DIR/tb_top.sv" -log xvlog.log > xvlog.out 2>&1
if [ $? -ne 0 ] || grep -q "^ERROR" xvlog.out xvlog.log 2>/dev/null; then
  echo "xvlog failed:"; grep -h "^ERROR" xvlog.out xvlog.log 2>/dev/null | sort -u | head -30
  echo "--- raw xvlog output (tail) ---"; tail -15 xvlog.out; exit 1
fi
xsc "$UVM_DIR/golden_model.cpp" > xsc.out 2>&1; cp xsc.out xsc.log
if [ $? -ne 0 ]; then
  echo "xsc (C++ golden model) failed:"; head -30 xsc.out; exit 1
fi
xelab -L uvm -sv_lib dpi -debug typical tb_top -s snap -timescale 1ns/1ps -log xelab.log > xelab.out 2>&1
if [ $? -ne 0 ] || grep -q "^ERROR" xelab.out xelab.log 2>/dev/null; then
  echo "xelab failed:"; grep -h "^ERROR" xelab.out xelab.log 2>/dev/null | sort -u | head -30
  echo "--- raw xelab output (tail) ---"; tail -15 xelab.out; exit 1
fi
[ -n "$LOGFILE" ] && { cat xvlog.log xsc.log xelab.log >> "$LOGFILE" 2>/dev/null; }

# ---- verdict for one finished run (reads that run's xsim log) ----
verdict() {   # $1 = test name, $2 = xsim log
  local T="$1" L="$2" SBL UNP E F RET MEMN STAT AXI CMP OK=1 WHY=""
  E=$(grep -E "^UVM_ERROR *:" "$L" | awk '{print $NF}'); F=$(grep -E "^UVM_FATAL *:" "$L" | awk '{print $NF}')
  RET=$(grep -E "retire_checker summary" "$L" | head -1 | sed -E 's/.*summary: ([0-9]+).*/\1/')
  MEMN=$(grep -E "mem_checker summary" "$L" | head -1 | sed -E 's/.*summary: ([0-9]+).*/\1/')
  STAT=$(grep -E "status_checker summary" "$L" | head -1 | sed -E 's/.*halts=([0-9]+).*/\1/')
  SBL=$(grep -E "\[CPU_SB\] SUMMARY" "$L" | head -1)
  CMP=$(echo "$SBL" | sed -E 's/.*match=([0-9]+) mismatch=([0-9]+).*/\1 \2/' | awk '{print $1+$2}')
  UNP=$(echo "$SBL" | sed -E 's/.*unpredicted=([0-9]+).*/\1/')
  AXI=$(grep -E "axi_checker summary" "$L" | head -1 | sed -E 's/.*summary: ([0-9]+) write.* ([0-9]+) read.*/\1 \2/' | awk '{print $1+$2}')
  [ "${E:-1}" = "0" ] && [ "${F:-1}" = "0" ] || { OK=0; WHY="$WHY UVM_ERROR=${E:-?} UVM_FATAL=${F:-?};"; }
  [ -n "$SBL" ] || { OK=0; WHY="$WHY scoreboard saw no runs;"; }
  [ "${UNP:-0}" = "0" ] || { OK=0; WHY="$WHY $UNP unpredicted run(s);"; }
  [ "${CMP:-0}" -gt 0 ]  || { OK=0; WHY="$WHY golden compare did not run;"; }
  [ "${RET:-0}" -gt 0 ]  || { OK=0; WHY="$WHY retire_agent silent;"; }
  [ "${MEMN:-0}" -gt 0 ] || [ "$T" = cpu_runoff_test ] || { OK=0; WHY="$WHY mem_agent silent;"; }   # run-off programs make no memory access
  [ "${STAT:-0}" -gt 0 ] || { OK=0; WHY="$WHY status_agent silent;"; }
  case "$T" in cpu_mem_test|cpu_halt_test|cpu_cache_test|cpu_pipeline_test|cpu_status_test|cpu_regression_test) [ "${AXI:-0}" -gt 0 ] || { OK=0; WHY="$WHY axi_agent silent;"; } ;; esac
  if [ "$OK" = 1 ]; then echo "PASS $T"; return 0; else echo "FAIL $T:$WHY (see $L)"; return 1; fi
}

# ---- run each test ----
RESULTS=""; NFAIL=0
for T in $TESTS; do
  RUNLOG="$BUILD/xsim_$T.log"
  if [ -n "$LOGFILE" ]; then
    xsim snap -R -testplusarg "UVM_TESTNAME=$T" -testplusarg "UVM_VERBOSITY=$VERB" "${PLUSARGS[@]}" -log "$RUNLOG" > /dev/null 2>&1
    { echo; echo "=================== $T ==================="; cat "$RUNLOG"; } >> "$LOGFILE"
  else
    echo; echo "=================== $T ==================="
    xsim snap -R -testplusarg "UVM_TESTNAME=$T" -testplusarg "UVM_VERBOSITY=$VERB" "${PLUSARGS[@]}" -log "$RUNLOG" 2>&1
  fi
  if [ "$SHOWCOV" = 1 ]; then echo "--- functional coverage: $T ---"; grep -E "\[COVERAGE\]" "$RUNLOG" | sed -E 's/^UVM_INFO [^ ]+ @ [0-9]+: reporter \[COVERAGE\] //'; fi
  if [ "$SHOWSVA" = 1 ]; then
    NS=$(grep -c "AXI_SVA" "$RUNLOG"); echo "--- AXI assertions: $T: $NS failure line(s) ---"
    grep "AXI_SVA" "$RUNLOG" | sed 's/^/    /' | head -20
    grep "axi_checker summary" "$RUNLOG" | sed -E 's/.*(axi_checker summary.*)/    traffic watched: \1/'
  fi
  R=$(verdict "$T" "$RUNLOG"); [ $? -ne 0 ] && NFAIL=$((NFAIL+1))
  RESULTS="$RESULTS$R"$'\n'
  if [ -n "$LOGFILE" ]; then echo "$R" | tee -a "$LOGFILE"; else echo ">>> $R"; fi
done

if [ "$(echo $TESTS | wc -w)" -gt 1 ]; then
  echo; echo "=========== summary ==========="; printf "%s" "$RESULTS"
fi
[ -n "$LOGFILE" ] && echo "log saved to $LOGFILE"
[ "$NFAIL" -eq 0 ]
