`timescale 1ns/1ps
module tb_char_overlay;
    logic clk=0, vclk=0, rst_n=0;
    always #5 clk=~clk;
    always #7 vclk=~vclk;
    logic [15:0] x=0, y=0;
    logic line_start=0, fs=0, fe=0, cv=0, vs=0, de=0;
    logic check_render=0;
    integer raster_x=0, raster_y=0, render_ticks=0;
    logic [15:0] reference_font [0:1215];
    logic [23:0] expected_rgb [0:3];
    logic [3:0] expected_de=0;
    integer letter;
    initial $readmemb("rtl_pds/data_process/mem_data/chars_16x16.mem", reference_font);
    logic [6:0] ch=0;
    wire vo, ho, deo;
    wire [23:0] rgb;
    char_overlay #(.CROP_HEIGHT(20), .FONT_FILE("rtl_pds/data_process/mem_data/chars_16x16.mem")) dut(
        .clk_video(vclk), .rst_n_video(rst_n), .video_vs_in(vs),
        .video_hs_in(1'b0), .video_de_in(de), .video_rgb_in(24'h123456),
        .video_vs_out(vo), .video_hs_out(ho), .video_de_out(deo), .video_rgb_out(rgb),
        .clk_pe(clk), .rst_n_pe(rst_n), .x_min_in(x), .y_min_in(y),
        .new_line_1(line_start), .out_char(ch), .out_valid(cv),
        .frame_start_out(fs), .frame_end_out(fe));
    always @(posedge vclk) if(check_render) begin
        for(int k=3;k>0;k--) expected_rgb[k]=expected_rgb[k-1];
        expected_rgb[0]=24'h123456;
        if(de && raster_x>=300 && raster_x<428 && raster_y>=184 && raster_y<200) begin
            letter=((raster_x-300)/16==7)?51:(10+(raster_x-300)/16);
            expected_rgb[0]=reference_font[letter*16+raster_y-184][15-(raster_x-300)%16] ? 24'hff00ff : 24'hffffff;
        end
        expected_de={expected_de[2:0],de};
        render_ticks++;
        #1;
        if(render_ticks>=4 && (rgb!==expected_rgb[3] || deo!==expected_de[3]))
            $fatal(1,"glyph/background/sync pipeline mismatch at input (%0d,%0d)",raster_x,raster_y);
    end
    // Exercise the documented raw-result diagnostic parameters as well.
    char_overlay #(.CROP_HEIGHT(20), .MAX_PLATES(1), .MIN_PLATE_CHARS(1),
        .MAX_PLATE_CHARS(20), .CONFIRM_RESULTS(1), .HOLD_FRAMES(1),
        .FONT_FILE("rtl_pds/data_process/mem_data/chars_16x16.mem")) diagnostic(
        .clk_video(vclk), .rst_n_video(rst_n), .video_vs_in(vs),
        .video_hs_in(1'b0), .video_de_in(1'b0), .video_rgb_in(24'h123456),
        .video_vs_out(), .video_hs_out(), .video_de_out(), .video_rgb_out(),
        .clk_pe(clk), .rst_n_pe(rst_n), .x_min_in(x), .y_min_in(y),
        .new_line_1(line_start), .out_char(ch), .out_valid(cv),
        .frame_start_out(fs), .frame_end_out(fe));
    task automatic coordinate(input int xx, input int yy);
        for(int row=0;row<20;row++) begin
            @(negedge clk); x=16'(xx); y=16'(yy); line_start=1;
            @(negedge clk); line_start=0;
        end
        repeat(3) @(negedge clk);
    endtask
    task automatic result(input int len, input int last=51);
        @(negedge clk); fs=1;
        @(negedge clk); fs=0;
        for(int i=0;i<len;i++) begin
            cv=1; ch=(i==len-1)?7'(last):7'(i+10);
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
    task automatic scan_known_plate;
        check_render=1;
        for(int row=0;row<202;row++) begin
            for(int col=0;col<450;col++) begin
                @(negedge vclk); de=1; raster_x=col; raster_y=row;
            end
            @(negedge vclk); de=0;
            repeat(6) @(negedge vclk);
        end
        check_render=0;
    endtask
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        coordinate(100,100); result(0);
        if(dut.coord_count!=0) $fatal(1,"blank result left a coordinate queued");
        coordinate(300,200); result(8);
        video_frame();
        if(dut.display_valid!=0) $fatal(1,"unconfirmed result became visible");
        if(diagnostic.display_valid!=1) $fatal(1,"one-frame hold/one-result confirmation failed");
        coordinate(300,200); result(8);
        if(dut.current_x_min!=300 || dut.current_y_min!=200) $fatal(1,"coordinate mismatch after blank");
        if(dut.display_valid!=0) $fatal(1,"display changed mid-frame");
        video_frame();
        if(dut.display_valid!=1 || dut.display_x[0]!=300 || dut.display_y[0]!=184 || dut.display_length[0]!=8)
            $fatal(1,"confirmed complete result not displayed");
        scan_known_plate();
        video_frame();
        if(dut.display_valid!=1) $fatal(1,"result was not retained across frames");
        if(diagnostic.display_valid!=0) $fatal(1,"one-frame result did not expire");
        coordinate(300,200); result(7,52);
        video_frame();
        if(dut.display_length[0]!=8) $fatal(1,"changed text skipped confirmation");
        coordinate(300,200); result(7,52);
        if(dut.display_length[0]!=8) $fatal(1,"mid-frame string length changed");
        video_frame();
        if(dut.display_length[0]!=7 || dut.display_text[0][6*7 +: 7]!=52 || dut.display_text[0][7*7 +: 7]!=0)
            $fatal(1,"shorter result left stale eighth character");
        // Invalid lengths and black flush crops are consumed but not displayed.
        coordinate(600,400); result(6);
        coordinate(600,400); result(9);
        coordinate(1280,720); result(8);
        video_frame();
        if($countones(dut.display_valid)!=1 || dut.coord_count!=0 || dut.dbg_coord_error)
            $fatal(1,"invalid/flush result corrupted display or coordinates");
        coordinate(1200,8); result(8);
        coordinate(1200,8); result(8);
        video_frame();
        if(!dut.display_valid[1] || dut.display_x[1]!=1152 || dut.display_y[1]!=0)
            $fatal(1,"screen-edge label clipping failed");
        repeat(6) video_frame();
        if(dut.display_valid!=0 || dut.pending_valid!=0) $fatal(1,"stale text did not expire");
        // Keep receiving different plausible strings at an old location:
        // this must not keep an unconfirmed old string visible indefinitely.
        coordinate(300,200); result(8); coordinate(300,200); result(8); video_frame();
        for(int i=0;i<7;i++) begin
            coordinate(300,200); result(8,52+(i%2)); video_frame();
        end
        if(dut.display_valid!=0) $fatal(1,"unstable new text kept stale confirmed text alive");
        if(dut.coord_count!=0 || dut.dbg_coord_error || dut.dbg_result_dropped) $fatal(1,"unexpected FIFO failure");
        coordinate(1100,100); result(20);
        video_frame();
        if(diagnostic.display_valid!=1 || diagnostic.display_length[0]!=20 || diagnostic.display_x[0]!=960)
            $fatal(1,"20-character diagnostic mode failed");
        for(int c=0;c<20;c++)
            if(diagnostic.display_text[0][c*7 +: 7] != ((c==19)?51:(c+10)))
                $fatal(1,"20-character packing/order mismatch at character %0d",c);
        if(dut.display_valid!=0) $fatal(1,"production mode accepted an overlength result");
        $display("PASS OSD: blank/flush association, confirmation, atomic VS update, 8-to-7 replacement, expiry, edge clipping");
        $finish;
    end
    initial begin #10000000; $fatal(1,"timeout"); end
endmodule
