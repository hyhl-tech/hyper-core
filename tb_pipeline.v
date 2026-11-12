// ===========================================================================
// Testbench : tb_pipeline
// Function  : Hazard-oriented verification, three phases selected by
//             uut.u_imem.bank. All three run on the REAL RTL.
//               PHASE A (bank 0) : load-use stall, JAL flush, branch flush,
//                                  store-data bypass, x5/x6, dmem[0].
//               PHASE B (bank 1) : JALR redirect (rs1 forwarding + "& ~1"),
//                                  link value, two wrong-path instructions
//                                  must never commit.
//               PHASE C (bank 2) : all remaining RV32I instructions, all
//                                  load/store widths, unaligned lanes,
//                                  cross-word store/load, all six branches
//                                  taken and not taken, FENCE/ECALL/EBREAK.
//               PHASE D (bank 3) : dependency distances 1/2/3 proving
//                                  EX/MEM->EX, MEM/WB->EX and the WB->ID
//                                  same-cycle write-first bypass.
//             Every stall / flush event is printed with its cycle number, the
//             squashed instruction PC and the redirect PC.
// Timeout   : separate initial block aborts with FAIL after 200000 ns.
// Reset     : active high, two clock periods before every phase.
// ===========================================================================
`timescale 1ns/1ps
module tb_pipeline;

reg         clk;
reg         rst;
wire [31:0] pc_out;
wire [31:0] alu_result_out;

cpu_top uut (
    .clk            (clk),
    .rst            (rst),
    .pc_out         (pc_out),
    .alu_result_out (alu_result_out)
);

initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
end

integer errors;
integer cyc;
integer n_stall, n_flush, n_jal_flush, n_jalr_flush, n_branch_flush;
reg [31:0] jal_flush_pc,  jal_redirect_pc;
reg [31:0] jalr_flush_pc, jalr_redirect_pc;
reg [31:0] stall_consumer_pc, stall_load_pc;
reg [31:0] cap_xlw, cap_x31;
reg        mon_en;
reg [8*8:1] kind;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
task reset_stats;
    begin
        cyc = 0;
        n_stall = 0;  n_flush = 0;
        n_jal_flush = 0; n_jalr_flush = 0; n_branch_flush = 0;
        jal_flush_pc      = 32'hFFFFFFFF;
        jal_redirect_pc   = 32'hFFFFFFFF;
        jalr_flush_pc     = 32'hFFFFFFFF;
        jalr_redirect_pc  = 32'hFFFFFFFF;
        stall_consumer_pc = 32'hFFFFFFFF;
        stall_load_pc     = 32'hFFFFFFFF;
        cap_xlw = 32'hFFFFFFFF;
        cap_x31 = 32'hFFFFFFFF;
        kind = "        ";
    end
endtask

task run_cycles;
    input [31:0] n;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1) @(negedge clk);
    end
endtask

task chk32;
    input [31:0]      got;
    input [31:0]      exp;
    input [8*72:1]    msg;
    begin
        if (got !== exp) begin
            $display("  FAIL %s : got=%0d (0x%08h), expected=%0d (0x%08h)",
                     msg, got, got, exp, exp);
            errors = errors + 1;
        end
    end
endtask

task chk_min;
    input [31:0]      got;
    input [31:0]      minv;
    input [8*72:1]    msg;
    begin
        if (got < minv) begin
            $display("  FAIL %s : got=%0d, expected >= %0d", msg, got, minv);
            errors = errors + 1;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Cycle-accurate hazard monitor.
// This always block samples PRE-EDGE combinational values (the pipeline
// registers are updated with nonblocking assignments), so "cyc N FLUSH"
// refers to the state that caused that clock edge.
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst && mon_en) begin
        cyc = cyc + 1;

        if (uut.load_stall) begin
            n_stall = n_stall + 1;
            stall_consumer_pc = uut.ifid_pc;
            stall_load_pc     = uut.idex_pc;
            $display("[cyc %3d] LOAD-USE STALL : held IF/ID pc=%08h (consumer) | load pc=%08h",
                     cyc, uut.ifid_pc, uut.idex_pc);
        end

        if (uut.ex_taken) begin
            n_flush = n_flush + 1;
            if (uut.idex_jalr) begin
                kind = "JALR    ";
                n_jalr_flush = n_jalr_flush + 1;
                if (n_jalr_flush == 1) begin
                    jalr_flush_pc    = uut.ifid_pc;
                    jalr_redirect_pc = uut.ex_redirect_pc;
                end
            end else if (uut.idex_jump) begin
                kind = "JAL     ";
                n_jal_flush = n_jal_flush + 1;
                if (n_jal_flush == 1) begin
                    jal_flush_pc    = uut.ifid_pc;
                    jal_redirect_pc = uut.ex_redirect_pc;
                end
            end else begin
                kind = "BRANCH  ";
                n_branch_flush = n_branch_flush + 1;
            end
            $display("[cyc %3d] %s FLUSH : squashed IF/ID pc=%08h | IF pc=%08h | redirect pc=%08h",
                     cyc, kind, uut.ifid_pc, uut.pc, uut.ex_redirect_pc);
        end

        // architectural commit observations used by PHASE C
        if (uut.memwb_valid && (uut.memwb_pc == 32'h00000088))
            cap_x31 = uut.memwb_wb_data;          // lw x31,4(x0)
        if (uut.memwb_valid && (uut.memwb_pc == 32'h00000090))
            cap_xlw = uut.memwb_wb_data;          // lw x30,10(x0)
    end
end

// ---------------------------------------------------------------------------
// main stimulus
// ---------------------------------------------------------------------------
initial begin
    errors = 0;
    mon_en = 0;
    rst    = 1'b1;
    reset_stats();

    // ======================= PHASE A : bank 0 ============================
    $display("=== PHASE A : main firmware (load-use / JAL / branch flush) ===");
    repeat (2) @(negedge clk);
    rst = 1'b0;
    mon_en = 1'b1;
    run_cycles(30);
    mon_en = 1'b0;
    $display("--- PHASE A counters: stalls=%0d flushes=%0d (jal=%0d jalr=%0d branch=%0d)",
             n_stall, n_flush, n_jal_flush, n_jalr_flush, n_branch_flush);
    $display("--- PHASE A perf: cycles=%0d retired=%0d stalls=%0d flushes=%0d",
             uut.perf_cycles, uut.perf_retired, uut.perf_stalls, uut.perf_flushes);
    $display("--- PHASE A bypass: EXMEM(a=%0d,b=%0d) MEMWB(a=%0d,b=%0d) WB_ID(a=%0d,b=%0d)",
             uut.perf_fwd_exmem_a, uut.perf_fwd_exmem_b,
             uut.perf_fwd_memwb_a, uut.perf_fwd_memwb_b,
             uut.perf_fwd_wbid_a, uut.perf_fwd_wbid_b);

    chk32(n_stall, 32'd1, "A: exactly one load-use stall");
    chk32(stall_consumer_pc, 32'h00000014, "A: stalled consumer PC = 0x14");
    chk32(stall_load_pc,     32'h00000010, "A: load PC = 0x10");
    chk32(uut.perf_stall_load_use, 32'd1, "A: perf_stall_load_use = 1");
    chk32(n_jal_flush,      32'd1, "A: exactly one JAL flush");
    chk32(jal_flush_pc,     32'h0000001C, "A: flushed wrong-path PC = 0x1C");
    chk32(jal_redirect_pc,  32'h00000020, "A: JAL redirect PC = 0x20");
    chk_min(n_branch_flush, 32'd1, "A: at least one branch flush (spin beq)");
    // In the main program EX/MEM->EX feeds rs2 (x2 for `add x3`, x3 store
    // data) while MEM/WB->EX feeds rs1 (x1 for `add x3`, x4 after the stall).
    chk_min(uut.perf_fwd_exmem_a + uut.perf_fwd_exmem_b, 32'd1,
            "A: EX/MEM->EX bypass used");
    chk_min(uut.perf_fwd_exmem_b, 32'd1, "A: store data bypass used");
    chk_min(uut.perf_fwd_memwb_a + uut.perf_fwd_memwb_b, 32'd1,
            "A: MEM/WB->EX bypass used");
    chk32(uut.u_regs.regs[1], 32'd5,  "A: x1");
    chk32(uut.u_regs.regs[2], 32'd3,  "A: x2");
    chk32(uut.u_regs.regs[3], 32'd8,  "A: x3 (dual bypass)");
    chk32(uut.u_regs.regs[4], 32'd8,  "A: x4 (load)");
    chk32(uut.u_regs.regs[5], 32'd28, "A: x5 (JAL link)");
    chk32(uut.u_regs.regs[6], 32'd8,  "A: x6 (after stall)");
    chk32(uut.u_dmem.mem[0], 32'd8,  "A: dmem[0]");

    // ======================= PHASE B : bank 1 ============================
    $display("=== PHASE B : JALR redirect / link / wrong-path ===");
    uut.u_imem.bank = 2'd1;
    rst = 1'b1;
    reset_stats();
    repeat (2) @(negedge clk);
    rst = 1'b0;
    mon_en = 1'b1;
    run_cycles(30);
    mon_en = 1'b0;
    $display("--- PHASE B counters: stalls=%0d flushes=%0d (jalr=%0d branch=%0d)",
             n_stall, n_flush, n_jalr_flush, n_branch_flush);

    chk32(n_stall,           32'd0, "B: no load-use stall");
    chk32(n_jalr_flush,      32'd1, "B: exactly one JALR flush");
    chk32(jalr_flush_pc,     32'h00000008, "B: flushed wrong-path PC = 0x08");
    chk32(jalr_redirect_pc,  32'h00000030, "B: JALR redirect = 0x30 (49 & ~1)");
    chk32(uut.u_regs.regs[9],  32'd8,  "B: JALR link x9 = 8");
    chk32(uut.u_regs.regs[12], 32'd42, "B: correct-target addi executed");
    chk32(uut.u_regs.regs[10], 32'd0,  "B: wrong-path x10 never committed");
    chk32(uut.u_regs.regs[11], 32'd0,  "B: wrong-path x11 never committed");
    chk32(uut.perf_flush_jalr, 32'd1, "B: perf_flush_jalr = 1");

    // ======================= PHASE C : bank 2 ============================
    $display("=== PHASE C : full RV32I instruction / memory / branch coverage ===");
    uut.u_imem.bank = 2'd2;
    rst = 1'b1;
    reset_stats();
    repeat (2) @(negedge clk);
    rst = 1'b0;
    mon_en = 1'b1;
    run_cycles(140);
    mon_en = 1'b0;
    $display("--- PHASE C counters: stalls=%0d flushes=%0d (jal=%0d branch=%0d)",
             n_stall, n_flush, n_jal_flush, n_branch_flush);
    $display("--- PHASE C perf: cycles=%0d retired=%0d",
             uut.perf_cycles, uut.perf_retired);

    chk32(n_stall, 32'd0, "C: no spurious load-use stall");
    chk_min(n_flush, 32'd7, "C: taken branches + JAL all flushed");

    // R-type
    chk32(uut.u_regs.regs[1],  32'h00000007, "C: ADDI x1");
    chk32(uut.u_regs.regs[2],  32'hFFFFFFFD, "C: ADDI x2 (-3)");
    chk32(uut.u_regs.regs[3],  32'h00000004, "C: ADD");
    chk32(uut.u_regs.regs[4],  32'h0000000A, "C: SUB");
    chk32(uut.u_regs.regs[5],  32'h00000380, "C: SLL");
    chk32(uut.u_regs.regs[6],  32'h00000001, "C: SLT (signed)");
    chk32(uut.u_regs.regs[7],  32'h00000000, "C: SLTU");
    chk32(uut.u_regs.regs[8],  32'hFFFFFFFA, "C: XOR");
    chk32(uut.u_regs.regs[9],  32'h01FFFFFF, "C: SRL");
    chk32(uut.u_regs.regs[10], 32'hFFFFFFFF, "C: SRA");
    chk32(uut.u_regs.regs[11], 32'hFFFFFFFF, "C: OR");
    chk32(uut.u_regs.regs[12], 32'h00000005, "C: AND");
    // I-type arithmetic / shifts
    chk32(uut.u_regs.regs[13], 32'h0000000C, "C: ADDI");
    chk32(uut.u_regs.regs[14], 32'h00000001, "C: SLTI");
    chk32(uut.u_regs.regs[15], 32'h00000000, "C: SLTIU");
    chk32(uut.u_regs.regs[16], 32'hFFFFFFF8, "C: XORI");
    chk32(uut.u_regs.regs[17], 32'h0000000F, "C: ORI");
    chk32(uut.u_regs.regs[18], 32'h00000003, "C: ANDI");
    chk32(uut.u_regs.regs[19], 32'h00000070, "C: SLLI");
    chk32(uut.u_regs.regs[20], 32'h0FFFFFFF, "C: SRLI");
    chk32(uut.u_regs.regs[21], 32'hFFFFFFFF, "C: SRAI");
    // U-type
    chk32(uut.u_regs.regs[22], 32'h12345000, "C: LUI");
    chk32(uut.u_regs.regs[23], 32'h00001058, "C: AUIPC");
    // loads (byte / half / word, signed + unsigned, unaligned lanes)
    chk32(uut.u_regs.regs[24], 32'hABCDE123, "C: LUI+ADDI data pattern");
    chk32(uut.u_regs.regs[25], 32'hFFFFFFE1, "C: LB sign extend");
    chk32(uut.u_regs.regs[26], 32'h000000E1, "C: LBU zero extend");
    chk32(uut.u_regs.regs[27], 32'hFFFFABCD, "C: LH sign extend");
    chk32(uut.u_regs.regs[28], 32'h0000E123, "C: LHU zero extend");
    chk32(uut.u_regs.regs[29], 32'hABCDE123, "C: LW");
    chk32(cap_x31,             32'hE123005A, "C: SB/SH lane readback");
    chk32(cap_xlw,             32'hABCDE123, "C: cross-word unaligned LW");
    // memory contents (SB / SH / SW incl. cross-word store)
    chk32(uut.u_dmem.mem[0], 32'hABCDE123, "C: SW word0");
    chk32(uut.u_dmem.mem[1], 32'hE123005A, "C: SB at 4 + SH at 6");
    chk32(uut.u_dmem.mem[2] & 32'hFFFF0000, 32'hE1230000, "C: cross-word SW low word");
    chk32(uut.u_dmem.mem[3] & 32'h0000FFFF, 32'h0000ABCD, "C: cross-word SW high word");
    // branches: 6 taken (poison skipped) + 6 not taken (marker counted)
    chk32(uut.u_regs.regs[30], 32'd6, "C: six not-taken branches fell through");
    chk32(uut.u_regs.regs[31], 32'd0, "C: six taken branches squashed poison");

    // ======================= PHASE D : bank 3 ============================
    $display("=== PHASE D : bypass matrix (EX/MEM->EX, MEM/WB->EX, WB->ID) ===");
    uut.u_imem.bank = 2'd3;
    rst = 1'b1;
    reset_stats();
    repeat (2) @(negedge clk);
    rst = 1'b0;
    mon_en = 1'b1;
    run_cycles(24);
    mon_en = 1'b0;
    $display("--- PHASE D bypass counters: EXMEM(a=%0d,b=%0d) MEMWB(a=%0d,b=%0d) WB_ID(a=%0d,b=%0d)",
             uut.perf_fwd_exmem_a, uut.perf_fwd_exmem_b,
             uut.perf_fwd_memwb_a, uut.perf_fwd_memwb_b,
             uut.perf_fwd_wbid_a, uut.perf_fwd_wbid_b);

    chk32(uut.u_regs.regs[2], 32'd11, "D: distance 1 EX/MEM->EX (x2=11)");
    chk32(uut.u_regs.regs[4], 32'd22, "D: distance 2 MEM/WB->EX (x4=22)");
    chk32(uut.u_regs.regs[6], 32'd33, "D: distance 3 WB->ID bypass (x6=33)");
    chk_min(uut.perf_fwd_exmem_a, 32'd1, "D: EX/MEM->EX on rs1");
    chk_min(uut.perf_fwd_memwb_a, 32'd1, "D: MEM/WB->EX on rs1");
    chk_min(uut.perf_fwd_wbid_a,  32'd1, "D: WB->ID same-cycle bypass");

    if (errors == 0)
        $display("PASS : tb_pipeline (load-use stall, branch flush, JAL/JALR redirect, RV32I coverage, bypass matrix)");
    else
        $display("FAIL : tb_pipeline (%0d check(s) failed)", errors);
    $finish;
end

initial begin
    #200000;
    $display("FAIL : tb_pipeline TIMEOUT");
    $finish;
end

endmodule
