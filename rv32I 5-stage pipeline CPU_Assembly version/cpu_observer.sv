// =============================================================================
// cpu_observer.sv
// Riviera EDU-compatible replacement for cpu_sva.sv + cpu_coverage.sv.
//
// IMPORTANT:
//   This file intentionally uses only ordinary SystemVerilog procedural logic.
//   It contains NO concurrent assertions, cover properties, or covergroups,
//   because the restricted EDA Playground Riviera license rejects those
//   advanced verification features during elaboration.
//
// What is retained:
//   - Procedural equivalents of the main pipeline checks
//   - Event counters for branch, jump, load-use stall, halt
//   - Instruction coverage counters for the 10 implemented RV32I instructions
//   - EX/MEM and MEM/WB forwarding-path counters
// =============================================================================

module cpu_observer (
  input logic        clk,
  input logic        rst_n,
  input logic        halt,
  input logic [31:0] pc,
  input logic        redirect_taken,
  input logic        branch_taken,
  input logic        jump_taken,
  input logic        stall_load_use,

  input logic [6:0]  id_ex_opcode,
  input logic [2:0]  id_ex_funct3,
  input logic [6:0]  id_ex_funct7,
  input logic [4:0]  id_ex_rs1_addr,
  input logic [4:0]  id_ex_rs2_addr,
  input logic        id_ex_rs2_used,
  input logic        id_ex_reg_write,
  input logic        id_ex_mem_write,
  input logic        id_ex_mem_to_reg,
  input logic        id_ex_is_branch,
  input logic        id_ex_is_jump,
  input logic        id_ex_is_halt,

  input logic        ex_mem_reg_write,
  input logic        ex_mem_mem_to_reg,
  input logic [4:0]  ex_mem_rd_addr,
  input logic        mem_wb_reg_write,
  input logic [4:0]  mem_wb_rd_addr,

  input logic [31:0] x0_value
);

  localparam logic [6:0] OPCODE_OP      = 7'b0110011;
  localparam logic [6:0] OPCODE_OP_IMM  = 7'b0010011;
  localparam logic [6:0] OPCODE_LOAD    = 7'b0000011;
  localparam logic [6:0] OPCODE_STORE   = 7'b0100011;
  localparam logic [6:0] OPCODE_BRANCH  = 7'b1100011;
  localparam logic [6:0] OPCODE_LUI     = 7'b0110111;
  localparam logic [6:0] OPCODE_JAL     = 7'b1101111;
  localparam logic [6:0] OPCODE_SYSTEM  = 7'b1110011;

  localparam logic [2:0] F3_ADD_SUB_ADDI = 3'b000;
  localparam logic [2:0] F3_LW_SW        = 3'b010;
  localparam logic [2:0] F3_OR           = 3'b110;
  localparam logic [2:0] F3_AND          = 3'b111;
  localparam logic [6:0] F7_ADD           = 7'b0000000;
  localparam logic [6:0] F7_SUB           = 7'b0100000;

  // ---------------------------------------------------------------------------
  // Forwarding detection. These conditions mirror the DUT/old coverage module.
  // ---------------------------------------------------------------------------
  logic fwd_ex_mem_rs1;
  logic fwd_ex_mem_rs2;
  logic fwd_mem_wb_rs1;
  logic fwd_mem_wb_rs2;

  assign fwd_ex_mem_rs1 = ex_mem_reg_write && !ex_mem_mem_to_reg &&
                          (ex_mem_rd_addr != 5'd0) &&
                          (ex_mem_rd_addr == id_ex_rs1_addr);

  assign fwd_ex_mem_rs2 = ex_mem_reg_write && !ex_mem_mem_to_reg &&
                          id_ex_rs2_used &&
                          (ex_mem_rd_addr != 5'd0) &&
                          (ex_mem_rd_addr == id_ex_rs2_addr);

  assign fwd_mem_wb_rs1 = mem_wb_reg_write && !fwd_ex_mem_rs1 &&
                          (mem_wb_rd_addr != 5'd0) &&
                          (mem_wb_rd_addr == id_ex_rs1_addr);

  assign fwd_mem_wb_rs2 = mem_wb_reg_write && id_ex_rs2_used &&
                          !fwd_ex_mem_rs2 &&
                          (mem_wb_rd_addr != 5'd0) &&
                          (mem_wb_rd_addr == id_ex_rs2_addr);

  // ---------------------------------------------------------------------------
  // Procedural check state.
  // ---------------------------------------------------------------------------
  logic        prev_valid;
  logic        prev_halt;
  logic [31:0] prev_pc;
  logic        prev_redirect;
  logic        prev_stall;
  logic [7:0]  stall_window;

  integer check_halt_sticky_fail;
  integer check_pc_freeze_fail;
  integer check_pc_aligned_fail;
  integer check_redirect_flush_fail;
  integer check_load_use_pc_hold_fail;
  integer check_load_use_bubble_fail;
  integer check_x0_zero_fail;

  integer branch_taken_count;
  integer jump_taken_count;
  integer load_use_stall_count;
  integer halt_count;
  integer stall_then_branch_count;

  integer fwd_ex_mem_rs1_count;
  integer fwd_ex_mem_rs2_count;
  integer fwd_mem_wb_rs1_count;
  integer fwd_mem_wb_rs2_count;

  integer add_count;
  integer sub_count;
  integer and_count;
  integer or_count;
  integer addi_count;
  integer lw_count;
  integer sw_count;
  integer beq_count;
  integer lui_count;
  integer jal_count;
  integer ecall_count;

  // Bits 0..9 represent the 10 implemented RV32I instructions.
  logic [9:0] instr_seen;

  initial begin
    prev_valid                    = 1'b0;
    prev_halt                     = 1'b0;
    prev_pc                       = 32'b0;
    prev_redirect                 = 1'b0;
    prev_stall                    = 1'b0;
    stall_window                  = 8'b0;

    check_halt_sticky_fail        = 0;
    check_pc_freeze_fail          = 0;
    check_pc_aligned_fail         = 0;
    check_redirect_flush_fail     = 0;
    check_load_use_pc_hold_fail   = 0;
    check_load_use_bubble_fail    = 0;
    check_x0_zero_fail            = 0;

    branch_taken_count            = 0;
    jump_taken_count              = 0;
    load_use_stall_count          = 0;
    halt_count                    = 0;
    stall_then_branch_count       = 0;

    fwd_ex_mem_rs1_count          = 0;
    fwd_ex_mem_rs2_count          = 0;
    fwd_mem_wb_rs1_count          = 0;
    fwd_mem_wb_rs2_count          = 0;

    add_count                     = 0;
    sub_count                     = 0;
    and_count                     = 0;
    or_count                      = 0;
    addi_count                    = 0;
    lw_count                      = 0;
    sw_count                      = 0;
    beq_count                     = 0;
    lui_count                     = 0;
    jal_count                     = 0;
    ecall_count                   = 0;
    instr_seen                    = 10'b0;
  end

  // ---------------------------------------------------------------------------
  // Ordinary procedural checks. `prev_*` implements the one-cycle implication
  // used by the original SVA properties.
  // ---------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_valid    <= 1'b0;
      prev_halt     <= 1'b0;
      prev_pc       <= 32'b0;
      prev_redirect <= 1'b0;
      prev_stall    <= 1'b0;
      stall_window  <= 8'b0;
    end else begin
      if (pc[1:0] !== 2'b00) begin
        check_pc_aligned_fail = check_pc_aligned_fail + 1;
        $error("[CHECK_PC_WORD_ALIGNED] PC is not word aligned: 0x%08h", pc);
      end

      if (x0_value !== 32'b0) begin
        check_x0_zero_fail = check_x0_zero_fail + 1;
        $error("[CHECK_X0_ZERO] x0 changed: 0x%08h", x0_value);
      end

      if (prev_valid) begin
        if (prev_halt && !halt) begin
          check_halt_sticky_fail = check_halt_sticky_fail + 1;
          $error("[CHECK_HALT_STICKY] halt deasserted without reset");
        end

        if (prev_halt && (pc !== prev_pc)) begin
          check_pc_freeze_fail = check_pc_freeze_fail + 1;
          $error("[CHECK_PC_FREEZE] PC changed after halt: old=0x%08h new=0x%08h",
                 prev_pc, pc);
        end

        if (prev_redirect &&
            ((id_ex_reg_write !== 1'b0) ||
             (id_ex_mem_write !== 1'b0) ||
             (id_ex_is_branch !== 1'b0) ||
             (id_ex_is_jump   !== 1'b0))) begin
          check_redirect_flush_fail = check_redirect_flush_fail + 1;
          $error("[CHECK_REDIRECT_FLUSH] ID/EX was not bubbled after redirect");
        end

        if (prev_stall && !prev_redirect) begin
          if (pc !== prev_pc) begin
            check_load_use_pc_hold_fail = check_load_use_pc_hold_fail + 1;
            $error("[CHECK_LOAD_USE_PC_HOLD] PC advanced during load-use stall");
          end

          if ((id_ex_reg_write !== 1'b0) || (id_ex_mem_write !== 1'b0)) begin
            check_load_use_bubble_fail = check_load_use_bubble_fail + 1;
            $error("[CHECK_LOAD_USE_BUBBLE] ID/EX was not bubbled after stall");
          end
        end
      end

      if (branch_taken) begin
        branch_taken_count = branch_taken_count + 1;
        if (|stall_window)
          stall_then_branch_count = stall_then_branch_count + 1;
      end
      if (jump_taken)       jump_taken_count     = jump_taken_count + 1;
      if (stall_load_use)   load_use_stall_count = load_use_stall_count + 1;
      if (halt && !prev_halt) halt_count         = halt_count + 1;

      if (fwd_ex_mem_rs1) fwd_ex_mem_rs1_count = fwd_ex_mem_rs1_count + 1;
      if (fwd_ex_mem_rs2) fwd_ex_mem_rs2_count = fwd_ex_mem_rs2_count + 1;
      if (fwd_mem_wb_rs1) fwd_mem_wb_rs1_count = fwd_mem_wb_rs1_count + 1;
      if (fwd_mem_wb_rs2) fwd_mem_wb_rs2_count = fwd_mem_wb_rs2_count + 1;

      // Instruction-kind counters and hit mask.
      case (id_ex_opcode)
        OPCODE_OP: begin
          if ((id_ex_funct3 == F3_ADD_SUB_ADDI) && (id_ex_funct7 == F7_ADD)) begin
            add_count = add_count + 1;
            instr_seen[0] <= 1'b1;
          end else if ((id_ex_funct3 == F3_ADD_SUB_ADDI) && (id_ex_funct7 == F7_SUB)) begin
            sub_count = sub_count + 1;
            instr_seen[1] <= 1'b1;
          end else if ((id_ex_funct3 == F3_AND) && (id_ex_funct7 == F7_ADD)) begin
            and_count = and_count + 1;
            instr_seen[2] <= 1'b1;
          end else if ((id_ex_funct3 == F3_OR) && (id_ex_funct7 == F7_ADD)) begin
            or_count = or_count + 1;
            instr_seen[3] <= 1'b1;
          end
        end

        OPCODE_OP_IMM: begin
          if (id_ex_funct3 == F3_ADD_SUB_ADDI) begin
            addi_count = addi_count + 1;
            instr_seen[4] <= 1'b1;
          end
        end

        OPCODE_LOAD: begin
          if (id_ex_funct3 == F3_LW_SW) begin
            lw_count = lw_count + 1;
            instr_seen[5] <= 1'b1;
          end
        end

        OPCODE_STORE: begin
          if (id_ex_funct3 == F3_LW_SW) begin
            sw_count = sw_count + 1;
            instr_seen[6] <= 1'b1;
          end
        end

        OPCODE_BRANCH: begin
          if (id_ex_funct3 == F3_ADD_SUB_ADDI) begin
            beq_count = beq_count + 1;
            instr_seen[7] <= 1'b1;
          end
        end

        OPCODE_LUI: begin
          lui_count = lui_count + 1;
          instr_seen[8] <= 1'b1;
        end

        OPCODE_JAL: begin
          jal_count = jal_count + 1;
          instr_seen[9] <= 1'b1;
        end

        OPCODE_SYSTEM: begin
          if (id_ex_is_halt)
            ecall_count = ecall_count + 1;
        end

        default: begin
        end
      endcase

      stall_window  <= {stall_window[6:0], stall_load_use};
      prev_valid    <= 1'b1;
      prev_halt     <= halt;
      prev_pc       <= pc;
      prev_redirect <= redirect_taken;
      prev_stall    <= stall_load_use;
    end
  end

  function integer count_seen(input logic [9:0] value);
    integer i;
    begin
      count_seen = 0;
      for (i = 0; i < 10; i = i + 1)
        if (value[i]) count_seen = count_seen + 1;
    end
  endfunction

  final begin
    integer total_failures;
    integer supported_seen_count;

    total_failures = check_halt_sticky_fail +
                     check_pc_freeze_fail +
                     check_pc_aligned_fail +
                     check_redirect_flush_fail +
                     check_load_use_pc_hold_fail +
                     check_load_use_bubble_fail +
                     check_x0_zero_fail;

    supported_seen_count = count_seen(instr_seen);

    $display("============================================================");
    $display("RIVIERA EDU-COMPATIBLE CPU CHECK SUMMARY");
    $display("CHECK_HALT_STICKY       failures = %0d", check_halt_sticky_fail);
    $display("CHECK_PC_FREEZE         failures = %0d", check_pc_freeze_fail);
    $display("CHECK_PC_WORD_ALIGNED   failures = %0d", check_pc_aligned_fail);
    $display("CHECK_REDIRECT_FLUSH    failures = %0d", check_redirect_flush_fail);
    $display("CHECK_LOAD_USE_PC_HOLD  failures = %0d", check_load_use_pc_hold_fail);
    $display("CHECK_LOAD_USE_BUBBLE   failures = %0d", check_load_use_bubble_fail);
    $display("CHECK_X0_ZERO           failures = %0d", check_x0_zero_fail);
    $display("TOTAL PROCEDURAL CHECK FAILURES = %0d", total_failures);
    if (total_failures == 0)
      $display("PROCEDURAL CHECK RESULT: PASS");
    else
      $display("PROCEDURAL CHECK RESULT: FAIL");

    $display("------------------------------------------------------------");
    $display("PIPELINE EVENT COUNTS");
    $display("BEQ taken              = %0d", branch_taken_count);
    $display("JAL redirect           = %0d", jump_taken_count);
    $display("Load-use stalls        = %0d", load_use_stall_count);
    $display("Halt events            = %0d", halt_count);
    $display("Stall then branch      = %0d", stall_then_branch_count);

    $display("------------------------------------------------------------");
    $display("FORWARDING PATH COUNTS");
    $display("EX/MEM -> rs1          = %0d", fwd_ex_mem_rs1_count);
    $display("EX/MEM -> rs2          = %0d", fwd_ex_mem_rs2_count);
    $display("MEM/WB -> rs1          = %0d", fwd_mem_wb_rs1_count);
    $display("MEM/WB -> rs2          = %0d", fwd_mem_wb_rs2_count);

    $display("------------------------------------------------------------");
    $display("DIRECTED INSTRUCTION COUNTS");
    $display("ADD=%0d SUB=%0d AND=%0d OR=%0d ADDI=%0d",
             add_count, sub_count, and_count, or_count, addi_count);
    $display("LW=%0d SW=%0d BEQ=%0d LUI=%0d JAL=%0d ECALL=%0d",
             lw_count, sw_count, beq_count, lui_count, jal_count, ecall_count);
    $display("Implemented RV32I instructions observed = %0d/10", supported_seen_count);
    if (supported_seen_count == 10)
      $display("INSTRUCTION COVERAGE RESULT: 10/10 PASS");
    else
      $display("INSTRUCTION COVERAGE RESULT: %0d/10", supported_seen_count);
    $display("============================================================");
  end

endmodule

bind simple_cpu_pipelined cpu_observer u_cpu_observer (
  .clk               (clk),
  .rst_n             (rst_n),
  .halt              (halt),
  .pc                (pc),
  .redirect_taken    (redirect_taken),
  .branch_taken      (branch_taken),
  .jump_taken        (jump_taken),
  .stall_load_use    (stall_load_use),

  .id_ex_opcode      (id_ex_opcode),
  .id_ex_funct3      (id_ex_funct3),
  .id_ex_funct7      (id_ex_funct7),
  .id_ex_rs1_addr    (id_ex_rs1_addr),
  .id_ex_rs2_addr    (id_ex_rs2_addr),
  .id_ex_rs2_used    (id_ex_rs2_used),
  .id_ex_reg_write   (id_ex_reg_write),
  .id_ex_mem_write   (id_ex_mem_write),
  .id_ex_mem_to_reg  (id_ex_mem_to_reg),
  .id_ex_is_branch   (id_ex_is_branch),
  .id_ex_is_jump     (id_ex_is_jump),
  .id_ex_is_halt     (id_ex_is_halt),

  .ex_mem_reg_write  (ex_mem_reg_write),
  .ex_mem_mem_to_reg (ex_mem_mem_to_reg),
  .ex_mem_rd_addr    (ex_mem_rd_addr),
  .mem_wb_reg_write  (mem_wb_reg_write),
  .mem_wb_rd_addr    (mem_wb_rd_addr),

  .x0_value          (regfile[0])
);
