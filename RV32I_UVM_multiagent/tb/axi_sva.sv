// =============================================================================
// axi_sva.sv   -- AXI-Lite protocol assertions for the L3 <-> iMC port
// Own file, own module: it only OBSERVES the axi_if signals (no testbench class, no test involved).
// Instantiated in tb_top.sv:   axi_sva #(...) u_axi_sva (axi_vif);
// Rules checked
//   handshake : VALID held, payload stable until READY (AW, W, AR, B, R)
//   response  : BRESP / RRESP OKAY, full write strobe, one outstanding transaction at a time
//   sequence  : B/R only after an accepted request, AW before W, response within MAX_LATENCY clocks
//   address   : word-aligned, inside ADDR_LO..ADDR_HI
//   signals   : no X/Z on any handshake wire after reset
// A failing assertion prints `ERROR @<time>: AXI_SVA <name>: ...`, adds to axi_if.sva_fails, and the
// axi agent turns that count into a UVM_ERROR (id AXI_SVA) in check_phase. The run is not stopped.
// =============================================================================
module axi_sva #(parameter logic [31:0] ADDR_LO = 32'h0000_0400,     // first external byte address
                 parameter logic [31:0] ADDR_HI = 32'h0000_4000,     // one past the last
                 parameter int          MAX_LATENCY = 24)            // clocks a request may wait for its response
                (axi_if bus);
  wire        clk = bus.clk, rst_n = bus.rst_n;
  wire        awvalid = bus.awvalid, awready = bus.awready;
  wire [31:0] awaddr  = bus.awaddr;
  wire        wvalid  = bus.wvalid,  wready  = bus.wready;
  wire [31:0] wdata   = bus.wdata;
  wire [3:0]  wstrb   = bus.wstrb;
  wire        bvalid  = bus.bvalid,  bready  = bus.bready;
  wire [1:0]  bresp   = bus.bresp;
  wire        arvalid = bus.arvalid, arready = bus.arready;
  wire [31:0] araddr  = bus.araddr;
  wire        rvalid  = bus.rvalid,  rready  = bus.rready;
  wire [31:0] rdata   = bus.rdata;
  wire [1:0]  rresp   = bus.rresp;

  function automatic void sva_fail(string msg);
    bus.sva_fails++;
    // $display, not $error: a failing assertion is counted and printed but must not stop the run,
    // so the other checkers (scoreboard, bus checker) still get to report the same fault
    $display("ERROR @%0t: %s", $time, msg);
  endfunction

  // VALID must stay high, with stable payload, until READY (AXI handshake rule)
  a_aw_hold: assert property (@(posedge clk) disable iff (!rst_n)
      awvalid && !awready |=> awvalid && $stable(awaddr))
    else sva_fail("AXI_SVA a_aw_hold: AWVALID dropped or AWADDR changed before AWREADY");
  a_w_hold: assert property (@(posedge clk) disable iff (!rst_n)
      wvalid && !wready |=> wvalid && $stable(wdata) && $stable(wstrb))
    else sva_fail("AXI_SVA a_w_hold: WVALID dropped or WDATA/WSTRB changed before WREADY");
  a_ar_hold: assert property (@(posedge clk) disable iff (!rst_n)
      arvalid && !arready |=> arvalid && $stable(araddr))
    else sva_fail("AXI_SVA a_ar_hold: ARVALID dropped or ARADDR changed before ARREADY");
  a_b_hold: assert property (@(posedge clk) disable iff (!rst_n)
      bvalid && !bready |=> bvalid && $stable(bresp))
    else sva_fail("AXI_SVA a_b_hold: BVALID dropped or BRESP changed before BREADY");
  a_r_hold: assert property (@(posedge clk) disable iff (!rst_n)
      rvalid && !rready |=> rvalid && $stable(rdata) && $stable(rresp))
    else sva_fail("AXI_SVA a_r_hold: RVALID dropped or RDATA/RRESP changed before RREADY");

  // responses must be OKAY, writes are always full words
  a_bresp_okay: assert property (@(posedge clk) disable iff (!rst_n)
      bvalid && bready |-> bresp == 2'b00)
    else sva_fail("AXI_SVA a_bresp_okay: non-OKAY write response");
  a_rresp_okay: assert property (@(posedge clk) disable iff (!rst_n)
      rvalid && rready |-> rresp == 2'b00)
    else sva_fail("AXI_SVA a_rresp_okay: non-OKAY read response");
  a_wstrb_full: assert property (@(posedge clk) disable iff (!rst_n)
      wvalid |-> wstrb == 4'hF)
    else sva_fail("AXI_SVA a_wstrb_full: partial write strobe on a word store");

  // L3 is a single-outstanding master: never a write and a read at the same time
  a_one_outstanding: assert property (@(posedge clk) disable iff (!rst_n)
      !((awvalid || wvalid || bready) && (arvalid || rready)))
    else sva_fail("AXI_SVA a_one_outstanding: write and read channels active together");


  // ---- transaction-level rules (L3 is the master, the iMC the slave) ----
  // which request halves have been accepted and are still waiting for their response
  logic aw_seen, w_seen, ar_seen;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin aw_seen <= 1'b0; w_seen <= 1'b0; ar_seen <= 1'b0; end
    else begin
      if (awvalid && awready) aw_seen <= 1'b1;
      if (wvalid  && wready)  w_seen  <= 1'b1;
      if (bvalid  && bready) begin aw_seen <= 1'b0; w_seen <= 1'b0; end
      if (arvalid && arready) ar_seen <= 1'b1;
      if (rvalid  && rready)  ar_seen <= 1'b0;
    end
  end

  // a response only exists for a request that was accepted (no spurious BVALID / RVALID)
  a_b_after_req: assert property (@(posedge clk) disable iff (!rst_n)
      bvalid |-> aw_seen && w_seen)
    else sva_fail("AXI_SVA a_b_after_req: BVALID without an accepted write address and data");
  a_r_after_req: assert property (@(posedge clk) disable iff (!rst_n)
      rvalid |-> ar_seen)
    else sva_fail("AXI_SVA a_r_after_req: RVALID without an accepted read address");

  // the L3 master sends the write address first, then the data
  a_aw_before_w: assert property (@(posedge clk) disable iff (!rst_n)
      wvalid |-> aw_seen)
    else sva_fail("AXI_SVA a_aw_before_w: WVALID before the write address was accepted");

  // every request gets its response within MAX_LATENCY clocks (a hung transaction is a failure)
  int unsigned wr_wait, rd_wait;        // clocks the oldest write / read has been waiting
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin wr_wait <= 0; rd_wait <= 0; end
    else begin
      wr_wait <= ((aw_seen || awvalid) && !(bvalid && bready)) ? wr_wait + 1 : 0;
      rd_wait <= ((ar_seen || arvalid) && !(rvalid && rready)) ? rd_wait + 1 : 0;
    end
  end
  a_wr_timeout: assert property (@(posedge clk) disable iff (!rst_n)
      wr_wait <= MAX_LATENCY)
    else sva_fail("AXI_SVA a_wr_timeout: no write response within MAX_LATENCY clocks");
  a_rd_timeout: assert property (@(posedge clk) disable iff (!rst_n)
      rd_wait <= MAX_LATENCY)
    else sva_fail("AXI_SVA a_rd_timeout: no read response within MAX_LATENCY clocks");

  // addresses are word-aligned and inside the external range
  a_awaddr_ok: assert property (@(posedge clk) disable iff (!rst_n)
      awvalid |-> (awaddr[1:0] == 2'b00) && (awaddr >= ADDR_LO) && (awaddr < ADDR_HI))
    else sva_fail("AXI_SVA a_awaddr_ok: write address unaligned or outside the external range");
  a_araddr_ok: assert property (@(posedge clk) disable iff (!rst_n)
      arvalid |-> (araddr[1:0] == 2'b00) && (araddr >= ADDR_LO) && (araddr < ADDR_HI))
    else sva_fail("AXI_SVA a_araddr_ok: read address unaligned or outside the external range");

  // no X on any handshake signal once out of reset
  a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
      !$isunknown({awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready}))
    else sva_fail("AXI_SVA a_no_x: X/Z on an AXI handshake signal");
endmodule
