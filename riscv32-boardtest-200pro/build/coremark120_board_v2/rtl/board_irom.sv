module board_irom #(
    parameter HEX_FILE = "firmware.hex"
)(
    input  wire [12:0] instruction_index,
    output wire [31:0] instruction,
    input  wire [12:0] data_index,
    output wire [31:0] data_word
);
    reg [31:0] mem [0:8191];
    initial begin
        $readmemh(HEX_FILE, mem);
    end
    assign instruction = mem[instruction_index];
    assign data_word = mem[data_index];
endmodule
