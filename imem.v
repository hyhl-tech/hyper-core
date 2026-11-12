// ===========================================================================
// Module   : imem  (instruction ROM with BUILT-IN FIRMWARE)
// Function : 4 KiB byte-addressable instruction ROM, word indexed, with an
//            asynchronous combinational read so IF sees imem[pc] in the same
//            cycle. Three firmware images live in this file:
//              bank 0 : the required Hyper Core main program
//                       (ALU bypass / store bypass / load-use / JAL / spin)
//              bank 1 : JALR redirect test program
//              bank 2 : full RV32I instruction-coverage program
//              bank 3 : bypass-matrix program (EX/MEM->EX, MEM/WB->EX,
//                       WB->ID same-cycle) at dependency distances 1/2/3
//            `bank` is a plain register that tb_pipeline sets hierarchically;
//            all images are static (filled in initial blocks), no runtime
//            memory writes are needed.
// Inputs   : clk        (accepted for a uniform port list; unused, ROM is
//                        combinational)
//            addr[31:0] byte address = IF stage pc
// Outputs  : rdata[31:0] fetched instruction word
// Timing   : always @(*) combinational read, default case returns NOP
//            -> no inferred latch. No clocked output => IF/ID latches the
//            instruction on the same posedge that advances pc.
// Reset    : None (ROM contents are fixed by the initial blocks).
// ===========================================================================
`include "core_defs.vh"
module imem (
    input  wire        clk,
    input  wire [31:0] addr,
    output reg  [31:0] rdata
);

parameter AW = 10;                       // 2^10 words = 4 KiB address space
localparam WORDS = (1 << AW);

reg [31:0] rom_main [0:WORDS-1];
reg [31:0] rom_jalr [0:WORDS-1];
reg [31:0] rom_isa  [0:WORDS-1];
reg [31:0] rom_byp  [0:WORDS-1];
reg [1:0]  bank;                         // set hierarchically by tb_pipeline

wire [AW-1:0] word_addr = addr[AW+1:2];

// ---------------------------------------------------------------------------
// Instruction assemblers. One definition, used by every firmware image.
// ---------------------------------------------------------------------------
function [31:0] enc_r;
    input [6:0] f7;  input [4:0] rs2; input [4:0] rs1;
    input [2:0] f3;  input [4:0] rd;  input [6:0] op;
    begin enc_r = {f7, rs2, rs1, f3, rd, op}; end
endfunction

function [31:0] enc_i;
    input [11:0] imm; input [4:0] rs1; input [2:0] f3;
    input [4:0] rd;   input [6:0] op;
    begin enc_i = {imm, rs1, f3, rd, op}; end
endfunction

function [31:0] enc_s;
    input [11:0] imm; input [4:0] rs2; input [4:0] rs1;
    input [2:0] f3;   input [6:0] op;
    begin enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op}; end
endfunction

function [31:0] enc_b;
    input [12:0] imm; input [4:0] rs2; input [4:0] rs1;
    input [2:0] f3;   input [6:0] op;
    begin enc_b = {imm[12], imm[10:5], rs2, rs1, f3,
                   imm[4:1], imm[11], op}; end
endfunction

function [31:0] enc_u;
    input [19:0] imm20; input [4:0] rd; input [6:0] op;
    begin enc_u = {imm20, rd, op}; end   // low 12 zero bits are implicit
endfunction

function [31:0] enc_j;
    input [20:0] imm; input [4:0] rd; input [6:0] op;
    begin enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, op}; end
endfunction

integer i;

initial begin
    bank = 2'd0;
    for (i = 0; i < WORDS; i = i + 1) begin
        rom_main[i] = `NOP_INST;
        rom_jalr[i] = `NOP_INST;
        rom_isa[i]  = `NOP_INST;
        rom_byp[i]  = `NOP_INST;
    end

    // =====================================================================
    // BANK 0 : required main program
    // Final architectural state: x1=5 x2=3 x3=8 x4=8 x5=28 x6=8, dmem[0]=8
    // =====================================================================
    rom_main[0] = enc_i(12'd5,  5'd0, 3'b000, 5'd1, `OP_OPIMM); // 00 addi x1,x0,5
    rom_main[1] = enc_i(12'd3,  5'd0, 3'b000, 5'd2, `OP_OPIMM); // 04 addi x2,x0,3
    rom_main[2] = enc_r(7'd0,   5'd2, 5'd1,  3'b000, 5'd3, `OP_OP);     // 08 add x3,x1,x2
    rom_main[3] = enc_s(12'd0,  5'd3, 5'd0,  3'b010, `OP_STORE);        // 0C sw x3,0(x0)
    rom_main[4] = enc_i(12'd0,  5'd0, 3'b010, 5'd4, `OP_LOAD);          // 10 lw x4,0(x0)
    rom_main[5] = enc_r(7'd0,   5'd0, 5'd4,  3'b000, 5'd6, `OP_OP);     // 14 add x6,x4,x0
    rom_main[6] = enc_j(21'd8,  5'd5, `OP_JAL);                          // 18 jal x5,+8
    rom_main[7] = `NOP_INST;                                              // 1C nop (flushed)
    rom_main[8] = enc_b(13'd0,  5'd0, 5'd0,  3'b000, `OP_BRANCH);       // 20 beq x0,x0,0

    // =====================================================================
    // BANK 1 : JALR redirect, including the "& ~1" rule and rs1 forwarding
    //   x8 = 49 (odd) -> jalr target = 48 (0x30), link x9 = 8
    //   0x08 and 0x0C are wrong-path instructions and must never retire.
    // =====================================================================
    rom_jalr[0]  = enc_i(12'd49, 5'd0, 3'b000, 5'd8,  `OP_OPIMM); // 00 addi x8,x0,49
    rom_jalr[1]  = enc_i(12'd0,  5'd8, 3'b000, 5'd9,  `OP_JALR);  // 04 jalr x9,0(x8)
    rom_jalr[2]  = enc_i(12'd111,5'd0, 3'b000, 5'd10, `OP_OPIMM); // 08 wrong-path #1
    rom_jalr[3]  = enc_i(12'd222,5'd0, 3'b000, 5'd11, `OP_OPIMM); // 0C wrong-path #2
    rom_jalr[12] = enc_i(12'd42, 5'd0, 3'b000, 5'd12, `OP_OPIMM); // 30 correct target
    rom_jalr[13] = enc_b(13'd0,  5'd0, 5'd0, 3'b000, `OP_BRANCH); // 34 beq x0,x0,0

    // =====================================================================
    // BANK 2 : full RV32I instruction coverage
    //   R-type x10, I-type x9, U-type x2, loads x5, stores x3,
    //   branches x6 (taken + not taken), JAL, FENCE/ECALL/EBREAK.
    //   Also covers byte/half/word lane shifting, unaligned lanes and a
    //   store/load pair that crosses a 32-bit word boundary.
    // =====================================================================
    rom_isa[0]  = enc_i(12'd7,   5'd0, 3'b000, 5'd1,  `OP_OPIMM); // 000 addi  x1,x0,7
    rom_isa[1]  = enc_i(12'hFFD, 5'd0, 3'b000, 5'd2,  `OP_OPIMM); // 004 addi  x2,x0,-3
    rom_isa[2]  = enc_r(7'd0,   5'd2, 5'd1, 3'b000, 5'd3,  `OP_OP); // 008 add  x3,x1,x2
    rom_isa[3]  = enc_r(7'h20,  5'd2, 5'd1, 3'b000, 5'd4,  `OP_OP); // 00C sub  x4,x1,x2
    rom_isa[4]  = enc_r(7'd0,   5'd1, 5'd1, 3'b001, 5'd5,  `OP_OP); // 010 sll  x5,x1,x1
    rom_isa[5]  = enc_r(7'd0,   5'd1, 5'd2, 3'b010, 5'd6,  `OP_OP); // 014 slt  x6,x2,x1
    rom_isa[6]  = enc_r(7'd0,   5'd1, 5'd2, 3'b011, 5'd7,  `OP_OP); // 018 sltu x7,x2,x1
    rom_isa[7]  = enc_r(7'd0,   5'd2, 5'd1, 3'b100, 5'd8,  `OP_OP); // 01C xor  x8,x1,x2
    rom_isa[8]  = enc_r(7'd0,   5'd1, 5'd2, 3'b101, 5'd9,  `OP_OP); // 020 srl  x9,x2,x1
    rom_isa[9]  = enc_r(7'h20,  5'd1, 5'd2, 3'b101, 5'd10, `OP_OP); // 024 sra  x10,x2,x1
    rom_isa[10] = enc_r(7'd0,   5'd2, 5'd1, 3'b110, 5'd11, `OP_OP); // 028 or   x11,x1,x2
    rom_isa[11] = enc_r(7'd0,   5'd2, 5'd1, 3'b111, 5'd12, `OP_OP); // 02C and  x12,x1,x2
    rom_isa[12] = enc_i(12'd5,   5'd1, 3'b000, 5'd13, `OP_OPIMM); // 030 addi  x13,x1,5
    rom_isa[13] = enc_i(12'd5,   5'd2, 3'b010, 5'd14, `OP_OPIMM); // 034 slti  x14,x2,5
    rom_isa[14] = enc_i(12'd5,   5'd2, 3'b011, 5'd15, `OP_OPIMM); // 038 sltiu x15,x2,5
    rom_isa[15] = enc_i(12'hFFF, 5'd1, 3'b100, 5'd16, `OP_OPIMM); // 03C xori  x16,x1,-1
    rom_isa[16] = enc_i(12'd8,   5'd1, 3'b110, 5'd17, `OP_OPIMM); // 040 ori   x17,x1,8
    rom_isa[17] = enc_i(12'd3,   5'd1, 3'b111, 5'd18, `OP_OPIMM); // 044 andi  x18,x1,3
    rom_isa[18] = enc_i(12'd4,   5'd1, 3'b001, 5'd19, `OP_OPIMM); // 048 slli  x19,x1,4
    rom_isa[19] = enc_i(12'd4,   5'd2, 3'b101, 5'd20, `OP_OPIMM); // 04C srli  x20,x2,4
    rom_isa[20] = enc_i(12'h404, 5'd2, 3'b101, 5'd21, `OP_OPIMM); // 050 srai  x21,x2,4
    rom_isa[21] = enc_u(20'h12345, 5'd22, `OP_LUI);                // 054 lui   x22,0x12345
    rom_isa[22] = enc_u(20'd1,     5'd23, `OP_AUIPC);               // 058 auipc x23,1
    rom_isa[23] = enc_u(20'hABCDE, 5'd24, `OP_LUI);                // 05C lui   x24,0xABCDE
    rom_isa[24] = enc_i(12'd291,  5'd24, 3'b000, 5'd24, `OP_OPIMM); // 060 addi x24,x24,291
    rom_isa[25] = enc_s(12'd0,  5'd24, 5'd0, 3'b010, `OP_STORE);   // 064 sw    x24,0(x0)
    rom_isa[26] = enc_i(12'd1,  5'd0,  3'b000, 5'd25, `OP_LOAD);   // 068 lb    x25,1(x0)
    rom_isa[27] = enc_i(12'd1,  5'd0,  3'b100, 5'd26, `OP_LOAD);   // 06C lbu   x26,1(x0)
    rom_isa[28] = enc_i(12'd2,  5'd0,  3'b001, 5'd27, `OP_LOAD);   // 070 lh    x27,2(x0)
    rom_isa[29] = enc_i(12'd0,  5'd0,  3'b101, 5'd28, `OP_LOAD);   // 074 lhu   x28,0(x0)
    rom_isa[30] = enc_i(12'd0,  5'd0,  3'b010, 5'd29, `OP_LOAD);   // 078 lw    x29,0(x0)
    rom_isa[31] = enc_i(12'd90, 5'd0,  3'b000, 5'd30, `OP_OPIMM); // 07C addi  x30,x0,90
    rom_isa[32] = enc_s(12'd4,  5'd30, 5'd0,  3'b000, `OP_STORE);  // 080 sb    x30,4(x0)
    rom_isa[33] = enc_s(12'd6,  5'd24, 5'd0,  3'b001, `OP_STORE);  // 084 sh    x24,6(x0)
    rom_isa[34] = enc_i(12'd4,  5'd0,  3'b010, 5'd31, `OP_LOAD);   // 088 lw    x31,4(x0)
    rom_isa[35] = enc_s(12'd10, 5'd24, 5'd0,  3'b010, `OP_STORE);  // 08C sw    x24,10(x0)
    rom_isa[36] = enc_i(12'd10, 5'd0,  3'b010, 5'd30, `OP_LOAD);   // 090 lw    x30,10(x0)
    rom_isa[37] = enc_i(12'd0,  5'd0,  3'b000, 5'd30, `OP_OPIMM); // 094 addi  x30,x0,0
    rom_isa[38] = enc_i(12'd0,  5'd0,  3'b000, 5'd31, `OP_OPIMM); // 098 addi  x31,x0,0
    rom_isa[39] = {12'd0, 5'd0, 3'b000, 5'd0, `OP_FENCE};          // 09C fence
    rom_isa[40] = 32'h00000073;                                     // 0A0 ecall
    rom_isa[41] = 32'h00100073;                                     // 0A4 ebreak
    // ---- taken branches: each skips one poison instruction ---------------
    rom_isa[42] = enc_b(13'd8, 5'd0, 5'd0, 3'b000, `OP_BRANCH);    // 0A8 beq  x0,x0,+8
    rom_isa[43] = enc_i(12'd100,5'd31,3'b000,5'd31,`OP_OPIMM);     // 0AC poison (flushed)
    rom_isa[44] = enc_b(13'd8, 5'd1, 5'd0, 3'b001, `OP_BRANCH);    // 0B0 bne  x0,x1,+8
    rom_isa[45] = enc_i(12'd100,5'd31,3'b000,5'd31,`OP_OPIMM);     // 0B4 poison
    rom_isa[46] = enc_b(13'd8, 5'd1, 5'd2, 3'b100, `OP_BRANCH);    // 0B8 blt  x2,x1,+8
    rom_isa[47] = enc_i(12'd100,5'd31,3'b000,5'd31,`OP_OPIMM);     // 0BC poison
    rom_isa[48] = enc_b(13'd8, 5'd2, 5'd1, 3'b101, `OP_BRANCH);    // 0C0 bge  x1,x2,+8
    rom_isa[49] = enc_i(12'd100,5'd31,3'b000,5'd31,`OP_OPIMM);     // 0C4 poison
    rom_isa[50] = enc_b(13'd8, 5'd2, 5'd1, 3'b110, `OP_BRANCH);    // 0C8 bltu x1,x2,+8
    rom_isa[51] = enc_i(12'd100,5'd31,3'b000,5'd31,`OP_OPIMM);     // 0CC poison
    rom_isa[52] = enc_b(13'd8, 5'd1, 5'd2, 3'b111, `OP_BRANCH);    // 0D0 bgeu x2,x1,+8
    rom_isa[53] = enc_i(12'd100,5'd31,3'b000,5'd31,`OP_OPIMM);     // 0D4 poison
    // ---- not-taken branches: each falls through into a marker -------------
    rom_isa[54] = enc_b(13'd8, 5'd1, 5'd0, 3'b000, `OP_BRANCH);    // 0D8 beq  x0,x1,+8
    rom_isa[55] = enc_i(12'd1, 5'd30,3'b000,5'd30,`OP_OPIMM);      // 0DC addi x30,x30,1
    rom_isa[56] = enc_b(13'd8, 5'd0, 5'd0, 3'b001, `OP_BRANCH);    // 0E0 bne  x0,x0,+8
    rom_isa[57] = enc_i(12'd1, 5'd30,3'b000,5'd30,`OP_OPIMM);      // 0E4 addi x30,x30,1
    rom_isa[58] = enc_b(13'd8, 5'd2, 5'd1, 3'b100, `OP_BRANCH);    // 0E8 blt  x1,x2,+8
    rom_isa[59] = enc_i(12'd1, 5'd30,3'b000,5'd30,`OP_OPIMM);      // 0EC addi x30,x30,1
    rom_isa[60] = enc_b(13'd8, 5'd1, 5'd2, 3'b101, `OP_BRANCH);    // 0F0 bge  x2,x1,+8
    rom_isa[61] = enc_i(12'd1, 5'd30,3'b000,5'd30,`OP_OPIMM);      // 0F4 addi x30,x30,1
    rom_isa[62] = enc_b(13'd8, 5'd1, 5'd2, 3'b110, `OP_BRANCH);    // 0F8 bltu x2,x1,+8
    rom_isa[63] = enc_i(12'd1, 5'd30,3'b000,5'd30,`OP_OPIMM);      // 0FC addi x30,x30,1
    rom_isa[64] = enc_b(13'd8, 5'd2, 5'd1, 3'b111, `OP_BRANCH);    // 100 bgeu x1,x2,+8
    rom_isa[65] = enc_i(12'd1, 5'd30,3'b000,5'd30,`OP_OPIMM);      // 104 addi x30,x30,1
    rom_isa[66] = enc_j(21'd8, 5'd0, `OP_JAL);                      // 108 jal  x0,+8
    rom_isa[67] = `NOP_INST;                                         // 10C flushed
    rom_isa[68] = enc_b(13'd0, 5'd0, 5'd0, 3'b000, `OP_BRANCH);    // 110 beq  x0,x0,0

    // =====================================================================
    // BANK 3 : bypass matrix, one dependency distance per case
    //   distance 1 -> EX/MEM -> EX   (rs1)
    //   distance 2 -> MEM/WB -> EX   (rs1)
    //   distance 3 -> WB -> ID same-cycle write-first bypass (rs1),
    //                 because the producer has already left the pipeline
    //                 by the time the consumer reaches EX.
    // =====================================================================
    rom_byp[0] = enc_i(12'd11, 5'd0, 3'b000, 5'd1, `OP_OPIMM); // 00 addi x1,x0,11
    rom_byp[1] = enc_i(12'd0,  5'd1, 3'b000, 5'd2, `OP_OPIMM); // 04 addi x2,x1,0  (d=1)
    rom_byp[2] = enc_i(12'd22, 5'd0, 3'b000, 5'd3, `OP_OPIMM); // 08 addi x3,x0,22
    rom_byp[3] = `NOP_INST;                                      // 0C nop
    rom_byp[4] = enc_i(12'd0,  5'd3, 3'b000, 5'd4, `OP_OPIMM); // 10 addi x4,x3,0  (d=2)
    rom_byp[5] = enc_i(12'd33, 5'd0, 3'b000, 5'd5, `OP_OPIMM); // 14 addi x5,x0,33
    rom_byp[6] = `NOP_INST;                                      // 18 nop
    rom_byp[7] = `NOP_INST;                                      // 1C nop
    rom_byp[8] = enc_i(12'd0,  5'd5, 3'b000, 5'd6, `OP_OPIMM); // 20 addi x6,x5,0  (d=3)
    rom_byp[9] = enc_b(13'd0,  5'd0, 5'd0, 3'b000, `OP_BRANCH);// 24 beq  x0,x0,0
end

always @(*) begin
    case (bank)
        2'd0    : rdata = rom_main[word_addr];
        2'd1    : rdata = rom_jalr[word_addr];
        2'd2    : rdata = rom_isa[word_addr];
        2'd3    : rdata = rom_byp[word_addr];
        default : rdata = `NOP_INST;
    endcase
end

endmodule
