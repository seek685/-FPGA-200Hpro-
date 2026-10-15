`timescale 1ns / 1ps

module tb_roi_label_overlay;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg video_vs = 0;
    reg video_hs = 0;
    reg video_de = 0;
    reg [23:0] video_rgb = 0;
    reg result_valid = 0;
    reg [1:0] result_class = 0;
    wire vs_out, hs_out, de_out;
    wire [23:0] rgb_out;
    wire clip_vs, clip_hs, clip_de;
    wire [23:0] clip_rgb;
    integer checked = 0;
    integer frame_number = 0;

    roi_label_overlay #(
        .ROI_X(8), .ROI_Y(20), .ROI_WIDTH(16), .ROI_HEIGHT(12),
        .VIDEO_WIDTH(88), .VIDEO_HEIGHT(40), .EXPIRE_FRAMES(4)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .video_vs(video_vs), .video_hs(video_hs), .video_de(video_de), .video_rgb(video_rgb),
        .result_valid(result_valid), .result_class(result_class),
        .video_vs_out(vs_out), .video_hs_out(hs_out), .video_de_out(de_out), .video_rgb_out(rgb_out)
    );

    // The text starts at y=-8; the box's right edge is beyond VIDEO_WIDTH.
    // No result is supplied to this instance, so its label remains WAIT.
    roi_label_overlay #(
        .ROI_X(84), .ROI_Y(8), .ROI_WIDTH(16), .ROI_HEIGHT(12),
        .VIDEO_WIDTH(88), .VIDEO_HEIGHT(40), .EXPIRE_FRAMES(4)
    ) clipped (
        .clk(clk), .rst_n(rst_n),
        .video_vs(video_vs), .video_hs(video_hs), .video_de(video_de), .video_rgb(video_rgb),
        .result_valid(1'b0), .result_class(2'd0),
        .video_vs_out(clip_vs), .video_hs_out(clip_hs), .video_de_out(clip_de), .video_rgb_out(clip_rgb)
    );

    task tick;
        input integer px;
        input integer py;
        input integer label_id;
        input vs;
        input hs;
        input de;
        input valid;
        input [1:0] class_id;
        reg [23:0] source_rgb;
        integer source_word;
        reg [23:0] expected;
        reg test_pixel;
        reg on_pixel;
        begin
            @(negedge clk);
            video_vs = vs;
            video_hs = hs;
            video_de = de;
            // Distinct non-overlay colors make a one-pixel RGB skew visible.
            source_word = 32'h00102030 + px * 257 + py * 65536;
            source_rgb = source_word[23:0];
            video_rgb = source_rgb;
            result_valid = valid;
            result_class = class_id;
            @(posedge clk);
            #1;
            if ({vs_out, hs_out, de_out} !== {vs, hs, de} ||
                {clip_vs, clip_hs, clip_de} !== {vs, hs, de})
                $fatal(1, "sync mismatch at (%0d,%0d)", px, py);

            expected = source_rgb;
            test_pixel = 1;
            on_pixel = 0;
            if (de && px >= 8 && px <= 23 && py >= 20 && py <= 31 &&
                (px == 8 || px == 23 || py == 20 || py == 31)) begin
                expected = 24'h00ff00;
            end else if (de && px >= 8 && px < 80 && py >= 4 && py < 18) begin
                // Probe known strokes, empty pixels, and both scale replicas.
                test_pixel = 0;
                if ((py == 4 || py == 5) && (px == 8 || px == 9)) begin
                    test_pixel = 1;
                    on_pixel = (label_id == 4 || label_id == 1);
                end
                if ((py == 4 || py == 5) && (px == 10 || px == 11)) begin
                    test_pixel = 1;
                    on_pixel = (label_id != 4);
                end
                if ((py == 4 || py == 5) && (px == 16 || px == 17)) begin
                    test_pixel = 1;
                    on_pixel = (label_id == 4);
                end
                if ((py == 10 || py == 11) && (px == 12 || px == 13)) begin
                    test_pixel = 1;
                    on_pixel = (label_id == 0 || label_id == 1 || label_id == 4);
                end
                if ((py == 4 || py == 5) && (px == 20 || px == 21)) begin
                    test_pixel = 1;
                    on_pixel = (label_id == 0 || label_id == 2 || label_id == 3);
                end
                if ((py == 6 || py == 7) && (px == 24 || px == 25)) begin
                    test_pixel = 1;
                    on_pixel = (label_id == 3);
                end
                if (px == 18 || px == 19) begin
                    test_pixel = 1;
                    on_pixel = 0;
                end
                // Sixth cell must be blank for APPLE, OTHER and WAIT.
                if (px >= 68 && label_id != 1 && label_id != 2) begin
                    test_pixel = 1;
                    on_pixel = 0;
                end
                if (on_pixel) expected = 24'hffff00;
            end
            if (test_pixel) begin
                checked = checked + 1;
                if (rgb_out !== expected)
                    $fatal(1, "frame %0d label %0d pixel (%0d,%0d): got %h expected %h",
                           frame_number, label_id, px, py, rgb_out, expected);
            end

            expected = source_rgb;
            test_pixel = 1;
            if (de && px >= 84 && px < 88 && py >= 8 && py <= 19 &&
                (px == 84 || py == 8 || py == 19)) begin
                expected = 24'h00ff00;
            end else if (de && px >= 84 && px < 88 && py < 6) begin
                // Visible bottom three rows of W after clipping at y=0.
                if ((py < 4 && px < 86) || (py >= 4 && px >= 86))
                    expected = 24'hffff00;
            end
            if (clip_rgb !== expected)
                $fatal(1, "clipped pixel (%0d,%0d): got %h expected %h", px, py, clip_rgb, expected);
        end
    endtask

    task frame;
        input integer label_id;
        input integer event_a;
        input [1:0] class_a;
        input integer event_b;
        input [1:0] class_b;
        integer x;
        integer y;
        integer sample;
        begin
            frame_number = frame_number + 1;
            tick(0, 0, label_id, 1, 1, 0, 0, 0);
            tick(0, 0, label_id, 0, 0, 0, 0, 0);
            // Active samples beyond the configured image test hard clipping.
            for (y = 0; y < 42; y = y + 1) begin
                for (x = 0; x < 90; x = x + 1) begin
                    sample = y * 90 + x;
                    tick(x, y, label_id, 0, 0, 1,
                         sample == event_a || sample == event_b,
                         sample == event_a ? class_a : class_b);
                end
                tick(0, y, label_id, 0, 1, 0, 0, 0);
                tick(0, y, label_id, 0, 0, 0, 0, 0);
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        // Results occur before the label rows: changing text immediately would
        // fail the WAIT probes in this same frame.
        frame(4, 91, 0, 92, 0);
        frame(0, -1, 0, -1, 0);
        frame(0, 91, 1, -1, 0); // only one BANANA: keep APPLE
        frame(0, 91, 2, -1, 0); // different result breaks the consecutive run
        frame(0, 91, 2, -1, 0); // second ORANGE, pending until next VS
        frame(2, 91, 1, 92, 1);
        frame(1, 91, 3, 92, 3);
        frame(3, -1, 0, -1, 0);
        frame(3, -1, 0, -1, 0); // age 1
        frame(3, -1, 0, -1, 0); // age 2
        frame(3, -1, 0, -1, 0); // age 3
        frame(4, -1, 0, -1, 0); // age 4: WAIT
        frame(4, 91, 3, -1, 0); // expired candidate also needs confirmation
        frame(4, 91, 3, -1, 0);
        frame(3, 91, 3, -1, 0); // already confirmed same-class result renews
        frame(3, -1, 0, -1, 0); // renewed, age 0
        frame(3, -1, 0, -1, 0);
        frame(3, -1, 0, -1, 0);
        frame(3, -1, 0, -1, 0);
        frame(4, -1, 0, -1, 0);
        $display("PASS tb_roi_label_overlay: %0d frames, %0d pixel checks", frame_number, checked);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "timeout");
    end
endmodule
