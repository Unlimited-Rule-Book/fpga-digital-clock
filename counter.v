// =============================================================================
// 文件名：counter.v
// 功能：通用BCD N进制加减计数器（可复用模块）
//
// 本模块被两处以不同方式复用：
//   1. counter_time.v 中：sys_clk 为时钟，sec_pulse 为计数使能（走时模式）
//   2. load_num.v 中：按键脉冲（hor_pulse等）直接作为时钟（手动调整模式）
//
// 接口说明：
//   data_radix  : 进制设定（如十进制传入9，六进制传入5）
//   RCO_last    : 前一位进位输入（最低位固定接1'b1）
//   RCO         : 向高位的进位/借位输出
//   mode        : 0=加计数，1=减计数
//   load        : 异步置数（低有效，优先级最高）
//   reset       : 同步清零（低有效）
//
// 计数规则：
//   RCO = RCO_last AND (当前位已到进位值)，仅当低位有进位时才计数
//   达到 data_radix 时清零（加计数）或减到0时回到 data_radix（减计数）
// =============================================================================
module counter
(      
input   wire    sys_clk,            //系统时钟
input   wire    sec_pulse,          //周期为1second的脉冲，脉宽与系统时钟相等
input   wire    reset,              //同步清零，低电平有效，长按按键至少1秒复位
input   wire    load,               //异步置数，下降沿有效
input   wire    [3:0]   data_counter,
input   wire    [3:0]   data_radix, //计数器在计到哪一个数时同步清零，即是几进制计数器
input   wire    RCO_last,           //前一位的进位信号
input   wire    point_in,           //需要输出小数点，则置高电平
input   wire    mode,               //mode=0为加计数，mode=1为减计数
output  reg     [31:0]   out_counter,
output  wire    RCO,
output  wire    point_out_counter   //输出小数点
);

wire    RCO_add;        //定义进位信号中间变量，可增强可读性，若为提高执行效率，则可去掉
wire    RCO_subtract;   //定义借位信号中间变量，可增强可读性，若为提高执行效率，则可去掉

always@(posedge sys_clk)        
begin
    if(reset==1'b0)          //同步清零，优先级高于计数
//        begin
        out_counter <= 4'b0000;
//        mode <= 1'b0;       //默认加计数，always里不可给wire型输入信号赋值
//        end
    else if(~load)
    out_counter <= data_counter;  //原本想采用异步置数，但是系统只支持异步清零

    else if(sec_pulse)
        begin
        if(RCO==1'b1     &&mode==1'b0)
            out_counter <= 4'b0000;
        else if(RCO==1'b1     &&mode==1'b1)
            out_counter <= data_radix;
        else if(RCO_last==1'b1&&mode==1'b0)
            out_counter <= out_counter + 1; //当前一位有进位信号时，计数
        else if(RCO_last==1'b1&&mode==1'b1)
            out_counter <= out_counter - 1;
        
//       else if(data_counter > data_radix || out_counter > data_radix)
//           out_counter <= data_radix;
//       else if(data_counter < 4'b0 || out_counter < 4'b0)
//           out_counter <= 4'b0;
        end
        
    else
        out_counter <= out_counter;
end

//进位信号的产生与消失
assign RCO_add = (out_counter >= data_radix && mode==1'b0)? 1'b1:1'b0;
assign RCO_subtract = (out_counter == 1'b0 && mode==1'b1) ? 1'b1:1'b0;
assign RCO = RCO_last && (RCO_add || RCO_subtract);

//小数点输出
assign point_out_counter = point_in;

//
//    always@(*)
//    begin
//        if(data_counter > data_radix || out_counter > data_radix)
//            out_counter = data_radix;
//        else if(data_counter < 4'b0 || out_counter < 4'b0)
//            out_counter = 4'b0;
//    end

endmodule