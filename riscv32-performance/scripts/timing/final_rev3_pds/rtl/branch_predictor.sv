module branch_predictor #(
    parameter PC_WIDTH        = 32,
    parameter GHR_WIDTH       = 12,
    parameter PHT_INDEX_WIDTH = 12,
    parameter PHT_ENTRIES     = (1 << PHT_INDEX_WIDTH),
    parameter BTB_INDEX_WIDTH = 9,
    parameter BTB_ENTRIES     = (1 << BTB_INDEX_WIDTH),
    parameter BTB_TAG_WIDTH   = PC_WIDTH - BTB_INDEX_WIDTH - 2,
    parameter RAS_DEPTH       = 16
)(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic [PC_WIDTH-1:0]         if_pc,
    input  logic                       if_is_branch,
    input  logic [PC_WIDTH-1:0]         if_instr,
    input  logic                       if_accept,

    output logic                       if_pred_taken,
    output logic [PC_WIDTH-1:0]         if_pred_target,
    output logic [PHT_INDEX_WIDTH-1:0]  if_pht_index,
    output logic [GHR_WIDTH-1:0]        if_ghr_snapshot,

    input  logic                       ex_train_valid,
    input  logic [PC_WIDTH-1:0]         ex_branch_pc,
    input  logic [PHT_INDEX_WIDTH-1:0]  ex_pht_index,
    input  logic                       ex_actual_taken,
    input  logic [PC_WIDTH-1:0]         ex_actual_target,
    input  logic                       ex_is_branch,
    input  logic                       ex_is_jalr,
    input  logic                       ex_is_call,
    input  logic                       ex_is_return,
    input  logic                       ex_ghr_recover_valid,
    input  logic [GHR_WIDTH-1:0]        ex_ghr_recover_value
);
    localparam RAS_PTR_WIDTH = (RAS_DEPTH > 1) ? $clog2(RAS_DEPTH) : 1;
    localparam RAS_COUNT_WIDTH = $clog2(RAS_DEPTH + 1);

    logic [GHR_WIDTH-1:0] ghr_q;
    logic [1:0] pht_q [0:PHT_ENTRIES-1];
    logic btb_valid_q [0:BTB_ENTRIES-1];
    logic [BTB_TAG_WIDTH-1:0] btb_tag_q [0:BTB_ENTRIES-1];
    logic [PC_WIDTH-1:0] btb_target_q [0:BTB_ENTRIES-1];

    logic [PC_WIDTH-1:0] ras_q [0:RAS_DEPTH-1];
    logic [RAS_PTR_WIDTH-1:0] ras_ptr_q, ras_ptr_d;
    logic [RAS_COUNT_WIDTH-1:0] ras_count_q, ras_count_d;
    logic ras_write;
    logic [RAS_PTR_WIDTH-1:0] ras_write_index, ras_top_index;
    logic [PC_WIDTH-1:0] ras_link, ras_top, ras_target;

    logic [PHT_INDEX_WIDTH-1:0] if_history;
    logic [BTB_INDEX_WIDTH-1:0] if_btb_index, ex_btb_index;
    logic [BTB_TAG_WIDTH-1:0] if_btb_tag;
    logic if_btb_hit, if_is_jal, if_is_jalr, if_rd_link, if_rs1_link;
    logic if_is_return;
    logic [PC_WIDTH-1:0] if_jal_imm, if_jalr_imm;
    integer pht_init_index;
    integer history_bit;
    integer btb_init_index;

    function automatic [RAS_PTR_WIDTH-1:0] ras_inc(
        input [RAS_PTR_WIDTH-1:0] ptr
    );
        ras_inc = (ptr == RAS_DEPTH - 1) ? '0 : ptr + 1'b1;
    endfunction

    function automatic [RAS_PTR_WIDTH-1:0] ras_dec(
        input [RAS_PTR_WIDTH-1:0] ptr
    );
        ras_dec = (ptr == 0) ? RAS_DEPTH - 1 : ptr - 1'b1;
    endfunction

    // FPGA power-up initialization; warm resets deliberately retain training.
    initial begin
        for (pht_init_index = 0; pht_init_index < PHT_ENTRIES; pht_init_index = pht_init_index + 1)
            pht_q[pht_init_index] = 2'b01;
        for (btb_init_index = 0; btb_init_index < BTB_ENTRIES; btb_init_index = btb_init_index + 1)
            btb_valid_q[btb_init_index] = 1'b0;
    end

    // Fold history when a smaller PHT is selected instead of truncating it.
    always_comb begin
        if_history = '0;
        for (history_bit = 0; history_bit < GHR_WIDTH; history_bit = history_bit + 1)
            if_history[history_bit % PHT_INDEX_WIDTH] =
                if_history[history_bit % PHT_INDEX_WIDTH] ^ ghr_q[history_bit];
    end

    assign if_pht_index = if_pc[PHT_INDEX_WIDTH+1:2] ^ if_history;
    assign if_ghr_snapshot = ghr_q;
    assign if_btb_index = if_pc[BTB_INDEX_WIDTH+1:2];
    assign ex_btb_index = ex_branch_pc[BTB_INDEX_WIDTH+1:2];
    assign if_btb_tag = if_pc[PC_WIDTH-1:BTB_INDEX_WIDTH+2];
    assign if_btb_hit = btb_valid_q[if_btb_index] &&
                        btb_tag_q[if_btb_index] == if_btb_tag;

    assign if_is_jal = if_instr[6:0] == 7'b1101111;
    assign if_is_jalr = if_instr[6:0] == 7'b1100111 &&
                        if_instr[14:12] == 3'b000;
    assign if_rd_link = if_instr[11:7] == 5'd1 || if_instr[11:7] == 5'd5;
    assign if_rs1_link = if_instr[19:15] == 5'd1 || if_instr[19:15] == 5'd5;
    // RISC-V RAS hints: different link registers implement pop then push.
    assign if_is_return = if_is_jalr && if_rs1_link &&
                          (!if_rd_link || if_instr[11:7] != if_instr[19:15]);
    assign if_jal_imm = {{(PC_WIDTH-21){if_instr[31]}}, if_instr[31],
                         if_instr[19:12], if_instr[20], if_instr[30:21], 1'b0};
    assign if_jalr_imm = {{(PC_WIDTH-12){if_instr[31]}}, if_instr[31:20]};
    assign ras_link = ex_branch_pc + 4;

    // Only resolved instructions modify the stack. This avoids speculative
    // stack corruption when an older branch squashes younger calls/returns.
    // The IF read sees a same-cycle EX push/pop through this small bypass.
    always_comb begin
        ras_ptr_d = ras_ptr_q;
        ras_count_d = ras_count_q;
        ras_write = 1'b0;
        ras_write_index = ras_ptr_q;
        if (ex_train_valid) begin
            if (ex_is_return && ras_count_d != 0) begin
                ras_ptr_d = ras_dec(ras_ptr_d);
                ras_count_d = ras_count_d - 1'b1;
            end
            if (ex_is_call) begin
                ras_write = 1'b1;
                ras_write_index = ras_ptr_d;
                ras_ptr_d = ras_inc(ras_ptr_d);
                if (ras_count_d < RAS_DEPTH)
                    ras_count_d = ras_count_d + 1'b1;
            end
        end
    end

    assign ras_top_index = ras_dec(ras_ptr_d);
    assign ras_top = (ras_write && ras_write_index == ras_top_index) ?
                     ras_link : ras_q[ras_top_index];
    assign ras_target = (ras_top + if_jalr_imm) & {{(PC_WIDTH-1){1'b1}}, 1'b0};

    // Stalling does not suppress prediction. Only acceptance is allowed to
    // advance speculative history.
    always_comb begin
        if_pred_taken = 1'b0;
        if_pred_target = if_pc + 4;
        if (rst_n) begin
            if (if_is_jal) begin
                if_pred_taken = 1'b1;
                if_pred_target = if_pc + if_jal_imm;
            end
            else if (if_is_jalr) begin
                if (if_is_return && ras_count_d != 0) begin
                    if_pred_taken = 1'b1;
                    if_pred_target = ras_target;
                end
                else if (if_btb_hit) begin
                    if_pred_taken = 1'b1;
                    if_pred_target = btb_target_q[if_btb_index];
                end
            end
            else if (if_is_branch && if_btb_hit) begin
                if_pred_taken = pht_q[if_pht_index][1];
                if_pred_target = btb_target_q[if_btb_index];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ghr_q <= '0;
            ras_ptr_q <= '0;
            ras_count_q <= '0;
        end
        else begin
            if (ex_ghr_recover_valid)
                ghr_q <= ex_ghr_recover_value;
            else if (if_accept && if_is_branch)
                ghr_q <= (ghr_q << 1) | if_pred_taken;

            ras_ptr_q <= ras_ptr_d;
            ras_count_q <= ras_count_d;
            if (ras_write)
                ras_q[ras_write_index] <= ras_link;

            if (ex_train_valid && ex_is_branch) begin
                pht_q[ex_pht_index][1] <=
                    (pht_q[ex_pht_index][1] & pht_q[ex_pht_index][0]) |
                    (pht_q[ex_pht_index][1] & ex_actual_taken) |
                    (pht_q[ex_pht_index][0] & ex_actual_taken);
                pht_q[ex_pht_index][0] <=
                    ((ex_actual_taken | pht_q[ex_pht_index][1]) &
                     ~pht_q[ex_pht_index][0]) |
                    (pht_q[ex_pht_index][1] & ex_actual_taken);
            end
            // JAL has a decoded target and does not consume BTB capacity.
            if (ex_train_valid && ex_actual_taken && (ex_is_branch || ex_is_jalr)) begin
                btb_valid_q[ex_btb_index] <= 1'b1;
                btb_tag_q[ex_btb_index] <= ex_branch_pc[PC_WIDTH-1:BTB_INDEX_WIDTH+2];
                btb_target_q[ex_btb_index] <= ex_actual_target;
            end
        end
    end
endmodule
