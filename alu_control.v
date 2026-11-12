// ===========================================================================
// Module   : alu_control
// Function : Translate the controller's ALU operation class + funct3 +
//            funct7[5] into the 4-bit ALU function code. Handles the R-type
//            ADD/SUB and SRL/SRA split, the I-type SRLI/SRAI split and all
//            remaining funct3 comparisons/logic/shift operations.
// Inputs   : alu_op[2:0]   operation class from controller
//            funct3[2:0]   instruction funct3
//            funct7_5      instruction bit 30 (inst[30])
// Outputs  : alu_ctrl[3:0] ALU function code (see core_defs.vh)
// Timing   : Pure combinational, always @(*). Every case has a default and
//            the outer case has a default -> no inferred latch.
// Reset    : None (combinational block).
// ===========================================================================
`include "core_defs.vh"
module alu_control (
    input  wire [2:0] alu_op,
    input  wire [2:0] funct3,
    input  wire       funct7_5,
    output reg  [3:0] alu_ctrl
);

always @(*) begin
    case (alu_op)
        `ALUOP_ADD    : alu_ctrl = `ALU_ADD;      // address / AUIPC / JAL link
        `ALUOP_PASSB  : alu_ctrl = `ALU_PASSB;    // LUI
        `ALUOP_BRANCH : alu_ctrl = `ALU_SUB;      // a-b feeds zero flag
        `ALUOP_ITYPE  : begin
            case (funct3)
                3'b000 : alu_ctrl = `ALU_ADD;     // ADDI
                3'b010 : alu_ctrl = `ALU_SLT;     // SLTI
                3'b011 : alu_ctrl = `ALU_SLTU;    // SLTIU
                3'b100 : alu_ctrl = `ALU_XOR;     // XORI
                3'b110 : alu_ctrl = `ALU_OR;      // ORI
                3'b111 : alu_ctrl = `ALU_AND;     // ANDI
                3'b001 : alu_ctrl = `ALU_SLL;     // SLLI
                3'b101 : alu_ctrl = funct7_5 ? `ALU_SRA : `ALU_SRL; // SRAI/SRLI
                default: alu_ctrl = `ALU_ADD;
            endcase
        end
        `ALUOP_RTYPE  : begin
            case (funct3)
                3'b000 : alu_ctrl = funct7_5 ? `ALU_SUB : `ALU_ADD;  // SUB/ADD
                3'b001 : alu_ctrl = `ALU_SLL;
                3'b010 : alu_ctrl = `ALU_SLT;
                3'b011 : alu_ctrl = `ALU_SLTU;
                3'b100 : alu_ctrl = `ALU_XOR;
                3'b101 : alu_ctrl = funct7_5 ? `ALU_SRA : `ALU_SRL;  // SRA/SRL
                3'b110 : alu_ctrl = `ALU_OR;
                3'b111 : alu_ctrl = `ALU_AND;
                default: alu_ctrl = `ALU_ADD;
            endcase
        end
        default       : alu_ctrl = `ALU_ADD;
    endcase
end

endmodule
