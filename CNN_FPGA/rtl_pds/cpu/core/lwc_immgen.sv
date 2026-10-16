// Imported from the user's 12-pipeline CPU; see cpu_import.json for provenance.
module lwc_immgen (
    input  logic [31:0] instr,
    input  logic [2:0]  imm_sel,
    output logic [31:0] imm
);
    // Keep the original imm_sel encoding: 000-I, 001-S, 010-B, 011-U, 100-J.
    localparam logic [2:0] I = 3'b000;
    localparam logic [2:0] S = 3'b001;
    localparam logic [2:0] B = 3'b010;
    localparam logic [2:0] U = 3'b011;
    localparam logic [2:0] J = 3'b100;

    always_comb begin
        case (imm_sel)
            I: imm = {{20{instr[31]}}, instr[31:20]};
            S: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            B: imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}; // bit0=0
            U: imm = {instr[31:12], 12'b0};
            J: imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}; // bit0=0
            default: imm = 32'b0;
        endcase
    end
endmodule
