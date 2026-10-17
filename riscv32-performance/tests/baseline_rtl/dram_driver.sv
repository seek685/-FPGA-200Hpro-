`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/22/2025 11:42:01 AM
// Design Name: 
// Module Name: dram_driver
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module dram_driver(
    input logic rst,
    input logic clk,
    input logic [17:0]perip_addr,//BRAM'low address 0x00000-0x3FFFF
    input logic [31:0]perip_wdata,
    input logic [1:0]perip_mask,
    input logic bram_wen,
    input logic bram_ren,
    output logic [31:0]perip_rdata
);
    //a as wirte   b as read
    logic [15:0] addra;
    logic [15:0] addrb;
    logic [3:0]  bram_we;
    logic [31:0] bram_din;
    logic [31:0] bram_dout;
    logic [1:0] read_offset_q;
    logic [1:0] read_mask_q;
    logic [1:0] offset;

    assign addra=perip_addr[17:2];
    assign addrb=perip_addr[17:2];
    assign offset=perip_addr[1:0];

    BRAM Mem_BRAM (
        .clka(clk),
        .clkb(clk),
        .ena(bram_wen),
        .enb(bram_ren),
        .addra(addra),
        .addrb(addrb),
        .wea(bram_wen?bram_we:4'b0000),
        .doutb(bram_dout),
        .dina(bram_din)
      
    );
    always_ff@(posedge clk)begin
        if(rst)begin
            read_offset_q<=2'd0;
            read_mask_q<=2'd0;
        end
        else if(bram_ren)begin
            read_offset_q<=perip_addr[1:0];
            read_mask_q<=perip_mask;
        end
    end
    
    // lw, lh lb
    logic [31:0] shifted_data;
    always_comb begin
        shifted_data=bram_dout>>(read_offset_q*8);
        case (read_mask_q)
            2'b00: // lb/lbu
                perip_rdata={24'b0,shifted_data[7:0]};
            2'b01:     //lh/lhu
                perip_rdata={16'b0,shifted_data[15:0]};
            2'b10:perip_rdata=shifted_data;//lw
            default: perip_rdata=32'd0;
        endcase
    end

    // sw, sh, sb
    always_comb begin
        bram_we=4'b0000;
        bram_din=32'd0;
        case (perip_mask)
            2'b10:begin
                bram_din=perip_wdata; // sw
                bram_we=4'b1111;
            end
            2'b01: begin // sh
                //bram_din={16'b0, perip_wdata[15:0]}<<(offset * 8);
                bram_din={2{perip_wdata[15:0]}};
                bram_we=offset[1]?4'b1100:4'b0011;
                //bram_we=4'b0011 << offset;
            end
            2'b00: begin// sb
                //bram_din={24'b0, perip_wdata[7:0]}<<(offset * 8);
                bram_din={4{perip_wdata[7:0]}};
                bram_we=4'b0001 << offset;
            end
            default: ;
        endcase
    end
endmodule
