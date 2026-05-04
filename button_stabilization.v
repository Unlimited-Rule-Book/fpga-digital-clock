// =============================================================================
// 文件名：button_stabilization.v
// 功能：按键消抖模块（单键，低电平按下）
//
// 参数：
//   DEBOUNCE_MS : 消抖时间，单位ms，默认20ms。修改此参数即可调整消抖时间，
//                 无需关心内部计数器大小（计数器位宽由$clog2自动计算）
//
// 工作原理：
//   以 pulse_1ms（每1ms一个20ns高脉冲）为计数使能，
//   按键信号每发生变化时开始计数，若计满 DEBOUNCE_MS 个ms仍未弹回，
//   则认为状态稳定，更新消抖后输出。若中途弹回则清零重新等待。
//
// 资源对比（与原50MHz直接计数方案）：
//   原方案：消抖计数器需20位（count to 1,000,000）
//   现方案：消抖计数器仅需 $clog2(DEBOUNCE_MS) 位（20ms时为5位），节省15位FF
//
// 注意：不要修改时序约束里对 sys_clk 的频率设定，pulse_1ms 是使能信号而非时钟。
// =============================================================================
module button_stabilization#(
parameter DEBOUNCE_MS = 20      // 消抖时间20ms（按实际调整）
)
(
input   wire   sys_clk,         // 系统时钟（如50MHz）
input   wire   pulse_1ms,       // 1ms脉冲，使能信号
input   wire   reset,           // 异步低电平复位
input   wire   button_in,       // 按键输入（低电平按下）
output  wire   button_out       //低电平有效
);

//  ------  下面这几行代码的思路很不错，输入系统时钟和需要的时间，让CPU计算计数最大值  ------
// // // 参数计算
// // parameter CLK_FREQ = 50_000_000, // 输入时钟频率，单位Hz，这是默认值，实例化时可修改
// // parameter DEBOUNCE_TIME = 20    // 消抖时间20ms（按实际调整）
// 计算计数值
localparam DEBOUNCE_CNT_MAX = DEBOUNCE_MS - 1;  // 20ms计数值，// 计满 DEBOUNCE_MS 个ms
//  ------                                                             ------

// 内部信号
reg button_sync;                // 同步后的按键信号
reg button_debounced;           //按键消抖后的状态
reg [$clog2(DEBOUNCE_MS)-1:0] debounce_counter;    // 消抖计数器

// 同步按键输入（避免亚稳态）
always @(posedge sys_clk) begin
    if (!reset) 
        button_sync <= 1'b1;  // 默认按键未按下（高电平）
    else
        button_sync <= button_in;
end

// 按键消抖逻辑
always @(posedge sys_clk) begin
    if (!reset)
    begin
        debounce_counter <= 0;
        button_debounced <= 1'b1;
    end
    else begin        
       if (button_sync != button_debounced) begin   // 按键状态变化
            if (pulse_1ms) begin
                if (debounce_counter >= DEBOUNCE_CNT_MAX) begin
                    button_debounced <= button_sync;    // 更新消抖后状态
                    debounce_counter <= 0;
                end
                else 
                    debounce_counter <= debounce_counter + 1;
            end
        end
        else 
            debounce_counter <= 0;
    end 

end

assign  button_out = button_debounced;

endmodule