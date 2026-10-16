// One outstanding APB4 data transaction. Instruction fetch remains Harvard ROM.
// A completion advances EX once; registered read data is consumed in MEM.
// APB errors / misalignment halt this prototype until reset (no CSR/traps yet).
module lwc_cpu_apb (
    input logic clk, rst_n,
    input logic req_valid, req_write,
    input logic [31:0] req_addr, req_wdata,
    input logic [1:0] req_size,
    output logic req_ready,
    output logic [31:0] rsp_rdata,
    output logic fault,
    output logic [31:0] fault_addr,
    output logic psel, penable, pwrite,
    output logic [31:0] paddr, pwdata,
    output logic [3:0] pstrb,
    output wire [2:0] pprot,
    input logic pready, pslverr,
    input logic [31:0] prdata
);
    localparam [1:0] IDLE=0, SETUP=1, ACCESS=2;
    logic [1:0] state, byte_offset;
    wire aligned = (req_size == 0) ||
                   ((req_size == 1) && !req_addr[0]) ||
                   ((req_size == 2) && (req_addr[1:0] == 0));
    assign pprot = 3'b000;
    always_comb begin
        psel = rst_n && (state != IDLE);
        penable = rst_n && (state == ACCESS);
        req_ready = penable && pready;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            paddr <= 0; pwdata <= 0; pstrb <= 0; pwrite <= 0;
            byte_offset <= 0; rsp_rdata <= 0; fault <= 0; fault_addr <= 0;
        end else begin
            case (state)
                IDLE: if (req_valid && !fault) begin
                    if (!aligned) begin
                        fault <= 1;
                        fault_addr <= req_addr;
                    end else begin
                        state <= SETUP;
                        paddr <= {req_addr[31:2], 2'b00};
                        byte_offset <= req_addr[1:0];
                        pwrite <= req_write;
                        case (req_size)
                            0: begin
                                pwdata <= {4{req_wdata[7:0]}};
                                pstrb <= req_write ? (4'b0001 << req_addr[1:0]) : 4'b0;
                            end
                            1: begin
                                pwdata <= {2{req_wdata[15:0]}};
                                pstrb <= req_write ? (req_addr[1] ? 4'b1100 : 4'b0011) : 4'b0;
                            end
                            default: begin
                                pwdata <= req_wdata;
                                pstrb <= req_write ? 4'b1111 : 4'b0;
                            end
                        endcase
                    end
                end
                SETUP: state <= ACCESS;
                ACCESS: if (pready) begin
                    state <= IDLE;
                    rsp_rdata <= prdata >> {byte_offset, 3'b000};
                    if (pslverr) begin
                        fault <= 1;
                        fault_addr <= paddr | {30'b0, byte_offset};
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
