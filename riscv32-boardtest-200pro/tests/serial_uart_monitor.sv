`timescale 1ns/1ps
module serial_uart_monitor #(
    parameter integer BIT_CYCLES = 10,
    parameter CAPTURE_FILE = "uart_capture.txt"
)(input wire clk, input wire rst, input wire tx);
    string received = "";
    string current_line = "";
    integer byte_count = 0;
    reg [7:0] bytes [0:8191];
    integer fd;
    reg line_toggle = 0;
    reg [7:0] value;
    integer bit_number;
    initial fd = $fopen(CAPTURE_FILE, "wb");

    // Decode the physical 8N1 serial output, without observing MMIO writes.
    always @(negedge tx) begin
        if (!rst) begin
            repeat (BIT_CYCLES / 2) @(posedge clk);
            #1;
            if (tx !== 0) $fatal(1, "UART start-bit framing error");
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                repeat (BIT_CYCLES) @(posedge clk);
                #1;
                if (tx !== 0 && tx !== 1) $fatal(1, "UART unknown data bit");
                value[bit_number] = tx;
            end
            repeat (BIT_CYCLES) @(posedge clk);
            #1;
            if (tx !== 1) $fatal(1, "UART stop-bit framing error");
            received = {received, string'(value)};
            if (byte_count >= 8192) $fatal(1, "UART capture buffer overflow");
            bytes[byte_count] = value;
            byte_count = byte_count + 1;
            $fwrite(fd, "%c", value);
            $fflush(fd);
            if (value == 8'h0a) begin
                $display("UART: %s", current_line);
                current_line = "";
                line_toggle = !line_toggle;
            end else if (value != 8'h0d) begin
                current_line = {current_line, string'(value)};
            end
        end
    end
endmodule
