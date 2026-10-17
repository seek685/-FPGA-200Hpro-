module board_dram (
    input  wire clk,
    input  wire rst,
    input  wire [15:0] addr,
    input  wire [31:0] write_data,
    input  wire write_enable,
    input  wire read_enable,
    input  wire [1:0] size,
    output wire [31:0] read_data
);
    reg [31:0] mem [0:16383];
    wire [13:0] index = addr[15:2];
    reg [3:0] byte_enable;
    reg [31:0] lane_data;
    reg [31:0] read_word;
    reg [1:0] read_offset;
    reg [1:0] read_size;
    wire [31:0] shifted_word = read_word >> {read_offset, 3'b000};

    always @* begin
        byte_enable = 4'b0000;
        lane_data = write_data;
        case (size)
            2'b00: begin
                byte_enable = 4'b0001 << addr[1:0];
                lane_data = {4{write_data[7:0]}};
            end
            2'b01: begin
                byte_enable = addr[1] ? 4'b1100 : 4'b0011;
                lane_data = {2{write_data[15:0]}};
            end
            2'b10: byte_enable = 4'b1111;
            default: ;
        endcase
    end

    // No RAM reset or initialization: startup firmware initializes .data/.bss.
    // All four byte lanes share one synchronous read address (BRAM inference).
    always @(posedge clk) begin
        if (write_enable) begin
            if (byte_enable[0]) mem[index][7:0]   <= lane_data[7:0];
            if (byte_enable[1]) mem[index][15:8]  <= lane_data[15:8];
            if (byte_enable[2]) mem[index][23:16] <= lane_data[23:16];
            if (byte_enable[3]) mem[index][31:24] <= lane_data[31:24];
        end
        if (read_enable) read_word <= mem[index];
        if (rst) begin
            read_offset <= 0;
            read_size <= 2'b10;
        end else if (read_enable) begin
            read_offset <= addr[1:0];
            read_size <= size;
        end
    end

    assign read_data = (read_size == 2'b00) ? {24'd0, shifted_word[7:0]} :
                       (read_size == 2'b01) ? {16'd0, shifted_word[15:0]} :
                       (read_size == 2'b10) ? shifted_word : 32'd0;
endmodule
