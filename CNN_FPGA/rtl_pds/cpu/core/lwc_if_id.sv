// Imported from the user's 12-pipeline CPU; see cpu_import.json for provenance.
module lwc_if_id(
    input  logic        clk,
    input  logic        rst,
    input  logic        flush,
    input  logic        stall,

    input  logic        in_valid,
    input  logic [31:0] in_pc,
    input  logic [31:0] in_pc4,
    input  logic [31:0] in_instr,

    output logic        out_valid,
    output logic [31:0] out_pc,
    output logic [31:0] out_pc4,
    output logic [31:0] out_instr,

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
        if(rst==0) begin
            out_valid<=1'b0;
            out_pc<=32'd0;
            out_pc4<=32'd0;
            out_instr<=32'd0;
            out_ghr_snapshot<=12'd0;
            out_pred_target<=32'd0;
            out_pht_index<=12'd0;
            out_pred_taken<=1'd0;
        end
        else if(flush==1)begin
            out_valid<=1'b0;
            out_pc<=32'd0;
            out_pc4<=32'd0;
            out_instr<=32'd0;
            out_ghr_snapshot<=12'd0;
            out_pred_target<=32'd0;
            out_pht_index<=12'd0;
            out_pred_taken<=1'd0;
        end
        else if(stall==1)begin
            //hold current state
        end
        else begin
            out_valid<=in_valid;
            out_pc<=in_pc;
            out_pc4<=in_pc4;
            out_instr<=in_instr;
            out_ghr_snapshot<=in_ghr_snapshot;
            out_pred_target<=in_pred_target;
            out_pht_index<=in_pht_index;
            out_pred_taken<=in_pred_taken;
        end
    end

endmodule
