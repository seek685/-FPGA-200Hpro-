module mem_wb(
    input logic clk,
    input logic rst_n,
    input logic in_valid,
    input logic [31:0] in_read_data,
    input logic [31:0] in_alu_result,
    input logic [31:0] in_pc4,
    input logic [4:0] in_rd,
    input logic in_reg_write,
    input logic [1:0] in_MemtoReg,

    output logic out_valid,
    output logic [31:0] out_read_data,
    output logic [31:0] out_alu_result,
    output logic [31:0] out_pc4,
    output logic [4:0] out_rd,
    output logic out_reg_write,
    output logic [1:0] out_MemtoReg
);
    always_ff@(posedge clk) begin
        if(rst_n==1'b0) begin
            out_valid<=0;
            out_read_data<=0;
            out_alu_result<=0;
            out_pc4<=0;
            out_rd<=0;
            out_reg_write<=0;
            out_MemtoReg<=0;
        end
        else begin
            out_valid<=in_valid;
            out_read_data<=in_read_data;
            out_alu_result<=in_alu_result;
            out_pc4<=in_pc4;
            out_rd<=in_rd;
            out_reg_write<=in_reg_write;
            out_MemtoReg<=in_MemtoReg;
        end   
    end

endmodule