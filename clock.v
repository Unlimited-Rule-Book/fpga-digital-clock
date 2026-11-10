// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Unlimited-Rule-Book
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
//      小时个位的进制由 radix_hour 动态计算：置数时，进制权在 data_hour ;非置数时，进制权在 out_hour 
//          以 out_hour 为例：
//          若 out_hour[7:4] == 2（即时十位为2），则个位进制为4（0~3，对应20~23时）
//          否则个位进制为10（0~9，对应00~19时）
//
// 模块说明：
// 本模块在系统运行期间始终保持工作（无论当前处于何种模式），
// 时钟数值由内部六个 counter 实例在每个 sec_pulse（1Hz脉冲）到来时递增。
// 其它模式时，显示输出被顶层的状态机屏蔽，但内部计数仍在继续（后台走时）。
//
// 接口说明：
// load : 同步置数使能（低有效），来自 clock_mode 状态机的 load_long_pulse ，确认置数后 load_long_pulse 有效
//       内部先延时一拍为 load_d 再接入 counter （保证 radix_hour 先按 data_hour 更新，counter 后置数）
//
// 模块历史说明：
// 原本内部实例化了 counter_time seg_dynamic hc595_ctrl ，而 counter_time 内部实例化六次 counter
// 但是在开发 load_num 模块时，seg_dynamic hc595_ctrl 被集中到了顶层模块，与 load_num 共用
// 所以 clock 与 counter_time 就重复了，于是删去了 counter_time
// =============================================================================
module clock
(
input   wire    sys_clk,    // 全局时钟，50MHz晶振
input   wire    sec_pulse,  // 1Hz秒脉冲,用于驱动计数器，来自 sys_divider 的 pulse_1s
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

// 踩坑记录
/* 当 clock 的小时为20-23，而置数界面的小时设定为 4-9/14-19，确认置数后， clock 显示的小时个位会被钳位到3
*/
// 进制问题最后修正方案
/* 若后台走时的小时为20-23， load_num 界面置为4-9 14-19，则确认置数后，小时个位会被钳位为3，
   已经找到问题根源: clock 模块里的 load 在顶层 clock_mode 里接的是 load_long_pulse ，此信号是在长按 load 3秒后自动产生的脉冲，
   故 clock 中将置数时的进制判断独立出来用组合逻辑实现，对解决这一问题没有意义.
   有效手段是用延迟1拍的置数信号代替现在接入 counter 的置数信号 load ，并同步修改进制判断逻辑
*/
// 定义并实现 load 的延迟信号
reg load_d = 1'b1;
always@(posedge sys_clk) load_d  <= load;
// 定义小时个位进制
reg [3:0]   radix_hour;
//注意，此逻辑只适用于加计数，减计数需根据借位后的十位判断个位的进制，故逻辑略有区别，具体见 load_num 模块
always@(posedge sys_clk)
begin
    if(!rst_n)
        radix_hour <= 4'b1001;
    else if(~load || ~load_d) begin     // 置数拍 load 与装载拍 load_d: 进制权交给置数值
        if(data_hour[7:4]==4'b0010)
            radix_hour <= 4'b0011;
        else if(data_hour[7:4]==4'b0001 || data_hour[7:4]==4'b0000)
            radix_hour <= 4'b1001;
    end
    else begin  // 非置数时，依照 counter 的输出判断一次进制
        if(out_hour[7:4]==4'b0010)
            radix_hour <= 4'b0011;
        else if(out_hour[7:4]==4'b0001 || out_hour[7:4]==4'b0000)
            radix_hour <= 4'b1001;
    end
end

wire    [5:0]   RCO;

//用实例化的方法组成计数器
counter sec0(sys_clk,sec_pulse,rst_n,load_d,data_second[3:0],4'b1001,     1'b1,1'b0,1'b0,out_second[3:0],RCO[0],point_out[0]),
        sec1(sys_clk,sec_pulse,rst_n,load_d,data_second[7:4],4'b0101,   RCO[0],1'b0,1'b0,out_second[7:4],RCO[1],point_out[1]),
        min0(sys_clk,sec_pulse,rst_n,load_d,data_minute[3:0],4'b1001,   RCO[1],1'b1,1'b0,out_minute[3:0],RCO[2],point_out[2]),
        min1(sys_clk,sec_pulse,rst_n,load_d,data_minute[7:4],4'b0101,   RCO[2],1'b0,1'b0,out_minute[7:4],RCO[3],point_out[3]),
        hor0(sys_clk,sec_pulse,rst_n,load_d,data_hour[3:0],  radix_hour,RCO[3],1'b1,1'b0,out_hour[3:0],  RCO[4],point_out[4]),
        hor1(sys_clk,sec_pulse,rst_n,load_d,data_hour[7:4],  4'b0010,   RCO[4],1'b0,1'b0,out_hour[7:4],  RCO[5],point_out[5]);

endmodule