// =============================================================================
// 文件名：alarm.v
// 功能：闹钟浏览、编辑与时间匹配模块，默认为4个闹钟，最多可设置10个，可在顶层 clock_mode 中设置
//
// 工作流程：
//   1. 由 clock_mode 的 mode_alarm_en 使能后进入工作状态
//   2. 默认为 ALARM_VIEW 浏览状态，通过 choose 短按切换浏览闹钟编号
//      显示格式：{闹钟编号, E/d(使能状态), hour, minute} → seg_dynamic
//   3. 在浏览状态下长按 choose（ choose_edit 脉冲有效），进入 ALARM_EDIT 编辑状态
//      编辑状态下先选中使能状态（可翻转），再选 hour，再选 minute
//   4. 编辑完成后长按 load （ load_confirm ）将编辑值写入对应闹钟 alarm_mem
//      短按 load 取消编辑，返回浏览状态
//   5. 时间匹配：每 1 秒（ pulse_1s 高电平脉冲）检测所有使能闹钟是否匹配当前时间，
//      匹配时拉高 alarm_ring_en （维持1秒），由 clock_mode 触发蜂鸣器
//   6. 鸣响显示：当 clock_mode 拉高 alarm_beep_disp_en 时，
//      本模块通过 beep_idx 找到正在鸣响的闹钟，
//      将其时间以 0.5Hz 慢闪烁（1秒亮/1秒灭）输出到 disp_* 端口，
//      供顶层的 seg_dynamic 扫描显示。此时 mode_en = 0，显示由 alarm_beep_disp_en 接管。
//
// 内部状态机：
//   ① current_alarm ：ALARM_VIEW / ALARM_EDIT 数码管显示控制
//   ② current_set ：SET_STATE → SET_HOUR → SET_MINUTE 编辑字段选择、计数脉冲产生
//   ③ twinkle ：TWINKLE_STATE / TWINKLE_HOUR / TWINKLE_MINUTE 闪烁显示控制
//
// 显示输出（ disp_state / disp_hour / disp_minute / point_out ）的三路选择：
//   · ALARM_VIEW 模式（ mode_en=1 ）：输出当前浏览闹钟的编号+使能状态+时间
//   · ALARM_EDIT 模式（ mode_en=1 ）：输出编辑中的值（含选中位闪烁）
//   · 鸣响显示模式（ mode_en=0, alarm_beep_disp_en=1）：输出 beep_idx 所指闹钟的时间（以 sec_clk_div 二分频实现1秒亮/1秒灭慢闪烁，其余位全灭）
//   · 未使能（ mode_en=0, alarm_beep_disp_en=0）：输出 8'hFF（负号--，在 seg_dynamic中被其他模块的输出覆盖，不可见）
//
// 子模块实例：
//   counter ×4（分别编辑 hour 个位/十位、minute 个位/十位）
//
// 注意：
//   1. alarm_ring_en 的拉高(使能) 和 拉低(不使能) 分支在同一时钟沿判断, 拉低 分支读到的是沿前的信号值：
//      当沿后信号使能, 拉低 分支读到沿前的信号（低电平），故不进行 拉低 ;下一时钟周期, 拉低 分支才读到上一时钟周期的高电平信号，将信号拉低
//      所以 alarm_ring_en 被拉高后，到下一次 pulse_1s_d 才被拉低，高电平维持 1 秒
//   2. choose_edit_delay 延时一拍，确保 counter 读到由 view_num 计算得到的
//      动态进制值，避免加载 FF 后立即被 counter 修正为 23
//   3. 小时加/减双方向变进制逻辑与 load_num 中一致（24小时制）
//   4. ALARM_VIEW 下 alarm_view_en=1, clock_mode 据此响应短按 load 是否返回时钟模式
//   5. beep_idx 在时间匹配循环中被赋值（记录触发闹钟编号），在鸣响显示模式下用于从 alarm_mem 读取正确的闹钟时间进行闪烁显示
//   6. sec_clk_div 是 sec_clk 的二分频信号（跳沿检测产生），实现鸣响显示时的 0.5Hz 慢闪烁（比编辑模式的 sec_clk 直接闪烁慢一半）
// =============================================================================
module alarm #(
parameter  ALARM_CNT = 4
)
(
input   wire    mode_en,
input   wire    sys_clk,
input   wire    sec_clk,                // 1Hz时钟，用于控制 ALARM_EDIT 状态下，被选中的数位闪烁的逻辑
input   wire    pulse_1s,               // 1秒脉冲，每秒判断一次闹钟是否到达时间
input   wire    rst_n,
input   wire    load,                   // 短按load，用于取消对某个闹钟的设置，在顶层与 load_short_pulse 相连接
input   wire    load_confirm,           // 长按load，用于确认对某个闹钟的设置，在顶层与 load_long_pulse 相连接
input   wire    choose,
input   wire    choose_edit,            // 长按choose，进入对某一个闹钟进行编辑的状态 --- 在 clock_mode 中已变成脉冲
input   wire    num_up,
input   wire    num_down,
input   wire    [7:0]   now_second,
input   wire    [7:0]   now_minute,
input   wire    [7:0]   now_hour,
input   wire    alarm_beep_disp_en,

output  wire    [7:0]   disp_state,     // 闹钟编号 + E/d (是否使能)
output  wire    [7:0]   disp_hour,      // 闹钟的 hour 显示
output  wire    [7:0]   disp_minute,    // 闹钟的 minute 显示
output  wire    [5:0]   point_out,      // 既然是要控制数码管的显示，那就得加上小数点了
output  wire    alarm_view_en,          // 闹钟的状态在 ALARM_VIEW, 短按 load 可以返回时钟模式；在 ALARM_EDIT, 短按 load 无法切换
output  reg     alarm_ring_en           // 到了闹钟的时间，拉高信号给顶层的 beep_song, 响铃
);

//  ====================  数码管显示控制状态机  ====================
//定义数码管显示状态机的状态
localparam  ALARM_VIEW = 1'b0;  // VIEW 浏览状态
localparam  ALARM_EDIT = 1'b1;  // EDIT 编辑状态
//定义数码管显示状态机
reg current_alarm;
//定义浏览状态使能信号、置数使能信号
reg view_en;
reg set_en;
//将 view_en 输出，在顶层 clock_mode 里用作切换回 clock 模式的使能
assign alarm_view_en = view_en;
//定义闹钟界面的字母显示
localparam  SHOW_EMPTY   = 4'd14; // 全灭
localparam  SHOW_DEFAULT = 4'd15; // 默认闹钟的时间是“负号-”
localparam  SHOW_d       = 4'd12; // d，表示闹钟未使能
localparam  SHOW_E       = 4'd13; // E，表示闹钟使能了
//状态机，控制数码管的显示
always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        view_en <= 1'b0;
        set_en <= 1'b0;
        current_alarm <= ALARM_VIEW;
    end
    else begin 
        case(current_alarm)
        ALARM_VIEW:
        begin
            if(~choose_edit) begin  // clock_mode 中变成脉冲
                view_en <= 1'b0;
                set_en <= 1'b1;
                current_alarm <= ALARM_EDIT;
            end
            else begin
                view_en <= 1'b1;
                set_en <= 1'b0;
                current_alarm <= ALARM_VIEW;  //维持当前状态
            end
        end
        ALARM_EDIT:
        begin
            if(~load || ~load_confirm) begin
                view_en <= 1'b1;
                set_en <= 1'b0;
                current_alarm <= ALARM_VIEW;
            end
            else begin
                view_en <= 1'b0;
                set_en <= 1'b1;
                current_alarm <= ALARM_EDIT;   //维持当前状态 
            end
        end        
        default:
        begin 
            view_en <= 1'b1;
            set_en <= 1'b0;          
            current_alarm <= ALARM_VIEW;             
        end
   
        endcase
    end
end

// ALARM_VIEW 状态下浏览不同alarm
// RAM 建模
reg [16:0] alarm_mem [0:ALARM_CNT-1'b1];// 最多有10个可设置闹钟，地址位宽最大为4；RAM一共用17位，第一位表示是否使能，后16位为4个BCD编码表示要设置的小时、分钟，秒默认为0，后面把这个写死。
reg [$clog2(ALARM_CNT)-1:0]  alarm_num; // 闹钟的编号，也是地址线。
// ALARM_VIEW 状态下的显示
// 闹钟时间
reg [15:0]  view_num;   // 用于暂存被选中的地址下的闹钟时间,只是为了表示起来方便
always@(posedge sys_clk)begin
    if(!rst_n) begin
        alarm_num <= 2'b00;
        view_num <= {SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT};
    end
    else if(view_en) begin
        view_num <= alarm_mem[alarm_num][15:0];
        if(~choose && (alarm_num==ALARM_CNT-1))
            alarm_num <= 0;
        else if(~choose)
            alarm_num <= alarm_num + 1'b1;
        else
            alarm_num <= alarm_num;
    end
end
// 是否使能
function [3:0] alarm_state_show;
input memory_alarm_state;
begin
    if(memory_alarm_state)
        alarm_state_show = SHOW_E;
    else if(!memory_alarm_state)
        alarm_state_show = SHOW_d;
    else
        alarm_state_show = SHOW_DEFAULT;
end
endfunction






//  ====================  时分秒计数脉冲状态机  ====================

// 数字闪烁状态机变量证明，该状态机在“实例化 counter ”的下面
// 没错，这不是此状态机的变量声明，而是下一个与本状态机配合的状态机的声明！！
reg [1:0]   twinkle;
localparam  TWINKLE_STATE  = 2'b00;
localparam  TWINKLE_HOUR   = 2'b01;
localparam  TWINKLE_MINUTE = 2'b10;

//定义时分秒计数脉冲状态机的状态
localparam  SET_STATE  = 2'b00;
localparam  SET_HOUR = 2'b01;
localparam  SET_MINUTE = 2'b10;
//定义时分秒计数脉冲状态机
reg [1:0]   current_set;
//定义时分秒计数信号脉冲
reg hour_pulse;
reg min_pulse;
//定义闹钟状态——闹钟是否使能（开启）
reg edit_state;

//状态机-时分秒计数脉冲产生
always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        edit_state <= 1'b0; // 复位时, alarm_mem 中的闹钟是未使能的，所以这里就赋 1'b0
        hour_pulse <= 1'b0;
        min_pulse <= 1'b0;      
        twinkle <= TWINKLE_STATE;
        current_set <= SET_STATE;
    end
    else begin
        if(set_en) begin               // 使能状态机的使能信号
            case(current_set)
            SET_STATE:
            begin
                hour_pulse <= 1'b0;
                min_pulse <= 1'b0;
                twinkle <= TWINKLE_STATE;    // 用于控制该数位闪烁
                if((~num_up) || (~num_down))
                    edit_state <= ~edit_state;
                    
                // 状态切换
                if(~choose) current_set <= SET_HOUR;    // choose 低有效
                else        current_set <= SET_STATE;
            end
            SET_HOUR:
            begin
                edit_state <= edit_state;
                min_pulse <= 1'b0;
                twinkle <= TWINKLE_HOUR;    // 用于控制该数位闪烁 
                if((~num_up) || (~num_down))
                    hour_pulse <= 1'b1;
                else
                    hour_pulse <= 1'b0;
                    
                // 状态切换    
                if(~choose) current_set <= SET_MINUTE;
                else        current_set <= SET_HOUR;
            end        
            SET_MINUTE:
            begin
                edit_state <= edit_state;
                hour_pulse <= 1'b0;
                twinkle <= TWINKLE_MINUTE;    // 用于控制该数位闪烁
                if((~num_up) || (~num_down))
                    min_pulse <= 1'b1;
                else
                    min_pulse <= 1'b0;
        
                // 状态切换
                if(~choose) current_set <= SET_STATE;
                else        current_set <= SET_MINUTE;
            end        
            default: 
            begin
                edit_state <= alarm_mem[alarm_num][16];
                hour_pulse <= 1'b0;    
                min_pulse <= 1'b0;
                twinkle <= TWINKLE_STATE;
                current_set <= SET_STATE;
            end
            endcase
        end
        else begin
            edit_state <= alarm_mem[alarm_num][16];// set_en 不使能时就将闹钟状态赋值给 edit_state
            hour_pulse <= 1'b0;    
            min_pulse <= 1'b0;
            twinkle <= TWINKLE_STATE;
            current_set <= SET_STATE;// set_en 不使能时就切换到 SET_STATE, 每次 set_en 使能进入 ALARM_EDIT, 就默认选择 SET_STATE
       end
    end
end





//  ====================  六次实例化 counter,并设计加减计数的小时个位进制动态显示  ====================

// 用延时信号置数，是因为要让 counter 读到 由 view_num 判断得到的 进制
reg choose_edit_delay = 1'b1;
always@(posedge sys_clk)  choose_edit_delay <= choose_edit;
//定义进位信号中间值
wire    [3:0]   RCO;
//定义置数中间值
wire [7:0]   edit_hour;     // counter 模块直接输出的值
wire [7:0]   edit_minute;   // ALARM_EDIT 模式下赋值给 ready_*
wire [5:0]   load_point;
//定义置数值显示中间值
reg  [7:0]   ready_state;   // 这些“中间值”是 ALARM_EDIT 模式下，数字的显示，经 MUX 直接连接 disp_* (即 disp_state 等)
reg  [7:0]   ready_hour;    // 受到“闪烁”逻辑的赋值，假如 hour 被选中，则 ready_hour 前半秒灭，后半秒显示 edit_hour
reg  [7:0]   ready_minute;

//定义中间变量，设置“时”的个位的进制
reg  [3:0]   radix_hour_lo;
reg  [3:0]   radix_hour_lo_up;
reg  [3:0]   radix_hour_lo_down;
// 小时个位加计数进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        radix_hour_lo_up <= 4'b1001;

    else if(edit_hour==8'hFF)
        radix_hour_lo_up <= 4'b1111;// 注意：现在采取的是 “负号”的编码是 F ，加计数溢出清零，加入将负号的编码进行更改，那么就可能无法溢出清零
                                    // 依照现在的逻辑，“负号”的编码必须是F，编码必须是4位，使得加计数能够溢出清零！
    else if(~num_up && edit_hour[7:4]==4'b0010)
        radix_hour_lo_up <= 4'b0011;
    else if(~num_up && (edit_hour[7:4]==4'b0001 || edit_hour[7:4]==4'b0000))
        radix_hour_lo_up <= 4'b1001;
end
// 小时个位减计数进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        radix_hour_lo_down <= 4'b1001;

    else if(edit_hour==8'hFF)
        radix_hour_lo_down <= 4'b0011;
        
    else if(~num_down && (edit_hour==8'b0000_0000 || edit_hour[7:4]==4'b0010) && edit_hour!=8'b0010_0000)
        radix_hour_lo_down <= 4'b0011;
    else if(~num_down && (edit_hour[7:4]==4'b0000 || edit_hour[7:4]==4'b0001 || edit_hour==8'b0010_0000) && edit_hour!=8'b0000_0000)
        radix_hour_lo_down <= 4'b1001;
end

// 注意：由于个位的进制是由两个 always 块决定，信号流水线式传递，所以第二级 always 要接收延迟一拍的 num_up num_down
reg num_up_d = 1'b1;
reg num_down_d = 1'b1;
always@(posedge sys_clk)    num_up_d <= num_up;
always@(posedge sys_clk)    num_down_d <= num_down;
// 小时个位进制动态显示，决断块
always@(posedge sys_clk)
begin
    if(!rst_n)
        radix_hour_lo <= 4'b1001;
    else if(current_set==SET_HOUR && ~num_up_d)     //  ~num_up_d 不可替换成 ~count_direction, 虽然二者都是 num_up 延迟一拍，但前者为脉冲，
        radix_hour_lo <= radix_hour_lo_up;              // 后者为电平，会导致进入编辑后，按 choose 切换状态到 current_set==SET_HOUR 后
    else if(current_set==SET_HOUR && ~num_down_d)       // 不用按 num_up num_down, radix_hour_lo 就成了3，小时数字就会被钳位到 23 
        radix_hour_lo <= radix_hour_lo_down;
        
    else if((~choose_edit || ~choose_edit_delay) && view_num[15:8]==8'hFF)    // 对 radix_hour_lo 赋值的 always 块里必须有这部分
        radix_hour_lo <= 4'b1111;                                                     // 因为 radix_hour_lo 只有在有上下键信号时才会更新，否则保持，而长按 choose 时恰好没有上下键按下！
    else if(edit_hour==8'hFF)                                                       // 并且减计数里，当 edit_hour==8'hFF 时， radix_hour_lo_down <= 4'b0011;需要提前预判下一个数的进制
        radix_hour_lo <= 4'b1111;                                                     // 所以需要左侧这一句来维持16进制
        
    else
        radix_hour_lo <= radix_hour_lo;
end

//定义中间变量，设置 小时个位 以外的进制
reg [3:0]   radix_min_lo;
reg [3:0]   radix_min_hi;
reg [3:0]   radix_hour_hi;
// 小时十位进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        radix_hour_hi <= 4'b0010;
        
    else if((~choose_edit || ~choose_edit_delay) && view_num[15:8]==8'hFF)    // 前面的小时个位进制、这里的十位、下面的分钟，都必须是(~choose_edit || ~choose_edit_delay)
        radix_hour_hi <= 4'b1111;                                               // 原因是 counter 会在读到输出值超出进制值时，在一个 sys_clk 周期后就强制将输出值置为进制值，
    else if(edit_hour==8'hFF)                                                 // 所以从将FF置给counter到转换至由edit_hour判断进制前的两个时钟周期，控制住进制
        radix_hour_hi <= 4'b1111;                                               // 否则 radix_hour_hi 会满足 else 条件，被设为 4'b0010 ，进而在 counter 中， 输出值会被立即从 FF 置为 23
        
    else
        radix_hour_hi <= 4'b0010;
end

// 分钟进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        {radix_min_hi,radix_min_lo} <= 8'b0101_1001;
        
    else if((~choose_edit || ~choose_edit_delay) && view_num[7:0]==8'hFF)
        {radix_min_hi,radix_min_lo} <= 8'b1111_1111;
    else if(edit_minute==8'hFF)
        {radix_min_hi,radix_min_lo} <= 8'b1111_1111;
    else
        {radix_min_hi,radix_min_lo} <= 8'b0101_1001;
end

//定义中间变量，决定加计数还是减计数
reg count_direction;
always@(posedge sys_clk)
begin
    if(!rst_n)
        count_direction <= 1'b0;
    else if(~num_up)
        count_direction <= 1'b0;
    else if(~num_down)
        count_direction <= 1'b1;
    else
        count_direction <= count_direction;
end

// 由于小时个位进制的决定由两个 always 块决定，所以个位 counter 的 hour_pulse 也要延迟一个时钟周期；
// 十位 counter 同样采用延迟的 hour_pulse_d, 具体原因如下
/* 
 在 endmodule 后撰写了 counter 小时十位 
 接 hour_pulse/hour_pulse_d 的 FF→down→23 流水线1-1/2-1
 接 hour_pulse/hour_pulse_d 的 23→up→20/00 流水线1-2/2-2
 流水线 1-1 = 2-1: FF→down→23
        counter 小时个位接 hour_pulse/hour_pulse_d 的两版本结果相同的原因，以及默认显示的负号--对23→up→20的影响：
        1. 十位在接到 hour_pulse 脉冲 以及 个位的进位的前提下才会改变，故两版本虽然脉冲接的不一样，但都不涉及进位，故十位数字不是因计数而变化的
        2. 此路径 FF→23 由 [counter] 无条件钳位，即十位数字因 [counter] 内分支 count_out>radix_data 而变化
        3. [counter] 内分支驱动(count_out>radix_data 不依赖 sec_pulse)，只随进制 radix_hour_lo / radix_hour_hi 变化，故十位是否延迟无关紧要
        4. 影响下一流水线的关键问题：都会导致 radix_hour_lo=F （FF 残留），从而影响 1-2 2-2
            这也是为什么在其它情况下（即 edit_hour 彻底脱离默认值--后），不会出现23→up→20的原因
 流水线 1-2 ≠ 2-2: 23→up→20/00
        根本原因：十位要同时满足 个位的进位信号+秒脉冲才会计数，
        但是原代码中，计数使能脉冲 hour_pulse 比进位信号 RCO[2] 提前一拍到来，故十位计数保持2不变
*/
reg hour_pulse_d = 1'b0;
always@(posedge sys_clk)    hour_pulse_d <= hour_pulse;
// ALARM_EDIT 状态下的计数器
// 在 用户长按 choose 即 choose_edit 低电平脉冲到来时，将用户要编辑的闹钟的时间 置数 到 counter ，进而输出到数码管。
//实例化             
counter min0(sys_clk,min_pulse, rst_n,choose_edit_delay,view_num[3:0],  radix_min_lo, 1'b1  ,1'b0,count_direction,edit_minute[3:0],RCO[0],load_point[0]),
        min1(sys_clk,min_pulse, rst_n,choose_edit_delay,view_num[7:4],  radix_min_hi, RCO[0],1'b0,count_direction,edit_minute[7:4],RCO[1],load_point[1]),
             
        hor0(sys_clk,hour_pulse_d,rst_n,choose_edit_delay,view_num[11:8], radix_hour_lo,1'b1  ,1'b1,count_direction,edit_hour[3:0],RCO[2],load_point[2]),
        hor1(sys_clk,hour_pulse_d,rst_n,choose_edit_delay,view_num[15:12],radix_hour_hi,RCO[2],1'b0,count_direction,edit_hour[7:4],RCO[3],load_point[3]);
assign  load_point[5:4] = 2'b00; // state 两位不显示小数点




//  ====================  ALARM_EDIT 编辑置数状态，时分秒闪烁显示状态机  ====================
// 变量声明： twinkle TWINKLE_STATE 等信号的声明在上一个时分秒计数脉冲状态机，主要是这些变量受该状态机控制
// 控制置数时的数字显示，当 mode_en 使能时，将当前时刻时钟的值赋予 ready_*
wire    [7:0]   ready_state_show;       // 增强可读性
assign  ready_state_show = {alarm_num, alarm_state_show(edit_state)};
always@(posedge sys_clk)
begin
if(!rst_n)begin
    ready_state <= {SHOW_DEFAULT,SHOW_DEFAULT};
    ready_hour  <= {SHOW_DEFAULT,SHOW_DEFAULT}; 
    ready_minute<= {SHOW_DEFAULT,SHOW_DEFAULT};
end
else begin
    case(twinkle)
        TWINKLE_STATE:
        begin
            ready_hour <= edit_hour;         ready_minute <= edit_minute;
            if(sec_clk)         ready_state <= {alarm_num,SHOW_EMPTY};
            else if(~sec_clk)   ready_state <= ready_state_show;
        end
        TWINKLE_HOUR:
        begin
            ready_state <= ready_state_show; ready_minute <= edit_minute;
            if(sec_clk)         ready_hour <= {SHOW_EMPTY,SHOW_EMPTY};
            else if(~sec_clk)   ready_hour <= edit_hour;     // sec_clk 低电平时输出正常数字，高电平时传入4'd14，即全灭
        end
        TWINKLE_MINUTE:
        begin
            ready_state <= ready_state_show; ready_hour <= edit_hour;
            if(sec_clk)         ready_minute <= {SHOW_EMPTY,SHOW_EMPTY};
            else if(~sec_clk)   ready_minute <= edit_minute;   
        end
        default: begin  // 与TWINKLE_STATE相同
            ready_hour <= edit_hour; ready_minute <= edit_minute;
            if(sec_clk)         ready_state <= {alarm_num,SHOW_EMPTY};
            else if(~sec_clk)   ready_state <= ready_state_show;
        end
    endcase
end
end




//  ====================  闹钟鸣响时，如果顶层处于 CLOCK 状态，则会给 alarm_beep_disp_en 使能, alarm 输出鸣响的闹钟的时间并闪烁  ====================
// 1秒亮1秒灭，慢点闪烁，便于观察
reg sec_clk_prev = 1'b1;
always@(posedge sys_clk)     sec_clk_prev <= sec_clk;
// 进行二分频
reg sec_clk_div;
always@(posedge sys_clk) begin
    if(!rst_n)  sec_clk_div <= 1'b0;
    else if(sec_clk && ~sec_clk_prev) sec_clk_div <= ~sec_clk_div;
end
reg [$clog2(ALARM_CNT):0] beep_idx;   // 在检测时间模块里，记录是哪个闹钟鸣响
reg [7:0]   beep_hour;
reg [7:0]   beep_minute;
reg [7:0]   beep_second;
reg [5:0]   beep_point;
// 注意，此时不显示闹钟使能状态，显示时分秒
always@(posedge sys_clk)
begin
    if(!rst_n)begin
        beep_hour   <= {SHOW_EMPTY,SHOW_EMPTY};
        beep_minute <= {SHOW_EMPTY,SHOW_EMPTY}; 
        beep_second <= {SHOW_EMPTY,SHOW_EMPTY};
    end
    else if(sec_clk_div)  begin
        beep_hour   <= alarm_mem[beep_idx][15:8];
        beep_minute <= alarm_mem[beep_idx][7 :0];
        beep_second <= 8'd0;    // 秒不可设置，默认为00秒
        beep_point  <= 6'd0;
    end
    else if(~sec_clk_div) begin
        beep_hour   <= {SHOW_EMPTY,SHOW_EMPTY};
        beep_minute <= {SHOW_EMPTY,SHOW_EMPTY};
        beep_second <= {SHOW_EMPTY,SHOW_EMPTY};
        beep_point  <= 6'b010100;
    end
end
// 检测时间是否到了
integer alarm_idx;    // 循环变量宜定义为 integer
reg pulse_1s_d;
always@(posedge sys_clk)    pulse_1s_d <= pulse_1s; // 延迟一拍，用于接收在 pulse_1s 下驱动的 counter 更新的时间
always@(posedge sys_clk)
begin
    if(!rst_n) begin
        alarm_ring_en <= 1'b0;
        beep_idx <= 0;
    end
    else begin
        if(pulse_1s_d) begin  // 每1秒检测一次，与顶层接收 alarm_ring_en 的模块形成流水线
            for (alarm_idx = 1'b0; alarm_idx < ALARM_CNT; alarm_idx = alarm_idx + 1'b1)begin
                if (alarm_mem[alarm_idx][16])begin
                    if({alarm_mem[alarm_idx][15:0],8'h00} == {now_hour,now_minute,now_second}) begin
                        alarm_ring_en <= 1'b1;
                        beep_idx    <= alarm_idx;
                    end
                end
            end
            if(alarm_ring_en)
                alarm_ring_en <= 1'b0;
        end
    end
end
// alarm_ring_en 采用 pulse_1s_d 使能的原因
/*
    因为在 clock 中, counter 依靠 pulse_1s 使能, 所以延迟一拍后, alarm_ring_en 模块能接收到更新后的时间 now_*。
    counter 模块、本模块中的 alarm_ring_en 使能模块、顶层 clock_mode 中连接 alarm_ring_en 的 counter_beep 鸣响计时模块
    共同构成流水线，所以三者的使能分别是 pulse_1s, pulse_1s_d, pulse_1s_d2
*/




// 数显控制，模式为 ALARM_VIEW 时，显示 alarm_mem 的值；模式为 ALARM_EDIT 时显示ready_*；
//           闹钟响铃时，输出闹钟的时间。
//           其它情况，输出为负号--（seg_dynamic编码，F 4'd15为负号）
assign  disp_state  = (mode_en && current_alarm==ALARM_VIEW) ? {alarm_num, alarm_state_show(alarm_mem[alarm_num][16])} : 
                      (mode_en && current_alarm==ALARM_EDIT) ? ready_state      :
                      (~mode_en&& alarm_beep_disp_en)        ? beep_hour        :
                      8'hFF;   // 增加出现其它情况时的保护
assign  disp_hour   = (mode_en && current_alarm==ALARM_VIEW) ? view_num[15:8]   :   // ALARM_VIEW 时的显示
                      (mode_en && current_alarm==ALARM_EDIT) ? ready_hour       :   // ALARM_EDIT 时的显示
                      (~mode_en&& alarm_beep_disp_en)        ? beep_minute      :   // 闹钟鸣响时的显示
                      8'hFF;
assign  disp_minute = (mode_en && current_alarm==ALARM_VIEW) ? view_num[7:0]    :   
                      (mode_en && current_alarm==ALARM_EDIT) ? ready_minute     :   
                      (~mode_en&& alarm_beep_disp_en)        ? beep_second      :   // 本模块端口名 disp_* 对应的是 显示语义 ，而非物理数码管分组 beep_*
                      8'hFF;                                                        // 故 disp_minute 应该被 beep_second 赋值 
assign  point_out   = (~mode_en&& alarm_beep_disp_en)        ? beep_point       :
                      load_point;



//  ====================  存入 RAM memory  ====================
integer alarm_index;  // 用于循环复位
always@(posedge sys_clk)
begin
    if(!rst_n)  // 由于闹钟数量未定，此处采用循环复位
        for (alarm_index = 1'b0; alarm_index < ALARM_CNT; alarm_index = alarm_index + 1'b1)
            alarm_mem[alarm_index] <= {1'b0,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT};
    else if(mode_en && set_en) begin  // 使能信号
        if(!load_confirm)   // 长按load的信号
        begin
            alarm_mem[alarm_num][16]   <= edit_state;
            alarm_mem[alarm_num][15:8] <= edit_hour;
            alarm_mem[alarm_num][7:0]  <= edit_minute;
        end
    end
end

endmodule

// counter 十位采用 hour_pulse 时的异常情况以及 hour_pulse_d 的正常情况流水线对比

/* 流水线1-1 edit_hour: --(FF) num_down → 23 ｜ 十位接 hour_pulse (修复前接法)

   按键按下前的状态：edit_hour=FF, radix_hour_lo_up=F, radix_hour_lo_down=3,
                     radix_hour_hi=F, radix_hour_lo=F, count_direction=0
   ┌ 1   num_down 变低（1 拍脉冲），edit_hour 仍为 FF
   ├ 2   [状态机] if((~num_up)‖(~num_down)) → hour_pulse<=1
   │     [方向锁存块] else if(~num_down) → count_direction<=1
   │     [个位减计数块] else if(edit_hour==8'hFF) → radix_hour_lo_down<=3
   │       （该分支无条件于按键，FF 期间每拍刷新为 3）
   ├ 3   num_down_d 变 0；hour_pulse 变 1；
   ├ 4   [决定块] else if(SET_HOUR && ~num_down_d)
   │        → radix_hour_lo <= radix_hour_lo_down(=3)
   │     - hour_pulse_d 变 1
   ├ 5   [counter·个位] 无条件钳位分支 count_out(F)>radix_hour_lo(3)
   │        → count_out<=3
   ├ 6   edit_hour = f3（十位 F 未动）；[决定块] 采样 edit_hour 沿前 FF
   │        → else if(edit_hour==8'hFF) → radix_hour_lo<=F（洗回）
   ├ 7   [十位进制块] edit_hour=f3≠FF → else → radix_hour_hi<=2
   ├ 8   [counter·十位] 无条件钳位 count_out(F)>radix_hour_hi(2)
   │        → count_out<=2
   └ 9   edit_hour = 23
   结果：23（与流水线 2-1 相同 → FF→23 由钳位链主导，与十位脉冲无关）
*/

/* 流水线2-1 edit_hour: --(FF) num_down → 23 ｜ 十位接 hour_pulse_d (修复后接法)

   按键按下前的状态：edit_hour=FF, radix_hour_lo_up=F, radix_hour_lo_down=3,
                     radix_hour_hi=F, radix_hour_lo=F, count_direction=0
   ┌ 1   num_down 变低（1 拍脉冲）, edit_hour 仍为 FF
   ├ 2   [状态机] if((~num_up)‖(~num_down)) → hour_pulse<=1
   │     [方向锁存块] else if(~num_down) → count_direction<=1
   │     [个位减计数块] else if(edit_hour==8'hFF) → radix_hour_lo_down<=3
   ├ 3   hour_pulse 变 1；num_down_d 变 0
   ├ 4   [决定块] else if(SET_HOUR && ~num_down_d)
   │        → radix_hour_lo <= radix_hour_lo_down(=3)
   │     - hour_pulse_d 变 1
   ├ 5   [counter·个位]（ sec_pulse=hour_pulse_d ）无条件钳位分支
   │        count_out(F)>radix_hour_lo(3) → count_out<=3
   │     [决定块] 采样 edit_hour 沿前 FF → radix_hour_lo<=F（洗回）
   ├ 6   edit_hour = f3
   ├ 7   [十位进制块] edit_hour≠FF → else → radix_hour_hi<=2
   │     [counter·十位]（sec_pulse=hour_pulse_d）
   ├ 8   [counter·十位] 无条件钳位 count_out(F)>radix_hour_hi(2)
   │        → count_out<=2
   └ 9   edit_hour = 23
   结果：23（十位接 hour_pulse_d 不影响 FF→23；此路径靠钳位，非进位）
*/


/* 流水线1-2 edit_hour: 23 num_up → 20 ｜ 十位接 hour_pulse (修复前接法)

   按键按下前的状态：edit_hour=23, radix_hour_lo_up=F （FF 残留）, radix_hour_lo_down=3,
                     radix_hour_hi=2, radix_hour_lo=F, count_direction=0
   ┌ 1   num_up 变低（1 拍脉冲），edit_hour 仍为 23
   ├ 2   [状态机] if((~num_up)‖(~num_down)) → hour_pulse<=1
   │     [方向锁存块] else if(~num_up) → count_direction<=0
   │     [个位加计数块] else if(~num_up && edit_hour[7:4]==2)
   │        → radix_hour_lo_up<=3
   │
   ├ 3   - hour_pulse 变 1（十位计数脉冲，短链先到）；num_up_d 变 0
   ├ 4   [counter·十位] 采样 hour_pulse=1 计数 —— 此刻 radix_hour_lo
   │       沿前值仍 = F → 个位 count_out(3)==radix_hour_lo(F) 不成立
   │       → RCO_unit（即RCO[2],小时个位进位信号）=0 （个位还未发出进位信号！！）→ 十位 RCO_last=0 → 十位不动！
   │     [决定块] else if(SET_HOUR && ~num_up_d) → radix_hour_lo
   │        <= radix_hour_lo_up(=3)（下一拍才可见）
   │     - hour_pulse_d 变 1
   │
   ├ 5   [counter·个位] 采样 hour_pulse_d=1 计数 —— radix_hour_lo
   │       已=3 → 个位 count_out(3)==3 → RCO_unit=1
   │       → 个位走 RCO==1&&count_direction==0 → count_out<=0
   └ 6   edit_hour = 20（个位清、十位 2 未动）＝异常
   差异根源：十位在拍 4 就采样（hour_pulse 短链），撞上 radix_hour_lo 沿前值 F，个位无进位信号
             个位在拍 5 采样(hour_pulse_d), radix_hour_lo 才=3
*/

/* 流水线2-2 edit_hour: 23 num_up → 00 ｜ 十位接 hour_pulse_d (修复后接法)

   按键按下前的状态：edit_hour=23, radix_hour_lo_up =F（FF 残留）, radix_hour_lo_down=3,
                     radix_hour_hi=2, radix_hour_lo =F, count_direction=0
   ┌ 1   num_up 变低（1 拍脉冲），edit_hour 仍为 23
   ├ 2   [状态机] if((~num_up)‖(~num_down)) → hour_pulse<=1
   │     [方向锁存块] else if(~num_up) → count_direction<=0
   │     [个位加计数块] else if(~num_up && edit_hour[7:4]==2)
   │        → radix_hour_lo_up<=3
   │
   ├ 3   - hour_pulse 变 1；num_up_d 变 0
   ├ 4   [决定块] else if(SET_HOUR && ~num_up_d)
   │        → radix_hour_lo <= radix_hour_lo_up(=3)（下一拍可见）
   │     - hour_pulse_d 变 1
   │
   ├ 5   [counter·十位] 与 [counter·个位]（sec_pulse 均=hour_pulse_d，
   │       同拍计数）—— radix_hour_lo 已=3 → 个位 count_out(3)==3
   │       → RCO_unit=1；十位 RCO_last=RCO_unit=1，十位
   │       count_out(2)==radix_hour_hi(2) → RCO_ten=1
   │       个位/十位均走 RCO==1&&count_direction==0 → count_out<=0
   └ 6   edit_hour = 00
   结果：00（十位与个位同拍、都等 radix_hour_lo=3 就位后计数）
*/
