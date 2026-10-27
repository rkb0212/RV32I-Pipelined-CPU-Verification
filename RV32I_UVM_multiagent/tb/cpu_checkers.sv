// =============================================================================
// cpu_checkers.sv
// One checker per passive agent, each a uvm_subscriber on that agent's items.
// Real self-contained checks (they need no golden model):
//   retire checker : retire spacing for programs that declare it (no-stall = 1 cycle,
//                    load-use = +1, memory stalls = +stall) -- cpu_program.exp_gap_*
//   mem checker    : an independent L2/L3 reference model predicts which level serves
//                    every external load (L2 hit / L3 hit / iMC) and the stall it costs
//                    (0 / 0 / 7 cycles, external store 4, everything else 0)
//   bus checker    : every external store and every iMC-served load must appear on the
//                    AXI bus with the same address and data, and no other AXI traffic
//                    may exist (a cache miss must reach the iMC, a hit must not)
//   axi checker    : every AXI response OKAY (protocol rules are SVA in axi_if)
//   status checker : the PC must never move while halt is asserted
// Each prints a one-line summary in report_phase; run_uvm_xsim.sh reads them.
// Contains: cpu_retire_checker, cpu_mem_checker, cpu_bus_checker, cpu_axi_checker, cpu_status_checker.
// =============================================================================

// ---- retire trace -----------------------------------------------------------
class cpu_retire_checker extends uvm_subscriber #(retire_item);
  `uvm_component_utils(cpu_retire_checker)

  int unsigned retired, reg_writes, stores, halts;
  int unsigned gap_checks, gap_errors;
  bit          seen_prog [int unsigned];

  // spacing state of the program currently retiring
  int unsigned cur_pid = 0, cur_idx = 0, last_cycle = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(retire_item t);
    retired++;
    if (t.reg_write) reg_writes++;
    if (t.is_store)  stores++;
    if (t.is_halt)   halts++;
    seen_prog[t.program_id] = 1;
    `uvm_info("RETIRE_CHECKER", t.convert2string(), UVM_HIGH)
    check_gap(t);
  endfunction

  // Retire-spacing check for programs that declare exp_gap_default / exp_gap_at.
  function void check_gap(retire_item t);
    cpu_program p;
    int unsigned gap;
    int          exp_gap;
    if (t.program_id != cur_pid) begin cur_pid = t.program_id; cur_idx = 0; end
    if (cur_idx > 0 && cpu_expect::programs.exists(t.program_id)) begin
      p = cpu_expect::programs[t.program_id];
      gap = t.cycle - last_cycle;
      exp_gap = p.exp_gap_at.exists(cur_idx) ? p.exp_gap_at[cur_idx] : p.exp_gap_default;
      if (exp_gap > 0) begin
        gap_checks++;
        if (gap != exp_gap) begin
          gap_errors++;
          `uvm_error("RETIRE_CHECKER", $sformatf("prog %0d (%s) retire #%0d pc=0x%08h: %0d cycle(s) after the previous retire, expected %0d",
                     t.program_id, p.program_name, cur_idx, t.pc, gap, exp_gap))
        end
      end
    end
    last_cycle = t.cycle;
    cur_idx++;
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("RETIRE_CHECKER", $sformatf("retire_checker summary: %0d instruction(s) retired in %0d program(s) | reg_writes=%0d stores=%0d ecalls=%0d | spacing checks=%0d errors=%0d",
              retired, seen_prog.num(), reg_writes, stores, halts, gap_checks, gap_errors), UVM_NONE)
  endfunction
endclass

typedef class cpu_bus_checker;

// ---- memory + stalls --------------------------------------------------------
class cpu_mem_checker extends uvm_subscriber #(mem_item);
  `uvm_component_utils(cpu_mem_checker)

  cpu_bus_checker bus;                       // set by the env

  int unsigned accesses, n_l1, n_csr, n_ext, n_gap;
  int unsigned stalled, max_stall, misaligned, oor;
  int unsigned l2_hits, l3_hits, imc_loads, ext_stores;
  int unsigned level_errors, stall_errors;

  // ---- reference model of the two caches (direct-mapped, read-allocate, write-through,
  //      writes update a line only on a hit and never allocate) ----
  localparam int L2_LINES = 64, L3_LINES = 128;
  bit [23:0] l2_tag [L2_LINES];   bit l2_valid [L2_LINES];
  bit [22:0] l3_tag [L3_LINES];   bit l3_valid [L3_LINES];
  int unsigned model_pid = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void model_reset();
    for (int i = 0; i < L2_LINES; i++) l2_valid[i] = 0;
    for (int i = 0; i < L3_LINES; i++) l3_valid[i] = 0;
  endfunction

  function bit model_l2_hit(bit [31:0] a);
    return l2_valid[a[7:2]] && (l2_tag[a[7:2]] == a[31:8]);
  endfunction
  function bit model_l3_hit(bit [31:0] a);
    return l3_valid[a[8:2]] && (l3_tag[a[8:2]] == a[31:9]);
  endfunction

  function void write(mem_item t);
    string pred = "";
    int    exp_stall = 0;
    accesses++;
    case (t.route)
      "L1":  n_l1++;
      "CSR": n_csr++;
      "EXT": n_ext++;
      default: n_gap++;
    endcase
    if (t.stall_cycles > 0)  stalled++;
    if (t.stall_cycles > max_stall) max_stall = t.stall_cycles;
    if (t.misaligned)    misaligned++;
    if (t.out_of_range)  oor++;

    // each program starts from reset, which clears both caches
    if (t.program_id != model_pid) begin
      model_pid = t.program_id;  model_reset();
      if (bus != null) bus.new_program(t.program_id);
    end

    if (t.level != "") begin                          // a real external cache access
      if (t.is_write) begin
        pred = "WR";  exp_stall = 4;  ext_stores++;
        if (bus != null) bus.mem_store(t.addr, t.data);
      end else begin
        pred = model_l2_hit(t.addr) ? "L2" : model_l3_hit(t.addr) ? "L3" : "IMC";
        exp_stall = (pred == "IMC") ? 7 : 0;
        case (t.level) "L2": l2_hits++;  "L3": l3_hits++;  default: begin imc_loads++;
          if (bus != null) bus.mem_imc_read(t.addr, t.data); end endcase
        // read miss fills L2; a read that missed L3 as well fills L3 too
        if (pred != "L2") begin l2_valid[t.addr[7:2]] = 1; l2_tag[t.addr[7:2]] = t.addr[31:8]; end
        if (pred == "IMC") begin l3_valid[t.addr[8:2]] = 1; l3_tag[t.addr[8:2]] = t.addr[31:9]; end
      end
      if (t.level != pred) begin
        level_errors++;
        `uvm_error("MEM_CHECKER", $sformatf("served by %s but the cache model predicts %s: %s", t.level, pred, t.convert2string()))
      end
    end
    else exp_stall = 0;                               // L1, CSR, hole, faulting accesses never stall

    if (t.stall_cycles != exp_stall) begin
      stall_errors++;
      `uvm_error("MEM_CHECKER", $sformatf("stalled %0d cycle(s), expected %0d: %s", t.stall_cycles, exp_stall, t.convert2string()))
    end
    `uvm_info("MEM_CHECKER", t.convert2string(), UVM_HIGH)
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("MEM_CHECKER", $sformatf("mem_checker summary: %0d access(es) | L1=%0d CSR=%0d EXT=%0d GAP=%0d | stalled=%0d max_stall=%0d | misaligned=%0d oor=%0d",
              accesses, n_l1, n_csr, n_ext, n_gap, stalled, max_stall, misaligned, oor), UVM_NONE)
    `uvm_info("MEM_CHECKER", $sformatf("mem_checker cache levels: loads L2-hit=%0d L3-hit=%0d iMC=%0d | external stores=%0d | level errors=%0d stall errors=%0d",
              l2_hits, l3_hits, imc_loads, ext_stores, level_errors, stall_errors), UVM_NONE)
  endfunction
endclass

// ---- bus checker: cache misses and stores must reach the iMC, nothing else may ----
class cpu_bus_checker extends uvm_subscriber #(cpu_program);
  `uvm_component_utils(cpu_bus_checker)

  // multisets keyed by {addr, data}
  int unsigned mem_w [bit [63:0]];   // external stores seen at the LSU
  int unsigned axi_w [bit [63:0]];   // AXI writes seen at the iMC
  int unsigned mem_r [bit [63:0]];   // loads served by the iMC (per the cache model / probes)
  int unsigned axi_r [bit [63:0]];   // AXI reads seen at the iMC
  int unsigned n_w, n_r, errors, resets;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Reset test: a program cut short by a reset leaves transactions half done, so what it contributed to
  // either side cannot be compared. The mem checker calls new_program() when a program's first access
  // appears, which snapshots everything seen so far; an abort puts that snapshot back, dropping only
  // the victim's traffic and keeping every earlier program's.
  int unsigned snap_pid = 0;
  int unsigned s_mem_w [bit [63:0]];  int unsigned s_axi_w [bit [63:0]];
  int unsigned s_mem_r [bit [63:0]];  int unsigned s_axi_r [bit [63:0]];

  function void new_program(int unsigned pid);
    snap_pid = pid;
    s_mem_w = mem_w;  s_axi_w = axi_w;  s_mem_r = mem_r;  s_axi_r = axi_r;
  endfunction

  function void write(cpu_program p);                 // from the driver's abort_ap
    if (snap_pid == p.program_id) begin
      mem_w = s_mem_w;  axi_w = s_axi_w;  mem_r = s_mem_r;  axi_r = s_axi_r;
    end
    resets++;
  endfunction

  function void mem_store(bit [31:0] a, bit [31:0] d);     mem_w[{a, d}]++; endfunction
  function void mem_imc_read(bit [31:0] a, bit [31:0] d);  mem_r[{a, d}]++; endfunction
  function void axi_write(bit [31:0] a, bit [31:0] d);     axi_w[{a, d}]++; endfunction
  function void axi_read(bit [31:0] a, bit [31:0] d);      axi_r[{a, d}]++; endfunction

  function void compare(bit is_w);
    string what = is_w ? "store" : "load";
    int unsigned lsu [bit [63:0]];
    int unsigned axi [bit [63:0]];
    int unsigned total = 0;
    if (is_w) begin lsu = mem_w; axi = axi_w; end else begin lsu = mem_r; axi = axi_r; end
    foreach (lsu[k]) begin
      int unsigned n_axi = axi.exists(k) ? axi[k] : 0;
      total += lsu[k];
      if (n_axi != lsu[k]) begin
        errors++;
        if (errors <= 10)
          `uvm_error("BUS_CHECKER", $sformatf("%s addr=0x%08h data=0x%08h: %0d at the LSU but %0d on AXI",
                     what, k[63:32], k[31:0], lsu[k], n_axi))
      end
    end
    foreach (axi[k]) if (!lsu.exists(k)) begin
      errors++;
      if (errors <= 10)
        `uvm_error("BUS_CHECKER", $sformatf("%s addr=0x%08h data=0x%08h: %0d AXI transaction(s) with no matching %s",
                   what, k[63:32], k[31:0], axi[k], is_w ? "store" : "cache miss"))
    end
    if (is_w) n_w = total; else n_r = total;
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    compare(1);
    compare(0);
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("BUS_CHECKER", $sformatf("bus_checker summary: %0d store(s) and %0d iMC-served load(s) matched against AXI | errors=%0d | programs aborted by reset=%0d",
              n_w, n_r, errors, resets), UVM_NONE)
  endfunction
endclass

// ---- AXI-Lite ---------------------------------------------------------------
class cpu_axi_checker extends uvm_subscriber #(axi_item);
  `uvm_component_utils(cpu_axi_checker)

  cpu_bus_checker bus;                       // set by the env
  int unsigned writes, reads, max_latency;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(axi_item t);
    if (t.is_write) begin writes++; if (bus != null) bus.axi_write(t.addr, t.data); end
    else            begin reads++;  if (bus != null) bus.axi_read (t.addr, t.data); end
    if (t.latency > max_latency) max_latency = t.latency;
    if (t.resp != 2'b00)
      `uvm_error("AXI_CHECKER", {"non-OKAY AXI response: ", t.convert2string()})
    `uvm_info("AXI_CHECKER", t.convert2string(), UVM_HIGH)
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("AXI_CHECKER", $sformatf("axi_checker summary: %0d write(s), %0d read(s) | max_latency=%0d",
              writes, reads, max_latency), UVM_NONE)
  endfunction
endclass

// ---- status / trap / halt ---------------------------------------------------
class cpu_status_checker extends uvm_subscriber #(status_item);
  `uvm_component_utils(cpu_status_checker)

  int unsigned halts, traps, misalign, oor, target_faults;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void write(status_item t);
    case (t.kind)
      ST_HALT:             halts++;
      ST_TRAP:             traps++;
      ST_MISALIGN:         misalign++;
      ST_OOR:              oor++;
      ST_MISALIGN_TARGET:  target_faults++;
      ST_PC_MOVED_AFTER_HALT:
        `uvm_error("STATUS_CHECKER", {"PC moved while halted: ", t.convert2string()})
      default: ;
    endcase
    `uvm_info("STATUS_CHECKER", t.convert2string(), UVM_HIGH)
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("STATUS_CHECKER", $sformatf("status_checker summary: halts=%0d traps=%0d misalign=%0d oor=%0d target_faults=%0d",
              halts, traps, misalign, oor, target_faults), UVM_NONE)
  endfunction
endclass
