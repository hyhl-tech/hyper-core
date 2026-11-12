// ===========================================================================
// Module   : controller  (ID-stage main decoder)
// Function : Decode the 7-bit opcode into the control bundle consumed by the
//            IF/ID/EX/MEM/WB pipeline. Covers LUI, AUIPC, JAL, JALR, all six
//            branches, all five loads, all three stores, all nine I-type
//            arithmetic/shift ops and all ten R-type ops. FENCE / ECALL /
//            EBREAK decode as legal do-nothing instructions (no state change).
//            o_uses_rs1 / o_uses_rs2 make the load-use hazard check precise,
//            so immediate bits can never be mistaken for a source register.
// Inputs   : opcode[6:0]  = ifid_inst[6:0]
// Outputs  : o_reg_write, o_mem_read, o_mem_write, o_mem_to_reg, o_alu_src,
//            o_branch, o_jump, o_jalr, o_lui, o_auipc,
//            o_uses_rs1, o_uses_rs2, o_alu_op[2:0], o_imm_sel[2:0],
//            o_illegal (decoded but not acted upon: no exception unit)
// Timing   : Pure combinational, always @(*). A full default assignment at
//            the top of the block guarantees every output on every path
//            -> no inferred latch.
// Reset    : None (combinational block).
// ===========================================================================
`include "core_defs.vh"
module controller (
    input  wire [6:0] opcode,
    output reg        o_reg_write,
    output reg        o_mem_read,
    output reg        o_mem_write,
    output reg        o_mem_to_reg,
    output reg        o_alu_src,
    output reg        o_branch,
    output reg        o_jump,
    output reg        o_jalr,
    output reg        o_lui,
    output reg        o_auipc,
    output reg        o_uses_rs1,
    output reg        o_uses_rs2,
    output reg  [2:0] o_alu_op,
    output reg  [2:0] o_imm_sel,
    output reg        o_illegal
);

always @(*) begin
    // ---- default: a legal, side-effect-free instruction -------------------
    o_reg_write = 1'b0;
    o_mem_read  = 1'b0;
    o_mem_write = 1'b0;
    o_mem_to_reg= 1'b0;
    o_alu_src   = 1'b0;
    o_branch    = 1'b0;
    o_jump      = 1'b0;
    o_jalr      = 1'b0;
    o_lui       = 1'b0;
    o_auipc     = 1'b0;
    o_uses_rs1  = 1'b0;
    o_uses_rs2  = 1'b0;
    o_alu_op    = `ALUOP_ADD;
    o_imm_sel   = `IMM_X;
    o_illegal   = 1'b0;

    case (opcode)
        `OP_LUI : begin                       // rd = imm << 12
            o_reg_write = 1'b1;
            o_lui       = 1'b1;
            o_alu_src   = 1'b1;
            o_alu_op    = `ALUOP_PASSB;
            o_imm_sel   = `IMM_U;
        end
        `OP_AUIPC : begin                     // rd = pc + (imm << 12)
            o_reg_write = 1'b1;
            o_auipc     = 1'b1;
            o_alu_src   = 1'b1;
            o_alu_op    = `ALUOP_ADD;
            o_imm_sel   = `IMM_U;
        end
        `OP_JAL : begin                       // rd = pc+4, pc = pc + imm
            o_reg_write = 1'b1;
            o_jump      = 1'b1;
            o_alu_src   = 1'b1;
            o_alu_op    = `ALUOP_ADD;
            o_imm_sel   = `IMM_J;
        end
        `OP_JALR : begin                      // rd = pc+4, pc = (rs1+imm)&~1
            o_reg_write = 1'b1;
            o_jump      = 1'b1;
            o_jalr      = 1'b1;
            o_uses_rs1  = 1'b1;
            o_alu_op    = `ALUOP_ADD;
            o_imm_sel   = `IMM_I;
        end
        `OP_BRANCH : begin                    // BEQ/BNE/BLT/BGE/BLTU/BGEU
            o_branch    = 1'b1;
            o_uses_rs1  = 1'b1;
            o_uses_rs2  = 1'b1;
            o_alu_op    = `ALUOP_BRANCH;
            o_imm_sel   = `IMM_B;
        end
        `OP_LOAD : begin                      // LB/LH/LW/LBU/LHU
            o_reg_write = 1'b1;
            o_mem_read  = 1'b1;
            o_mem_to_reg= 1'b1;
            o_alu_src   = 1'b1;
            o_uses_rs1  = 1'b1;
            o_alu_op    = `ALUOP_ADD;
            o_imm_sel   = `IMM_I;
        end
        `OP_STORE : begin                     // SB/SH/SW
            o_mem_write = 1'b1;
            o_alu_src   = 1'b1;
            o_uses_rs1  = 1'b1;
            o_uses_rs2  = 1'b1;
            o_alu_op    = `ALUOP_ADD;
            o_imm_sel   = `IMM_S;
        end
        `OP_OPIMM : begin                     // ADDI..ANDI / SLLI/SRLI/SRAI
            o_reg_write = 1'b1;
            o_alu_src   = 1'b1;
            o_uses_rs1  = 1'b1;
            o_alu_op    = `ALUOP_ITYPE;
            o_imm_sel   = `IMM_I;
        end
        `OP_OP : begin                        // ADD..AND (R-type)
            o_reg_write = 1'b1;
            o_uses_rs1  = 1'b1;
            o_uses_rs2  = 1'b1;
            o_alu_op    = `ALUOP_RTYPE;
            o_imm_sel   = `IMM_X;
        end
        `OP_FENCE  : begin end                // FENCE: legal NOP here
        `OP_SYSTEM : begin end                // ECALL/EBREAK: legal NOP here
        default    : begin
            o_illegal = 1'b1;                // no exception unit in this core
        end
    endcase
end

endmodule
