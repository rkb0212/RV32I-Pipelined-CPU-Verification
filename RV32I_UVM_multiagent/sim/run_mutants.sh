#!/bin/bash
# Fault-injection check: copies dut/ to a scratch folder, breaks ONE thing, runs the tests against
# the broken copy, and shows the first error each test raised. dut/ itself is never touched.
#   bash run_mutants.sh                 # all six faults, tests: pipeline cache status mem
#   bash run_mutants.sh m4              # one fault
#   bash run_mutants.sh m2 cpu_cache_test cpu_mem_test    # one fault, chosen tests
# A fault is DETECTED when the test FAILS and the log has UVM_ERROR lines. The good DUT must pass.
#   m1 load-use stall removed (control_unit)      m4 iMC latency 5 instead of 4 (design_top)
#   m2 L2 hit ignores the tag (l2_cache)          m5 L3 write strobe 4'h7 instead of 4'hF (l3_cache)
#   m3 CSR out-of-range limit off by one (csr_regs)  m6 L3 write address XOR 4 (l3_cache)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="$ROOT/sim"
ALL="m1 m2 m3 m4 m5 m6"
case "$1" in m[1-6]) MUTS="$1"; shift ;; *) MUTS="$ALL" ;; esac
TESTS="$*"; [ -z "$TESTS" ] && TESTS="cpu_pipeline_test cpu_cache_test cpu_status_test cpu_mem_test"
W="$SIM/uvm_run/mutants"; mkdir -p "$W"

mutate() {   # mutate <id> <file> <old> <new>
  python3 - "$W/$1/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) < 1: sys.exit("mutation text not found in " + p)
open(p, "w").write(s.replace(old, new))
PY
}

for m in $MUTS; do
  rm -rf "$W/$m"; mkdir -p "$W/$m"; cp "$ROOT"/dut/*.sv "$W/$m/"
  case $m in
    m1) mutate m1 control_unit.sv "stall_load_use = 1'b1;" "stall_load_use = 1'b0;" ;;
    m2) mutate m2 l2_cache.sv "valid[idx] && (tag[idx] == tg);" "valid[idx];" ;;
    m3) mutate m3 csr_regs.sv "(offset >> 2) >= CSR_WORDS);" "(offset >> 2) >= CSR_WORDS + 1);" ;;
    m4) mutate m4 design_top.sv "IMC_LATENCY = 4" "IMC_LATENCY = 5" ;;
    m5) mutate m5 l3_cache.sv "m_wstrb   = 4'hF;" "m_wstrb   = 4'h7;" ;;
    m6) mutate m6 l3_cache.sv "addr_q <= up_addr; wdata_q" "addr_q <= up_wr_en ? (up_addr ^ 32'h4) : up_addr; wdata_q" ;;
  esac || { echo "$m: could not apply the fault"; continue; }
  echo "================ fault $m ================"
  for t in $TESTS; do
    L="$W/${m}_${t}.log"
    DUT_DIR="$W/$m" bash "$SIM/run_uvm_xsim.sh" $t -log "$L" > /dev/null 2>&1
    n=$(grep -c "^UVM_ERROR /" "$L" 2>/dev/null)
    if [ "${n:-0}" -gt 0 ]; then
      by=$(grep "^UVM_ERROR /" "$L" | sed -E 's/^UVM_ERROR [^[]*\[([A-Z_]+)\].*/\1/' | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
      echo "  DETECTED  $t : $n UVM_ERROR line(s)   [ ${by}]"
      grep -m2 "^UVM_ERROR /" "$L" | sed -E 's#^UVM_ERROR [^ ]+ @ [0-9]+: [^ ]+ ##' | cut -c1-170 | sed 's/^/      /'
    else
      echo "  not seen  $t"
    fi
  done
done
echo "(logs in sim/uvm_run/mutants/)"
