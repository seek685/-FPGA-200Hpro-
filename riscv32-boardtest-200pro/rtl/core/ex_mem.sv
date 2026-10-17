module ex_mem(
    input logic clk,
    input logic rst_n,
    input logic flush,
    input logic bubble,

    input logic in_valid,
    input logic [31:0] in_alu_result,
    input logic [31:0] in_store_data,
    input logic [31:0] in_pc4,
    input logic [4:0] in_rd,
    input logic in_reg_write,
    input logic in_mem_read,
    input logic in_mem_write,
    input logic [1:0] in_MemtoReg,
    input logic [1:0] in_mem_size,
    input logic in_load_unsigned,

    output logic out_valid,
    output logic [31:0] out_alu_result,
    output logic [31:0] out_store_data,
    output logic [31:0] out_pc4,
    output logic [4:0] out_rd,
    output logic out_reg_write,
    output logic out_mem_read,
    output logic out_mem_write,
    output logic [1:0] out_MemtoReg,
    output logic [1:0] out_mem_size,
    output logic out_load_unsigned

);
    always_ff@(posedge clk)begin
        if(!rst_n) begin
            out_valid<=0;
            out_alu_result<=0;
            out_store_data<=0;
            out_pc4<=0;
            out_rd<=0;
            out_reg_write<=0;
            out_mem_read<=0;
            out_mem_write<=0;
            out_MemtoReg<=0;
            out_mem_size<=0;
            out_load_unsigned<=0;
        end
        else if(flush) begin
            out_valid<=0;
            out_alu_result<=0;
            out_store_data<=0;
            out_pc4<=0;
            out_rd<=0;
            out_reg_write<=0;
            out_mem_read<=0;
            out_mem_write<=0;
            out_MemtoReg<=0;
            out_mem_size<=0;
            out_load_unsigned<=0;
        end
        else if (bubble)begin
            out_valid<=0;
            out_alu_result<=0;
            out_store_data<=0;
            out_pc4<=0;
            out_rd<=0;
            out_reg_write<=0;
            out_mem_read<=0;
            out_mem_write<=0;
            out_MemtoReg<=0;
            out_mem_size<=0;
            out_load_unsigned<=0;
        end
        else begin
            out_valid<=in_valid;
            out_alu_result<=in_alu_result;
            out_store_data<=in_store_data;
            out_pc4<=in_pc4;
            out_rd<=in_rd;
            out_reg_write<=in_reg_write;
            out_mem_read<=in_mem_read;
            out_mem_write<=in_mem_write;
            out_MemtoReg<=in_MemtoReg;
            out_mem_size<=in_mem_size;
            out_load_unsigned<=in_load_unsigned;
        end
    end


endmodule