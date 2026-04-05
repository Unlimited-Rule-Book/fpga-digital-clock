// =============================================================================
// 文件名：seg_dynamic.v
// 功能：六位数码管动态扫描驱动模块
//
// 扫描原理：
//   六个数码管轮流点亮（每次只亮一个），利用人眼视觉暂留形成"同时显示"的效果。
//   扫描时钟 seg_clk 由 pre_clk（1MHz）内部分频生成，周期约1ms（500计数后翻转）。
//   六个位轮流一遍共6ms，即刷新率约167Hz，远高于人眼分辨率。
//
// 小数点控制：
//   通过 sec_clk（1Hz，50%占空比）的跳变沿检测实现1s闪烁。
//   point_en 在每次跳变时翻转，控制 point_disp 的最终输出。
//   point_out[i] 为1表示第i位需要显示小数点（如时分之间、分秒之间）。
//
// 段码约定（低电平点亮，共阳极数码管）：
//   seg[7]=小数点, seg[6:0] 对应 g, f, e, d, c, b, a（bit6=g, bit0=a）
//   当前支持数字0~9和字母A~F（4'd0~4'd15）
//   ⚠ 若需显示 L、d 等字符（如置数模式的"LOAd"提示），需扩展 data_disp 位宽
//     并在 case 语句中新增对应段码。
//
// 与 hc595_ctrl 的配合：
//   sel（6位位选）和 seg（8位段选）送入 hc595_ctrl，
//   通过两片级联的74HC595串行传输到数码管。
// =============================================================================
module seg_dynamic
(
input   wire    sys_clk,
input   wire    pre_clk,                //数码管刷新时钟，1us为周期，PLL生成
input   wire    sec_clk,                //为实现数码管以1s为周期闪烁
input   wire    reset,
input   wire    [7:0]   out_second,
input   wire    [7:0]   out_minute,
input   wire    [7:0]   out_hour,
input   wire    [5:0]   point_out,

output  reg     [5:0]   sel = 6'b11_1111,  //数码管位选信号，初值为选中所有数码管
output  reg     [7:0]   seg = 8'b0          //数码管段选信号，初值为点亮数码管的所有段
);
//定义常量
parameter   CNT_MAX = 9'd500;            //数码管以1ms为周期进行扫描，待分频时钟1mhz计500个数后反转，刷新数码管的时钟的电平

//定义中间变量——数码管刷新时钟
reg     [$clog2(CNT_MAX)-1:0]  cnt_1ms = 9'b0;         //1ms计数器，每1ms刷新一次数码管，24_999需要定义15位十进制数
reg     seg_clk = 1'b1;

//定义中间变量——数码管数据显示
reg     [2:0]   cnt_sel = 3'b0;         //位选信号计数器
reg     [3:0]   data_disp = 4'b0;       //为了避免case语句嵌套，增强可读性，定义此变量位段选信号生成的中间变量，此变量不包含小数点
reg     point_en   = 1'b1;              //为了实现小数点以1s为周期闪烁而定义数码管使能信号
reg     point_disp = 1'b0;              //当前数码管显示的小数点
//定义锁存器——存储sec_clk在seg_clk的上一周期的值
reg     sec_clk_prev = 1'b1;


//  --------------------  主程序  --------------------

//seg_clk:数码管刷新时钟
//  ----------------------------如需添加复位信号，则可将divider中的脉冲pulse引出，作为刷新时钟的复位信号--------------------------
always@(posedge pre_clk)
begin
    if(cnt_1ms==CNT_MAX)
        begin
        seg_clk <= ~seg_clk;
        cnt_1ms <= 9'd0;        //如果pre_clk改了，这里0的大小也得从3改成其它数
        end
    else
        cnt_1ms <= cnt_1ms + 1'b1;
end

//cnt_sel:位选信号计数器
//always@(posedge seg_clk or negedge reset)
always@(posedge seg_clk)
begin
//    if(!reset)
    if(reset==1'b0)
        cnt_sel <= 3'b0;
    else if(cnt_sel==3'd5)
        cnt_sel <= 3'b0;
    else
        cnt_sel <= cnt_sel + 1'b1;
end

//data_disp,sel:位选信号生成与控制六个数码管位选信号，使数码管轮流显示
//always@(posedge seg_clk or negedge reset)
always@(posedge seg_clk)
begin
//    if(!reset)
    if(reset==1'b0)
        begin data_disp <= 4'd15; sel <= 6'b11_1111; end    //复位：全显示
    else
        begin
        case(cnt_sel)
        3'd0:   begin data_disp   <=  out_second[3:0];  sel <=  6'b00_0001; end
        3'd1:   begin data_disp   <=  out_second[7:4];  sel <=  6'b00_0010; end
        3'd2:   begin data_disp   <=  out_minute[3:0];  sel <=  6'b00_0100; end
        3'd3:   begin data_disp   <=  out_minute[7:4];  sel <=  6'b00_1000; end
        3'd4:   begin data_disp   <=  out_hour[3:0];    sel <=  6'b01_0000; end
        3'd5:   begin data_disp   <=  out_hour[7:4];    sel <=  6'b10_0000; end
        default:begin data_disp   <=  4'dx;             sel <=  6'b00_0000; end //异常：全不显示，data_disp也没有4'dx这个取值
        endcase
        end
end

//数码管数据显示，小数点以1s为周期闪烁
//always@(posedge sys_clk or negedge reset)    //采用一样的时钟seg_clk
always@(posedge sys_clk)
begin
//    if(!reset)
    if(reset==1'b0)
        point_en <= 1'b1;
    else if(sec_clk != sec_clk_prev)
        point_en <= ~point_en;
    else
        point_en <= point_en;
end
//但是sec_clk为边沿触发而非电平触发，
//所以需要定义锁存器sec_clk_prev记录sec_clk上一时刻的状态
//always@(posedge sys_clk or negedge reset)
always@(posedge sys_clk)
begin
//    if(!reset)
    if(reset==1'b0)
        sec_clk_prev <= 1'b1;
    else
        sec_clk_prev <= sec_clk;
end


//point_disp:为了增强可读性，也为了使对小数点的操作更加灵活，设置小数点寄存器，低电平点亮，所以需要对输入信号取反
//always@(posedge seg_clk or negedge reset)
always@(posedge seg_clk)
begin
//    if(!reset)
    if(reset==1'b0)
        point_disp <= 1'b0;
    else if(point_en==1'b1)
        point_disp <= ~point_out[cnt_sel];
    else if(point_en==1'b0)
        point_disp <= 1'b1;
    else
        point_disp <= point_disp;
end

//seg:控制数码管段选信号，低电平点亮数码管
//原本的代码采取的是seg_clk上升沿触发
//由于data_disp的更新和seg的生成是同一时钟上升沿触发的，但seg依赖于data_disp的值，这导致了段选信号比位选信号延迟一个时钟周期
//所以段选信号改为组合逻辑
always@(*)
begin
//    if(!reset)
    if(reset==1'b0)
        seg <=  8'b0;                               //复位：全显示
    else
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
        4'd10:  seg =   {point_disp,7'b100_0111};   //显示数字L
        4'd11:  seg =   {point_disp,7'b000_1000};   //显示数字A
        4'd12:  seg =   {point_disp,7'b010_0001};   //显示数字d
        4'd13:  seg =   {point_disp,7'b100_0110};   //显示数字C
        4'd14:  seg =   {point_disp,7'b111_1111};   //全灭
        4'd15:  seg =   8'b0;                       //全显示
        
        // 请看上方对data_disp复制的case语句，这种逻辑下，disp无法被赋予15以上的值！！
        // 所以只能根据现有的需求，将需要的编码，不需要的只能舍弃
        // data_disp也没必要定义成5位宽的了
        // 5'd11:  seg =   {point_disp,7'b000_0011};   //显示数字B       
        // 5'd14:  seg =   {point_disp,7'b000_0110};   //显示数字E
        // 5'd15:  seg =   {point_disp,7'b000_1110};   //显示数字F
                                                    //数字G无法显示  
        // 5'd16:  seg =   {point_disp,7'b000_1001};   //显示数字H
                                                    //数字I无法显示
                                                    //数字J无法显示
                                                    //数字K无法显示
//        5'd16:  seg =   8'b1011_1111;               //显示负号

        default:seg =   8'b1;                       //异常：全不显示
        endcase
        end
end

endmodule