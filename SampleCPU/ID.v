`include "lib/defines.vh"

/*  
    - 需要在该级进行指令译码
    - 从寄存器中读取需要的数据
    - 完成数据相关处理
    - 生成发给EX段的控制信号
*/

// 指令解码，同时读取寄存器
// IF/ID阶段可能会取出经符号扩展为32位的立即数和两个从寄存器中读取的数，放入ID/EX流水线寄存器

module ID(
    input wire clk,//时钟
    input wire rst,//复位
    // input wire flush,
    input wire [`StallBus-1:0] stall,//暂停

    input wire [`IF_TO_ID_WD-1:0] if_to_id_bus,//来自IF阶段的信息总线

    input wire [31:0] inst_sram_rdata,//从指令SRAM读取的指令数据

    input wire ex_id,//来自EX阶段的暂停请求

    // forwording回传内容
    input wire [`WB_TO_RF_WD-1:0] wb_to_rf_bus,

    input wire [`EX_TO_RF_WD-1:0] ex_to_rf_bus,

    input wire [`MEM_TO_RF_WD-1:0] mem_to_rf_bus,

    input wire [65:0] ex_hi_lo_bus,
    
    output wire stallreq,// 暂停请求

    output wire [71:0] id_hi_lo_bus,// 输出到EX阶段的HI_LO信息总线
    
    // 访存相关
    output wire [`LoadBus-1:0] id_load_bus,
    output wire [`SaveBus-1:0] id_save_bus,

    output wire stallreq_for_bru,// 来自分支跳转单元的暂停请求

    output wire [`ID_TO_EX_WD-1:0] id_to_ex_bus,// 输出到EX阶段的信息总线

    output wire [`BR_WD-1:0] br_bus // 输出到分支跳转单元的信息总线
);

    // 数据总线相关
    reg [`IF_TO_ID_WD-1:0] if_to_id_bus_r; // IF到ID阶段的信息总线寄存器
    wire [31:0] inst; // 当前指令
    wire [31:0] id_pc;// 当前指令的PC
    wire ce; // 指令使能信号
    reg flag; // 缓存标志位
    reg [31:0] buf_inst; // 缓存指令

    // forwording回传内容拆解相关
    wire wb_rf_we;
    wire [4:0] wb_rf_waddr; 
    wire [31:0] wb_rf_wdata;

    wire ex_rf_we;
    wire [4:0] ex_rf_waddr;
    wire [31:0] ex_rf_wdata;
    
    wire mem_rf_we;
    wire [4:0] mem_rf_waddr;
    wire [31:0] mem_rf_wdata;

    always @ (posedge clk) begin
        if (rst) begin // 复位
            if_to_id_bus_r <= `IF_TO_ID_WD'b0; 
            flag <= 1'b0;    
            buf_inst <= 32'b0;
        end
        // else if (flush) begin
        //     ic_to_id_bus <= `IC_TO_ID_WD'b0;
        // end
        else if (stall[1]==`Stop && stall[2]==`NoStop) begin // ID阶段暂停，EX阶段运行
            if_to_id_bus_r <= `IF_TO_ID_WD'b0; // 插入气泡
            flag <= 1'b0; // 清除缓存标志
        end
        else if (stall[1]==`NoStop) begin // 正常流动
            if_to_id_bus_r <= if_to_id_bus;
            flag <= 1'b0;
        end
        else if (stall[1]==`Stop && stall[2]==`Stop && ~flag) begin
            flag <= 1'b1; // 设置缓存标志
            buf_inst <= inst_sram_rdata; // 缓存当前指令
        end  
    end
    
    // 指令选择逻辑
    assign inst = ce ? 
        flag ? buf_inst : // 使用缓存的指令
        inst_sram_rdata : // 使用当前读取的指令
    32'b0;    // 如果指令使能无效，输出空指令

    // forwording回传内容拆解
    assign {
        ex_rf_we,    // 使能
        ex_rf_waddr, // 地址
        ex_rf_wdata  // 数据
    } = ex_to_rf_bus;
    assign {
        mem_rf_we,
        mem_rf_waddr,
        mem_rf_wdata
    } = mem_to_rf_bus;
    assign {
        ce,
        id_pc
    } = if_to_id_bus_r;
    assign {
        wb_rf_we,
        wb_rf_waddr,
        wb_rf_wdata
    } = wb_to_rf_bus;



    wire [5:0] opcode;
    wire [4:0] rs,rt,rd,sa;
    wire [5:0] func;
    wire [15:0] imm;
    wire [25:0] instr_index;
    wire [19:0] code;
    wire [4:0] base;//基址
    wire [15:0] offset;//偏移
    wire [2:0] sel;//选择信号

    wire [63:0] op_d, func_d;
    wire [31:0] rs_d, rt_d, rd_d, sa_d;

    wire [2:0] sel_alu_src1;
    wire [3:0] sel_alu_src2;
    wire [11:0] alu_op;

    wire data_ram_en;
    wire [3:0] data_ram_wen;
    
    wire rf_we;
    wire [4:0] rf_waddr;
    wire sel_rf_res;
    wire [2:0] sel_rf_dst;

    wire [31:0] rdata1, rdata2;
    wire [31:0] ndata1, ndata2;

//  数据相关

    // 流水线相关，ex，mem，wb阶段的寄存器堆写使能，写地址，写数据
    assign ndata1 = ((ex_rf_we && rs == ex_rf_waddr) ? ex_rf_wdata : 32'b0) | // 优先EX阶段 源寄存器1的地址等于EX阶段要写的地址，并且EX阶段写使能有效，直接用EX阶段的数据
                   ((!(ex_rf_we && rs == ex_rf_waddr) && (mem_rf_we && rs == mem_rf_waddr)) ? mem_rf_wdata : 32'b0) | // MEM阶段
                   ((!(ex_rf_we && rs == ex_rf_waddr) && !(mem_rf_we && rs == mem_rf_waddr) && (wb_rf_we && rs == wb_rf_waddr)) ? wb_rf_wdata : 32'b0) | // WB阶段
                   (((ex_rf_we && rs == ex_rf_waddr) || (mem_rf_we && rs == mem_rf_waddr) || (wb_rf_we && rs == wb_rf_waddr)) ? 32'b0 : rdata1); // 读取默认寄存器堆数据

    assign ndata2 = ((ex_rf_we && rt == ex_rf_waddr) ? ex_rf_wdata : 32'b0) | //源寄存器2地址等于EX阶段要写的地址，并且EX阶段写使能有效，直接用EX阶段的数据
                   ((!(ex_rf_we && rt == ex_rf_waddr) && (mem_rf_we && rt == mem_rf_waddr)) ? mem_rf_wdata : 32'b0) |
                   ((!(ex_rf_we && rt == ex_rf_waddr) && !(mem_rf_we && rt == mem_rf_waddr) && (wb_rf_we && rt == wb_rf_waddr)) ? wb_rf_wdata : 32'b0) |
                   (((ex_rf_we && rt == ex_rf_waddr) || (mem_rf_we && rt == mem_rf_waddr) || (wb_rf_we && rt == wb_rf_waddr)) ? 32'b0 : rdata2);

    // 寄存器堆实例化，读写r0-r31
    regfile u_regfile(
    	.clk    (clk    ),
        .raddr1 (rs ),
        .rdata1 (rdata1 ),
        .raddr2 (rt ),
        .rdata2 (rdata2 ),
        .we     (wb_rf_we     ),
        .waddr  (wb_rf_waddr  ),
        .wdata  (wb_rf_wdata  )
    );

    
    wire [31:0] hi, hi_rdata;
    wire [31:0] lo, lo_rdata;
    wire hi_we;
    wire lo_we;
    wire [31:0] hi_wdata;
    wire [31:0] lo_wdata;

    assign {
        hi_we,
        lo_we,
        hi_wdata,
        lo_wdata
    } = ex_hi_lo_bus;
    
    // HI_LO寄存器相关实例化
    hi_lo_reg u_hi_lo_reg(
        .clk      (clk        ),
        .hi_we    (hi_we      ), // 高位写使能
        .lo_we    (lo_we      ), // 低位写使能
        .hi_wdata (hi_wdata   ), // 高位写数据
        .lo_wdata (lo_wdata   ), // 低位写数据
        .hi_rdata (hi_rdata   ), // 高位读数据
        .lo_rdata (lo_rdata   )  // 低位读数据
    );

    assign hi = hi_we ? hi_wdata : hi_rdata;
    assign lo = lo_we ? lo_wdata : lo_rdata;

    assign opcode = inst[31:26];
    assign rs = inst[25:21];
    assign rt = inst[20:16];
    assign rd = inst[15:11];
    assign sa = inst[10:6];
    assign func = inst[5:0];
    assign imm = inst[15:0];
    assign instr_index = inst[25:0];
    assign code = inst[25:6];
    assign base = inst[25:21];
    assign offset = inst[15:0];
    assign sel = inst[2:0];

    /*
        定义指令信号
    */

    // 算术运算指令
    wire inst_addu; // 将寄存器 rs 的值与寄存器 rt 的值相加，结果写入 rd 寄存器中。
    wire inst_addiu;// 将寄存器 rs 的值与有符号扩展 至 32 位的立即数 imm 相加，结果写入 rt 寄存器中。
    wire inst_add;  // 将寄存器 rs 的值与寄存器 rt 的值相加，结果写入寄存器 rd 中。
                    // 如果产生溢出，则触发整型溢出例外（IntegerOverflow）。
    wire inst_addi; // 将寄存器 rs 的值与有符号扩展至 32 位的立即数 imm 相加，结果写入 rt 寄存器中。
                    // 如果产生溢出，则触发整型溢出例外（IntegerOverflow）。


    wire inst_sub;  //将寄存器 rs 的值与寄存器 rt 的值相减，结果写入 rd 寄存器中。
                    // 如果产生溢出，则触发整型溢出例外（IntegerOverflow）。
    wire inst_subu; // 将寄存器 rs 的值与寄存器 rt 的值相减，结果写入 rd 寄存器中。


    wire inst_slt;  //将寄存器 rs 的值与寄存器 rt 中的值进行有符号数比较，
                    // 如果寄存器 rs 中的值小，则寄存器 rd 置 1；否则寄存器 rd 置 0。
    wire inst_slti; //将寄存器 rs 的值与有符号扩展至 32 位的立即数 imm 进行有符号数比较，
                    // 如果寄存器 rs 中的值小，则寄存器 rt 置 1；否则寄存器 rt 置 0。
    wire inst_sltu; // 将寄存器 rs 的值与寄存器 rt 中的值进行无符号数比较，
                     // 如果寄存器 rs 中的值小，则寄存器 rd 置 1；否则寄存器 rd 置 0。
    wire inst_sltiu;// 将寄存器 rs 的值与有符号扩展至 32 位的立即数 imm 进行无符号数比较，
                    // 如果寄存器 rs 中的值小，则寄存器 rt 置 1；否则寄存器 rt 置 0。

    wire inst_mult;  // 有符号乘法，寄存器 rs 的值乘以寄存器 rt 的值，乘积的低半部分和高半部分分别写入 LO 寄存器和 HI 寄存器。
    wire inst_multu; // 无符号乘法，寄存器 rs 的值乘以寄存器 rt 的值，乘积的低半部分和高半部分分别写入 LO 寄存器和 HI 寄存器。
    wire inst_div;   // 有符号除法，寄存器 rs 的值除以寄存器 rt 的值，商写入 LO 寄存器中，余数写入 HI 寄存器中。
    wire inst_divu;  // 无符号除法，寄存器 rs 的值除以寄存器 rt 的值，商写入 LO 寄存器中，余数写入 HI 寄存器中。

// 逻辑运算指令
    wire inst_ori;  // 寄存器 rs 中的值与 0 扩展至 32 位的立即数 imm 按位逻辑或，结果写入寄存器 rt 中。
    wire inst_lui;  // 将 16 位立即数 imm 写入寄存器 rt 的高 16 位，寄存器 rt 的低 16 位置 0。
    wire inst_or;   // 寄存器 rs 中的值与寄存器 rt 中的值按位逻辑或，结果写入寄存器 rd 中。
    wire inst_xor;  // 寄存器 rs 中的值与寄存器 rt 中的值按位逻辑异或，结果写入寄存器 rd 中。
    wire inst_xori; // 寄存器 rs 中的值与 0 扩展至 32 位的立即数 imm 按位逻辑异或，结果写入寄存器 rt 中。
    wire inst_and;  // 寄存器 rs 中的值与寄存器 rt 中的值按位逻辑与，结果写入寄存器 rd 中。
    wire inst_nor;  // 寄存器 rs 中的值与寄存器 rt 中的值按位逻辑或，结果取反，写入寄存器 rd 中。
    wire inst_andi; // 寄存器 rs 中的值与 0 扩展至 32 位的立即数 imm 按位逻辑与，结果写入寄存器 rt 中。

// 移位指令
    wire inst_sll;  // 由立即数 sa 指定移位量，对寄存器 rt 的值进行逻辑左移，结果写入寄存器 rd 中。
    wire inst_sla;  // 由立即数 sa 指定移位量，对寄存器 rt 的值进行算术左移，结果写入寄存器 rd 中。
    wire inst_srl;  // 由立即数 sa 指定移位量，对寄存器 rt 的值进行逻辑右移，结果写入寄存器 rd 中。
    wire inst_sra;  // 由立即数 sa 指定移位量，对寄存器 rt 的值进行算术右移，结果写入寄存器 rd 中。
    wire inst_sllv; // 由寄存器 rs 的值指定移位量，对寄存器 rt 的值进行逻辑左移，结果写入寄存器 rd 中。
    wire inst_srlv; // 由寄存器 rs 的值指定移位量，对寄存器 rt 的值进行逻辑右移，结果写入寄存器 rd 中。
    wire inst_srav; // 由寄存器 rs 的值指定移位量，对寄存器 rt 的值进行算术右移，结果写入寄存器 rd 中。

// 分支跳转指令
    wire inst_beq;  // 如果寄存器 rs 的值等于寄存器 rt 的值则转移，否则顺序执行。
                    // 转移目标由立即数 offset 左移 2 位并进行有符号扩展的值加上该分支指令对应的延迟槽指令的 PC 计算得到。
    wire inst_bne;  // 如果寄存器 rs 的值不等于寄存器 rt 的值则转移，否则顺序执行。
                    // 转移目标由立即数 offset 左移 2位并进行有符号扩展的值
                    // 加上该分支指令对应的延迟槽指令的 PC 计算得到。
    wire inst_jr;   // 无条件跳转。跳转目标为寄存器 rs 中的值。
    wire inst_jal;  // 无条件跳转。跳转目标由该分支指令对应的延迟槽指令的 PC 的最高 4 位与立即数 instr_index 左移2 位后的值拼接得到。
                    // 同时将该分支对应延迟槽指令之后的指令的 PC 值保存至第 31 号通用寄存器中。
    wire inst_jalr; // 无条件跳转。跳转目标为寄存器 rs 中的值，同时将该分支对应延迟槽指令之后的指令的 PC 值保存至第 31 号通用寄存器中。
    wire inst_bgezal;
    wire inst_j;
    wire inst_bltz;
    wire inst_blez;
    wire inst_bgtz;
    wire inst_bgez;
    wire inst_bltzal;

//访存指令
    wire inst_lw;   // 将 base 寄存器的值加上符号扩展后的立即数 offset 得到访存的虚地址，
                    // 如果地址不是 4 的整数倍则触发地址错例外，
                    // 否则据此虚地址从存储器中读取连续 4 个字节的值，写入到 rt 寄存器中。
    wire inst_sw;   // 将 base 寄存器的值加上符号扩展后的立即数 offset 得到访存的虚地址，
                    // 如果地址不是 4 的整数倍则触发地址错例外，
                    // 否则据此虚地址将 rt 寄存器存入存储器中。

    wire inst_lb;   // 将 base 寄存器的值加上符号扩展后的立即数 offset 得到访存的虚地址,
                    // 据此虚地址从存储器中读取 1 个字节的值并进行符号扩展，写入到 rt 寄存器中。
    wire inst_lbu;  // 将 base 寄存器的值加上符号扩展后的立即数 offset 得到访存的虚地址，
                    // 据此虚地址从存储器中读取 1 个字节的值并进行 0 扩展，写入到 rt 寄存器中。
    wire inst_lh;   // 将 base 寄存器的值加上符号扩展后的立即数 offset 得到访存的虚地址，如果地址不是 2 的整数倍
                    // 则触发地址错例外，否则据此虚地址从存储器中读取连续 2 个字节的值并进行符号扩展，写入到rt 寄存器中。

    wire inst_lhu;  // 将 base 寄存器的值加上符号扩展后的立即数 offset 得到访存的虚地址，如果地址不是 2 的整数倍则触发地址错例外，
                    // 否则据此虚地址从存储器中读取连续 2 个字节的值并进行 0 扩展，写入到 rt寄存器中。
    wire inst_sb;   // 将 base 寄存器的值加上符号扩展后的立即数 offset 得到访存的虚地址，据此虚地址将 rt 寄存器的最低字节存入存储器中。
    wire inst_sh;   // 将 base 寄存器的值加上符号扩展后的立即数 offset 得到访存的虚地址，如果地址不是 2 的整数倍则触发地址错例外，
                    // 否则据此虚地址将 rt 寄存器的低半字存入存储器中。

    // 数据移动指令

    wire inst_mfhi; // 将 HI 寄存器的值写入到寄存器 rd 中。
    wire inst_mflo; // 将 LO 寄存器的值写入到寄存器 rd 中。
    wire inst_mthi; // 将寄存器 rs 的值写入到 HI 寄存器中。
    wire inst_mtlo; // 将寄存器 rs 的值写入到 LO 寄存器中。

    wire op_add, op_sub, op_slt, op_sltu;
    wire op_and, op_nor, op_or, op_xor;
    wire op_sll, op_srl, op_sra, op_lui;

    // 6-64译码器
    decoder_6_64 u0_decoder_6_64(
    	.in  (opcode  ),
        .out (op_d )
    ); // 二进制编码转为one-hot编码，64
    
    // 6-64译码器
    decoder_6_64 u1_decoder_6_64(
    	.in  (func  ),
        .out (func_d )
    ); // 64
    
    // 5-32译码器
    decoder_5_32 u0_decoder_5_32(
    	.in  (rs  ),
        .out (rs_d )
    );
    
    // 5-32译码器
    decoder_5_32 u1_decoder_5_32(
    	.in  (rt  ),
        .out (rt_d )
    );

     decoder_5_32 u2_decoder_5_32(
    	.in  (rd  ),
        .out (rd_d )
    );

     decoder_5_32 u3_decoder_5_32(
    	.in  (sa  ),
        .out (sa_d )
    );

    /*
        一条指令
        op[31:26] rs[25:21] rt[20:16] rd[15:11] sa[10:6] func[5:0]
    */

    
    // 判断

    /* 
        算术运算指令
    */

    // 加（可产生溢出例外）
    assign inst_add     = op_d[6'b00_0000] & func_d[6'b10_0000];    
    // 加立即数（可产生溢出例外）
    assign inst_addi    = op_d[6'b00_1000];    
    // 无符号加（不产生溢出例外）
     assign inst_addu   = op_d[6'b00_0000] & func_d[6'b10_0001];   
    // 无符号加立即数（不产生溢出例外）
    assign inst_addiu   = op_d[6'b00_1001];    
    // 减（可产生溢出例外）
    assign inst_sub     = op_d[6'b00_0000] & func_d[6'b10_0010];    
    // 无符号减（不产生溢出例外）
    assign inst_subu    = op_d[6'b00_0000] & func_d[6'b10_0011];    
    // 有符号小于 置 1
    assign inst_slt     = op_d[6'b00_0000] & func_d[6'b10_1010];    
    // 有符号小于立即数 置 1
    assign inst_slti    = op_d[6'b00_1010];    
    // 无符号小于 置 1
    assign inst_sltu    = op_d[6'b00_0000] & func_d[6'b10_1011];    
    // 无符号小于立即数 置 1
    assign inst_sltiu   = op_d[6'b00_1011];    
    // 有符号字除
    assign inst_div     = op_d[6'b00_0000] & func_d[6'b01_1010] & rd_d[5'b0_0000] & sa_d[5'b0_0000];
    // 无符号字除
    assign inst_divu    = op_d[6'b00_0000] & func_d[6'b01_1011] & rd_d[5'b0_0000] & sa_d[5'b0_0000];
    // 有符号字乘
    assign inst_mult    = op_d[6'b00_0000] & func_d[6'b01_1000] & rd_d[5'b0_0000] & sa_d[5'b0_0000];
    // 无符号字乘
    assign inst_multu   = op_d[6'b00_0000] & func_d[6'b01_1001] & rd_d[5'b0_0000] & sa_d[5'b0_0000];


    /* 
        逻辑运算指令
    */

    // 位与
    assign inst_and     = op_d[6'b00_0000] & func_d[6'b10_0100];
    // 立即数位与
    assign inst_andi    = op_d[6'b00_1100];
    // 寄存器高半部分置立即数
    assign inst_lui     = op_d[6'b00_1111];    
    // 位或非
    assign inst_nor     = op_d[6'b00_0000] & func_d[6'b10_0111];
    // 位或
    assign inst_or      = op_d[6'b00_0000] & func_d[6'b10_0101];   
    // 立即数位或
    assign inst_ori     = op_d[6'b00_1101];    
    // 位异或
    assign inst_xor     = op_d[6'b00_0000] & func_d[6'b10_0110];    
    // 立即数位异或
    assign inst_xori    = op_d[6'b00_1110];
    
    /*
        移位指令
    */

    // 逻辑左移
    assign inst_sllv    = op_d[6'b00_0000] & func_d[6'b00_0100];
    // 立即数逻辑左移
    assign inst_sll     = op_d[6'b00_0000] & func_d[6'b00_0000];

    // 算术右移
    assign inst_srav    = op_d[6'b00_0000] & func_d[6'b00_0111];
    
    // 立即数算术右移
    assign inst_sra     = op_d[6'b00_0000] & func_d[6'b00_0011];
    // 逻辑右移
    assign inst_srlv    = op_d[6'b00_0000] & func_d[6'b00_0110];

    // 立即数逻辑右移
    assign inst_srl     = op_d[6'b00_0000] & func_d[6'b00_0010];


    /*
        分支跳转指令
    */

    // 分支相等转移
    assign inst_beq     = op_d[6'b00_0100];
    // 分支不等转移
    assign inst_bne     = op_d[6'b00_0101];
    // 大于等于0转移
    assign inst_bgez    = op_d[6'b00_0001] & rt_d[6'b0_0001];
    // 大于0转移
    assign inst_bgtz    = op_d[6'b00_0111] & rt_d[6'b0_0000];
    // 小于等于0转移
    assign inst_blez    = op_d[6'b00_0110] & rt_d[6'b0_0000];
    // 小于0转移
    assign inst_bltz    = op_d[6'b00_0001] & rt_d[6'b0_0000];
    // 大于等于0且保存返回地址
    assign inst_bgezal  = op_d[6'b00_0001] & rt_d[6'b1_0001];
    // 小于0且保存返回地址
    assign inst_bltzal  = op_d[6'b00_0001] & rt_d[6'b1_0000];

    // 无条件跳转
    assign inst_j       = op_d[6'b00_0010];
    // 无条件直接跳转至子程序并保存返回地址
    assign inst_jal     = op_d[6'b00_0011];
    // 无条件寄存器跳转
    assign inst_jr      = op_d[6'b00_0000] & func_d[6'b00_1000] & rt_d[5'b0_0000] & rd_d[5'b0_0000] & sa_d[5'b0_0000];
    // 无条件寄存器跳转至子程序并保存返回地址下
    assign inst_jalr      = op_d[6'b00_0000]  & rt_d[6'b0_0000] & func_d[6'b00_1001];

    /*
        数据移动指令
    */

    // HI 寄存器至通用寄存器
    assign inst_mfhi    = op_d[6'b00_0000] & func_d[6'b01_0000] & rs_d[5'b0_0000] & rt_d[5'b0_0000] & sa_d[5'b0_0000];
    // LO 寄存器至通用寄存器
    assign inst_mflo    = op_d[6'b00_0000] & func_d[6'b01_0010] & rs_d[5'b0_0000] & rt_d[5'b0_0000] & sa_d[5'b0_0000];
    // 通用寄存器至 HI 寄存器
   assign inst_mthi    = op_d[6'b00_0000] & func_d[6'b01_0001] & rt_d[5'b0_0000] & rd_d[5'b0_0000] & sa_d[5'b0_0000];
    // 通用寄存器至 LO 寄存器

   assign inst_mtlo    = op_d[6'b00_0000] & func_d[6'b01_0011] & rt_d[5'b0_0000] & rd_d[5'b0_0000] & sa_d[5'b0_0000];

    /*
        访存指令
    */

    // 取字节，有符号拓展
    assign inst_lb      = op_d[6'b10_0000];
    // 取字节，无符号拓展
    assign inst_lbu     = op_d[6'b10_0100];
    // 取半字，有符号拓展
    assign inst_lh      = op_d[6'b10_0001];
    // 取半字，无符号拓展
    assign inst_lhu     = op_d[6'b10_0101];
    // 取字
    assign inst_lw      = op_d[6'b10_0011];
    // 存字
    assign inst_sw      = op_d[6'b10_1011];
    // 存字节
    assign inst_sb      = op_d[6'b10_1000];
    // 存半字
    assign inst_sh      = op_d[6'b10_1001];

    // rs to reg1
    assign sel_alu_src1[0] =    inst_lw | inst_sw |inst_lb| inst_lbu  | inst_lh | inst_lhu| inst_sb | inst_sh |
                                inst_ori | inst_addiu | inst_or | inst_xor | inst_and  | inst_andi| inst_nor | inst_xori |
                                inst_sub | inst_subu | inst_add | inst_addi | inst_addu |
                                inst_jr | inst_bgezal | inst_bltzal |
                                inst_slti | inst_or | inst_srav | inst_sltu | inst_slt | inst_sltiu | inst_sllv| inst_srlv |
                                inst_div | inst_divu |inst_mult | inst_multu |
                                inst_mthi | inst_mtlo 
                                ; // 源寄存器1选择rs(寄存器1)

    // pc to reg1
    assign sel_alu_src1[1] = inst_jal | inst_jalr | inst_bltzal | inst_bgezal; // 源寄存器1选择pc

    // sa_zero_extend to reg1
    assign sel_alu_src1[2] = inst_sll | inst_sra | inst_srl; // 源寄存器1选择sa(移位量)

    
    // rt to reg2
    assign sel_alu_src2[0] =    inst_sub | inst_subu | inst_addu | inst_sll | inst_or | inst_xor | inst_sra | inst_srl |
                                inst_srlv | inst_sllv| inst_sra | inst_srav| inst_sltu | inst_slt  | inst_add | inst_and| inst_nor |//;
                                inst_div | inst_divu |inst_mult | inst_multu;
        
    // imm_sign_extend to reg2
    assign sel_alu_src2[1] =    inst_lui | inst_addiu | inst_lw | inst_sw | inst_slti| inst_sltiu | inst_addi | 
                                inst_lb  | inst_lbu   | inst_lh  | inst_lhu | inst_sh | inst_sb;

    // 32'b8 to reg2
    assign sel_alu_src2[2] = inst_jal | inst_jalr | inst_bgezal | inst_bltzal;

    // imm_zero_extend to reg2
    assign sel_alu_src2[3] = inst_ori | inst_andi | inst_xori;

    // ALU 运算类型

    assign op_add = inst_add | inst_addi | inst_addiu |  inst_addu |  inst_add | inst_addi |
                    inst_jal | inst_jalr | inst_bltzal | inst_bgezal |
                    inst_lw | inst_lb | inst_lbu | inst_lh | inst_lhu | inst_sw | inst_sb | inst_sh
                    ;
                    
    assign op_sub = inst_subu | inst_sub;
    assign op_slt = inst_slt | inst_slti;
    assign op_sltu = inst_sltu | inst_sltiu;
    assign op_and = inst_and | inst_andi;
    assign op_nor = inst_nor;
    assign op_or = inst_ori | inst_or;
    assign op_xor = inst_xor | inst_xori;
    assign op_sll = inst_sll | inst_sllv;
    assign op_srl = inst_srl | inst_srlv;
    assign op_sra = inst_sra | inst_srav;
    assign op_lui = inst_lui;

    assign alu_op = {op_add, op_sub, op_slt, op_sltu,
                     op_and, op_nor, op_or, op_xor,
                     op_sll, op_srl, op_sra, op_lui}; // 选择ALU运算类型



    // load and store enable 是否正常执行访存操作，内存sam
    assign data_ram_en = inst_lw | inst_lb | inst_lbu | inst_lh | inst_lhu | inst_sw | inst_sb | inst_sh  ;

    // write enable 写使能，内存sam，0000表示只读，1111表示全写，0011表示写低半字，0001表示写低字节
    assign data_ram_wen = inst_sw | inst_sb | inst_sh ? 4'b1111 : 4'b0000;



    // regfile store enable 写使能，判断指令是否要写回寄存器
    assign rf_we =  inst_ori | inst_lui | inst_addiu | inst_subu | inst_addu | inst_add | inst_addi | inst_sub |
                    inst_jr | inst_jal | inst_jalr | inst_bgezal | inst_bltzal |
                    inst_sll | inst_sllv | inst_sra | inst_srl | inst_srlv | inst_srav |
                    inst_or | inst_xor | inst_xori | inst_and | inst_andi | inst_nor |
                    inst_lw | inst_lb | inst_lbu | inst_lh | inst_lhu |
                    inst_slt | inst_slti | inst_sltu | inst_sltiu |
                    inst_mfhi | inst_mflo
                    ;


    // 寄存器写回位置控制
    // store in [rd] 寄存器地址来源
    assign sel_rf_dst[0] =  inst_sub |inst_subu | inst_addu |  inst_add |
                            inst_and | inst_nor | inst_or | inst_xor |
                            inst_slt | inst_sltu |
                            inst_jalr | 
                            inst_sra | inst_srl | inst_srlv | inst_srav | inst_sll | inst_sllv |
                            inst_mfhi | inst_mflo;

    // store in [rt] 
    assign sel_rf_dst[1] =  inst_ori | inst_lui | inst_addiu | inst_lw | inst_addi | inst_slti | inst_sltiu |
                            inst_andi | inst_xori |      
                            inst_lb |inst_lbu | inst_lh | inst_lhu
                            ;
    // store in [31]
    assign sel_rf_dst[2] = inst_jal | inst_jalr | inst_bltzal | inst_bgezal;

    // sel for regfile address 写回寄存器地址选择
    assign rf_waddr = {5{sel_rf_dst[0]}} & rd 
                    | {5{sel_rf_dst[1]}} & rt
                    | {5{sel_rf_dst[2]}} & 32'd31;

    // 0 from alu_res ; 1 from ld_res 写回数据选择 决定写回寄存器的数据是来自 ALU 的运算结果，还是来自内存的读取结果。
    assign sel_rf_res = inst_lw | inst_lb | inst_lbu | inst_lh | inst_lhu ? 1'b1:1'b0;

    assign id_to_ex_bus = { // 打包
        id_pc,          // 158:127
        inst,           // 126:95
        alu_op,         // 94:83
        sel_alu_src1,   // 82:80
        sel_alu_src2,   // 79:76
        data_ram_en,    // 75
        data_ram_wen,   // 74:71
        rf_we,          // 70
        rf_waddr,       // 69:65
        sel_rf_res,     // 64
        ndata1,         // 63:32
        ndata2          // 31:0
    };



    wire br_e;
    wire [31:0] br_addr;
    wire rs_eq_rt;
    wire rs_ge_z;
    wire rs_gt_z;
    wire rs_le_z;
    wire rs_lt_z;
    wire [31:0] pc_plus_4;
    assign pc_plus_4 = id_pc + 32'h4;

    assign rs_eq_rt = (ndata1 == ndata2); // 等于跳转
    assign rs_ge_z  = (!ndata1[31]); // >=跳转
    assign rs_gt_z  = ((!ndata1[31]) && ndata1!=0); // >跳转
    assign rs_le_z  = (ndata1 == 0 | ndata1[31]); // <=跳转
    assign rs_lt_z  = (ndata1[31]); // <跳转

    // 是否跳转
    assign br_e = inst_beq & rs_eq_rt | inst_j | inst_jalr | inst_jr | inst_jal | inst_bne & ~rs_eq_rt | 
                  inst_bgez & rs_ge_z | inst_bgtz & rs_gt_z |inst_blez & rs_le_z | inst_bltz & rs_lt_z |
                  inst_bgezal & rs_ge_z | inst_bltzal & rs_lt_z ;
                   
    // 计算跳转地址        
    assign br_addr =    // inst 当前指令
                        (inst_beq       ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : 32'b0) |
                        (inst_jr        ? ndata1 : 32'b0) |
                        (inst_jal       ? {pc_plus_4[31:28],instr_index,2'b0} : 32'b0) |
                        (inst_bne       ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : 32'b0) |
                        (inst_bgez      ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : 32'b0) |
                        (inst_bgtz      ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : 32'b0) |
                        (inst_blez      ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : 32'b0) |
                        (inst_bltz      ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : 32'b0) |
                        (inst_bgezal    ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : 32'b0) |
                        (inst_bltzal    ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : 32'b0) |
                        (inst_j         ? ({ pc_plus_4[31:28]         ,inst[25:0],2'b0}) : 32'b0) |
                        (inst_jalr      ? ndata1:32'b0);

    // HI/LO寄存器操作指令
    assign id_hi_lo_bus = {
        inst_mfhi,
        inst_mflo,
        inst_mthi,
        inst_mtlo,
        inst_mult,
        inst_multu,
        inst_div,
        inst_divu,
        hi,
        lo
    };
    
    // 访存指令
    assign id_load_bus = {
        inst_lb,
        inst_lbu,
        inst_lh,
        inst_lhu,
        inst_lw
    };

    // 存储指令
    assign id_save_bus = {
        inst_sb,
        inst_sh,
        inst_sw
    };

    // 分支跳转指令
    assign br_bus = {
        br_e,
        br_addr
    };

    // 与EX阶段进行数据相关性比较，决定是否暂停流水线
    assign stallreq_for_bru = ex_id & // 当前EX阶段指令要写寄存器，请求暂停
    (& ex_rf_we & (rs == ex_rf_waddr | rt == ex_rf_waddr)) ? `Stop // 要写到的寄存器是当前ID阶段指令要读的寄存器，请求暂停
    : `NoStop;


endmodule