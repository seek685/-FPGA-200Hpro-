`timescale 1ns / 1ps

module char_overlay #(
    parameter CROP_HEIGHT = 128,
    parameter CHAR_NUM = 76,
    parameter FONT_FILE = "chars_16x16.mem",
    parameter IMG_WIDTH = 1280,
    parameter IMG_HEIGHT = 720,
    parameter MAX_PLATES = 6,
    parameter MAX_PLATE_CHARS = 8,
    parameter MIN_PLATE_CHARS = 7,
    parameter HOLD_FRAMES = 6,
    parameter CONFIRM_RESULTS = 2,
    parameter MATCH_DISTANCE = 24
)(
    input logic clk_video, rst_n_video,
    input logic video_vs_in, video_hs_in, video_de_in,
    input logic [23:0] video_rgb_in,
    output logic video_vs_out, video_hs_out, video_de_out,
    output logic [23:0] video_rgb_out,
    input logic clk_pe, rst_n_pe,
    input logic [15:0] x_min_in, y_min_in,
    input logic new_line_1,
    input logic [6:0] out_char,
    input logic out_valid, frame_start_out, frame_end_out
);
    localparam LEN_WIDTH = $clog2(MAX_PLATE_CHARS + 1);
    localparam TEXT_WIDTH = MAX_PLATE_CHARS * 7;
    localparam PACKET_WIDTH = TEXT_WIDTH + LEN_WIDTH + 32;
    localparam AGE_WIDTH = (HOLD_FRAMES > 1) ? $clog2(HOLD_FRAMES + 1) : 1;
    localparam CONFIRM_WIDTH = (CONFIRM_RESULTS > 1) ? $clog2(CONFIRM_RESULTS + 1) : 1;

    // One coordinate per input crop. Output crop boundaries are unconditional,
    // so even a blank crop consumes its entry. Never wrap a full coordinate FIFO.
    logic [15:0] line_cnt;
    logic [31:0] coord_fifo [0:31];
    logic [4:0] coord_wr_ptr, coord_rd_ptr;
    logic [5:0] coord_count;
    logic dbg_coord_error /* synthesis syn_preserve=1 */;
    wire coord_push_req = new_line_1 && (line_cnt == 0);
    wire coord_pop = frame_start_out && (coord_count != 0);
    wire coord_push = coord_push_req && ((coord_count < 32) || coord_pop);
    wire [31:0] coord_head = coord_fifo[coord_rd_ptr];

    always_ff @(posedge clk_pe or negedge rst_n_pe) begin
        if (!rst_n_pe) begin
            line_cnt <= 0;
            coord_wr_ptr <= 0;
            coord_rd_ptr <= 0;
            coord_count <= 0;
            dbg_coord_error <= 0;
        end else begin
            if (new_line_1) begin
                if (line_cnt == CROP_HEIGHT - 1) line_cnt <= 0;
                else line_cnt <= line_cnt + 1'b1;
            end
            if (coord_push) begin
                coord_fifo[coord_wr_ptr] <= {x_min_in, y_min_in};
                coord_wr_ptr <= coord_wr_ptr + 1'b1;
            end
            if (coord_pop) coord_rd_ptr <= coord_rd_ptr + 1'b1;
            case ({coord_push, coord_pop})
                2'b10: coord_count <= coord_count + 1'b1;
                2'b01: coord_count <= coord_count - 1'b1;
                default: ;
            endcase
            // If association is lost, fail closed until reset, rather than
            // silently attach all subsequent recognitions to the wrong plate.
            if ((coord_push_req && !coord_push) || (frame_start_out && !coord_pop))
                dbg_coord_error <= 1'b1;
        end
    end

    logic [15:0] current_x_min, current_y_min;
    // Keep character storage flat: ADS rejects runtime selection of a
    // dimension in a multidimensional packed array. Character 0 is bits 6:0.
    logic [TEXT_WIDTH-1:0] text_pe;
    logic [LEN_WIDTH-1:0] length_pe;
    logic sequence_active, sequence_overflow;
    wire coord_on_screen = (coord_head[31:16] < IMG_WIDTH) &&
                           (coord_head[15:0] < IMG_HEIGHT);

    always_ff @(posedge clk_pe or negedge rst_n_pe) begin
        if (!rst_n_pe) begin
            current_x_min <= 0;
            current_y_min <= 0;
            length_pe <= 0;
            sequence_active <= 0;
            sequence_overflow <= 0;
        end else begin
            if (frame_start_out) begin
                current_x_min <= coord_head[31:16];
                current_y_min <= coord_head[15:0];
                sequence_active <= coord_pop && coord_on_screen && !dbg_coord_error;
                sequence_overflow <= 0;
                length_pe <= 0;
            end else if (out_valid && sequence_active) begin
                if ((out_char < CHAR_NUM - 1) && (length_pe < MAX_PLATE_CHARS)) begin
                    length_pe <= length_pe + 1'b1;
                end else begin
                    sequence_overflow <= 1'b1;
                end
            end
            if (frame_end_out) sequence_active <= 0;
        end
    end

    // Each generated register has a constant seven-bit slice. The runtime
    // character index is used only as a write enable, never a packed index.
    genvar text_char;
    generate
        for (text_char=0; text_char<MAX_PLATE_CHARS; text_char=text_char+1) begin : gen_text_char
            always_ff @(posedge clk_pe or negedge rst_n_pe) begin
                if (!rst_n_pe) text_pe[text_char*7 +: 7] <= 7'd0;
                else if (frame_start_out) text_pe[text_char*7 +: 7] <= 7'd0;
                else if (out_valid && sequence_active && (out_char < CHAR_NUM - 1) &&
                         (length_pe == text_char))
                    text_pe[text_char*7 +: 7] <= out_char;
            end
        end
    endgenerate

    // Transfer a whole result in ONE FIFO word. A full FIFO drops a whole
    // recognition, never a prefix/suffix. Black flush crops are off-screen.
    wire result_ready = frame_end_out && sequence_active && !sequence_overflow &&
                        !dbg_coord_error && (length_pe >= MIN_PLATE_CHARS);
    wire result_full, result_empty;
    wire result_rd = !result_empty;
    wire [PACKET_WIDTH-1:0] result_dout;
    logic dbg_result_dropped /* synthesis syn_preserve=1 */;
    always_ff @(posedge clk_pe or negedge rst_n_pe) begin
        if (!rst_n_pe) dbg_result_dropped <= 0;
        else if (result_ready && result_full) dbg_result_dropped <= 1;
    end
    my_fifo #(.DATA_WIDTH(PACKET_WIDTH), .FIFO_DEPTH(16)) u_result_fifo (
        .wr_clk(clk_pe), .rd_clk(clk_video), .rst(!rst_n_video || !rst_n_pe),
        .wr_en(result_ready && !result_full),
        .din({current_x_min, current_y_min, length_pe, text_pe}),
        .rd_en(result_rd), .dout(result_dout), .full(result_full), .empty(result_empty)
    );
    logic result_valid;
    always_ff @(posedge clk_video or negedge rst_n_video) begin
        if (!rst_n_video) result_valid <= 0;
        else result_valid <= result_rd;
    end
    wire [15:0] new_x = result_dout[PACKET_WIDTH-1 -: 16];
    wire [15:0] new_y = result_dout[PACKET_WIDTH-17 -: 16];
    wire [LEN_WIDTH-1:0] new_length = result_dout[TEXT_WIDTH +: LEN_WIDTH];
    wire [TEXT_WIDTH-1:0] new_text = result_dout[TEXT_WIDTH-1:0];

    // Active pixels have zero-based coordinates, increment Y after DE falls.
    logic [15:0] pixel_x, pixel_y;
    logic de_d1, vs_in_d;
    wire hs_falling = !video_de_in && de_d1;
    wire vs_rising = video_vs_in && !vs_in_d;
    always_ff @(posedge clk_video or negedge rst_n_video) begin
        if (!rst_n_video) begin
            de_d1 <= 0; vs_in_d <= 0;
            pixel_x <= 0; pixel_y <= 0;
        end else begin
            de_d1 <= video_de_in;
            vs_in_d <= video_vs_in;
            if (vs_rising) begin
                pixel_x <= 0; pixel_y <= 0;
            end else if (video_de_in) pixel_x <= pixel_x + 1'b1;
            else if (hs_falling) begin
                pixel_x <= 0; pixel_y <= pixel_y + 1'b1;
            end
        end
    end

    // Pending results and display results are separate. Display registers
    // change only at VS, so no incoming character can tear a displayed string.
    logic [MAX_PLATES-1:0] track_used, pending_valid, display_valid;
    logic [15:0] pending_x [0:MAX_PLATES-1], pending_y [0:MAX_PLATES-1];
    logic [15:0] display_x [0:MAX_PLATES-1], display_y [0:MAX_PLATES-1];
    logic [TEXT_WIDTH-1:0] pending_text [0:MAX_PLATES-1];
    logic [TEXT_WIDTH-1:0] display_text [0:MAX_PLATES-1];
    logic [TEXT_WIDTH-1:0] trial_text [0:MAX_PLATES-1];
    logic [LEN_WIDTH-1:0] pending_length [0:MAX_PLATES-1];
    logic [LEN_WIDTH-1:0] display_length [0:MAX_PLATES-1];
    logic [LEN_WIDTH-1:0] trial_length [0:MAX_PLATES-1];
    logic [CONFIRM_WIDTH-1:0] trial_count [0:MAX_PLATES-1];
    logic [AGE_WIDTH-1:0] age [0:MAX_PLATES-1];
    integer replace_ptr;
    integer match_idx, free_idx, target_idx, best_distance;
    integer dx, dy;
    // Keep loop variables outside the for initializer for the PDS ADS parser.
    // Each process owns its loop variable; do not share one between processes.
    integer match_slot, update_slot, render_slot;
    always_comb begin
        match_idx = -1;
        free_idx = -1;
        best_distance = 2 * MATCH_DISTANCE + 1;
        dx = 0; dy = 0;
        for (match_slot=0; match_slot<MAX_PLATES; match_slot=match_slot+1) begin
            dx = (new_x >= pending_x[match_slot]) ?
                ({16'd0, new_x} - {16'd0, pending_x[match_slot]}) :
                ({16'd0, pending_x[match_slot]} - {16'd0, new_x});
            dy = (new_y >= pending_y[match_slot]) ?
                ({16'd0, new_y} - {16'd0, pending_y[match_slot]}) :
                ({16'd0, pending_y[match_slot]} - {16'd0, new_y});
            if (track_used[match_slot] && (dx <= MATCH_DISTANCE) && (dy <= MATCH_DISTANCE) &&
                (dx + dy < best_distance)) begin
                match_idx = match_slot;
                best_distance = dx + dy;
            end
            if (!track_used[match_slot] && (free_idx < 0)) free_idx = match_slot;
        end
        target_idx = (match_idx >= 0) ? match_idx : ((free_idx >= 0) ? free_idx : replace_ptr);
    end

    always_ff @(posedge clk_video or negedge rst_n_video) begin
        if (!rst_n_video) begin
            track_used <= '0;
            pending_valid <= '0;
            display_valid <= '0;
            replace_ptr <= 0;
            for (update_slot=0; update_slot<MAX_PLATES; update_slot=update_slot+1) begin
                age[update_slot] <= 0;
                trial_count[update_slot] <= 0;
                trial_text[update_slot] <= '0;
                trial_length[update_slot] <= 0;
                pending_x[update_slot] <= 0; pending_y[update_slot] <= 0;
                pending_text[update_slot] <= '0; pending_length[update_slot] <= 0;
                display_x[update_slot] <= 0; display_y[update_slot] <= 0;
                display_text[update_slot] <= '0; display_length[update_slot] <= 0;
            end
        end else begin
            if (vs_rising) begin
                for (update_slot=0; update_slot<MAX_PLATES; update_slot=update_slot+1) begin
                    display_valid[update_slot] <= pending_valid[update_slot] && track_used[update_slot] && (age[update_slot] < HOLD_FRAMES);
                    // Keep the whole label inside the right/top screen edges.
                    if (pending_x[update_slot] + pending_length[update_slot] * 16 > IMG_WIDTH)
                        display_x[update_slot] <= IMG_WIDTH - pending_length[update_slot] * 16;
                    else display_x[update_slot] <= pending_x[update_slot];
                    display_y[update_slot] <= (pending_y[update_slot] >= 16) ? pending_y[update_slot] - 16 : 0;
                    display_text[update_slot] <= pending_text[update_slot];
                    display_length[update_slot] <= pending_length[update_slot];
                    if (track_used[update_slot]) begin
                        if (age[update_slot] >= HOLD_FRAMES - 1) begin
                            track_used[update_slot] <= 0;
                            pending_valid[update_slot] <= 0;
                            trial_count[update_slot] <= 0;
                        end else age[update_slot] <= age[update_slot] + 1'b1;
                    end
                end
            end
            if (result_valid) begin
                track_used[target_idx] <= 1;
                pending_x[target_idx] <= new_x;
                pending_y[target_idx] <= new_y;
                trial_text[target_idx] <= new_text;
                trial_length[target_idx] <= new_length;
                if ((match_idx >= 0) && (trial_text[target_idx] == new_text) &&
                    (trial_length[target_idx] == new_length)) begin
                    if (trial_count[target_idx] < CONFIRM_RESULTS)
                        trial_count[target_idx] <= trial_count[target_idx] + 1'b1;
                    if (trial_count[target_idx] >= CONFIRM_RESULTS - 1) begin
                        pending_text[target_idx] <= new_text;
                        pending_length[target_idx] <= new_length;
                        pending_valid[target_idx] <= 1;
                        age[target_idx] <= 0;
                    end
                end else begin
                    trial_count[target_idx] <= 1;
                    if ((match_idx < 0) || (CONFIRM_RESULTS <= 1)) begin
                        age[target_idx] <= 0;
                        pending_valid[target_idx] <= (CONFIRM_RESULTS <= 1);
                        pending_text[target_idx] <= new_text;
                        pending_length[target_idx] <= new_length;
                    end
                end
                if (match_idx < 0)
                    replace_ptr <= (target_idx == MAX_PLATES - 1) ? 0 : target_idx + 1;
            end
        end
    end

    logic s1_hit;
    logic [6:0] s1_char;
    logic [3:0] s1_row, s1_col;
    always_ff @(posedge clk_video or negedge rst_n_video) begin
        if (!rst_n_video) begin
            s1_hit <= 0; s1_char <= 0; s1_row <= 0; s1_col <= 0;
        end else begin
            s1_hit <= 0;
            for (render_slot=0; render_slot<MAX_PLATES; render_slot=render_slot+1) begin
                if (display_valid[render_slot] && video_de_in &&
                    (pixel_x >= display_x[render_slot]) && (pixel_x < display_x[render_slot] + display_length[render_slot] * 16) &&
                    (pixel_y >= display_y[render_slot]) && (pixel_y < display_y[render_slot] + 16)) begin
                    s1_hit <= 1;
                    s1_char <= display_text[render_slot][(((pixel_x - display_x[render_slot]) >> 4) * 7) +: 7];
                    // Low four bits of the offset, without a sized SV cast.
                    s1_col <= pixel_x[3:0] - display_x[render_slot][3:0];
                    s1_row <= pixel_y[3:0] - display_y[render_slot][3:0];
                end
            end
        end
    end

    logic [10:0] rom_addr; 
    logic        s2_hit;
    logic [3:0]  s2_col;

    always_ff @(posedge clk_video) begin
        s2_hit   <= s1_hit;
        s2_col   <= s1_col;
        rom_addr <= {s1_char, s1_row};
    end

    // ROM 读取需要严格的一维非压缩数组，这是 $readmemb 规定的
    logic [15:0] font_rom [0:2047];
    initial $readmemb(FONT_FILE, font_rom);

    logic [15:0] rom_data;
    always_ff @(posedge clk_video) rom_data <= font_rom[rom_addr];

    logic s3_hit;
    logic [3:0] s3_col;
    always_ff @(posedge clk_video) begin
        s3_hit <= s2_hit;
        s3_col <= s2_col;
    end

    logic char_pixel;
    assign char_pixel = s3_hit ? rom_data[15 - s3_col] : 1'b0;
    
    // =========================================================
    // F. 延迟补偿与混色输出 (完美对齐)
    // =========================================================
    logic [3:0]  vs_delay, hs_delay, de_delay;
    
    // [修改] 把 RGB 缓存也修改为压缩数组
    logic [2:0][23:0] rgb_delay; 

    always_ff @(posedge clk_video) begin
        vs_delay <= {vs_delay[2:0], video_vs_in};
        hs_delay <= {hs_delay[2:0], video_hs_in};
        de_delay <= {de_delay[2:0], video_de_in};

        rgb_delay[0] <= video_rgb_in;
        rgb_delay[1] <= rgb_delay[0];
        rgb_delay[2] <= rgb_delay[1];
    end

    // 纯连线输出控制信号，绝对延迟 4 拍
    assign video_vs_out = vs_delay[3];
    assign video_hs_out = hs_delay[3];
    assign video_de_out = de_delay[3];
    
    always_ff @(posedge clk_video) begin
        if(s3_hit) begin
            if (char_pixel) 
                video_rgb_out <= 24'hFF_00_FF; // 粉色文字
            else 
                video_rgb_out <= 24'hFF_FF_FF; // 白色背景
        end
        else            
            // 取 T-3 时刻的数据进寄存器，输出正好是绝对延迟 4 拍！严格与 DE 信号对齐。
            video_rgb_out <= rgb_delay[2]; 
    end

endmodule
