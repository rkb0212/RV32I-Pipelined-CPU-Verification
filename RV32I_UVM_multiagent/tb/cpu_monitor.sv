// =============================================================================
// cpu_monitor.sv
// Purpose  : observe one program run and publish a cpu_actual.
// Mechanism: one loop on posedge clk.
//            - while reset is low: clear the per-run counters
//            - after reset: count cycles and event pulses (trap_taken,
//              fault_mem_misaligned, fault_mem_out_of_range)
//            - when `halt` rises: wait DRAIN cycles (older instructions finish
//              their write-back), then read state through cpu_if and publish.
// Rationale: halt freezes the PC and squashes younger instructions, so state
//            is stable after the drain; the monitor never touches DUT paths
//            directly -- only cpu_if functions.
// =============================================================================
class cpu_monitor extends uvm_component;
  `uvm_component_utils(cpu_monitor)

  localparam int DRAIN = 5;

  virtual cpu_if vif;
  uvm_analysis_port #(cpu_actual) actual_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    actual_ap = new("actual_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual cpu_if)::get(this, "", "vif", vif)) begin
      `uvm_fatal("CPU_MONITOR", "virtual interface 'vif' not found in config_db")
    end
  endfunction

  task run_phase(uvm_phase phase);
    int unsigned cycles = 0, traps = 0, misal = 0, oor = 0, tgt = 0;
    int          drain  = -1;     // -1 = waiting for halt, >=0 = counting drain cycles
    int unsigned halt_cycles = 0;
    bit          halt_seen = 0;

    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin
        cycles = 0; traps = 0; misal = 0; oor = 0; tgt = 0;
        drain = -1; halt_seen = 0;
      end else begin
        cycles++;
        if (vif.trap_taken)             traps++;
        if (vif.fault_mem_misaligned)   misal++;
        if (vif.fault_mem_out_of_range) oor++;
        if (vif.fault_misaligned_target) tgt++;

        if (vif.halt && !halt_seen) begin
          halt_seen   = 1;
          halt_cycles = cycles;
          drain       = 0;
        end else if (drain >= 0) begin
          drain++;
          if (drain == DRAIN) begin
            publish(halt_cycles, traps, misal, oor, tgt);
            drain = -2;           // published; wait for next reset
          end
        end
      end
    end
  endtask

  function void publish(int unsigned cycles, int unsigned traps, int unsigned misal, int unsigned oor, int unsigned tgt);
    cpu_actual act = cpu_actual::type_id::create("act");
    act.program_id    = vif.program_id;
    act.halted        = vif.halt;
    act.pc            = vif.pc_out;
    act.cycles        = cycles;
    act.trap_count    = traps;
    act.misalign_flags= misal;
    act.oor_flags     = oor;
    act.target_faults = tgt;
    for (int i = 0; i < 32; i++)         act.regs[i] = vif.read_reg(i);
    for (int i = 0; i < DMEM_DEPTH; i++) act.dmem[i] = vif.read_dmem(i);
    for (int i = 0; i < IMC_WORDS;  i++) act.ext[i]  = vif.read_imc(i);
    act.instr_count = vif.read_instr_count();
    act.mepc        = vif.read_mepc();
    act.mcause      = vif.read_mcause();
    act.mtval       = vif.read_mtval();
    actual_ap.write(act);
  endfunction
endclass
