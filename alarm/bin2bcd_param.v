/*
 * 模块：bin2bcd_param
 * 功能：将任意位宽二进制数转换为压缩BCD码（每4位一组十进制数）。
 *       采用“加3移位”（Double Dabble）算法。
 * 参数：BIN_WIDTH  - 二进制输入位宽（默认8，支持0~255）
 * 输出：BCD_WIDTH  - 自动计算得到的BCD总位宽（4的倍数）
 * 输出格式：最高4位为最高位十进制数（如百位），依次到最低4位为个位。
 */
module bin2bcd_param #(
    parameter BIN_WIDTH = 8
) (
    input  wire [BIN_WIDTH-1:0] bin,   // 二进制输入
    output reg  [(function_bcd_digits(BIN_WIDTH) * 4) - 1 : 0] bcd    // BCD输出
);

    // 函数：根据二进制位宽精确计算所需十进制位数
    function integer function_bcd_digits(input integer width);
        integer max_val;
        integer i;
        begin
            max_val = (1 << width) - 1;   // 最大值：2^width - 1
            i = 1;
            // 找最小的 i 使 10^i > max_val
            while ((10 ** i) <= max_val) begin
                i = i + 1;
            end
            function_bcd_digits = i;
        end
    endfunction
                 
    // 计算所需BCD十进制位数
    localparam BCD_DIGITS = function_bcd_digits(BIN_WIDTH);
    // BCD总位宽（4位一组）
    localparam BCD_WIDTH  = BCD_DIGITS * 4;
        // 移位寄存器总宽度 = BCD_WIDTH + BIN_WIDTH
    localparam SHIFT_WIDTH = BCD_WIDTH + BIN_WIDTH;

    reg [SHIFT_WIDTH-1:0] shift_reg;    // 移位寄存器
    integer i, j;   // 循环变量




    always @(*) begin   
                // 初始化：高BCD_WIDTH位清零，低BIN_WIDTH位接输入二进制
        shift_reg = { {BCD_WIDTH{1'b0}}, bin };

        // Double Dabble 核心算法
        // 进行 BIN_WIDTH 次移位
        for (i = 0; i < BIN_WIDTH; i = i + 1) begin
            // 对每一组4位BCD进行“≥5则加3”的调整
            // BCD组从高位到低位排列：索引范围 [SHIFT_WIDTH-1 -: 4] 为最高位组，依次向右
            for (j = 0; j < BCD_DIGITS; j = j + 1) begin
                // 当前BCD组在shift_reg中的起始位 = SHIFT_WIDTH - 4*(j+1)
                // 简写：使用动态位选
                if (shift_reg[SHIFT_WIDTH - 4*(j+1) +: 4] >= 5)
                    shift_reg[SHIFT_WIDTH - 4*(j+1) +: 4] =
                        shift_reg[SHIFT_WIDTH - 4*(j+1) +: 4] + 2'd3;
            end
            
            // 整体左移1位
            shift_reg = shift_reg << 1;
        end

        // 移位结束后，高 BCD_WIDTH 位即为最终的BCD结果
        bcd = shift_reg[SHIFT_WIDTH-1 -: BCD_WIDTH];
    end

endmodule