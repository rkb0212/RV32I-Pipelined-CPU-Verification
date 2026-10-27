// =============================================================================
// cpu_env.sv
// Five agents, each with its own checker:
//   ctrl_agent   (ACTIVE)  -> cpu_scoreboard      end state, compared with the golden model
//   cpu_predictor          -> cpu_scoreboard      expected end state (golden model, DPI-C)
//   retire_agent (passive) -> cpu_retire_checker  per-instruction trace
//   mem_agent    (passive) -> cpu_mem_checker     routing + stalls
//   axi_agent    (passive) -> cpu_axi_checker     AXI-Lite protocol
//   status_agent (passive) -> cpu_status_checker  halt / trap / faults
//   coverage               (all of the above)     functional coverage report
// =============================================================================
class cpu_env extends uvm_env;
  `uvm_component_utils(cpu_env)

  cpu_ctrl_agent     ctrl_agent;
  cpu_retire_agent   retire_agent;
  cpu_mem_agent      mem_agent;
  cpu_axi_agent      axi_agent;
  cpu_status_agent   status_agent;

  cpu_predictor      predictor;      // golden model (DPI-C) -> expected end state
  cpu_scoreboard     scoreboard;
  cpu_retire_checker retire_checker;
  cpu_mem_checker    mem_checker;
  cpu_axi_checker    axi_checker;
  cpu_bus_checker    bus_checker;    // cache misses / stores must reach the iMC over AXI
  cpu_status_checker status_checker;
  cpu_coverage       coverage;       // functional coverage: what did the tests exercise?

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ctrl_agent     = cpu_ctrl_agent    ::type_id::create("ctrl_agent",     this);
    retire_agent   = cpu_retire_agent  ::type_id::create("retire_agent",   this);
    mem_agent      = cpu_mem_agent     ::type_id::create("mem_agent",      this);
    axi_agent      = cpu_axi_agent     ::type_id::create("axi_agent",      this);
    status_agent   = cpu_status_agent  ::type_id::create("status_agent",   this);
    predictor      = cpu_predictor     ::type_id::create("predictor",      this);
    scoreboard     = cpu_scoreboard    ::type_id::create("scoreboard",     this);
    retire_checker = cpu_retire_checker::type_id::create("retire_checker", this);
    mem_checker    = cpu_mem_checker   ::type_id::create("mem_checker",    this);
    axi_checker    = cpu_axi_checker   ::type_id::create("axi_checker",    this);
    bus_checker    = cpu_bus_checker   ::type_id::create("bus_checker",    this);
    status_checker = cpu_status_checker::type_id::create("status_checker", this);
    coverage       = cpu_coverage      ::type_id::create("coverage",       this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    ctrl_agent  .driver .program_ap.connect(predictor    .analysis_export);   // program -> golden model
    predictor   .expected_ap       .connect(scoreboard   .pred_fifo.analysis_export);
    ctrl_agent  .monitor.actual_ap .connect(scoreboard   .act_fifo.analysis_export);  // DUT end state
    retire_agent.monitor.ap       .connect(retire_checker.analysis_export);
    mem_agent   .monitor.ap       .connect(mem_checker   .analysis_export);
    axi_agent   .monitor.ap       .connect(axi_checker   .analysis_export);
    status_agent.monitor.ap       .connect(status_checker.analysis_export);
    ctrl_agent  .driver .abort_ap  .connect(bus_checker  .analysis_export);   // reset test: drop in-flight bus traffic
    predictor   .expected_ap       .connect(coverage.exp_sub   .analysis_export);   // functional coverage taps
    mem_agent   .monitor.ap        .connect(coverage.mem_sub   .analysis_export);
    axi_agent   .monitor.ap        .connect(coverage.axi_sub   .analysis_export);
    status_agent.monitor.ap        .connect(coverage.status_sub.analysis_export);
    ctrl_agent  .driver .abort_ap  .connect(coverage.abort_sub .analysis_export);
    mem_checker.bus = bus_checker;     // plain handles: the two checkers report what they saw to the bus checker
    axi_checker.bus = bus_checker;
  endfunction
endclass
