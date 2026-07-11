// =============================================================================
// cpu_sva.sv
// SVA checker bound to simple_cpu_pipelined RV32I-subset DUT.
//
// Adds console-visible assertion summary at end of simulation.
// =============================================================================

module cpu_sva_checker (
  input logic        clk,
  input logic        rst_n,
  input logic        halt,
  input logic [31:0] pc,
  input logic        redirect_taken,
  input logic        branch_taken,
  input logic        jump_taken,
  input logic        stall_load_use,
  input logic        id_ex_is_branch,
  input logic        id_ex_is_jump,
  input logic        id_ex_reg_write,
  input logic        id_ex_mem_write,
  input logic [31:0] x0_value
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  int unsigned ast_halt_sticky_fail;
  int unsigned ast_pc_freeze_fail;
  int unsigned ast_pc_word_aligned_fail;
  int unsigned ast_redirect_flush_fail;
  int unsigned ast_load_use_pc_hold_fail;
  int unsigned ast_load_use_bubble_fail;
  int unsigned ast_x0_zero_fail;

  int unsigned cov_branch_taken_count;
  int unsigned cov_jump_taken_count;
  int unsigned cov_load_use_stall_count;
  int unsigned cov_halt_reached_count;
  int unsigned cov_stall_then_branch_count;

  AST_HALT_STICKY:
    assert property (halt |=> halt)
    else begin
      ast_halt_sticky_fail++;
      $error("[AST_HALT_STICKY] halt deasserted without reset");
    end

  AST_PC_FREEZE:
    assert property (halt |=> (pc == $past(pc)))
    else begin
      ast_pc_freeze_fail++;
      $error("[AST_PC_FREEZE] PC changed after halt");
    end

  AST_PC_WORD_ALIGNED:
    assert property (pc[1:0] == 2'b00)
    else begin
      ast_pc_word_aligned_fail++;
      $error("[AST_PC_WORD_ALIGNED] PC is not word aligned");
    end

  AST_REDIRECT_FLUSH:
    assert property (
      redirect_taken |=>
        (id_ex_reg_write == 1'b0 &&
         id_ex_mem_write == 1'b0 &&
         id_ex_is_branch == 1'b0 &&
         id_ex_is_jump   == 1'b0)
    )
    else begin
      ast_redirect_flush_fail++;
      $error("[AST_REDIRECT_FLUSH] ID/EX not bubbled after BEQ/JAL redirect");
    end

  AST_LOAD_USE_PC_HOLD:
    assert property (
      (stall_load_use && !redirect_taken) |=> (pc == $past(pc))
    )
    else begin
      ast_load_use_pc_hold_fail++;
      $error("[AST_LOAD_USE_PC_HOLD] PC advanced during load-use stall");
    end

  AST_LOAD_USE_BUBBLE:
    assert property (
      (stall_load_use && !redirect_taken) |=>
        (id_ex_reg_write == 1'b0 && id_ex_mem_write == 1'b0)
    )
    else begin
      ast_load_use_bubble_fail++;
      $error("[AST_LOAD_USE_BUBBLE] ID/EX not bubbled after load-use stall");
    end

  AST_X0_ZERO:
    assert property (x0_value == 32'b0)
    else begin
      ast_x0_zero_fail++;
      $error("[AST_X0_ZERO] RISC-V x0 changed from zero");
    end

  COV_BRANCH_TAKEN:      cover property (branch_taken);
  COV_JUMP_TAKEN:        cover property (jump_taken);
  COV_LOAD_USE_STALL:    cover property (stall_load_use);
  COV_HALT_REACHED:      cover property (halt);
  COV_STALL_THEN_BRANCH: cover property (stall_load_use ##[1:8] branch_taken);

  // Procedural cover counters so the console always shows whether events occurred,
  // even if the simulator's ACDB assertion report is not printed.
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (branch_taken)   cov_branch_taken_count++;
      if (jump_taken)     cov_jump_taken_count++;
      if (stall_load_use) cov_load_use_stall_count++;
      if (halt)           cov_halt_reached_count++;
    end
  end

  logic [7:0] stall_window;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stall_window <= 8'b0;
    end else begin
      if (branch_taken && (|stall_window))
        cov_stall_then_branch_count++;
      stall_window <= {stall_window[6:0], stall_load_use};
    end
  end

  final begin
    int unsigned total_failures;
    total_failures = ast_halt_sticky_fail + ast_pc_freeze_fail +
                     ast_pc_word_aligned_fail + ast_redirect_flush_fail +
                     ast_load_use_pc_hold_fail + ast_load_use_bubble_fail +
                     ast_x0_zero_fail;

    $display("============================================================");
    $display("RV32I SVA ASSERTION SUMMARY");
    $display("AST_HALT_STICKY        failures = %0d", ast_halt_sticky_fail);
    $display("AST_PC_FREEZE          failures = %0d", ast_pc_freeze_fail);
    $display("AST_PC_WORD_ALIGNED    failures = %0d", ast_pc_word_aligned_fail);
    $display("AST_REDIRECT_FLUSH     failures = %0d", ast_redirect_flush_fail);
    $display("AST_LOAD_USE_PC_HOLD   failures = %0d", ast_load_use_pc_hold_fail);
    $display("AST_LOAD_USE_BUBBLE    failures = %0d", ast_load_use_bubble_fail);
    $display("AST_X0_ZERO            failures = %0d", ast_x0_zero_fail);
    $display("TOTAL ASSERTION FAILURES = %0d", total_failures);
    if (total_failures == 0)
      $display("ASSERTION RESULT: PASS");
    else
      $display("ASSERTION RESULT: FAIL");

    $display("RV32I SVA COVER EVENT COUNTS");
    $display("COV_BRANCH_TAKEN      count = %0d", cov_branch_taken_count);
    $display("COV_JUMP_TAKEN        count = %0d", cov_jump_taken_count);
    $display("COV_LOAD_USE_STALL    count = %0d", cov_load_use_stall_count);
    $display("COV_HALT_REACHED      count = %0d", cov_halt_reached_count);
    $display("COV_STALL_THEN_BRANCH count = %0d", cov_stall_then_branch_count);
    $display("============================================================");
  end

endmodule

bind simple_cpu_pipelined cpu_sva_checker u_sva_checker (
  .clk             (clk),
  .rst_n           (rst_n),
  .halt            (halt),
  .pc              (pc),
  .redirect_taken  (redirect_taken),
  .branch_taken    (branch_taken),
  .jump_taken      (jump_taken),
  .stall_load_use  (stall_load_use),
  .id_ex_is_branch (id_ex_is_branch),
  .id_ex_is_jump   (id_ex_is_jump),
  .id_ex_reg_write (id_ex_reg_write),
  .id_ex_mem_write (id_ex_mem_write),
  .x0_value        (regfile[0])
);
