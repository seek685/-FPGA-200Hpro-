`timescale 1ns/1ps
module tb_cpu_apb;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    logic valid=0,write=0,ready=0,error=0;
    logic [31:0] addr=0,wdata=0,rdata=32'h89abcdef;
    logic [1:0] size=2;
    wire done,fault,psel,penable,pwrite;
    wire [31:0] result,paddr,pwdata,fault_addr;
    wire [3:0] strb;
    wire [2:0] prot;
    lwc_cpu_apb dut(.clk(clk),.rst_n(rst_n),.req_valid(valid),.req_write(write),
        .req_addr(addr),.req_wdata(wdata),.req_size(size),.req_ready(done),.rsp_rdata(result),
        .fault(fault),.fault_addr(fault_addr),.psel(psel),.penable(penable),.pwrite(pwrite),
        .paddr(paddr),.pwdata(pwdata),.pstrb(strb),.pprot(prot),.pready(ready),.pslverr(error),.prdata(rdata));
    task automatic reset_bus;
        @(negedge clk);rst_n=0;valid=0;ready=0;error=0;
        repeat(3) @(negedge clk);rst_n=1;
    endtask
    task automatic access(input int off,input int sz,input bit wr,input int delay_cycles);
        logic [68:0] controls;
        @(negedge clk);addr=32'h80100000+32'(off);size=2'(sz);write=wr;wdata=32'h12345678;valid=1;
        @(negedge clk);
        if(!psel || penable || done || prot!=0) $fatal(1,"missing APB setup");
        controls={paddr,pwdata,strb,pwrite};
        if(paddr!=32'h80100000) $fatal(1,"unaligned APB address");
        if(!wr && strb!=0) $fatal(1,"read has write strobes");
        if(wr && strb!=(sz==0 ? (4'b1<<off) : (sz==1 ? (4'b11<<off) : 4'b1111))) $fatal(1,"bad strobes");
        @(negedge clk);
        if(!penable) $fatal(1,"missing APB access");
        repeat(delay_cycles) begin
            @(negedge clk);
            if(done || controls!={paddr,pwdata,strb,pwrite} || !psel || !penable) $fatal(1,"wait state violated");
        end
        ready=1;
        @(negedge clk);valid=0;ready=0;
        if(psel || result!=(rdata>>(off*8))) $fatal(1,"response offset/latency");
    endtask
    initial begin
        reset_bus();
        for(int i=0;i<4;i++) begin access(i,0,0,i);access(i,0,1,3-i);end
        access(0,1,0,2);access(2,1,1,2);access(0,2,0,0);access(0,2,1,4);
        // Slave error: retain address, halt new requests, reset recovers.
        @(negedge clk);valid=1;addr=32'h40002000;size=2;write=0;error=1;ready=1;
        repeat(4) @(negedge clk);
        if(!fault || fault_addr!=addr || psel) $fatal(1,"slave error not latched/halted");
        reset_bus();
        @(negedge clk);valid=1;addr=32'h80100001;size=1;
        repeat(3) @(negedge clk);
        if(!fault || psel || fault_addr!=addr) $fatal(1,"misalignment issued a transaction");
        reset_bus();
        @(negedge clk);valid=1;addr=32'h80100000;size=2;
        repeat(3) @(negedge clk);
        if(!psel || !penable) $fatal(1,"reset test never reached waiting access");
        reset_bus();
        if(psel || fault) $fatal(1,"reset failed to cancel bus");
        access(0,2,0,1);
        $display("PASS APB: setup/access/waits, byte lanes, read alignment, error halt, misalignment, reset cancellation");
        $finish;
    end
endmodule
