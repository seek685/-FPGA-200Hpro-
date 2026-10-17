module cpu_soc #(
    parameter integer CPU_CLK_HZ = 120_000_000,
    parameter integer BAUD_RATE = 115200,
    parameter HEX_FILE = "firmware.hex"
)(
    input  wire clk,
    input  wire rst,
    output wire uart_tx
);
    wire [31:0] pc;
    wire [31:0] instruction;
    wire [31:0] perip_addr, perip_wdata, perip_rdata;
    wire perip_wen;
    wire [1:0] perip_mask;
    wire [12:0] data_rom_index;
    wire [31:0] data_rom_word;

    myCPU u_cpu (
        .cpu_clk(clk), .cpu_rst(rst),
        .irom_addr(pc), .irom_data(instruction),
        .perip_addr(perip_addr), .perip_wen(perip_wen),
        .perip_mask(perip_mask), .perip_wdata(perip_wdata),
        .perip_rdata(perip_rdata)
    );

    board_irom #(.HEX_FILE(HEX_FILE)) u_rom (
        .instruction_index(pc[14:2]), .instruction(instruction),
        .data_index(data_rom_index), .data_word(data_rom_word)
    );

    board_mmio #(.CPU_CLK_HZ(CPU_CLK_HZ), .BAUD_RATE(BAUD_RATE)) u_mmio (
        .clk(clk), .rst(rst),
        .addr(perip_addr), .write_data(perip_wdata),
        .write_enable(perip_wen), .size(perip_mask),
        .read_data(perip_rdata),
        .data_rom_index(data_rom_index), .data_rom_word(data_rom_word),
        .uart_tx(uart_tx)
    );
endmodule
