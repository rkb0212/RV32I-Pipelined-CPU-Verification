// =============================================================================
// control_unit.sv
// Used in: ID stage (instruction decode) and, for hazard/branch logic, reads
//   a few EX-stage pipeline-register values that live in design_top.sv.
// How it works: purely combinational. Splits into two halves:
//   1. ID decode of the currently-fetched instruction (if_id_instr) into
//      opcode/funct fields, register addresses, the sign-extended immediate,
//      and every control bit design_top.sv's pipeline registers need.
//   2. Hazard + control-transfer resolution, using the EX-stage instruction's
//      latched fields (id_ex_*) plus alu_zero fed back from alu.sv:
//        - stall_load_use: one-cycle stall for a load-use RAW hazard that
//          forwarding cannot fix in time.
//        - branch_taken / jump_taken / redirect_taken / redirect_target:
//          BEQ and JAL resolve here, in the same stage as the ALU comparison.
//        - misaligned_target: RV32I (no C-extension) requires a 4-byte
//          aligned branch/jump target. design_top.sv turns this into a
//          trap (cause 0) instead of redirecting to the bad address.
//        - is_mret: MRET (0x30200073) is decoded here; design_top.sv carries
//          it to MEM and jumps to MEPC from there.
//        - pc_write / pc_next: what design_top.sv's PC register does next.
// Why it's used: this is the "Control Unit" block in the diagram -- it owns
//   every decode and hazard decision but no state of its own; all pipeline
//   registers live in design_top.sv.
// =============================================================================
module control_unit #(
  parameter int DATA_W = 32
)(
  // current fetch (registered IF/ID instruction + its PC)
  input  logic [DATA_W-1:0] if_id_instr,
  input  logic [DATA_W-1:0] pc,

  // EX-stage pipeline register values, for hazard + branch resolution
  input  logic [6:0]        id_ex_opcode,
  input  logic [4:0]        id_ex_rd_addr,
  input  logic              id_ex_reg_write,
  input  logic              id_ex_is_branch,
  input  logic              id_ex_is_jump,
  input  logic [DATA_W-1:0] id_ex_pc,
  input  logic [DATA_W-1:0] id_ex_imm_sext,
  input  logic              alu_zero,

  // ---- ID decode outputs ----
  output logic [6:0]        id_opcode,
  output logic [2:0]        funct3,
  output logic [6:0]        funct7,
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  output logic [4:0]        rd_addr,
  output logic              id_reg_write,
  output logic              mem_write,
  output logic              mem_to_reg,
  output logic              is_branch,
  output logic              is_jump,
  output logic              is_halt,
  output logic              is_mret,
  output logic [DATA_W-1:0] id_imm_sext,
  output logic              alu_src_imm,

  // ---- hazard + control-transfer outputs ----
  output logic              stall_load_use,
  output logic              branch_taken,
  output logic              jump_taken,
  output logic              redirect_taken,
  output logic [DATA_W-1:0] redirect_target,
  output logic              misaligned_target,
  output logic              pc_write,
  output logic [DATA_W-1:0] pc_next
);

  // RV32I opcodes (same subset as design.sv)
  localparam logic [6:0] OPCODE_OP      = 7'b0110011; // ADD/SUB/AND/OR
  localparam logic [6:0] OPCODE_OP_IMM  = 7'b0010011; // ADDI
  localparam logic [6:0] OPCODE_LOAD    = 7'b0000011; // LW
  localparam logic [6:0] OPCODE_STORE   = 7'b0100011; // SW
  localparam logic [6:0] OPCODE_BRANCH  = 7'b1100011; // BEQ
  localparam logic [6:0] OPCODE_LUI     = 7'b0110111; // LUI
  localparam logic [6:0] OPCODE_JAL     = 7'b1101111; // JAL
  localparam logic [6:0] OPCODE_SYSTEM  = 7'b1110011; // ECALL

  localparam logic [2:0] F3_ADD_SUB_ADDI = 3'b000;
  localparam logic [2:0] F3_AND          = 3'b111;
  localparam logic [2:0] F3_OR           = 3'b110;
  localparam logic [2:0] F3_LW_SW        = 3'b010;
  localparam logic [2:0] F3_BEQ          = 3'b000;

  localparam logic [6:0] F7_ADD = 7'b0000000;
  localparam logic [6:0] F7_SUB = 7'b0100000;

  localparam logic [31:0] INSTR_ECALL = 32'h0000_0073;
  localparam logic [31:0] INSTR_MRET  = 32'h3020_0073; // return from trap

  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  logic        rs1_used, rs2_used;

  assign id_opcode = if_id_instr[6:0];
  assign rd_addr   = if_id_instr[11:7];
  assign funct3    = if_id_instr[14:12];
  assign rs1_addr  = if_id_instr[19:15];
  assign rs2_addr  = if_id_instr[24:20];
  assign funct7    = if_id_instr[31:25];

  assign imm_i = {{20{if_id_instr[31]}}, if_id_instr[31:20]};
  assign imm_s = {{20{if_id_instr[31]}}, if_id_instr[31:25], if_id_instr[11:7]};
  assign imm_b = {{19{if_id_instr[31]}}, if_id_instr[31], if_id_instr[7],
                  if_id_instr[30:25], if_id_instr[11:8], 1'b0};
  assign imm_u = {if_id_instr[31:12], 12'b0};
  assign imm_j = {{11{if_id_instr[31]}}, if_id_instr[31], if_id_instr[19:12],
                  if_id_instr[20], if_id_instr[30:21], 1'b0};

  // ID decode
  always_comb begin
    rs1_used     = 1'b0;
    rs2_used     = 1'b0;
    alu_src_imm  = 1'b0;
    id_reg_write = 1'b0;
    mem_write    = 1'b0;
    mem_to_reg   = 1'b0;
    is_branch    = 1'b0;
    is_jump      = 1'b0;
    is_halt      = 1'b0;
    is_mret      = 1'b0;
    id_imm_sext  = 32'b0;

    unique case (id_opcode)
      OPCODE_OP: begin
        if ((funct3 == F3_ADD_SUB_ADDI && (funct7 == F7_ADD || funct7 == F7_SUB)) ||
            (funct3 == F3_AND          &&  funct7 == F7_ADD) ||
            (funct3 == F3_OR           &&  funct7 == F7_ADD)) begin
          rs1_used     = 1'b1;
          rs2_used     = 1'b1;
          id_reg_write = 1'b1;
        end
      end
      OPCODE_OP_IMM: begin
        if (funct3 == F3_ADD_SUB_ADDI) begin
          rs1_used     = 1'b1;
          alu_src_imm  = 1'b1;
          id_reg_write = 1'b1;
          id_imm_sext  = imm_i;
        end
      end
      OPCODE_LOAD: begin
        if (funct3 == F3_LW_SW) begin
          rs1_used     = 1'b1;
          alu_src_imm  = 1'b1;
          id_reg_write = 1'b1;
          mem_to_reg   = 1'b1;
          id_imm_sext  = imm_i;
        end
      end
      OPCODE_STORE: begin
        if (funct3 == F3_LW_SW) begin
          rs1_used    = 1'b1;
          rs2_used    = 1'b1;
          alu_src_imm = 1'b1;
          mem_write   = 1'b1;
          id_imm_sext = imm_s;
        end
      end
      OPCODE_BRANCH: begin
        if (funct3 == F3_BEQ) begin
          rs1_used    = 1'b1;
          rs2_used    = 1'b1;
          is_branch   = 1'b1;
          id_imm_sext = imm_b;
        end
      end
      OPCODE_LUI: begin
        id_reg_write = 1'b1;
        id_imm_sext  = imm_u;
      end
      OPCODE_JAL: begin
        id_reg_write = 1'b1;
        is_jump      = 1'b1;
        id_imm_sext  = imm_j;
      end
      OPCODE_SYSTEM: begin
        if (if_id_instr == INSTR_ECALL) is_halt = 1'b1;
        if (if_id_instr == INSTR_MRET)  is_mret = 1'b1;
      end
      default: ; // unsupported instructions decode as NOP
    endcase
  end

  // Load-use hazard: stall one cycle if the EX-stage instruction is a load
  // whose destination this ID-stage instruction actually reads.
  always_comb begin
    stall_load_use = 1'b0;
    if (id_ex_opcode == OPCODE_LOAD && id_ex_reg_write && id_ex_rd_addr != 5'd0) begin
      if (rs1_used && id_ex_rd_addr == rs1_addr) stall_load_use = 1'b1;
      if (rs2_used && id_ex_rd_addr == rs2_addr) stall_load_use = 1'b1;
    end
  end

  // Branch/jump resolution -- happens in EX, using the EX-stage instruction's
  // own latched fields and this cycle's alu_zero from alu.sv.
  assign branch_taken   = id_ex_is_branch && alu_zero;
  assign jump_taken     = id_ex_is_jump;
  assign redirect_taken = branch_taken || jump_taken;

  always_comb begin
    if (redirect_taken) redirect_target = id_ex_pc + id_ex_imm_sext;
    else                redirect_target = 32'b0;
  end

  assign misaligned_target = redirect_taken && (redirect_target[1:0] != 2'b00);

  // PC control
  assign pc_write = (!stall_load_use) || redirect_taken;

  always_comb begin
    if (redirect_taken)      pc_next = redirect_target;
    else if (stall_load_use) pc_next = pc;
    else                     pc_next = pc + 32'd4;
  end

endmodule

