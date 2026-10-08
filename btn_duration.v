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
//   long_press  : 长按触发，在按满3s时立即输出低电平信号，直到按键抬起才恢复高电平
//
// 判定逻辑：
//   按下时间 0ms~500ms，抬起后：short_press触发（低脉冲持续20ms后自动拉高）
//   按下时间 500ms~3000ms，抬起后：无效，short_press/long_press均不触发
//   按下时间 >= 3000ms：long_press立即触发，同时 press_cnt 清零（防止重复触发）
//
// 与 btn_debounce 的联系与区别：
//   1. 本身不含按键消抖，按键输入信号已经过消抖
//   2. 可以将 分频功能 嵌入本模块内，当然也可以直接用 sys_divider 产生的 pulse_1ms ，具体原因见 btn_debounce.v 模块
//     2.5 分频功能嵌入的优势：如果忽略2us同步误差（下面介绍），每次按键按下, pre_ms_cnt 都从零相位开始计时
//                      反之，如果将分频功能交给 sys_divider, 系统分频器是连续工作的，故按键按下的时刻会落在
//                      1ms计数器 计数的任意时刻（相位），造成第 1ms 计时不完整（0~1ms 早计）
//
// 内部 pulse_1ms 的启动与精度说明：
//   1. 使能链路：active(=cs!=IDLE, sys_clk域) -- 2拍pre_clk同步 --> pre_clk_en(pre_clk域)，控制 pre_clk 域计数器启停；
//      sys_clk 域同步链由本域 active 直接门控（不用 pre_clk_en, 因为它是 pre_clk 域信号）。
//   2. 固有偏差：进入 TIMING 后计数晚约 2us 才出首个 pulse_1ms, 是将 active 同步到 pre_clk 域的代价；
//      active 撤销时 sys_clk 域先停、pre_clk 域滞后约 2us 停, 2us 窗口内即使 pre_ms_cnt 计满使得 pre_ms_flag 翻转，
//                                                              也不会被 sys_clk 域的三级同步器捕获，无假脉冲。
//
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
localparam SHORT_END_CNT_MAX  = SHORT_END_MS  - 1;  // 短按按键判定：最长不长于500ms计数值
localparam LONG_PRESS_CNT_MAX = LONG_PRESS_MS - 1;  // 长按时间3秒


// 定义计数器
reg [$clog2(LONG_PRESS_MS)-1:0] press_cnt;  // 长短按计数器
localparam SHORT_DURATION_MS = 20;          // 短按按下后，保持 20ms 再拉高
localparam SHORT_DURATION_CNT_MAX = SHORT_DURATION_MS - 1;
reg [$clog2(SHORT_DURATION_MS)-1:0] shortdur_press_cnt;


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
    if(!rst_n)
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
        if(press_cnt <= SHORT_END_CNT_MAX && button_in)       // 小于短按结束时长 && 按键抬起 触发短按
            ns = SHORT_FIRED;
        else if(press_cnt >= LONG_PRESS_CNT_MAX && ~button_in)// 大于长按开始时长 && 按键未抬起 触发长按
            ns = LONG_FIRED;
        else if(press_cnt > SHORT_END_CNT_MAX && press_cnt <= LONG_PRESS_CNT_MAX && button_in)
            ns = IDLE;                                      // 介于长短按边界 && 抬起按键 无效按键
        // 注意：上面两个分支必须都要是 press_cnt >= LONG_PRESS_CNT_MAX ，这样才能把press_cnt = LONG_PRESS_CNT_MAX 边界的两种情况： ~button_in 与 button_in 都讨论到
        else
            ns = TIMING;                                    // 其余情况 继续计时
    end
    SHORT_FIRED: begin
        if(shortdur_press_cnt >= SHORT_DURATION_CNT_MAX)
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
wire    active;
assign  active = (cs != IDLE);
reg     active_sync1, active_sync2;
always@(posedge pre_clk) begin
    if(!rst_n) begin
        active_sync1 <= 1'b0; active_sync2 <= 1'b0;
    end
    else begin
        active_sync1 <= active;
        active_sync2 <= active_sync1;
    end
end
wire    pre_clk_en;
assign  pre_clk_en = active_sync2;
// pre_clk 域：1ms toggle flag（将 1000 个 pre_clk 周期翻转一次）
localparam PRE_CLK_PER_MS = 1_000;   // pre_clk 是 1MHz，1ms = 1000个周期
reg [$clog2(PRE_CLK_PER_MS)-1:0] pre_ms_cnt;
reg pre_ms_flag;
always @(posedge pre_clk) begin
    if (!rst_n) begin
        pre_ms_cnt  <= 0;
        pre_ms_flag <= 1'b0;
    end else if(pre_clk_en) begin
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
reg pre_ms_sync1, pre_ms_sync2, pre_ms_sync3;
reg pulse_1ms;
always @(posedge sys_clk) begin
    if (!rst_n) begin
        pre_ms_sync1 <= 0; pre_ms_sync2 <= 0; pre_ms_sync3 <= 0;
        pulse_1ms <= 0;
    end else if(active) begin
        pre_ms_sync1 <= pre_ms_flag;
        pre_ms_sync2 <= pre_ms_sync1;
        pre_ms_sync3 <= pre_ms_sync2;
        pulse_1ms <= pre_ms_sync2 ^ pre_ms_sync3;
    end else begin
        pre_ms_sync1 <= 0; pre_ms_sync2 <= 0; pre_ms_sync3 <= 0;
        pulse_1ms <= 0;
    end
end

// 状态输出
always@(posedge sys_clk)
begin
    if(!rst_n)begin
        press_cnt <= 0;
        shortdur_press_cnt <= 0;
        short_press <= 1'b1;
        long_press <= 1'b1;
    end
    else begin
        case(cs)
        IDLE: begin
            press_cnt <= 0;
            shortdur_press_cnt <= 0;
            short_press <= 1'b1;
            long_press <= 1'b1;
        end
        TIMING: begin
            if (pulse_1ms) press_cnt <= press_cnt + 1'b1;
            shortdur_press_cnt <= 0;
            short_press <= 1'b1;
            long_press <= 1'b1;
        end
        SHORT_FIRED: begin
            press_cnt <= 0;
            if (pulse_1ms) shortdur_press_cnt <= shortdur_press_cnt + 1'b1;
            short_press <= 1'b0;
            long_press <= 1'b1;
        end
        LONG_FIRED: begin
            press_cnt <= 0;
            shortdur_press_cnt <= 0;
            short_press <= 1'b1;
            long_press <= 1'b0;
        end
        default: begin
            press_cnt <= 0;
            shortdur_press_cnt <= 0;
            short_press <= 1'b1;
            long_press <= 1'b1;
        end
        endcase
    end
end

endmodule