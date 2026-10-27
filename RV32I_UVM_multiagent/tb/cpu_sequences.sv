// =============================================================================
// cpu_sequences.sv   -- ALL sequences in one file
//   cpu_sequence      base class: unique program ids + start_item/finish_item
//   cpu_hazard_seq    forwarding, load-use, BEQ, JAL         (retire / mem / status)
//   cpu_trap_seq      misaligned LW / SW / JAL, handler, MRET (status / retire / mem)
//   cpu_halt_seq      ECALL halt, software halt via CSR       (status / retire / mem / axi)
//   cpu_mem_seq       CSR, L2/L3 hit and miss, iMC, out-of-range (mem / axi / status)
//   cpu_rand_seq      random aligned-L1 programs              (retire / mem)
//   cpu_csr_seq / cpu_runoff_seq / cpu_reset_seq / cpu_known_issue_seq   (appended below)
// Every sequence runs on the ONE sequencer inside ctrl_agent; the passive agents
// simply observe what each program does to the DUT.
// =============================================================================

// ---------------------------------------------------------------------------
// =============================================================================
// cpu_sequence.sv
// Base class for every program sequence: numbers programs uniquely and wraps
// the start_item / finish_item handshake.
// =============================================================================
class cpu_sequence extends uvm_sequence #(cpu_program);
  `uvm_object_utils(cpu_sequence)

  static int unsigned next_id = 1;   // unique program id across all sequences

  function new(string name = "cpu_sequence");
    super.new(name);
  endfunction

  // Create an empty (all-NOP) program with a fresh id and a name.
  function cpu_program make_program(string pname);
    cpu_program p = cpu_program::type_id::create(pname);
    p.program_id   = next_id++;
    p.program_name = pname;
    return p;
  endfunction

  // Point MTVEC at the handler (word 64 = 0x100). MTVEC is 0 after reset, so every program
  // that can trap must run this FIRST. Uses x30/x31 (3 instructions).
  function void set_mtvec(cpu_program p);
    p.emit(addi(30, 0, -256));            // x30 = CSR_BASE
    p.emit(addi(31, 0, 'h100));           // x31 = handler address
    p.emit(sw  (31, 30, CSR_MTVEC));      // MTVEC = 0x100
  endfunction

  // Standard trap handler for the new tests, placed at word 64 (0x100):
  // MEPC += 4 (skip only the faulting instruction), MRET. Uses x30/x31, so programs must not.
  function void add_skip_handler(cpu_program p);
    p.org(64);
    p.emit(addi(30, 0, -256));            // x30 = CSR_BASE
    p.emit(lw  (31, 30, CSR_MEPC));       // x31 = MEPC
    p.emit(addi(31, 31, 4));              // resume after the faulting instruction
    p.emit(sw  (31, 30, CSR_MEPC));
    p.emit(INSTR_MRET);
  endfunction

  // Hand a finished program to the driver and wait until it has run.
  task send(cpu_program p);
    start_item(p);
    finish_item(p);
  endtask
endclass

// ---------------------------------------------------------------------------
// =============================================================================
// cpu_hazard_seq.sv
// One directed program: RAW forwarding, load-use stall, taken BEQ (two flushed
// instructions), LUI, JAL (one flushed instruction), x0 stays zero, ECALL.
// Data is preloaded with an ordinary SW (the testbench cannot write data RAM).
// =============================================================================
class cpu_hazard_seq extends cpu_sequence;
  `uvm_object_utils(cpu_hazard_seq)

  function new(string name = "cpu_hazard_seq");
    super.new(name);
  endfunction

  task body();
    cpu_program p = make_program("hazard_branch_jump");
    p.emit(addi(10, 0, 100));    // x10 = 100
    p.emit(sw(10, 0, 0));        // mem[0] = 100
    p.emit(addi(1, 0, 5));       // x1 = 5
    p.emit(addi(2, 1, 3));       // x2 = 8        (forward EX/MEM)
    p.emit(add_(3, 2, 1));       // x3 = 13       (forward)
    p.emit(lw(4, 0, 0));         // x4 = 100
    p.emit(add_(5, 4, 3));       // x5 = 113      (load-use stall)
    p.emit(sw(5, 0, 4));         // mem[1] = 113
    p.emit(beq(1, 1, 12));       // taken: skip next 2
    p.emit(addi(6, 0, 9));       //   flushed
    p.emit(addi(6, 0, 8));       //   flushed
    p.emit(addi(7, 0, 7));       // x7 = 7
    p.emit(lui(8, 20'h12345));   // x8 = 0x12345000
    p.emit(jal(9, 8));           // x9 = link, skip next 1
    p.emit(addi(10, 0, 111));    //   flushed (x10 stays 100)
    p.emit(addi(11, 0, 42));     // x11 = 42
    p.emit(addi(0, 0, 99));      // x0 must stay 0
    p.emit(INSTR_ECALL);
    send(p);
  endtask
endclass

// ---------------------------------------------------------------------------
// =============================================================================
// cpu_trap_seq.sv
// One program exercising the misalignment trap on four paths, with a handler
// at word 64 (0x100). Every faulting instruction is followed by a "poison"
// ADDI x9 that must be squashed; the handler returns to MEPC+8, skipping it.
//   T1 LW  misaligned (L1)       cause 4   x6  must keep its value
//   T2 SW  misaligned (L1)       cause 6   store must not happen
//   T3 LW  misaligned (beyond L1, 0x402)  cause 4   x12 must keep its value
//   T4 JAL misaligned target     cause 0   link register x13 must keep its value
// Handler: count the trap in x30, copy MCAUSE/MTVAL/MEPC into x26/x27/x28,
// MEPC += 8, write MEPC back, MRET.
// =============================================================================
class cpu_trap_seq extends cpu_sequence;
  `uvm_object_utils(cpu_trap_seq)

  function new(string name = "cpu_trap_seq");
    super.new(name);
  endfunction

  task body();
    cpu_program p = make_program("misalign_trap_lw_sw_jal");

    // ---- setup ----
    p.emit(addi(20, 0, -256));          // x20 = 0xFFFF_FF00 (CSR_BASE)
    p.emit(addi(1, 0, 'h100));
    p.emit(sw(1, 20, CSR_MTVEC));       // MTVEC = 0x100
    p.emit(addi(5, 0, 'h20));           // x5  = 0x20 (L1 base)
    p.emit(addi(6, 0, 'h66));           // x6  preset
    p.emit(addi(7, 0, 'h77));           // x7  store data

    // ---- T1: misaligned LW in L1 (0x22) ----
    p.emit(lw(6, 5, 2));
    p.emit(addi(9, 0, 'h7AD));          // poison
    // ---- T2: misaligned SW in L1 (0x26) ----
    p.emit(sw(7, 5, 6));
    p.emit(addi(9, 0, 'h7AD));          // poison
    // ---- T3: misaligned LW beyond L1 (0x402) ----
    p.emit(addi(8, 0, 'h402));
    p.emit(addi(12, 0, 'h88));          // x12 preset
    p.emit(lw(12, 8, 0));
    p.emit(addi(9, 0, 'h7AD));          // poison
    // ---- T4: misaligned JAL target (pc+6) ----
    p.emit(addi(13, 0, 'h99));          // x13 preset (link must not be written)
    p.emit(jal(13, 6));
    p.emit(addi(9, 0, 'h7AD));          // poison
    p.emit(INSTR_ECALL);

    // ---- trap handler at word 64 (0x100) ----
    p.org(64);
    p.emit(addi(30, 30, 1));            // trap counter
    p.emit(lw(26, 20, CSR_MCAUSE));
    p.emit(lw(27, 20, CSR_MTVAL));
    p.emit(lw(28, 20, CSR_MEPC));
    p.emit(addi(28, 28, 8));            // skip faulting instr + poison
    p.emit(sw(28, 20, CSR_MEPC));
    p.emit(INSTR_MRET);

    send(p);
  endtask
endclass

// ---------------------------------------------------------------------------
// =============================================================================
// cpu_halt_seq.sv
// Two programs that must stop the CPU:
//   A) ECALL, with a plain ADDI, a taken BEQ and another ADDI behind it
//   B) software halt: SW 1 -> HALT_CTRL after an external store, with a SW to
//      SCRATCH behind it
// Everything behind the halting instruction is "poison" and must never commit.
// =============================================================================
class cpu_halt_seq extends cpu_sequence;
  `uvm_object_utils(cpu_halt_seq)

  function new(string name = "cpu_halt_seq");
    super.new(name);
  endfunction

  task body();
    cpu_program a = make_program("halt_ecall");
    cpu_program b = make_program("halt_software_csr");

    a.emit(addi(1, 0, 5));
    a.emit(addi(4, 0, 9));              // right before ECALL: must commit
    a.emit(INSTR_ECALL);
    a.emit(addi(9, 0, 'h7AD));          // poison
    a.emit(beq(0, 0, 8));               // poison: taken branch must not move the PC
    a.emit(addi(10, 0, 'h7AD));         // poison
    send(a);

    b.emit(addi(20, 0, -256));          // CSR_BASE
    b.emit(addi(1, 0, 1));
    b.emit(addi(5, 0, 'h400));          // 0x400 = first address beyond L1 (external store, stalls)
    b.emit(sw(1, 5, 0));
    b.emit(addi(6, 0, 'h66));           // before the halting SW: must commit
    b.emit(sw(1, 20, CSR_HALT));        // HALT_CTRL = 1
    b.emit(addi(9, 0, 'h7AD));          // poison
    b.emit(sw(1, 20, CSR_SCRATCH));     // poison store
    send(b);

    // ---- more halt situations: every one must still freeze the PC and squash all younger work ----
    begin
      cpu_program c = make_program("halt_during_ext_store");     // ECALL right behind a stalling store
      c.emit(addi(1, 0, 1));
      c.emit(addi(5, 0, 'h400));
      c.emit(sw(1, 5, 0));                // external store: pipeline stalls 4 cycles
      c.emit(INSTR_ECALL);
      c.emit(addi(9, 0, 'h7AD));          // poison
      c.emit(sw(1, 5, 4));                // poison external store: must never reach the iMC
      send(c);
    end
    begin
      cpu_program d = make_program("halt_after_ext_miss");       // ECALL right behind a load that goes to the iMC
      d.emit(addi(5, 0, 'h400));
      d.emit(lw(2, 5, 0));                // L2/L3 miss: stalls 7 cycles
      d.emit(INSTR_ECALL);
      d.emit(addi(9, 0, 'h7AD));          // poison
      send(d);
    end
    begin
      cpu_program e = make_program("halt_after_taken_branch");   // ECALL is the branch target
      e.emit(addi(1, 0, 1));
      e.emit(beq(1, 1, 12));              // taken: target is the ECALL, 3 slots on
      e.emit(addi(9, 0, 'h7AD));          // poison (flushed)
      e.emit(addi(10, 0, 'h7AD));         // poison (flushed)
      e.emit(INSTR_ECALL);
      e.emit(addi(11, 0, 'h7AD));         // poison
      send(e);
    end
    begin
      cpu_program f = make_program("halt_in_trap_handler");      // a trap, then the handler halts
      f.exp_traps = 1;  f.exp_misalign = 1;
      set_mtvec(f);
      f.emit(addi(1, 0, 1));
      f.emit(lw(2, 0, 2));                // misaligned load -> trap, MEPC = this pc
      f.emit(addi(9, 0, 'h7AD));          // must not run before the handler
      f.org(64);
      f.emit(INSTR_ECALL);                // handler halts at 0x100
      f.emit(addi(10, 0, 'h7AD));         // poison
      send(f);
    end
    begin
      cpu_program g = make_program("halt_sw_after_ext_store");   // software halt right behind a stalling store
      g.emit(addi(20, 0, -256));
      g.emit(addi(1, 0, 1));
      g.emit(addi(5, 0, 'h400));
      g.emit(sw(1, 5, 0));                // external store, stalls
      g.emit(sw(1, 20, CSR_HALT));        // HALT_CTRL = 1
      g.emit(addi(9, 0, 'h7AD));          // poison
      g.emit(sw(1, 5, 4));                // poison external store
      send(g);
    end
    begin
      cpu_program h = make_program("halt_back_to_back");         // second ECALL must never execute
      h.emit(addi(1, 0, 1));
      h.emit(INSTR_ECALL);
      h.emit(INSTR_ECALL);
      h.emit(addi(9, 0, 'h7AD));          // poison
      send(h);
    end
  endtask
endclass

// ---------------------------------------------------------------------------
// cpu_mem_seq.sv (new)
// Two programs aimed at mem_agent and axi_agent. Address map: L1 [0,0x400),
// external (L2 -> L3 -> AXI -> iMC) [0x400,0x4000), hole [0x4000,CSR_BASE),
// CSR window at 0xFFFF_FF00. L2 is direct-mapped with 64 one-word lines
// (index = addr[7:2]), L3 with 128 (index = addr[8:2]).
//   A) ext_traffic : store/load/reload to the external range
//        0x400 and 0x500 share an L2 index but not an L3 index, so alternating
//        between them forces L2 conflict misses that can still hit in L3;
//        0x1000 is touched once, a cold miss all the way to the iMC.
//   B) csr_and_gap : CSR reads/writes, a store to a read-only CSR (ignored),
//        and loads/stores into the address hole (out-of-range flag, no trap).
// =============================================================================
class cpu_mem_seq extends cpu_sequence;
  `uvm_object_utils(cpu_mem_seq)

  function new(string name = "cpu_mem_seq");
    super.new(name);
  endfunction

  task body();
    cpu_program a = make_program("mem_ext_traffic");
    cpu_program b = make_program("mem_csr_and_gap");

    // ---- A: external traffic ----
    a.emit(addi(1, 0, 'h11));
    a.emit(addi(2, 0, 'h22));
    a.emit(addi(5, 0, 'h400));          // x5 = 0x400
    a.emit(addi(6, 0, 'h500));          // x6 = 0x500 (same L2 index as x5)
    a.emit(lui (9, 1));                 // x9 = 0x1000
    a.emit(sw(1, 5, 0));                // store to 0x400  (write-through, stalls)
    a.emit(sw(2, 6, 0));                // store to 0x500
    a.emit(lw(3, 5, 0));                // 0x400: L2 read miss
    a.emit(lw(4, 5, 0));                // 0x400 again: L2 hit, no stall
    a.emit(add_(11, 3, 4));             // load-use right after a load
    a.emit(lw(7, 6, 0));                // 0x500: conflicts with 0x400 in L2
    a.emit(lw(8, 5, 0));                // 0x400: L2 miss again, L3 may hit
    a.emit(lw(10, 9, 0));               // 0x1000: cold miss, goes to the iMC
    a.emit(sw(10, 9, 4));               // store behind it
    a.emit(INSTR_ECALL);
    send(a);

    // ---- B: CSR window and the address hole ----
    b.emit(addi(20, 0, -256));          // x20 = CSR_BASE
    b.emit(addi(1, 0, 'h55));
    b.emit(sw(1, 20, CSR_SCRATCH));     // SCRATCH = 0x55
    b.emit(lw(2, 20, CSR_SCRATCH));     // x2 = 0x55
    b.emit(lw(3, 20, 0));               // CYCLE_COUNT
    b.emit(lw(4, 20, 4));               // INSTR_COUNT
    b.emit(sw(1, 20, CSR_MCAUSE));      // read-only CSR: write ignored
    b.emit(lw(5, 20, CSR_MCAUSE));      // still 0
    b.emit(lui(8, 'h10));               // x8 = 0x10000, inside the hole
    b.emit(lw(9, 8, 0));                // out-of-range load: flag only, x9 = 0
    b.emit(sw(1, 8, 0));                // out-of-range store: flag only
    b.emit(addi(10, 0, 'h7B));          // execution continues normally
    b.emit(INSTR_ECALL);
    send(b);
  endtask
endclass

// =============================================================================
// cpu_rand_seq.sv
// N random programs. Each one: header (MTVEC setup, x20 = CSR_BASE, x21 = 1), `num_ops` random
// operations, then a halt (ECALL or a software halt, chosen at random). Registers
// x1..x15 are the working set; x20/x21 and the handler's x30/x31 are never touched.
// Operations (one instruction each, so branch offsets are exact):
//    ALU: ADDI / ADD / SUB / AND / OR / LUI, often dependent on a recent result
//    LW / SW to L1 (0..0xFC) and to the external range (0x400..0x7FC)
//    BEQ and JAL, FORWARD only, skipping 1..3 instructions (never past the halt)
//    misaligned LW / SW (trap; MTVEC points at the handler at word 64, which resumes after the fault)
// Knobs (plusargs): +NUM_RAND=<programs>   default 50
//                   +RAND_OPS=<ops>        default 24 (max 48)
// =============================================================================
class cpu_rand_seq extends cpu_sequence;
  `uvm_object_utils(cpu_rand_seq)

  int unsigned num_programs = 50;
  int unsigned num_ops      = 24;

  function new(string name = "cpu_rand_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned n_arg;
    if ($value$plusargs("NUM_RAND=%d", n_arg)) num_programs = n_arg;
    if ($value$plusargs("RAND_OPS=%d", n_arg)) num_ops      = n_arg;
    if (num_ops > 48) num_ops = 48;          // keep every program below the handler at word 64

    for (int n = 0; n < num_programs; n++) begin
      cpu_program p = make_program($sformatf("random_%0d", n));
      bit [4:0]   last_rd = 1;
      int         first   = 5;               // ops start after the five header instructions
      int         halt_slot = first + num_ops;
      bit         sw_halt = ($urandom_range(0, 1) == 1);

      set_mtvec(p);                          // 3 instructions: MTVEC = handler at 0x100
      p.emit(addi(20, 0, -256));             // x20 = CSR_BASE
      p.emit(addi(21, 0, 1));                // x21 = 1 (software-halt value)
      for (int k = 0; k < num_ops; k++) begin
        int       slot = first + k;          // word index this op occupies
        bit [4:0] rd   = $urandom_range(1, 15);
        bit [4:0] rs1  = ($urandom_range(0, 9) < 4) ? last_rd : $urandom_range(0, 15);
        bit [4:0] rs2  = $urandom_range(0, 15);
        int       off  = 4 * $urandom_range(0, 63);                  // aligned, inside L1
        int       eoff = 'h400 + 4 * $urandom_range(0, 255);         // aligned, external
        int       imm  = $urandom_range(0, 200) - 100;
        int       room = halt_slot - slot - 1;                       // slots left before the halt
        int       skip = (room >= 1) ? $urandom_range(1, (room > 3) ? 3 : room) : 0;
        bit       use_zero_rd = ($urandom_range(0, 1) == 1);
        case ($urandom_range(0, 15))
          0:  begin p.emit(addi(rd, rs1, imm)); end
          1:  begin p.emit(add_(rd, rs1, rs2)); end
          2:  begin p.emit(sub_(rd, rs1, rs2)); end
          3:  begin p.emit(and_(rd, rs1, rs2)); end
          4:  begin p.emit(or_ (rd, rs1, rs2)); end
          5:  begin p.emit(lw(rd, 0, off)); end
          6:  begin p.emit(sw(rs2, 0, off)); end
          7:  begin p.emit(lui(rd, $urandom_range(0, 'hFFFFF))); end
          8:  begin p.emit(lw(rd, 0, eoff)); end
          9:  begin p.emit(sw(rs2, 0, eoff)); end
          10: begin p.emit(lw(rd, 0, eoff - 4 * $urandom_range(0, 1))); end   // external loads, often repeated (hits)
          11: if (skip > 0) begin p.emit(use_zero_rd ? beq(0, 0, 4 * (skip + 1)) : beq(rs1, rs2, 4 * (skip + 1))); end
              else          begin p.emit(addi(rd, rs1, imm)); end
          12: if (skip > 0) begin p.emit(jal(use_zero_rd ? 5'd0 : rd, 4 * (skip + 1))); end
              else          begin p.emit(addi(rd, rs1, imm)); end
          13: begin                                                    // misaligned access -> trap
                case ($urandom_range(0, 3))
                  0: p.emit(lw(rd, 0, off + 2));
                  1: p.emit(sw(rs2, 0, off + 2));
                  2: p.emit(lw(rd, 0, eoff + 2));
                  3: p.emit(sw(rs2, 0, eoff + 2));
                endcase

              end
          14: begin p.emit(add_(rd, last_rd, last_rd)); end   // back-to-back dependency
          15: begin p.emit(lw(rd, 0, off)); end    // L1 load, often used right away
        endcase
        last_rd = rd;
      end
      p.emit(sw_halt ? sw(21, 20, CSR_HALT) : INSTR_ECALL);
      add_skip_handler(p);
      send(p);
    end
  endtask
endclass

// =============================================================================
// cpu_decode_seq.sv   (decode / addressing modes)
// Walks every instruction format of the implemented subset with awkward operands,
// and feeds instructions the control unit must treat as NOPs. The golden model
// predicts every result, so a decode slip shows up as a wrong register or memory word.
//   decode_imm_extremes : I/U immediates at their limits, LUI with all bit patterns
//   decode_ldst_modes   : LW/SW base+offset: negative offsets, nonzero bases, L1 and external,
//                         the last external word 0x3FFC
//   decode_branches     : BEQ forward / backward / taken / not taken, JAL forward and backward,
//                         large offsets in both directions (sign bit exercised)
//   decode_rd_x0        : every instruction kind with rd = x0 (x0 must stay 0, consumers see 0)
//   decode_unsupported  : XOR SLT SLL SRA MUL, ANDI ORI SLLI XORI, LB LH LBU, SB SH, BNE BLT,
//                         JALR AUIPC EBREAK CSRRW, AND with a bad funct7 -> all NOPs, no state change
// =============================================================================
class cpu_decode_seq extends cpu_sequence;
  `uvm_object_utils(cpu_decode_seq)

  function new(string name = "cpu_decode_seq");
    super.new(name);
  endfunction

  task body();
    cpu_program a = make_program("decode_imm_extremes");
    cpu_program b = make_program("decode_ldst_modes");
    cpu_program c = make_program("decode_branches");
    cpu_program d = make_program("decode_rd_x0");
    cpu_program e = make_program("decode_unsupported");

    // ---- A: immediate extremes ----
    a.emit(addi(1, 0, 2047));            // +max I-immediate
    a.emit(addi(2, 0, -2048));           // -min I-immediate
    a.emit(add_(3, 1, 2));               // -1
    a.emit(addi(4, 1, 2047));            // 4094
    a.emit(addi(5, 2, -2048));           // -4096
    a.emit(lui (6, 20'hFFFFF));
    a.emit(lui (7, 20'h80000));
    a.emit(lui (8, 20'h00001));
    a.emit(lui (9, 20'hFFFFF));
    a.emit(addi(9, 9, -1));              // 0xFFFFEFFF
    a.emit(addi(10, 0, -1));
    a.emit(sub_(11, 0, 10));             // 1
    a.emit(and_(12, 6, 7));
    a.emit(or_ (13, 6, 8));
    a.emit(INSTR_ECALL);
    send(a);

    // ---- B: load/store addressing ----
    b.emit(addi(1, 0, 'h11));
    b.emit(addi(5, 0, 'h100));           // L1 base
    b.emit(sw(1, 5, 0));                 // 0x100
    b.emit(sw(1, 5, -4));                // 0x0FC (negative offset)
    b.emit(sw(1, 5, -256));              // 0x000 (most negative offset used)
    b.emit(sw(1, 5, 252));               // 0x1FC
    b.emit(lw(2, 5, 0));
    b.emit(lw(3, 5, -4));
    b.emit(lw(4, 5, -256));
    b.emit(lw(6, 5, 252));
    b.emit(addi(7, 0, 'h7FC));           // external base
    b.emit(sw(1, 7, 0));                 // 0x7FC
    b.emit(lw(8, 7, 0));
    b.emit(addi(9, 0, 'h600));
    b.emit(sw(1, 9, -512));              // 0x400 via negative offset from an external base
    b.emit(lw(10, 9, -512));
    b.emit(lw(11, 0, 2044));             // absolute 0x7FC, base x0, +max aligned offset
    b.emit(lw(12, 7, -4));               // 0x7F8
    b.emit(lui(13, 4));                  // x13 = 0x4000 (first address past the external range)
    b.emit(sw(1, 13, -4));               // 0x3FFC: last external word
    b.emit(lw(15, 13, -4));
    b.emit(lw(14, 13, -8));              // 0x3FF8
    b.emit(INSTR_ECALL);
    send(b);

    // ---- C: branches and jumps ----
    c.emit(addi(1, 0, 3));               // w0  loop counter
    c.emit(addi(2, 0, 0));               // w1  accumulator
    c.emit(addi(2, 2, 10));              // w2  loop body
    c.emit(addi(1, 1, -1));              // w3
    c.emit(beq(1, 0, 8));                // w4  forward BEQ, taken when the counter reaches 0
    c.emit(jal(0, -12));                 // w5  backward JAL to w2 (no link)
    c.emit(addi(3, 0, 5));               // w6
    c.emit(addi(4, 0, 2));               // w7
    c.emit(addi(5, 5, 1));               // w8  second loop body
    c.emit(addi(4, 4, -1));              // w9
    c.emit(beq(4, 0, 8));                // w10 forward BEQ
    c.emit(beq(0, 0, -12));              // w11 BACKWARD BEQ (taken) to w8
    c.emit(addi(6, 0, 6));               // w12
    c.emit(addi(7, 0, 1));               // w13
    c.emit(beq(7, 0, 8));                // w14 not taken
    c.emit(addi(8, 0, 8));               // w15 must run
    c.emit(addi(9, 0, 9));               // w16 must run
    c.emit(jal(10, 444));                // w17 big forward JAL to w128, x10 = 0x48
    c.emit(addi(11, 0, 'h7AD));          // w18 poison
    c.emit(addi(11, 0, 'h7AD));          // w19 poison
    c.emit(addi(14, 0, 14));             // w20 target of the backward JAL below
    c.emit(beq(0, 0, 716));              // w21 big forward BEQ (taken) to w200
    for (int i = 22; i < 31; i++) c.emit(addi(11, 0, 'h7AD));      // poison
    c.org(128);
    c.emit(addi(12, 0, 12));             // w128
    c.emit(jal(13, -436));               // w129 big BACKWARD JAL to w20, x13 = 0x208
    c.org(200);
    c.emit(addi(15, 0, 15));             // w200
    c.emit(INSTR_ECALL);                 // w201
    send(c);

    // ---- D: rd = x0 everywhere ----
    d.emit(addi(0, 0, 99));              // must not change x0
    d.emit(addi(1, 0, 5));               // x0 still reads 0 -> x1 = 5
    d.emit(lui (0, 20'hABCDE));
    d.emit(add_(2, 0, 1));               // 5
    d.emit(lw  (0, 0, 0));               // L1 load into x0
    d.emit(addi(6, 0, 'h400));
    d.emit(lw  (0, 6, 0));               // external load into x0 (stalls, still no write)
    d.emit(sub_(0, 1, 2));               // x1 - x2 = 0, discarded
    d.emit(jal (0, 8));                  // no link, skip next
    d.emit(addi(3, 0, 'h7AD));           // poison
    d.emit(addi(4, 0, 4));
    d.emit(or_ (5, 0, 1));               // 5
    d.emit(INSTR_ECALL);
    send(d);

    // ---- E: unsupported instructions decode as NOPs ----
    e.emit(addi(1, 0, 12));
    e.emit(addi(2, 0, 5));
    e.emit(enc_r(OP,  10, 3'h4, 1, 2, 7'h00));        // XOR
    e.emit(enc_r(OP,  11, 3'h2, 1, 2, 7'h00));        // SLT
    e.emit(enc_r(OP,  12, 3'h1, 1, 2, 7'h00));        // SLL
    e.emit(enc_r(OP,  13, 3'h5, 1, 2, 7'h20));        // SRA
    e.emit(enc_r(OP,  14, 3'h0, 1, 2, 7'h01));        // MUL
    e.emit(enc_r(OP,  15, F3_AND, 1, 2, 7'h20));      // AND with a wrong funct7
    e.emit(enc_i(OP_IMM, 16, 3'h7, 1, 5));            // ANDI
    e.emit(enc_i(OP_IMM, 17, 3'h6, 1, 5));            // ORI
    e.emit(enc_i(OP_IMM, 18, 3'h1, 1, 3));            // SLLI
    e.emit(enc_i(OP_IMM, 19, 3'h4, 1, 5));            // XORI
    e.emit(enc_i(LOAD,   20, 3'h0, 0, 0));            // LB
    e.emit(enc_i(LOAD,   21, 3'h1, 0, 0));            // LH
    e.emit(enc_i(LOAD,   22, 3'h4, 0, 0));            // LBU
    e.emit(enc_s(STORE,  3'h0, 0, 1, 'h20));          // SB (must not write memory)
    e.emit(enc_s(STORE,  3'h1, 0, 1, 'h24));          // SH
    e.emit(enc_b(BRANCH, 3'h1, 1, 2, 8));             // BNE (x1 != x2: a real BNE would skip the next instruction)
    e.emit(addi(27, 0, 27));                          // must run
    e.emit(enc_b(BRANCH, 3'h4, 2, 1, 8));             // BLT (5 < 12: a real BLT would branch)
    e.emit(addi(28, 0, 28));                          // must run
    e.emit(enc_i(7'b1100111, 23, 3'h0, 1, 0));        // JALR
    e.emit(enc_u(7'b0010111, 24, 20'h12345));         // AUIPC
    e.emit(32'h0010_0073);                            // EBREAK
    e.emit(enc_i(SYSTEM, 25, 3'h1, 1, 'h340));        // CSRRW
    e.emit(addi(26, 0, 'h2A));                        // must run
    e.emit(INSTR_ECALL);
    send(e);
  endtask
endclass

// =============================================================================
// cpu_pipeline_seq.sv   (5-stage pipeline: no stall, stall, resume)
// Programs declare how far apart their instructions must retire (exp_gap_*), and
// cpu_retire_checker enforces it:
//   pipe_nostall       : 5 independent ALU ops back to back  -> one retire per cycle
//   pipe_forward_chain : 5 dependent ops, forwarded, no stall -> still one retire per cycle
//   pipe_loaduse       : load-use on rs1 / rs2 / base / store-data -> exactly one bubble each
//   pipe_stall_resume  : external store (+4), iMC load (+7), L2-hit load (+0), then normal work resumes
//   pipe_stall_branch  : an iMC load whose value feeds a taken BEQ: stall, then the flush is still correct
//   pipe_l2_alias      : two addresses that share an L2 line but differ in tag: the second must NOT hit
// =============================================================================
class cpu_pipeline_seq extends cpu_sequence;
  `uvm_object_utils(cpu_pipeline_seq)

  function new(string name = "cpu_pipeline_seq");
    super.new(name);
  endfunction

  task body();
    cpu_program a = make_program("pipe_nostall");
    cpu_program b = make_program("pipe_forward_chain");
    cpu_program c = make_program("pipe_loaduse");
    cpu_program d = make_program("pipe_stall_resume");
    cpu_program e = make_program("pipe_stall_branch");
    cpu_program f = make_program("pipe_l2_alias");

    // ---- A: independent instructions ----
    a.exp_gap_default = 1;
    a.emit(addi(1, 0, 1));
    a.emit(addi(2, 0, 2));
    a.emit(addi(3, 0, 3));
    a.emit(addi(4, 0, 4));
    a.emit(addi(5, 0, 5));
    a.emit(add_(6, 1, 2));
    a.emit(add_(7, 3, 4));
    a.emit(sub_(8, 5, 1));
    a.emit(and_(9, 2, 3));
    a.emit(or_ (10, 4, 5));
    a.emit(INSTR_ECALL);
    send(a);

    // ---- B: dependent chain, resolved by forwarding ----
    b.exp_gap_default = 1;
    b.emit(addi(1, 0, 1));
    b.emit(add_(1, 1, 1));
    b.emit(add_(1, 1, 1));
    b.emit(add_(1, 1, 1));
    b.emit(add_(1, 1, 1));
    b.emit(add_(2, 1, 1));
    b.emit(sub_(3, 2, 1));
    b.emit(INSTR_ECALL);
    send(b);

    // ---- C: load-use hazards: one bubble every time, none when an instruction separates them ----
    c.exp_gap_default = 1;
    c.emit(addi(1, 0, 4));               // #0
    c.emit(sw(1, 0, 0));                 // #1  mem[0] = 4
    c.emit(sw(1, 0, 4));                 // #2  mem[1] = 4
    c.emit(lw(2, 0, 0));                 // #3
    c.emit(add_(3, 2, 2));               // #4  uses the load result at once  -> +1
    c.exp_gap_at[4] = 2;
    c.emit(lw(4, 0, 0));                 // #5
    c.emit(addi(5, 0, 1));               // #6  independent instruction in between
    c.emit(add_(6, 4, 5));               // #7  no stall
    c.emit(lw(7, 0, 4));                 // #8
    c.emit(add_(8, 1, 7));               // #9  load result as rs2           -> +1
    c.exp_gap_at[9] = 2;
    c.emit(lw(9, 0, 0));                 // #10 x9 = 4
    c.emit(lw(10, 9, 0));                // #11 load result as BASE address  -> +1
    c.exp_gap_at[11] = 2;
    c.emit(sw(10, 0, 8));                // #12 load result as store DATA    -> +1
    c.exp_gap_at[12] = 2;
    c.emit(INSTR_ECALL);                 // #13
    send(c);

    // ---- D: stalls and resume ----
    d.exp_gap_default = 1;
    d.emit(addi(1, 0, 'h55));            // #0
    d.emit(addi(5, 0, 'h400));           // #1
    d.emit(sw(1, 5, 0));                 // #2  external store: +4 cycles
    d.exp_gap_at[2] = 1 + 4;
    d.emit(addi(2, 0, 2));               // #3  pipeline resumes: 1 per cycle again
    d.emit(lw(3, 5, 0));                 // #4  cold load from the iMC: +7 cycles
    d.exp_gap_at[4] = 1 + 7;
    d.emit(addi(4, 0, 4));               // #5
    d.emit(lw(6, 5, 0));                 // #6  L2 hit: no stall
    d.emit(add_(7, 6, 6));               // #7  load-use: +1
    d.exp_gap_at[7] = 2;
    d.emit(add_(8, 3, 4));               // #8
    d.emit(INSTR_ECALL);                 // #9
    send(d);

    // ---- E: iMC load feeding a taken branch (stall + load-use + flush together) ----
    e.emit(addi(1, 0, 5));
    e.emit(addi(5, 0, 'h400));
    e.emit(sw(1, 5, 0));                 // external store of 5
    e.emit(lw(2, 5, 0));                 // iMC load
    e.emit(beq(2, 1, 12));               // taken (5 == 5), operand just loaded
    e.emit(addi(6, 0, 'h7AD));           // poison
    e.emit(addi(7, 0, 'h7AD));           // poison
    e.emit(addi(8, 0, 8));
    e.emit(INSTR_ECALL);
    send(e);

    // ---- F: L2 alias: same index, different tag. A hit that ignores the tag returns A's data for B ----
    f.emit(addi(1, 0, 'h11));
    f.emit(addi(2, 0, 'h22));
    f.emit(addi(5, 0, 'h400));           // A = 0x400
    f.emit(addi(6, 0, 'h500));           // B = 0x500: same L2 index as A, different tag
    f.emit(sw(1, 5, 0));                 // mem[A] = 0x11  (external store, no allocate)
    f.emit(sw(2, 6, 0));                 // mem[B] = 0x22
    f.emit(lw(3, 5, 0));                 // A: iMC, fills the L2 line
    f.emit(lw(4, 6, 0));                 // B: must MISS (tag differs) and return 0x22
    f.emit(lw(7, 5, 0));                 // A: L2 miss (B evicted it), L3 hit
    f.emit(add_(8, 3, 4));               // 0x33
    f.emit(INSTR_ECALL);
    send(f);
  endtask
endclass

// =============================================================================
// cpu_cache_seq.sv   (L1 / L2 / L3 / iMC, read and write)
// cpu_mem_checker holds an independent model of the two caches and predicts, for
// every external load, whether L2, L3 or the iMC serves it (and the stall that costs).
// L2: 64 lines, index addr[7:2].  L3: 128 lines, index addr[8:2].  Both direct-mapped,
// read-allocate, write-through, writes update a line only if it is already present.
//   0x400 / 0x500 / 0x600 / 0x700 all share an L2 index; 0x400 and 0x600 also share an L3 index.
//   cache_levels   : cold miss, L2 hit, L2 conflict -> L3 hit, double conflict -> iMC again,
//                    write hit updates both caches, write miss does not allocate
//   cache_conflict : 60 random loads/stores over the four alias addresses plus two neighbours
//   cache_edges    : first and last external words, L1/external boundary
//   cache_wide_data: 32-bit patterns with every byte lane non-zero (catches a bad write strobe or a dropped byte)
// =============================================================================
class cpu_cache_seq extends cpu_sequence;
  `uvm_object_utils(cpu_cache_seq)

  function new(string name = "cpu_cache_seq");
    super.new(name);
  endfunction

  task body();
    cpu_program a = make_program("cache_levels");
    cpu_program b = make_program("cache_conflict");
    cpu_program c = make_program("cache_edges");
    cpu_program d = make_program("cache_wide_data");

    // ---- A: the level ladder ----
    a.emit(addi(1, 0, 'h11));
    a.emit(addi(5, 0, 'h400));           // A  = 0x400
    a.emit(addi(6, 0, 'h500));           // B  = 0x500 (same L2 index as A, different L3 index)
    a.emit(addi(7, 0, 'h600));           // C  = 0x600 (same L2 AND L3 index as A)
    a.emit(sw(1, 5, 0));                 // store miss: goes to the iMC, allocates nothing
    a.emit(lw(2, 5, 0));                 // A: iMC (cold)
    a.emit(lw(3, 5, 0));                 // A: L2 hit
    a.emit(lw(4, 6, 0));                 // B: iMC (cold), evicts A from L2 only
    a.emit(lw(8, 5, 0));                 // A: L2 miss, L3 hit
    a.emit(lw(9, 7, 0));                 // C: iMC (cold), evicts A from L2 and L3
    a.emit(lw(10, 5, 0));                // A: iMC again
    a.emit(lw(11, 5, 0));                // A: L2 hit
    a.emit(addi(12, 0, 'h77));
    a.emit(sw(12, 5, 0));                // write hit: both caches updated, iMC written
    a.emit(lw(13, 5, 0));                // A: L2 hit, must return 0x77
    a.emit(lw(14, 6, 0));                // B: L2 miss, L3 hit (B survived in L3); evicts A from L2
    a.emit(lw(15, 5, 0));                // A: L2 miss, L3 hit, must return 0x77 (L3 saw the write)
    a.emit(sw(1, 5, 4));                 // store to a never-read word: no allocate
    a.emit(lw(16, 5, 4));                // iMC
    a.emit(lw(17, 5, 4));                // L2 hit
    a.emit(add_(18, 17, 17));            // load-use on a 0-stall hit: needs the 1-cycle bubble, else x18 is wrong
    a.emit(INSTR_ECALL);
    send(a);

    // ---- D: every byte lane carries data, through every level ----
    d.emit(lui(1, 'hA1B2C));              // x1 = 0xA1B2C000
    d.emit(addi(1, 1, 'h3D4));            // x1 = 0xA1B2C3D4 (low half positive, so no borrow)
    d.emit(lui(2, 'h5E6F7));
    d.emit(addi(2, 2, 'h6A8));            // x2 = 0x5E6F76A8
    d.emit(addi(5, 0, 'h400));
    d.emit(addi(6, 0, 'h500));
    d.emit(sw(1, 5, 0));                  // write miss -> iMC; all four strobes must be set
    d.emit(lw(3, 5, 0));                  // iMC read back
    d.emit(lw(4, 5, 0));                  // L2 hit
    d.emit(sw(2, 5, 0));                  // write hit: L2, L3 and iMC updated with the new pattern
    d.emit(lw(7, 5, 0));                  // L2 hit, must be 0x5E6F76A8
    d.emit(lw(8, 6, 0));                  // conflicting line evicts A from L2
    d.emit(lw(9, 5, 0));                  // L3 hit, must still be 0x5E6F76A8
    d.emit(sw(1, 6, 4));
    d.emit(lw(10, 6, 4));                 // different word, other pattern, iMC then cached
    d.emit(INSTR_ECALL);
    send(d);

    // ---- B: random conflict traffic over the alias set ----
    begin
      int unsigned addrs [6] = '{'h400, 'h500, 'h600, 'h700, 'h404, 'h504};
      b.emit(addi(1, 0, 'h21));
      b.emit(addi(5, 0, 'h400));
      b.emit(addi(6, 0, 'h500));
      b.emit(addi(7, 0, 'h600));
      b.emit(addi(8, 0, 'h700));
      for (int i = 0; i < 60; i++) begin
        int unsigned ad = addrs[$urandom_range(0, 5)];
        bit [4:0] base = (ad == 'h400 || ad == 'h404) ? 5'd5 : (ad == 'h500 || ad == 'h504) ? 5'd6 : (ad == 'h600) ? 5'd7 : 5'd8;
        int off = (ad == 'h404 || ad == 'h504) ? 4 : 0;
        bit [4:0] rd = $urandom_range(9, 15);
        if ($urandom_range(0, 3) == 0) b.emit(sw(1, base, off));       // 25% stores
        else                           b.emit(lw(rd, base, off));
      end
      b.emit(INSTR_ECALL);
      send(b);
    end

    // ---- C: edges of the external range ----
    c.emit(addi(1, 0, 'h5A));
    c.emit(lui (13, 4));                 // 0x4000
    c.emit(sw(1, 13, -4));               // 0x3FFC last external word
    c.emit(lw(2, 13, -4));               // iMC
    c.emit(lw(3, 13, -4));               // L2 hit
    c.emit(sw(1, 0, 'h3FC));             // last L1 word
    c.emit(lw(4, 0, 'h3FC));
    c.emit(addi(5, 0, 'h400));           // first external word
    c.emit(sw(1, 5, 0));
    c.emit(lw(6, 5, 0));                 // iMC
    c.emit(lw(7, 5, 0));                 // L2 hit
    c.emit(INSTR_ECALL);
    send(c);
  endtask
endclass

// =============================================================================
// cpu_status_seq.sv   (status / fault outputs, one at a time)
// Every DUT status output gets a program that must raise it, and a "twin" that
// looks similar but is legal and must stay quiet. Each program PINS the pulse
// counts the output must show (exp_misalign / exp_oor / exp_target / exp_traps);
// the scoreboard compares them with the DUT, so a missing OR a spurious pulse fails.
//   fault_mem_misaligned : LW/SW at +2 in L1, external, CSR window;  twin: aligned accesses
//   fault_mem_out_of_range: hole and past-the-CSR-window loads/stores; twin: valid CSR words
//   fault_misaligned_target: JAL / taken BEQ to a bad target;  twins: not-taken BEQ, shadow faults
//   trap_taken           : one pulse per fault, incl. right after a stall and back to back
// All traps use the skip-4 handler at word 64 (MTVEC is pointed at it first).
// =============================================================================
class cpu_status_seq extends cpu_sequence;
  `uvm_object_utils(cpu_status_seq)

  function new(string name = "cpu_status_seq");
    super.new(name);
  endfunction

  // pin the expected pulse counts and add the handler
  function void pins(cpu_program p, int mis, int oor, int tgt, int traps);
    p.exp_misalign = mis;  p.exp_oor = oor;  p.exp_target = tgt;  p.exp_traps = traps;
    add_skip_handler(p);
  endfunction

  // one program = setup lines + the probe instruction(s) + ECALL, with its pins
  task prog(string name, int mis, int oor, int tgt, int traps,
            bit [31:0] i0 = INSTR_NOP, bit [31:0] i1 = INSTR_NOP, bit [31:0] i2 = INSTR_NOP, bit [31:0] i3 = INSTR_NOP);
    cpu_program p = make_program(name);
    set_mtvec(p);                        // MTVEC = handler (needed before any trap)
    p.emit(addi(1, 0, 5));
    p.emit(addi(20, 0, -256));           // CSR_BASE
    p.emit(addi(5, 0, 'h400));
    p.emit(lui (8, 'h10));               // 0x10000: inside the address hole
    p.emit(i0);  p.emit(i1);  p.emit(i2);  p.emit(i3);
    p.emit(addi(3, 0, 3));               // execution continues normally afterwards
    p.emit(INSTR_ECALL);
    pins(p, mis, oor, tgt, traps);
    send(p);
  endtask

  task body();
    // ---- fault_mem_misaligned (+ trap_taken) ----
    prog("st_misalign_lw_l1",   1, 0, 0, 1, lw(2, 0, 2));
    prog("st_misalign_sw_l1",   1, 0, 0, 1, sw(1, 0, 6));
    prog("st_misalign_lw_ext",  1, 0, 0, 1, lw(2, 0, 'h402));
    prog("st_misalign_sw_ext",  1, 0, 0, 1, sw(1, 0, 'h406));
    prog("st_misalign_lw_csr",  1, 0, 0, 1, lw(2, 20, 2));
    prog("st_misalign_twin",    0, 0, 0, 0, lw(2, 0, 0), sw(1, 0, 4), lw(3, 0, 'h400), sw(1, 0, 'h404));
    // ---- fault_mem_out_of_range (no trap) ----
    prog("st_oor_hole_lw",      0, 1, 0, 0, lw(9, 8, 0));
    prog("st_oor_hole_sw",      0, 1, 0, 0, sw(1, 8, 0));
    prog("st_oor_csr_lw",       0, 1, 0, 0, lw(9, 20, 'h20));        // CSR word 8: first one past the window
    prog("st_oor_csr_sw",       0, 1, 0, 0, sw(1, 20, 'h24));
    prog("st_oor_twin",         0, 0, 0, 0, lw(9, 20, 'h1C), sw(1, 20, 'h0C), lw(10, 20, 'h0C));   // last valid CSR words
    // ---- fault_misaligned_target (+ trap_taken) ----
    prog("st_target_jal",       0, 0, 1, 1, jal(6, 6));              // target = pc + 6
    prog("st_target_beq_taken", 0, 0, 1, 1, beq(0, 0, 6));
    prog("st_target_beq_twin",  0, 0, 0, 0, beq(1, 0, 6));           // NOT taken: a bad target alone is no fault
    // ---- faults in the shadow of a taken branch must be squashed ----
    prog("st_shadow_no_fault",  0, 0, 0, 0, beq(0, 0, 12), lw(2, 0, 2), sw(1, 0, 6));
    // ---- trap right behind a stall, and traps back to back ----
    prog("st_trap_after_stall", 1, 0, 0, 1, sw(1, 5, 0), lw(2, 0, 2));
    prog("st_two_traps",        2, 0, 0, 2, lw(2, 0, 2), lw(4, 0, 6));
    // ---- no fault at all, then a halt ----
    prog("st_quiet_halt",       0, 0, 0, 0);
  endtask
endclass

// =============================================================================
// cpu_csr_seq.sv   (CSR register behaviour; golden model predicts, plus pinned values)
//   csr_scratch_ro   : SCRATCH reads back what was written; writes to the read-only registers
//                      (CYCLE, INSTR, MCAUSE, MTVAL) are ignored; HALT_CTRL bit 0 = 0 does not halt
//   csr_align_masks  : MTVEC and MEPC force their low two bits to 0
//   csr_trap_capture : a trap writes MCAUSE / MTVAL / MEPC (cause 4 for a load, 6 for a store)
//   csr_mepc_mret    : software writes MEPC, MRET jumps there, younger instructions are squashed
//   csr_counters     : INSTR_COUNT and CYCLE_COUNT advance by what the program executed
// =============================================================================
class cpu_csr_seq extends cpu_sequence;
  `uvm_object_utils(cpu_csr_seq)

  function new(string name = "cpu_csr_seq");
    super.new(name);
  endfunction

  task body();
    cpu_program a = make_program("csr_scratch_ro");
    cpu_program b = make_program("csr_align_masks");
    cpu_program c = make_program("csr_trap_capture");
    cpu_program d = make_program("csr_mepc_mret");
    cpu_program e = make_program("csr_counters");

    // ---- A: SCRATCH, read-only registers, HALT_CTRL with bit 0 clear ----
    a.emit(addi(20, 0, -256));              // x20 = CSR_BASE
    a.emit(addi(1, 0, 'h5A5));
    a.emit(sw(1, 20, CSR_SCRATCH));
    a.emit(lw(2, 20, CSR_SCRATCH));         // x2 = 0x5A5
    a.emit(lui(3, 'hDEADB));
    a.emit(sw(3, 20, CSR_SCRATCH));
    a.emit(lw(4, 20, CSR_SCRATCH));         // x4 = 0xDEADB000: full 32 bits kept
    a.emit(addi(5, 0, 'h77));
    a.emit(sw(5, 20, 'h00));                // CYCLE   read-only: ignored
    a.emit(sw(5, 20, 'h04));                // INSTR   read-only: ignored
    a.emit(sw(5, 20, CSR_MCAUSE));          // MCAUSE  read-only: ignored
    a.emit(sw(5, 20, CSR_MTVAL));           // MTVAL   read-only: ignored
    a.emit(lw(6, 20, CSR_MCAUSE));          // x6 = 0
    a.emit(lw(7, 20, CSR_MTVAL));           // x7 = 0
    a.emit(lw(8, 20, 'h04));                // x8 = retired count so far (model predicts it exactly)
    a.emit(addi(9, 0, 'hFE));
    a.emit(sw(9, 20, CSR_HALT));            // bit 0 clear: must NOT halt
    a.emit(lw(10, 20, CSR_HALT));           // x10 = 0xFE
    a.emit(addi(11, 0, 11));                // still running
    a.emit(INSTR_ECALL);
    a.pin_reg_range(2,  'h5A5,       'h5A5);
    a.pin_reg_range(4,  'hDEADB000,  'hDEADB000);
    a.pin_reg_range(6,  0, 0);
    a.pin_reg_range(7,  0, 0);
    a.pin_reg_range(10, 'hFE, 'hFE);
    a.pin_reg_range(11, 11, 11);
    a.exp_traps = 0;
    send(a);

    // ---- B: low two bits of MTVEC and MEPC are forced to 0 ----
    b.emit(addi(20, 0, -256));
    b.emit(addi(1, 0, 'h107));
    b.emit(sw(1, 20, CSR_MTVEC));
    b.emit(lw(2, 20, CSR_MTVEC));           // x2 = 0x104
    b.emit(addi(3, 0, 'h2B3));
    b.emit(sw(3, 20, CSR_MEPC));
    b.emit(lw(4, 20, CSR_MEPC));            // x4 = 0x2B0
    b.emit(INSTR_ECALL);
    b.pin_reg_range(2, 'h104, 'h104);
    b.pin_reg_range(4, 'h2B0, 'h2B0);
    b.exp_traps = 0;
    send(b);

    // ---- C: a trap fills MCAUSE / MTVAL / MEPC ----
    set_mtvec(c);                           // slots 0..2
    c.emit(addi(20, 0, -256));              // 3
    c.emit(addi(1, 0, 5));                  // 4
    c.emit(lw(2, 0, 2));                    // 5  misaligned load (address 2): cause 4
    c.emit(lw(10, 20, CSR_MCAUSE));         // x10 = 4
    c.emit(lw(11, 20, CSR_MTVAL));          // x11 = 2
    c.emit(lw(12, 20, CSR_MEPC));           // x12 = 0x18: handler stored MEPC + 4 (slot 5 = 0x14)
    c.emit(sw(1, 0, 6));                    //    misaligned store (address 6): cause 6
    c.emit(lw(13, 20, CSR_MCAUSE));         // x13 = 6
    c.emit(lw(14, 20, CSR_MTVAL));          // x14 = 6
    c.emit(INSTR_ECALL);
    add_skip_handler(c);
    c.pin_reg_range(10, 4, 4);   c.pin_reg_range(11, 2, 2);   c.pin_reg_range(12, 'h18, 'h18);
    c.pin_reg_range(13, 6, 6);   c.pin_reg_range(14, 6, 6);
    c.exp_misalign = 2;  c.exp_traps = 2;
    send(c);

    // ---- D: software sets MEPC, MRET goes there ----
    set_mtvec(d);                           // 0..2
    d.emit(addi(20, 0, -256));              // 3
    d.emit(addi(1, 0, 'h24));               // 4  target = slot 9
    d.emit(sw(1, 20, CSR_MEPC));            // 5
    d.emit(INSTR_MRET);                     // 6
    d.emit(addi(9, 0, 'h7AD));              // 7  squashed
    d.emit(addi(9, 0, 'h7AD));              // 8  squashed
    d.emit(addi(5, 0, 5));                  // 9  MRET lands here
    d.emit(INSTR_ECALL);
    add_skip_handler(d);
    d.pin_reg_range(9, 0, 0);
    d.pin_reg_range(5, 5, 5);
    d.exp_traps = 0;
    send(d);

    // ---- E: counters advance by what ran between two reads ----
    e.emit(addi(20, 0, -256));              // 0
    e.emit(lw(1, 20, 'h04));                // 1  INSTR_COUNT read 1
    e.emit(addi(5, 0, 1));
    e.emit(addi(5, 0, 2));
    e.emit(addi(5, 0, 3));
    e.emit(addi(5, 0, 4));
    e.emit(addi(5, 0, 5));
    e.emit(lw(2, 20, 'h04));                // 7  INSTR_COUNT read 2
    e.emit(sub_(3, 2, 1));                  // x3 = 6: the first LW plus five ADDIs
    e.emit(lw(6, 20, 'h00));                // 9  CYCLE read 1 (value unknown to the model)
    e.emit(addi(5, 0, 1));
    e.emit(addi(5, 0, 2));
    e.emit(addi(5, 0, 3));
    e.emit(addi(5, 0, 4));
    e.emit(addi(5, 0, 5));
    e.emit(addi(5, 0, 6));
    e.emit(lw(7, 20, 'h00));                // 16 CYCLE read 2
    e.emit(sub_(8, 7, 6));                  // x8 = cycles between the two reads: one per instruction, 7
    e.emit(INSTR_ECALL);
    e.pin_reg_range(3, 6, 6);
    e.pin_reg_range(8, 7, 7);
    e.exp_traps = 0;
    send(e);
  endtask
endclass

// =============================================================================
// cpu_runoff_seq.sv   (running past the end of instruction memory)
// The fetch index is pc[9:2], so the PC passing word 255 wraps to word 0 and the
// program runs again from there. The golden model wraps the same way.
//   runoff_fallthrough : jump to word 253, fall through 254 and 255, wrap to word 0
//   runoff_branch_wrap : a taken BEQ whose target (0x408) is beyond the memory: lands on word 2
//   runoff_jal_wrap    : the same with JAL
// =============================================================================
class cpu_runoff_seq extends cpu_sequence;
  `uvm_object_utils(cpu_runoff_seq)

  function new(string name = "cpu_runoff_seq");
    super.new(name);
  endfunction

  task body();
    cpu_program a = make_program("runoff_fallthrough");
    cpu_program b = make_program("runoff_branch_wrap");
    cpu_program c = make_program("runoff_jal_wrap");

    // ---- A: x2 = 0 on the first pass (branch taken), 1 after the wrap (branch not taken -> ECALL) ----
    a.emit(beq(2, 0, 253 * 4));             // slot 0: first pass jumps to slot 253
    a.emit(INSTR_ECALL);                    // slot 1: reached after the wrap
    a.org(253);
    a.emit(addi(1, 0, 'h11));               // 253
    a.emit(addi(2, 0, 1));                  // 254
    a.emit(addi(3, 0, 'h33));               // 255: next fetch address 0x400 wraps to word 0
    a.pin_reg_range(1, 'h11, 'h11);  a.pin_reg_range(2, 1, 1);  a.pin_reg_range(3, 'h33, 'h33);
    send(a);

    // ---- B: branch target beyond the end ----
    b.emit(beq(2, 0, 1032));                // slot 0: target 0x408 -> word 2
    b.emit(addi(9, 0, 'h7AD));              // slot 1: skipped
    b.emit(addi(2, 0, 1));                  // slot 2
    b.emit(addi(5, 0, 5));                  // slot 3
    b.emit(INSTR_ECALL);                    // slot 4
    b.pin_reg_range(9, 0, 0);  b.pin_reg_range(2, 1, 1);  b.pin_reg_range(5, 5, 5);
    send(b);

    // ---- C: JAL target beyond the end; the link register still gets pc + 4 ----
    c.emit(jal(1, 1032));                   // slot 0: x1 = 4, target 0x408 -> word 2
    c.emit(addi(9, 0, 'h7AD));              // slot 1: skipped
    c.emit(addi(5, 0, 5));                  // slot 2
    c.emit(INSTR_ECALL);                    // slot 3
    c.pin_reg_range(1, 4, 4);  c.pin_reg_range(9, 0, 0);  c.pin_reg_range(5, 5, 5);
    send(c);
  endtask
endclass

// =============================================================================
// cpu_reset_seq.sv   (reset in the middle of a run, then restart)
// A "victim" program dirties every kind of state (L1, external memory and both caches, SCRATCH,
// MEPC/MCAUSE/MTVAL, a trap) and is cut off by a reset after N clocks (abort_at). A "probe"
// program then runs from the reset and reads everything back: all of it must read 0, because
// the reset has to clear it. N lands in a different place each time (during the stores, the
// iMC loads, the trap ...): a fixed list plus +RST_RAND=<n> random cut points (default 6).
// =============================================================================
class cpu_reset_seq extends cpu_sequence;
  `uvm_object_utils(cpu_reset_seq)

  function new(string name = "cpu_reset_seq");
    super.new(name);
  endfunction

  function cpu_program victim(int n);
    cpu_program p = make_program($sformatf("reset_victim_at_%0d", n));
    set_mtvec(p);                           // 0..2
    p.emit(addi(20, 0, -256));              // 3  CSR_BASE
    p.emit(addi(1, 0, 'h5A5));              // 4
    p.emit(addi(5, 0, 'h400));              // 5
    p.emit(addi(6, 0, 'h500));              // 6
    p.emit(sw(1, 0, 0));                    // 7  L1 words
    p.emit(sw(1, 0, 4));                    // 8
    p.emit(sw(1, 5, 0));                    // 9  external stores (stall)
    p.emit(sw(1, 6, 0));                    // 10
    p.emit(lw(2, 5, 0));                    // 11 iMC loads: fill L2 and L3
    p.emit(lw(3, 6, 0));                    // 12
    p.emit(sw(1, 20, CSR_SCRATCH));         // 13 SCRATCH dirty
    p.emit(sw(5, 20, CSR_MEPC));            // 14 MEPC dirty
    p.emit(lw(4, 0, 2));                    // 15 misaligned: a trap, MCAUSE / MTVAL / MEPC dirty
    p.org(60);
    p.emit(INSTR_ECALL);                    // 60: the victim would only halt after ~100 clocks
    add_skip_handler(p);
    p.abort_at = n;
    return p;
  endfunction

  function cpu_program probe();
    cpu_program p = make_program("reset_probe");
    p.emit(addi(20, 0, -256));              // 0
    p.emit(addi(5, 0, 'h400));              // 1
    p.emit(addi(6, 0, 'h500));              // 2
    p.emit(lw(1, 0, 0));                    // L1 words the victim wrote
    p.emit(lw(2, 0, 4));
    p.emit(lw(3, 5, 0));                    // external words the victim wrote (and cached)
    p.emit(lw(4, 6, 0));
    p.emit(lw(7, 20, CSR_SCRATCH));
    p.emit(lw(8, 20, CSR_MTVEC));
    p.emit(lw(9, 20, CSR_MEPC));
    p.emit(lw(10, 20, CSR_MCAUSE));
    p.emit(lw(11, 20, CSR_MTVAL));
    p.emit(lw(12, 20, CSR_HALT));
    p.emit(INSTR_ECALL);
    p.pin_reg_range(1, 0, 0);  p.pin_reg_range(2, 0, 0);  p.pin_reg_range(3, 0, 0);  p.pin_reg_range(4, 0, 0);
    p.pin_reg_range(7, 0, 0);  p.pin_reg_range(8, 0, 0);  p.pin_reg_range(9, 0, 0);
    p.pin_reg_range(10, 0, 0); p.pin_reg_range(11, 0, 0); p.pin_reg_range(12, 0, 0);
    p.exp_traps = 0;
    return p;
  endfunction

  task body();
    int unsigned n_rand = 6;
    int unsigned cuts [$] = '{4, 9, 15, 22, 28, 34, 41, 50, 60, 75};
    void'($value$plusargs("RST_RAND=%d", n_rand));
    repeat (n_rand) cuts.push_back($urandom_range(3, 90));
    foreach (cuts[i]) begin
      send(victim(cuts[i]));
      send(probe());
    end
  endtask
endclass

// =============================================================================
// cpu_known_issue_seq.sv   (misaligned address beyond the CSR window / in the address hole)
// Rule used: a misaligned access traps and raises ONLY the misaligned flag, whatever region it
// is in. The L1 and external regions already behave that way. In the CSR window (beyond its 8
// words) and in the address hole this DUT raises the out-of-range flag as well, so these
// programs are expected to FAIL on the DUT. They run in cpu_known_issue_test, which is not
// part of `all` or the regression.
// =============================================================================
class cpu_known_issue_seq extends cpu_sequence;
  `uvm_object_utils(cpu_known_issue_seq)

  function new(string name = "cpu_known_issue_seq");
    super.new(name);
  endfunction

  task kprog(string name, bit [31:0] probe);
    cpu_program p = make_program(name);
    set_mtvec(p);
    p.emit(addi(1, 0, 5));
    p.emit(addi(20, 0, -256));             // CSR_BASE
    p.emit(lui (8, 'h10));                 // 0x10000: inside the address hole
    p.emit(probe);
    p.emit(addi(3, 0, 3));
    p.emit(INSTR_ECALL);
    add_skip_handler(p);
    p.exp_misalign = 1;  p.exp_oor = 0;  p.exp_target = 0;  p.exp_traps = 1;
    send(p);
  endtask

  task body();
    kprog("ki_csr_lw",  lw(2, 20, 'h22));          // 0xFFFFFF22: past the 8 words and misaligned
    kprog("ki_csr_sw",  sw(1, 20, 'h26));
    kprog("ki_hole_lw", lw(2, 8, 2));              // 0x10002: hole and misaligned
    kprog("ki_hole_sw", sw(1, 8, 6));
  endtask
endclass
