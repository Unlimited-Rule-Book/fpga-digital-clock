// =============================================================================
// 文件名：counter.v
// 功能：通用 BCD N 进制加减计数器，支持多个 counter 级联，
//       通过 RCO_last RCO 实现进位链连接，进而实现级联。
//
// 本模块被三处复用：
//   1. clock.v 中：   sys_clk 为时钟，sec_pulse 为计数使能（走时模式）
//   2. load_num.v 中：sys_clk 为时钟，按键脉冲（ hour_pulse 等）作为计数使能（手动调整模式）
//   3. alarm.v 中：   sys_clk 为时钟，按键脉冲（ hour_pulse 等）作为计数使能（闹钟设置模式）
//
//
// 计数规则：
//   RCO = RCO_last AND (当前位已到进位值)，仅当低位有进位时才计数
//   达到 radix_data 时清零（加计数）或减到0时回到 radix_data（减计数）
// =============================================================================
module counter
(      
input   wire    sys_clk,            // 系统时钟
input   wire    sec_pulse,          // 周期为 1 second 的脉冲 或按键脉冲，脉宽与系统时钟相等
input   wire    rst_n,              // 同步清零，低电平有效
input   wire    load,               // 同步置数，低电平有效
input   wire    [3:0]   load_data,  // 置数时加载进模块的数值
input   wire    [3:0]   radix_data, // 计数器在计到哪一个数时同步清零，如十进制传入9，六进制传入5
input   wire    RCO_last,           // 前一位（前一个 counter 模块）的进位信号 RCO （最低位固定接1'b1）
input   wire    point_in,           // 需要输出小数点，则置高电平
input   wire    count_direction,    // count_direction=0 为加计数， count_direction=1 为减计数
output  reg     [3:0]   count_out,// 为数码管设计，设为4位即可
output  wire    RCO,                // 接下一个模块（下一个 counter ）的 RCO_last
output  wire    point_out   // 输出小数点
);

wire    RCO_add;        // 定义进位信号中间变量
wire    RCO_subtract;   // 定义借位信号中间变量

always@(posedge sys_clk)begin
    if(!rst_n)              // 同步清零，优先级高于计数
        count_out <= 0; 
    else if(~load)          // 原本想采用异步置数，但是系统只支持异步清零。后来因为 PLL 锁定信号需要与I/O口输入的复位信号一同控制复位，最终改为同步清零（同步复位）
        count_out <= (load_data > radix_data) ? radix_data : load_data; 
        // 防止非法装载大于最大进制的值，下方 RCO_add 就可以从 count_out >= radix_data 改成 count_out == radix_data
        // 现在的逻辑是，装载非法值后，输出进制值 radix_data ，也可以想之前一样，装载非法值后，输出0。

    else if(count_out > radix_data)
        count_out <= radix_data;

    else if(sec_pulse)begin
        if     (RCO==1'b1     &&count_direction==1'b0)
            count_out <= 0;
        else if(RCO==1'b1     &&count_direction==1'b1)
            count_out <= radix_data;
        else if(RCO_last==1'b1&&count_direction==1'b0)
            count_out <= count_out + 1'b1;  //当前一位有进位信号时，计数
        else if(RCO_last==1'b1&&count_direction==1'b1)
            count_out <= count_out - 1'b1;
    end
        
    else
        count_out <= count_out;
end

// 进位信号的产生与消失
assign RCO_add = (count_out == radix_data && count_direction==1'b0)? 1'b1:1'b0;
// 上方 load 处添加了防止非法装载大于最大进制的值的逻辑，此处可以从 count_out >= radix_data 改成 count_out == radix_data
// 否则，装载非法值后会被直接清零。在load处添加检测逻辑，可以灵活设置装载非法值后，输出是0还是 radix_data 。
assign RCO_subtract = (count_out == 0 && count_direction==1'b1) ? 1'b1:1'b0;
assign RCO = RCO_last && (RCO_add || RCO_subtract);

// 小数点输出
assign point_out = point_in;

endmodule