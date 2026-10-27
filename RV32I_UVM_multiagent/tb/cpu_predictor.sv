// =============================================================================
// cpu_predictor.sv
// Purpose  : turn each program into an expected end state.
// Mechanism: subscribes to the driver's program_ap. For every cpu_program it
//            resets the C golden model, loads the same 256-word image the
//            driver puts in instr_mem, runs it to halt, and publishes a
//            cpu_expected on expected_ap (read through the gm_get_* DPI calls).
// Rationale: the prediction is made when the program STARTS, long before the
//            monitor publishes the DUT's result, so the scoreboard's FIFO
//            always has the expected item waiting.
// =============================================================================
class cpu_predictor extends uvm_subscriber #(cpu_program);
  `uvm_component_utils(cpu_predictor)

  localparam int MAX_STEPS = 5000;
  uvm_analysis_port #(cpu_expected) expected_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    expected_ap = new("expected_ap", this);
  endfunction

  function void write(cpu_program p);
    cpu_expected e;
    if (p.abort_at >= 0) return;                  // reset-test victim: never completes, nothing to predict
    e = cpu_expected::type_id::create("expected");

    gm_reset();
    for (int i = 0; i < IMEM_DEPTH; i++) gm_load_instr(i, int'(p.imem[i]));
    gm_run(MAX_STEPS);

    e.program_id   = p.program_id;
    e.program_name = p.program_name;
    e.halted     = (gm_is_halted() != 0);
    e.diverged   = (gm_is_diverged() != 0);
    e.halt_pc    = gm_get_halt_pc();
    e.pc         = gm_get_pc();
    e.steps      = gm_get_steps();
    for (int i = 0; i < 32; i++) begin
      e.regs[i]      = gm_get_reg(i);
      e.reg_taint[i] = (gm_reg_tainted(i) != 0);
    end
    for (int i = 0; i < DMEM_DEPTH; i++) begin
      e.dmem[i]       = gm_get_dmem(i);
      e.dmem_taint[i] = (gm_dmem_tainted(i) != 0);
    end
    for (int i = 0; i < IMC_WORDS; i++) begin
      e.ext[i]       = gm_get_ext(i);
      e.ext_taint[i] = (gm_ext_tainted(i) != 0);
    end
    e.instr_count    = gm_get_instr_count();
    e.mepc           = gm_get_mepc();
    e.mcause         = gm_get_mcause();
    e.mtval          = gm_get_mtval();
    e.trap_count     = gm_get_trap_count();
    e.misalign_flags = gm_get_misalign_count();
    e.oor_flags      = gm_get_oor_count();
    e.target_faults  = gm_get_target_fault_count();
    e.pin_misalign = p.exp_misalign;  e.pin_oor = p.exp_oor;
    e.pin_target   = p.exp_target;    e.pin_traps = p.exp_traps;
    for (int r = 0; r < 32; r++) begin
      e.pin_reg_lo[r] = p.exp_reg_lo[r];  e.pin_reg_hi[r] = p.exp_reg_hi[r];
    end
    e.pin_reg_mask = p.exp_reg_mask;
    cpu_expect::programs[p.program_id] = p;       // checkers read the program's timing/pin expectations

    `uvm_info("CPU_PREDICTOR", $sformatf("program %0d '%s': golden model ran %0d instruction(s), halted=%0b halt_pc=0x%0h retired=%0d traps=%0d%s",
              p.program_id, p.program_name, e.steps, e.halted, e.halt_pc, e.instr_count, e.trap_count,
              e.diverged ? " DIVERGED" : ""), UVM_MEDIUM)
    expected_ap.write(e);
  endfunction
endclass
