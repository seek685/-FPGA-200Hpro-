`timescale 1ns/1ps
// Pure RTL RV32I architectural checker; ROM is asynchronous, data returns one clock later.
module tb_cpu_regression;
    logic cpu_clk = 0, cpu_rst = 1;
    always #5 cpu_clk = ~cpu_clk;
    wire [31:0] irom_addr, perip_addr, perip_wdata;
    wire perip_wen;
    wire [1:0] perip_mask;
    logic [31:0] irom_data, perip_rdata = 0;
    myCPU dut (.*);

    logic [31:0] imem [0:16383];
    logic [31:0] memory [0:65535];
    logic [31:0] ref_memory [0:65535];
    logic [31:0] regs [0:31];
    logic [31:0] ref_pc = 32'h80000000;
    logic [31:0] seg = 0, led = 0, ref_seg = 0, ref_led = 0;
    logic [1:0] physical_store_valid = 0;
    logic [31:0] physical_store_addr [0:1];
    logic [31:0] physical_store_data [0:1];
    logic [1:0] physical_store_size [0:1];
    integer cycles = 0, retired = 0, max_cycles = 100000;
    integer stores = 0, loads = 0, branches = 0, stalls = 0, redirects = 0;
    integer trace_file;
    integer benchmark_start = 0, benchmark_cycles = 0;
    bit done = 0;
    bit check_seg = 0;
    logic [31:0] expected_seg;
    integer warm_reset = 0, warm_phase = 0;
    bit warm_restart_requested = 0;
    string imem_path, dmem_path, trace_path, warm_imem_path;

    function automatic logic [31:0] fetch(input logic [31:0] address);
        if(address >= 32'h80000000 && address < 32'h80010000 && address[1:0] == 0)
            fetch = imem[(address - 32'h80000000) >> 2];
        else fetch = 0;
    endfunction
    always @* irom_data = fetch(irom_addr);

    function automatic logic [31:0] bus_read(input logic [31:0] address, input logic [1:0] size);
        logic [31:0] value;
        begin
            if(address >= 32'h80100000 && address < 32'h80140000) begin
                value = memory[(address - 32'h80100000) >> 2] >> (address[1:0] * 8);
                case(size)
                    0: bus_read = {24'd0, value[7:0]};
                    1: bus_read = {16'd0, value[15:0]};
                    2: bus_read = value;
                    default: bus_read = 0;
                endcase
            end else begin
                case(address)
                    32'h80200020: bus_read = seg;
                    32'h80200040: bus_read = led;
                    default: bus_read = 0;
                endcase
            end
        end
    endfunction

    task automatic check_commit;
        logic [31:0] ins, a, b, imm, value, next_pc, address, raw;
        logic [6:0] opcode;
        logic [2:0] f3;
        integer rd, rs1, rs2, bytes, index, shift;
        bit write_reg, write_mem, taken, legal;
        begin
            ins = fetch(ref_pc);
            if(dut.mem_wb_pc4 !== ref_pc + 4)
                $fatal(1,"PC mismatch retired=%0d got=%h expected=%h instruction=%h",retired,dut.mem_wb_pc4-4,ref_pc,ins);
            opcode=ins[6:0]; f3=ins[14:12]; rd=ins[11:7]; rs1=ins[19:15]; rs2=ins[24:20];
            a=regs[rs1]; b=regs[rs2]; imm=0; value=0; next_pc=ref_pc+4; address=0;
            write_reg=0; write_mem=0; taken=0; legal=1; bytes=0;
            case(opcode)
                7'h37: begin write_reg=1; value={ins[31:12],12'b0}; end
                7'h17: begin write_reg=1; value=ref_pc+{ins[31:12],12'b0}; end
                7'h6f: begin
                    imm={{11{ins[31]}},ins[31],ins[19:12],ins[20],ins[30:21],1'b0};
                    write_reg=1; value=ref_pc+4; next_pc=ref_pc+imm;
                end
                7'h67: begin
                    imm={{20{ins[31]}},ins[31:20]}; write_reg=1; value=ref_pc+4;
                    next_pc=(a+imm)&32'hfffffffe; legal=(f3==0);
                end
                7'h63: begin
                    imm={{19{ins[31]}},ins[31],ins[7],ins[30:25],ins[11:8],1'b0};
                    case(f3)
                        0: taken=(a==b); 1: taken=(a!=b);
                        4: taken=($signed(a)<$signed(b)); 5: taken=($signed(a)>=$signed(b));
                        6: taken=(a<b); 7: taken=(a>=b); default: legal=0;
                    endcase
                    if(taken) next_pc=ref_pc+imm;
                    branches++;
                end
                7'h13: begin
                    write_reg=1; imm={{20{ins[31]}},ins[31:20]};
                    case(f3)
                        0: value=a+imm;
                        2: value=($signed(a)<$signed(imm));
                        3: value=(a<imm);
                        4: value=a^imm;
                        6: value=a|imm;
                        7: value=a&imm;
                        1: begin value=a<<ins[24:20]; legal=(ins[31:25]==0); end
                        5: begin
                            if(ins[31:25]==0) value=a>>ins[24:20];
                            else if(ins[31:25]==7'h20) value=$signed(a)>>>ins[24:20];
                            else legal=0;
                        end
                    endcase
                end
                7'h33: begin
                    write_reg=1;
                    if(ins[31:25]!=0 && !(ins[31:25]==7'h20 && (f3==0 || f3==5))) legal=0;
                    case(f3)
                        0: value=ins[30] ? a-b : a+b;
                        1: value=a<<b[4:0];
                        2: value=($signed(a)<$signed(b));
                        3: value=(a<b);
                        4: value=a^b;
                        5: begin
                            if(ins[30]) value=$signed(a)>>>b[4:0];
                            else value=a>>b[4:0];
                        end
                        6: value=a|b;
                        7: value=a&b;
                    endcase
                end
                7'h03: begin
                    imm={{20{ins[31]}},ins[31:20]}; address=a+imm; write_reg=1; loads++;
                    if(address>=32'h80100000 && address<32'h80140000)
                        raw=ref_memory[(address-32'h80100000)>>2]>>(address[1:0]*8);
                    else if(address==32'h80200020) raw=ref_seg;
                    else if(address==32'h80200040) raw=ref_led;
                    else raw=0;
                    case(f3)
                        0: value={{24{raw[7]}},raw[7:0]};
                        1: begin value={{16{raw[15]}},raw[15:0]}; legal=!address[0]; end
                        2: begin value=raw; legal=(address[1:0]==0); end
                        4: value={24'b0,raw[7:0]};
                        5: begin value={16'b0,raw[15:0]}; legal=!address[0]; end
                        default: legal=0;
                    endcase
                end
                7'h23: begin
                    imm={{20{ins[31]}},ins[31:25],ins[11:7]}; address=a+imm; write_mem=1;
                    case(f3)
                        0: bytes=1;
                        1: begin bytes=2; legal=!address[0]; end
                        2: begin bytes=4; legal=(address[1:0]==0); end
                        default: legal=0;
                    endcase
                end
                7'h0f: legal=(f3==0);
                default: legal=0;
            endcase
            if(!legal || next_pc[1:0]!=0) $fatal(1,"Invalid test instruction at %h: %h",ref_pc,ins);
            if((dut.mem_wb_reg_write && dut.mem_wb_rd!=0) !== (write_reg && rd!=0))
                $fatal(1,"Register enable mismatch pc=%h instruction=%h",ref_pc,ins);
            if(write_reg && rd!=0) begin
                if(dut.mem_wb_rd !== rd[4:0] || dut.write_back !== value)
                    $fatal(1,"Register mismatch pc=%h x%0d got rd=%0d value=%h expected=%h",ref_pc,rd,dut.mem_wb_rd,dut.write_back,value);
                regs[rd]=value;
            end
            if(physical_store_valid[1] !== write_mem)
                $fatal(1,"Physical store enable mismatch pc=%h instruction=%h",ref_pc,ins);
            if(write_mem) begin
                if(physical_store_addr[1] !== address || physical_store_data[1] !== b || physical_store_size[1] !== f3[1:0])
                    $fatal(1,"Store mismatch pc=%h address=%h/%h data=%h/%h size=%h/%h",ref_pc,physical_store_addr[1],address,physical_store_data[1],b,physical_store_size[1],f3[1:0]);
                if(address>=32'h80100000 && address<32'h80140000) begin
                    index=(address-32'h80100000)>>2;
                    for(integer j=0;j<bytes;j++) begin
                        shift=8*(address[1:0]+j);
                        ref_memory[index]=(ref_memory[index]&~(32'hff<<shift))|(((b>>(8*j))&32'hff)<<shift);
                    end
                end else begin
                    if(address==32'h80200020) ref_seg=b;
                    if(address==32'h80200040) ref_led=b;
                end
                stores++;
            end
            $fdisplay(trace_file,"%08h %08h %01h %02h %08h %01h %08h %08h %01h",ref_pc,ins,write_reg&&rd!=0,
                write_reg&&rd!=0?rd:0,write_reg&&rd!=0?value:32'd0,write_mem,
                write_mem?address:32'd0,write_mem?b:32'd0,write_mem?f3[1:0]:2'd0);
            regs[0]=0; ref_pc=next_pc; retired++;
            if(write_mem && address==32'h80200040 && b==32'h6d) begin
                if(check_seg && ref_seg !== expected_seg)
                    $fatal(1,"C kernel checksum mismatch got=%h expected=%h",ref_seg,expected_seg);
                for(integer j=0;j<65536;j++)
                    if(memory[j] !== ref_memory[j]) $fatal(1,"Final memory mismatch word=%0d",j);
                done=1;
                if(warm_reset && warm_phase==0) begin
                    $display("WARM_PHASE_PASS cycles=%0d retired=%0d",cycles,retired);
                    warm_restart_requested=1;
                end else begin
                    $display("RESULT PASS cycles=%0d retired=%0d stalls=%0d redirects=%0d stores=%0d loads=%0d branches=%0d",cycles,retired,stalls,redirects,stores,loads,branches);
                    if(benchmark_cycles>0) $display("BENCHMARK_CYCLES %0d",benchmark_cycles);
                    $fclose(trace_file); $finish;
                end
            end
        end
    endtask

    always @(posedge cpu_clk) begin
        if(!cpu_rst && !done) begin
            cycles++;
            if(dut.stall && dut.if_id_flush)
                $fatal(1,"Load-use stall and redirect flush must be mutually exclusive");
            if(dut.stall) stalls++;
            if(dut.if_id_flush) redirects++;
            if(dut.mem_wb_valid) check_commit();
            else if(physical_store_valid[1]) $fatal(1,"Store without retired instruction");
            physical_store_valid[1]=physical_store_valid[0];
            physical_store_addr[1]=physical_store_addr[0];
            physical_store_data[1]=physical_store_data[0];
            physical_store_size[1]=physical_store_size[0];
            physical_store_valid[0]=perip_wen;
            physical_store_addr[0]=perip_addr;
            physical_store_data[0]=perip_wdata;
            physical_store_size[0]=perip_mask;
            perip_rdata <= perip_wen ? 0 : bus_read(perip_addr,perip_mask);
            if(perip_wen) begin
                if(perip_addr>=32'h80100000 && perip_addr<32'h80140000) begin
                    for(integer j=0;j<(1<<perip_mask);j++)
                        memory[(perip_addr-32'h80100000)>>2][8*(perip_addr[1:0]+j)+:8] = perip_wdata[8*j+:8];
                end else begin
                    if(perip_addr==32'h80200020) seg=perip_wdata;
                    if(perip_addr==32'h80200040) led=perip_wdata;
                    if(perip_addr==32'h80200070 && perip_wdata==1) benchmark_start=cycles;
                    if(perip_addr==32'h80200070 && perip_wdata==0) benchmark_cycles=cycles-benchmark_start;
                    if(perip_addr>=32'h80200080 && perip_addr<=32'h80200090)
                        $display("COREMARK_CRC address=%h value=%h",perip_addr,perip_wdata);
                end
            end
            if(cycles>=max_cycles) $fatal(1,"Timeout retired=%0d next_pc=%h",retired,ref_pc);
        end
    end

    initial begin
        for(integer j=0;j<16384;j++) imem[j]=32'h13;
        for(integer j=0;j<65536;j++) begin memory[j]=0; ref_memory[j]=0; end
        for(integer j=0;j<32;j++) regs[j]=0;
        if(!$value$plusargs("IMEM=%s",imem_path)) $fatal(1,"IMEM required");
        if(!$value$plusargs("DMEM=%s",dmem_path)) $fatal(1,"DMEM required");
        if(!$value$plusargs("TRACE=%s",trace_path)) trace_path="cpu.trace";
        if($value$plusargs("MAX_CYCLES=%d",max_cycles)) begin end
        if($value$plusargs("EXPECTED_SEG=%h",expected_seg)) check_seg=1;
        if($value$plusargs("WARM_RESET=%d",warm_reset)) begin end
        if($value$plusargs("WARM_IMEM=%s",warm_imem_path)) begin end
        $readmemh(imem_path,imem); $readmemh(dmem_path,memory);
        for(integer j=0;j<65536;j++) ref_memory[j]=memory[j];
        trace_file=$fopen(trace_path,"w");
        if(!trace_file) $fatal(1,"Cannot open trace");
        repeat(5) @(negedge cpu_clk);
        cpu_rst=0;
    end

    initial begin
        wait(warm_restart_requested);
        @(negedge cpu_clk);
        cpu_rst=1;
        repeat(3) @(negedge cpu_clk);
        $readmemh(warm_imem_path,imem);
        for(integer j=0;j<65536;j++) ref_memory[j]=memory[j];
        for(integer j=0;j<32;j++) regs[j]=0;
        ref_pc=32'h80000000; ref_seg=seg; ref_led=led;
        physical_store_valid=0; perip_rdata=0;
        $fdisplay(trace_file,"WARM_RESET");
        warm_phase=1; done=0; cpu_rst=0;
    end
endmodule
