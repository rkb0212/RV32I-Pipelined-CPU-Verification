// =============================================================================
// cpu_scoreboard.sv   (same structure as the UART scoreboard)
//
//   predictor ----> pred_fifo  (cpu_expected, one per program, queued at program start)
//   ctrl monitor -> act_fifo   (cpu_actual,   one per program, queued at halt)
//
// run_phase is driven by the OBSERVED run: take a cpu_actual from act_fifo, pull the
// prediction that is waiting, compare. If no prediction is waiting the run is only
// counted as `unpredicted`; if the ids differ the streams are out of step and that is
// an error (so one unpaired item cannot silently offset all later compares).
//
// Compares : halted, x1..x31, L1 data RAM, external memory, retired count, trap
//            count, misaligned / out-of-range flag counts, MEPC / MCAUSE / MTVAL,
//            frozen PC (accepts halt_pc+4 .. halt_pc+12, word aligned).
// Skips    : values the golden model marked unknown (taint), and the whole program
//            if the model `diverged` (counted as `skipped`).
//
// Log levels
//   UVM_LOW    (default)  one MATCH / SKIP / MISMATCH / UNPREDICTED line per program, SUMMARY
//   UVM_MEDIUM            + per-program dump: halted, pc, cycles, non-zero registers
//   errors                always printed: one line per mismatching field (max MAX_PRINT per program)
// =============================================================================
class cpu_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(cpu_scoreboard)

  localparam int MAX_PRINT = 10;

  uvm_tlm_analysis_fifo #(cpu_expected) pred_fifo;
  uvm_tlm_analysis_fifo #(cpu_actual)   act_fifo;

  int unsigned observed;       // runs taken from act_fifo
  int unsigned match_count, mismatch_count, unpredicted_count, skipped_count;

  // state of the program being compared
  int unsigned bad;
  int unsigned cur_pid;
  string       cur_name;
  int unsigned n_regs, n_l1, n_ext, n_unknown;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    pred_fifo = new("pred_fifo", this);
    act_fifo  = new("act_fifo",  this);
  endfunction

  // ---- helpers ----------------------------------------------------------------
  function void mismatch(string what, bit [31:0] got, bit [31:0] exp);
    bad++;
    if (bad <= MAX_PRINT)
      `uvm_error("CPU_SB", $sformatf("MISMATCH prog %0d (%s): %s Got 0x%08h, Expected 0x%08h",
                                     cur_pid, cur_name, what, got, exp))
  endfunction

  function void check32(string what, bit [31:0] got, bit [31:0] exp);
    if (got !== exp) mismatch(what, got, exp);
  endfunction

  // ---- main loop --------------------------------------------------------------
  task run_phase(uvm_phase phase);
    cpu_actual   act;
    cpu_expected exp;
    forever begin
      act_fifo.get(act);
      observed++;
      cur_pid = act.program_id;

      if (!pred_fifo.try_get(exp)) begin
        unpredicted_count++;
        `uvm_info("CPU_SB", $sformatf("UNPREDICTED prog %0d: run observed with no prediction outstanding (not compared)", cur_pid), UVM_LOW)
        continue;
      end
      cur_name = exp.program_name;

      if (exp.program_id != act.program_id) begin
        mismatch_count++;
        `uvm_error("CPU_SB", $sformatf("OUT OF STEP: DUT result is for prog %0d but the waiting prediction is for prog %0d (%s)",
                                       act.program_id, exp.program_id, exp.program_name))
        continue;
      end

      dump(act);

      if (exp.diverged) begin
        skipped_count++;
        `uvm_info("CPU_SB", $sformatf("SKIP prog %0d (%s): golden model lost track (a branch or address depended on an unknown value)",
                                      cur_pid, cur_name), UVM_LOW)
        continue;
      end

      compare(act, exp);
    end
  endtask

  function void dump(cpu_actual t);
    string nonzero = "";
    for (int i = 1; i < 32; i++)
      if (t.regs[i] != 0) nonzero = {nonzero, $sformatf(" x%0d=0x%0h", i, t.regs[i])};
    `uvm_info("CPU_SB", $sformatf(
      "  prog %0d (%s) DUT state: halted=%0b pc=0x%08h cycles=%0d retired=%0d traps=%0d misalign=%0d oor=%0d | mepc=0x%0h mcause=%0d mtval=0x%0h\n    regs:%s",
      t.program_id, cur_name, t.halted, t.pc, t.cycles, t.instr_count, t.trap_count,
      t.misalign_flags, t.oor_flags, t.mepc, t.mcause, t.mtval,
      (nonzero == "") ? " (all zero)" : nonzero), UVM_MEDIUM)
  endfunction

  function void compare(cpu_actual t, cpu_expected e);
    bad = 0; n_regs = 0; n_l1 = 0; n_ext = 0; n_unknown = 0;

    check32("halted", t.halted, e.halted);
    for (int i = 1; i < 32; i++) begin
      if (e.reg_taint[i]) begin n_unknown++; continue; end
      n_regs++; check32($sformatf("x%0d", i), t.regs[i], e.regs[i]);
    end
    for (int i = 0; i < DMEM_DEPTH; i++) begin
      if (e.dmem_taint[i]) begin n_unknown++; continue; end
      n_l1++; check32($sformatf("L1[0x%03h]", i*4), t.dmem[i], e.dmem[i]);
    end
    for (int i = 0; i < IMC_WORDS; i++) begin
      if (e.ext_taint[i]) begin n_unknown++; continue; end
      n_ext++; check32($sformatf("EXT[0x%04h]", i*4), t.ext[i], e.ext[i]);
    end
    check32("retired",    t.instr_count,    e.instr_count);
    check32("traps",      t.trap_count,     e.trap_count);
    check32("misalign",   t.misalign_flags, e.misalign_flags);
    check32("oor",        t.oor_flags,      e.oor_flags);
    check32("target faults", t.target_faults, e.target_faults);
    // hand-written expectations from the sequence (independent of the golden model)
    if (e.pin_misalign >= 0) check32("PINNED misalign flags", t.misalign_flags, e.pin_misalign);
    if (e.pin_oor      >= 0) check32("PINNED oor flags",      t.oor_flags,      e.pin_oor);
    if (e.pin_target   >= 0) check32("PINNED target faults",  t.target_faults,  e.pin_target);
    if (e.pin_traps    >= 0) check32("PINNED trap count",     t.trap_count,     e.pin_traps);
    for (int r = 0; r < 32; r++)
      if (e.pin_reg_mask[r] && (t.regs[r] < e.pin_reg_lo[r] || t.regs[r] > e.pin_reg_hi[r]))
        mismatch($sformatf("PINNED x%0d (must be in 0x%0h..0x%0h)", r, e.pin_reg_lo[r], e.pin_reg_hi[r]), t.regs[r], e.pin_reg_lo[r]);
    check32("MEPC",       t.mepc,           e.mepc);
    check32("MCAUSE",     t.mcause,         e.mcause);
    check32("MTVAL",      t.mtval,          e.mtval);
    if (e.halted) begin
      bit [31:0] d = t.pc - e.halt_pc;
      if (t.pc[1:0] != 2'b00 || d < 4 || d > 12) begin
        bad++;
        `uvm_error("CPU_SB", $sformatf("MISMATCH prog %0d (%s): frozen PC Got 0x%08h, Expected halt_pc 0x%08h + 4..12",
                                       cur_pid, cur_name, t.pc, e.halt_pc))
      end
    end

    if (bad > MAX_PRINT)
      `uvm_error("CPU_SB", $sformatf("MISMATCH prog %0d (%s): %0d more mismatch(es) not printed", cur_pid, cur_name, bad - MAX_PRINT))

    if (bad == 0) begin
      match_count++;
      `uvm_info("CPU_SB", $sformatf("MATCH prog %0d (%s): regs=%0d L1=%0d EXT=%0d retired=%0d traps=%0d faults(mis/oor/tgt)=%0d/%0d/%0d%s",
                cur_pid, cur_name, n_regs, n_l1, n_ext, t.instr_count, t.trap_count,
                t.misalign_flags, t.oor_flags, t.target_faults,
                (n_unknown == 0) ? "" : $sformatf(" (%0d unknown value(s) not compared)", n_unknown)), UVM_LOW)
    end else begin
      mismatch_count++;
    end
  endfunction

  // ---- end of test ------------------------------------------------------------
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (mismatch_count > 0)
      `uvm_error("CPU_SB", $sformatf("FAILED with %0d mismatching program(s)", mismatch_count))
    if (!pred_fifo.is_empty())
      `uvm_error("CPU_SB", $sformatf("%0d prediction(s) never matched a DUT run", pred_fifo.used()))
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("CPU_SB", $sformatf("SUMMARY: observed=%0d match=%0d mismatch=%0d unpredicted=%0d skipped=%0d",
              observed, match_count, mismatch_count, unpredicted_count, skipped_count), UVM_NONE)
  endfunction
endclass
