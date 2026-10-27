// =============================================================================
// golden_model.cpp
// DPI-C reference model of the RV32I-subset CPU, written in C++ (a GoldenModel
// class behind a thin extern "C" layer for DPI). Non-pipelined: one instruction
// per step. The UVM predictor runs a whole program through it and the scoreboard
// compares the result with what the DUT ended up with.
//
// It models what the DUT's ARCHITECTURE promises, not its pipeline:
//   - RV32I subset: ADD SUB AND OR, ADDI, LW, SW, BEQ, LUI, JAL, ECALL, MRET.
//     Anything else decodes as a NOP (same as the DUT).
//   - Address map (byte addresses):
//       L1 data RAM   [0x0000, 0x0400)         256 words
//       external      [0x0400, 0x4000)         4096 words behind L2/L3/AXI/iMC
//                                              (caches are write-through, so the
//                                               model keeps one coherent array)
//       hole          [0x4000, 0xFFFFFF00)     aligned access: out-of-range flag only,
//                                              store ignored, load data UNDEFINED
//       CSR window    [0xFFFFFF00, +32 bytes)  CYCLE INSTR HALT SCRATCH MTVEC MEPC MCAUSE MTVAL
//                                              beyond the 8 words: out-of-range, reads 0
//   - Misaligned LW/SW (any region) -> precise trap, cause 4 / 6, MTVAL = address.
//     Misaligned taken BEQ / JAL target -> trap, cause 0, MTVAL = target, MEPC = its PC.
//     The faulting instruction writes nothing. PC goes to MTVEC. MRET: PC = MEPC.
//   - Halt: ECALL, or a SW with bit 0 set to HALT_CTRL (that SW completes first).
//   - INSTR_COUNT counts exactly what the DUT's instr_retired counts: every
//     instruction with a register write, a store, or ECALL that does not trap.
//     BEQ, MRET and unsupported (NOP-decoded) instructions are not counted; ADDI x0 is.
//
// Values the model cannot know are TAINTED instead of guessed, and the scoreboard
// skips them: a LW from CYCLE_COUNT (timing dependent) and a LW from the address
// hole (the DUT returns whatever is on its data bus). Taint follows the data
// through ALU ops, stores and loads. If a BRANCH operand or a LW/SW address is
// tainted the model sets `diverged` and the scoreboard skips the whole compare.
//
// DPI note: only 32-bit `int` crosses the boundary; indices are word indices.
// Build for xsim:   xsc golden_model.cpp   then   xelab ... -sv_lib dpi
// Standalone test:  g++ -DGM_STANDALONE_TEST -o gm_test golden_model.cpp && ./gm_test
// =============================================================================
#include <cstdint>
#include <cstring>

namespace {

constexpr int      IMEM_DEPTH = 256;
constexpr int      DMEM_DEPTH = 256;
constexpr int      IMC_WORDS  = 4096;
constexpr uint32_t L1_BYTES   = DMEM_DEPTH * 4u;
constexpr uint32_t EXT_BYTES  = IMC_WORDS * 4u;
constexpr uint32_t CSR_BASE   = 0xFFFFFF00u;
constexpr uint32_t CSR_WORDS  = 8;

constexpr uint32_t OPCODE_OP     = 0x33;
constexpr uint32_t OPCODE_OP_IMM = 0x13;
constexpr uint32_t OPCODE_LOAD   = 0x03;
constexpr uint32_t OPCODE_STORE  = 0x23;
constexpr uint32_t OPCODE_BRANCH = 0x63;
constexpr uint32_t OPCODE_LUI    = 0x37;
constexpr uint32_t OPCODE_JAL    = 0x6F;
constexpr uint32_t OPCODE_SYSTEM = 0x73;
constexpr uint32_t INSTR_ECALL   = 0x00000073u;
constexpr uint32_t INSTR_MRET    = 0x30200073u;

enum Csr : uint32_t { CSR_CYCLE = 0, CSR_INSTR, CSR_HALT, CSR_SCRATCH, CSR_MTVEC, CSR_MEPC, CSR_MCAUSE, CSR_MTVAL };

// ---- functional coverage counters --------------------------------------------
// One counter per bin, counted every time the model executes something that matches. They live outside the
// GoldenModel object, so gm_reset() between programs does not clear them: the SV coverage report reads the
// totals over the whole run (gm_cov_count / gm_cov_get). cpu_coverage.sv keeps the names in the same order.
enum CovId : int {
    I_ADD,
    I_SUB,
    I_AND,
    I_OR,
    I_ADDI,
    I_LUI,
    I_LW,
    I_SW,
    I_BEQ_TAKEN,
    I_BEQ_NOT_TAKEN,
    I_JAL,
    I_ECALL,
    I_MRET,
    I_UNSUPPORTED,
    I_WRITES_X0,
    IMM_NEG,
    IMM_ZERO,
    IMM_POS,
    IMM_MAX,
    IMM_MIN,
    OFF_NEG,
    OFF_ZERO,
    OFF_POS,
    M_L1_LW_ALIGNED,
    M_L1_LW_MISALIGNED,
    M_L1_SW_ALIGNED,
    M_L1_SW_MISALIGNED,
    M_EXT_LW_ALIGNED,
    M_EXT_LW_MISALIGNED,
    M_EXT_SW_ALIGNED,
    M_EXT_SW_MISALIGNED,
    M_HOLE_LW_ALIGNED,
    M_HOLE_LW_MISALIGNED,
    M_HOLE_SW_ALIGNED,
    M_HOLE_SW_MISALIGNED,
    M_CSR_IN_LW_ALIGNED,
    M_CSR_IN_LW_MISALIGNED,
    M_CSR_IN_SW_ALIGNED,
    M_CSR_IN_SW_MISALIGNED,
    M_CSR_BEYOND_LW_ALIGNED,
    M_CSR_BEYOND_LW_MISALIGNED,
    M_CSR_BEYOND_SW_ALIGNED,
    M_CSR_BEYOND_SW_MISALIGNED,
    T_TARGET_JAL,
    T_TARGET_BEQ,
    T_LOAD_MIS,
    T_STORE_MIS,
    T_NESTED,
    C_CYCLE_R,
    C_CYCLE_W,
    C_INSTR_R,
    C_INSTR_W,
    C_HALT_R,
    C_HALT_W,
    C_SCRATCH_R,
    C_SCRATCH_W,
    C_MTVEC_R,
    C_MTVEC_W,
    C_MEPC_R,
    C_MEPC_W,
    C_MCAUSE_R,
    C_MCAUSE_W,
    C_MTVAL_R,
    C_MTVAL_W,
    C_RO_WRITE,
    C_MTVEC_LOW_BITS,
    C_MEPC_LOW_BITS,
    C_HALT_BIT0_CLEAR,
    H_ECALL,
    H_SW,
    H_AFTER_TAKEN,
    H_IN_HANDLER,
    D_DIST1,
    D_DIST2,
    D_DIST3,
    LU_ALU_RS1,
    LU_ALU_RS2,
    LU_BASE,
    LU_STORE_DATA,
    LU_BRANCH,
    BEQ_FWD_TAKEN,
    BEQ_BWD_TAKEN,
    JAL_FWD,
    JAL_BWD,
    BEQ_CMP_X0,
    COV_N
};
uint32_t g_cov[COV_N];
inline void cov_hit(int id) { g_cov[id]++; }


int32_t sext(uint32_t v, int bits) {
    const uint32_t sign = 1u << (bits - 1);
    const uint32_t mask = (bits == 32) ? 0xFFFFFFFFu : ((1u << bits) - 1u);
    v &= mask;
    if (v & sign) v |= ~mask;
    return static_cast<int32_t>(v);
}
int32_t imm_i(uint32_t x) { return sext(x >> 20, 12); }
int32_t imm_s(uint32_t x) { return sext((((x >> 25) & 0x7F) << 5) | ((x >> 7) & 0x1F), 12); }
int32_t imm_b(uint32_t x) {
    return sext((((x >> 31) & 1) << 12) | (((x >> 7) & 1) << 11) | (((x >> 25) & 0x3F) << 5) | (((x >> 8) & 0xF) << 1), 13);
}
int32_t imm_u(uint32_t x) { return static_cast<int32_t>(x & 0xFFFFF000u); }
int32_t imm_j(uint32_t x) {
    return sext((((x >> 31) & 1) << 20) | (((x >> 12) & 0xFF) << 12) | (((x >> 20) & 1) << 11) | (((x >> 21) & 0x3FF) << 1), 21);
}

class GoldenModel {
public:
    // ---- architectural state ----
    uint32_t imem[IMEM_DEPTH];
    uint32_t dmem[DMEM_DEPTH];
    uint32_t ext[IMC_WORDS];
    uint8_t  dmem_t[DMEM_DEPTH];     // 1 = word unknown
    uint8_t  ext_t[IMC_WORDS];
    uint32_t regs[32];
    uint32_t reg_t;                  // bit i set = x[i] unknown
    uint32_t pc, halt_pc;
    bool     halted, diverged;
    uint32_t mtvec, mepc, mcause, mtval, scratch, halt_ctrl;
    bool     scratch_t;
    uint32_t instr_count;
    int      trap_count, misalign_count, oor_count, target_fault_count;
    long     steps;
    // coverage bookkeeping (reset with the model): the registers written by the last three executed
    // instructions, whether the last one was a load, whether it was a taken branch/jump, handler flag
    uint32_t h1, h2, h3, cur_wr;
    bool     h1_load, cur_load, prev_taken, in_handler;

    GoldenModel() { reset(); }

    void reset() { std::memset(this, 0, sizeof(*this)); }
    void load_instr(int idx, uint32_t instr) { imem[idx & (IMEM_DEPTH - 1)] = instr; }
    bool tainted(uint32_t r) const { return (reg_t >> r) & 1u; }

    void run(int max_steps) {
        for (int i = 0; i < max_steps && !halted; i++) step();
    }

    // One architectural instruction.
    void step() {
        if (halted) return;
        const uint32_t instr  = imem[(pc >> 2) & (IMEM_DEPTH - 1)];
        const uint32_t opcode = instr & 0x7F;
        const uint32_t rd     = (instr >> 7)  & 0x1F;
        const uint32_t f3     = (instr >> 12) & 7;
        const uint32_t rs1    = (instr >> 15) & 0x1F;
        const uint32_t rs2    = (instr >> 20) & 0x1F;
        const uint32_t f7     = (instr >> 25) & 0x7F;
        uint32_t pc_next = pc + 4u;
        uint32_t count   = 0;
        bool     took    = false;
        steps++;
        cur_wr = 0;  cur_load = false;

        switch (opcode) {
        case OPCODE_OP: {
            const uint32_t a = regs[rs1], b = regs[rs2];
            uint32_t r = 0; bool ok = true;
            dep(rs1, DEP_ALU_RS1);  dep(rs2, DEP_ALU_RS2);
            if      (f3 == 0 && f7 == 0x00) { r = a + b; cov_hit(I_ADD); }
            else if (f3 == 0 && f7 == 0x20) { r = a - b; cov_hit(I_SUB); }
            else if (f3 == 7 && f7 == 0x00) { r = a & b; cov_hit(I_AND); }
            else if (f3 == 6 && f7 == 0x00) { r = a | b; cov_hit(I_OR);  }
            else ok = false;
            if (ok) { set_reg(rd, r, tainted(rs1) || tainted(rs2)); count = 1; if (rd == 0) cov_hit(I_WRITES_X0); }
            else cov_hit(I_UNSUPPORTED);
            break; }
        case OPCODE_OP_IMM:
            if (f3 == 0) {
                const int32_t im = imm_i(instr);
                dep(rs1, DEP_ALU_RS1);
                cov_hit(I_ADDI);
                cov_hit(im < 0 ? IMM_NEG : (im == 0 ? IMM_ZERO : IMM_POS));
                if (im == 2047) cov_hit(IMM_MAX);
                if (im == -2048) cov_hit(IMM_MIN);
                if (rd == 0) cov_hit(I_WRITES_X0);
                set_reg(rd, regs[rs1] + static_cast<uint32_t>(im), tainted(rs1)); count = 1;
            } else cov_hit(I_UNSUPPORTED);
            break;
        case OPCODE_LOAD:
            if (f3 == 2) {
                const int32_t  off  = imm_i(instr);
                const uint32_t addr = regs[rs1] + static_cast<uint32_t>(off);
                uint32_t v = 0; bool t = false;
                dep(rs1, DEP_BASE);
                cov_hit(I_LW);  cov_off(off);  cov_mem(addr, false);
                if (tainted(rs1)) diverged = true;
                if (addr & 3u) { misalign_count++; take_trap(4, pc, addr); return; }
                if (addr >= CSR_BASE) {
                    const uint32_t idx = (addr - CSR_BASE) >> 2;
                    if (idx >= CSR_WORDS) oor_count++; else { cov_hit(C_CYCLE_R + 2 * idx); v = csr_read(idx, t); }
                } else if (addr < L1_BYTES)  { v = dmem[addr >> 2]; t = dmem_t[addr >> 2]; }
                else if (addr < EXT_BYTES)   { v = ext[addr >> 2];  t = ext_t[addr >> 2]; }
                else                         { oor_count++; t = true; }      // hole: data undefined
                if (rd == 0) cov_hit(I_WRITES_X0);
                set_reg(rd, v, t); count = 1; cur_load = (rd != 0);
            } else cov_hit(I_UNSUPPORTED);
            break;
        case OPCODE_STORE:
            if (f3 == 2) {
                const int32_t  off  = imm_s(instr);
                const uint32_t addr = regs[rs1] + static_cast<uint32_t>(off);
                const uint32_t d = regs[rs2]; const bool dt = tainted(rs2);
                dep(rs1, DEP_BASE);  dep(rs2, DEP_STORE_DATA);
                cov_hit(I_SW);  cov_off(off);  cov_mem(addr, true);
                if (tainted(rs1)) diverged = true;
                if (addr & 3u) { misalign_count++; take_trap(6, pc, addr); return; }
                if (addr >= CSR_BASE) {
                    const uint32_t idx = (addr - CSR_BASE) >> 2;
                    if (idx >= CSR_WORDS) oor_count++;
                    else {
                        cov_hit(C_CYCLE_R + 2 * idx + 1);
                        if (idx == CSR_CYCLE || idx == CSR_INSTR || idx == CSR_MCAUSE || idx == CSR_MTVAL) cov_hit(C_RO_WRITE);
                        if (idx == CSR_MTVEC && (d & 3u)) cov_hit(C_MTVEC_LOW_BITS);
                        if (idx == CSR_MEPC  && (d & 3u)) cov_hit(C_MEPC_LOW_BITS);
                        if (idx == CSR_HALT  && !(d & 1u)) cov_hit(C_HALT_BIT0_CLEAR);
                        if (idx == CSR_HALT  &&  (d & 1u)) cov_halt(H_SW);
                        csr_write(idx, d, dt);
                    }
                } else if (addr < L1_BYTES)  { dmem[addr >> 2] = d; dmem_t[addr >> 2] = dt; }
                else if (addr < EXT_BYTES)   { ext[addr >> 2]  = d; ext_t[addr >> 2]  = dt; }
                else                         { oor_count++; }                // hole: store ignored
                count = 1;
            } else cov_hit(I_UNSUPPORTED);
            break;
        case OPCODE_BRANCH:
            if (f3 == 0) {
                dep(rs1, DEP_BRANCH);  dep(rs2, DEP_BRANCH);
                if (rs1 == 0 || rs2 == 0) cov_hit(BEQ_CMP_X0);
                if (tainted(rs1) || tainted(rs2)) diverged = true;
                if (regs[rs1] == regs[rs2]) {
                    const int32_t  bo     = imm_b(instr);
                    const uint32_t target = pc + static_cast<uint32_t>(bo);
                    cov_hit(I_BEQ_TAKEN);  cov_hit(bo < 0 ? BEQ_BWD_TAKEN : BEQ_FWD_TAKEN);
                    if (target & 3u) { target_fault_count++; cov_hit(T_TARGET_BEQ); take_trap(0, pc, target); return; }
                    pc_next = target;  took = true;
                } else cov_hit(I_BEQ_NOT_TAKEN);
            } else cov_hit(I_UNSUPPORTED);
            break;
        case OPCODE_LUI:
            cov_hit(I_LUI);  if (rd == 0) cov_hit(I_WRITES_X0);
            set_reg(rd, static_cast<uint32_t>(imm_u(instr)), false); count = 1;
            break;
        case OPCODE_JAL: {
            const int32_t  jo     = imm_j(instr);
            const uint32_t target = pc + static_cast<uint32_t>(jo);
            cov_hit(I_JAL);  cov_hit(jo < 0 ? JAL_BWD : JAL_FWD);
            if (target & 3u) { target_fault_count++; cov_hit(T_TARGET_JAL); take_trap(0, pc, target); return; }
            if (rd == 0) cov_hit(I_WRITES_X0);
            set_reg(rd, pc + 4u, false); count = 1; pc_next = target; took = true;
            break; }
        case OPCODE_SYSTEM:
            if (instr == INSTR_ECALL)     { cov_hit(I_ECALL); cov_halt(H_ECALL); halted = true; halt_pc = pc; count = 1; pc_next = pc; }
            else if (instr == INSTR_MRET) { cov_hit(I_MRET); in_handler = false; pc_next = mepc; }
            else cov_hit(I_UNSUPPORTED);
            break;
        default:
            cov_hit(I_UNSUPPORTED);                  // unsupported -> NOP
            break;
        }
        instr_count += count;
        pc = pc_next;
        regs[0] = 0; reg_t &= ~1u;
        h3 = h2;  h2 = h1;  h1 = cur_wr;  h1_load = cur_load;  prev_taken = took;
    }

private:
    // ---- coverage helpers ----
    enum DepKind { DEP_ALU_RS1, DEP_ALU_RS2, DEP_BASE, DEP_STORE_DATA, DEP_BRANCH };

    // `r` is read now: how far back was it written (1, 2 or 3 instructions), and was that writer a load?
    void dep(uint32_t r, DepKind kind) {
        if (r == 0) return;
        if (r == h1) {
            cov_hit(D_DIST1);
            if (h1_load) switch (kind) {
                case DEP_ALU_RS1:    cov_hit(LU_ALU_RS1);    break;
                case DEP_ALU_RS2:    cov_hit(LU_ALU_RS2);    break;
                case DEP_BASE:       cov_hit(LU_BASE);       break;
                case DEP_STORE_DATA: cov_hit(LU_STORE_DATA); break;
                case DEP_BRANCH:     cov_hit(LU_BRANCH);     break;
            }
        }
        else if (r == h2) cov_hit(D_DIST2);
        else if (r == h3) cov_hit(D_DIST3);
    }
    void cov_off(int32_t off) { cov_hit(off < 0 ? OFF_NEG : (off == 0 ? OFF_ZERO : OFF_POS)); }
    // region x operation x alignment of a load/store address
    void cov_mem(uint32_t addr, bool is_store) {
        int region;
        if (addr >= CSR_BASE)         region = (((addr - CSR_BASE) >> 2) < CSR_WORDS) ? 3 : 4;
        else if (addr < L1_BYTES)     region = 0;
        else if (addr < EXT_BYTES)    region = 1;
        else                          region = 2;
        cov_hit(M_L1_LW_ALIGNED + region * 4 + (is_store ? 2 : 0) + ((addr & 3u) ? 1 : 0));
    }
    void cov_halt(int which) {
        cov_hit(which);
        if (prev_taken) cov_hit(H_AFTER_TAKEN);
        if (in_handler) cov_hit(H_IN_HANDLER);
    }

    void set_reg(uint32_t rd, uint32_t v, bool t) {
        if (rd == 0) return;                         // x0 is hard-wired to zero
        cur_wr = rd;
        regs[rd] = v;
        if (t) reg_t |= (1u << rd); else reg_t &= ~(1u << rd);
    }

    void take_trap(uint32_t cause, uint32_t epc, uint32_t tval) {
        if (cause == 4) cov_hit(T_LOAD_MIS);
        if (cause == 6) cov_hit(T_STORE_MIS);
        if (in_handler) cov_hit(T_NESTED);
        in_handler = true;
        h3 = h2;  h2 = h1;  h1 = 0;  h1_load = false;  prev_taken = false;    // the trapping instruction wrote nothing
        mepc = epc; mcause = cause; mtval = tval;
        trap_count++;
        pc = mtvec;
    }

    uint32_t csr_read(uint32_t idx, bool &t) const {
        t = false;
        switch (idx) {
        case CSR_CYCLE:   t = true; return 0;        // timing dependent: unknown
        case CSR_INSTR:   return instr_count;
        case CSR_HALT:    return halt_ctrl;
        case CSR_SCRATCH: t = scratch_t; return scratch;
        case CSR_MTVEC:   return mtvec;
        case CSR_MEPC:    return mepc;
        case CSR_MCAUSE:  return mcause;
        case CSR_MTVAL:   return mtval;
        }
        return 0;
    }

    void csr_write(uint32_t idx, uint32_t d, bool dt) {
        switch (idx) {
        case CSR_HALT:
            if (dt) diverged = true;
            halt_ctrl = d;
            if (d & 1u) { halted = true; halt_pc = pc; }
            break;
        case CSR_SCRATCH: scratch = d; scratch_t = dt; break;
        case CSR_MTVEC:   if (dt) diverged = true; mtvec = d & ~3u; break;
        case CSR_MEPC:    if (dt) diverged = true; mepc  = d & ~3u; break;
        default: break;                              // CYCLE INSTR MCAUSE MTVAL are read-only
        }
    }
};

GoldenModel gm;

}  // namespace

// ---------------------------------------------------------------------------
// DPI-C layer (C linkage, 32-bit int only)
// ---------------------------------------------------------------------------
extern "C" {
void gm_reset(void)                    { gm.reset(); }
void gm_load_instr(int idx, int instr) { gm.load_instr(idx, static_cast<uint32_t>(instr)); }
void gm_run(int max_steps)             { gm.run(max_steps); }

int gm_cov_count(void)           { return COV_N; }
int gm_cov_get(int id)           { return (id >= 0 && id < COV_N) ? static_cast<int>(g_cov[id]) : 0; }
int gm_get_reg(int i)            { return static_cast<int32_t>(gm.regs[i & 31]); }
int gm_reg_tainted(int i)        { return gm.tainted(i & 31); }
int gm_get_dmem(int w)           { return static_cast<int32_t>(gm.dmem[w & (DMEM_DEPTH - 1)]); }
int gm_dmem_tainted(int w)       { return gm.dmem_t[w & (DMEM_DEPTH - 1)]; }
int gm_get_ext(int w)            { return static_cast<int32_t>(gm.ext[w & (IMC_WORDS - 1)]); }
int gm_ext_tainted(int w)        { return gm.ext_t[w & (IMC_WORDS - 1)]; }
int gm_get_pc(void)              { return static_cast<int32_t>(gm.pc); }
int gm_get_halt_pc(void)         { return static_cast<int32_t>(gm.halt_pc); }
int gm_is_halted(void)           { return gm.halted; }
int gm_is_diverged(void)         { return gm.diverged; }
int gm_get_instr_count(void)     { return static_cast<int32_t>(gm.instr_count); }
int gm_get_mepc(void)            { return static_cast<int32_t>(gm.mepc); }
int gm_get_mcause(void)          { return static_cast<int32_t>(gm.mcause); }
int gm_get_mtval(void)           { return static_cast<int32_t>(gm.mtval); }
int gm_get_trap_count(void)      { return gm.trap_count; }
int gm_get_misalign_count(void)  { return gm.misalign_count; }
int gm_get_oor_count(void)       { return gm.oor_count; }
int gm_get_target_fault_count(void) { return gm.target_fault_count; }
int gm_get_steps(void)           { return static_cast<int>(gm.steps); }
}

// =============================================================================
// Standalone self-test. Programs are the same ones the UVM sequences send, and
// every expected number was worked out by hand from the RISC-V spec / DUT
// behaviour (and the retired-instruction counts the DUT itself reported), so
// this checks the model independently of the RTL.
// =============================================================================
#ifdef GM_STANDALONE_TEST
#include <cstdio>
namespace {
int fails = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::printf("  FAIL: "); std::printf(__VA_ARGS__); std::printf("\n"); fails++; } } while (0)

uint32_t R(uint32_t op, uint32_t rd, uint32_t f3, uint32_t a, uint32_t b, uint32_t f7) {
    return (f7 << 25) | (b << 20) | (a << 15) | (f3 << 12) | (rd << 7) | op; }
uint32_t I(uint32_t op, uint32_t rd, uint32_t f3, uint32_t a, int32_t imm) {
    return ((static_cast<uint32_t>(imm) & 0xFFF) << 20) | (a << 15) | (f3 << 12) | (rd << 7) | op; }
uint32_t S(uint32_t rs2, uint32_t rs1, int32_t imm) {
    const uint32_t u = static_cast<uint32_t>(imm) & 0xFFF;
    return ((u >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2u << 12) | ((u & 0x1F) << 7) | OPCODE_STORE; }
uint32_t B(uint32_t a, uint32_t b, int32_t imm) {
    const uint32_t u = static_cast<uint32_t>(imm) & 0x1FFF;
    return (((u >> 12) & 1) << 31) | (((u >> 5) & 0x3F) << 25) | (b << 20) | (a << 15) |
           (((u >> 1) & 0xF) << 8) | (((u >> 11) & 1) << 7) | OPCODE_BRANCH; }
uint32_t U(uint32_t rd, uint32_t imm20) { return (imm20 << 12) | (rd << 7) | OPCODE_LUI; }
uint32_t J(uint32_t rd, int32_t imm) {
    const uint32_t u = static_cast<uint32_t>(imm) & 0x1FFFFF;
    return (((u >> 20) & 1) << 31) | (((u >> 1) & 0x3FF) << 21) | (((u >> 11) & 1) << 20) |
           (((u >> 12) & 0xFF) << 12) | (rd << 7) | OPCODE_JAL; }
uint32_t ADDI(uint32_t rd, uint32_t a, int32_t i) { return I(OPCODE_OP_IMM, rd, 0, a, i); }
uint32_t LW(uint32_t rd, uint32_t a, int32_t i)   { return I(OPCODE_LOAD, rd, 2, a, i); }
uint32_t ADD(uint32_t rd, uint32_t a, uint32_t b) { return R(OPCODE_OP, rd, 0, a, b, 0x00); }

int pos;
void begin()               { gm_reset(); pos = 0; }
void emit(uint32_t w)      { gm_load_instr(pos++, static_cast<int>(w)); }
void org(int w)            { pos = w; }
void finish()              { gm_run(5000); }
uint32_t REG(int i)        { return static_cast<uint32_t>(gm_get_reg(i)); }
}  // namespace

int main() {
    // ---- hazard program (cpu_hazard_seq) ----
    begin();
    emit(ADDI(10,0,100)); emit(S(10,0,0)); emit(ADDI(1,0,5)); emit(ADDI(2,1,3)); emit(ADD(3,2,1));
    emit(LW(4,0,0)); emit(ADD(5,4,3)); emit(S(5,0,4)); emit(B(1,1,12)); emit(ADDI(6,0,9)); emit(ADDI(6,0,8));
    emit(ADDI(7,0,7)); emit(U(8,0x12345)); emit(J(9,8)); emit(ADDI(10,0,111)); emit(ADDI(11,0,42));
    emit(ADDI(0,0,99)); emit(INSTR_ECALL);
    finish();
    std::printf("[hazard]\n");
    CHECK(REG(2)==8 && REG(3)==13 && REG(4)==100 && REG(5)==113, "forwarding values");
    CHECK(REG(6)==0 && REG(7)==7 && REG(8)==0x12345000u, "branch skip / LUI");
    CHECK(REG(9)==0x38 && REG(10)==100 && REG(11)==42 && REG(0)==0, "JAL link %x / flushed x10 / x0", REG(9));
    CHECK(gm_get_dmem(1)==113, "mem[1]");
    CHECK(gm_is_halted() && gm_get_halt_pc()==0x44, "halt pc %x", gm_get_halt_pc());
    CHECK(gm_get_instr_count()==14, "instr_count %d (DUT reported 14: BEQ is not counted)", gm_get_instr_count());

    // ---- trap program (cpu_trap_seq) ----
    begin();
    emit(ADDI(20,0,-256)); emit(ADDI(1,0,0x100)); emit(S(1,20,0x10)); emit(ADDI(5,0,0x20));
    emit(ADDI(6,0,0x66)); emit(ADDI(7,0,0x77));
    emit(LW(6,5,2)); emit(ADDI(9,0,0x7AD));
    emit(S(7,5,6));  emit(ADDI(9,0,0x7AD));
    emit(ADDI(8,0,0x402)); emit(ADDI(12,0,0x88)); emit(LW(12,8,0)); emit(ADDI(9,0,0x7AD));
    emit(ADDI(13,0,0x99)); emit(J(13,6)); emit(ADDI(9,0,0x7AD)); emit(INSTR_ECALL);
    org(64);
    emit(ADDI(30,30,1)); emit(LW(26,20,0x18)); emit(LW(27,20,0x1C)); emit(LW(28,20,0x14));
    emit(ADDI(28,28,8)); emit(S(28,20,0x14)); emit(INSTR_MRET);
    finish();
    std::printf("[trap]\n");
    CHECK(gm_get_trap_count()==4 && gm_get_misalign_count()==3 && gm_get_oor_count()==0, "trap counts");
    CHECK(REG(6)==0x66 && REG(12)==0x88 && REG(13)==0x99 && REG(9)==0, "faulting instrs wrote nothing / poison skipped");
    CHECK(REG(30)==4, "handler ran %u times", REG(30));
    CHECK(gm_get_mcause()==0 && gm_get_mepc()==0x44 && gm_get_mtval()==0x42, "last trap = JAL (pc 0x3C), handler then added 8 to MEPC: cause %d mepc %x tval %x", gm_get_mcause(), gm_get_mepc(), gm_get_mtval());
    CHECK(REG(26)==0 && REG(27)==0x42 && REG(28)==0x3C+8, "handler copies x26=%u x27=%x x28=%x", REG(26), REG(27), REG(28));
    CHECK(gm_get_dmem(0)==0 && gm_get_dmem(9)==0, "misaligned SW wrote nothing");
    CHECK(gm_is_halted() && !gm_is_diverged(), "halted");

    // ---- halt programs (cpu_halt_seq): DUT reported retired=3 and 6 ----
    begin(); emit(ADDI(1,0,5)); emit(ADDI(4,0,9)); emit(INSTR_ECALL); emit(ADDI(9,0,0x7AD)); emit(B(0,0,8)); emit(ADDI(10,0,0x7AD)); finish();
    std::printf("[halt A]\n");
    CHECK(gm_is_halted() && gm_get_halt_pc()==8 && gm_get_instr_count()==3 && REG(9)==0 && REG(10)==0, "ECALL halt");
    begin(); emit(ADDI(20,0,-256)); emit(ADDI(1,0,1)); emit(ADDI(5,0,0x400)); emit(S(1,5,0)); emit(ADDI(6,0,0x66));
    emit(S(1,20,0x08)); emit(ADDI(9,0,0x7AD)); emit(S(1,20,0x0C)); finish();
    std::printf("[halt B]\n");
    CHECK(gm_is_halted() && gm_get_halt_pc()==0x14 && gm_get_instr_count()==6, "software halt: pc %x count %d", gm_get_halt_pc(), gm_get_instr_count());
    CHECK(REG(6)==0x66 && REG(9)==0 && gm_get_ext(0x400>>2)==1, "older work committed, younger squashed, ext store landed");

    // ---- mem program A (cpu_mem_seq): DUT reported retired=15 ----
    begin();
    emit(ADDI(1,0,0x11)); emit(ADDI(2,0,0x22)); emit(ADDI(5,0,0x400)); emit(ADDI(6,0,0x500)); emit(U(9,1));
    emit(S(1,5,0)); emit(S(2,6,0)); emit(LW(3,5,0)); emit(LW(4,5,0)); emit(ADD(11,3,4)); emit(LW(7,6,0));
    emit(LW(8,5,0)); emit(LW(10,9,0)); emit(S(10,9,4)); emit(INSTR_ECALL);
    finish();
    std::printf("[mem A]\n");
    CHECK(REG(3)==0x11 && REG(4)==0x11 && REG(11)==0x22 && REG(7)==0x22 && REG(8)==0x11 && REG(10)==0, "external loads");
    CHECK(gm_get_ext(0x400>>2)==0x11 && gm_get_ext(0x500>>2)==0x22 && gm_get_ext(0x1004>>2)==0, "external stores");
    CHECK(gm_get_instr_count()==15 && gm_get_halt_pc()==0x38, "count %d", gm_get_instr_count());

    // ---- mem program B: CSR window and the hole; DUT reported retired=13, x4=5 ----
    begin();
    emit(ADDI(20,0,-256)); emit(ADDI(1,0,0x55)); emit(S(1,20,0x0C)); emit(LW(2,20,0x0C)); emit(LW(3,20,0));
    emit(LW(4,20,4)); emit(S(1,20,0x18)); emit(LW(5,20,0x18)); emit(U(8,0x10)); emit(LW(9,8,0)); emit(S(1,8,0));
    emit(ADDI(10,0,0x7B)); emit(INSTR_ECALL);
    finish();
    std::printf("[mem B]\n");
    CHECK(REG(2)==0x55 && REG(4)==5 && REG(5)==0 && REG(10)==0x7B, "CSR values: x4(INSTR_COUNT)=%u", REG(4));
    CHECK(gm_reg_tainted(3) && gm_reg_tainted(9) && !gm_reg_tainted(2), "CYCLE read and hole load are tainted, others are not");
    CHECK(gm_get_oor_count()==2 && gm_get_instr_count()==13 && gm_get_trap_count()==0, "oor %d count %d", gm_get_oor_count(), gm_get_instr_count());

    // ---- taint propagation / divergence ----
    begin();
    emit(ADDI(20,0,-256)); emit(LW(3,20,0)); emit(ADDI(4,3,1)); emit(ADD(5,4,4)); emit(S(5,0,0)); emit(LW(6,0,0)); emit(INSTR_ECALL);
    finish();
    std::printf("[taint]\n");
    CHECK(gm_reg_tainted(3) && gm_reg_tainted(4) && gm_reg_tainted(5) && gm_reg_tainted(6) && gm_dmem_tainted(0), "taint flows through ALU, store and load");
    CHECK(!gm_is_diverged(), "no divergence yet");
    begin(); emit(ADDI(20,0,-256)); emit(LW(3,20,0)); emit(B(3,0,8)); emit(INSTR_ECALL); finish();
    CHECK(gm_is_diverged(), "branch on a tainted register must set diverged");

    std::printf(fails ? "FAIL (%d)\n" : "PASS\n", fails);
    return fails ? 1 : 0;
}
#endif
