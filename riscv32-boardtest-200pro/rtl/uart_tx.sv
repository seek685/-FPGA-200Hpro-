module uart_tx #(
    parameter integer CLK_HZ = 120_000_000,
    parameter integer BAUD_RATE = 115200
)(
    input wire clk,
    input wire rst,
    input wire start,
    input wire [7:0] data,
    output reg tx,
    output reg busy
);
    localparam integer DIVISOR = CLK_HZ / BAUD_RATE;
    localparam integer COUNT_WIDTH = (DIVISOR > 1) ? $clog2(DIVISOR) : 1;
    localparam [1:0] IDLE = 0, START = 1, DATA = 2, STOP = 3;
    reg [1:0] state;
    reg [COUNT_WIDTH-1:0] count;
    reg [7:0] shift;
    reg [2:0] bit_index;

    always @(posedge clk) begin
        if (rst) begin
            tx <= 1'b1;
            busy <= 1'b0;
            state <= IDLE;
            count <= 0;
            shift <= 0;
            bit_index <= 0;
        end else if (state == IDLE) begin
            tx <= 1'b1;
            if (start) begin
                tx <= 1'b0;
                busy <= 1'b1;
                shift <= data;
                bit_index <= 0;
                count <= DIVISOR - 1;
                state <= START;
            end
        end else if (count != 0) begin
            count <= count - 1'b1;
        end else begin
            count <= DIVISOR - 1;
            case (state)
                START: begin
                    tx <= shift[0];
                    state <= DATA;
                end
                DATA: begin
                    if (bit_index == 7) begin
                        tx <= 1'b1;
                        state <= STOP;
                    end else begin
                        bit_index <= bit_index + 1'b1;
                        tx <= shift[bit_index + 1'b1];
                    end
                end
                STOP: begin
                    busy <= 1'b0;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
