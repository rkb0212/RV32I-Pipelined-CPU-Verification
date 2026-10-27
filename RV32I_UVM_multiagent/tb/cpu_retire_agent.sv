// =============================================================================
// cpu_retire_agent.sv   PASSIVE
// Watches the instruction that retires from the MEM stage (retire_if) and
// publishes one retire_item per instruction. Phase 3 compares this trace with
// the golden model's, so the first wrong instruction is pinpointed, not just a
// wrong final register file.
// Contains: retire_item, cpu_retire_monitor, cpu_retire_agent.
// =============================================================================
class retire_item extends uvm_sequence_item;
  `uvm_object_utils(retire_item)

  int unsigned program_id, cycle;
  bit [31:0]   pc, result, store_addr, store_data;
  bit [4:0]    rd;
  bit          reg_write, is_store, is_halt;

  function new(string name = "retire_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("prog %0d cyc %0d pc=0x%08h %s%s%s", program_id, cycle, pc,
      reg_write ? $sformatf("x%0d<=0x%0h ", rd, result) : "",
      is_store  ? $sformatf("mem[0x%0h]<=0x%0h ", store_addr, store_data) : "",
      is_halt   ? "ECALL" : "");
  endfunction
endclass

class cpu_retire_monitor extends uvm_component;
  `uvm_component_utils(cpu_retire_monitor)

  virtual cpu_if    vif;     // clk, rst_n, program_id
  virtual retire_if pvif;    // probe
  uvm_analysis_port #(retire_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual cpu_if)::get(this, "", "vif", vif))
      `uvm_fatal("RETIRE_MON", "virtual interface 'vif' not found in config_db")
    if (!uvm_config_db#(virtual retire_if)::get(this, "", "retire_vif", pvif))
      `uvm_fatal("RETIRE_MON", "virtual interface 'retire_vif' not found in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned cycle = 0;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) cycle = 0;
      else begin
        cycle++;
        if (pvif.retired === 1'b1) begin
          retire_item it = retire_item::type_id::create("it");
          it.program_id = vif.program_id;  it.cycle = cycle;
          it.pc = pvif.pc;  it.rd = pvif.rd;  it.reg_write = pvif.reg_write;
          it.result = pvif.result;
          it.is_store = pvif.is_store;  it.store_addr = pvif.store_addr;  it.store_data = pvif.store_data;
          it.is_halt = pvif.is_halt;
          ap.write(it);
        end
      end
    end
  endtask
endclass

class cpu_retire_agent extends uvm_agent;
  `uvm_component_utils(cpu_retire_agent)
  cpu_retire_monitor monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    is_active = UVM_PASSIVE;           // no sequencer, no driver
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = cpu_retire_monitor::type_id::create("monitor", this);
  endfunction
endclass
