`timescale 1ns/1ps
module tb_uart_nominal;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg [7:0] data = 0;
    wire tx;
    wire busy;
    uart_tx dut (.clk(clk), .rst(rst), .start(start), .data(data), .tx(tx), .busy(busy));
    serial_uart_monitor #(.BIT_CYCLES(120_000_000 / 115200)) monitor (.clk(clk), .rst(rst), .tx(tx));
    always #5 clk = !clk;
    task automatic send(input [7:0] value);
        begin
            wait (!busy);
            @(negedge clk); data = value; start = 1;
            @(negedge clk); start = 0;
            wait (!busy);
        end
    endtask
    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        send(8'h00); send(8'hff); send(8'ha5); send(8'h5a);
        repeat (2) @(posedge clk);
        if (monitor.byte_count != 4 || monitor.bytes[0] != 8'h00 ||
            monitor.bytes[1] != 8'hff || monitor.bytes[2] != 8'ha5 ||
            monitor.bytes[3] != 8'h5a)
            $fatal(1, "Nominal UART data/framing mismatch");
        $display("PASS tb_uart_nominal divisor=1041 uart_bytes=4");
        $fclose(monitor.fd);
        $finish;
    end
    initial begin
        repeat (50000) @(posedge clk);
        $fatal(1, "Nominal UART timeout");
    end
endmodule
