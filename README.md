# 数显时钟的FPGA开发

> 私人项目 - 基于 Verilog 的数显时钟，支持置数模式与闹钟。

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
- ✅ 闹钟模式：4组闹钟，支持使能/失能切换、分别设置时/分（秒固定为00）
- ✅ 闹钟鸣响：闹钟触发时播放乐曲《起风了》或《your new home》，响90秒后自动停止，按choose、num_up、num_down任意键可提前关闭
- ✅ 鸣响显示：闹钟触发时数码管自动切换到鸣响显示模式，以1Hz慢闪烁显示当前鸣响闹钟的时间

### 软件架构
<details>
<summary>点击展开架构的ASCII树形图</summary>

```
clock_mode.v ← 顶层模块，整个项目的入口
│
│ ── 时钟与复位 ──
├── my_pll_divider [Quartus IP核]
│ ├── 输入: sys_clk（板载50MHz晶振）
│ ├── 输出: sys_clk_1mhz（PLL分频后1MHz）
│ └── 输出: locked_sig（锁定标志，PLL未锁定时强制全局复位有效）
│
├── reset_sync.v（异步断言、同步释放复位）
│ ├── 输入: key_rst_n（按键复位，低有效）、pll_locked（= locked_sig）
│ ├── 两级同步FF：异步清零，PLL锁定后才同步释放
│ └── 输出: rst_n → 全系统统一使用的低有效同步复位
│
│ ── 系统分频器 ──
├── sys_divider.v
│ ├── pre_clk域（1MHz）：两级10位链式计数器
│ │ ├── ms_cnt [10位] 0→999：每满1ms，ms_flag toggle一次，传递到sys_clk域
│ │ └── sec_cnt [9位] 0→499：每满500ms，sec_flag toggle一次，传递到sys_clk域
│ └── sys_clk域（50MHz）：两路独立CDC（toggle-flag + 三级同步 + 边沿检测）
│ ├── pulse_1ms → 按键消抖计数使能 / 16s超时计数使能（XOR双沿，1kHz）
│ ├── pulse_1s → clock.v → counter（精确1Hz计时驱动，20ns宽脉冲，下降沿检测）
│ └── sec_clk → 各模块显示/计时（= sec_flag_s2，已做CDC，1Hz 50%占空比）
│
│ ── 按键处理 ──
├── button_stabilization.v [实例化×3]（choose / num_up / num_down）
│ ├── 以外部 pulse_1ms 为使能，$clog2(DEBOUNCE_MS) 位计数器消抖
│ ├── ⚠ pulse_1ms 来自外部 sys_divider，非模块内部自产（节省逻辑资源，无功能影响）
│ └── 输出：消抖后电平信号（低有效）→ choose_bs / num_up_bs / num_down_bs
│
├── button_stabilization_long_short.v [实例化×2]（load键、alarm_choose键）
│ ├── pre_clk域：内部自产 pulse_1ms（1000个pre_clk周期后toggle → CDC到sys_clk域）
│ │ └── 跨时钟域方案：toggle-flag + 三级同步寄存器 + XOR边沿检测
│ ├── 消抖：$clog2(DEBOUNCE_MS) 位计数器，以内部 pulse_1ms 为使能
│ ├── 短按判定：消抖确认后按下时长 < SHORT_END_MS（500ms），松手时输出
│ │ └── 输出：load_bs_s / choose_bs_s（低有效，脉宽约 DEBOUNCE_MS 宽的低电平脉冲）
│ └── 长按判定：按住时长 ≥ LONG_PRESS_MS（3000ms），立即输出，不等松手
│ └── 输出：load_bs_l / choose_bs_l（低有效，约1ms宽脉冲，long_press_fired防重复触发）
│
│ ── 长短按边沿检测（在clock_mode内部）──
├── load_s_pulse / load_l_pulse（各1个sys_clk周期宽的低电平脉冲）
│ └── 由 load_bs_s / load_bs_l 的下降沿（prev=1→now=0）产生
│
│ ── 模式状态机（在clock_mode内部，三段式：状态更新/状态切换/状态输出）──
├── 状态机 cs/ns [2位寄存器，初值MODE_CLOCK]
│ ├── MODE_CLOCK（00）：时钟模式，正常走时显示
│ │ ├── 转出条件A：load短按（load_s_pulse=0）→ MODE_LOAD
│ │ └── 转出条件B：beep_en=1（闹钟触发）→ MODE_BEEP
│ ├── MODE_LOAD（01）：置数模式
│ │ ├── 转出条件A：load短按（load_s_pulse=0, load_l_pulse=1）→ MODE_ALARM
│ │ ├── 转出条件B：load长按（load_s_pulse=1, load_l_pulse=0）→ MODE_CLOCK（确认置数）
│ │ └── 转出条件C：16s内 choose/num_up/num_down 均无变化 → MODE_CLOCK（超时取消）
│ │ 16s计时：counter_16s 以 pulse_1s 为使能，按键电平跳变时清零
│ ├── MODE_ALARM（10）：闹钟模式
│ │ └── 转出条件：alarm_view_en=1 且 load短按（load_s_pulse=0）→ MODE_CLOCK
│ └── MODE_BEEP（11）：闹钟鸣响显示模式
│ ├── 进入条件：cs=MODE_CLOCK 且 beep_en=1（由 alarm_ring_en 触发 counter_beep 自增引起）
│ ├── 数码管显示来源：alarm.v 的输出（由 alarm_beep_disp_en=1 控制显示鸣响闹钟时间）
│ └── 转出条件：beep_en=0（counter_beep计满90秒 或 按键中断）→ MODE_CLOCK
│
│ ── 信号路由与使能 ──
├── mode_load_en（MODE_LOAD时为1，其余为0）→ load_num 的工作使能
├── mode_alarm_en（MODE_ALARM时为1，其余为0）→ alarm 的工作使能
├── alarm_beep_disp_en（MODE_BEEP时为1，其余为0）→ alarm 的鸣响显示使能
├── 按键放行
│ ├── MODE_CLOCK：choose/nump/nupn 强制为1（屏蔽）；load 响应短按进行模式切换
│ ├── MODE_LOAD ：choose/nump/nupn 直通至 load_num；load 短按切闹钟/长按确认置数
│ ├── MODE_ALARM：choose 接 choose_bs_s/l（短按切换闹钟/长按进入编辑）
│ │ num_up/down 直通至 alarm；load 短按取消/长按确认闹钟
│ └── MODE_BEEP ：所有按键屏蔽（仅响应 button_now ≠ button_prev 中断闹钟）
├── 显示数据选择（disp_second/minute/hour, disp_point）
│ ├── MODE_CLOCK/default：接 clock.v 的 out_、point_out
│ ├── MODE_LOAD ：接 load_num.v 的 disp_、point_out
│ ├── MODE_ALARM ：接 alarm.v 的 disp_state/hour/minute、point_out
│ └── MODE_BEEP ：接 alarm.v 的 disp_（由 alarm_beep_disp_en 控制输出鸣响闹钟时间）
│
│ ── 置数信号路径 ──
├── load_clock（接 clock.v 的 load 口）
│ ├── = load_l_pulse 延迟一个sys_clk周期（load_l_pulse_delay）
│ └── 延迟原因：load_num.v 内 data_* 用非阻塞赋值更新，需等下一拍才对 clock 有效
│
│ ── 时钟子系统 ──
├── clock.v（持续后台运行，不受MODE影响）
│ ├── 接收：sys_clk、sec_pulse(=pulse_1s)、rst_n、load(=load_clock)、data_*
│ ├── counter.v [实例化×6]（通用BCD N进制加减计数器，纯加计数模式）
│ │ ├── sec0/sec1：秒个位(十进制 0~9) / 秒十位(六进制 0~5)
│ │ ├── min0/min1：分个位(十进制 0~9) / 分十位(六进制 0~5)
│ │ └── hor0/hor1：时个位(变进制，十位=2时0~3，否则0~9) / 时十位(三进制 0~2)
│ │ hour_radix_clockonly：时序逻辑，sec_pulse 到来时根据当前 out_hour[7:4] 更新
│ │ hour_radix（组合逻辑）：load=0 时根据 data_hour 前瞻判断，用于置数时刻
│ │ 注：加计数时 hour_radix 慢一拍无影响，减计数另有处理（见 load_num、alarm）
│ └── 输出：out_second/minute/hour（BCD）、point_out（固定 6'b010100）
│
│ ── 置数子系统 ──
├── load_num.v（mode_load_en使能后工作）
├── 接收：mode_en(=mode_load_en)、sys_clk、sec_clk、rst_n
│ load_confirm(=load_l_pulse)、choose/num_up/num_down(经放行后)
│ before_(= clock.v 的 out_)
│
├── 状态机①：显示控制（current_load）
│ ├── LOAD_IDLE：等待 mode_en 使能
│ ├── LOAD_SHOW：显示"LOAd"，等待 sec_clk 完整上升沿+下降沿后切换（至少1秒）
│ └── LOAD_EDIT：编辑模式，set_en=1，允许按键调整数值
│
├── 状态机②：时分秒选择与计数脉冲产生（current_set）
│ ├── SET_HOUR ：hor_pulse 由 num_up/down 下降沿产生（单周期脉冲）
│ ├── SET_MINUTE：min_pulse 同上
│ └── SET_SECOND：sec_pulse（本地信号）同上
│ choose 下降沿切换状态；set_en 上升沿复位回 SET_HOUR
│
├── counter.v [实例化×6]（与 clock.v 复用同一模块，但以按键脉冲为时钟）
│ ├── hor0/hor1：时钟 = hor_pulse，支持加减计数
│ ├── min0/min1：时钟 = min_pulse，支持加减计数
│ └── sec0/sec1：时钟 = sec_pulse（本地），支持加减计数
│ hour_radix（方案2：取消跳沿检测，mode_en_prev=0期间持续置数）：
│ 加计数：当前 load_hour[7:4]==2 → radix=3，否则 radix=9
│ 减计数：load_hour[3:0]==0（即将借位）时前瞻判断借位后十位
│ 十位当前=0 → 借位后=2 → radix=3
│ 十位当前=1或2 → 借位后=0或1 → radix=9
│
├── 状态机③：闪烁显示（twinkle，由状态机②控制）
│ ├── TWINKLE_HOUR ：时位 sec_clk 高时全灭，低时显示 load_hour
│ ├── TWINKLE_MINUTE：分位同上
│ └── TWINKLE_SECOND：秒位同上
│ ready_* 寄存器暂存含闪烁逻辑的显示值
│
├── 显示输出（组合逻辑 assign）
│ ├── LOAD_SHOW：固定显示"LOAd"（L/O/A/d 字符编码）
│ ├── LOAD_EDIT：显示 ready_（含闪烁）
│ └── 其他/未使能：8'hFF（seg_dynamic 编码为全亮，与 clock 叠加不可见）
│
└── 置数输出（长按 load_confirm 有效时，data_ <= load_）
→ 经 clock_mode 延迟一拍后送入 clock.v 的 load 口完成置数
│
│ ── 闹钟子系统 ──
├── alarm.v（mode_alarm_en使能后工作；鸣响显示时由 alarm_beep_disp_en 使能）
│ ├── 接收：mode_en(=mode_alarm_en)、sys_clk、sec_clk、rst_n
│ │ load(=load_s_pulse)、load_confirm(=load_l_pulse)
│ │ choose(=choose_bs_s)、choose_edit(=choose_bs_l)
│ │ num_up_bs/num_down_bs / now_{second,minute,hour}(=clock.v out_)
│ │ alarm_beep_disp_en（来自clock_mode，鸣响时拉高）
│ │
│ ├── 寄存器堆 memory[0:3]：4组闹钟 × 17位
│ │ └── {en[1位], hour[8位BCD], minute[8位BCD]}，秒固定为 00
│ │
│ ├── bin2bcd_param.v（闹钟编号二进制 → BCD编码显示）
│ │
│ ├── 状态机①：显示控制（current_alarm）
│ │ ├── ALARM_VIEW：浏览闹钟列表，按 choose 短按切换编号（0~3循环）
│ │ │ ├── 显示：{编号BCD, E/d(使能状态), hour, minute}
│ │ │ ├── alarm_view_en=1（顶层据此响应短按 load 返回时钟模式）
│ │ │ └── 长按 choose 进入 ALARM_EDIT
│ │ └── ALARM_EDIT：编辑当前闹钟
│ │ ├── 退出：短按 load（取消编辑）/ 长按 load（确认写入 memory）
│ │ └── alarm_view_en=0（禁止顶层响应短按 load）
│ │
│ ├── 状态机②：编辑字段选择与计数脉冲产生（current_set）
│ │ ├── SET_STATE ：使能状态翻转（num_up/down 翻转 en 位）
│ │ ├── SET_HOUR ：hor_pulse 由 num_up/down 下降沿产生
│ │ └── SET_MINUTE：min_pulse 同上
│ │ choose 下降沿切换状态；set_en 上升沿复位回 SET_STATE
│ │ set_en_prev 检测沿，初始时 latch memory[alarm_num][16] 到 state_tmp
│ │
│ ├── counter.v [实例化×4]（与 clock/load_num 复用同一模块）
│ │ ├── hor0/hor1：时钟 = hor_pulse，支持加减计数
│ │ └── min0/min1：时钟 = min_pulse，支持加减计数
│ │ hour_radix 变进制与 load_num 相同（24小时制，含 FF 特殊处理）
│ │ choose_edit_delay 延时一拍确保 counter 正确加载 view_num
│ │ 参数 min_radix0/min_radix1/hour_radix1 同样考虑 FF 边界情况
│ │
│ ├── 状态机③：闪烁显示（twinkle，由状态机②控制）
│ │ ├── TWINKLE_STATE ：状态位（闹钟编号 + E/d）sec_clk 高时全灭，低时显示
│ │ ├── TWINKLE_HOUR ：时位闪烁
│ │ └── TWINKLE_MINUTE：分位闪烁
│ │ ready_{state, hour, minute} 暂存含闪烁逻辑的显示值
│ │
│ ├── 时间匹配（每 sec_clk 上升沿）
│ │ ├── for 循环遍历 4 组闹钟：若 en=1 且 {hour,minute,00} 匹配 now_time
│ │ │ → alarm_ring_en <= 1'b1；同时 index_beep <= index 记录触发闹钟编号
│ │ └── 若上周期 alarm_ring_en=1 且本轮无新匹配 → alarm_ring_en <= 1'b0
│ │ alarm_ring_en 维持 1 个 sec_clk 周期，用于触发蜂鸣器
│ │
│ ├── 鸣响显示（alarm_beep_disp_en=1, mode_en=0 时生效）
│ │ ├── sec_clk_div：sec_clk 的二分频信号（跳沿检测产生），用于1Hz慢闪烁
│ │ ├── index_beep：时间匹配时记录触发闹钟编号，鸣响显示时用于索引 memory
│ │ ├── beep_hour/minute/second：以 sec_clk_div 控制，1秒输出时间、1秒输出全灭
│ │ └── 显示数据通过 disp_* 端口送出，上报 clock_mode 的 seg_dynamic
│ │
│ └── 显示输出（assign，三路选择）
│ ├── ALARM_VIEW：{编号BCD, E/d, memory[hour], memory[minute]}
│ ├── ALARM_EDIT：ready_{state, hour, minute}（含闪烁）
│ └── 鸣响显示：beep_{hour, minute, second}（含1Hz慢闪烁）
│
│ ── 蜂鸣器（在clock_mode内部） ──
├── counter_beep [7位，CNT_BEEP=90]
│ ├── alarm_ring_en 为高时开始计数（pulse_1s 驱动）
│ ├── 计数到 89 时归零（beep_en 随之拉低，状态机返回 MODE_CLOCK）
│ ├── choose/num_up/num_down 中任意按键按下（button_now ≠ button_prev）立即归零
│ └── beep_en = counter_beep > 0
│
├── beep_song.v（乐曲播放）
│ ├── 接收：sys_clk、rst_n、beep_en(=counter_beep>0)
│ ├── my_ram IP核（qifengle.mif 初始化，地址深度256，12位字宽）
│ │ RAM编码：{octave[3:0], note[3:0], duration[3:0]}
│ │ (octave: 3/4/5=八度, 0=休止, F=结束; note: 1=DO~7=XI)
│ │ (duration: 1=十六分, 2=八分, 3=附点八分, 4=四分, …)
│ │
│ ├── 指针 rd_addr：beep_en 使能后从 0 递增，遇到结束标记归零（循环播放）
│ ├── 音符时长控制：BPM=80，cnt_dur 计到 cnt_dur_max 后移向下个音符
│ │ └── 每音符末尾留 TIME_GAP 静音间隙（≈十六分音符宽度）
│ └── PWM 发声
│ ├── freq_cnt 以 freq_data 为上限循环计数
│ └── beep 在 duty_data(=freq_data/2) 前为高，之后为低（50%占空比）
│
│ ── 共享显示输出 ──
├── seg_dynamic.v（顶层唯一实例，四种模式共用）
│ ├── 输入：disp_*/point_disp（由状态机选择的当前模式数据）
│ ├── 扫描时钟：pre_clk(1MHz) 内部计500次生成 seg_toggle，CDC到 sys_clk 域
│ ├── 小数点：sec_clk 电平控制 point_disp 输出（低电平点亮，闪烁由 sec_clk 状态切换实现）
│ └── 输出：sel（6位位选）、seg（8位段码）→ hc595_ctrl
│
└── hc595_ctrl.v（顶层唯一实例，四种模式共用）
├── 移位时钟：sys_clk 四分频 ≈ 12.5MHz（满足 HC595 时序要求）
├── 数据格式：14位串行（8位段码 seg + 6位位选 sel，低位先传）
└── 输出：stcp / shcp / ds / oe → 两片级联74HC595 → 六位数码管
```
</details> 

## 按键映射
| 按键 | 功能 | 引脚映射 | 实体按键 |
|------|------|------|------|
| choose | 置数模式：切换设置字段（时→分→秒→时）<br>闹钟浏览模式：切换闹钟编号（0~3循环）<br>闹钟编辑模式：切换设置字段（状态→时→分→状态）<br>闹钟编辑入口：长按3秒进入编辑 <br>闹钟鸣响：按下可中断鸣响 | M2 | KEY1 |
| num_down | 当前字段数值 -1 <br>闹钟鸣响：按下可中断鸣响 | M1 | KEY2 |
| num_up | 当前字段数值 +1 <br>闹钟鸣响：按下可中断鸣响 | E15 | KEY3 |
| load | 时钟模式：短按进入置数模式<br>置数模式：短按进入闹钟模式，长按3秒确认置数<br>闹钟浏览模式：短按返回时钟模式<br>闹钟编辑模式：短按取消编辑，长按确认写入 <br>闹钟鸣响：注意，按下load无法中断闹钟鸣响，以后另有用途 | E16 | KEY4 |
| reset | 系统复位 | M15 | RESET |

## 备注
- 小时进制动态显示很容易出bug，上板验证时尤其注意考察：前一时刻小时为20\~23，后一时刻，置数前小时为04\~09/14\~19的情况下，置数后是否会跳变为03/13

    说得比较抽象， load_num 代码中有详细解释。
- alarm_ring_en 维持1秒高电平后自动清除，输出到 clock_mode 里，触发 counter_beep 自增，计数未达到90前， beep_en 持续拉高，作为 beep_song 模块的输入
- 闹钟鸣响时，状态机自动从 MODE_CLOCK 切换到 MODE_BEEP，数码管显示当前鸣响闹钟的时间（以1Hz慢闪烁，1秒亮/1秒灭）
- 闹钟鸣响显示的数据流：alarm.v 在时间匹配时用 index_beep 记录触发闹钟编号，clock_mode 拉高 alarm_beep_disp_en 后，alarm.v 将对应闹钟时间以闪烁形式输出到 disp_* 端口，供 seg_dynamic 扫描显示
- 本仓库为私人备份，不公开。
- VScode里 ctrl + shift + v 预览markdown文件
