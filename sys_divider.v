// =============================================================================
// 文件名：sys_divider.v
// 功能：系统多输出分频器（由 pulse_sec.v 扩展重命名而来）
//
// 输入时钟：pre_clk（PLL输出，1MHz），sys_clk（系统时钟，50MHz）
//
// 输出信号（均在 sys_clk 域安全）：
//   pulse_1ms : 每1ms输出一个宽度为1个sys_clk周期（20ns）的高脉冲
//               → 用途：按键消抖计数使能、模式超时计数（counter_16s）使能
//   pulse_1s  : 每1s输出一个宽度为1个sys_clk周期（20ns）的高脉冲
//               → 用途：驱动 counter_time 走时
//   sec_clk   : 1Hz，50%占空比时钟（注：视觉信号，未作CDC处理，约有60ns固有延迟）
//               → 用途：seg_dynamic 小数点闪烁
//
// CDC方案：toggle-flag + 三级同步寄存器 + XOR边沿检测
//   pre_clk域的flag每个计数周期翻转一次，在sys_clk域经三级寄存器同步后，
//   通过 s2 XOR s3 检测跳变边沿，输出宽度恰好为1个sys_clk周期的高脉冲。
//   此方案同时兼顾：避免亚稳态、脉宽精确、不漏脉冲。
//
// 资源对比（与原50MHz直接计数方案）：
//   原方案：秒计数器需27位（2^27 > 50,000,000），按键消抖计数器需20位
//   现方案：两个10位链式计数器 + 两路CDC各3个同步FF，合计约26FF，节省约20FF
// =============================================================================

module sys_divider #(
    parameter CLK_FREQ = 1_000_000  // 输入时钟频率，单位Hz，这是默认值，实例化时可修改
)(
    input  wire sys_clk,            // 系统时钟，50MHz，用于同步输出脉冲
    input  wire pre_clk,            // PLL 输出时钟，1MHz，用于计数
    input  wire rst_n,
    
    output reg  pulse_1s,    // 1Hz 秒脉冲，宽度 = 1个sys_clk周期（20ns），sys_clk域安全
    output reg  pulse_1ms,   // 1kHZ毫秒脉冲，用于驱动按键消抖
    output reg  sec_clk      // 1Hz 50%占空比时钟，用于小数点闪烁驱动
);
    // ----------------------------------------------------------------
    //  pre_clk 域：计数 + toggle flag + sec_clk 生成
    // ----------------------------------------------------------------
    localparam _1MS_CNT = 1_000;                            // 1us计到1ms，共计1000个数
    localparam _1MS_MAX = _1MS_CNT - 1;                     // 最大计数值999
    localparam _1S_FULL_CNT = CLK_FREQ / _1MS_CNT;          // 每1ms自增1，共计1000个数，计满1秒
    localparam _1S_FULL_MAX = _1S_FULL_CNT - 1;             // 最大计数值999
    localparam _1S_HALF_MAX = CLK_FREQ / _1MS_CNT / 2 - 1;  // 最大计数值499，半秒翻转点

    
    reg [$clog2(_1MS_CNT)-1:0]      ms_cnt;     // 10位1毫秒（秒低位）计数器
    reg [$clog2(_1S_FULL_CNT)-1:0]  sec_cnt;    // 10位1秒（秒高位）计数器
 // 两个10位计数器级联，输出两个flag信号，一共20位计数器相比50MHz的27位节省7个FF   
    reg ms_flag;        // 每毫秒 翻转 一次，用于跨时钟域传递
    reg sec_flag;       // 每秒 toggle 一次，用于跨时钟域传递
    
    always @(posedge pre_clk) begin
        if (!rst_n) begin
            sec_cnt  <= 0;
            ms_cnt   <= 0;
            ms_flag  <= 1'b0;
            sec_flag <= 1'b0;
            sec_clk  <= 1'b1;   // 初值与原 divider 一致，为高电平
        end 
        else begin
            if(ms_cnt == _1MS_MAX) begin
                ms_cnt <= 0;
                ms_flag <= ~ms_flag;            // 每满1毫秒toggle，传递给sys_clk域
                if(sec_cnt == _1S_FULL_MAX) begin
                    sec_cnt <= 0;
                    sec_flag <= ~sec_flag;      // 每满1秒toggle，传递给sys_clk域
                    sec_clk  <= ~sec_clk;       // 整秒翻转(第二次) 
                end
                else begin
                    if(sec_cnt==_1S_HALF_MAX)
                        sec_clk <= ~sec_clk;    // 半秒翻转(第一次)实现50%占空比
                    sec_cnt <= sec_cnt + 1'b1;  // 在 if(ms_cnt == _1MS_MAX) 分支下加计数，所以加到1秒仅需1000个数
                end
            end
            else 
                ms_cnt <= ms_cnt + 1'b1;
        end
    end
    
    // ----------------------------------------------------------------
    //  sys_clk 域：三级同步寄存器 + 边沿检测 → pulse_1s
    // ----------------------------------------------------------------   
    // 三级寄存器：
    //   _s1/_s2：两级同步，消除亚稳态
    //   _s3：    延迟一拍，用于边沿检测    
    reg sec_flag_s1, sec_flag_s2, sec_flag_s3;
    reg ms_flag_s1,  ms_flag_s2,  ms_flag_s3;
    
    always @(posedge sys_clk) begin
        if (!rst_n) begin
            ms_flag_s1  <= 1'b0;
            ms_flag_s2  <= 1'b0;
            ms_flag_s3  <= 1'b0;
            pulse_1ms   <= 1'b0;
            
            sec_flag_s1 <= 1'b0;
            sec_flag_s2 <= 1'b0;
            sec_flag_s3 <= 1'b0;
            pulse_1s    <= 1'b0;
        end else begin
            ms_flag_s1  <= ms_flag;     // 第1级同步（可能亚稳态）
            ms_flag_s2  <= ms_flag_s1;  // 第2即同步（稳定输出）
            ms_flag_s3  <= ms_flag_s2;  // 第3级，用于边沿检测     
            
            sec_flag_s1 <= sec_flag;    // 第1级同步（可能亚稳态）
            sec_flag_s2 <= sec_flag_s1; // 第2级同步（稳定输出）
            sec_flag_s3 <= sec_flag_s2; // 第3级，用于边沿检测
            
            // XOR 边沿检测，上升沿和下降沿都触发（因为 sec_flag 是 toggle）
            // 每次跳变对应恰好过了1秒，pulse_out 高电平仅持续1个sys_clk周期(20ns)
            pulse_1ms <= ms_flag_s2  ^ ms_flag_s3;
            
            pulse_1s  <= sec_flag_s2 ^ sec_flag_s3;
        end
    end
    
endmodule