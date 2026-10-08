// =============================================================================
// 文件名：seg_dynamic.v
// 功能：六位数码管动态扫描驱动模块
//
// 扫描原理：
//   六个数码管轮流点亮（每次只亮一个），利用人眼视觉暂留形成"同时显示"的效果。
//   扫描时钟 pulse_1ms 来自 sys_divider。
//   六个位轮流一遍共6ms，即刷新率约167Hz，远高于人眼分辨率。
//
// 小数点控制：
//   通过外部信号 point_out_twinkle_en 决定小数点是否闪烁
//   通过 sec_clk（1Hz，50%占空比）的电平检测实现1s闪烁。
//   point_out[i] 为1表示第i位需要显示小数点（如时分之间、分秒之间）。
//
// 段码约定（低电平点亮，共阳极数码管）：
//   seg[7]=小数点, seg[6:0] 对应 g, f, e, d, c, b, a（bit6=g, bit0=a）
//   当前支持数字0~9和字母L、A、d、E、全灭、-（4'd0~4'd15）
//   ⚠ 对 data_disp 、 sel 赋值的case语句，这种逻辑下，disp最大只能是4位宽，因此无法显示更多字符
//
// 与 hc595_ctrl 的配合：
//   sel（6位位选）和 seg（8位段选）送入 hc595_ctrl，
//   通过两片级联的74HC595串行传输到数码管。
// =============================================================================
module seg_dynamic
(
input   wire    sys_clk,
input   wire    pulse_1ms,      // 数码管扫描时钟，1ms为周期，来自 sys_divider
input   wire    sec_clk,        // 为实现数码管以1s为周期闪烁
input   wire    rst_n,
input   wire    [7:0]   out_second,
input   wire    [7:0]   out_minute,
input   wire    [7:0]   out_hour,
input   wire    [5:0]   point_out,
input   wire    point_out_twinkle_en,

output  reg     [5:0]   sel,    // 数码管位选信号，初值为选中所有数码管
output  reg     [7:0]   seg     // 数码管段选信号，初值为点亮数码管的所有段
);
//  ====================  定义中间变量  ====================
//定义中间变量——数码管数据显示
reg     [2:0]   cnt_sel;         // 位选信号计数器
reg     [3:0]   data_disp;       // 为了避免case语句嵌套，增强可读性，定义此变量位段选信号生成的中间变量，此变量不包含小数点
reg     point_disp;              // 当前数码管显示的小数点

//  ====================  主程序  ====================
//cnt_sel:位选信号计数器
always@(posedge sys_clk)
begin
    if(!rst_n)
        cnt_sel <= 0;
    else if(cnt_sel==3'd5 && pulse_1ms)
        cnt_sel <= 0;
    else if (pulse_1ms)
        cnt_sel <= cnt_sel + 1'b1;
end

//data_disp,sel:位选信号生成与控制六个数码管位选信号，使数码管轮流显示
always@(posedge sys_clk)
begin
    if(!rst_n)begin
        data_disp <= 4'd15; sel <= 6'b11_1111; end    //复位：全显示
    else if(pulse_1ms)begin
        case(cnt_sel)
        3'd0:   begin data_disp   <=  out_second[3:0];  sel <=  6'b00_0001; end
        3'd1:   begin data_disp   <=  out_second[7:4];  sel <=  6'b00_0010; end
        3'd2:   begin data_disp   <=  out_minute[3:0];  sel <=  6'b00_0100; end
        3'd3:   begin data_disp   <=  out_minute[7:4];  sel <=  6'b00_1000; end
        3'd4:   begin data_disp   <=  out_hour[3:0];    sel <=  6'b01_0000; end
        3'd5:   begin data_disp   <=  out_hour[7:4];    sel <=  6'b10_0000; end
        default:begin data_disp   <=  4'd14;            sel <=  6'b00_0000; end //异常：全灭
        endcase
    end
end

//数码管数据显示，小数点以1s为周期闪烁
//point_disp:为了增强可读性，也为了使对小数点的操作更加灵活，设置小数点寄存器，低电平点亮，所以需要对输入信号取反
always@(posedge sys_clk)
begin
    if(!rst_n)
        point_disp <= 1'b0; // 默认小数点点亮
    else if(~point_out_twinkle_en            && pulse_1ms)    point_disp <= ~point_out[cnt_sel];
    else if(point_out_twinkle_en && sec_clk  && pulse_1ms)    point_disp <= ~point_out[cnt_sel];
    else if(point_out_twinkle_en && ~sec_clk && pulse_1ms)    point_disp <= 1'b1;   // 小数点熄灭
    else                                                      point_disp <= point_disp;
end

//seg:控制数码管段选信号，低电平点亮数码管
//由于data_disp的更新和seg的生成是同一时钟上升沿触发的，但seg依赖于data_disp的值，这导致了段选信号比位选信号延迟一个时钟周期
//所以段选信号改为组合逻辑
always@(*)
begin
    case(data_disp)
    4'd0 :  seg =   {point_disp,7'b100_0000};   //显示数字0，字母O
    4'd1 :  seg =   {point_disp,7'b111_1001};   //显示数字1
    4'd2 :  seg =   {point_disp,7'b010_0100};   //显示数字2
    4'd3 :  seg =   {point_disp,7'b011_0000};   //显示数字3
    4'd4 :  seg =   {point_disp,7'b001_1001};   //显示数字4
    4'd5 :  seg =   {point_disp,7'b001_0010};   //显示数字5
    4'd6 :  seg =   {point_disp,7'b000_0010};   //显示数字6
    4'd7 :  seg =   {point_disp,7'b111_1000};   //显示数字7
    4'd8 :  seg =   {point_disp,7'b000_0000};   //显示数字8
    4'd9 :  seg =   {point_disp,7'b001_0000};   //显示数字9
    4'd10:  seg =   {point_disp,7'b100_0111};   //显示字母L
    4'd11:  seg =   {point_disp,7'b000_1000};   //显示字母A
    4'd12:  seg =   {point_disp,7'b010_0001};   //显示字母d
    4'd13:  seg =   {point_disp,7'b000_0110};   //显示字母E
    4'd14:  seg =   {point_disp,7'b111_1111};   //全灭
    4'd15:  seg =   {point_disp,7'b011_1111};   //显示负号  // 依照现在 alarm 中小时个位加计数进制的逻辑，“负号”的编码必须是F，编码必须是4位，使得加计数能够溢出清零！
    
    // 请看上方对data_disp赋值的case语句，这种逻辑下，disp最大只能是4位宽，无法被赋予15以上的值！！
    // 所以只能根据现有的需求，将需要的编码，不需要的只能舍弃
    // data_disp也没必要定义成5位宽以增加编码数量了
    
    default:seg =   {8{1'b1}};                       //异常：全不显示
    endcase
end

endmodule