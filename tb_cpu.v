// ===========================================================================
// Testbench : tb_cpu
// Function  : Cycle-by-cycle architectural trace of Hyper Core running the
//             bank-0 firmware. Prints IF PC, EX ALU result and x1..x6 each
//             cycle, then asserts the final architectural state
//             x1=5 x2=3 x3=8 x4=8 x5=28 x6=8 and dmem[0]=8.
//             Also prints the hierarchical performance counters.
// Timeout   : a separate initial block aborts with FAIL after 100000 ns.
// Reset     : active high for two clock periods, released on a negedge.
// ===========================================================================
`timescale 1ns/1ps
module tb_cpu;

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
    forever #5 clk = ~clk;               // 10 ns period
end

integer c;
reg     err;

task chk_reg;
    input [4:0]  idx;
    input [31:0] exp;
    begin
        if (uut.u_regs.regs[idx] !== exp) begin
            $display("  MISMATCH x%0d : got %0d (0x%08h), expected %0d (0x%08h)",
                     idx, uut.u_regs.regs[idx], uut.u_regs.regs[idx], exp, exp);
            err = 1'b1;
        end
    end
endtask

initial begin
    err = 1'b0;
    rst = 1'b1;
    repeat (2) @(negedge clk);
    rst = 1'b0;

    $display("================ Hyper Core : tb_cpu ================");
    $display("cyc | pc_out   | alu_result | x1 x2 x3 x4 x5 x6");
    $display("----+----------+------------+-----------------------");
    for (c = 0; c < 30; c = c + 1) begin
        @(negedge clk);
        $display("%3d | %08h | %08h   | %2d %2d %2d %2d %2d %2d",
                 c, pc_out, alu_result_out,
                 uut.u_regs.regs[1], uut.u_regs.regs[2],
                 uut.u_regs.regs[3], uut.u_regs.regs[4],
                 uut.u_regs.regs[5], uut.u_regs.regs[6]);
    end

    $display("---- final architectural state ----");
    $display("x1=%0d x2=%0d x3=%0d x4=%0d x5=%0d x6=%0d  dmem[0]=%0d",
             uut.u_regs.regs[1], uut.u_regs.regs[2], uut.u_regs.regs[3],
             uut.u_regs.regs[4], uut.u_regs.regs[5], uut.u_regs.regs[6],
             uut.u_dmem.mem[0]);
    $display("perf: cycles=%0d retired=%0d stalls=%0d flushes=%0d",
             uut.perf_cycles, uut.perf_retired, uut.perf_stalls, uut.perf_flushes);
    $display("perf: stall_load_use=%0d flush_branch=%0d flush_jal=%0d flush_jalr=%0d",
             uut.perf_stall_load_use, uut.perf_flush_branch,
             uut.perf_flush_jal, uut.perf_flush_jalr);
    $display("perf: fwd EXMEM(a=%0d,b=%0d) MEMWB(a=%0d,b=%0d) WB_ID(a=%0d,b=%0d)",
             uut.perf_fwd_exmem_a, uut.perf_fwd_exmem_b,
             uut.perf_fwd_memwb_a, uut.perf_fwd_memwb_b,
             uut.perf_fwd_wbid_a, uut.perf_fwd_wbid_b);

    chk_reg(5'd1, 32'd5);
    chk_reg(5'd2, 32'd3);
    chk_reg(5'd3, 32'd8);
    chk_reg(5'd4, 32'd8);
    chk_reg(5'd5, 32'd28);
    chk_reg(5'd6, 32'd8);
    if (uut.u_dmem.mem[0] !== 32'd8) begin
        $display("  MISMATCH dmem[0] : got %0d, expected 8", uut.u_dmem.mem[0]);
        err = 1'b1;
    end

    if (err == 1'b0)
        $display("PASS : tb_cpu  (x1=5 x2=3 x3=8 x4=8 x5=28 x6=8, dmem[0]=8)");
    else
        $display("FAIL : tb_cpu  (architectural state mismatch)");
    $finish;
end

initial begin
    #100000;
    $display("FAIL : tb_cpu TIMEOUT");
    $finish;
end

endmodule
