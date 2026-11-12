@echo off
REM =====================================================================
REM  Hyper Core - Icarus Verilog build + run (Windows)
REM  Verilog-2001 source: plain iverilog works, -g2012 is NOT required.
REM  Requires iverilog.exe and vvp.exe on PATH. On this machine they are in
REM  C:\iverilog\bin, so uncomment the line below if PATH is not set.
REM =====================================================================
REM set PATH=C:\iverilog\bin;%PATH%

setlocal
set SRC=alu.v regfile.v imm_gen.v alu_control.v controller.v load_ext.v imem.v dmem.v cpu_top.v

iverilog -o tb_cpu.vvp %SRC% tb_cpu.v
if errorlevel 1 goto :fail
vvp tb_cpu.vvp

iverilog -o tb_pipeline.vvp %SRC% tb_pipeline.v
if errorlevel 1 goto :fail
vvp tb_pipeline.vvp

echo.
echo Both simulations finished. See sim_output.txt for the reference log.
goto :eof

:fail
echo.
echo ERROR: iverilog compile failed.
echo If core_defs.vh cannot be found, add  -I .  to the iverilog command line.
exit /b 1
