/* =============================================================================
 * golden_model.c
 * DPI-C golden reference model for the RV32I-subset pipelined CPU.
 *
 * This is a plain, non-pipelined architectural model of the DUT's supported
 * RV32I subset. It executes one instruction per gm_step() using fetch -> decode
 * -> execute -> writeback behavior.
 *
 * Purpose:
 *   - The RTL is pipelined.
 *   - This golden model is NOT pipelined.
 *   - The UVM scoreboard compares final architectural state after a program
 *     finishes: registers, data memory, PC, and halt status.
 *
 * Supported RV32I subset:
 *   R-type: ADD, SUB, AND, OR
 *   I-type: ADDI, LW
 *   S-type: SW
 *   B-type: BEQ
 *   U-type: LUI
 *   J-type: JAL
 *   SYSTEM: ECALL used as HALT
 *
 * Addressing model:
 *   - PC is byte-addressed.
 *   - instr_mem[] is word-addressed, so fetch uses pc >> 2.
 *   - data_mem[] is word-addressed.
 *   - LW/SW use byte addresses, converted to word index using addr >> 2.
 *
 * DPI note:
 *   Update cpu_pkg.sv DPI imports to use 32-bit int, not shortint:
 *
 *     import "DPI-C" function void gm_reset();
 *     import "DPI-C" function void gm_load_instr(input int addr, input int instr);
 *     import "DPI-C" function void gm_load_data(input int addr, input int value);
 *     import "DPI-C" function void gm_run(input int max_steps);
 *     import "DPI-C" function int  gm_get_reg(input int idx);
 *     import "DPI-C" function int  gm_get_mem(input int addr);
 *     import "DPI-C" function int  gm_get_pc();
 *     import "DPI-C" function int  gm_is_halted();
 * ========================================================================== */

#include <stdint.h>
#include <string.h>

#define IMEM_DEPTH 256
#define DMEM_DEPTH 256

/* RV32I opcodes */
#define OPCODE_OP      0x33  /* ADD/SUB/AND/OR */
#define OPCODE_OP_IMM  0x13  /* ADDI */
#define OPCODE_LOAD    0x03  /* LW */
#define OPCODE_STORE   0x23  /* SW */
#define OPCODE_BRANCH  0x63  /* BEQ */
#define OPCODE_LUI     0x37  /* LUI */
#define OPCODE_JAL     0x6F  /* JAL */
#define OPCODE_SYSTEM  0x73  /* ECALL */

/* funct3 */
#define F3_ADD_SUB_ADDI 0x0
#define F3_LW_SW        0x2
#define F3_BEQ          0x0
#define F3_OR           0x6
#define F3_AND          0x7

/* funct7 */
#define F7_ADD 0x00
#define F7_SUB 0x20

#define INSTR_ECALL 0x00000073u

typedef struct {
    uint32_t instr_mem[IMEM_DEPTH];
    uint32_t data_mem[DMEM_DEPTH];
    uint32_t regfile[32];
    uint32_t pc;       /* byte-addressed PC */
    int      halted;
} gm_state_t;

static gm_state_t gm;

/* --------------------------------------------------------------------------
 * Sign extension helper.
 * Example:
 *   sext(value, 12) sign-extends a 12-bit immediate to int32_t.
 * -------------------------------------------------------------------------- */
static int32_t sext(uint32_t value, int bits) {
    uint32_t sign_bit = 1u << (bits - 1);
    uint32_t mask     = (bits == 32) ? 0xFFFFFFFFu : ((1u << bits) - 1u);

    value &= mask;

    if (value & sign_bit) {
        value |= ~mask;
    }

    return (int32_t)value;
}

/* --------------------------------------------------------------------------
 * Immediate decode helpers.
 * These follow official RISC-V instruction immediate layouts.
 * -------------------------------------------------------------------------- */
static int32_t imm_i(uint32_t instr) {
    return sext(instr >> 20, 12);
}

static int32_t imm_s(uint32_t instr) {
    uint32_t imm =
        (((instr >> 25) & 0x7F) << 5) |
        ((instr >> 7)  & 0x1F);

    return sext(imm, 12);
}

static int32_t imm_b(uint32_t instr) {
    uint32_t imm =
        (((instr >> 31) & 0x1)  << 12) |
        (((instr >> 7)  & 0x1)  << 11) |
        (((instr >> 25) & 0x3F) << 5)  |
        (((instr >> 8)  & 0xF)  << 1);

    return sext(imm, 13);
}

static int32_t imm_u(uint32_t instr) {
    return (int32_t)(instr & 0xFFFFF000u);
}

static int32_t imm_j(uint32_t instr) {
    uint32_t imm =
        (((instr >> 31) & 0x1)    << 20) |
        (((instr >> 12) & 0xFF)   << 12) |
        (((instr >> 20) & 0x1)    << 11) |
        (((instr >> 21) & 0x3FF)  << 1);

    return sext(imm, 21);
}

/* --------------------------------------------------------------------------
 * DPI functions
 * -------------------------------------------------------------------------- */
void gm_reset(void) {
    memset(&gm, 0, sizeof(gm));
}

/*
 * addr is a WORD index, matching DUT backdoor usage:
 *   dut.instr_mem[addr] = instr;
 */
void gm_load_instr(int addr, int instr) {
    gm.instr_mem[addr & (IMEM_DEPTH - 1)] = (uint32_t)instr;
}

/*
 * addr is a WORD index, matching DUT backdoor usage:
 *   dut.data_mem[addr] = value;
 */
void gm_load_data(int addr, int value) {
    gm.data_mem[addr & (DMEM_DEPTH - 1)] = (uint32_t)value;
}

/* --------------------------------------------------------------------------
 * Execute exactly one architectural instruction.
 * -------------------------------------------------------------------------- */
static void gm_step(void) {
    if (gm.halted) {
        return;
    }

    uint32_t instr = gm.instr_mem[(gm.pc >> 2) & (IMEM_DEPTH - 1)];

    uint32_t opcode = instr & 0x7F;
    uint32_t rd     = (instr >> 7)  & 0x1F;
    uint32_t funct3 = (instr >> 12) & 0x7;
    uint32_t rs1    = (instr >> 15) & 0x1F;
    uint32_t rs2    = (instr >> 20) & 0x1F;
    uint32_t funct7 = (instr >> 25) & 0x7F;

    uint32_t pc_next = gm.pc + 4u;

    switch (opcode) {

        case OPCODE_OP: {
            if (funct3 == F3_ADD_SUB_ADDI && funct7 == F7_ADD) {
                /* ADD */
                if (rd != 0) {
                    gm.regfile[rd] = gm.regfile[rs1] + gm.regfile[rs2];
                }
            } else if (funct3 == F3_ADD_SUB_ADDI && funct7 == F7_SUB) {
                /* SUB */
                if (rd != 0) {
                    gm.regfile[rd] = gm.regfile[rs1] - gm.regfile[rs2];
                }
            } else if (funct3 == F3_AND && funct7 == F7_ADD) {
                /* AND */
                if (rd != 0) {
                    gm.regfile[rd] = gm.regfile[rs1] & gm.regfile[rs2];
                }
            } else if (funct3 == F3_OR && funct7 == F7_ADD) {
                /* OR */
                if (rd != 0) {
                    gm.regfile[rd] = gm.regfile[rs1] | gm.regfile[rs2];
                }
            }
            break;
        }

        case OPCODE_OP_IMM: {
            if (funct3 == F3_ADD_SUB_ADDI) {
                /* ADDI */
                int32_t imm = imm_i(instr);
                if (rd != 0) {
                    gm.regfile[rd] = gm.regfile[rs1] + (uint32_t)imm;
                }
            }
            break;
        }

        case OPCODE_LOAD: {
            if (funct3 == F3_LW_SW) {
                /* LW */
                int32_t imm = imm_i(instr);
                uint32_t byte_addr = gm.regfile[rs1] + (uint32_t)imm;
                uint32_t word_idx  = (byte_addr >> 2) & (DMEM_DEPTH - 1);

                if (rd != 0) {
                    gm.regfile[rd] = gm.data_mem[word_idx];
                }
            }
            break;
        }

        case OPCODE_STORE: {
            if (funct3 == F3_LW_SW) {
                /* SW */
                int32_t imm = imm_s(instr);
                uint32_t byte_addr = gm.regfile[rs1] + (uint32_t)imm;
                uint32_t word_idx  = (byte_addr >> 2) & (DMEM_DEPTH - 1);

                gm.data_mem[word_idx] = gm.regfile[rs2];
            }
            break;
        }

        case OPCODE_BRANCH: {
            if (funct3 == F3_BEQ) {
                /* BEQ */
                int32_t imm = imm_b(instr);

                if (gm.regfile[rs1] == gm.regfile[rs2]) {
                    pc_next = gm.pc + (uint32_t)imm;
                }
            }
            break;
        }

        case OPCODE_LUI: {
            /* LUI */
            int32_t imm = imm_u(instr);

            if (rd != 0) {
                gm.regfile[rd] = (uint32_t)imm;
            }
            break;
        }

        case OPCODE_JAL: {
            /* JAL */
            int32_t imm = imm_j(instr);

            if (rd != 0) {
                gm.regfile[rd] = gm.pc + 4u;
            }

            pc_next = gm.pc + (uint32_t)imm;
            break;
        }

        case OPCODE_SYSTEM: {
            if (instr == INSTR_ECALL) {
                gm.halted = 1;
                pc_next = gm.pc; /* freeze at ECALL, same behavior as DUT */
            }
            break;
        }

        default:
            /* Unsupported instruction behaves as NOP. */
            break;
    }

    gm.pc = pc_next;

    /* RISC-V x0 is hardwired to zero. */
    gm.regfile[0] = 0u;
}

void gm_run(int max_steps) {
    int i;

    for (i = 0; i < max_steps && !gm.halted; i++) {
        gm_step();
    }
}

int gm_get_reg(int idx) {
    return (int32_t)gm.regfile[idx & 0x1F];
}

/*
 * addr is a WORD index, matching DUT data_mem[word_idx].
 * Internal LW/SW execution still uses byte address >> 2.
 */
int gm_get_mem(int addr) {
    return (int32_t)gm.data_mem[addr & (DMEM_DEPTH - 1)];
}

int gm_get_pc(void) {
    return (int32_t)gm.pc;
}

int gm_is_halted(void) {
    return gm.halted;
}

/* --------------------------------------------------------------------------
 * Standalone self-test:
 *
 *   gcc -DGM_STANDALONE_TEST -o gm_test golden_model.c && ./gm_test
 * -------------------------------------------------------------------------- */
#ifdef GM_STANDALONE_TEST
#include <stdio.h>

static uint32_t enc_r(uint32_t opcode,
                      uint32_t rd,
                      uint32_t funct3,
                      uint32_t rs1,
                      uint32_t rs2,
                      uint32_t funct7) {
    return ((funct7 & 0x7F) << 25) |
           ((rs2    & 0x1F) << 20) |
           ((rs1    & 0x1F) << 15) |
           ((funct3 & 0x7)  << 12) |
           ((rd     & 0x1F) << 7)  |
           (opcode  & 0x7F);
}

static uint32_t enc_i(uint32_t opcode,
                      uint32_t rd,
                      uint32_t funct3,
                      uint32_t rs1,
                      int32_t imm) {
    uint32_t imm12 = (uint32_t)imm & 0xFFF;

    return (imm12 << 20) |
           ((rs1    & 0x1F) << 15) |
           ((funct3 & 0x7)  << 12) |
           ((rd     & 0x1F) << 7)  |
           (opcode  & 0x7F);
}

static uint32_t enc_s(uint32_t opcode,
                      uint32_t funct3,
                      uint32_t rs1,
                      uint32_t rs2,
                      int32_t imm) {
    uint32_t imm12 = (uint32_t)imm & 0xFFF;

    return (((imm12 >> 5) & 0x7F) << 25) |
           ((rs2          & 0x1F) << 20) |
           ((rs1          & 0x1F) << 15) |
           ((funct3       & 0x7)  << 12) |
           ((imm12        & 0x1F) << 7)  |
           (opcode        & 0x7F);
}

static uint32_t enc_b(uint32_t opcode,
                      uint32_t funct3,
                      uint32_t rs1,
                      uint32_t rs2,
                      int32_t imm) {
    uint32_t imm13 = (uint32_t)imm & 0x1FFF;

    return (((imm13 >> 12) & 0x1)  << 31) |
           (((imm13 >> 5)  & 0x3F) << 25) |
           ((rs2           & 0x1F) << 20) |
           ((rs1           & 0x1F) << 15) |
           ((funct3        & 0x7)  << 12) |
           (((imm13 >> 1)  & 0xF)  << 8)  |
           (((imm13 >> 11) & 0x1)  << 7)  |
           (opcode         & 0x7F);
}

static uint32_t enc_u(uint32_t opcode,
                      uint32_t rd,
                      uint32_t imm20) {
    return ((imm20 & 0xFFFFF) << 12) |
           ((rd    & 0x1F)   << 7)  |
           (opcode & 0x7F);
}

static uint32_t enc_j(uint32_t opcode,
                      uint32_t rd,
                      int32_t imm) {
    uint32_t imm21 = (uint32_t)imm & 0x1FFFFF;

    return (((imm21 >> 20) & 0x1)   << 31) |
           (((imm21 >> 1)  & 0x3FF) << 21) |
           (((imm21 >> 11) & 0x1)   << 20) |
           (((imm21 >> 12) & 0xFF)  << 12) |
           ((rd            & 0x1F)  << 7)  |
           (opcode         & 0x7F);
}

static void load_hazard_program(void) {
    gm_load_instr(0,  (int)enc_i(OPCODE_OP_IMM, 1,  F3_ADD_SUB_ADDI, 0,  5));    /* ADDI x1, x0, 5 */
    gm_load_instr(1,  (int)enc_i(OPCODE_OP_IMM, 2,  F3_ADD_SUB_ADDI, 1,  3));    /* ADDI x2, x1, 3 */
    gm_load_instr(2,  (int)enc_r(OPCODE_OP,     3,  F3_ADD_SUB_ADDI, 2,  1, F7_ADD)); /* ADD x3,x2,x1 */
    gm_load_instr(3,  (int)enc_i(OPCODE_LOAD,   4,  F3_LW_SW,        0,  0));    /* LW x4, 0(x0) */
    gm_load_instr(4,  (int)enc_r(OPCODE_OP,     5,  F3_ADD_SUB_ADDI, 4,  3, F7_ADD)); /* ADD x5,x4,x3 */
    gm_load_instr(5,  (int)enc_s(OPCODE_STORE,      F3_LW_SW,        0,  5, 4)); /* SW x5, 4(x0) */
    gm_load_instr(6,  (int)enc_b(OPCODE_BRANCH,     F3_BEQ,          1,  1, 12));/* BEQ x1,x1,+12 */
    gm_load_instr(7,  (int)enc_i(OPCODE_OP_IMM, 6,  F3_ADD_SUB_ADDI, 0,  9));    /* flushed */
    gm_load_instr(8,  (int)enc_i(OPCODE_OP_IMM, 6,  F3_ADD_SUB_ADDI, 0,  8));    /* flushed */
    gm_load_instr(9,  (int)enc_i(OPCODE_OP_IMM, 7,  F3_ADD_SUB_ADDI, 0,  7));    /* x7=7 */
    gm_load_instr(10, (int)enc_u(OPCODE_LUI,    8,  0x12345));                  /* x8=0x12345000 */
    gm_load_instr(11, (int)enc_j(OPCODE_JAL,    9,  8));                        /* x9=48, jump +8 */
    gm_load_instr(12, (int)enc_i(OPCODE_OP_IMM, 10, F3_ADD_SUB_ADDI, 0,  111));  /* flushed */
    gm_load_instr(13, (int)enc_i(OPCODE_OP_IMM, 11, F3_ADD_SUB_ADDI, 0,  42));   /* x11=42 */
    gm_load_instr(14, (int)enc_i(OPCODE_OP_IMM, 0,  F3_ADD_SUB_ADDI, 0,  99));   /* x0 stays 0 */
    gm_load_instr(15, (int)INSTR_ECALL);                                        /* halt */

    gm_load_data(0, 100);
}

int main(void) {
    int ok = 1;

    gm_reset();
    load_hazard_program();
    gm_run(1000);

    printf("[directed RV32I test]\n");
    printf("x1=%d x2=%d x3=%d x4=%d x5=%d x6=%d x7=%d\n",
           gm_get_reg(1), gm_get_reg(2), gm_get_reg(3), gm_get_reg(4),
           gm_get_reg(5), gm_get_reg(6), gm_get_reg(7));

    printf("x8=0x%08x x9=%d x10=%d x11=%d x0=%d mem[1]=%d halted=%d pc=0x%08x\n",
           (uint32_t)gm_get_reg(8), gm_get_reg(9), gm_get_reg(10),
           gm_get_reg(11), gm_get_reg(0), gm_get_mem(1),
           gm_is_halted(), (uint32_t)gm_get_pc());

    if (gm_get_reg(1)  != 5)          ok = 0;
    if (gm_get_reg(2)  != 8)          ok = 0;
    if (gm_get_reg(3)  != 13)         ok = 0;
    if (gm_get_reg(4)  != 100)        ok = 0;
    if (gm_get_reg(5)  != 113)        ok = 0;
    if (gm_get_reg(6)  != 0)          ok = 0;
    if (gm_get_reg(7)  != 7)          ok = 0;
    if ((uint32_t)gm_get_reg(8) != 0x12345000u) ok = 0;
    if (gm_get_reg(9)  != 48)         ok = 0;
    if (gm_get_reg(10) != 0)          ok = 0;
    if (gm_get_reg(11) != 42)         ok = 0;
    if (gm_get_reg(0)  != 0)          ok = 0;
    if (gm_get_mem(1)  != 113)        ok = 0;
    if (!gm_is_halted())              ok = 0;
    if ((uint32_t)gm_get_pc() != 0x0000003Cu) ok = 0;

    gm_reset();
    gm_load_instr(0, (int)enc_i(OPCODE_OP_IMM, 1,  F3_ADD_SUB_ADDI, 0, 5));          /* x1=5 */
    gm_load_instr(1, (int)enc_i(OPCODE_OP_IMM, 2,  F3_ADD_SUB_ADDI, 0, 8));          /* x2=8 */
    gm_load_instr(2, (int)enc_r(OPCODE_OP,     12, F3_ADD_SUB_ADDI, 2, 1, F7_SUB));  /* x12=3 */
    gm_load_instr(3, (int)enc_r(OPCODE_OP,     13, F3_AND,          2, 1, F7_ADD));  /* x13=0 */
    gm_load_instr(4, (int)enc_r(OPCODE_OP,     14, F3_OR,           2, 1, F7_ADD));  /* x14=13 */
    gm_load_instr(5, (int)INSTR_ECALL);

    gm_run(1000);

    printf("[R-type test] x12=%d x13=%d x14=%d halted=%d\n",
           gm_get_reg(12), gm_get_reg(13), gm_get_reg(14), gm_is_halted());

    if (gm_get_reg(12) != 3)  ok = 0;
    if (gm_get_reg(13) != 0)  ok = 0;
    if (gm_get_reg(14) != 13) ok = 0;
    if (!gm_is_halted())      ok = 0;

    printf(ok ? "PASS\n" : "FAIL\n");
    return ok ? 0 : 1;
}
#endif