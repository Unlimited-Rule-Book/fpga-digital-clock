// =============================================================================
// 文件名：clock.v
// 功能：
//      时钟显示模块，负责走时计数
//      时分秒BCD联级计数器，对通用计数器 counter 进行六次实例化
//      计数结构（BCD码，二进制十进制）：
//          秒个位（十进制 0~9）→ 秒十位（六进制 0~5）→
//          分个位（十进制 0~9）→ 分十位（六进制 0~5）→
//          时个位（变进制：时十位为0或1时0~9，时十位为2时0~3）→
//          时十位（三进制 0~2）
//      小时个位变进制说明：
//      小时个位的进制由 hour_radix 动态计算，每个 sec_pulse 时根据时十位更新：
//          若 out_hour[7:4] == 2（即时十位为2），则个位进制为4（0~3，对应20~23时）
//          否则个位进制为10（0~9，对应00~19时）
//
// 模块说明：
// 本模块在系统运行期间始终保持工作（无论当前处于何种模式），
// 时钟数值由内部六个 counter 实例在每个 sec_pulse（1Hz脉冲）到来时递增。
// 其它模式时，显示输出被顶层的状态机屏蔽，但内部计数仍在继续（后台走时）。
//
// 接口说明：
// load: 同步置数使能（低有效），来自clock_mode状态机的load_l_pulse，确认置数后load_l_pulse有效
//
// 模块历史说明：
// 原本内部实例化了counter_time、seg_dynamic、hc595_ctrl，而counter_time内部实例化六次counter
// 但是在开发load_num模块时，seg_dynamic、hc595_ctrl被集中到了顶层模块，与load_num共用
// 所以clock、与counter_time就重复了，于是删去了counter_time
// =============================================================================
module clock                // 时钟的顶层封装模块
(
input   wire    sys_clk,    // 全局时钟，50MHz晶振
input   wire    sec_pulse,  // 1Hz秒脉冲,用于驱动计数器，来自sys_divider的pulse_1s
input   wire    rst_n,      // 复位信号
input   wire    load,       // 置数信号，同步置数
input   wire    [7:0]   data_second,   // 置数：秒
input   wire    [7:0]   data_minute,   // 置数：分
input   wire    [7:0]   data_hour,     // 置数：时

output  wire    [7:0]   out_second, // 输出一下，给置数模块使用
output  wire    [7:0]   out_minute,
output  wire    [7:0]   out_hour,
output  wire    [5:0]   point_out
);
//  ====================  实例化六次通用计数器  ====================
//定义中间变量，设置“时”的个位的进制
reg [3:0]   hour_radix = 4'b1001;
//注意，此逻辑只适用于加计数，减计数需根据借位后的十位判断个位的进制，故逻辑略有区别，具体键load_num模块
always@(posedge sys_clk)
begin
//    if(!rst_n)
    if(rst_n==1'b0)
    hour_radix <= 4'b1001;
    else if(sec_pulse)
        begin
        if(out_hour[7:4]==4'b0010)
        hour_radix <= 4'b0011;
        else if((out_hour[7:4]==4'b0001)||(out_hour[7:4]==4'b0000))
        hour_radix <= 4'b1001;
        end
    else
    hour_radix <= hour_radix;
end
wire    [5:0]   RCO_zhong;

//用实例化的方法组成计数器
counter sec0(sys_clk,sec_pulse,rst_n,load,data_second[3:0],4'b1001,   1'b1,        1'b0,1'b0,out_second[3:0],RCO_zhong[0],point_out[0]),
        sec1(sys_clk,sec_pulse,rst_n,load,data_second[7:4],4'b0101,   RCO_zhong[0],1'b0,1'b0,out_second[7:4],RCO_zhong[1],point_out[1]),
        min0(sys_clk,sec_pulse,rst_n,load,data_minute[3:0],4'b1001,   RCO_zhong[1],1'b1,1'b0,out_minute[3:0],RCO_zhong[2],point_out[2]),
        min1(sys_clk,sec_pulse,rst_n,load,data_minute[7:4],4'b0101,   RCO_zhong[2],1'b0,1'b0,out_minute[7:4],RCO_zhong[3],point_out[3]),
        hor0(sys_clk,sec_pulse,rst_n,load,data_hour[3:0],  hour_radix,RCO_zhong[3],1'b1,1'b0,out_hour[3:0],  RCO_zhong[4],point_out[4]),
        hor1(sys_clk,sec_pulse,rst_n,load,data_hour[7:4],  4'b0010,   RCO_zhong[4],1'b0,1'b0,out_hour[7:4],  RCO_zhong[5],point_out[5]);

endmodule