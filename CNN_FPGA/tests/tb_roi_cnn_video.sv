`timescale 1ns/1ps
// Run with cwd = CNN_FPGA/rtl_pds/roi_cnn. This test uses the real exported
// weights and all three production modules, with no DDR or original CNN IP.
module tb_roi_cnn_video;
    localparam integer H_TOTAL = 1650;
    localparam integer V_TOTAL = 750;
    localparam integer H_ACTIVE = 260; // HS 40 + back porch 220
    localparam integer V_ACTIVE = 25;  // VS 5 + back porch 20
    localparam integer ROI_X = 528;
    localparam integer ROI_Y = 248;
    reg clk = 0;
    always #6.734 clk = !clk; // 74.25 MHz, rounded to the 1 ps simulator grid
    reg rst_n = 0;
    reg video_vs = 0;
    reg video_hs = 0;
    reg video_de = 0;
    reg [23:0] video_rgb = 0;
    wire image_wr_en;
    wire [9:0] image_wr_addr;
    wire [23:0] image_wr_rgb;
    wire start;
    wire busy;
    wire done;
    wire [1:0] class_id;
    wire signed [31:0] score0, score1, score2, score3;
    wire video_vs_out, video_hs_out, video_de_out;
    wire [23:0] video_rgb_out;

    roi_capture_28 capture (
        .clk(clk), .rst_n(rst_n), .video_vs(video_vs), .video_de(video_de),
        .video_rgb(video_rgb), .core_busy(busy), .image_wr_en(image_wr_en),
        .image_wr_addr(image_wr_addr), .image_wr_rgb(image_wr_rgb), .start(start)
    );
    roi_cnn_core core (
        .clk(clk), .rst_n(rst_n), .image_wr_en(image_wr_en),
        .image_wr_addr(image_wr_addr), .image_wr_rgb(image_wr_rgb),
        .start(start), .busy(busy), .done(done), .class_id(class_id),
        .score0(score0), .score1(score1), .score2(score2), .score3(score3)
    );
    roi_label_overlay overlay (
        .clk(clk), .rst_n(rst_n), .video_vs(video_vs), .video_hs(video_hs),
        .video_de(video_de), .video_rgb(video_rgb), .result_valid(done),
        .result_class(class_id), .video_vs_out(video_vs_out),
        .video_hs_out(video_hs_out), .video_de_out(video_de_out),
        .video_rgb_out(video_rgb_out)
    );

    reg [23:0] fixture_images [0:6271];
    reg signed [31:0] fixture_logits [0:31];
    // Python integer_forward(np.full((1,3,28,28),255,uint8), integer_model).
    // Filled by the same independent reference used to export the fixtures.
    integer white_logits [0:3];
    integer frame_index = 0;
    integer monitor_frame_index = -1;
    integer drive_x = -1;
    integer drive_y = -1;
    integer cycle_count = 0;
    integer frame_writes = 0;
    integer frame_starts = 0;
    integer total_writes = 0;
    integer total_starts = 0;
    integer total_done = 0;
    integer skipped_frames = 0;
    integer skipped_idle_frames = 0;
    integer last_write_cycle = -1;
    integer inference_begin_cycle = -1;
    integer first_begin_cycle = -1;
    integer first_done_cycle = -1;
    integer confirmed_done_cycle = -1;
    integer label_cycle = -1;
    integer apple_text_pixels = 0;
    integer border_pixels = 0;
    integer passthrough_pixels = 0;
    integer expected_class;
    integer score_index;
    reg frame_open = 0;
    reg frame_eligible = 0;
    reg skipped_became_idle = 0;
    reg inference_white = 0;
    reg inference_open = 0;
    reg monitor_vs_d = 0;
    reg previous_start = 0;
    reg previous_done = 0;
    reg old_busy;
    reg old_display_valid;
    reg [1:0] old_display_class;
    reg frame_edge;
    reg [23:0] expected_rgb;
    reg [23:0] expected_sample;

    // Independent APPLE bitmap: seven 25-bit rows, five letters with five
    // columns each. The two blank pixels between 10-pixel glyphs are tested too.
    function automatic bit apple_pixel(input integer x, input integer y);
        reg [24:0] row_bits;
        integer column;
        integer glyph_cell;
        begin
            case (y / 2)
                0: row_bits = {5'b01110,5'b11110,5'b11110,5'b10000,5'b11111};
                1: row_bits = {5'b10001,5'b10001,5'b10001,5'b10000,5'b10000};
                2: row_bits = {5'b10001,5'b10001,5'b10001,5'b10000,5'b10000};
                3: row_bits = {5'b11111,5'b11110,5'b11110,5'b10000,5'b11110};
                4: row_bits = {5'b10001,5'b10000,5'b10000,5'b10000,5'b10000};
                5: row_bits = {5'b10001,5'b10000,5'b10000,5'b10000,5'b10000};
                6: row_bits = {5'b10001,5'b10000,5'b10000,5'b11111,5'b11111};
                default: row_bits = 0;
            endcase
            glyph_cell = x / 12;
            column = (x % 12) / 2;
            apple_pixel = glyph_cell < 5 && column < 5 && row_bits[24-glyph_cell*5-column];
        end
    endfunction

    task automatic check_finished_frame;
        begin
            if (frame_eligible) begin
                if (frame_writes != 784 || frame_starts != 1)
                    $fatal(1, "frame %0d: capture writes=%0d starts=%0d", monitor_frame_index,
                           frame_writes, frame_starts);
            end else begin
                if (frame_writes != 0 || frame_starts != 0)
                    $fatal(1, "busy-start frame wrote data after the core became idle");
                skipped_frames = skipped_frames + 1;
                if (skipped_became_idle)
                    skipped_idle_frames = skipped_idle_frames + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        old_busy = busy;
        old_display_valid = overlay.display_valid;
        old_display_class = overlay.display_class;
        frame_edge = video_vs && !monitor_vs_d;
        monitor_vs_d = video_vs;
        // An ordinary register output must contain this edge's input sample
        // after NBA, so all video sidebands and RGB are checked together.
        expected_rgb = video_rgb;
        if (video_de && drive_x >= ROI_X && drive_x < ROI_X + 224 &&
            drive_y >= ROI_Y && drive_y < ROI_Y + 224 &&
            (drive_x == ROI_X || drive_x == ROI_X + 223 ||
             drive_y == ROI_Y || drive_y == ROI_Y + 223))
            expected_rgb = 24'h00ff00;
        if (video_de && old_display_valid && old_display_class == 0 &&
            drive_x >= ROI_X && drive_x < ROI_X + 72 &&
            drive_y >= ROI_Y - 16 && drive_y < ROI_Y - 2 &&
            apple_pixel(drive_x - ROI_X, drive_y - (ROI_Y - 16)))
            expected_rgb = 24'hffff00;
        #1;
        cycle_count = cycle_count + 1;
        if (rst_n) begin
            if (frame_edge) begin
                if (frame_open) check_finished_frame();
                monitor_frame_index = frame_index;
                frame_open = 1;
                frame_eligible = !old_busy;
                frame_writes = 0;
                frame_starts = 0;
                skipped_became_idle = 0;
                $display("VIDEO frame=%0d eligible=%0d cycle=%0d", frame_index,
                         frame_eligible, cycle_count);
                if (total_done < 2 && overlay.display_valid)
                    $fatal(1, "label became visible before two matching results");
                if (total_done >= 2 && (!overlay.display_valid || overlay.display_class != 0))
                    $fatal(1, "confirmed APPLE was not committed at the next VS");
            end
            if (!frame_eligible && !busy) skipped_became_idle = 1;
            if (start && previous_start) $fatal(1, "start is not a one-cycle pulse");
            if (done && previous_done) $fatal(1, "done is not a one-cycle pulse");
            previous_start = start;
            previous_done = done;
            if (image_wr_en) begin
                if (!frame_eligible || old_busy || busy)
                    $fatal(1, "input write during busy/skipped frame");
                if (image_wr_addr !== frame_writes[9:0] || frame_writes >= 784)
                    $fatal(1, "capture address sequence mismatch");
                expected_sample = (frame_index >= 4) ? 24'hffffff : fixture_images[frame_writes];
                if (image_wr_rgb !== expected_sample)
                    $fatal(1, "frame=%0d pixel=%0d got=%h expected=%h", frame_index,
                           frame_writes, image_wr_rgb, expected_sample);
                frame_writes = frame_writes + 1;
                total_writes = total_writes + 1;
                last_write_cycle = cycle_count;
            end
            if (start) begin
                if (!frame_eligible || frame_writes != 784 || inference_open ||
                    image_wr_en || cycle_count - last_write_cycle < 2)
                    $fatal(1, "invalid capture-to-core launch");
                inference_white = frame_index >= 4;
                frame_starts = frame_starts + 1;
                total_starts = total_starts + 1;
            end
            if (busy && !old_busy) begin
                inference_open = 1;
                inference_begin_cycle = cycle_count;
                if (first_begin_cycle < 0) first_begin_cycle = cycle_count;
            end
            if (done) begin
                if (!inference_open || busy)
                    $fatal(1, "unexpected completion or busy retained on done");
                if (cycle_count - inference_begin_cycle != 634580)
                    $fatal(1, "unexpected inference cycles %0d", cycle_count - inference_begin_cycle);
                if (inference_white) begin
                    if (score0 !== white_logits[0] || score1 !== white_logits[1] ||
                        score2 !== white_logits[2] || score3 !== white_logits[3])
                        $fatal(1, "white logits mismatch: [%0d,%0d,%0d,%0d]", score0,score1,score2,score3);
                    expected_class = 0;
                    for (score_index = 1; score_index < 4; score_index = score_index + 1)
                        if (white_logits[score_index] > white_logits[expected_class])
                            expected_class = score_index;
                end else begin
                    if (score0 !== fixture_logits[0] || score1 !== fixture_logits[1] ||
                        score2 !== fixture_logits[2] || score3 !== fixture_logits[3])
                        $fatal(1, "APPLE logits mismatch: [%0d,%0d,%0d,%0d]", score0,score1,score2,score3);
                    expected_class = 0;
                end
                if ({30'd0,class_id} != expected_class) $fatal(1, "incorrect argmax");
                inference_open = 0;
                total_done = total_done + 1;
                if (total_done == 1) first_done_cycle = cycle_count;
                if (total_done == 2) confirmed_done_cycle = cycle_count;
                $display("VIDEO done=%0d white=%0d cycles=%0d class=%0d logits=[%0d,%0d,%0d,%0d]",
                         total_done, inference_white, cycle_count-inference_begin_cycle,
                         class_id,score0,score1,score2,score3);
            end
            if ((overlay.display_valid !== old_display_valid ||
                 overlay.display_class !== old_display_class) && !frame_edge)
                $fatal(1, "label changed outside VS");
            if (overlay.display_valid && !old_display_valid) begin
                if (total_done < 2 || overlay.display_class != 0)
                    $fatal(1, "APPLE shown before two matching results");
                label_cycle = cycle_count;
                $display("VIDEO APPLE display cycle=%0d after_first_start=%0d after_confirmed_done=%0d",
                         label_cycle, label_cycle-first_begin_cycle, label_cycle-confirmed_done_cycle);
            end
            if (video_vs_out !== video_vs || video_hs_out !== video_hs || video_de_out !== video_de)
                $fatal(1, "overlay video sidebands are misaligned");
            // Before confirmation, WAIT is covered by its separate module test.
            // Here check every other output pixel, plus the full APPLE bitmap.
            if (!video_de || drive_x < ROI_X || drive_x >= ROI_X + 72 ||
                drive_y < ROI_Y - 16 || drive_y >= ROI_Y - 2 || old_display_valid) begin
                if (video_rgb_out !== expected_rgb)
                    $fatal(1, "overlay frame=%0d x=%0d y=%0d got=%h expected=%h",
                           frame_index,drive_x,drive_y,video_rgb_out,expected_rgb);
                if (expected_rgb == 24'hffff00) apple_text_pixels = apple_text_pixels + 1;
                else if (expected_rgb == 24'h00ff00) border_pixels = border_pixels + 1;
                else passthrough_pixels = passthrough_pixels + 1;
            end
        end
    end

    integer v;
    integer h;
    integer fixture_address;
    initial begin
        $readmemh("../../tests/fixtures/roi_cnn/test_images_rgb.mem", fixture_images);
        $readmemh("../../tests/fixtures/roi_cnn/test_logits.mem", fixture_logits);
        // These constants are populated from the checked-in integer model.
        white_logits[0] = 5015;
        white_logits[1] = 5338;
        white_logits[2] = -31362;
        white_logits[3] = 9198;
        repeat (4) @(negedge clk);
        rst_n = 1;
        for (frame_index = 0; frame_index < 6; frame_index = frame_index + 1)
            for (v = 0; v < V_TOTAL; v = v + 1)
                for (h = 0; h < H_TOTAL; h = h + 1) begin
                    @(negedge clk);
                    video_vs = v < 5;
                    video_hs = h < 40;
                    drive_x = h - H_ACTIVE;
                    drive_y = v - V_ACTIVE;
                    video_de = drive_x >= 0 && drive_x < 1280 && drive_y >= 0 && drive_y < 720;
                    video_rgb = video_de ? 24'hffffff : 24'd0;
                    if (frame_index < 4 && video_de && drive_x >= ROI_X &&
                        drive_x < ROI_X + 224 && drive_y >= ROI_Y && drive_y < ROI_Y + 224) begin
                        fixture_address = ((drive_y - ROI_Y) / 8) * 28 + (drive_x - ROI_X) / 8;
                        video_rgb = fixture_images[fixture_address];
                    end
                    @(posedge clk);
                    #2;
                end
        check_finished_frame();
        if (total_starts != 3 || total_done != 3 || total_writes != 2352 || busy)
            $fatal(1, "unexpected aggregate starts=%0d done=%0d writes=%0d busy=%0d",
                   total_starts,total_done,total_writes,busy);
        if (skipped_frames != 3 || skipped_idle_frames != 3)
            $fatal(1, "busy-at-VS skip coverage missing");
        if (label_cycle < 0 || !overlay.display_valid || overlay.display_class != 0 ||
            apple_text_pixels == 0 || border_pixels == 0 || passthrough_pixels == 0)
            $fatal(1, "APPLE overlay coverage missing");
        $display("PASS tb_roi_cnn_video: 6 720p frames, 2352 exact RGB writes, 3 exact-logit inferences, 3 whole-frame busy skips, confirmed APPLE at VS");
        $display("LATENCY at 74.25MHz: inference=%0.6f ms; first done to display=%0.6f ms; confirmed done to display=%0.6f ms",
                 634580.0/74250.0, (label_cycle-first_done_cycle)/74250.0,
                 (label_cycle-confirmed_done_cycle)/74250.0);
        $finish;
    end
endmodule
