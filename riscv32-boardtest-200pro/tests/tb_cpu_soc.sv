`timescale 1ns/1ps
module tb_cpu_soc;
    reg clk = 0;
    reg rst = 1;
    wire tx;
    integer cycles = 0;
    integer coremark_mode = 0;
    integer unused;
    cpu_soc #(.BAUD_RATE(12_000_000)) dut (.clk(clk), .rst(rst), .uart_tx(tx));
    serial_uart_monitor #(.BIT_CYCLES(10)) monitor (.clk(clk), .rst(rst), .tx(tx));
    always #5 clk = !clk;

    function automatic bit contains(input string haystack, input string needle);
        integer index;
        begin
            contains = 0;
            for (index = 0; index + needle.len() <= haystack.len(); index = index + 1)
                if (haystack.substr(index, index + needle.len() - 1) == needle)
                    contains = 1;
        end
    endfunction
    initial begin
        unused = $value$plusargs("COREMARK=%d", coremark_mode);
        repeat (8) @(negedge clk);
        rst = 0;
    end
    always @(posedge clk) begin
        if (!rst) begin
            cycles <= cycles + 1;
            if (cycles > 20_000_000) $fatal(1, "CPU firmware timeout");
            if (^dut.instruction === 1'bx) $fatal(1, "Unknown IROM instruction");
        end
    end
    always @(monitor.line_toggle) begin
        if (contains(monitor.received, "HALTED") ||
            contains(monitor.received, "SMOKE FAIL") ||
            contains(monitor.received, "TIMER OVERFLOW"))
            $fatal(1, "Firmware self-test/overflow failure");
        if ((!coremark_mode && contains(monitor.received, "SMOKE DONE")) ||
            (coremark_mode && contains(monitor.received, "COREMARK DONE"))) begin
            if (!contains(monitor.received, "CPU BOARD TEST") ||
                !contains(monitor.received, "CPU_HZ=120000000") ||
                !contains(monitor.received, "SMOKE PASS checksum=0x24924939"))
                $fatal(1, "Missing boot/self-test output");
            $display("PASS tb_cpu_soc mode=%0d cycles=%0d uart_bytes=%0d", coremark_mode,
                     cycles, monitor.byte_count);
            $fclose(monitor.fd);
            $finish;
        end
    end
endmodule
