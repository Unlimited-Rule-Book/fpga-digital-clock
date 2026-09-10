// =============================================================================
// 文件名：sys_divider.v
// 功能：系统多输出分频器（由 pulse_sec.v 扩展重命名而来）
//
// 输入时钟：pre_clk（PLL输出，1MHz），sys_clk（系统时钟，50MHz）
//
// 输出信号（均在 sys_clk 域安全）：
//   pulse_1ms : 每1ms输出一个宽度为1个sys_clk周期（20ns）的高脉冲
//               → 用途：按键消抖计数使能、按键长短按判定计数使能，数码管动态显示的扫描时钟
//   pulse_1s  : 每1s输出一个宽度为1个sys_clk周期（20ns）的高脉冲
//               → 用途：驱动 counter 走时
//   sec_clk   : 1Hz，50%占空比时钟
//               → 用途：seg_dynamic 小数点闪烁
//
// CDC方案：toggle-flag + 三级同步寄存器 + XOR边沿检测
//   pre_clk域的flag每个计数周期翻转一次，在sys_clk域经三级寄存器同步后，
//   通过 s2 XOR s3 检测跳变边沿，输出宽度恰好为1个sys_clk周期的高脉冲。
//   此方案同时兼顾：避免亚稳态、脉宽精确、不漏脉冲。
//
// 资源对比（与原50MHz直接计数方案）：
//   原方案：秒计数器需26位（2^26 > 50,000,000），按键消抖计数器需20位
//   现方案：10位和9位链式计数器 + 两路CDC各3个同步FF，合计约25FF，节省约21FF
// =============================================================================

module sys_divider #(
    parameter CLK_FREQ = 1_000_000  // 输入时钟频率，单位Hz，这是默认值，实例化时可修改
)(
    input  wire sys_clk,            // 系统时钟，50MHz，用于同步输出脉冲
    input  wire pre_clk,            // PLL 输出时钟，1MHz，用于计数
    input  wire rst_n,
    
    output reg  pulse_1s,    // 1Hz 秒脉冲，宽度 = 1个sys_clk周期（20ns），sys_clk域安全
    output reg  pulse_1ms,   // 1kHZ毫秒脉冲，用于驱动按键消抖和数码管动态显示的扫描时钟
    output reg  sec_clk      // 1Hz 50%占空比时钟，用于小数点闪烁驱动
);
    // ----------------------------------------------------------------
    //  pre_clk 域：计数 + toggle flag + sec_clk 生成
    // ----------------------------------------------------------------
    localparam _1MS_CNT = 1_000;                            // 计满 1000 个pre_clk 周期（每个 1us）= 1ms
    localparam _1MS_MAX = _1MS_CNT - 1;                     // 最大计数值999
    // localparam _1S_FULL_CNT = CLK_FREQ / _1MS_CNT;          // 每1ms自增1，共计1000个数，计满1秒
    // localparam _1S_FULL_MAX = _1S_FULL_CNT - 1;             // 最大计数值999
    localparam _1S_HALF_MAX = CLK_FREQ / _1MS_CNT / 2 - 1;  // 最大计数值499，半秒翻转点

    
    reg [$clog2(_1MS_CNT)-1:0]      ms_cnt;     // 10位1毫秒（秒低位）计数器
    reg [$clog2(_1S_HALF_MAX)-1:0]  sec_cnt;    // 9位1秒（秒高位）计数器  
    reg ms_flag;        // 每毫秒 翻转 一次，用于跨时钟域传递
    reg sec_flag;       // 每秒 toggle 一次，用于跨时钟域传递
    
    always @(posedge pre_clk) begin
        if (!rst_n) begin
            sec_cnt  <= 0;
            ms_cnt   <= 0;
            ms_flag  <= 1'b0;
            sec_flag <= 1'b0;
        end 
        else begin
            if(ms_cnt == _1MS_MAX) begin
                ms_cnt <= 0;
                ms_flag <= ~ms_flag;            // 每满1毫秒toggle，传递给sys_clk域
                if(sec_cnt == _1S_HALF_MAX) begin
                    sec_cnt <= 0;
                    sec_flag <= ~sec_flag;      // 每满0.5秒toggle，传递给sys_clk域，实现 50% 占空比 1Hz 时钟信号
                end
                else begin
                    sec_cnt <= sec_cnt + 1'b1;  // 在 if(ms_cnt == _1MS_MAX) 分支下加计数，所以加到0.5秒仅需500个数
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
    //   _sync1/_sync2：两级同步，消除亚稳态
    //   _sync3：    延迟一拍，用于边沿检测    
    reg sec_flag_sync1, sec_flag_sync2, sec_flag_sync3;
    reg ms_flag_sync1,  ms_flag_sync2,  ms_flag_sync3;
    
    always @(posedge sys_clk) begin
        if (!rst_n) begin
            ms_flag_sync1  <= 1'b0;
            ms_flag_sync2  <= 1'b0;
            ms_flag_sync3  <= 1'b0;
            pulse_1ms   <= 1'b0;
            
            sec_flag_sync1 <= 1'b0;
            sec_flag_sync2 <= 1'b0;
            sec_flag_sync3 <= 1'b0;
            pulse_1s    <= 1'b0;
            sec_clk     <= 1'b1;   // 初值与原 divider 一致，为高电平
        end else begin
            ms_flag_sync1  <= ms_flag;     // 第1级同步（可能亚稳态）
            ms_flag_sync2  <= ms_flag_sync1;  // 第2即同步（稳定输出）
            ms_flag_sync3  <= ms_flag_sync2;  // 第3级，用于边沿检测     
            
            sec_flag_sync1 <= sec_flag;    // 第1级同步（可能亚稳态）
            sec_flag_sync2 <= sec_flag_sync1; // 第2级同步（稳定输出）
            sec_flag_sync3 <= sec_flag_sync2; // 第3级，用于边沿检测
            
            // XOR 边沿检测，上升沿和下降沿都触发（因为 sec_flag 是 toggle）
            // 每次跳变对应恰好过了1秒，pulse_out 高电平仅持续1个sys_clk周期(20ns)
            pulse_1ms <= ms_flag_sync2  ^ ms_flag_sync3;
            
            pulse_1s  <= sec_flag_sync2 && ~sec_flag_sync3;   // 一定是上升沿检测，这样的话就符合我对 clock 模式下小数点与秒的配合：前半秒小数点亮、后半秒灭
            
            sec_clk   <= sec_flag_sync2;
        end
    end
    
endmodule