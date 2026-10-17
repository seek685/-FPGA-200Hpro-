module board_mmio #(
    parameter integer CPU_CLK_HZ = 120_000_000,
    parameter integer BAUD_RATE = 115200
)(
    input wire clk,
    input wire rst,
    input wire [31:0] addr,
    input wire [31:0] write_data,
    input wire write_enable,
    input wire [1:0] size,
    output reg [31:0] read_data,
    output wire [12:0] data_rom_index,
    input wire [31:0] data_rom_word,
    output wire uart_tx
);
    localparam [31:0] UART_DATA = 32'h8020_0100;
    localparam [31:0] UART_STATUS = 32'h8020_0104;
    localparam [31:0] TIMER_VALUE = 32'h8020_0050;
    localparam [31:0] TIMER_STATUS = 32'h8020_0054;
    localparam [31:0] TIMER_CONTROL = 32'h8020_0070;
    reg [31:0] addr_q;
    reg [1:0] size_q;
    reg write_q;
    reg [31:0] cycle_counter;
    reg counter_running;
    reg counter_overflow;
    reg [31:0] counter_read_q;
    reg counter_overflow_q;
    reg tx_pending;
    reg [7:0] tx_data;
    wire tx_busy;
    wire uart_busy = tx_busy || tx_pending;
    reg uart_busy_q;
    wire ram_selected = (addr[31:16] == 16'h8010);
    wire [31:0] ram_data;
    wire [31:0] shifted_rom = data_rom_word >> {addr_q[1:0], 3'b000};

    assign data_rom_index = addr_q[14:2];
    board_dram u_ram (
        .clk(clk), .rst(rst), .addr(addr[15:0]),
        .write_data(write_data), .write_enable(write_enable && ram_selected && !rst),
        .read_enable(!write_enable && ram_selected && !rst), .size(size),
        .read_data(ram_data)
    );
    uart_tx #(.CLK_HZ(CPU_CLK_HZ), .BAUD_RATE(BAUD_RATE)) u_uart (
        .clk(clk), .rst(rst), .start(tx_pending), .data(tx_data),
        .tx(uart_tx), .busy(tx_busy)
    );

    always @(posedge clk) begin
        if (rst) begin
            addr_q <= 0;
            size_q <= 2'b10;
            write_q <= 0;
            cycle_counter <= 0;
            counter_running <= 0;
            counter_overflow <= 0;
            counter_read_q <= 0;
            counter_overflow_q <= 0;
            tx_pending <= 0;
            tx_data <= 0;
            uart_busy_q <= 0;
        end else begin
            addr_q <= addr;
            size_q <= size;
            write_q <= write_enable;
            uart_busy_q <= uart_busy;
            counter_read_q <= cycle_counter;
            counter_overflow_q <= counter_overflow;
            tx_pending <= 0;
            if (write_enable && addr == UART_DATA && !uart_busy) begin
                tx_pending <= 1;
                tx_data <= write_data[7:0];
            end
            // Include the stop edge: a start-to-stop interval of N clocks
            // measures N, then remains frozen during UART reporting.
            if (counter_running) begin
                cycle_counter <= cycle_counter + 1'b1;
                if (&cycle_counter) counter_overflow <= 1;
            end
            if (write_enable && addr == TIMER_CONTROL) begin
                counter_running <= write_data[0];
                if (write_data[0]) begin
                    cycle_counter <= 0;
                    counter_overflow <= 0;
                end
            end
        end
    end

    always @* begin
        read_data = 0;
        if (!write_q) begin
            if (addr_q[31:15] == 17'h10000) begin
                case (size_q)
                    2'b00: read_data = {24'd0, shifted_rom[7:0]};
                    2'b01: read_data = {16'd0, shifted_rom[15:0]};
                    2'b10: read_data = shifted_rom;
                    default: ;
                endcase
            end else if (addr_q[31:16] == 16'h8010)
                read_data = ram_data;
            else if (addr_q == UART_STATUS)
                read_data = {31'd0, uart_busy_q};
            else if (addr_q == TIMER_VALUE)
                read_data = counter_read_q;
            else if (addr_q == TIMER_STATUS)
                read_data = {31'd0, counter_overflow_q};
        end
    end
endmodule
