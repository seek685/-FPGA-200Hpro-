module max_pool2d #(
    parameter int unsigned PE_ROW_NUM = 9,
    parameter int unsigned DATA_WIDTH = 7
) (
    input  logic                  clk,
    input  logic                  clk_en,
    input  logic                  rst_n,
    
    // 控制信号输入
    input  logic                  new_line_1,
    input  logic                  input_valid,
    
    // 数据输入 (针对单个 page 传入的 PE_ROW_NUM 个数据)
    input  logic   [PE_ROW_NUM-1:0] [DATA_WIDTH-1:0] data,
    
    // 数据与控制信号输出
    output logic   [DATA_WIDTH-1:0] y_out,
    output logic                  new_line_out_1,
    output logic                  output_valid
);

    // =============================================================
    // 1. 控制信号打两拍 (2-Cycle Delay)
    // =============================================================
    logic [1:0] new_line_delay;
    logic [1:0] valid_delay;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            new_line_delay <= '0;
            valid_delay    <= '0;
        end else if (clk_en) begin
            new_line_delay <= {new_line_delay[0], new_line_1};
            valid_delay    <= {valid_delay[0], input_valid};
        end
    end

    assign new_line_out_1 = new_line_delay[1];
    assign output_valid      = valid_delay[1];

    // =============================================================
    // 2. 平衡比较树，平均分配到原有的两个流水级 (Cycle 1)
    // =============================================================
    // The former five-element half used four serial compare/mux operations.
    // For the actual 3x3 pool, this tree uses at most two comparisons in
    // either cycle, while preserving latency, clk_en and control alignment.
    // Values are unsigned, so unused leaves can be padded with zero.
    localparam int TREE_LEVELS = (PE_ROW_NUM > 1) ? $clog2(PE_ROW_NUM) : 0;
    localparam int GROUP_SIZE = 1 << ((TREE_LEVELS + 1) / 2);
    localparam int GROUP_COUNT = 1 << (TREE_LEVELS / 2);

    logic [DATA_WIDTH-1:0] group_max [0:GROUP_COUNT-1];
    generate
        for (genvar group_idx = 0; group_idx < GROUP_COUNT; group_idx = group_idx + 1) begin : gen_groups
            for (genvar node = 1; node < 2*GROUP_SIZE; node = node + 1) begin : gen_tree
                wire [DATA_WIDTH-1:0] value;
                if (node >= GROUP_SIZE) begin : gen_leaf
                    if (group_idx*GROUP_SIZE + node-GROUP_SIZE < PE_ROW_NUM) begin : gen_data
                        assign value = data[group_idx*GROUP_SIZE + node-GROUP_SIZE];
                    end else begin : gen_padding
                        assign value = '0;
                    end
                end else begin : gen_compare
                    assign value = (gen_tree[2*node].value > gen_tree[2*node+1].value) ?
                                    gen_tree[2*node].value : gen_tree[2*node+1].value;
                end
            end
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    group_max[group_idx] <= '0;
                else if (clk_en)
                    group_max[group_idx] <= gen_tree[1].value;
            end
        end
    endgenerate

    // =============================================================
    // 3. 第二级流水线：平衡合并各组最大值 (Cycle 2)
    // =============================================================
    logic [DATA_WIDTH-1:0] reg_max_final;

    generate
        for (genvar node = 1; node < 2*GROUP_COUNT; node = node + 1) begin : gen_final_tree
            wire [DATA_WIDTH-1:0] value;
            if (node >= GROUP_COUNT) begin : gen_leaf
                assign value = group_max[node-GROUP_COUNT];
            end else begin : gen_compare
                assign value = (gen_final_tree[2*node].value > gen_final_tree[2*node+1].value) ?
                                gen_final_tree[2*node].value : gen_final_tree[2*node+1].value;
            end
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_max_final <= '0;
        end else if (clk_en) begin
            reg_max_final <= gen_final_tree[1].value;
        end
    end

    // =============================================================
    // 4. 输出分发：将计算结果分配给所有的 PE_COL
    // =============================================================
    assign y_out = reg_max_final;

endmodule
