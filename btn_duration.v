// =============================================================================
// 文件名： btn_duration.v
// 功能：按键长/短按判定模块（单键，低电平按下）
//
// 参数（单位均为ms，修改参数即可调整时间，无需修改内部逻辑）：
//   SHORT_END_MS : 短按有效上限，默认500ms（按下到抬起时间 < 此值判为短按）
//   LONG_PRESS_MS: 长按触发时间，默认3000ms（按满3s立即触发，不等抬起）
//
// 输出信号（均为低电平有效）：
//   short_press : 短按触发，在按键抬起后输出约20ms宽的低电平脉冲
//   long_press  : 长按触发，在按满3s时立即输出约1ms宽的低电平信号，直到按键抬起才恢复高电平
//
// 判定逻辑：
//   按下时间 <  20ms（消抖区）：滤除抖动，不产生任何输出
//   按下时间 20ms~520ms，抬起后：short_press触发（低脉冲持续20ms后自动拉高）
//   按下时间 520ms~3020ms，抬起后：无效，short_press/long_press均不触发
//   按下时间 >= 3020ms：long_press立即触发，同时press_counter清零（防止重复触发）
//   注：消抖时钟 counter 与 shortdur_counter 是两个计数器， 
//       press_counter 各个计数节点均为减去消抖时长，所以后面的时间得叠加上消抖时间
//
// 与 btn_debounce 的联系与区别：
//   1. 本身不含按键消抖，按键输入信号已经过消抖
//   2. 可以将 分频功能 嵌入本模块内，当然也可以直接用 sys_divider 产生的 pulse_1ms ，具体原因见 btn_debounce.v 模块
// =============================================================================
module btn_duration#(
parameter SHORT_END_MS = 500,    // 短按按键判定：最长不长于0.5秒
parameter LONG_PRESS_MS = 3_000   // 长按时间3秒
)
(
input   wire   sys_clk,     // 系统时钟（如50MHz）
input   wire   pre_clk,     // PLL产生的占空比50%、1MHz的时钟，
input   wire   rst_n,       // 同步低电平复位
input   wire   button_in,   // 按键输入（低电平按下）

output  reg    short_press, // 短按触发信号，低电平有效
output  reg    long_press   // 长按触发信号，低电平有效
);

// 计算计数值
localparam SHORT_END_CNT_MAX  = SHORT_END_MS  - 1; // 短按按键判定：最长不长于500ms计数值
localparam LONG_PRESS_CNT_MAX = LONG_PRESS_MS - 1; // 长按时间3秒


// 定义计数器
reg [$clog2(LONG_PRESS_MS)-1:0] counter;    // 长短按计数器
localparam SHORT_DURATION_MS = 20;          // 短按按下后，保持 20ms 再拉高
localparam SHORT_DURATION_CNT_MAX = SHORT_DURATION_MS - 1;
reg [$clog2(SHORT_DURATION_MS)-1:0] shortdur_counter;


//  ====================  长短按信号产生逻辑  ====================
// 方法：三段式状态机

// 定义状态机状态
localparam  IDLE = 2'b00;
localparam  TIMING  = 2'b01;
localparam  SHORT_FIRED = 2'b10;
localparam  LONG_FIRED  = 2'b11;

// 定义状态机状态
reg [1:0]   cs, ns;

// 状态更新
always@(posedge sys_clk) begin
    if(~rst_n)
        cs <= IDLE;
    else
        cs <= ns;
end

// 状态切换
always@(*)
begin
    case(cs)
    IDLE: begin
        if(~button_in)
            ns = TIMING;
        else
            ns = IDLE;
    end
    TIMING: begin
        if(counter <= SHORT_END_CNT_MAX && button_in)       // 小于短按结束时长 && 按键抬起 触发短按
            ns = SHORT_FIRED;
        else if(counter >= LONG_PRESS_CNT_MAX && ~button_in)// 大于长按开始时长 && 按键未抬起 触发长按
            ns = LONG_FIRED;
        else if(counter > SHORT_END_CNT_MAX && counter <= LONG_PRESS_CNT_MAX && button_in)
            ns = IDLE;                                      // 介于长短按边界 && 抬起按键 无效按键
        // 注意：上面两个分支必须都要是 counter => LONG_PRESS_CNT_MAX ，这样才能把counter = LONG_PRESS_CNT_MAX 边界的两种情况： ~button_in 与 button_in 都讨论到
        else
            ns = TIMING;                                    // 其余情况 继续计时
    end
    SHORT_FIRED: begin
        if(shortdur_counter >= SHORT_DURATION_CNT_MAX)
            ns = IDLE;
        else
            ns = SHORT_FIRED;
    end
    LONG_FIRED: begin
        if(button_in)   // 按键抬起 返回空闲
            ns = IDLE;
        else if(~button_in)  // 按键未抬起 保持
            ns = LONG_FIRED;
        else
            ns = IDLE;
    end
    default: ns = IDLE;
    endcase
end

// 生成 1ms 脉冲驱动，在 cs 不为 IDLE 状态时才使能
// 将 sys_clk 域的使能信号 cs != IDLE 同步到 pre_clk 域
wire    busy;
assign  busy = (cs != IDLE);
reg     busy_s1, busy_s2;
always@(posedge pre_clk) begin
    if(!rst_n) begin
        busy_s1 <= 1'b0; busy_s2 <= 1'b0;
    end
    else begin
        busy_s1 <= busy;
        busy_s2 <= busy_s1;
    end
end
wire    run_pc;
assign  run_pc = busy_s2;
// pre_clk 域：1ms toggle flag（将 1000 个 pre_clk 周期翻转一次）
localparam PRE_CLK_PER_MS = 1_000;   // pre_clk 是 1MHz，1ms = 1000个周期
reg [$clog2(PRE_CLK_PER_MS)-1:0] pre_ms_cnt;
reg pre_ms_flag;
always @(posedge pre_clk) begin
    if (!rst_n) begin
        pre_ms_cnt  <= 0;
        pre_ms_flag <= 1'b0;
    end else if(run_pc) begin
        if (pre_ms_cnt == PRE_CLK_PER_MS - 1) begin
            pre_ms_cnt  <= 0;
            pre_ms_flag <= ~pre_ms_flag;   // 每满 1ms 翻转一次
        end else
            pre_ms_cnt <= pre_ms_cnt + 1'b1;
    end else begin
            pre_ms_cnt  <= 0;
            pre_ms_flag <= 1'b0;
    end
end
// sys_clk 域：三级同步 + XOR 边沿检测
reg pre_ms_s1, pre_ms_s2, pre_ms_s3;
reg pulse_1ms;
always @(posedge sys_clk) begin
    if (!rst_n) begin
        pre_ms_s1 <= 0; pre_ms_s2 <= 0; pre_ms_s3 <= 0;
        pulse_1ms <= 0;
    end else if(run_pc) begin
        pre_ms_s1 <= pre_ms_flag;
        pre_ms_s2 <= pre_ms_s1;
        pre_ms_s3 <= pre_ms_s2;
        pulse_1ms <= pre_ms_s2 ^ pre_ms_s3;
    end else begin
        pre_ms_s1 <= 0; pre_ms_s2 <= 0; pre_ms_s3 <= 0;
        pulse_1ms <= 0;
    end
end

// 状态输出
always@(posedge sys_clk)
begin
    if(!rst_n)begin
        counter <= 0;
        shortdur_counter <= 0;
        short_press <= 1'b1;
        long_press <= 1'b1;
    end
    else begin
        case(cs)
        IDLE: begin
            counter <= 0;
            shortdur_counter <= 0;
            short_press <= 1'b1;
            long_press <= 1'b1;
        end
        TIMING: begin
            if (pulse_1ms) counter <= counter + 1'b1;
            shortdur_counter <= 0;
            short_press <= 1'b1;
            long_press <= 1'b1;
        end
        SHORT_FIRED: begin
            counter <= 0;
            if (pulse_1ms) shortdur_counter <= shortdur_counter + 1'b1;
            short_press <= 1'b0;
            long_press <= 1'b1;
        end
        LONG_FIRED: begin
            counter <= 0;
            shortdur_counter <= 0;
            short_press <= 1'b1;
            long_press <= 1'b0;
        end
        default: begin
            counter <= 0;
            shortdur_counter <= 0;
            short_press <= 1'b1;
            long_press <= 1'b1;
        end
        endcase
    end
end

endmodule