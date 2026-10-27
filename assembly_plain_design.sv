// =============================================================================
// simple_cpu_pipelined.sv
// 5-stage RV32I-subset pipelined CPU: IF -> ID -> EX -> MEM -> WB.
//
// Supported RV32I subset:
//   R-type: ADD, SUB, AND, OR
//   I-type: ADDI, LW
//   S-type: SW
//   B-type: BEQ
//   U-type: LUI
//   J-type: JAL
//   SYSTEM: ECALL used as HALT
//
// Pipeline correctness features:
//   1. EX/MEM and MEM/WB forwarding
//   2. Load-use hazard stalling
//   3. Control hazard flushing for taken BEQ and JAL
//   4. x0 hardwired to zero
//
// Notes:
//   - PC is byte-addressed and increments by 4.
//   - instr_mem and data_mem are 32-bit word arrays.
//   - LW/SW are word-aligned only; address[1:0] is ignored by indexing [9:2].
//   - Unsupported instructions behave as NOPs, except ECALL which asserts halt.
// =============================================================================

module simple_cpu_pipelined #(
  parameter int DATA_W     = 32,
  parameter int IMEM_DEPTH = 256,
  parameter int DMEM_DEPTH = 256
)(
  input  logic              clk,
  input  logic              rst_n,
  output logic              halt,
  output logic [DATA_W-1:0] pc_out
);

  // ---------------------------------------------------------------------
  // RV32I opcodes
  // ---------------------------------------------------------------------
  localparam logic [6:0] OPCODE_OP      = 7'b0110011; // ADD/SUB/AND/OR
  localparam logic [6:0] OPCODE_OP_IMM  = 7'b0010011; // ADDI
  localparam logic [6:0] OPCODE_LOAD    = 7'b0000011; // LW
  localparam logic [6:0] OPCODE_STORE   = 7'b0100011; // SW
  localparam logic [6:0] OPCODE_BRANCH  = 7'b1100011; // BEQ
  localparam logic [6:0] OPCODE_LUI     = 7'b0110111; // LUI
  localparam logic [6:0] OPCODE_JAL     = 7'b1101111; // JAL
  localparam logic [6:0] OPCODE_SYSTEM  = 7'b1110011; // ECALL

  // funct3 values used by this subset
  localparam logic [2:0] F3_ADD_SUB_ADDI = 3'b000;
  localparam logic [2:0] F3_AND          = 3'b111;
  localparam logic [2:0] F3_OR           = 3'b110;
  localparam logic [2:0] F3_LW_SW        = 3'b010;
  localparam logic [2:0] F3_BEQ          = 3'b000;

  // funct7 values for ADD/SUB distinction
  localparam logic [6:0] F7_ADD = 7'b0000000;
  localparam logic [6:0] F7_SUB = 7'b0100000;

  // ECALL instruction used as simulation HALT
  localparam logic [31:0] INSTR_ECALL = 32'h0000_0073;

  // ---------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------
  logic [31:0] instr_mem [0:IMEM_DEPTH-1];
  logic [31:0] data_mem  [0:DMEM_DEPTH-1];
  logic [31:0] regfile   [0:31];
  logic [31:0] pc;

  assign pc_out = pc;

  // ---------------------------------------------------------------------
  // Pipeline registers and next-state signals
  // ---------------------------------------------------------------------
  // IF/ID
  logic [31:0] if_id_pc,        if_id_pc_n;
  logic [31:0] if_id_instr,     if_id_instr_n;
  logic        if_id_valid,     if_id_valid_n;

  // ID/EX
  logic [31:0] id_ex_pc,        id_ex_pc_n;
  logic [31:0] id_ex_rs1_data,  id_ex_rs1_data_n;
  logic [31:0] id_ex_rs2_data,  id_ex_rs2_data_n;
  logic [31:0] id_ex_imm_sext,  id_ex_imm_sext_n;
  logic [4:0]  id_ex_rs1_addr,  id_ex_rs1_addr_n;
  logic [4:0]  id_ex_rs2_addr,  id_ex_rs2_addr_n;
  logic [4:0]  id_ex_rd_addr,   id_ex_rd_addr_n;
  logic        id_ex_rs2_used,  id_ex_rs2_used_n;
  logic        id_ex_alu_src_imm, id_ex_alu_src_imm_n;
  logic [6:0]  id_ex_opcode,    id_ex_opcode_n;
  logic [2:0]  id_ex_funct3,    id_ex_funct3_n;
  logic [6:0]  id_ex_funct7,    id_ex_funct7_n;
  logic        id_ex_reg_write, id_ex_reg_write_n;
  logic        id_ex_mem_write, id_ex_mem_write_n;
  logic        id_ex_mem_to_reg, id_ex_mem_to_reg_n;
  logic        id_ex_is_branch, id_ex_is_branch_n;
  logic        id_ex_is_jump,   id_ex_is_jump_n;
  logic        id_ex_is_halt,   id_ex_is_halt_n;

  // EX/MEM
  logic [31:0] ex_mem_alu_result, ex_mem_alu_result_n;
  logic [31:0] ex_mem_store_data, ex_mem_store_data_n;
  logic [4:0]  ex_mem_rd_addr,    ex_mem_rd_addr_n;
  logic        ex_mem_reg_write,  ex_mem_reg_write_n;
  logic        ex_mem_mem_write,  ex_mem_mem_write_n;
  logic        ex_mem_mem_to_reg, ex_mem_mem_to_reg_n;

  // MEM/WB
  logic [31:0] mem_wb_write_data, mem_wb_write_data_n;
  logic [4:0]  mem_wb_rd_addr,    mem_wb_rd_addr_n;
  logic        mem_wb_reg_write,  mem_wb_reg_write_n;

  // ======================================================================
  // IF stage
  // ======================================================================
  logic [31:0] if_instr;
  logic [31:0] pc_plus4;
  logic        fetch_is_halt;

  // PC is byte-addressed. instr_mem is word-addressed.
  assign if_instr      = instr_mem[pc[9:2]];
  assign pc_plus4      = pc + 32'd4;
  assign fetch_is_halt = (if_instr == INSTR_ECALL);

  logic        stall_load_use;
  logic        branch_taken;
  logic        jump_taken;
  logic        redirect_taken;
  logic [31:0] redirect_target;

  logic        pc_write;
  logic [31:0] pc_next;

  assign redirect_taken = branch_taken || jump_taken;
  assign pc_write       = (!stall_load_use) || redirect_taken; // redirect wins over stall

  always_comb begin
    if (redirect_taken)      pc_next = redirect_target;
    else if (fetch_is_halt)  pc_next = pc;       // freeze once ECALL is fetched
    else if (stall_load_use) pc_next = pc;       // hold during load-use stall
    else                     pc_next = pc_plus4;
  end

  // ======================================================================
  // ID stage: RV32I decode
  // ======================================================================
  logic [6:0] id_opcode;
  logic [2:0] id_funct3;
  logic [6:0] id_funct7;
  logic [4:0] id_rs1_addr, id_rs2_addr, id_rd_addr;

  logic       id_rs1_used, id_rs2_used, id_alu_src_imm;
  logic       id_reg_write, id_mem_write, id_mem_to_reg;
  logic       id_is_branch, id_is_jump, id_is_halt;

  logic [31:0] id_imm_i;
  logic [31:0] id_imm_s;
  logic [31:0] id_imm_b;
  logic [31:0] id_imm_u;
  logic [31:0] id_imm_j;
  logic [31:0] id_imm_sext;

  assign id_opcode   = if_id_instr[6:0];
  assign id_rd_addr  = if_id_instr[11:7];
  assign id_funct3   = if_id_instr[14:12];
  assign id_rs1_addr = if_id_instr[19:15];
  assign id_rs2_addr = if_id_instr[24:20];
  assign id_funct7   = if_id_instr[31:25];

  // Immediate generation
  assign id_imm_i = {{20{if_id_instr[31]}}, if_id_instr[31:20]};

  assign id_imm_s = {{20{if_id_instr[31]}},
                     if_id_instr[31:25],
                     if_id_instr[11:7]};

  // B/J immediates include bit0 = 0 because RISC-V branch/jump offsets are aligned.
  assign id_imm_b = {{19{if_id_instr[31]}},
                     if_id_instr[31],
                     if_id_instr[7],
                     if_id_instr[30:25],
                     if_id_instr[11:8],
                     1'b0};

  assign id_imm_u = {if_id_instr[31:12], 12'b0};

  assign id_imm_j = {{11{if_id_instr[31]}},
                     if_id_instr[31],
                     if_id_instr[19:12],
                     if_id_instr[20],
                     if_id_instr[30:21],
                     1'b0};

  always_comb begin
    // Defaults: unsupported instructions become NOPs.
    id_rs1_used    = 1'b0; // <---
    id_rs2_used    = 1'b0;
    id_alu_src_imm = 1'b0;
    id_reg_write   = 1'b0;
    id_mem_write   = 1'b0;
    id_mem_to_reg  = 1'b0;
    id_is_branch   = 1'b0;
    id_is_jump     = 1'b0;
    id_is_halt     = 1'b0;
    id_imm_sext    = 32'b0;

    unique case (id_opcode)
      OPCODE_OP: begin
        // ADD/SUB/AND/OR
        if ((id_funct3 == F3_ADD_SUB_ADDI && (id_funct7 == F7_ADD || id_funct7 == F7_SUB)) ||
            (id_funct3 == F3_AND          &&  id_funct7 == F7_ADD) ||
            (id_funct3 == F3_OR           &&  id_funct7 == F7_ADD)) begin
          id_rs1_used  = 1'b1;
          id_rs2_used  = 1'b1;
          id_reg_write = 1'b1;
        end
      end

      OPCODE_OP_IMM: begin
        // ADDI
        if (id_funct3 == F3_ADD_SUB_ADDI) begin
          id_rs1_used    = 1'b1;
          id_alu_src_imm = 1'b1;
          id_reg_write   = 1'b1;
          id_imm_sext    = id_imm_i;
        end
      end

      OPCODE_LOAD: begin
        // LW
        if (id_funct3 == F3_LW_SW) begin
          id_rs1_used    = 1'b1;
          id_alu_src_imm = 1'b1;
          id_reg_write   = 1'b1;
          id_mem_to_reg  = 1'b1;
          id_imm_sext    = id_imm_i;
        end
      end

      OPCODE_STORE: begin
        // SW
        if (id_funct3 == F3_LW_SW) begin
          id_rs1_used    = 1'b1;
          id_rs2_used    = 1'b1;
          id_alu_src_imm = 1'b1;
          id_mem_write   = 1'b1;
          id_imm_sext    = id_imm_s;
        end
      end

      OPCODE_BRANCH: begin
        // BEQ
        if (id_funct3 == F3_BEQ) begin
          id_rs1_used  = 1'b1;
          id_rs2_used  = 1'b1;
          id_is_branch = 1'b1;
          id_imm_sext  = id_imm_b;
        end
      end

      OPCODE_LUI: begin
        id_reg_write = 1'b1;
        id_imm_sext  = id_imm_u;
      end

      OPCODE_JAL: begin
        id_reg_write = 1'b1;
        id_is_jump   = 1'b1;
        id_imm_sext  = id_imm_j;
      end

      OPCODE_SYSTEM: begin
        if (if_id_instr == INSTR_ECALL) begin
          id_is_halt = 1'b1;
        end
      end

      default: begin
        // NOP
      end
    endcase
  end

  // Register file read with same-cycle WB bypass.
  // RISC-V x0 is hardwired to zero.
  logic [31:0] id_rs1_data, id_rs2_data;

  always_comb begin
    if (id_rs1_addr == 5'd0)
      id_rs1_data = 32'b0;
    else if (mem_wb_reg_write && mem_wb_rd_addr != 5'd0 && mem_wb_rd_addr == id_rs1_addr)
      id_rs1_data = mem_wb_write_data;
    else
      id_rs1_data = regfile[id_rs1_addr];

    if (id_rs2_addr == 5'd0)
      id_rs2_data = 32'b0;
    else if (mem_wb_reg_write && mem_wb_rd_addr != 5'd0 && mem_wb_rd_addr == id_rs2_addr)
      id_rs2_data = mem_wb_write_data;
    else
      id_rs2_data = regfile[id_rs2_addr];
  end

  // ---------------------------------------------------------------------
  // Hazard detection: stall one cycle on load-use hazard.
  // ---------------------------------------------------------------------
  always_comb begin
    stall_load_use = 1'b0;

    if (id_ex_opcode == OPCODE_LOAD &&
        id_ex_reg_write &&
        id_ex_rd_addr != 5'd0) begin

      if (id_rs1_used && id_ex_rd_addr == id_rs1_addr)
        stall_load_use = 1'b1;            //<---

      if (id_rs2_used && id_ex_rd_addr == id_rs2_addr)
        stall_load_use = 1'b1;
    end
  end

  logic if_id_write;
  assign if_id_write = (!stall_load_use) || redirect_taken;

  always_comb begin
    if (redirect_taken) begin
      if_id_pc_n    = 32'b0;
      if_id_instr_n = 32'b0;
      if_id_valid_n = 1'b0;
    end else if (stall_load_use) begin
      if_id_pc_n    = if_id_pc;
      if_id_instr_n = if_id_instr;
      if_id_valid_n = if_id_valid;
    end else begin
      if_id_pc_n    = pc;
      if_id_instr_n = if_instr;
      if_id_valid_n = 1'b1;
    end
  end

  logic id_ex_bubble;
  assign id_ex_bubble = stall_load_use || redirect_taken;

  always_comb begin
    if (id_ex_bubble) begin
      id_ex_pc_n          = 32'b0;
      id_ex_rs1_data_n    = 32'b0;
      id_ex_rs2_data_n    = 32'b0;
      id_ex_imm_sext_n    = 32'b0;
      id_ex_rs1_addr_n    = 5'b0;
      id_ex_rs2_addr_n    = 5'b0;
      id_ex_rd_addr_n     = 5'b0;
      id_ex_rs2_used_n    = 1'b0;
      id_ex_alu_src_imm_n = 1'b0;
      id_ex_opcode_n      = 7'b0;
      id_ex_funct3_n      = 3'b0;
      id_ex_funct7_n      = 7'b0;
      id_ex_reg_write_n   = 1'b0;
      id_ex_mem_write_n   = 1'b0;
      id_ex_mem_to_reg_n  = 1'b0;
      id_ex_is_branch_n   = 1'b0;
      id_ex_is_jump_n     = 1'b0;
      id_ex_is_halt_n     = 1'b0;
    end else begin
      id_ex_pc_n          = if_id_pc;
      id_ex_rs1_data_n    = id_rs1_data;
      id_ex_rs2_data_n    = id_rs2_data;
      id_ex_imm_sext_n    = id_imm_sext;
      id_ex_rs1_addr_n    = id_rs1_addr;
      id_ex_rs2_addr_n    = id_rs2_addr;
      id_ex_rd_addr_n     = id_rd_addr;
      id_ex_rs2_used_n    = id_rs2_used;
      id_ex_alu_src_imm_n = id_alu_src_imm;
      id_ex_opcode_n      = id_opcode;
      id_ex_funct3_n      = id_funct3;
      id_ex_funct7_n      = id_funct7;
      id_ex_reg_write_n   = id_reg_write;
      id_ex_mem_write_n   = id_mem_write;
      id_ex_mem_to_reg_n  = id_mem_to_reg;
      id_ex_is_branch_n   = id_is_branch;
      id_ex_is_jump_n     = id_is_jump;
      id_ex_is_halt_n     = id_is_halt;
    end
  end

  // ======================================================================
  // EX stage: forwarding + ALU + branch/jump resolution
  // ======================================================================
  logic [31:0] fwd_rs1, fwd_rs2;

  // Forwarding mux: EX/MEM result has priority, then MEM/WB.
  // Do not forward into x0. Do not forward EX/MEM load address as data.
  always_comb begin
    if (id_ex_rs1_addr == 5'd0)
      fwd_rs1 = 32'b0;
    else if (ex_mem_reg_write && !ex_mem_mem_to_reg &&
             ex_mem_rd_addr != 5'd0 && ex_mem_rd_addr == id_ex_rs1_addr)
      fwd_rs1 = ex_mem_alu_result;
    else if (mem_wb_reg_write && mem_wb_rd_addr != 5'd0 && mem_wb_rd_addr == id_ex_rs1_addr)
      fwd_rs1 = mem_wb_write_data;
    else
      fwd_rs1 = id_ex_rs1_data;

    if (id_ex_rs2_addr == 5'd0)
      fwd_rs2 = 32'b0;
    else if (ex_mem_reg_write && !ex_mem_mem_to_reg &&
             ex_mem_rd_addr != 5'd0 && ex_mem_rd_addr == id_ex_rs2_addr)
      fwd_rs2 = ex_mem_alu_result;
    else if (mem_wb_reg_write && mem_wb_rd_addr != 5'd0 && mem_wb_rd_addr == id_ex_rs2_addr)
      fwd_rs2 = mem_wb_write_data;
    else
      fwd_rs2 = id_ex_rs2_data;
  end

  logic [31:0] alu_op_b, alu_result;
  logic        alu_zero;

  assign alu_op_b = id_ex_alu_src_imm ? id_ex_imm_sext : fwd_rs2;
  assign alu_zero = (fwd_rs1 == fwd_rs2);

  always_comb begin
    alu_result = 32'b0;

    unique case (id_ex_opcode)
      OPCODE_OP: begin
        unique case (id_ex_funct3)
          F3_ADD_SUB_ADDI: begin
            if (id_ex_funct7 == F7_SUB)
              alu_result = fwd_rs1 - fwd_rs2; // SUB
            else
              alu_result = fwd_rs1 + fwd_rs2; // ADD
          end
          F3_AND:  alu_result = fwd_rs1 & fwd_rs2;
          F3_OR:   alu_result = fwd_rs1 | fwd_rs2;
          default: alu_result = 32'b0;
        endcase
      end

      OPCODE_OP_IMM: begin
        // ADDI only in this subset.
        alu_result = fwd_rs1 + id_ex_imm_sext;
      end

      OPCODE_LOAD,
      OPCODE_STORE: begin
        // Effective byte address.
        alu_result = fwd_rs1 + id_ex_imm_sext;
      end

      OPCODE_LUI: begin
        alu_result = id_ex_imm_sext;
      end

      OPCODE_JAL: begin
        // Link value: rd = PC + 4.
        alu_result = id_ex_pc + 32'd4;
      end

      default: begin
        alu_result = 32'b0;
      end
    endcase
  end

  assign branch_taken = id_ex_is_branch &&
                        (id_ex_funct3 == F3_BEQ) &&
                        alu_zero;

  assign jump_taken = id_ex_is_jump;

  always_comb begin
    if (jump_taken)
      redirect_target = id_ex_pc + id_ex_imm_sext;
    else if (branch_taken)
      redirect_target = id_ex_pc + id_ex_imm_sext;
    else
      redirect_target = 32'b0;
  end

  always_comb begin
    ex_mem_alu_result_n = alu_result;
    ex_mem_store_data_n = fwd_rs2;
    ex_mem_rd_addr_n    = id_ex_rd_addr;
    ex_mem_reg_write_n  = id_ex_reg_write;
    ex_mem_mem_write_n  = id_ex_mem_write;
    ex_mem_mem_to_reg_n = id_ex_mem_to_reg;
  end

  // ======================================================================
  // MEM stage
  // ======================================================================
  logic [31:0] mem_rdata;

  // data_mem is word-addressed; RISC-V LW/SW addresses are byte-addressed.
  assign mem_rdata = data_mem[ex_mem_alu_result[9:2]];

  always_comb begin
    mem_wb_write_data_n = ex_mem_mem_to_reg ? mem_rdata : ex_mem_alu_result;
    mem_wb_rd_addr_n    = ex_mem_rd_addr;
    mem_wb_reg_write_n  = ex_mem_reg_write;
  end

  // ======================================================================
  // Sequential state update
  // ======================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= 32'b0;

      if_id_pc    <= 32'b0;
      if_id_instr <= 32'b0;
      if_id_valid <= 1'b0;

      id_ex_pc          <= 32'b0;
      id_ex_rs1_data    <= 32'b0;
      id_ex_rs2_data    <= 32'b0;
      id_ex_imm_sext    <= 32'b0;
      id_ex_rs1_addr    <= 5'b0;
      id_ex_rs2_addr    <= 5'b0;
      id_ex_rd_addr     <= 5'b0;
      id_ex_rs2_used    <= 1'b0;
      id_ex_alu_src_imm <= 1'b0;
      id_ex_opcode      <= 7'b0;
      id_ex_funct3      <= 3'b0;
      id_ex_funct7      <= 7'b0;
      id_ex_reg_write   <= 1'b0;
      id_ex_mem_write   <= 1'b0;
      id_ex_mem_to_reg  <= 1'b0;
      id_ex_is_branch   <= 1'b0;
      id_ex_is_jump     <= 1'b0;
      id_ex_is_halt     <= 1'b0;

      ex_mem_alu_result <= 32'b0;
      ex_mem_store_data <= 32'b0;
      ex_mem_rd_addr    <= 5'b0;
      ex_mem_reg_write  <= 1'b0;
      ex_mem_mem_write  <= 1'b0;
      ex_mem_mem_to_reg <= 1'b0;

      mem_wb_write_data <= 32'b0;
      mem_wb_rd_addr    <= 5'b0;
      mem_wb_reg_write  <= 1'b0;

      halt <= 1'b0;

      for (int i = 0; i < 32; i++) begin
        regfile[i] <= 32'b0;
      end
    end else begin
      if (pc_write)
        pc <= pc_next;

      if (if_id_write) begin
        if_id_pc    <= if_id_pc_n;
        if_id_instr <= if_id_instr_n;
        if_id_valid <= if_id_valid_n;
      end

      id_ex_pc          <= id_ex_pc_n;
      id_ex_rs1_data    <= id_ex_rs1_data_n;
      id_ex_rs2_data    <= id_ex_rs2_data_n;
      id_ex_imm_sext    <= id_ex_imm_sext_n;
      id_ex_rs1_addr    <= id_ex_rs1_addr_n;
      id_ex_rs2_addr    <= id_ex_rs2_addr_n;
      id_ex_rd_addr     <= id_ex_rd_addr_n;
      id_ex_rs2_used    <= id_ex_rs2_used_n;
      id_ex_alu_src_imm <= id_ex_alu_src_imm_n;
      id_ex_opcode      <= id_ex_opcode_n;
      id_ex_funct3      <= id_ex_funct3_n;
      id_ex_funct7      <= id_ex_funct7_n;
      id_ex_reg_write   <= id_ex_reg_write_n;
      id_ex_mem_write   <= id_ex_mem_write_n;
      id_ex_mem_to_reg  <= id_ex_mem_to_reg_n;
      id_ex_is_branch   <= id_ex_is_branch_n;
      id_ex_is_jump     <= id_ex_is_jump_n;
      id_ex_is_halt     <= id_ex_is_halt_n;

      ex_mem_alu_result <= ex_mem_alu_result_n;
      ex_mem_store_data <= ex_mem_store_data_n;
      ex_mem_rd_addr    <= ex_mem_rd_addr_n;
      ex_mem_reg_write  <= ex_mem_reg_write_n;
      ex_mem_mem_write  <= ex_mem_mem_write_n;
      ex_mem_mem_to_reg <= ex_mem_mem_to_reg_n;

      mem_wb_write_data <= mem_wb_write_data_n;
      mem_wb_rd_addr    <= mem_wb_rd_addr_n;
      mem_wb_reg_write  <= mem_wb_reg_write_n;

      // Register file writeback. Ignore writes to x0.
      if (mem_wb_reg_write && mem_wb_rd_addr != 5'd0)
        regfile[mem_wb_rd_addr] <= mem_wb_write_data;

      // Data memory write. Word-aligned SW only.
      if (ex_mem_mem_write)
        data_mem[ex_mem_alu_result[9:2]] <= ex_mem_store_data;

      // x0 is hardwired to zero.
      regfile[0] <= 32'b0;

      // ECALL acts as simulation halt.
      if (id_ex_is_halt)
        halt <= 1'b1;
    end
  end

endmodule
