`timescale 1ns/1ps

// Vendor BRAM interface only: synchronous independent read and byte-write ports.
// The CPU, bridge, DRAM lane/size logic and all MMIO peripherals remain real RTL.
module BRAM (
    input logic clka, clkb, ena, enb,
    input logic [15:0] addra, addrb,
    input logic [3:0] wea,
    input logic [31:0] dina,
    output logic [31:0] doutb
);
    logic [31:0] memory [0:65535];
    initial begin
        doutb = 0;
        for (integer i = 0; i < 65536; i++) memory[i] = 0;
    end
    always @(posedge clka) begin
        if (ena) begin
            if (wea[0]) memory[addra][7:0] <= dina[7:0];
            if (wea[1]) memory[addra][15:8] <= dina[15:8];
            if (wea[2]) memory[addra][23:16] <= dina[23:16];
            if (wea[3]) memory[addra][31:24] <= dina[31:24];
        end
    end
    always @(posedge clkb) if (enb) doutb <= memory[addrb];
endmodule

module tb_memory_path;
    localparam [31:0] ROM_BASE = 32'h80000000;
    localparam [31:0] RAM_BASE = 32'h80100000;
    localparam [31:0] MMIO_BASE = 32'h80200000;
    logic clk = 0, cnt_clk = 0, rst = 1;
    always #5 clk = ~clk;
    always #7 cnt_clk = ~cnt_clk;
    logic [31:0] irom_addr, irom_data;
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic perip_wen;
    logic [1:0] perip_mask;
    logic [39:0] seg;
    logic [31:0] led;
    logic [31:0] rom [0:1023];
    logic [31:0] ref_regs [0:31];
    byte unsigned ref_bytes [0:1023];
    logic [31:0] ref_seg = 0;
    logic [31:0] load_raw [0:255], load_value [0:255];
    logic [31:0] store_address [0:255], store_value [0:255];
    logic [1:0] store_size [0:255];
    integer instructions = 0, expected_loads = 0, expected_stores = 0;
    integer loads = 0, stores = 0, cycles = 0, stalls = 0, done_age = 0;
    integer load_op [0:4];
    integer load_offset [0:4];
    integer destination;

    myCPU cpu (.cpu_clk(clk), .cpu_rst(rst), .*);
    perip_bridge bridge (
        .clk(clk), .cnt_clk(cnt_clk), .rst(rst), .perip_addr(perip_addr),
        .perip_wdata(perip_wdata), .perip_wen(perip_wen), .perip_mask(perip_mask),
        .perip_rdata(perip_rdata), .virtual_sw_input(64'hfedcba9813579bdf),
        .virtual_key_input(8'ha5), .virtual_seg_output(seg), .virtual_led_output(led)
    );
    always_comb begin
        irom_data = 32'h00000013;
        if (irom_addr >= ROM_BASE && irom_addr < ROM_BASE + 4096)
            irom_data = rom[(irom_addr - ROM_BASE) >> 2];
    end

    function automatic [31:0] itype(input [6:0] opcode, input integer rd,
                                   input integer f3, input integer rs1, input integer imm);
        itype = {imm[11:0], rs1[4:0], f3[2:0], rd[4:0], opcode};
    endfunction
    function automatic [31:0] stype(input integer rs2, input integer rs1,
                                   input integer imm, input integer f3);
        stype = {imm[11:5], rs2[4:0], rs1[4:0], f3[2:0], imm[4:0], 7'h23};
    endfunction
    task automatic emit(input [31:0] instruction);
        rom[instructions] = instruction;
        instructions++;
    endtask
    task automatic addi(input integer rd, input integer rs1, input integer imm);
        emit(itype(7'h13, rd, 0, rs1, imm));
        if (rd != 0) ref_regs[rd] = ref_regs[rs1] + imm;
    endtask
    task automatic lui(input integer rd, input [19:0] upper);
        emit({upper, rd[4:0], 7'h37});
        if (rd != 0) ref_regs[rd] = {upper, 12'b0};
    endtask

    // Architectural byte memory reference, independent of BRAM lanes and the
    // bridge's registered-address/size/offset implementation.
    task automatic load(input integer rd, input integer rs1, input integer offset,
                        input integer f3);
        logic [31:0] address, raw, value;
        integer byte_count;
        address = ref_regs[rs1] + offset;
        raw = 0;
        if (address >= RAM_BASE && address < RAM_BASE + 1024) begin
            case (f3)
                0, 4: byte_count = 1;
                1, 5: byte_count = 2;
                default: byte_count = 4;
            endcase
            for (integer lane = 0; lane < byte_count; lane++)
                raw = raw | (32'(ref_bytes[address - RAM_BASE + lane]) << (lane * 8));
        end
        else begin
            case (address)
                MMIO_BASE: raw = 32'h13579bdf;
                MMIO_BASE + 4: raw = 32'hfedcba98;
                MMIO_BASE + 16: raw = 32'ha5;
                MMIO_BASE + 32: raw = ref_seg;
                MMIO_BASE + 80: raw = 0;
                default: $fatal(1, "test generated unsupported load address %h", address);
            endcase
        end
        case (f3)
            0: value = {{24{raw[7]}}, raw[7:0]};
            1: value = {{16{raw[15]}}, raw[15:0]};
            4: value = {24'd0, raw[7:0]};
            5: value = {16'd0, raw[15:0]};
            default: value = raw;
        endcase
        load_raw[expected_loads] = raw;
        load_value[expected_loads] = value;
        expected_loads++;
        emit(itype(7'h03, rd, f3, rs1, offset));
        if (rd != 0) ref_regs[rd] = value;
    endtask
    task automatic store(input integer rs2, input integer rs1, input integer offset,
                         input integer f3);
        logic [31:0] address, value;
        integer byte_count;
        address = ref_regs[rs1] + offset;
        value = ref_regs[rs2];
        store_address[expected_stores] = address;
        store_value[expected_stores] = value;
        store_size[expected_stores] = f3;
        expected_stores++;
        if (address >= RAM_BASE && address < RAM_BASE + 1024) begin
            byte_count = 1 << f3;
            for (integer lane = 0; lane < byte_count; lane++)
                ref_bytes[address - RAM_BASE + lane] = value >> (lane * 8);
        end
        else if (address == MMIO_BASE + 32) ref_seg = value;
        else if (address != MMIO_BASE + 64)
            $fatal(1, "test generated unsupported store address %h", address);
        emit(stype(rs2, rs1, offset, f3));
    endtask

    initial begin
        for (integer i = 0; i < 1024; i++) begin
            rom[i] = 32'h00000013;
            ref_bytes[i] = 0;
        end
        for (integer i = 0; i < 32; i++) ref_regs[i] = 0;
        // An address pointer plus deliberately negative bytes and halfwords.
        ref_bytes[0] = 8'h80; ref_bytes[1] = 8'h02;
        ref_bytes[2] = 8'h10; ref_bytes[3] = 8'h80;
        ref_bytes[4] = 8'h81; ref_bytes[5] = 8'hfe;
        ref_bytes[6] = 8'h80; ref_bytes[7] = 8'h7f;
        ref_bytes[8] = 8'h01; ref_bytes[9] = 8'h80;
        ref_bytes[10] = 8'hdc; ref_bytes[11] = 8'hfe;
        ref_bytes[12] = 8'hef; ref_bytes[13] = 8'hcd;
        ref_bytes[14] = 8'hab; ref_bytes[15] = 8'h89;
        #1;
        for (integer i = 0; i < 256; i++)
            bridge.dram_driver_inst.Mem_BRAM.memory[i] =
                {ref_bytes[i*4+3], ref_bytes[i*4+2], ref_bytes[i*4+1], ref_bytes[i*4]};

        lui(20, 20'h80100);
        lui(21, 20'h80200);
        load_op[0] = 2; load_op[1] = 0; load_op[2] = 4;
        load_op[3] = 1; load_op[4] = 5;
        load_offset[0] = 12; load_offset[1] = 4; load_offset[2] = 5;
        load_offset[3] = 8; load_offset[4] = 10;
        // Each load size/sign immediately feeds each store size. The SB lanes
        // span all four offsets and SH spans both naturally aligned offsets.
        for (integer kind = 0; kind < 5; kind++) begin
            for (integer mode = 0; mode < 3; mode++) begin
                destination = 256 + (kind * 3 + mode) * 8;
                load(7, 20, load_offset[kind], load_op[kind]);
                case (mode)
                    0: store(7, 20, destination, 2);
                    1: store(7, 20, destination + ((kind * 3 + mode) % 4), 0);
                    2: store(7, 20, destination + ((kind % 2) * 2), 1);
                endcase
                load(8, 20, destination, 2);
            end
        end
        load(9, 20, 4, 0); load(10, 20, 10, 5);
        load(11, 20, 6, 4); load(12, 20, 8, 1); load(13, 20, 12, 2);
        store(13, 20, 512, 2);
        load(6, 20, 0, 2); store(7, 6, 0, 2); // address dependency
        load(6, 20, 0, 2); store(6, 6, 4, 2); // both rs1 and rs2 depend on load
        load(6, 20, 0, 2); load(14, 6, 0, 2);
        load(6, 20, 0, 2); store(6, 6, 9, 0);
        load(6, 20, 0, 2); store(6, 6, 10, 1);
        load(0, 20, 0, 2); store(0, 20, 528, 2);

        load(1, 21, 0, 2); store(1, 20, 576, 2);
        load(1, 21, 4, 2); store(1, 20, 586, 1);
        load(1, 21, 16, 2); store(1, 20, 591, 0);
        lui(15, 20'h89abd); addi(15, 15, -529);
        store(15, 21, 32, 2); load(16, 21, 32, 2); store(16, 20, 592, 2);
        load(17, 21, 80, 2); store(17, 20, 596, 2);

        // Cold taken branch with a load dependency squashes two DRAM stores.
        load(7, 20, 4, 0);
        emit(32'h00738663); // beq x7,x7,+12
        emit(stype(7, 20, 896, 2));
        emit(stype(7, 20, 900, 2));
        // Cold indirect jump computes target from AUIPC, including bit0 clear.
        ref_regs[12] = ROM_BASE + instructions * 4;
        emit({20'd0, 5'd12, 7'h17});
        addi(12, 12, 20);
        emit(itype(7'h67, 0, 0, 12, 1));
        emit(stype(7, 20, 904, 2));
        emit(stype(7, 20, 908, 2));
        load(18, 20, 896, 2); load(19, 20, 900, 2);
        load(22, 20, 904, 2); load(23, 20, 908, 2);
        lui(31, 20'h80200); addi(30, 0, 109); store(30, 31, 64, 2);
        emit(32'h0000006f);

        repeat (5) @(negedge clk);
        rst = 0;
    end

    always @(posedge clk) begin
        if (!rst) begin
            cycles++;
            if (cpu.stall) stalls++;
            if (cpu.ex_mem_valid && cpu.ex_mem_mem_read) begin
                if (loads >= expected_loads || perip_rdata !== load_raw[loads] ||
                    cpu.read_data !== load_value[loads])
                    $fatal(1, "load %0d bridge=%h expected=%h cpu=%h expected=%h pc=%h",
                           loads, perip_rdata, load_raw[loads], cpu.read_data,
                           load_value[loads], cpu.ex_mem_pc4 - 4);
                loads++;
            end
            if (perip_wen) begin
                if (stores >= expected_stores || perip_addr !== store_address[stores] ||
                    perip_wdata !== store_value[stores] || perip_mask !== store_size[stores])
                    $fatal(1, "store %0d addr=%h/%h value=%h/%h size=%h/%h",
                           stores, perip_addr, store_address[stores], perip_wdata,
                           store_value[stores], perip_mask, store_size[stores]);
                stores++;
            end
            if (cycles > 2000) $fatal(1, "timeout pc=%h led=%h", irom_addr, led);
        end
    end
    always @(negedge clk) begin
        if (!rst && led == 109) begin
            done_age++;
            if (done_age == 4) begin
                if (loads != expected_loads || stores != expected_stores)
                    $fatal(1, "operation count loads=%0d/%0d stores=%0d/%0d",
                           loads, expected_loads, stores, expected_stores);
                for (integer i = 0; i < 256; i++)
                    if (bridge.dram_driver_inst.Mem_BRAM.memory[i] !==
                        {ref_bytes[i*4+3], ref_bytes[i*4+2], ref_bytes[i*4+1], ref_bytes[i*4]})
                        $fatal(1, "BRAM word %0d mismatch", i);
                for (integer i = 0; i < 32; i++)
                    if (cpu.u_regfile.regs[i] !== ref_regs[i])
                        $fatal(1, "register x%0d=%h expected=%h", i, cpu.u_regfile.regs[i], ref_regs[i]);
                $display("PASS tb_memory_path cycles=%0d stalls=%0d loads=%0d stores=%0d instructions=%0d words_checked=256 registers_checked=32",
                         cycles, stalls, loads, stores, instructions);
                $finish;
            end
        end
    end
endmodule
