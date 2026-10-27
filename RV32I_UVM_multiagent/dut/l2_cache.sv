// =============================================================================
// l2_cache.sv
// Used in: below the L1 / on-chip data memory, above l3_cache.sv.
// How it works: direct-mapped, write-through, no-write-allocate, one word per
//   line. A read hit answers in the same cycle (no stall). Everything else
//   (read miss, any write) is passed straight down to L3 with the upstream
//   request held, and the L3 response is passed straight back up; on the cycle
//   the response arrives, a read miss fills its line and a write that hits
//   updates its line. Handshake: the master holds wr_en/rd_en until
//   up_resp_valid.
// Why it's used: the L2 block in the diagram; same 7-wire req/resp shape as
//   LSU<->L1 and L2<->L3.
// =============================================================================
module l2_cache #(
  parameter int LINES = 64
)(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [31:0] up_addr,
  input  logic [31:0] up_wdata,
  input  logic        up_wr_en,
  input  logic        up_rd_en,
  output logic [31:0] up_rdata,
  output logic        up_req_ready,
  output logic        up_resp_valid,

  output logic [31:0] addr,
  output logic [31:0] wdata,
  output logic        wr_en,
  output logic        rd_en,
  input  logic [31:0] rdata,
  input  logic        req_ready,
  input  logic        resp_valid
);
  localparam int IDX_W = $clog2(LINES);
  localparam int TAG_W = 30 - IDX_W;

  logic              valid [0:LINES-1];
  logic [TAG_W-1:0]  tag   [0:LINES-1];
  logic [31:0]       data  [0:LINES-1];

  wire [IDX_W-1:0] idx = up_addr[IDX_W+1:2];
  wire [TAG_W-1:0] tg  = up_addr[31:IDX_W+2];
  wire             hit = valid[idx] && (tag[idx] == tg);
  wire             access = up_wr_en || up_rd_en;

  assign addr  = up_addr;
  assign wdata = up_wdata;
  assign wr_en = up_wr_en;
  assign rd_en = up_rd_en && !hit;

  assign up_req_ready  = 1'b1;
  assign up_resp_valid = !access || (up_rd_en && hit) || resp_valid;
  assign up_rdata      = (up_rd_en && hit) ? data[idx] : rdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < LINES; i++) valid[i] <= 1'b0;
    end else if (access && resp_valid && !(up_rd_en && hit)) begin
      if (up_rd_en) begin
        valid[idx] <= 1'b1; tag[idx] <= tg; data[idx] <= rdata;
      end else if (up_wr_en && hit) begin
        data[idx] <= up_wdata;
      end
    end
  end
endmodule
