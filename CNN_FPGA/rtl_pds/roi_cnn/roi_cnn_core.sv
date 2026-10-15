// Fixed ROI classifier. All arithmetic runs on the FPGA; no CPU is required.
// RGB 28x28 -> Conv3x3(8), ReLU, Pool2 -> Conv3x3(16), ReLU,
// Pool2 -> FC32, ReLU -> FC4. Convolutions are valid, pooling floors 11 to 5.
// Feature memories use CHW order. Weights use OIHW (convolution) / OI (FC).
// RAM/ROM reads are synchronous. One signed 9x8 multiplier is shared by all
// layers. Biases and accumulators are signed 32-bit; hidden activations uint8.
module roi_cnn_core #(
    parameter SHIFT1 = 10,
    parameter SHIFT2 = 8,
    parameter SHIFT3 = 10,
    parameter W1_FILE = "../data_process/mem_data/roi_cnn/conv1_w.mem",
    parameter B1_FILE = "../data_process/mem_data/roi_cnn/conv1_b.mem",
    parameter W2_FILE = "../data_process/mem_data/roi_cnn/conv2_w.mem",
    parameter B2_FILE = "../data_process/mem_data/roi_cnn/conv2_b.mem",
    parameter W3_FILE = "../data_process/mem_data/roi_cnn/fc1_w.mem",
    parameter B3_FILE = "../data_process/mem_data/roi_cnn/fc1_b.mem",
    parameter W4_FILE = "../data_process/mem_data/roi_cnn/fc2_w.mem",
    parameter B4_FILE = "../data_process/mem_data/roi_cnn/fc2_b.mem"
)(
    input  wire clk,
    input  wire rst_n,
    input  wire image_wr_en,
    input  wire [9:0] image_wr_addr,
    input  wire [23:0] image_wr_rgb,
    // Start is accepted only while idle, at least one cycle after the last
    // image write. Image writes and further starts are ignored while busy.
    input  wire start,
    output reg busy,
    output reg done,
    output reg [1:0] class_id,
    output reg signed [31:0] score0,
    output reg signed [31:0] score1,
    output reg signed [31:0] score2,
    output reg signed [31:0] score3
);
    localparam [5:0] S_IDLE=0,
        S_C1_BIAS=1, S_C1_INIT=2, S_C1_READ=3, S_C1_MAC=4, S_C1_WRITE=5,
        S_P1_READ=6, S_P1_MAX=7, S_P1_WRITE=8,
        S_C2_BIAS=9, S_C2_INIT=10, S_C2_READ=11, S_C2_MAC=12, S_C2_WRITE=13,
        S_P2_READ=14, S_P2_MAX=15, S_P2_WRITE=16,
        S_F1_BIAS=17, S_F1_INIT=18, S_F1_READ=19, S_F1_MAC=20, S_F1_WRITE=21,
        S_F2_BIAS=22, S_F2_INIT=23, S_F2_READ=24, S_F2_MAC=25, S_F2_WRITE=26;
    reg [5:0] state;

    // Do not reset arrays: an image is loaded before start, and every used
    // intermediate address is overwritten before the following layer reads it.
    reg [23:0] image_mem [0:783];
    reg [7:0] conv1_mem [0:5407];  // 8 * 26 * 26
    reg [7:0] pool1_mem [0:1351];  // 8 * 13 * 13
    reg [7:0] conv2_mem [0:1935];  // 16 * 11 * 11
    reg [7:0] pool2_mem [0:399];   // 16 * 5 * 5
    reg [7:0] fc1_mem [0:31];
    reg signed [7:0] conv1_weights [0:215];
    reg signed [7:0] conv2_weights [0:1151];
    reg signed [7:0] fc1_weights [0:12799];
    reg signed [7:0] fc2_weights [0:127];
    reg signed [31:0] conv1_bias [0:7];
    reg signed [31:0] conv2_bias [0:15];
    reg signed [31:0] fc1_bias [0:31];
    reg signed [31:0] fc2_bias [0:3];
    initial begin
        if (W1_FILE != "") $readmemh(W1_FILE, conv1_weights);
        if (B1_FILE != "") $readmemh(B1_FILE, conv1_bias);
        if (W2_FILE != "") $readmemh(W2_FILE, conv2_weights);
        if (B2_FILE != "") $readmemh(B2_FILE, conv2_bias);
        if (W3_FILE != "") $readmemh(W3_FILE, fc1_weights);
        if (B3_FILE != "") $readmemh(B3_FILE, fc1_bias);
        if (W4_FILE != "") $readmemh(W4_FILE, fc2_weights);
        if (B4_FILE != "") $readmemh(B4_FILE, fc2_bias);
    end

    reg [4:0] out_ch, out_x, out_y;
    reg [3:0] in_ch;
    reg [1:0] kernel_x, kernel_y;
    reg [8:0] element_idx;
    reg [3:0] pool_ch, pool_x, pool_y;
    reg [1:0] pool_offset;
    reg [7:0] pool_max, activation;
    reg signed [31:0] accumulator, best_score;
    reg [1:0] best_class;

    // Constant-stride address expressions synthesize to shifts/adders.
    wire [9:0] image_rd_addr = ({5'd0, out_y} + {8'd0, kernel_y}) * 10'd28 +
        {5'd0, out_x} + {8'd0, kernel_x};
    wire [7:0] w1_addr = {3'd0, out_ch} * 8'd27 + {4'd0, in_ch} * 8'd9 +
        {6'd0, kernel_y} * 8'd3 + {6'd0, kernel_x};
    wire [10:0] w2_addr = {6'd0, out_ch} * 11'd72 + {7'd0, in_ch} * 11'd9 +
        {9'd0, kernel_y} * 11'd3 + {9'd0, kernel_x};
    wire [13:0] w3_addr = {9'd0, out_ch} * 14'd400 + {5'd0, element_idx};
    wire [6:0] w4_addr = {out_ch[1:0], element_idx[4:0]};
    wire [12:0] c1_write_addr = {8'd0, out_ch} * 13'd676 +
        {8'd0, out_y} * 13'd26 + {8'd0, out_x};
    wire [10:0] c2_write_addr = {6'd0, out_ch} * 11'd121 +
        {6'd0, out_y} * 11'd11 + {6'd0, out_x};
    wire [12:0] c1_read_addr = {9'd0, pool_ch} * 13'd676 +
        {8'd0, pool_y, pool_offset[1]} * 13'd26 + {8'd0, pool_x, pool_offset[0]};
    wire [10:0] c2_read_addr = {7'd0, pool_ch} * 11'd121 +
        {6'd0, pool_y, pool_offset[1]} * 11'd11 + {6'd0, pool_x, pool_offset[0]};
    wire [10:0] p1_write_addr = {7'd0, pool_ch} * 11'd169 +
        {7'd0, pool_y} * 11'd13 + {7'd0, pool_x};
    wire [8:0] p2_write_addr = {5'd0, pool_ch} * 9'd25 +
        {5'd0, pool_y} * 9'd5 + {5'd0, pool_x};
    wire [10:0] p1_read_addr = {7'd0, in_ch} * 11'd169 +
        ({6'd0, out_y} + {9'd0, kernel_y}) * 11'd13 +
        {6'd0, out_x} + {9'd0, kernel_x};

    reg [23:0] image_q;
    reg [7:0] c1_q, c2_q, p1_q, p2_q, f1_q;
    reg signed [7:0] w1_q, w2_q, w3_q, w4_q;
    reg signed [31:0] b1_q, b2_q, b3_q, b4_q;
    // One synchronous read port and one write port per feature RAM.
    always @(posedge clk) begin
        if (image_wr_en && !busy && (image_wr_addr < 10'd784))
            image_mem[image_wr_addr] <= image_wr_rgb;
        if (state == S_C1_READ) begin
            image_q <= image_mem[image_rd_addr];
            w1_q <= conv1_weights[w1_addr];
        end
        if (state == S_C1_BIAS) b1_q <= conv1_bias[out_ch[2:0]];
        if (state == S_C1_WRITE) conv1_mem[c1_write_addr] <= activation;
        if (state == S_P1_READ) c1_q <= conv1_mem[c1_read_addr];
        if (state == S_P1_WRITE) pool1_mem[p1_write_addr] <= pool_max;
        if (state == S_C2_READ) begin
            p1_q <= pool1_mem[p1_read_addr];
            w2_q <= conv2_weights[w2_addr];
        end
        if (state == S_C2_BIAS) b2_q <= conv2_bias[out_ch[3:0]];
        if (state == S_C2_WRITE) conv2_mem[c2_write_addr] <= activation;
        if (state == S_P2_READ) c2_q <= conv2_mem[c2_read_addr];
        if (state == S_P2_WRITE) pool2_mem[p2_write_addr] <= pool_max;
        if (state == S_F1_READ) begin
            p2_q <= pool2_mem[element_idx];
            w3_q <= fc1_weights[w3_addr];
        end
        if (state == S_F1_BIAS) b3_q <= fc1_bias[out_ch];
        if (state == S_F1_WRITE) fc1_mem[out_ch] <= activation;
        if (state == S_F2_READ) begin
            f1_q <= fc1_mem[element_idx[4:0]];
            w4_q <= fc2_weights[w4_addr];
        end
        if (state == S_F2_BIAS) b4_q <= fc2_bias[out_ch[1:0]];
    end

    reg [7:0] mac_data;
    reg signed [7:0] mac_weight;
    always @* begin
        mac_data = 0;
        mac_weight = 0;
        case (state)
            S_C1_MAC: begin
                case (in_ch)
                    0: mac_data = image_q[23:16];
                    1: mac_data = image_q[15:8];
                    default: mac_data = image_q[7:0];
                endcase
                mac_weight = w1_q;
            end
            S_C2_MAC: begin mac_data = p1_q; mac_weight = w2_q; end
            S_F1_MAC: begin mac_data = p2_q; mac_weight = w3_q; end
            S_F2_MAC: begin mac_data = f1_q; mac_weight = w4_q; end
            default: ;
        endcase
    end
    wire signed [8:0] mac_unsigned_data = {1'b0, mac_data};
    wire signed [16:0] mac_product = mac_unsigned_data * mac_weight;
    wire signed [31:0] mac_sum = accumulator + {{15{mac_product[16]}}, mac_product};

    function automatic [7:0] relu_shift_clip;
        input signed [31:0] value;
        input integer shift;
        reg signed [31:0] shifted;
        begin
            shifted = value >>> shift;
            if (shifted < 0) relu_shift_clip = 8'd0;
            else if (shifted > 255) relu_shift_clip = 8'd255;
            else relu_shift_clip = shifted[7:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy <= 0; done <= 0; class_id <= 0;
            score0 <= 0; score1 <= 0; score2 <= 0; score3 <= 0;
            out_ch <= 0; out_x <= 0; out_y <= 0; in_ch <= 0;
            kernel_x <= 0; kernel_y <= 0; element_idx <= 0;
            pool_ch <= 0; pool_x <= 0; pool_y <= 0; pool_offset <= 0;
            pool_max <= 0; activation <= 0; accumulator <= 0;
            best_score <= 0; best_class <= 0;
        end else begin
            done <= 0;
            case (state)
                S_IDLE: if (start) begin
                    busy <= 1;
                    out_ch <= 0; out_x <= 0; out_y <= 0;
                    state <= S_C1_BIAS;
                end
                S_C1_BIAS: state <= S_C1_INIT;
                S_C1_INIT: begin
                    accumulator <= b1_q;
                    in_ch <= 0; kernel_y <= 0; kernel_x <= 0;
                    state <= S_C1_READ;
                end
                S_C1_READ: state <= S_C1_MAC;
                S_C1_MAC: begin
                    accumulator <= mac_sum;
                    if ((in_ch == 2) && (kernel_y == 2) && (kernel_x == 2)) begin
                        activation <= relu_shift_clip(mac_sum, SHIFT1);
                        state <= S_C1_WRITE;
                    end else begin
                        if (kernel_x == 2) begin
                            kernel_x <= 0;
                            if (kernel_y == 2) begin kernel_y <= 0; in_ch <= in_ch + 1'b1; end
                            else kernel_y <= kernel_y + 1'b1;
                        end else kernel_x <= kernel_x + 1'b1;
                        state <= S_C1_READ;
                    end
                end
                S_C1_WRITE: begin
                    state <= S_C1_BIAS;
                    if (out_x == 25) begin
                        out_x <= 0;
                        if (out_y == 25) begin
                            out_y <= 0;
                            if (out_ch == 7) begin
                                pool_ch <= 0; pool_x <= 0; pool_y <= 0;
                                pool_offset <= 0; pool_max <= 0;
                                state <= S_P1_READ;
                            end else out_ch <= out_ch + 1'b1;
                        end else out_y <= out_y + 1'b1;
                    end else out_x <= out_x + 1'b1;
                end
                S_P1_READ: state <= S_P1_MAX;
                S_P1_MAX: begin
                    if (c1_q > pool_max) pool_max <= c1_q;
                    if (pool_offset == 3) state <= S_P1_WRITE;
                    else begin pool_offset <= pool_offset + 1'b1; state <= S_P1_READ; end
                end
                S_P1_WRITE: begin
                    pool_offset <= 0; pool_max <= 0;
                    state <= S_P1_READ;
                    if (pool_x == 12) begin
                        pool_x <= 0;
                        if (pool_y == 12) begin
                            pool_y <= 0;
                            if (pool_ch == 7) begin
                                out_ch <= 0; out_x <= 0; out_y <= 0;
                                state <= S_C2_BIAS;
                            end else pool_ch <= pool_ch + 1'b1;
                        end else pool_y <= pool_y + 1'b1;
                    end else pool_x <= pool_x + 1'b1;
                end
                S_C2_BIAS: state <= S_C2_INIT;
                S_C2_INIT: begin
                    accumulator <= b2_q;
                    in_ch <= 0; kernel_y <= 0; kernel_x <= 0;
                    state <= S_C2_READ;
                end
                S_C2_READ: state <= S_C2_MAC;
                S_C2_MAC: begin
                    accumulator <= mac_sum;
                    if ((in_ch == 7) && (kernel_y == 2) && (kernel_x == 2)) begin
                        activation <= relu_shift_clip(mac_sum, SHIFT2);
                        state <= S_C2_WRITE;
                    end else begin
                        if (kernel_x == 2) begin
                            kernel_x <= 0;
                            if (kernel_y == 2) begin kernel_y <= 0; in_ch <= in_ch + 1'b1; end
                            else kernel_y <= kernel_y + 1'b1;
                        end else kernel_x <= kernel_x + 1'b1;
                        state <= S_C2_READ;
                    end
                end
                S_C2_WRITE: begin
                    state <= S_C2_BIAS;
                    if (out_x == 10) begin
                        out_x <= 0;
                        if (out_y == 10) begin
                            out_y <= 0;
                            if (out_ch == 15) begin
                                pool_ch <= 0; pool_x <= 0; pool_y <= 0;
                                pool_offset <= 0; pool_max <= 0;
                                state <= S_P2_READ;
                            end else out_ch <= out_ch + 1'b1;
                        end else out_y <= out_y + 1'b1;
                    end else out_x <= out_x + 1'b1;
                end
                S_P2_READ: state <= S_P2_MAX;
                S_P2_MAX: begin
                    if (c2_q > pool_max) pool_max <= c2_q;
                    if (pool_offset == 3) state <= S_P2_WRITE;
                    else begin pool_offset <= pool_offset + 1'b1; state <= S_P2_READ; end
                end
                S_P2_WRITE: begin
                    pool_offset <= 0; pool_max <= 0;
                    state <= S_P2_READ;
                    if (pool_x == 4) begin
                        pool_x <= 0;
                        if (pool_y == 4) begin
                            pool_y <= 0;
                            if (pool_ch == 15) begin out_ch <= 0; state <= S_F1_BIAS; end
                            else pool_ch <= pool_ch + 1'b1;
                        end else pool_y <= pool_y + 1'b1;
                    end else pool_x <= pool_x + 1'b1;
                end
                S_F1_BIAS: state <= S_F1_INIT;
                S_F1_INIT: begin accumulator <= b3_q; element_idx <= 0; state <= S_F1_READ; end
                S_F1_READ: state <= S_F1_MAC;
                S_F1_MAC: begin
                    accumulator <= mac_sum;
                    if (element_idx == 399) begin
                        activation <= relu_shift_clip(mac_sum, SHIFT3);
                        state <= S_F1_WRITE;
                    end else begin element_idx <= element_idx + 1'b1; state <= S_F1_READ; end
                end
                S_F1_WRITE: begin
                    if (out_ch == 31) begin out_ch <= 0; state <= S_F2_BIAS; end
                    else begin out_ch <= out_ch + 1'b1; state <= S_F1_BIAS; end
                end
                S_F2_BIAS: state <= S_F2_INIT;
                S_F2_INIT: begin accumulator <= b4_q; element_idx <= 0; state <= S_F2_READ; end
                S_F2_READ: state <= S_F2_MAC;
                S_F2_MAC: begin
                    accumulator <= mac_sum;
                    if (element_idx == 31) state <= S_F2_WRITE;
                    else begin element_idx <= element_idx + 1'b1; state <= S_F2_READ; end
                end
                S_F2_WRITE: begin
                    case (out_ch)
                        0: score0 <= accumulator;
                        1: score1 <= accumulator;
                        2: score2 <= accumulator;
                        3: score3 <= accumulator;
                        default: ;
                    endcase
                    // Strict comparison gives the first class on ties. Always
                    // initialize from class 0 so all-negative logits work.
                    if ((out_ch == 0) || (accumulator > best_score)) begin
                        best_score <= accumulator;
                        best_class <= out_ch[1:0];
                    end
                    if (out_ch == 3) begin
                        class_id <= (accumulator > best_score) ? 2'd3 : best_class;
                        done <= 1; busy <= 0; state <= S_IDLE;
                    end else begin out_ch <= out_ch + 1'b1; state <= S_F2_BIAS; end
                end
                default: begin busy <= 0; state <= S_IDLE; end
            endcase
        end
    end
endmodule
