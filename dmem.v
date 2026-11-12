// ===========================================================================
// Module   : dmem  (byte-enabled data memory)
// Function : 4 KiB word-organised data RAM. Reads are combinational and return
//            TWO adjacent words (rdata_lo = mem[addr>>2], rdata_hi =
//            mem[(addr>>2)+1]) so load_ext can build a 64-bit window and
//            handle unaligned / cross-word loads by shifting.
//            Writes use 4 byte-enable lanes for the addressed word (be_lo)
//            plus 4 more lanes for the next word (be_hi), which is what makes
//            a store that straddles a 32-bit boundary possible in one cycle.
//            Per-byte read-modify-write uses a temporary word, because
//            Verilog-2001 does not allow a part-select of a memory element on
//            the left-hand side.
// Inputs   : clk, rst, addr[31:0], wdata_lo/hi[31:0], be_lo/hi[3:0], we
// Outputs  : rdata_lo[31:0], rdata_hi[31:0]
// Timing   : Combinational read (continuous assignment); single-cycle write
//            on posedge clk. A load in MEM therefore observes a store that
//            retired on the immediately preceding edge.
// Reset    : ASYNCHRONOUS, active high (always @(posedge clk or posedge rst)).
//            rst clears all words to zero.
// ===========================================================================
module dmem (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] addr,
    input  wire [31:0] wdata_lo,
    input  wire [31:0] wdata_hi,
    input  wire [3:0]  be_lo,
    input  wire [3:0]  be_hi,
    input  wire        we,
    output wire [31:0] rdata_lo,
    output wire [31:0] rdata_hi
);

parameter AW = 10;                       // 2^10 words = 4 KiB byte space
localparam WORDS = (1 << AW);

reg [31:0] mem [0:WORDS-1];

wire [AW-1:0] widx    = addr[AW+1:2];
wire [AW-1:0] widx_hi = widx + 1'b1;     // wraps at the top of the address space

assign rdata_lo = mem[widx];
assign rdata_hi = mem[widx_hi];

reg [31:0] cur_lo;
reg [31:0] cur_hi;
integer i;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] <= 32'd0;
    end else if (we) begin
        // ---- low word: 4 byte-enable lanes -------------------------------
        cur_lo = mem[widx];
        if (be_lo[0]) cur_lo[7:0]   = wdata_lo[7:0];
        if (be_lo[1]) cur_lo[15:8]  = wdata_lo[15:8];
        if (be_lo[2]) cur_lo[23:16] = wdata_lo[23:16];
        if (be_lo[3]) cur_lo[31:24] = wdata_lo[31:24];
        mem[widx] <= cur_lo;
        // ---- high word: only touched by a cross-word store ---------------
        if ((be_hi != 4'b0) && (widx != {AW{1'b1}})) begin
            cur_hi = mem[widx_hi];
            if (be_hi[0]) cur_hi[7:0]   = wdata_hi[7:0];
            if (be_hi[1]) cur_hi[15:8]  = wdata_hi[15:8];
            if (be_hi[2]) cur_hi[23:16] = wdata_hi[23:16];
            if (be_hi[3]) cur_hi[31:24] = wdata_hi[31:24];
            mem[widx_hi] <= cur_hi;
        end
    end
end

endmodule
