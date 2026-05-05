// =============================================================================
// 文件名：button_stabilization_long_short.v
// 功能：按键消抖 + 长按/短按判定模块（单键，低电平按下）
//
// 参数（单位均为ms，修改参数即可调整时间，无需修改内部逻辑）：
//   DEBOUNCE_MS  : 消抖时间，默认20ms
//   SHORT_END_MS : 短按有效上限，默认500ms（按下到抬起时间 < 此值判为短按）
//   LONG_PRESS_MS: 长按触发时间，默认3000ms（按满3s立即触发，不等抬起）
//
// 输出信号（均为低电平有效）：
//   short_press : 短按触发，在按键抬起后输出约20ms宽的低电平脉冲
//   long_press  : 长按触发，在按满3s时立即输出约1ms宽的低电平脉冲
//
// 判定逻辑：
//   按下时间 <  20ms（消抖区）：滤除抖动，不产生任何输出
//   按下时间 20ms~500ms，抬起后：short_press触发（低脉冲持续20ms后自动拉高）
//   按下时间 500ms~3000ms，抬起后：无效，short_press/long_press均不触发
//   按下时间 >= 3000ms：long_press立即触发，同时press_counter清零（防止重复触发）
//
// 与 button_stabilization 的区别：
//   增加了 press_counter（按压计时）和 short_counter（短按脉冲宽度控制），
//   实现了三段式时间判定。
// =============================================================================
module button_stabilization_long_short #(
parameter DEBOUNCE_MS = 20,      // 消抖时间20ms（按实际调整）
parameter SHORT_END_MS = 500,    // 短按按键判定：最长不长于0.5秒
parameter LONG_PRESS_MS = 3_000   // 长按时间3秒
)
(
input   wire   sys_clk,     // 系统时钟（如50MHz）
// input   wire   pre_clk,     // PLL产生的占空比50%、1MHz的时钟，
input   wire   reset,       // 异步低电平复位
input   wire   button_in,   // 按键输入（低电平按下）

output  reg    short_press, // 短按触发信号，低电平有效
output  reg    long_press   // 长按触发信号，低电平有效
);


localparam CLK_FREQ = 50_000_000;
localparam CLK_PER_MS = CLK_FREQ / 1_000;
// reg [$clog2(CLK_PER_MS)-1:0] clk_cnt;

// 计算计数值
localparam DEBOUNCE_CNT_MAX   = DEBOUNCE_MS  *CLK_PER_MS - 1; // 消抖时间20ms计数值
localparam SHORT_END_CNT_MAX  = SHORT_END_MS *CLK_PER_MS - 1; // 短按按键判定：最长不长于500ms计数值
localparam LONG_PRESS_CNT_MAX = LONG_PRESS_MS*CLK_PER_MS - 1; // 长按时间3秒


// 内部信号
reg button_sync;        // 同步后的按键信号
reg button_debounced;   // 消抖后的按键状态
reg [$clog2(DEBOUNCE_CNT_MAX)-1:0] debounce_counter;  // 消抖计数器
reg [$clog2(LONG_PRESS_CNT_MAX)-1:0] press_counter;   // 短按长按计时计数器=========================注释掉用于测试

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
           if (debounce_counter >= DEBOUNCE_CNT_MAX) begin
               button_debounced <= button_sync;    // 更新消抖后状态
               debounce_counter <= 0;
           end
           else 
               debounce_counter <= debounce_counter + 1;
        end
        else 
            debounce_counter <= 0;
    end
end

//短按与长按计时逻辑
// // // // 1ms脉冲信号
// // // reg pulse_1ms;
// // // always@(posedge sys_clk)begin
    // // // if(!reset)begin
    
    
    // // // end
    // // // else if(button_debounced==0) begin
    
    
    
    // // // end


// // // end

//短按信号计数器
reg [$clog2(DEBOUNCE_CNT_MAX)-1:0] short_counter;    // 用于拉高短按信号
// 长按标志
reg long_press_fired = 1'b0;
// 按键抬起——采取跳沿检测
reg button_debounced_prev;

always @(posedge sys_clk) begin
    if (!reset) begin
        press_counter <= 0;
        short_counter <= 0;
        short_press <= 1'b1;
        long_press <= 1'b1;
        long_press_fired <= 1'b0;
        button_debounced_prev <= 1'b1;
    end
    else begin
        button_debounced_prev <= button_debounced;
        if (button_debounced==1'b0)begin    // 按键按下（低电平）
            short_counter <= 5'd0;   // 新增：每次按下时清零short_counter，防止上次残留值影响本次短按脉冲宽度
            if (press_counter < SHORT_END_CNT_MAX)begin
                press_counter <= press_counter + 1;
                short_press <= 1'b1;     // 未达到0.5秒，且按键未抬起，不触发短按长按
            end
            else if(press_counter >= SHORT_END_CNT_MAX && press_counter < LONG_PRESS_CNT_MAX)begin
                press_counter <= press_counter + 1;
                short_press <= 1'b1;      // 达到0.5秒，不是短按信号,可能为长按信号，继续计时
            end
            else if(press_counter >= LONG_PRESS_CNT_MAX)begin
                press_counter <= press_counter;
                long_press <= 1'b0;       // 达到3秒，是长按信号，无论此后按键是否抬起，都立即生效，press_counter在按键抬起时才清零
                short_press <= 1'b1;
                long_press_fired <= 1'b1; // 拉高长按标志
            end
            else begin
                press_counter <= press_counter + 1;
                short_press <= 1'b1;
                long_press <= 1'b1;    
            end
        end
        else begin              // 按键抬起 
            if(press_counter < SHORT_END_CNT_MAX && !long_press_fired)begin 
            //按键抬起且小于0.5秒，并且长按标志为0，判定为短按
                if(button_debounced == 1'b1 && button_debounced_prev == 1'b0) begin
                // 只在 button_debounced 从0变1（刚松开）的那一个周期才检查
                    short_press <= 1'b0;
                    press_counter <= press_counter;
                end
                // else，保持
                //为避免按键抬起后，短按信号维持低电平，20ms后将其强制拉高；同时为了持续计数，先使press_counter维持原态
                if(short_counter < DEBOUNCE_CNT_MAX)
                    short_counter <= short_counter + 1'b1;
                else begin
                    press_counter <= 0; //此操作会使按键一直未按下时，不会重复触发短按信号
                                        //（即press_counter小于0，if条件判断为逻辑零，不进入此分支）
                    short_press <= 1'b1;
                    long_press <= 1'b1;
                    short_counter <= 0;
                end                
            end
            else if(press_counter >= SHORT_END_CNT_MAX && press_counter < LONG_PRESS_CNT_MAX)begin
                press_counter <= 0;          
                short_press <= 1'b1;
                long_press <= 1'b1;                     //按键抬起且大于0.5秒，小于3秒，判定为无效
            end
            else begin
                press_counter <= 0;
                short_press <= 1'b1;
                long_press <= 1'b1;      //长按3秒后抬起，或处于press_counter未开始计数的状态
                long_press_fired <= 1'b0;//彻底松开按键后，清除长按标志
            end
        end
    end
end

endmodule