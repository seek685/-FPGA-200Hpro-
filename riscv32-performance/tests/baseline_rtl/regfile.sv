module regfile (
    // Clock and write enable
    input  logic        clk,
    input  logic        rst_n,
    input  logic        we,
    // Write address and data
    input  logic [4:0]  waddr,
    input  logic [31:0] wdata,
    // Read addresses and data
    input  logic [4:0]  raddr1,
    input  logic [4:0]  raddr2,
    output logic [31:0] rdata1,
    output logic [31:0] rdata2
);
    // 32-bit register file with 32 registers.
    logic [31:0] regs [0:31];

    // x0 is hardwired to zero by RV32I, so writes to address 0 are blocked.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) begin
                regs[i] <= 32'd0;
            end
        end else if (we && (waddr != 5'd0)) begin
            regs[waddr] <= wdata;
        end
    end

    // Return the corresponding data based on the read address; x0 always returns zero.
    always_comb begin
        if (raddr1 == 5'd0)
            rdata1 = 32'd0;
        else if (we && (waddr == raddr1))
            rdata1 = wdata;
        else
            rdata1 = regs[raddr1];

        if (raddr2 == 5'd0)
            rdata2 = 32'd0;
        else if (we && (waddr == raddr2))
            rdata2 = wdata;
        else
            rdata2 = regs[raddr2];
    end
endmodule
