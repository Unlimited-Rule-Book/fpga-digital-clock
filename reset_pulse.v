// =============================================================================
// 文件名：reset_pulse.v
// 功能：复位脉冲发生器（当前版本未使用，保留备用）
//
// 原设计意图：在系统复位后，产生一个固定宽度的高电平脉冲，
// 用于对下游模块（如 seg_dynamic 的刷新时钟）进行同步复位。
// 当前系统已通过 PLL locked_sig 实现全局同步复位，此模块暂时不接入信号链。
// =============================================================================
module reset_pulse
(
input   wire    sys_clk,
input   wire    reset,

output  reg     pulse = 1'b0
);


//用参数定义状态机状态
localparam  RESET_MODE = 1'b0;
localparam  NORMAL_MODE = 1'b1;
//定义脉冲发生器中间变量
reg     current_state;
reg     [2:0]   pulse_counter = 3'b0;   //复位脉冲的脉宽为160ns
reg     [15:0]  state_counter = 16'b0;  /*复位状态检测计数器，当复位信号仍为低电平时，
                                        每1ms检测一次是否还在复位状态，如果还在就再产生一次脉冲*/

//脉冲发生器（用状态机实现）
always@(posedge sys_clk or negedge reset)
begin
    if(!reset) begin
        current_state <= RESET_MODE;
        pulse_counter <= 3'b0;
        state_counter <= 16'b0;
        pulse <= 1'b1;

        case(current_state)
            RESET_MODE: begin
                if(pulse_counter < 3'd7) begin
                    pulse_counter <= pulse_counter + 1'b1;
                    pulse <= 1'b1;          //脉冲保持高电平
                    current_state <= RESET_MODE;
                end
                else begin
                    pulse_counter <= 3'b0;
                    pulse <= 1'b0;          //脉冲结束
                    current_state <= NORMAL_MODE;
                end
            end
            
            NORMAL_MODE: begin
                if(reset==1'b1) begin
                    current_state <= NORMAL_MODE;
                    pulse_counter <= 3'b0;
                    state_counter <= 16'b0;
                    pulse <= 1'b0;
                end
                else begin
                    if(state_counter < 16'd49_999) begin
                        state_counter <= state_counter + 1'b1;
                        current_state <= RESET_MODE;
                    end
                    else begin
                        state_counter <= 16'b0;
                        current_state <= NORMAL_MODE;
                        /*假设1ms后reset电平被拉高，则进入NORMAL模式，
                        如果未被拉高，则在NORMAL模式中会被检测出来，再次进入RESET模式*/
                    end
                end
            end      
        endcase
    end
    else begin
        current_state <= NORMAL_MODE;
        pulse_counter <= 3'b0;
        state_counter <= 16'b0;
        pulse <= 1'b0;
    end
end

endmodule