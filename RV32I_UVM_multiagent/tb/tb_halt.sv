// =============================================================================
// tb_halt.sv -- halt must really stop the CPU.
//   A: ECALL halt. Instructions after it (a plain ADDI, a taken BEQ that would
//      move the PC, another ADDI) must never commit; the PC must freeze; the
//      instruction right before ECALL must still commit.
//   B: software halt (SW 1 -> HALT_CTRL) right after a stalled external store.
//      The halting SW itself and the ext store must complete; a later SW to
//      SCRATCH and later ADDIs must not.
//   Then reset: halt must clear, PC restart at 0, and both programs halt again.
// =============================================================================
`timescale 1ns/1ps
module tb_halt;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic        ha, hb, fa1, fa2, fa3, ta, fb1, fb2, fb3, tbp;
  logic [31:0] pca, pcb;

  design_top #(.IMEM_DEPTH(64), .DMEM_DEPTH(64)) dut_a (.clk(clk), .rst_n(rst_n), .halt(ha), .pc_out(pca),
    .fault_misaligned_target(fa1), .fault_mem_misaligned(fa2), .fault_mem_out_of_range(fa3), .trap_taken(ta));
  design_top #(.IMEM_DEPTH(64), .DMEM_DEPTH(64)) dut_b (.clk(clk), .rst_n(rst_n), .halt(hb), .pc_out(pcb),
    .fault_misaligned_target(fb1), .fault_mem_misaligned(fb2), .fault_mem_out_of_range(fb3), .trap_taken(tbp));

  function automatic [31:0] enc_i(input [11:0] imm, input [4:0] rs1, input [2:0] f3, input [4:0] rd, input [6:0] op);
    enc_i = {imm, rs1, f3, rd, op};
  endfunction
  function automatic [31:0] enc_r(input [6:0] f7, input [4:0] rs2, rs1, input [2:0] f3, input [4:0] rd, input [6:0] op);
    enc_r = {f7, rs2, rs1, f3, rd, op};
  endfunction
  function automatic [31:0] enc_s(input [11:0] imm, input [4:0] rs2, rs1, input [2:0] f3, input [6:0] op);
    enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
  endfunction
  function automatic [31:0] enc_b(input [12:0] imm, input [4:0] rs2, rs1, input [2:0] f3, input [6:0] op);
    enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], op};
  endfunction
  localparam [6:0] OP=7'b0110011, OPI=7'b0010011, STORE=7'b0100011, BR=7'b1100011;
  localparam [31:0] ECALL = 32'h0000_0073;
  localparam [11:0] POISON = 12'h7AD;

  int errors = 0;
  task automatic check(input string name, input logic [31:0] act, exp);
    if (act !== exp) begin errors++; $display("FAIL %-40s got=0x%08h exp=0x%08h", name, act, exp); end
    else $display("PASS %-40s = 0x%08h", name, act);
  endtask

  task automatic load_programs();
    // ---- A: ECALL ----
    dut_a.instr_mem[0] = enc_i(12'd5, 5'd0, 3'b000, 5'd1, OPI);        // ADDI x1,x0,5
    dut_a.instr_mem[1] = enc_i(12'd7, 5'd0, 3'b000, 5'd2, OPI);        // ADDI x2,x0,7
    dut_a.instr_mem[2] = enc_r(7'b0, 5'd2, 5'd1, 3'b000, 5'd3, OP);    // ADD  x3,x1,x2
    dut_a.instr_mem[3] = enc_i(12'd9, 5'd0, 3'b000, 5'd4, OPI);        // ADDI x4,x0,9  (right before ECALL)
    dut_a.instr_mem[4] = ECALL;                                        // HALT
    dut_a.instr_mem[5] = enc_i(POISON, 5'd0, 3'b000, 5'd9, OPI);       // poison (in EX when ECALL is in MEM)
    dut_a.instr_mem[6] = enc_b(13'd8, 5'd0, 5'd0, 3'b000, BR);         // taken BEQ -> would move the PC
    dut_a.instr_mem[7] = enc_i(POISON, 5'd0, 3'b000, 5'd10, OPI);      // poison
    dut_a.instr_mem[8] = enc_i(POISON, 5'd0, 3'b000, 5'd11, OPI);      // poison
    // ---- B: software halt after a stalled ext store ----
    dut_b.instr_mem[0] = enc_i(12'hF00, 5'd0, 3'b000, 5'd20, OPI);     // x20 = 0xFFFF_FF00
    dut_b.instr_mem[1] = enc_i(12'd1,   5'd0, 3'b000, 5'd1,  OPI);     // x1 = 1
    dut_b.instr_mem[2] = enc_i(12'h100, 5'd0, 3'b000, 5'd5,  OPI);     // x5 = 0x100 (beyond L1)
    dut_b.instr_mem[3] = enc_s(12'd0,   5'd1, 5'd5,  3'b010, STORE);   // SW x1,0(x5)  ext store, stalls
    dut_b.instr_mem[4] = enc_i(12'h066, 5'd0, 3'b000, 5'd6,  OPI);     // x6 = 0x66
    dut_b.instr_mem[5] = enc_s(12'd8,   5'd1, 5'd20, 3'b010, STORE);   // SW x1,8(x20) HALT_CTRL=1
    dut_b.instr_mem[6] = enc_i(POISON, 5'd0, 3'b000, 5'd9,  OPI);      // poison
    dut_b.instr_mem[7] = enc_i(POISON, 5'd0, 3'b000, 5'd10, OPI);      // poison
    dut_b.instr_mem[8] = enc_s(12'd12,  5'd1, 5'd20, 3'b010, STORE);   // poison SW SCRATCH
  endtask

  logic [31:0] pca_frozen, pcb_frozen, ica, icb;

  task automatic run_and_check(input string tag);
    wait (ha === 1'b1 && hb === 1'b1);
    @(posedge clk); #1;
    pca_frozen = pca; pcb_frozen = pcb;
    ica = dut_a.u_csr_regs.instr_count; icb = dut_b.u_csr_regs.instr_count;
    repeat (20) @(posedge clk);
    #1;
    $display("--- %s ---", tag);
    check({tag, " A: PC frozen"},              pca, pca_frozen);
    check({tag, " B: PC frozen"},              pcb, pcb_frozen);
    check({tag, " A: instr_count frozen"},     dut_a.u_csr_regs.instr_count, ica);
    check({tag, " B: instr_count frozen"},     dut_b.u_csr_regs.instr_count, icb);
    check({tag, " A: halt stays 1"},           {31'b0, ha}, 32'd1);
    check({tag, " B: halt stays 1"},           {31'b0, hb}, 32'd1);
    // A: older instructions committed, younger ones did not
    check({tag, " A: x1"},                     dut_a.u_regfile.regs[1],  32'd5);
    check({tag, " A: x3 (ADD)"},               dut_a.u_regfile.regs[3],  32'd12);
    check({tag, " A: x4 (just before ECALL)"}, dut_a.u_regfile.regs[4],  32'd9);
    check({tag, " A: x9  poison squashed"},    dut_a.u_regfile.regs[9],  32'd0);
    check({tag, " A: x10 poison squashed"},    dut_a.u_regfile.regs[10], 32'd0);
    check({tag, " A: x11 poison squashed"},    dut_a.u_regfile.regs[11], 32'd0);
    check({tag, " A: instr_count = 5"},        dut_a.u_csr_regs.instr_count, 32'd5);
    // B: stalled ext store + halting SW completed, later work did not
    check({tag, " B: ext store reached iMC"},  dut_b.u_imc.mem[64],      32'd1);
    check({tag, " B: x6 (before halting SW)"}, dut_b.u_regfile.regs[6],  32'h66);
    check({tag, " B: HALT_CTRL written"},      dut_b.u_csr_regs.halt_ctrl_reg, 32'd1);
    check({tag, " B: x9  poison squashed"},    dut_b.u_regfile.regs[9],  32'd0);
    check({tag, " B: x10 poison squashed"},    dut_b.u_regfile.regs[10], 32'd0);
    check({tag, " B: poison SW not done"},     dut_b.u_csr_regs.scratch, 32'd0);
    check({tag, " B: instr_count = 6"},        dut_b.u_csr_regs.instr_count, 32'd6);
  endtask

  initial begin
    load_programs();
    rst_n = 0; repeat (3) @(posedge clk); rst_n = 1;
    run_and_check("run1");

    // Reset must clear halt and restart both programs from PC 0.
    rst_n = 0; repeat (2) @(posedge clk); #1;
    check("after reset: A halt cleared", {31'b0, ha}, 32'd0);
    check("after reset: B halt cleared", {31'b0, hb}, 32'd0);
    check("after reset: A pc = 0",       pca, 32'd0);
    check("after reset: B pc = 0",       pcb, 32'd0);
    rst_n = 1;
    run_and_check("run2");

    if (errors == 0) $display("\nALL HALT CHECKS PASSED");
    else             $display("\n%0d HALT CHECK(S) FAILED", errors);
    $finish;
  end

  initial begin #200000; $display("TIMEOUT -- a halt never asserted (ha=%b hb=%b)", ha, hb); $finish; end
endmodule
