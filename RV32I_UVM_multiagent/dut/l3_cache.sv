// =============================================================================
// l3_cache.sv
// Used in: LLC, below l2_cache.sv, above imc.sv.
// How it works: same policy as L2 (direct-mapped, write-through, no-write-
//   allocate, one word per line, same-cycle read hit) with 128 lines. A miss or
//   write is carried out as an AXI-Lite master transaction, one channel at a
//   time (AW -> W -> B for writes, AR -> R for reads), then answered upward for
//   one cycle in DONE. The upstream request is held for the whole transaction.
// Why it's used: the only block that speaks AXI; everything above it uses the
//   simple req/resp bus.
// =============================================================================
module l3_cache #(
  parameter int LINES = 128
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

  output logic [31:0] m_awaddr,
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  output logic        m_wvalid,
  input  logic        m_wready,
  input  logic [1:0]  m_bresp,
  input  logic        m_bvalid,
  output logic        m_bready,

  output logic [31:0] m_araddr,
  output logic        m_arvalid,
  input  logic        m_arready,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,
  input  logic        m_rvalid,
  output logic        m_rready
);
  localparam int IDX_W = $clog2(LINES);
  localparam int TAG_W = 30 - IDX_W;

  logic              valid [0:LINES-1];
  logic [TAG_W-1:0]  tag   [0:LINES-1];
  logic [31:0]       data  [0:LINES-1];

  wire [IDX_W-1:0] idx = up_addr[IDX_W+1:2];
  wire [TAG_W-1:0] tg  = up_addr[31:IDX_W+2];
  wire             hit = valid[idx] && (tag[idx] == tg);
  wire             rd_hit = up_rd_en && hit;
  wire             access = up_wr_en || up_rd_en;

  typedef enum logic [2:0] {IDLE, AW, W, B, AR, R, DONE} state_t;
  state_t state;
  logic [31:0] addr_q, wdata_q, rdata_q;
  logic        was_write;

  assign up_req_ready  = 1'b1;
  assign up_resp_valid = !access || rd_hit || (state == DONE);
  assign up_rdata      = (state == DONE) ? rdata_q : data[idx];

  assign m_awaddr  = addr_q;
  assign m_awvalid = (state == AW);
  assign m_wdata   = wdata_q;
  assign m_wstrb   = 4'hF;
  assign m_wvalid  = (state == W);
  assign m_bready  = (state == B);
  assign m_araddr  = addr_q;
  assign m_arvalid = (state == AR);
  assign m_rready  = (state == R);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE; addr_q <= '0; wdata_q <= '0; rdata_q <= '0; was_write <= 1'b0;
      for (int i = 0; i < LINES; i++) valid[i] <= 1'b0;
    end else begin
      case (state)
        IDLE: if (access && !rd_hit) begin
                addr_q <= up_addr; wdata_q <= up_wdata; was_write <= up_wr_en;
                state <= up_wr_en ? AW : AR;
              end
        AW: if (m_awready) state <= W;
        W:  if (m_wready)  state <= B;
        B:  if (m_bvalid)  state <= DONE;
        AR: if (m_arready) state <= R;
        R:  if (m_rvalid) begin rdata_q <= m_rdata; state <= DONE; end
        DONE: begin
          if (was_write) begin
            if (valid[addr_q[IDX_W+1:2]] && tag[addr_q[IDX_W+1:2]] == addr_q[31:IDX_W+2])
              data[addr_q[IDX_W+1:2]] <= wdata_q;
          end else begin
            valid[addr_q[IDX_W+1:2]] <= 1'b1;
            tag[addr_q[IDX_W+1:2]]   <= addr_q[31:IDX_W+2];
            data[addr_q[IDX_W+1:2]]  <= rdata_q;
          end
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
