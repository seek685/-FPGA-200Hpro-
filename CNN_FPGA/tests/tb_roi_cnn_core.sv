`timescale 1ns/1ps
// Run with cwd = CNN_FPGA/rtl_pds/roi_cnn.
// Tests every hidden activation against a separate nested-loop integer model,
// then tests all four logits of eight independently exported real images.
module tb_roi_cnn_core;
    reg clk = 0;
    always #5 clk <= ~clk;
    reg rst_n = 0;
    reg image_wr_en = 0;
    reg [9:0] image_wr_addr = 0;
    reg [23:0] image_wr_rgb = 0;
    reg start = 0;
    wire busy, done;
    wire [1:0] class_id;
    wire signed [31:0] score0, score1, score2, score3;
    roi_cnn_core #(
        .W1_FILE(""), .B1_FILE(""), .W2_FILE(""), .B2_FILE(""),
        .W3_FILE(""), .B3_FILE(""), .W4_FILE(""), .B4_FILE("")
    ) dut (
        .clk(clk), .rst_n(rst_n), .image_wr_en(image_wr_en),
        .image_wr_addr(image_wr_addr), .image_wr_rgb(image_wr_rgb),
        .start(start), .busy(busy), .done(done), .class_id(class_id),
        .score0(score0), .score1(score1), .score2(score2), .score3(score3)
    );

    integer image_ref [0:2351]; // interleaved RGB; separate from DUT image RAM
    integer w1 [0:215], w2 [0:1151], w3 [0:12799], w4 [0:127];
    integer b1 [0:7], b2 [0:15], b3 [0:31], b4 [0:3];
    integer c1 [0:5407], p1 [0:1351], c2 [0:1935], p2 [0:399];
    integer f1 [0:31], expected_scores [0:3];
    integer expected_class;
    reg [23:0] real_images [0:6271];
    reg signed [31:0] real_logits [0:31];
    reg [7:0] real_classes [0:7];
    integer i, n;
    integer cycles;

    function automatic integer activate;
        input integer value;
        input integer shift;
        integer scaled;
        begin
            // Division after testing sign independently implements truncation
            // of a nonnegative value, without copying RTL's shift function.
            if (value <= 0) activate = 0;
            else begin
                scaled = value / (2 ** shift);
                if (scaled > 255) activate = 255;
                else activate = scaled;
            end
        end
    endfunction

    task automatic prepare_synthetic;
        input integer seed;
        integer j;
        begin
            for (j=0; j<2352; j=j+1)
                image_ref[j] = (((j/3)%28)*11 + (j/84)*17 + (j%3)*53 + seed*37)%256;
            for (j=0; j<216; j=j+1) begin
                w1[j] = (j*11 + j/9)%17 - 8;
                dut.conv1_weights[j] = w1[j][7:0];
            end
            for (j=0; j<1152; j=j+1) begin
                w2[j] = (j*7 + j/9)%13 - 6;
                dut.conv2_weights[j] = w2[j][7:0];
            end
            for (j=0; j<12800; j=j+1) begin
                w3[j] = (j*3 + j/17)%15 - 7;
                dut.fc1_weights[j] = w3[j][7:0];
            end
            for (j=0; j<128; j=j+1) begin
                w4[j] = (j*5 + j/7)%21 - 10;
                dut.fc2_weights[j] = w4[j][7:0];
            end
            for (j=0; j<8; j=j+1) begin
                b1[j] = j*1479 - 4100;
                if (j==0) b1[j] = 1000000;
                if (j==1) b1[j] = -1000000;
                dut.conv1_bias[j] = b1[j];
            end
            for (j=0; j<16; j=j+1) begin
                b2[j] = j*1333 - 7000;
                if (j==0) b2[j] = 1000000;
                if (j==1) b2[j] = -1000000;
                dut.conv2_bias[j] = b2[j];
            end
            for (j=0; j<32; j=j+1) begin
                b3[j] = j*1987 - 10000;
                if (j==0) b3[j] = 1000000;
                if (j==1) b3[j] = -1000000;
                dut.fc1_bias[j] = b3[j];
            end
            for (j=0; j<4; j=j+1) begin
                b4[j] = j*1100 - 4000;
                dut.fc2_bias[j] = b4[j];
            end
        end
    endtask

    task automatic calculate_reference;
        integer oc, ic, x, y, kx, ky, j, acc, largest;
        begin
            for (oc=0; oc<8; oc=oc+1)
                for (y=0; y<26; y=y+1)
                    for (x=0; x<26; x=x+1) begin
                        acc = b1[oc];
                        for (ic=0; ic<3; ic=ic+1)
                            for (ky=0; ky<3; ky=ky+1)
                                for (kx=0; kx<3; kx=kx+1)
                                    acc = acc + image_ref[((y+ky)*28+x+kx)*3+ic] *
                                        w1[((oc*3+ic)*3+ky)*3+kx];
                        c1[(oc*26+y)*26+x] = activate(acc, 10);
                    end
            for (oc=0; oc<8; oc=oc+1)
                for (y=0; y<13; y=y+1)
                    for (x=0; x<13; x=x+1) begin
                        largest = 0;
                        for (ky=0; ky<2; ky=ky+1)
                            for (kx=0; kx<2; kx=kx+1)
                                if (c1[(oc*26+y*2+ky)*26+x*2+kx] > largest)
                                    largest = c1[(oc*26+y*2+ky)*26+x*2+kx];
                        p1[(oc*13+y)*13+x] = largest;
                    end
            for (oc=0; oc<16; oc=oc+1)
                for (y=0; y<11; y=y+1)
                    for (x=0; x<11; x=x+1) begin
                        acc = b2[oc];
                        for (ic=0; ic<8; ic=ic+1)
                            for (ky=0; ky<3; ky=ky+1)
                                for (kx=0; kx<3; kx=kx+1)
                                    acc = acc + p1[(ic*13+y+ky)*13+x+kx] *
                                        w2[((oc*8+ic)*3+ky)*3+kx];
                        c2[(oc*11+y)*11+x] = activate(acc, 8);
                    end
            for (oc=0; oc<16; oc=oc+1)
                for (y=0; y<5; y=y+1)
                    for (x=0; x<5; x=x+1) begin
                        largest = 0;
                        for (ky=0; ky<2; ky=ky+1)
                            for (kx=0; kx<2; kx=kx+1)
                                if (c2[(oc*11+y*2+ky)*11+x*2+kx] > largest)
                                    largest = c2[(oc*11+y*2+ky)*11+x*2+kx];
                        p2[(oc*5+y)*5+x] = largest;
                    end
            for (oc=0; oc<32; oc=oc+1) begin
                acc = b3[oc];
                for (j=0; j<400; j=j+1) acc = acc + p2[j] * w3[oc*400+j];
                f1[oc] = activate(acc, 10);
            end
            for (oc=0; oc<4; oc=oc+1) begin
                acc = b4[oc];
                for (j=0; j<32; j=j+1) acc = acc + f1[j] * w4[oc*32+j];
                expected_scores[oc] = acc;
            end
            expected_class = 0;
            for (oc=1; oc<4; oc=oc+1)
                if (expected_scores[oc] > expected_scores[expected_class])
                    expected_class = oc;
        end
    endtask

    task automatic load_image;
        integer j;
        begin
            for (j=0; j<784; j=j+1) begin
                @(negedge clk);
                image_wr_en = 1;
                image_wr_addr = j[9:0];
                image_wr_rgb = {image_ref[j*3][7:0], image_ref[j*3+1][7:0], image_ref[j*3+2][7:0]};
            end
            @(negedge clk);
            image_wr_en = 0;
            // Exercise ignored out-of-range writes as well as one idle cycle.
            image_wr_en = 1; image_wr_addr = 10'd1023; image_wr_rgb = 24'hffffff;
            @(negedge clk);
            image_wr_en = 0;
        end
    endtask

    task automatic infer_and_check;
        input integer check_hidden;
        integer j;
        begin
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            if (!busy || done) $fatal(1, "start was not accepted");
            cycles = 0;
            while (!done) begin
                @(negedge clk);
                cycles = cycles + 1;
                if (cycles == 5) begin
                    // Neither a start nor a write may disturb this inference.
                    start = 1; image_wr_en = 1;
                    image_wr_addr = 0; image_wr_rgb = 24'hbadbad;
                end
                if (cycles == 6) begin start = 0; image_wr_en = 0; end
                if (!busy && !done) $fatal(1, "busy dropped before done");
                if (cycles > 700000) $fatal(1, "inference timeout");
            end
            if (busy) $fatal(1, "busy remained high on done");
            if (cycles != 634580) $fatal(1, "unexpected inference latency %0d", cycles);
            if (score0 !== expected_scores[0] || score1 !== expected_scores[1] ||
                score2 !== expected_scores[2] || score3 !== expected_scores[3])
                $fatal(1, "logits got [%0d,%0d,%0d,%0d], expected [%0d,%0d,%0d,%0d]",
                    score0,score1,score2,score3,expected_scores[0],expected_scores[1],
                    expected_scores[2],expected_scores[3]);
            if ({30'd0, class_id} !== expected_class) $fatal(1, "argmax mismatch");
            if (dut.image_mem[0] !== {image_ref[0][7:0], image_ref[1][7:0], image_ref[2][7:0]})
                $fatal(1, "busy image write was not ignored");
            if (check_hidden != 0) begin
                for (j=0; j<5408; j=j+1)
                    if (dut.conv1_mem[j] !== c1[j][7:0]) $fatal(1, "conv1 mismatch %0d", j);
                for (j=0; j<1352; j=j+1)
                    if (dut.pool1_mem[j] !== p1[j][7:0]) $fatal(1, "pool1 mismatch %0d", j);
                for (j=0; j<1936; j=j+1)
                    if (dut.conv2_mem[j] !== c2[j][7:0]) $fatal(1, "conv2 mismatch %0d", j);
                for (j=0; j<400; j=j+1)
                    if (dut.pool2_mem[j] !== p2[j][7:0]) $fatal(1, "pool2 mismatch %0d", j);
                for (j=0; j<32; j=j+1)
                    if (dut.fc1_mem[j] !== f1[j][7:0]) $fatal(1, "fc1 mismatch %0d", j);
                if (c1[0] != 255 || c1[676] != 0 || c2[0] != 255 ||
                    c2[121] != 0 || f1[0] != 255 || f1[1] != 0)
                    $fatal(1, "synthetic test did not exercise ReLU and saturation");
            end
            $display("PASS cycles=%0d class=%0d logits=[%0d,%0d,%0d,%0d] hidden=%0d",
                cycles,class_id,score0,score1,score2,score3,check_hidden);
            @(negedge clk);
            if (done || busy) $fatal(1, "done must be a one-cycle pulse");
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        prepare_synthetic(1);
        calculate_reference();
        load_image();
        infer_and_check(1);

        // Consecutive images need no reset; all-negative tied logits choose 0.
        prepare_synthetic(4);
        for (i=0; i<128; i=i+1) begin w4[i]=0; dut.fc2_weights[i]=0; end
        b4[0]=-5; b4[1]=-5; b4[2]=-9; b4[3]=-7;
        for (i=0; i<4; i=i+1) dut.fc2_bias[i]=b4[i];
        calculate_reference();
        load_image();
        infer_and_check(1);

        // Abort in-flight work. A fresh complete image must work after reset.
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        repeat (123) @(negedge clk);
        rst_n=0;
        repeat (3) @(negedge clk);
        if (busy || done || class_id != 0 || score0 != 0 || score1 != 0 ||
            score2 != 0 || score3 != 0) $fatal(1, "reset did not clear control/results");
        rst_n=1;

        $readmemh("../data_process/mem_data/roi_cnn/conv1_w.mem", dut.conv1_weights);
        $readmemh("../data_process/mem_data/roi_cnn/conv1_b.mem", dut.conv1_bias);
        $readmemh("../data_process/mem_data/roi_cnn/conv2_w.mem", dut.conv2_weights);
        $readmemh("../data_process/mem_data/roi_cnn/conv2_b.mem", dut.conv2_bias);
        $readmemh("../data_process/mem_data/roi_cnn/fc1_w.mem", dut.fc1_weights);
        $readmemh("../data_process/mem_data/roi_cnn/fc1_b.mem", dut.fc1_bias);
        $readmemh("../data_process/mem_data/roi_cnn/fc2_w.mem", dut.fc2_weights);
        $readmemh("../data_process/mem_data/roi_cnn/fc2_b.mem", dut.fc2_bias);
        $readmemh("../../tests/fixtures/roi_cnn/test_images_rgb.mem", real_images);
        $readmemh("../../tests/fixtures/roi_cnn/test_logits.mem", real_logits);
        $readmemh("../../tests/fixtures/roi_cnn/test_classes.mem", real_classes);
        for (n=0; n<8; n=n+1) begin
            for (i=0; i<784; i=i+1) begin
                image_ref[i*3] = {24'd0, real_images[n*784+i][23:16]};
                image_ref[i*3+1] = {24'd0, real_images[n*784+i][15:8]};
                image_ref[i*3+2] = {24'd0, real_images[n*784+i][7:0]};
            end
            for (i=0; i<4; i=i+1) expected_scores[i] = real_logits[n*4+i];
            expected_class = {24'd0, real_classes[n]};
            load_image();
            infer_and_check(0);
        end
        $display("PASS roi_cnn_core: 2 synthetic full-layer references, 8 real exact-logit vectors, protocol/reset");
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "testbench watchdog");
    end
endmodule
