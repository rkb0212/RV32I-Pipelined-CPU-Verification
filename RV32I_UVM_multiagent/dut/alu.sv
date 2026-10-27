// =============================================================================
// alu.sv
// Used in: EX stage.
// How it works: takes the ID/EX pipeline register's operands and does its
//   own forwarding -- checks EX/MEM's result first (highest priority, most
//   recently produced), then MEM/WB's result, before falling back to the
//   value the register file handed it back in ID. This is what lets a
//   dependent instruction run with zero stall cycles for every hazard except
//   the one-cycle load-use case control_unit.sv already stalls for.
//   operand2 is then chosen between the (possibly forwarded) rs2 value and
//   the sign-extended immediate, and the RV32I subset's ALU op executes.
// Why it's used: this is the "ALU" block in the diagram; fwd_rs1/fwd_rs2 stay
//   internal to it, only alu_result/alu_zero/store_data cross its boundary.
// =============================================================================
module alu #(
  parameter int DATA_W = 32
)(
  // ID/EX pipeline register
  input  logic [DATA_W-1:0] id_ex_rs1_data,
  input  logic [DATA_W-1:0] id_ex_rs2_data,
  input  logic [4:0]        id_ex_rs1_addr,
  input  logic [4:0]        id_ex_rs2_addr,
  input  logic [DATA_W-1:0] id_ex_imm_sext,
  input  logic              id_ex_alu_src_imm,
  input  logic [6:0]        id_ex_opcode,
  input  logic [2:0]        id_ex_funct3,
  input  logic [6:0]        id_ex_funct7,
  input  logic [DATA_W-1:0] id_ex_pc,

  // EX/MEM pipeline register (forwarding source #1, highest priority)
  input  logic [DATA_W-1:0] ex_mem_alu_result,
  input  logic              ex_mem_reg_write,
  input  logic [4:0]        ex_mem_rd_addr,
  input  logic              ex_mem_mem_to_reg,

  // MEM/WB pipeline register (forwarding source #2)
  input  logic [DATA_W-1:0] mem_wb_mem_result,
  input  logic              mem_wb_reg_write,
  input  logic [4:0]        mem_wb_rd_addr,

  output logic [DATA_W-1:0] alu_result,
  output logic              alu_zero,
  output logic [DATA_W-1:0] store_data
);

  localparam logic [6:0] OPCODE_OP      = 7'b0110011;
  localparam logic [6:0] OPCODE_OP_IMM  = 7'b0010011;
  localparam logic [6:0] OPCODE_LOAD    = 7'b0000011;
  localparam logic [6:0] OPCODE_STORE   = 7'b0100011;
  localparam logic [6:0] OPCODE_LUI     = 7'b0110111;
  localparam logic [6:0] OPCODE_JAL     = 7'b1101111;

  localparam logic [2:0] F3_ADD_SUB_ADDI = 3'b000;
  localparam logic [2:0] F3_AND          = 3'b111;
  localparam logic [2:0] F3_OR           = 3'b110;
  localparam logic [6:0] F7_SUB          = 7'b0100000;

  logic [DATA_W-1:0] fwd_rs1, fwd_rs2;
  logic [DATA_W-1:0] operand2;

  // Forwarding: EX/MEM has priority (most recent), then MEM/WB.
  // Never forward into x0, and never forward a load's own address as data
  // (ex_mem_mem_to_reg means the EX/MEM instruction is itself a load, whose
  // real result isn't ready until MEM -- that case is a load-use hazard and
  // is caught by stall_load_use in control_unit.sv instead).
  always_comb begin
    if (id_ex_rs1_addr == 5'd0)
      fwd_rs1 = '0;
    else if (ex_mem_reg_write && !ex_mem_mem_to_reg && ex_mem_rd_addr != 5'd0 &&
             ex_mem_rd_addr == id_ex_rs1_addr)
      fwd_rs1 = ex_mem_alu_result;
    else if (mem_wb_reg_write && mem_wb_rd_addr != 5'd0 && mem_wb_rd_addr == id_ex_rs1_addr)
      fwd_rs1 = mem_wb_mem_result;
    else
      fwd_rs1 = id_ex_rs1_data;

    if (id_ex_rs2_addr == 5'd0)
      fwd_rs2 = '0;
    else if (ex_mem_reg_write && !ex_mem_mem_to_reg && ex_mem_rd_addr != 5'd0 &&
             ex_mem_rd_addr == id_ex_rs2_addr)
      fwd_rs2 = ex_mem_alu_result;
    else if (mem_wb_reg_write && mem_wb_rd_addr != 5'd0 && mem_wb_rd_addr == id_ex_rs2_addr)
      fwd_rs2 = mem_wb_mem_result;
    else
      fwd_rs2 = id_ex_rs2_data;
  end

  assign operand2   = id_ex_alu_src_imm ? id_ex_imm_sext : fwd_rs2;
  assign store_data = fwd_rs2;
  assign alu_zero   = (fwd_rs1 == fwd_rs2);

  always_comb begin
    alu_result = 32'b0;
    unique case (id_ex_opcode)
      OPCODE_OP: begin
        unique case (id_ex_funct3)
          F3_ADD_SUB_ADDI: alu_result = (id_ex_funct7 == F7_SUB) ? (fwd_rs1 - operand2)
                                                                  : (fwd_rs1 + operand2);
          F3_AND:          alu_result = fwd_rs1 & operand2;
          F3_OR:           alu_result = fwd_rs1 | operand2;
          default:         alu_result = 32'b0;
        endcase
      end
      OPCODE_OP_IMM:            alu_result = fwd_rs1 + operand2; // ADDI only
      OPCODE_LOAD, OPCODE_STORE: alu_result = fwd_rs1 + operand2; // effective address
      OPCODE_LUI:               alu_result = id_ex_imm_sext;
      OPCODE_JAL:               alu_result = id_ex_pc + 32'd4; // link value (rd = return address)
      default:                  alu_result = 32'b0;
    endcase
  end

endmodule
