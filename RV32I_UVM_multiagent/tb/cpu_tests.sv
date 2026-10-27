// =============================================================================
// cpu_tests.sv   -- ALL tests in one file
//   cpu_base_test        builds cpu_env, runs run_sequences() under an objection
//   cpu_hazard_test      forwarding / load-use / branch / jump program
//   cpu_trap_test        misaligned LW / SW / JAL traps, handler, MRET
//   cpu_halt_test        ECALL halt and software (CSR) halt freeze the CPU
//   cpu_mem_test         CSR window, external L2/L3/iMC traffic, out-of-range
//   cpu_decode_test      instruction formats, addressing modes, rd = x0, unsupported opcodes
//   cpu_pipeline_test    no-stall flow, forwarding, load-use bubble, memory stalls and resume
//   cpu_cache_test       L1 / L2 / L3 / iMC levels, conflicts, write hit / miss, range edges
//   cpu_status_test      each status/fault output raised by its own program, with a legal twin
//   cpu_rand_test        random programs: ALU, L1 + external accesses, branches, jumps, traps, both halts
//   cpu_csr_test         every CSR: read/write rules, masks, trap capture, MRET, counters
//   cpu_runoff_test      PC past the end of instruction memory wraps to word 0
//   cpu_reset_test       reset in the middle of a run (stall, trap, cache fill), then restart and read all state
//   cpu_known_issue_test misaligned address beyond the CSR window / in the hole: EXPECTED TO FAIL (DUT finding)
//   cpu_regression_test  every sequence, one after another
// Pick one at run time:  bash sim/run_uvm_xsim.sh cpu_trap_test
// =============================================================================

// ---------------------------------------------------------------------------
// cpu_base_test.sv
// Builds the env and runs whatever run_sequences() starts, holding an objection
// so the simulation does not end early. Subclasses override run_sequences().
class cpu_base_test extends uvm_test;
  `uvm_component_utils(cpu_base_test)

  cpu_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = cpu_env::type_id::create("env", this);
  endfunction

  // Override in subclasses: create and start sequences on env.ctrl_agent.sequencer.
  virtual task run_sequences();
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_sequences();
    repeat (20) @(posedge env.ctrl_agent.driver.vif.clk);   // let the last sample publish
    phase.drop_objection(this);
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_hazard_test.sv  -- forwarding / load-use / branch / jump program
class cpu_hazard_test extends cpu_base_test;
  `uvm_component_utils(cpu_hazard_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_sequences();
    cpu_hazard_seq seq = cpu_hazard_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_trap_test.sv  -- misalignment traps (LW, SW, beyond-L1 LW, JAL) with a handler
class cpu_trap_test extends cpu_base_test;
  `uvm_component_utils(cpu_trap_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_sequences();
    cpu_trap_seq seq = cpu_trap_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_halt_test.sv  -- ECALL halt and software (CSR) halt freeze the CPU
class cpu_halt_test extends cpu_base_test;
  `uvm_component_utils(cpu_halt_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_sequences();
    cpu_halt_seq seq = cpu_halt_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_mem_test.sv  -- CSR, external L2/L3/iMC traffic and out-of-range accesses
class cpu_mem_test extends cpu_base_test;
  `uvm_component_utils(cpu_mem_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_sequences();
    cpu_mem_seq seq = cpu_mem_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_rand_test.sv  -- random straight-line programs
class cpu_rand_test extends cpu_base_test;
  `uvm_component_utils(cpu_rand_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_sequences();
    cpu_rand_seq seq = cpu_rand_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_decode_test  -- instruction formats, addressing modes, rd = x0, unsupported opcodes
class cpu_decode_test extends cpu_base_test;
  `uvm_component_utils(cpu_decode_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task run_sequences();
    cpu_decode_seq seq = cpu_decode_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_pipeline_test  -- no-stall flow, forwarding, load-use bubble, memory stalls and resume
class cpu_pipeline_test extends cpu_base_test;
  `uvm_component_utils(cpu_pipeline_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task run_sequences();
    cpu_pipeline_seq seq = cpu_pipeline_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_cache_test  -- L1 / L2 / L3 / iMC levels, conflicts, write hit / miss, range edges
class cpu_cache_test extends cpu_base_test;
  `uvm_component_utils(cpu_cache_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task run_sequences();
    cpu_cache_seq seq = cpu_cache_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_status_test  -- every status/fault output raised by its own program, with a legal twin
class cpu_status_test extends cpu_base_test;
  `uvm_component_utils(cpu_status_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  virtual task run_sequences();
    cpu_status_seq seq = cpu_status_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_regression_test.sv -- hazard, trap, halt, mem, then random programs, in order
class cpu_csr_test extends cpu_base_test;
  `uvm_component_utils(cpu_csr_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual task run_sequences();
    cpu_csr_seq seq = cpu_csr_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

class cpu_runoff_test extends cpu_base_test;
  `uvm_component_utils(cpu_runoff_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual task run_sequences();
    cpu_runoff_seq seq = cpu_runoff_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

class cpu_reset_test extends cpu_base_test;
  `uvm_component_utils(cpu_reset_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual task run_sequences();
    cpu_reset_seq seq = cpu_reset_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

// Not part of `all` or the regression: these programs are meant to fail on this DUT (see cpu_known_issue_seq).
class cpu_known_issue_test extends cpu_base_test;
  `uvm_component_utils(cpu_known_issue_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual task run_sequences();
    cpu_known_issue_seq seq = cpu_known_issue_seq::type_id::create("seq");
    seq.start(env.ctrl_agent.sequencer);
  endtask
endclass

class cpu_regression_test extends cpu_base_test;
  `uvm_component_utils(cpu_regression_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual task run_sequences();
    cpu_hazard_seq hz = cpu_hazard_seq::type_id::create("hz");
    cpu_trap_seq   tr = cpu_trap_seq  ::type_id::create("tr");
    cpu_halt_seq   ha = cpu_halt_seq  ::type_id::create("ha");
    cpu_mem_seq    me = cpu_mem_seq   ::type_id::create("me");
    cpu_decode_seq   dc = cpu_decode_seq  ::type_id::create("dc");
    cpu_pipeline_seq pl = cpu_pipeline_seq::type_id::create("pl");
    cpu_cache_seq    ca = cpu_cache_seq   ::type_id::create("ca");
    cpu_status_seq   st = cpu_status_seq  ::type_id::create("st");
    cpu_csr_seq      cs = cpu_csr_seq     ::type_id::create("cs");
    cpu_runoff_seq   ro = cpu_runoff_seq  ::type_id::create("ro");
    cpu_reset_seq    rs = cpu_reset_seq   ::type_id::create("rs");
    cpu_rand_seq   rn = cpu_rand_seq  ::type_id::create("rn");
    hz.start(env.ctrl_agent.sequencer);
    tr.start(env.ctrl_agent.sequencer);
    ha.start(env.ctrl_agent.sequencer);
    me.start(env.ctrl_agent.sequencer);
    dc.start(env.ctrl_agent.sequencer);
    pl.start(env.ctrl_agent.sequencer);
    ca.start(env.ctrl_agent.sequencer);
    st.start(env.ctrl_agent.sequencer);
    cs.start(env.ctrl_agent.sequencer);
    ro.start(env.ctrl_agent.sequencer);
    rs.start(env.ctrl_agent.sequencer);
    rn.start(env.ctrl_agent.sequencer);
  endtask
endclass

