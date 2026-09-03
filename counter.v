// =============================================================================
// 文件名：counter.v
// 功能：通用 BCD N 进制加减计数器，支持多个 counter 级联，
//       通过 RCO_last RCO 实现进位链连接，进而实现级联。
//
// 本模块被三处复用：
//   1. clock.v 中：   sys_clk 为时钟，sec_pulse 为计数使能（走时模式）
//   2. load_num.v 中：sys_clk 为时钟，按键脉冲（hor_pulse等）作为计数使能（手动调整模式）
//   3. alarm.v 中：   sys_clk 为时钟，按键脉冲（hor_pulse等）作为计数使能（闹钟设置模式）
//
//
// 计数规则：
//   RCO = RCO_last AND (当前位已到进位值)，仅当低位有进位时才计数
//   达到 data_radix 时清零（加计数）或减到0时回到 data_radix（减计数）
// =============================================================================
module counter
(      
input   wire    sys_clk,            // 系统时钟
input   wire    sec_pulse,          // 周期为1second的脉冲，脉宽与系统时钟相等
input   wire    rst_n,              // 同步清零，低电平有效
input   wire    load,               // 同步置数，下降沿有效
input   wire    [3:0]   data_counter,  
input   wire    [3:0]   data_radix, // 计数器在计到哪一个数时同步清零，如十进制传入9，六进制传入5
input   wire    RCO_last,           // 前一位（前一个counter模块）的进位信号RCO（最低位固定接1'b1）
input   wire    point_in,           // 需要输出小数点，则置高电平
input   wire    mode,               // mode=0为加计数，mode=1为减计数
output  reg     [3:0]   out_counter,// 为数码管设计，设为4位即可
output  wire    RCO,                // 接下一个模块（）下一个counter）的RCO_last
output  wire    point_out_counter   // 输出小数点
);

wire    RCO_add;        // 定义进位信号中间变量，可增强可读性，若为提高执行效率，则可去掉
wire    RCO_subtract;   // 定义借位信号中间变量，可增强可读性，若为提高执行效率，则可去掉

always@(posedge sys_clk)begin
    if(~rst_n)              // 同步清零，优先级高于计数
        out_counter <= 0;
    else if(~load)          // 原本想采用异步置数，但是系统只支持异步清零。后来因为PLL锁定信号需要与I/O口输入的复位信号一同控制复位，最终改为同步清零（同步复位）
        out_counter <= (data_counter > data_radix) ? data_radix : data_counter; 
        // 防止非法装载大于最大进制的值，下方RCO_add就可以从out_counter >= data_radix改成out_counter == data_radix
        // 现在的逻辑是，装载非法值后，输出进制值data_radix，也可以想之前一样，装载非法值后，输出0。

    else if(out_counter > data_radix)
        out_counter <= data_radix;

    else if(sec_pulse)begin
        if     (RCO==1'b1     &&mode==1'b0)
            out_counter <= 0;
        else if(RCO==1'b1     &&mode==1'b1)
            out_counter <= data_radix;
        else if(RCO_last==1'b1&&mode==1'b0)
            out_counter <= out_counter + 1'b1;  //当前一位有进位信号时，计数
        else if(RCO_last==1'b1&&mode==1'b1)
            out_counter <= out_counter - 1'b1;
    end
        
    else
        out_counter <= out_counter;
end

// 进位信号的产生与消失
assign RCO_add = (out_counter == data_radix && mode==1'b0)? 1'b1:1'b0;
// 上方load处添加了防止非法装载大于最大进制的值的逻辑，此处可以从out_counter >= data_radix改成out_counter == data_radix
// 否则，装载非法值后会被直接清零。在load处添加检测逻辑，可以灵活设置装载非法值后，输出是0还是data_radix。
assign RCO_subtract = (out_counter == 0 && mode==1'b1) ? 1'b1:1'b0;
assign RCO = RCO_last && (RCO_add || RCO_subtract);

// 小数点输出
assign point_out_counter = point_in;

endmodule