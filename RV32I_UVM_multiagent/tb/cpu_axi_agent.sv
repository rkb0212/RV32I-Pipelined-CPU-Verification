// =============================================================================
// cpu_axi_agent.sv   PASSIVE (active later)
// Watches the AXI-Lite port between L3 and the iMC (axi_if). One axi_item per
// write (AW/W handshake .. B) and per read (AR .. R), with the latency between
// them. The iMC is inside design_top, so nothing here can drive the bus yet;
// moving the iMC outside the DUT (an RTL change) would let this agent become
// ACTIVE with a driver and sequencer of its own.
// Contains: axi_item, cpu_axi_monitor, cpu_axi_agent.
// =============================================================================
class axi_item extends uvm_sequence_item;
  `uvm_object_utils(axi_item)

  int unsigned program_id, cycle, latency;
  bit [31:0]   addr, data;
  bit [3:0]    strb;
  bit [1:0]    resp;
  bit          is_write;

  function new(string name = "axi_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("prog %0d cyc %0d AXI %s addr=0x%08h data=0x%08h%s resp=%0d latency=%0d",
      program_id, cycle, is_write ? "WRITE" : "READ ", addr, data,
      is_write ? $sformatf(" strb=%b", strb) : "", resp, latency);
  endfunction
endclass

class cpu_axi_monitor extends uvm_component;
  `uvm_component_utils(cpu_axi_monitor)

  virtual cpu_if  vif;
  virtual axi_if  pvif;
  uvm_analysis_port #(axi_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual cpu_if)::get(this, "", "vif", vif))
      `uvm_fatal("AXI_MON", "virtual interface 'vif' not found in config_db")
    if (!uvm_config_db#(virtual axi_if)::get(this, "", "axi_vif", pvif))
      `uvm_fatal("AXI_MON", "virtual interface 'axi_vif' not found in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned cycle = 0, wlat = 0, rlat = 0;
    bit          wbusy = 0, rbusy = 0;
    bit [31:0]   w_addr = 0, w_data = 0, r_addr = 0;
    bit [3:0]    w_strb = 0;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin cycle = 0; wbusy = 0; rbusy = 0; end
      else begin
        cycle++;
        if (wbusy) wlat++;
        if (rbusy) rlat++;
        // ---- write: AW + W handshakes, then B ----
        if (pvif.awvalid === 1'b1 && pvif.awready === 1'b1) begin w_addr = pvif.awaddr; wbusy = 1; wlat = 0; end
        if (pvif.wvalid  === 1'b1 && pvif.wready  === 1'b1) begin w_data = pvif.wdata; w_strb = pvif.wstrb; end
        if (pvif.bvalid  === 1'b1 && pvif.bready  === 1'b1) begin
          axi_item it = axi_item::type_id::create("it");
          it.program_id = vif.program_id;  it.cycle = cycle;  it.is_write = 1;
          it.addr = w_addr;  it.data = w_data;  it.strb = w_strb;
          it.resp = pvif.bresp;  it.latency = wlat;
          ap.write(it);
          wbusy = 0;
        end
        // ---- read: AR handshake, then R ----
        if (pvif.arvalid === 1'b1 && pvif.arready === 1'b1) begin r_addr = pvif.araddr; rbusy = 1; rlat = 0; end
        if (pvif.rvalid  === 1'b1 && pvif.rready  === 1'b1) begin
          axi_item it = axi_item::type_id::create("it");
          it.program_id = vif.program_id;  it.cycle = cycle;  it.is_write = 0;
          it.addr = r_addr;  it.data = pvif.rdata;
          it.resp = pvif.rresp;  it.latency = rlat;
          ap.write(it);
          rbusy = 0;
        end
      end
    end
  endtask
  // The protocol assertions live in axi_sva.sv (they count into axi_if.sva_fails); a failure there must fail the UVM test.
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (pvif.sva_fails > 0)
      `uvm_error("AXI_SVA", $sformatf("%0d AXI protocol assertion failure(s) (axi_sva) (see the AXI_SVA lines above)", pvif.sva_fails))
  endfunction
endclass

class cpu_axi_agent extends uvm_agent;
  `uvm_component_utils(cpu_axi_agent)
  cpu_axi_monitor monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    is_active = UVM_PASSIVE;           // flip to ACTIVE once the iMC is outside the DUT
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = cpu_axi_monitor::type_id::create("monitor", this);
  endfunction
endclass
