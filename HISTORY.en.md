# Development History

[简体中文](HISTORY.md) · **English**

> I only learned Git in March 2026 and made my first commit on April 4, so everything before that was never tracked by Git. This page records the main events of my development. 

## Timeline

- Summer break 2024: I started learning Verilog following EmbedFire's tutorials. Just before the new semester, I wrote the "first version" of my digital clock, with all the code crammed into a single file. I neither finished it nor tested it on my development board. 
- Winter break 2025 (Jan-Feb): I scrapped my earlier design and started over. Starting from drawing block diagrams, I adopted a modular design approach. I wrote a generic BCD up/down counter `counter.v`, and then `clock.v`, which solved the hour's units digit variable-radix problem for plain timekeeping, without time setting. 
- Spring semester 2025: I took _Fundamentals of Digital Electronics_, which touched on Verilog a little, and made some changes to the code. 
- Summer break 2025: 
  - From late June to early July, I wrote testbenches for the modules of the `clock` era and simulated them. The timekeeping function was basically finished. 
  - In late July, I started working on the time-setting function and the project entered the `clock_mode` era. By the end of the break, I had roughly built the top-level module `clock_mode.v` and left an interface for the alarm feature, to be added later. 
- Fall semester 2025 to winter break 2026 (Jan-Feb): 
  - When I tested on the development board, pressing the `load` button did nothing. I tried simulating, but couldn't find the root cause. I once lost interest in the project. 
  - During the semester, my coursework was heavy, so I mostly worked on the project during breaks. But during the winter break of 2026, I was busy preparing for and taking part in a competition, so I had no time to move the project forward. 
  - Together, these two reasons brought the project almost to a halt. Fortunately, I came across Git in that break. 
- Spring semester 2026: 
  - On April 4, I committed my project to Git for the first time. 
  - By chance, I learned what a PLL can do and tried to add it to my project. Then I started taking _Digital System Design Based on Verilog_, an out-of-major course. These together brought my confidence back. After simulating the module that handles button debouncing and long/short-press detection (`button_stabilization_long_short.v`) separately, I eventually found the problem and `load_num.v` passed on-board verification. 
  - Then in only about three days, I reworked `load_num.v` into `alarm.v` and solved the hour's units digit variable-radix problem with time setting involved, which laid the groundwork for solving the similar problems in `clock.v` and `load_num.v`. 
- Fall semester 2026: I prepared to open-source the project: fixing bugs, completing the comments and writing the README and HISTORY files in both Chinese and English. 

## Development experience and lessons


屎山代码：spaghetti code（或口语的 a big ball of mud）。
一个巨大的 if-else：one giant if-else chain。
带自校验的 testbench：self-checking testbench。
按键没反应：the buttons did nothing on the board。
板上验证：on-board bring-up / on-board verification。
阶段性检测：a checkpoint of my self-study。
可读性、维护性差：hard to read and maintain
门控-控制模式切换：AND-OR gating - switch modes
按键资源紧张、复用 `load` 键：I was short of buttons, so I reused `load` for several functions
这都怪我没有验证习惯：That was my own fault: I had never built the habit of verifying my work
数码管开始频闪：the 7-segment display began to flicker
「if-else」的锅：the culprit was still the giant if-else chain（`culprit` 比 `blame` 自然）
节省了 43% 的 FF：reduced flip-flop (FF) usage by 43%
变进制问题：variable-radix problem
