// =============================================================================
// cpu_if.sv
// Simple interface wrapping the DUT's external ports.
//
// For this RV32I-subset CPU, pc_out is 32-bit because the PC is byte-addressed
// and increments by 4. Instruction memory, data memory, and register file are
// still accessed through UVM backdoor paths inside cpu_pkg.sv.
// =============================================================================

interface cpu_if (input logic clk);
  logic        rst_n;
  logic        halt;
  logic [31:0] pc_out;
endinterface
