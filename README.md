# 数显时钟的FPGA开发

[简体中文](README.md) | [English](README.en.md)

> 基于 Verilog 的 FPGA 数显时钟，支持走时、置数与闹钟功能。

## 目录
- [数显时钟的FPGA开发](#数显时钟的fpga开发)
  - [目录](#目录)
  - [开发环境](#开发环境)
  - [使用注意事项](#使用注意事项)
    - [① PLL —— my\_pll\_divider（50MHz → 1MHz）](#-pll--my_pll_divider50mhz--1mhz)
    - [② RAM —— my\_ram（256 × 12bit 只读乐谱）](#-ram--my_ram256--12bit-只读乐谱)
    - [③ 关联 .mif 乐谱文件](#-关联-mif-乐谱文件)
    - [④ 其它提醒](#-其它提醒)
  - [主要功能](#主要功能)
  - [项目特色](#项目特色)
  - [软件架构](#软件架构)
  - [按键映射](#按键映射)
  - [备注](#备注)

## 开发环境
- 软件：Quartus II
- 器件：Cyclone IV EP4CE10F17C8N 野火征途Pro开发板
- 板载时钟：50MHz 晶振
- 外设：6位数码管（74HC595驱动）、4个独立按键（选择/上调/下调/加载）、1个复位键

## 使用注意事项

本项目**不是纯 RTL 工程**：`clock_mode.v` 实例化了 PLL 的 `my_pll_divider`，`beep_song.v` 实例化了 RAM 的 `my_ram`。仓库**不包含**这两个 IP 的生成文件（它们是 Quartus 向导生成的、与器件绑定，不同环境需自行配置），所以拿到源码后**不能直接编译**——第一次会报 `module my_pll_divider / my_ram not found`。

**最小复现路径**：在 EDA 工具里按下列参数重建这两个 IP，并把模块命名为 `my_pll_divider` / `my_ram`、端口名保持一致，即可**不改任何 RTL 代码**直接编译。若想用其它命名/端口，则需同步修改 `clock_mode.v`（PLL 例化处）与 `beep_song.v`（RAM 例化处）。

### ① PLL —— my_pll_divider（50MHz → 1MHz）

| 配置项 | 值 | 备注 |
|---|---|---|
| IP 类型 | ALTPLL | 无 |
| 目标器件 | Cyclone IV E（EP4CE10F17C8N） | 请根据您的芯片选择型号 |
| 输入频率 inclk0 | 50 MHz（即 20000 ps） | 请根据您的芯片选择参数 |
| 输出 c0 | 倍频 ×1，分频 ÷50 → **1 MHz** | 请根据您的芯片选择参数 |
| c0 占空比 | 50% | 无 |
| c0 相位偏移 | 0° | 无 |
| 补偿时钟 | CLK0 | 请根据您的芯片选择参数 |

生成模块的端口（顶层 `clock_mode.v` 按此例化，命名须一致）：

| 端口 | 方向 | 顶层连接 | 说明 |
|---|---|---|---|
| `areset` | input | 恒接 `1'b0` | 复位（高有效）；PLL 仅上电自动复位，不受系统复位 rst_n 的控制 |
| `inclk0` | input | `sys_clk` | 50MHz 晶振输入 |
| `c0` | output | `sys_clk_1mhz` | 1MHz 输出，作为全系统的 pre_clk 域 |
| `locked` | output | `locked_sig` | 锁定标志，控制全局复位释放（PLL 未锁定时系统保持复位） |

### ② RAM —— my_ram（256 × 12bit 只读乐谱）

| 配置项 | 值 | 备注 |
|---|---|---|
| IP 类型 | RAM: 1-PORT（ALTSYNCRAM） | 无 |
| 目标器件 | Cyclone IV E（EP4CE10F17C8N） | 请根据您的芯片选择型号 |
| 数据位宽 | 12 bit | 无 |
| 地址位宽 | 8 bit（深度 256） | 无 |
| 操作模式 | Single-Port（单端口） | 无 |
| 读/写模式 | 读优先；本项目只读（wren 恒 0） | 不同IP核有不同的端口(wren)命名 |
| 输出寄存 | 由 clock 上升沿寄存输出 | 无 |

生成模块的端口（`beep_song.v` 按此例化，命名须一致）：

| 端口 | 方向 | 顶层连接 | 说明 |
|---|---|---|---|
| `address[7:0]` | input | `rd_addr` | 乐谱地址指针 |
| `clock` | input | `sys_clk` | 系统时钟 |
| `data[11:0]` | input | 恒接 `12'd0` | 只读，写数据口闲置 |
| `wren` | input | 恒接 `1'b0` | 只读，写使能无效 |
| `q[11:0]` | output | `rd_data` | 读出的乐谱编码 |

乐谱编码格式（由 `beep_song.v` 解析，每 12 位 = `{八度[3:0], 音名[3:0], 时值[3:0]}`）：

| 字段 | 取值 |
|---|---|
| 八度 | 3/4/5 = Oct3/4/5，0 = 休止，F = 结束标记 |
| 音名 | 1\~7 = DO/RE/ME/FA/SO/LA/XI，A\~C = 升半音（DO♯/RE♯/FA♯ 等），0 = 休止，F = 结束标记|
| 时值 | 1 = 十六分，2 = 八分，3 = 附点八分，4 = 四分，6 = 附点四分，8 = 二分，F = 一分 |

注：
1. 结束标记的 bit[11:4] = FF, bit[3:0] 可任意填写
2. 结束标记相当于乐谱中的终止线 :||，FPGA 一旦识别到高 8 位为 FF 即立即停止读取，不再解析剩余的低 4 位，因此低 4 位可任意填写，但不能不写，否则高 8 位的 FF 在综合时会被识别为低 8 位，高 4 位会补零，从而导致错误。

### ③ 关联 .mif 乐谱文件

乐谱数据在仓库 `rtl/beep/` 下，两首可选：

- `your_new_home.mif` —— _Your New Home_（神奇数字马戏团主题曲，又称认清现实的小曲儿），**当前默认加载**
- `qifengle.mif` —— 《起风了》

在 RAM 的 MegaWizard 配置页将初始化文件指向其中之一。**注意：`init_file` 路径是相对主工程 `.qpf` 文件所在目录的，不是相对 RAM 文件本身**——例如工程在 `quartus_prj/` 下，应填 `../rtl/beep/your_new_home.mif`。

换歌：1. 改 `init_file` 指向另一份 `.mif` 2. beep_song.v 中的 BPM 参数需改为对那个歌曲的数值（起风了=80，_Your New Home_=90，稍快一点）。然后重新全编译即可。RAM 未关联 `.mif`（或路径错误）时内容为空，蜂鸣器不会响。

### ④ 其它提醒

- 系统时钟假定 **50 MHz**：`beep_song.v` 的音高/节拍参数（`CLK = 50_000_000`、BPM）与 `sys_divider` 的分频常数均按此设计，换时钟频率需同步调整。
- 以上两个 IP 是 Altera/Intel 专有的（altpll / altsyncram）。**其他芯片无法直接使用**，需用其对应EDA工具自带的 PLL/BRAM 原语替代，并改写 `clock_mode.v` 与 `beep_song.v` 中的例化（模块名、端口名可自行定义）。
- 按键引脚绑定见下方「按键映射」表；数码管扫描输出（74HC595：`stcp` / `shcp` / `ds` / `oe`）与蜂鸣器（`beep`）引脚请按你的开发板自行分配。

## 主要功能
- ✅ 时钟模式：时分秒正常走时，小数点1Hz闪烁
- ✅ 置数模式：短按load键切换模式，可分别设置时/分/秒，长按确认，15秒无操作自动退出

    （由于LOAd显示占用时间，实际在编辑置数的界面是约14秒无操作自动退出）
- ✅ 闹钟模式：4组闹钟，支持使能/失能切换、分别设置时/分（秒固定为00）
- ✅ 闹钟鸣响：闹钟触发时播放乐曲《起风了》或 _Your New Home_ ，响90秒后自动停止，按choose、num_up、num_down任意键可提前关闭
- ✅ 鸣响显示：闹钟触发时数码管自动切换到鸣响显示模式，以0.5Hz慢闪烁显示当前鸣响闹钟的时间

## 项目特色
- **一次编写，三处复用**：`counter.v` 是通用 BCD N 进制加减计数器，进制由参数 `radix_data` 指定，被 `clock.v`（走时）、`load_num.v`（手动置数）、`alarm.v`（闹钟编辑）三处共实例化 16 次，不必进行二进制到 BCD 编码的转换。
- **变进制（动态进制）设计**：以 clock 为例：小时个位的进制不固定——十位为 0/1 时个位是十进制（0\~9），十位为 2 时个位是四进制（0\~3，对应 20\~23 时）。进制由 `radix_hour` 动态计算：计数时跟随当前值，置数时跟随装载值，从根上规避"置数瞬间进制错乱"这一经典 bug。
  - 在 load_num 和 alarm 中也有类似处理，是整个项目中最难解决的问题。
- **跨时钟域（CDC）**：PLL 输出的 1MHz（pre_clk 域）与系统 50MHz（sys_clk 域）双时钟域之间，采用 toggle-flag + 三级同步寄存器 + 边沿检测，解决亚稳态问题。
- **状态机**：大胆尝试编写状态机，顶层模式切换、按键长短按判定均使用三段式状态机，置数、闹钟使用三个状态机协同工作。
- **参数化位宽**：计数器位宽用 `$clog2` 自动计算；消抖时间与长短按阈值通过设置端口参数 `DEBOUNCE_MS`、`SHORT_END_MS`、`LONG_PRESS_MS` ，在顶层例化该模块时即可调节参数，无需改动模块内部逻辑。

## 软件架构

```mermaid
flowchart TB
    subgraph clk["时钟与复位"]
        PLL["my_pll_divider<br/>PLL：50MHz → 1MHz"]
        RST["reset_sync<br/>同步复位"]
        DIV["sys_divider<br/>分频 + CDC"]
    end

    subgraph key["按键"]
        DB["btn_debounce ×4<br/>消抖"]
        DUR["btn_duration ×2<br/>长短按判定"]
    end

    subgraph core["核心功能"]
        FSM["模式状态机<br/>CLOCK/LOAD/ALARM/BEEP"]
        CLK["clock.v<br/>走时 · counter×6"]
        NUM["load_num.v<br/>置数 · counter×6"]
        ALM["alarm.v<br/>闹钟 · counter×4"]
    end

    subgraph out["显示与鸣响"]
        SEG["seg_dynamic<br/>动态扫描"]
        HC["hc595_ctrl<br/>74HC595 驱动"]
        BEEP["beep_song<br/>乐曲播放"]
    end

    PLL -->|1MHz| DIV
    PLL -->|locked| RST
    DIV -->|pulse_1ms| DB
    DB --> DUR
    DUR --> FSM
    FSM --> CLK
    FSM --> NUM
    FSM --> ALM
    DIV -->|pulse_1s| CLK
    DIV -->|sec_clk| NUM
    DIV -->|sec_clk| SEG
    DIV -->|sec_clk| ALM
    CLK --> SEG
    NUM --> SEG
    ALM --> SEG
    SEG --> HC
    HC --> LED["6位数码管"]
    ALM -->|alarm_ring_en| BEEP
    BEEP --> BUZ["蜂鸣器"]
```

## 按键映射
| 按键 | 功能 | 引脚映射 | 实体按键 |
|------|------|------|------|
| choose | 置数模式：切换设置字段（时→分→秒→时）<br>闹钟浏览模式：切换闹钟编号（0\~3循环）<br>闹钟编辑模式：切换设置字段（状态→时→分→状态）<br>闹钟编辑入口：长按3秒进入编辑 <br>闹钟鸣响：按下可中断鸣响 | M2 | KEY1 |
| num_down | 当前字段数值 -1 <br>闹钟鸣响：按下可中断鸣响 | M1 | KEY2 |
| num_up | 当前字段数值 +1 <br>闹钟鸣响：按下可中断鸣响 | E15 | KEY3 |
| load | 时钟模式：短按进入置数模式<br>置数模式：短按进入闹钟模式，长按3秒确认置数<br>闹钟浏览模式：短按返回时钟模式<br>闹钟编辑模式：短按取消编辑，长按3秒确认写入 <br>闹钟鸣响：注意，按下load无法中断闹钟鸣响，可能以后会开发“10分钟再响”功能，届时可能这么设计——按下load真正停止闹钟，按下其余按键触发再响 | E16 | KEY4 |
| reset | 系统复位 | M15 | RESET |

## 备注
- 小时进制动态显示很容易出bug，上板验证时尤其注意考察：前一时刻小时为20\~23，后一时刻，置数前小时为04\~09/14\~19的情况下，置数后是否会跳变为03/13，闹钟不仅要检查置数的这些边界情况，还要检查从默认的 -- 切换到正常计数时的边界情况

    说得比较抽象， load_num alarm 代码中有详细解释。
- alarm_ring_en 维持1秒高电平后自动清除，输出到 clock_mode 里，触发 counter_beep 自增，计数未达到90前， beep_en 持续拉高，作为 beep_song 模块的输入
- 闹钟鸣响时，状态机自动从 MODE_CLOCK 切换到 MODE_BEEP，数码管显示当前鸣响闹钟的时间（以0.5Hz慢闪烁，1秒亮/1秒灭）
- 闹钟鸣响显示的数据流：alarm.v 在时间匹配时用 beep_idx 记录触发闹钟编号，clock_mode 拉高 alarm_beep_disp_en 后，alarm.v 将对应闹钟时间以闪烁形式输出到 disp_* 端口，供 seg_dynamic 扫描显示
