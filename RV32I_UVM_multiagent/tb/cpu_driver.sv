// =============================================================================
// cpu_driver.sv
// Purpose  : run one cpu_program on the DUT.
// Mechanism: per item -> assert reset -> write the image into instr_mem
//            (backdoor, via cpu_if) -> release reset -> wait for `halt` or a
//            cycle timeout -> idle a few cycles so the monitor can sample.
// Rationale: reset before every program gives each run a clean architectural
//            state (regfile, data RAM, CSRs all reset); instr_mem is not reset
//            by the RTL, so loading it while reset is held is safe.
// =============================================================================
class cpu_driver extends uvm_driver #(cpu_program);
  `uvm_component_utils(cpu_driver)

  virtual cpu_if vif;
  uvm_analysis_port #(cpu_program) program_ap;   // every program, as it starts: feeds the golden-model predictor
  uvm_analysis_port #(cpu_program) abort_ap;     // a program cut short by a mid-run reset: tells the bus checker to drop in-flight traffic

  function new(string name, uvm_component parent);
    super.new(name, parent);
    program_ap = new("program_ap", this);
    abort_ap   = new("abort_ap",   this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual cpu_if)::get(this, "", "vif", vif)) begin
      `uvm_fatal("CPU_DRIVER", "virtual interface 'vif' not found in config_db")
    end
  endfunction

  task run_phase(uvm_phase phase);
    cpu_program req;
    vif.rst_n = 1'b0;
    forever begin
      seq_item_port.get_next_item(req);
      run_one_program(req);
      seq_item_port.item_done();
    end
  endtask

  task automatic run_one_program(cpu_program prog);
    bit          timed_out = 0;
    int unsigned waited    = 0;

    `uvm_info("CPU_DRIVER", {"Driving ", prog.convert2string()}, UVM_MEDIUM)
    program_ap.write(prog);               // the predictor runs the golden model on it now

    // 1. reset (clears regfile / data RAM / CSRs / pipeline)
    vif.rst_n = 1'b0;
    repeat (3) @(posedge vif.clk);

    // 2. load the image while reset is held
    vif.program_id = prog.program_id;
    for (int i = 0; i < IMEM_DEPTH; i++) vif.load_instr(i, prog.imem[i]);

    // 3. run
    @(posedge vif.clk);
    vif.rst_n = 1'b1;

    // Reset-test victim: let it run abort_at clocks, then reset the DUT in the middle of whatever it is doing
    // (a stall, a trap, a cache fill ...). The next program starts from that reset.
    if (prog.abort_at >= 0) begin
      repeat (prog.abort_at) @(posedge vif.clk);
      vif.rst_n = 1'b0;
      repeat (3) @(posedge vif.clk);
      abort_ap.write(prog);
      `uvm_info("CPU_DRIVER", $sformatf("program %0d '%s' aborted by reset after %0d clock(s) (pc was 0x%08h)",
                prog.program_id, prog.program_name, prog.abort_at, vif.pc_out), UVM_LOW)
      return;
    end

    // Poll once per clock until halt or the cycle budget is used up. (A plain
    // loop instead of fork/join_any: no stray processes to kill, same result.)
    while (vif.halt !== 1'b1 && waited < prog.max_cycles) begin
      @(posedge vif.clk);
      waited++;
    end
    timed_out = (vif.halt !== 1'b1);

    if (timed_out) begin
      `uvm_error("CPU_DRIVER", $sformatf("program %0d '%s' did not halt within %0d cycles (pc=0x%08h)",
                 prog.program_id, prog.program_name, prog.max_cycles, vif.pc_out))
    end

    // 4. let the monitor sample (it samples 5 cycles after halt)
    repeat (10) @(posedge vif.clk);
  endtask
endclass
