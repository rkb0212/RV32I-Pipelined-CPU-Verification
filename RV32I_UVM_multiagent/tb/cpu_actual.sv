// =============================================================================
// cpu_actual.sv
// What the monitor observed for one program run: final architectural state
// plus event counts. The scoreboard compares it with the golden model's
// cpu_expected (a subclass of this).
// =============================================================================
class cpu_actual extends uvm_object;
  `uvm_object_utils(cpu_actual)

  bit [31:0]   regs [32];
  bit [31:0]   dmem [DMEM_DEPTH];   // L1 data RAM
  bit [31:0]   ext  [IMC_WORDS];    // external memory (iMC backing store)
  bit [31:0]   pc;
  bit          halted;
  int unsigned program_id;
  int unsigned cycles;          // cycles from reset release to halt
  int unsigned trap_count;      // trap_taken pulses
  int unsigned misalign_flags;  // fault_mem_misaligned pulses
  int unsigned oor_flags;       // fault_mem_out_of_range pulses
  int unsigned target_faults;   // fault_misaligned_target pulses
  bit [31:0]   instr_count, mepc, mcause, mtval;

  function new(string name = "cpu_actual");
    super.new(name);
  endfunction
endclass
