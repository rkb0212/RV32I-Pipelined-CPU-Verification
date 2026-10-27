// =============================================================================
// tb_top.sv
// Clock, interface, DUT, config_db, run_test(). The DUT instance MUST be named
// `dut` and this module `tb_top`: cpu_if.sv reaches into tb_top.dut for the
// backdoor load/read.
// =============================================================================
`timescale 1ns/1ps
module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import cpu_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  cpu_if     vif        (clk);
  retire_if  retire_vif (clk);
  mem_if     mem_vif    (clk);
  axi_if     axi_vif    (clk, vif.rst_n);
  axi_sva    u_axi_sva  (axi_vif);          // AXI-Lite protocol assertions (tb/axi_sva.sv)

  design_top #(.IMEM_DEPTH(IMEM_DEPTH), .DMEM_DEPTH(DMEM_DEPTH)) dut (
    .clk                     (clk),
    .rst_n                   (vif.rst_n),
    .halt                    (vif.halt),
    .pc_out                  (vif.pc_out),
    .fault_misaligned_target (vif.fault_misaligned_target),
    .fault_mem_misaligned    (vif.fault_mem_misaligned),
    .fault_mem_out_of_range  (vif.fault_mem_out_of_range),
    .trap_taken              (vif.trap_taken)
  );

  // ---- probe interfaces for the passive agents (the only place DUT net names appear) ----
  assign retire_vif.retired    = dut.instr_retired;
  assign retire_vif.pc         = dut.ex_mem_pc;
  assign retire_vif.rd         = dut.ex_mem_rd_addr;
  assign retire_vif.reg_write  = dut.ex_mem_reg_write;
  assign retire_vif.result     = dut.mem_result;
  assign retire_vif.is_store   = dut.ex_mem_mem_write;
  assign retire_vif.store_addr = dut.ex_mem_alu_result;
  assign retire_vif.store_data = dut.ex_mem_store_data;
  assign retire_vif.is_halt    = dut.ex_mem_is_halt;

  assign mem_vif.addr          = dut.cache_addr;
  assign mem_vif.wdata         = dut.cache_wdata;
  assign mem_vif.wr_en         = dut.cache_wr_en;
  assign mem_vif.rd_en         = dut.cache_rd_en;
  assign mem_vif.rdata         = dut.mem_result;
  assign mem_vif.stall         = dut.mem_stall;
  assign mem_vif.misaligned    = dut.mem_misaligned;
  assign mem_vif.out_of_range  = dut.mem_out_of_range;
  assign mem_vif.is_l1         = dut.is_l1;
  assign mem_vif.is_csr        = dut.is_csr;
  assign mem_vif.is_ext        = dut.is_ext;
  assign mem_vif.is_gap        = dut.is_gap;
  assign mem_vif.l2_hit        = dut.u_l2_cache.hit;
  assign mem_vif.l3_hit        = dut.u_l3_cache.hit;

  assign axi_vif.awvalid = dut.axi_awvalid;  assign axi_vif.awready = dut.axi_awready;  assign axi_vif.awaddr = dut.axi_awaddr;
  assign axi_vif.wvalid  = dut.axi_wvalid;   assign axi_vif.wready  = dut.axi_wready;
  assign axi_vif.wdata   = dut.axi_wdata;    assign axi_vif.wstrb   = dut.axi_wstrb;
  assign axi_vif.bvalid  = dut.axi_bvalid;   assign axi_vif.bready  = dut.axi_bready;   assign axi_vif.bresp  = dut.axi_bresp;
  assign axi_vif.arvalid = dut.axi_arvalid;  assign axi_vif.arready = dut.axi_arready;  assign axi_vif.araddr = dut.axi_araddr;
  assign axi_vif.rvalid  = dut.axi_rvalid;   assign axi_vif.rready  = dut.axi_rready;
  assign axi_vif.rdata   = dut.axi_rdata;    assign axi_vif.rresp   = dut.axi_rresp;

  initial begin
    vif.rst_n = 1'b0;
    uvm_config_db#(virtual cpu_if)   ::set(null, "*", "vif",        vif);
    uvm_config_db#(virtual retire_if)::set(null, "*", "retire_vif", retire_vif);
    uvm_config_db#(virtual mem_if)   ::set(null, "*", "mem_vif",    mem_vif);
    uvm_config_db#(virtual axi_if)   ::set(null, "*", "axi_vif",    axi_vif);
    run_test();                      // test chosen with +UVM_TESTNAME=...
  end
endmodule
