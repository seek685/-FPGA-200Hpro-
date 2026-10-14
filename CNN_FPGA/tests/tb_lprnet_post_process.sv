`timescale 1ns/1ps
module tb_lprnet_post_process;
    logic clk=0, rst_n=0, clk_en=1;
    always #5 clk=~clk;
    logic nl=0, valid=0;
    logic signed [3:0][9:0] data_in='0;
    wire [6:0] ch;
    wire ch_valid, frame_start, frame_end;
    integer starts=0, ends=0, count=0;
    integer decoded[0:19];
    integer tick=0, last_char_tick=-1;
    logic single_valid=0;
    logic signed [3:0][7:0] single_data='0;
    wire signed [7:0] single_max, single_min;
    wire [1:0] max_channel, min_channel;
    wire max_valid, min_valid;
    extrema_finder #(.DATA_WIDTH(8), .PE_COL_NUM(4), .CYCLE_PERIOD_OUT(1),
        .CHANNEL_OUT_NUM(4), .VALID_CHANNEL_NUM(3), .CONV_POSITIVE(1)) max_one(
        .clk(clk), .rst_n(rst_n), .clk_en(1'b1), .data_input_valid(single_valid),
        .new_line_1(1'b0), .data_in(single_data), .val_out(single_max),
        .val_out_channel(max_channel), .val_valid(max_valid));
    extrema_finder #(.DATA_WIDTH(8), .PE_COL_NUM(4), .CYCLE_PERIOD_OUT(1),
        .CHANNEL_OUT_NUM(4), .VALID_CHANNEL_NUM(3), .CONV_POSITIVE(0)) min_one(
        .clk(clk), .rst_n(rst_n), .clk_en(1'b1), .data_input_valid(single_valid),
        .new_line_1(1'b0), .data_in(single_data), .val_out(single_min),
        .val_out_channel(min_channel), .val_valid(min_valid));
    lprnet_post_process #(.PE_COL_NUM(4), .CYCLE_PERIOD_OUT(32),
        .IMG_COL(20), .IMG_ROW(5), .DATA_WIDTH(10), .ACC_WIDTH(13),
        .BLANK_CHAR(75), .VALID_CHAR_NUM(76)) dut (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .new_line_input_1(nl),
        .data_input_valid(valid), .data_input(data_in), .out_char(ch),
        .out_valid(ch_valid), .frame_start_out(frame_start), .frame_end_out(frame_end));
    always @(posedge clk) if (rst_n && clk_en) begin
        tick++;
        if(frame_start) starts++;
        if(ch_valid) begin
            if(count>=20) $fatal(1,"too many decoded characters");
            decoded[count]=int'(ch); count++; last_char_tick=tick;
        end
        if(frame_end) begin
            ends++;
            if(ch_valid || (tick<=last_char_tick)) $fatal(1,"end must follow final character");
        end
    end
    task automatic frame(input int mode);
        int winner;
        for(int row=0;row<5;row++) begin
            @(negedge clk); nl=1; valid=0;
            @(negedge clk); nl=0;
            for(int t=0;t<20;t++) begin
                winner=75;
                // Same label separated by blank must survive twice.
                if(mode==1 && (t==1 || t==2 || t==4)) winner=51;
                // Last time step is also a character; it must reach the OSD.
                if(mode==2 && t==0) winner=10;
                if(mode==2 && t==19) winner=51;
                for(int cy=0;cy<32;cy++) begin
                    @(negedge clk); valid=1;
                    for(int pe=0;pe<4;pe++) begin
                        data_in[pe]=(cy+pe*32==winner)?10'sd100:-10'sd100;
                        // Padding has a deliberately larger logit than all
                        // real classes. It must be masked before argmax.
                        if(cy+pe*32==100) data_in[pe]=10'sd400;
                    end
                    if(mode==2 && cy==8) begin
                        clk_en=0;
                        repeat(3) @(negedge clk);
                        clk_en=1;
                    end
                end
            end
            @(negedge clk); valid=0;
            repeat(8) @(negedge clk);
        end
        repeat(24) @(negedge clk);
    endtask
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        frame(0);
        if(starts!=1 || ends!=1 || count!=0) $fatal(1,"blank crop lost its boundary");
        frame(1);
        if(starts!=2 || ends!=2 || count!=2 || decoded[0]!=51 || decoded[1]!=51)
            $fatal(1,"CTC repeat/blank or padding mask failed");
        frame(2);
        if(starts!=3 || ends!=3 || count!=4 || decoded[2]!=10 || decoded[3]!=51)
            $fatal(1,"final time step or clock-enable handling failed");
        frame(0);
        if(starts!=4 || ends!=4 || count!=4) $fatal(1,"blank crop after characters failed");
        @(negedge clk); single_valid=1;
        single_data={8'sd127,8'sd9,8'sd7,8'sd10};
        @(negedge clk);
        if(!max_valid || !min_valid || single_max!=10 || max_channel!=0 || single_min!=7 || min_channel!=1)
            $fatal(1,"one-cycle extrema/padding mask failed");
        single_data={-8'sd128,-8'sd9,-8'sd7,-8'sd10};
        @(negedge clk); single_valid=0;
        if(!max_valid || !min_valid || single_max!=-7 || max_channel!=1 || single_min!=-10 || min_channel!=0)
            $fatal(1,"one-cycle extrema reused a previous pixel");
        $display("PASS CTC: blank boundaries, repeats, last character, padding mask, clock stalls");
        $finish;
    end
    initial begin #10000000; $fatal(1,"timeout"); end
endmodule
