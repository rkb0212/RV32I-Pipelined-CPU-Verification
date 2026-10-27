// =============================================================================
// data_memory.sv
// Used in: MEM stage, downstream of lsu.sv. This is "L1" in the block
//   diagram -- a flat, single-cycle backing store with no tag/valid logic
//   of its own (that's what l2_cache.sv adds, standalone, not yet spliced
//   in here).
// How it works: word-addressed array. req_ready/resp_valid are hardwired to
//   1 because every access completes in the same cycle it's issued -- they
//   exist as real ports (matching the req/resp shape l2_cache.sv's upstream
//   port also uses) so this block could be swapped for something with real
//   latency without changing lsu.sv's interface.
// Why it's used: LW/SW are word-aligned only in this subset, so misaligned
//   and out-of-range are flagged combinationally for lsu.sv to report as
//   faults, instead of either silently corrupting data or crashing sim.
// =============================================================================
module data_memory #(
  parameter int DATA_W    = 32,
  parameter int DMEM_DEPTH = 256
)(
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic [DATA_W-1:0]     addr,
  input  logic [DATA_W-1:0]     wdata,
  input  logic                  wr_en,
  input  logic                  rd_en,
  output logic [DATA_W-1:0]     rdata,
  output logic                  req_ready,
  output logic                  resp_valid,
  output logic                  misaligned,
  output logic                  out_of_range
);

  logic [DATA_W-1:0] mem [0:DMEM_DEPTH-1];

  localparam int IDX_W = $clog2(DMEM_DEPTH);

  wire [IDX_W-1:0] word_idx = addr[IDX_W+1:2];
  wire             access   = wr_en || rd_en;

  assign req_ready    = 1'b1; // single-cycle L1, always ready
  assign resp_valid   = 1'b1; // response is available same cycle as request
  assign misaligned   = access && (addr[1:0] != 2'b00);
  assign out_of_range = access && ((addr >> 2) >= DMEM_DEPTH);

  assign rdata = mem[word_idx];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < DMEM_DEPTH; i++) mem[i] <= '0;
    end else if (wr_en && !misaligned && !out_of_range) begin
      mem[word_idx] <= wdata;
    end
  end

endmodule
