`timescale 1ns/1ps
module tb_cpu_core;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic [31:0] rom[0:16383], ram[0:1023];
    wire [31:0] pc, instr, req_addr, req_wdata;
    wire [1:0] req_size;
    wire req_write, req_valid;
    logic [31:0] rsp_rdata;
    wire bus_hold;
    integer cycles=0, predicted=0, redirects=0, waits=0, runs=0;
    logic [31:0] host_value=0;
    logic [1:0] saved_pht[0:4095];
    logic saved_btb_valid[0:511];
    logic [20:0] saved_btb_tag[0:511];
    logic [31:0] saved_btb_target[0:511];
    assign instr=rom[pc[15:2]];
`ifdef ORIGINAL_CPU
    assign bus_hold=0;
    assign req_valid=(req_addr!=0) && rst_n;
    myCPU dut(.cpu_clk(clk), .cpu_rst(!rst_n), .irom_addr(pc), .irom_data(instr),
        .perip_addr(req_addr), .perip_wen(req_write), .perip_mask(req_size),
        .perip_wdata(req_wdata), .perip_rdata(rsp_rdata));
    always @(posedge clk) if (rst_n && req_valid) begin
        if (req_addr==32'h40001000 && req_write) host_value<=req_wdata;
        else if(req_addr[31:12]==20'h80100) begin
            if(req_write) begin
                case(req_size)
                    0: ram[req_addr[11:2]][req_addr[1:0]*8 +: 8] <= req_wdata[7:0];
                    1: ram[req_addr[11:2]][req_addr[1]*16 +: 16] <= req_wdata[15:0];
                    2: ram[req_addr[11:2]] <= req_wdata;
                endcase
            end else rsp_rdata<=ram[req_addr[11:2]] >> (req_addr[1:0]*8);
        end else $fatal(1,"unexpected CPU address %h",req_addr);
    end
`else
    wire req_ready, fault, psel, penable, pwrite;
    wire [31:0] paddr, pwdata, fault_addr;
    wire [3:0] pstrb;
    wire [2:0] pprot;
    logic pready;
    logic [31:0] prdata;
    logic [3:0] wait_left=0;
    integer transfers=0;
    assign bus_hold=fault || (req_valid && !req_ready);
    lwc_cpu dut(.cpu_clk(clk), .cpu_rst(!rst_n), .bus_hold(bus_hold), .perip_valid(req_valid),
        .irom_addr(pc), .irom_data(instr), .perip_addr(req_addr), .perip_wen(req_write),
        .perip_mask(req_size), .perip_wdata(req_wdata), .perip_rdata(rsp_rdata));
    lwc_cpu_apb bridge(.clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_write(req_write),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_size(req_size), .req_ready(req_ready),
        .rsp_rdata(rsp_rdata), .fault(fault), .fault_addr(fault_addr),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
        .pstrb(pstrb), .pprot(pprot), .pready(pready), .pslverr(1'b0), .prdata(prdata));
    assign pready=(wait_left==0);
    assign prdata=ram[paddr[11:2]];
    logic old_wait=0;
    logic [68:0] old_controls;
    always @(posedge clk) begin
        if(!rst_n) begin wait_left<=0; old_wait<=0; end
        else begin
            if(fault) $fatal(1,"bus fault %h",fault_addr);
            if(old_wait && {paddr,pwdata,pstrb,pwrite}!==old_controls)
                $fatal(1,"APB controls changed during wait");
            if(old_wait && (!psel || !penable)) $fatal(1,"APB dropped during wait");
            old_wait<=psel && penable && !pready;
            old_controls<={paddr,pwdata,pstrb,pwrite};
            if(psel && !penable) wait_left<=4'(transfers%8);
            if(psel && penable) begin
                if(!pready) wait_left<=wait_left-1'b1;
                else begin
                    transfers<=transfers+1;
                    if(!pwrite && pstrb!=0) $fatal(1,"read strobes nonzero");
                    if(pwrite) begin
                        if(paddr==32'h40001000) host_value<=pwdata;
                        else if(paddr[31:12]==20'h80100) begin
                            for(int b=0;b<4;b++) if(pstrb[b]) ram[paddr[11:2]][b*8 +: 8]<=pwdata[b*8 +: 8];
                        end else $fatal(1,"unexpected APB address %h",paddr);
                    end
                end
            end
        end
    end
`endif
    always @(posedge clk) if(rst_n) begin
        cycles++;
        if(bus_hold) waits++;
        if(!bus_hold && dut.if_pred_taken) predicted++;
        if(!bus_hold && dut.ex_branch_mispredict) redirects++;
        if(cycles>200000) $fatal(1,"CPU timeout pc=%h",pc);
    end
    initial begin
        $readmemh("selftest.mem",rom);
        for(int i=0;i<1024;i++) ram[i]=0;
        // Observe every entry after time-zero initialization has settled.
        #1;
        for(int i=0;i<4096;i++)
            if(dut.u_branch_predictor.pht_q[i]!==2'b01)
                $fatal(1,"PHT cold initialization failed at entry %0d",i);
        for(int i=0;i<512;i++)
            if(dut.u_branch_predictor.btb_valid_q[i]!==1'b0)
                $fatal(1,"BTB cold initialization failed at entry %0d",i);
        repeat(2) begin
            rst_n=0; host_value=0;
            repeat(5) @(negedge clk);
            if(dut.u_branch_predictor.ghr_q!==12'd0)
                $fatal(1,"GHR not cleared by reset");
            if(runs!=0) begin
                for(int i=0;i<4096;i++)
                    if(dut.u_branch_predictor.pht_q[i]!==saved_pht[i])
                        $fatal(1,"PHT changed across warm reset at entry %0d",i);
                for(int i=0;i<512;i++) begin
                    if(dut.u_branch_predictor.btb_valid_q[i]!==saved_btb_valid[i])
                        $fatal(1,"BTB valid changed across warm reset at entry %0d",i);
                    if(saved_btb_valid[i] &&
                       {dut.u_branch_predictor.btb_tag_q[i],dut.u_branch_predictor.btb_target_q[i]}
                       !== {saved_btb_tag[i],saved_btb_target[i]})
                        $fatal(1,"BTB target/tag changed across warm reset at entry %0d",i);
                end
            end
            rst_n=1;
            wait(host_value!=0);
            if(host_value!=1) $fatal(1,"CPU selftest failed case %0d pc=%h",host_value>>1,pc);
            repeat(8) @(negedge clk);
            for(int i=0;i<4096;i++) saved_pht[i]=dut.u_branch_predictor.pht_q[i];
            for(int i=0;i<512;i++) begin
                saved_btb_valid[i]=dut.u_branch_predictor.btb_valid_q[i];
                saved_btb_tag[i]=dut.u_branch_predictor.btb_tag_q[i];
                saved_btb_target[i]=dut.u_branch_predictor.btb_target_q[i];
            end
            runs++;
        end
        if(predicted==0 || redirects==0) $fatal(1,"predictor paths not exercised");
        $display("PASS predictor: all 4096 PHT / 512 BTB initial states, GHR reset, trained tables retained across warm reset");
        $display("PASS CPU: RV32I ALU/subwords/forwarding/load-use/JAL/JALR/branches, runs=%0d cycles=%0d predicted=%0d redirects=%0d wait_cycles=%0d",
                 runs,cycles,predicted,redirects,waits);
        $finish;
    end
endmodule
