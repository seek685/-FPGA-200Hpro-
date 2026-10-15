// Capture a fixed 224x224 RGB ROI and reduce each 8x8 block to one pixel.
// Pixel coordinates are zero based. VS rising starts a frame; DE falling
// advances the line. All ports use the incoming video pixel clock.
`timescale 1ns/1ps
module roi_capture_28 #(
    parameter integer ROI_X = 528,
    parameter integer ROI_Y = 248
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        video_vs,
    input  wire        video_de,
    input  wire [23:0] video_rgb,
    input  wire        core_busy,
    output reg         image_wr_en,
    output reg  [9:0]  image_wr_addr,
    output reg  [23:0] image_wr_rgb,
    output reg         start
);
    reg vs_d;
    reg de_d;
    reg [11:0] pixel_x;
    reg [11:0] pixel_y;
    reg capture_active;
    reg [15:0] roi_pixel_count;
    reg [9:0] write_count;
    reg [1:0] start_pending;
    localparam [11:0] ROI_LEFT = ROI_X[11:0];
    localparam [11:0] ROI_TOP = ROI_Y[11:0];
    localparam [11:0] ROI_RIGHT = ROI_LEFT + 12'd224;
    localparam [11:0] ROI_BOTTOM = ROI_TOP + 12'd224;

    // Only 28 partial blocks are stored. A new group of eight rows replaces
    // every accumulator before use, so these arrays need no reset network.
    reg [13:0] red_sum   [0:27];
    reg [13:0] green_sum [0:27];
    reg [13:0] blue_sum  [0:27];

    wire vs_rise = video_vs && !vs_d;
    wire inside_roi = video_de &&
                      (pixel_x >= ROI_LEFT) && (pixel_x < ROI_RIGHT) &&
                      (pixel_y >= ROI_TOP) && (pixel_y < ROI_BOTTOM);
    wire [11:0] roi_dx = pixel_x - ROI_LEFT;
    wire [11:0] roi_dy = pixel_y - ROI_TOP;
    wire [4:0] block_col = inside_roi ? roi_dx[7:3] : 5'd0;
    wire [13:0] red_total = red_sum[block_col] + {6'd0, video_rgb[23:16]};
    wire [13:0] green_total = green_sum[block_col] + {6'd0, video_rgb[15:8]};
    wire [13:0] blue_total = blue_sum[block_col] + {6'd0, video_rgb[7:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d <= 1'b0;
            de_d <= 1'b0;
            pixel_x <= 12'd0;
            pixel_y <= 12'd0;
            capture_active <= 1'b0;
            roi_pixel_count <= 16'd0;
            write_count <= 10'd0;
            start_pending <= 2'd0;
            image_wr_en <= 1'b0;
            image_wr_addr <= 10'd0;
            image_wr_rgb <= 24'd0;
            start <= 1'b0;
        end else begin
            vs_d <= video_vs;
            de_d <= video_de;
            image_wr_en <= 1'b0;
            start <= 1'b0;

            if (vs_rise) begin
                pixel_x <= 12'd0;
                pixel_y <= 12'd0;
                // Busy at frame start means skip this entire frame, even if
                // the core becomes idle before the ROI enters the video.
                // VS during active video has no reliable pixel origin. Skip
                // that malformed frame and wait for a clean blanking VS.
                capture_active <= !core_busy && !video_de;
                roi_pixel_count <= 16'd0;
                write_count <= 10'd0;
                start_pending <= 2'd0;
            end else begin
                if (video_de)
                    pixel_x <= pixel_x + 12'd1;
                else if (de_d) begin
                    pixel_x <= 12'd0;
                    pixel_y <= pixel_y + 12'd1;
                end

                if (core_busy) begin
                    // Never overwrite the core's input while it is running.
                    capture_active <= 1'b0;
                    start_pending <= 2'd0;
                end else begin
                    // The final write is followed by a full idle cycle.
                    // A new VS or reset cancels a pending inference start.
                    if (start_pending == 2'd1)
                        start_pending <= 2'd2;
                    else if (start_pending == 2'd2) begin
                        start <= 1'b1;
                        start_pending <= 2'd0;
                    end

                    if (capture_active && inside_roi) begin
                        roi_pixel_count <= roi_pixel_count + 16'd1;
                        if ((roi_dy[2:0] == 3'd0) &&
                            (roi_dx[2:0] == 3'd0)) begin
                            red_sum[block_col] <= {6'd0, video_rgb[23:16]};
                            green_sum[block_col] <= {6'd0, video_rgb[15:8]};
                            blue_sum[block_col] <= {6'd0, video_rgb[7:0]};
                        end else begin
                            red_sum[block_col] <= red_total;
                            green_sum[block_col] <= green_total;
                            blue_sum[block_col] <= blue_total;
                        end

                        if ((roi_dy[2:0] == 3'd7) &&
                            (roi_dx[2:0] == 3'd7)) begin
                            image_wr_en <= 1'b1;
                            image_wr_addr <= write_count;
                            // 64 * 255 = 16320, so all three sums fit 14 bits.
                            image_wr_rgb <= {red_total[13:6],
                                             green_total[13:6],
                                             blue_total[13:6]};
                            write_count <= write_count + 10'd1;
                        end

                        if ((roi_dx == 12'd223) && (roi_dy == 12'd223)) begin
                            capture_active <= 1'b0;
                            // Reject a short or interrupted ROI, even if its
                            // bottom-right pixel eventually arrives.
                            if (roi_pixel_count == 16'd50175)
                                start_pending <= 2'd1;
                        end
                    end
                end
            end
        end
    end
endmodule
