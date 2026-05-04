// =============================================================================
// 文件名：load_num.v
// 功能：置数交互模块，允许用户通过按键手动设定时分秒
//
// 工作流程（待完善，当前仅实现置数值输出，显示交互尚未完成）：
//   1. 由 clock_mode 的 mode_load_en 使能后进入工作状态
//   2. 用户通过 choose 键切换当前设置的位（时→分→秒→时循环）
//   3. 用户通过 num_up/num_down 对当前位进行加减
//   4. 用户长按 load_confirm 后，将设定值写入 data_* 输出，
//      由 clock_mode 传给 clock 的 counter_time 完成实际置数
//
// 与 clock.v 中 counter_time 的区别：
//   clock.v 中 counter 以 sec_pulse 为使能信号（每秒计一次，用于走时）
//   load_num 中 counter 以按键脉冲（hor_pulse/min_pulse/sec_pulse）为时钟
//   （每次按键产生一个脉冲，计数器响应该脉冲直接计一次，用于手动调整）
//
// ⚠ 注意：
//   当前 sys_clk 端口由 clock_mode 传入门控时钟（sys_clk && mode_load_en），
//   后续需要改为：sys_clk 直通 + 新增 mode_en 输入端口（时钟使能内部化）。
//
//   load_num 内部的 divider 实例化已移除，sec_clk 改为从顶层传入（来自 sys_divider）。
//
// 子模块实例：
//   counter（×6，同 counter_time，但以按键脉冲为时钟）
//   seg_dynamic、hc595_ctrl（置数模式专用显示链）
// =============================================================================
module load_num
(
input   wire    mode_en,
input   wire    sys_clk,
input   wire    pre_clk,
input   wire    sec_clk,
input   wire    reset,
input   wire    load,
input   wire    load_confirm,
input   wire    choose,
input   wire    num_up,
input   wire    num_down,
input   wire    [7:0]   before_second,
input   wire    [7:0]   before_minute,
input   wire    [7:0]   before_hour,    //在时间置数中为当前时间，在闹钟置数中为上次设定的闹钟值
input   wire    [5:0]   point_out,


output  reg     [7:0]   data_second,
output  reg     [7:0]   data_minute,
output  reg     [7:0]   data_hour,
output  wire    stcp,
output  wire    shcp,
output  wire    ds,
output  wire    oe
);

//load或load_confirm（确认置数）后，都进行一次复位
// // // reg reset_n = 1'b1;
// // // reg reset_n_count = 1'b0;
// // // always@(posedge sys_clk)
// // // begin
    // // // if(!reset) begin
        // // // reset_n <= reset;
        // // // reset_n_count <= 1'b0;
    // // // end
    // // // else begin
        // // // if(mode_en) begin               // 使能信号
            // // // if(load==1'b0) begin
                // // // if(reset_n_count==1'b0) begin
                    // // // reset_n <= 1'b0;
                    // // // reset_n_count <= 1'b1;
                // // // end
                // // // else if(reset_n_count==1'b1) begin
                    // // // reset_n <= 1'b1;
                    // // // reset_n_count <= 1'b1;
                // // // end
            // // // end  
            // // // else if(load==1'b1) begin
                // // // reset_n <= 1'b1;
                // // // reset_n_count <= 1'b0;
            // // // end
        // // // end
// // // //        else  // 非使能时就不写else了，一方面是不写的话，系统综合后就是“维持原值”，符合预期，
                // // // //另一方面是写的话要就得写两行，还得添加begin、end，麻烦！
    // // // end
// // // end
wire reset_n;
assign reset_n = reset;





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
always@(posedge sys_clk)
begin
    if(reset==1'b0)
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
    if(!reset_n)
    begin
        current_load <= LOAD_IDLE;
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
            set_en <= 1'b0;
            
        end
   
        endcase
    end
end


// 控制置数时的数字显示，状态机在实例化counter的下面
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
    if(reset==1'b0) begin
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
    if(reset==1'b0)                                     choose_pulse <= 1'b1;
    else if(choose_pulse_prev==1'b1 & choose==1'b0)     choose_pulse <= 1'b0;
    else                                                choose_pulse <= 1'b1;
end
always@(posedge sys_clk) begin
    if(reset==1'b0)                                     num_up_pulse <= 1'b1;
    else if(num_up_pulse_prev==1'b1 & num_up==1'b0)     num_up_pulse <= 1'b0;
    else                                                num_up_pulse <= 1'b1;
end
always@(posedge sys_clk) begin
    if(reset==1'b0)                                     num_down_pulse <= 1'b1;
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
// // // //对时/分/秒进行选择
// // // always@(posedge choose)
// // // begin
    // // // if(!reset_n)
        // // // current_set <= 2'b00;
    // // // else begin
        // // // if(set_en) begin               // 使能状态机的使能信号
            // // // if(current_set == 2'b10)
                // // // current_set <= 2'b0;
            // // // else
                // // // current_set <= current_set + 1'b1;
        // // // end
        // // // else current_set <= current_set // 非使能时维持原值
    // // // end
// // // end
//定义时分秒计数信号脉冲
reg sec_pulse = 1'b0;
reg min_pulse = 1'b0;
reg hor_pulse = 1'b0;
//num_up与num_down采用跳沿检测
reg num_up_prev = 1'b1;
reg num_down_prev = 1'b1;//默认按键未按下
//在set_en第一次使能时，“按下”load_before，将此时的时间输出到数码管
reg load_before_cnt = 1'b0; //load_before只能按一次
reg load_before = 1'b1;


//状态机、时分秒计数脉冲产生
always@(posedge sys_clk)
begin
    if(!reset_n)
    begin
        load_before_cnt <= 1'b0;
        load_before     <= 1'b1;
        current_set     <= SET_HOUR;
        num_up_prev     <= 1'b1;
        num_down_prev   <= 1'b1;
        sec_pulse <= 1'b0;
        min_pulse <= 1'b0;      
        hor_pulse <= 1'b0;         
    end
    else begin 
    if(set_en) begin               // 使能状态机的使能信号
        //第一个时钟周期进行一次置数，把按下set_en使能后的时间进行显示
        if (load_before_cnt==1'b0)begin
            load_before <= 1'b0;
            load_before_cnt<=1'b1;
        end
        else
            load_before <= 1'b1;
    
        case(current_set)
        SET_HOUR:
        begin
            num_up_prev <= num_up;
            num_down_prev <= num_down;
            sec_pulse <= 1'b0;
            min_pulse <= 1'b0;
            twinkle <= TWINKLE_HOUR;    // 用于控制该数位闪烁

            // if((num_up_prev==1'b1&&num_up==1'b0) || (num_down_prev==1'b1&&num_down==1'b0))
                // hor_pulse <= 1'b1;
            // else if(((num_up_prev==1'b0&&num_up==1'b1) || (num_down_prev==1'b0&&num_down==1'b1)))
                // hor_pulse <= 1'b0;
            // else
                // hor_pulse <= hor_pulse;
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
            num_up_prev <= num_up;
            num_down_prev <= num_down;
            sec_pulse <= 1'b0;
            hor_pulse <= 1'b0;
            twinkle <= TWINKLE_MINUTE;    // 用于控制该数位闪烁

            if((num_up_prev==1'b1&&num_up==1'b0) || (num_down_prev==1'b1&&num_down==1'b0))
                min_pulse <= 1'b1;
            else if(((num_up_prev==1'b0&&num_up==1'b1) || (num_down_prev==1'b0&&num_down==1'b1)))
                min_pulse <= 1'b0;
            else
                min_pulse <= min_pulse;
            if(~choose_pulse) current_set <= SET_SECOND;    // choose低有效
        end        
        SET_SECOND:
        begin
            num_up_prev <= num_up;
            num_down_prev <= num_down;
            min_pulse <= 1'b0;
            hor_pulse <= 1'b0;
            twinkle <= TWINKLE_SECOND;    // 用于控制该数位闪烁
        
            if((num_up_prev==1'b1&&num_up==1'b0) || (num_down_prev==1'b1&&num_down==1'b0))
                sec_pulse <= 1'b1;
            else if(((num_up_prev==1'b0&&num_up==1'b1) || (num_down_prev==1'b0&&num_down==1'b1)))
                sec_pulse <= 1'b0;
            else
                sec_pulse <= sec_pulse;
            if(~choose_pulse) current_set <= SET_HOUR;//    choose低有效
        end        
        default: //----------------------后期应当修改------------------------------
        begin
            num_up_prev <= num_up;
            num_down_prev <= num_down;
            sec_pulse <= 1'b0;
            min_pulse <= 1'b0;
        
            if((num_up_prev==1'b1&&num_up==1'b0) || (num_down_prev==1'b1&&num_down==1'b0))
                hor_pulse <= 1'b1;
            else if(((num_up_prev==1'b0&&num_up==1'b1) || (num_down_prev==1'b0&&num_down==1'b1)))
                hor_pulse <= 1'b0;
            else
                hor_pulse <= hor_pulse;
        end
    
        endcase
    end // 这是使能信号 if(mode_en) begin 的结束，就不按Tab缩进了
    end
end


//定义进位信号中间值
wire    [5:0]   RCO_zhong;
//定义置数中间值
wire [7:0]   load_hour;
wire [7:0]   load_minute;
wire [7:0]   load_second;
//将中间值暂存下来
reg  [7:0]   ready_hour = 8'b00;
reg  [7:0]   ready_minute = 8'b00;
reg  [7:0]   ready_second = 8'b00;

//定义中间变量，设置“时”的个位的进制
reg [3:0]   hour_radix = 4'b1001;
always@(posedge sys_clk)
begin
    if(!reset_n)
    hour_radix <= 4'b1001;
    else if(hor_pulse && ready_hour[7:4]==4'b0010)
    hour_radix <= 4'b0011;
    else if(hor_pulse && (ready_hour[7:4]==4'b0001)||(ready_hour[7:4]==4'b0000))
    hour_radix <= 4'b1001;
    else
    hour_radix <= hour_radix;
end

//实例化
counter sec0(sys_clk,sec_pulse,reset_n,load_before,before_second[3:0],4'b1001,   1'b1        ,1'b0,mode_updown,load_second[3:0],RCO_zhong[0], ),
        sec1(sys_clk,sec_pulse,reset_n,load_before,before_second[7:4],4'b0101,   RCO_zhong[0],1'b0,mode_updown,load_second[7:4],RCO_zhong[1], ),
             
        min0(sys_clk,min_pulse,reset_n,load_before,before_minute[3:0],4'b1001,   1'b1        ,1'b1,mode_updown,load_minute[3:0],RCO_zhong[2], ),
        min1(sys_clk,min_pulse,reset_n,load_before,before_minute[7:4],4'b0101,   RCO_zhong[2],1'b0,mode_updown,load_minute[7:4],RCO_zhong[3], ),
             
        hor0(sys_clk,hor_pulse,reset_n,load_before,before_hour[3:0],  hour_radix,1'b1        ,1'b1,mode_updown,load_hour[3:0],  RCO_zhong[4], ),
        hor1(sys_clk,hor_pulse,reset_n,load_before,before_hour[7:4],  4'b0010,   RCO_zhong[4],1'b0,mode_updown,load_hour[7:4],  RCO_zhong[5], );
// 注：从右往左数第1个数字代表着counter的point_in输入口，此端口其实不需要输入，但是未用的输入端口则必须提供一个确定的值
// 而最右侧的输出端口point_out_counter也不需要，就暂时悬空

// 控制置数时的数字显示，
always@(posedge sys_clk)         // 状态机牛逼！！！
begin
if(!reset_n)begin
    ready_minute <= load_minute; 
    ready_second <= load_second;
    ready_hour <= load_hour;
end
else begin
    case(twinkle)
        TWINKLE_HOUR:
        begin
            ready_minute <= load_minute; ready_second <= load_second;
            if(sec_clk)         ready_hour <= 4'd14;
            else if(~sec_clk)   ready_hour <= load_hour; // sec_clk高电平时输出正常数字，低电平时传入31，即全灭
        end
        TWINKLE_MINUTE:
        begin
            ready_hour <= load_hour; ready_second <= load_second;
            if(sec_clk)         ready_minute <= 4'd14;
            else if(~sec_clk)   ready_minute <= load_minute; // sec_clk高电平时输出正常数字，低电平时传入31，即全灭
        end
        TWINKLE_SECOND:
        begin
            ready_hour <= load_hour; ready_minute <= load_minute;
            if(sec_clk)         ready_second <= 4'd14;
            else if(~sec_clk)   ready_second <= load_second; // sec_clk高电平时输出正常数字，低电平时传入31，即全灭    
        end
        default: begin  // 与TWINKLE_HOUR相同
            ready_minute <= load_minute; ready_second <= load_second;
            if(sec_clk)         ready_hour <= 4'd14;
            else if(~sec_clk)   ready_hour <= load_hour;
        end
    endcase
end
end

// 进行置数
always@(posedge sys_clk)
begin
    if(!reset_n)
    begin
        data_hour <= before_hour;
        data_minute <= before_minute;
        data_second <= before_second;
    end
    else if(mode_en) begin               // 使能信号
        if(!load_confirm)
        begin
            data_hour <= ready_hour;
            data_minute <= ready_minute;
            data_second <= ready_second;
        end
        else
        begin
            data_hour <= before_hour;
            data_minute <= before_minute;
            data_second <= before_second;
        end
    end
end

////复位与置数
////别忘了添加使能信号mode_en
//always@(posedge sec_clk)
//begin
//    if(!reset)
//    begin
//        current_set <= SET_HOUR;
//        ready_hour <= 8'b0;
//        ready_minute <= 8'b0;
//        ready_second <= 8'b0;
//    end
//    else if(load)
//    begin
//        ready_hour   <= before_hour;
//        ready_minute <= before_minute;
//        ready_second <= before_second;
//    end
//end





//子模块连线声明
wire    [5:0]   sel;
wire    [7:0]   seg;
// // 数显控制，模式为LOAD_SHOW时，显示LOAd
// wire    [7:0]   disp_hour   = (current_load==LOAD_SHOW) ? {SHOW_EMPTY, SHOW_L} : ready_hour;
// wire    [7:0]   disp_minute = (current_load==LOAD_SHOW) ? {SHOW_O, SHOW_A}     : ready_minute;
// wire    [7:0]   disp_second = (current_load==LOAD_SHOW) ? {SHOW_d, SHOW_EMPTY} : ready_second;
// 增加完全关闭时的保护
wire    [7:0]   disp_hour   = (mode_en && current_load==LOAD_SHOW) ? {SHOW_EMPTY, SHOW_L} : 
                              (mode_en ? ready_hour : 8'hFF);
wire    [7:0]   disp_minute = (mode_en && current_load==LOAD_SHOW) ? {SHOW_O, SHOW_A}     : 
                              (mode_en ? ready_minute : 8'hFF);
wire    [7:0]   disp_second = (mode_en && current_load==LOAD_SHOW) ? {SHOW_d, SHOW_EMPTY} : 
                              (mode_en ? ready_second : 8'hFF);

//数码管动态显示模块
seg_dynamic     load_num_seg_dynamic
(
    .sys_clk            (sys_clk   ),
    .pre_clk            (pre_clk    ),
    .sec_clk            (sec_clk   ),                
    .reset              (reset_n   ),
    .out_second         (disp_second),
    .out_minute         (disp_minute),
    .out_hour           (disp_hour  ),
    .point_out          (point_out  ),

    .sel                (sel       ),  
    .seg                (seg       )   
);  

//74HC595控制模块
hc595_ctrl      load_num_hc595_ctrl
(
    .sys_clk            (sys_clk),
    .reset              (reset_n),
    .sel                (sel    ),
    .seg                (seg    ),

    .stcp               (stcp   ),           
    .shcp               (shcp   ),           
    .ds                 (ds     ),             
    .oe                 (oe     )
);

endmodule