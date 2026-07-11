// =============================================================================
// cpu_coverage.sv
// Functional coverage module bound to simple_cpu_pipelined RV32I-subset DUT.
//
// Covergroups:
//   cg_pipeline_events - stall / branch / jump / forwarding / halt
//   cg_rv32i_opcodes   - RV32I subset opcode coverage
//   cg_rv32i_instrs    - decoded instruction-kind coverage
//   cg_forward_paths   - individual forwarding path coverage
// =============================================================================

module cpu_pipeline_cov (
  input logic        clk,
  input logic        rst_n,
  input logic        halt,
  input logic        branch_taken,
  input logic        jump_taken,
  input logic        stall_load_use,

  // EX stage decode/control
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

  // Forwarding sources
  input logic        ex_mem_reg_write,
  input logic        ex_mem_mem_to_reg,
  input logic [4:0]  ex_mem_rd_addr,
  input logic        mem_wb_reg_write,
  input logic [4:0]  mem_wb_rd_addr
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
  localparam logic [2:0] F3_AND          = 3'b111;
  localparam logic [2:0] F3_OR           = 3'b110;
  localparam logic [2:0] F3_LW_SW        = 3'b010;
  localparam logic [2:0] F3_BEQ          = 3'b000;

  localparam logic [6:0] F7_ADD = 7'b0000000;
  localparam logic [6:0] F7_SUB = 7'b0100000;

  // ---------------------------------------------------------------------------
  // Forwarding detection mirrors the RTL forwarding conditions.
  // EX/MEM load values are not forwardable because load data is not ready there.
  // ---------------------------------------------------------------------------
  logic fwd_ex_mem_rs1, fwd_ex_mem_rs2;
  logic fwd_mem_wb_rs1, fwd_mem_wb_rs2;
  logic any_forward;

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

  assign fwd_mem_wb_rs2 = mem_wb_reg_write && id_ex_rs2_used && !fwd_ex_mem_rs2 &&
                          (mem_wb_rd_addr != 5'd0) &&
                          (mem_wb_rd_addr == id_ex_rs2_addr);

  assign any_forward = fwd_ex_mem_rs1 | fwd_ex_mem_rs2 |
                       fwd_mem_wb_rs1 | fwd_mem_wb_rs2;

  // Instruction kind encoding for easier coverage reports.
  logic [3:0] instr_kind;

  always_comb begin
    instr_kind = 4'd0; // other/NOP

    unique case (id_ex_opcode)
      OPCODE_OP: begin
        if (id_ex_funct3 == F3_ADD_SUB_ADDI && id_ex_funct7 == F7_ADD)
          instr_kind = 4'd1; // ADD
        else if (id_ex_funct3 == F3_ADD_SUB_ADDI && id_ex_funct7 == F7_SUB)
          instr_kind = 4'd2; // SUB
        else if (id_ex_funct3 == F3_AND && id_ex_funct7 == F7_ADD)
          instr_kind = 4'd3; // AND
        else if (id_ex_funct3 == F3_OR && id_ex_funct7 == F7_ADD)
          instr_kind = 4'd4; // OR
      end
      OPCODE_OP_IMM: if (id_ex_funct3 == F3_ADD_SUB_ADDI) instr_kind = 4'd5; // ADDI
      OPCODE_LOAD:   if (id_ex_funct3 == F3_LW_SW)        instr_kind = 4'd6; // LW
      OPCODE_STORE:  if (id_ex_funct3 == F3_LW_SW)        instr_kind = 4'd7; // SW
      OPCODE_BRANCH: if (id_ex_funct3 == F3_BEQ)          instr_kind = 4'd8; // BEQ
      OPCODE_LUI:                                           instr_kind = 4'd9; // LUI
      OPCODE_JAL:                                           instr_kind = 4'd10; // JAL
      OPCODE_SYSTEM: if (id_ex_is_halt)                    instr_kind = 4'd11; // ECALL
      default:                                              instr_kind = 4'd0;
    endcase
  end

  covergroup cg_pipeline_events @(posedge clk iff rst_n);
    option.per_instance = 1;

    cp_stall: coverpoint stall_load_use {
      bins stall    = {1};
      bins no_stall = {0};
    }

    cp_branch: coverpoint branch_taken {
      bins taken     = {1};
      bins not_taken = {0};
    }

    cp_jump: coverpoint jump_taken {
      bins jump    = {1};
      bins no_jump = {0};
    }

    cp_forward: coverpoint any_forward {
      bins forwarded  = {1};
      bins no_forward = {0};
    }

    cp_halt: coverpoint halt {
      bins halted = {1};
    }

    cx_branch_fwd: cross cp_branch, cp_forward;
    cx_jump_fwd:   cross cp_jump,   cp_forward;
    cx_stall_fwd:  cross cp_stall,  cp_forward;
  endgroup

  covergroup cg_rv32i_opcodes @(posedge clk iff rst_n);
    option.per_instance = 1;

    cp_opcode: coverpoint id_ex_opcode {
      bins op_rtype  = {OPCODE_OP};
      bins op_imm    = {OPCODE_OP_IMM};
      bins op_load   = {OPCODE_LOAD};
      bins op_store  = {OPCODE_STORE};
      bins op_branch = {OPCODE_BRANCH};
      bins op_lui    = {OPCODE_LUI};
      bins op_jal    = {OPCODE_JAL};
      bins op_system = {OPCODE_SYSTEM};
      bins other     = default;
    }
  endgroup

  covergroup cg_rv32i_instrs @(posedge clk iff rst_n);
    option.per_instance = 1;

    cp_instr_kind: coverpoint instr_kind {
      bins add   = {4'd1};
      bins sub   = {4'd2};
      bins and_i = {4'd3};
      bins or_i  = {4'd4};
      bins addi  = {4'd5};
      bins lw    = {4'd6};
      bins sw    = {4'd7};
      bins beq   = {4'd8};
      bins lui   = {4'd9};
      bins jal   = {4'd10};
      bins ecall = {4'd11};
    }
  endgroup

  covergroup cg_forward_paths @(posedge clk iff rst_n);
    option.per_instance = 1;

    cp_ex_mem_rs1: coverpoint fwd_ex_mem_rs1 { bins active = {1}; }
    cp_ex_mem_rs2: coverpoint fwd_ex_mem_rs2 { bins active = {1}; }
    cp_mem_wb_rs1: coverpoint fwd_mem_wb_rs1 { bins active = {1}; }
    cp_mem_wb_rs2: coverpoint fwd_mem_wb_rs2 { bins active = {1}; }
  endgroup

  cg_pipeline_events cg_pipe_inst;
  cg_rv32i_opcodes   cg_opcode_inst;
  cg_rv32i_instrs    cg_instr_inst;
  cg_forward_paths   cg_fwd_inst;

  initial begin
    cg_pipe_inst   = new();
    cg_opcode_inst = new();
    cg_instr_inst  = new();
    cg_fwd_inst    = new();
  end


  final begin
    real pipe_cov;
    real opcode_cov;
    real instr_cov;
    real fwd_cov;
    real avg_cov;

    pipe_cov   = cg_pipe_inst.get_inst_coverage();
    opcode_cov = cg_opcode_inst.get_inst_coverage();
    instr_cov  = cg_instr_inst.get_inst_coverage();
    fwd_cov    = cg_fwd_inst.get_inst_coverage();
    avg_cov    = (pipe_cov + opcode_cov + instr_cov + fwd_cov) / 4.0;

    $display("============================================================");
    $display("RV32I FUNCTIONAL COVERAGE SUMMARY");
    $display("cg_pipeline_events  = %0.2f%%", pipe_cov);
    $display("cg_rv32i_opcodes    = %0.2f%%", opcode_cov);
    $display("cg_rv32i_instrs     = %0.2f%%", instr_cov);
    $display("cg_forward_paths    = %0.2f%%", fwd_cov);
    $display("Average shown score = %0.2f%%", avg_cov);
    $display("Note: the official ACDB report may weight coverage differently.");
    $display("============================================================");
  end

endmodule

bind simple_cpu_pipelined cpu_pipeline_cov u_cov (
  .clk              (clk),
  .rst_n            (rst_n),
  .halt             (halt),
  .branch_taken     (branch_taken),
  .jump_taken       (jump_taken),
  .stall_load_use   (stall_load_use),
  .id_ex_opcode     (id_ex_opcode),
  .id_ex_funct3     (id_ex_funct3),
  .id_ex_funct7     (id_ex_funct7),
  .id_ex_rs1_addr   (id_ex_rs1_addr),
  .id_ex_rs2_addr   (id_ex_rs2_addr),
  .id_ex_rs2_used   (id_ex_rs2_used),
  .id_ex_reg_write  (id_ex_reg_write),
  .id_ex_mem_write  (id_ex_mem_write),
  .id_ex_mem_to_reg (id_ex_mem_to_reg),
  .id_ex_is_branch  (id_ex_is_branch),
  .id_ex_is_jump    (id_ex_is_jump),
  .id_ex_is_halt    (id_ex_is_halt),
  .ex_mem_reg_write (ex_mem_reg_write),
  .ex_mem_mem_to_reg(ex_mem_mem_to_reg),
  .ex_mem_rd_addr   (ex_mem_rd_addr),
  .mem_wb_reg_write (mem_wb_reg_write),
  .mem_wb_rd_addr   (mem_wb_rd_addr)
);
