`timescale 1ns/1ps
module tb_branch_unit;
    logic [31:0] rdata1, rdata2;
    logic [2:0] funct3;
    logic branch_1;
    logic [31:0] edges [0:25];
    logic [31:0] random_state = 32'h9e3779b9;
    logic [31:0] random_a, random_b;
    integer checks = 0;
    branch_unit dut (.*);

    function automatic [31:0] next_random(input [31:0] state_value);
        logic [31:0] value;
        value = state_value ^ (state_value << 13);
        value = value ^ (value >> 17);
        next_random = value ^ (value << 5);
    endfunction

    // Independent native operators are the reference, not the DUT's grouping.
    function automatic logic reference(input [31:0] a, input [31:0] b, input [2:0] op);
        case (op)
            3'b000: reference = a == b;
            3'b001: reference = a != b;
            3'b100: reference = $signed(a) < $signed(b);
            3'b101: reference = $signed(a) >= $signed(b);
            3'b110: reference = a < b;
            3'b111: reference = a >= b;
            default: reference = 0;
        endcase
    endfunction

    task automatic check_pair(input [31:0] a, input [31:0] b);
        rdata1 = a;
        rdata2 = b;
        for (integer op = 0; op < 8; op++) begin
            funct3 = op;
            #1;
            if (branch_1 !== reference(a, b, op))
                $fatal(1, "comparison mismatch a=%08x b=%08x funct3=%03b result=%b expected=%b",
                       a, b, funct3, branch_1, reference(a, b, op));
            checks = checks + 1;
        end
    endtask

    initial begin
        edges[0] = 32'h00000000; edges[1] = 32'h00000001;
        edges[2] = 32'hffffffff; edges[3] = 32'hfffffffe;
        edges[4] = 32'h7fffffff; edges[5] = 32'h80000000;
        edges[6] = 32'h80000001; edges[7] = 32'h7ffffffe;
        edges[8] = 32'h000000ff; edges[9] = 32'h00000100;
        edges[10] = 32'h00000101; edges[11] = 32'h0000ffff;
        edges[12] = 32'h00010000; edges[13] = 32'h00010001;
        edges[14] = 32'h00ffffff; edges[15] = 32'h01000000;
        edges[16] = 32'h01000001; edges[17] = 32'hff000000;
        edges[18] = 32'hffff0000; edges[19] = 32'hffffff00;
        edges[20] = 32'h55555555; edges[21] = 32'haaaaaaaa;
        edges[22] = 32'h80808080; edges[23] = 32'h7f7f7f7f;
        edges[24] = 32'h00800000; edges[25] = 32'h00008000;
        for (integer i = 0; i < 26; i++)
            for (integer j = 0; j < 26; j++)
                check_pair(edges[i], edges[j]);

        // Equal and adjacent pairs stress long equal prefixes and carry edges.
        for (integer i = 0; i < 100000; i++) begin
            random_state = next_random(random_state);
            random_a = random_state;
            random_state = next_random(random_state);
            case (i % 5)
                0: random_b = random_a;
                1: random_b = random_a + 1;
                2: random_b = random_a - 1;
                3: random_b = {random_a[31:8], random_state[7:0]};
                default: random_b = random_state;
            endcase
            check_pair(random_a, random_b);
        end
        $display("PASS tb_branch_unit checks=%0d", checks);
        $finish;
    end
endmodule
