// =============================================================================
// cpu_status_agent.sv   PASSIVE
// Watches the DUT's status ports (halt, pc_out, fault flags, trap_taken) through
// cpu_if and publishes one status_item per event: a halt, a trap (with MCAUSE /
// MEPC / MTVAL read back), a fault flag, or a PC that moved while halted.
// Phase 3 compares the trap CSRs with the golden model.
// Contains: status_kind_e, status_item, cpu_status_monitor, cpu_status_agent.
// =============================================================================
typedef enum { ST_HALT, ST_TRAP, ST_MISALIGN, ST_OOR, ST_MISALIGN_TARGET, ST_PC_MOVED_AFTER_HALT } status_kind_e;

class status_item extends uvm_sequence_item;
  `uvm_object_utils(status_item)

  int unsigned  program_id, cycle;
  status_kind_e kind;
  bit [31:0]    pc, mepc, mcause, mtval;   // CSR fields valid for ST_TRAP

  function new(string name = "status_item");
    super.new(name);
  endfunction

  function string convert2string();
    string s = $sformatf("prog %0d cyc %0d %s pc=0x%08h", program_id, cycle, kind.name(), pc);
    if (kind == ST_TRAP) s = {s, $sformatf(" mcause=%0d mepc=0x%0h mtval=0x%0h", mcause, mepc, mtval)};
    return s;
  endfunction
endclass

class cpu_status_monitor extends uvm_component;
  `uvm_component_utils(cpu_status_monitor)

  virtual cpu_if vif;
  uvm_analysis_port #(status_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual cpu_if)::get(this, "", "vif", vif))
      `uvm_fatal("STATUS_MON", "virtual interface 'vif' not found in config_db")
  endfunction

  function void emit(status_kind_e k, int unsigned cycle);
    status_item it = status_item::type_id::create("it");
    it.program_id = vif.program_id;  it.cycle = cycle;  it.kind = k;  it.pc = vif.pc_out;
    if (k == ST_TRAP) begin
      it.mepc = vif.read_mepc();  it.mcause = vif.read_mcause();  it.mtval = vif.read_mtval();
    end
    ap.write(it);
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned cycle = 0;
    bit          prev_halt = 0;
    bit [31:0]   prev_pc   = 0;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin cycle = 0; prev_halt = 0; end
      else begin
        cycle++;
        if (vif.halt === 1'b1 && !prev_halt) emit(ST_HALT, cycle);
        if (vif.halt === 1'b1 && prev_halt && vif.pc_out !== prev_pc) emit(ST_PC_MOVED_AFTER_HALT, cycle);
        if (vif.trap_taken === 1'b1)                emit(ST_TRAP, cycle);
        if (vif.fault_mem_misaligned === 1'b1)      emit(ST_MISALIGN, cycle);
        if (vif.fault_mem_out_of_range === 1'b1)    emit(ST_OOR, cycle);
        if (vif.fault_misaligned_target === 1'b1)   emit(ST_MISALIGN_TARGET, cycle);
        prev_halt = (vif.halt === 1'b1);
        prev_pc   = vif.pc_out;
      end
    end
  endtask
endclass

class cpu_status_agent extends uvm_agent;
  `uvm_component_utils(cpu_status_agent)
  cpu_status_monitor monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    is_active = UVM_PASSIVE;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = cpu_status_monitor::type_id::create("monitor", this);
  endfunction
endclass
