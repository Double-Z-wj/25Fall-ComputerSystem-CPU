`include "lib/defines.vh"

//P'64之前注意跳转

// 从内存中取指令
// 使用PC中的地址，从存储器中读取数据，然后将数据放入IF/ID流水线寄存器中。
// PC地址+4然后写回PC以便为下个时钟周期做好准备，
// 增加后的地址同时也存入了IF/ID流水线寄存器以备后面的指令使用。

module IF(
    input wire clk,                     // 时钟信号
    input wire rst,                     // 复位信号
    input wire [`StallBus-1:0] stall,   // 流水线暂停信号，用于解决冲突

    // input wire flush,
    // input wire [31:0] new_pc,

    // 分支跳转总线，来自 ID 阶段。包含是否跳转(br_e)和跳转地址(br_addr)
    input wire [`BR_WD-1:0] br_bus,

    // 输出到 ID 阶段的总线，包含当前 PC 值
    output wire [`IF_TO_ID_WD-1:0] if_to_id_bus,

    // 指令存储器 (SRAM) 接口
    output wire inst_sram_en,           // 读使能信号 (Chip Enable)
    output wire [3:0] inst_sram_wen,    // 写使能信号 (Write Enable)，取指阶段通常为0
    output wire [31:0] inst_sram_addr,  // 读地址
    output wire [31:0] inst_sram_wdata  // 写数据，取指阶段为0
);
    reg [31:0] pc_reg;  // PC 寄存器，存储当前指令地址
    reg ce_reg;         // 片选寄存器 (Chip Enable)，指示当前 PC 是否有效
    wire [31:0] next_pc;// 下一跳 PC 的值
    wire br_e;          // 分支使能 (Branch Enable)，1 表示需要跳转
    wire [31:0] br_addr;// 跳转的目标地址

    // 将输入的 br_bus 拆解为使能信号和地址
    // 这里的顺序取决于 ID 阶段打包时的顺序，通常是 {使能, 地址}
    assign {
        br_e,
        br_addr
    } = br_bus;

    // PC 寄存器更新逻辑
    always @ (posedge clk) begin
        if (rst) begin
            pc_reg <= 32'hbfbf_fffc;    // 复位时 PC 初始化为预定义地址
        end
        else if (stall[0]==`NoStop) begin
            pc_reg <= next_pc;          // 正常情况下更新 PC 为下一个地址
        end
    end

    // 片选寄存器更新逻辑
    always @ (posedge clk) begin
        if (rst) begin
            ce_reg <= 1'b0;
        end
        else if (stall[0]==`NoStop) begin
            ce_reg <= 1'b1;
        end
    end

    assign next_pc = br_e ? br_addr // 如果分支使能，则跳转到目标地址
                   : pc_reg + 32'h4;// 默认情况下 PC 加 4

    
    // SRAM 接口赋值
    assign inst_sram_en = ce_reg;      // 只有 ce_reg 为 1 时才读内存
    assign inst_sram_wen = 4'b0;       // 取指阶段不写内存，写使能全0
    assign inst_sram_addr = pc_reg;    // 地址就是当前 PC
    assign inst_sram_wdata = 32'b0;    // 写数据为 0

    // 打包数据发送给 ID 阶段
    assign if_to_id_bus = {
        ce_reg,  // 将指令有效位传下去
        pc_reg   // 将当前指令的地址(PC)传下去，用于计算后续跳转或异常
    };

endmodule