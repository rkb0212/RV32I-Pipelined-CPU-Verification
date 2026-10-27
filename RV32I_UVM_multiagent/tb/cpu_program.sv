// =============================================================================
// cpu_program.sv
// Transaction = one complete program image for the DUT's instruction memory.
// Mechanism : imem[] starts as NOPs. A sequence places instructions with
//             emit() (next free slot) or org() (jump to a slot, used to put a
//             trap handler at a fixed address such as word 64 = 0x100).
// Rationale : "one item = one whole program" keeps the driver trivial: reset,
//             load, run until halt, report. Data memory is NOT part of the
//             item -- the testbench cannot write it (see cpu_if.sv); programs
//             preload data with SW.
// =============================================================================
class cpu_program extends uvm_sequence_item;
  `uvm_object_utils(cpu_program)

  bit [31:0]   imem [IMEM_DEPTH];
  int unsigned program_id;
  string       program_name;
  int unsigned max_cycles;     // timeout for the run
  int unsigned next_slot;      // where emit() writes next

  // ---- optional hand-written expectations (checked in addition to the golden model) ----
  // Fault/trap counts the DUT's status outputs must show for THIS program (-1 = not pinned).
  int exp_misalign = -1, exp_oor = -1, exp_target = -1, exp_traps = -1;
  // Retire spacing: cycles between consecutive retired instructions.
  //   exp_gap_default : expected gap for every retire after the first (0 = do not check)
  //   exp_gap_at[k]   : override for the gap before the k-th retire (k counts from 0)
  int exp_gap_default = 0;
  int exp_gap_at [int];
  // Register range pins: final value of x[k] must lie in [lo, hi], checked even when the golden model
  // calls the value unknown (used for the free-running CYCLE counter, whose exact value it cannot predict).
  // fixed arrays + a mask (no associative arrays: xsim crashes on them in this path)
  bit [31:0] exp_reg_lo [32];
  bit [31:0] exp_reg_hi [32];
  bit [31:0] exp_reg_mask = 32'h0;     // bit r set = x[r] is pinned
  // Reset test: >= 0 means "assert reset this many clocks after the run starts, never wait for halt".
  // Such a program is a victim: it is not predicted or compared, it only leaves the DUT dirty.
  int abort_at = -1;

  function new(string name = "cpu_program");
    super.new(name);
    program_name = name;
    max_cycles   = 2000;
    clear();
  endfunction

  // Fill with NOPs and rewind. Called by new() and by sequences reusing an item.
  function void clear();
    for (int i = 0; i < IMEM_DEPTH; i++) imem[i] = INSTR_NOP;
    next_slot = 0;
  endfunction

  // Append one instruction at the next free slot.
  function void emit(bit [31:0] instr);
    if (next_slot >= IMEM_DEPTH) begin
      `uvm_fatal("CPU_PROGRAM", "program larger than IMEM_DEPTH")
    end
    imem[next_slot] = instr;
    next_slot++;
  endfunction

  // Continue emitting at word index `slot` (e.g. org(64) for a handler at 0x100).
  // Pin the final value of register `r` to [lo, hi].
  function void pin_reg_range(int r, bit [31:0] lo, bit [31:0] hi);
    exp_reg_lo[r] = lo;  exp_reg_hi[r] = hi;  exp_reg_mask[r] = 1'b1;
  endfunction

  function void org(int unsigned slot);
    next_slot = slot;
  endfunction

  // Human-readable listing, non-NOP words only.
  function string convert2string();
    string s;
    s = $sformatf("program %0d '%s'\n", program_id, program_name);
    for (int i = 0; i < IMEM_DEPTH; i++)
      if (imem[i] != INSTR_NOP)
        s = {s, $sformatf("    [%03d] pc=0x%03h  %08h  %s\n", i, i*4, imem[i], rv_disasm(imem[i]))};
    return s;
  endfunction
endclass

// ---------------------------------------------------------------------------
// cpu_expect: lets the passive checkers find the program that is running.
// The predictor registers each program here when it starts; checkers look it
// up by program id to read its exp_* expectations.
// ---------------------------------------------------------------------------
class cpu_expect;
  static cpu_program programs [int unsigned];
endclass
