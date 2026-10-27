// =============================================================================
// cpu_functions.sv  (included inside cpu_pkg -- not compiled on its own)
// Every standalone utility function lives here: RV32I constants, instruction
// encoders, and a small disassembler used only for readable logs.
// Each function states: purpose / mechanism / rationale.
// =============================================================================

// ---- opcodes / fields of the implemented subset ----
localparam bit [6:0] OP      = 7'b0110011;   // ADD SUB AND OR
localparam bit [6:0] OP_IMM  = 7'b0010011;   // ADDI
localparam bit [6:0] LOAD    = 7'b0000011;   // LW
localparam bit [6:0] STORE   = 7'b0100011;   // SW
localparam bit [6:0] BRANCH  = 7'b1100011;   // BEQ
localparam bit [6:0] LUI     = 7'b0110111;
localparam bit [6:0] JAL     = 7'b1101111;
localparam bit [6:0] SYSTEM  = 7'b1110011;   // ECALL (halt), MRET

localparam bit [2:0] F3_ADD_SUB_ADDI = 3'b000;
localparam bit [2:0] F3_LW_SW        = 3'b010;
localparam bit [2:0] F3_BEQ          = 3'b000;
localparam bit [2:0] F3_OR           = 3'b110;
localparam bit [2:0] F3_AND          = 3'b111;
localparam bit [6:0] F7_ADD          = 7'b0000000;
localparam bit [6:0] F7_SUB          = 7'b0100000;

localparam bit [31:0] INSTR_ECALL = 32'h0000_0073;  // halts the DUT
localparam bit [31:0] INSTR_MRET  = 32'h3020_0073;  // return from trap
localparam bit [31:0] INSTR_NOP   = 32'h0000_0013;  // ADDI x0,x0,0

// ---- memory map (must match design_top.sv) ----
localparam bit [31:0] CSR_BASE    = 32'hFFFF_FF00;
localparam int        CSR_MTVEC   = 'h10;  // byte offsets from CSR_BASE
localparam int        CSR_MEPC    = 'h14;
localparam int        CSR_MCAUSE  = 'h18;
localparam int        CSR_MTVAL   = 'h1C;
localparam int        CSR_HALT    = 'h08;
localparam int        CSR_SCRATCH = 'h0C;

// ---------------------------------------------------------------------------
// Purpose  : build a 32-bit R-type word. Mechanism: concatenate fields in the
// RV32I order. Rationale: sequences read like assembly instead of hex.
// ---------------------------------------------------------------------------
function automatic bit [31:0] enc_r(input bit [6:0] opcode, input bit [4:0] rd,
    input bit [2:0] funct3, input bit [4:0] rs1, input bit [4:0] rs2, input bit [6:0] funct7);
  return {funct7, rs2, rs1, funct3, rd, opcode};
endfunction

// I-type (ADDI, LW). imm is signed; only the low 12 bits are encoded.
function automatic bit [31:0] enc_i(input bit [6:0] opcode, input bit [4:0] rd,
    input bit [2:0] funct3, input bit [4:0] rs1, input int signed imm);
  bit [11:0] imm12;
  imm12 = imm[11:0];
  return {imm12, rs1, funct3, rd, opcode};
endfunction

// S-type (SW): the 12-bit offset is split around rs1/funct3.
function automatic bit [31:0] enc_s(input bit [6:0] opcode, input bit [2:0] funct3,
    input bit [4:0] rs1, input bit [4:0] rs2, input int signed imm);
  bit [11:0] imm12;
  imm12 = imm[11:0];
  return {imm12[11:5], rs2, rs1, funct3, imm12[4:0], opcode};
endfunction

// B-type (BEQ): imm is a BYTE offset from the branch's own PC; bit0 is implicit.
function automatic bit [31:0] enc_b(input bit [6:0] opcode, input bit [2:0] funct3,
    input bit [4:0] rs1, input bit [4:0] rs2, input int signed imm);
  bit [12:0] imm13;
  imm13 = imm[12:0];
  return {imm13[12], imm13[10:5], rs2, rs1, funct3, imm13[4:1], imm13[11], opcode};
endfunction

// U-type (LUI): upper 20 bits.
function automatic bit [31:0] enc_u(input bit [6:0] opcode, input bit [4:0] rd,
    input bit [19:0] imm20);
  return {imm20, rd, opcode};
endfunction

// J-type (JAL): imm is a BYTE offset from the JAL's own PC.
function automatic bit [31:0] enc_j(input bit [6:0] opcode, input bit [4:0] rd,
    input int signed imm);
  bit [20:0] imm21;
  imm21 = imm[20:0];
  return {imm21[20], imm21[10:1], imm21[11], imm21[19:12], rd, opcode};
endfunction

// ---------------------------------------------------------------------------
// Purpose  : turn an instruction word into text for logs.
// Mechanism: decode opcode/funct fields exactly like control_unit.sv does.
// Rationale: a Phase-1 environment has no checker yet, so readable program
//            listings in the log are how you see what was driven.
// ---------------------------------------------------------------------------
function automatic string rv_disasm(input bit [31:0] w);
  bit [6:0] op = w[6:0];
  bit [4:0] rd = w[11:7], rs1 = w[19:15], rs2 = w[24:20];
  bit [2:0] f3 = w[14:12];
  bit [6:0] f7 = w[31:25];
  int signed imm_i = $signed({{20{w[31]}}, w[31:20]});
  int signed imm_s = $signed({{20{w[31]}}, w[31:25], w[11:7]});
  int signed imm_b = $signed({{19{w[31]}}, w[31], w[7], w[30:25], w[11:8], 1'b0});
  int signed imm_j = $signed({{11{w[31]}}, w[31], w[19:12], w[20], w[30:21], 1'b0});
  if (w == INSTR_ECALL) return "ECALL";
  if (w == INSTR_MRET)  return "MRET";
  if (w == INSTR_NOP)   return "NOP";
  case (op)
    OP: begin
      if (f3 == F3_ADD_SUB_ADDI && f7 == F7_ADD) return $sformatf("ADD  x%0d,x%0d,x%0d", rd, rs1, rs2);
      if (f3 == F3_ADD_SUB_ADDI && f7 == F7_SUB) return $sformatf("SUB  x%0d,x%0d,x%0d", rd, rs1, rs2);
      if (f3 == F3_AND)                          return $sformatf("AND  x%0d,x%0d,x%0d", rd, rs1, rs2);
      if (f3 == F3_OR)                           return $sformatf("OR   x%0d,x%0d,x%0d", rd, rs1, rs2);
    end
    OP_IMM: if (f3 == F3_ADD_SUB_ADDI) return $sformatf("ADDI x%0d,x%0d,%0d", rd, rs1, imm_i);
    LOAD:   if (f3 == F3_LW_SW)        return $sformatf("LW   x%0d,%0d(x%0d)", rd, imm_i, rs1);
    STORE:  if (f3 == F3_LW_SW)        return $sformatf("SW   x%0d,%0d(x%0d)", rs2, imm_s, rs1);
    BRANCH: if (f3 == F3_BEQ)          return $sformatf("BEQ  x%0d,x%0d,%0d", rs1, rs2, imm_b);
    LUI:                               return $sformatf("LUI  x%0d,0x%05h", rd, w[31:12]);
    JAL:                               return $sformatf("JAL  x%0d,%0d", rd, imm_j);
    default: ;
  endcase
  return $sformatf("?? 0x%08h", w);
endfunction

// ---------------------------------------------------------------------------
// Assembly-style shorthands so sequences read like a program listing.
// Purpose: shorter and less error-prone than enc_*(opcode, funct, ...) calls.
// Mechanism: each is one enc_* call with the fixed opcode/funct filled in.
// ---------------------------------------------------------------------------
function automatic bit [31:0] addi(input bit [4:0] rd, input bit [4:0] rs1, input int signed imm);
  return enc_i(OP_IMM, rd, F3_ADD_SUB_ADDI, rs1, imm);
endfunction
function automatic bit [31:0] add_(input bit [4:0] rd, input bit [4:0] rs1, input bit [4:0] rs2);
  return enc_r(OP, rd, F3_ADD_SUB_ADDI, rs1, rs2, F7_ADD);
endfunction
function automatic bit [31:0] sub_(input bit [4:0] rd, input bit [4:0] rs1, input bit [4:0] rs2);
  return enc_r(OP, rd, F3_ADD_SUB_ADDI, rs1, rs2, F7_SUB);
endfunction
function automatic bit [31:0] and_(input bit [4:0] rd, input bit [4:0] rs1, input bit [4:0] rs2);
  return enc_r(OP, rd, F3_AND, rs1, rs2, F7_ADD);
endfunction
function automatic bit [31:0] or_(input bit [4:0] rd, input bit [4:0] rs1, input bit [4:0] rs2);
  return enc_r(OP, rd, F3_OR, rs1, rs2, F7_ADD);
endfunction
function automatic bit [31:0] lw(input bit [4:0] rd, input bit [4:0] rs1, input int signed imm);
  return enc_i(LOAD, rd, F3_LW_SW, rs1, imm);
endfunction
function automatic bit [31:0] sw(input bit [4:0] rs2, input bit [4:0] rs1, input int signed imm);
  return enc_s(STORE, F3_LW_SW, rs1, rs2, imm);
endfunction
function automatic bit [31:0] beq(input bit [4:0] rs1, input bit [4:0] rs2, input int signed imm);
  return enc_b(BRANCH, F3_BEQ, rs1, rs2, imm);
endfunction
function automatic bit [31:0] lui(input bit [4:0] rd, input bit [19:0] imm20);
  return enc_u(LUI, rd, imm20);
endfunction
function automatic bit [31:0] jal(input bit [4:0] rd, input int signed imm);
  return enc_j(JAL, rd, imm);
endfunction
