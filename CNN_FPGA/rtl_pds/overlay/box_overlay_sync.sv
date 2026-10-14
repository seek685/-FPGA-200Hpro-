module box_overlay_sync #(
    parameter int IMG_WIDTH          = 1280,   // 图像总宽
    parameter int IMG_HEIGHT         = 720,    // 图像总高
    parameter int GRID_STRIDE_CENTER = 16,     // 中心点网格步长 (下采样率)
    parameter int GRID_STRIDE_LTRB   = 1,      // 边框相对偏移步长
    parameter int LINE_WIDTH         = 4,      // 画框的线宽(像素)
    parameter int NMS_IOU_NUM        = 128,    // IoU threshold = 128 / 256
    parameter int NMS_IOU_DEN        = 256,
    parameter int CLASS_NUM          = 5,
    parameter int MAX_BOX_NUM        = 10,     // 屏幕中最多同时展示的框数量。
    
    // 裁剪子图的目标尺寸 W1 x H1
    parameter int CROP_WIDTH         = 40,     // 裁剪出的子图宽度
    parameter int CROP_HEIGHT        = 10      // 裁剪出的子图高度
)(
    input  logic               clk_video,
    input  logic               clk_pe,
    input  logic               rst_n,
    
    // ===================================
    // 1. 视频流输入输出 (同步于 clk_video)
    // ===================================
    input  logic               video_vs_in,
    input  logic               video_hs_in,
    input  logic               video_de_in,
    input  logic [23:0]        video_rgb_in,
    
    output logic               video_vs_out,
    output logic               video_hs_out,
    output logic               video_de_out,
    output logic [23:0]        video_rgb_out,
    
    // ===================================
    // 2. YOLO 检测数据 (同步于 clk_pe)
    // ===================================
    input  logic               box_wr_en,
    input  logic [31:0]        box_wr_data,
    
    // ===================================
    // 2. Iprnet 子图相关数据 (同步于 clk_video)
    // ===================================
    output logic [MAX_BOX_NUM-1:0]        start_crop_wr,
    output logic [MAX_BOX_NUM-1:0]        end_crop_wr,
    output logic [MAX_BOX_NUM-1:0][15:0]  crop_x_min,
    output logic [MAX_BOX_NUM-1:0][15:0]  crop_y_min,
    output logic [MAX_BOX_NUM-1:0]        crop_wr_en,
    output logic [MAX_BOX_NUM-1:0][23:0]  crop_rgb_out
);     

    // =========================================================
    // 变量统一定义区
    // =========================================================
    genvar i_gen;
    int idx;
    
    // 坐标计算中间变量 (改为供 always_comb 使用的纯组合逻辑)
    logic signed [15:0] cx, cy;
    logic signed [15:0] xmin_val, ymin_val, xmax_val, ymax_val;

    // DDA 累加器与写使能数组
    localparam int FRAC_BITS = 8;
    localparam int FRAC_ONE  = (1 << FRAC_BITS);
    localparam int FP_WIDTH  = 32;
    localparam int RECIP_BITS = 32;
    localparam longint unsigned CROP_WIDTH_RECIP  = ((64'd1 << RECIP_BITS) + CROP_WIDTH - 1) / CROP_WIDTH;
    localparam longint unsigned CROP_HEIGHT_RECIP = ((64'd1 << RECIP_BITS) + CROP_HEIGHT - 1) / CROP_HEIGHT;

    logic [FP_WIDTH-1:0] x_step       [0:MAX_BOX_NUM-1];
    logic [FP_WIDTH-1:0] y_step       [0:MAX_BOX_NUM-1];
    logic [FP_WIDTH-1:0] x_fp         [0:MAX_BOX_NUM-1];
    logic [FP_WIDTH-1:0] y_fp         [0:MAX_BOX_NUM-1];
    logic [15:0]         x_sample     [0:MAX_BOX_NUM-1];
    logic [15:0]         y_sample     [0:MAX_BOX_NUM-1];
    logic [FRAC_BITS-1:0] x_frac      [0:MAX_BOX_NUM-1];
    logic [FRAC_BITS-1:0] y_frac      [0:MAX_BOX_NUM-1];
    logic [15:0]         crop_col_idx [0:MAX_BOX_NUM-1];
    logic [15:0]         crop_row_idx [0:MAX_BOX_NUM-1];
    logic                y_valid_row  [0:MAX_BOX_NUM-1];
    
    // 【新增标志位】：用于解决残缺框和半途crop的问题
    logic        crop_active [0:MAX_BOX_NUM-1]; // 标记当前正在进行一次从头开始的合法crop过程
    logic        crop_done   [0:MAX_BOX_NUM-1]; // 标记当前框已经完成了一次完整的crop
    logic        crop_emit_done [0:MAX_BOX_NUM-1];
    
    // 数据打拍，用于对齐 crop_wr_en 的一级时序延迟
    logic [23:0] video_rgb_in_d1;
    logic video_vs_d1, video_hs_d1, video_de_d1;
    logic [23:0] line_buf [0:IMG_WIDTH-1];
    logic [23:0] curr_rgb_left;
    logic [23:0] prev_row_left;

    function automatic [FP_WIDTH-1:0] calc_step(
        input logic [15:0]          src_size,
        input longint unsigned      dst_recip
    );
        logic [63:0] scaled;
        begin
            scaled    = ({48'd0, src_size} << FRAC_BITS) * dst_recip;
            calc_step = scaled >> RECIP_BITS;
        end
    endfunction

    function automatic [FP_WIDTH-1:0] calc_start_fp(input logic [FP_WIDTH-1:0] step);
        if (step > FRAC_ONE) calc_start_fp = (step >> 1) - (FRAC_ONE >> 1);
        else                 calc_start_fp = 0;
    endfunction

    function automatic [15:0] calc_sample(
        input logic [FP_WIDTH-1:0] fp,
        input logic [15:0]         src_size
    );
        logic [15:0] base;
        logic        has_frac;
        begin
            base        = fp[FP_WIDTH-1:FRAC_BITS];
            has_frac    = |fp[FRAC_BITS-1:0];
            calc_sample = base + has_frac;
            if (src_size != 0 && calc_sample >= src_size) calc_sample = src_size - 1;
        end
    endfunction

    function automatic [FRAC_BITS-1:0] calc_frac(input logic [FP_WIDTH-1:0] fp);
        calc_frac = fp[FRAC_BITS-1:0];
    endfunction

    function automatic [16:0] interp_horizontal(
        input logic [7:0]           c0,
        input logic [7:0]           c1,
        input logic [FRAC_BITS-1:0] frac
    );
        logic signed [9:0]  delta;
        logic signed [17:0] acc;
        begin
            delta = $signed({1'b0, c1}) - $signed({1'b0, c0});
            acc   = $signed({1'b0, c0, {FRAC_BITS{1'b0}}}) +
                    delta * $signed({1'b0, frac});
            interp_horizontal = acc[16:0];
        end
    endfunction

    function automatic [7:0] interp_vertical(
        input logic [16:0]          top,
        input logic [16:0]          bottom,
        input logic [FRAC_BITS-1:0] frac
    );
        logic signed [17:0] delta;
        logic signed [26:0] acc;
        begin
            delta = $signed({1'b0, bottom}) - $signed({1'b0, top});
            acc   = $signed({1'b0, top, {FRAC_BITS{1'b0}}}) +
                    delta * $signed({1'b0, frac}) +
                    (1 << (2 * FRAC_BITS - 1));
            interp_vertical = acc >> (2 * FRAC_BITS);
        end
    endfunction
    // 碰撞检测流水线中间变量数组
    logic       cur_hit ;
    logic [7:0] cur_conf;
    logic [7:0] cur_cls ;
    logic signed [15:0] pixel_x, pixel_y; // Zero-based active pixel coordinates
    logic video_de_in_d;
    wire  hs_falling = !video_de_in && video_de_in_d;

    // Assemble all five words in the PE domain before crossing clocks.
    // If full, discard an entire candidate. Partial packets must never reach
    // the coordinate decoder, even when all display/crop slots are occupied.
    logic [2:0] pe_word_cnt;
    logic [31:0] pe_header;
    logic [8:0] pe_l, pe_t, pe_r;
    logic fifo_full, fifo_empty;
    logic [67:0] fifo_dout;
    logic fifo_rd_en;
    wire packet_complete = box_wr_en && (pe_word_cnt == 4);
    logic [15:0] dbg_box_packets_dropped /* synthesis syn_preserve=1 */;
    always_ff @(posedge clk_pe or negedge rst_n) begin
        if (!rst_n) begin
            pe_word_cnt <= 0;
            pe_header <= 0; pe_l <= 0; pe_t <= 0; pe_r <= 0;
            dbg_box_packets_dropped <= 0;
        end else if (box_wr_en) begin
            case (pe_word_cnt)
                0: pe_header <= box_wr_data;
                1: pe_l <= box_wr_data[8:0];
                2: pe_t <= box_wr_data[8:0];
                3: pe_r <= box_wr_data[8:0];
                default: ;
            endcase
            if (pe_word_cnt == 4) begin
                pe_word_cnt <= 0;
                if (fifo_full && !(&dbg_box_packets_dropped))
                    dbg_box_packets_dropped <= dbg_box_packets_dropped + 1'b1;
            end else pe_word_cnt <= pe_word_cnt + 1'b1;
        end
    end
    my_fifo #(.DATA_WIDTH(68), .FIFO_DEPTH(64)) u_box_fifo (
        .rd_clk(clk_video), .wr_clk(clk_pe), .rst(!rst_n),
        .wr_en(packet_complete && !fifo_full),
        .din({pe_header, pe_l, pe_t, pe_r, box_wr_data[8:0]}),
        .rd_en(fifo_rd_en), .dout(fifo_dout), .full(fifo_full), .empty(fifo_empty)
    );

    logic [7:0] tmp_idx_x, tmp_idx_y, tmp_conf, tmp_cls;
    logic signed [8:0] tmp_L, tmp_T, tmp_B, tmp_R;
    logic signed [15:0] box_xmin [0:MAX_BOX_NUM-1], box_xmax [0:MAX_BOX_NUM-1];
    logic signed [15:0] box_ymin [0:MAX_BOX_NUM-1], box_ymax [0:MAX_BOX_NUM-1];
    logic [15:0] box_w0 [0:MAX_BOX_NUM-1], box_h0 [0:MAX_BOX_NUM-1];
    logic [7:0] box_conf [0:MAX_BOX_NUM-1], box_cls [0:MAX_BOX_NUM-1];
    logic [MAX_BOX_NUM-1:0] box_valid;
    logic vs_in_d;
    wire vs_rising = video_vs_in && !vs_in_d;
    always_ff @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) vs_in_d <= 0;
        else vs_in_d <= video_vs_in;
    end

    always_comb begin
        cx = {1'b0, tmp_idx_x} * GRID_STRIDE_CENTER + GRID_STRIDE_CENTER/2;
        cy = {1'b0, tmp_idx_y} * GRID_STRIDE_CENTER + GRID_STRIDE_CENTER/2;
        xmin_val = cx - tmp_L * GRID_STRIDE_LTRB;
        ymin_val = cy - tmp_T * GRID_STRIDE_LTRB;
        xmax_val = cx + tmp_R * GRID_STRIDE_LTRB;
        ymax_val = cy + tmp_B * GRID_STRIDE_LTRB;
    end
    function automatic [15:0] clamp_coord(input integer v, input integer upper);
        if (v < 1) clamp_coord = 1;
        else if (v > upper) clamp_coord = upper[15:0];
        else clamp_coord = v[15:0];
    endfunction

    // Streaming, class-agnostic overlap suppression. Before a crop starts,
    // the higher-score box may replace lower-score overlapping candidates.
    // Once sampling starts, freeze that box and suppress later duplicates;
    // changing its dimensions halfway through would corrupt the crop FIFO.
    localparam [2:0] BOX_IDLE=0, BOX_LOAD=1, BOX_DECODE=2, BOX_SIZE=3,
                     BOX_AREA=4, BOX_COMPARE=5, BOX_COMMIT=6;
    logic [2:0] box_state;
    logic [15:0] cand_xmin, cand_xmax, cand_ymin, cand_ymax;
    logic cand_valid, reject_candidate;
    logic [MAX_BOX_NUM-1:0] overlap_mask;
    integer scan_idx, free_idx, overlap_idx, commit_idx;
    logic [15:0] inter_xmin, inter_xmax, inter_ymin, inter_ymax;
    logic [31:0] intersection_area, candidate_area, existing_area;
    logic [32:0] union_area;
    logic [63:0] intersection_scaled, union_scaled;
    logic overlap_locked;
    // PDS ADS compatibility: module-scope loop variables, one per process.
    integer lock_slot, box_slot;
    always_comb begin
        inter_xmin = (cand_xmin > box_xmin[scan_idx]) ? cand_xmin : box_xmin[scan_idx];
        inter_xmax = (cand_xmax < box_xmax[scan_idx]) ? cand_xmax : box_xmax[scan_idx];
        inter_ymin = (cand_ymin > box_ymin[scan_idx]) ? cand_ymin : box_ymin[scan_idx];
        inter_ymax = (cand_ymax < box_ymax[scan_idx]) ? cand_ymax : box_ymax[scan_idx];
        union_area = {1'b0, candidate_area} + {1'b0, existing_area} - {1'b0, intersection_area};
        intersection_scaled = {32'd0, intersection_area} * NMS_IOU_DEN;
        union_scaled = {31'd0, union_area} * NMS_IOU_NUM;
        commit_idx = (overlap_idx >= 0) ? overlap_idx : free_idx;
        overlap_locked = 0;
        for (lock_slot=0; lock_slot<MAX_BOX_NUM; lock_slot=lock_slot+1) begin
            if (overlap_mask[lock_slot] && box_valid[lock_slot] &&
                (crop_active[lock_slot] || crop_done[lock_slot] ||
                 (hs_falling && (pixel_y + 1 == box_ymin[lock_slot])))) overlap_locked = 1;
        end
    end
    assign fifo_rd_en = (box_state == BOX_IDLE) && !fifo_empty;

    always_ff @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            box_state <= BOX_IDLE;
            box_valid <= '0;
            tmp_idx_x <= 0; tmp_idx_y <= 0; tmp_conf <= 0; tmp_cls <= 0;
            tmp_L <= 0; tmp_T <= 0; tmp_R <= 0; tmp_B <= 0;
            cand_xmin <= 0; cand_xmax <= 0; cand_ymin <= 0; cand_ymax <= 0;
            cand_valid <= 0; reject_candidate <= 0; overlap_mask <= '0;
            scan_idx <= 0; free_idx <= -1; overlap_idx <= -1;
            intersection_area <= 0; candidate_area <= 0; existing_area <= 0;
            for (box_slot=0; box_slot<MAX_BOX_NUM; box_slot=box_slot+1) begin
                box_xmin[box_slot] <= 0; box_xmax[box_slot] <= 0;
                box_ymin[box_slot] <= 0; box_ymax[box_slot] <= 0;
                box_w0[box_slot] <= 0; box_h0[box_slot] <= 0;
                box_conf[box_slot] <= 0; box_cls[box_slot] <= 0;
            end
        end else begin
            for (box_slot=0; box_slot<MAX_BOX_NUM; box_slot=box_slot+1) begin
                if ((pixel_y > box_ymax[box_slot] + 1) && crop_done[box_slot]) box_valid[box_slot] <= 0;
            end
            case (box_state)
                BOX_IDLE: if (fifo_rd_en) box_state <= BOX_LOAD;
                BOX_LOAD: begin
                    {tmp_cls, tmp_idx_x, tmp_idx_y, tmp_conf, tmp_L, tmp_T, tmp_R, tmp_B} <= fifo_dout;
                    box_state <= BOX_DECODE;
                end
                BOX_DECODE: begin
                    // Signed 32-bit arithmetic preserves negative off-screen
                    // coordinates until clamping, without an int cast.
                    cand_xmin <= clamp_coord(xmin_val - 32'sd10, IMG_WIDTH - 2);
                    cand_xmax <= clamp_coord(xmax_val + 32'sd10, IMG_WIDTH - 2);
                    cand_ymin <= clamp_coord(ymin_val - 32'sd5, IMG_HEIGHT - 2);
                    cand_ymax <= clamp_coord(ymax_val + 32'sd5, IMG_HEIGHT - 2);
                    cand_valid <= (xmax_val > xmin_val) && (ymax_val > ymin_val) && (tmp_cls < CLASS_NUM);
                    box_state <= BOX_SIZE;
                end
                BOX_SIZE: begin
                    cand_valid <= cand_valid && (cand_xmax > cand_xmin) && (cand_ymax > cand_ymin);
                    // The one-pass resizer supports downsampling; preserve the
                    // existing minimum crop extent and keep it inside the image.
                    if (cand_xmax - cand_xmin < CROP_WIDTH) begin
                        if (cand_xmin + CROP_WIDTH <= IMG_WIDTH - 2)
                            cand_xmax <= cand_xmin + CROP_WIDTH;
                        else begin
                            cand_xmax <= IMG_WIDTH - 2;
                            cand_xmin <= IMG_WIDTH - 2 - CROP_WIDTH;
                        end
                    end
                    if (cand_ymax - cand_ymin < CROP_HEIGHT) begin
                        if (cand_ymin + CROP_HEIGHT <= IMG_HEIGHT - 2)
                            cand_ymax <= cand_ymin + CROP_HEIGHT;
                        else begin
                            cand_ymax <= IMG_HEIGHT - 2;
                            cand_ymin <= IMG_HEIGHT - 2 - CROP_HEIGHT;
                        end
                    end
                    scan_idx <= 0; free_idx <= -1; overlap_idx <= -1;
                    reject_candidate <= 0;
                    overlap_mask <= '0;
                    box_state <= BOX_AREA;
                end
                BOX_AREA: begin
                    candidate_area <= (cand_xmax - cand_xmin) * (cand_ymax - cand_ymin);
                    existing_area <= box_w0[scan_idx] * box_h0[scan_idx];
                    if ((inter_xmax > inter_xmin) && (inter_ymax > inter_ymin))
                        intersection_area <= (inter_xmax - inter_xmin) * (inter_ymax - inter_ymin);
                    else intersection_area <= 0;
                    box_state <= BOX_COMPARE;
                end
                BOX_COMPARE: begin
                    if (!box_valid[scan_idx]) begin
                        if (free_idx < 0) free_idx <= scan_idx;
                    end else if ((intersection_area != 0) && (intersection_scaled >= union_scaled)) begin
                        overlap_mask[scan_idx] <= 1;
                        if (overlap_idx < 0) overlap_idx <= scan_idx;
                        if ((tmp_conf <= box_conf[scan_idx]) || crop_active[scan_idx] || crop_done[scan_idx])
                            reject_candidate <= 1;
                    end
                    if (scan_idx == MAX_BOX_NUM - 1) box_state <= BOX_COMMIT;
                    else begin
                        scan_idx <= scan_idx + 1;
                        box_state <= BOX_AREA;
                    end
                end
                BOX_COMMIT: begin
                    if (cand_valid && !reject_candidate && !overlap_locked && (commit_idx >= 0)) begin
                        for (box_slot=0; box_slot<MAX_BOX_NUM; box_slot=box_slot+1)
                            if (overlap_mask[box_slot]) box_valid[box_slot] <= 0;
                        box_xmin[commit_idx] <= cand_xmin;
                        box_xmax[commit_idx] <= cand_xmax;
                        box_ymin[commit_idx] <= cand_ymin;
                        box_ymax[commit_idx] <= cand_ymax;
                        box_w0[commit_idx] <= cand_xmax - cand_xmin;
                        box_h0[commit_idx] <= cand_ymax - cand_ymin;
                        box_conf[commit_idx] <= tmp_conf;
                        box_cls[commit_idx] <= tmp_cls;
                        box_valid[commit_idx] <= 1;
                    end
                    // Always drain the packet FIFO, even if no slot is free.
                    box_state <= BOX_IDLE;
                end
                default: box_state <= BOX_IDLE;
            endcase
        end
    end

    // =========================================================
    // C. 视频光栅扫描与坐标追踪
    // =========================================================
    
    always_ff @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            video_de_in_d <= 0;
            pixel_x <= 0;
            pixel_y <= 0;
            video_rgb_in_d1 <= 0;
            video_vs_d1 <= 0; video_hs_d1 <= 0; video_de_d1 <= 0;
        end else begin
            video_de_in_d <= video_de_in;
            // [修复3]: 像素数据打一拍，用于对齐 crop_wr_en
            video_rgb_in_d1 <= video_rgb_in;
            video_vs_d1 <= video_vs_in; video_hs_d1 <= video_hs_in; video_de_d1 <= video_de_in;
            
            if (vs_rising) begin
                pixel_x <= 0;
                pixel_y <= 0;
            end 
            else if (video_de_in) begin
                pixel_x <= pixel_x + 1;
            end 
            // At DE falling, pixel_y is the row that just ended.
            else if (hs_falling) begin
                pixel_x <= 0;
                pixel_y <= pixel_y + 1;
            end
        end
    end

    always_ff @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            curr_rgb_left <= 0;
            prev_row_left <= 0;
        end else if (video_de_in) begin
            line_buf[pixel_x] <= video_rgb_in;
            curr_rgb_left     <= video_rgb_in;
            prev_row_left     <= line_buf[pixel_x];
        end
    end

    // =========================================================
    // F. Bilinear resize mapping and crop FIFO write generation
    // =========================================================
    generate
        for (i_gen = 0; i_gen < MAX_BOX_NUM; i_gen++) begin : gen_crop_fifo
            logic [23:0] p00, p10, p01, p11;
            logic [FP_WIDTH-1:0] next_x_fp, next_y_fp;
            logic [FP_WIDTH-1:0] init_x_step, init_y_step;
            logic [FP_WIDTH-1:0] init_x_fp, init_y_fp;
            logic [15:0] init_y_sample;
            logic interp_valid_s1, interp_valid_s2;
            logic end_crop_s1, end_crop_s2;
            logic [16:0] top_r_s1, top_g_s1, top_b_s1;
            logic [16:0] bot_r_s1, bot_g_s1, bot_b_s1;
            logic [FRAC_BITS-1:0] y_frac_s1;
            logic [23:0] interp_rgb_s2;

            always_comb begin
                p00 = prev_row_left;
                p10 = (pixel_x >= IMG_WIDTH) ? line_buf[IMG_WIDTH - 1] : line_buf[pixel_x];
                p01 = curr_rgb_left;
                p11 = video_rgb_in;

                if (x_frac[i_gen] == 0) begin
                    p00 = p10;
                    p01 = p11;
                end
                if (y_frac[i_gen] == 0) begin
                    p00 = p01;
                    p10 = p11;
                end

                next_x_fp    = x_fp[i_gen] + x_step[i_gen];
                next_y_fp    = y_fp[i_gen] + y_step[i_gen];
                init_x_step  = calc_step(box_w0[i_gen], CROP_WIDTH_RECIP);
                init_y_step  = calc_step(box_h0[i_gen], CROP_HEIGHT_RECIP);
                init_x_fp    = calc_start_fp(init_x_step);
                init_y_fp    = calc_start_fp(init_y_step);
                init_y_sample = calc_sample(init_y_fp, box_h0[i_gen]);
            end

            always_ff @(posedge clk_video or negedge rst_n) begin
                if (!rst_n) begin
                    x_step[i_gen]        <= 0;
                    y_step[i_gen]        <= 0;
                    x_fp[i_gen]          <= 0;
                    y_fp[i_gen]          <= 0;
                    x_sample[i_gen]      <= 0;
                    y_sample[i_gen]      <= 0;
                    x_frac[i_gen]        <= 0;
                    y_frac[i_gen]        <= 0;
                    crop_col_idx[i_gen]  <= 0;
                    crop_row_idx[i_gen]  <= 0;
                    y_valid_row[i_gen]   <= 1'b0;
                    start_crop_wr[i_gen] <= 1'b0;
                    end_crop_wr[i_gen]   <= 1'b0;
                    crop_x_min[i_gen]    <= 0;
                    crop_y_min[i_gen]    <= 0;
                    crop_active[i_gen]   <= 1'b0;
                    crop_done[i_gen]     <= 1'b0;
                    crop_emit_done[i_gen] <= 1'b0;
                    crop_wr_en[i_gen]    <= 1'b0;
                    crop_rgb_out[i_gen]  <= 24'd0;
                    interp_valid_s1      <= 1'b0;
                    interp_valid_s2      <= 1'b0;
                    end_crop_s1          <= 1'b0;
                    end_crop_s2          <= 1'b0;
                    top_r_s1             <= 0;
                    top_g_s1             <= 0;
                    top_b_s1             <= 0;
                    bot_r_s1             <= 0;
                    bot_g_s1             <= 0;
                    bot_b_s1             <= 0;
                    y_frac_s1            <= 0;
                    interp_rgb_s2        <= 24'd0;
                end else begin
                    start_crop_wr[i_gen] <= 1'b0;
                    end_crop_wr[i_gen]   <= end_crop_s2;
                    crop_wr_en[i_gen]    <= interp_valid_s2;
                    if (interp_valid_s2) begin
                        crop_rgb_out[i_gen] <= interp_rgb_s2;
                        if (end_crop_s2) begin
                            crop_done[i_gen] <= 1'b1;
                            crop_active[i_gen] <= 1'b0;
                        end
                    end

                    interp_valid_s2 <= interp_valid_s1;
                    end_crop_s2     <= end_crop_s1;
                    if (interp_valid_s1) begin
                        interp_rgb_s2[23:16] <= interp_vertical(top_r_s1, bot_r_s1, y_frac_s1);
                        interp_rgb_s2[15:8]  <= interp_vertical(top_g_s1, bot_g_s1, y_frac_s1);
                        interp_rgb_s2[7:0]   <= interp_vertical(top_b_s1, bot_b_s1, y_frac_s1);
                    end

                    interp_valid_s1 <= 1'b0;
                    end_crop_s1     <= 1'b0;

                    if (vs_rising) begin
                        y_valid_row[i_gen] <= 1'b0;
                        crop_active[i_gen] <= 1'b0;
                    end else if (box_valid[i_gen]) begin
                        if (hs_falling) begin
                            y_valid_row[i_gen] <= 1'b0;

                            if (pixel_y + 1 == box_ymin[i_gen]) begin
                                x_step[i_gen]        <= init_x_step;
                                y_step[i_gen]        <= init_y_step;
                                x_fp[i_gen]          <= init_x_fp;
                                y_fp[i_gen]          <= init_y_fp;
                                x_sample[i_gen]      <= calc_sample(init_x_fp, box_w0[i_gen]);
                                y_sample[i_gen]      <= init_y_sample;
                                x_frac[i_gen]        <= calc_frac(init_x_fp);
                                y_frac[i_gen]        <= calc_frac(init_y_fp);
                                crop_col_idx[i_gen]  <= 0;
                                crop_row_idx[i_gen]  <= 0;
                                y_valid_row[i_gen]   <= (init_y_sample == 0);
                                start_crop_wr[i_gen] <= 1'b1;
                                crop_active[i_gen]   <= 1'b1;
                                crop_emit_done[i_gen] <= 1'b0;
                                crop_x_min[i_gen]    <= box_xmin[i_gen];
                                crop_y_min[i_gen]    <= box_ymin[i_gen];
                            end else if (crop_active[i_gen] &&
                                         !crop_emit_done[i_gen] &&
                                         !y_valid_row[i_gen] &&
                                         (pixel_y + 1 == box_ymin[i_gen] + y_sample[i_gen])) begin
                                y_valid_row[i_gen] <= 1'b1;
                            end


                        end

                        if (y_valid_row[i_gen] && video_de_in &&
                            (pixel_x >= box_xmin[i_gen] + x_sample[i_gen])) begin
                            interp_valid_s1 <= 1'b1;
                            top_r_s1        <= interp_horizontal(p00[23:16], p10[23:16], x_frac[i_gen]);
                            top_g_s1        <= interp_horizontal(p00[15:8],  p10[15:8],  x_frac[i_gen]);
                            top_b_s1        <= interp_horizontal(p00[7:0],   p10[7:0],   x_frac[i_gen]);
                            bot_r_s1        <= interp_horizontal(p01[23:16], p11[23:16], x_frac[i_gen]);
                            bot_g_s1        <= interp_horizontal(p01[15:8],  p11[15:8],  x_frac[i_gen]);
                            bot_b_s1        <= interp_horizontal(p01[7:0],   p11[7:0],   x_frac[i_gen]);
                            y_frac_s1       <= y_frac[i_gen];

                            if (crop_col_idx[i_gen] < CROP_WIDTH - 1) begin
                                crop_col_idx[i_gen] <= crop_col_idx[i_gen] + 1;
                                x_fp[i_gen]         <= next_x_fp;
                                x_sample[i_gen]     <= calc_sample(next_x_fp, box_w0[i_gen]);
                                x_frac[i_gen]       <= calc_frac(next_x_fp);
                            end else begin
                                y_valid_row[i_gen] <= 1'b0;
                                x_fp[i_gen]         <= calc_start_fp(x_step[i_gen]);
                                x_sample[i_gen]     <= calc_sample(calc_start_fp(x_step[i_gen]), box_w0[i_gen]);
                                x_frac[i_gen]       <= calc_frac(calc_start_fp(x_step[i_gen]));
                                crop_col_idx[i_gen] <= 0;

                                if (crop_row_idx[i_gen] < CROP_HEIGHT - 1) begin
                                    crop_row_idx[i_gen] <= crop_row_idx[i_gen] + 1;
                                    y_fp[i_gen]         <= next_y_fp;
                                    y_sample[i_gen]     <= calc_sample(next_y_fp, box_h0[i_gen]);
                                    y_frac[i_gen]       <= calc_frac(next_y_fp);
                                end else begin
                                    end_crop_s1          <= 1'b1;
                                    crop_emit_done[i_gen] <= 1'b1;
                                end
                            end
                        end
                    end else begin
                        y_valid_row[i_gen] <= 1'b0;
                        crop_active[i_gen] <= 1'b0;
                        crop_done[i_gen]   <= 1'b0;
                        crop_emit_done[i_gen] <= 1'b0;
                    end
                end
            end
        end
    endgenerate

    // =========================================================
    // D. 碰撞检测（并行架构）
    // =========================================================
    
    
    // [修复1] 把判定逻辑放入 always_comb 中
    always_ff @(posedge clk_video) begin
        cur_hit  <= 1'b0;
        cur_conf <= 8'd0;
        cur_cls  <= 8'd0;
        for (idx = 0; idx < MAX_BOX_NUM; idx = idx + 1) begin
            if (video_de_in && box_valid[idx] &&
                pixel_x         >= box_xmin[idx] && pixel_x         <= box_xmax[idx] &&
                pixel_y   >= box_ymin[idx] && pixel_y   <= box_ymax[idx]) begin
                
                if (pixel_x         < box_xmin[idx] + LINE_WIDTH || pixel_x             > box_xmax[idx] - LINE_WIDTH ||
                    pixel_y   < box_ymin[idx] + LINE_WIDTH || pixel_y       > box_ymax[idx] - LINE_WIDTH) begin
                    cur_hit  <= 1'b1;
                    cur_conf <= box_conf[idx] ;
                    cur_cls  <= box_cls[idx] ;
                end
            end
        end
    end

    // =========================================================
    // E. 最终混叠输出 
    // =========================================================
    always_ff @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            video_vs_out <= 0; 
            video_hs_out <= 0; 
            video_de_out <= 0; 
            video_rgb_out <= 0;
        end else begin
            video_vs_out <= video_vs_d1;
            video_hs_out <= video_hs_d1;
            video_de_out <= video_de_d1;
            
            if (cur_hit) begin
                if (cur_cls == 0) 
                    video_rgb_out <= 24'h00_00_FF; 
                else if(cur_cls == 1)
                    video_rgb_out <= 24'h00_FF_00; 
                else if(cur_cls == 2)
                    video_rgb_out <= 24'hFF_FF_00; 
                else if(cur_cls == 3)
                    video_rgb_out <= 24'h00_00_00; 
                else if(cur_cls == 4)
                    video_rgb_out <= 24'hFF_FF_FF; 
                else
                    video_rgb_out <= 24'hFF_00_FF; 
            end else begin
                video_rgb_out <= video_rgb_in_d1;
            end
        end
    end

endmodule
