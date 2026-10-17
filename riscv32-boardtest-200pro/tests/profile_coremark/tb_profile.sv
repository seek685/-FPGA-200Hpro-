`timescale 1ns/1ps
module tb_profile;
    reg clk = 0;
    reg rst = 1;
    wire tx;
    integer elapsed = 0;
    integer measured = 0;
    integer retired = 0;
    integer bubbles = 0;
    integer stalls = 0;
    integer ex_branches = 0;
    integer branch_wrong = 0;
    integer ex_jalr = 0;
    integer jalr_wrong = 0;
    integer id_jal_wrong = 0;
    integer id_jal_raw = 0;
    integer stall_flush_overlap = 0;
    integer loads = 0;
    integer stores = 0;
    integer branches = 0;
    integer jal = 0;
    integer jalr = 0;
    integer other = 0;
    integer instruction_counts [0:8191];
    integer cycle_counts [0:8191];
    integer branch_wrong_counts [0:8191];
    integer jalr_wrong_counts [0:8191];
    integer stall_counts [0:8191];
    integer index;
    integer fd;
    reg done_profile = 0;
    reg [31:0] retired_pc;
    reg [31:0] last_retired_pc;
    reg [31:0] instruction;
    cpu_soc #(.BAUD_RATE(12_000_000)) dut (.clk(clk), .rst(rst), .uart_tx(tx));
    serial_uart_monitor #(.BIT_CYCLES(10)) monitor (.clk(clk), .rst(rst), .tx(tx));
    always #5 clk = !clk;

    function automatic bit contains(input string haystack, input string needle);
        integer item;
        begin
            contains = 0;
            for (item = 0; item + needle.len() <= haystack.len(); item = item + 1)
                if (haystack.substr(item, item + needle.len() - 1) == needle) contains = 1;
        end
    endfunction
    initial begin
        for (index = 0; index < 8192; index = index + 1) begin
            instruction_counts[index] = 0;
            cycle_counts[index] = 0;
            branch_wrong_counts[index] = 0;
            jalr_wrong_counts[index] = 0;
            stall_counts[index] = 0;
        end
        repeat (8) @(negedge clk);
        rst = 0;
    end

    // The window is exactly the hardware counter's active clock edges:
    // exclude start-store edge, include stop-store edge. Count WB valid before
    // each edge (architectural retirement), including stores and branches.
    always @(posedge clk) begin
        if (!rst) begin
            elapsed = elapsed + 1;
            if (elapsed > 10_000_000) $fatal(1, "Profile firmware timeout");
            if (dut.u_mmio.counter_running && !done_profile) begin
                measured = measured + 1;
                if (dut.u_cpu.mem_wb_valid) begin
                    retired = retired + 1;
                    retired_pc = dut.u_cpu.mem_wb_pc4 - 4;
                    if (retired_pc[31:15] != 17'h10000 || retired_pc[1:0] != 0)
                        $fatal(1, "Retired PC outside ROM: %08x", retired_pc);
                    last_retired_pc = retired_pc;
                    index = retired_pc[14:2];
                    instruction_counts[index] = instruction_counts[index] + 1;
                    instruction = dut.u_rom.mem[index];
                    case (instruction[6:0])
                        7'h03: loads = loads + 1;
                        7'h23: stores = stores + 1;
                        7'h63: branches = branches + 1;
                        7'h6f: jal = jal + 1;
                        7'h67: jalr = jalr + 1;
                        default: other = other + 1;
                    endcase
                end else bubbles = bubbles + 1;
                // Leaf-function time attribution: WB bubbles remain assigned
                // to the last retired PC, so branch recovery is visible. This
                // is an attribution convention, not an instruction latency.
                if (last_retired_pc[31:15] == 17'h10000) begin
                    index = last_retired_pc[14:2];
                    cycle_counts[index] = cycle_counts[index] + 1;
                end
                if (dut.u_cpu.stall) begin
                    stalls = stalls + 1;
                    index = dut.u_cpu.id_ex_pc[14:2];
                    stall_counts[index] = stall_counts[index] + 1;
                end
                if (dut.u_cpu.id_ex_valid && dut.u_cpu.id_ex_branch)
                    ex_branches = ex_branches + 1;
                if (dut.u_cpu.ex_branch_mispredict) begin
                    branch_wrong = branch_wrong + 1;
                    index = dut.u_cpu.id_ex_pc[14:2];
                    branch_wrong_counts[index] = branch_wrong_counts[index] + 1;
                end
                if (dut.u_cpu.id_ex_valid && dut.u_cpu.id_ex_jump == 2'b10)
                    ex_jalr = ex_jalr + 1;
                if (dut.u_cpu.ex_jalr_redirect) begin
                    jalr_wrong = jalr_wrong + 1;
                    index = dut.u_cpu.id_ex_pc[14:2];
                    jalr_wrong_counts[index] = jalr_wrong_counts[index] + 1;
                end
                if (dut.u_cpu.id_jal_redirect) begin
                    id_jal_raw = id_jal_raw + 1;
                    if (!dut.u_cpu.ex_branch_mispredict && !dut.u_cpu.ex_jalr_redirect)
                        id_jal_wrong = id_jal_wrong + 1;
                end
                if (dut.u_cpu.stall && dut.u_cpu.if_id_flush)
                    stall_flush_overlap = stall_flush_overlap + 1;
                if (dut.perip_wen && dut.perip_addr == 32'h80200070 && !dut.perip_wdata[0]) begin
                    done_profile = 1;
                    fd = $fopen("pc_counts.csv", "w");
                    $fdisplay(fd, "pc,retired,cycles_by_last_retired_pc,branch_mispredict,jalr_redirect,load_use_stall");
                    for (index = 0; index < 8192; index = index + 1)
                        if (instruction_counts[index] || cycle_counts[index] || branch_wrong_counts[index] || jalr_wrong_counts[index] || stall_counts[index])
                            $fdisplay(fd, "%08x,%0d,%0d,%0d,%0d,%0d", 32'h80000000 + index * 4,
                                instruction_counts[index], cycle_counts[index], branch_wrong_counts[index],
                                jalr_wrong_counts[index], stall_counts[index]);
                    $fclose(fd);
                    fd = $fopen("counters.json", "w");
                    $fdisplay(fd, "{");
                    $fdisplay(fd, "\"cycles\":%0d,\"retired\":%0d,\"wb_bubbles\":%0d,\"load_use_stalls\":%0d,", measured, retired, bubbles, stalls);
                    $fdisplay(fd, "\"ex_conditional_branches\":%0d,\"branch_mispredicts\":%0d,\"ex_jalr\":%0d,\"jalr_redirects\":%0d,", ex_branches, branch_wrong, ex_jalr, jalr_wrong);
                    $fdisplay(fd, "\"effective_id_jal_corrections\":%0d,\"raw_id_jal_corrections\":%0d,\"stall_flush_overlap\":%0d,", id_jal_wrong, id_jal_raw, stall_flush_overlap);
                    $fdisplay(fd, "\"loads\":%0d,\"stores\":%0d,\"branches\":%0d,\"jal\":%0d,\"jalr\":%0d,\"other\":%0d}", loads, stores, branches, jal, jalr, other);
                    $fclose(fd);
                    #1;
                    if (measured != dut.u_mmio.cycle_counter)
                        $fatal(1, "Counter/window mismatch measured=%0d timer=%0d", measured, dut.u_mmio.cycle_counter);
                    $display("PROFILE cycles=%0d retired=%0d stalls=%0d branch_wrong=%0d jalr_wrong=%0d id_jal_correct=%0d", measured, retired, stalls, branch_wrong, jalr_wrong, id_jal_wrong);
                end
            end
        end
    end
    always @(monitor.line_toggle) begin
        if (contains(monitor.received, "HALTED") || contains(monitor.received, "SMOKE FAIL") || contains(monitor.received, "TIMER OVERFLOW"))
            $fatal(1, "Firmware failure while profiling");
        if (contains(monitor.received, "COREMARK DONE")) begin
            if (!done_profile) $fatal(1, "No completed measurement");
            $display("PASS tb_profile cycles=%0d retired=%0d", measured, retired);
            $fclose(monitor.fd);
            $finish;
        end
    end
endmodule
