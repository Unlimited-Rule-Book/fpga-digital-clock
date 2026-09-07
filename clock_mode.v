// =============================================================================
// 文件名：clock_mode.v
// 功能：顶层控制模块，负责模式切换、信号路由、数码管显示
//
// 模式定义（MODE状态机，2位）：
//   MODE_CLOCK（2'b00）：正常走时显示模式（上电默认）
//   MODE_LOAD （2'b01）：时间置数模式
//   MODE_ALARM（2'b10）：闹钟设置模式
//   MODE_BEEP （2'b11）：闹钟鸣响显示模式（进入条件是 beep_en=1，退出条件是 beep_en=0。在此状态下数码管显示鸣响闹钟的时间）
//
// 按键功能说明：
// ┌────────────────────────────────────────────────────────────────────────┐
// │  当前模式     │  操作                  │  效果                         │
// ├────────────────────────────────────────────────────────────────────────┤
// │  时钟模式     │  短按 load             │  进入置数模式                 │
// │  时钟模式     │  达到闹钟定时(自动触发)│  进入鸣响显示模式 MODE_BEEP   │
// ├────────────────────────────────────────────────────────────────────────┤
// │  置数模式     │  短按 load             │  进入闹钟模式的浏览闹钟界面   │
// │  置数模式     │  长按 load             │  确认置数，返回时钟模式       │
// │  置数模式     │  15s 无操作            │  超时，返回时钟模式(置数取消) │
// │  置数模式     │  短按 choose           │  （在 load_num 中）切换设置位 │
// │  置数模式     │  短按 num_up           │  （在 load_num 中）当前位+1   │
// │  置数模式     │  短按 num_down         │  （在 load_num 中）当前位-1   │
// ├────────────────────────────────────────────────────────────────────────┤
// │  闹钟模式     │  浏览闹钟界面短按 load │  返回时钟模式                 │
// │  闹钟模式     │  短按 choose           │  在不同闹钟之间进行浏览       │
// │  闹钟模式     │  长按 choose           │  编辑某一个闹钟               │
// │  闹钟模式     │  编辑闹钟界面长按 load │  确认该闹钟的时间             │
// │  闹钟模式     │  编辑闹钟界面短按 load │  取消设置闹钟，返回浏览闹钟   │
// ├────────────────────────────────────────────────────────────────────────┤
// │  鸣响显示模式 │  闹钟/乐曲停止（自动） │  返回时钟模式                 │
// │  鸣响显示模式 │  短按 choose/num_up/   │  手动停止闹钟，返回时钟模式   │
// │               │  num_down              │                               │
// └────────────────────────────────────────────────────────────────────────┘
// 注意：由于 LOAd 需显示1秒，故“15秒无操作返回”实际上在置数的数字编辑页面只能显示约14秒
// 总结：load键：短按在不同模式之间切换，长按确认，
//      所以短按load，是顶层信号；长按load，是子模块信号。前者是状态机的切换条件，后者是状态机内的控制信号！
//
// 注意事项：
//   1. clock 子模块始终在后台运行，
//      置数和闹钟模式不会暂停走时，退出后显示的是实际流逝后的时间。
//   2. 输出信号选择： 状态机控制 disp_second/disp_minute/disp_hour/disp_point 的来源，
//      两个子系统的显示输出通过 OR 门合并，同一时刻只有一路处于使能状态。
//   3. 三种模式在顶层共用一套seg_dynamic、hc595_ctrl模块，用状态机对模块输出的数字进行控制
//   4. 闹钟鸣响与显示控制
//      架构概览（握手信号流）：
//           ┌───────────→ disp_* <= beep_*
//           │
//         alarm.v ──alarm_ring_en──→ clock_mode.v ──beep_en──→ beep_song.v (驱动蜂鸣器)
//           ↑                                           │
//           └─────────────alarm_beep_disp_en────────────┘
//
//      时序流程：
//        a) alarm.v 每 1 秒检测所有使能闹钟。匹配时 alarm_ring_en 拉高 1 个 sec_clk 周期，
//           同时用 index_beep 记录是第几组闹钟触发了。
//        b) clock_mode 收到 alarm_ring_en → counter_beep 从 0 开始自增（pulse_1s 驱动）
//           → beep_en = if(counter_beep > 0) = 1
//           → 状态机 cs 从 MODE_CLOCK 切换到 MODE_BEEP（见三段式状态机第二段）
//        c) MODE_BEEP 状态下：
//           · clock_mode 拉高 alarm_beep_disp_en，并将 disp_* 的来源切换为 alarm.v 的输出
//           · beep_song.v 被 beep_en 使能，开始循环播放《起风了》或《your new home》乐曲
//           · alarm.v 收到 alarm_beep_disp_en → 以 1Hz 慢闪烁（1秒亮/1秒灭）
//             输出鸣响闹钟的时间到 disp_* 端口，供 seg_dynamic 扫描显示
//        d) 停止条件（二选一，任意满足即停止）：
//           ① counter_beep 计到 CNT_BEEP(90) → counter_beep 归零 → beep_en=0
//           ② 任意按键(choose/num_up/num_down)按下（button_now ≠ button_prev）
//              → counter_beep 归零 → beep_en=0
//           beep_en=0 后 cs 回到 MODE_CLOCK，alarm_beep_disp_en 拉低
//
//      设计理由：
//        · beep_song.v 是物理外设（蜂鸣器 PWM），放在顶层 clock_mode 中实例化更合逻辑；
//          若放在 alarm.v 中，alarm 将被迫管理蜂鸣器 pin 和 counter_beep 计时，
//          破坏 alarm.v 作为纯闹钟数据管理模块的职责单一性。
//        · 闹钟时间数据存储在 alarm.v 的 memory 中，鸣响时需 alarm 配合输出显示数据，
//          因此通过 alarm_beep_disp_en 握手信号请求 alarm 输出鸣响闹钟的时间。
//        · 这套"双向握手"虽然跨模块，但每个信号的职责是明确的：
//          alarm_ring_en = "我该响了"（事件通知），
//          alarm_beep_disp_en = "请告诉我哪个闹钟在响"（数据查询）。
//
// 状态机重构说明：
//   本版本已将状态机从一段式改为三段式：状态更新/状态切换/状态输出 三者分离
//
// 子模块实例：
//   my_pll_divider（IP核）、sys_divider、
//   btn_debounce ×4、 btn_duration ×2、
//   clock、load_num、alarm、beep_song、
//   seg_dynamic（6位8段数码管动态扫描）、hc595_ctrl（74HC595串行输出驱动）
// =============================================================================

// 踩坑总结
/* 【进制权移交】
 counter 的小时个位进制 radix_hour ，在"被置数"的瞬间必须交给"被装载的值"决定，而不是"计数器当前值"：
   · clock   ：置数时按 data_hour 判（而非 out_hour），load 延时一拍为 load_d 再给 counter；
   · load_num：进入置数页时按 before_hour 判（而非遗留的 load_hour），load_before 延时一拍为 load_before_d；
   · alarm   ：进入编辑时按 view_num 判（而非 edit_hour），用 choose_edit_delay 延时一拍。
 三处同源：置数瞬间，进制权要从旧值移交给新值，且时序上要先更新进制、后置数。
 */

module clock_mode               //时钟的顶层封装模块：模式调整
(
input   wire    sys_clk,        //全局时钟，50MHz
input   wire    rst_n_input,      //复位信号
input   wire    load,       //置数信号
input   wire    choose,
input   wire    num_up,
input   wire    num_down,

output  wire    beep,

output  wire    stcp,
output  wire    shcp,
output  wire    ds,  
output  wire    oe   
);


//  ====================  实例化PLL IP核  ====================
wire sys_clk_1mhz;
wire locked_sig;
// 系统时钟PLL输出1MHz
my_pll_divider	clock_mode_my_pll_divider (
	.areset ( 1'b0 ),      // 我的系统复位低有效，而PLL复位高有效，所以这里填0。另外， PLL 的复位不应受外部reset按键控制，其复位进上电时自动复位，故areset连接成无效。
	.inclk0 ( sys_clk ),
    
	.c0 ( sys_clk_1mhz ),
	.locked ( locked_sig )  // 系统全局复位“使能”，当PLL锁定之前，系统一直处于复位状态
	);
//  ====================  实例化复位同步器  ====================
// 与PLL输出的锁定信号连接
wire    rst_n;
reset_sync clock_mode_reset_sync
(
    .sys_clk    (sys_clk),     
    .key_rst_n  (rst_n_input),   
    .pll_locked (locked_sig),  
    
    .sys_rst_n  (rst_n)
);




//  ====================  实例化系统分频器  ====================
// 对PLL得到的1MHz信号进行同步到系统时钟域sys_clk；分频处理
wire pulse_1ms;
wire pulse_1s;
wire sec_clk;
sys_divider clock_mode_sys_divider
(
    .sys_clk  (sys_clk      ),
    .pre_clk  (sys_clk_1mhz ),
    .rst_n    (rst_n        ),
    
    .pulse_1ms(pulse_1ms    ),
    .pulse_1s (pulse_1s     ),   // → clock-counter的使能时钟
    .sec_clk  (sec_clk      )    // → clock里小数点和load_num置数和显示load几个字时用

);




//  ====================  实例化按键消抖、按键消抖长短按模块  ====================
// 按键消抖
// 注意！！改变消抖时间，修改实例化时的参数即可，无需关心内部计数
wire    choose_db;
wire    num_up_db;
wire    num_down_db; 
wire    load_db;
// 按键消抖模块接口已改为pulse_1ms计数，参数单位为ms
btn_debounce #(.DEBOUNCE_MS(20))
    // DEBOUNCE_MS不可设为1ms，否则在模块内部DEBOUNCE_CNT_MAX会变成0，导致1.消抖逻辑失效；2.debounce_counter的位宽会变成[-1,0]，被系统解析为1bit
    clock_mode_btn_debounce_choose   (sys_clk, pulse_1ms, rst_n, choose, choose_db),    // 这个 choose 是对 load_num 产生的，只有短按判定。
    clock_mode_btn_debounce_num_up   (sys_clk, pulse_1ms, rst_n, num_up, num_up_db),
    clock_mode_btn_debounce_num_down (sys_clk, pulse_1ms, rst_n, num_down, num_down_db),
    clock_mode_btn_debounce_load     (sys_clk, pulse_1ms, rst_n, load, load_db);
// choose_db num_up_db num_down_db 脉冲产生
reg choose_pulse = 1'b1;    // 这个 choose 信号专供 load_num, 因为该模块的 choose 没有长短按需求，
reg num_up_pulse = 1'b1;                                    //直接用 choose_db 产生脉冲，用户使用体验比用 load_short_pulse 更好
reg num_down_pulse = 1'b1;
//采用跳沿检测，采集到下跳沿即产生脉冲
reg choose_prev = 1'b1;
reg num_up_prev = 1'b1;
reg num_down_prev = 1'b1;
always@(posedge sys_clk)    choose_prev <= choose_db;
always@(posedge sys_clk)    num_up_prev <= num_up_db;
always@(posedge sys_clk)    num_down_prev  <= num_down_db;
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                 choose_pulse <= 1'b1;
    else if(choose_prev==1'b1 & choose_db==1'b0)    choose_pulse <= 1'b0;
    else                                            choose_pulse <= 1'b1;
end
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                 num_up_pulse <= 1'b1;
    else if(num_up_prev==1'b1 & num_up_db==1'b0)    num_up_pulse <= 1'b0;
    else                                            num_up_pulse <= 1'b1;
end
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                 num_down_pulse <= 1'b1;
    else if(num_down_prev==1'b1 & num_down_db==1'b0)num_down_pulse <= 1'b0;
    else                                            num_down_pulse <= 1'b1;
end

// 短按检测（小于500ms）+长按3秒检测  
wire    load_short;
wire    load_long;
// 按键消抖+长短按模块接口已改为pulse_1ms计数，LONG_PRESS_MS单位为ms
btn_duration #(.SHORT_END_MS(500), .LONG_PRESS_MS(3000))
clock_mode_btn_duration_load    
(
    .sys_clk        (sys_clk),    
    .pre_clk        (sys_clk_1mhz),  
    .rst_n          (rst_n),      
    .button_in      (load_db),  
    
    .short_press    (load_short),
    .long_press     (load_long) 
);
// 长短按 load 脉冲         
reg     load_short_pulse;
reg     load_long_pulse;
// 记录上次长短按信号，以便产生脉冲
reg    load_short_prev;
reg    load_long_prev;
// 长短按 load 脉冲产生                    
always@(posedge sys_clk)    load_short_prev <= load_short;
always@(posedge sys_clk)    load_long_prev  <= load_long;
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                     load_short_pulse <= 1'b1;
    else if(load_short_prev==1'b1 & load_short==1'b0)   load_short_pulse <= 1'b0;
    else                                                load_short_pulse <= 1'b1;
end
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                     load_long_pulse <= 1'b1;
    else if(load_long_prev==1'b1 & load_long==1'b0)     load_long_pulse <= 1'b0;
    else                                                load_long_pulse <= 1'b1;
end
// alarm 专供的 choose
wire    choose_short;
wire    choose_long;
btn_duration #(.SHORT_END_MS(500), .LONG_PRESS_MS(3000))
clock_mode_btn_duration_choose    
(
    .sys_clk        (sys_clk),    
    .pre_clk        (sys_clk_1mhz),  
    .rst_n          (rst_n),      
    .button_in      (choose_db),  
    
    .short_press    (choose_short),
    .long_press     (choose_long) 
);
//将 choose 的两个信号转化成脉宽等于系统时钟的脉冲
reg choose_short_pulse = 1'b1;
reg choose_long_pulse = 1'b1;
//采用跳沿检测，采集到下跳沿即产生脉冲
reg choose_short_prev = 1'b1;
reg choose_long_prev = 1'b1;
always@(posedge sys_clk)    choose_short_prev <= choose_short;
always@(posedge sys_clk)    choose_long_prev  <= choose_long;
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                         choose_short_pulse <= 1'b1;
    else if(choose_short_prev==1'b1 & choose_short==1'b0)   choose_short_pulse <= 1'b0;
    else                                                    choose_short_pulse <= 1'b1;
end
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                         choose_long_pulse <= 1'b1;
    else if(choose_long_prev==1'b1 & choose_long==1'b0)     choose_long_pulse <= 1'b0;
    else                                                    choose_long_pulse <= 1'b1;
end




//  ====================  clock_mode顶层状态机  ====================
/*
模式选择模块的控制模块：不同的按压方式对应不同的选择，具体如下：

对于置数模式：
非置数模式，reset为低电平（复位模式），时钟信号均置零，choose、num_up、num_down均置一，其余三个输入不做处理
置数模式下，load_num模块的load信号为低电平，
  使用者确认置数正确后，长按确认，此处设置代码识别“长按”，然后将load_num模块的load信号拉高，一个系统时钟后再拉低（即一个脉冲）
  系统模式切换回CLOCK（非置数模式）
*/

// 对状态进行选择 单按load选择时钟、置数、闹钟模式，长按确认置数、闹钟的输入

// 置数模式、闹钟模式使能信号，时钟模式不需要
reg mode_load_en = 1'b0;
reg mode_alarm_en = 1'b0;
// 对不同模式的输入输出进行控制
// 输入控制
// 时钟模式
// 不论前面发现的bug：load_num中，data_hour等的更新与clock-counter加载置数值在同一个时钟沿，在同步时钟下，counter读到的是沿前值，所以要对load_clock延时一个周期
// 还是后来发现的bug：即使在 clock 模式下，长按 load 也会发生置数，问题就在于 load_long_pulse 信号在任何状态均生效！
// 都是因为没有将长按load的信号放进状态机！
// 短按load，是顶层信号；长按load，是子模块信号。
reg     load_clock;
// 置数模式
reg     choose_load_num  ;
reg     num_up_load_num  ;
reg     num_down_load_num;
// 闹钟模式
reg     choose_alarm;
reg     choose_edit_alarm;
reg     num_up_alarm;
reg     num_down_alarm;
reg     load_confirm_alarm;
reg     load_alarm;


// 输出控制  
// 时钟模式
wire    [7:0]   disp_second_clock;
wire    [7:0]   disp_minute_clock;
wire    [7:0]   disp_hour_clock  ;
wire    [5:0]   disp_point_clock ; 
// 置数模式
wire    [7:0]   disp_second_num;
wire    [7:0]   disp_minute_num;
wire    [7:0]   disp_hour_num  ;
wire    [5:0]   disp_point_num ; 
// 闹钟模式
wire    [7:0]   disp_second_alarm;
wire    [7:0]   disp_minute_alarm;
wire    [7:0]   disp_hour_alarm  ;
wire    [5:0]   disp_point_alarm ;


// 向seg_dynamic汇总输出时分秒数字
reg     [7:0]   disp_second;
reg     [7:0]   disp_minute;
reg     [7:0]   disp_hour  ;
reg     [5:0]   disp_point ;
reg     disp_point_twinkle_en;  // 小数点闪烁使能信号


//模式选择模块
//定义状态机状态
localparam  MODE_CLOCK = 2'b00;
localparam  MODE_LOAD  = 2'b01;
localparam  MODE_ALARM = 2'b10;
localparam  MODE_BEEP  = 2'b11;
//定义状态机
reg [1:0]   cs, ns;


// load_num、alarm模式：若15秒内无按键输入，自动切换回clock模式
// 由于 LOAd 的显示，实际在置数页面只能显示约14秒
parameter COUNTER_15S_TIME = 15;     // 超时时间15秒
reg [$clog2(COUNTER_15S_TIME)-1:0]  counter_15s = 0;
localparam COUNTER_15S_COUNT = COUNTER_15S_TIME;      // 15秒计数值
// ⚠ 踩坑警示：这里时间=走过的间隔数=计数值，值域0~15含16个状态但只递增15次=15秒；
// 计数器counter的0是有效状态，循环一圈(0→9→0)才算满，此处0只是起点不占时间，故COUNT=TIME=15，不是"16个数"。

// 采用跳沿检测按键输入变化
// 之前，将 choose num_up/down 变成脉冲的任务在 alarm load_num 中，现已移交至顶层。
// 所以就有了 plan B ：可以用 button_now 表示拼接后的 choose num_up/down 脉冲，然后用 缩位与 运算——
// 缩位与后，只要 button_now 里有0（按键被按下），运算结果就是0，进而判断是否有按键按下。
// 但是这样有一个问题: plan A 中，使用的是消抖后的信号，无论用户按下还是抬起按键，都算是按键状态改变
// plan B 中，对于 num_up/down ，用户只有按下的一刻会产生脉冲，抬起时不产生，所以抬起不算按键状态改变
// 我更倾向于 plan A, 所以就不做更改了
reg [2:0]   button_prev=3'b111;      //记录输入信号之前的值（num_up、num_down、choose），按系统时钟更新
wire[2:0]   button_now;
assign      button_now={choose_db,num_up_db,num_down_db};//现在的值，实时更新
always@(posedge sys_clk) button_prev <= {choose_db,num_up_db,num_down_db};
//检测按键变化的功能在后面也有作用：用于将闹钟关掉

// alarm 在 ALARM_VIEW 状态下，短按 load ，才切换回时钟模式
wire    alarm_view_en;
// beep_song 闹钟鸣响使能信号，先行声明
reg     beep_en;
// MODE_BEEP 状态下，让 alarm 显示当前鸣响的闹钟的时间
reg     alarm_beep_disp_en;

//状态机

// 状态更新
always@(posedge sys_clk) begin
    if(~rst_n)
        cs <= MODE_CLOCK;
    else
        cs <= ns;
end

// 状态切换
always@(*)
begin
    case(cs)
    MODE_CLOCK: begin
        if(~load_short_pulse)
            ns = MODE_LOAD;
        else if(beep_en)  // 仅在clock模式下，出现闹钟使能信号后，才会切换到 MODE_BEEP 的显示
            ns = MODE_BEEP;
        else 
            ns = MODE_CLOCK;
    end
        
    MODE_LOAD: begin
        if(load_short_pulse==1'b0&&load_long_pulse==1'b1)      //load短按，切换为闹钟模式
            ns = MODE_ALARM;
        else if(load_short_pulse==1'b1&&load_long_pulse==1'b0) //load长按确认置数，之后切换为时钟模式
            ns = MODE_CLOCK;
        // 15秒无按键输入即返回clock，计时逻辑在第三段状态机里
        else if(button_now == button_prev && counter_15s >= COUNTER_15S_COUNT)
            ns = MODE_CLOCK;
        else
            ns = MODE_LOAD;
    end
        
    MODE_ALARM: begin
        if(alarm_view_en && load_short_pulse==1'b0)    // alarm 在 ALARM_VIEW 状态下，短按 load ，才切换回时钟模式
            ns = MODE_CLOCK;
        else
            ns = MODE_ALARM;
    end
    
    MODE_BEEP: begin
        if(~beep_en)
            ns = MODE_CLOCK;
        else if(beep_en)
            ns = MODE_BEEP;
        else
            ns = MODE_CLOCK;
    end

    default:ns = MODE_CLOCK;
    
    endcase
end

// 状态输出
always@(posedge sys_clk)
begin
    if(!rst_n)begin
        // 使能控制
        mode_load_en <= 1'b0;
        mode_alarm_en <= 1'b0;
        // 输入控制
        load_clock       <= 1'b1;
        choose_load_num  <= 1'b1;
        num_up_load_num  <= 1'b1;
        num_down_load_num<= 1'b1;
        choose_alarm     <= 1'b1;
        choose_edit_alarm<= 1'b1;
        num_up_alarm     <= 1'b1;
        num_down_alarm   <= 1'b1;
        load_confirm_alarm<= 1'b1;
        load_alarm        <= 1'b1;
        // 输出控制
        disp_second <= disp_second_clock;
        disp_minute <= disp_minute_clock;
        disp_hour   <= disp_hour_clock  ;
        disp_point  <= disp_point_clock ; 
        disp_point_twinkle_en <= 1'b1;
        alarm_beep_disp_en    <= 1'b0;
    end
    else begin
        case(cs)
        MODE_CLOCK:
        begin
            // 使能控制
            mode_load_en <= 1'b0;
            mode_alarm_en <= 1'b0;
            // 输入控制 load
            load_clock       <= 1'b1;
            choose_load_num  <= 1'b1;
            num_up_load_num  <= 1'b1;
            num_down_load_num<= 1'b1;
            // 输入控制 alarm
            choose_alarm     <= 1'b1;
            choose_edit_alarm<= 1'b1;
            num_up_alarm     <= 1'b1;
            num_down_alarm   <= 1'b1;
            load_confirm_alarm<= 1'b1;
            load_alarm        <= 1'b1;
            // 输出控制
            disp_second <= disp_second_clock;
            disp_minute <= disp_minute_clock;
            disp_hour   <= disp_hour_clock  ;
            disp_point  <= disp_point_clock ;
            disp_point_twinkle_en <= 1'b1;
            alarm_beep_disp_en    <= 1'b0;
        end
        
        MODE_LOAD:
        begin
            // 使能控制
            mode_load_en <= 1'b1;
            mode_alarm_en <= 1'b0;
            // 输入控制 load
            load_clock       <= load_long_pulse;
            choose_load_num  <= choose_pulse;
            num_up_load_num  <= num_up_pulse;
            num_down_load_num<= num_down_pulse;
            // 输入控制 alarm
            choose_alarm     <= 1'b1;
            choose_edit_alarm<= 1'b1;
            num_up_alarm     <= 1'b1;
            num_down_alarm   <= 1'b1;
            load_confirm_alarm<= 1'b1;
            load_alarm        <= 1'b1;
            //输出控制
            disp_second <= disp_second_num;
            disp_minute <= disp_minute_num;
            disp_hour   <= disp_hour_num  ;
            disp_point  <= disp_point_num ;
            disp_point_twinkle_en <= 1'b1;
            alarm_beep_disp_en    <= 1'b0;
            
            
            if(load_short_pulse==1'b0&&load_long_pulse==1'b1)//load短按，切换为闹钟模式，停止计时
                counter_15s <= 0;
            else if(load_short_pulse==1'b1&&load_long_pulse==1'b0)//load长按确认置数，之后切换为时钟模式，停止计时
                counter_15s <= 0;

            // 计时15秒无按键输入（检测load之外的按键）即返回clock
            else if(button_now != button_prev)       
                counter_15s <= 0;           
            else if(button_now == button_prev && counter_15s < COUNTER_15S_COUNT)begin
                if (pulse_1s) counter_15s <= counter_15s + 1'b1;
            end // 这里的begin-end必须加，否则下一行的else就会匹配if(pulse_1s)而不会匹配正确的if
            else if(button_now == button_prev && counter_15s >= COUNTER_15S_COUNT)
                counter_15s <= 0;
            else
                counter_15s <= counter_15s;
        
        end
        
        MODE_ALARM:
        begin
            // 使能控制
            mode_load_en <= 1'b0;
            mode_alarm_en <= 1'b1;
            // 输入控制 load
            load_clock       <= 1'b1;
            choose_load_num  <= 1'b1;
            num_up_load_num  <= 1'b1;
            num_down_load_num<= 1'b1;
            // 输入控制 alarm
            choose_alarm     <= choose_short_pulse;
            choose_edit_alarm<= choose_long_pulse;
            num_up_alarm     <= num_up_pulse;
            num_down_alarm   <= num_down_pulse;
            load_confirm_alarm<= load_long_pulse;
            load_alarm        <= load_short_pulse;
            //输出控制
            disp_second <= disp_second_alarm;
            disp_minute <= disp_minute_alarm;
            disp_hour   <= disp_hour_alarm  ;
            disp_point  <= disp_point_alarm ;
            disp_point_twinkle_en <= 1'b0;
            alarm_beep_disp_en    <= 1'b0;
        end
        
        MODE_BEEP:
        begin
            // 使能控制
            mode_load_en <= 1'b0;
            mode_alarm_en <= 1'b0;
            // 输入控制 load
            load_clock       <= 1'b1;
            choose_load_num  <= 1'b1;
            num_up_load_num  <= 1'b1;
            num_down_load_num<= 1'b1;
            // 输入控制 alarm
            choose_alarm     <= 1'b1;
            choose_edit_alarm<= 1'b1;
            num_up_alarm     <= 1'b1;
            num_down_alarm   <= 1'b1;
            load_confirm_alarm<= 1'b1;
            load_alarm        <= 1'b1;
            //输出控制
            disp_second <= disp_second_alarm;
            disp_minute <= disp_minute_alarm;
            disp_hour   <= disp_hour_alarm  ;
            disp_point  <= disp_point_alarm ;
            disp_point_twinkle_en <= 1'b0;
            alarm_beep_disp_en    <= 1'b1;  // 让 alarm 显示当前鸣响的闹钟的时间
        end
            
        default:    //default：时钟模式
        begin
            // 使能控制
            mode_load_en <= 1'b0;
            mode_alarm_en <= 1'b0;
            // 输入控制 load
            load_clock       <= 1'b1;
            choose_load_num  <= 1'b1;
            num_up_load_num  <= 1'b1;
            num_down_load_num<= 1'b1;
            // 输入控制 alarm
            choose_alarm     <= 1'b1;
            choose_edit_alarm<= 1'b1;
            num_up_alarm     <= 1'b1;
            num_down_alarm   <= 1'b1;
            load_confirm_alarm<= 1'b1;
            load_alarm        <= 1'b1;
            // 输出控制
            disp_second <= disp_second_clock;
            disp_minute <= disp_minute_clock;
            disp_hour   <= disp_hour_clock  ;
            disp_point  <= disp_point_clock ;
            disp_point_twinkle_en <= 1'b1;
            alarm_beep_disp_en    <= 1'b0;
        end 

        endcase
    end
end






//  ====================  clock、load_num、alarm三大模块及鸣响beep_song模块实例化  ====================
//时钟模式实例化
wire    [7:0]   data_second;
wire    [7:0]   data_minute;   
wire    [7:0]   data_hour;   
clock   clock_mode_clock
(
    .sys_clk    (sys_clk    ),
    .sec_pulse  (pulse_1s   ),  
    .rst_n      (rst_n      ), 
    .load       (load_clock ),  
    .data_second(data_second),    
    .data_minute(data_minute),    
    .data_hour  (data_hour  ),    
    
    .out_second (disp_second_clock),
    .out_minute (disp_minute_clock),
    .out_hour   (disp_hour_clock  ),
    .point_out  (disp_point_clock )
);


//置数模式
/* 注意：不可以将 load_confirm 信号加入状态机进行控制！ load_long_pulse 必须直接连接 load_confirm 
因为在 load_num 末尾，data_* 在 load_confirm 即 load_long_pulse 下降沿更新（被 load_* 赋值）
load_clock 经状态机，也是在 load_long_pulse 下降沿更新，故二者同拍更新
下一拍， clock 就能因 load_clock 的低电平而读取已更新的 data_* ，读取正确。
一旦输入 load_confirm 的信号进入状态机， data_* 更新的时间就比 load_clock 晚一拍，
clock 读取到旧值，时钟数据紊乱！
*/
load_num    clock_mode_load_num
(
    .mode_en        (mode_load_en),
    .sys_clk        (sys_clk   ),
    .sec_clk        (sec_clk   ),
    .rst_n          (rst_n     ),
    .load_confirm   (load_long_pulse ),       // 直接连接 load_long_pulse !!! 原因见上
    .choose         (choose_load_num  ),
    .num_up         (num_up_load_num  ),
    .num_down       (num_down_load_num),
    .before_second  (disp_second_clock),
    .before_minute  (disp_minute_clock),
    .before_hour    (disp_hour_clock  ),
    // .point_out      (point_out    ),     // 小数点输出在load_num 内部被固定，故不需要输入值，但还是留下接口

    .data_second    (data_second  ),
    .data_minute    (data_minute  ),
    .data_hour      (data_hour    ),
    .disp_second    (disp_second_num),
    .disp_minute    (disp_minute_num),
    .disp_hour      (disp_hour_num  ),
    .point_out      (disp_point_num)
);

//闹钟模式实例化
// alarm 模块输出：闹钟该响了的脉冲使能信号
wire    alarm_ring_en;
alarm       clock_mode_alarm
(
    .mode_en        (mode_alarm_en      ),
    .sys_clk        (sys_clk            ),
    .sec_clk        (sec_clk            ),      
    .rst_n          (rst_n              ),
    .load           (load_alarm         ),         
    .load_confirm   (load_confirm_alarm ), 
    .choose         (choose_alarm       ),
    .choose_edit    (choose_edit_alarm  ),  
    .num_up         (num_up_alarm       ),
    .num_down       (num_down_alarm     ),
    .now_second     (disp_second_clock  ),
    .now_minute     (disp_minute_clock  ),
    .now_hour       (disp_hour_clock    ),
    .alarm_beep_disp_en(alarm_beep_disp_en),

    .disp_state     (disp_hour_alarm    ),   
    .disp_hour      (disp_minute_alarm  ),    
    .disp_minute    (disp_second_alarm  ),  
    .point_out      (disp_point_alarm   ),
    .alarm_view_en  (alarm_view_en      ),  
    .alarm_ring_en  (alarm_ring_en      )
);

// beep_en 使能信号在状态机前声明
parameter   CNT_BEEP = 7'd90;   // 闹钟响90秒
reg [$clog2(CNT_BEEP)-1:0]   counter_beep;
always@(posedge sys_clk)
begin
    if(!rst_n)
        counter_beep <= 0;
    else if(button_now != button_prev)  // 按任意按键暂停闹钟
        counter_beep <= 0;
    else if(pulse_1s && alarm_ring_en)
        counter_beep <= counter_beep + 1'b1;
    else if(pulse_1s && (counter_beep == CNT_BEEP) )
        counter_beep <= 0;
    else if(pulse_1s && counter_beep > 0)
        counter_beep <= counter_beep + 1'b1;
end
always@(counter_beep or beep_en)
begin
    if(counter_beep > 0)
        beep_en = 1'b1;
    else
        beep_en = 1'b0;
end

beep_song clock_mode_beep_song
(
    .sys_clk    (sys_clk),
    .rst_n      (rst_n),
    .beep_en    (beep_en),

    .beep       (beep)
);



//  ====================  seg_dynamic、hc595_ctrl实例化  ====================             
wire    [5:0]   sel;                          
wire    [7:0]   seg;
//数码管动态显示模块
seg_dynamic     clock_mode_seg_dynamic
(
   .sys_clk            (sys_clk   ),
   .pulse_1ms          (pulse_1ms ),   
   .sec_clk            (sec_clk   ), 
   .rst_n              (rst_n     ),
   .out_second         (disp_second),
   .out_minute         (disp_minute),
   .out_hour           (disp_hour  ),
   .point_out          (disp_point ),
   .point_out_twinkle_en(disp_point_twinkle_en),

   .sel                (sel       ),  
   .seg                (seg       )   
);  

//74HC595控制模块
hc595_ctrl      clock_mode_hc595_ctrl
(
   .sys_clk            (sys_clk),
   .rst_n              (rst_n  ),
   .sel                (sel    ),
   .seg                (seg    ),

   .stcp               (stcp   ),           
   .shcp               (shcp   ),           
   .ds                 (ds     ),             
   .oe                 (oe     )
);

endmodule