`timescale 1ns/1ps

module tb_reset_release_sync;
    logic clk_a = 0, clk_b = 0, run_b = 1, arst_n = 1;
    wire rst_a_n, rst_b_n;
    integer edges_a = 0, edges_b = 0;
    integer assertions = 0;
    always #5 clk_a = ~clk_a;
    always #7 if (run_b) clk_b = ~clk_b;
    reset_release_sync a(.clk(clk_a), .arst_n(arst_n), .rst_n(rst_a_n));
    reset_release_sync b(.clk(clk_b), .arst_n(arst_n), .rst_n(rst_b_n));

    always @(posedge clk_a or negedge arst_n) begin
        if (!arst_n) edges_a = 0;
        else if (edges_a < 3) edges_a = edges_a + 1;
        #0.001;
        assert (rst_a_n === (edges_a == 3)) else $fatal(1, "reset A release latency");
        assertions = assertions + 1;
    end
    always @(posedge clk_b or negedge arst_n) begin
        if (!arst_n) edges_b = 0;
        else if (edges_b < 3) edges_b = edges_b + 1;
        #0.001;
        assert (rst_b_n === (edges_b == 3)) else $fatal(1, "reset B release latency");
    end
    always @(posedge rst_a_n)
        assert (clk_a && arst_n) else $fatal(1, "A reset released off-clock");
    always @(posedge rst_b_n)
        assert (clk_b && arst_n) else $fatal(1, "B reset released off-clock");

    initial begin
        #1 arst_n = 0;
        #2 arst_n = 1;
        wait (rst_a_n && rst_b_n);
        @(negedge clk_b);
        run_b = 0;
        #2 arst_n = 0;
        #0.01;
        assert (!rst_a_n && !rst_b_n) else $fatal(1, "reset must assert with stopped clock");
        #1 arst_n = 1;
        #60;
        assert (rst_a_n && !rst_b_n) else $fatal(1, "stopped domain released reset");
        run_b = 1;
        wait (rst_b_n);
        // Pulse reset repeatedly at different phases, including shorter than
        // either clock period and before an earlier release has completed.
        for (integer n = 0; n < 24; n = n + 1) begin
            #(2+n%9) arst_n = 0;
            #0.01;
            assert (!rst_a_n && !rst_b_n) else $fatal(1, "asynchronous reset pulse missed");
            #1 arst_n = 1;
        end
        wait (rst_a_n && rst_b_n);
        #20;
        $display("PASS tb_reset_release_sync: independent clocks, stopped clock, short pulses (%0d A checks)", assertions);
        $finish;
    end
    initial begin
        #5000;
        $fatal(1, "reset regression timeout");
    end
endmodule
