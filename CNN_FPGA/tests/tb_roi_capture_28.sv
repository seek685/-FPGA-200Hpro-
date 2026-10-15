`timescale 1ns/1ps
module tb_roi_capture_28;
    localparam integer ROI_X = 528;
    localparam integer ROI_Y = 248;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst_n = 0;
    reg video_vs = 0;
    reg video_de = 0;
    reg [23:0] video_rgb = 0;
    reg core_busy = 0;
    wire image_wr_en;
    wire [9:0] image_wr_addr;
    wire [23:0] image_wr_rgb;
    wire start;
    roi_capture_28 dut (
        .clk(clk), .rst_n(rst_n), .video_vs(video_vs),
        .video_de(video_de), .video_rgb(video_rgb), .core_busy(core_busy),
        .image_wr_en(image_wr_en), .image_wr_addr(image_wr_addr),
        .image_wr_rgb(image_wr_rgb), .start(start)
    );

    integer clock_count = 0;
    integer write_count = 0;
    integer start_count = 0;
    integer last_write_clock = -100;
    integer pattern = 0;
    reg check_pixels = 0;
    reg forbid_output = 0;
    reg previous_start = 0;
    integer bx;
    integer by;
    integer dx;
    integer dy;
    integer sr;
    integer sg;
    integer sb;
    reg [23:0] sample;
    reg [23:0] expected;

    function automatic [23:0] pixel_value(input integer x, input integer y,
                                           input integer mode);
        integer r;
        integer g;
        integer b;
        begin
            // Different channels and within-block gradients catch sampling,
            // channel-order, block-order and sum-width mistakes.
            if (mode == 0) begin
                r = (x * 3 + y * 5 + 7) % 256;
                g = (x * 11 + y * 2 + 31) % 256;
                b = (x * 7 + y * 13 + 193) % 256;
            end else if (mode == 1) begin
                r = 255;
                g = ((x / 8) * 9 + (y / 8) * 5) % 256;
                b = ((x % 8) + (y % 8) * 8) * 4;
            end else begin
                r = 0;
                g = 255;
                b = 255;
            end
            pixel_value = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction

    always @(posedge clk) begin
        #1;
        clock_count = clock_count + 1;
        if (rst_n) begin
            if (start && previous_start)
                $fatal(1, "start is not a single cycle pulse");
            previous_start = start;
            if (forbid_output && (image_wr_en || start))
                $fatal(1, "output occurred during a skipped frame");
            if (image_wr_en) begin
                if (core_busy) $fatal(1, "write while core is busy");
                if (check_pixels) begin
                    if (image_wr_addr != write_count[9:0])
                        $fatal(1, "address %0d expected %0d", image_wr_addr, write_count);
                    bx = write_count % 28;
                    by = write_count / 28;
                    sr = 0;
                    sg = 0;
                    sb = 0;
                    for (dy = 0; dy < 8; dy = dy + 1)
                        for (dx = 0; dx < 8; dx = dx + 1) begin
                            sample = pixel_value(bx * 8 + dx, by * 8 + dy, pattern);
                            sr = sr + {24'd0, sample[23:16]};
                            sg = sg + {24'd0, sample[15:8]};
                            sb = sb + {24'd0, sample[7:0]};
                        end
                    expected = {8'(sr / 64), 8'(sg / 64), 8'(sb / 64)};
                    if (image_wr_rgb !== expected)
                        $fatal(1, "pixel %0d got %h expected %h", write_count,
                               image_wr_rgb, expected);
                end
                write_count = write_count + 1;
                last_write_clock = clock_count;
            end
            if (start) begin
                if (image_wr_en || clock_count - last_write_clock < 2)
                    $fatal(1, "start overlaps final write or lacks an idle cycle");
                if (write_count != 784)
                    $fatal(1, "start with %0d writes", write_count);
                start_count = start_count + 1;
            end
        end else begin
            previous_start = 0;
        end
    end

    task automatic tick(input bit vs, input bit de, input [23:0] rgb);
        begin
            @(negedge clk);
            video_vs = vs;
            video_de = de;
            video_rgb = rgb;
            @(posedge clk);
            #2;
        end
    endtask

    task automatic new_frame(input bit busy_at_start);
        begin
            core_busy = busy_at_start;
            tick(0, 0, 0);
            tick(1, 0, 0);
            tick(1, 0, 0);
            tick(0, 0, 0);
            write_count = 0;
        end
    endtask

    task automatic send_lines(input integer first_y, input integer stop_y,
                               input integer short_y, input integer short_width);
        integer x;
        integer y;
        integer width;
        reg [23:0] rgb;
        begin
            for (y = first_y; y < stop_y; y = y + 1) begin
                width = (y == short_y) ? short_width : 1280;
                for (x = 0; x < width; x = x + 1) begin
                    if (x >= ROI_X && x < ROI_X + 224 &&
                        y >= ROI_Y && y < ROI_Y + 224)
                        rgb = pixel_value(x - ROI_X, y - ROI_Y, pattern);
                    else
                        rgb = 24'hbd31ef;
                    tick(0, 1, rgb);
                end
                tick(0, 0, 0);
                tick(0, 0, 0);
            end
        end
    endtask

    integer starts_before;
    integer last_row_x;
    initial begin
        repeat (3) tick(0, 0, 0);
        rst_n = 1;

        // Full 720p frame: independently average all 64 pixels of each block.
        check_pixels = 1;
        pattern = 0;
        new_frame(0);
        send_lines(0, 720, -1, 0);
        if (write_count != 784 || start_count != 1)
            $fatal(1, "first complete frame did not start exactly once");

        // The core finishes before the ROI, but the busy-start frame must skip.
        check_pixels = 0;
        forbid_output = 1;
        new_frame(1);
        send_lines(0, 10, -1, 0);
        core_busy = 0;
        send_lines(10, 720, -1, 0);
        if (write_count != 0 || start_count != 1)
            $fatal(1, "busy-start frame was not entirely skipped");
        forbid_output = 0;

        // An abnormal VS edge during active pixels cannot establish a frame
        // origin. Even a full ROI later in this frame must remain skipped.
        forbid_output = 1;
        starts_before = start_count;
        tick(0, 0, 0);
        tick(1, 1, 24'hbadbad);
        tick(0, 1, 24'hbadbad);
        tick(0, 0, 0);
        write_count = 0;
        send_lines(1, 720, -1, 0);
        if (write_count != 0 || start_count != starts_before)
            $fatal(1, "active-video VS did not skip the entire frame");
        forbid_output = 0;

        // Mid-ROI VS cancels the partial frame. The next image must not mix it.
        new_frame(0);
        send_lines(0, ROI_Y + 17, -1, 0);
        starts_before = start_count;
        pattern = 1;
        new_frame(0);
        check_pixels = 1;
        send_lines(0, 720, -1, 0);
        if (write_count != 784 || start_count != starts_before + 1)
            $fatal(1, "interrupted frame was started or recovery failed");

        // A shortened line misses ROI pixels but still reaches bottom-right.
        // This must fail the full-ROI pixel count rather than start stale data.
        check_pixels = 0;
        new_frame(0);
        starts_before = start_count;
        send_lines(0, 720, ROI_Y + 2, ROI_X + 100);
        if (start_count != starts_before)
            $fatal(1, "short ROI line caused a start");

        // A new VS arriving immediately after the last ROI write must cancel
        // the pending start, not launch the old image in the new frame.
        new_frame(0);
        send_lines(0, ROI_Y + 223, -1, 0);
        for (last_row_x = 0; last_row_x < ROI_X + 224;
             last_row_x = last_row_x + 1) begin
            if (last_row_x >= ROI_X)
                tick(0, 1, pixel_value(last_row_x - ROI_X, 223, pattern));
            else
                tick(0, 1, 24'hbd31ef);
        end
        if (!image_wr_en || write_count != 784)
            $fatal(1, "final write setup failed");
        tick(1, 0, 0);
        repeat (5) tick(0, 0, 0);
        if (start_count != starts_before)
            $fatal(1, "new VS did not cancel pending start");

        // Reset during acquisition must cancel the partial image.
        new_frame(0);
        send_lines(0, ROI_Y + 16, -1, 0);
        rst_n = 0;
        tick(0, 0, 0);
        rst_n = 1;
        repeat (5) tick(0, 0, 0);
        if (start_count != starts_before)
            $fatal(1, "reset partial image caused a start");

        // Reset recovery and maximum 64*255 channel sums.
        pattern = 2;
        check_pixels = 1;
        new_frame(0);
        send_lines(0, 720, -1, 0);
        if (write_count != 784 || start_count != starts_before + 1)
            $fatal(1, "reset recovery failed");

        $display("PASS tb_roi_capture_28: 8x8 RGB means, ordering, busy skip, active-video VS skip, truncated ROI, reset, start gap");
        $finish;
    end
endmodule
