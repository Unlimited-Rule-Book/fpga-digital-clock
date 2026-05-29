module alarm
(
input   wire    mode_en,
input   wire    sys_clk,
input   wire    sec_clk,                // 1Hz时钟，用于控制 LOAd 显示时长，控制 ALARM_EDIT 状态下，被选中的数位闪烁的逻辑
input   wire    rst_n,
input   wire    load,                   // 短按load，用于取消对某个闹钟的设置，在顶层与 load_s_pulse 相连接。
input   wire    load_confirm,           // 长按load，用于确认对某个闹钟的设置，在顶层与 load_l_pulse 相连接
input   wire    choose,
input   wire    choose_edit,            // 长按choose，进入对某一个闹钟进行编辑的状态 // clock_mode 中变成脉冲===================================
input   wire    num_up,
input   wire    num_down,
input   wire    [7:0]   now_second,
input   wire    [7:0]   now_minute,
input   wire    [7:0]   now_hour,

output  wire    [7:0]   disp_state,     // 置数模式下，数码管的显示
output  wire    [7:0]   disp_hour,      // 涵盖 LOAd 、置数值的显示
output  wire    [7:0]   disp_minute,    // 赋值逻辑在 data_* 的上方
output  wire    [5:0]   point_out,      // 既然是要控制数码管的显示，那就得加上小数点了=====================
output  wire    alarm_view_en,          // 闹钟的状态在 ALARM_VIEW ,可以切换到其它模式。
output  reg     alarm_ring_en           // 到了闹钟的时间，响铃
);
//将choose、num_up、num_down转化成脉宽等于系统时钟的脉冲
reg choose_pulse = 1'b1;
reg num_up_pulse = 1'b1;
reg num_down_pulse = 1'b1;
reg choose_edit_pulse = 1'b1;
//采用跳沿检测，采集到下跳沿即产生脉冲
reg choose_pulse_prev = 1'b1;
reg num_up_pulse_prev = 1'b1;
reg num_down_pulse_prev = 1'b1;
reg choose_edit_pulse_prev = 1'b1;
always@(posedge sys_clk) begin
    if(rst_n==1'b0) begin
        choose_pulse_prev <= 1'b1;
        num_up_pulse_prev <= 1'b1;
        num_down_pulse_prev <= 1'b1;
        choose_edit_pulse_prev <= 1'b1;
    end
    else begin          
        choose_pulse_prev <= choose;
        num_up_pulse_prev <= num_up;
        num_down_pulse_prev <= num_down;
        choose_edit_pulse_prev <= choose_edit;
    end
end
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                     choose_pulse <= 1'b1;
    else if(choose_pulse_prev==1'b1 & choose==1'b0)     choose_pulse <= 1'b0;
    else                                                choose_pulse <= 1'b1;
end
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                     num_up_pulse <= 1'b1;
    else if(num_up_pulse_prev==1'b1 & num_up==1'b0)     num_up_pulse <= 1'b0;
    else                                                num_up_pulse <= 1'b1;
end
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                     num_down_pulse <= 1'b1;
    else if(num_down_pulse_prev==1'b1 & num_down==1'b0) num_down_pulse <= 1'b0;
    else                                                num_down_pulse <= 1'b1;
end
always@(posedge sys_clk) begin
    if(rst_n==1'b0)                                             choose_edit_pulse <= 1'b1;
    else if(choose_edit_pulse_prev==1'b1 & choose_edit==1'b0)   choose_edit_pulse <= 1'b0;
    else                                                        choose_edit_pulse <= 1'b1;
end

//定义中间变量，决定加计数还是减计数
reg mode_updown = 1'b0;
always@(*)
begin
    if(num_up==1'b0)
    mode_updown = 1'b0;
    else if(num_down==1'b0)
    mode_updown = 1'b1;
    else
    mode_updown = 1'b0;
end
// always@(posedge sys_clk)
// begin
    // if(~rst_n)
        // mode_updown <= 1'b0;
    // else if(num_up==1'b0)
        // mode_updown <= 1'b0;
    // else if(num_down==1'b0)
        // mode_updown <= 1'b1;
    // else
        // mode_updown <= 1'b0;
// end




//  ====================  数码管显示控制状态机  ====================
//定义数码管显示状态机的状态
localparam  ALARM_VIEW = 1'b0;  //VIEW浏览状态
localparam  ALARM_EDIT = 1'b1;  //EDIT编辑状态
//定义数码管显示状态机
reg current_alarm = ALARM_VIEW;
//定义浏览状态使能信号、置数使能信号
reg view_en = 1'b0;
reg set_en = 1'b0;
//将 view_en 输出，在顶层 clock_mode 里用作切换回 clock 模式的使能
assign alarm_view_en = view_en;
//定义闹钟界面的字母显示
localparam  SHOW_EMPTY   = 4'd14; // 全灭
localparam  SHOW_DEFAULT = 4'd15; // 默认闹钟的时间是“符号
localparam  SHOW_d       = 4'd12; // d，表示闹钟未使能
localparam  SHOW_E       = 4'd13; // E，表示闹钟使能了
//状态机，控制数码管的显示
always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        current_alarm <= ALARM_VIEW;
        view_en <= 1'b0;
        set_en <= 1'b0;
    end
    else begin 
        case(current_alarm)
        ALARM_VIEW:
        begin
            if(~choose_edit_pulse) begin  // clock_mode 中变成脉冲
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
        default: //----------------------后期可能修改------------------------------
        begin 
            view_en <= 1'b1;
            set_en <= 1'b0;          
            current_alarm <= ALARM_VIEW;             
        end
   
        endcase
    end
end

// ALARM_VIEW 状态下浏览不同alarm
// RAM 建模！！！
parameter  ALARM_CNT = 4;
reg [16:0] memory [0:ALARM_CNT-1'b1];   // 一共有4个可设置闹钟，地址位宽为2；一共用17位，第一位表示是否使能，后16位为4个BCD编码表示要设置的小时、分钟，秒默认为0，后面把这个写死。
reg [$clog2(ALARM_CNT)-1:0]  alarm_num;       // 闹钟的编号，也是地址线。
// ALARM_VIEW 状态下的显示
// 闹钟时间
reg [15:0]  view_num;   // 用于暂存被选中的地址下的闹钟时间,只是为了表示起来方便
always@(posedge sys_clk)begin
    if(!rst_n) begin
        alarm_num <= 2'b00;
        view_num <= {SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT};
    end
    else if(view_en) begin
        view_num <= memory[alarm_num][15:0];
        if(~choose_pulse && (alarm_num==ALARM_CNT-1))
            alarm_num <= 0;
        else if(~choose_pulse)
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
// 闹钟编号
wire    [3:0]  alarm_num_bcd;
bin2bcd_param #( .BIN_WIDTH($clog2(ALARM_CNT)) ) alarm_bin2bcd_param(
    .bin        (alarm_num),
    .bcd        (alarm_num_bcd)
);




// 数字闪烁状态机变量证明，该状态机在代码counter的下面
// 没错，这不是此状态机的变量声明，而是下一个与本状态机配合的状态机的声明！！
reg [1:0]   twinkle = 2'b0;
localparam  TWINKLE_STATE  = 2'b00;
localparam  TWINKLE_HOUR   = 2'b01;
localparam  TWINKLE_MINUTE = 2'b10;

//定义时分秒计数脉冲状态机的状态
localparam  SET_STATE  = 2'b00;
localparam  SET_HOUR = 2'b01;
localparam  SET_MINUTE = 2'b10;
//定义时分秒计数脉冲状态机
reg [1:0]   current_set = SET_STATE;
//定义时分秒计数信号脉冲
reg hor_pulse = 1'b0;
reg min_pulse = 1'b0;
//定义状态中间变量
reg state_tmp;
//每次set_en使能（上跳沿），对current_set重置为SET_STATE
reg set_en_prev;// 对 set_en 采用跳沿检测，每次 set_en 使能进入 ALARM_EDIT 模式，就重置本状态机选择的时钟位

//状态机、时分秒计数脉冲产生
always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        set_en_prev     <= 1'b0;
        current_set     <= SET_STATE;
        state_tmp <= memory[alarm_num][16]; 
        hor_pulse <= 1'b0;
        min_pulse <= 1'b0;      
       
    end
    else begin
        // 每次 set_en 使能进入 ALARM_EDIT 模式，就默认选择 SET_STATE ，并且将该闹钟的状态赋给中间变量
        set_en_prev <= set_en;
        if(set_en_prev==1'b0 && set_en==1'b1) begin
            current_set <=  SET_STATE;
            state_tmp <= memory[alarm_num][16];
        end
        // 上面这部分综合以后，相当于是加在了SET_HOUR、SET_MINUTE状态切换到SET_STATE状态的条件
        // （可以去看看RTL视图）与在下面加是一样的，但是还是选择夹在前面吧，体现出心路历程
        if(set_en) begin               // 使能状态机的使能信号
            case(current_set)
            SET_STATE:
            begin
                min_pulse <= 1'b0;
                hor_pulse <= 1'b0;
                twinkle <= TWINKLE_STATE;    // 用于控制该数位闪烁
    
                if((~num_up_pulse) || (~num_down_pulse))
                    state_tmp <= ~state_tmp;
                    
                if(~choose_pulse) current_set <= SET_HOUR;    // choose低有效
            end
            SET_HOUR:
            begin
                state_tmp <= state_tmp;
                min_pulse <= 1'b0;
                twinkle <= TWINKLE_HOUR;    // 用于控制该数位闪烁
    
                if((~num_up_pulse) || (~num_down_pulse))
                    hor_pulse <= 1'b1;
                else
                    hor_pulse <= 1'b0;
                    
                if(~choose_pulse) current_set <= SET_MINUTE;    // choose低有效
            end        
            SET_MINUTE:
            begin
                state_tmp <= state_tmp;
                hor_pulse <= 1'b0;
                twinkle <= TWINKLE_MINUTE;    // 用于控制该数位闪烁
            
                    if((~num_up_pulse) || (~num_down_pulse))
                        min_pulse <= 1'b1;
                    else
                        min_pulse <= 1'b0;
        
                if(~choose_pulse) current_set <= SET_STATE;//    choose低有效
            end        
            default: 
            begin
                set_en_prev     <= 1'b0;
                current_set     <= SET_STATE;
                state_tmp <= memory[alarm_num][16];
                hor_pulse <= 1'b0;    
                min_pulse <= 1'b0;
            end
        
            endcase
        end
    end
end


  

//  ====================  六次实例化counter，并设计加减计数的小时个位进制动态显示  ====================
//定义进位信号中间值
wire    [5:0]   RCO_zhong;
//定义置数中间值
wire [7:0]   edit_hour;             // counter 模块直接输出的值
wire [7:0]   edit_minute;           // ALARM_EDIT 模式下赋值给 ready_*
wire [5:0]   load_piont;
//定义置数值显示中间值
reg  [7:0]   ready_state = 8'b00;    // 这些“中间值”是 ALARM_EDIT 模式下，数字的显示，经 MUX 直接连接 disp_* (即 disp_state 等)
reg  [7:0]   ready_hour = 8'b00;  // 受到“闪烁”逻辑的赋值，假如 hour 被选中，则 ready_state 前半秒灭，后半秒显示 edit_hour
reg  [7:0]   ready_minute = 8'b00;  // 可以考虑改名：twinkle_*

//定义中间变量，设置“时”的个位的进制
reg  [3:0]   hour_radix0;
reg  [3:0]   hour_radix0_up;
reg  [3:0]   hour_radix0_down;
// 小时个位加计数进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        hour_radix0_up <= 4'b1001;

    else if(edit_hour==8'hFF)
        hour_radix0_up <= 4'b1111;  // 注意：现在采取的是 “负号”的编码是 F ，加计数溢出清零，加入将负号的编码进行更改，那么就可能无法溢出清零
                                    // 依照现在的逻辑，“负号”的编码必须是F，编码必须是4位，使得加计数能够溢出清零！
    else if(mode_updown==1'b0 && edit_hour[7:4]==4'b0010)
        hour_radix0_up <= 4'b0011;
    else if(mode_updown==1'b0 && (edit_hour[7:4]==4'b0001 || edit_hour[7:4]==4'b0000))
        hour_radix0_up <= 4'b1001;
    else
        hour_radix0_up <= hour_radix0_up;
end
// 小时个位减计数进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        hour_radix0_down <= 4'b1001;

    else if(edit_hour==8'hFF)
        hour_radix0_down <= 4'b0011;
        
    else if(mode_updown==1'b1 && (edit_hour==8'b0000_0000 || edit_hour[7:4]==4'b0010) && edit_hour!=8'b0010_0000)
        hour_radix0_down <= 4'b0011;
    else if(mode_updown==1'b1 && (edit_hour[7:4]==4'b0000 || edit_hour[7:4]==4'b0001 || edit_hour==8'b0010_0000) && edit_hour!=8'b0000_0000)
        hour_radix0_down <= 4'b1001;
    else
        hour_radix0_down <= 4'b1001;
end
always@(posedge sys_clk)
begin
    if(~rst_n)
        hour_radix0 <= 4'b1001;
    else if(current_set==SET_HOUR && ~num_up_pulse)
        hour_radix0 <= hour_radix0_up;
    else if(current_set==SET_HOUR && ~num_down_pulse)
        hour_radix0 <= hour_radix0_down;
        
    else if((~choose_edit_pulse || ~choose_edit_delay) && view_num[15:8]==8'hFF)    // 对 hour_radix0 赋值的always块里必须有这部分
        hour_radix0 <= 4'b1111;                                                     // 因为 hour_radix0 只有在有上下键信号时才会更新，否则保持，而长按 choose 时恰好没有上下键按下！
    else if(edit_hour==8'hFF)                                                       // 并且减计数里，当edit_hour==8'hFF时，hour_radix0_down <= 4'b0011;需要提前预判下一个数的进制
        hour_radix0 <= 4'b1111;                                                     // 所以需要左侧这一句来维持16进制
        
    else
        hour_radix0 <= hour_radix0;
end

//定义中间变量，设置“时”个位以外的进制
reg [3:0]   min_radix0;
reg [3:0]   min_radix1;
reg [3:0]   hour_radix1;
// 小时十位进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        hour_radix1 <= 4'b0010;
        
    else if((~choose_edit_pulse || ~choose_edit_delay) && view_num[15:8]==8'hFF)    // 前面的小时个位进制、这里的十位、下面的分钟，都必须是(~choose_edit_pulse || ~choose_edit_delay)
        hour_radix1 <= 4'b1111;                                                     // 原因是 counter 会在读到输出值超出进制值时，在一个 sys_clk 周期后就强制将输出值置为进制值，
    else if(edit_hour==8'hFF)                                                       // 所以从将FF置给counter到转换至由edit_hour判断进制前的两个时钟周期，控制住进制
        hour_radix1 <= 4'b1111;                                                     // 否则 hour_radix1 会满足 else 条件，被设为 4'b0010 ，进而在 counter 中， 输出值会被立即从 FF 置为 23
        
    else
        hour_radix1 <= 4'b0010;
end
// 分钟进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        {min_radix1,min_radix0} <= 8'b0101_1001;
        
    else if((~choose_edit_pulse || ~choose_edit_delay) && view_num[7:0]==8'hFF)
        {min_radix1,min_radix0} <= 8'b1111_1111;
    else if(edit_minute==8'hFF)
        {min_radix1,min_radix0} <= 8'b1111_1111;
        
    else
        {min_radix1,min_radix0} <= 8'b0101_1001;
end
reg choose_edit_delay = 1'b1;
always@(posedge sys_clk)  choose_edit_delay <= choose_edit_pulse;   // 用延时信号置数，是因为要让counter读到 由view_num判断得到 的进制

// ALARM_EDIT 状态下的计数器
// 在 用户长按 choose 即 choose_edit 低电平脉冲到来时，将用户要编辑的闹钟的时间 置数 到 counter ，进而输出到数码管。
//实例化             
 counter min0(sys_clk,min_pulse,rst_n,choose_edit_delay,view_num[3:0], min_radix0, 1 'b1        ,1'b0,mode_updown,edit_minute[3:0],RCO_zhong[2],load_piont[0]),
         min1(sys_clk,min_pulse,rst_n,choose_edit_delay,view_num[7:4], min_radix1,  RCO_zhong[2],1'b0,mode_updown,edit_minute[7:4],RCO_zhong[3],load_piont[1]),
             
         hor0(sys_clk,hor_pulse,rst_n,choose_edit_delay,view_num[11:8], hour_radix0,1'b1        ,1'b1,mode_updown,edit_hour[3:0],  RCO_zhong[4],load_piont[2]),
         hor1(sys_clk,hor_pulse,rst_n,choose_edit_delay,view_num[15:12],hour_radix1,RCO_zhong[4],1'b0,mode_updown,edit_hour[7:4],  RCO_zhong[5],load_piont[3]);
// 注：从右往左数第1个数字代表着counter的point_in输入口，此端口其实不需要输入，但是未用的输入端口则必须提供一个确定的值
// 而最右侧的输出端口point_out_counter也不需要，就暂时悬空
assign  load_piont[5:4] = 1'b0; // state 两位不显示小数点




//  ====================  ALARM_EDIT编辑置数状态，时分秒闪烁显示状态机  ====================
// 变量声明：twinkle、TWINKLE_STATE等在上一个时分秒计数脉冲状态机，主要是这些变量受该状态机控制
// 控制置数时的数字显示，当mode_en使能时，将当前时刻时钟的值赋予ready_*

// 需要增加 ready_state ,去掉 ready_sec =================================================================================================
wire    [7:0]   ready_state_show;       // 增强可读性
assign  ready_state_show = {alarm_num_bcd, alarm_state_show(state_tmp)};
always@(posedge sys_clk)         // 状态机牛逼！！！
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
            if(sec_clk)         ready_state <= {alarm_num_bcd,SHOW_EMPTY};
            else if(~sec_clk)   ready_state <= ready_state_show; // sec_clk高电平时输出正常数字，低电平时传入31，即全灭
        end
        TWINKLE_HOUR:
        begin
            ready_state <= ready_state_show; ready_minute <= edit_minute;
            if(sec_clk)         ready_hour <= {SHOW_EMPTY,SHOW_EMPTY};
            else if(~sec_clk)   ready_hour <= edit_hour; // sec_clk高电平时输出正常数字，低电平时传入31，即全灭
        end
        TWINKLE_MINUTE:
        begin
            ready_state <= ready_state_show; ready_hour <= edit_hour;
            if(sec_clk)         ready_minute <= {SHOW_EMPTY,SHOW_EMPTY};
            else if(~sec_clk)   ready_minute <= edit_minute; // sec_clk高电平时输出正常数字，低电平时传入31，即全灭    
        end
        default: begin  // 与TWINKLE_STATE相同
            ready_hour <= edit_hour; ready_minute <= edit_minute;
            if(sec_clk)         ready_state <= {alarm_num_bcd,SHOW_EMPTY};
            else if(~sec_clk)   ready_state <= edit_hour;
        end
    endcase
end
end

// 数显控制，模式为LOAD_SHOW时，显示LOAd；模式为ALARM_EDIT时显示read_*；模式为ALARM_VIEW时显示为全显示（seg_dynamic编码，F 4'd15为全显示）

// 需要增加 ready_state ,去掉 ready_sec =================================================================================================

assign  disp_state  = (mode_en && current_alarm==ALARM_VIEW) ? {alarm_num_bcd, alarm_state_show(memory[alarm_num][16])} : 
                      (mode_en && current_alarm==ALARM_EDIT) ? ready_state      :
                      8'hFF;   // 增加完全关闭时的保护：mode_en使能且ALARM_VIEW待机时，或者干脆没使能时，都为FF，seg_dynamic编码为全显示
assign  disp_hour   = (mode_en && current_alarm==ALARM_VIEW) ? view_num[15:8]   : 
                      (mode_en && current_alarm==ALARM_EDIT) ? ready_hour       :
                      8'hFF;
assign  disp_minute = (mode_en && current_alarm==ALARM_VIEW) ? view_num[7:0]    : 
                      (mode_en && current_alarm==ALARM_EDIT) ? ready_minute     :
                      8'hFF;                 
assign point_out = load_piont;



//  ====================  进行置数  ====================
always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        memory[2'b00] <= {1'b0,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT};
        memory[2'b01] <= {1'b0,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT};
        memory[2'b10] <= {1'b0,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT};
        memory[2'b11] <= {1'b0,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT,SHOW_DEFAULT};
    end
    else if(mode_en && set_en) begin  // 使能信号
        if(!load_confirm)   // 长按load的信号
        begin
            memory[alarm_num][16]   <= state_tmp;
            memory[alarm_num][15:8] <= edit_hour;
            memory[alarm_num][7:0]  <= edit_minute;
        end
    end
end


// 检测时间是否到了
// 每1秒检测一次，对 sec_clk 跳沿检测
reg sec_clk_prev;
reg [$clog2(ALARM_CNT):0] index;    // 这里的位宽必须为3，否则index计到4会溢出归零，永远达不到index < ALARM_NUM条件，而终止条件必须设为这样，否则检测不到3号闹钟
always@(posedge sys_clk)
begin
    if(!rst_n) begin
        alarm_ring_en <= 1'b0;
        sec_clk_prev <= 1'b0;
    end
    else begin
        sec_clk_prev <= sec_clk;
        if(sec_clk && ~sec_clk_prev) begin
            for (index = 1'b0; index < ALARM_CNT; index = index + 1'b1)begin
                if (memory[index][16])begin
                    if({memory[index][15:0],8'h00} == {now_hour,now_minute,now_second})
                        alarm_ring_en <= 1'b1;
                end
            end
            if(alarm_ring_en)
                alarm_ring_en <= 1'b0;
        end
    end
end

endmodule