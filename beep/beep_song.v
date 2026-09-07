// =============================================================================
// 文件名：beep_song.v
// 功能：蜂鸣器乐曲播放模块，基于 RAM IP 核 + PWM 分频
//
// 乐谱数据：qifengle.mif — 《起风了》 your_new_home.mif-神奇数字马戏团主题曲-认清现实的小曲儿 乐谱，初始化到 my_ram IP 核
//
// RAM 数据编码（每12位，地址空间 256 字节）：
//   bit[11:8] — 八度（3=Oct3, 4=Oct4, 5=Oct5, 0=休止, F=结束标记）
//   bit[7:4]  — 音名（0=休止, 1=DO, 2=RE, 3=ME, 4=FA, 5=SO, 6=LA, 7=XI, 8=DO# RE♭, 9=RE# ME♭, A=FA# SO♭, B=SO# LA♭, C=LA# XI♭, F=结束标记）
//   bit[3:0]  — 时值（1=十六分, 2=八分, 3=附点八分, 4=四分,
//                      6=附点四分, 8=二分, F=一分）
//   注: bit[11:4] = FF 表示结束标记，结束标记的 bit[3:0] 可任意填写
//
// 工作时序：
//   1. beep_en 使能后，rd_addr 从 0 开始递增，按地址读取 rd_data
//   2. 根据 rd_data[11:4]（八度+音名）查表得到 freq_data（计数器上限）
//     和 duty_data（占空比翻转点，固定 50%）
//   3. freq_cnt 从 0 计数到 freq_data 再归零，产生对应音高的 PWM 波
//   4. cnt_dur 计数到 cnt_dur_max（由时值决定）后 rd_addr 指向下一个音符
//   5. 遇到结束标记（12'hFFF）时 rd_addr 归零，从头开始循环播放
//   6. beep_en 低电平期间指针和计数器全部归零，下次使能后从头播放
//
// 节拍参数：
//   示例：BPM = 80，这个根据音乐的情绪定，就跟节拍器一样，一拍 = 十六分音符，PAI = 16
//   四分音符 = 4 拍，二分音符 = 8 拍，依此类推
//
// 注意：
//   1. 音高参数乘 2 时务必用 `DO3 = DO4*2`（字面量 2 位宽32），
//      不可用 `2'd2`（2位宽会导致乘积截断），所以要除以2，默认为32位宽，远大于相乘结果的位宽
//   2. 音高参数除 2 时用 `DO5 = DO4/2'd2`（除法不会产生高位截断问题）
//   3. 每个音符末尾有 TIME_GAP = CNT_T1P_MAX/16 的静音间隙
//   4. DO3/DO5 的 _80/_40 分数参数目前未在 duty_data 中使用，仅 _50 有效
// =============================================================================
module beep_song
(
input   sys_clk,
input   rst_n,
input   beep_en,

output  reg beep
);

parameter   DO4 = 18'd190840, DO4_80 = 18'd152672 , DO4_50 = 17'd95420  , DO4_40 = 17'd76336  , DO4_20 = 16'd38168  , DO4_10 = 15'd19084;
parameter   RE4 = 18'd170068, RE4_80 = 18'd136054 , RE4_50 = 17'd85034  , RE4_40 = 17'd68027  , RE4_20 = 16'd34014  , RE4_10 = 15'd17007;
parameter   ME4 = 18'd151515, ME4_80 = 17'd121212 , ME4_50 = 17'd75758  , ME4_40 = 16'd60606  , ME4_20 = 15'd30303  , ME4_10 = 14'd15152;
parameter   FA4 = 18'd143266, FA4_80 = 17'd114613 , FA4_50 = 17'd71633  , FA4_40 = 16'd57306  , FA4_20 = 15'd28653  , FA4_10 = 14'd14327;
parameter   SO4 = 17'd127551, SO4_80 = 17'd102041 , SO4_50 = 16'd63776  , SO4_40 = 16'd51020  , SO4_20 = 15'd25510  , SO4_10 = 14'd12755;
parameter   LA4 = 17'd113636, LA4_80 =  17'd90909 , LA4_50 = 16'd56818  , LA4_40 = 16'd45454  , LA4_20 = 15'd22727  , LA4_10 = 14'd11364;
parameter   XI4 = 17'd101214, XI4_80 =  17'd80971 , XI4_50 = 16'd50607  , XI4_40 = 16'd40486  , XI4_20 = 15'd20243  , XI4_10 = 14'd10121;
parameter   DO4_HALF = 18'd180388,                    DO4_HALF_50 = 17'd90194;
parameter   RE4_HALF = 18'd160705,                    RE4_HALF_50 = 17'd80352;
parameter   FA4_HALF = 18'd135139,                    FA4_HALF_50 = 17'd67569;
parameter   SO4_HALF = 17'd120395,                    SO4_HALF_50 = 16'd60197;
parameter   LA4_HALF = 17'd107259,                    LA4_HALF_50 = 16'd53630;

// 注意：这里必须用2不可用2'd2，因为在不同位宽的运算中，结果会取参与运算的数字中较大的那个，乘2后的结果DO3比乘数DO4宽，但是仍采用了DO4的位宽，
// 导致高位被截断。而2的默认位宽是32，使得DO3位宽为32，就不会出现截断。
parameter   DO3 = DO4*2     , DO3_80 = DO4_80*2   , DO3_50 = DO4_50*2   , DO3_40 = DO4_40*2   , DO3_20 = DO4_20*2   , DO3_10 = DO4_10*2   ;
parameter   RE3 = RE4*2     , RE3_80 = RE4_80*2   , RE3_50 = RE4_50*2   , RE3_40 = RE4_40*2   , RE3_20 = RE4_20*2   , RE3_10 = RE4_10*2   ;
parameter   ME3 = ME4*2     , ME3_80 = ME4_80*2   , ME3_50 = ME4_50*2   , ME3_40 = ME4_40*2   , ME3_20 = ME4_20*2   , ME3_10 = ME4_10*2   ;
parameter   FA3 = FA4*2     , FA3_80 = FA4_80*2   , FA3_50 = FA4_50*2   , FA3_40 = FA4_40*2   , FA3_20 = FA4_20*2   , FA3_10 = FA4_10*2   ;
parameter   SO3 = SO4*2     , SO3_80 = SO4_80*2   , SO3_50 = SO4_50*2   , SO3_40 = SO4_40*2   , SO3_20 = SO4_20*2   , SO3_10 = SO4_10*2   ;
parameter   LA3 = LA4*2     , LA3_80 = LA4_80*2   , LA3_50 = LA4_50*2   , LA3_40 = LA4_40*2   , LA3_20 = LA4_20*2   , LA3_10 = LA4_10*2   ;
parameter   XI3 = XI4*2     , XI3_80 = XI4_80*2   , XI3_50 = XI4_50*2   , XI3_40 = XI4_40*2   , XI3_20 = XI4_20*2   , XI3_10 = XI4_10*2   ;
parameter   DO3_HALF = DO4_HALF*2,                  DO3_HALF_50 = DO4_HALF_50*2;
parameter   RE3_HALF = RE4_HALF*2,                  RE3_HALF_50 = RE4_HALF_50*2;
parameter   FA3_HALF = FA4_HALF*2,                  FA3_HALF_50 = FA4_HALF_50*2;
parameter   SO3_HALF = SO4_HALF*2,                  SO3_HALF_50 = SO4_HALF_50*2;
parameter   LA3_HALF = LA4_HALF*2,                  LA3_HALF_50 = LA4_HALF_50*2;
    
parameter   DO5 = DO4/2'd2  , DO5_80 = DO4_80/2'd2, DO5_50 = DO4_50/2'd2, DO5_40 = DO4_40/2'd2, DO5_20 = DO4_20/2'd2, DO5_10 = DO4_10/2'd2;
parameter   RE5 = RE4/2'd2  , RE5_80 = RE4_80/2'd2, RE5_50 = RE4_50/2'd2, RE5_40 = RE4_40/2'd2, RE5_20 = RE4_20/2'd2, RE5_10 = RE4_10/2'd2;
parameter   ME5 = ME4/2'd2  , ME5_80 = ME4_80/2'd2, ME5_50 = ME4_50/2'd2, ME5_40 = ME4_40/2'd2, ME5_20 = ME4_20/2'd2, ME5_10 = ME4_10/2'd2;
parameter   FA5 = FA4/2'd2  , FA5_80 = FA4_80/2'd2, FA5_50 = FA4_50/2'd2, FA5_40 = FA4_40/2'd2, FA5_20 = FA4_20/2'd2, FA5_10 = FA4_10/2'd2;
parameter   SO5 = SO4/2'd2  , SO5_80 = SO4_80/2'd2, SO5_50 = SO4_50/2'd2, SO5_40 = SO4_40/2'd2, SO5_20 = SO4_20/2'd2, SO5_10 = SO4_10/2'd2;
parameter   LA5 = LA4/2'd2  , LA5_80 = LA4_80/2'd2, LA5_50 = LA4_50/2'd2, LA5_40 = LA4_40/2'd2, LA5_20 = LA4_20/2'd2, LA5_10 = LA4_10/2'd2;
parameter   XI5 = XI4/2'd2  , XI5_80 = XI4_80/2'd2, XI5_50 = XI4_50/2'd2, XI5_40 = XI4_40/2'd2, XI5_20 = XI4_20/2'd2, XI5_10 = XI4_10/2'd2;
parameter   DO5_HALF = DO4_HALF/2'd2,               DO5_HALF_50 = DO4_HALF_50/2'd2;
parameter   RE5_HALF = RE4_HALF/2'd2,               RE5_HALF_50 = RE4_HALF_50/2'd2;
parameter   FA5_HALF = FA4_HALF/2'd2,               FA5_HALF_50 = FA4_HALF_50/2'd2;
parameter   SO5_HALF = SO4_HALF/2'd2,               SO5_HALF_50 = SO4_HALF_50/2'd2;
parameter   LA5_HALF = LA4_HALF/2'd2,               LA5_HALF_50 = LA4_HALF_50/2'd2;

parameter   EMPTY = 0;
// RAM 相关

reg [7:0]   rd_addr; // RAM指针，RAM深度暂定为256
wire [11:0]  rd_data; // 从 RAM 里找出来的值

// 编码规则: {octave[3:0], note[3:0], duration[3:0]}
//bit[11:8] — 八度     (4'd3=Oct3, 4'd4=Oct4, 4'd5=Oct5, 4'd0=休止, 4'd15=结束标记)
//bit[7:4]  — 音名     (4'd1=DO, 4'd2=RE, 4'd3=ME, 4'd4=FA, 4'd5=SO, 4'd6=LA, 4'd7=XI, 4'd0=休止, 4'd15=结束标记)
//bit[3:0]   — 时值     (以「一拍」为单位, 1=十六分, 2=八分, 3=附点八分, 4=四分, 6=附点四分, 8=二分, F=一分, 注意休止也可以有时长，但是结束标记没有，因为遇到结束标记，RAM指针就归零)
// Oct4 = 4'd4, 音名: DO=1~XI=7, 时值: 四分=4, 二分=8
    
// 拍子计时
// 每一拍的时长
parameter   CLK = 50_000_000;
parameter   BPM = 7'd90;    // BPM 是以4分音符为1拍。起风了 qifengle.mif 设置成80。认清现实的小曲儿 your_new_home.mif 设置成90
parameter   PAI = 5'd16;    // 16分音符为1拍，所以下面的 BPM 要乘 PAI/3'd4 = 4
parameter   CNT_T1P_MAX = CLK * 6'd60 / (BPM * PAI/3'd4 ); // 1拍的计数

wire    [$clog2(CNT_T1P_MAX*16)-1:0]  cnt_dur_max;   // 最多拍数的时长的计数上限，十六分音符为1拍，设最长2份音符是8拍
reg     [$clog2(CNT_T1P_MAX*16)-1:0]  cnt_dur;       // 该音符的时长，即n拍的时长;

// 十六分音符1拍
// 八分音符2拍
// 附点八分3拍
// 四分音符4拍
// 附点四分6拍
// 二分音符8拍
// 一分音符16拍，RAM编码为F即15，所以得处理一下
// 该音符时长最大值
assign  cnt_dur_max = rd_data[3:0]==4'hF ? CNT_T1P_MAX*5'd16 : CNT_T1P_MAX*rd_data[3:0];

// 该音符的时长
always@(posedge sys_clk)
begin
    if(~rst_n)
        cnt_dur <= 0;
    else if((cnt_dur==cnt_dur_max || rd_data[11:4]==8'hFF) && beep_en)
        cnt_dur <= 0;
    else if(beep_en)
        cnt_dur <= cnt_dur + 1'b1;
        // 如果不加下面的这条语句，那么效果是 beep_en 中途不使能，然后再使能时，会接着上次播放
    else if(!beep_en)
        cnt_dur <= 0;
end


// 指针移动
always@(posedge sys_clk)
begin   // 暂定为 beep_en 使能不断就一直播放
    if(~rst_n)
        rd_addr <= 0;
    else if(rd_data[11:4]==8'hFF && beep_en)    // 遇到结束标记，将指针归零
        rd_addr <= 0;
    else if(cnt_dur==cnt_dur_max && beep_en)
        rd_addr <= rd_addr+1'b1;
        // 如果不加下面的这条语句，那么效果是 beep_en 中途不使能，然后再使能时，会接着上次播放
    else if(!beep_en)
        rd_addr <= 0;
end
// 内容读取
// 应该在实例化RAM-IP核时，RAM的输出之一就是内容
// 上面的指针是RAM的输入
my_ram beep_song_my_ram
(
	.address(rd_addr),
	.clock  (sys_clk),
	.data   (12'd0  ), // 写数据端口，不使用，但要接
	.wren   (1'b0   ), // 只读不写

	.q      (rd_data)
);
// my_ram 中 init_file ，就是保存乐谱的 .mif 文件的位置
// 如果填写相对路径的话，相对路径不是相对 my_ram.v 的路径，而是相对主工程 .qpf 文件而言的




// 音符PWM
// 该音符频率多少？

reg [31:0]  freq_data;  // 不管了，干脆设为最大位宽吧
reg [31:0]  duty_data;  // 占空比50%的占空比计数值，在计到这个数之前，PWM为高电平

always@(posedge sys_clk)
begin
    if(~rst_n)begin
        freq_data <= DO4;
        duty_data <= DO4_50;
    end
    else begin
        case(rd_data[11:4])                                    
        8'h31 : begin    freq_data <= DO3;      duty_data <= DO3_50; end
        8'h32 : begin    freq_data <= RE3;      duty_data <= RE3_50; end
        8'h33 : begin    freq_data <= ME3;      duty_data <= ME3_50; end
        8'h34 : begin    freq_data <= FA3;      duty_data <= FA3_50; end
        8'h35 : begin    freq_data <= SO3;      duty_data <= SO3_50; end
        8'h36 : begin    freq_data <= LA3;      duty_data <= LA3_50; end
        8'h37 : begin    freq_data <= XI3;      duty_data <= XI3_50; end
        8'h38 : begin    freq_data <= DO3_HALF; duty_data <= DO3_HALF_50; end
        8'h39 : begin    freq_data <= RE3_HALF; duty_data <= RE3_HALF_50; end
        8'h3A : begin    freq_data <= FA3_HALF; duty_data <= FA3_HALF_50; end
        8'h3B : begin    freq_data <= SO3_HALF; duty_data <= SO3_HALF_50; end
        8'h3C : begin    freq_data <= LA3_HALF; duty_data <= LA3_HALF_50; end
                                                               
        8'h41 : begin    freq_data <= DO4;      duty_data <= DO4_50; end
        8'h42 : begin    freq_data <= RE4;      duty_data <= RE4_50; end
        8'h43 : begin    freq_data <= ME4;      duty_data <= ME4_50; end
        8'h44 : begin    freq_data <= FA4;      duty_data <= FA4_50; end
        8'h45 : begin    freq_data <= SO4;      duty_data <= SO4_50; end
        8'h46 : begin    freq_data <= LA4;      duty_data <= LA4_50; end
        8'h47 : begin    freq_data <= XI4;      duty_data <= XI4_50; end
        8'h48 : begin    freq_data <= DO4_HALF; duty_data <= DO4_HALF_50; end
        8'h49 : begin    freq_data <= RE4_HALF; duty_data <= RE4_HALF_50; end
        8'h4A : begin    freq_data <= FA4_HALF; duty_data <= FA4_HALF_50; end
        8'h4B : begin    freq_data <= SO4_HALF; duty_data <= SO4_HALF_50; end
        8'h4C : begin    freq_data <= LA4_HALF; duty_data <= LA4_HALF_50; end
                                                               
        8'h51 : begin    freq_data <= DO5;      duty_data <= DO5_50; end
        8'h52 : begin    freq_data <= RE5;      duty_data <= RE5_50; end
        8'h53 : begin    freq_data <= ME5;      duty_data <= ME5_50; end
        8'h54 : begin    freq_data <= FA5;      duty_data <= FA5_50; end
        8'h55 : begin    freq_data <= SO5;      duty_data <= SO5_50; end
        8'h56 : begin    freq_data <= LA5;      duty_data <= LA5_50; end
        8'h57 : begin    freq_data <= XI5;      duty_data <= XI5_50; end
        8'h58 : begin    freq_data <= DO5_HALF; duty_data <= DO5_HALF_50; end
        8'h59 : begin    freq_data <= RE5_HALF; duty_data <= RE5_HALF_50; end
        8'h5A : begin    freq_data <= FA5_HALF; duty_data <= FA5_HALF_50; end
        8'h5B : begin    freq_data <= SO5_HALF; duty_data <= SO5_HALF_50; end
        8'h5C : begin    freq_data <= LA5_HALF; duty_data <= LA5_HALF_50; end
        
        8'h00 : begin    freq_data <= EMPTY;  duty_data <= EMPTY;  end  // 休止符
        8'hFF : begin    freq_data <= EMPTY;  duty_data <= EMPTY;  end  // 结束标记。看似没啥用，因为遇到结束标记，RAM指针rd_data就归零，但是假如遇到了，得能有对应的值可查
        
        default:begin    freq_data <= DO4;    duty_data <= DO4_50; end
        endcase
    end
end
// 决定PWM频率的计数器与PWM的值

reg [32:0]  freq_cnt;

parameter   TIME_GAP = CNT_T1P_MAX / 5'd16; // 每一个音符之间留一些空
always@(posedge sys_clk)
begin
    if(~rst_n)
        freq_cnt <= 0;
    else if(freq_cnt==freq_data || cnt_dur>=(cnt_dur_max - TIME_GAP)) // 如果freq_cnt未计到最大值，但是该音符发声时间已到，也进行清零
        freq_cnt <= 0;
    else if(beep_en)
        freq_cnt <= freq_cnt + 1'b1;
        // 如果不加下面的这条语句，那么效果是 beep_en 中途不使能，然后再使能时，会接着上次播放
    else if(!beep_en)
        freq_cnt <= 0;
end
always@(posedge sys_clk)
begin
    if(~rst_n)
        beep <= 1'b0;
    else if(freq_cnt > 0 && freq_cnt < duty_data && beep_en)
        beep <= 1'b1;
    else if(freq_cnt>=duty_data && freq_cnt<=freq_data && beep_en)
        beep <= 1'b0;   // 在计到duty_data之前，beep为高电平
    else if(freq_cnt==0)
        beep <= 1'b0;
end

endmodule