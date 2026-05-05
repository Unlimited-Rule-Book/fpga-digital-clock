// =============================================================================
// 文件名：clock_mode.v
// 功能：顶层控制模块，负责模式切换、信号路由、数码管显示
//
// 模式定义（MODE状态机，2位）：
//   MODE_CLOCK（2'b00）：正常走时显示模式（上电默认）
//   MODE_LOAD （2'b01）：时间置数模式
//   MODE_ALARM（2'b10）：闹钟设置模式（功能待完善）
//
// 按键功能说明：
// ┌─────────────────────────────────────────────────────────────────┐
// │  当前模式     │  操作           │  效果                         │
// ├─────────────────────────────────────────────────────────────────┤
// │  时钟模式     │  短按 load      │  进入置数模式                 │
// ├─────────────────────────────────────────────────────────────────┤
// │  置数模式     │  短按 load      │  进入闹钟模式                 │
// │  置数模式     │  长按 load      │  确认置数，返回时钟模式       │
// │  置数模式     │  16s 无操作     │  超时，返回时钟模式(置数取消) │
// │  置数模式     │  短按 choose    │  （在 load_num 中）切换设置位 │
// │  置数模式     │  短按 num_up    │  （在 load_num 中）当前位+1   │
// │  置数模式     │  短按 num_down  │  （在 load_num 中）当前位-1   │
// ├─────────────────────────────────────────────────────────────────┤
// │  闹钟模式     │  短按 load      │  返回时钟模式                 │
// │  闹钟模式     │  长按 load      │  返回时钟模式                 │
// │  闹钟模式     │  16s 无操作     │  超时，返回时钟模式           │
// │  闹钟模式     │  各按键         │  闹钟置数（功能待完善）       │
// └─────────────────────────────────────────────────────────────────┘
// 总结：load键：短按在不同模式之间切换，长按确认
//
// 注意事项：
//   1. clock 子模块始终在后台运行，
//      置数和闹钟模式不会暂停走时，退出后显示的是实际流逝后的时间。
//   2. 输出信号选择： 状态机控制 disp_second/disp_minute/disp_hour/point_disp 的来源，
//      两个子系统的显示输出通过 OR 门合并，同一时刻只有一路处于使能状态。
//   3. 三种模式在顶层共用一套seg_dynamic、hc595_ctrl模块，用状态机对模块输出的数字进行控制
// 子模块实例：
//   my_pll_divider（IP核）、sys_divider、
//   button_stabilization（×3）、button_stabilization_long_short（×1）、
//   clock、load_num、
//   seg_dynamic（6位8段数码管动态扫描）、hc595_ctrl（74HC595串行输出驱动）
// =============================================================================
module clock_mode               //时钟的顶层封装模块：模式调整
(
//  ------  顶层入口（直接连接）  ------  
input   wire    sys_clk,        //全局时钟，50MHz
input   wire    rst_n_input,      //复位信号
input   wire    load,       //置数信号
input   wire    choose,
input   wire    num_up,
input   wire    num_down,

output  wire    stcp,
output  wire    shcp,
output  wire    ds,  
output  wire    oe   
);


//  ====================  实例化PLL IP核  ====================
wire sys_clk_1mhz;
wire locked_sig;
// 系统时钟PLL输出1MHz
my_pll_divider	my_pll_divider_inst (
	.areset ( ~rst_n_input ),      // 我的系统复位低有效，而PLL复位高有效，所以这里这么写？
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
sys_divider clock_mode_divider
(
    .sys_clk  (sys_clk      ),
    .pre_clk  (sys_clk_1mhz ),
    .rst_n    (rst_n        ),
    
    .pulse_1ms(pulse_1ms    ),
    .pulse_1s (pulse_1s     ),   // → clock-counter_time-counter的使能时钟
    .sec_clk  (sec_clk      )    // → clock里小数点和load_num置数和显示load几个字时用

);




//  ====================  实例化按键消抖、按键消抖长短按模块  ====================
// 按键消抖（短按）
// 注意！！改变消抖时间，修改实例化时的参数即可，无需关心内部计数
wire    choose_bs;
wire    num_up_bs;
wire    num_down_bs; 
// 按键消抖模块接口已改为pulse_1ms计数，参数单位为ms
button_stabilization #(.DEBOUNCE_MS(20))        // 为了test bench从20ms改成2ms======================================================
                        // DEBOUNCE_MS千万别改成1ms，在模块内部DEBOUNCE_CNT_MAX会变成0，导致1.消抖逻辑失效；2.debounce_counter的位宽会变成[-1,0]，被系统解析为1bit
                        choose_b_s   (sys_clk, pulse_1ms, rst_n, choose, choose_bs),
                        num_up_b_s   (sys_clk, pulse_1ms, rst_n, num_up, num_up_bs),
                        num_down_b_s (sys_clk, pulse_1ms, rst_n, num_down, num_down_bs);
// 按键消抖+短按检测（大于20ms小于500ms）+长按3秒检测  
// 注意！！改变消抖时间和长短按时长，修改实例化时的参数即可，无需关心内部计数 
// 从按键消抖模块中取出的长短按load
wire    load_bs_s;                  // 短按信号其实对load_num模块没有直接作用！=====================================
wire    load_bs_l;
// 按键消抖+长短按模块接口已改为pulse_1ms计数，LONG_PRESS_MS单位为ms
button_stabilization_long_short #(.DEBOUNCE_MS(20), .SHORT_END_MS(500), .LONG_PRESS_MS(3000)) // 为了test bench短按从20ms改成2ms，短按停止从500改成5，长按判定从3000改成7==============================================
                                    // // DEBOUNCE_MS千万别改成1ms，在模块内部DEBOUNCE_CNT_MAX会变成0，导致1.消抖逻辑失效；2.NBA冲突，使得short_counter被持续拉高；3.debounce_counter的位宽会变成[-1,0]，被系统解析为1bit
load_b_s_l_s    
(
    .sys_clk        (sys_clk),    
    .pre_clk        (sys_clk_1mhz),  
    .rst_n          (rst_n),      
    .button_in      (load),  
    
    .short_press    (load_bs_s),
    .long_press     (load_bs_l) 
);
// 长短按load脉冲         
reg     load_s_pulse;
reg     load_l_pulse;
// 记录上次长短按信号，以便产生脉冲
reg    load_bs_s_prev;
reg    load_bs_l_prev;
// 长短按load脉冲产生                    
always@(posedge sys_clk) begin
    if(!rst_n)begin
        load_s_pulse <= 1'b1;
        load_bs_s_prev <= 1'b1;
    end
    else if(load_bs_s_prev==1'b1 && load_bs_s==1'b0)begin
        load_s_pulse <= 1'b0;
        load_bs_s_prev <= load_bs_s;
    end
    else begin
        load_s_pulse <= 1'b1;
        load_bs_s_prev <= load_bs_s;
    end
end
always@(posedge sys_clk) begin
    if(!rst_n)begin
        load_l_pulse <= 1'b1;
        load_bs_l_prev <= 1'b1;
    end
    else if(load_bs_l_prev==1'b1 && load_bs_l==1'b0)begin
        load_l_pulse <= 1'b0;
        load_bs_l_prev <= load_bs_l;
    end
    else begin
        load_l_pulse <= 1'b1;
        load_bs_l_prev <= load_bs_l;
    end
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

////对状态进行选择//-----------------------单按load选择时钟、置数、闹钟模式，长按确认置数、闹钟的输入---------------

// 置数模式、闹钟模式使能信号，时钟模式不需要
reg mode_load_en = 1'b0;
reg mode_alarm_en = 1'b0;
// 对不同模式的输入输出进行使能
// 置数、闹钟模式的输入需要控制，时钟的输入不可控制
// 输入控制
// 时钟模式没有外部按键输入
// 置数模式
reg     choose_load_num  ;
reg     num_up_load_num  ;
reg     num_down_load_num;
// 闹钟模式========================================================================
// reg     choose_alarm   ;
// reg     num_up_alarm   ;
// reg     num_down_alarm ;


// 输出控制  
// 时钟模式
wire    [7:0]   disp_second_clock;
wire    [7:0]   disp_minute_clock;
wire    [7:0]   disp_hour_clock  ;
wire    [5:0]   point_disp_clock ; 
// 置数模式
wire    [7:0]   disp_second_num;
wire    [7:0]   disp_minute_num;
wire    [7:0]   disp_hour_num  ;
wire    [5:0]   point_disp_num ; 
// 闹钟模式========================================================================
// wire    [7:0]   disp_second_alarm;
// wire    [7:0]   disp_minute_alarm;
// wire    [7:0]   disp_hour_alarm  ;
// wire    [5:0]   point_disp_alarm ;


// 向seg_dynamic汇总输出时分秒数字
reg     [7:0]   disp_second;
reg     [7:0]   disp_minute;
reg     [7:0]   disp_hour  ;
reg     [5:0]   point_disp ;


//模式选择模块
//定义状态机状态
localparam  MODE_CLOCK = 2'b00;
localparam  MODE_LOAD = 2'b01;
localparam  MODE_ALARM = 2'b10;
//定义状态机
reg [1:0]   MODE = MODE_CLOCK;


// load_num、alarm模式：若16秒内无按键输入，自动切换回clock模式
// parameter CLK_FREQ = 50_000_000;   // 时钟频率50MHz
parameter PULSE_1MS = 1_000;// 1ms脉冲驱动
parameter COUNTER_16S_TIME = 16;     // 长按时间16秒
localparam COUNTER_16S_COUNT = PULSE_1MS * COUNTER_16S_TIME;      // 16秒计数值
reg [$clog2(COUNTER_16S_COUNT)-1:0]  counter_16s=0;
//采用跳沿检测按键输入变化
reg [2:0]   button_prev=3'b111;      //记录输入信号之前的值（num_up、num_down、choose），按系统时钟更新
wire[2:0]   button_now;
assign      button_now={choose_bs,num_up_bs,num_down_bs};//现在的值，实时更新

//状态机
always@(posedge sys_clk)
begin
    if(!rst_n)begin
        MODE <= MODE_CLOCK;
        counter_16s <= 0;
        button_prev <= 3'b111;
        // 使能控制
        mode_load_en <= 1'b0;
        mode_alarm_en <= 1'b0;
        // 输入控制
        choose_load_num  <= 1'b1;
        num_up_load_num  <= 1'b1;
        num_down_load_num<= 1'b1;
        // 输出控制
        disp_second <= disp_second_clock;
        disp_minute <= disp_minute_clock;
        disp_hour   <= disp_hour_clock  ;
        point_disp  <= point_disp_clock ; 
        
    end
    else begin
        case(MODE)
        MODE_CLOCK:
        begin
            // 使能控制
            mode_load_en <= 1'b0;
            mode_alarm_en <= 1'b0;
            // 输入控制
            choose_load_num  <= 1'b1;
            num_up_load_num  <= 1'b1;
            num_down_load_num<= 1'b1;
            // 输出控制
            disp_second <= disp_second_clock;
            disp_minute <= disp_minute_clock;
            disp_hour   <= disp_hour_clock  ;
            point_disp  <= point_disp_clock ;
            // 模式切换
            if(~load_s_pulse)begin
                MODE <= MODE_LOAD;
            end
            else begin
                MODE <= MODE;
            end
        end
        
        MODE_LOAD:
        begin
            // 使能控制
            mode_load_en <= 1'b1;
            mode_alarm_en <= 1'b0;
            // 输入控制
            choose_load_num  <= choose_bs;
            num_up_load_num  <= num_up_bs;
            num_down_load_num<= num_down_bs;
            //输出控制
            disp_second <= disp_second_num;
            disp_minute <= disp_minute_num;
            disp_hour   <= disp_hour_num  ;
            point_disp  <= point_disp_num ;
            // 模式切换
            button_prev <= {choose_bs,num_up_bs,num_down_bs};
            if(load_s_pulse==1'b0&&load_l_pulse==1'b1)begin//load短按，切换为闹钟模式
                    counter_16s <= 0;
                    // 测试load_num阶段，禁用alarm======================================================================================
                    // // // MODE <= MODE_ALARM;
                    MODE <= MODE_CLOCK;
            end
            
            else if(load_s_pulse==1'b1&&load_l_pulse==1'b0)begin//load长按，切换为时钟模式
                    counter_16s <= 0;
                    MODE <= MODE_CLOCK;
            end            
            
            else if(button_now != button_prev)       
                 counter_16s <= 0;           
            else if(button_now == button_prev && counter_16s < COUNTER_16S_COUNT)begin
                if (pulse_1ms) counter_16s <= counter_16s + 1'b1;
            end // 这里的begin-end必须加，否则下一行的else就会匹配if(pulse_1ms)而不会匹配正确的if
            else if(button_now == button_prev && counter_16s >= COUNTER_16S_COUNT)begin
                counter_16s <= 0;
                MODE <= MODE_CLOCK;
            end
            else begin
                counter_16s <= counter_16s;
                MODE <= MODE;
            end
        end
    
    
    // 测试load_num阶段，禁用alarm
        // // // MODE_ALARM:
        // // // begin
        
            // // // //同上，输入输出控制
        

        // // // end
        
        
        
        default:    //default：时钟模式
        begin
            // 使能控制
            mode_load_en <= 1'b0;
            mode_alarm_en <= 1'b0;
            // 输入控制
            choose_load_num  <= 1'b1;
            num_up_load_num  <= 1'b1;
            num_down_load_num<= 1'b1;
            // 输出控制
            disp_second <= disp_second_clock;
            disp_minute <= disp_minute_clock;
            disp_hour   <= disp_hour_clock  ;
            point_disp  <= point_disp_clock ;           
            // 模式切换
            if(~load_s_pulse)begin
                MODE <= MODE_LOAD;
            end
            else begin
                MODE <= MODE;
            end
        end 
            
        endcase
    end
end




//  ====================  clock、load_num、alarm三大模块实例化  ====================
//时钟模式----实例化
//时钟的置数信号：无论长按短按都会触发置数（长按、短按均为低电平触发，所以相与后为clock的load输入）
wire    load_clock;
// load_num中，data_hour等的更新与clock-counter_time-counter加载置数值在同一个时钟沿
// 在同步时钟下，counter读到的是沿前值，所以要对load_clock延时一个周期
reg     load_l_pulse_delay;
always@(posedge sys_clk) load_l_pulse_delay <= load_l_pulse;
assign load_clock = load_l_pulse_delay;

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
    .point_out  (point_disp_clock )//=============================
);


//置数模式
load_num    clock_mode_load_num
(
    .mode_en         (mode_load_en),
    .sys_clk         (sys_clk   ),
    .sec_clk         (sec_clk   ),
    .rst_n           (rst_n     ),
    .load_confirm    (load_l_pulse ),
    .choose          (choose_load_num  ),
    .num_up          (num_up_load_num  ),
    .num_down        (num_down_load_num),
    .before_second   (disp_second_clock),//---------------
    .before_minute   (disp_minute_clock),//---------------
    .before_hour     (disp_hour_clock  ),//---------------
    // .point_out       (point_out    ),

    .data_second     (data_second  ),
    .data_minute     (data_minute  ),
    .data_hour       (data_hour    ),
    .disp_second    (disp_second_num),
    .disp_minute    (disp_minute_num),
    .disp_hour      (disp_hour_num  ),
    .point_out      (point_disp_num)
);

//闹钟模式----实例化








//  ====================  seg_dynamic、hc595_ctrl实例化  ====================             
wire    [5:0]   sel;                          
wire    [7:0]   seg;
////  ------  实例化子模块  ------  
////按键消抖----------目前只有load需要消抖
//数码管动态显示模块
seg_dynamic     clock_seg_dynamic
(
   .sys_clk            (sys_clk   ),
   .pre_clk            (sys_clk_1mhz),   
   .sec_clk            (sec_clk   ), 
   .rst_n              (rst_n     ),
   .out_second         (disp_second),
   .out_minute         (disp_minute),
   .out_hour           (disp_hour  ),
   .point_out          (point_disp ),

   .sel                (sel       ),  
   .seg                (seg       )   
);  

//74HC595控制模块
hc595_ctrl      clock_hc595_ctrl
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