`timescale 1ns/1ns
// Directed check of the live L1 -> L2 -> L3 -> AXI-Lite -> iMC path and the
// mem_stall pipeline freeze.
module tb_hier;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic halt; logic [31:0] pc_out;
  logic f_mt, f_mm, f_oor;

  design_top #(.IMEM_DEPTH(64), .DMEM_DEPTH(64)) dut (
    .clk(clk), .rst_n(rst_n), .halt(halt), .pc_out(pc_out),
    .fault_misaligned_target(f_mt), .fault_mem_misaligned(f_mm), .fault_mem_out_of_range(f_oor), .trap_taken());

  function automatic [31:0] enc_r(input [6:0] f7, input [4:0] rs2, rs1, input [2:0] f3, input [4:0] rd, input [6:0] op);
    enc_r = {f7, rs2, rs1, f3, rd, op}; endfunction
  function automatic [31:0] enc_i(input [11:0] imm, input [4:0] rs1, input [2:0] f3, input [4:0] rd, input [6:0] op);
    enc_i = {imm, rs1, f3, rd, op}; endfunction
  function automatic [31:0] enc_s(input [11:0] imm, input [4:0] rs2, rs1, input [2:0] f3, input [6:0] op);
    enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op}; endfunction
  localparam [6:0] OP=7'b0110011, OPI=7'b0010011, LOAD=7'b0000011, STORE=7'b0100011;

  int errors = 0;
  task automatic check(input string n, input logic [31:0] a, e);
    if (a !== e) begin errors++; $display("FAIL %-34s got=0x%08h exp=0x%08h", n, a, e); end
    else $display("PASS %-34s = 0x%08h", n, a);
  endtask

  int stall_x3 = 0, stall_x4 = 0, stall_l1 = 0, stall_total = 0;
  logic oor_seen = 0;
  always @(posedge clk) if (rst_n) begin
    if (dut.mem_stall) begin
      stall_total++;
      if (dut.ex_mem_mem_to_reg && dut.ex_mem_rd_addr == 5'd3) stall_x3++;
      if (dut.ex_mem_mem_to_reg && dut.ex_mem_rd_addr == 5'd4) stall_x4++;
      if (dut.is_l1) stall_l1++;
    end
    if (f_oor) oor_seen <= 1;
  end

  initial begin
    int k;
    k = 0;
    dut.instr_mem[k++] = enc_i(12'd1445, 5'd0, 3'b000, 5'd1, OPI);   // x1 = 1445
    dut.instr_mem[k++] = enc_i(12'd1024, 5'd0, 3'b000, 5'd2, OPI);   // x2 = 1024 (beyond L1 -> L2 region)
    dut.instr_mem[k++] = enc_s(12'd0,   5'd1, 5'd2, 3'b010, STORE);  // SW  x1,0(x2)   -> iMC[256]
    dut.instr_mem[k++] = enc_i(12'd0,   5'd2, 3'b010, 5'd3, LOAD);   // LW  x3,0(x2)   -> miss everywhere
    dut.instr_mem[k++] = enc_r(7'b0, 5'd3, 5'd3, 3'b000, 5'd5, OP);  // ADD x5,x3,x3   (load-use + stall)
    dut.instr_mem[k++] = enc_i(12'd0,   5'd2, 3'b010, 5'd4, LOAD);   // LW  x4,0(x2)   -> L2 hit, no stall
    dut.instr_mem[k++] = enc_i(12'd7,   5'd0, 3'b000, 5'd6, OPI);    // x6 = 7
    dut.instr_mem[k++] = enc_s(12'd4,   5'd6, 5'd2, 3'b010, STORE);  // SW  x6,4(x2)   -> iMC[257]
    dut.instr_mem[k++] = enc_i(12'd4,   5'd2, 3'b010, 5'd7, LOAD);   // LW  x7,4(x2)
    dut.instr_mem[k++] = enc_s(12'd8,   5'd1, 5'd0, 3'b010, STORE);  // SW  x1,8(x0)   -> L1
    dut.instr_mem[k++] = enc_i(12'd8,   5'd0, 3'b010, 5'd9, LOAD);   // LW  x9,8(x0)   -> L1
    dut.instr_mem[k++] = enc_i(12'd2047,5'd0, 3'b000, 5'd11, OPI);   // x11 = 2047
    dut.instr_mem[k++] = enc_r(7'b0, 5'd11, 5'd11, 3'b000, 5'd11, OP); // 4094
    dut.instr_mem[k++] = enc_r(7'b0, 5'd11, 5'd11, 3'b000, 5'd11, OP); // 8188
    dut.instr_mem[k++] = enc_r(7'b0, 5'd11, 5'd11, 3'b000, 5'd11, OP); // 16376
    dut.instr_mem[k++] = enc_r(7'b0, 5'd11, 5'd11, 3'b000, 5'd11, OP); // 32752 (hole in map)
    dut.instr_mem[k++] = enc_s(12'd0,   5'd1, 5'd11, 3'b010, STORE); // SW -> out of range, must not hang
    dut.instr_mem[k++] = enc_i(12'd99,  5'd0, 3'b000, 5'd12, OPI);   // x12 = 99 (proves no hang)
    dut.instr_mem[k++] = 32'h0000_0073;                              // ECALL

    repeat (3) @(posedge clk); rst_n = 1;
    fork
      wait (halt === 1'b1);
      begin repeat (600) @(posedge clk); $display("TIMEOUT"); errors++; end
    join_any
    disable fork;
    @(posedge clk); #1;

    check("x3  LW via L2/L3/iMC",        dut.u_regfile.regs[3], 32'd1445);
    check("x5  load-use after stalled LW", dut.u_regfile.regs[5], 32'd2890);
    check("x4  LW L2 hit",               dut.u_regfile.regs[4], 32'd1445);
    check("x7  second ext word",         dut.u_regfile.regs[7], 32'd7);
    check("x9  L1 path still works",     dut.u_regfile.regs[9], 32'd1445);
    check("x12 ran after OOR (no hang)", dut.u_regfile.regs[12], 32'd99);
    check("iMC mem[256] (write-through)", dut.u_imc.mem[256], 32'd1445);
    check("iMC mem[257] (write-through)", dut.u_imc.mem[257], 32'd7);
    check("OOR fault seen for map hole", {31'b0, oor_seen}, 32'd1);
    check("no stall on L2 hit (x4)",     stall_x4, 0);
    check("no stall on L1 accesses",     stall_l1, 0);
    if (stall_x3 > 0) $display("PASS stalled %0d cycles on the L3-miss load (x3)", stall_x3);
    else begin errors++; $display("FAIL x3 load never stalled"); end
    $display("total mem_stall cycles = %0d", stall_total);
    if (errors == 0) $display("\nALL HIERARCHY CHECKS PASSED"); else $display("\n%0d CHECK(S) FAILED", errors);
    $finish;
  end
endmodule
