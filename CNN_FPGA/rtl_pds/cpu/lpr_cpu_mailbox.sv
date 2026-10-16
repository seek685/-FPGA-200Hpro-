// Single-clock, bounded hardware -> CPU -> OSD queue.
// Coordinates are paired BEFORE admission. A full queue drops a whole NEW job;
// it cannot shift later coordinates. No input backpressure is required by CNN.
module lpr_cpu_mailbox #(
    parameter integer CROP_HEIGHT = 20,
    parameter integer QUEUE_DEPTH = 8
)(
    input logic clk, rst_n,
    input logic crop_new_line,
    input logic [15:0] crop_x, crop_y,
    input logic token_valid, token_first, token_last,
    input logic [6:0] token_char,
    input logic psel, penable, pwrite,
    input logic [31:0] paddr, pwdata,
    input logic [3:0] pstrb,
    output logic pready, pslverr,
    output logic [31:0] prdata,
    output logic result_coord_valid,
    output logic [15:0] result_x, result_y,
    output logic [31:0] result_id,
    output logic frame_start, char_valid, frame_end,
    output logic [6:0] out_char,
    output wire protocol_fault,
    output logic [31:0] accepted_jobs, dropped_jobs, completed_jobs
);
    localparam integer QW = $clog2(QUEUE_DEPTH);
    localparam [QW:0] QUEUE_LIMIT = QUEUE_DEPTH[QW:0];
    localparam [15:0] LAST_CROP_LINE = CROP_HEIGHT[15:0] - 16'd1;
    initial begin
        if ((QUEUE_DEPTH < 2) || (QUEUE_DEPTH > 32) || ((QUEUE_DEPTH & (QUEUE_DEPTH-1)) != 0))
            $error("QUEUE_DEPTH must be a power of two between 2 and 32");
        if ((CROP_HEIGHT < 1) || (CROP_HEIGHT > 65536)) $error("Invalid CROP_HEIGHT");
    end
    logic [63:0] coords [0:31];
    logic [4:0] coord_wr, coord_rd;
    logic [5:0] coord_count;
    logic [15:0] crop_line;
    logic [31:0] next_id;
    logic coord_fault, token_fault;
    wire coord_pop = token_valid && token_first && (coord_count != 0);
    wire coord_request = crop_new_line && (crop_line == 0);
    wire coord_push = coord_request && ((coord_count < 32) || coord_pop);
    wire [63:0] coord_head = coords[coord_rd];
    assign protocol_fault = coord_fault || token_fault;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coord_wr <= 0; coord_rd <= 0; coord_count <= 0;
            crop_line <= 0; next_id <= 0; coord_fault <= 0;
        end else begin
            if (crop_new_line) begin
                if (crop_line == LAST_CROP_LINE) crop_line <= 0;
                else crop_line <= crop_line + 1'b1;
            end
            if (coord_request) next_id <= next_id + 1'b1;
            if (coord_push) begin
                coords[coord_wr] <= {next_id, crop_x, crop_y};
                coord_wr <= coord_wr + 1'b1;
            end
            if (coord_pop) coord_rd <= coord_rd + 1'b1;
            case ({coord_push, coord_pop})
                2'b10: coord_count <= coord_count + 1'b1;
                2'b01: coord_count <= coord_count - 1'b1;
                default: ;
            endcase
            if ((coord_request && !coord_push) || (token_valid && token_first && !coord_pop))
                coord_fault <= 1;
        end
    end

    logic [139:0] job_tokens [0:QUEUE_DEPTH-1];
    logic [63:0] job_meta [0:QUEUE_DEPTH-1];
    logic [QW-1:0] wr_ptr, rd_ptr;
    logic [QW:0] job_count;
    logic capture_active, capture_admitted;
    logic [4:0] capture_index;
    logic [139:0] capture_tokens;
    logic [63:0] capture_meta;
    wire [139:0] head_tokens = job_tokens[rd_ptr];
    wire [63:0] head_meta = job_meta[rd_ptr];
    wire job_push = token_valid && !token_first && token_last && capture_active &&
                    capture_admitted && (capture_index == 19) && !protocol_fault &&
                    (token_char < 76);

    localparam [2:0] EMIT_IDLE=0, EMIT_COORD=1, EMIT_START=2, EMIT_CHAR=3, EMIT_END=4;
    logic [2:0] emit_state;
    logic [4:0] emit_left;
    logic [139:0] emit_text, shadow_text;
    logic [19:0] shadow_written;
    logic [4:0] shadow_length;
    logic [31:0] cycles;
    wire [19:0] required_written = 20'hfffff >> (20 - shadow_length);
    wire token_addr = (paddr[11:0] >= 12'h040) && (paddr[11:0] <= 12'h08c);
    wire text_addr = (paddr[11:0] >= 12'h100) && (paddr[11:0] <= 12'h14c);
    wire [4:0] token_index = paddr[6:2] - 5'd16;
    wire [4:0] text_index = paddr[6:2];
    wire commit_addr = paddr[11:0] == 12'h014;
    wire apb_fire = psel && penable && pready;
    wire job_pop = apb_fire && pwrite && commit_addr && !pslverr;

    // APB register accesses are aligned full words. Byte lanes are supported
    // by the system RAM, but partial writes to control registers are errors.
    always_comb begin
        pready = !(psel && pwrite && commit_addr && (emit_state != EMIT_IDLE));
        prdata = 0;
        pslverr = 0;
        if (psel) begin
            if (paddr[1:0] != 0) pslverr = 1;
            else if (pwrite) begin
                if (pstrb != 4'b1111) pslverr = 1;
                else if (text_addr) pslverr = pwdata >= 75;
                else case (paddr[11:0])
                    12'h010: pslverr = pwdata > 20;
                    12'h014: pslverr = (job_count == 0) || (pwdata != head_meta[63:32]) ||
                                     ((shadow_written & required_written) != required_written);
                    default: pslverr = 1;
                endcase
            end else if (token_addr) begin
                if (job_count == 0) pslverr = 1;
                else prdata = {25'd0, head_tokens[token_index*7 +: 7]};
            end else case (paddr[11:0])
                12'h000: prdata = {30'd0, protocol_fault, (job_count != 0)};
                12'h004: begin prdata = head_meta[63:32]; pslverr = (job_count == 0); end
                12'h008: begin prdata = head_meta[31:0]; pslverr = (job_count == 0); end
                12'h00c: prdata = {{(31-QW){1'b0}}, job_count};
                12'h01c: prdata = dropped_jobs;
                12'h020: prdata = cycles;
                12'h024: prdata = accepted_jobs;
                12'h028: prdata = completed_jobs;
                default: pslverr = 1;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0; rd_ptr <= 0; job_count <= 0;
            capture_active <= 0; capture_admitted <= 0; capture_index <= 0;
            capture_tokens <= 0; capture_meta <= 0; token_fault <= 0;
            accepted_jobs <= 0; dropped_jobs <= 0;
        end else begin
            if (token_valid) begin
                if (token_first) begin
                    if (capture_active || token_last || (token_char >= 76)) token_fault <= 1;
                    capture_active <= 1;
                    capture_index <= 1;
                    capture_tokens <= {token_char, 133'd0};
                    capture_meta <= coord_head;
                    capture_admitted <= coord_pop && !protocol_fault && (job_count < QUEUE_LIMIT);
                    if (job_count == QUEUE_LIMIT) dropped_jobs <= dropped_jobs + 1'b1;
                end else if (capture_active) begin
                    capture_tokens <= {token_char, capture_tokens[139:7]};
                    capture_index <= capture_index + 1'b1;
                    if ((token_char >= 76) || (token_last != (capture_index == 19)))
                        token_fault <= 1;
                    if (token_last || (capture_index == 19)) capture_active <= 0;
                end else token_fault <= 1;
            end
            if (job_push) begin
                job_tokens[wr_ptr] <= {token_char, capture_tokens[139:7]};
                job_meta[wr_ptr] <= capture_meta;
                wr_ptr <= wr_ptr + 1'b1;
                accepted_jobs <= accepted_jobs + 1'b1;
            end
            if (job_pop) rd_ptr <= rd_ptr + 1'b1;
            case ({job_push, job_pop})
                2'b10: job_count <= job_count + 1'b1;
                2'b01: job_count <= job_count - 1'b1;
                default: ;
            endcase
        end
    end

    always_comb begin
        result_coord_valid = (emit_state == EMIT_COORD);
        frame_start = (emit_state == EMIT_START);
        char_valid = (emit_state == EMIT_CHAR);
        frame_end = (emit_state == EMIT_END);
        out_char = emit_text[6:0];
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            emit_state <= EMIT_IDLE; emit_text <= 0; emit_left <= 0;
            shadow_text <= 0; shadow_written <= 0; shadow_length <= 0;
            result_x <= 0; result_y <= 0; result_id <= 0;
            completed_jobs <= 0; cycles <= 0;
        end else begin
            cycles <= cycles + 1'b1;
            if (apb_fire && pwrite && !pslverr) begin
                if (text_addr) begin
                    shadow_text[text_index*7 +: 7] <= pwdata[6:0];
                    shadow_written[text_index] <= 1;
                end
                if (paddr[11:0] == 12'h010) shadow_length <= pwdata[4:0];
            end
            case (emit_state)
                EMIT_IDLE: if (job_pop) begin
                    result_id <= head_meta[63:32];
                    result_x <= head_meta[31:16]; result_y <= head_meta[15:0];
                    emit_text <= shadow_text; emit_left <= shadow_length;
                    shadow_written <= 0; shadow_length <= 0;
                    emit_state <= EMIT_COORD;
                end
                EMIT_COORD: emit_state <= EMIT_START;
                EMIT_START: emit_state <= (emit_left == 0) ? EMIT_END : EMIT_CHAR;
                EMIT_CHAR: begin
                    emit_text <= {7'd0, emit_text[139:7]};
                    emit_left <= emit_left - 1'b1;
                    if (emit_left == 1) emit_state <= EMIT_END;
                end
                EMIT_END: begin
                    emit_state <= EMIT_IDLE;
                    completed_jobs <= completed_jobs + 1'b1;
                end
                default: emit_state <= EMIT_IDLE;
            endcase
        end
    end
endmodule
