// ===========================================================================
// File       : core_defs.vh   (shared encoding definitions, NOT a module)
// Function   : Single source of truth for opcodes, immediate-format selectors,
//              ALU operation classes, ALU function codes and forwarding codes.
//              Included by every module that needs them so no encoding is
//              copy-pasted between files.
// Syntax     : Verilog-2001 `define / `include. No SystemVerilog constructs.
// Timing     : n/a (compile-time constants). No reset.
// ===========================================================================
`ifndef CORE_DEFS_VH
`define CORE_DEFS_VH

// ---- RV32I opcodes -------------------------------------------------------
`define OP_LUI      7'b0110111
`define OP_AUIPC    7'b0010111
`define OP_JAL      7'b1101111
`define OP_JALR     7'b1100111
`define OP_BRANCH   7'b1100011
`define OP_LOAD     7'b0000011
`define OP_STORE    7'b0100011
`define OP_OPIMM    7'b0010011
`define OP_OP       7'b0110011
`define OP_FENCE    7'b0001111
`define OP_SYSTEM   7'b1110011

// ---- immediate format selector (imm_gen) ---------------------------------
`define IMM_I       3'd0
`define IMM_S       3'd1
`define IMM_B       3'd2
`define IMM_U       3'd3
`define IMM_J       3'd4
`define IMM_X       3'd5

// ---- ALU operation class (controller -> alu_control) ---------------------
`define ALUOP_ADD     3'd0   // address / AUIPC / JAL-link addition
`define ALUOP_ITYPE   3'd1   // OPIMM: funct3 (+funct7[5] for SRAI)
`define ALUOP_RTYPE   3'd2   // OP:    funct3 + funct7[5]
`define ALUOP_BRANCH  3'd3   // branch: ALU computes a-b (comparison is separate)
`define ALUOP_PASSB   3'd4   // LUI: rd = imm

// ---- ALU function codes ---------------------------------------------------
`define ALU_ADD     4'd0
`define ALU_SUB     4'd1
`define ALU_SLL     4'd2
`define ALU_SLT     4'd3
`define ALU_SLTU    4'd4
`define ALU_XOR     4'd5
`define ALU_SRL     4'd6
`define ALU_SRA     4'd7
`define ALU_OR      4'd8
`define ALU_AND     4'd9
`define ALU_PASSB   4'd10

// ---- forwarding mux selectors --------------------------------------------
`define FWD_NONE    2'd0     // ID/EX register operand (already WB->ID bypassed)
`define FWD_MEMWB   2'd1     // older instruction, MEM/WB -> EX
`define FWD_EXMEM   2'd2     // younger instruction, EX/MEM -> EX (higher priority)

`define NOP_INST    32'h00000013   // addi x0,x0,0

`endif
