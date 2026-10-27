// =============================================================================
// design_top.sv
// 5-stage RV32I-subset pipelined CPU: IF -> ID -> EX -> MEM -> WB, matching
// the block diagram (cpu_dut_block_diagram.html).
//
// Owns all state: the PC register, instr_mem[], and every IF/ID, ID/EX,
// EX/MEM, MEM/WB pipeline register. control_unit.sv, regfile.sv, alu.sv,
// lsu.sv and data_memory.sv are all purely combinational-plus-their-own-state
// blocks wired together here -- this is deliberately the only place pipeline
// timing decisions (bubbling, stalling, redirecting) actually happen.
//
// Supported RV32I subset (same as the original single-file design.sv):
//   R-type: ADD, SUB, AND, OR
//   I-type: ADDI, LW
//   S-type: SW
//   B-type: BEQ
//   U-type: LUI
//   J-type: JAL
//   SYSTEM: ECALL used as HALT, MRET (return from trap)
//   HALT is real: once ECALL (or a store of 1 to CSR HALT_CTRL) reaches MEM,
//   every younger instruction is squashed and the PC freezes. Older
//   instructions and the halting instruction itself still complete. Only
//   reset clears it.
//
// Correctness features:
//   1. EX/MEM and MEM/WB forwarding (in alu.sv) + same-cycle WB bypass
//      (in regfile.sv) -- most RAW hazards cost 0 cycles.
//   2. Load-use hazard stalling (in control_unit.sv) -- the one hazard
//      forwarding can't reach in time.
//   3. Control-hazard flushing for taken BEQ and JAL, resolved in EX.
//   4. x0 hardwired to zero (in regfile.sv).
//   5. Fault reporting: fault_misaligned_target (redirect target not
//      4-byte aligned), fault_mem_misaligned / fault_mem_out_of_range
//      (from data_memory.sv, via lsu.sv).
//   6. Precise TRAP on misalignment (RISC-V style): a misaligned LW/SW
//      (detected in MEM) or a misaligned branch/jump target (detected in EX)
//      no longer just raises a flag -- the faulting instruction is cancelled
//      (no register write, no store), every younger instruction is squashed,
//      csr_regs.sv records MEPC / MCAUSE / MTVAL, and the PC jumps to MTVEC.
//      MRET (resolved in MEM) jumps back to MEPC.
//        MCAUSE: 0 = jump/branch target misaligned, 4 = load misaligned,
//                6 = store misaligned.
//      Out-of-range (map hole) accesses are still flag-only.
//
// Notes (matches the diagram's "not yet wired" callouts):
//   - LW/SW are word-aligned only; misaligned/out-of-range accesses are
//     flagged, not silently corrupted.
//   - l2_cache.sv / l3_cache.sv / imc.sv exist as standalone, verified
//     modules; they are instantiated below lsu.sv (see Address map).
//
// Address map added below lsu.sv (new):
//   - An address decoder (is_csr) sits between lsu.sv and the backing
//     stores, exactly where an L2/L3 decoder would go -- lsu.sv itself is
//     untouched. Addresses >= CSR_BASE route to csr_regs.sv instead of
//     data_memory.sv, giving software a handful of memory-mapped
//     control/status registers (cycle/instruction counters, a
//     software-triggered halt, a scratch register) reached with ordinary
//     LW/SW, the same way regfile.sv's GPRs are never reached -- those stay
//     addressed only by rs1/rs2/rd.
// =============================================================================
module design_top #(
  parameter int DATA_W     = 32,
  parameter int IMEM_DEPTH = 256,
  parameter int DMEM_DEPTH = 256,
  parameter int IMC_WORDS  = 4096,
  parameter int IMC_LATENCY = 4
)(
  input  logic              clk,
  input  logic              rst_n,

  output logic              halt,
  output logic [DATA_W-1:0] pc_out,

  output logic              fault_misaligned_target,
  output logic              fault_mem_misaligned,
  output logic              fault_mem_out_of_range,
  output logic              trap_taken      // 1-cycle pulse when a trap is entered
);

  // ---------------------------------------------------------------------
  // Storage owned at top level
  // ---------------------------------------------------------------------
  logic [31:0] instr_mem [0:IMEM_DEPTH-1];
  logic [31:0] pc;
  logic [31:0] if_instr;

  assign pc_out   = pc;
  assign if_instr = instr_mem[pc[$clog2(IMEM_DEPTH)+1:2]];

  // IF/ID
  logic [31:0] if_id_pc,    if_id_pc_n;
  logic [31:0] if_id_instr, if_id_instr_n;

  // ID/EX
  logic [31:0] id_ex_pc,          id_ex_pc_n;
  logic [31:0] id_ex_rs1_data,    id_ex_rs1_data_n;
  logic [31:0] id_ex_rs2_data,    id_ex_rs2_data_n;
  logic [31:0] id_ex_imm_sext,    id_ex_imm_sext_n;
  logic [4:0]  id_ex_rs1_addr,    id_ex_rs1_addr_n;
  logic [4:0]  id_ex_rs2_addr,    id_ex_rs2_addr_n;
  logic [4:0]  id_ex_rd_addr,     id_ex_rd_addr_n;
  logic        id_ex_alu_src_imm, id_ex_alu_src_imm_n;
  logic [6:0]  id_ex_opcode,      id_ex_opcode_n;
  logic [2:0]  id_ex_funct3,      id_ex_funct3_n;
  logic [6:0]  id_ex_funct7,      id_ex_funct7_n;
  logic        id_ex_reg_write,   id_ex_reg_write_n;
  logic        id_ex_mem_write,   id_ex_mem_write_n;
  logic        id_ex_mem_to_reg,  id_ex_mem_to_reg_n;
  logic        id_ex_is_branch,   id_ex_is_branch_n;
  logic        id_ex_is_jump,     id_ex_is_jump_n;
  logic        id_ex_is_halt,     id_ex_is_halt_n;
  logic        id_ex_is_mret,     id_ex_is_mret_n;

  // EX/MEM
  logic [31:0] ex_mem_alu_result, ex_mem_alu_result_n;
  logic [31:0] ex_mem_store_data, ex_mem_store_data_n;
  logic [4:0]  ex_mem_rd_addr,    ex_mem_rd_addr_n;
  logic        ex_mem_reg_write,  ex_mem_reg_write_n;
  logic        ex_mem_mem_write,  ex_mem_mem_write_n;
  logic        ex_mem_mem_to_reg, ex_mem_mem_to_reg_n;
  logic        ex_mem_is_halt,    ex_mem_is_halt_n;
  logic        ex_mem_is_mret,    ex_mem_is_mret_n;
  logic [31:0] ex_mem_pc,         ex_mem_pc_n;      // PC of the instruction in MEM (for MEPC)

  // MEM/WB
  logic [31:0] mem_wb_write_data, mem_wb_write_data_n;
  logic [4:0]  mem_wb_rd_addr,    mem_wb_rd_addr_n;
  logic        mem_wb_reg_write,  mem_wb_reg_write_n;

  // ---------------------------------------------------------------------
  // control_unit.sv -- ID decode + hazard/branch resolution
  // ---------------------------------------------------------------------
  logic [6:0]  cu_opcode;
  logic [2:0]  cu_funct3;
  logic [6:0]  cu_funct7;
  logic [4:0]  cu_rs1_addr, cu_rs2_addr, cu_rd_addr;
  logic        cu_reg_write, cu_mem_write, cu_mem_to_reg;
  logic        cu_is_branch, cu_is_jump, cu_is_halt, cu_is_mret;
  logic [31:0] cu_imm_sext;
  logic        cu_alu_src_imm;
  logic        stall_load_use, branch_taken, jump_taken, redirect_taken;
  logic [31:0] redirect_target;
  logic        misaligned_target;
  logic        pc_write;
  logic [31:0] pc_next;
  logic        alu_zero;

  control_unit #(.DATA_W(DATA_W)) u_control_unit (
    .if_id_instr        (if_id_instr),
    .pc                 (pc),
    .id_ex_opcode       (id_ex_opcode),
    .id_ex_rd_addr      (id_ex_rd_addr),
    .id_ex_reg_write    (id_ex_reg_write),
    .id_ex_is_branch    (id_ex_is_branch),
    .id_ex_is_jump      (id_ex_is_jump),
    .id_ex_pc           (id_ex_pc),
    .id_ex_imm_sext     (id_ex_imm_sext),
    .alu_zero           (alu_zero),

    .id_opcode          (cu_opcode),
    .funct3             (cu_funct3),
    .funct7             (cu_funct7),
    .rs1_addr           (cu_rs1_addr),
    .rs2_addr           (cu_rs2_addr),
    .rd_addr            (cu_rd_addr),
    .id_reg_write       (cu_reg_write),
    .mem_write          (cu_mem_write),
    .mem_to_reg         (cu_mem_to_reg),
    .is_branch          (cu_is_branch),
    .is_jump            (cu_is_jump),
    .is_halt            (cu_is_halt),
    .is_mret            (cu_is_mret),
    .id_imm_sext        (cu_imm_sext),
    .alu_src_imm        (cu_alu_src_imm),

    .stall_load_use     (stall_load_use),
    .branch_taken       (branch_taken),
    .jump_taken         (jump_taken),
    .redirect_taken     (redirect_taken),
    .redirect_target    (redirect_target),
    .misaligned_target  (misaligned_target),
    .pc_write           (pc_write),
    .pc_next            (pc_next)
  );

  // ---------------------------------------------------------------------
  // regfile.sv -- ID read / WB write
  // ---------------------------------------------------------------------
  logic [31:0] rf_rs1_data, rf_rs2_data;

  regfile #(.DATA_W(DATA_W)) u_regfile (
    .clk           (clk),
    .rst_n         (rst_n),
    .rs1_addr      (cu_rs1_addr),
    .rs2_addr      (cu_rs2_addr),
    .rs1_data      (rf_rs1_data),
    .rs2_data      (rf_rs2_data),
    .wb_rd_addr    (mem_wb_rd_addr),
    .wb_write_data (mem_wb_write_data),
    .wb_reg_write  (mem_wb_reg_write)
  );

  // ---------------------------------------------------------------------
  // alu.sv -- EX
  // ---------------------------------------------------------------------
  logic [31:0] alu_result, store_data;

  alu #(.DATA_W(DATA_W)) u_alu (
    .id_ex_rs1_data    (id_ex_rs1_data),
    .id_ex_rs2_data    (id_ex_rs2_data),
    .id_ex_rs1_addr    (id_ex_rs1_addr),
    .id_ex_rs2_addr    (id_ex_rs2_addr),
    .id_ex_imm_sext    (id_ex_imm_sext),
    .id_ex_alu_src_imm (id_ex_alu_src_imm),
    .id_ex_opcode      (id_ex_opcode),
    .id_ex_funct3      (id_ex_funct3),
    .id_ex_funct7      (id_ex_funct7),
    .id_ex_pc          (id_ex_pc),

    .ex_mem_alu_result (ex_mem_alu_result),
    .ex_mem_reg_write  (ex_mem_reg_write),
    .ex_mem_rd_addr    (ex_mem_rd_addr),
    .ex_mem_mem_to_reg (ex_mem_mem_to_reg),

    .mem_wb_mem_result (mem_wb_write_data),
    .mem_wb_reg_write  (mem_wb_reg_write),
    .mem_wb_rd_addr    (mem_wb_rd_addr),

    .alu_result        (alu_result),
    .alu_zero          (alu_zero),
    .store_data        (store_data)
  );

  // ---------------------------------------------------------------------
  // lsu.sv + data_memory.sv / csr_regs.sv -- MEM
  // ---------------------------------------------------------------------
  logic [31:0] cache_addr, cache_wdata, cache_rdata;
  logic        cache_wr_en, cache_rd_en, cache_req_ready, cache_resp_valid;
  logic        cache_misaligned, cache_out_of_range;
  logic [31:0] mem_result;
  logic        mem_stall, mem_misaligned, mem_out_of_range;

  lsu #(.DATA_W(DATA_W)) u_lsu (
    .ex_mem_alu_result  (ex_mem_alu_result),
    .ex_mem_store_data  (ex_mem_store_data),
    .ex_mem_mem_write   (ex_mem_mem_write),
    .ex_mem_mem_to_reg  (ex_mem_mem_to_reg),

    .cache_addr         (cache_addr),
    .cache_wdata        (cache_wdata),
    .cache_wr_en        (cache_wr_en),
    .cache_rd_en        (cache_rd_en),
    .cache_rdata        (cache_rdata),
    .cache_req_ready    (cache_req_ready),
    .cache_resp_valid   (cache_resp_valid),
    .cache_misaligned   (cache_misaligned),
    .cache_out_of_range (cache_out_of_range),

    .mem_result         (mem_result),
    .mem_stall          (mem_stall),
    .mem_misaligned     (mem_misaligned),
    .mem_out_of_range   (mem_out_of_range)
  );

  // ---- address decoder: picks data_memory.sv or csr_regs.sv, same role
  // as apb_decoder.sv picking a peripheral by address range. lsu.sv has
  // no idea this split exists -- it still just drives one cache_* port. ----
  localparam logic [31:0] CSR_BASE  = 32'hFFFF_FF00;
  localparam int          CSR_WORDS = 8;

  logic        is_csr;
  logic [31:0] dmem_rdata, csr_rdata;
  logic        dmem_req_ready, dmem_resp_valid, dmem_misaligned, dmem_out_of_range;
  logic        csr_req_ready,  csr_resp_valid,  csr_misaligned,  csr_out_of_range;
  logic        instr_retired, sw_halt_req;

  // ---------------------------------------------------------------------
  // Trap control (precise exceptions for misalignment + MRET)
  //   trap_mem : load/store in MEM has a misaligned address
  //   mret_mem : MRET is in MEM -> PC <= MEPC (resolved in MEM, so a SW to
  //              MEPC one instruction earlier has already landed)
  //   trap_ex  : branch/jump in EX has a misaligned target
  // Priority (oldest instruction wins): trap_mem > mret_mem > trap_ex.
  // ---------------------------------------------------------------------
  logic        trap_mem, mret_mem, trap_ex, take_trap, flush_front, squash_ex_mem;
  logic        trap_csr_valid;
  logic        halt_event, halting;
  logic [31:0] trap_cause, trap_epc, trap_tval, mtvec_val, mepc_val;

  assign trap_mem  = mem_misaligned;
  assign mret_mem  = ex_mem_is_mret;
  // Halt: the halting instruction (ECALL, or the SW to HALT_CTRL) is in MEM.
  // From that cycle on -- and for ever after, until reset -- everything
  // younger is squashed and the PC holds.
  assign halt_event = (ex_mem_is_halt || sw_halt_req) && !mem_stall;
  assign halting    = halt || halt_event;

  assign trap_ex   = misaligned_target && !trap_mem && !mret_mem && !halting;
  assign take_trap = trap_mem || trap_ex;

  // Younger stages are cancelled on any trap or MRET; the normal branch/jump
  // redirect (redirect_taken) also flushes IF/ID and ID/EX as before.
  assign flush_front   = take_trap || mret_mem || redirect_taken || halting;
  // The instruction entering MEM next cycle is cancelled when it is younger
  // than the trap/MRET in MEM, or when it is the faulting jump itself.
  assign squash_ex_mem = trap_mem || mret_mem || trap_ex || halting;

  assign trap_csr_valid = take_trap && !mem_stall;
  assign trap_cause = trap_mem ? (ex_mem_mem_write ? 32'd6 : 32'd4) : 32'd0;
  assign trap_epc   = trap_mem ? ex_mem_pc : id_ex_pc;
  assign trap_tval  = trap_mem ? ex_mem_alu_result : redirect_target;

  // Three regions, in address order:
  //   [0, DMEM_DEPTH*4)           L1  -> data_memory.sv (on-chip data RAM)
  //   [DMEM_DEPTH*4, IMC_WORDS*4) beyond L1 -> L2 -> L3 -> AXI-Lite -> iMC
  //   [CSR_BASE, ...)             csr_regs.sv
  // Anything else is a hole in the map and reports out-of-range.
  logic        is_l1, is_ext, is_gap, mem_access, ext_misaligned;
  assign is_csr     = (cache_addr >= CSR_BASE);
  assign is_l1      = !is_csr && (cache_addr < DMEM_DEPTH * 4);
  assign is_ext     = !is_csr && !is_l1 && (cache_addr < IMC_WORDS * 4);
  assign is_gap     = !is_csr && !is_l1 && !is_ext;
  assign mem_access = cache_wr_en || cache_rd_en;
  assign ext_misaligned = mem_access && !is_csr && !is_l1 && (cache_addr[1:0] != 2'b00);

  // A real instruction reached EX/MEM this cycle -- not a bubble, and not a
  // repeat of an instruction held in MEM by mem_stall.
  assign instr_retired = (ex_mem_reg_write || ex_mem_mem_write || ex_mem_is_halt) && !mem_stall && !trap_mem;

  data_memory #(.DATA_W(DATA_W), .DMEM_DEPTH(DMEM_DEPTH)) u_data_memory (
    .clk          (clk),
    .rst_n        (rst_n),
    .addr         (cache_addr),
    .wdata        (cache_wdata),
    .wr_en        (cache_wr_en && is_l1),
    .rd_en        (cache_rd_en && is_l1),
    .rdata        (dmem_rdata),
    .req_ready    (dmem_req_ready),
    .resp_valid   (dmem_resp_valid),
    .misaligned   (dmem_misaligned),
    .out_of_range (dmem_out_of_range)
  );

  csr_regs #(.DATA_W(DATA_W), .CSR_BASE(CSR_BASE), .CSR_WORDS(CSR_WORDS)) u_csr_regs (
    .clk           (clk),
    .rst_n         (rst_n),
    .addr          (cache_addr),
    .wdata         (cache_wdata),
    .wr_en         (cache_wr_en && is_csr),
    .rd_en         (cache_rd_en && is_csr),
    .rdata         (csr_rdata),
    .req_ready     (csr_req_ready),
    .resp_valid    (csr_resp_valid),
    .misaligned    (csr_misaligned),
    .out_of_range  (csr_out_of_range),
    .instr_retired (instr_retired),
    .sw_halt_req   (sw_halt_req),
    .trap_valid    (trap_csr_valid),
    .trap_cause    (trap_cause),
    .trap_epc      (trap_epc),
    .trap_tval     (trap_tval),
    .mtvec_o       (mtvec_val),
    .mepc_o        (mepc_val)
  );

  // ---- L2 -> L3 -> AXI-Lite -> iMC. Requests are issued only for aligned,
  // in-map addresses; the pipeline holds the request in MEM until
  // ext_resp_valid (see mem_stall freeze below). ----
  logic [31:0] ext_rdata;
  logic        ext_req_ready, ext_resp_valid;
  logic        ext_wr_en, ext_rd_en;
  assign ext_wr_en = cache_wr_en && is_ext && !ext_misaligned;
  assign ext_rd_en = cache_rd_en && is_ext && !ext_misaligned;

  logic [31:0] l2_addr, l2_wdata, l2_rdata;
  logic        l2_wr_en, l2_rd_en, l2_req_ready, l2_resp_valid;

  l2_cache #(.LINES(64)) u_l2_cache (
    .clk (clk), .rst_n (rst_n),
    .up_addr       (cache_addr),
    .up_wdata      (cache_wdata),
    .up_wr_en      (ext_wr_en),
    .up_rd_en      (ext_rd_en),
    .up_rdata      (ext_rdata),
    .up_req_ready  (ext_req_ready),
    .up_resp_valid (ext_resp_valid),
    .addr          (l2_addr),
    .wdata         (l2_wdata),
    .wr_en         (l2_wr_en),
    .rd_en         (l2_rd_en),
    .rdata         (l2_rdata),
    .req_ready     (l2_req_ready),
    .resp_valid    (l2_resp_valid)
  );

  logic [31:0] axi_awaddr, axi_wdata, axi_araddr, axi_rdata;
  logic [3:0]  axi_wstrb;
  logic [1:0]  axi_bresp, axi_rresp;
  logic        axi_awvalid, axi_awready, axi_wvalid, axi_wready;
  logic        axi_bvalid, axi_bready, axi_arvalid, axi_arready, axi_rvalid, axi_rready;

  l3_cache #(.LINES(128)) u_l3_cache (
    .clk (clk), .rst_n (rst_n),
    .up_addr       (l2_addr),
    .up_wdata      (l2_wdata),
    .up_wr_en      (l2_wr_en),
    .up_rd_en      (l2_rd_en),
    .up_rdata      (l2_rdata),
    .up_req_ready  (l2_req_ready),
    .up_resp_valid (l2_resp_valid),
    .m_awaddr (axi_awaddr), .m_awvalid (axi_awvalid), .m_awready (axi_awready),
    .m_wdata  (axi_wdata),  .m_wstrb   (axi_wstrb),   .m_wvalid  (axi_wvalid), .m_wready (axi_wready),
    .m_bresp  (axi_bresp),  .m_bvalid  (axi_bvalid),  .m_bready  (axi_bready),
    .m_araddr (axi_araddr), .m_arvalid (axi_arvalid), .m_arready (axi_arready),
    .m_rdata  (axi_rdata),  .m_rresp   (axi_rresp),   .m_rvalid  (axi_rvalid), .m_rready (axi_rready)
  );

  imc #(.WORDS(IMC_WORDS), .LATENCY(IMC_LATENCY)) u_imc (
    .clk (clk), .rst_n (rst_n),
    .s_awaddr (axi_awaddr), .s_awvalid (axi_awvalid), .s_awready (axi_awready),
    .s_wdata  (axi_wdata),  .s_wstrb   (axi_wstrb),   .s_wvalid  (axi_wvalid), .s_wready (axi_wready),
    .s_bresp  (axi_bresp),  .s_bvalid  (axi_bvalid),  .s_bready  (axi_bready),
    .s_araddr (axi_araddr), .s_arvalid (axi_arvalid), .s_arready (axi_arready),
    .s_rdata  (axi_rdata),  .s_rresp   (axi_rresp),   .s_rvalid  (axi_rvalid), .s_rready (axi_rready)
  );

  assign cache_rdata        = is_csr ? csr_rdata : is_l1 ? dmem_rdata : ext_rdata;
  assign cache_req_ready    = is_csr ? csr_req_ready : is_l1 ? dmem_req_ready : 1'b1;
  assign cache_resp_valid   = is_csr ? csr_resp_valid
                            : is_l1  ? dmem_resp_valid
                            : is_ext ? (ext_resp_valid || ext_misaligned)
                            :          1'b1;
  assign cache_misaligned   = is_csr ? csr_misaligned
                            : is_l1  ? dmem_misaligned
                            :          ext_misaligned;
  assign cache_out_of_range = is_csr ? csr_out_of_range
                            : is_l1  ? dmem_out_of_range
                            :          (is_gap && mem_access);

  // ---------------------------------------------------------------------
  // IF/ID pipeline register
  // ---------------------------------------------------------------------
  logic if_id_write;
  assign if_id_write = (!stall_load_use) || flush_front;

  always_comb begin
    if (flush_front) begin
      if_id_pc_n    = 32'b0;
      if_id_instr_n = 32'b0;
    end else if (stall_load_use) begin
      if_id_pc_n    = if_id_pc;
      if_id_instr_n = if_id_instr;
    end else begin
      if_id_pc_n    = pc;
      if_id_instr_n = if_instr;
    end
  end

  // ---------------------------------------------------------------------
  // ID/EX pipeline register (bubbled on stall or redirect)
  // ---------------------------------------------------------------------
  logic id_ex_bubble;
  assign id_ex_bubble = stall_load_use || flush_front;

  always_comb begin
    if (id_ex_bubble) begin
      id_ex_pc_n          = 32'b0;
      id_ex_rs1_data_n    = 32'b0;
      id_ex_rs2_data_n    = 32'b0;
      id_ex_imm_sext_n    = 32'b0;
      id_ex_rs1_addr_n    = 5'b0;
      id_ex_rs2_addr_n    = 5'b0;
      id_ex_rd_addr_n     = 5'b0;
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
      id_ex_is_mret_n     = 1'b0;
    end else begin
      id_ex_pc_n          = if_id_pc;
      id_ex_rs1_data_n    = rf_rs1_data;
      id_ex_rs2_data_n    = rf_rs2_data;
      id_ex_imm_sext_n    = cu_imm_sext;
      id_ex_rs1_addr_n    = cu_rs1_addr;
      id_ex_rs2_addr_n    = cu_rs2_addr;
      id_ex_rd_addr_n     = cu_rd_addr;
      id_ex_alu_src_imm_n = cu_alu_src_imm;
      id_ex_opcode_n      = cu_opcode;
      id_ex_funct3_n      = cu_funct3;
      id_ex_funct7_n      = cu_funct7;
      id_ex_reg_write_n   = cu_reg_write;
      id_ex_mem_write_n   = cu_mem_write;
      id_ex_mem_to_reg_n  = cu_mem_to_reg;
      id_ex_is_branch_n   = cu_is_branch;
      id_ex_is_jump_n     = cu_is_jump;
      id_ex_is_halt_n     = cu_is_halt;
      id_ex_is_mret_n     = cu_is_mret;
    end
  end

  // ---------------------------------------------------------------------
  // EX/MEM pipeline register (unconditional -- no control hazard reaches
  // this far without already having been bubbled at ID/EX)
  // ---------------------------------------------------------------------
  always_comb begin
    ex_mem_alu_result_n = alu_result;
    ex_mem_store_data_n = store_data;
    ex_mem_rd_addr_n    = id_ex_rd_addr;
    ex_mem_reg_write_n  = id_ex_reg_write;
    ex_mem_mem_write_n  = id_ex_mem_write;
    ex_mem_mem_to_reg_n = id_ex_mem_to_reg;
    ex_mem_is_halt_n    = id_ex_is_halt;
    ex_mem_is_mret_n    = id_ex_is_mret;
    ex_mem_pc_n         = id_ex_pc;
    if (squash_ex_mem) begin   // cancelled by a trap / MRET / faulting jump
      ex_mem_alu_result_n = 32'b0;
      ex_mem_store_data_n = 32'b0;
      ex_mem_rd_addr_n    = 5'b0;
      ex_mem_reg_write_n  = 1'b0;
      ex_mem_mem_write_n  = 1'b0;
      ex_mem_mem_to_reg_n = 1'b0;
      ex_mem_is_halt_n    = 1'b0;
      ex_mem_is_mret_n    = 1'b0;
      ex_mem_pc_n         = 32'b0;
    end
  end

  // ---------------------------------------------------------------------
  // MEM/WB pipeline register
  // ---------------------------------------------------------------------
  always_comb begin
    mem_wb_write_data_n = mem_result;
    mem_wb_rd_addr_n    = ex_mem_rd_addr;
    mem_wb_reg_write_n  = ex_mem_reg_write && !trap_mem; // faulting load/store never writes rd
  end

  // ---------------------------------------------------------------------
  // Sequential state update
  // ---------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= 32'b0;

      if_id_pc    <= 32'b0;
      if_id_instr <= 32'b0;

      id_ex_pc          <= 32'b0;
      id_ex_rs1_data    <= 32'b0;
      id_ex_rs2_data    <= 32'b0;
      id_ex_imm_sext    <= 32'b0;
      id_ex_rs1_addr    <= 5'b0;
      id_ex_rs2_addr    <= 5'b0;
      id_ex_rd_addr     <= 5'b0;
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
      id_ex_is_mret     <= 1'b0;

      ex_mem_alu_result <= 32'b0;
      ex_mem_store_data <= 32'b0;
      ex_mem_rd_addr    <= 5'b0;
      ex_mem_reg_write  <= 1'b0;
      ex_mem_mem_write  <= 1'b0;
      ex_mem_mem_to_reg <= 1'b0;
      ex_mem_is_halt    <= 1'b0;
      ex_mem_is_mret    <= 1'b0;
      ex_mem_pc         <= 32'b0;

      mem_wb_write_data <= 32'b0;
      mem_wb_rd_addr    <= 5'b0;
      mem_wb_reg_write  <= 1'b0;

      halt                    <= 1'b0;
      fault_misaligned_target <= 1'b0;
      fault_mem_misaligned    <= 1'b0;
      fault_mem_out_of_range  <= 1'b0;
      trap_taken              <= 1'b0;
    end else if (!mem_stall) begin
      // mem_stall freezes PC and every pipeline register (including MEM/WB, so
      // forwarding sources stay valid) until the hierarchy responds.
      // PC mux: trap entry > MRET > normal (stall / redirect / +4)
      if (halting)         pc <= pc;          // halted: PC frozen
      else if (take_trap)  pc <= mtvec_val;
      else if (mret_mem)   pc <= mepc_val;
      else if (pc_write)   pc <= pc_next;

      if (if_id_write) begin
        if_id_pc    <= if_id_pc_n;
        if_id_instr <= if_id_instr_n;
      end

      id_ex_pc          <= id_ex_pc_n;
      id_ex_rs1_data    <= id_ex_rs1_data_n;
      id_ex_rs2_data    <= id_ex_rs2_data_n;
      id_ex_imm_sext    <= id_ex_imm_sext_n;
      id_ex_rs1_addr    <= id_ex_rs1_addr_n;
      id_ex_rs2_addr    <= id_ex_rs2_addr_n;
      id_ex_rd_addr     <= id_ex_rd_addr_n;
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
      id_ex_is_mret     <= id_ex_is_mret_n;

      ex_mem_alu_result <= ex_mem_alu_result_n;
      ex_mem_store_data <= ex_mem_store_data_n;
      ex_mem_rd_addr    <= ex_mem_rd_addr_n;
      ex_mem_reg_write  <= ex_mem_reg_write_n;
      ex_mem_mem_write  <= ex_mem_mem_write_n;
      ex_mem_mem_to_reg <= ex_mem_mem_to_reg_n;
      ex_mem_is_halt    <= ex_mem_is_halt_n;
      ex_mem_is_mret    <= ex_mem_is_mret_n;
      ex_mem_pc         <= ex_mem_pc_n;

      mem_wb_write_data <= mem_wb_write_data_n;
      mem_wb_rd_addr    <= mem_wb_rd_addr_n;
      mem_wb_reg_write  <= mem_wb_reg_write_n;

      // Halt asserts once the ECALL instruction has reached MEM, OR once
      // software writes 1 to csr_regs.sv's HALT_CTRL bit 0, and stays
      // asserted (sticky, cleared only by reset). The same event squashes
      // all younger instructions and freezes the PC (see `halting`).
      if (halt_event) halt <= 1'b1;

      // Fault outputs, registered the cycle after each is detected.
      fault_misaligned_target <= misaligned_target && !halting;
      fault_mem_misaligned    <= mem_misaligned;
      fault_mem_out_of_range  <= mem_out_of_range;
      trap_taken              <= take_trap;
    end
  end

endmodule

