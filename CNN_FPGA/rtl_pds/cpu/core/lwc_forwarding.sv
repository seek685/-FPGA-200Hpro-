// Imported from the user's 12-pipeline CPU; see cpu_import.json for provenance.
module lwc_forwarding (
    input  logic [4:0]  id_ex_rs1,
    input  logic [4:0]  id_ex_rs2,
    input  logic [31:0] id_ex_rs1_value,
    input  logic [31:0] id_ex_rs2_value,

    input  logic  ex_mem_valid,
    input  logic  ex_mem_reg_write,
    input  logic  ex_mem_mem_read,
    input  logic [1:0]  ex_mem_MemtoReg,
    input  logic [4:0]  ex_mem_rd,
    input  logic [31:0] ex_mem_alu_result,
    input  logic [31:0] ex_mem_pc4,

    input  logic  mem_wb_valid,
    input  logic  mem_wb_reg_write,
    input  logic [4:0]  mem_wb_rd,
    input  logic [31:0] mem_wb_write_data,

    output logic [31:0] forwarded_rs1_value,
    output logic [31:0] forwarded_rs2_value
);
    always_comb begin
        forwarded_rs1_value=id_ex_rs1_value;
        forwarded_rs2_value=id_ex_rs2_value;
        if(ex_mem_valid==1&&ex_mem_reg_write==1&&ex_mem_mem_read==0&&ex_mem_rd!=0&&id_ex_rs1==ex_mem_rd)begin
            if(ex_mem_MemtoReg!=2'b01) begin
                    if(ex_mem_MemtoReg==2'b00||ex_mem_MemtoReg==2'b11)forwarded_rs1_value=ex_mem_alu_result;
                    else forwarded_rs1_value=ex_mem_pc4;
            end
        end
        else if(mem_wb_valid==1&&mem_wb_reg_write==1&&mem_wb_rd!=0&&id_ex_rs1==mem_wb_rd)begin
            forwarded_rs1_value=mem_wb_write_data;
        end
       if(ex_mem_valid==1&&ex_mem_reg_write==1&&ex_mem_mem_read==0&&ex_mem_rd!=0&&id_ex_rs2==ex_mem_rd)begin
            if(ex_mem_MemtoReg!=2'b01) begin
                    if(ex_mem_MemtoReg==2'b00||ex_mem_MemtoReg==2'b11)forwarded_rs2_value=ex_mem_alu_result;
                    else forwarded_rs2_value=ex_mem_pc4;
            end
        end
        else if(mem_wb_valid==1&&mem_wb_reg_write==1&&mem_wb_rd!=0&&id_ex_rs2==mem_wb_rd)begin
            forwarded_rs2_value=mem_wb_write_data;
        end

    end

endmodule
