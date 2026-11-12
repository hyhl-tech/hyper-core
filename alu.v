// ===========================================================================
// Module   : alu
// Function : 32-bit integer ALU. ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND and
//            PASSB (b passthrough, used by LUI). Signed comparison and
//            arithmetic shift right are implemented WITHOUT $signed / >>>
//            (MSB-flip trick and ~((~a)>>n)), so the file is strict
//            Verilog-2001 and compiles under plain iverilog.
// Inputs   : a[31:0], b[31:0]  operands (b[4:0] is the shift amount)
//            op[3:0]           ALU function code (see core_defs.vh)
// Outputs  : y[31:0]           result
//            zero              asserted when y == 0
// Timing   : Pure combinational, always @(*) with a default branch in the
//            case statement -> no inferred latch.
// Reset    : None (combinational block).
// ===========================================================================
`include "core_defs.vh"
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output reg  [31:0] y,
    output wire        zero
);

wire [4:0]  shamt = b[4:0];

// Offset-binary view turns a signed "<" into an unsigned "<".
wire [31:0] ax = {~a[31], a[30:0]};
wire [31:0] bx = {~b[31], b[30:0]};

// Arithmetic shift right without $signed: for negative a, ~( (~a) >> n ).
wire [31:0] sra_y = a[31] ? ~((~a) >> shamt) : (a >> shamt);

always @(*) begin
    case (op)
        `ALU_ADD   : y = a + b;
        `ALU_SUB   : y = a - b;
        `ALU_SLL   : y = a << shamt;
        `ALU_SLT   : y = (ax < bx) ? 32'd1 : 32'd0;
        `ALU_SLTU  : y = (a < b)  ? 32'd1 : 32'd0;
        `ALU_XOR   : y = a ^ b;
        `ALU_SRL   : y = a >> shamt;
        `ALU_SRA   : y = sra_y;
        `ALU_OR    : y = a | b;
        `ALU_AND   : y = a & b;
        `ALU_PASSB : y = b;
        default    : y = 32'd0;
    endcase
end

assign zero = (y == 32'd0);

endmodule
