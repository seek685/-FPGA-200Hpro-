`timescale 1ns/1ps
module tb_lpr_cpu_soc;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    logic nl=0,tv=0,tf=0,tl=0;
    logic [15:0] x=0,y=0;
    logic [6:0] token=75;
    wire cv,fs,v,fe,fault,protocol_fault;
    wire [15:0] ox,oy;
    wire [31:0] id,accepted,dropped,completed,pc;
    wire [6:0] ch;
    lpr_cpu_soc #(.CROP_HEIGHT(1)) dut(
        .clk(clk),.rst_n(rst_n),.crop_new_line(nl),.crop_x(x),.crop_y(y),
        .token_valid(tv),.token_first(tf),.token_last(tl),.token_char(token),
        .result_coord_valid(cv),.result_x(ox),.result_y(oy),.result_id(id),
        .frame_start(fs),.char_valid(v),.frame_end(fe),.out_char(ch),
        .cpu_fault(fault),.protocol_fault(protocol_fault),.accepted_jobs(accepted),
        .dropped_jobs(dropped),.completed_jobs(completed),.debug_pc(pc));
    integer expected[0:127][0:19],lengths[0:127],end_cycle[0:127];
    integer cycles=0,seen=0,pos=0,current=-1,last_id=-1,starts=0;
    integer min_latency=100000,max_latency=0;
    logic active=0,coord_seen=0;
    logic [31:0] rng=32'h200c7c;
    always @(posedge clk) if(rst_n) begin
        cycles++;
        if(fault || protocol_fault) $fatal(1,"SoC fault pc=%h bus=%0d protocol=%0d",pc,fault,protocol_fault);
        if(cv) begin
            if(active || coord_seen) $fatal(1,"overlapping result coordinates");
            if(int'(id)<=last_id || id>=128) $fatal(1,"task ID reordered/repeated");
            if(ox!=16'(20+id*3) || oy!=16'(40+id*2)) $fatal(1,"task/coordinate mismatch");
            coord_seen=1; current=int'(id);
        end
        if(fs) begin
            if(!coord_seen || active || v || fe) $fatal(1,"start boundary invalid");
            active=1; coord_seen=0; pos=0; starts++;
        end
        if(v) begin
            if(!active || pos>=lengths[current] || int'(ch)!=expected[current][pos])
                $fatal(1,"CTC mismatch task=%0d pos=%0d got=%0d expected=%0d",current,pos,ch,expected[current][pos]);
            pos++;
        end
        if(fe) begin
            if(!active || v || pos!=lengths[current]) $fatal(1,"incomplete CTC result");
            active=0; seen++; last_id=current;
            if(current<48) begin
                if(cycles-end_cycle[current]<min_latency) min_latency=cycles-end_cycle[current];
                if(cycles-end_cycle[current]>max_latency) max_latency=cycles-end_cycle[current];
            end
        end
    end
    task automatic submit(input int task_id,input int mode,input int gaps);
        int prev,symbol,n;
        @(negedge clk); nl=1; x=16'(20+task_id*3); y=16'(40+task_id*2);
        @(negedge clk); nl=0;
        prev=75; n=0;
        for(int t=0;t<20;t++) begin
            rng=1664525*rng+1013904223;
            symbol=int'(rng%76);
            case(mode)
                0:symbol=75;
                1:symbol=51;
                2:symbol=(t==0 || t==1 || t==3 || t==19)?51:75;
                3:symbol=t;
                4:symbol=(t==19)?0:75;
                default: if(t%4==0) symbol=75; else if(t%4==2) symbol=prev;
            endcase
            if(symbol!=75 && symbol!=prev) begin expected[task_id][n]=symbol; n++; end
            prev=symbol;
            @(negedge clk); tv=1;tf=(t==0);tl=(t==19);token=7'(symbol);
            if(gaps && t%3==1) begin
                @(negedge clk);tv=0;tf=0;tl=0;
                repeat(gaps) @(negedge clk);
            end
        end
        lengths[task_id]=n;
        @(negedge clk);tv=0;tf=0;tl=0;end_cycle[task_id]=cycles;
    endtask
    task automatic reset_scoreboard;
        rst_n=0;nl=0;tv=0;tf=0;tl=0;
        repeat(5) @(negedge clk);
        seen=0;starts=0;current=-1;last_id=-1;active=0;coord_seen=0;
        rst_n=1;
    endtask
    initial begin
        reset_scoreboard();
        for(int j=0;j<48;j++) begin
            submit(j,(j<5)?j:5,j%3);
            wait(seen==j+1);
            repeat(2) @(negedge clk);
        end
        if(dropped!=0 || accepted!=48 || completed!=48) $fatal(1,"isolated queue accounting");
        // Deliberately exceed the CPU service rate and the eight-job capacity.
        for(int j=48;j<80;j++) submit(j,5,0);
        repeat(10000) @(negedge clk);
        if(dropped==0 || accepted+dropped!=80 || completed!=accepted || seen!=int'(accepted))
            $fatal(1,"overflow did not drain intact jobs accepted=%0d dropped=%0d complete=%0d seen=%0d",accepted,dropped,completed,seen);
        $display("PASS CPU CTC: 48 isolated + 32 burst jobs, accepted=%0d whole_job_drops=%0d; isolated completion latency=%0d..%0d PE clocks",accepted,dropped,min_latency,max_latency);
        // Cancel an in-flight CPU job and a partially received next crop.
        submit(80,3,0);
        @(negedge clk);nl=1;
        @(negedge clk);nl=0;tv=1;tf=1;token=10;
        @(negedge clk);tf=0;
        @(negedge clk);reset_scoreboard();
        submit(0,2,1);
        wait(seen==1);repeat(20) @(negedge clk);
        if(accepted!=1 || dropped!=0 || completed!=1 || starts!=1) $fatal(1,"reset leaked an old task");
        $display("PASS CPU CTC reset: pending computation and partial input cancelled; no stale task output");
        $finish;
    end
    initial begin #10000000;$fatal(1,"SoC timeout pc=%h",pc);end
endmodule
