`timescale 1ns/1ps
module tb_branch_predictor;
    localparam RAS_DEPTH = 16;
    logic clk = 0;
    logic rst_n = 0;
    logic [31:0] if_pc = 0, if_instr = 32'h00000013;
    logic if_is_branch = 0, if_accept = 0;
    logic if_pred_taken;
    logic [31:0] if_pred_target;
    logic [3:0] if_pht_index;
    logic [5:0] if_ghr_snapshot;
    logic ex_train_valid = 0;
    logic [31:0] ex_branch_pc = 0, ex_actual_target = 0;
    logic [3:0] ex_pht_index = 0;
    logic ex_actual_taken = 0;
    logic ex_is_branch = 0, ex_is_jalr = 0, ex_is_call = 0, ex_is_return = 0;
    logic ex_ghr_recover_valid = 0;
    logic [5:0] ex_ghr_recover_value = 0;
    integer checks = 0;

    branch_predictor #(
        .GHR_WIDTH(6), .PHT_INDEX_WIDTH(4), .BTB_INDEX_WIDTH(2),
        .RAS_DEPTH(RAS_DEPTH)
    ) dut (.*);

    function automatic [31:0] jal(input [4:0] rd, input integer imm);
        jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
    endfunction

    function automatic [31:0] jalr(input [4:0] rd, input [4:0] rs1, input integer imm);
        jalr = {imm[11:0], rs1, 3'b000, rd, 7'b1100111};
    endfunction

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "FAIL: %s (time=%0t)", message, $time);
        checks = checks + 1;
    endtask

    // A controlled clock keeps each directed transaction at exactly one edge.
    task automatic tick;
        #2; clk = 1; #2; clk = 0;
        ex_train_valid = 0;
        ex_is_branch = 0;
        ex_is_jalr = 0;
        ex_is_call = 0;
        ex_is_return = 0;
        ex_ghr_recover_valid = 0;
        #2;
    endtask

    task automatic reset_predictor;
        rst_n = 0;
        if_accept = 0;
        tick();
        rst_n = 1;
        #1;
    endtask

    task automatic fetch(input [31:0] pc_value, input [31:0] instruction,
                         input logic branch_value, input logic accept_value);
        if_pc = pc_value;
        if_instr = instruction;
        if_is_branch = branch_value;
        if_accept = accept_value;
        #1;
    endtask

    task automatic train(input [31:0] pc_value, input [3:0] pht_index,
                         input logic taken, input [31:0] target,
                         input logic is_branch, input logic is_jalr,
                         input logic is_call, input logic is_return);
        ex_train_valid = 1;
        ex_branch_pc = pc_value;
        ex_pht_index = pht_index;
        ex_actual_taken = taken;
        ex_actual_target = target;
        ex_is_branch = is_branch;
        ex_is_jalr = is_jalr;
        ex_is_call = is_call;
        ex_is_return = is_return;
        tick();
    endtask

    initial begin
        reset_predictor();
        check(if_ghr_snapshot == 0, "reset clears history");
        check(!if_pred_taken, "ordinary instruction is not predicted taken");
        for (int i = 0; i < 4; i++)
            check(dut.btb_valid_q[i] == 0, "cold initialization invalidates every BTB entry");
        fetch(32'h100, jalr(0, 2, 0), 0, 0);
        check(!if_pred_taken, "cold JALR misses without a trained target");

        fetch(32'h100, jal(1, 64), 0, 0);
        check(if_pred_taken && if_pred_target == 32'h140, "cold JAL positive immediate");
        tick();
        check(if_ghr_snapshot == 0, "stalled JAL does not update GHR");
        fetch(32'h100, jal(0, -8), 0, 1);
        check(if_pred_taken && if_pred_target == 32'hf8, "JAL negative immediate and rd=x0");
        tick();
        check(if_ghr_snapshot == 0, "accepted JAL does not enter branch history");
        fetch(32'h100000, jal(5, -1048576), 0, 0);
        check(if_pred_taken && if_pred_target == 0, "JAL minimum signed immediate");
        fetch(32'h100000, jal(1, 1048574), 0, 0);
        check(if_pred_taken && if_pred_target == 32'h1ffffe, "JAL maximum signed immediate");

        fetch(0, 32'h13, 0, 0);
        check(dut.pht_q[3] == 2'b01, "PHT starts weakly not taken");
        train(32'h10c, 3, 0, 32'h80, 1, 0, 0, 0);
        check(dut.pht_q[3] == 2'b00, "PHT 01 to 00");
        train(32'h10c, 3, 0, 32'h80, 1, 0, 0, 0);
        check(dut.pht_q[3] == 2'b00, "PHT lower saturation");
        for (int i = 1; i <= 3; i++) begin
            train(32'h10c, 3, 1, 32'h80, 1, 0, 0, 0);
            check(dut.pht_q[3] == i, "PHT increments on taken");
        end
        train(32'h10c, 3, 1, 32'h80, 1, 0, 0, 0);
        check(dut.pht_q[3] == 2'b11, "PHT upper saturation");
        for (int i = 2; i >= 0; i--) begin
            train(32'h10c, 3, 0, 32'h80, 1, 0, 0, 0);
            check(dut.pht_q[3] == i, "PHT decrements on not taken");
        end

        train(32'h100, 0, 1, 32'h80, 1, 0, 0, 0);
        fetch(32'h100, 32'h00000063, 1, 0);
        check(if_pred_taken && if_pred_target == 32'h80, "trained branch predicts target");
        tick();
        check(if_ghr_snapshot == 0 && if_pred_taken, "stall holds history without suppressing prediction");
        if_accept = 1;
        tick();
        check(if_ghr_snapshot == 1, "accepted taken branch shifts history");
        tick();
        check(if_ghr_snapshot == 2, "accepted not-taken branch shifts zero");
        ex_ghr_recover_valid = 1;
        ex_ghr_recover_value = 6'b101101;
        tick();
        check(if_ghr_snapshot == 6'b101101, "recovery wins over concurrent accepted branch");
        check(if_pht_index == 4'b1111, "wide GHR folds into smaller PHT index");
        fetch(0, 32'h13, 0, 1);
        tick();
        check(if_ghr_snapshot == 6'b101101, "ordinary instructions do not pollute history");

        reset_predictor();
        train(32'h100, 3, 1, 32'h900, 0, 1, 0, 0);
        check(dut.pht_q[3] == 0, "JALR does not train conditional counters");
        fetch(32'h100, jalr(0, 2, 12), 0, 0);
        check(if_pred_taken && if_pred_target == 32'h900, "JALR BTB target is already an effective target");
        train(32'h110, 0, 1, 32'ha00, 0, 1, 0, 0);
        check(!if_pred_taken && if_pred_target == 32'h104, "BTB tag rejects overwritten alias");
        fetch(32'h110, jalr(0, 2, 0), 0, 0);
        check(if_pred_taken && if_pred_target == 32'ha00, "BTB alias replacement installs new tag");
        train(32'h110, 0, 1, 32'hbbb, 0, 0, 0, 0);
        check(if_pred_target == 32'ha00, "direct JAL does not evict BTB entries");
        fetch(32'h110, 32'h13, 0, 0);
        check(!if_pred_taken, "BTB entry cannot redirect ordinary instruction");

        reset_predictor();
        fetch(32'h800, jalr(0, 1, 0), 0, 0);
        check(!if_pred_taken, "empty RAS misses without reading stale stack data");
        ex_train_valid = 1;
        ex_branch_pc = 32'h300;
        ex_is_call = 1;
        #1;
        check(if_pred_taken && if_pred_target == 32'h304, "same-cycle EX call bypasses link to IF return");
        check(dut.ras_count_q == 0, "EX bypass does not modify state before clock");
        tick();
        check(dut.ras_count_q == 1 && if_pred_target == 32'h304, "call commits one stack entry");
        train(32'h400, 0, 1, 0, 0, 0, 1, 0);
        check(if_pred_target == 32'h404 && dut.ras_count_q == 2, "nested call predicts newest return");
        fetch(32'h800, jalr(0, 1, 3), 0, 0);
        check(if_pred_target == 32'h406, "RAS return adds positive I immediate and clears bit zero");
        fetch(32'h800, jalr(0, 1, -3), 0, 0);
        check(if_pred_target == 32'h400, "RAS return sign-extends negative I immediate");
        fetch(32'h800, jalr(0, 5, 0), 0, 0);
        check(if_pred_taken && if_pred_target == 32'h404, "x5 is a return hint");
        fetch(32'h800, jalr(1, 1, 0), 0, 0);
        check(!if_pred_taken, "same link rd/rs1 is a call, not a return");
        fetch(32'h800, jalr(5, 1, 0), 0, 0);
        check(if_pred_taken && if_pred_target == 32'h404, "x1 to x5 coroutine has a pop hint");
        fetch(32'h800, jalr(1, 5, 0), 0, 0);
        check(if_pred_taken && if_pred_target == 32'h404, "x5 to x1 coroutine has a pop hint");
        fetch(32'h800, jalr(0, 1, 0), 0, 0);
        ex_train_valid = 1;
        ex_is_return = 1;
        #1;
        check(if_pred_target == 32'h304, "same-cycle EX pop bypass exposes older return");
        tick();
        check(dut.ras_count_q == 1 && if_pred_target == 32'h304, "resolved return pops once");
        ex_train_valid = 1;
        ex_branch_pc = 32'h500;
        ex_is_return = 1;
        ex_is_call = 1;
        #1;
        check(if_pred_target == 32'h504, "same-cycle coroutine pop then push bypass");
        tick();
        check(dut.ras_count_q == 1 && if_pred_target == 32'h504, "coroutine preserves nonempty depth");
        train(0, 0, 1, 0, 0, 0, 0, 1);
        train(0, 0, 1, 0, 0, 0, 0, 1);
        check(dut.ras_count_q == 0 && !if_pred_taken, "RAS underflow does not wrap count");
        ex_is_call = 1;
        ex_is_return = 1;
        ex_train_valid = 0;
        tick();
        check(dut.ras_count_q == 0, "squashed control flow cannot train RAS");
        train(32'h600, 0, 1, 0, 0, 0, 1, 1);
        check(dut.ras_count_q == 1 && if_pred_target == 32'h604, "empty coroutine pushes after ignored pop");

        reset_predictor();
        for (int i = 0; i < RAS_DEPTH + 3; i++) begin
            train(32'h1000 + i * 4, 0, 1, 0, 0, 0, 1, 0);
            check(dut.ras_count_q == ((i < RAS_DEPTH) ? i + 1 : RAS_DEPTH), "RAS count saturates at capacity");
            check(if_pred_taken && if_pred_target == 32'h1004 + i * 4, "overflow keeps newest return");
        end
        for (int i = RAS_DEPTH + 2; i >= 3; i--) begin
            check(if_pred_taken && if_pred_target == 32'h1004 + i * 4, "overflow unwinds newest retained entries");
            train(0, 0, 1, 0, 0, 0, 0, 1);
        end
        check(dut.ras_count_q == 0 && !if_pred_taken, "overflow discards oldest entries cleanly");

        train(32'h800, 0, 1, 32'hc00, 0, 1, 0, 0);
        check(if_pred_taken && if_pred_target == 32'hc00, "empty return falls back to BTB");
        train(32'h700, 0, 1, 0, 0, 0, 1, 0);
        check(if_pred_target == 32'h704, "nonempty RAS overrides stale BTB return target");
        reset_predictor();
        check(if_pred_taken && if_pred_target == 32'hc00 && dut.ras_count_q == 0,
              "warm reset retains BTB training and empties RAS");
        check(if_ghr_snapshot == 0 && dut.pht_q[3] == 0, "warm reset clears GHR and retains trained counters");
        train(32'h800, 0, 1, 32'hd00, 0, 1, 0, 0);
        check(if_pred_taken && if_pred_target == 32'hd00,
              "resolved JALR corrects retained target after warm reset");

        fetch(32'h200, 32'h00000063, 1, 0);
        train(32'h200, 0, 1, 32'h240, 1, 0, 0, 0);
        train(32'h200, 0, 1, 32'h240, 1, 0, 0, 0);
        check(if_pred_taken && if_pred_target == 32'h240, "branch is trained before warm reset");
        reset_predictor();
        check(if_pred_taken && if_pred_target == 32'h240,
              "warm reset retains conditional target and direction training");
        train(32'h200, 0, 1, 32'h280, 1, 0, 0, 0);
        check(if_pred_taken && if_pred_target == 32'h280,
              "resolved taken branch corrects retained target after warm reset");
        train(32'h200, 0, 0, 32'h280, 1, 0, 0, 0);
        train(32'h200, 0, 0, 32'h280, 1, 0, 0, 0);
        check(!if_pred_taken, "resolved not-taken branches correct retained direction after warm reset");

        $display("PASS tb_branch_predictor checks=%0d", checks);
        $finish;
    end
endmodule
