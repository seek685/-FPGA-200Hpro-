module board_top (
    input  wire sys_clk,
    input  wire rst_n,
    output wire uart_tx
);
    wire cpu_clk;
    wire pll_locked;
    wire reset_async = !rst_n || !pll_locked;
    reg [1:0] reset_sync = 2'b11;
    reg [5:0] reset_hold = 6'd0;

    cpu_pll120 u_pll (
        .clkin1(sys_clk),
        .clkout0(cpu_clk),
        .lock(pll_locked)
    );

    // Assert even without a running clock; release only in the CPU domain.
    always @(posedge cpu_clk or posedge reset_async) begin
        if (reset_async) begin
            reset_sync <= 2'b11;
            reset_hold <= 6'd0;
        end else begin
            reset_sync <= {reset_sync[0], 1'b0};
            if (reset_sync[1])
                reset_hold <= 6'd0;
            else if (!reset_hold[5])
                reset_hold <= reset_hold + 1'b1;
        end
    end

    cpu_soc u_soc (
        .clk(cpu_clk),
        .rst(reset_sync[1] || !reset_hold[5]),
        .uart_tx(uart_tx)
    );
endmodule
