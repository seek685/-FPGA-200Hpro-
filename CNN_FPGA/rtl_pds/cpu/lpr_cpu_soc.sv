// Experimental same-clock RV32I + APB4 + CTC mailbox.
// 4 KiB asynchronous instruction ROM; 4 KiB synchronous byte-write data RAM.
module lpr_cpu_soc #(
    parameter ROM_FILE = "lpr_ctc.mem",
    parameter integer CROP_HEIGHT = 20,
    parameter integer QUEUE_DEPTH = 8
)(
    input logic clk, rst_n,
    input logic crop_new_line,
    input logic [15:0] crop_x, crop_y,
    input logic token_valid, token_first, token_last,
    input logic [6:0] token_char,
    output wire result_coord_valid,
    output wire [15:0] result_x, result_y,
    output wire [31:0] result_id,
    output wire frame_start, char_valid, frame_end,
    output wire [6:0] out_char,
    output wire cpu_fault, protocol_fault,
    output wire [31:0] accepted_jobs, dropped_jobs, completed_jobs,
    output wire [31:0] debug_pc
);
    logic [31:0] rom [0:1023];
    logic [31:0] ram [0:1023];
    initial $readmemh(ROM_FILE, rom);
    wire [31:0] instr = (debug_pc[31:12] == 20'h80000) ? rom[debug_pc[11:2]] : 32'h00000013;
    wire req_valid, req_write, req_ready;
    wire [31:0] req_addr, req_wdata, rsp_rdata;
    wire [1:0] req_size;
    wire bus_hold = cpu_fault || (req_valid && !req_ready);
    wire psel, penable, pwrite, pready, pslverr;
    wire [31:0] paddr, pwdata, prdata, fault_addr;
    wire [3:0] pstrb;
    wire [2:0] pprot;
    lwc_cpu u_cpu (
        .cpu_clk(clk), .cpu_rst(!rst_n), .bus_hold(bus_hold),
        .irom_addr(debug_pc), .irom_data(instr), .perip_valid(req_valid),
        .perip_addr(req_addr), .perip_wen(req_write), .perip_mask(req_size),
        .perip_wdata(req_wdata), .perip_rdata(rsp_rdata)
    );
    lwc_cpu_apb u_bus (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_write(req_write),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_size(req_size),
        .req_ready(req_ready), .rsp_rdata(rsp_rdata), .fault(cpu_fault), .fault_addr(fault_addr),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
        .pstrb(pstrb), .pprot(pprot), .pready(pready), .pslverr(pslverr), .prdata(prdata)
    );
    wire ram_sel = paddr[31:12] == 20'h80100;
    wire mailbox_sel = paddr[31:12] == 20'h40000;
    wire mailbox_ready, mailbox_error;
    wire [31:0] mailbox_rdata;
    logic [31:0] ram_rdata;
    integer byte_lane;
    always_ff @(posedge clk) begin
        if (psel && !penable && ram_sel && !pwrite) ram_rdata <= ram[paddr[11:2]];
        if (rst_n && psel && penable && pready && pwrite && ram_sel)
            for (byte_lane=0; byte_lane<4; byte_lane=byte_lane+1)
                if (pstrb[byte_lane]) ram[paddr[11:2]][byte_lane*8 +: 8] <= pwdata[byte_lane*8 +: 8];
    end
    assign pready = mailbox_sel ? mailbox_ready : 1'b1;
    assign prdata = ram_sel ? ram_rdata : (mailbox_sel ? mailbox_rdata : 32'd0);
    assign pslverr = mailbox_sel ? mailbox_error : !ram_sel;
    lpr_cpu_mailbox #(.CROP_HEIGHT(CROP_HEIGHT), .QUEUE_DEPTH(QUEUE_DEPTH)) u_mailbox (
        .clk(clk), .rst_n(rst_n), .crop_new_line(crop_new_line), .crop_x(crop_x), .crop_y(crop_y),
        .token_valid(token_valid), .token_first(token_first), .token_last(token_last), .token_char(token_char),
        .psel(psel && mailbox_sel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .pstrb(pstrb), .pready(mailbox_ready), .pslverr(mailbox_error), .prdata(mailbox_rdata),
        .result_coord_valid(result_coord_valid), .result_x(result_x), .result_y(result_y), .result_id(result_id),
        .frame_start(frame_start), .char_valid(char_valid), .frame_end(frame_end), .out_char(out_char),
        .protocol_fault(protocol_fault), .accepted_jobs(accepted_jobs), .dropped_jobs(dropped_jobs),
        .completed_jobs(completed_jobs)
    );
endmodule
