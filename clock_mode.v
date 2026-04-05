// =============================================================================
// 文件名：clock_mode.v
// 功能：顶层控制模块，负责模式切换与信号路由
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
// │  时钟模式     │  长按 load      │  将 load_num 的置数结果写入   │
// │               │                 │  counter_time（异步置数）     │
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
//   1. clock 子模块始终在后台运行（pulse_1s 持续驱动 counter_time），
//      置数和闹钟模式不会暂停走时，退出后显示的是实际流逝后的时间。
//   2. 输出信号选择：mode_clock_en/mode_load_en 控制 stcp/shcp/ds/oe 的来源，
//      两个子系统的显示输出通过 OR 门合并，同一时刻只有一路处于使能状态。
//   3. ⚠ 门控时钟问题：sys_clk_load_num = sys_clk && mode_load_en 为门控时钟，
//      会导致综合器警告和时序分析不准确，后续需要改为时钟直通 + 内部使能的方式。
//
// 子模块实例：
//   my_pll_divider（IP核）、sys_divider、
//   button_stabilization（×3）、button_stabilization_long_short（×1）、
//   clock、load_num
// =============================================================================
module clock_mode               //时钟的顶层封装模块：模式调整
(
//  ------  顶层入口（直接连接）  ------  
input   wire    sys_clk,        //全局时钟，50MHz
input   wire    reset_input,      //复位信号
input   wire    load,       //置数信号
input   wire    choose,
input   wire    num_up,
input   wire    num_down,

output  wire    clk_load_num,   //用于调试

output  wire    stcp,
output  wire    shcp,
output  wire    ds,  
output  wire    oe   
);

//系统时钟PLL输出1MHz
my_pll_divider	my_pll_divider_inst (
	.areset ( ~reset_input ),      // 我的系统复位低有效，而PLL复位高有效，所以这里这么写？
	.inclk0 ( sys_clk ),
	.c0 ( sys_clk_1mhz ),
	.locked ( locked_sig )  // 系统全局复位“使能”，当PLL锁定之前，系统一直处于复位状态
	);
wire    reset = reset_input & locked_sig;

wire pulse_1ms;
wire pulse_1s;
wire sec_clk;
sys_divider clock_mode_divider
(
    .sys_clk  (sys_clk      ),
    .pre_clk  (sys_clk_1mhz ),
    .reset    (reset        ),
    
    .pulse_1ms(pulse_1ms    ),
    .pulse_1s (pulse_1s     ),   // → clock.v 里 counter_time 用
    .sec_clk  (sec_clk      )    // → clock.v 里小数点和load_num置数和显示load几个字时用

);

//按键消抖（短按）
// 注意！！改变消抖时间，修改实例化时的参数即可，无需关心内部计数
//wire    load_bs;
wire    choose_bs;
wire    num_up_bs;
wire    num_down_bs; 
// 按键消抖模块接口已改为pulse_1ms计数，参数单位为ms
button_stabilization #(.DEBOUNCE_MS(20))
                        //load_b_s     (sys_clk, reset, load, load_bs),
                        choose_b_s   (sys_clk, pulse_1ms, reset, choose, choose_bs),
                        num_up_b_s   (sys_clk, pulse_1ms, reset, num_up, num_up_bs),
                        num_down_b_s (sys_clk, pulse_1ms, reset, num_down, num_down_bs);
//按键消抖+短按检测（大于20ms小于500ms）+长按3秒检测  
// 注意！！改变消抖时间和长短按时长，修改实例化时的参数即可，无需关心内部计数          
wire    load_bs_s;
wire    load_bs_l;
// 按键消抖+长短按模块接口已改为pulse_1ms计数，LONG_PRESS_MS单位为ms
button_stabilization_long_short #(.DEBOUNCE_MS(20), .SHORT_END_MS(500), .LONG_PRESS_MS(3_000)) 
                                load_b_s_l_s    (sys_clk, pulse_1ms, reset, load, load_bs_s, load_bs_l);





/*
模式选择模块的控制模块：不同的按压方式对应不同的选择，具体如下：

对于置数模式：
非置数模式，reset为低电平（复位模式），时钟信号均置零，choose、num_up、num_down均置一，其余三个输入不做处理
置数模式下，load_num模块的load信号为低电平，
  使用者确认置数正确后，长按确认，此处设置代码识别“长按”，然后将load_num模块的load信号拉高，一个系统时钟后再拉低（即一个脉冲）
  系统模式切换回CLOCK（非置数模式）
*/

////对状态进行选择//-----------------------单按load选择时钟、置数、闹钟模式，长按确认置数、闹钟的输入---------------

//时钟模式、置数模式、闹钟模式使能信号
reg mode_clock_en = 1'b1;
reg mode_load_en = 1'b0;
reg mode_alarm_en = 1'b0;
//对不同模式的输入输出进行使能
//置数、闹钟模式的输入需要控制，时钟的输入不可控制
assign  clk_load_num  =   sys_clk &&mode_load_en ;//-------------------------------------------------------------------------------------------------
assign  choose_load_num   = choose_bs   | (~mode_load_en); // 按键低有效
assign  num_up_load_num   = num_up_bs   | (~mode_load_en);
assign  num_down_load_num = num_down_bs | (~mode_load_en);
//闹钟模式 assign   sys_clk_alarm  =   sys_clk &&mode_alarm_en ;
//闹钟模式 assign   choose_alarm   = ~(choose  &&mode_alarm_en);
//闹钟模式 assign   num_up_alarm   = ~(num_up  &&mode_alarm_en);
//闹钟模式 assign   num_down_alarm = ~(num_down&&mode_alarm_en);

//时钟、置数、闹钟模式的输出都需控制
//子模块连线----输出控制
//时钟模式
wire    stcp_clock;
wire    shcp_clock;
wire    ds_clock;  
wire    oe_clock;  
//置数模式
wire    stcp_load_num;
wire    shcp_load_num;
wire    ds_load_num;  
wire    oe_load_num;  
//闹钟模式========================================================================

assign  stcp = (stcp_clock&&mode_clock_en) || (stcp_load_num&&mode_load_en); //闹钟模式 || (stcp_alarm&&mode_alarm_en);
assign  shcp = (shcp_clock&&mode_clock_en) || (shcp_load_num&&mode_load_en); //闹钟模式 || (stcp_alarm&&mode_alarm_en);
assign  ds   = (ds_clock&&mode_clock_en)   || (ds_load_num&&mode_load_en); //闹钟模式   || (stcp_alarm&&mode_alarm_en);
assign  oe   = (oe_clock&&mode_clock_en)   || (oe_load_num&&mode_load_en); //闹钟模式   || (stcp_alarm&&mode_alarm_en);

//模式选择模块
//定义状态机状态
localparam  MODE_CLOCK = 2'b00;
localparam  MODE_LOAD = 2'b01;
localparam  MODE_ALARM = 2'b10;
//定义状态机
reg [1:0]   MODE = MODE_CLOCK;

//在不同模式下，对输入输出信号进行控制，若16秒内无操作（无变化）自动取消
// // parameter CLK_FREQ = 50_000_000;   // 时钟频率50MHz
parameter PULSE_1MS = 1_000;// 1ms脉冲驱动
parameter COUNTER_16S_TIME = 16;     // 长按时间16秒
localparam COUNTER_16S_COUNT = PULSE_1MS * COUNTER_16S_TIME;      // 16秒计数值

reg [$clog2(COUNTER_16S_COUNT)-1:0]  counter_16s=0;
reg [1:0]   counter_load_wait=2'b0;
reg [2:0]   prev=3'b111;      //记录输入信号之前的值（num_up、num_down、choose），按系统时钟更新
wire[2:0]   now;
assign      now={choose_bs,num_up_bs,num_down_bs};//现在的值，实时更新

always@(posedge sys_clk or negedge reset)
begin
    if(!reset)begin
        MODE <= MODE_CLOCK;
        counter_16s <= 0;
        prev <= 3'b111;
        mode_clock_en <= 1'b1;
        mode_load_en <= 1'b0;
        mode_alarm_en <= 1'b0;
    end
    else begin
        case(MODE)
        MODE_CLOCK:
        begin
            mode_clock_en <= 1'b1;
            mode_load_en <= 1'b0;
            mode_alarm_en <= 1'b0;
//            stcp    <=  stcp_clock;
//            shcp    <=  shcp_clock;
//            ds      <=  ds_clock;  
//            oe      <=  oe_clock;
            if(~load_bs_s)begin
                MODE <= MODE_LOAD;
            end
            else begin
                MODE <= MODE;
            end
        end
        
        MODE_LOAD:
        begin
            mode_clock_en <= 1'b0;
            mode_load_en <= 1'b1;
            mode_alarm_en <= 1'b0;
            
//            sys_clk_load_num <= sys_clk;
//            choose_load_num  <= choose_bs;
//            num_up_load_num  <= num_up_bs;
//            num_down_load_num<= num_down_bs;
            
//            stcp    <=  stcp_load_num;
//            shcp    <=  shcp_load_num;
//            ds      <=  ds_load_num;  
//            oe      <=  oe_load_num;  
        
            prev <= {choose_bs,num_up_bs,num_down_bs};
            if(load_bs_s==1'b0&&load_bs_l==1'b1)begin
                if(counter_load_wait < 2'b11) //load短按，等待2个时钟周期后，切换为闹钟模式
                    counter_load_wait <= counter_load_wait + 1'b1;
                else begin
                    counter_load_wait <= 2'b0;
                    counter_16s <= 0;
                    MODE <= MODE_ALARM;
                end
            end
            
            else if(load_bs_s==1'b1&&load_bs_l==1'b0)begin
                if(counter_load_wait < 2'b11) //load长按，等待2个时钟周期后，切换回时钟模式
                    counter_load_wait <= counter_load_wait + 1'b1;
                else begin
                    counter_load_wait <= 2'b0;
                    counter_16s <= 0;
                    MODE <= MODE_CLOCK;
                end
            end            
            
            else if(now != prev)       
                 counter_16s <= 0;           
            else if(now == prev && counter_16s < COUNTER_16S_COUNT)
                if (pulse_1ms) counter_16s <= counter_16s + 1'b1;
            else if(now == prev && counter_16s >= COUNTER_16S_COUNT)begin
                counter_16s <= 0;
                MODE <= MODE_CLOCK;
            end
            else begin
                counter_16s <= counter_16s;
                MODE <= MODE;
            end
        end
    
        MODE_ALARM:
        begin
        
            //同上，输入输出控制
        
            prev <= {choose_bs,num_up_bs,num_down_bs};
            if(load_bs_s==1'b0||load_bs_l==1'b0)begin
                if(counter_load_wait < 2'b11) //load短按或长按，等待2个时钟周期后，切换回时钟模式
                    counter_load_wait <= counter_load_wait + 1'b1;
                else begin
                    counter_load_wait <= 2'b0;
                    counter_16s <= 0;
                    MODE <= MODE_CLOCK;     // 修改前是MODE <= MODE_ALARM;
                end
            end
            else if(now != prev)       
                 counter_16s <= 0;           
            else if(now == prev && counter_16s < COUNTER_16S_COUNT)
                if (pulse_1ms) counter_16s <= counter_16s + 1'b1;
            else if(now == prev && counter_16s >= COUNTER_16S_COUNT)begin
                counter_16s <= 0;
                MODE <= MODE_CLOCK;
            end
            else begin
                counter_16s <= counter_16s;
                MODE <= MODE;
            end
        end
        
        default:    //default：时钟模式
        begin
            mode_clock_en <= 1'b1;
            mode_load_en <= 1'b0;
            mode_alarm_en <= 1'b0;
//            stcp    <=  stcp_clock;
//            shcp    <=  shcp_clock;
//            ds      <=  ds_clock;  
//            oe      <=  oe_clock;
            if(~load_bs_s)begin
                MODE <= MODE_LOAD;
            end
            else begin
                MODE <= MODE;
            end
        end 
            
        endcase
    end
end








//子模块连线----输入控制
//时钟模式不能限制输入！
//置数模式
// wire    sys_clk_load_num ;
// wire    choose_load_num  ;
// wire    num_up_load_num  ;
// wire    num_down_load_num;
//闹钟模式
//wire    sys_clk_alarm  ;  // 不能这么用门控时钟
//wire    choose_alarm   ;
//wire    num_up_alarm   ;
//wire    num_down_alarm ;









//时钟模式----实例化
//时钟的置数信号：无论长按短按都会触发置数（长按、短按均为低电平触发，所以相与后为clock的load输入）
wire    load_clock;
assign  load_clock = load_bs_s && load_bs_l;
wire    [7:0]   data_second;
wire    [7:0]   data_minute;   
wire    [7:0]   data_hour;   
//时钟与置数连线----实例化
wire    [7:0]   out_second;       //---------------
wire    [7:0]   out_minute;       //---------------
wire    [7:0]   out_hour  ;       //---------------
wire    [5:0]   point_out;        //---------------
clock   clock_mode_clock
(
    .sys_clk    (sys_clk    ),
    .pre_clk    (sys_clk_1mhz),
    .sec_pulse  (pulse_1s   ),  
    .sec_clk    (sec_clk    ),
    .reset      (reset      ), 
    .load       (load_clock ),  
    .data_second(data_second),    
    .data_minute(data_minute),    
    .data_hour  (data_hour  ),    
    

    .stcp       (stcp_clock),
    .shcp       (shcp_clock),
    .ds         (ds_clock  ),  
    .oe         (oe_clock  ),
    .out_second (out_second),
    .out_minute (out_minute),
    .out_hour   (out_hour  )
);


//置数模式
// // assign  out_second = 8'b0000_0000;        //---------------
// // assign  out_minute = 8'b0000_0110;        //---------------
// // assign  out_hour   = 8'b0001_0101;        //---------------
assign  point_out  = 6'b010100;   //---------------
load_num    clock_mode_load_num
(
    .mode_en         (mode_load_en),
    .sys_clk         (sys_clk   ),
    .sec_clk         (sec_clk   ),
    .reset           (reset     ),
    .load            (load_bs_s ),
    .load_confirm    (load_bs_l ),
    .choose          (choose_load_num  ),
    .num_up          (num_up_load_num  ),
    .num_down        (num_down_load_num),
    .before_second   (out_second),//---------------
    .before_minute   (out_minute),//---------------
    .before_hour     (out_hour  ),//---------------
    .point_out       (point_out    ),//------------

    .data_second     (data_second  ),
    .data_minute     (data_minute  ),
    .data_hour       (data_hour    ),
    .stcp            (stcp_load_num),
    .shcp            (shcp_load_num),
    .ds              (ds_load_num  ),
    .oe              (oe_load_num  )
);

//闹钟模式----实例化








////  ------  子模块连线声明（内部连接）  ------  
//wire    sec_clk;
//wire    [7:0]   out_second, out_minute, out_hour; 
//wire    [5:0]   point_out;                              
//wire    [5:0]   sel;                          
//wire    [7:0]   seg;
//wire    load_bs;
//wire    reset_p;
//
////  -----  子模块内部
//
////  ------  实例化子模块  ------  
////按键消抖----------目前只有load需要消抖
//button_stabilization    load_b_s(.sys_clk(sys_clk), .reset(reset), .button_in(load), .button_out(load_bs));
//
////      //复位脉冲发生模块
////      reset_pulse     reset_p_s
////      (
////          .sys_clk    (sys_clk),   
////          .reset      (reset  ), 
////      
////          .pulse      (reset_p)
////      );
//
////分频器
//divider         clock_divider
//(
//    .sys_clk            (sys_clk),  
////    .reset              (reset  ),
//
//    .sec_clk            (sec_clk)    
//);
//
////通用计数器
//counter_time    clock_counter_time
//(
//    .sec_clk            (sec_clk    ),            
//    .reset              (reset      ),              
//    .load               (load_bs    ),               
//    .data_second        (data_second),
//    .data_minute        (data_minute),
//    .data_hour          (data_hour  ),            
//
//    .out_second         (out_second ),
//    .out_minute         (out_minute ),
//    .out_hour           (out_hour   ),
//    .point_out          (point_out  )
//);   
//
////数码管动态显示模块
//seg_dynamic     clock_seg_dynamic
//(
//    .sys_clk            (sys_clk   ),
//    .sec_clk            (sec_clk   ),                
//    .reset              (reset     ),
//    .out_second         (out_second),
//    .out_minute         (out_minute),
//    .out_hour           (out_hour  ),
//    .point_out          (point_out ),
//
//    .sel                (sel       ),  
//    .seg                (seg       )   
//);  
//
////74HC595控制模块
//hc595_ctrl      clock_hc595_ctrl
//(
//    .sys_clk            (sys_clk),
//    .reset              (reset  ),
//    .sel                (sel    ),
//    .seg                (seg    ),
//
//    .stcp               (stcp   ),           
//    .shcp               (shcp   ),           
//    .ds                 (ds     ),             
//    .oe                 (oe     )
//);

endmodule