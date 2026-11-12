// ===========================================================================
// Module   : regfile   (instantiated as u_regs inside cpu_top)
// Function : 32 x 32-bit integer register file, 2 combinational read ports,
//            1 synchronous write port. x0 is hardwired to zero.
//            Instance name MUST be u_regs and the array MUST be regs so the
//            existing testbench can probe u_regs.regs[n] hierarchically.
// Inputs   : clk, rst, rs1[4:0], rs2[4:0], rd[4:0], wdata[31:0], we
// Outputs  : rdata1[31:0], rdata2[31:0]
// Timing   : Writes are clocked on posedge clk. Reads are combinational.
//            A write-first read bypass is implemented inside the file:
//            when we=1 and rd==rsX the read port returns wdata in the SAME
//            cycle (cpu_top additionally implements the explicit MEM/WB->ID
//            bypass mux, so the two mechanisms agree).
// Reset    : ASYNCHRONOUS, active high (always @(posedge clk or posedge rst)).
//            rst clears all 32 registers to zero.
// ===========================================================================
module regfile (
    input  wire        clk,
    input  wire        rst,
    input  wire [4:0]  rs1,
    input  wire [4:0]  rs2,
    input  wire [4:0]  rd,
    input  wire [31:0] wdata,
    input  wire        we,
    output reg  [31:0] rdata1,
    output reg  [31:0] rdata2
);

reg [31:0] regs [0:31];          // <-- required array name, do not rename
integer i;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        for (i = 0; i < 32; i = i + 1)
            regs[i] <= 32'd0;
    end else if (we && (rd != 5'd0)) begin
        regs[rd] <= wdata;
    end
end

always @(*) begin
    if      (rs1 == 5'd0)                        rdata1 = 32'd0;
    else if (we && (rd != 5'd0) && (rd == rs1)) rdata1 = wdata;
    else                                         rdata1 = regs[rs1];

    if      (rs2 == 5'd0)                        rdata2 = 32'd0;
    else if (we && (rd != 5'd0) && (rd == rs2)) rdata2 = wdata;
    else                                         rdata2 = regs[rs2];
end

endmodule
