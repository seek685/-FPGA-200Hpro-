`timescale 1ns / 1ps

// Single-clock, one-cycle video overlay. result_valid/result_class must already
// be synchronous to clk. Input active-video coordinates start at (0, 0).
module roi_label_overlay #(
    parameter integer ROI_X = 528,
    parameter integer ROI_Y = 248,
    parameter integer ROI_WIDTH = 224,
    parameter integer ROI_HEIGHT = 224,
    parameter integer VIDEO_WIDTH = 1280,
    parameter integer VIDEO_HEIGHT = 720,
    parameter integer EXPIRE_FRAMES = 30,
    parameter [23:0] BORDER_COLOR = 24'h00ff00,
    parameter [23:0] TEXT_COLOR = 24'hffff00
)(
    input wire clk,
    input wire rst_n,
    input wire video_vs,
    input wire video_hs,
    input wire video_de,
    input wire [23:0] video_rgb,
    input wire result_valid,
    input wire [1:0] result_class,
    output reg video_vs_out,
    output reg video_hs_out,
    output reg video_de_out,
    output reg [23:0] video_rgb_out
);
    localparam integer AGE_LIMIT = (EXPIRE_FRAMES < 1) ? 1 : EXPIRE_FRAMES;
    localparam integer AGE_WIDTH = (AGE_LIMIT <= 1) ? 1 : $clog2(AGE_LIMIT);
    localparam integer AGE_LAST = AGE_LIMIT - 1;
    localparam integer TEXT_Y = ROI_Y - 16;

    reg vs_prev;
    reg de_prev;
    reg [15:0] x_pos;
    reg [15:0] y_pos;
    wire frame_start = video_vs && !vs_prev;

    reg candidate_valid;
    reg [1:0] candidate_class;
    reg pending_dirty;
    reg [1:0] pending_class;
    reg display_valid;
    reg [1:0] display_class;
    reg [AGE_WIDTH-1:0] age_frames;

    // A changed class needs two consecutive results. Every further matching
    // result renews it. Only confirmed results renew the displayed label's age.
    // A result on the VS rising edge is queued for the following VS edge.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            candidate_valid <= 1'b0;
            candidate_class <= 2'd0;
            pending_dirty <= 1'b0;
            pending_class <= 2'd0;
            display_valid <= 1'b0;
            display_class <= 2'd0;
            age_frames <= 0;
        end else begin
            if (frame_start) begin
                if (pending_dirty) begin
                    display_class <= pending_class;
                    display_valid <= 1'b1;
                    pending_dirty <= 1'b0;
                    age_frames <= 0;
                end else if (display_valid) begin
                    if (age_frames >= AGE_LAST[AGE_WIDTH-1:0]) begin
                        display_valid <= 1'b0;
                        age_frames <= 0;
                        candidate_valid <= 1'b0;
                    end else begin
                        age_frames <= age_frames + 1'b1;
                    end
                end
            end

            // This block follows the VS handling so a coincident new result
            // cannot be lost when an older pending result is displayed.
            if (result_valid) begin
                candidate_valid <= 1'b1;
                candidate_class <= result_class;
                if (candidate_valid && result_class == candidate_class) begin
                    pending_class <= result_class;
                    pending_dirty <= 1'b1;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_prev <= 1'b0;
            de_prev <= 1'b0;
            x_pos <= 0;
            y_pos <= 0;
        end else begin
            vs_prev <= video_vs;
            de_prev <= video_de;
            if (frame_start) begin
                x_pos <= 0;
                y_pos <= 0;
            end else if (video_de) begin
                x_pos <= x_pos + 1'b1;
            end else begin
                x_pos <= 0;
                if (de_prev)
                    y_pos <= y_pos + 1'b1;
            end
        end
    end

    // 0..3 are classes; 4 is WAIT. A sixth cell is blank for short names.
    function [7:0] label_char;
        input [2:0] label_id;
        input [2:0] char_index;
        begin
            label_char = " ";
            case (label_id)
                3'd0: case (char_index)
                    0: label_char = "A"; 1: label_char = "P";
                    2: label_char = "P"; 3: label_char = "L";
                    4: label_char = "E";
                    default: label_char = " ";
                endcase
                3'd1: case (char_index)
                    0: label_char = "B"; 1: label_char = "A";
                    2: label_char = "N"; 3: label_char = "A";
                    4: label_char = "N"; 5: label_char = "A";
                    default: label_char = " ";
                endcase
                3'd2: case (char_index)
                    0: label_char = "O"; 1: label_char = "R";
                    2: label_char = "A"; 3: label_char = "N";
                    4: label_char = "G"; 5: label_char = "E";
                    default: label_char = " ";
                endcase
                3'd3: case (char_index)
                    0: label_char = "O"; 1: label_char = "T";
                    2: label_char = "H"; 3: label_char = "E";
                    4: label_char = "R";
                    default: label_char = " ";
                endcase
                default: case (char_index)
                    0: label_char = "W"; 1: label_char = "A";
                    2: label_char = "I"; 3: label_char = "T";
                    default: label_char = " ";
                endcase
            endcase
        end
    endfunction

    // Each constant lists seven rows from top to bottom, five pixels per row.
    function [34:0] glyph;
        input [7:0] letter;
        begin
            case (letter)
                "A": glyph = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "B": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "E": glyph = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "G": glyph = {5'b01110,5'b10001,5'b10000,5'b10111,5'b10001,5'b10001,5'b01110};
                "H": glyph = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "I": glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
                "L": glyph = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "N": glyph = {5'b10001,5'b11001,5'b11001,5'b10101,5'b10011,5'b10011,5'b10001};
                "O": glyph = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "P": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "R": glyph = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "T": glyph = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "W": glyph = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                default: glyph = 35'd0;
            endcase
        end
    endfunction

    integer pixel_x;
    integer pixel_y;
    integer text_dx;
    integer text_dy;
    integer glyph_col;
    reg [2:0] char_index;
    reg [2:0] glyph_row_index;
    reg [34:0] glyph_bits;
    reg [4:0] glyph_row;
    reg border_hit;
    reg text_hit;
    reg [23:0] pixel_rgb;

    always @* begin
        // Signed integer intermediates preserve clipping when the text origin
        // or a parameterized ROI starts above/left of the visible image.
        pixel_x = {16'd0, x_pos};
        pixel_y = {16'd0, y_pos};
        text_dx = pixel_x - ROI_X;
        text_dy = pixel_y - TEXT_Y;
        glyph_col = 0;
        char_index = 0;
        glyph_row_index = 0;
        glyph_bits = 35'd0;
        glyph_row = 5'd0;
        border_hit = 1'b0;
        text_hit = 1'b0;
        pixel_rgb = video_rgb;

        if (video_de && pixel_x < VIDEO_WIDTH && pixel_y < VIDEO_HEIGHT) begin
            if (ROI_WIDTH > 0 && ROI_HEIGHT > 0 &&
                pixel_x >= ROI_X && pixel_x < ROI_X + ROI_WIDTH &&
                pixel_y >= ROI_Y && pixel_y < ROI_Y + ROI_HEIGHT) begin
                border_hit = (pixel_x == ROI_X) ||
                             (pixel_x == ROI_X + ROI_WIDTH - 1) ||
                             (pixel_y == ROI_Y) ||
                             (pixel_y == ROI_Y + ROI_HEIGHT - 1);
            end

            // Six 12-pixel cells: 10 pixels of glyph and 2 transparent pixels.
            if (text_dx >= 0 && text_dx < 72 && text_dy >= 0 && text_dy < 14) begin
                // Fixed cell comparisons avoid a general division/modulo by
                // twelve on the video clock path.
                if (text_dx >= 60) begin
                    char_index = 3'd5;
                    glyph_col = (text_dx - 60) / 2;
                end else if (text_dx >= 48) begin
                    char_index = 3'd4;
                    glyph_col = (text_dx - 48) / 2;
                end else if (text_dx >= 36) begin
                    char_index = 3'd3;
                    glyph_col = (text_dx - 36) / 2;
                end else if (text_dx >= 24) begin
                    char_index = 3'd2;
                    glyph_col = (text_dx - 24) / 2;
                end else if (text_dx >= 12) begin
                    char_index = 3'd1;
                    glyph_col = (text_dx - 12) / 2;
                end else begin
                    char_index = 3'd0;
                    glyph_col = text_dx / 2;
                end
                glyph_row_index = text_dy[3:1];
                glyph_bits = glyph(label_char(display_valid ? {1'b0, display_class} : 3'd4,
                                              char_index));
                // Constant slices avoid multidimensional packed-array access
                // and variable-width ranges in the PDS ADS parser.
                case (glyph_row_index)
                    0: glyph_row = glyph_bits[34:30];
                    1: glyph_row = glyph_bits[29:25];
                    2: glyph_row = glyph_bits[24:20];
                    3: glyph_row = glyph_bits[19:15];
                    4: glyph_row = glyph_bits[14:10];
                    5: glyph_row = glyph_bits[9:5];
                    6: glyph_row = glyph_bits[4:0];
                    default: glyph_row = 5'd0;
                endcase
                if (glyph_col < 5)
                    text_hit = glyph_row[4-glyph_col];
            end
            if (border_hit)
                pixel_rgb = BORDER_COLOR;
            if (text_hit)
                pixel_rgb = TEXT_COLOR;
        end
    end

    // All video signals have the same single-register latency, including RGB
    // during blanking and unpainted background pixels.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            video_vs_out <= 1'b0;
            video_hs_out <= 1'b0;
            video_de_out <= 1'b0;
            video_rgb_out <= 24'd0;
        end else begin
            video_vs_out <= video_vs;
            video_hs_out <= video_hs;
            video_de_out <= video_de;
            video_rgb_out <= pixel_rgb;
        end
    end
endmodule
