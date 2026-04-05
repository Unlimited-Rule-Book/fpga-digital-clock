# 数显时钟的FPGA开发

> 私人项目 - 基于 Verilog 的数显时钟，支持置数模式与闹钟（待实现）。

## 目录
- [开发环境](#开发环境)
- [主要功能](#主要功能)
- [软件架构](#软件架构)
- [按键映射](#按键映射)
- [备注](#备注)

## 开发环境
- 软件：Quartus II
- 器件：Cyclone IV EP4CE10F17C8N 野火征途Pro开发板
- 板载时钟：50MHz 晶振
- 外设：6位数码管（74HC595驱动）、3个独立按键（选择/上调/下调）、1个加载键

## 主要功能
- ✅ 时钟模式：时分秒正常走时，小数点1Hz闪烁
- ⏳ 置数模式：长按加载键进入，可分别设置时/分/秒，16秒无操作自动退出
- ⏳ 闹钟模式（待实现）

### 软件架构
<details>
<summary>点击展开架构的ASCII树形图</summary>

```
clock_mode.v  ← 顶层模块，整个项目的入口
│
│  ── 时钟与复位 ──
├── my_pll_divider [Quartus IP核]
│   ├── 输入:  sys_clk（板载50MHz晶振）
│   ├── 输出:  sys_clk_1mhz（PLL分频后1MHz）
│   └── 输出:  locked_sig（锁定标志，未锁定时使全局复位有效）
│   注：reset = reset_input & locked_sig（PLL未锁定前系统始终处于复位）
│
│  ── 系统分频器（原pulse_sec，扩展重命名）──
├── sys_divider.v
│   ├── pre_clk域（1MHz）：两级10位链式计数器
│   │   ├── ms_cnt  [10位] 0→999：每满1ms，ms_flag toggle一次，传递到sys_clk域
│   │   └── sec_cnt [10位] 0→999：每满1s，sec_flag toggle一次，传递到sys_clk域 + sec_clk翻转
│   └── sys_clk域（50MHz）：两路独立CDC（toggle-flag + 双级同步 + XOR边沿检测）
│       ├── pulse_1ms → 按键消抖计数使能 / 16s超时计数使能
│       ├── pulse_1s  → clock.v → counter_time（精确1Hz计时驱动，20ns宽脉冲）
│       └── sec_clk   → clock.v → seg_dynamic（小数点1Hz闪烁）
│                     → load_num.v → seg_dynamic（置数模式小数点）
│
│  ── 按键处理 ──
├── button_stabilization.v [实例化×3]（choose / num_up / num_down）
│   ├── 计数单位：1ms（以pulse_1ms为使能，5位计数器，0~19 = 20ms消抖）
│   └── 输出：消抖后电平信号（低有效）
│       → choose_bs / num_up_bs / num_down_bs
│
├── button_stabilization_long_short.v [实例化×1]（load键）
│   ├── 计数单位：1ms（以pulse_1ms为使能，12位计数器，0~2999 = 3s长按）
│   ├── 输出：load_bs_s（短按，低有效，~20ms宽脉冲）
│   └── 输出：load_bs_l（长按，低有效，~1ms宽脉冲，按满3s立即触发）
│
│  ── 模式状态机（在clock_mode内部）──
├── 状态机 MODE [2位寄存器]
│   ├── MODE_CLOCK（00）：时钟模式，正常走时显示
│   │   └── 转出条件：load短按(load_bs_s=0) → MODE_LOAD
│   ├── MODE_LOAD（01）：置数模式
│   │   ├── 转出条件A：load短按(load_bs_s=0, load_bs_l=1) → MODE_ALARM
│   │   ├── 转出条件B：load长按(load_bs_s=1, load_bs_l=0) → MODE_CLOCK（确认置数）
│   │   └── 转出条件C：16秒无操作（choose/num_up/num_down均无变化） → MODE_CLOCK
│   └── MODE_ALARM（10）：闹钟模式（待实现）
│       ├── 转出条件：load短按或长按 → MODE_CLOCK
│       └── 转出条件：16秒无操作 → MODE_CLOCK
│
│  ── 模式使能与信号路由 ──
├── 输入使能（置数/闹钟模式下才放行按键信号）
│   ├── choose_load_num  = ~(choose  && mode_load_en)
│   ├── num_up_load_num  = ~(num_up  && mode_load_en)
│   └── num_down_load_num= ~(num_down&& mode_load_en)
│   ⚠ sys_clk_load_num = sys_clk && mode_load_en  [门控时钟，待修复]
│
└── 输出选择（各模式输出互斥OR到stcp/shcp/ds/oe）
    ├── stcp/shcp/ds/oe = (时钟模式输出 && mode_clock_en)
    │                  || (置数模式输出 && mode_load_en)
    │   注：两模块同时运行，通过使能信号决定谁的输出送到数码管
    └── load_clock = load_bs_s && load_bs_l（短按或长按均触发计数器置数）
│
│  ── 时钟显示子系统 ──
└── clock.v（持续运行，不受MODE影响，后台始终计时）
    ├── 接收：sys_clk, pre_clk, sec_pulse(=pulse_1s), sec_clk, reset, load, data_*
    ├── counter_time.v（时分秒BCD联级计数）
    │   └── counter.v [实例化×6]（通用BCD N进制加减计数器）
    │       ├── sec0/sec1：秒个位(十进制)/秒十位(六进制)
    │       ├── min0/min1：分个位(十进制)/分十位(六进制)
    │       └── hor0/hor1：时个位(变进制，0~9或0~3)/时十位(三进制)
    ├── seg_dynamic.v（6位数码管动态扫描，1ms刷新周期）
    │   ├── 以pre_clk(1MHz)自行生成1ms扫描时钟（内部500计数）
    │   └── 以sec_clk边沿检测控制小数点1s闪烁
    └── hc595_ctrl.v（74HC595串行驱动，sys_clk四分频后12.5MHz移位）
│
│  ── 置数子系统 ──
└── load_num.v（由mode_load_en使能后前台显示，clock在后台持续运行）
    ├── 接收：sys_clk(门控⚠), sec_clk, reset, load_bs_s, load_bs_l
    │         choose/num_up/num_down(经模式使能门控后), before_*/point_out
    ├── 内部状态机 current_set（SET_HOUR→SET_MINUTE→SET_SECOND，由choose切换）
    ├── 内部复位逻辑 reset_n（load短按时产生一次内部复位）
    ├── counter.v [实例化×6]（复用同一计数器模块）
    │   注意：load_num里counter的用法与clock里不同——
    │   clock里：sec_pulse作为使能，sys_clk作为时钟（脉冲使能模式）
    │   load_num里：hor_pulse/min_pulse/sec_pulse直接作为时钟（按键驱动模式）
    ├── seg_dynamic.v（置数模式专用，输入为load_num内部计数值）
    └── hc595_ctrl.v（置数模式专用）
```
</details> 

## 按键映射
| 按键 | 功能 | 引脚映射 | 实体按键 |
|------|------|------|------|
| choose | 切换置数字段（时→分→秒）| M2 | KEY1 |
| num_down | 当前字段数值-1 | M1 | KEY2 |
| num_up | 当前字段数值+1 | E15 | KEY3 |
| load   | 短按切换模式/确认置数，长按3秒确认置数 | E16 | KEY4 |
| reset | 复位 | M15 | RESET |

## 备注
- 本仓库为私人备份，不公开。
- VScode里 ctrl + shift + v 预览markdown文件
