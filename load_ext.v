// ===========================================================================
// Module   : load_ext
// Function : Load data alignment + extension for LB / LH / LW / LBU / LHU.
//            The data memory returns TWO consecutive 32-bit words
//            (rdata_lo = mem[addr>>2], rdata_hi = mem[(addr>>2)+1]). They are
//            concatenated into a 64-bit window and shifted right by
//            8*addr[1:0]; the low byte / halfword / word is then sign- or
//            zero-extended according to funct3. This implements unaligned
//            access with shifting + lane selection, including accesses that
//            cross a 32-bit word boundary.
// Inputs   : rdata_lo[31:0], rdata_hi[31:0]  two adjacent memory words
//            byte_off[1:0]                   addr[1:0]
//            funct3[2:0]                     load width / signedness
// Outputs  : load_data[31:0]                 final value written back to rd
// Timing   : Pure combinational, always @(*) with a default case branch
//            -> no inferred latch.
// Reset    : None (combinational block).
// ===========================================================================
module load_ext (
    input  wire [31:0] rdata_lo,
    input  wire [31:0] rdata_hi,
    input  wire [1:0]  byte_off,
    input  wire [2:0]  funct3,
    output reg  [31:0] load_data
);

wire [63:0] window  = {rdata_hi, rdata_lo};
wire [63:0] shifted = window >> {byte_off, 3'b0};   // shift = 8 * byte_off

wire [31:0] w = shifted[31:0];
wire [15:0] h = shifted[15:0];
wire [7:0]  b = shifted[7:0];

always @(*) begin
    case (funct3)
        3'b000 : load_data = {{24{b[7]}}, b};       // LB  (sign extend)
        3'b001 : load_data = {{16{h[15]}}, h};      // LH  (sign extend)
        3'b010 : load_data = w;                      // LW
        3'b100 : load_data = {24'b0, b};            // LBU (zero extend)
        3'b101 : load_data = {16'b0, h};            // LHU (zero extend)
        default: load_data = w;
    endcase
end

endmodule
