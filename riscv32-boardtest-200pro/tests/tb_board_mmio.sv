`timescale 1ns/1ps
module tb_board_mmio;
    reg clk = 0;
    reg rst = 1;
    reg [31:0] addr = 0;
    reg [31:0] write_data = 0;
    reg write_enable = 0;
    reg [1:0] size = 2'b10;
    wire [31:0] read_data;
    wire [12:0] rom_index;
    wire [31:0] rom_data = 32'hfedcba98 ^ {19'd0, rom_index};
    wire tx;
    integer checks = 0;
    integer lane;
    reg [31:0] observed;
    reg [31:0] frozen;
    board_mmio #(.BAUD_RATE(12_000_000)) dut (
        .clk(clk), .rst(rst), .addr(addr), .write_data(write_data),
        .write_enable(write_enable), .size(size), .read_data(read_data),
        .data_rom_index(rom_index), .data_rom_word(rom_data), .uart_tx(tx)
    );
    serial_uart_monitor #(.BIT_CYCLES(10)) monitor (.clk(clk), .rst(rst), .tx(tx));
    always #5 clk = !clk;

    task automatic check(input [31:0] got, input [31:0] expected);
        begin
            checks = checks + 1;
            if (got !== expected)
                $fatal(1, "MMIO check=%0d got=%08x expected=%08x addr=%08x", checks,
                       got, expected, addr);
        end
    endtask
    task automatic store(input [31:0] address, input [31:0] value, input [1:0] width);
        begin
            @(negedge clk);
            addr = address; write_data = value; size = width; write_enable = 1;
            @(posedge clk); #1;
        end
    endtask
    task automatic load(input [31:0] address, input [1:0] width, output [31:0] value);
        begin
            @(negedge clk);
            addr = address; size = width; write_enable = 0;
            @(posedge clk); #1;
            value = read_data;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        store(32'h80100000, 32'h80ff7f01, 2'b10);
        load(32'h80100000, 2'b10, observed); check(observed, 32'h80ff7f01);
        for (lane = 0; lane < 4; lane = lane + 1) begin
            load(32'h80100000 + lane, 2'b00, observed);
            check(observed, (32'h80ff7f01 >> (lane * 8)) & 255);
        end
        load(32'h80100000, 2'b01, observed); check(observed, 32'h7f01);
        load(32'h80100002, 2'b01, observed); check(observed, 32'h80ff);
        for (lane = 0; lane < 4; lane = lane + 1)
            store(32'h80100000 + lane, 32'h10 + lane, 2'b00);
        load(32'h80100000, 2'b10, observed); check(observed, 32'h13121110);
        store(32'h80100002, 32'hf080, 2'b01);
        load(32'h80100000, 2'b10, observed); check(observed, 32'hf0801110);
        store(32'h80100000, 32'h55aa, 2'b01);
        load(32'h80100000, 2'b10, observed); check(observed, 32'hf08055aa);
        store(32'h8010fffc, 32'h5a55a5aa, 2'b10);
        load(32'h8010fffc, 2'b10, observed); check(observed, 32'h5a55a5aa);
        for (lane = 0; lane < 4; lane = lane + 1) begin
            load(32'h80000000 + lane, 2'b00, observed);
            check(observed, (32'hfedcba98 >> (lane * 8)) & 255);
        end
        load(32'h80000002, 2'b01, observed); check(observed, 32'hfedc);
        load(32'h80007ffc, 2'b10, observed); check(observed, 32'hfedcba98 ^ 8191);
        load(32'h80008000, 2'b10, observed); check(observed, 0);
        load(32'h80110000, 2'b10, observed); check(observed, 0);
        load(32'h12345678, 2'b10, observed); check(observed, 0);

        store(32'h80200070, 1, 2'b10);
        @(negedge clk); write_enable = 0; addr = 0;
        repeat (7) @(posedge clk);
        #1;
        check(dut.cycle_counter, 7);
        store(32'h80200070, 0, 2'b10);
        check(dut.cycle_counter, 8);
        frozen = dut.cycle_counter;
        repeat (4) @(posedge clk);
        #1; check(dut.cycle_counter, frozen);
        load(32'h80200050, 2'b10, observed); check(observed, frozen);
        store(32'h80200070, 1, 2'b10);
        check(dut.cycle_counter, 0);
        @(negedge clk); write_enable = 0; addr = 0;
        dut.cycle_counter = 32'hfffffffe;
        repeat (2) @(posedge clk);
        #1; check(dut.cycle_counter, 0); check(dut.counter_overflow, 1);
        store(32'h80200070, 0, 2'b10);
        load(32'h80200054, 2'b10, observed); check(observed, 1);
        store(32'h80200070, 1, 2'b10);
        load(32'h80200054, 2'b10, observed); check(observed, 0);
        store(32'h80200070, 0, 2'b10);

        store(32'h80200100, 32'h41, 2'b10);
        check(dut.uart_busy, 1);
        // Adjacent store while pending must be rejected, with no idle window.
        store(32'h80200100, 32'h42, 2'b10);
        check(dut.uart_busy, 1);
        load(32'h80200104, 2'b10, observed); check(observed, 1);
        repeat (120) @(posedge clk);
        #1; check(monitor.byte_count, 1);
        if (monitor.received != "A") $fatal(1, "Unexpected UART byte stream");
        load(32'h80200104, 2'b10, observed); check(observed, 0);
        $display("PASS tb_board_mmio checks=%0d uart_bytes=%0d", checks, monitor.byte_count);
        $fclose(monitor.fd);
        $finish;
    end
    initial begin
        repeat (1000) @(posedge clk);
        $fatal(1, "MMIO unit-test timeout");
    end
endmodule
