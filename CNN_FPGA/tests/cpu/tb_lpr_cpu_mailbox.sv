`timescale 1ns/1ps
module tb_lpr_cpu_mailbox;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    logic nl=0,tv=0,tf=0,tl=0;
    logic [15:0] x=0,y=0;
    logic [6:0] token=0;
    logic psel=0,penable=0,pwrite=0;
    logic [31:0] addr=0,wdata=0;
    logic [3:0] strb=0;
    wire ready,error,cv,fs,v,fe,fault;
    wire [31:0] rdata,id,accepted,dropped,completed;
    wire [15:0] ox,oy;
    wire [6:0] ch;
    lpr_cpu_mailbox #(.CROP_HEIGHT(1),.QUEUE_DEPTH(2)) dut(
        .clk(clk),.rst_n(rst_n),.crop_new_line(nl),.crop_x(x),.crop_y(y),
        .token_valid(tv),.token_first(tf),.token_last(tl),.token_char(token),
        .psel(psel),.penable(penable),.pwrite(pwrite),.paddr(addr),.pwdata(wdata),.pstrb(strb),
        .pready(ready),.pslverr(error),.prdata(rdata),.result_coord_valid(cv),
        .result_x(ox),.result_y(oy),.result_id(id),.frame_start(fs),.char_valid(v),.frame_end(fe),
        .out_char(ch),.protocol_fault(fault),.accepted_jobs(accepted),.dropped_jobs(dropped),.completed_jobs(completed));
    integer expect_len[0:63],expect_ch[0:63][0:19],seen=0,pos=0,active_id=-1,simultaneous=0,waits=0;
    logic active=0,coord=0;
    always @(posedge clk) if(rst_n) begin
        if(psel&&penable&&!ready) waits++;
        if(dut.job_push && dut.job_pop) simultaneous++;
        if(cv) begin
            if(active || coord || ox!=16'(10+id) || oy!=16'(20+id)) $fatal(1,"mailbox coordinate association");
            coord=1;active_id=int'(id);
        end
        if(fs) begin if(!coord || active || v) $fatal(1,"result framing");coord=0;active=1;pos=0;end
        if(v) begin
            if(!active || int'(ch)!=expect_ch[active_id][pos]) $fatal(1,"shadow/result changed during emit");
            pos++;
        end
        if(fe) begin
            if(!active || v || pos!=expect_len[active_id]) $fatal(1,"result length/boundary");
            active=0;seen++;
        end
    end
    task automatic reset_all;
        @(negedge clk);rst_n=0;nl=0;tv=0;tf=0;tl=0;psel=0;penable=0;
        repeat(3) @(negedge clk);
        active=0;coord=0;seen=0;pos=0;active_id=-1;
        for(int i=0;i<64;i++) expect_len[i]=0;
        rst_n=1;
    endtask
    task automatic access(input bit wr,input int offset,input int value,input bit expect_error,output logic [31:0] readback);
        @(negedge clk);psel=1;penable=0;pwrite=wr;addr=32'h40000000+32'(offset);wdata=32'(value);strb=wr?15:0;
        @(negedge clk);penable=1;
        do @(posedge clk); while(!ready);
        if(error!=expect_error) $fatal(1,"APB error mismatch offset=%h value=%0d",offset,value);
        readback=rdata;
        @(negedge clk);psel=0;penable=0;
    endtask
    task automatic wr(input int offset,input int value,input bit err=0);
        logic [31:0] unused;
        access(1,offset,value,err,unused);
    endtask
    task automatic crop(input int task_id,input int steps=20);
        @(negedge clk);nl=1;x=16'(10+task_id);y=16'(20+task_id);
        @(negedge clk);nl=0;
        for(int t=0;t<steps;t++) begin
            @(negedge clk);tv=1;tf=(t==0);tl=(t==steps-1);token=7'(t);
        end
        @(negedge clk);tv=0;tf=0;tl=0;
    endtask
    logic [31:0] rb;
    initial begin
        reset_all();crop(0);
        // Pop the first job on exactly the clock that pushes the second job.
        fork
            crop(1);
            begin
                wait(tv && token==18);
                psel=1;penable=0;pwrite=1;addr=32'h40000014;wdata=0;strb=15;
                @(negedge clk);penable=1;
                @(posedge clk);if(!ready || error) $fatal(1,"simultaneous commit rejected");
                @(negedge clk);psel=0;penable=0;
            end
        join
        if(simultaneous!=1 || dut.job_count!=1) $fatal(1,"simultaneous queue accounting");
        access(0,4,0,0,rb);if(rb!=1) $fatal(1,"peek moved the head");
        access(0,4,0,0,rb);if(rb!=1) $fatal(1,"repeated peek moved head");
        wr('h14,99,1);wr('h10,21,1);wr('h100,75,1);
        wr('h10,1);wr('h14,1,1); // missing output byte cannot be published
        expect_len[1]=1;expect_ch[1][0]=10;
        wr('h100,10);wr('h14,1);
        repeat(10) @(negedge clk);
        if(accepted!=2 || completed!=2 || seen!=2 || fault) $fatal(1,"transaction error mutated job state");
        crop(2);crop(3);crop(4);
        if(dropped!=1 || accepted!=4) $fatal(1,"full queue not whole-job drop");
        wr('h14,2);wr('h14,3);
        repeat(10) @(negedge clk);
        crop(5);wr('h14,5);repeat(10) @(negedge clk);
        if(completed!=5 || seen!=5 || fault) $fatal(1,"drop shifted following coordinates");
        // Output busy holds COMMIT in APB ACCESS; next shadow cannot overwrite an emitted packet.
        reset_all();crop(0);crop(1);expect_len[0]=20;
        for(int i=0;i<20;i++) begin expect_ch[0][i]=i;wr('h100+i*4,i);end
        wr('h10,20);wr('h14,0);wr('h10,0);wr('h14,1);
        repeat(10) @(negedge clk);
        if(waits==0 || seen!=2 || completed!=2) $fatal(1,"output backpressure missing");
        reset_all();crop(0,3);
        if(!fault || accepted!=0) $fatal(1,"malformed packet not rejected");
        reset_all();
        for(int i=0;i<33;i++) begin
            @(negedge clk);nl=1;x=16'(10+i);y=16'(20+i);
            @(negedge clk);nl=0;
        end
        if(!fault) $fatal(1,"metadata overflow not fail closed");
        crop(33);if(accepted!=0) $fatal(1,"metadata error published misassociated result");
        reset_all();crop(0);wr('h14,0);repeat(10) @(negedge clk);
        if(fault || seen!=1) $fatal(1,"reset did not recover mailbox");
        $display("PASS mailbox: simultaneous push/pop, non-destructive reads, stale/missing/invalid commit rejection, full drop/recovery, output backpressure, malformed input, metadata overflow, reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"mailbox timeout");end
endmodule
