// Imported from the user's 12-pipeline CPU; see cpu_import.json for provenance.
module lwc_alu (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [3:0]  alu_control,
    output logic [31:0] alu_result
);
    //R'b=rs2  I'b=imm
    //I:alu_src=1,b=imm   R:alu_src=0,b=rs2
    always_comb begin
        case (alu_control)
            4'b0000: alu_result = a + b; // ADD
            4'b0001: alu_result = a - b; // SUB
            4'b0010: alu_result = a & b; // AND
            4'b0011: alu_result = a | b; // OR
            4'b0100: alu_result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0; // SLT
            4'b0101: alu_result = (a < b) ? 32'd1 : 32'd0; // SLTU, unsigned comparison
            4'b0110: alu_result = a ^ b; // XOR
            4'b0111: alu_result = a << b[4:0];  // SLL
            4'b1000: alu_result = a >> b[4:0];  // SRL, fill high bits with zero
            4'b1001: alu_result = $signed(a) >>> b[4:0]; // SRA, fill high bits with the sign bit
            default: alu_result = 32'b0;
        endcase
    end
endmodule
