# Hyper Core

一个用 Verilog-2001 编写的 RV32I 五级流水线（IF / ID / EX / MEM / WB）CPU，在 Icarus Verilog 12.0 下完成功能仿真验证。

> **合规声明**：本项目只运行了仓库内置的自写固件，**未运行 RISC-V International 官方架构测试（riscv-arch-test / RISCOF）**，因此不宣称 "RISC-V compliant" 或 "官方兼容"。RISC-V 名称及 logo 归 RISC-V International 所有，本项目仅作描述性引用，与该项目无隶属或认证关系。

---

## 1. 文件清单

| 文件 | 作用 |
|---|---|
| `cpu_top.v` | 顶层：五级流水线寄存器、旁路网络、冒险控制、重定向、性能计数器 |
| `alu.v` | 32 位整数 ALU（11 种操作，含无 `$signed` 的算术右移与有符号比较） |
| `regfile.v` | 32×32 寄存器堆，2 读 1 写，x0 硬连线为 0，写优先读 |
| `imm_gen.v` | I / S / B / U / J 五种立即数生成与符号扩展 |
| `alu_control.v` | 由 ALU 操作类别 + funct3 + funct7[5] 生成 ALU 功能码 |
| `controller.v` | 主译码器，输出全部控制信号与操作数使用标记 |
| `load_ext.v` | LB / LH / LW / LBU / LHU 的移位对齐与符号/零扩展 |
| `imem.v` | 4 KiB 指令 ROM，内置 4 段固件（见第 6 节） |
| `dmem.v` | 4 KiB 数据 RAM，4 byte-enable lane + 跨字第二组的 4 lane |
| `core_defs.vh` | 所有 opcode / ALU 编码 / 立即数选择码 / 旁路选择码的单一定义源 |
| `tb_cpu.v` | 逐周期架构状态跟踪，断言 x1–x6 与 `dmem[0]`，带超时保护 |
| `tb_pipeline.v` | 冒险专项：load-use stall、branch flush、JAL/JALR 重定向、全指令覆盖、旁路矩阵 |
| `run.bat` | Windows 一键编译 + 运行 |
| `sim_output.txt` | 真实 `iverilog` + `vvp` 终端输出日志（生成物，保留作为验证证据） |

`core_defs.vh` 通过 `` `include `` 被 9 个模块引用，**必须与 `.v` 文件放在同一目录**。

---

## 2. 快速开始

依赖：Icarus Verilog（开发时使用 12.0）。`iverilog` **默认参数即可编译**，不需要 `-g2012`；源码为 Verilog-2001，也已用 `-g2005`、`-g2012` 分别编译通过。

### Windows（CMD）
```bat
cd /d "path\to\hyper-core"
set PATH=C:\iverilog\bin;%PATH%        :: 仅当 iverilog 不在 PATH 时
run.bat
```

或手动：
```bat
set SRC=alu.v regfile.v imm_gen.v alu_control.v controller.v load_ext.v imem.v dmem.v cpu_top.v
iverilog -o tb_cpu.vvp      %SRC% tb_cpu.v
vvp tb_cpu.vvp
iverilog -o tb_pipeline.vvp %SRC% tb_pipeline.v
vvp tb_pipeline.vvp
```

### Linux / macOS / Git Bash
```sh
SRC="alu.v regfile.v imm_gen.v alu_control.v controller.v load_ext.v imem.v dmem.v cpu_top.v"
iverilog -o tb_cpu.vvp      $SRC tb_cpu.v      && vvp tb_cpu.vvp
iverilog -o tb_pipeline.vvp $SRC tb_pipeline.v && vvp tb_pipeline.vvp
```

若编译器报找不到 `core_defs.vh`，在 `iverilog` 命令中加 `-I .`（换用 Verilator / Yosys 等工具时通常也需要显式 include 路径）。

**预期结果**：两个 testbench 都打印 `PASS`，无 `FAIL` 行。`tb_cpu` 逐周期打印 PC、ALU 结果与 x1–x6；`tb_pipeline` 打印每次 stall / flush 发生的周期号、被 squash 的指令 PC 与重定向 PC。完整实际输出见 `sim_output.txt`。

---

## 3. 顶层接口

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk` | in | 1 | 时钟 |
| `rst` | in | 1 | **异步、高有效复位**，清零 PC、五级流水线 valid/控制字段、寄存器堆、数据存储器与全部计数器 |
| `pc_out` | out | 32 | IF 阶段 PC 寄存器（`pc`）当前值 |
| `alu_result_out` | out | 32 | EX 阶段 ALU 组合输出 |

为兼容已有 testbench，以下名字固定不可更改：

- 寄存器堆实例名 `u_regs`，内部数组名 `regs`（可用 `uut.u_regs.regs[n]` 层次访问）
- IF 阶段 PC 寄存器名 `pc`
- 顶层模块名 `cpu_top`

复数模块实例：`u_imem`、`u_dmem`、`u_ctrl`、`u_immgen`、`u_aluctrl`、`u_alu`、`u_loadext`。

---

## 4. 微架构

### 指令集
实现 37 条 RV32I 指令：

- U 型：`LUI`、`AUIPC`
- J / I 跳转：`JAL`、`JALR`（目标按 `(rs1+imm) & ~1` 计算，`rd = pc+4`）
- B 型：`BEQ`、`BNE`、`BLT`、`BGE`、`BLTU`、`BGEU`（有符号比较用 MSB 翻转，无 `$signed`）
- Load：`LB`、`LH`、`LW`、`LBU`、`LHU`
- Store：`SB`、`SH`、`SW`
- I 型运算：`ADDI`、`SLTI`、`SLTIU`、`XORI`、`ORI`、`ANDI`、`SLLI`、`SRLI`、`SRAI`
- R 型：`ADD`、`SUB`、`SLL`、`SLT`、`SLTU`、`XOR`、`SRL`、`SRA`、`OR`、`AND`

`FENCE`、`ECALL`、`EBREAK` 被译码为合法的无副作用指令（不改变架构状态）；非法 opcode 只置 `o_illegal`，不触发异常。

### 旁路网络（优先级明确）
1. **EX/MEM → EX**（更年轻，优先级最高）
2. **MEM/WB → EX**（较老，先赋值、被上一条覆盖）
3. **WB → ID 同周期写优先旁路**：`cpu_top` 中显式 mux（`id_wbid_hit1/2`）+ `regfile` 内部写优先读，双重实现

`controller` 输出的 `o_uses_rs1/o_uses_rs2` 让旁路和冒险判断只针对真正使用寄存器的指令，立即数字段不会被误判为源寄存器。仍处在 EX/MEM 的 load 不参与 EX 转发（数据要到 MEM 末才可用），由 load-use stall 保证其消费者不会在那个时刻进入 EX。

### 冒险处理
- **load-use**：ID 阶段检测 `idex_mem_read && idex_rd == ifid_rsX`，产生 1 周期 stall；PC 与 IF/ID 保持，ID/EX 插入 bubble（valid=0 且所有控制信号清零）。
- **控制冒险**：分支 / JAL / JALR 在 **EX** 解析。taken 时清 IF/ID 与 ID/EX、从 EX 重定向 PC，产生 **2 周期惩罚**。JAL/JALR 自身仍正常流到 WB 写链接寄存器。
- **精确架构状态**：`ifid_valid` / `idex_valid` / `exmem_valid` / `memwb_valid` 贯穿五级；只有 valid 的指令能写寄存器堆和数据存储器；bubble 与 flush 掉的指令不改架构状态。

优先级：复位 > EX 重定向/flush > load-use stall > 正常推进。

### 访存
`dmem` 按 32 位字组织，一次给出相邻两个字 `rdata_lo = mem[addr>>2]`、`rdata_hi = mem[(addr>>2)+1]`。`load_ext` 把它们拼成 64 位窗口并按 `8 × addr[1:0]` 右移，再按 funct3 取 byte / half / word 并符号或零扩展。store 把 rs2 左移 `8 × addr[1:0]` 后拆成两个字，生成 `be_lo[3:0]`（寻址字的 4 个 lane）和 `be_hi[3:0]`（下一字的 4 个 lane）。因此非对齐访问、包括跨越 32 位字边界的 load/store，都在单周期内用移位和 lane 选择完成。

### 性能计数器（层次引用观测）
顶层端口按约定不增加，计数器通过 `uut.perf_xxx` 读取：

- 总量：`perf_cycles`、`perf_retired`、`perf_stalls`、`perf_flushes`
- 分类：`perf_stall_load_use`、`perf_flush_branch`、`perf_flush_jal`、`perf_flush_jalr`
- 旁路：`perf_fwd_exmem_a/b`、`perf_fwd_memwb_a/b`、`perf_fwd_wbid_a/b`
- 追踪：`perf_last_flush_pc`、`perf_last_redirect_pc`、`perf_last_stall_pc`

### 时序假设
`imem` / `dmem` 读为组合逻辑，`dmem` 写在 `posedge clk`；IF/ID 在推进 `pc` 的同一上升沿锁存 `imem[pc]`。因此 MEM 阶段的 load 能看到上一条 store 在前一上升沿写入的数据。所有时序块统一 `always @(posedge clk or posedge rst)`，组合块统一 `always @(*)` 并在开头/默认分支给全赋值，不推断 latch。

---

## 5. 主固件（bank 0）

```asm
addi x1, x0, 5
addi x2, x0, 3
add  x3, x1, x2      # EX/MEM 与 MEM/WB 旁路
sw   x3, 0(x0)       # store 数据旁路
lw   x4, 0(x0)       # load
add  x6, x4, x0      # load-use，1 周期 stall
jal  x5, +8          # 控制冒险，flush 下一条
nop                  # 被 flush 的 wrong-path
beq  x0, x0, 0       # 自旋
```

最终架构状态：`x1=5 x2=3 x3=8 x4=8 x5=28 x6=8`，`dmem[0]=8`。

---

## 6. 内置固件 bank

`imem.v` 内含 4 张静态 ROM 表，由 `imem.bank` 选择。`tb_pipeline.v` 通过层次引用 `uut.u_imem.bank = 2'dN` 切换，因此不需要在运行时改写指令存储器。

| bank | 内容 |
|---|---|
| 0 | 上述主程序：`tb_cpu.v` 与 PHASE A 使用 |
| 1 | JALR 重定向：`x8=49` → 目标 `48 (0x30)`，验证 `& ~1`、链接值、`rs1` 转发，以及两条 wrong-path 指令不提交 |
| 2 | 全 RV32I 覆盖：10 个 R 型、9 个 I 型运算、LUI/AUIPC、5 种 load、3 种 store、6 种分支的 taken/not-taken、JAL、FENCE/ECALL/EBREAK，含非对齐 lane 与跨字 store/load |
| 3 | 旁路矩阵：依赖距离 1 / 2 / 3 分别验证 EX/MEM→EX、MEM/WB→EX、WB→ID |

---

## 7. 验证结果

以下是在 Icarus Verilog 12.0 下真实运行的结果（完整逐行输出见 `sim_output.txt`）：

```
tb_cpu      : PASS  x1=5 x2=3 x3=8 x4=8 x5=28 x6=8, dmem[0]=8
tb_pipeline : PASS  0 个 FAIL
```

`tb_cpu` 30 周期摘要：`cycles=30 retired=13 stalls=1 flushes=7`，其中 `stall_load_use=1`、`flush_jal=1`、`flush_branch=6`（自旋 beq 反复 taken）。

`tb_pipeline` 关键事件：

```
[cyc   7] LOAD-USE STALL : held IF/ID pc=00000014 | load pc=00000010
[cyc  10] JAL      FLUSH : squashed IF/ID pc=0000001c | redirect pc=00000020
[cyc   4] JALR     FLUSH : squashed IF/ID pc=00000008 | redirect pc=00000030   (PHASE B)
--- PHASE D bypass counters: EXMEM(a=1,b=0) MEMWB(a=1,b=0) WB_ID(a=1,b=0)
```

`-Wall` 编译只产生两类无害提示：RTL 模块未声明 timescale；`always @(*)` 对存储器数组全体字敏感。默认参数编译无警告。

---

## 8. 已知限制

- 不支持 M / A / F / D / C 扩展（乘除法、原子、浮点、压缩指令）
- 无 CSR、特权级、异常与中断；`ECALL`/`EBREAK` 为 NOP；非法指令不触发异常
- 无 Cache、MMU/TLB、分支预测、乱序执行、超标量、写缓冲；taken 分支固定 2 周期惩罚
- `FENCE` 无内存序语义
- 无总线接口与等待状态；`imem` / `dmem` 为理想单周期组合读
- 地址空间 4 KiB，高位地址被截断；地址空间最末一个字的跨字访存因索引回绕被禁止（其余非对齐、含跨 32 位字边界的访存均支持）
- 复位为异步高有效，未做复位释放同步
- 只完成 Icarus Verilog 功能仿真验证；**未做综合、静态时序分析、FPGA 上板、形式化验证，也未跑官方 ISA 合规测试**

---

## 9. 许可证

见仓库根目录的 `LICENSE` 文件。
