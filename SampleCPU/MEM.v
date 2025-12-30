`include "lib/defines.vh"

/*
    - 接收并处理访存的结果，并选择写回结果
    - 对于需要访存的指令在此段接收访存结果
*/

// 访问内存操作
// 可能从EX/MEM流水线寄存器中得到地址读取数据寄存器，并将数据存入MEM/WB流水线寄存器。

module MEM(
    input wire clk,
    input wire rst,
    // input wire flush,
    input wire [`StallBus-1:0] stall,

    input wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus,

    input wire [31:0] data_sram_rdata, // 来自数据存储器的数据
    input wire [3:0] data_ram_sel, // 数据存储器的字节选择信号
    input wire [`LoadBus-1:0] ex_load_bus, // 访存指令类型

    output wire stallreq_for_load,

    output wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus,
    output wire [`MEM_TO_RF_WD-1:0] mem_to_rf_bus
);
    reg [`LoadBus-1:0] ex_load_bus_r;
    reg [3:0] data_ram_sel_r;

    reg [`EX_TO_MEM_WD-1:0] ex_to_mem_bus_r;

    always @ (posedge clk) begin
        if (rst) begin
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
            data_ram_sel_r <= 3'b0;            
            ex_load_bus_r <= `LoadBus'b0;

        end
        // else if (flush) begin
        //     ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        // end
        else if (stall[3]==`Stop && stall[4]==`NoStop) begin // MEM 暂停但 WB 继续 -> 插入气泡 (Flush)
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
            data_ram_sel_r <= 3'b0;            
            ex_load_bus_r <= `LoadBus'b0;
        end
        else if (stall[3]==`NoStop) begin // 正常传递
            ex_to_mem_bus_r <= ex_to_mem_bus;
            data_ram_sel_r <= data_ram_sel;            
            ex_load_bus_r <= ex_load_bus;
        end
    end

    wire [31:0] mem_pc;
    wire data_ram_en;
    wire [3:0] data_ram_wen;
    wire sel_rf_res;
    wire rf_we;
    wire [4:0] rf_waddr;
    wire [31:0] rf_wdata;
    wire [31:0] ex_result;
    wire [31:0] mem_result;

    wire inst_lb, inst_lbu, inst_lh, inst_lhu, inst_lw;

    wire [7:0] b_data;
    wire [15:0] h_data;
    wire [31:0] w_data;


    assign {
        mem_pc,         // 75:44 PC
        data_ram_en,    // 43
        data_ram_wen,   // 42:39
        sel_rf_res,     // 38 结果选择信号
        rf_we,          // 37 写寄存器使能
        rf_waddr,       // 36:32 写寄存器地址
        ex_result       // 31:0 EX 计算结果
    } =  ex_to_mem_bus_r;

    assign {
        inst_lb,//4
        inst_lbu,//3
        inst_lh,//2
        inst_lhu,//1
        inst_lw//0
    } = ex_load_bus_r;



    assign b_data = data_ram_sel_r[3] ? data_sram_rdata[31:24] : // 字节提取
                    data_ram_sel_r[2] ? data_sram_rdata[23:16] :
                    data_ram_sel_r[1] ? data_sram_rdata[15: 8] : 
                    data_ram_sel_r[0] ? data_sram_rdata[ 7: 0] : 8'b0;
    assign h_data = data_ram_sel_r[2] ? data_sram_rdata[31:16] : // 半字提取
                    data_ram_sel_r[0] ? data_sram_rdata[15: 0] : 16'b0;
    assign w_data = data_sram_rdata; // 字提取

    // 符号拓展
    assign mem_result = inst_lb     ? {{24{b_data[7]}},b_data} :
                        inst_lbu    ? {{24{1'b0}},b_data} :
                        inst_lh     ? {{16{h_data[15]}},h_data} :
                        inst_lhu    ? {{16{1'b0}},h_data} :
                        inst_lw     ? w_data : 32'b0;

    // sel_rf_res 在 ID 阶段生成：如果是 Load 类指令为 1，否则为 0
    assign rf_wdata = sel_rf_res ? mem_result : ex_result;

    // 发送给 WB 阶段，准备写入寄存器堆
    assign mem_to_wb_bus = {
        mem_pc,     // 69:38
        rf_we,      // 37
        rf_waddr,   // 36:32
        rf_wdata    // 31:0
    };

    // 数据前推 (Forwarding)
    // 直接把本级的结果 (rf_wdata) 发回 ID 阶段
    assign mem_to_rf_bus = {
        // mem_pc,     // 69:38
        rf_we,      // 37
        rf_waddr,   // 36:32
        rf_wdata    // 31:0
    };


endmodule