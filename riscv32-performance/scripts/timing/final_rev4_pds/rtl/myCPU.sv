module myCPU(
    input logic cpu_clk,
    input logic cpu_rst,
    output logic[31:0] irom_addr,
    input logic[31:0] irom_data,

    output logic[31:0] perip_addr,
    output logic perip_wen,
    output logic [1:0] perip_mask,
    output logic [31:0] perip_wdata,
    input logic[31:0] perip_rdata
);

    logic [11:0] if_ghr_snapshot;
    logic [31:0] if_pred_target;
    logic [11:0] if_pht_index;
    logic if_pred_taken;

    logic stall;
    logic if_id_flush;
    logic id_ex_flush;
    logic if_id_valid;
    logic [31:0] if_id_pc;
    logic [31:0] if_id_pc4;
    logic [31:0] if_id_instr;
    //branch_predictor
    logic [11:0] if_id_ghr_snapshot;
    logic [31:0] if_id_pred_target;
    logic [11:0] if_id_pht_index;
    logic if_id_pred_taken;


    logic id_load_unsigned;
    assign id_load_unsigned=
    ((if_id_instr[6:0]==7'b0000011)&&(if_id_instr[14:12]==3'b100 || if_id_instr[14:12]==3'b101))?1:0;

    logic id_ex_valid;
    logic [31:0] id_ex_pc;
    logic [31:0] id_ex_pc4;
    logic [31:0] id_ex_rs1_value;
    logic [31:0] id_ex_rs2_value;
    logic [31:0] id_ex_imm;
    logic [4:0] id_ex_rs1;
    logic [4:0] id_ex_rs2;
    logic [4:0] id_ex_rd;
    logic [2:0] id_ex_funct3;
    logic id_ex_funct7_5;
    logic [1:0] id_ex_alu_src_a;
    logic id_ex_alu_src_b;
    logic [3:0] id_ex_alu_control;
    logic id_ex_reg_write;
    logic id_ex_mem_read;
    logic id_ex_mem_write;
    logic [1:0] id_ex_MemtoReg;
    logic id_ex_branch;
    logic [1:0] id_ex_jump;
    logic [1:0]id_ex_mem_size;
    logic id_ex_load_unsigned;
    //branch_predictor
    logic [11:0] id_ex_ghr_snapshot;
    logic [31:0] id_ex_pred_target;
    logic [11:0] id_ex_pht_index;
    logic id_ex_pred_taken;

    logic ex_mem_valid;
    logic [31:0] ex_mem_alu_result;
    logic [31:0] ex_mem_store_data;//mem_wdata
    logic [31:0] ex_mem_pc4;
    logic [4:0] ex_mem_rd;
    logic ex_mem_reg_write;
    logic ex_mem_mem_read;
    logic ex_mem_mem_write;
    logic [1:0] ex_mem_MemtoReg;
    logic [1:0] ex_mem_mem_size;
    logic ex_mem_load_unsigned;

    logic mem_wb_valid;
    logic [31:0] mem_wb_read_data;
    logic [31:0] mem_wb_alu_result;
    logic [31:0] mem_wb_pc4;
    logic [4:0] mem_wb_rd;
    logic mem_wb_reg_write;
    logic [1:0] mem_wb_MemtoReg;


    logic pc_stall;
    // A load-use stall requires an EX load. That instruction cannot resolve a
    // branch/JALR, and an ID JAL has no source dependency. Thus stall and
    // redirect are mutually exclusive; keep recovery off the PC-enable path.
    assign pc_stall=stall;
    logic rst_n;
    assign rst_n = ~cpu_rst;
    //pc
    logic [31:0] pc;
    logic [31:0] next_pc;
    logic [31:0] pc_4;
    logic [31:0] pc_imm;
    //alu
    logic [31:0] b;
    logic [31:0] a;
    //logic zero;
    logic [31:0] alu_result;

    //ctrl
    logic reg_write;
    logic [1:0] alu_src_a;
    logic alu_src_b;
    logic mem_read;
    logic mem_write;
    logic [1:0] MemtoReg;
    logic branch;
    logic [1:0] jump;
    logic [2:0] imm_sel;
    logic [3:0] alu_control;

    logic [31:0] forwarded_rs1_value;
    logic [31:0] forwarded_rs2_value;

    assign irom_addr=pc;
    logic [31:0] instr;
    assign instr = irom_data;

    //regfile
    logic [31:0] rdata1;
    logic [31:0] rdata2;

    //immgen
    logic [31:0] imm;

    //branch_unit
    logic branch_1;

    //AND
    logic pc_src;
    assign pc_src=id_ex_branch&branch_1;

    //pc_4
    assign pc_4=pc+32'd4;

    //pc_imm
    assign pc_imm=id_ex_pc+id_ex_imm;

    //pc_src MUX                         //jalr
  // assign next_pc=(id_ex_jump==2'b10)?{alu_result[31:1],1'b0}:
  //             (id_ex_jump==2'b01)?pc_imm:  //jal
  //             (pc_src==1'b1)?pc_imm:  //b_type
  //                            pc_4;   //normal
    logic id_jal;
    assign id_jal=(if_id_valid)&&(jump==2'b01);
    logic [31:0] id_jal_target;
    logic id_jal_redirect;
    assign id_jal_target = if_id_pc + imm;
    assign id_jal_redirect = id_jal &&
        (!if_id_pred_taken || if_id_pred_target != id_jal_target);

    logic ex_branch_mispredict;
    logic actual_taken;
    assign actual_taken=(id_ex_valid==1)&&(pc_src==1'b1);
    //assign ex_branch_mispredict=actual_taken!=id_ex_pred_taken;
    assign ex_branch_mispredict =id_ex_valid && id_ex_branch &&
    ((id_ex_pred_taken != branch_1) ||
     (id_ex_pred_taken && branch_1 &&
      id_ex_pred_target != pc_imm));

    logic ex_jalr_redirect;
    logic [31:0] ex_jalr_target;
    logic [31:0] ex_jalr_sum;
    // Resolve indirect targets without the general ALU's operation/shift mux.
    assign ex_jalr_sum = forwarded_rs1_value + id_ex_imm;
    assign ex_jalr_target = {ex_jalr_sum[31:1], 1'b0};
    assign ex_jalr_redirect = id_ex_valid && id_ex_jump == 2'b10 &&
        (!id_ex_pred_taken || id_ex_pred_target != ex_jalr_target);

    assign if_id_flush=(ex_jalr_redirect||ex_branch_mispredict||id_jal_redirect);
    assign id_ex_flush=(ex_jalr_redirect||ex_branch_mispredict);
    always_comb begin
        next_pc=pc_4;
        if(ex_branch_mispredict)begin
            next_pc=(actual_taken)?pc_imm:id_ex_pc4;   
        end
        else if(ex_jalr_redirect)begin
            next_pc=ex_jalr_target;
        end
        else if(id_jal_redirect)begin
            next_pc=id_jal_target;
        end
        else if(if_pred_taken)begin //predict
            next_pc=if_pred_target;
        end
        
        //if() begin
            //case(id_ex_jump)
            //case(id_ex_jump)
                //2'b10:next_pc={alu_result[31:1],1'b0};//jalr
                //2'b01:next_pc=pc_imm;
                //default:next_pc=(pc_src==1'b1)?pc_imm:pc_4;//b type
            //endcase
        //end
    end

    //alu_src MUX
    //running while ex
    assign b=(id_ex_alu_src_b==1)?id_ex_imm:forwarded_rs2_value;
    assign a = (id_ex_alu_src_a==2'b01) ? id_ex_pc:
               (id_ex_alu_src_a==2'b10) ? 32'd0:
                                    forwarded_rs1_value;//case00 and case 11 as default

    assign perip_addr  = (id_ex_valid&&(id_ex_mem_read||id_ex_mem_write))?alu_result:32'd0;
    logic [31:0] read_data;
    logic [31:0] store_write_data;
    // A load response is already available in MEM when the following store
    // reaches EX. Forward only its payload, keeping the address/ALU path short.
    assign store_write_data = (id_ex_mem_write && ex_mem_valid &&
        ex_mem_mem_read && ex_mem_reg_write && ex_mem_rd != 5'd0 &&
        ex_mem_rd == id_ex_rs2) ? read_data : forwarded_rs2_value;
    assign perip_wdata = store_write_data;
    assign perip_wen   = id_ex_valid&&id_ex_mem_write;
    assign perip_mask  = id_ex_mem_size;    // funct3 low2


    always_comb begin //00-byte  01-halfword  10-word
        case (ex_mem_mem_size)
            2'b00: read_data =(ex_mem_load_unsigned==0)?
            {{24{perip_rdata[7]}}, perip_rdata[7:0]}
            :{24'd0, perip_rdata[7:0]};
            2'b01: read_data =(ex_mem_load_unsigned==0)?
            {{16{perip_rdata[15]}}, perip_rdata[15:0]}
            :{16'd0, perip_rdata[15:0]};
            default: read_data = perip_rdata;
        endcase
    end
    //MemtoReg
    logic [31:0] write_back;
    assign write_back=(mem_wb_MemtoReg==2'b01)?mem_wb_read_data:
                      (mem_wb_MemtoReg==2'b10)?mem_wb_pc4:
                                        mem_wb_alu_result;//case 00 and case 11 as default

    pc u_pc(
        .clk(cpu_clk),
        .rst_n(rst_n),
        .next_pc(next_pc),
        .stall(pc_stall),
        .pc(pc)
    );
    alu u_alu(
        .a(a),
        .b(b),
        .alu_control(id_ex_alu_control),
        .alu_result(alu_result)
    );
    ctrl U_ctrl(
        .opcode(if_id_instr[6:0]),
        .funct3(if_id_instr[14:12]),
        .funct7_5(if_id_instr[30]),
        .branch(branch),
        .jump(jump),
        .mem_write(mem_write),
        .mem_read(mem_read),
        .MemtoReg(MemtoReg),
        .reg_write(reg_write),
        .alu_src_a(alu_src_a),
        .alu_src_b(alu_src_b),
        .imm_sel(imm_sel),
        .alu_control(alu_control)
    );
    regfile u_regfile(
        .raddr1(if_id_instr[19:15]),
        .raddr2(if_id_instr[24:20]),
        .waddr(mem_wb_rd),
        .we(mem_wb_valid&&mem_wb_reg_write),
        .clk(cpu_clk),
        .rst_n(rst_n),
        .wdata(write_back),
        .rdata1(rdata1),
        .rdata2(rdata2)
    );
    immgen u_immgen(
        .instr(if_id_instr),
        .imm_sel(imm_sel),
        .imm(imm)
    );
    branch_unit u_branch_unit(
        .rdata1(forwarded_rs1_value),
        .rdata2(forwarded_rs2_value),
        .funct3(id_ex_funct3),
        .branch_1(branch_1)
    );
    if_id u_if_id(
        .clk(cpu_clk),
        .rst(rst_n),
        .flush(if_id_flush),
        .stall(stall),
        .in_valid(1'b1),
        .in_pc(pc),
        .in_pc4(pc_4),
        .in_instr(irom_data),
        .out_valid(if_id_valid),
        .out_pc(if_id_pc),
        .out_pc4(if_id_pc4),
        .out_instr(if_id_instr),
        .in_ghr_snapshot(if_ghr_snapshot),
        .in_pred_target(if_pred_target),
        .in_pht_index(if_pht_index),
        .in_pred_taken(if_pred_taken),
        .out_ghr_snapshot(if_id_ghr_snapshot),
        .out_pred_target(if_id_pred_target),
        .out_pht_index(if_id_pht_index),
        .out_pred_taken(if_id_pred_taken)
    );
    id_ex u_id_ex(
        .clk(cpu_clk),
        .rst_n(rst_n),
        .flush(id_ex_flush),
        .bubble(stall),
        .in_valid(if_id_valid),
        .in_pc(if_id_pc),
        .in_pc4(if_id_pc4),
        .in_rs1_value(rdata1),
        .in_rs2_value(rdata2),
        .in_imm(imm),
        .in_rs1(if_id_instr[19:15]),
        .in_rs2(if_id_instr[24:20]),
        .in_rd(if_id_instr[11:7]),
        .in_funct3(if_id_instr[14:12]),
        .in_funct7_5(if_id_instr[30]),
        .in_alu_src_a(alu_src_a),
        .in_alu_src_b(alu_src_b),
        .in_alu_control(alu_control),
        .in_reg_write(reg_write),
        .in_mem_read(mem_read),
        .in_mem_write(mem_write),
        .in_MemtoReg(MemtoReg),
        .in_branch(branch),
        .in_jump(jump),
        .in_mem_size(if_id_instr[13:12]),//funct3[1:0]
        .in_load_unsigned(id_load_unsigned),

        .out_valid(id_ex_valid),
        .out_pc(id_ex_pc),
        .out_pc4(id_ex_pc4),
        .out_rs1_value(id_ex_rs1_value),
        .out_rs2_value(id_ex_rs2_value),
        .out_imm(id_ex_imm),
        .out_rs1(id_ex_rs1),
        .out_rs2(id_ex_rs2),
        .out_rd(id_ex_rd),
        .out_funct3(id_ex_funct3),
        .out_funct7_5(id_ex_funct7_5),
        .out_alu_src_a(id_ex_alu_src_a),
        .out_alu_src_b(id_ex_alu_src_b),
        .out_alu_control(id_ex_alu_control),
        .out_reg_write(id_ex_reg_write),
        .out_mem_read(id_ex_mem_read),
        .out_mem_write(id_ex_mem_write),
        .out_MemtoReg(id_ex_MemtoReg),
        .out_branch(id_ex_branch),
        .out_jump(id_ex_jump),
        .out_mem_size(id_ex_mem_size),
        .out_load_unsigned(id_ex_load_unsigned),

        .in_ghr_snapshot(if_id_ghr_snapshot),
        .in_pred_target(if_id_pred_target),
        .in_pht_index(if_id_pht_index),
        .in_pred_taken(if_id_pred_taken),
        .out_ghr_snapshot(id_ex_ghr_snapshot),
        .out_pred_target(id_ex_pred_target),
        .out_pht_index(id_ex_pht_index),
        .out_pred_taken(id_ex_pred_taken)
    );
    ex_mem u_ex_mem(
        .clk(cpu_clk),
        .rst_n(rst_n),
        .flush(1'b0),
        .bubble(1'b0),
        .in_valid(id_ex_valid),
        .in_alu_result(alu_result),
        .in_store_data(store_write_data),
        .in_pc4(id_ex_pc4),
        .in_rd(id_ex_rd),
        .in_reg_write(id_ex_reg_write),
        .in_mem_read(id_ex_mem_read),
        .in_mem_write(id_ex_mem_write),
        .in_MemtoReg(id_ex_MemtoReg),
        .in_mem_size(id_ex_mem_size),
        .in_load_unsigned(id_ex_load_unsigned),

        .out_valid(ex_mem_valid),
        .out_alu_result(ex_mem_alu_result),
        .out_store_data(ex_mem_store_data),
        .out_pc4(ex_mem_pc4),
        .out_rd(ex_mem_rd),
        .out_reg_write(ex_mem_reg_write),
        .out_mem_read(ex_mem_mem_read),
        .out_mem_write(ex_mem_mem_write),
        .out_MemtoReg(ex_mem_MemtoReg),
        .out_mem_size(ex_mem_mem_size),
        .out_load_unsigned(ex_mem_load_unsigned)

    );
    mem_wb u_mem_wb(
        .clk(cpu_clk),
        .rst_n(rst_n),
        .in_valid(ex_mem_valid),
        .in_read_data(read_data),
        .in_alu_result(ex_mem_alu_result),
        .in_pc4(ex_mem_pc4),
        .in_rd(ex_mem_rd),
        .in_reg_write(ex_mem_reg_write),
        .in_MemtoReg(ex_mem_MemtoReg),
        .out_valid(mem_wb_valid),
        .out_read_data(mem_wb_read_data),
        .out_alu_result(mem_wb_alu_result),
        .out_pc4(mem_wb_pc4),
        .out_rd(mem_wb_rd),
        .out_reg_write(mem_wb_reg_write),
        .out_MemtoReg(mem_wb_MemtoReg)
    );
    forwarding u_forwarding(
        .id_ex_rs1(id_ex_rs1),
        .id_ex_rs2(id_ex_rs2),
        .id_ex_rs1_value(id_ex_rs1_value),
        .id_ex_rs2_value(id_ex_rs2_value),
        .ex_mem_valid(ex_mem_valid),
        .ex_mem_reg_write(ex_mem_reg_write),
        .ex_mem_mem_read(ex_mem_mem_read),
        .ex_mem_rd(ex_mem_rd),
        .ex_mem_pc4(ex_mem_pc4),
        .ex_mem_MemtoReg(ex_mem_MemtoReg),
        .ex_mem_alu_result(ex_mem_alu_result),
        .mem_wb_valid(mem_wb_valid),
        .mem_wb_reg_write(mem_wb_reg_write),
        .mem_wb_rd(mem_wb_rd),
        .mem_wb_write_data(write_back),
        .forwarded_rs1_value(forwarded_rs1_value),
        .forwarded_rs2_value(forwarded_rs2_value)
    );
    hazard_detection u_hazard_dection(
        .id_ex_valid(id_ex_valid),
        .id_ex_mem_read(id_ex_mem_read),
        .id_ex_rd(id_ex_rd),
        .if_id_valid(if_id_valid),
        .if_id_opcode(if_id_instr[6:0]),
        .if_id_rs1(if_id_instr[19:15]),
        .if_id_rs2(if_id_instr[24:20]),
        .load_use_stall(stall)
    );
    logic [11:0] ex_ghr_recover_value;
    assign ex_ghr_recover_value = ex_branch_mispredict ?
        {id_ex_ghr_snapshot[10:0], actual_taken} :
        ex_jalr_redirect ? id_ex_ghr_snapshot : if_id_ghr_snapshot;
    logic if_is_branch;
    assign if_is_branch=(irom_data[6:0]==7'b1100011);
    logic ex_link_rd;
    logic ex_link_rs1;
    logic ex_is_call;
    logic ex_is_return;
    assign ex_link_rd = id_ex_rd == 5'd1 || id_ex_rd == 5'd5;
    assign ex_link_rs1 = id_ex_rs1 == 5'd1 || id_ex_rs1 == 5'd5;
    assign ex_is_call = id_ex_jump != 2'b00 && ex_link_rd;
    assign ex_is_return = id_ex_jump == 2'b10 && ex_link_rs1 &&
        (!ex_link_rd || id_ex_rd != id_ex_rs1);
    branch_predictor #(
        .PC_WIDTH(32),
        .GHR_WIDTH(12),
        .PHT_INDEX_WIDTH(12),
        .PHT_ENTRIES(4096),
        .BTB_INDEX_WIDTH(9),
        .BTB_ENTRIES(512),
        .BTB_TAG_WIDTH(21)
    )u_branch_predictor(
        .clk(cpu_clk),
        .rst_n(rst_n),
        .if_pc(pc),
        .if_instr(irom_data),
        .if_is_branch(if_is_branch),
        .if_accept(!if_id_flush&&!stall&&rst_n),
        .if_pred_taken(if_pred_taken),//out
        .if_pred_target(if_pred_target),//out
        .if_pht_index(if_pht_index),//out
        .if_ghr_snapshot(if_ghr_snapshot),//out
        .ex_train_valid(id_ex_valid && (id_ex_branch || id_ex_jump != 2'b00)),
        .ex_is_branch(id_ex_branch),
        .ex_is_jalr(id_ex_jump == 2'b10),
        .ex_is_call(ex_is_call),
        .ex_is_return(ex_is_return),
        .ex_branch_pc(id_ex_pc),
        .ex_pht_index(id_ex_pht_index),
        .ex_actual_taken(id_ex_branch ? actual_taken : 1'b1),
        .ex_actual_target(id_ex_jump == 2'b10 ? ex_jalr_target : pc_imm),
        .ex_ghr_recover_valid(ex_branch_mispredict || ex_jalr_redirect || id_jal_redirect),
        .ex_ghr_recover_value(ex_ghr_recover_value)
    );
endmodule
