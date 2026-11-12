// ===========================================================================
// Module   : cpu_top   (Hyper Core, RV32I 5-stage in-order pipeline)
// Function : IF / ID / EX / MEM / WB pipeline. Full bypass network
//            (EX/MEM->EX, MEM/WB->EX, WB->ID), 1-cycle load-use stall,
//            branches + JAL + JALR resolved in EX with a 2-cycle taken
//            penalty, valid bit carried through all five stages, byte / half
//            / word memory access with 4 byte-enable lanes and shift-based
//            unaligned handling, and hierarchical performance counters.
// Inputs  : clk, rst
// Outputs : pc_out[31:0]          = IF stage PC register (the signal `pc`)
//           alu_result_out[31:0]  = EX stage ALU result (combinational)
// Timing  : All pipeline registers are clocked on posedge clk. imem/dmem
//           reads are combinational; dmem writes are clocked. IF/ID latches
//           imem[pc] on the same posedge that advances pc.
// Reset   : ASYNCHRONOUS, active high (always @(posedge clk or posedge rst)).
//           Reset clears pc, all five pipeline valid bits / control fields,
//           the register file, data memory and every performance counter.
// Naming  : Instance u_regs / array regs / IF register pc are fixed by the
//           existing testbench and MUST NOT be renamed.
// ===========================================================================
`include "core_defs.vh"
module cpu_top (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] pc_out,
    output wire [31:0] alu_result_out
);

// ===========================================================================
// 1. IF stage
// ===========================================================================
reg  [31:0] pc;                          // <-- required PC register name
wire [31:0] if_inst;
wire [31:0] pc_plus4 = pc + 32'd4;
assign pc_out = pc;

// ===========================================================================
// 2. IF/ID pipeline register
// ===========================================================================
reg         ifid_valid;
reg  [31:0] ifid_pc;
reg  [31:0] ifid_inst;

// ===========================================================================
// 3. ID stage wires
// ===========================================================================
wire [6:0]  id_opcode   = ifid_inst[6:0];
wire [4:0]  id_rs1      = ifid_inst[19:15];
wire [4:0]  id_rs2      = ifid_inst[24:20];
wire [4:0]  id_rd       = ifid_inst[11:7];
wire [2:0]  id_funct3   = ifid_inst[14:12];
wire        id_funct7_5 = ifid_inst[30];

wire        id_reg_write, id_mem_read, id_mem_write, id_mem_to_reg;
wire        id_alu_src, id_branch, id_jump, id_jalr, id_lui, id_auipc;
wire        id_uses_rs1, id_uses_rs2, id_illegal;
wire [2:0]  id_alu_op, id_imm_sel;
wire [31:0] id_imm;
wire [31:0] id_rf_rdata1, id_rf_rdata2;
wire        id_wbid_hit1, id_wbid_hit2;
wire [31:0] id_rdata1, id_rdata2;

// ===========================================================================
// 4. ID/EX pipeline register
// ===========================================================================
reg         idex_valid;
reg  [31:0] idex_pc;
reg  [31:0] idex_inst;
reg  [31:0] idex_imm;
reg  [31:0] idex_pc_plus4;
reg  [4:0]  idex_rs1, idex_rs2, idex_rd;
reg  [2:0]  idex_funct3;
reg         idex_funct7_5;
reg  [31:0] idex_rdata1, idex_rdata2;
reg         idex_reg_write, idex_mem_read, idex_mem_write, idex_mem_to_reg;
reg         idex_alu_src, idex_branch, idex_jump, idex_jalr;
reg         idex_auipc;
reg  [2:0]  idex_alu_op;
reg         idex_uses_rs1, idex_uses_rs2;

// ===========================================================================
// 5. EX stage wires
// ===========================================================================
reg  [1:0]  fwd_a, fwd_b;                // forwarding mux selectors
wire [31:0] exmem_fwd_data;
wire [31:0] memwb_fwd_data;
wire [31:0] ex_rs1_fwd, ex_rs2_fwd;
wire [31:0] ex_op_a, ex_op_b;
wire [3:0]  ex_alu_ctrl;
wire [31:0] ex_alu_result;
wire        ex_alu_zero;
wire [31:0] ex_store_data;
reg         ex_branch_cond;
wire        ex_taken;
wire [31:0] ex_branch_target;
wire [31:0] ex_jalr_target;
wire [31:0] ex_redirect_pc;
wire        load_stall;
assign alu_result_out = ex_alu_result;

// ===========================================================================
// 6. EX/MEM pipeline register
// ===========================================================================
reg         exmem_valid;
reg  [31:0] exmem_pc;
reg  [31:0] exmem_alu_result;
reg  [31:0] exmem_store_data;
reg  [4:0]  exmem_rd;
reg  [2:0]  exmem_funct3;
reg         exmem_reg_write, exmem_mem_read, exmem_mem_write, exmem_mem_to_reg;

// ===========================================================================
// 7. MEM stage wires
// ===========================================================================
reg  [3:0]  mem_be_lo, mem_be_hi;
reg  [31:0] mem_wdata_lo, mem_wdata_hi;
wire [31:0] mem_rdata_lo, mem_rdata_hi;
wire [31:0] mem_load_data;
wire        mem_we;
wire [1:0]  st_off      = exmem_alu_result[1:0];
wire [63:0] st_shifted  = {32'd0, exmem_store_data} << {st_off, 3'b0};
wire [7:0]  st_lane_base =
              (exmem_funct3[1:0] == 2'b00) ? 8'h01 :   // SB
              (exmem_funct3[1:0] == 2'b01) ? 8'h03 :   // SH
              (exmem_funct3[1:0] == 2'b10) ? 8'h0F :   // SW
                                             8'h00;
wire [7:0]  st_lane_shifted = st_lane_base << st_off;

// ===========================================================================
// 8. MEM/WB pipeline register and WB wires
// ===========================================================================
reg         memwb_valid;
reg  [31:0] memwb_pc;
reg  [31:0] memwb_alu_result;
reg  [31:0] memwb_load_data;
reg  [4:0]  memwb_rd;
reg         memwb_reg_write, memwb_mem_to_reg;
wire [31:0] memwb_wb_data;
wire        memwb_we;

// ===========================================================================
// 9. Performance counters (hierarchically observable: uut.perf_xxx)
//    Level 1: totals.  Level 2: cause / bypass breakdown.  Level 3: last-PC
//    trace registers so a testbench can name the squashed instruction.
// ===========================================================================
reg [31:0] perf_cycles;
reg [31:0] perf_retired;
reg [31:0] perf_stalls;
reg [31:0] perf_flushes;
reg [31:0] perf_stall_load_use;
reg [31:0] perf_flush_branch;
reg [31:0] perf_flush_jal;
reg [31:0] perf_flush_jalr;
reg [31:0] perf_fwd_exmem_a,  perf_fwd_exmem_b;
reg [31:0] perf_fwd_memwb_a,  perf_fwd_memwb_b;
reg [31:0] perf_fwd_wbid_a,   perf_fwd_wbid_b;
reg [31:0] perf_last_flush_pc;
reg [31:0] perf_last_redirect_pc;
reg [31:0] perf_last_stall_pc;

// ===========================================================================
// 10. Module instances
// ===========================================================================
imem u_imem (
    .clk   (clk),
    .addr  (pc),
    .rdata (if_inst)
);

controller u_ctrl (
    .opcode      (id_opcode),
    .o_reg_write (id_reg_write),
    .o_mem_read  (id_mem_read),
    .o_mem_write (id_mem_write),
    .o_mem_to_reg(id_mem_to_reg),
    .o_alu_src   (id_alu_src),
    .o_branch    (id_branch),
    .o_jump      (id_jump),
    .o_jalr      (id_jalr),
    .o_lui       (id_lui),
    .o_auipc     (id_auipc),
    .o_uses_rs1  (id_uses_rs1),
    .o_uses_rs2  (id_uses_rs2),
    .o_alu_op    (id_alu_op),
    .o_imm_sel   (id_imm_sel),
    .o_illegal   (id_illegal)
);

imm_gen u_immgen (
    .inst    (ifid_inst),
    .imm_sel (id_imm_sel),
    .imm     (id_imm)
);

regfile u_regs (
    .clk    (clk),
    .rst    (rst),
    .rs1    (id_rs1),
    .rs2    (id_rs2),
    .rd     (memwb_rd),
    .wdata  (memwb_wb_data),
    .we     (memwb_we),
    .rdata1 (id_rf_rdata1),
    .rdata2 (id_rf_rdata2)
);

alu_control u_aluctrl (
    .alu_op   (idex_alu_op),
    .funct3   (idex_funct3),
    .funct7_5 (idex_funct7_5),
    .alu_ctrl (ex_alu_ctrl)
);

alu u_alu (
    .a    (ex_op_a),
    .b    (ex_op_b),
    .op   (ex_alu_ctrl),
    .y    (ex_alu_result),
    .zero (ex_alu_zero)
);

dmem u_dmem (
    .clk      (clk),
    .rst      (rst),
    .addr     (exmem_alu_result),
    .wdata_lo (mem_wdata_lo),
    .wdata_hi (mem_wdata_hi),
    .be_lo    (mem_be_lo),
    .be_hi    (mem_be_hi),
    .we       (mem_we),
    .rdata_lo (mem_rdata_lo),
    .rdata_hi (mem_rdata_hi)
);

load_ext u_loadext (
    .rdata_lo  (mem_rdata_lo),
    .rdata_hi  (mem_rdata_hi),
    .byte_off  (exmem_alu_result[1:0]),
    .funct3    (exmem_funct3),
    .load_data (mem_load_data)
);

// ===========================================================================
// 11. Combinational logic
// ===========================================================================

// ---- WB mux / write enables ----------------------------------------------
assign memwb_wb_data = memwb_mem_to_reg ? memwb_load_data : memwb_alu_result;
assign memwb_we      = memwb_valid && memwb_reg_write;
assign memwb_fwd_data= memwb_wb_data;
assign exmem_fwd_data= exmem_alu_result;
assign mem_we        = exmem_valid && exmem_mem_write;

// ---- WB -> ID same-cycle write-first bypass ------------------------------
assign id_wbid_hit1 = memwb_we && (memwb_rd != 5'd0) && (memwb_rd == id_rs1);
assign id_wbid_hit2 = memwb_we && (memwb_rd != 5'd0) && (memwb_rd == id_rs2);
assign id_rdata1 = id_wbid_hit1 ? memwb_wb_data : id_rf_rdata1;
assign id_rdata2 = id_wbid_hit2 ? memwb_wb_data : id_rf_rdata2;

// ---- EX/MEM -> EX and MEM/WB -> EX bypass mux selectors ------------------
// Priority is explicit: MEM/WB (older) is assigned first, then EX/MEM
// (younger) overwrites it. A load still in EX/MEM is excluded because its
// data is not available until the end of MEM; the load-use stall guarantees
// such a consumer never reaches EX at that time.
always @(*) begin
    fwd_a = `FWD_NONE;
    fwd_b = `FWD_NONE;

    if (memwb_valid && memwb_reg_write && (memwb_rd != 5'd0) &&
        idex_uses_rs1 && (memwb_rd == idex_rs1))
        fwd_a = `FWD_MEMWB;
    if (memwb_valid && memwb_reg_write && (memwb_rd != 5'd0) &&
        idex_uses_rs2 && (memwb_rd == idex_rs2))
        fwd_b = `FWD_MEMWB;

    if (exmem_valid && exmem_reg_write && (exmem_rd != 5'd0) &&
        !exmem_mem_read && idex_uses_rs1 && (exmem_rd == idex_rs1))
        fwd_a = `FWD_EXMEM;      // younger instruction wins
    if (exmem_valid && exmem_reg_write && (exmem_rd != 5'd0) &&
        !exmem_mem_read && idex_uses_rs2 && (exmem_rd == idex_rs2))
        fwd_b = `FWD_EXMEM;      // younger instruction wins
end

assign ex_rs1_fwd = (fwd_a == `FWD_EXMEM) ? exmem_fwd_data :
                    (fwd_a == `FWD_MEMWB) ? memwb_fwd_data : idex_rdata1;
assign ex_rs2_fwd = (fwd_b == `FWD_EXMEM) ? exmem_fwd_data :
                    (fwd_b == `FWD_MEMWB) ? memwb_fwd_data : idex_rdata2;

// ---- EX operand selection --------------------------------------------------
// AUIPC / JAL / JALR use PC as operand A; JAL / JALR force operand B = 4 so
// the ALU directly produces the link value pc+4. LUI uses ALU_PASSB so the
// U-immediate passes straight to rd.
assign ex_op_a = (idex_auipc || idex_jump) ? idex_pc : ex_rs1_fwd;
assign ex_op_b = idex_jump ? 32'd4 :
                 (idex_alu_src ? idex_imm : ex_rs2_fwd);
assign ex_store_data = ex_rs2_fwd;        // store data also goes through bypass

// ---- branch decision, redirect PC, taken ----------------------------------
assign ex_branch_target = idex_pc + idex_imm;                  // B / JAL
assign ex_jalr_target   = (ex_rs1_fwd + idex_imm) & 32'hFFFF_FFFE;
assign ex_redirect_pc   = idex_jalr ? ex_jalr_target : ex_branch_target;

wire [31:0] cmp_ax = {~ex_rs1_fwd[31], ex_rs1_fwd[30:0]};
wire [31:0] cmp_bx = {~ex_rs2_fwd[31], ex_rs2_fwd[30:0]};
wire cmp_eq  = (ex_rs1_fwd == ex_rs2_fwd);
wire cmp_lts = (cmp_ax < cmp_bx);
wire cmp_ltu = (ex_rs1_fwd < ex_rs2_fwd);

always @(*) begin
    case (idex_funct3)
        3'b000 : ex_branch_cond =  cmp_eq;        // BEQ
        3'b001 : ex_branch_cond = ~cmp_eq;        // BNE
        3'b100 : ex_branch_cond =  cmp_lts;       // BLT  (signed)
        3'b101 : ex_branch_cond = ~cmp_lts;       // BGE  (signed)
        3'b110 : ex_branch_cond =  cmp_ltu;       // BLTU (unsigned)
        3'b111 : ex_branch_cond = ~cmp_ltu;       // BGEU (unsigned)
        default: ex_branch_cond = 1'b0;
    endcase
end

assign ex_taken = idex_valid && (idex_jump || (idex_branch && ex_branch_cond));

// ---- load-use hazard: one cycle stall + ID/EX bubble ----------------------
assign load_stall = idex_valid && idex_mem_read && (idex_rd != 5'd0) &&
                    ifid_valid &&
                    ((id_uses_rs1 && (idex_rd == id_rs1)) ||
                     (id_uses_rs2 && (idex_rd == id_rs2)));

// ---- MEM store alignment: shift into a 64-bit window, split into two words
always @(*) begin
    mem_wdata_lo = 32'd0;
    mem_wdata_hi = 32'd0;
    mem_be_lo    = 4'd0;
    mem_be_hi    = 4'd0;
    if (mem_we) begin
        mem_wdata_lo = st_shifted[31:0];
        mem_wdata_hi = st_shifted[63:32];
        mem_be_lo    = st_lane_shifted[3:0];   // 4 lanes, addressed word
        mem_be_hi    = st_lane_shifted[7:4];   // 4 lanes, next word
    end
end

// ===========================================================================
// 12. Sequential logic (all pipeline registers + counters)
//     Priority: reset > EX redirect/flush > load-use stall > normal advance.
//     EX/MEM and MEM/WB always advance, so a taken JAL still writes its link
//     register and a stalled load still reaches WB.
// ===========================================================================
always @(posedge clk or posedge rst) begin
    if (rst) begin
        // ---- IF / IF_ID ----
        pc          <= 32'd0;
        ifid_valid  <= 1'b0;
        ifid_pc     <= 32'd0;
        ifid_inst   <= `NOP_INST;
        // ---- ID/EX ----
        idex_valid  <= 1'b0;
        idex_pc     <= 32'd0;
        idex_inst   <= `NOP_INST;
        idex_imm    <= 32'd0;
        idex_pc_plus4 <= 32'd0;
        idex_rs1    <= 5'd0;
        idex_rs2    <= 5'd0;
        idex_rd     <= 5'd0;
        idex_funct3 <= 3'd0;
        idex_funct7_5 <= 1'b0;
        idex_rdata1 <= 32'd0;
        idex_rdata2 <= 32'd0;
        idex_reg_write   <= 1'b0;
        idex_mem_read    <= 1'b0;
        idex_mem_write   <= 1'b0;
        idex_mem_to_reg  <= 1'b0;
        idex_alu_src     <= 1'b0;
        idex_branch      <= 1'b0;
        idex_jump        <= 1'b0;
        idex_jalr        <= 1'b0;
        idex_auipc       <= 1'b0;
        idex_alu_op      <= `ALUOP_ADD;
        idex_uses_rs1    <= 1'b0;
        idex_uses_rs2    <= 1'b0;
        // ---- EX/MEM ----
        exmem_valid      <= 1'b0;
        exmem_pc         <= 32'd0;
        exmem_alu_result <= 32'd0;
        exmem_store_data <= 32'd0;
        exmem_rd         <= 5'd0;
        exmem_funct3     <= 3'd0;
        exmem_reg_write  <= 1'b0;
        exmem_mem_read   <= 1'b0;
        exmem_mem_write  <= 1'b0;
        exmem_mem_to_reg <= 1'b0;
        // ---- MEM/WB ----
        memwb_valid      <= 1'b0;
        memwb_pc         <= 32'd0;
        memwb_alu_result <= 32'd0;
        memwb_load_data  <= 32'd0;
        memwb_rd         <= 5'd0;
        memwb_reg_write  <= 1'b0;
        memwb_mem_to_reg <= 1'b0;
        // ---- counters ----
        perf_cycles            <= 32'd0;
        perf_retired           <= 32'd0;
        perf_stalls            <= 32'd0;
        perf_flushes           <= 32'd0;
        perf_stall_load_use    <= 32'd0;
        perf_flush_branch      <= 32'd0;
        perf_flush_jal         <= 32'd0;
        perf_flush_jalr        <= 32'd0;
        perf_fwd_exmem_a       <= 32'd0;
        perf_fwd_exmem_b       <= 32'd0;
        perf_fwd_memwb_a       <= 32'd0;
        perf_fwd_memwb_b       <= 32'd0;
        perf_fwd_wbid_a        <= 32'd0;
        perf_fwd_wbid_b        <= 32'd0;
        perf_last_flush_pc     <= 32'd0;
        perf_last_redirect_pc  <= 32'd0;
        perf_last_stall_pc     <= 32'd0;
    end else begin

        // ---------- IF / IF_ID ----------
        if (ex_taken) begin
            // taken branch/JAL/JALR: squash IF/ID and redirect from EX
            ifid_valid <= 1'b0;
            ifid_inst  <= `NOP_INST;
            ifid_pc    <= 32'd0;
            pc         <= ex_redirect_pc;
        end else if (load_stall) begin
            // hold both PC and IF/ID: the consumer is decoded again next cycle
            pc         <= pc;
            ifid_valid <= ifid_valid;
            ifid_pc    <= ifid_pc;
            ifid_inst  <= ifid_inst;
        end else begin
            pc         <= pc_plus4;
            ifid_valid <= 1'b1;
            ifid_pc    <= pc;
            ifid_inst  <= if_inst;
        end

        // ---------- ID/EX ----------
        if (ex_taken || load_stall) begin
            // bubble: valid=0 and every control field cleared, so no
            // architectural state can be changed by a squashed instruction
            idex_valid <= 1'b0;
            idex_pc    <= 32'd0;
            idex_inst  <= `NOP_INST;
            idex_imm   <= 32'd0;
            idex_pc_plus4 <= 32'd0;
            idex_rs1   <= 5'd0;
            idex_rs2   <= 5'd0;
            idex_rd    <= 5'd0;
            idex_funct3<= 3'd0;
            idex_funct7_5 <= 1'b0;
            idex_rdata1 <= 32'd0;
            idex_rdata2 <= 32'd0;
            idex_reg_write   <= 1'b0;
            idex_mem_read    <= 1'b0;
            idex_mem_write   <= 1'b0;
            idex_mem_to_reg  <= 1'b0;
            idex_alu_src     <= 1'b0;
            idex_branch      <= 1'b0;
            idex_jump        <= 1'b0;
            idex_jalr        <= 1'b0;
            idex_auipc       <= 1'b0;
            idex_alu_op      <= `ALUOP_ADD;
            idex_uses_rs1    <= 1'b0;
            idex_uses_rs2    <= 1'b0;
        end else begin
            idex_valid <= ifid_valid;
            idex_pc    <= ifid_pc;
            idex_inst  <= ifid_inst;
            idex_imm   <= id_imm;
            idex_pc_plus4 <= ifid_pc + 32'd4;
            idex_rs1   <= id_rs1;
            idex_rs2   <= id_rs2;
            idex_rd    <= id_rd;
            idex_funct3<= id_funct3;
            idex_funct7_5 <= id_funct7_5;
            idex_rdata1 <= id_rdata1;
            idex_rdata2 <= id_rdata2;
            idex_reg_write   <= id_reg_write;
            idex_mem_read    <= id_mem_read;
            idex_mem_write   <= id_mem_write;
            idex_mem_to_reg  <= id_mem_to_reg;
            idex_alu_src     <= id_alu_src;
            idex_branch      <= id_branch;
            idex_jump        <= id_jump;
            idex_jalr        <= id_jalr;
            idex_auipc       <= id_auipc;
            idex_alu_op      <= id_alu_op;
            idex_uses_rs1    <= id_uses_rs1;
            idex_uses_rs2    <= id_uses_rs2;
        end

        // ---------- EX/MEM (always advances) ----------
        exmem_valid      <= idex_valid;
        exmem_pc         <= idex_pc;
        exmem_alu_result <= ex_alu_result;
        exmem_store_data <= ex_store_data;
        exmem_rd         <= idex_rd;
        exmem_funct3     <= idex_funct3;
        exmem_reg_write  <= idex_reg_write && idex_valid;
        exmem_mem_read   <= idex_mem_read  && idex_valid;
        exmem_mem_write  <= idex_mem_write && idex_valid;
        exmem_mem_to_reg <= idex_mem_to_reg;

        // ---------- MEM/WB (always advances) ----------
        memwb_valid      <= exmem_valid;
        memwb_pc         <= exmem_pc;
        memwb_alu_result <= exmem_alu_result;
        memwb_load_data  <= mem_load_data;
        memwb_rd         <= exmem_rd;
        memwb_reg_write  <= exmem_reg_write;
        memwb_mem_to_reg <= exmem_mem_to_reg;

        // ---------- performance counters (pre-edge values) ----------
        perf_cycles <= perf_cycles + 32'd1;
        if (memwb_valid)
            perf_retired <= perf_retired + 32'd1;

        if (load_stall) begin
            perf_stall_load_use <= perf_stall_load_use + 32'd1;
            perf_stalls         <= perf_stalls + 32'd1;
            perf_last_stall_pc  <= ifid_pc;
        end
        if (ex_taken) begin
            perf_flushes          <= perf_flushes + 32'd1;
            perf_last_flush_pc    <= ifid_pc;
            perf_last_redirect_pc <= ex_redirect_pc;
            if      (idex_jalr) perf_flush_jalr    <= perf_flush_jalr    + 32'd1;
            else if (idex_jump) perf_flush_jal     <= perf_flush_jal     + 32'd1;
            else                perf_flush_branch  <= perf_flush_branch  + 32'd1;
        end

        if (fwd_a == `FWD_EXMEM)  perf_fwd_exmem_a <= perf_fwd_exmem_a + 32'd1;
        if (fwd_b == `FWD_EXMEM)  perf_fwd_exmem_b <= perf_fwd_exmem_b + 32'd1;
        if (fwd_a == `FWD_MEMWB)  perf_fwd_memwb_a <= perf_fwd_memwb_a + 32'd1;
        if (fwd_b == `FWD_MEMWB)  perf_fwd_memwb_b <= perf_fwd_memwb_b + 32'd1;
        if (id_wbid_hit1)         perf_fwd_wbid_a  <= perf_fwd_wbid_a  + 32'd1;
        if (id_wbid_hit2)         perf_fwd_wbid_b  <= perf_fwd_wbid_b  + 32'd1;
    end
end

endmodule
