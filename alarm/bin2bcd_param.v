// =============================================================================
// 文件名：bin2bcd_param.v
// 功能：二进制转 BCD 码，每 4 位表示一位十进制数
//
// 参数：
//   BIN_WIDTH : 二进制输入位宽，默认 8，支持 1~16 位
//
// 工作原理：
//   使用加 3 移位（Double Dabble）算法，纯组合逻辑，无需时钟。
//   BCD 输出位宽随 BIN_WIDTH 自动计算，高位为十进制高位。
// =============================================================================
module bin2bcd_param #(
parameter BIN_WIDTH = 8
)
(
input   wire    [BIN_WIDTH-1:0] bin,                        // 二进制输入
output  reg     [(function_bcd_digits(BIN_WIDTH)*4)-1:0] bcd // BCD 输出
);

// 根据输入位宽确定十进制位数；BIN_WIDTH 的有效范围为 1~16
function integer function_bcd_digits;
    input integer width;
    begin
        if(width <= 3)
            function_bcd_digits = 1;
        else if(width <= 6)
            function_bcd_digits = 2;
        else if(width <= 9)
            function_bcd_digits = 3;
        else if(width <= 13)
            function_bcd_digits = 4;
        else
            function_bcd_digits = 5;
    end
endfunction

localparam BCD_DIGITS  = function_bcd_digits(BIN_WIDTH); // 十进制位数
localparam BCD_WIDTH   = BCD_DIGITS * 4;                 // BCD 总位宽
localparam SHIFT_WIDTH = BIN_WIDTH + BCD_WIDTH;         // 移位寄存器总位宽

reg [SHIFT_WIDTH-1:0] shift_reg;
integer i, j;

// 加 3 移位：每处理一位二进制数，先调整 BCD，再整体左移
always@(*) begin
    shift_reg = {{BCD_WIDTH{1'b0}}, bin};

    for(i=0; i<BIN_WIDTH; i=i+1) begin
        for(j=0; j<BCD_DIGITS; j=j+1) begin
            if(shift_reg[BIN_WIDTH+j*4 +: 4] >= 4'd5)
                shift_reg[BIN_WIDTH+j*4 +: 4] =
                    shift_reg[BIN_WIDTH+j*4 +: 4] + 4'd3;
        end
        shift_reg = shift_reg << 1;
    end

    bcd = shift_reg[SHIFT_WIDTH-1 -: BCD_WIDTH];
end

endmodule
