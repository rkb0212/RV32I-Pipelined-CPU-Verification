// =============================================================================
// cpu_ctrl_agent.sv   (was cpu_agent.sv)
// The ACTIVE agent and the only one with a sequencer: every sequence runs here.
//   sequencer : stock uvm_sequencer #(cpu_program), no custom class needed
//   driver    : reset, load program, release, wait for halt
//   monitor   : end-state snapshot (cpu_actual) after halt
// The four passive agents (retire / mem / axi / status) have no sequencer, so
// a sequence can never be started on them.
// =============================================================================
class cpu_ctrl_agent extends uvm_agent;
  `uvm_component_utils(cpu_ctrl_agent)

  uvm_sequencer #(cpu_program) sequencer;
  cpu_driver                   driver;
  cpu_monitor                  monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    is_active = UVM_ACTIVE;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    monitor = cpu_monitor::type_id::create("monitor", this);
    if (is_active == UVM_ACTIVE) begin
      sequencer = uvm_sequencer#(cpu_program)::type_id::create("sequencer", this);
      driver    = cpu_driver ::type_id::create("driver",  this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (is_active == UVM_ACTIVE) driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction
endclass
