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
- ✅ 置数模式：短按load键切换模式，可分别设置时/分/秒，长按确认，16秒无操作自动退出

    （由于LOAd显示占用时间，实际在编辑置数的界面是约14秒无操作自动退出）
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
│   └── 输出:  locked_sig（锁定标志，PLL未锁定时强制全局复位有效）
│
├── reset_sync.v（异步断言、同步释放复位）
│   ├── 输入:  key_rst_n（按键复位，低有效）、pll_locked（= locked_sig）
│   ├── 两级同步FF：异步清零，PLL锁定后才同步释放
│   └── 输出:  rst_n → 全系统统一使用的低有效同步复位
│
│  ── 系统分频器 ──
├── sys_divider.v
│   ├── pre_clk域（1MHz）：两级10位链式计数器
│   │   ├── ms_cnt  [10位] 0→999：每满1ms，ms_flag toggle一次，传递到sys_clk域
│   │   └── sec_cnt [10位] 0→999：每满1s，sec_flag toggle一次，传递到sys_clk域 + sec_clk翻转
│   └── sys_clk域（50MHz）：两路独立CDC（toggle-flag + 三级同步 + XOR边沿检测）
│       ├── pulse_1ms → 按键消抖计数使能 / 16s超时计数使能
│       ├── pulse_1s  → clock.v → counter（精确1Hz计时驱动，20ns宽脉冲）
│       └── sec_clk   → clock.v显示输出 / load_num.v（小数点闪烁 + LOAd停留时长）
│
│  ── 按键处理 ──
├── button_stabilization.v [实例化×3]（choose / num_up / num_down）
│   ├── 以外部 pulse_1ms 为使能，$clog2(DEBOUNCE_MS) 位计数器消抖
│   ├── ⚠ pulse_1ms 来自外部 sys_divider，非模块内部自产（节省逻辑资源，无功能影响）
│   └── 输出：消抖后电平信号（低有效）→ choose_bs / num_up_bs / num_down_bs
│
├── button_stabilization_long_short.v [实例化×1]（load键）
│   ├── pre_clk域：内部自产 pulse_1ms（1000个pre_clk周期后toggle → CDC到sys_clk域）
│   │   └── 跨时钟域方案：toggle-flag + 三级同步寄存器 + XOR边沿检测
│   ├── 消抖：$clog2(DEBOUNCE_MS) 位计数器，以内部 pulse_1ms 为使能
│   ├── 短按判定：消抖确认后按下时长 < SHORT_END_MS（500ms），松手时输出
│   │   └── 输出：load_bs_s（低有效，脉宽约 DEBOUNCE_MS 宽的低电平脉冲）
│   └── 长按判定：按住时长 ≥ LONG_PRESS_MS（3000ms），立即输出，不等松手
│       └── 输出：load_bs_l（低有效，约1ms宽脉冲，long_press_fired防重复触发）
│
│  ── 长短按边沿检测（在clock_mode内部）──
├── load_s_pulse / load_l_pulse（各1个sys_clk周期宽的低电平脉冲）
│   └── 由 load_bs_s / load_bs_l 的下降沿（prev=1→now=0）产生
│
│  ── 模式状态机（在clock_mode内部）──
├── 状态机 MODE [2位寄存器，初值MODE_CLOCK]
│   ├── MODE_CLOCK（00）：时钟模式，正常走时显示
│   │   └── 转出条件：load短按（load_s_pulse=0）→ MODE_LOAD
│   ├── MODE_LOAD（01）：置数模式
│   │   ├── 转出条件A：load短按（load_s_pulse=0, load_l_pulse=1）→ MODE_CLOCK
│   │   │   注：alarm功能待实现后改为 → MODE_ALARM
│   │   ├── 转出条件B：load长按（load_s_pulse=1, load_l_pulse=0）→ MODE_CLOCK（确认置数）
│   │   └── 转出条件C：16s内 choose/num_up/num_down 均无变化 → MODE_CLOCK（超时取消）
│   │       16s计时：counter_16s 以 pulse_1ms 为使能，按键电平跳变时清零
│   └── MODE_ALARM（10）：闹钟模式（待实现，现暂时短路到MODE_CLOCK）
│
│  ── 信号路由与使能 ──
├── mode_load_en（MODE_LOAD时为1，其余为0）→ load_num 的工作使能
├── 按键放行（仅 MODE_LOAD 下有效）
│   ├── choose_load_num  = choose_bs （MODE_CLOCK/default时强制1）
│   ├── num_up_load_num  = num_up_bs
│   └── num_down_load_num= num_down_bs
└── 显示数据选择（disp_second/minute/hour, point_disp）
    ├── MODE_CLOCK/default：接 clock.v 的 out_*、point_out
    └── MODE_LOAD：接 load_num.v 的 disp_*、point_out
│
│  ── 置数信号路径 ──
├── load_clock（接 clock.v 的 load 口）
│   ├── = load_l_pulse 延迟一个sys_clk周期（load_l_pulse_delay）
│   └── 延迟原因：load_num.v 内 data_* 用非阻塞赋值更新，需等下一拍才对 clock 有效
│
│  ── 时钟子系统 ──
└── clock.v（持续后台运行，不受MODE影响）
    ├── 接收：sys_clk、sec_pulse(=pulse_1s)、rst_n、load(=load_clock)、data_*
    ├── counter.v [实例化×6]（通用BCD N进制加减计数器，纯加计数模式）
    │   ├── sec0/sec1：秒个位(十进制 0~9) / 秒十位(六进制 0~5)
    │   ├── min0/min1：分个位(十进制 0~9) / 分十位(六进制 0~5)
    │   └── hor0/hor1：时个位(变进制，十位=2时0~3，否则0~9) / 时十位(三进制 0~2)
    │       hour_radix：时序逻辑，sec_pulse 到来时根据当前 out_hour[7:4] 更新
    │       注：加计数时 hour_radix 慢一拍无影响，减计数另有处理（见 load_num）
    └── 输出：out_second/minute/hour（BCD）、point_out（固定 6'b010100）
│
│  ── 置数子系统 ──
└── load_num.v（mode_load_en使能后工作）
    ├── 接收：mode_en(=mode_load_en)、sys_clk、sec_clk、rst_n
    │         load_confirm(=load_l_pulse)、choose/num_up/num_down(经放行后)
    │         before_*(= clock.v 的 out_*)
    │
    ├── 状态机①：显示控制（current_load）
    │   ├── LOAD_IDLE：等待 mode_en 使能
    │   ├── LOAD_SHOW：显示"LOAd"，等待 sec_clk 完整上升沿+下降沿后切换（至少1秒）
    │   └── LOAD_EDIT：编辑模式，set_en=1，允许按键调整数值
    │
    ├── 状态机②：时分秒选择与计数脉冲产生（current_set）
    │   ├── SET_HOUR  ：hor_pulse 由 num_up/down 下降沿产生（单周期脉冲）
    │   ├── SET_MINUTE：min_pulse 同上
    │   └── SET_SECOND：sec_pulse（本地信号）同上
    │   choose 下降沿切换状态；set_en 上升沿复位回 SET_HOUR
    │
    ├── counter.v [实例化×6]（与 clock.v 复用同一模块，但以按键脉冲为时钟）
    │   ├── hor0/hor1：时钟 = hor_pulse，支持加减计数
    │   ├── min0/min1：时钟 = min_pulse，支持加减计数
    │   └── sec0/sec1：时钟 = sec_pulse（本地），支持加减计数
    │   hour_radix（组合逻辑 wire）：
    │       加计数：当前 load_hour[7:4]==2 → radix=3，否则 radix=9
    │       减计数：load_hour[3:0]==0（即将借位）时前瞻判断借位后十位
    │           十位当前=0 → 借位后=2 → radix=3
    │           十位当前=1或2 → 借位后=0或1 → radix=9
    │
    ├── 状态机③：闪烁显示（twinkle，由状态机②控制）
    │   ├── TWINKLE_HOUR  ：时位 sec_clk 高时全灭，低时显示 load_hour
    │   ├── TWINKLE_MINUTE：分位同上
    │   └── TWINKLE_SECOND：秒位同上
    │   ready_* 寄存器暂存含闪烁逻辑的显示值
    │
    ├── 显示输出（组合逻辑 assign）
    │   ├── LOAD_SHOW：固定显示"LOAd"（L/O/A/d 字符编码）
    │   ├── LOAD_EDIT：显示 ready_*（含闪烁）
    │   └── 其他/未使能：8'hFF（seg_dynamic 编码为全亮，与 clock 叠加不可见）
    │
    └── 置数输出（长按 load_confirm 有效时，data_* <= load_*）
        → 经 clock_mode 延迟一拍后送入 clock.v 的 load 口完成置数
│
│  ── 共享显示输出 ──
├── seg_dynamic.v（顶层唯一实例，三种模式共用）
│   ├── 输入：disp_*/point_disp（由状态机选择的当前模式数据）
│   ├── 扫描时钟：pre_clk(1MHz) 内部计500次生成 seg_toggle，CDC到 sys_clk 域
│   ├── 小数点：sec_clk 边沿翻转 point_en，控制 point_disp 输出
│   └── 输出：sel（6位位选）、seg（8位段码）→ hc595_ctrl
│
└── hc595_ctrl.v（顶层唯一实例，三种模式共用）
    ├── 移位时钟：sys_clk 四分频 ≈ 12.5MHz（满足 HC595 时序要求）
    ├── 数据格式：14位串行（8位段码 seg + 6位位选 sel，低位先传）
    └── 输出：stcp / shcp / ds / oe → 两片级联74HC595 → 六位数码管
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
- 小时进制动态显示很容易出bug，上板验证时尤其注意考察：前一时刻小时为20~23，后一时刻，置数前小时为04~09/14~19的情况下，置数后是否会跳变为03/13

    说得比较抽象， load_num 代码中有详细解释。
- 本仓库为私人备份，不公开。
- VScode里 ctrl + shift + v 预览markdown文件
