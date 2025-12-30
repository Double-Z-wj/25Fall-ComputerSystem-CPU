`include "lib/defines.vh"

module CTRL(
    input wire rst,
    
    input wire stallreq_for_ex,
    input wire stallreq_for_load,
    input wire stallreq_load_use,
    
    // output reg flush,
    // output reg [31:0] new_pc,
    output reg [`StallBus-1:0] stall
);  
    always @ (*) begin
        if (rst) begin
            stall = `StallBus'b0;
        end
        else if (stallreq_for_ex) begin // 来自 EX 阶段
            stall = `StallBus'b001111;// PC, IF, ID, EX 暂停
        end
        else if (stallreq_load_use) begin // 来自 ID 阶段的 load-use 冲突
            stall = `StallBus'b000111; //  PC、IF、ID 暂停
        end
        else begin
            stall = `StallBus'b0;
        end
    end

endmodule