// =============================================================================
// 文件名：load_num.v
// 功能：置数交互模块，允许用户通过按键手动设定时分秒
//
// 工作流程：
//   1. 由 clock_mode 的 mode_load_en 使能后进入工作状态，接入本模块的mode_en（这其实是短按load信号的间接作用）
//   2. 切换到 load_num 后，显示的时间为按下 load 键时的时间，也就是说用户是用当前时刻的时间开始置数
//   3. 用户通过 choose 键切换当前设置的位（时→分→秒→时循环）
//   4. 用户通过 num_up/num_down 对当前位进行加减
//   5. 用户长按 load 传入本模块的 load_confirm 后，将设定值 load_* (即 load_hour 等)写入 data_* 输出，
//      由 clock_mode 传给 clock 的 counter 完成实际置数
//
// 与 clock 的区别（counter模块的使用）：
//   clock 中 counter 以 sec_pulse 为使能信号（每秒计一次，用于走时）
//   load_num 中 counter 以按键脉冲（hour_pulse/min_pulse/sec_pulse）为使能
//   （每次按键产生一个脉冲，计数器响应该脉冲直接计一次，用于手动调整）
//
//  状态机说明：
//      1. 数码管显示控制状态机，控制空闲、LOAd显示、编辑置数三状态
//      2. 时分秒脉冲发生状态机，在编辑置数状态下，对choose选择的时或分或秒，输入计数脉冲，并且确定时分秒闪烁显示状态机的状态
//      3. 时分秒闪烁显示状态机  ，在时分秒脉冲发生状态机的控制下，确定被选中的数位进行闪烁的逻辑
//
// 子模块实例：
//   counter * 6
// =============================================================================
module load_num
(
input   wire    mode_en,
input   wire    sys_clk,
input   wire    sec_clk,                // 1Hz时钟，用于控制 LOAd 显示时长，控制 LOAD_EDIT 状态下，被选中的数位闪烁的逻辑
input   wire    rst_n,
input   wire    load_confirm,           // 长按load的信号，在顶层与 load_long_pulse 相连接
input   wire    choose,
input   wire    num_up,
input   wire    num_down,
input   wire    [7:0]   before_second,  // 将 clock 当前的时间输入到 load_num 中
input   wire    [7:0]   before_minute,  // 切换到 load_num 后，显示的时间为按下 load 键时的时间，也就是说用户是用当前时刻的时间开始置数
input   wire    [7:0]   before_hour,
// input   wire    [5:0]   point_out,   // 小数点输出被固定，故不需要输入值


output  reg     [7:0]   data_second,    // 作用是把用户设置的数字输出到clock-counter的置数端口，完成同步置数
output  reg     [7:0]   data_minute,    // 在顶层模块中与 clock 的 data_* 输入口连接
output  reg     [7:0]   data_hour,      // 赋值逻辑在底部
output  wire    [7:0]   disp_second,    // 置数模式下，数码管的显示
output  wire    [7:0]   disp_minute,    // 涵盖 LOAd 、置数值的显示
output  wire    [7:0]   disp_hour  ,    // 赋值逻辑在 data_* 的上方
output  wire    [5:0]   point_out       // 既然是要控制数码管的显示，那就得加上小数点了

);

//  ====================  数码管显示控制状态机  ====================
//定义数码管显示状态机的状态
localparam  LOAD_IDLE = 2'b00;  //IDLE空闲状态
localparam  LOAD_SHOW = 2'b01;  //显示LOAd几个字
localparam  LOAD_EDIT = 2'b10;  //EDIT编辑状态
//定义数码管显示状态机
reg [1:0]   current_load;
//定义置数使能信号
reg set_en;

//定义SHOW状态数码管显示的字符，这些在末尾对 disp_* point_out 赋值时才会用到
localparam  SHOW_EMPTY = 4'd14;  //全空，与seg_dynamic中的设定有关，既用于“ LOAd ”左右两侧数码管的显示，也用于 LOAD_EDIT 状态下，被选中的数位闪烁的显示
localparam  SHOW_L     = 4'd10;  //L，与seg_dynamic中的设定有关
localparam  SHOW_O     = 4'd0 ;  //O，与seg_dynamic中的设定有关
localparam  SHOW_A     = 4'd11;  //A，与seg_dynamic中的设定有关
localparam  SHOW_d     = 4'd12;  //d，与seg_dynamic中的设定有关

//记录sec_clk在上一系统时钟周期的值，用于判断sec_clk的跳沿
reg sec_clk_prev = 1'b1;
// 这里并没有把sec_clk_prev <= sec_clk放在状态机内，
// 是因为若将sec_clk_prev的更新放在状态机的LOAD_SHOW状态内，就切断了它在其他状态下的跟踪，
// 导致进入该状态时“历史值”失真，边沿检测逻辑会立刻误触发，从而显著缩短预期停留时间
always@(posedge sys_clk) sec_clk_prev <= sec_clk;

//用于记录sec_clk的上、下跳沿，从而记录1秒钟
reg up_display;
reg down_display;

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
            if (sec_clk_prev==1'b0 && sec_clk==1'b1) begin
                up_display <= 1'b1;         //遇到上升沿才给使能
                current_load <= LOAD_SHOW;  //维持原态
            end
            else if(sec_clk_prev==1'b1 && sec_clk==1'b0) begin
                down_display <= 1'b1;   //遇到下降沿才给使能
                current_load <= LOAD_SHOW;  //维持原态
            end
            
            if (~mode_en) begin // 如果还在显示 LOAd 时用户就短按 load 切换模式，那么就执行此退出处理
                current_load <= LOAD_IDLE;
                up_display   <= 1'b0;
                down_display <= 1'b0;
                set_en       <= 1'b0;
            end
            else if (up_display==1'b1 && down_display==1'b1) begin
            //两使能齐全才切换模式，保证LOAd至少显示0.5秒，最多不到1秒 - (0.5,1]
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
        
        default:
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
reg [1:0]   twinkle;
localparam  TWINKLE_HOUR = 2'b00;
localparam  TWINKLE_MINUTE = 2'b01;
localparam  TWINKLE_SECOND = 2'b10;

//定义时分秒计数脉冲状态机的状态
localparam  SET_HOUR = 2'b00;
localparam  SET_MINUTE = 2'b01;
localparam  SET_SECOND = 2'b10;
//定义时分秒计数脉冲状态机
reg [1:0]   current_set;
//定义时分秒计数信号脉冲
reg sec_pulse;
reg min_pulse;
reg hour_pulse;

//状态机、时分秒计数脉冲产生
always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        sec_pulse <= 1'b0;
        min_pulse <= 1'b0;      
        hour_pulse <= 1'b0;    
        twinkle <= TWINKLE_HOUR;
        current_set <= SET_HOUR;        
    end
    else begin
        if(set_en) begin               // 使能状态机的使能信号
            case(current_set)
            SET_HOUR:
            begin
                sec_pulse <= 1'b0;
                min_pulse <= 1'b0;
                twinkle <= TWINKLE_HOUR;    // 用于控制该数位闪烁
    
                if((~num_up) || (~num_down))
                    hour_pulse <= 1'b1;
                else
                    hour_pulse <= 1'b0;
                
                // 状态切换
                if(~choose) current_set <= SET_MINUTE;    // choose低有效
                else        current_set <= SET_HOUR;
            end
            SET_MINUTE:
            begin
                sec_pulse <= 1'b0;
                hour_pulse <= 1'b0;
                twinkle <= TWINKLE_MINUTE;    // 用于控制该数位闪烁
    
                if((~num_up) || (~num_down))
                    min_pulse <= 1'b1;
                else
                    min_pulse <= 1'b0;

                // 状态切换
                if(~choose) current_set <= SET_SECOND;
                else        current_set <= SET_MINUTE;
            end        
            SET_SECOND:
            begin
                min_pulse <= 1'b0;
                hour_pulse <= 1'b0;
                twinkle <= TWINKLE_SECOND;    // 用于控制该数位闪烁
            
                if((~num_up) || (~num_down))
                    sec_pulse <= 1'b1;
                else
                        sec_pulse <= 1'b0;
        
                // 状态切换
                if(~choose) current_set <= SET_HOUR;
                else        current_set <= SET_SECOND;
            end        
            default: 
            begin
                sec_pulse <= 1'b0;
                min_pulse <= 1'b0;      
                hour_pulse <= 1'b0; 
                twinkle <= TWINKLE_HOUR;
                current_set <= SET_HOUR;
            end
            endcase
        end
        else begin
            sec_pulse <= 1'b0;
            min_pulse <= 1'b0;      
            hour_pulse <= 1'b0;    
            twinkle <= TWINKLE_HOUR;
            current_set <= SET_HOUR;// set_en 不使能时就切换到 SET_HOUR, 当 set_en 使能进入 LOAD_EDIT 模式，就会默认选择 SET_HOUR
        end
    end
end


  

//  ====================  在 mode_en 使能的跳沿，产生置数信号，将 clock 的值置数到 load_num 界面  ====================
// 对mode_en采用跳沿检测，用于“从 clock 切换到 load_num 时”，对 load_num 界面的值进行置数
reg mode_en_prev = 1'b0;    // mode_en 为高有效，故初值默认为低电平-不使能
always@(posedge sys_clk) mode_en_prev <= mode_en;
// 置数信号，用于 radix_hour 进制决断
reg load_before;
always@(posedge sys_clk)
begin
    if(!rst_n)
        load_before  <= 1'b0;
    else begin
        if(~mode_en_prev && mode_en)
            load_before <= 1'b0;// clock状态
        else
            load_before <= 1'b1;// load_num状态
    end
end
// 延迟一拍置数，用于 counter
reg load_before_d = 1'b0;
always@(posedge sys_clk) load_before_d <= load_before;
// 2026-07之前记录：踩坑记录
// load_num被置数时进制显示bug
// 什么叫“load_num被置数”？即从clock切换到load_num时，load_before发出低电平脉冲，使load_num最初显示的数字是当前时刻的时间，也就是说load_num的counter被colck置数了
/* 这一bug的现象是：
   在load_num界面短按load取消置数的时刻，如果clock的后台走时在4~9或14~19hour，并且置数值为20-23（个位进制：3）（该值已经被显示出来了，但是用户由于某些原因取消了置数），
   当用户在取消置数后，再次短按load回到置数页面（此时clock的时间还要在4~9或14~19），系统根据上次取消置数时的load_hour20~23的个位的3进制，会将load_num初始的hour显示为3或13！
*/
/* 所以方案1是，我们要在load_num被clock置数时，采用 before_hour 决定进制，而在置数时（ mode_en =1）回归上面的用 load_hour 决定进制
   注意此方案只能用时序逻辑，与 clock 中的不一样！并且必须用 mode_en_prev 来判断，不可以用 mode_en !
   因为 load_before 是在 mode_en 上跳沿时生效，如果用 mode_en 来判断用谁决定进制，那么进制决定权从 before_hour 变为 load_hour 与 load_before 在同一时钟周期改变/生效
   而 counter 里为同步置数，即是在 load_before 生效后的下一时钟周期才置数，此时进制决定权已经归属于 load_hour 了。
   所以这里必须延迟一个时钟周期，采用 mode_en_prev 决定进制权的归属。
*/
/* 当然还有方案2，就是取消对mode_en的跳沿检测，让load_before在 mode_en_prev =0时一直生效，即非load_num模式下， load_num 的counter一直在被置数，一直与load_before同步；
   同时取消下面的方案1的进制选择机制，让 radix_hour 决定权只在 load_hour 手里。
*/   
/* 方案1缺点是逻辑较复杂，占用LUT资源略多
   方案2缺点是每秒load_*一直在更新，耗电量略多
   综合权衡后，决定使用代码更简洁的方案2（该方案后来已被下方 2026-09 的新方案替代），
                但是如果将来为了节省那一点点电，可以采取方案1，于是将方案1的代码注释掉、保留！
   
   这也是与进制动态显示的bug在置数模块自身的具体体现，在clock里已经有所体现了，看来进制动态显示真的挺麻烦的。
*/
// 2026-09之后记录：解决方案
/* 其实我当初想出这两个方案时都没抓到本质（方案1碰巧对了一半，但是没想到 load_before 也要延迟），
   包括我在 clock 模块中遇到的问题（当 clock 的小时为20-23，置数界面的小时设定为 4-9/14-19，确认置数后，clock显示的小时个位会被钳位到3），
   以及 alarm 进制问题，都是一样的：进制是"值"的属性，不是"计数器"的属性，以下是解释：
   时钟走时、置数上下调整时间、闹钟上下调整时间，这些正常计数时，进制天然跟随当前值，所以我把 radix_hour 很自然地建模成"跟随 counter 输出的寄存器"
   但是这一套在“计数”完全成立的逻辑，放到“置数时刻”，此时进制还是由 counter 输出决定，而非装入 counter 的置数值，就会出现问题。
   正确的逻辑是：“计数”时，进制由 counter 输出决定，置数时，进制由置数值决定。
   我在最后一个主模块 alarm 的编写中第一次领悟到这一点，现在才把它迁移到 load_num 和 clock 中。
*/
/* 另外，置数信号（统称为 load ）必须先到达进制判断模块，晚一拍到达 counter ，这样 counter 接收到的进制才是正确的值
   否则，load 同拍到达 进制判断模块、 counter 两个 always 块， counter 读取的进制值是 load 沿前的 进制值，而沿后的值才是正确的进制
*/

//  ====================  六次实例化counter，并设计加减计数的小时个位进制动态显示  ====================
//定义进位信号中间值
wire    [5:0]   RCO;
//定义置数中间值
wire [7:0]   load_hour;     // counter 模块直接输出的值
wire [7:0]   load_minute;   // LOAD_EDIT 模式下赋值给 ready_*
wire [7:0]   load_second;   // 确认置数时赋值给 data_*
wire [5:0]   load_point;
//定义置数值显示中间值
reg  [7:0]   ready_hour;    // 这些“中间值”是 LOAD_EDIT 模式下，数字的显示，经 MUX 直接连接 disp_* (即 disp_hour 等)
reg  [7:0]   ready_minute;  // 受到“闪烁”逻辑的赋值，假如 hour 被选中，则 ready_hour 前半秒灭，后半秒显示 load_hour
reg  [7:0]   ready_second;

//定义中间变量，设置“时”的个位的进制
reg  [3:0]   radix_hour;
reg  [3:0]   radix_hour_up;
reg  [3:0]   radix_hour_down;
// 加计数进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        radix_hour_up <= 4'b1001;
    else if(~num_up && load_hour[7:4]==4'b0010)
        radix_hour_up <= 4'b0011;
    else if(~num_up && (load_hour[7:4]==4'b0001 || load_hour[7:4]==4'b0000))
        radix_hour_up <= 4'b1001;
end
// 减计数进制动态显示
always@(posedge sys_clk)
begin
    if(!rst_n)
        radix_hour_down <= 4'b1001;
    else if(~num_down && (load_hour==8'b0000_0000 || load_hour[7:4]==4'b0010) && load_hour!=8'b0010_0000)    
        radix_hour_down <= 4'b0011;             // 十位为2时，除了20，其余个位均为3进制; 个位十位为00时，个位也为三进制
    else if(~num_down && (load_hour[7:4]==4'b0000 || load_hour[7:4]==4'b0001 || load_hour==8'b0010_0000) && load_hour!=8'b0000_0000)
        radix_hour_down <= 4'b1001;
end

// 进制最终决定
// 注意：由于个位的进制是由两个 always 块决定，信号流水线式传递，所以第二级 always 要接收延迟一拍的 num_up num_down
reg num_up_d = 1'b1;
reg num_down_d = 1'b1;
always@(posedge sys_clk)    num_up_d <= num_up;
always@(posedge sys_clk)    num_down_d <= num_down;
always@(posedge sys_clk)
begin
    if(!rst_n)
        radix_hour <= radix_hour_up;
    else if(~load_before)   // 置数瞬间，进制权交给 clock 的值
        begin
        if(before_hour[7:4]==4'b0010)
            radix_hour <= 4'b0011;
        else if(before_hour[7:4]==4'b0001 || before_hour[7:4]==4'b0000)
            radix_hour <= 4'b1001;
        end
    else if(~num_up_d)  // 其余时刻，进制权交给 上下计数 按键
        radix_hour <= radix_hour_up;
    else if(~num_down_d)
        radix_hour <= radix_hour_down;
    else
        radix_hour <= radix_hour;
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

// 由于小时个位进制的决定由两个 always 块决定，所以其 hour_pulse 也要延迟一个时钟周期
// 小时十位不必像 alarm 一样加延迟，因为 load_num 不存在 edit_hour==8'hFF 导致的进制 radix_hour_lo 残留 F 或类似的情况
// alarm 中的 radix_hour_lo （小时低位的进制）对应本模块 radix_hour
reg hour_pulse_d = 1'b0;
always@(posedge sys_clk)    hour_pulse_d <= hour_pulse;
//实例化
counter sec0(sys_clk,sec_pulse, rst_n,load_before_d,before_second[3:0],4'b1001,   1'b1  ,1'b0,count_direction,load_second[3:0],RCO[0],load_point[0]),
        sec1(sys_clk,sec_pulse, rst_n,load_before_d,before_second[7:4],4'b0101,   RCO[0],1'b0,count_direction,load_second[7:4],RCO[1],load_point[1]),

        min0(sys_clk,min_pulse, rst_n,load_before_d,before_minute[3:0],4'b1001,   1'b1  ,1'b1,count_direction,load_minute[3:0],RCO[2],load_point[2]),
        min1(sys_clk,min_pulse, rst_n,load_before_d,before_minute[7:4],4'b0101,   RCO[2],1'b0,count_direction,load_minute[7:4],RCO[3],load_point[3]),

        hor0(sys_clk,hour_pulse_d,rst_n,load_before_d,before_hour[3:0],radix_hour,1'b1  ,1'b1,count_direction,load_hour[3:0],  RCO[4],load_point[4]),
        hor1(sys_clk,hour_pulse,  rst_n,load_before_d,before_hour[7:4],4'b0010,   RCO[4],1'b0,count_direction,load_hour[7:4],  RCO[5],load_point[5]);




//  ====================  LOAD_EDIT编辑置数状态，时分秒闪烁显示状态机  ====================
// 变量声明：twinkle、TWINKLE_HOUR等在上一个时分秒计数脉冲状态机，主要是这些变量受该状态机控制
// 控制置数时的数字显示，当mode_en使能时，将当前时刻时钟的值赋予ready_*
always@(posedge sys_clk)
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
            if(sec_clk)         ready_hour <= {SHOW_EMPTY,SHOW_EMPTY};
            else if(~sec_clk)   ready_hour <= load_hour; // sec_clk 低电平时输出正常数字，高电平时传入 4'hE ，即全灭
        end
        TWINKLE_MINUTE:
        begin
            ready_hour <= load_hour; ready_second <= load_second;
            if(sec_clk)         ready_minute <= {SHOW_EMPTY,SHOW_EMPTY};
            else if(~sec_clk)   ready_minute <= load_minute;
        end
        TWINKLE_SECOND:
        begin
            ready_hour <= load_hour; ready_minute <= load_minute;
            if(sec_clk)         ready_second <= {SHOW_EMPTY,SHOW_EMPTY};
            else if(~sec_clk)   ready_second <= load_second;   
        end
        default: begin  // 与TWINKLE_HOUR相同
            ready_minute <= load_minute; ready_second <= load_second;
            if(sec_clk)         ready_hour <= {SHOW_EMPTY,SHOW_EMPTY};
            else if(~sec_clk)   ready_hour <= load_hour;
        end
    endcase
end
end

// 数显控制，模式为 LOAD_SHOW 时，显示 LOAd; 模式为 LOAD_EDIT 时显示 ready_*; 
//           模式为 LOAD_IDLE 时，显示为负号--（seg_dynamic编码，F 4'd15为负号）
assign  disp_hour   = (mode_en && current_load==LOAD_SHOW) ? {SHOW_EMPTY, SHOW_L} : 
                      (mode_en && current_load==LOAD_EDIT) ? ready_hour           :
                      8'hFF;   // 增加完全关闭时的保护：mode_en使能且LOAD_IDLE待机时，或者干脆没使能时，都为FF，seg_dynamic编码为负号
assign  disp_minute = (mode_en && current_load==LOAD_SHOW) ? {SHOW_O, SHOW_A}     : 
                      (mode_en && current_load==LOAD_EDIT) ? ready_minute         :
                      8'hFF;
assign  disp_second = (mode_en && current_load==LOAD_SHOW) ? {SHOW_d, SHOW_EMPTY} : 
                      (mode_en && current_load==LOAD_EDIT) ? ready_second         :
                      8'hFF;                 
assign  point_out = load_point;



//  ====================  进行置数  ====================
always@(posedge sys_clk)
begin
    if(!rst_n)
    begin
        data_hour   <= before_hour  ;
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
    end
    else begin
        data_hour   <= before_hour  ;
        data_minute <= before_minute;
        data_second <= before_second;
    end
end

endmodule