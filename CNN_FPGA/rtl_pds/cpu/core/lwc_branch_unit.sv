// Imported from the user's 12-pipeline CPU; see cpu_import.json for provenance.
module lwc_branch_unit (
    input  logic [31:0] rdata1,
    input  logic [31:0] rdata2,
    input  logic [2:0]  funct3,
    output logic        branch_1
);
    always_comb begin
        case (funct3)
            3'b000: branch_1 = (rdata1 == rdata2);// BEQ
            3'b001: branch_1 = (rdata1 != rdata2);// BNE
            3'b100: branch_1 = ($signed(rdata1) <  $signed(rdata2)); // BLT
            3'b101: branch_1 = ($signed(rdata1) >= $signed(rdata2)); // BGE
            3'b110: branch_1 = (rdata1 < rdata2); // BLTU
            3'b111: branch_1 = (rdata1 >= rdata2);  // BGEU
            default: branch_1 = 1'b0;
        endcase
    end
endmodule
