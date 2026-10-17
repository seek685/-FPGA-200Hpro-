module branch_unit (
    input  logic [31:0] rdata1,
    input  logic [31:0] rdata2,
    input  logic [2:0]  funct3,
    output logic        branch_1
);
    logic [3:0] byte_equal;
    logic [3:0] byte_less;
    logic upper_equal;
    logic upper_less;
    logic lower_less;
    logic equal_value;
    logic unsigned_less;
    logic signed_less;

    // Bound the carry comparisons to one byte and combine them in parallel.
    assign byte_equal[3] = rdata1[31:24] == rdata2[31:24];
    assign byte_equal[2] = rdata1[23:16] == rdata2[23:16];
    assign byte_equal[1] = rdata1[15:8] == rdata2[15:8];
    assign byte_equal[0] = rdata1[7:0] == rdata2[7:0];
    assign byte_less[3] = rdata1[31:24] < rdata2[31:24];
    assign byte_less[2] = rdata1[23:16] < rdata2[23:16];
    assign byte_less[1] = rdata1[15:8] < rdata2[15:8];
    assign byte_less[0] = rdata1[7:0] < rdata2[7:0];

    assign upper_equal = byte_equal[3] & byte_equal[2];
    assign upper_less = byte_less[3] | (byte_equal[3] & byte_less[2]);
    assign lower_less = byte_less[1] | (byte_equal[1] & byte_less[0]);
    assign equal_value = upper_equal & byte_equal[1] & byte_equal[0];
    assign unsigned_less = upper_less | (upper_equal & lower_less);
    assign signed_less = (rdata1[31] ^ rdata2[31]) ? rdata1[31] : unsigned_less;

    always_comb begin
        case (funct3[2:1])
            2'b00: branch_1 = equal_value ^ funct3[0];   // BEQ/BNE
            2'b10: branch_1 = signed_less ^ funct3[0];  // BLT/BGE
            2'b11: branch_1 = unsigned_less ^ funct3[0];// BLTU/BGEU
            default: branch_1 = 1'b0;
        endcase
    end
endmodule
