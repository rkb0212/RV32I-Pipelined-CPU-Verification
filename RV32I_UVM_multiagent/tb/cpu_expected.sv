// =============================================================================
// cpu_expected.sv
// What the golden model predicts for one program: everything cpu_actual holds,
// plus "unknown" markers for values the model refuses to guess (see
// golden_model.cpp: CYCLE_COUNT reads and loads from the address hole).
//   reg_taint / dmem_taint / ext_taint : 1 = value unknown, skip it in the compare
//   diverged : a branch operand or a load/store address was unknown, so the
//              rest of the prediction cannot be trusted; skip the whole compare
//   halt_pc  : address of the halting instruction (ECALL, or the SW to HALT_CTRL)
// =============================================================================
class cpu_expected extends cpu_actual;
  `uvm_object_utils(cpu_expected)

  bit          reg_taint  [32];
  bit          dmem_taint [DMEM_DEPTH];
  bit          ext_taint  [IMC_WORDS];
  bit          diverged;
  bit [31:0]   halt_pc;
  int unsigned steps;           // instructions the model executed
  string       program_name;    // copied from the cpu_program, for log lines
  // Hand-written expectations from the sequence (-1 = not pinned). They guard against
  // the golden model and the DUT sharing the same wrong idea of a fault.
  int          pin_misalign = -1, pin_oor = -1, pin_target = -1, pin_traps = -1;
  bit [31:0]   pin_reg_lo [32];
  bit [31:0]   pin_reg_hi [32];
  bit [31:0]   pin_reg_mask = 32'h0;

  function new(string name = "cpu_expected");
    super.new(name);
  endfunction
endclass
