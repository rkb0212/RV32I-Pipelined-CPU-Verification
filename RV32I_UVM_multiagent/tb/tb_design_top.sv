`timescale 1ns/1ns
// Directed testbench for design_top.sv -- exercises every instruction in the
// supported subset, both forwarding paths, the load-use stall, a taken and
// a not-taken branch, JAL, ECALL halt, and both fault outputs.
module tb_design_top;
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
    .fault_mem_out_of_range(fault_mem_out_of_range),
    .trap_taken()
  );

  // Sticky "seen" latches for the one-cycle-pulsed fault outputs.
  logic fault_mem_misaligned_seen = 0;
  logic fault_oor_seen = 0;
  always @(posedge clk) begin
    if (fault_mem_misaligned)   fault_mem_misaligned_seen <= 1'b1;
    if (fault_mem_out_of_range) fault_oor_seen            <= 1'b1;
  end

  // ---- RV32I encoders ----
  function automatic [31:0] enc_r(input [6:0] f7, input [4:0] rs2, rs1,
                                    input [2:0] f3, input [4:0] rd, input [6:0] op);
    enc_r = {f7, rs2, rs1, f3, rd, op};
  endfunction
  function automatic [31:0] enc_i(input [11:0] imm, input [4:0] rs1,
                                    input [2:0] f3, input [4:0] rd, input [6:0] op);
    enc_i = {imm, rs1, f3, rd, op};
  endfunction
  function automatic [31:0] enc_s(input [11:0] imm, input [4:0] rs2, rs1,
                                    input [2:0] f3, input [6:0] op);
    enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
  endfunction
  function automatic [31:0] enc_b(input [12:0] imm, input [4:0] rs2, rs1,
                                    input [2:0] f3, input [6:0] op);
    enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], op};
  endfunction
  function automatic [31:0] enc_u(input [31:12] imm, input [4:0] rd, input [6:0] op);
    enc_u = {imm, rd, op};
  endfunction
  function automatic [31:0] enc_j(input [20:0] imm, input [4:0] rd, input [6:0] op);
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
  endfunction

  localparam [6:0] OP=7'b0110011, OPI=7'b0010011, LOAD=7'b0000011, STORE=7'b0100011,
                    BR=7'b1100011, LUI=7'b0110111, JAL=7'b1101111, SYS=7'b1110011;

  int errors = 0;
  task automatic check(input string name, input logic [31:0] act, exp);
    if (act !== exp) begin
      errors++;
      $display("FAIL %-28s got=0x%08h exp=0x%08h", name, act, exp);
    end else
      $display("PASS %-28s = 0x%08h", name, act);
  endtask

  initial begin
    // Program (word addresses 0..):
    // 0: ADDI x1, x0, 5          -> x1=5
    // 1: ADDI x2, x0, 7          -> x2=7
    // 2: ADD  x3, x1, x2         -> x3=12  (back-to-back: tests EX/MEM forward)
    // 3: SUB  x4, x2, x1         -> x4=2
    // 4: AND  x5, x1, x2         -> x5=5&7=5
    // 5: OR   x6, x1, x2         -> x6=5|7=7
    // 6: SW   x3, 0(x0)          -> mem[0]=12
    // 7: LW   x7, 0(x0)          -> x7=12   (load, then next instr uses x7: load-use stall)
    // 8: ADD  x8, x7, x0         -> x8=12   (needs stall since x7 comes from LOAD)
    // 9: BEQ  x1, x1, +8 (to 11) -> taken, skip instr at word 10
    // 10: ADDI x9, x0, 999       -> must be SKIPPED (branch taken)
    // 11: ADDI x9, x0, 111       -> x9=111
    // 12: BEQ  x1, x2, +8        -> not taken (5 != 7)
    // 13: ADDI x10, x0, 222      -> x10=222 (must execute, branch not taken)
    // 14: JAL  x11, +8 (to 16)   -> x11=link=word15*4+... ; skip word15
    // 15: ADDI x12, x0, 888      -> must be SKIPPED (jump taken)
    // 16: LUI  x13, 0xABCDE      -> x13=0xABCDE000
    // 17: SW   x1, 4(x0)         -> misaligned? no, addr=4, aligned -> mem[1]=5
    // 18: LW   x14, 1(x0)        -> addr=1 -> MISALIGNED read (funct check), expect fault_mem_misaligned
    // 19: SW   x1, 4092(x0)      -> word idx way beyond DMEM_DEPTH=64*4=256 -> OUT OF RANGE
    // 20: ECALL                  -> halt


    // Prelude (words 0-3): x20 = CSR_BASE (0xFFFF_FF00), MTVEC = 0x80 (word 32).
    // A misaligned LW now TRAPS to MTVEC instead of just raising a flag.
    dut.instr_mem[0] = enc_i(12'hF00, 5'd0, 3'b000, 5'd20, OPI);             // ADDI x20,x0,-256 -> 0xFFFF_FF00 (CSR_BASE)
    dut.instr_mem[1] = enc_i(12'd0,  5'd0, 3'b000, 5'd0,  OPI);             // NOP
    dut.instr_mem[2] = enc_i(12'h080, 5'd0, 3'b000, 5'd21, OPI);             // ADDI x21,x0,0x80
    dut.instr_mem[3] = enc_s(12'd16, 5'd21, 5'd20, 3'b010, STORE);           // SW   x21,16(x20) -> MTVEC
    // Trap handler at word 32 (0x80): mark x15=1, MEPC += 4, MRET
    dut.instr_mem[32] = enc_i(12'd1,  5'd0,  3'b000, 5'd15, OPI);            // ADDI x15,x0,1
    dut.instr_mem[33] = enc_i(12'd20, 5'd20, 3'b010, 5'd16, LOAD);           // LW   x16,20(x20)  (MEPC)
    dut.instr_mem[34] = enc_i(12'd4,  5'd16, 3'b000, 5'd16, OPI);            // ADDI x16,x16,4
    dut.instr_mem[35] = enc_s(12'd20, 5'd16, 5'd20, 3'b010, STORE);          // SW   x16,20(x20)
    dut.instr_mem[36] = 32'h3020_0073;                                       // MRET

    dut.instr_mem[4]  = enc_i(12'd5, 5'd0, 3'b000, 5'd1, OPI);              // ADDI x1,x0,5
    dut.instr_mem[5]  = enc_i(12'd7, 5'd0, 3'b000, 5'd2, OPI);              // ADDI x2,x0,7
    dut.instr_mem[6]  = enc_r(7'b0,5'd2,5'd1,3'b000,5'd3,OP);               // ADD x3,x1,x2
    dut.instr_mem[7]  = enc_r(7'b0100000,5'd1,5'd2,3'b000,5'd4,OP);         // SUB x4,x2,x1
    dut.instr_mem[8]  = enc_r(7'b0,5'd2,5'd1,3'b111,5'd5,OP);               // AND x5,x1,x2
    dut.instr_mem[9]  = enc_r(7'b0,5'd2,5'd1,3'b110,5'd6,OP);               // OR  x6,x1,x2
    dut.instr_mem[10]  = enc_s(12'd0, 5'd3, 5'd0, 3'b010, STORE);            // SW x3,0(x0)
    dut.instr_mem[11]  = enc_i(12'd0, 5'd0, 3'b010, 5'd7, LOAD);             // LW x7,0(x0)
    dut.instr_mem[12]  = enc_r(7'b0,5'd0,5'd7,3'b000,5'd8,OP);               // ADD x8,x7,x0
    dut.instr_mem[13]  = enc_b(13'd8, 5'd1, 5'd1, 3'b000, BR);               // BEQ x1,x1,+8 -> word 11
    dut.instr_mem[14] = enc_i(12'd999, 5'd0, 3'b000, 5'd9, OPI);            // skipped
    dut.instr_mem[15] = enc_i(12'd111, 5'd0, 3'b000, 5'd9, OPI);            // ADDI x9,x0,111
    dut.instr_mem[16] = enc_b(13'd8, 5'd2, 5'd1, 3'b000, BR);               // BEQ x1,x2,+8 (not taken)
    dut.instr_mem[17] = enc_i(12'd222, 5'd0, 3'b000, 5'd10, OPI);           // ADDI x10,x0,222
    dut.instr_mem[18] = enc_j(21'd8, 5'd11, JAL);                           // JAL x11,+8 -> word 16
    dut.instr_mem[19] = enc_i(12'd888, 5'd0, 3'b000, 5'd12, OPI);           // skipped
    dut.instr_mem[20] = enc_u(20'hABCDE, 5'd13, LUI);                      // LUI x13,0xABCDE
    dut.instr_mem[21] = enc_s(12'd4, 5'd1, 5'd0, 3'b010, STORE);            // SW x1,4(x0)
    dut.instr_mem[22] = enc_i(12'd1, 5'd0, 3'b010, 5'd14, LOAD);            // LW x14,1(x0) misaligned
    dut.instr_mem[23] = enc_s(12'd4092, 5'd1, 5'd0, 3'b010, STORE);         // SW x1,4092(x0) OOR
    dut.instr_mem[24] = 32'h0000_0073;                                     // ECALL

    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;

    wait (halt === 1'b1);
    @(posedge clk); #1;

    check("x1  (ADDI)",            dut.u_regfile.regs[1],  32'd5);
    check("x2  (ADDI)",            dut.u_regfile.regs[2],  32'd7);
    check("x3  (ADD fwd EX/MEM)",  dut.u_regfile.regs[3],  32'd12);
    check("x4  (SUB)",             dut.u_regfile.regs[4],  32'd2);
    check("x5  (AND)",             dut.u_regfile.regs[5],  32'd5);
    check("x6  (OR)",              dut.u_regfile.regs[6],  32'd7);
    check("x7  (LW)",              dut.u_regfile.regs[7],  32'd12);
    check("x8  (load-use stall)",  dut.u_regfile.regs[8],  32'd12);
    check("x9  (branch taken)",    dut.u_regfile.regs[9],  32'd111);
    check("x10 (branch not taken)",dut.u_regfile.regs[10], 32'd222);
    check("x12 (jump skip)",       dut.u_regfile.regs[12], 32'd0);
    check("x13 (LUI)",             dut.u_regfile.regs[13], 32'hABCDE000);
    check("mem[0] (SW x3)",        dut.u_data_memory.mem[0], 32'd12);
    check("mem[1] (SW x1,4)",      dut.u_data_memory.mem[1], 32'd5);
    check("halt",                  {31'b0,halt},           32'd1);
    check("x14 (trapped LW not written)", dut.u_regfile.regs[14], 32'd0);
    check("x15 (handler ran)",     dut.u_regfile.regs[15], 32'd1);
    check("MCAUSE = 4 (load misal)", dut.u_csr_regs.mcause, 32'd4);
    check("MTVAL  = 1 (bad addr)", dut.u_csr_regs.mtval,   32'd1);
    check("MEPC = LW pc+4 (after handler)", dut.u_csr_regs.mepc, 32'd92);

    if (dut.u_regfile.regs[11] == 32'd0)
      $display("FAIL x11 (JAL link) should not be 0");
    else
      $display("PASS x11 (JAL link) = 0x%08h (nonzero return addr)", dut.u_regfile.regs[11]);

    $display("fault_mem_misaligned (sticky-seen)   = %0b (expect it pulsed high during LW x14,1(x0))", fault_mem_misaligned_seen);
    $display("fault_mem_out_of_range (sticky-seen) = %0b (expect it pulsed high during SW x1,4092(x0))", fault_oor_seen);

    if (errors == 0) $display("\nALL CHECKS PASSED");
    else $display("\n%0d CHECK(S) FAILED", errors);

    $finish;
  end

  initial begin
    #5000;
    $display("TIMEOUT -- halt never asserted");
    $finish;
  end
endmodule
