// =============================================================================
// cpu_pkg.sv  -- UVM package for the RV32I pipelined CPU (Phase 2: golden-model compare)
// One class per file, pulled in dependency order. Compile this AFTER cpu_if.sv
// and the DUT, BEFORE tb_top.sv, with the uvm library:   xvlog -L uvm -sv ...
// =============================================================================
package cpu_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  localparam int IMEM_DEPTH = 256;   // must equal design_top's IMEM_DEPTH
  localparam int DMEM_DEPTH = 256;   // must equal design_top's DMEM_DEPTH
  localparam int IMC_WORDS  = 4096;  // must equal design_top's IMC_WORDS

  `include "cpu_functions.sv"

  `include "cpu_program.sv"
  `include "cpu_actual.sv"
  `include "cpu_expected.sv"
  `include "cpu_golden_dpi.sv"

  `include "cpu_driver.sv"
  `include "cpu_monitor.sv"
  `include "cpu_predictor.sv"
  `include "cpu_scoreboard.sv"
  `include "cpu_ctrl_agent.sv"      // active agent (the only sequencer)
  `include "cpu_retire_agent.sv"    // passive agents: item + monitor + agent each
  `include "cpu_mem_agent.sv"
  `include "cpu_axi_agent.sv"
  `include "cpu_status_agent.sv"
  `include "cpu_checkers.sv"        // one checker per passive agent
  `include "cpu_coverage.sv"        // functional coverage (golden-model counters + live monitors)
  `include "cpu_env.sv"

  `include "cpu_sequences.sv"       // every sequence, one file

  `include "cpu_tests.sv"           // every test, one file
endpackage
