// =============================================================================
// imc.sv
// Used in: bottom of the memory hierarchy, below l3_cache.sv (AXI-Lite master).
// How it works: AXI-Lite slave in front of a word-addressed backing store that
//   stands in for DDR5. Write path walks AW -> W -> B one channel per state, so
//   AWREADY and WREADY are never high together (l3_cache.sv sequences its
//   channels the same way). Read path accepts AR, waits LATENCY cycles, then
//   presents R until RREADY.
// Why it's used: the single slow block in the hierarchy; its read latency is
//   what makes mem_stall real.
// =============================================================================
module imc #(
  parameter int WORDS   = 4096,
  parameter int LATENCY = 4
)(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [31:0] s_awaddr,
  input  logic        s_awvalid,
  output logic        s_awready,
  input  logic [31:0] s_wdata,
  input  logic [3:0]  s_wstrb,
  input  logic        s_wvalid,
  output logic        s_wready,
  output logic [1:0]  s_bresp,
  output logic        s_bvalid,
  input  logic        s_bready,

  input  logic [31:0] s_araddr,
  input  logic        s_arvalid,
  output logic        s_arready,
  output logic [31:0] s_rdata,
  output logic [1:0]  s_rresp,
  output logic        s_rvalid,
  input  logic        s_rready
);
  localparam int IDX_W = $clog2(WORDS);
  logic [31:0] mem [0:WORDS-1];

  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  typedef enum logic [1:0] {R_IDLE, R_WAIT, R_RESP} rstate_t;
  wstate_t wstate;
  rstate_t rstate;
  logic [31:0] waddr_q, raddr_q;
  logic [7:0]  lat_cnt;
  localparam logic [7:0] LAT = LATENCY;

  assign s_awready = (wstate == W_IDLE);
  assign s_wready  = (wstate == W_DATA);
  assign s_bvalid  = (wstate == W_RESP);
  assign s_bresp   = 2'b00;

  assign s_arready = (rstate == R_IDLE);
  assign s_rvalid  = (rstate == R_RESP);
  assign s_rresp   = 2'b00;
  assign s_rdata   = mem[raddr_q[IDX_W+1:2]];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wstate <= W_IDLE; rstate <= R_IDLE;
      waddr_q <= '0; raddr_q <= '0; lat_cnt <= '0;
      for (int i = 0; i < WORDS; i++) mem[i] <= 32'b0;
    end else begin
      case (wstate)
        W_IDLE: if (s_awvalid) begin waddr_q <= s_awaddr; wstate <= W_DATA; end
        W_DATA: if (s_wvalid) begin
                  if (s_wstrb == 4'hF) mem[waddr_q[IDX_W+1:2]] <= s_wdata;
                  wstate <= W_RESP;
                end
        W_RESP: if (s_bready) wstate <= W_IDLE;
        default: wstate <= W_IDLE;
      endcase

      case (rstate)
        R_IDLE: if (s_arvalid) begin
                  raddr_q <= s_araddr; lat_cnt <= LAT; rstate <= R_WAIT;
                end
        R_WAIT: if (lat_cnt <= 8'd1) rstate <= R_RESP;
                else lat_cnt <= lat_cnt - 8'd1;
        R_RESP: if (s_rready) rstate <= R_IDLE;
        default: rstate <= R_IDLE;
      endcase
    end
  end
endmodule
