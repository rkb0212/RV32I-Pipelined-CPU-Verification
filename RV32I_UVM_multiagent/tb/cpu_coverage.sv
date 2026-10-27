// =============================================================================
// cpu_coverage.sv   -- functional coverage
// Answers "what did the tests actually exercise?". Two sources:
//   1. golden model (golden_model.cpp): counts every architectural event it executes, over all
//      programs of the run: instruction kinds, immediates, memory region x operation x alignment,
//      CSR registers, trap causes, halt styles, register dependencies / load-use, branch direction.
//      Read once in report_phase through gm_cov_get().
//   2. the passive monitors (live): cache level of every external access, store tag hits, stall
//      length per access kind, L2 index / L3 index coverage, stall followed by trap or halt, AXI
//      latency / back-to-back / read-after-write, program size and trap count, reset cut points.
// Bins are declared up front, so a bin nobody hit shows up as MISSING in the report. Hand-rolled
// bins (an associative array of counters), not SystemVerilog covergroups: same information, and it
// builds and runs on any simulator. A bin that is hit but was never declared is printed as UNEXPECTED
// (for example a stall length no access kind should have).
// Report lines start with "COVERAGE" (UVM_NONE, always printed).
// =============================================================================
class cpu_cov_db;
  int unsigned hits   [string];           // key "group|bin"
  string       groups [$];
  string       decl   [string][$];        // group -> declared bins, in order
  int unsigned unexpected [string];

  function void declare(string grp, string bname);
    if (!decl.exists(grp)) begin groups.push_back(grp); decl[grp] = {}; end
    decl[grp].push_back(bname);
    hits[{grp, "|", bname}] = 0;
  endfunction

  function void hit(string grp, string bname, int unsigned n = 1);
    string k = {grp, "|", bname};
    if (hits.exists(k)) hits[k] += n;
    else unexpected[k] += n;
  endfunction

  function void report();
    int unsigned tot = 0, got = 0;
    foreach (groups[g]) begin
      int unsigned t = 0, h = 0;
      string miss = "";
      foreach (decl[groups[g]][b]) begin
        t++;
        if (hits[{groups[g], "|", decl[groups[g]][b]}] > 0) h++;
        else miss = {miss, (miss == "" ? "" : ", "), decl[groups[g]][b]};
      end
      tot += t;  got += h;
      `uvm_info("COVERAGE", $sformatf("%-34s %3d/%-3d %5.1f%%%s", groups[g], h, t, 100.0 * h / t,
                (miss == "") ? "" : {"   MISSING: ", miss}), UVM_NONE)
    end
    foreach (unexpected[k]) `uvm_info("COVERAGE", $sformatf("UNEXPECTED bin hit: %s (%0d time(s))", k, unexpected[k]), UVM_NONE)
    `uvm_info("COVERAGE", $sformatf("COVERAGE TOTAL: %0d/%0d bins hit (%0.1f%%)", got, tot, tot == 0 ? 0.0 : 100.0 * got / tot), UVM_NONE)
  endfunction
endclass

// ---- the live streams reach cpu_coverage through small forwarding subscribers ----
typedef class cpu_coverage;

class cov_exp_sub extends uvm_subscriber #(cpu_expected);
  `uvm_component_utils(cov_exp_sub)
  cpu_coverage cov;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void write(cpu_expected t); cov.sample_program(t); endfunction
endclass
class cov_mem_sub extends uvm_subscriber #(mem_item);
  `uvm_component_utils(cov_mem_sub)
  cpu_coverage cov;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void write(mem_item t); cov.sample_mem(t); endfunction
endclass
class cov_axi_sub extends uvm_subscriber #(axi_item);
  `uvm_component_utils(cov_axi_sub)
  cpu_coverage cov;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void write(axi_item t); cov.sample_axi(t); endfunction
endclass
class cov_status_sub extends uvm_subscriber #(status_item);
  `uvm_component_utils(cov_status_sub)
  cpu_coverage cov;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void write(status_item t); cov.sample_status(t); endfunction
endclass
class cov_abort_sub extends uvm_subscriber #(cpu_program);
  `uvm_component_utils(cov_abort_sub)
  cpu_coverage cov;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void write(cpu_program t); cov.sample_abort(t); endfunction
endclass

class cpu_coverage extends uvm_component;
  `uvm_component_utils(cpu_coverage)

  cov_exp_sub    exp_sub;     // expected end state of each program (size, trap count)
  cov_mem_sub    mem_sub;     // every LSU access
  cov_axi_sub    axi_sub;     // every AXI transaction
  cov_status_sub status_sub;  // halt / trap / fault pulses
  cov_abort_sub  abort_sub;   // programs cut short by a reset

  cpu_cov_db db;

  // golden-model bin names, in the order of the C++ enum CovId (checked against gm_cov_count())
  string gm_bin [$];
  function void init_gm_names();
    gm_bin = '{
      "I_ADD",
      "I_SUB",
      "I_AND",
      "I_OR",
      "I_ADDI",
      "I_LUI",
      "I_LW",
      "I_SW",
      "I_BEQ_TAKEN",
      "I_BEQ_NOT_TAKEN",
      "I_JAL",
      "I_ECALL",
      "I_MRET",
      "I_UNSUPPORTED",
      "I_WRITES_X0",
      "IMM_NEG",
      "IMM_ZERO",
      "IMM_POS",
      "IMM_MAX",
      "IMM_MIN",
      "OFF_NEG",
      "OFF_ZERO",
      "OFF_POS",
      "M_L1_LW_ALIGNED",
      "M_L1_LW_MISALIGNED",
      "M_L1_SW_ALIGNED",
      "M_L1_SW_MISALIGNED",
      "M_EXT_LW_ALIGNED",
      "M_EXT_LW_MISALIGNED",
      "M_EXT_SW_ALIGNED",
      "M_EXT_SW_MISALIGNED",
      "M_HOLE_LW_ALIGNED",
      "M_HOLE_LW_MISALIGNED",
      "M_HOLE_SW_ALIGNED",
      "M_HOLE_SW_MISALIGNED",
      "M_CSR_IN_LW_ALIGNED",
      "M_CSR_IN_LW_MISALIGNED",
      "M_CSR_IN_SW_ALIGNED",
      "M_CSR_IN_SW_MISALIGNED",
      "M_CSR_BEYOND_LW_ALIGNED",
      "M_CSR_BEYOND_LW_MISALIGNED",
      "M_CSR_BEYOND_SW_ALIGNED",
      "M_CSR_BEYOND_SW_MISALIGNED",
      "T_TARGET_JAL",
      "T_TARGET_BEQ",
      "T_LOAD_MIS",
      "T_STORE_MIS",
      "T_NESTED",
      "C_CYCLE_R",
      "C_CYCLE_W",
      "C_INSTR_R",
      "C_INSTR_W",
      "C_HALT_R",
      "C_HALT_W",
      "C_SCRATCH_R",
      "C_SCRATCH_W",
      "C_MTVEC_R",
      "C_MTVEC_W",
      "C_MEPC_R",
      "C_MEPC_W",
      "C_MCAUSE_R",
      "C_MCAUSE_W",
      "C_MTVAL_R",
      "C_MTVAL_W",
      "C_RO_WRITE",
      "C_MTVEC_LOW_BITS",
      "C_MEPC_LOW_BITS",
      "C_HALT_BIT0_CLEAR",
      "H_ECALL",
      "H_SW",
      "H_AFTER_TAKEN",
      "H_IN_HANDLER",
      "D_DIST1",
      "D_DIST2",
      "D_DIST3",
      "LU_ALU_RS1",
      "LU_ALU_RS2",
      "LU_BASE",
      "LU_STORE_DATA",
      "LU_BRANCH",
      "BEQ_FWD_TAKEN",
      "BEQ_BWD_TAKEN",
      "JAL_FWD",
      "JAL_BWD",
      "BEQ_CMP_X0"
    };
  endfunction

  // group a golden-model bin belongs to, from its name
  function string gm_group(string n);
    if (n.substr(0, 1) == "I_")                                  return "instruction kinds (model)";
    if (n.substr(0, 3) == "IMM_" || n.substr(0, 3) == "OFF_")    return "immediates and offsets (model)";
    if (n.substr(0, 1) == "M_")                                  return "memory region x op x alignment";
    if (n.substr(0, 1) == "T_")                                  return "trap causes (model)";
    if (n.substr(0, 1) == "C_")                                  return "CSR registers (model)";
    if (n.substr(0, 1) == "H_")                                  return "halt styles (model)";
    if (n.substr(0, 1) == "D_" || n.substr(0, 2) == "LU")        return "dependencies, load-use (model)";
    return "control flow (model)";
  endfunction

  // live-state trackers
  int unsigned cur_pid = 0;
  string       prev_level = "";
  int unsigned last_stall_cycle = 0, last_trap_cycle = 0, last_axi_cycle = 0;
  bit          seen_trap = 0, seen_stall = 0, seen_axi = 0;
  bit          written [bit [31:0]];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void declare_all();
    string lv [3] = '{"L2", "L3", "IMC"};
    init_gm_names();
    foreach (gm_bin[i]) db.declare(gm_group(gm_bin[i]), gm_bin[i]);

    foreach (lv[i]) db.declare("external load served by", {"LD_", lv[i]});
    foreach (lv[i]) foreach (lv[j]) db.declare("external load: previous -> this", {lv[i], "_to_", lv[j]});
    db.declare("external store vs caches", "ST_L2_HIT");  db.declare("external store vs caches", "ST_L2_MISS");
    db.declare("external store vs caches", "ST_L3_HIT");  db.declare("external store vs caches", "ST_L3_MISS");
    db.declare("stall length by access kind", "NONE_L1");     db.declare("stall length by access kind", "NONE_CSR");
    db.declare("stall length by access kind", "NONE_OTHER");  db.declare("stall length by access kind", "NONE_HIT");
    db.declare("stall length by access kind", "ST_4");        db.declare("stall length by access kind", "LD_IMC_7");
    for (int i = 0; i < 64; i++)  db.declare("L2 index touched (64)", $sformatf("idx%0d", i));
    for (int i = 0; i < 16; i++)  db.declare("L3 index bucket touched (16)", $sformatf("idx%0d-%0d", i * 8, i * 8 + 7));
    db.declare("events close together", "STALL_THEN_TRAP");  db.declare("events close together", "STALL_THEN_HALT");
    db.declare("events close together", "HALT_AFTER_TRAP");  db.declare("events close together", "TRAP_AFTER_TRAP");
    db.declare("AXI traffic", "WR_LAT_LE4");  db.declare("AXI traffic", "WR_LAT_5_8");  db.declare("AXI traffic", "WR_LAT_GT8");
    db.declare("AXI traffic", "RD_LAT_LE4");  db.declare("AXI traffic", "RD_LAT_5_8");  db.declare("AXI traffic", "RD_LAT_GT8");
    db.declare("AXI traffic", "BACK_TO_BACK");  db.declare("AXI traffic", "READ_AFTER_WRITE_SAME_ADDR");
    db.declare("AXI traffic", "ADDR_0400_07FF");  db.declare("AXI traffic", "ADDR_0800_0FFF");  db.declare("AXI traffic", "ADDR_1000_UP");
    db.declare("program size / traps", "TRAPS_0");  db.declare("program size / traps", "TRAPS_1");
    db.declare("program size / traps", "TRAPS_2");  db.declare("program size / traps", "TRAPS_3PLUS");
    db.declare("program size / traps", "STEPS_LE10");  db.declare("program size / traps", "STEPS_11_50");
    db.declare("program size / traps", "STEPS_51_200");  db.declare("program size / traps", "STEPS_GT200");
    db.declare("reset cut point (clocks)", "RST_LE8");   db.declare("reset cut point (clocks)", "RST_9_24");
    db.declare("reset cut point (clocks)", "RST_25_50"); db.declare("reset cut point (clocks)", "RST_GT50");
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    db = new();
    exp_sub    = cov_exp_sub   ::type_id::create("exp_sub",    this);
    mem_sub    = cov_mem_sub   ::type_id::create("mem_sub",    this);
    axi_sub    = cov_axi_sub   ::type_id::create("axi_sub",    this);
    status_sub = cov_status_sub::type_id::create("status_sub", this);
    abort_sub  = cov_abort_sub ::type_id::create("abort_sub",  this);
    exp_sub.cov = this;  mem_sub.cov = this;  axi_sub.cov = this;  status_sub.cov = this;  abort_sub.cov = this;
    declare_all();
  endfunction

  // new program id on any stream: forget the per-program trackers
  function void pid_check(int unsigned pid);
    if (pid != cur_pid) begin
      cur_pid = pid;  prev_level = "";  written.delete();
      seen_trap = 0;  seen_stall = 0;  seen_axi = 0;
    end
  endfunction

  function void sample_mem(mem_item t);
    string b;
    pid_check(t.program_id);
    if (t.stall_cycles > 0) begin last_stall_cycle = t.cycle;  seen_stall = 1; end

    // stall length by access kind
    // (plain if/else everywhere: xsim mishandles `cond ? "literal" : "longer literal"` for strings)
    if (t.level == "IMC") begin
      if (t.stall_cycles == 7) b = "LD_IMC_7"; else b = $sformatf("LD_IMC_%0d", t.stall_cycles);
    end else if (t.level == "WR") begin
      if (t.stall_cycles == 4) b = "ST_4"; else b = $sformatf("ST_%0d", t.stall_cycles);
    end else if (t.level == "L2" || t.level == "L3") begin
      if (t.stall_cycles == 0) b = "NONE_HIT"; else b = $sformatf("HIT_%0d", t.stall_cycles);
    end else begin
      if (t.stall_cycles != 0)      b = $sformatf("OTHER_%0d", t.stall_cycles);
      else if (t.route == "L1")     b = "NONE_L1";
      else if (t.route == "CSR")    b = "NONE_CSR";
      else                          b = "NONE_OTHER";
    end
    db.hit("stall length by access kind", b);

    if (t.level == "") return;                       // L1 / CSR / hole / faulting: nothing cache-related
    db.hit("L2 index touched (64)", $sformatf("idx%0d", t.addr[7:2]));
    db.hit("L3 index bucket touched (16)", $sformatf("idx%0d-%0d", (t.addr[8:2] / 8) * 8, (t.addr[8:2] / 8) * 8 + 7));
    if (t.is_write) begin
      if (t.l2_hit) db.hit("external store vs caches", "ST_L2_HIT"); else db.hit("external store vs caches", "ST_L2_MISS");
      if (t.l3_hit) db.hit("external store vs caches", "ST_L3_HIT"); else db.hit("external store vs caches", "ST_L3_MISS");
    end
    else begin
      db.hit("external load served by", {"LD_", t.level});
      if (prev_level != "") db.hit("external load: previous -> this", {prev_level, "_to_", t.level});
      prev_level = t.level;
    end
  endfunction

  function void sample_status(status_item t);
    pid_check(t.program_id);
    case (t.kind)
      ST_TRAP: begin
        if (seen_stall && t.cycle - last_stall_cycle <= 3) db.hit("events close together", "STALL_THEN_TRAP");
        if (seen_trap  && t.cycle - last_trap_cycle  <= 20) db.hit("events close together", "TRAP_AFTER_TRAP");
        last_trap_cycle = t.cycle;  seen_trap = 1;
      end
      ST_HALT: begin
        if (seen_stall && t.cycle - last_stall_cycle <= 3) db.hit("events close together", "STALL_THEN_HALT");
        if (seen_trap  && t.cycle - last_trap_cycle  <= 30) db.hit("events close together", "HALT_AFTER_TRAP");
      end
      default: ;
    endcase
  endfunction

  function void sample_axi(axi_item t);
    string kind;
    if (t.is_write) kind = "WR"; else kind = "RD";
    pid_check(t.program_id);
    if      (t.latency <= 4) db.hit("AXI traffic", {kind, "_LAT_LE4"});
    else if (t.latency <= 8) db.hit("AXI traffic", {kind, "_LAT_5_8"});
    else                     db.hit("AXI traffic", {kind, "_LAT_GT8"});
    if (seen_axi && t.cycle - last_axi_cycle <= 2) db.hit("AXI traffic", "BACK_TO_BACK");
    last_axi_cycle = t.cycle;  seen_axi = 1;
    if (t.is_write) written[t.addr] = 1;
    else if (written.exists(t.addr)) db.hit("AXI traffic", "READ_AFTER_WRITE_SAME_ADDR");
    if      (t.addr < 32'h800)  db.hit("AXI traffic", "ADDR_0400_07FF");
    else if (t.addr < 32'h1000) db.hit("AXI traffic", "ADDR_0800_0FFF");
    else                        db.hit("AXI traffic", "ADDR_1000_UP");
  endfunction

  function void sample_program(cpu_expected e);
    if      (e.trap_count == 0) db.hit("program size / traps", "TRAPS_0");
    else if (e.trap_count == 1) db.hit("program size / traps", "TRAPS_1");
    else if (e.trap_count == 2) db.hit("program size / traps", "TRAPS_2");
    else                        db.hit("program size / traps", "TRAPS_3PLUS");
    if      (e.steps <= 10)  db.hit("program size / traps", "STEPS_LE10");
    else if (e.steps <= 50)  db.hit("program size / traps", "STEPS_11_50");
    else if (e.steps <= 200) db.hit("program size / traps", "STEPS_51_200");
    else                     db.hit("program size / traps", "STEPS_GT200");
  endfunction

  function void sample_abort(cpu_program p);
    if      (p.abort_at <= 8)  db.hit("reset cut point (clocks)", "RST_LE8");
    else if (p.abort_at <= 24) db.hit("reset cut point (clocks)", "RST_9_24");
    else if (p.abort_at <= 50) db.hit("reset cut point (clocks)", "RST_25_50");
    else                       db.hit("reset cut point (clocks)", "RST_GT50");
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (gm_cov_count() != gm_bin.size())
      `uvm_warning("COVERAGE", $sformatf("golden model counts %0d bins but cpu_coverage names %0d: the lists are out of step", gm_cov_count(), gm_bin.size()))
    else
      foreach (gm_bin[i]) db.hit(gm_group(gm_bin[i]), gm_bin[i], gm_cov_get(i));
    db.report();
  endfunction
endclass
