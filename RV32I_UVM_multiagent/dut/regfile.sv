// =============================================================================
// regfile.sv
// Used in: ID stage (read) and WB stage (write) of design_top.sv.
// How it works: 32 x 32-bit array, x0 hardwired to zero. Read ports are
//   combinational with a same-cycle write-back bypass: if the instruction
//   currently retiring in WB is writing the same register this cycle's ID
//   read is asking for, the fresh value is forwarded straight out instead
//   of the stale value still sitting in the array (avoids a 1-cycle stall
//   for the RAW hazard that would otherwise appear for the very next
//   instruction after a 3-apart producer reaches WB).
// Why it's used: this is the split-out register-file block shown in the
//   block diagram, matching the ports drawn there.
// =============================================================================
module regfile #(
  parameter int DATA_W = 32
)(
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic [4:0]            rs1_addr,
  input  logic [4:0]            rs2_addr,
  output logic [DATA_W-1:0]     rs1_data,
  output logic [DATA_W-1:0]     rs2_data,

  input  logic [4:0]            wb_rd_addr,
  input  logic [DATA_W-1:0]     wb_write_data,
  input  logic                  wb_reg_write
);

  logic [DATA_W-1:0] regs [0:31];

  // Same-cycle WB bypass on the read ports.
  always_comb begin
    if (rs1_addr == 5'd0)
      rs1_data = '0;
    else if (wb_reg_write && wb_rd_addr == rs1_addr)
      rs1_data = wb_write_data;
    else
      rs1_data = regs[rs1_addr];

    if (rs2_addr == 5'd0)
      rs2_data = '0;
    else if (wb_reg_write && wb_rd_addr == rs2_addr)
      rs2_data = wb_write_data;
    else
      rs2_data = regs[rs2_addr];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 32; i++) regs[i] <= '0;
    end else begin
      if (wb_reg_write && wb_rd_addr != 5'd0)
        regs[wb_rd_addr] <= wb_write_data;
      regs[0] <= '0;
    end
  end

endmodule

