// ===========================================================================
// Module   : imm_gen
// Function : Extract and sign-extend the immediate for the five RISC-V
//            immediate formats I / S / B / U / J. B and J immediates are
//            produced already byte-aligned (bit0 = 0) in 32-bit form, so the
//            EX stage can add them directly to the PC.
// Inputs   : inst[31:0]     full instruction word from IF/ID
//            imm_sel[2:0]   format selector from controller (core_defs.vh)
// Outputs  : imm[31:0]      sign-extended 32-bit immediate
// Timing   : Pure combinational, always @(*), default branch assigns 0
//            -> no inferred latch.
// Reset    : None (combinational block).
// ===========================================================================
`include "core_defs.vh"
module imm_gen (
    input  wire [31:0] inst,
    input  wire [2:0]  imm_sel,
    output reg  [31:0] imm
);

always @(*) begin
    case (imm_sel)
        // I: inst[31:20]
        `IMM_I : imm = {{20{inst[31]}}, inst[31:20]};
        // S: inst[31:25] | inst[11:7]
        `IMM_S : imm = {{20{inst[31]}}, inst[31:25], inst[11:7]};
        // B: imm[12]=inst[31], imm[11]=inst[7], imm[10:5]=inst[30:25],
        //    imm[4:1]=inst[11:8], imm[0]=0
        `IMM_B : imm = {{19{inst[31]}}, inst[31], inst[7],
                        inst[30:25], inst[11:8], 1'b0};
        // U: inst[31:12] | 12'b0
        `IMM_U : imm = {inst[31:12], 12'b0};
        // J: imm[20]=inst[31], imm[19:12]=inst[19:12], imm[11]=inst[20],
        //    imm[10:1]=inst[30:21], imm[0]=0
        `IMM_J : imm = {{11{inst[31]}}, inst[31], inst[19:12],
                        inst[20], inst[30:21], 1'b0};
        default: imm = 32'd0;
    endcase
end

endmodule
