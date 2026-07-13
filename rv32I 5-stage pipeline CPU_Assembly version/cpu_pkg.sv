// =============================================================================
// cpu_pkg.sv
// UVM package for RV32I-subset pipelined CPU verification.
//
// Main updates from the old custom 16-bit CPU package:
//   - 32-bit instruction/data/register values
//   - 32 architectural registers, x0 hardwired zero
//   - RV32I instruction encoders for R/I/S/B/U/J formats
//   - DPI-C imports use int, not shortint
//   - Backdoor load/read paths still assume DUT instance is tb_top.dut
//   - Scoreboard compares final architectural state against golden_model.c
// =============================================================================

package cpu_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ---------------------------------------------------------------------------
  // DPI-C golden model imports. These must match golden_model.c exactly.
  // ---------------------------------------------------------------------------
  import "DPI-C" function void gm_reset();
  import "DPI-C" function void gm_load_instr(input int addr, input int instr);
  import "DPI-C" function void gm_load_data (input int addr, input int value);
  import "DPI-C" function void gm_run       (input int max_steps);
  import "DPI-C" function int  gm_get_reg   (input int idx);
  import "DPI-C" function int  gm_get_mem   (input int addr);
  import "DPI-C" function int  gm_get_pc    ();
  import "DPI-C" function int  gm_is_halted ();

  // ---------------------------------------------------------------------------
  // RV32I constants used by the testbench and sequences.
  // ---------------------------------------------------------------------------
  localparam int IMEM_DEPTH = 256;
  localparam int DMEM_DEPTH = 256;

  localparam bit [6:0] OP      = 7'b0110011;
  localparam bit [6:0] OP_IMM  = 7'b0010011;
  localparam bit [6:0] LOAD    = 7'b0000011;
  localparam bit [6:0] STORE   = 7'b0100011;
  localparam bit [6:0] BRANCH  = 7'b1100011;
  localparam bit [6:0] LUI     = 7'b0110111;
  localparam bit [6:0] JAL     = 7'b1101111;
  localparam bit [6:0] SYSTEM  = 7'b1110011;

  localparam bit [2:0] F3_ADD_SUB_ADDI = 3'b000;
  localparam bit [2:0] F3_LW_SW        = 3'b010;
  localparam bit [2:0] F3_BEQ          = 3'b000;
  localparam bit [2:0] F3_OR           = 3'b110;
  localparam bit [2:0] F3_AND          = 3'b111;

  localparam bit [6:0] F7_ADD = 7'b0000000;
  localparam bit [6:0] F7_SUB = 7'b0100000;

  localparam bit [31:0] INSTR_ECALL = 32'h0000_0073;
  localparam bit [31:0] INSTR_NOP   = 32'h0000_0013; // ADDI x0, x0, 0

  // ---------------------------------------------------------------------------
  // RV32I encoding helpers.
  // ---------------------------------------------------------------------------
  function automatic bit [31:0] enc_r(
    input bit [6:0] opcode,
    input bit [4:0] rd,
    input bit [2:0] funct3,
    input bit [4:0] rs1,
    input bit [4:0] rs2,
    input bit [6:0] funct7
  );
    return {funct7, rs2, rs1, funct3, rd, opcode};
  endfunction

  function automatic bit [31:0] enc_i(
    input bit [6:0] opcode,
    input bit [4:0] rd,
    input bit [2:0] funct3,
    input bit [4:0] rs1,
    input int signed imm
  );
    bit [11:0] imm12;
    imm12 = imm[11:0];
    return {imm12, rs1, funct3, rd, opcode};
  endfunction

  function automatic bit [31:0] enc_s(
    input bit [6:0] opcode,
    input bit [2:0] funct3,
    input bit [4:0] rs1,
    input bit [4:0] rs2,
    input int signed imm
  );
    bit [11:0] imm12;
    imm12 = imm[11:0];
    return {imm12[11:5], rs2, rs1, funct3, imm12[4:0], opcode};
  endfunction

  function automatic bit [31:0] enc_b(
    input bit [6:0] opcode,
    input bit [2:0] funct3,
    input bit [4:0] rs1,
    input bit [4:0] rs2,
    input int signed imm
  );
    bit [12:0] imm13;
    imm13 = imm[12:0];
    return {imm13[12], imm13[10:5], rs2, rs1, funct3,
            imm13[4:1], imm13[11], opcode};
  endfunction

  function automatic bit [31:0] enc_u(
    input bit [6:0] opcode,
    input bit [4:0] rd,
    input bit [19:0] imm20
  );
    return {imm20, rd, opcode};
  endfunction

  function automatic bit [31:0] enc_j(
    input bit [6:0] opcode,
    input bit [4:0] rd,
    input int signed imm
  );
    bit [20:0] imm21;
    imm21 = imm[20:0];
    return {imm21[20], imm21[10:1], imm21[11], imm21[19:12], rd, opcode};
  endfunction

  // ---------------------------------------------------------------------------
  // Transaction describing one complete program image.
  // ---------------------------------------------------------------------------
  class cpu_program extends uvm_sequence_item;
    bit [31:0] imem [IMEM_DEPTH];
    bit [31:0] dmem [DMEM_DEPTH];
    int unsigned program_id;
    int unsigned max_steps;
    string program_name;

    `uvm_object_utils(cpu_program)

    function new(string name = "cpu_program");
      super.new(name);
      max_steps = 1000;
      program_name = name;
      init_mems();
    endfunction

    function void init_mems();
      for (int i = 0; i < IMEM_DEPTH; i++) begin
        imem[i] = INSTR_NOP;
      end
      for (int i = 0; i < DMEM_DEPTH; i++) begin
        dmem[i] = 32'b0;
      end
    endfunction
  endclass

  class cpu_expected extends uvm_object;
    bit [31:0] regs [32];
    bit [31:0] mem  [DMEM_DEPTH];
    bit [31:0] pc;
    bit        halted;
    int unsigned program_id;
    string program_name;

    `uvm_object_utils(cpu_expected)

    function new(string name = "cpu_expected");
      super.new(name);
    endfunction
  endclass

  class cpu_actual extends uvm_object;
    bit [31:0] regs [32];
    bit [31:0] mem  [DMEM_DEPTH];
    bit [31:0] pc;
    bit        halted;
    int unsigned program_id;

    `uvm_object_utils(cpu_actual)

    function new(string name = "cpu_actual");
      super.new(name);
    endfunction
  endclass

  // ---------------------------------------------------------------------------
  // Sequences
  // ---------------------------------------------------------------------------
  class cpu_hazard_seq extends uvm_sequence #(cpu_program);
    `uvm_object_utils(cpu_hazard_seq)

    function new(string name = "cpu_hazard_seq");
      super.new(name);
    endfunction

    task body();
      cpu_program req;
      req = cpu_program::type_id::create("hazard_program");
      start_item(req);
      req.init_mems();
      req.program_id   = 1;
      req.program_name = "directed_rv32i_hazard_branch_jump";
      req.max_steps    = 1000;

      // Same program as the directed non-UVM sanity test.
      req.imem[0]  = enc_i(OP_IMM, 5'd1,  F3_ADD_SUB_ADDI, 5'd0,  5);   // ADDI x1,x0,5
      req.imem[1]  = enc_i(OP_IMM, 5'd2,  F3_ADD_SUB_ADDI, 5'd1,  3);   // ADDI x2,x1,3
      req.imem[2]  = enc_r(OP,     5'd3,  F3_ADD_SUB_ADDI, 5'd2,  5'd1, F7_ADD); // ADD x3,x2,x1
      req.imem[3]  = enc_i(LOAD,   5'd4,  F3_LW_SW,        5'd0,  0);   // LW x4,0(x0)
      req.imem[4]  = enc_r(OP,     5'd5,  F3_ADD_SUB_ADDI, 5'd4,  5'd3, F7_ADD); // ADD x5,x4,x3
      req.imem[5]  = enc_s(STORE,         F3_LW_SW,        5'd0,  5'd5, 4); // SW x5,4(x0)
      req.imem[6]  = enc_b(BRANCH,        F3_BEQ,          5'd1,  5'd1, 12); // BEQ +12
      req.imem[7]  = enc_i(OP_IMM, 5'd6,  F3_ADD_SUB_ADDI, 5'd0,  9);   // flushed
      req.imem[8]  = enc_i(OP_IMM, 5'd6,  F3_ADD_SUB_ADDI, 5'd0,  8);   // flushed
      req.imem[9]  = enc_i(OP_IMM, 5'd7,  F3_ADD_SUB_ADDI, 5'd0,  7);   // x7=7
      req.imem[10] = enc_u(LUI,    5'd8,  20'h12345);                   // x8=0x12345000
      req.imem[11] = enc_j(JAL,    5'd9,  8);                           // x9=48, jump +8
      req.imem[12] = enc_i(OP_IMM, 5'd10, F3_ADD_SUB_ADDI, 5'd0,  111); // flushed
      req.imem[13] = enc_i(OP_IMM, 5'd11, F3_ADD_SUB_ADDI, 5'd0,  42);  // x11=42
      req.imem[14] = enc_i(OP_IMM, 5'd0,  F3_ADD_SUB_ADDI, 5'd0,  99);  // x0 stays 0
      req.imem[15] = INSTR_ECALL;

      req.dmem[0] = 32'd100;
      finish_item(req);
    endtask
  endclass



  // ---------------------------------------------------------------------------
  // Directed program loaded from an assembly-generated hexadecimal image.
  //
  // EDA Playground/Riviera executes SystemVerilog, not RISC-V assembly text.
  // run.bash first converts hazard_test.S into hazard_test.hex. This sequence
  // then reads that machine-code image into the same cpu_program object used by
  // the driver, golden model, monitor, and scoreboard.
  // ---------------------------------------------------------------------------
  class cpu_asm_seq extends uvm_sequence #(cpu_program);
    `uvm_object_utils(cpu_asm_seq)

    function new(string name = "cpu_asm_seq");
      super.new(name);
    endfunction

    task body();
      cpu_program req;
      string hex_file;
      int fd;

      req = cpu_program::type_id::create("assembly_program");
      start_item(req);
      req.init_mems();
      req.program_id   = 1;
      req.program_name = "directed_assembly_hazard_branch_jump";
      req.max_steps    = 1000;

      // The filename can be changed from run.bash with:
      //   +PROGRAM_HEX=another_program.hex
      if (!$value$plusargs("PROGRAM_HEX=%s", hex_file)) begin
        hex_file = "hazard_test.hex";
      end

      // Give a clear UVM error instead of a vague $readmemh warning.
      fd = $fopen(hex_file, "r");
      if (fd == 0) begin
        `uvm_fatal("ASM_FILE", $sformatf(
          "Cannot open assembly machine-code file '%s'", hex_file))
      end
      $fclose(fd);

      `uvm_info("ASM_SEQ", $sformatf(
        "Loading directed assembly image from %s", hex_file), UVM_LOW)

      // req.imem was pre-filled with NOPs. $readmemh replaces entries present
      // in the file, leaving the remaining instruction memory as NOPs.
      $readmemh(hex_file, req.imem);

      // hazard_test.S performs LW x4, 0(x0), so seed data memory word 0.
      req.dmem[0] = 32'd100;

      finish_item(req);
    endtask
  endclass

  class cpu_rand_seq extends uvm_sequence #(cpu_program);
    `uvm_object_utils(cpu_rand_seq)

    function new(string name = "cpu_rand_seq");
      super.new(name);
    endfunction

    task body();
      cpu_program req;
      int a, b;
      bit take_branch;

      for (int p = 1; p <= 10; p++) begin
        req = cpu_program::type_id::create($sformatf("rand_program_%0d", p));
        start_item(req);
        req.init_mems();
        req.program_id   = p;
        req.program_name = $sformatf("rand_rv32i_program_%0d", p);
        req.max_steps    = 1000;

        a = $urandom_range(1, 20);
        b = $urandom_range(1, 15);
        take_branch = (p % 2 == 0);

        req.imem[0]  = enc_i(OP_IMM, 5'd1,  F3_ADD_SUB_ADDI, 5'd0,  a);      // x1=a
        req.imem[1]  = enc_i(OP_IMM, 5'd2,  F3_ADD_SUB_ADDI, 5'd1,  b);      // x2=x1+b
        req.imem[2]  = enc_r(OP,     5'd3,  F3_ADD_SUB_ADDI, 5'd2,  5'd1, F7_ADD);
        req.imem[3]  = enc_r(OP,     5'd12, F3_ADD_SUB_ADDI, 5'd2,  5'd1, F7_SUB);
        req.imem[4]  = enc_r(OP,     5'd13, F3_AND,          5'd2,  5'd1, F7_ADD);
        req.imem[5]  = enc_r(OP,     5'd14, F3_OR,           5'd2,  5'd1, F7_ADD);
        req.imem[6]  = enc_s(STORE,         F3_LW_SW,        5'd0,  5'd3, 4); // mem[1]=x3
        req.imem[7]  = enc_i(LOAD,   5'd4,  F3_LW_SW,        5'd0,  4);      // x4=mem[1]
        req.imem[8]  = enc_r(OP,     5'd5,  F3_ADD_SUB_ADDI, 5'd4,  5'd3, F7_ADD); // load-use

        if (take_branch)
          req.imem[9] = enc_b(BRANCH, F3_BEQ, 5'd1, 5'd1, 8); // taken: skip instr 10
        else
          req.imem[9] = enc_b(BRANCH, F3_BEQ, 5'd1, 5'd0, 8); // not taken because x1 != 0

        req.imem[10] = enc_i(OP_IMM, 5'd6,  F3_ADD_SUB_ADDI, 5'd0,  99);
        req.imem[11] = enc_i(OP_IMM, 5'd7,  F3_ADD_SUB_ADDI, 5'd0,  p);
        req.imem[12] = enc_j(JAL,    5'd9,  8);                           // skip instr 13
        req.imem[13] = enc_i(OP_IMM, 5'd10, F3_ADD_SUB_ADDI, 5'd0,  111); // flushed
        req.imem[14] = enc_i(OP_IMM, 5'd11, F3_ADD_SUB_ADDI, 5'd0,  42);
        req.imem[15] = INSTR_ECALL;

        finish_item(req);
      end
    endtask
  endclass

  // ---------------------------------------------------------------------------
  // UVM components
  // ---------------------------------------------------------------------------
  class cpu_sequencer extends uvm_sequencer #(cpu_program);
    `uvm_component_utils(cpu_sequencer)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
  endclass

  class cpu_driver extends uvm_driver #(cpu_program);
    `uvm_component_utils(cpu_driver)

    virtual cpu_if vif;
    uvm_analysis_port #(cpu_expected) expected_ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      expected_ap = new("expected_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual cpu_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("CPU_DRIVER", "virtual interface not found")
      end
    endfunction

    task run_phase(uvm_phase phase);
      cpu_program req;
      vif.rst_n <= 1'b0;
      forever begin
        seq_item_port.get_next_item(req);
        run_one_program(req);
        seq_item_port.item_done();
      end
    endtask

    task automatic run_one_program(cpu_program prog);
      cpu_expected exp;
      bit timed_out;

      `uvm_info("CPU_DRIVER", $sformatf("Loading program %0d: %s",
                prog.program_id, prog.program_name), UVM_MEDIUM)

      // Reset before loading memories, so architectural state starts clean.
      vif.rst_n <= 1'b0;
      repeat (3) @(posedge vif.clk);

      // Backdoor load memories into DUT and golden model.
      gm_reset();
      for (int i = 0; i < IMEM_DEPTH; i++) begin
        hdl_deposit32($sformatf("tb_top.dut.instr_mem[%0d]", i), prog.imem[i]);
        gm_load_instr(i, int'(prog.imem[i]));
      end
      for (int i = 0; i < DMEM_DEPTH; i++) begin
        hdl_deposit32($sformatf("tb_top.dut.data_mem[%0d]", i), prog.dmem[i]);
        gm_load_data(i, int'(prog.dmem[i]));
      end

      // Run golden model immediately; it is architectural/non-pipelined.
      gm_run(prog.max_steps);

      exp = cpu_expected::type_id::create("exp");
      exp.program_id   = prog.program_id;
      exp.program_name = prog.program_name;
      exp.pc           = gm_get_pc();
      exp.halted       = (gm_is_halted() != 0);
      for (int i = 0; i < 32; i++) begin
        exp.regs[i] = gm_get_reg(i);
      end
      for (int i = 0; i < DMEM_DEPTH; i++) begin
        exp.mem[i] = gm_get_mem(i);
      end
      expected_ap.write(exp);

      // Start DUT.
      repeat (1) @(posedge vif.clk);
      vif.rst_n <= 1'b1;

      timed_out = 0;
      fork
        begin : wait_halt
          @(posedge vif.halt);
        end
        begin : timeout
          repeat (prog.max_steps + 50) @(posedge vif.clk);
          timed_out = 1;
        end
      join_any
      disable fork;

      if (timed_out) begin
        `uvm_fatal("CPU_DRIVER", $sformatf("DUT timeout on program %0d: %s",
                   prog.program_id, prog.program_name))
      end

      // Give monitor time to sample final architectural state after halt.
      repeat (8) @(posedge vif.clk);
    endtask

    function automatic void hdl_deposit32(string path, bit [31:0] data);
      uvm_hdl_data_t value;
      value = '0;
      value[31:0] = data;
      if (!uvm_hdl_deposit(path, value)) begin
        `uvm_fatal("HDL_DEPOSIT", $sformatf("Failed to deposit %s", path))
      end
    endfunction
  endclass

  class cpu_monitor extends uvm_component;
    `uvm_component_utils(cpu_monitor)

    virtual cpu_if vif;
    uvm_analysis_port #(cpu_actual) actual_ap;
    int unsigned observed_programs;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      actual_ap = new("actual_ap", this);
      observed_programs = 0;
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual cpu_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("CPU_MONITOR", "virtual interface not found")
      end
    endfunction

    task run_phase(uvm_phase phase);
      cpu_actual act;

      forever begin
        @(posedge vif.halt);
        observed_programs++;
        repeat (5) @(posedge vif.clk); // drain final WB after halt reaches EX

        act = cpu_actual::type_id::create("act");
        act.program_id = observed_programs;
        act.halted     = vif.halt;
        act.pc         = vif.pc_out;

        for (int i = 0; i < 32; i++) begin
          act.regs[i] = hdl_read32($sformatf("tb_top.dut.regfile[%0d]", i));
        end
        for (int i = 0; i < DMEM_DEPTH; i++) begin
          act.mem[i] = hdl_read32($sformatf("tb_top.dut.data_mem[%0d]", i));
        end

        actual_ap.write(act);

        // Wait for reset before looking for the next program's halt edge.
        wait (vif.rst_n === 1'b0);
      end
    endtask

    function automatic bit [31:0] hdl_read32(string path);
      uvm_hdl_data_t value;
      value = '0;
      if (!uvm_hdl_read(path, value)) begin
        `uvm_fatal("HDL_READ", $sformatf("Failed to read %s", path))
      end
      return value[31:0];
    endfunction
  endclass

  class cpu_scoreboard extends uvm_component;
    `uvm_component_utils(cpu_scoreboard)

    uvm_tlm_analysis_fifo #(cpu_expected) exp_fifo;
    uvm_tlm_analysis_fifo #(cpu_actual)   act_fifo;

    int unsigned programs_checked;
    int unsigned programs_passed;
    int unsigned mismatch_count;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      exp_fifo = new("exp_fifo", this);
      act_fifo = new("act_fifo", this);
    endfunction

    function automatic string cmp32(bit [31:0] actual, bit [31:0] expected);
      if (actual === expected)
        return "OK";
      else
        return "MISMATCH";
    endfunction

    function automatic string cmp1(bit actual, bit expected);
      if (actual === expected)
        return "OK";
      else
        return "MISMATCH";
    endfunction

    function void print_actual_vs_golden(cpu_expected exp, cpu_actual act);
      `uvm_info("CPU_STATE", "------------------------------------------------------------", UVM_LOW)
      `uvm_info("CPU_STATE", $sformatf(
        "Program %0d (%s) actual-vs-golden architectural state",
        exp.program_id, exp.program_name), UVM_LOW)

      `uvm_info("CPU_STATE", $sformatf(
        "PC    actual=0x%08h  golden=0x%08h  %s",
        act.pc, exp.pc, cmp32(act.pc, exp.pc)), UVM_LOW)

      `uvm_info("CPU_STATE", $sformatf(
        "HALT  actual=%0d           golden=%0d           %s",
        act.halted, exp.halted, cmp1(act.halted, exp.halted)), UVM_LOW)

      `uvm_info("CPU_STATE", "Register compare: x0-x15", UVM_LOW)
      for (int i = 0; i < 16; i++) begin
        `uvm_info("CPU_STATE", $sformatf(
          "x%02d   actual=0x%08h  golden=0x%08h  %s",
          i, act.regs[i], exp.regs[i], cmp32(act.regs[i], exp.regs[i])), UVM_LOW)
      end

      `uvm_info("CPU_STATE", "Data memory compare: word indices 0-7", UVM_LOW)
      for (int i = 0; i < 8; i++) begin
        `uvm_info("CPU_STATE", $sformatf(
          "mem[%02d] actual=0x%08h  golden=0x%08h  %s",
          i, act.mem[i], exp.mem[i], cmp32(act.mem[i], exp.mem[i])), UVM_LOW)
      end
      `uvm_info("CPU_STATE", "------------------------------------------------------------", UVM_LOW)
    endfunction

    task run_phase(uvm_phase phase);
      cpu_expected exp;
      cpu_actual act;
      forever begin
        exp_fifo.get(exp);
        act_fifo.get(act);
        compare_program(exp, act);
      end
    endtask

    function void compare_program(cpu_expected exp, cpu_actual act);
      int local_mismatches;
      local_mismatches = 0;
      programs_checked++;

      print_actual_vs_golden(exp, act);

      if (act.pc !== exp.pc) begin
        local_mismatches++;
        `uvm_error("CPU_SCOREBOARD", $sformatf(
          "Program %0d PC mismatch: actual=0x%08h expected=0x%08h",
          exp.program_id, act.pc, exp.pc))
      end

      if (act.halted !== exp.halted) begin
        local_mismatches++;
        `uvm_error("CPU_SCOREBOARD", $sformatf(
          "Program %0d halt mismatch: actual=%0d expected=%0d",
          exp.program_id, act.halted, exp.halted))
      end

      for (int i = 0; i < 32; i++) begin
        if (act.regs[i] !== exp.regs[i]) begin
          local_mismatches++;
          `uvm_error("CPU_SCOREBOARD", $sformatf(
            "Program %0d reg x%0d mismatch: actual=0x%08h expected=0x%08h",
            exp.program_id, i, act.regs[i], exp.regs[i]))
        end
      end

      for (int i = 0; i < DMEM_DEPTH; i++) begin
        if (act.mem[i] !== exp.mem[i]) begin
          local_mismatches++;
          `uvm_error("CPU_SCOREBOARD", $sformatf(
            "Program %0d data_mem[%0d] mismatch: actual=0x%08h expected=0x%08h",
            exp.program_id, i, act.mem[i], exp.mem[i]))
        end
      end

      if (local_mismatches == 0) begin
        programs_passed++;
        `uvm_info("CPU_SCOREBOARD", $sformatf("Program %0d (%s): PASS",
                  exp.program_id, exp.program_name), UVM_LOW)
      end else begin
        mismatch_count += local_mismatches;
        `uvm_error("CPU_SCOREBOARD", $sformatf("Program %0d (%s): FAIL with %0d mismatches",
                   exp.program_id, exp.program_name, local_mismatches))
      end
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("CPU_SCOREBOARD", $sformatf(
        "Scoreboard summary: %0d/%0d programs matched golden model, mismatches=%0d",
        programs_passed, programs_checked, mismatch_count), UVM_NONE)
    endfunction
  endclass

  class cpu_agent extends uvm_component;
    `uvm_component_utils(cpu_agent)

    cpu_sequencer sequencer;
    cpu_driver    driver;
    cpu_monitor   monitor;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sequencer = cpu_sequencer::type_id::create("sequencer", this);
      driver    = cpu_driver   ::type_id::create("driver",    this);
      monitor   = cpu_monitor  ::type_id::create("monitor",   this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass

  class cpu_env extends uvm_env;
    `uvm_component_utils(cpu_env)

    cpu_agent      agent;
    cpu_scoreboard scoreboard;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent      = cpu_agent     ::type_id::create("agent",      this);
      scoreboard = cpu_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.driver.expected_ap.connect(scoreboard.exp_fifo.analysis_export);
      agent.monitor.actual_ap.connect(scoreboard.act_fifo.analysis_export);
    endfunction
  endclass

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
  endclass

  class cpu_hazard_test extends cpu_base_test;
    `uvm_component_utils(cpu_hazard_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      cpu_hazard_seq seq;
      phase.raise_objection(this);
      seq = cpu_hazard_seq::type_id::create("seq");
      seq.start(env.agent.sequencer);
      repeat (10) @(posedge env.agent.driver.vif.clk);
      phase.drop_objection(this);
    endtask
  endclass



  class cpu_asm_test extends cpu_base_test;
    `uvm_component_utils(cpu_asm_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      cpu_asm_seq seq;
      phase.raise_objection(this);
      seq = cpu_asm_seq::type_id::create("seq");
      seq.start(env.agent.sequencer);
      repeat (10) @(posedge env.agent.driver.vif.clk);
      phase.drop_objection(this);
    endtask
  endclass

  class cpu_rand_test extends cpu_base_test;
    `uvm_component_utils(cpu_rand_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      cpu_rand_seq seq;
      phase.raise_objection(this);
      seq = cpu_rand_seq::type_id::create("seq");
      seq.start(env.agent.sequencer);
      repeat (10) @(posedge env.agent.driver.vif.clk);
      phase.drop_objection(this);
    endtask
  endclass

endpackage
