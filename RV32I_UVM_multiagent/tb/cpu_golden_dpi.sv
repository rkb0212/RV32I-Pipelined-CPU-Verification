// =============================================================================
// cpu_golden_dpi.sv
// DPI-C imports of golden_model.cpp. Only 32-bit `int` crosses the boundary;
// memory indices are WORD indices. Compiled for xsim with `xsc golden_model.cpp`
// and loaded with `xelab -sv_lib dpi` (sim/run_uvm_xsim.sh does both).
// =============================================================================
import "DPI-C" function void gm_reset();
import "DPI-C" function void gm_load_instr(input int idx, input int instr);
import "DPI-C" function void gm_run(input int max_steps);

import "DPI-C" function int  gm_get_reg(input int idx);
import "DPI-C" function int  gm_reg_tainted(input int idx);
import "DPI-C" function int  gm_get_dmem(input int word);
import "DPI-C" function int  gm_dmem_tainted(input int word);
import "DPI-C" function int  gm_get_ext(input int word);
import "DPI-C" function int  gm_ext_tainted(input int word);
import "DPI-C" function int  gm_get_pc();
import "DPI-C" function int  gm_get_halt_pc();
import "DPI-C" function int  gm_is_halted();
import "DPI-C" function int  gm_is_diverged();
import "DPI-C" function int  gm_get_instr_count();
import "DPI-C" function int  gm_get_mepc();
import "DPI-C" function int  gm_get_mcause();
import "DPI-C" function int  gm_get_mtval();
import "DPI-C" function int  gm_get_trap_count();
import "DPI-C" function int  gm_get_misalign_count();
import "DPI-C" function int  gm_get_oor_count();
import "DPI-C" function int  gm_get_target_fault_count();
import "DPI-C" function int  gm_get_steps();
import "DPI-C" function int  gm_cov_count();            // number of functional-coverage bins the model counts
import "DPI-C" function int  gm_cov_get(input int id);  // hits of bin <id> over the whole run
