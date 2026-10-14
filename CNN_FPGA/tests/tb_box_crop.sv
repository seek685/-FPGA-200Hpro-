`timescale 1ns/1ps
module tb_box_crop;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic vs=0, de=0, wr=0;
    logic [31:0] wd=0;
    logic [23:0] rgb=0;
    wire vo, ho, deo;
    wire [23:0] ro;
    wire [5:0] start_crop, end_crop, crop_en;
    wire [5:0][15:0] crop_x,crop_y;
    wire [5:0][23:0] crop_rgb;
    integer pixels=0, ends=0;
    integer origin_x=0, origin_y=0, source_w=80, source_h=20;
    logic check_pixels=0;
    logic vs_d=0, de_d=0;
    logic [23:0] rgb_d=0;
    box_overlay_sync #(.IMG_WIDTH(1280), .IMG_HEIGHT(720), .CROP_WIDTH(80),
        .CROP_HEIGHT(20), .MAX_BOX_NUM(6), .GRID_STRIDE_CENTER(16), .GRID_STRIDE_LTRB(2)) dut(
        .clk_video(clk), .clk_pe(clk), .rst_n(rst_n), .video_vs_in(vs), .video_hs_in(1'b0),
        .video_de_in(de), .video_rgb_in(rgb), .video_vs_out(vo), .video_hs_out(ho),
        .video_de_out(deo), .video_rgb_out(ro), .box_wr_en(wr), .box_wr_data(wd),
        .start_crop_wr(start_crop), .end_crop_wr(end_crop), .crop_x_min(crop_x),
        .crop_y_min(crop_y), .crop_wr_en(crop_en), .crop_rgb_out(crop_rgb));

    // Independent fixed-point reference, evaluated for EVERY emitted pixel.
    // Input image R=x mod 256, G=0, B=y mod 256 also tests wrap interpolation.
    function automatic int expected_axis(input int origin, input int size, input int dest, input int pos);
        int step_fp, start_fp, fp, a, b, fraction;
        step_fp=(size*256)/dest;
        start_fp=(step_fp>256)?((step_fp/2)-128):0;
        fp=start_fp+pos*step_fp;
        a=(origin+(fp/256))%256;
        b=(a+1)%256;
        fraction=fp%256;
        return (a*(256-fraction)+b*fraction+128)/256;
    endfunction
    always @(posedge clk) if(rst_n && check_pixels) begin
        if(crop_en[0]) begin
            if(pixels>=1600) $fatal(1,"too many crop pixels");
            if(int'(crop_rgb[0][23:16])!=expected_axis(origin_x,source_w,80,pixels%80) ||
               int'(crop_rgb[0][7:0])!=expected_axis(origin_y,source_h,20,pixels/80))
                $fatal(1,"crop mismatch pixel=%0d rgb=%h expected R=%0d B=%0d", pixels,crop_rgb[0],
                    expected_axis(origin_x,source_w,80,pixels%80),expected_axis(origin_y,source_h,20,pixels/80));
            pixels++;
        end
        if(end_crop[0]) begin
            ends++;
            if(!crop_en[0] || pixels!=1600) $fatal(1,"crop end is not aligned with the last pixel");
        end
    end
    // The box/background overlay must preserve DE/VS and unmodified pixels
    // with the same two-register latency as the box hit decision.
    always @(posedge clk) begin
        if(rst_n) begin
            #1;
            if(vo!==vs_d || deo!==de_d) $fatal(1,"box video sync latency mismatch");
            if(!de_d && ro!==rgb_d) $fatal(1,"blanking background latency mismatch");
        end
        vs_d=vs; de_d=de; rgb_d=rgb;
    end
    task automatic reset_dut;
        @(negedge clk); rst_n=0; vs=0; de=0; wr=0; rgb=0; check_pixels=0;
        repeat(5) @(negedge clk);
        rst_n=1; pixels=0; ends=0;
    endtask
    task automatic word(input logic [31:0] v);
        @(negedge clk); wr=1; wd=v;
        @(negedge clk); wr=0;
    endtask
    task automatic packet(input int ix, input int iy, input int l, input int t,
                          input int r, input int b, input int score=200, input int cls=0);
        word({8'(cls),8'(ix),8'(iy),8'(score)});
        word(32'(l)); word(32'(t)); word(32'(r)); word(32'(b));
    endtask
    task automatic video(input int rows);
        @(negedge clk); vs=1;
        @(negedge clk); vs=0;
        for(int y=0;y<rows;y++) begin
            for(int x=0;x<1280;x++) begin
                @(negedge clk); de=1; rgb={8'(x),8'd0,8'(y)};
            end
            @(negedge clk); de=0;
            repeat(12) @(negedge clk);
        end
    endtask
    task automatic check_crop;
        if(pixels!=1600 || ends!=1) $fatal(1,"incomplete crop: pixels=%0d ends=%0d",pixels,ends);
    endtask
    initial begin
        reset_dut();
        packet(10,10,15,0,15,5,150,0);
        packet(10,10,15,0,15,5,220,2);
        packet(10,10,15,0,15,5,180,1);
        packet(30,10,15,0,15,5,200,0);
        repeat(120) @(negedge clk);
        if($countones(dut.box_valid)!=2 || dut.box_conf[0]!=220 || dut.box_cls[0]!=2)
            $fatal(1,"overlap suppression, score replacement, or distinct-box retention failed");
        origin_x=128; origin_y=163; source_w=80; source_h=20; check_pixels=1;
        fork
            video(210);
            begin
                wait(start_crop[0]);
                packet(10,10,15,0,15,5,250,0);
            end
        join
        check_crop();
        if(dut.box_conf[0]!=220) $fatal(1,"an active crop was replaced");

        reset_dut();
        packet(10,10,15,10,25,10);
        repeat(80) @(negedge clk);
        origin_x=128; origin_y=143; source_w=100; source_h=50; check_pixels=1;
        video(210); check_crop();

        reset_dut();
        packet(79,44,32,8,32,8);
        repeat(80) @(negedge clk);
        origin_x=1198; origin_y=691; source_w=80; source_h=27; check_pixels=1;
        video(720); check_crop();

        reset_dut();
        // Negative source coordinates must stay signed until clamping.
        packet(0,0,20,10,30,10);
        repeat(80) @(negedge clk);
        if(dut.box_xmin[0]!=1 || dut.box_ymin[0]!=1 ||
           dut.box_xmax[0]!=81 || dut.box_ymax[0]!=33)
            $fatal(1,"negative top/left coordinates did not clamp correctly");
        origin_x=1; origin_y=1; source_w=80; source_h=32; check_pixels=1;
        video(50); check_crop();

        reset_dut();
        // Reject reversed geometry, entirely off-screen, and padding classes.
        packet(10,10,-20,0,-20,5); packet(200,200,15,0,15,5); packet(10,10,15,0,15,5,200,7);
        repeat(100) @(negedge clk);
        if(dut.box_valid!=0) $fatal(1,"invalid candidate accepted");
        for(int i=0;i<6;i++) begin
            packet(5+i*12,10,15,0,15,5,220);
            repeat(30) @(negedge clk);
        end
        for(int i=0;i<220;i++) packet(5,10,15,0,15,5,180);
        repeat(6000) @(negedge clk);
        if($countones(dut.box_valid)!=6 || !dut.fifo_empty || dut.dbg_box_packets_dropped==0)
            $fatal(1,"full-slot FIFO stress did not drain/drop whole packets");
        for(int i=0;i<6;i++)
            if(dut.box_xmin[i]!=(48+i*192) || dut.box_ymin[i]!=163 || dut.box_conf[i]!=220)
                $fatal(1,"packet boundaries corrupted under overflow");
        $display("PASS boxes/crops: NMS, crop lock, 1:1 and bilinear pixels, edge clipping, video latency, packet overflow");
        $finish;
    end
    initial begin #30000000; $fatal(1,"timeout"); end
endmodule
