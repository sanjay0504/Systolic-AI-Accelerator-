// -----------------------------------------------------------------------------
// tb_top.sv -- black-box, self-checking testbench for accelerator_top.sv
//
// Every task except test_timing_alignment_regression touches ONLY the external
// ports: start/done, the two write ports, the read-back port. That is how a host
// CPU would drive this accelerator, and it is what makes a failure here mean
// "integration/wiring", since every sub-module is already verified on its own.
//
// -----------------------------------------------------------------------------
// WHY SHIFT = 0
// -----------------------------------------------------------------------------
// The DUT is instantiated with SHIFT=0 (saturation still applies). This is a
// deliberate choice for a wiring test: at the design's default SHIFT=8 every
// scaled result of a small matrix is crushed to zero -- the hand-checked case
// [1 2;3 4]x[5 6;7 8] = [19 22;43 50] would read back as an all-zero matrix, and
// an all-zero matrix is exactly what a completely broken datapath also produces.
// With SHIFT=0 the read-back IS the matrix product, so a misrouted lane or a
// one-cycle misalignment shows up as a wrong number instead of hiding inside a
// zero. The shift/saturate path itself is exhaustively covered by
// tb_output_processing; it is not what this file is for.
//
// The golden model tracks whatever SHIFT/USE_BIAS/USE_RELU the DUT is built
// with, so changing them here keeps the comparison honest.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_top;

    // ---------------------------------------------------------------------
    // Parameters / infrastructure
    // ---------------------------------------------------------------------
    localparam int  N        = 4;
    localparam int  DEPTH    = 16;
    localparam int  IN_W     = 8;
    localparam int  ACC_W    = 32;
    localparam int  DW_OUT   = 8;
    localparam int  SHIFT    = 0;      // see the header note
    localparam int  USE_BIAS = 0;
    localparam int  USE_RELU = 0;
    localparam int  ADDR_W   = $clog2(DEPTH);

    localparam time TCLK   = 10ns;
    localparam time SETTLE = 1ns;
    localparam int  SEED   = 32'h5EED_7099;
    localparam int  RUN_GUARD = 400;   // cycles to wait for done before crying foul

    localparam logic signed [ACC_W-1:0] MAX_OUT =  (ACC_W'(1) <<< (DW_OUT-1)) - 1;
    localparam logic signed [ACC_W-1:0] MIN_OUT = -(ACC_W'(1) <<< (DW_OUT-1));

    logic              clk;
    logic              rst_n;
    logic              start;
    logic              done;

    logic              weight_wr_en;
    logic [ADDR_W-1:0] weight_wr_addr;
    logic [IN_W-1:0]   weight_wr_data [0:N-1];

    logic              act_wr_en;
    logic [ADDR_W-1:0] act_wr_addr;
    logic [IN_W-1:0]   act_wr_data    [0:N-1];

    logic              out_rd_en;
    logic [ADDR_W-1:0] out_rd_addr;
    logic [DW_OUT-1:0] out_rd_data    [0:N-1];

    // Padding extension: real inner (contraction) dimension for the run.
    localparam int KW = $clog2(N+1);
    logic [KW-1:0]     K_real;

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

    initial begin $dumpfile("tb_top.vcd"); $dumpvars(0, tb_top); end

    initial begin
        #2000000;
        $error("TIMEOUT -- done never asserted");
        $finish;
    end

    // ---------------------------------------------------------------------
    // GOLDEN MODEL -- matrix multiply followed by output_processing's exact
    // pipeline, in the same order and with the same bounds.
    // ---------------------------------------------------------------------
    function automatic logic signed [DW_OUT-1:0] saturate(input logic signed [ACC_W-1:0] v);
        if      (v > MAX_OUT) return MAX_OUT[DW_OUT-1:0];
        else if (v < MIN_OUT) return MIN_OUT[DW_OUT-1:0];
        else                  return v[DW_OUT-1:0];
    endfunction

    function automatic void golden(
        input  logic signed [IN_W-1:0]   A [0:N-1][0:N-1],
        input  logic signed [IN_W-1:0]   B [0:N-1][0:N-1],
        output logic signed [DW_OUT-1:0] C [0:N-1][0:N-1]
    );
        logic signed [ACC_W-1:0] acc, biased, activated;
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                acc = '0;
                for (int k = 0; k < N; k++)
                    acc += A[i][k] * B[k][j];
                // Mirror output_processing: bias -> ReLU -> shift -> saturate.
                biased    = (USE_BIAS != 0) ? acc : acc;          // bias is tied to 0
                activated = (USE_RELU != 0) ? (biased[ACC_W-1] ? '0 : biased) : biased;
                C[i][j]   = saturate(activated >>> SHIFT);
            end
    endfunction

    // Padded reference. The only difference from golden() is the inner sum's
    // bound: k < k_real instead of k < N. Note it still produces all N x N
    // outputs -- K bounds the CONTRACTION, not the shape of C. Which output rows
    // and columns the host cares about is an M/N question the hardware never
    // sees.
    //
    // Because it never reads A[i][k] or B[k][j] for k >= k_real, whatever poison
    // sits in those positions is invisible to this model -- which is exactly the
    // property test_poison_sensitivity holds the DUT to.
    function automatic void golden_padded(
        input  int                       k_real,
        input  logic signed [IN_W-1:0]   A [0:N-1][0:N-1],
        input  logic signed [IN_W-1:0]   B [0:N-1][0:N-1],
        output logic signed [DW_OUT-1:0] C [0:N-1][0:N-1]
    );
        logic signed [ACC_W-1:0] acc, biased, activated;
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                acc = '0;
                for (int k = 0; k < k_real; k++)      // k_real, not N
                    acc += A[i][k] * B[k][j];
                biased    = (USE_BIAS != 0) ? acc : acc;
                activated = (USE_RELU != 0) ? (biased[ACC_W-1] ? '0 : biased) : biased;
                C[i][j]   = saturate(activated >>> SHIFT);
            end
    endfunction

    // Build the full 4x4 matrices actually written to memory: real data inside
    // the k_real region, poison outside it.
    //
    // Poison goes EXACTLY where the hardware zeros -- A's columns >= k_real and
    // B's rows >= k_real -- and nowhere else. That matters: A's columns are the
    // contraction index, so they are masked, but A's ROWS are output rows and
    // are never masked. Poisoning A's rows would legitimately change the answer
    // and would make test_poison_sensitivity fail for a correct design.
    //
    // Poison is non-zero on purpose. With zeros there, a pad mux that zeroed
    // nothing at all would still produce the right answer by coincidence, and
    // the whole test would be vacuous.
    function automatic void build_padded(
        input  int                     k_real,
        input  logic signed [IN_W-1:0] poison,
        input  logic signed [IN_W-1:0] A_real [0:N-1][0:N-1],
        input  logic signed [IN_W-1:0] B_real [0:N-1][0:N-1],
        output logic signed [IN_W-1:0] A_pad  [0:N-1][0:N-1],
        output logic signed [IN_W-1:0] B_pad  [0:N-1][0:N-1]
    );
        for (int i = 0; i < N; i++)
            for (int k = 0; k < N; k++)
                A_pad[i][k] = (k < k_real) ? A_real[i][k] : poison;   // columns
        for (int k = 0; k < N; k++)
            for (int j = 0; j < N; j++)
                B_pad[k][j] = (k < k_real) ? B_real[k][j] : poison;   // rows
    endfunction

    // ---------------------------------------------------------------------
    // Scoreboard
    // ---------------------------------------------------------------------
    string test_order[$];
    int    pass_cnt[string], fail_cnt[string];
    int    total_pass, total_fail;

    function automatic string begin_test(input string name);
        test_order.push_back(name);
        pass_cnt[name] = 0;  fail_cnt[name] = 0;
        $display("---- %s ----", name);
        return name;
    endfunction

    task automatic score(input string tname, input bit ok);
        if (ok) begin pass_cnt[tname]++; total_pass++; end
        else    begin fail_cnt[tname]++; total_fail++; end
    endtask

    task automatic check(input string tname, input int got, input int exp, input string note);
        score(tname, (got === exp));
        if (got !== exp)
            $display("[FAIL] %s: %s expected=%0d got=%0d at time %0t",
                     tname, note, exp, got, $time);
    endtask

    task automatic check_matrix(
        input string                   tname,
        input logic signed [DW_OUT-1:0] C_got [0:N-1][0:N-1],
        input logic signed [DW_OUT-1:0] C_exp [0:N-1][0:N-1]
    );
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                score(tname, (C_got[i][j] === C_exp[i][j]));
                if (C_got[i][j] !== C_exp[i][j])
                    $display("[FAIL] %s: C[%0d][%0d] expected=%0d got=%0d",
                             tname, i, j, C_exp[i][j], C_got[i][j]);
            end
    endtask

    // ---------------------------------------------------------------------
    // Matrix helpers
    // ---------------------------------------------------------------------
    function automatic void mat_zero(output logic signed [IN_W-1:0] M [0:N-1][0:N-1]);
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) M[i][j] = '0;
    endfunction
    function automatic void mat_identity(output logic signed [IN_W-1:0] M [0:N-1][0:N-1]);
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) M[i][j] = (i == j);
    endfunction
    function automatic void mat_ramp(input int base, input int step,
                                     output logic signed [IN_W-1:0] M [0:N-1][0:N-1]);
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++)
            M[i][j] = IN_W'(base + step*(i*N + j));
    endfunction
    // Range-limited randoms. With SHIFT=0 a full-range 8-bit matrix saturates
    // almost every element, which makes a wrong answer hard to distinguish from
    // a right one; small values keep results inside [-128,127] where every bit
    // of the product is actually being compared.
    function automatic void mat_rand_small(output logic signed [IN_W-1:0] M [0:N-1][0:N-1]);
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++)
            M[i][j] = IN_W'($urandom_range(0, 10)) - 8'sd5;      // -5 .. +5
    endfunction
    function automatic void mat_rand_full(output logic signed [IN_W-1:0] M [0:N-1][0:N-1]);
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++)
            M[i][j] = IN_W'($urandom());
    endfunction

    // =====================================================================
    // EXTERNAL-PORT DRIVER TASKS -- the host's view of the accelerator
    // =====================================================================

    // K_real is forced to N here, so every pre-existing task runs fully
    // populated and exercises exactly what it did before the padding extension.
    // run_matmul's k_real argument overrides it for the padded tasks.
    task automatic do_reset();
        @(negedge clk);
        rst_n          = 1'b0;
        start          = 1'b0;
        K_real         = KW'(N);
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

    // B goes in ROW-MAJOR and NOT pre-reversed. address_gen's down-counter does
    // the bottom-row-first reversal internally; reversing here as well would
    // cancel it out and load B upside down.
    task automatic preload_weights(input logic signed [IN_W-1:0] B [0:N-1][0:N-1]);
        for (int r = 0; r < N; r++) begin
            @(negedge clk);
            weight_wr_en   = 1'b1;
            weight_wr_addr = ADDR_W'(r);
            for (int k = 0; k < N; k++) weight_wr_data[k] = B[r][k];
        end
        @(negedge clk);
        weight_wr_en = 1'b0;
    endtask

    // A goes in row-major and un-skewed. The skew buffer inside does the
    // staggering.
    task automatic preload_acts(input logic signed [IN_W-1:0] A [0:N-1][0:N-1]);
        for (int r = 0; r < N; r++) begin
            @(negedge clk);
            act_wr_en   = 1'b1;
            act_wr_addr = ADDR_W'(r);
            for (int k = 0; k < N; k++) act_wr_data[k] = A[r][k];
        end
        @(negedge clk);
        act_wr_en = 1'b0;
    endtask

    task automatic pulse_start();
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
    endtask

    // Poll for done. No internal timing knowledge -- just "it must arrive", with
    // a guard so a hang is reported as a hang rather than running to the
    // watchdog with no context.
    //
    // `probe` is used only by test_timing_alignment_regression; every other
    // caller leaves it off and this task stays black-box.
    task automatic wait_done(input string tname, input bit probe,
                             input logic signed [IN_W-1:0] A [0:N-1][0:N-1],
                             input logic signed [IN_W-1:0] B [0:N-1][0:N-1]);
        int guard, wcnt, acnt;
        guard = 0;  wcnt = 0;  acnt = 0;

        forever begin
            @(negedge clk);
            #(TCLK/2 - SETTLE);

            if (probe) begin
                // ---- weight path alignment -------------------------------
                // On every cycle wload is high, the weight bus must already be
                // presenting the row for that load step: B[N-1] first, then
                // B[N-2] ... B[0]. If wload led the memory by a cycle this sees
                // the previous row (or the reset value) instead.
                if (dut.wload === 1'b1) begin
                    if (wcnt < N) begin
                        for (int k = 0; k < N; k++)
                            check(tname, int'(signed'(dut.wmem_rd_data[k])),
                                  int'(B[N-1-wcnt][k]),
                                  $sformatf("wload cycle %0d: weight_mem row %0d lane %0d",
                                            wcnt, N-1-wcnt, k));
                    end
                    wcnt++;
                end

                // ---- activation path alignment ---------------------------
                // Same idea: whenever the skew buffer is told its input is
                // valid, act_mem must already be presenting that row.
                if (dut.sk_valid_in[0] === 1'b1) begin
                    if (acnt < N) begin
                        for (int k = 0; k < N; k++)
                            check(tname, int'(signed'(dut.amem_rd_data[k])),
                                  int'(A[acnt][k]),
                                  $sformatf("valid_in cycle %0d: act_mem row %0d lane %0d",
                                            acnt, acnt, k));
                    end
                    acnt++;
                end
            end

            if (done === 1'b1) break;

            guard++;
            if (guard > RUN_GUARD) begin
                check(tname, 0, 1, "done asserted within the guard window");
                break;
            end
        end

        if (probe) begin
            check(tname, wcnt, N, "wload asserted for exactly N cycles");
            check(tname, acnt, N, "skew valid_in asserted for exactly N cycles");
        end
    endtask

    // Read C back, one row per cycle. output_mem's read is registered, so the
    // row driven onto rd_addr in a cycle is sampled just after that cycle's
    // posedge -- back-to-back reads pipeline with no gaps.
    task automatic read_c(output logic signed [DW_OUT-1:0] C [0:N-1][0:N-1]);
        for (int r = 0; r < N; r++) begin
            @(negedge clk);
            out_rd_en   = 1'b1;
            out_rd_addr = ADDR_W'(r);
            @(posedge clk);
            #SETTLE;
            for (int k = 0; k < N; k++) C[r][k] = signed'(out_rd_data[k]);
        end
        @(negedge clk);
        out_rd_en = 1'b0;
    endtask

    // The full black-box sequence: preload, start, wait, read back.
    task automatic run_matmul(
        input  string                    tname,
        input  logic signed [IN_W-1:0]   A [0:N-1][0:N-1],
        input  logic signed [IN_W-1:0]   B [0:N-1][0:N-1],
        output logic signed [DW_OUT-1:0] C [0:N-1][0:N-1],
        input  bit                       reset_first = 1'b1,
        input  bit                       probe       = 1'b0,
        input  int                       k_real      = N
    );
        if (reset_first) do_reset();
        preload_weights(B);
        preload_acts(A);
        // Committed before start, which is the edge address_gen samples it on.
        // Defaults to N, so every pre-existing call site is the unpadded case.
        K_real = KW'(k_real);
        pulse_start();
        wait_done(tname, probe, A, B);
        read_c(C);
    endtask

    // =====================================================================
    // TEST TASKS
    //
    // Each notes what it confirms at SYSTEM level -- something no sub-module
    // testbench could have confirmed on its own.
    // =====================================================================

    // The hand-checked case, end to end. Confirms that nine separately-verified
    // modules, each correct against its own contract, actually agree with each
    // other about timing and ordering. If this fails while every sub-module test
    // passes, the bug is in accelerator_top's wiring -- run
    // test_timing_alignment_regression next.
    task automatic test_known_case();
        string tn = begin_test("test_known_case");
        logic signed [IN_W-1:0]   A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        mat_zero(A);  mat_zero(B);
        A[0][0] = 1; A[0][1] = 2; A[1][0] = 3; A[1][1] = 4;
        B[0][0] = 5; B[0][1] = 6; B[1][0] = 7; B[1][1] = 8;

        golden(A, B, E);
        run_matmul(tn, A, B, C);
        check_matrix(tn, C, E);

        // With SHIFT=0 the top-left block is the literal hand-computed product,
        // so name it outright -- the one place in this file with typed values.
        check(tn, int'(C[0][0]), 19, "C[0][0] of the hand-checked case");
        check(tn, int'(C[0][1]), 22, "C[0][1] of the hand-checked case");
        check(tn, int'(C[1][0]), 43, "C[1][0] of the hand-checked case");
        check(tn, int'(C[1][1]), 50, "C[1][1] of the hand-checked case");
    endtask

    // Confirms no lane or row permutation anywhere across the whole chain --
    // memory ordering, skew, array edges, de-skew, and write-back all have to
    // agree on what "row i, lane j" means for a distinct-valued matrix to
    // survive an identity multiply intact.
    task automatic test_identity_passthrough();
        string tn = begin_test("test_identity_passthrough");
        logic signed [IN_W-1:0]   M [0:N-1][0:N-1], I [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        mat_ramp(1, 1, M);  mat_identity(I);

        golden(I, M, E);  run_matmul(tn, I, M, C);  check_matrix(tn, C, E);   // I x B
        golden(M, I, E);  run_matmul(tn, M, I, C);  check_matrix(tn, C, E);   // A x I
    endtask

    // Confirms done is a trustworthy completion signal for a host: low for the
    // whole run, and still high later. No sub-module could establish this --
    // control_unit knows when it thinks it is finished, but only here can we
    // check that the data really is readable at that moment.
    task automatic test_done_behavior();
        string tn = begin_test("test_done_behavior");
        logic signed [IN_W-1:0]   A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];
        int low_cycles;

        mat_ramp(1, 1, A);  mat_ramp(2, 1, B);
        golden(A, B, E);

        do_reset();
        check(tn, int'(done), 0, "done low after reset");

        preload_weights(B);
        preload_acts(A);
        check(tn, int'(done), 0, "done low after preload, before start");

        pulse_start();

        // Low for every cycle of the run until the very end.
        low_cycles = 0;
        forever begin
            @(negedge clk);
            #(TCLK/2 - SETTLE);
            if (done === 1'b1) break;
            low_cycles++;
            if (low_cycles > RUN_GUARD) begin
                check(tn, 0, 1, "done asserted within the guard window");
                break;
            end
        end
        check(tn, (low_cycles > 0) ? 1 : 0, 1, "done stayed low during the run");

        // Held, not pulsed.
        for (int i = 0; i < 20; i++) begin
            @(negedge clk);
            #(TCLK/2 - SETTLE);
            check(tn, int'(done), 1, "done holds high with no new start");
        end

        // And the data really is there when done says so.
        read_c(C);
        check_matrix(tn, C, E);
    endtask

    // PRIORITY. Confirms an early read cannot corrupt or hang the run. The
    // design does not specify a return value for a read before done, so no
    // specific value is demanded on the first run -- what IS asserted is that
    // the run still completes and the result is still correct afterwards.
    //
    // The second run makes it falsifiable: output_mem now holds run 1's result,
    // and reading mid-run must return exactly that stale data. Stale is fine;
    // corrupt is not.
    task automatic test_readback_before_done();
        string tn = begin_test("test_readback_before_done");
        logic signed [IN_W-1:0]   A1 [0:N-1][0:N-1], B1 [0:N-1][0:N-1];
        logic signed [IN_W-1:0]   A2 [0:N-1][0:N-1], B2 [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C  [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] E1 [0:N-1][0:N-1], E2 [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] early [0:N-1][0:N-1];

        mat_ramp(1, 1, A1);   mat_ramp(2, 1, B1);
        mat_ramp(-2, 1, A2);  mat_ramp(3, -1, B2);
        golden(A1, B1, E1);
        golden(A2, B2, E2);

        // --- run 1: read early, value unconstrained ----------------------
        do_reset();
        preload_weights(B1);
        preload_acts(A1);
        pulse_start();
        repeat (3) @(negedge clk);
        read_c(early);                       // mid-flight, deliberately
        wait_done(tn, 1'b0, A1, B1);
        read_c(C);
        check_matrix(tn, C, E1);             // the run survived the early read

        // --- run 2: the early read must return run 1's result -------------
        preload_weights(B2);
        preload_acts(A2);
        pulse_start();
        repeat (3) @(negedge clk);
        read_c(early);
        check_matrix(tn, early, E1);         // stale, not corrupt

        wait_done(tn, 1'b0, A2, B2);
        read_c(C);
        check_matrix(tn, C, E2);             // and run 2 is still correct
    endtask

    // Confirms every sub-module clears together between runs -- weights
    // reloading, the skew buffers draining, psum residue, the output row
    // counter restarting. Each was tested for residue alone; only here do they
    // all have to be simultaneously clean, with NO reset between runs.
    task automatic test_back_to_back_matmuls();
        string tn = begin_test("test_back_to_back_matmuls");
        logic signed [IN_W-1:0]   A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        do_reset();

        // Run 1, then several more with different operands and no reset.
        mat_ramp(1, 1, A);    mat_ramp(2, 1, B);
        golden(A, B, E);  run_matmul(tn, A, B, C, 1'b0);  check_matrix(tn, C, E);

        mat_ramp(-3, 1, A);   mat_ramp(4, -1, B);
        golden(A, B, E);  run_matmul(tn, A, B, C, 1'b0);  check_matrix(tn, C, E);

        mat_ramp(2, 1, A);    mat_zero(B);              // zero weights: C must be 0
        golden(A, B, E);  run_matmul(tn, A, B, C, 1'b0);  check_matrix(tn, C, E);

        mat_identity(A);      mat_ramp(1, 2, B);        // identity right after zeros
        golden(A, B, E);  run_matmul(tn, A, B, C, 1'b0);  check_matrix(tn, C, E);

        for (int it = 0; it < 4; it++) begin
            mat_rand_small(A);  mat_rand_small(B);
            golden(A, B, E);  run_matmul(tn, A, B, C, 1'b0);  check_matrix(tn, C, E);
        end
    endtask

    // 50 end-to-end runs. Mostly small operands, so results land inside
    // [-128,127] and every bit of the product is genuinely compared; a handful
    // of full-range runs exercise the saturation path too, where a wrong answer
    // and a right one can both clamp to 127 and the check is weaker.
    task automatic test_random_full_system();
        string tn = begin_test("test_random_full_system");
        logic signed [IN_W-1:0]   A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        do_reset();

        for (int it = 0; it < 40; it++) begin
            mat_rand_small(A);  mat_rand_small(B);
            golden(A, B, E);
            run_matmul(tn, A, B, C, 1'b0);
            check_matrix(tn, C, E);
        end

        for (int it = 0; it < 10; it++) begin
            mat_rand_full(A);  mat_rand_full(B);
            golden(A, B, E);
            run_matmul(tn, A, B, C, 1'b0);
            check_matrix(tn, C, E);
        end
    endtask

    // PRIORITY -- the one task permitted to look inside the DUT, because its
    // whole purpose is diagnosing the top level's own wiring.
    //
    // Both risks are the same shape: a signal and the data it describes must
    // become valid on the SAME cycle, and each carries its own one-cycle delay
    // that has to line up.
    //   * wload vs weight_mem.rd_data -- two independent one-cycle delays that
    //     must coincide; an extra register on either side loads B shifted by a
    //     row and produces a full, plausible, wrong C.
    //   * skew_buffer.valid_in vs act_mem.rd_data -- valid_in must be act_rd_en
    //     delayed by one, or the skew buffer staggers a bus that still holds the
    //     previous contents.
    // Checked by content, not by eyeballing edges: on the k-th asserted cycle
    // the bus must carry exactly the row that step needs.
    task automatic test_timing_alignment_regression();
        string tn = begin_test("test_timing_alignment_regression");
        logic signed [IN_W-1:0]   A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        // Distinct values everywhere, so a row picked up one step out cannot
        // coincidentally match the right one.
        mat_ramp(1, 1, A);
        mat_ramp(1, 2, B);
        golden(A, B, E);

        run_matmul(tn, A, B, C, 1'b1, 1'b1);      // probe enabled
        check_matrix(tn, C, E);

        // Again with the known case, so a failure here can be read straight
        // against test_known_case's waveform.
        mat_zero(A);  mat_zero(B);
        A[0][0] = 1; A[0][1] = 2; A[1][0] = 3; A[1][1] = 4;
        B[0][0] = 5; B[0][1] = 6; B[1][0] = 7; B[1][1] = 8;
        golden(A, B, E);
        run_matmul(tn, A, B, C, 1'b1, 1'b1);
        check_matrix(tn, C, E);
    endtask

    // =====================================================================
    // PADDING EXTENSION TESTS
    //
    // What these prove that no lower-level test can: address_gen's padding
    // DECISION and accelerator_top's mux EXECUTION of it have to survive the
    // entire real datapath -- memories, skew, array, output processing,
    // de-skew, output memory -- and still land as the right number in the right
    // place in output_mem. tb_address_gen can only show the masks have the right
    // values; only here does anything check they have the right EFFECT.
    // =====================================================================

    // Run FIRST of the padded tasks: the known case again with K_real = N driven
    // explicitly. If this fails, the padding extension broke the unpadded path
    // and nothing below should be read as a padding bug.
    task automatic test_regression_full_k_real();
        string tn = begin_test("test_regression_full_k_real");
        logic signed [IN_W-1:0]   A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        mat_zero(A);  mat_zero(B);
        A[0][0] = 1; A[0][1] = 2; A[1][0] = 3; A[1][1] = 4;
        B[0][0] = 5; B[0][1] = 6; B[1][0] = 7; B[1][1] = 8;

        golden(A, B, E);
        run_matmul(tn, A, B, C, 1'b1, 1'b0, N);       // K_real = N, explicit
        check_matrix(tn, C, E);

        // golden_padded at k_real=N must agree with golden(), or the padded
        // reference itself is suspect before any padded run uses it.
        golden_padded(N, A, B, E);
        check_matrix(tn, C, E);
    endtask

    // A hand-computable padded case: K_real=2, so only the first two inner terms
    // count, with rows/columns beyond that poisoned. Also asserts the result is
    // NOT what a design that ignored padding would produce -- without that, a
    // completely inert pad mux could still look plausible.
    task automatic test_padded_known_case();
        string tn = begin_test("test_padded_known_case");
        logic signed [IN_W-1:0]   Ar [0:N-1][0:N-1], Br [0:N-1][0:N-1];
        logic signed [IN_W-1:0]   Ap [0:N-1][0:N-1], Bp [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C  [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] E_pad [0:N-1][0:N-1], E_full [0:N-1][0:N-1];
        int differing;

        // Real 2x2 content, zeros elsewhere inside the real region.
        mat_zero(Ar);  mat_zero(Br);
        Ar[0][0] = 1; Ar[0][1] = 2; Ar[1][0] = 3; Ar[1][1] = 4;
        Br[0][0] = 5; Br[0][1] = 6; Br[1][0] = 7; Br[1][1] = 8;

        build_padded(2, 8'sd99, Ar, Br, Ap, Bp);

        golden_padded(2, Ap, Bp, E_pad);
        golden(Ap, Bp, E_full);            // what an unpadded run would give

        run_matmul(tn, Ap, Bp, C, 1'b1, 1'b0, 2);
        check_matrix(tn, C, E_pad);

        // The top-left block is the familiar hand-checked product, unchanged by
        // the poison around it.
        check(tn, int'(C[0][0]), 19, "padded C[0][0]");
        check(tn, int'(C[0][1]), 22, "padded C[0][1]");
        check(tn, int'(C[1][0]), 43, "padded C[1][0]");
        check(tn, int'(C[1][1]), 50, "padded C[1][1]");

        // And it is genuinely different from the unpadded answer, so the check
        // above could not have passed with the pad muxes doing nothing.
        differing = 0;
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++)
                if (E_pad[i][j] !== E_full[i][j]) begin
                    differing++;
                    check(tn, (C[i][j] === E_full[i][j]) ? 1 : 0, 0,
                          $sformatf("C[%0d][%0d] must NOT include the poisoned rows", i, j));
                end
        check(tn, (differing > 0) ? 1 : 0, 1,
              "the poison must actually change the unpadded answer, or this test is vacuous");
    endtask

    // PRIORITY. Every valid K_real, end to end through the external interface
    // with randomized real data and poisoned padding. This is the proof that the
    // masks have the right effect all the way to output_mem, for every shape.
    task automatic test_padded_all_k_real_values();
        string tn = begin_test("test_padded_all_k_real_values");
        logic signed [IN_W-1:0]   Ar [0:N-1][0:N-1], Br [0:N-1][0:N-1];
        logic signed [IN_W-1:0]   Ap [0:N-1][0:N-1], Bp [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C  [0:N-1][0:N-1], E [0:N-1][0:N-1];

        do_reset();

        for (int k_real = 1; k_real <= N; k_real++) begin
            for (int it = 0; it < 6; it++) begin
                mat_rand_small(Ar);  mat_rand_small(Br);
                build_padded(k_real, 8'sd99, Ar, Br, Ap, Bp);
                golden_padded(k_real, Ap, Bp, E);
                run_matmul(tn, Ap, Bp, C, 1'b0, 1'b0, k_real);
                check_matrix(tn, C, E);
            end
        end
    endtask

    // The same real computation reached two ways: through the padded path with
    // poison, and through the ordinary K_real=N path with real zeros in place of
    // the poison. Both must agree, which says the pad mux does exactly what
    // explicit zeros in memory would -- no more, no less.
    task automatic test_padded_vs_unpadded_consistency();
        string tn = begin_test("test_padded_vs_unpadded_consistency");
        logic signed [IN_W-1:0]   Ar [0:N-1][0:N-1], Br [0:N-1][0:N-1];
        logic signed [IN_W-1:0]   Ap [0:N-1][0:N-1], Bp [0:N-1][0:N-1];
        logic signed [IN_W-1:0]   Az [0:N-1][0:N-1], Bz [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C_pad [0:N-1][0:N-1], C_zero [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] E [0:N-1][0:N-1];

        do_reset();

        for (int it = 0; it < 6; it++) begin
            mat_rand_small(Ar);  mat_rand_small(Br);

            build_padded(2, 8'sd99, Ar, Br, Ap, Bp);   // padded, poisoned
            build_padded(2, 8'sd0,  Ar, Br, Az, Bz);   // same data, zeros instead

            golden_padded(2, Ap, Bp, E);

            run_matmul(tn, Ap, Bp, C_pad,  1'b0, 1'b0, 2);   // padding does the zeroing
            run_matmul(tn, Az, Bz, C_zero, 1'b0, 1'b0, N);   // memory does the zeroing

            check_matrix(tn, C_pad,  E);
            check_matrix(tn, C_zero, E);
            for (int i = 0; i < N; i++)
                for (int j = 0; j < N; j++)
                    check(tn, int'(C_pad[i][j]), int'(C_zero[i][j]),
                          $sformatf("padded and zero-filled paths must agree at C[%0d][%0d]", i, j));
        end
    endtask

    // PRIORITY. The strongest available evidence that padding really happens:
    // run identical real data with DIFFERENT poison in the padded region and
    // require bit-identical output. A pad mux that is not actually zeroing lets
    // the poison through into the accumulation, and the two runs diverge.
    //
    // This cannot pass by coincidence the way a single-poison-value test can.
    task automatic test_poison_sensitivity();
        string tn = begin_test("test_poison_sensitivity");
        logic signed [IN_W-1:0]   Ar [0:N-1][0:N-1], Br [0:N-1][0:N-1];
        logic signed [IN_W-1:0]   Ap [0:N-1][0:N-1], Bp [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C1 [0:N-1][0:N-1], C2 [0:N-1][0:N-1];
        logic signed [DW_OUT-1:0] C3 [0:N-1][0:N-1], E [0:N-1][0:N-1];

        do_reset();

        for (int k_real = 1; k_real < N; k_real++) begin
            mat_rand_small(Ar);  mat_rand_small(Br);
            golden_padded(k_real, Ar, Br, E);      // real region only, poison-free

            build_padded(k_real,  8'sd99, Ar, Br, Ap, Bp);
            run_matmul(tn, Ap, Bp, C1, 1'b0, 1'b0, k_real);

            build_padded(k_real, -8'sd50, Ar, Br, Ap, Bp);
            run_matmul(tn, Ap, Bp, C2, 1'b0, 1'b0, k_real);

            // The two-complement extreme, the poison most likely to survive a
            // half-working mux.
            build_padded(k_real, -8'sd128, Ar, Br, Ap, Bp);
            run_matmul(tn, Ap, Bp, C3, 1'b0, 1'b0, k_real);

            check_matrix(tn, C1, E);
            check_matrix(tn, C2, E);
            check_matrix(tn, C3, E);

            for (int i = 0; i < N; i++)
                for (int j = 0; j < N; j++) begin
                    check(tn, int'(C1[i][j]), int'(C2[i][j]),
                          $sformatf("K_real=%0d poison 99 vs -50 at C[%0d][%0d]", k_real, i, j));
                    check(tn, int'(C1[i][j]), int'(C3[i][j]),
                          $sformatf("K_real=%0d poison 99 vs -128 at C[%0d][%0d]", k_real, i, j));
                end
        end
    endtask

    // ---------------------------------------------------------------------
    // Report
    // ---------------------------------------------------------------------
    task automatic report();
        string failing[$];
        string t;

        $display("\n=================================================================");
        $display(" TOP-LEVEL TESTBENCH SUMMARY  (black box, SHIFT=%0d)", SHIFT);
        $display("=================================================================");
        $display(" %-34s %8s %8s   %s", "TASK", "PASS", "FAIL", "STATUS");
        $display("-----------------------------------------------------------------");
        foreach (test_order[i]) begin
            t = test_order[i];
            $display(" %-34s %8d %8d   %s", t, pass_cnt[t], fail_cnt[t],
                     (fail_cnt[t] == 0) ? "PASS" : "FAIL");
            if (fail_cnt[t] != 0) failing.push_back(t);
        end
        $display("-----------------------------------------------------------------");
        $display(" %-34s %8d %8d", "TOTAL", total_pass, total_fail);
        $display("=================================================================\n");

        if (total_fail == 0) $display("=== TOP-LEVEL PASSED ===");
        else begin
            $display("=== TOP-LEVEL FAILED ===");
            $display("Failing tasks:");
            foreach (failing[i]) $display("  - %s", failing[i]);
        end
    endtask

    // ---------------------------------------------------------------------
    // Main sequence
    // ---------------------------------------------------------------------
    initial begin
        int seed;

        total_pass = 0;  total_fail = 0;
        seed = SEED;
        void'($urandom(seed));

        rst_n          = 1'b1;
        start          = 1'b0;
        K_real         = KW'(N);        // fully populated, as every original task assumes
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

        // Original tasks, unchanged and in their original order. All run at
        // K_real = N and are the regression net for the padding extension.
        test_known_case();
        test_identity_passthrough();
        test_done_behavior();
        test_readback_before_done();
        test_back_to_back_matmuls();
        test_random_full_system();
        test_timing_alignment_regression();

        // Padding extension. The full-K regression runs first so a broken base
        // case is named as such before any padded result is interpreted.
        test_regression_full_k_real();
        test_padded_known_case();
        test_padded_all_k_real_values();
        test_padded_vs_unpadded_consistency();
        test_poison_sensitivity();

        report();
        $finish;
    end

endmodule
