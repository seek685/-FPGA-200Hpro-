`timescale 1ns/1ps

module pool_checker #(
    parameter integer ROWS = 9,
    parameter integer WIDTH = 9
)(output logic done = 0);
    logic clk = 0;
    always #5 clk = ~clk;
    logic clk_en = 0, rst_n = 1, new_line_1 = 0, input_valid = 0;
    logic [ROWS-1:0][WIDTH-1:0] data = '0;
    wire [WIDTH-1:0] y_out;
    wire new_line_out_1, output_valid;
    logic [WIDTH-1:0] expected0 = 0, expected1 = 0, sample_max;
    logic [1:0] expected_line = 0, expected_valid = 0;
    integer checks = 0;

    max_pool2d #(.PE_ROW_NUM(ROWS), .DATA_WIDTH(WIDTH)) dut (.*);

    // Independent, linear reference; check all data and control every cycle,
    // including invalid cycles and stalls, so latency changes cannot pass.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            expected0 = 0;
            expected1 = 0;
            expected_line = 0;
            expected_valid = 0;
        end else if (clk_en) begin
            sample_max = 0;
            for (integer k = 0; k < ROWS; k = k + 1)
                if (data[k] > sample_max) sample_max = data[k];
            expected1 = expected0;
            expected0 = sample_max;
            expected_line = {expected_line[0], new_line_1};
            expected_valid = {expected_valid[0], input_valid};
        end
        #0.001;
        assert (y_out === expected1 && new_line_out_1 === expected_line[1] &&
                output_valid === expected_valid[1])
            else $fatal(1, "pool ROWS=%0d WIDTH=%0d check=%0d data=%0d expected=%0d", ROWS, WIDTH, checks, y_out, expected1);
        checks = checks + 1;
    end

    initial begin
        #1 rst_n = 0;
        #2 rst_n = 1;
        for (integer cycle = 0; cycle < 2200; cycle = cycle + 1) begin
            @(negedge clk);
            clk_en = (cycle < ROWS*2 + 8) || (($urandom % 5) != 0);
            input_valid = (($urandom % 4) != 0);
            new_line_1 = (($urandom % 17) == 0);
            for (integer k = 0; k < ROWS; k = k + 1) data[k] = WIDTH'($urandom);
            if (cycle < ROWS) begin
                data = '0;
                data[cycle] = '1;  // Every input must be able to win.
            end else if (cycle < 2*ROWS) begin
                data = '0;
                data[cycle-ROWS] = WIDTH'(1) << (WIDTH-1); // Unsigned MSB.
            end else if ((cycle % 19) == 0) begin
                data = '0;
            end else if ((cycle % 23) == 0) begin
                data = '1; // Ties at the largest representable value.
            end
            if (cycle == 700 || cycle == 1400) begin
                clk_en = 0;
                #1 rst_n = 0;
                #1 rst_n = 1; // Reset between clock edges, even while stalled.
            end
        end
        repeat (3) @(negedge clk);
        $display("PASS max_pool2d ROWS=%0d WIDTH=%0d cycles=%0d", ROWS, WIDTH, checks);
        done = 1;
    end
endmodule

module tb_max_pool2d;
    wire [6:0] done;
    pool_checker #(.ROWS(1), .WIDTH(1)) c0(done[0]);
    pool_checker #(.ROWS(2), .WIDTH(7)) c1(done[1]);
    pool_checker #(.ROWS(3), .WIDTH(9)) c2(done[2]);
    pool_checker #(.ROWS(4), .WIDTH(8)) c3(done[3]);
    pool_checker #(.ROWS(9), .WIDTH(9)) c4(done[4]);
    pool_checker #(.ROWS(16), .WIDTH(9)) c5(done[5]);
    pool_checker #(.ROWS(25), .WIDTH(12)) c6(done[6]);
    initial begin
        wait (&done);
        $display("PASS tb_max_pool2d: maximum, two-cycle alignment, stalls and async reset");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "pool regression timeout");
    end
endmodule
