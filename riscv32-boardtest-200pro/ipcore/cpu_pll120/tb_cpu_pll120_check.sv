`timescale 1ns/1fs
module tb_cpu_pll120_check;
    reg clkin1 = 0;
    wire clkout0;
    wire lock;
    real first_edge, elapsed, measured_mhz;
    integer edge_count;
    cpu_pll120 dut(.clkin1(clkin1), .clkout0(clkout0), .lock(lock));
    always #(500.0/27.0) clkin1 = ~clkin1;
    initial begin
        #1000000;
        $fatal(1, "PLL lock/frequency check timed out");
    end
    initial begin
        wait(lock === 1'b1);
        repeat(20) @(posedge clkout0);
        first_edge = $realtime;
        for (edge_count = 0; edge_count < 12000; edge_count = edge_count + 1) begin
            @(posedge clkout0);
            if (lock !== 1'b1) $fatal(1, "PLL lost lock");
        end
        elapsed = $realtime - first_edge;
        measured_mhz = 12000.0 * 1000.0 / elapsed;
        if (measured_mhz < 119.988 || measured_mhz > 120.012)
            $fatal(1, "Unexpected PLL output frequency: %0.9f MHz", measured_mhz);
        $display("PASS cpu_pll120: input=27 MHz, measured=%0.9f MHz, 12000 stable output cycles, lock maintained", measured_mhz);
        $finish;
    end
endmodule
