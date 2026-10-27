// =============================================================================
// cpu_probe_if.sv
// Three read-only "probe" interfaces for the passive agents. They are wired to
// internal DUT nets by continuous assigns in tb_top.sv (the only place that
// knows DUT net names), so the monitors never contain a DUT path.
//   retire_if : the instruction leaving the MEM stage this cycle
//   mem_if    : the LSU request/response, before it is routed to L1/CSR/L2
//   axi_if    : the AXI-Lite port between L3 and the iMC
// The status agent needs no probe interface: it uses the DUT ports in cpu_if.
// =============================================================================
interface retire_if (input logic clk);
  logic        retired;      // a real instruction (not a bubble / stalled repeat) retires now
  logic [31:0] pc;           // its PC
  logic [4:0]  rd;           // destination register
  logic        reg_write;    // it writes rd
  logic [31:0] result;       // value written to rd (load data or ALU result)
  logic        is_store;
  logic [31:0] store_addr;
  logic [31:0] store_data;
  logic        is_halt;      // it is the ECALL
endinterface

interface mem_if (input logic clk);
  logic [31:0] addr;         // effective address from the LSU
  logic [31:0] wdata;
  logic        wr_en;
  logic        rd_en;
  logic [31:0] rdata;        // value returned to the pipeline
  logic        stall;        // mem_stall: pipeline frozen waiting for L2/L3/iMC
  logic        misaligned;
  logic        out_of_range;
  logic        is_l1, is_csr, is_ext, is_gap;   // address-map region of this access
  logic        l2_hit;       // L2 tag match for the current address (direct-mapped, 64 lines)
  logic        l3_hit;       // L3 tag match for the current address (direct-mapped, 128 lines)
endinterface

// -----------------------------------------------------------------------------
// axi_if : the AXI-Lite port between L3 and the iMC (signals only).
// The protocol assertions are NOT here: they are in axi_sva.sv (module axi_sva), which watches this
// interface and adds to sva_fails; the AXI monitor turns a non-zero count into a UVM_ERROR.
// -----------------------------------------------------------------------------
interface axi_if (input logic clk, input logic rst_n);
  logic        awvalid, awready;
  logic [31:0] awaddr;
  logic        wvalid, wready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        bvalid, bready;
  logic [1:0]  bresp;
  logic        arvalid, arready;
  logic [31:0] araddr;
  logic        rvalid, rready;
  logic [31:0] rdata;
  logic [1:0]  rresp;

  // Failure count of the protocol assertions. The assertions themselves are in axi_sva.sv
  // (module axi_sva, instantiated next to this interface in tb_top.sv); they add to this counter.
  int unsigned sva_fails = 0;
endinterface
