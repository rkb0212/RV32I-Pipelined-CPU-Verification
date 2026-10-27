// =============================================================================
// tb_trap.sv -- directed test for the misalignment TRAP (Option B).
// Six faulting instructions, one per source of misalignment:
//   T1 SW  misaligned, L1                 -> cause 6
//   T2 LW  misaligned, L1                 -> cause 4
//   T3 LW  misaligned, beyond L1 (0x402)  -> cause 4
//   T4 JAL misaligned target              -> cause 0
//   T5 BEQ (taken) misaligned target      -> cause 0
//   T6 LW  misaligned, CSR window         -> cause 4
// After every fault comes a "poison" ADDI x9 that must be squashed (the handler
// returns to MEPC+8, skipping it). The handler logs MCAUSE/MTVAL/MEPC into
// data memory and then does MEPC += 8 ; SW MEPC ; MRET back-to-back (this also
// exercises MRET reading a MEPC written the cycle before).
// =============================================================================
`timescale 1ns/1ps
module tb_trap;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic        halt, f_mt, f_mm, f_oor, trap_taken;
  logic [31:0] pc_out;

  design_top #(.IMEM_DEPTH(128), .DMEM_DEPTH(64)) dut (
    .clk(clk), .rst_n(rst_n), .halt(halt), .pc_out(pc_out),
    .fault_misaligned_target(f_mt), .fault_mem_misaligned(f_mm),
    .fault_mem_out_of_range(f_oor), .trap_taken(trap_taken)
  );

  int trap_pulses = 0;
  always @(posedge clk) if (rst_n && trap_taken) trap_pulses++;

  function automatic [31:0] enc_i(input [11:0] imm, input [4:0] rs1, input [2:0] f3, input [4:0] rd, input [6:0] op);
    enc_i = {imm, rs1, f3, rd, op};
  endfunction
  function automatic [31:0] enc_s(input [11:0] imm, input [4:0] rs2, rs1, input [2:0] f3, input [6:0] op);
    enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
  endfunction
  function automatic [31:0] enc_b(input [12:0] imm, input [4:0] rs2, rs1, input [2:0] f3, input [6:0] op);
    enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], op};
  endfunction
  function automatic [31:0] enc_j(input [20:0] imm, input [4:0] rd, input [6:0] op);
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
  endfunction
  localparam [6:0] OPI=7'b0010011, LOAD=7'b0000011, STORE=7'b0100011, BR=7'b1100011, JAL=7'b1101111;
  localparam [31:0] MRET = 32'h3020_0073, ECALL = 32'h0000_0073;

  int errors = 0;
  task automatic check(input string name, input logic [31:0] act, exp);
    if (act !== exp) begin errors++; $display("FAIL %-34s got=0x%08h exp=0x%08h", name, act, exp); end
    else $display("PASS %-34s = 0x%08h", name, act);
  endtask

  localparam [11:0] POISON = 12'h7AD;

  logic [31:0] exp_cause [0:5];
  logic [31:0] exp_tval  [0:5];
  logic [31:0] exp_epc   [0:5];
  string       nm        [0:5];

  initial begin
    exp_cause[0]=6; exp_cause[1]=4; exp_cause[2]=4; exp_cause[3]=0; exp_cause[4]=0; exp_cause[5]=4;
    exp_tval[0]=10; exp_tval[1]=6; exp_tval[2]=32'h402; exp_tval[3]=78; exp_tval[4]=86; exp_tval[5]=32'hFFFF_FF02;
    exp_epc[0]=32; exp_epc[1]=44; exp_epc[2]=60; exp_epc[3]=72; exp_epc[4]=80; exp_epc[5]=92;
    nm[0]="T1 SW  misal L1"; nm[1]="T2 LW  misal L1"; nm[2]="T3 LW  misal ext";
    nm[3]="T4 JAL misal tgt"; nm[4]="T5 BEQ misal tgt"; nm[5]="T6 LW  misal CSR";
    // ---------------- main program ----------------
    dut.instr_mem[0]  = enc_i(12'hF00, 5'd0,  3'b000, 5'd20, OPI);   // ADDI x20,x0,-256 (CSR_BASE)
    dut.instr_mem[1]  = enc_i(12'h100, 5'd0,  3'b000, 5'd1,  OPI);   // ADDI x1,x0,0x100
    dut.instr_mem[2]  = enc_s(12'd16,  5'd1,  5'd20, 3'b010, STORE); // SW x1,16(x20)  -> MTVEC=0x100
    dut.instr_mem[3]  = enc_i(12'h040, 5'd0,  3'b000, 5'd31, OPI);   // ADDI x31,x0,0x40 (log pointer)
    dut.instr_mem[4]  = enc_i(12'h055, 5'd0,  3'b000, 5'd1,  OPI);   // ADDI x1,x0,0x55
    dut.instr_mem[5]  = enc_s(12'd8,   5'd1,  5'd0,  3'b010, STORE); // SW x1,8(x0)    mem[2]=0x55
    dut.instr_mem[6]  = enc_i(12'h077, 5'd0,  3'b000, 5'd2,  OPI);   // ADDI x2,x0,0x77
    dut.instr_mem[7]  = enc_i(12'h011, 5'd0,  3'b000, 5'd11, OPI);   // ADDI x11,x0,0x11 (older than T1: must commit)
    dut.instr_mem[8]  = enc_s(12'd10,  5'd2,  5'd0,  3'b010, STORE); // T1: SW x2,10(x0)  misaligned store
    dut.instr_mem[9]  = enc_i(POISON,  5'd0,  3'b000, 5'd9,  OPI);   //     poison (squashed)
    dut.instr_mem[10] = enc_i(12'h044, 5'd0,  3'b000, 5'd4,  OPI);   // ADDI x4,x0,0x44
    dut.instr_mem[11] = enc_i(12'd6,   5'd0,  3'b010, 5'd4,  LOAD);  // T2: LW x4,6(x0)   misaligned load
    dut.instr_mem[12] = enc_i(POISON,  5'd0,  3'b000, 5'd9,  OPI);
    dut.instr_mem[13] = enc_i(12'h402, 5'd0,  3'b000, 5'd6,  OPI);   // ADDI x6,x0,0x402
    dut.instr_mem[14] = enc_i(12'h077, 5'd0,  3'b000, 5'd7,  OPI);   // ADDI x7,x0,0x77
    dut.instr_mem[15] = enc_i(12'd0,   5'd6,  3'b010, 5'd7,  LOAD);  // T3: LW x7,0(x6)   misaligned, beyond L1
    dut.instr_mem[16] = enc_i(POISON,  5'd0,  3'b000, 5'd9,  OPI);
    dut.instr_mem[17] = enc_i(12'h088, 5'd0,  3'b000, 5'd8,  OPI);   // ADDI x8,x0,0x88
    dut.instr_mem[18] = enc_j(21'd6,   5'd8,  JAL);                  // T4: JAL x8,+6  misaligned target
    dut.instr_mem[19] = enc_i(POISON,  5'd0,  3'b000, 5'd9,  OPI);
    dut.instr_mem[20] = enc_b(13'd6,   5'd0,  5'd0,  3'b000, BR);    // T5: BEQ x0,x0,+6 (taken, misaligned)
    dut.instr_mem[21] = enc_i(POISON,  5'd0,  3'b000, 5'd9,  OPI);
    dut.instr_mem[22] = enc_i(12'h0AA, 5'd0,  3'b000, 5'd10, OPI);   // ADDI x10,x0,0xAA
    dut.instr_mem[23] = enc_i(12'd2,   5'd20, 3'b010, 5'd10, LOAD);  // T6: LW x10,2(x20) misaligned, CSR window
    dut.instr_mem[24] = enc_i(POISON,  5'd0,  3'b000, 5'd9,  OPI);
    dut.instr_mem[25] = ECALL;

    // ---------------- trap handler @ 0x100 (word 64) ----------------
    dut.instr_mem[64] = enc_i(12'd1,   5'd30, 3'b000, 5'd30, OPI);   // ADDI x30,x30,1  (trap counter)
    dut.instr_mem[65] = enc_i(12'd24,  5'd20, 3'b010, 5'd26, LOAD);  // LW x26,24(x20)  MCAUSE
    dut.instr_mem[66] = enc_i(12'd28,  5'd20, 3'b010, 5'd27, LOAD);  // LW x27,28(x20)  MTVAL
    dut.instr_mem[67] = enc_i(12'd20,  5'd20, 3'b010, 5'd28, LOAD);  // LW x28,20(x20)  MEPC
    dut.instr_mem[68] = enc_s(12'd0,   5'd26, 5'd31, 3'b010, STORE); // log cause @ p
    dut.instr_mem[69] = enc_s(12'd64,  5'd27, 5'd31, 3'b010, STORE); // log tval  @ p+64
    dut.instr_mem[70] = enc_s(12'd128, 5'd28, 5'd31, 3'b010, STORE); // log mepc  @ p+128
    dut.instr_mem[71] = enc_i(12'd4,   5'd31, 3'b000, 5'd31, OPI);   // p += 4
    dut.instr_mem[72] = enc_i(12'd8,   5'd28, 3'b000, 5'd28, OPI);   // MEPC += 8 (skip poison)
    dut.instr_mem[73] = enc_s(12'd20,  5'd28, 5'd20, 3'b010, STORE); // SW MEPC
    dut.instr_mem[74] = MRET;                                        // MRET right after the MEPC store

    rst_n = 0; repeat (3) @(posedge clk); rst_n = 1;
    wait (halt === 1'b1);
    repeat (3) @(posedge clk); #1;

    // Per-trap log: cause / tval / mepc  (data-memory words 16+i / 32+i / 48+i)
    for (int i = 0; i < 6; i++) begin
      check({nm[i], " MCAUSE"}, dut.u_data_memory.mem[16+i], exp_cause[i]);
      check({nm[i], " MTVAL"},  dut.u_data_memory.mem[32+i], exp_tval[i]);
      check({nm[i], " MEPC"},   dut.u_data_memory.mem[48+i], exp_epc[i]);
    end

    check("trap counter x30 == 6",          dut.u_regfile.regs[30], 32'd6);
    check("trap_taken pulses == 6",         trap_pulses,            32'd6);
    check("poison squashed (x9 == 0)",      dut.u_regfile.regs[9],  32'd0);
    check("T1 store blocked (mem[2]=0x55)", dut.u_data_memory.mem[2], 32'h55);
    check("T2 load not written (x4)",       dut.u_regfile.regs[4],  32'h44);
    check("T3 load not written (x7)",       dut.u_regfile.regs[7],  32'h77);
    check("T4 JAL link not written (x8)",   dut.u_regfile.regs[8],  32'h88);
    check("T6 load not written (x10)",      dut.u_regfile.regs[10], 32'hAA);
    check("older instr committed (x11)",    dut.u_regfile.regs[11], 32'h11);
    check("MTVEC",                          dut.u_csr_regs.mtvec,   32'h100);
    check("halt reached via ECALL",         {31'b0, halt},          32'd1);

    if (errors == 0) $display("\nALL TRAP CHECKS PASSED");
    else             $display("\n%0d TRAP CHECK(S) FAILED", errors);
    $finish;
  end

  initial begin #60000; $display("TIMEOUT -- halt never asserted (pc=0x%08h)", pc_out); $finish; end
endmodule
