// =============================================================================
// cpu_mem_agent.sv   PASSIVE
// Watches the LSU memory request (mem_if) and publishes one mem_item per
// completed access: address, data, which region served it (L1 / CSR / EXT /
// GAP) and how many cycles mem_stall held the pipeline. Phase 3 checks the
// routing and the 0 / 4 / 7-cycle stall counts.
// Contains: mem_item, cpu_mem_monitor, cpu_mem_agent.
// =============================================================================
class mem_item extends uvm_sequence_item;
  `uvm_object_utils(mem_item)

  int unsigned program_id, cycle, stall_cycles;
  bit [31:0]   addr, data;          // data = store data, or the loaded value
  bit          is_write, misaligned, out_of_range;
  string       route;               // "L1" / "CSR" / "EXT" / "GAP"
  bit          l2_hit, l3_hit;      // tag matches seen on the FIRST cycle of the access
  string       level;               // EXT loads: "L2" / "L3" / "IMC" (who served it); EXT stores: "WR"; else ""

  function new(string name = "mem_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("prog %0d cyc %0d %s %s%s addr=0x%08h data=0x%08h stall=%0d%s%s",
      program_id, cycle, is_write ? "SW" : "LW", route, (level == "") ? "" : {"/", level}, addr, data, stall_cycles,
      misaligned ? " MISALIGNED" : "", out_of_range ? " OUT_OF_RANGE" : "");
  endfunction
endclass

class cpu_mem_monitor extends uvm_component;
  `uvm_component_utils(cpu_mem_monitor)

  virtual cpu_if  vif;
  virtual mem_if  pvif;
  uvm_analysis_port #(mem_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual cpu_if)::get(this, "", "vif", vif))
      `uvm_fatal("MEM_MON", "virtual interface 'vif' not found in config_db")
    if (!uvm_config_db#(virtual mem_if)::get(this, "", "mem_vif", pvif))
      `uvm_fatal("MEM_MON", "virtual interface 'mem_vif' not found in config_db")
  endfunction

  // An access is "in flight" while wr_en/rd_en is high. mem_stall freezes the
  // pipeline, so the same access stays on the bus until stall drops; count
  // those cycles, publish on the first cycle without stall.
  task run_phase(uvm_phase phase);
    int unsigned cycle = 0, stalls = 0;
    bit          inflight = 0, first_l2 = 0, first_l3 = 0;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin cycle = 0; stalls = 0; inflight = 0; end
      else begin
        cycle++;
        // once halt is up the PC is frozen and the halting SW to HALT_CTRL (if that is how we halted)
        // stays on the bus every cycle; that is the same access repeating, not new traffic
        if (vif.halt === 1'b1) begin stalls = 0; inflight = 0; end
        else if ((pvif.wr_en === 1'b1) || (pvif.rd_en === 1'b1)) begin
          if (!inflight) begin               // first cycle of this access: sample the tag matches
            inflight = 1;  first_l2 = (pvif.l2_hit === 1'b1);  first_l3 = (pvif.l3_hit === 1'b1);
          end
          if (pvif.stall === 1'b1) stalls++;
          else begin
            mem_item it = mem_item::type_id::create("it");
            it.program_id = vif.program_id;  it.cycle = cycle;
            it.addr = pvif.addr;  it.is_write = (pvif.wr_en === 1'b1);
            it.data = it.is_write ? pvif.wdata : pvif.rdata;
            it.stall_cycles = stalls;
            it.misaligned = (pvif.misaligned === 1'b1);
            it.out_of_range = (pvif.out_of_range === 1'b1);
            it.route = (pvif.is_csr === 1'b1) ? "CSR" : (pvif.is_l1 === 1'b1) ? "L1" :
                       (pvif.is_ext === 1'b1) ? "EXT" : "GAP";
            it.l2_hit = first_l2;  it.l3_hit = first_l3;
            it.level  = "";
            if (it.route == "EXT" && !it.misaligned && !it.out_of_range)
              it.level = it.is_write ? "WR" : first_l2 ? "L2" : first_l3 ? "L3" : "IMC";
            ap.write(it);
            stalls = 0;  inflight = 0;
          end
        end else begin stalls = 0; inflight = 0; end
      end
    end
  endtask
endclass

class cpu_mem_agent extends uvm_agent;
  `uvm_component_utils(cpu_mem_agent)
  cpu_mem_monitor monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    is_active = UVM_PASSIVE;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = cpu_mem_monitor::type_id::create("monitor", this);
  endfunction
endclass
