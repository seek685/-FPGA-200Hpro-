// LPRNet 的后处理模块
module lprnet_post_process #(
    // --- LPRNet 整体参数 ---
    parameter int unsigned PE_COL_NUM       = 4,
    parameter int unsigned CYCLE_PERIOD_OUT = 4,
    parameter int unsigned IMG_COL          = 128,
    parameter int unsigned IMG_ROW          = 128,
    parameter int unsigned DATA_WIDTH       = 8,   // 卷积输出位宽
    parameter int unsigned ACC_WIDTH        = 16,  // 累加器位宽
    
    // --- Extrema Finder 参数 ---
    parameter bit unsigned CONV_POSITIVE    = 1,   // 1: 找最大值, 0: 找最小值
    
    // --- CTC 参数 ---
    parameter int unsigned BLANK_CHAR       = 75,  // 空白符对应的通道索引
    parameter int unsigned VALID_CHAR_NUM   = 76   // 真实类别数，包含 blank，不包含补齐通道
) (
    input  logic                                clk,
    input  logic                                clk_en,
    input  logic                                rst_n,
    
    // 输入接口 (来自最后一层卷积)
    input  logic                                new_line_input_1,
    input  logic                                data_input_valid,
    input  logic signed [PE_COL_NUM-1:0] [DATA_WIDTH-1:0]        data_input ,
    
    // 最终 CTC 解码输出
    output logic [$clog2(CYCLE_PERIOD_OUT * PE_COL_NUM)-1:0] out_char         /* synthesis syn_preserve=1 */,
    output logic                                out_valid                     /* synthesis syn_preserve=1 */,
    output logic                                frame_start_out, // Every crop, including all-blank crops
    output logic                                frame_end_out    // One cycle after the last possible character
);

    localparam int unsigned CHANNEL_OUT_NUM = CYCLE_PERIOD_OUT * PE_COL_NUM;
    localparam int unsigned CH_WIDTH        = $clog2(CHANNEL_OUT_NUM);
    localparam logic [CH_WIDTH-1:0] BLANK_CHAR_CH = BLANK_CHAR[CH_WIDTH-1:0];
    localparam int unsigned VALID_CHAR_LIMIT = (VALID_CHAR_NUM < CHANNEL_OUT_NUM) ?
                                               VALID_CHAR_NUM : CHANNEL_OUT_NUM;

    // =============================================================
    // 1. 例化 Spatial Sum (同列通道累加)
    // =============================================================
    logic signed [PE_COL_NUM-1:0] [ACC_WIDTH-1:0] ss_y_out ;
    logic                        ss_new_line_out_1            /* synthesis syn_preserve=1 */;
    logic                        ss_output_valid              /* synthesis syn_preserve=1 */;

    lprnet_spatial_sum #(
        .PE_COL_NUM(PE_COL_NUM),
        .CYCLE_PERIOD_OUT(CYCLE_PERIOD_OUT),
        .IMG_COL(IMG_COL),
        .IMG_ROW(IMG_ROW),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_spatial_sum (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .new_line_input_1(new_line_input_1),
        .data_input_valid(data_input_valid),
        .data_input(data_input),
        
        .y_out(ss_y_out),
        .new_line_out_1(ss_new_line_out_1),
        .output_valid(ss_output_valid)
    );


    // =============================================================
    // 2. 例化 Extrema Finder (寻找极值通道)
    // =============================================================
    logic [ACC_WIDTH-1:0] ef_val_out                          /* synthesis syn_preserve=1 */;
    logic [CH_WIDTH-1:0]          ef_val_out_channel           /* synthesis syn_preserve=1 */;
    logic                         ef_val_valid                 /* synthesis syn_preserve=1 */;

    extrema_finder #(
        .DATA_WIDTH(ACC_WIDTH),         // 输入为累加器位宽
        .PE_COL_NUM(PE_COL_NUM),
        .CYCLE_PERIOD_OUT(CYCLE_PERIOD_OUT),
        .CHANNEL_OUT_NUM(CHANNEL_OUT_NUM),
        .VALID_CHANNEL_NUM(VALID_CHAR_LIMIT),
        .CONV_POSITIVE(CONV_POSITIVE)
    ) u_extrema_finder (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .data_input_valid(ss_output_valid), 
        .new_line_1(ss_new_line_out_1), 
        .data_in(ss_y_out),
        
        .val_out(ef_val_out),
        .val_out_channel(ef_val_out_channel),
        .val_valid(ef_val_valid)
    );


    // A crop boundary must not depend on whether CTC emits a character.
    // Coordinates are consumed once per crop, including blank/flush crops.
    localparam int TIME_WIDTH = (IMG_COL > 1) ? $clog2(IMG_COL) : 1;
    localparam [TIME_WIDTH-1:0] LAST_TIME_STEP = IMG_COL - 1;
    logic new_frame_flag;
    logic [TIME_WIDTH-1:0] time_step;
    logic [CH_WIDTH-1:0] prefix_char;
    logic ctc_match_reg;
    logic [CH_WIDTH-1:0] ctc_char_reg;
    logic last_s1, last_s2;
    wire ctc_match = ef_val_valid && (ef_val_out_channel < VALID_CHAR_LIMIT) &&
                     (ef_val_out_channel != BLANK_CHAR_CH) &&
                     (new_frame_flag || (ef_val_out_channel != prefix_char));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            new_frame_flag <= 1'b0;
            time_step      <= '0;
            prefix_char    <= BLANK_CHAR_CH;
            ctc_match_reg  <= 1'b0;
            ctc_char_reg   <= '0;
            last_s1        <= 1'b0;
            last_s2        <= 1'b0;
            out_valid      <= 1'b0;
            out_char       <= '0;
            frame_start_out <= 1'b0;
            frame_end_out   <= 1'b0;
        end else if (clk_en) begin
            frame_start_out <= 1'b0;
            if (ss_new_line_out_1) begin
                new_frame_flag <= 1'b1;
                time_step <= '0;
            end
            if (ef_val_valid) begin
                frame_start_out <= new_frame_flag;
                new_frame_flag <= 1'b0;
                prefix_char <= ef_val_out_channel;
                if (time_step == LAST_TIME_STEP) time_step <= '0;
                else                          time_step <= time_step + 1'b1;
            end
            ctc_match_reg <= ctc_match;
            ctc_char_reg  <= ef_val_out_channel;
            out_valid     <= ctc_match_reg;
            out_char      <= ctc_char_reg;
            last_s1       <= ef_val_valid && (time_step == LAST_TIME_STEP);
            last_s2       <= last_s1;
            frame_end_out <= last_s2;
        end
    end
endmodule
