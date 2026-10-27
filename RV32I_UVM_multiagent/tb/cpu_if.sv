// =============================================================================
// cpu_if.sv
// Purpose : the single point where the UVM testbench touches the DUT.
//           (1) the DUT's external ports, (2) backdoor tasks/functions.
// Mechanism: the DUT has no instruction-load port, so the program image is
//           written straight into design_top.instr_mem[] with a hierarchical
//           assignment, and final state (registers, data RAM, CSRs) is read
//           back with hierarchical reads. These live HERE, in one place, so
//           the driver/monitor never contain a DUT path string.
// Rationale: plain hierarchical access instead of uvm_hdl_deposit/read -- no
//           DPI backdoor library needed, so it behaves the same in xsim.
//           instr_mem has no RTL driver, so a procedural write is legal.
//           data_memory.mem IS driven by an always_ff, so it is READ ONLY from
//           the testbench (a TB write would be a multi-driver error in xsim);
//           programs preload data with ordinary SW instructions instead.
// NOTE    : paths assume the DUT instance is  tb_top.dut  (see tb_top.sv).
// =============================================================================
interface cpu_if (input logic clk);
  // ---- DUT ports ----
  logic        rst_n;
  logic        halt;
  logic [31:0] pc_out;
  logic        fault_misaligned_target;
  logic        fault_mem_misaligned;
  logic        fault_mem_out_of_range;
  logic        trap_taken;

  // ---- driver -> monitor side channel: which program is running ----
  int unsigned program_id = 0;

  // ---- backdoor: write ----
  function automatic void load_instr(input int idx, input bit [31:0] data);
    tb_top.dut.instr_mem[idx] = data;
  endfunction

  // ---- backdoor: read ----
  function automatic bit [31:0] read_reg(input int idx);
    return tb_top.dut.u_regfile.regs[idx];
  endfunction

  function automatic bit [31:0] read_dmem(input int idx);
    return tb_top.dut.u_data_memory.mem[idx];
  endfunction

  function automatic bit [31:0] read_imc(input int idx);
    return tb_top.dut.u_imc.mem[idx];       // external memory (read only: driven by an always_ff)
  endfunction

  function automatic bit [31:0] read_instr_count();
    return tb_top.dut.u_csr_regs.instr_count;
  endfunction

  function automatic bit [31:0] read_mepc();
    return tb_top.dut.u_csr_regs.mepc;
  endfunction

  function automatic bit [31:0] read_mcause();
    return tb_top.dut.u_csr_regs.mcause;
  endfunction

  function automatic bit [31:0] read_mtval();
    return tb_top.dut.u_csr_regs.mtval;
  endfunction
endinterface
