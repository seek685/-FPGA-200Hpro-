`timescale 1ns/1ps

// Exercise the actual top-level and DDR-wrapper reset wiring. Inference,
// PLLs, HDMI I2C and the DDR PHY are interface stubs supplied by the runner.
module tb_hdmi_reset;
    logic cfg_clk = 0, pix_clk = 0, pe_clk = 0, ddr_clk = 0;
    logic run_pe = 0, run_ddr = 0, board_reset_n = 1;
    logic cfg_locked = 0, cfg_init = 0, vs = 0;
    wire rstn_out;
    wire [7:0] r_out, g_out, b_out;
    always #50 cfg_clk = ~cfg_clk;
    always #6.5 pix_clk = ~pix_clk;
    always #3.25 if (run_pe) pe_clk = ~pe_clk;
    always #4 if (run_ddr) ddr_clk = ~ddr_clk;

    hdmi_loop #(.ROI_CNN_ENABLE(0)) dut (
        .sys_clk(cfg_clk), .rst_n(board_reset_n), .rstn_out(rstn_out),
        .pixclk_in(pix_clk), .clk_p(ddr_clk), .clk_n(~ddr_clk),
        .vs_in(vs), .hs_in(1'b0), .de_in(1'b0),
        .r_in(8'b0), .g_in(8'b0), .b_in(8'b0),
        .r_out(r_out), .g_out(g_out), .b_out(b_out)
    );

    initial begin
        force dut.roi_video_rgb = 24'h123456;
        force dut.roi_video_de = 1'b1;
        force dut.roi_video_vs = 1'b0;
        force dut.roi_video_hs = 1'b0;

        #1 board_reset_n = 0;
        #1;
        assert (!rstn_out && !dut.rst_n_video && !dut.rst_n_pe)
            else $fatal(1, "initial board reset did not reach all domains");
        #1 board_reset_n = 1;
        cfg_locked = 1;
        wait (rstn_out);
        #0.001;
        assert (cfg_clk && dut.rstn_1ms == 16'h2710)
            else $fatal(1, "configuration reset must be registered after delay");
        repeat (3) @(posedge pix_clk);
        #0.001;
        assert (dut.rst_n_video && dut.u_ddr_video_delay_sync.rst_n_pix)
            else $fatal(1, "pixel resets failed to release after three clocks");
        assert (!dut.rst_n_pe && !dut.u_ddr_video_delay_sync.rst_n_ddr)
            else $fatal(1, "stopped clocks must hold local logic in reset");
        assert (!dut.rst_n_app_video && !dut.rst_n_app_pe)
            else $fatal(1, "application reset released before first VS");

        run_pe = 1;
        run_ddr = 1;
        repeat (3) @(posedge ddr_clk);
        #0.001;
        assert (dut.rst_n_pe && dut.u_ddr_video_delay_sync.rst_n_ddr)
            else $fatal(1, "late-starting domains did not release reset");
        assert ({r_out,g_out,b_out} == 0)
            else $fatal(1, "HDMI output enabled before configuration completion");

        @(negedge pix_clk);
        #1 cfg_init = 1;
        repeat (2) @(posedge pix_clk);
        #0.001;
        assert ({r_out,g_out,b_out} == 0)
            else $fatal(1, "raw cfg init signal bypassed synchronizer");
        @(posedge pix_clk);
        #0.001;
        assert ({r_out,g_out,b_out} == 24'h123456)
            else $fatal(1, "synchronized cfg completion did not enable HDMI");

        @(negedge pix_clk) vs = 1;
        repeat (8) @(posedge pix_clk);
        #0.001;
        assert (dut.rst_n_app_video && dut.rst_n_app_pe)
            else $fatal(1, "first VS did not release application domains");
        @(negedge pix_clk) vs = 0;
        @(negedge pe_clk) run_pe = 0;
        @(negedge ddr_clk) run_ddr = 0;
        #1 board_reset_n = 0;
        #0.001;
        assert (!rstn_out && !dut.rst_n_video && !dut.rst_n_pe &&
                !dut.rst_n_app_video && !dut.rst_n_app_pe &&
                !dut.u_ddr_video_delay_sync.rst_n_pix &&
                !dut.u_ddr_video_delay_sync.rst_n_ddr)
            else $fatal(1, "reassertion failed while PE/DDR clocks stopped");
        @(posedge pix_clk);
        #0.001;
        assert ({r_out,g_out,b_out} == 0)
            else $fatal(1, "HDMI output was not cleared by reset");
        $display("PASS tb_hdmi_reset: top/DDR reset routing, late clocks, first VS and synchronized HDMI enable");
        $finish;
    end

    initial begin
        #1100000;
        $fatal(1, "HDMI reset integration timeout");
    end
endmodule
