// =============================================================================
// 文件名：load_num.v
// 功能：置数交互模块，允许用户通过按键手动设定时分秒
//
// 工作流程：
//   1. 由 clock_mode 的 mode_load_en 使能后进入工作状态，接入本模块的mode_en（这其实是短按load信号的间接作用）
//   2. 用户通过 choose 键切换当前设置的位（时→分→秒→时循环）
//   3. 用户通过 num_up/num_down 对当前位进行加减
//   4. 用户长按 load 传入本模块的 load_confirm 后，将设定值load_*写入 data_* 输出，
//      由 clock_mode 传给 clock 的 counter_time 完成实际置数
//
// 与 clock 的区别：
//   clock 中 counter 以 sec_pulse 为使能信号（每秒计一次，用于走时）
//   load_num 中 counter 以按键脉冲（hor_pulse/min_pulse/sec_pulse）为时钟
//   （每次按键产生一个脉冲，计数器响应该脉冲直接计一次，用于手动调整）
//
//  状态机说明：
//      1. 数码管显示控制状态机，控制空闲、LOAd显示、编辑置数三状态
//      2. 时分秒脉冲发生状态机，在编辑置数状态下，对choose选择的时或分或秒，输入计数脉冲，并且确定时分秒闪烁显示状态机的状态
//      3. 分秒闪烁显示状态机  ，在时分秒脉冲发生状态机的控制下，确定被选中的数位进行闪烁的逻辑
//
// 子模块实例：
//   counter（×6，同 counter_time，但以按键脉冲为时钟）
// =============================================================================
module load_num
(
input   wire    mode_en,
input   wire    sys_clk,
input   wire    sec_clk,
input   wire    rst_n,
input   wire    load_confirm,
input   wire    choose,
input   wire    num_up,
input   wire    num_down,
input   wire    [7:0]   before_second,
input   wire    [7:0]   before_minute,
input   wire    [7:0]   before_hour,    // 在时间置数中为当前时间，在闹钟置数中为上次设定的闹钟值
// input   wire    [5:0]   point_out,   // 小数点输出被固定，故不需要输入值


output  reg     [7:0]   data_second,
output  reg     [7:0]   data_minute,
output  reg     [7:0]   data_hour,
output  wire    [7:0]   disp_second,
output  wire    [7:0]   disp_minute,
output  wire    [7:0]   disp_hour  ,
output  wire    [5:0]   point_out

);

//  ====================  数码管显示控制状态机  ====================
//定义数码管显示状态机的状态
localparam  LOAD_IDLE = 2'b00;  //IDLE空闲状态
localparam  LOAD_SHOW = 2'b01;  //显示LOAd几个字
localparam  LOAD_EDIT = 2'b10;  //EDIT编辑状态
//定义数码管显示状态机
reg [1:0]   current_load = LOAD_IDLE;
//定义置数使能信号
reg set_en = 1'b0;

//定义SHOW状态数码管显示的字符，这些在末尾实例化seg_dymanic时才会用到
localparam  SHOW_EMPTY = 4'd14;  //全空，与seg_dynamic中的设定有关
localparam  SHOW_L     = 4'd10;  //L，与seg_dynamic中的设定有关
localparam  SHOW_O     = 4'd0 ;  //O，与seg_dynamic中的设定有关
localparam  SHOW_A     = 4'd11;  //A，与seg_dynamic中的设定有关
localparam  SHOW_d     = 4'd12;  //d，与seg_dynamic中的设定有关

//记录sec_clk在上一系统时钟周期的只，用于判断sec_clk的跳沿
reg sec_clk_prev = 1'b1;
// 这里并没有把sec_clk_prev <= sec_clk放在状态机内，
// 是因为若将sec_clk_prev的更新放在状态机的LOAD_SHOW状态内，就切断了它在其他状态下的跟踪，
// 导致进入该状态时“历史值”失真，边沿检测逻辑会立刻误触发，从而显著缩短预期停留时间
always@(posedge sys_clk)
begin
    if(rst_n==1'b0)
        sec_clk_prev <= 1'b1;
    else
        sec_clk_prev <= sec_clk;
end
//用于记录sec_clk的上、下跳沿，从而记录1秒钟
reg up_display   = 1'b0;
reg down_display = 1'b0;

//状态机，控制数码管的显示
always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        current_load <= LOAD_IDLE;
        up_display <= 1'b0;
        down_display <= 1'b0;
        set_en <= 1'b0;
    end
    else begin 
        case(current_load)
        LOAD_IDLE:
        begin
            if(mode_en)                 // 使能信号
                current_load <= LOAD_SHOW;
            else
                current_load <= LOAD_IDLE;  //维持当前状态
        end

        LOAD_SHOW:   // 不能直接对ready_hour等赋值，因为置数时也会对它们赋值，这样的话就会有两个地方驱动ready_hour，不合法，
        begin        // 所以需要将SHOW与EDIT时的信号分开，可能需要再对seg_dynamic实例化
            if (sec_clk_prev==1'b0 & sec_clk==1'b1) begin
                up_display <= 1'b1;         //遇到上升沿才给使能
                current_load <= LOAD_SHOW;  //维持原态
            end
            else if(sec_clk_prev==1'b1 & sec_clk==1'b0) begin
                down_display <= 1'b1;   //遇到下降沿才给使能
                current_load <= LOAD_SHOW;  //维持原态
            end
            if (up_display==1'b1&down_display==1'b1) begin
            //两使能齐全才切换模式，保证LOAd至少显示1秒
                up_display <= 1'b0;
                down_display <= 1'b0;
                current_load <= LOAD_EDIT;
            end
        end
        
        LOAD_EDIT:
        begin
            if(mode_en) begin
                set_en <= 1'b1;
                current_load <= LOAD_EDIT;  //维持当前状态
            end
            else begin
                set_en <= 1'b0;
                current_load <= LOAD_IDLE;
            end
        end        
        default: //----------------------后期可能修改------------------------------
        begin
            current_load <= LOAD_IDLE;
            up_display <= 1'b0;
            down_display <= 1'b0;    
            set_en <= 1'b0;            
        end
   
        endcase
    end
end
// LOAd 的显示在末尾，这是因为不同模式显示的内容不同，编辑模式下的显示写在了后面




//  ====================  LOAD_EDIT 编辑置数状态，时分秒选择（计数脉冲产生）状态机  ====================
// 数字闪烁状态机变量证明，该状态机在代码counter的下面
// 没错，这不是此状态机的变量声明，而是下一个与本状态机配合的状态机的声明！！
reg [1:0]   twinkle = 2'b0;
localparam  TWINKLE_HOUR = 2'b00;
localparam  TWINKLE_MINUTE = 2'b01;
localparam  TWINKLE_SECOND = 2'b10;

//将choose、num_up、num_down转化成脉宽等于系统时钟的脉冲
reg choose_pulse = 1'b1;
reg num_up_pulse = 1'b1;
reg num_down_pulse = 1'b1;
//采用跳沿检测，采集到下跳沿即产生脉冲
reg choose_pulse_prev = 1'b1;
reg num_up_pulse_prev = 1'b1;
reg num_down_pulse_prev = 1'b1;
always@(posedge sys_clk) begin
    if(rst_n==1'b0) begin
        choose_pulse_prev <= 1'b1;
        num_up_pulse_prev <= 1'b1;
        num_down_pulse_prev <= 1'b1;
    end
    else            
    choose_pulse_prev <= choose;
    num_up_pulse_prev <= num_up;
    num_down_pulse_prev <= num_down;
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

//定义时分秒计数脉冲状态机的状态
localparam  SET_HOUR = 2'b00;
localparam  SET_MINUTE = 2'b01;
localparam  SET_SECOND = 2'b10;
//定义时分秒计数脉冲状态机
reg [1:0]   current_set = SET_HOUR;
//定义时分秒计数信号脉冲
reg sec_pulse = 1'b0;
reg min_pulse = 1'b0;
reg hor_pulse = 1'b0;
//每次set_en使能（上跳沿），对current_set重置为SET_HOUR
reg set_en_prev;// 对 set_en 采用跳沿检测，每次 set_en 使能进入 LOAD_EDIT 模式，就重置本状态机选择的时钟位

//状态机、时分秒计数脉冲产生
always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        set_en_prev     <= 1'b0;
        current_set     <= SET_HOUR;
        sec_pulse <= 1'b0;
        min_pulse <= 1'b0;      
        hor_pulse <= 1'b0;         
    end
    else begin
        // 每次 set_en 使能进入 LOAD_EDIT 模式，就默认选择 SET_HOUR
        set_en_prev <= set_en;
        if(set_en_prev==1'b0 && set_en==1'b1)
            current_set <=  SET_HOUR;
        // 上面这部分综合以后，相当于是加在了SET_MINUTE、SET_SECOND状态切换到SET_HOUR状态的条件
        // （可以去看看RTL视图）与在下面加是一样的，但是还是选择夹在前面吧，体现出心路历程
        if(set_en) begin               // 使能状态机的使能信号
            case(current_set)
            SET_HOUR:
            begin
                sec_pulse <= 1'b0;
                min_pulse <= 1'b0;
                twinkle <= TWINKLE_HOUR;    // 用于控制该数位闪烁
    
                if((~num_up_pulse) || (~num_down_pulse))begin
                    hor_pulse <= 1'b1;
                end
                else if((num_up_pulse) || (num_down_pulse))
                    hor_pulse <= 1'b0;
                else
                    hor_pulse <= hor_pulse; // 只修改了这一处，分、秒的都没改。主要是考虑到num_updown已经是脉冲了，hour_pulse是不是不需要边沿检测了
                    
                if(~choose_pulse) current_set <= SET_MINUTE;    // choose低有效
            end
            SET_MINUTE:
            begin
                sec_pulse <= 1'b0;
                hor_pulse <= 1'b0;
                twinkle <= TWINKLE_MINUTE;    // 用于控制该数位闪烁
    
                if((~num_up_pulse) || (~num_down_pulse))
                    min_pulse <= 1'b1;
                else
                    min_pulse <= 1'b0;
                    
                if(~choose_pulse) current_set <= SET_SECOND;    // choose低有效
            end        
            SET_SECOND:
            begin
                min_pulse <= 1'b0;
                hor_pulse <= 1'b0;
                twinkle <= TWINKLE_SECOND;    // 用于控制该数位闪烁
            
                    if((~num_up_pulse) || (~num_down_pulse))
                        sec_pulse <= 1'b1;
                    else
                        sec_pulse <= 1'b0;
        
                if(~choose_pulse) current_set <= SET_HOUR;//    choose低有效
            end        
            default: 
            begin
                set_en_prev     <= 1'b0;
                current_set     <= SET_HOUR;
                sec_pulse <= 1'b0;
                min_pulse <= 1'b0;      
                hor_pulse <= 1'b0; 
            end
        
            endcase
        end
    end
end



//  ====================  置数到clock的逻辑  ====================
// 在mode_en第一次使能时，“按下”load_before，将此时的时间输出到counter，进而输出到数码管
reg mode_en_prev;// 对mode_en采用跳沿检测
reg load_before = 1'b1;

always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        mode_en_prev <= 1'b0;
        load_before     <= 1'b1;
            // 对mode_en跳沿检测，load_before低电平脉冲置数，ready_hour等显示按下load时的数字。
    end
    else begin
        mode_en_prev <= mode_en;
        if(mode_en_prev==1'b0 && mode_en==1'b1)
            load_before <= 1'b0;
        else
            load_before <= 1'b1;
    end
end     

//  ====================  六次实例化counter，并设计加减计数的小时个位进制动态显示  ====================
//定义进位信号中间值
wire    [5:0]   RCO_zhong;
//定义置数中间值
wire [7:0]   load_hour;
wire [7:0]   load_minute;
wire [7:0]   load_second;
//将中间值暂存下来
reg  [7:0]   ready_hour = 8'b00;        // 改名：twinkle_*
reg  [7:0]   ready_minute = 8'b00;
reg  [7:0]   ready_second = 8'b00;

//定义中间变量，设置“时”的个位的进制
wire [3:0]   hour_radix;
reg  [3:0]   hour_radix_up;
reg  [3:0]   hour_radix_down;
// 加计数进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        hour_radix_up <= 4'b1001;
    else if(mode_updown==1'b0 && load_hour[7:4]==4'b0010)
        hour_radix_up <= 4'b0011;
    else if(mode_updown==1'b0 && (load_hour[7:4]==4'b0001 || load_hour[7:4]==4'b0000))
        hour_radix_up <= 4'b1001;
    else
        hour_radix_up <= hour_radix_up;
end
// 减计数进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        hour_radix_down <= 4'b1001;
    else if(mode_updown==1'b1 && load_hour[7:4]==4'b0000)
        hour_radix_down <= 4'b0011;
    else if(mode_updown==1'b1 && (load_hour[7:4]==4'b0001 || load_hour[7:4]==4'b0010))
        hour_radix_down <= 4'b1001;
    else
        hour_radix_down <= hour_radix_down;
end
assign hour_radix = mode_updown==1'b0 ? hour_radix_up : hour_radix_down;

//实例化
counter sec0(sys_clk,sec_pulse,rst_n,load_before,before_second[3:0],4'b1001,   1'b1        ,1'b0,mode_updown,load_second[3:0],RCO_zhong[0], ),
        sec1(sys_clk,sec_pulse,rst_n,load_before,before_second[7:4],4'b0101,   RCO_zhong[0],1'b0,mode_updown,load_second[7:4],RCO_zhong[1], ),
             
        min0(sys_clk,min_pulse,rst_n,load_before,before_minute[3:0],4'b1001,   1'b1        ,1'b1,mode_updown,load_minute[3:0],RCO_zhong[2], ),
        min1(sys_clk,min_pulse,rst_n,load_before,before_minute[7:4],4'b0101,   RCO_zhong[2],1'b0,mode_updown,load_minute[7:4],RCO_zhong[3], ),
             
        hor0(sys_clk,hor_pulse,rst_n,load_before,before_hour[3:0],  hour_radix,1'b1        ,1'b1,mode_updown,load_hour[3:0],  RCO_zhong[4], ),
        hor1(sys_clk,hor_pulse,rst_n,load_before,before_hour[7:4],  4'b0010,   RCO_zhong[4],1'b0,mode_updown,load_hour[7:4],  RCO_zhong[5], );
// 注：从右往左数第1个数字代表着counter的point_in输入口，此端口其实不需要输入，但是未用的输入端口则必须提供一个确定的值
// 而最右侧的输出端口point_out_counter也不需要，就暂时悬空




//  ====================  LOAD_EDIT编辑置数状态，时分秒闪烁显示状态机  ====================
// 变量声明：twinkle、TWINKLE_HOUR等在上一个时分秒计数脉冲状态机，主要是这些变量受该状态机控制
// 控制置数时的数字显示，当mode_en使能时，将当前时刻时钟的值赋予ready_*
always@(posedge sys_clk)         // 状态机牛逼！！！
begin
if(!rst_n)begin
    ready_minute <= before_minute; 
    ready_second <= before_second;
    ready_hour   <= before_hour;
end
else begin
    case(twinkle)
        TWINKLE_HOUR:
        begin
            ready_minute <= load_minute; ready_second <= load_second;
            if(sec_clk)         ready_hour <= {4'd14,4'd14};
            else if(~sec_clk)   ready_hour <= load_hour; // sec_clk高电平时输出正常数字，低电平时传入31，即全灭
        end
        TWINKLE_MINUTE:
        begin
            ready_hour <= load_hour; ready_second <= load_second;
            if(sec_clk)         ready_minute <= {4'd14,4'd14};
            else if(~sec_clk)   ready_minute <= load_minute; // sec_clk高电平时输出正常数字，低电平时传入31，即全灭
        end
        TWINKLE_SECOND:
        begin
            ready_hour <= load_hour; ready_minute <= load_minute;
            if(sec_clk)         ready_second <= {4'd14,4'd14};
            else if(~sec_clk)   ready_second <= load_second; // sec_clk高电平时输出正常数字，低电平时传入31，即全灭    
        end
        default: begin  // 与TWINKLE_HOUR相同
            ready_minute <= load_minute; ready_second <= load_second;
            if(sec_clk)         ready_hour <= {4'd14,4'd14};
            else if(~sec_clk)   ready_hour <= load_hour;
        end
    endcase
end
end

// 数显控制，模式为LOAD_SHOW时，显示LOAd；模式为LOAD_EDIT时显示read_*；模式为LOAD_IDLE时显示为全显示（seg_dynamic编码，F 4'd15为全显示）
assign  disp_hour   = (mode_en && current_load==LOAD_SHOW) ? {SHOW_EMPTY, SHOW_L} : 
                      (mode_en && current_load==LOAD_EDIT) ? ready_hour           :
                      8'hFF;   // 增加完全关闭时的保护：mode_en使能且LOAD_IDLE待机时，或者干脆没使能时，都为FF，seg_dynamic编码为全显示
assign  disp_minute = (mode_en && current_load==LOAD_SHOW) ? {SHOW_O, SHOW_A}     : 
                      (mode_en && current_load==LOAD_EDIT) ? ready_minute         :
                      8'hFF;
assign  disp_second = (mode_en && current_load==LOAD_SHOW) ? {SHOW_d, SHOW_EMPTY} : 
                      (mode_en && current_load==LOAD_EDIT) ? ready_second         :
                      8'hFF;                 
assign point_out = 6'b010100;



//  ====================  进行置数  ====================
always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        data_hour   <= before_hour;
        data_minute <= before_minute;
        data_second <= before_second;
    end
    else if(mode_en) begin  // 使能信号
        if(!load_confirm)   // 长按load的信号
        begin
            data_hour   <= load_hour;
            data_minute <= load_minute;
            data_second <= load_second;
        end
        else
        begin
            data_hour   <= data_hour  ;
            data_minute <= data_minute;
            data_second <= data_second;
        end
    end
end

endmodule