// =============================================================================
// csr_regs.sv
// Used in: MEM stage, address-mapped alongside data_memory.sv -- this is NOT
//   reached through rs1/rs2/rd like the GPRs in regfile.sv. It's selected by
//   an address decode in design_top.sv (the same pattern apb_decoder.sv uses
//   to pick a peripheral): any LW/SW whose effective address falls in
//   [CSR_BASE, CSR_BASE + CSR_WORDS*4) lands here instead of in
//   data_memory.sv. Software reaches it with ordinary LW/SW -- no new
//   instructions, no CSRRW/CSRRS -- it just needs the address in a register
//   first (LUI + ADDI gets any 32-bit constant in this subset).
//
// Register map (word-addressed offsets from CSR_BASE):
//   0x0  CYCLE_COUNT   RO  free-running cycle counter since reset
//   0x4  INSTR_COUNT   RO  retired-instruction counter (pulses on
//                          instr_retired, asserted by design_top.sv once per
//                          real EX/MEM instruction, not per bubble)
//   0x8  HALT_CTRL     RW  write 1 to bit 0 -> sw_halt_req pulses this same
//                          cycle; design_top.sv ORs it into the sticky halt
//                          flop ECALL already sets. Read returns the last
//                          written value.
//   0xC  SCRATCH       RW  plain read/write register, no hardware behavior --
//                          the minimal example of a control/status register.
//   0x10 MTVEC         RW  trap-handler address (word-aligned, low 2 bits
//                          forced to 0). Reset value 0.
//   0x14 MEPC          RW  PC of the faulting instruction, written by
//                          hardware when a trap is taken. Software normally
//                          does MEPC += 4 then MRET to skip the instruction.
//   0x18 MCAUSE        RO  why the trap happened: 0 = instruction address
//                          misaligned (jump/branch target), 4 = load address
//                          misaligned, 6 = store address misaligned.
//   0x1C MTVAL         RO  the bad address (misaligned load/store address, or
//                          misaligned jump target).
//
// Why it's used: demonstrates the address-mapped register pattern for
// CSR/peripheral-style registers, as distinct from regfile.sv's GPRs, which
// are never address-mapped (selected by instruction fields instead).
// =============================================================================
module csr_regs #(
  parameter int           DATA_W    = 32,
  parameter logic [31:0]  CSR_BASE  = 32'hFFFF_FF00,
  parameter int           CSR_WORDS = 8   // 32-byte window
)(
  input  logic                  clk,
  input  logic                  rst_n,

  // Same shape as data_memory.sv's port, so design_top.sv can mux between
  // the two with no change to lsu.sv.
  input  logic [DATA_W-1:0]     addr,     // full effective address from lsu.sv
  input  logic [DATA_W-1:0]     wdata,
  input  logic                  wr_en,
  input  logic                  rd_en,
  output logic [DATA_W-1:0]     rdata,
  output logic                  req_ready,
  output logic                  resp_valid,
  output logic                  misaligned,
  output logic                  out_of_range,

  // Hardware hooks design_top.sv drives / consumes.
  input  logic                  instr_retired, // pulses once per real instruction
  output logic                  sw_halt_req,   // pulses the cycle HALT_CTRL bit 0 is written 1

  // Trap hooks. design_top.sv pulses trap_valid for one cycle when a trap is
  // taken and supplies cause / faulting PC / bad address; mtvec_o and mepc_o
  // feed the PC mux (trap entry and MRET).
  input  logic                  trap_valid,
  input  logic [DATA_W-1:0]     trap_cause,
  input  logic [DATA_W-1:0]     trap_epc,
  input  logic [DATA_W-1:0]     trap_tval,
  output logic [DATA_W-1:0]     mtvec_o,
  output logic [DATA_W-1:0]     mepc_o
);

  localparam int OFF_CYCLE_COUNT = 0;
  localparam int OFF_INSTR_COUNT = 1;
  localparam int OFF_HALT_CTRL   = 2;
  localparam int OFF_SCRATCH     = 3;
  localparam int OFF_MTVEC       = 4;
  localparam int OFF_MEPC        = 5;
  localparam int OFF_MCAUSE      = 6;
  localparam int OFF_MTVAL       = 7;

  localparam int IDX_W = (CSR_WORDS <= 1) ? 1 : $clog2(CSR_WORDS);

  logic [DATA_W-1:0]  cycle_count, instr_count, scratch, halt_ctrl_reg;
  logic [DATA_W-1:0]  mtvec, mepc, mcause, mtval;
  logic [DATA_W-1:0]  offset;
  logic [IDX_W-1:0]   word_idx;
  logic               access;

  assign access       = wr_en || rd_en;
  assign offset       = addr - CSR_BASE;
  assign word_idx     = offset[IDX_W+1:2];

  assign mtvec_o      = mtvec;
  assign mepc_o       = mepc;

  assign req_ready    = 1'b1; // single-cycle, like data_memory.sv
  assign resp_valid   = 1'b1;
  assign misaligned   = access && (addr[1:0] != 2'b00);
  assign out_of_range = access && ((offset >> 2) >= CSR_WORDS);

  // Write pulse derived combinationally, same cycle as the SW -- this is
  // what lets a program halt itself without routing through ECALL.
  assign sw_halt_req = wr_en && !misaligned && !out_of_range &&
                        (word_idx == OFF_HALT_CTRL) && wdata[0];

  always_comb begin
    rdata = 32'b0;
    if (rd_en && !misaligned && !out_of_range) begin
      unique case (word_idx)
        OFF_CYCLE_COUNT: rdata = cycle_count;
        OFF_INSTR_COUNT: rdata = instr_count;
        OFF_HALT_CTRL:   rdata = halt_ctrl_reg;
        OFF_SCRATCH:     rdata = scratch;
        OFF_MTVEC:       rdata = mtvec;
        OFF_MEPC:        rdata = mepc;
        OFF_MCAUSE:      rdata = mcause;
        OFF_MTVAL:       rdata = mtval;
        default:         rdata = 32'b0;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_count   <= '0;
      instr_count   <= '0;
      scratch       <= '0;
      halt_ctrl_reg <= '0;
      mtvec         <= '0;
      mepc          <= '0;
      mcause        <= '0;
      mtval         <= '0;
    end else begin
      cycle_count <= cycle_count + 32'd1;
      if (instr_retired) instr_count <= instr_count + 32'd1;

      if (wr_en && !misaligned && !out_of_range) begin
        unique case (word_idx)
          OFF_HALT_CTRL: halt_ctrl_reg <= wdata;
          OFF_SCRATCH:   scratch       <= wdata;
          OFF_MTVEC:     mtvec         <= {wdata[DATA_W-1:2], 2'b00};
          OFF_MEPC:      mepc          <= {wdata[DATA_W-1:2], 2'b00};
          default: ; // CYCLE_COUNT / INSTR_COUNT / MCAUSE / MTVAL are read-only
        endcase
      end

      // Hardware trap entry wins over any software write the same cycle.
      if (trap_valid) begin
        mepc   <= trap_epc;
        mcause <= trap_cause;
        mtval  <= trap_tval;
      end
    end
  end

endmodule
