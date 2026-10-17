module pc #(
    parameter logic [31:0] RESET_PC = 32'h8000_0000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] next_pc,

    input logic stall,

    output logic [31:0] pc
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pc <= RESET_PC;
        else if (stall) pc<=pc;
        else        pc <= next_pc;
    end
endmodule
