`timescale 1ns/1ps
// Clock-only PLL substitute: exercise board_top's reset protocol independently
// of vendor analog PLL behavior, including lock loss with no CPU clock.
module cpu_pll120(input wire clkin1, output reg clkout0 = 0, output reg lock = 0);
    reg clock_enabled = 1;
    always #5 begin
        if (clock_enabled) clkout0 = !clkout0;
        else clkout0 = 0;
    end
endmodule

module tb_board_reset;
    reg sys_clk = 0;
    reg rst_n = 0;
    wire tx;
    integer cycles;
    integer checks = 0;
    board_top dut (.sys_clk(sys_clk), .rst_n(rst_n), .uart_tx(tx));
    always #18.5185 sys_clk = !sys_clk;
    task automatic released;
        begin
            cycles = 0;
            while (dut.u_soc.rst) begin
                @(posedge dut.cpu_clk); #1;
                cycles = cycles + 1;
                if (cycles > 34) $fatal(1, "Reset failed to release");
            end
            if (cycles != 34) $fatal(1, "Reset released after %0d clocks; expected 34", cycles);
            checks = checks + 1;
        end
    endtask
    initial begin
        repeat (4) @(negedge dut.cpu_clk);
        rst_n = 1;
        repeat (40) @(negedge dut.cpu_clk);
        if (dut.u_soc.rst !== 1) $fatal(1, "Reset released before PLL lock");
        checks = checks + 1;
        dut.u_pll.lock = 1;
        released();
        @(negedge dut.cpu_clk);
        dut.u_pll.clock_enabled = 0;
        #2; rst_n = 0;
        #1;
        if (dut.u_soc.rst !== 1) $fatal(1, "External reset needs a running CPU clock");
        checks = checks + 1;
        #20; rst_n = 1;
        dut.u_pll.clock_enabled = 1;
        released();
        @(negedge dut.cpu_clk);
        dut.u_pll.clock_enabled = 0;
        #2; dut.u_pll.lock = 0;
        #1;
        if (dut.u_soc.rst !== 1) $fatal(1, "PLL lock loss needs a running CPU clock");
        checks = checks + 1;
        #20; dut.u_pll.lock = 1;
        dut.u_pll.clock_enabled = 1;
        released();
        $display("PASS tb_board_reset checks=%0d release_cycles=34", checks);
        $finish;
    end
    initial begin
        #5000;
        $fatal(1, "Board reset-test timeout");
    end
endmodule
