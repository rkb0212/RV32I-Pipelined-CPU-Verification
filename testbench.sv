// =============================================================================
// tb_top.sv
// Top-level module for EDA Playground. Instantiates the DUT as `dut` (the
// UVM driver/monitor backdoor paths in cpu_pkg.sv assume this exact instance
// name: "tb_top.dut...") and the cpu_if interface, then hands control to UVM.
//
// EDA Playground setup:
//   - Testbench Tool: pick a simulator with UVM 1.2 + DPI-C support
//     (Synopsys VCS, Cadence Xcelium, Siemens Questa, or Aldec Riviera-PRO
//     all work; Icarus Verilog does NOT support the full UVM base classes)
//   - Add golden_model.c under the "Files" panel / C files section
//   - Compile order: design.sv, cpu_if.sv, cpu_pkg.sv, testbench.sv,
//                    cpu_sva.sv, cpu_coverage.sv
//   - Run with: +UVM_TESTNAME=cpu_hazard_test   (or cpu_rand_test)
//   - Enable backdoor access for UVM HDL calls, e.g. +access+rw
// =============================================================================

`include "uvm_macros.svh"
`include "cpu_if.sv"
`include "cpu_pkg.sv"

import uvm_pkg::*;
import cpu_pkg::*;

module tb_top;

  logic clk = 0;
  always #5 clk = ~clk;

  cpu_if vif(clk);

  simple_cpu_pipelined dut (
    .clk    (clk),
    .rst_n  (vif.rst_n),
    .halt   (vif.halt),
    .pc_out (vif.pc_out)
  );

  initial begin
    uvm_config_db#(virtual cpu_if)::set(null, "*", "vif", vif);
    run_test();
  end

  // Global safety timeout in case a test forgets to drop its objection.
  initial begin
    #1_000_000;
    `uvm_fatal("TB_TOP", "Global timeout - test did not finish")
  end

endmodule
