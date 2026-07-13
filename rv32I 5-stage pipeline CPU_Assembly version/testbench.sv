`timescale 1ns/1ns

// =============================================================================
// Plain-SystemVerilog self-checking testbench for the RV32I-subset CPU.
//
// Why this version exists:
//   The current EDA Playground Riviera license rejects UVM, covergroups, and
//   concurrent SVA as "SystemVerilog advanced verification features".
//   This testbench therefore uses only ordinary SystemVerilog plus DPI-C.
//
// Flow:
//   hazard_test.S -> rv32i_subset_asm.py -> hazard_test.hex
//   hazard_test.hex -> DUT instruction memory + DPI-C golden model
//   DUT runs to ECALL -> all 32 registers, memory, PC, and halt are compared.
// =============================================================================

module tb_top;

  localparam int IMEM_DEPTH = 256;
  localparam int DMEM_DEPTH = 256;
  localparam logic [31:0] INSTR_NOP = 32'h0000_0013; // ADDI x0,x0,0

  // RV32I opcodes implemented by the DUT.
  localparam logic [6:0] OPCODE_OP      = 7'h33;
  localparam logic [6:0] OPCODE_OP_IMM  = 7'h13;
  localparam logic [6:0] OPCODE_LOAD    = 7'h03;
  localparam logic [6:0] OPCODE_STORE   = 7'h23;
  localparam logic [6:0] OPCODE_BRANCH  = 7'h63;
  localparam logic [6:0] OPCODE_LUI     = 7'h37;
  localparam logic [6:0] OPCODE_JAL     = 7'h6f;

  localparam logic [2:0] F3_ADD_SUB = 3'h0;
  localparam logic [2:0] F3_OR      = 3'h6;
  localparam logic [2:0] F3_AND     = 3'h7;
  localparam logic [6:0] F7_ADD     = 7'h00;
  localparam logic [6:0] F7_SUB     = 7'h20;

  logic clk;
  logic rst_n;
  logic halt;
  logic [31:0] pc_out;

  logic [31:0] program_image [0:IMEM_DEPTH-1];

  int cycle_count;
  int pass_count;
  int fail_count;
  int procedural_error_count;

  int load_use_stall_count;
  int branch_taken_count;
  int jump_taken_count;
  int ex_mem_forward_count;
  int mem_wb_forward_count;

  // Bit mapping: 0 ADD, 1 SUB, 2 AND, 3 OR, 4 ADDI,
  //              5 LW, 6 SW, 7 BEQ, 8 LUI, 9 JAL.
  logic [9:0] instruction_seen;

  logic [31:0] sampled_pc;
  logic sampled_stall;
  logic sampled_redirect;
  logic sampled_halt;

  // ---------------------------------------------------------------------------
  // DPI-C golden-model imports. These are plain DPI functions; no UVM is used.
  // ---------------------------------------------------------------------------
  import "DPI-C" function void gm_reset();
  import "DPI-C" function void gm_load_instr(input int addr, input int instr);
  import "DPI-C" function void gm_load_data(input int addr, input int value);
  import "DPI-C" function void gm_run(input int max_steps);
  import "DPI-C" function int  gm_get_reg(input int idx);
  import "DPI-C" function int  gm_get_mem(input int addr);
  import "DPI-C" function int  gm_get_pc();
  import "DPI-C" function int  gm_is_halted();

  simple_cpu_pipelined dut (
    .clk    (clk),
    .rst_n  (rst_n),
    .halt   (halt),
    .pc_out (pc_out)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // Forwarding-event detection using the same conditions/priorities as the RTL.
  // ---------------------------------------------------------------------------
  wire fwd_ex_mem_rs1 =
      dut.ex_mem_reg_write && !dut.ex_mem_mem_to_reg &&
      (dut.ex_mem_rd_addr != 5'd0) &&
      (dut.ex_mem_rd_addr == dut.id_ex_rs1_addr);

  wire fwd_ex_mem_rs2 =
      dut.id_ex_rs2_used &&
      dut.ex_mem_reg_write && !dut.ex_mem_mem_to_reg &&
      (dut.ex_mem_rd_addr != 5'd0) &&
      (dut.ex_mem_rd_addr == dut.id_ex_rs2_addr);

  wire fwd_mem_wb_rs1 =
      dut.mem_wb_reg_write &&
      (dut.mem_wb_rd_addr != 5'd0) &&
      (dut.mem_wb_rd_addr == dut.id_ex_rs1_addr) &&
      !fwd_ex_mem_rs1;

  wire fwd_mem_wb_rs2 =
      dut.id_ex_rs2_used &&
      dut.mem_wb_reg_write &&
      (dut.mem_wb_rd_addr != 5'd0) &&
      (dut.mem_wb_rd_addr == dut.id_ex_rs2_addr) &&
      !fwd_ex_mem_rs2;

  // ---------------------------------------------------------------------------
  // Manual event/instruction coverage counters. No covergroups are used.
  // ---------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_count           <= 0;
      load_use_stall_count  <= 0;
      branch_taken_count    <= 0;
      jump_taken_count      <= 0;
      ex_mem_forward_count  <= 0;
      mem_wb_forward_count  <= 0;
      instruction_seen      <= '0;
    end else begin
      cycle_count <= cycle_count + 1;

      if (dut.stall_load_use)
        load_use_stall_count <= load_use_stall_count + 1;

      if (dut.branch_taken)
        branch_taken_count <= branch_taken_count + 1;

      if (dut.jump_taken)
        jump_taken_count <= jump_taken_count + 1;

      if (fwd_ex_mem_rs1 || fwd_ex_mem_rs2)
        ex_mem_forward_count <= ex_mem_forward_count + 1;

      if (fwd_mem_wb_rs1 || fwd_mem_wb_rs2)
        mem_wb_forward_count <= mem_wb_forward_count + 1;

      case (dut.id_ex_opcode)
        OPCODE_OP: begin
          if (dut.id_ex_funct3 == F3_ADD_SUB && dut.id_ex_funct7 == F7_ADD)
            instruction_seen[0] <= 1'b1; // ADD
          else if (dut.id_ex_funct3 == F3_ADD_SUB && dut.id_ex_funct7 == F7_SUB)
            instruction_seen[1] <= 1'b1; // SUB
          else if (dut.id_ex_funct3 == F3_AND && dut.id_ex_funct7 == F7_ADD)
            instruction_seen[2] <= 1'b1; // AND
          else if (dut.id_ex_funct3 == F3_OR && dut.id_ex_funct7 == F7_ADD)
            instruction_seen[3] <= 1'b1; // OR
        end
        OPCODE_OP_IMM: instruction_seen[4] <= 1'b1; // ADDI
        OPCODE_LOAD:   instruction_seen[5] <= 1'b1; // LW
        OPCODE_STORE:  instruction_seen[6] <= 1'b1; // SW
        OPCODE_BRANCH: instruction_seen[7] <= 1'b1; // BEQ
        OPCODE_LUI:    instruction_seen[8] <= 1'b1; // LUI
        OPCODE_JAL:    instruction_seen[9] <= 1'b1; // JAL
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Procedural replacements for the unavailable concurrent SVA properties.
  // Checks are sampled before the edge and evaluated after the NBA updates.
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n) begin
      sampled_pc       = dut.pc;
      sampled_stall    = dut.stall_load_use;
      sampled_redirect = dut.redirect_taken;
      sampled_halt     = halt;

      #1;

      if (sampled_stall && !sampled_redirect && dut.pc !== sampled_pc) begin
        procedural_error_count++;
        $error("LOAD-USE CHECK: PC changed during stall: before=%08h after=%08h",
               sampled_pc, dut.pc);
      end

      if ((sampled_stall || sampled_redirect) &&
          (dut.id_ex_reg_write || dut.id_ex_mem_write ||
           dut.id_ex_is_branch || dut.id_ex_is_jump)) begin
        procedural_error_count++;
        $error("BUBBLE/FLUSH CHECK: ID/EX was not cleared after stall/redirect");
      end

      if (sampled_halt && !halt) begin
        procedural_error_count++;
        $error("HALT CHECK: halt deasserted after being asserted");
      end

      if (sampled_halt && dut.pc !== sampled_pc) begin
        procedural_error_count++;
        $error("HALT CHECK: PC changed after halt: before=%08h after=%08h",
               sampled_pc, dut.pc);
      end

      if (dut.regfile[0] !== 32'b0) begin
        procedural_error_count++;
        $error("X0 CHECK: x0 changed to %08h", dut.regfile[0]);
      end

      if (dut.pc[1:0] !== 2'b00) begin
        procedural_error_count++;
        $error("PC ALIGNMENT CHECK: PC is not word aligned: %08h", dut.pc);
      end
    end
  end

  task automatic check_register(input int idx);
    logic [31:0] actual;
    logic [31:0] expected;
    begin
      actual   = dut.regfile[idx];
      expected = gm_get_reg(idx);

      if (actual === expected) begin
        pass_count++;
        $display("  PASS x%0d = 0x%08h", idx, actual);
      end else begin
        fail_count++;
        $display("  FAIL x%0d = 0x%08h, expected 0x%08h", idx, actual, expected);
      end
    end
  endtask

  task automatic check_memory;
    int mismatches;
    logic [31:0] actual;
    logic [31:0] expected;
    begin
      mismatches = 0;

      for (int i = 0; i < DMEM_DEPTH; i++) begin
        actual   = dut.data_mem[i];
        expected = gm_get_mem(i);

        if (actual !== expected) begin
          mismatches++;
          fail_count++;
          $display("  FAIL data_mem[%0d] = 0x%08h, expected 0x%08h",
                   i, actual, expected);
        end
      end

      if (mismatches == 0) begin
        pass_count++;
        $display("  PASS all %0d data-memory words match the golden model", DMEM_DEPTH);
      end
    end
  endtask

  task automatic check_scalar_state;
    logic [31:0] expected_pc;
    int expected_halt;
    begin
      expected_pc   = gm_get_pc();
      expected_halt = gm_is_halted();

      if (pc_out === expected_pc) begin
        pass_count++;
        $display("  PASS PC = 0x%08h", pc_out);
      end else begin
        fail_count++;
        $display("  FAIL PC = 0x%08h, expected 0x%08h", pc_out, expected_pc);
      end

      if (halt === expected_halt[0]) begin
        pass_count++;
        $display("  PASS halt = %0b", halt);
      end else begin
        fail_count++;
        $display("  FAIL halt = %0b, expected %0b", halt, expected_halt[0]);
      end
    end
  endtask

  function automatic int instruction_count(input logic [9:0] seen);
    int count;
    begin
      count = 0;
      for (int i = 0; i < 10; i++)
        count += seen[i];
      return count;
    end
  endfunction

  task automatic print_missing_instructions;
    begin
      if (!instruction_seen[0]) $display("  MISSING ADD");
      if (!instruction_seen[1]) $display("  MISSING SUB");
      if (!instruction_seen[2]) $display("  MISSING AND");
      if (!instruction_seen[3]) $display("  MISSING OR");
      if (!instruction_seen[4]) $display("  MISSING ADDI");
      if (!instruction_seen[5]) $display("  MISSING LW");
      if (!instruction_seen[6]) $display("  MISSING SW");
      if (!instruction_seen[7]) $display("  MISSING BEQ");
      if (!instruction_seen[8]) $display("  MISSING LUI");
      if (!instruction_seen[9]) $display("  MISSING JAL");
    end
  endtask

  task automatic check_required_event(
      input string event_name,
      input int event_count
  );
    begin
      if (event_count > 0) begin
        pass_count++;
        $display("  PASS %-24s observed %0d time(s)", event_name, event_count);
      end else begin
        fail_count++;
        $display("  FAIL %-24s was not observed", event_name);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Program loading, golden-model execution, DUT execution, and final checks.
  // ---------------------------------------------------------------------------
  initial begin : run_test
    bit timed_out;
    int covered_instructions;

    rst_n                  = 1'b0;
    pass_count             = 0;
    fail_count             = 0;
    procedural_error_count = 0;
    timed_out              = 1'b0;

    gm_reset();

    // Initialize every location to a valid NOP/zero before reading the program.
    for (int i = 0; i < IMEM_DEPTH; i++)
      program_image[i] = INSTR_NOP;

    $readmemh("hazard_test.hex", program_image);

    for (int i = 0; i < IMEM_DEPTH; i++) begin
      dut.instr_mem[i] = program_image[i];
      dut.data_mem[i]  = 32'b0;
      gm_load_instr(i, int'(program_image[i]));
      gm_load_data(i, 0);
    end

    // Assembly instruction "lw x4, 0(x0)" reads this value.
    dut.data_mem[0] = 32'd100;
    gm_load_data(0, 100);

    // Run the non-pipelined architectural reference before releasing the DUT.
    gm_run(1000);

    $display("============================================================");
    $display("Running assembly-backed RV32I directed test");
    $display("Program: hazard_test.S -> hazard_test.hex");
    $display("============================================================");

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    fork
      begin : wait_for_halt
        @(posedge halt);
        $display("DUT reached ECALL/HALT at cycle %0d, PC=0x%08h",
                 cycle_count, pc_out);
      end

      begin : timeout_guard
        repeat (500) @(posedge clk);
        timed_out = 1'b1;
        $display("TIMEOUT: DUT did not assert halt within 500 cycles");
      end
    join_any

    disable fork;

    if (timed_out) begin
      fail_count++;
    end else begin
      // Keep running briefly to prove halt is sticky and PC remains frozen.
      repeat (5) @(posedge clk);

      $display("\n================ ARCHITECTURAL COMPARISON ================");
      for (int i = 0; i < 32; i++)
        check_register(i);

      check_memory();
      check_scalar_state();

      $display("\n================ HAZARD/EVENT OBSERVATION =================");
      check_required_event("load-use stall", load_use_stall_count);
      check_required_event("taken BEQ redirect", branch_taken_count);
      check_required_event("JAL redirect", jump_taken_count);
      check_required_event("EX/MEM forwarding", ex_mem_forward_count);
      check_required_event("MEM/WB forwarding", mem_wb_forward_count);

      // Final-state evidence for flush behavior and x0 hardwiring.
      if (dut.regfile[6] === 32'd0) begin
        pass_count++;
        $display("  PASS BEQ flush: x6 remained zero");
      end else begin
        fail_count++;
        $display("  FAIL BEQ flush: x6 = 0x%08h", dut.regfile[6]);
      end

      if (dut.regfile[10] === 32'd0) begin
        pass_count++;
        $display("  PASS JAL flush: x10 remained zero");
      end else begin
        fail_count++;
        $display("  FAIL JAL flush: x10 = 0x%08h", dut.regfile[10]);
      end

      if (dut.regfile[0] === 32'd0) begin
        pass_count++;
        $display("  PASS x0 hardwiring: x0 remained zero");
      end else begin
        fail_count++;
        $display("  FAIL x0 hardwiring: x0 = 0x%08h", dut.regfile[0]);
      end

      $display("\n================ MANUAL INSTRUCTION COVERAGE ==============");
      covered_instructions = instruction_count(instruction_seen);
      $display("Implemented instructions observed = %0d/10", covered_instructions);
      print_missing_instructions();

      if (covered_instructions == 10) begin
        pass_count++;
        $display("  PASS all 10 implemented RV32I instructions were observed");
      end else begin
        fail_count++;
        $display("  FAIL only %0d/10 implemented instructions were observed",
                 covered_instructions);
      end
    end

    if (procedural_error_count != 0) begin
      fail_count += procedural_error_count;
      $display("\nProcedural checker errors = %0d", procedural_error_count);
    end

    $display("\n============================================================");
    $display("FINAL RESULT: %0d checks passed, %0d checks failed",
             pass_count, fail_count);

    if (fail_count == 0)
      $display("TEST PASS: assembly program, hazards, and golden comparison passed");
    else
      $display("TEST FAIL: review the failures above");

    $display("============================================================");

    if (fail_count == 0)
      $finish;
    else
      $fatal(1, "Assembly-backed RV32I verification failed");
  end

  initial begin
    $dumpfile("rv32i_assembly_test.vcd");
    $dumpvars(0, tb_top);
  end

endmodule
