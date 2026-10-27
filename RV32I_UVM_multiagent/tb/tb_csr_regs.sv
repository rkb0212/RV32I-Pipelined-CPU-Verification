`timescale 1ns/1ns
// Directed check for the new csr_regs.sv integration: builds x6 = CSR_BASE
// with LUI+ADDI (no new instructions needed), writes SCRATCH, reads it
// back, then writes HALT_CTRL and confirms halt asserts with no ECALL.
module tb_csr_regs;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic halt;
  logic [31:0] pc_out;
  logic fault_misaligned_target, fault_mem_misaligned, fault_mem_out_of_range;

  design_top #(.IMEM_DEPTH(64), .DMEM_DEPTH(64)) dut (
    .clk(clk), .rst_n(rst_n),
    .halt(halt), .pc_out(pc_out),
    .fault_misaligned_target(fault_misaligned_target),
    .fault_mem_misaligned(fault_mem_misaligned),
    .fault_mem_out_of_range(fault_mem_out_of_range), .trap_taken()
  );

  function automatic [31:0] enc_i(input [11:0] imm, input [4:0] rs1,
                                    input [2:0] f3, input [4:0] rd, input [6:0] op);
    enc_i = {imm, rs1, f3, rd, op};
  endfunction
  function automatic [31:0] enc_s(input [11:0] imm, input [4:0] rs2, rs1,
                                    input [2:0] f3, input [6:0] op);
    enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
  endfunction
  function automatic [31:0] enc_u(input [31:12] imm, input [4:0] rd, input [6:0] op);
    enc_u = {imm, rd, op};
  endfunction

  localparam [6:0] OPI=7'b0010011, LOAD=7'b0000011, STORE=7'b0100011, LUI=7'b0110111;

  int errors = 0;
  task automatic check(input string name, input logic [31:0] act, exp);
    if (act !== exp) begin
      errors++;
      $display("FAIL %-28s got=0x%08h exp=0x%08h", name, act, exp);
    end else
      $display("PASS %-28s = 0x%08h", name, act);
  endtask

  initial begin
    // CSR_BASE = 0xFFFF_FF00, which is exactly -256 sign-extended to 32
    // bits -- no LUI needed, ADDI x0,-256 alone produces it.
    // 0: ADDI x1, x0, 77            -> x1 = 77 (value to scratch)
    // 1: ADDI x6, x0, -256 (0xF00)  -> x6 = 0xFFFFFF00 = CSR_BASE
    // 2: SW   x1, 12(x6)            -> SCRATCH (offset 0xC) = 77
    // 3: LW   x7, 12(x6)            -> x7 = SCRATCH = 77
    // 4: LW   x8, 4(x6)             -> x8 = INSTR_COUNT so far
    // 5: ADDI x9, x0, 1             -> x9 = 1 (halt-request bit)
    // 6: SW   x9, 8(x6)             -> HALT_CTRL = 1 -> sw_halt_req fires
    // 7: ADDI x10, x0, 555          -> must be SKIPPED, core already halted
    dut.instr_mem[0] = enc_i(12'd77, 5'd0, 3'b000, 5'd1, OPI);
    dut.instr_mem[1] = enc_i(-12'sd256, 5'd0, 3'b000, 5'd6, OPI);
    dut.instr_mem[2] = enc_s(12'd12, 5'd1, 5'd6, 3'b010, STORE);
    dut.instr_mem[3] = enc_i(12'd12, 5'd6, 3'b010, 5'd7, LOAD);
    dut.instr_mem[4] = enc_i(12'd4,  5'd6, 3'b010, 5'd8, LOAD);
    dut.instr_mem[5] = enc_i(12'd1,  5'd0, 3'b000, 5'd9, OPI);
    dut.instr_mem[6] = enc_s(12'd8,  5'd9, 5'd6, 3'b010, STORE);
    dut.instr_mem[7] = enc_i(12'd555, 5'd0, 3'b000, 5'd10, OPI);

    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;

    fork
      begin
        wait (halt === 1'b1);
      end
      begin
        repeat (30) begin
          @(posedge clk);
          $display("t=%0t pc=0x%0h instr=0x%0h cache_addr=0x%0h is_csr=%0b wr=%0b rd=%0b halt=%0b sw_halt=%0b",
                    $time, dut.pc, dut.if_id_instr, dut.cache_addr, dut.is_csr,
                    dut.cache_wr_en, dut.cache_rd_en, halt, dut.sw_halt_req);
        end
      end
    join_any
    disable fork;
    @(posedge clk); #1;

    check("x6  (CSR_BASE built)",  dut.u_regfile.regs[6], 32'hFFFFFF00);
    check("x7  (SCRATCH readback)", dut.u_regfile.regs[7], 32'd77);
    check("x10 (skipped post-halt)", dut.u_regfile.regs[10], 32'd0);
    check("halt (software-triggered)", {31'b0,halt}, 32'd1);

    if (dut.u_regfile.regs[8] == 32'd0)
      $display("FAIL x8 (INSTR_COUNT) should be nonzero by instruction 5");
    else
      $display("PASS x8 (INSTR_COUNT) = %0d retired instructions", dut.u_regfile.regs[8]);

    if (errors == 0) $display("\nALL CSR CHECKS PASSED");
    else $display("\n%0d CHECK(S) FAILED", errors);
    $finish;
  end

  initial begin
    #5000;
    $display("TIMEOUT -- halt never asserted");
    $finish;
  end
endmodule
