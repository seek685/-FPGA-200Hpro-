// Assert immediately; release only after three destination-clock edges.
// Use a separate instance for every clock domain. The registers after this
// synchronizer still require ordinary recovery/removal timing analysis.
module reset_release_sync (
    input  wire clk,
    input  wire arst_n,
    output wire rst_n
);
    (* syn_preserve = 1 *) reg [2:0] release_pipe = 3'b000;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            release_pipe <= 3'b000;
        else
            release_pipe <= {release_pipe[1:0], 1'b1};
    end

    assign rst_n = release_pipe[2];
endmodule
