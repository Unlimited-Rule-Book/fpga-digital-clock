// =============================================================================
// 文件名：reset_sync.v
// 功能：同步复位器，异步断言，同步释放，兼顾PLL锁定
//
// 说明：对I/O口输入的复位信号与PLL锁定信号进行整合
//      PLL锁定之前pll_locked输入0，此时系统处于强制复位状态，锁定后pll_locked输出1，复位取决于I/O口输入
// =============================================================================
// 
module reset_sync (
    input  wire sys_clk,     // 系统时钟
    input  wire key_rst_n,   // 外部按键复位，低有效（直接来自I/O引脚）
    input  wire pll_locked,  // PLL锁定信号
    output reg  sys_rst_n    // 给全系统用的同步复位，低有效
);
    reg rff1;

    // 只有按键信号作为async reset送入FF，走专用布线，无警告
    // pll_locked 在同步路径中控制释放时机
    always @(posedge sys_clk or negedge key_rst_n) begin
        if (!key_rst_n) begin
            rff1      <= 1'b0;   // 异步断言，立即复位
            sys_rst_n <= 1'b0;
        end else begin
            rff1      <= pll_locked; // PLL未锁定时一直维持0，锁定后才释放
            sys_rst_n <= rff1;       // 两级同步，消除来自pll_locked的亚稳态
        end
    end
endmodule