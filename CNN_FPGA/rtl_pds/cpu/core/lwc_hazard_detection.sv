// Imported from the user's 12-pipeline CPU; see cpu_import.json for provenance.
module lwc_hazard_detection(
    input logic id_ex_valid,
    input logic id_ex_mem_read,
    input logic [4:0] id_ex_rd,

    input logic if_id_valid,
    input logic [6:0] if_id_opcode,
    input logic [4:0] if_id_rs1,
    input logic [4:0] if_id_rs2,

    output logic load_use_stall
);
localparam R_type=7'b0110011;
localparam Load=7'b0000011;
localparam Store=7'b0100011;
localparam Branch=7'b1100011;
localparam I_typeALU=7'b0010011;
localparam JALR=7'b1100111;
localparam LUI=7'b0110111;
localparam AUIPC=7'b0010111;
localparam JAL=7'b1101111;
    logic user_rs1;
    logic user_rs2;
    always_comb begin
        user_rs1=0;
        user_rs2=0;
       case(if_id_opcode)
        R_type:begin
            user_rs1=1;user_rs2=1;
        end
        Load:begin
            user_rs1=1;user_rs2=0;
        end
        Store:begin
            user_rs1=1;user_rs2=1;
        end
        Branch:begin
            user_rs1=1;user_rs2=1;
        end
        I_typeALU:begin
            user_rs1=1;user_rs2=0;
        end
        JALR:begin
            user_rs1=1;user_rs2=0;
        end
        LUI:begin
            user_rs1=0;user_rs2=0;
        end
        AUIPC:begin
            user_rs1=0;user_rs2=0;
        end
        JAL:begin
            user_rs1=0;user_rs2=0;
        end
        default:;
    endcase
        load_use_stall=if_id_valid&&id_ex_valid&&id_ex_mem_read&&id_ex_rd!=0&&(user_rs1&&if_id_rs1==id_ex_rd||user_rs2&&if_id_rs2==id_ex_rd);
    end
endmodule
