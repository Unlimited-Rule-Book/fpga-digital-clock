// =============================================================================
// 文件名： btn_debounce.v
// 功能：按键消抖模块（单键，低电平按下）
//
// 参数：
//   DEBOUNCE_MS : 消抖时间，单位ms，默认20ms。修改此参数即可调整消抖时间，
//                 无需关心内部计数器大小（计数器位宽由 $clog2 自动计算）
//
// 工作原理：
//   以 pulse_1ms（每1ms一个20ns高脉冲）为计数使能，
//   按键信号每发生变化时开始计数，若计满 DEBOUNCE_MS 个ms仍未弹回，
//   则认为状态稳定，更新消抖后输出。若中途弹回则清零重新等待。
//
// 输出信号：
//   单纯输出无抖动的信号，按键按下多久， button_out 的电平就拉低多久，而不是像野火官方一样生成脉冲信号
//   这样的好处是 1. 最大程度地保留原始按键信号 2. 允许与长短按模块拼接，如果本代码生成脉冲，则长短按模块就无法判定长短，只能内置消抖代码
//
// 资源对比（与原 50MHz 直接计数方案）：
//   原方案：消抖计数器需20位（count to 1,000,000）
//   现方案：消抖计数器仅需 $clog2(DEBOUNCE_MS) 位（20ms时为5位），节省15位 FF
//
// 1ms 使能信号的其它方案讨论
//    从 pre_clk 分频至 pulse_1ms 使能信号是 btn_debounce 内部业务，能否将其嵌入本 module 内部，并令分频功能在按键按下时才使能呢？
//    不可以, btn_debounce 的计数使能信号绝不能由按键状态门控，
//    因为"按键是否稳定按下"正是 debounce 计数器要给出的输出——用输出门控输入就是自锁/循环依赖。
//    相比之下， btn_duration 输入的是已经消抖干净的 (顶层)load_db, 按键状态已确定，
//    它只需测量"已确定按下"的持续时长，所以内部用 pre_clk 自分频 + 按键状态门控是合法的。
//
// 注意：不要修改时序约束里对 sys_clk 的频率设定， pulse_1ms 是使能信号而非时钟。
// =============================================================================
module btn_debounce#(
parameter DEBOUNCE_MS = 20      // 消抖时间20ms（按实际调整）
)
(
input   wire   sys_clk,         // 系统时钟（如50MHz）
input   wire   pulse_1ms,       // 1ms脉冲，使能信号
input   wire   rst_n,           // 同步低电平复位
input   wire   button_in,       // 按键输入（低电平按下）

output  wire   button_out       //低电平有效
);

localparam DEBOUNCE_CNT_MAX = DEBOUNCE_MS - 1;  // 20ms计数值，// 计满 DEBOUNCE_MS 个ms

reg button_sync1, button_sync2; // 同步后的按键信号
reg button_debounced;           //按键消抖后的状态
reg [$clog2(DEBOUNCE_MS)-1:0] debounce_counter;    // 消抖计数器

// 同步按键输入（避免亚稳态）
always @(posedge sys_clk) begin
    if (!rst_n) begin
        button_sync1 <= 1'b1; // 默认按键未按下（高电平）
        button_sync2 <= 1'b1;
    end
    else begin
        button_sync1 <= button_in;
        button_sync2 <= button_sync1;
    end
end

// 按键消抖逻辑
always @(posedge sys_clk) begin
    if (!rst_n)
    begin
        debounce_counter <= 0;
        button_debounced <= 1'b1;
    end
    else begin        
       if (button_sync2 != button_debounced) begin  // 按键状态变化
            if (pulse_1ms) begin
                if (debounce_counter >= DEBOUNCE_CNT_MAX) begin
                    button_debounced <= button_sync2;   // 更新消抖后状态
                    debounce_counter <= 0;
                end
                else 
                    debounce_counter <= debounce_counter + 1'b1;
            end
        end
        else 
            debounce_counter <= 0;
    end 

end

assign  button_out = button_debounced;

endmodule