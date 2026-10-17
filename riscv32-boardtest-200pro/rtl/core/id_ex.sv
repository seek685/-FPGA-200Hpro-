module id_ex(
    input logic clk,
    input logic rst_n,
    input logic flush,
    input logic bubble,

    input logic in_valid,
    input logic [31:0] in_pc,
    input logic [31:0] in_pc4,
    input logic [31:0] in_rs1_value,
    input logic [31:0] in_rs2_value,
    input logic [31:0] in_imm,
    input logic [4:0] in_rs1,
    input logic [4:0] in_rs2,
    input logic [4:0] in_rd,
    input logic [2:0] in_funct3,
    input logic in_funct7_5,
    input logic [1:0] in_alu_src_a,
    input logic in_alu_src_b,
    input logic [3:0] in_alu_control,
    input logic in_reg_write,
    input logic in_mem_read,
    input logic in_mem_write,
    input logic [1:0] in_MemtoReg,
    input logic in_branch,
    input logic [1:0] in_jump,
    input logic [1:0] in_mem_size,
    input logic in_load_unsigned,

    output logic out_valid,
    output logic [31:0] out_pc,
    output logic [31:0] out_pc4,
    output logic [31:0] out_rs1_value,
    output logic [31:0] out_rs2_value,
    output logic [31:0] out_imm,
    output logic [4:0] out_rs1,
    output logic [4:0] out_rs2,
    output logic [4:0] out_rd,
    output logic [2:0] out_funct3,
    output logic out_funct7_5,
    output logic [1:0] out_alu_src_a,
    output logic out_alu_src_b,
    output logic [3:0] out_alu_control,
    output logic out_reg_write,
    output logic out_mem_read,
    output logic out_mem_write,
    output logic [1:0] out_MemtoReg,
    output logic out_branch,
    output logic [1:0] out_jump,
    output logic [1:0] out_mem_size,
    output logic out_load_unsigned,


    input logic [11:0] in_ghr_snapshot,
    input logic [31:0] in_pred_target,
    input logic [11:0] in_pht_index,
    input logic in_pred_taken,
    output logic [11:0] out_ghr_snapshot,
    output logic [31:0] out_pred_target,
    output logic [11:0] out_pht_index,
    output logic out_pred_taken

);
    always_ff@(posedge clk) begin
        if(rst_n==0)begin
            out_valid<=0;
            out_pc<=0;
            out_pc4<=0;
            out_rs1_value<=0;
            out_rs2_value<=0;
            out_imm<=0;
            out_rs1<=0;
            out_rs2<=0;
            out_rd<=0;
            out_funct3<=0;
            out_funct7_5<=0;
            out_alu_src_a<=0;
            out_alu_src_b<=0;
            out_alu_control<=0;
            out_reg_write<=0;
            out_mem_read<=0;
            out_mem_write<=0;
            out_MemtoReg<=0;
            out_branch<=0;
            out_jump<=0;
            out_mem_size<=0;
            out_load_unsigned<=0;

            out_ghr_snapshot<=12'd0;
            out_pred_target<=32'd0;
            out_pht_index<=12'd0;
            out_pred_taken<=1'd0;
        end
        else begin
            // Valid gates every architectural side effect. Squash only this
            // bit, keeping branch recovery off the wide datapath reset nets.
            out_valid<=in_valid && !flush && !bubble;
            out_pc<=in_pc;
            out_pc4<=in_pc4;
            out_rs1_value<=in_rs1_value;
            out_rs2_value<=in_rs2_value;
            out_imm<=in_imm;
            out_rs1<=in_rs1;
            out_rs2<=in_rs2;
            out_rd<=in_rd;
            out_funct3<=in_funct3;
            out_funct7_5<=in_funct7_5;
            out_alu_src_a<=in_alu_src_a;
            out_alu_src_b<=in_alu_src_b;
            out_alu_control<=in_alu_control;
            out_reg_write<=in_reg_write;
            out_mem_read<=in_mem_read;
            out_mem_write<=in_mem_write;
            out_MemtoReg<=in_MemtoReg;
            out_branch<=in_branch;
            out_jump<=in_jump;
            out_mem_size<=in_mem_size;
            out_load_unsigned<=in_load_unsigned;

            out_ghr_snapshot<=in_ghr_snapshot;
            out_pred_target<=in_pred_target;
            out_pht_index<=in_pht_index;
            out_pred_taken<=in_pred_taken;
        end
    end

endmodule
