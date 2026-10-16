`timescale 1ns/1ps
// Actual spatial_sum -> masked argmax -> user CPU executing C -> actual OSD.
// Only the last CNN layer's tensors are synthetic; convolution is not simulated.
module tb_lpr_cpu_post;
    logic clk=0,vclk=0,rst_n=0,clk_en=1,nl=0,dv=0,crop_nl=0;
    always #5 clk=~clk;
    always #7 vclk=~vclk;
    logic signed [3:0][9:0] data_in=0;
    wire [6:0] hw_ch,token,ch;
    wire hw_valid,hw_start,hw_end,tv,tf,tl,cv,fs,v,fe,fault,proto;
    wire [15:0] ox,oy;
    wire [31:0] id,accepted,dropped,completed,pc;
    logic [15:0] cx=100,cy=80;
    lprnet_post_process #(.PE_COL_NUM(4),.CYCLE_PERIOD_OUT(32),.IMG_COL(20),.IMG_ROW(5),
        .DATA_WIDTH(10),.ACC_WIDTH(13),.BLANK_CHAR(75),.VALID_CHAR_NUM(76)) post (
        .clk(clk),.clk_en(clk_en),.rst_n(rst_n),.new_line_input_1(nl),.data_input_valid(dv),.data_input(data_in),
        .out_char(hw_ch),.out_valid(hw_valid),.frame_start_out(hw_start),.frame_end_out(hw_end),
        .token_char(token),.token_valid(tv),.token_first(tf),.token_last(tl));
    lpr_cpu_soc #(.CROP_HEIGHT(20)) soc (
        .clk(clk),.rst_n(rst_n),.crop_new_line(crop_nl),.crop_x(cx),.crop_y(cy),
        .token_valid(tv),.token_first(tf),.token_last(tl),.token_char(token),
        .result_coord_valid(cv),.result_x(ox),.result_y(oy),.result_id(id),
        .frame_start(fs),.char_valid(v),.frame_end(fe),.out_char(ch),
        .cpu_fault(fault),.protocol_fault(proto),.accepted_jobs(accepted),.dropped_jobs(dropped),
        .completed_jobs(completed),.debug_pc(pc));
    logic vs=0;
    wire ovs,ohs,ode;
    wire [23:0] rgb;
    char_overlay #(.CROP_HEIGHT(1),.FONT_FILE("chars_16x16.mem"),.MAX_PLATES(16),
        .MAX_PLATE_CHARS(8),.MIN_PLATE_CHARS(7),.CONFIRM_RESULTS(2)) osd (
        .clk_video(vclk),.rst_n_video(rst_n),.video_vs_in(vs),.video_hs_in(1'b0),
        .video_de_in(1'b0),.video_rgb_in(24'h123456),.video_vs_out(ovs),
        .video_hs_out(ohs),.video_de_out(ode),.video_rgb_out(rgb),
        .clk_pe(clk),.rst_n_pe(rst_n),.x_min_in(ox),.y_min_in(oy),.new_line_1(cv),
        .out_char(ch),.out_valid(v),.frame_start_out(fs),.frame_end_out(fe));
    integer reference[0:15][0:19],lens[0:15];
    integer hw_id=-1,hw_pos=0,hw_ends=0,seen=0,pos=0,raw_count=0,raw_starts=0,raw_ends=0;
    logic cpu_active=0;
    always @(posedge clk) if(rst_n) begin
        if(fault || proto || osd.dbg_coord_error) $fatal(1,"integration fault pc=%h",pc);
        if(tv) begin
            raw_count++;
            if(token>=76) $fatal(1,"padding won argmax");
            if(tf) raw_starts++;
            if(tl) raw_ends++;
        end
        if(clk_en) begin
            if(hw_start) begin hw_id++;hw_pos=0;end
            if(hw_valid) begin reference[hw_id][hw_pos]=int'(hw_ch);hw_pos++;end
            if(hw_end) begin lens[hw_id]=hw_pos;hw_ends++;end
        end
        if(fs) begin
            if(id!=32'(seen) || cpu_active || ox!=100 || oy!=80) $fatal(1,"job/coordinate mismatch");
            cpu_active=1;pos=0;
        end
        if(v) begin
            if(!cpu_active || hw_ends<=seen || int'(ch)!=reference[seen][pos])
                $fatal(1,"CPU CTC differs from hardware CTC task=%0d pos=%0d",seen,pos);
            pos++;
        end
        if(fe) begin
            if(!cpu_active || v || pos!=lens[seen]) $fatal(1,"CTC crop boundary mismatch");
            seen++;cpu_active=0;
        end
    end
    task automatic frame(input int mode);
        int winner;
        // Metadata is captured at the first of the real crop's 20 input rows.
        for(int row=0;row<20;row++) begin
            @(negedge clk);crop_nl=1;
            @(negedge clk);crop_nl=0;
        end
        for(int row=0;row<5;row++) begin
            @(negedge clk);nl=1;dv=0;
            @(negedge clk);nl=0;
            for(int t=0;t<20;t++) begin
                winner=75;
                if(mode==1 && (t==1 || t==2 || t==4)) winner=51;
                if(mode==2 && t==0) winner=10;
                if(mode==2 && t==19) winner=51;
                if(mode==3 && t<14) winner=10+t/2;
                if(mode==4) winner=t;
                for(int c=0;c<32;c++) begin
                    @(negedge clk);dv=1;
                    for(int p=0;p<4;p++) begin
                        data_in[p]=(c+p*32==winner)?10'sd100:-10'sd100;
                        if(c+p*32==100) data_in[p]=10'sd400;
                    end
                    // Freeze the real reduction/argmax while the CPU keeps running.
                    if((mode==2 || mode==3) && c%11==3) begin
                        clk_en=0;
                        repeat(3) @(negedge clk);
                        clk_en=1;
                    end
                end
            end
            @(negedge clk);dv=0;
            repeat(8) @(negedge clk);
        end
        repeat(500) @(negedge clk);
    endtask
    initial begin
        repeat(5) @(negedge clk);rst_n=1;
        frame(0);frame(1);frame(2);
        if(seen!=3 || lens[0]!=0 || lens[1]!=2 || lens[2]!=2) $fatal(1,"reference fixtures invalid");
        frame(3);frame(3);
        repeat(30) @(negedge vclk);
        if(seen!=5 || osd.pending_valid==0 || osd.display_valid!=0) $fatal(1,"OSD confirmation/VS staging failed");
        @(negedge vclk);vs=1;
        repeat(2) @(negedge vclk);vs=0;
        repeat(2) @(negedge vclk);
        if(osd.display_valid!=16'b1 || osd.display_length[0]!=7 || osd.display_x[0]!=100 || osd.display_y[0]!=64)
            $fatal(1,"OSD did not atomically display CPU result");
        for(int i=0;i<7;i++) if(osd.display_text[0][i*7 +: 7]!=7'(10+i)) $fatal(1,"OSD text mismatch");
        frame(4);frame(0);
        if(seen!=7 || lens[5]!=20 || lens[6]!=0 || raw_count!=140 || raw_starts!=7 || raw_ends!=7 ||
           accepted!=7 || dropped!=0 || completed!=7 || osd.coord_count!=0)
            $fatal(1,"raw/decoded/coordinate accounting failed");
        $display("PASS real LPR post + CPU + OSD: 7 crops/140 tokens, CTC equivalent, padded logits masked, clock-enable stalls, blank/20-char results, paired coordinates and VS atomic display");
        $finish;
    end
    initial begin #3000000;$fatal(1,"post integration timeout");end
endmodule
