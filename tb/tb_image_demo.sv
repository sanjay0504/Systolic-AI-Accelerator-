// -----------------------------------------------------------------------------
// tb_image_demo.sv -- APPLICATION DEMO for accelerator_top.sv
//
// Not a correctness testbench. There is no golden model and no scoreboard here;
// tb_top.sv already proves the accelerator computes A x B correctly, including
// the K_real padding path. This file takes that verified accelerator, drives it
// with a REAL photograph of ANY size, and writes real results to files that
// hex_to_image.py turns back into three channel-split images.
//
// It exercises one thing tb_top does not: `skip_load` weight reuse across a long
// run of back-to-back multiplies that all share the same weight matrix.
//
// -----------------------------------------------------------------------------
// WHAT THE HARDWARE IS ACTUALLY DOING
// -----------------------------------------------------------------------------
// Each pixel is [R,G,B]. Four pixels form one 4x3 activation matrix A (padded to
// 4x4, K_real=3). Multiplying by a fixed 3x3 selector matrix B (padded to 4x4)
// isolates one channel:
//
//   C[i][j] = sum_k A[i][k] * B[k][j]
//
// With B = RED_WEIGHTS (only B[0][0]=1), C[i][0] = A[i][0] = R of pixel i and
// every other column is zero -- so output row i packs back into a word carrying
// only red. GREEN uses B[1][1]=1, BLUE uses B[2][2]=1. Three passes over the
// whole image, one per channel.
//
// -----------------------------------------------------------------------------
// RUNTIME SIZING -- nothing about image size is a compile-time parameter
// -----------------------------------------------------------------------------
// IMG_SIZE / NUM_PIXELS deliberately do not exist. width/height/real_pixels/
// total_pixels are read from image_meta.txt at time 0 via $fscanf, and
// pixel_data is a dynamic array sized with new[total_pixels]. The same compiled
// testbench runs a 4x4 test pattern or a 12-megapixel photo with no edit and no
// recompilation -- point image_to_hex.py at a different file and re-run.
//
// -----------------------------------------------------------------------------
// FILE FORMATS
// -----------------------------------------------------------------------------
// INPUT  image_meta.txt : four integers, one per line, IN THIS ORDER --
//                           line 1: width
//                           line 2: height
//                           line 3: real_pixels    (width*height)
//                           line 4: total_pixels   (real_pixels padded up to a
//                                                   multiple of 4 by the script)
//
// INPUT  act_stim.hex   : total_pixels lines, one 32-bit hex word per pixel,
//                         row-major, INCLUDING the black padding pixels at the
//                         end. Word layout (act_mem's lane convention, lane 0 in
//                         the low byte):
//                           bits [7:0]   = R  -> lane 0
//                           bits [15:8]  = G  -> lane 1
//                           bits [23:16] = B  -> lane 2
//                           bits [31:24] = 0  -> lane 3, the K_real=3 pad lane
//
// OUTPUT results_red.hex / results_green.hex / results_blue.hex : total_pixels
//                         lines each, same word layout, same pixel order as the
//                         input, padding pixels included. Cropping the padding
//                         back off is hex_to_image.py's job -- it has
//                         real_pixels from the metadata file. This testbench
//                         does not crop.
//
// -----------------------------------------------------------------------------
// WHY SHIFT = 0, and why the bytes survive round-trip
// -----------------------------------------------------------------------------
// The DUT is instantiated with SHIFT=0, as in tb_top. At the design default
// SHIFT=8 every result would be scaled down by 256 and the entire image would
// come back black -- indistinguishable from a completely dead datapath.
//
// The subtler point is signedness. The datapath treats the 8-bit lanes as
// SIGNED, so a pixel byte of 200 enters the array as -56. It is multiplied by 1,
// nothing else is accumulated into it, and -56 sits comfortably inside the
// saturation window [-128,127], so output_processing passes it through and the
// low 8 bits read back as 0xC8 = 200 again. Every value 0..255 round-trips
// bit-exactly through two's complement. Saturation never fires for a selector
// matrix, which is exactly why this demo works on real photographs and not just
// on dark ones.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (what this file asserts about itself)
// -----------------------------------------------------------------------------
//   * skip_load is 0 on batch 0 of EVERY channel and 1 on every other batch
//     within that channel. Counted per channel and checked at the end of each
//     channel's loop; the first few batches of each channel also print which
//     mode they ran in, so the pattern is visible in the transcript and not only
//     in an assertion.
//   * Each output file receives exactly total_pixels lines. Counted as written
//     and checked before $finish.
//   * Nothing is sized at compile time: the run works for ANY
//     image_meta.txt / act_stim.hex pair without recompilation. The watchdog is
//     derived from the runtime num_batches for the same reason.
//   * DUT access is black-box only -- external ports, exactly like tb_top.sv.
//     No dut.<internal> reference appears anywhere in this file.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_image_demo;

    // ---------------------------------------------------------------------
    // Parameters. Only the array geometry is fixed here; everything about the
    // image comes from the metadata file at runtime.
    // ---------------------------------------------------------------------
    localparam int  N        = 4;      // array dimension = pixels per batch
    localparam int  K_REAL   = 3;      // real contraction depth = R,G,B
    localparam int  DEPTH    = 16;
    localparam int  IN_W     = 8;
    localparam int  ACC_W    = 32;
    localparam int  DW_OUT   = 8;
    localparam int  SHIFT    = 0;      // see the header note -- not the default 8
    localparam int  USE_BIAS = 0;
    localparam int  USE_RELU = 0;
    localparam int  ADDR_W   = $clog2(DEPTH);
    localparam int  KW       = $clog2(N+1);

    localparam time TCLK     = 10ns;
    localparam time SETTLE   = 1ns;
    localparam int  RUN_GUARD = 400;   // cycles to wait for done before crying foul

    // The hex word format packs N lanes of IN_W bits into one 32-bit word. Both
    // the Python scripts and the pack/unpack loops below assume that fits.
    localparam int  WORD_W   = 32;

    // ---------------------------------------------------------------------
    // DUT interface
    // ---------------------------------------------------------------------
    logic              clk;
    logic              rst_n;
    logic              start;
    logic              done;
    logic              skip_load;
    logic [KW-1:0]     K_real;

    logic              weight_wr_en;
    logic [ADDR_W-1:0] weight_wr_addr;
    logic [IN_W-1:0]   weight_wr_data [0:N-1];

    logic              act_wr_en;
    logic [ADDR_W-1:0] act_wr_addr;
    logic [IN_W-1:0]   act_wr_data    [0:N-1];

    logic              out_rd_en;
    logic [ADDR_W-1:0] out_rd_addr;
    logic [DW_OUT-1:0] out_rd_data    [0:N-1];

    accelerator_top #(
        .N        (N),
        .DEPTH    (DEPTH),
        .IN_W     (IN_W),
        .ACC_W    (ACC_W),
        .DW_OUT   (DW_OUT),
        .USE_BIAS (USE_BIAS),
        .USE_RELU (USE_RELU),
        .SHIFT    (SHIFT)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .done           (done),
        .skip_load      (skip_load),
        .K_real         (K_real),
        .weight_wr_en   (weight_wr_en),
        .weight_wr_addr (weight_wr_addr),
        .weight_wr_data (weight_wr_data),
        .act_wr_en      (act_wr_en),
        .act_wr_addr    (act_wr_addr),
        .act_wr_data    (act_wr_data),
        .out_rd_en      (out_rd_en),
        .out_rd_addr    (out_rd_addr),
        .out_rd_data    (out_rd_data)
    );

    initial begin clk = 1'b0; forever #(TCLK/2) clk = ~clk; end

    // No $dumpvars on purpose. A full-resolution photo is hundreds of thousands
    // of runs; dumping every signal would produce a multi-gigabyte VCD and slow
    // the demo to a crawl. tb_top.sv is where waveforms are wanted.

    // ---------------------------------------------------------------------
    // Runtime image geometry -- read, never hardcoded
    // ---------------------------------------------------------------------
    int    width, height, real_pixels, total_pixels;
    int    num_batches;
    bit    sizing_valid = 1'b0;        // gates the watchdog, which needs num_batches

    logic [WORD_W-1:0] pixel_data [];  // dynamic: sized new[total_pixels]

    // ---------------------------------------------------------------------
    // Bookkeeping for the self-checks
    // ---------------------------------------------------------------------
    int    fd_out    [0:2];            // results_red / _green / _blue
    int    lines_out [0:2];            // lines actually written to each
    int    load_runs [0:2];            // runs that loaded weights (must be 1)
    int    skip_runs [0:2];            // runs that reused them (must be nb-1)
    int    total_runs;
    int    demo_errors;

    string CH_NAME [0:2] = '{"RED", "GREEN", "BLUE"};
    string CH_FILE [0:2] = '{"results_red.hex", "results_green.hex", "results_blue.hex"};

    // ---------------------------------------------------------------------
    // THE THREE FIXED SELECTOR MATRICES
    //
    // Row-major, exactly as they go into weight_mem. Written out in full rather
    // than generated from a loop so the demo can be read straight off the
    // screen: each one is a 3x3 selector padded to 4x4, and the single 1 sits at
    // [channel][channel].
    //
    //   RED           GREEN         BLUE
    //   [1 0 0 0]     [0 0 0 0]     [0 0 0 0]
    //   [0 0 0 0]     [0 1 0 0]     [0 0 0 0]
    //   [0 0 0 0]     [0 0 0 0]     [0 0 1 0]
    //   [0 0 0 0]     [0 0 0 0]     [0 0 0 0]
    //
    // Column 3 is zero in all three, which is what makes the output word's
    // bits[31:24] come back as 0 -- the same unused lane the input word has.
    // ---------------------------------------------------------------------
    logic signed [IN_W-1:0] W_SEL [0:2][0:N-1][0:N-1];

    function automatic void init_selector_matrices();
        for (int c = 0; c < 3; c++)
            for (int r = 0; r < N; r++)
                for (int k = 0; k < N; k++)
                    W_SEL[c][r][k] = '0;

        W_SEL[0][0][0] = 8'sd1;    // RED   : C[i][0] = A[i][0] = R
        W_SEL[1][1][1] = 8'sd1;    // GREEN : C[i][1] = A[i][1] = G
        W_SEL[2][2][2] = 8'sd1;    // BLUE  : C[i][2] = A[i][2] = B
    endfunction

    // ---------------------------------------------------------------------
    // Watchdog, sized from the runtime batch count rather than a constant.
    //
    // 50 cycles per run is a generous upper bound: one run is roughly 4N+2
    // cycles of hardware plus the preload/read-back cycles this testbench adds
    // around it. It waits for sizing_valid because num_batches does not exist
    // until image_meta.txt has been read.
    // ---------------------------------------------------------------------
    initial begin
        wait (sizing_valid);
        #(num_batches * 3 * 50 * TCLK);
        $error("TIMEOUT -- demo did not finish within the runtime-sized watchdog (%0d batches x 3 channels)",
               num_batches);
        $finish;
    end

    // =====================================================================
    // FILE INPUT
    // =====================================================================

    // Reads the four integers in their documented order. Anything short or
    // unreadable is fatal -- running on a partially-read geometry would produce
    // an output file of the wrong length and a silently mangled image.
    task automatic read_metadata();
        int fd, code;

        fd = $fopen("image_meta.txt", "r");
        if (fd == 0) begin
            $error("Cannot open image_meta.txt -- run image_to_hex.py first");
            $finish;
        end

        code = $fscanf(fd, "%d", width);        if (code != 1) $error("meta: bad width");
        code = $fscanf(fd, "%d", height);       if (code != 1) $error("meta: bad height");
        code = $fscanf(fd, "%d", real_pixels);  if (code != 1) $error("meta: bad real_pixels");
        code = $fscanf(fd, "%d", total_pixels); if (code != 1) $error("meta: bad total_pixels");
        $fclose(fd);

        if (total_pixels <= 0 || (total_pixels % N) != 0) begin
            $error("meta: total_pixels=%0d is not a positive multiple of %0d -- image_to_hex.py pads it, so this file is stale or hand-edited",
                   total_pixels, N);
            $finish;
        end

        num_batches = total_pixels / N;
    endtask

    // pixel_data is allocated only after total_pixels is known, which is the
    // whole point of it being a dynamic array.
    task automatic read_pixels();
        pixel_data = new[total_pixels];
        $readmemh("act_stim.hex", pixel_data);
    endtask

    task automatic open_output_files();
        for (int c = 0; c < 3; c++) begin
            fd_out[c] = $fopen(CH_FILE[c], "w");
            if (fd_out[c] == 0) begin
                $error("Cannot open %s for writing", CH_FILE[c]);
                $finish;
            end
            lines_out[c] = 0;
        end
    endtask

    // =====================================================================
    // EXTERNAL-PORT DRIVER TASKS -- the host's view of the accelerator.
    // Black box throughout: start/done, the two write ports, the read port.
    // =====================================================================

    task automatic do_reset();
        @(negedge clk);
        rst_n          = 1'b0;
        start          = 1'b0;
        skip_load      = 1'b0;
        K_real         = KW'(K_REAL);
        weight_wr_en   = 1'b0;
        act_wr_en      = 1'b0;
        out_rd_en      = 1'b0;
        weight_wr_addr = '0;
        act_wr_addr    = '0;
        out_rd_addr    = '0;
        for (int k = 0; k < N; k++) begin
            weight_wr_data[k] = '0;
            act_wr_data[k]    = '0;
        end
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
    endtask

    // B goes in ROW-MAJOR and NOT pre-reversed -- address_gen's down-counter
    // does the bottom-row-first reversal internally. Called ONCE per channel,
    // before that channel's first batch; the whole point of skip_load is that it
    // is not called again for batches 1..num_batches-1.
    task automatic preload_weights(input int ch);
        for (int r = 0; r < N; r++) begin
            @(negedge clk);
            weight_wr_en   = 1'b1;
            weight_wr_addr = ADDR_W'(r);
            for (int k = 0; k < N; k++) weight_wr_data[k] = W_SEL[ch][r][k];
        end
        @(negedge clk);
        weight_wr_en = 1'b0;
    endtask

    // Activations are NOT reusable and are reloaded on EVERY batch -- each batch
    // is four different pixels. Only the weights are stationary.
    //
    // Row r of A is pixel (base + r); lane k of that row is byte k of the pixel
    // word, so lane 0 = R, lane 1 = G, lane 2 = B, lane 3 = the pad lane that
    // K_real=3 zeroes at the array edge anyway.
    task automatic preload_act_batch(input int base);
        for (int r = 0; r < N; r++) begin
            @(negedge clk);
            act_wr_en   = 1'b1;
            act_wr_addr = ADDR_W'(r);
            for (int k = 0; k < N; k++)
                act_wr_data[k] = pixel_data[base + r][k*IN_W +: IN_W];
        end
        @(negedge clk);
        act_wr_en = 1'b0;
    endtask

    // One multiply. `skip` is committed before the start pulse because
    // control_unit samples skip_load on the same edge as start; setting it after
    // the pulse would apply to the NEXT run, not this one.
    task automatic run_one_batch(input int ch, input bit skip);
        int guard;

        @(negedge clk);
        skip_load = skip;
        K_real    = KW'(K_REAL);

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        if (skip) skip_runs[ch]++; else load_runs[ch]++;
        total_runs++;

        guard = 0;
        forever begin
            @(negedge clk);
            #(TCLK/2 - SETTLE);
            if (done === 1'b1) break;
            guard++;
            if (guard > RUN_GUARD) begin
                $error("[%s] done never asserted within %0d cycles at time %0t",
                       CH_NAME[ch], RUN_GUARD, $time);
                demo_errors++;
                break;
            end
        end
    endtask

    // Read C back one row per cycle and write one hex word per row. Row i of C
    // is pixel (base + i)'s result, and its lanes pack back into a word in
    // exactly the input's layout -- lane 0 into bits[7:0], and so on -- so the
    // output file needs no reordering to line up with act_stim.hex.
    task automatic read_and_write_result(input int ch, input int base);
        logic [WORD_W-1:0] word;

        for (int r = 0; r < N; r++) begin
            @(negedge clk);
            out_rd_en   = 1'b1;
            out_rd_addr = ADDR_W'(r);
            @(posedge clk);
            #SETTLE;

            word = '0;
            for (int k = 0; k < N; k++) word[k*DW_OUT +: DW_OUT] = out_rd_data[k];

            $fwrite(fd_out[ch], "%08x\n", word);
            lines_out[ch]++;
        end
        @(negedge clk);
        out_rd_en = 1'b0;
    endtask

    // =====================================================================
    // THE CHANNEL PASS
    //
    // ############################################################
    // #  skip_load MUST BE RESET TO 0 AT THE START OF EACH        #
    // #  CHANNEL. Read this before changing anything below.       #
    // ############################################################
    //
    // Weight reuse is valid only WITHIN a channel. Batch 0 of RED, batch 0 of
    // GREEN and batch 0 of BLUE each need a real load, because each is the first
    // run after a different selector matrix was written into weight_mem. Only
    // batches 1..num_batches-1 of a given channel may skip.
    //
    // Carrying skip_load=1 across the channel boundary -- e.g. hoisting it out
    // of this task, or leaving it high from the previous channel's last batch --
    // means GREEN and BLUE would both compute with RED's resident weights. The
    // hardware CANNOT detect this: control_unit's contract says explicitly that
    // it trusts the caller, so there is no error, no X, no stuck done. Every
    // output file would still be exactly the right length, full of plausible
    // 0..255 values, and all three "channel" images would just be the red one.
    // That is the same class of silent, structurally-normal-looking wrongness as
    // the wload one-cycle offset documented in control_unit.sv, and it is the
    // single easiest mistake to make in this file.
    //
    // The reset is expressed as `skip = (batch != 0)` -- a per-batch expression
    // recomputed inside the loop -- rather than a flag mutated across
    // iterations, so there is no state to forget to clear.
    // =====================================================================
    task automatic run_channel(input int ch);
        int base;
        bit skip;

        // Weights loaded ONCE for the entire channel. Everything after this
        // depends on them staying resident in the PE registers.
        preload_weights(ch);

        for (int batch = 0; batch < num_batches; batch++) begin
            base = batch * N;
            skip = (batch != 0);          // <-- the per-channel reset, see above

            preload_act_batch(base);      // every batch: activations are not reusable
            run_one_batch(ch, skip);
            read_and_write_result(ch, base);

            // Visible confirmation of the mode for the first few batches of each
            // channel, so the load/skip pattern can be read off the transcript
            // as well as trusted to the end-of-channel assertion.
            if (batch < 3)
                $display("[%s] batch %0d ran with skip_load=%0b (%s)",
                         CH_NAME[ch], batch, skip,
                         skip ? "reusing resident weights" : "LOADING weights");

            if (batch % (num_batches / 20 + 1) == 0)
                $display("[%s] batch %0d / %0d (%0d%%)", CH_NAME[ch], batch,
                         num_batches, (batch*100)/num_batches);
        end

        // Per-channel self-check: exactly one loading run, all the rest skipped.
        if (load_runs[ch] != 1) begin
            $error("[%s] expected exactly 1 weight-loading run, saw %0d -- skip_load was not reset at this channel's batch 0",
                   CH_NAME[ch], load_runs[ch]);
            demo_errors++;
        end
        if (skip_runs[ch] != num_batches - 1) begin
            $error("[%s] expected %0d weight-reusing runs, saw %0d",
                   CH_NAME[ch], num_batches - 1, skip_runs[ch]);
            demo_errors++;
        end

        $display("[%s] complete: %0d batches, %0d load run, %0d reuse runs, %0d lines written",
                 CH_NAME[ch], num_batches, load_runs[ch], skip_runs[ch], lines_out[ch]);
    endtask

    // =====================================================================
    // Final report
    // =====================================================================
    task automatic final_checks();
        for (int c = 0; c < 3; c++) begin
            $fclose(fd_out[c]);
            if (lines_out[c] != total_pixels) begin
                $error("%s has %0d lines, expected %0d (total_pixels)",
                       CH_FILE[c], lines_out[c], total_pixels);
                demo_errors++;
            end
        end

        $display("\n=================================================================");
        $display(" IMAGE DEMO COMPLETE");
        $display("=================================================================");
        $display(" Image            : %0dx%0d  (%0d real pixels, %0d padded)",
                 width, height, real_pixels, total_pixels);
        $display(" Batches/channel  : %0d", num_batches);
        $display(" Total runs       : %0d  (%0d weight loads, %0d weight reuses)",
                 total_runs, load_runs[0]+load_runs[1]+load_runs[2],
                 skip_runs[0]+skip_runs[1]+skip_runs[2]);
        $display(" Simulated time   : %0t", $time);
        $display(" Output files     : %s, %s, %s (%0d lines each)",
                 CH_FILE[0], CH_FILE[1], CH_FILE[2], total_pixels);
        $display("-----------------------------------------------------------------");
        if (demo_errors == 0)
            $display(" === DEMO OK -- run: python hex_to_image.py ===");
        else
            $display(" === DEMO FINISHED WITH %0d PROBLEM(S) -- see errors above ===",
                     demo_errors);
        $display("=================================================================\n");
    endtask

    // =====================================================================
    // Main sequence
    // =====================================================================
    initial begin
        total_runs  = 0;
        demo_errors = 0;
        for (int c = 0; c < 3; c++) begin
            load_runs[c] = 0;
            skip_runs[c] = 0;
            lines_out[c] = 0;
        end

        rst_n          = 1'b1;
        start          = 1'b0;
        skip_load      = 1'b0;
        K_real         = KW'(K_REAL);
        weight_wr_en   = 1'b0;
        act_wr_en      = 1'b0;
        out_rd_en      = 1'b0;
        weight_wr_addr = '0;
        act_wr_addr    = '0;
        out_rd_addr    = '0;
        for (int k = 0; k < N; k++) begin
            weight_wr_data[k] = '0;
            act_wr_data[k]    = '0;
        end

        init_selector_matrices();

        read_metadata();
        read_pixels();
        open_output_files();
        sizing_valid = 1'b1;          // releases the runtime-sized watchdog

        $display("Starting image demo: %0dx%0d (%0d real pixels, %0d padded), %0d batches x 3 channels = %0d total runs",
                 width, height, real_pixels, total_pixels, num_batches, num_batches*3);

        do_reset();

        run_channel(0);   // RED
        run_channel(1);   // GREEN
        run_channel(2);   // BLUE

        final_checks();
        $finish;
    end

endmodule
