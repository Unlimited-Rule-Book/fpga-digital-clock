// =============================================================================
// 文件名：hc595_ctrl.v
// 功能：两片级联的74HC595串行移位寄存器驱动模块
//
// 数据格式：
//   总传输14位 = 8位段选（seg）+ 6位位选（sel），sel低位先传（串行输入顺序）
//   第一片595输出8位段选（控制各段），第二片595输出6位位选（控制哪个数码管亮）
//
// 时序：
//   shcp（移位时钟）：sys_clk 四分频后约12.5MHz（满足HC595最大移位频率要求）
//   ds（串行数据）：在 shcp 上升沿前稳定（cnt_4==0时更新ds，cnt_4==2时拉高shcp）
//   stcp（存储时钟）：14位全部传完后产生一个上升沿，将移位寄存器数据锁存到输出端
//   oe（输出使能）：固定接低，始终使能输出
// =============================================================================
module  hc595_ctrl
(
input   wire    sys_clk,
input   wire    rst_n,
input   wire    [5:0]   sel,
input   wire    [7:0]   seg,

output  reg     stcp,           //数据存储时钟
output  reg     shcp,           //移位寄存器时钟，hc595的刷新时钟有频率限制，此处采用系统时钟4分频后12.5MHz的时钟
output  reg     ds,             //串行数据输入
output  wire    oe              //使能信号，低电平有效
);

//定义中间变量
reg     [1:0]   cnt_4 = 2'b00;  //4分频计数器
reg     [3:0]   cnt_bit = 4'b0; //传输位数计数器，一共要传14位数
wire    [13:0]  data;           //数码管信号寄存

//让使能信号使能
assign  oe = 1'b0;

/*1片74hc595最多锁存8位信号，溢出的会从Q7S串行输出，此时让Q7S接上另一篇595的串行输入DS即可
也就是说14位信号的高六位——正好是全部的sel信号会从第二片595输出，低八位——全部的seg信号从第一片595输出*/
/*data用于将数码管信号寄存，hc595为串行输入并行输出，先输入的被排在最高位进行输出，
所以我们把seg、sel中的最低位seg[0]放在了data的最高位（最晚输入），其余的以此类推*/
assign  data = {seg[0],seg[1],seg[2],seg[3],seg[4],seg[5],seg[6],seg[7],sel};
/*虽然但是，sel先输入的是最低位sel[0]，也就是说sel[0]会在最高位输出。
不过在硬件上，第二片595输出的高位与数码管的低位相接（这种接法在野火的FPGA上是顺畅的）
所以让sel的低位先输入没问题*/

//cnt_4:分频计数器:0-3循环计数
always@(posedge sys_clk)
begin
    if(!rst_n)
        cnt_4 <= 2'b00;
    else if(cnt_4 == 2'd3)
        cnt_4 <= 2'b00;
    else
        cnt_4 <= cnt_4 + 1'b1;
end

//cnt_bit:传输位数寄存器，记录遍历data中的数据
always@(posedge sys_clk)
begin
    if(!rst_n)
        cnt_bit <= 4'b0000;
    else if(cnt_bit==4'd13 && cnt_4==2'd3)
        cnt_bit <= 4'b0000;
    else if(cnt_4==2'd3)
        cnt_bit <= cnt_bit + 1'b1;
    else
        cnt_bit <= cnt_bit; 
end

//stcp:14个信号传输完成后产生一个上升沿
always@(posedge sys_clk)
begin
    if(!rst_n)
        stcp    <=  1'b0;
    else if(cnt_bit==4'd13 && cnt_4==2'd3)
        stcp    <=  1'b1;
    else
        stcp    <=  1'b0;
end

//shcp:产生四分频移位时钟
always@(posedge sys_clk)
begin
    if(!rst_n)
        shcp <= 1'b0;
    else if(cnt_4 == 2'd2)
        shcp <= 1'b1;
    else if(cnt_4 == 2'd0)
        shcp <= 1'b0;
    else
        shcp <= shcp;
end

//ds:将寄存器里存储的数码管信号输入
always@(posedge sys_clk)
begin
//由于seg_dynamic里已经设定了复位时数码管的显示，故此处不设置复位信号
    if(cnt_4 == 2'b0)
        ds <= data[cnt_bit];
    else
        ds <= ds;
end

endmodule