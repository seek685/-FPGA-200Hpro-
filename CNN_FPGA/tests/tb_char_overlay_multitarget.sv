`timescale 1ns/1ps
module tb_char_overlay_multitarget;
    logic clk=0, vclk=0, rst_n=0;
    always #5 clk=~clk;
    always #7 vclk=~vclk;
    logic [15:0] x=0, y=0;
    logic line_start=0, fs=0, fe=0, cv=0, vs=0;
    logic [6:0] ch=0;
    logic [15:0] previous_display;

    // Negative control: eight stable targets revisit a six-slot tracker only
    // after their previous trial has been evicted. None can confirm twice.
    char_overlay #(.CROP_HEIGHT(20), .MAX_PLATES(6),
        .FONT_FILE("rtl_pds/data_process/mem_data/chars_16x16.mem")) six_slots(
        .clk_video(vclk), .rst_n_video(rst_n), .video_vs_in(vs),
        .video_hs_in(1'b0), .video_de_in(1'b0), .video_rgb_in(24'd0),
        .video_vs_out(), .video_hs_out(), .video_de_out(), .video_rgb_out(),
        .clk_pe(clk), .rst_n_pe(rst_n), .x_min_in(x), .y_min_in(y),
        .new_line_1(line_start), .out_char(ch), .out_valid(cv),
        .frame_start_out(fs), .frame_end_out(fe));

    // Positive control: display tracks have independent capacity; increasing
    // these slots does not require more concurrent crop pixel buffers.
    char_overlay #(.CROP_HEIGHT(20), .MAX_PLATES(16),
        .FONT_FILE("rtl_pds/data_process/mem_data/chars_16x16.mem")) dut(
        .clk_video(vclk), .rst_n_video(rst_n), .video_vs_in(vs),
        .video_hs_in(1'b0), .video_de_in(1'b0), .video_rgb_in(24'd0),
        .video_vs_out(), .video_hs_out(), .video_de_out(), .video_rgb_out(),
        .clk_pe(clk), .rst_n_pe(rst_n), .x_min_in(x), .y_min_in(y),
        .new_line_1(line_start), .out_char(ch), .out_valid(cv),
        .frame_start_out(fs), .frame_end_out(fe));

    task automatic result(input int target, input int last=-1);
        // Match the deployed crop's twenty input rows, followed by a complete
        // seven-character CTC result. All targets are farther apart than the
        // coordinate matching distance and repeat exactly each round.
        for(int row=0;row<20;row++) begin
            @(negedge clk);
            x=16'(100+(target%4)*250); y=16'(100+(target/4)*300); line_start=1;
            @(negedge clk); line_start=0;
        end
        @(negedge clk); fs=1;
        @(negedge clk); fs=0;
        for(int i=0;i<7;i++) begin
            cv=1; ch=7'((i==6 && last>=0)?last:(10+i+target));
            @(negedge clk);
        end
        cv=0;
        @(negedge clk); fe=1;
        @(negedge clk); fe=0;
        repeat(20) @(negedge vclk);
    endtask

    task automatic video_frame;
        @(negedge vclk); vs=1;
        repeat(2) @(negedge vclk); vs=0;
        repeat(4) @(negedge vclk);
    endtask

    task automatic check_association;
        if(dut.coord_count!=0 || dut.dbg_coord_error || dut.dbg_result_dropped ||
           six_slots.coord_count!=0 || six_slots.dbg_coord_error || six_slots.dbg_result_dropped)
            $fatal(1,"multitarget results lost coordinates or overflowed a FIFO");
    endtask

    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        // One trial round, then five consecutive confirmed display rounds.
        for(int round=0;round<6;round++) begin
            previous_display=dut.display_valid;
            for(int target=0;target<8;target++) begin
                result(target);
                if(dut.display_valid!=previous_display)
                    $fatal(1,"multitarget visibility changed before VS");
            end
            check_association();
            if(six_slots.pending_valid!=0)
                $fatal(1,"six-slot negative control unexpectedly confirmed a target");
            if(round==0 && dut.pending_valid!=0)
                $fatal(1,"first result skipped two-result confirmation");
            if(round>0 && dut.pending_valid!=16'h00ff)
                $fatal(1,"eight stable targets did not all confirm in round %0d",round+1);
            video_frame();
            if(six_slots.display_valid!=0)
                $fatal(1,"six-slot negative control unexpectedly displayed text");
            if(dut.display_valid!=((round==0)?16'h0000:16'h00ff))
                $fatal(1,"eight-target frame snapshot incorrect in round %0d",round+1);
            if(round>0) begin
                for(int target=0;target<8;target++) begin
                    if(dut.display_x[target]!=100+(target%4)*250 ||
                       dut.display_y[target]!=84+(target/4)*300 || dut.display_length[target]!=7)
                        $fatal(1,"target %0d displayed at the wrong position/length",target);
                    for(int c=0;c<7;c++)
                        if(dut.display_text[target][c*7 +: 7]!=10+c+target)
                            $fatal(1,"target %0d character %0d was mixed with another target",target,c);
                end
            end
        end

        // A confirmed replacement must also remain invisible until VS.
        result(0,65); result(0,65);
        if(dut.pending_text[0][6*7 +: 7]!=65 || dut.display_text[0][6*7 +: 7]!=16 ||
           dut.display_valid!=16'h00ff)
            $fatal(1,"text replacement was not confirmed separately from the frame snapshot");
        video_frame();
        if(dut.display_text[0][6*7 +: 7]!=65 || dut.display_valid!=16'h00ff)
            $fatal(1,"confirmed text replacement was not published at VS");
        check_association();

        // No new results: the seven unchanged tracks expire one frame before
        // the recently refreshed target. All tracks must eventually disappear.
        repeat(4) video_frame();
        if(dut.display_valid!=16'h00ff)
            $fatal(1,"multitarget text expired before its configured hold time");
        video_frame();
        if(dut.display_valid!=16'h0001)
            $fatal(1,"unchanged tracks did not expire independently of refreshed target");
        video_frame();
        if(dut.display_valid!=0 || dut.pending_valid!=0 || dut.track_used!=0)
            $fatal(1,"stopped multitarget results did not fully expire");

        $display("PASS multitarget OSD: six-slot starvation reproduced; sixteen slots confirm eight stable targets, frame-atomic text and independent expiry");
        $finish;
    end
    initial begin #10000000; $fatal(1,"timeout"); end
endmodule
