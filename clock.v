// =============================================================================
// 文件名：clock.v
// 功能：时钟显示子模块，负责走时计数与数码管显示
//
// 本模块在系统运行期间始终保持工作（无论当前处于何种模式），
// 时钟数值由 counter_time 在每个 sec_pulse（1Hz脉冲）到来时递增。
// 数码管显示由 seg_dynamic + hc595_ctrl 驱动，在 mode_clock_en=0 时
// 显示输出被顶层的 OR 门屏蔽，但内部计数仍在继续（后台走时）。
//
// 接口说明：
//   sec_pulse  : 1Hz计时驱动脉冲（来自 sys_divider 的 pulse_1s）
//   sec_clk    : 1Hz 50%占空比时钟，驱动小数点闪烁（来自 sys_divider）
//   pre_clk    : 1MHz时钟，供 seg_dynamic 内部生成扫描时钟使用
//   load       : 异步置数使能（低有效），来自 clock_mode 的 load_clock
//                load_clock = load_bs_s AND load_bs_l（短按或长按均触发置数）
//   data_*     : 置数目标值，来自 load_num 的输出
//
// 内部结构：
//   counter_time （时分秒BCD计数，复用 counter 模块6次）
//   seg_dynamic （6位数码管动态扫描）
//   hc595_ctrl （74HC595串行输出驱动）
// =============================================================================
module clock                //时钟的顶层封装模块
(
//  ------  顶层入口（直接连接）  ------  
input   wire    sys_clk,    //全局时钟，目前由PLL生成1MHz
input   wire    pre_clk,    //待分频时钟1mhz
input   wire    sec_pulse,  //秒脉冲，用于驱动计数器
input   wire    sec_clk,    //占空比50%的秒信号，用于控制小数点闪烁  
input   wire    reset,      //复位信号
input   wire    load,       //置数信号
input   wire    [7:0]   data_second,   //置数：秒
input   wire    [7:0]   data_minute,   //置数：分
input   wire    [7:0]   data_hour,     //置数：时

// // output  wire    stcp,
// // output  wire    shcp,
// // output  wire    ds,  
// // output  wire    oe,
output  wire    [7:0]   out_second, //输出一下，给置数模块使用
output  wire    [7:0]   out_minute,
output  wire    [7:0]   out_hour,
output  wire    [5:0]   point_out
);

//wire    [7:0]   data_second;
//wire    [7:0]   data_minute;
//wire    [7:0]   data_hour  ;
// assign  data_second = 8'b0110_1100;
// assign  data_minute = 8'b0101_1000;
// assign  data_hour   = 8'b0010_0011;

//  ------  子模块连线声明（内部连接）  ------  
// wire    sec_clk;
// // wire    [7:0]   out_second, out_minute, out_hour; //端口处声明了，此处就注释了
// wire    [5:0]   point_out;  //端口处声明了，此处就注释了
wire    [5:0]   sel;                          
wire    [7:0]   seg;

//  -----  子模块内部

//  ------  实例化子模块  ------  
// load已在顶层clock_mode里消抖，clock无需消抖-----------------------------

//      //复位脉冲发生模块
//      reset_pulse     reset_p_s
//      (
//          .sys_clk    (sys_clk),   
//          .reset      (reset  ), 
//      
//          .pulse      (reset_p)
//      );

// // // // //分频器，由于counter改成系统时钟+脉冲驱动，所以divider仅作为小数点显示的驱动
// // // // divider         clock_divider
// // // // (
    // // // // .sys_clk            (pre_clk),  
// // // // //    .reset              (reset  ),

    // // // // .sec_clk            (sec_clk)    
// // // // );

// //秒脉冲发生器，将sys_clk的频率(单位Hz)赋给CLK_FREQ可直接生成1Hz秒脉冲
// pulse_sec #(.CLK_FREQ(1_000_000)) clock_sec_pulse
// (
    // .sys_clk            (sys_clk    ),
    // .pre_clk            (pre_clk    ),
    // .reset              (reset      ),
    
    // .pulse_out          (sec_pulse  ),
    // .sec_clk            (sec_clk    )
// );
// 已在顶层模块中使用，信号从clock输入端口传入


//通用计数器
counter_time    clock_counter_time
(
    .sys_clk            (sys_clk    ),
    .sec_pulse          (sec_pulse  ),            
    .reset              (reset      ),              
    .load               (load       ),               
    .data_second        (data_second),
    .data_minute        (data_minute),
    .data_hour          (data_hour  ),            

    .out_second         (out_second ),
    .out_minute         (out_minute ),
    .out_hour           (out_hour   ),
    .point_out          (point_out  )
);   

// // //数码管动态显示模块
// // seg_dynamic     clock_seg_dynamic
// // (
    // // .sys_clk            (sys_clk   ),
    // // .pre_clk            (pre_clk   ),
    // // .sec_clk            (sec_clk   ),                
    // // .reset              (reset     ),
    // // .out_second         (out_second),
    // // .out_minute         (out_minute),
    // // .out_hour           (out_hour  ),
    // // .point_out          (point_out ),

    // // .sel                (sel       ),  
    // // .seg                (seg       )   
// // );  

// // //74HC595控制模块
// // hc595_ctrl      clock_hc595_ctrl
// // (
    // // .sys_clk            (sys_clk),
    // // .reset              (reset  ),
    // // .sel                (sel    ),
    // // .seg                (seg    ),

    // // .stcp               (stcp   ),           
    // // .shcp               (shcp   ),           
    // // .ds                 (ds     ),             
    // // .oe                 (oe     )
// // );

endmodule