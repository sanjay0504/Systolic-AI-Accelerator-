// -----------------------------------------------------------------------------
// tb_array.sv
//
// Self-checking testbench for systolic_array.sv (N x N weight-stationary array).
//
// The PE is verified separately by tb_pe.sv, so this testbench does NOT re-verify
// arithmetic. It targets the array-level bug classes: edge wiring, weight-load
// ordering, activation skew, sign extension on the shared top edge, result
// arrival timing, and state leaking between successive multiplies.
//
// Structure
// ---------
//   array_harness  - parameterised wrapper: one DUT, the golden model, the
//                    run_matmul driver, all test tasks and a local scoreboard.
//   tb_array       - top level: clock, waveforms, watchdog, two harnesses
//                    (N=4 and N=2) and the merged summary report.
//
// Timing convention (identical to tb_pe.sv)
// -----------------------------------------
//   * Stimulus is driven on the NEGEDGE.
//   * Outputs are sampled on the POSEDGE after a small SETTLE delay, so the NBA
//     region has committed. Driving and sampling can never race.
//
// Compute-relative cycle numbering
// --------------------------------
//   Cycle 0 is the cycle in which the first activation is PRESENTED on a_in[0].
//   A value registered by the posedge that ends drive cycle k is labelled
//   cycle k+1 -- i.e. the label is the cycle in which the result is visible on
//   the output. Under that numbering the DUT contract is:
//
//       C[n][j] appears on psum_out[j], with valid_out[j] high, at cycle N+n+j.
//
// Sources of truth
// ----------------
//   golden()      - a plain nested-loop matrix multiply.
//   run_matmul()  - the one and only DUT driver.
//   Every test compares one against the other. The only hand-typed expected
//   values in the whole file are the [19 22; 43 50] pair used to sanity-check
//   golden() itself.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

// =============================================================================
// array_harness -- one DUT plus everything needed to exercise it.
// =============================================================================
module array_harness #(
    parameter int    N     = 4,        // array dimension
    parameter int    IN_W  = 8,        // activation / weight width
    parameter int    ACC_W = 32,       // partial-sum width
    parameter string TAG   = ""        // prefix for this harness's test names
) (
    input logic clk
);

    localparam time SETTLE = 1ns;      // post-edge settle before sampling
    localparam int  DRAIN  = 3;        // extra bubble cycles after the last result

    // ---------------------------------------------------------------------
    // DUT interface
    // ---------------------------------------------------------------------
    logic                    rst_n;
    logic                    wload;
    logic signed [IN_W-1:0]  a_in       [0:N-1];
    logic                    valid_in   [0:N-1];
    logic signed [IN_W-1:0]  weight_top [0:N-1];
    logic signed [ACC_W-1:0] psum_out   [0:N-1];
    logic                    valid_out  [0:N-1];

    systolic_array #(
        .N     (N),
        .IN_W  (IN_W),
        .ACC_W (ACC_W)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .wload      (wload),
        .a_in       (a_in),
        .valid_in   (valid_in),
        .weight_top (weight_top),
        .psum_out   (psum_out),
        .valid_out  (valid_out)
    );

    // ---------------------------------------------------------------------
    // Observation state, filled in by run_matmul() and inspected by
    // test_timing(). Cleared at the start of every run.
    // ---------------------------------------------------------------------
    int obs_cycle   [0:N-1][0:N-1];    // compute-relative cycle C[n][j] arrived
    int obs_count   [0:N-1];           // results collected on column j
    int extra_valid [0:N-1];           // valid pulses beyond the expected N

    // ---------------------------------------------------------------------
    // Scoreboard (per task; merged into the global totals by tb_array)
    // ---------------------------------------------------------------------
    string test_order[$];
    int    pass_cnt[string];
    int    fail_cnt[string];
    int    total_pass;
    int    total_fail;

    initial begin
        total_pass = 0;
        total_fail = 0;
    end

    // ---------------------------------------------------------------------
    // GOLDEN MODEL -- the only source of expected values.
    // ---------------------------------------------------------------------
    function automatic void golden(
        input  logic signed [IN_W-1:0]  A [0:N-1][0:N-1],
        input  logic signed [IN_W-1:0]  B [0:N-1][0:N-1],
        output logic signed [ACC_W-1:0] C [0:N-1][0:N-1]
    );
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                C[i][j] = '0;
                // Assignment context is ACC_W and both operands are signed, so
                // the product is sign-extended before it is accumulated.
                for (int k = 0; k < N; k++)
                    C[i][j] += A[i][k] * B[k][j];
            end
    endfunction

    // ---------------------------------------------------------------------
    // Book-keeping
    // ---------------------------------------------------------------------
    function automatic string begin_test(input string base);
        string name = {TAG, base};
        test_order.push_back(name);
        pass_cnt[name] = 0;
        fail_cnt[name] = 0;
        $display("---- %s ----", name);
        return name;
    endfunction

    // Scalar check, used for timing and bookkeeping assertions.
    task automatic check(
        input string tname,
        input int    got,
        input int    exp,
        input string note
    );
        if (got === exp) begin
            pass_cnt[tname]++;
            total_pass++;
        end else begin
            fail_cnt[tname]++;
            total_fail++;
            $display("[FAIL] %s: %s expected=%0d got=%0d at time %0t",
                     tname, note, exp, got, $time);
        end
    endtask

    // Element-by-element matrix comparison. `===` so an uncollected element
    // (left as X by run_matmul) fails instead of silently comparing equal.
    task automatic check_matrix(
        input string                   tname,
        input logic signed [ACC_W-1:0] C_got [0:N-1][0:N-1],
        input logic signed [ACC_W-1:0] C_exp [0:N-1][0:N-1]
    );
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                if (C_got[i][j] === C_exp[i][j]) begin
                    pass_cnt[tname]++;
                    total_pass++;
                end else begin
                    fail_cnt[tname]++;
                    total_fail++;
                    $display("[FAIL] %s: C[%0d][%0d] expected=%0d got=%0d",
                             tname, i, j, C_exp[i][j], C_got[i][j]);
                end
            end
    endtask

    // ---------------------------------------------------------------------
    // Matrix helpers
    // ---------------------------------------------------------------------
    function automatic void mat_zero(output logic signed [IN_W-1:0] M [0:N-1][0:N-1]);
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) M[i][j] = '0;
    endfunction

    function automatic void mat_identity(output logic signed [IN_W-1:0] M [0:N-1][0:N-1]);
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) M[i][j] = (i == j) ? 8'sd1 : 8'sd0;
    endfunction

    function automatic void mat_const(
        input  logic signed [IN_W-1:0] v,
        output logic signed [IN_W-1:0] M [0:N-1][0:N-1]
    );
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) M[i][j] = v;
    endfunction

    // Every element distinct, so a row/column permutation cannot hide.
    function automatic void mat_ramp(
        input  int                     base,
        input  int                     step,
        output logic signed [IN_W-1:0] M [0:N-1][0:N-1]
    );
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) M[i][j] = IN_W'(base + step*(i*N + j));
    endfunction

    function automatic void mat_rand(output logic signed [IN_W-1:0] M [0:N-1][0:N-1]);
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) M[i][j] = IN_W'($urandom());  // full signed range
    endfunction

    // ---------------------------------------------------------------------
    // Synchronous active-low reset. Called at the start of every test task so
    // no state leaks between tests.
    // ---------------------------------------------------------------------
    task automatic do_reset();
        @(negedge clk);
        rst_n = 1'b0;
        wload = 1'b0;
        for (int k = 0; k < N; k++) begin
            a_in[k]       = '0;
            valid_in[k]   = 1'b0;
            weight_top[k] = '0;
        end
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);                 // one clean idle cycle before stimulus
    endtask

    // ---------------------------------------------------------------------
    // THE CENTRAL DRIVER -- one complete multiply on the DUT.
    //
    //   Load    : wload=1 for N cycles, column j fed B[N-1][j] first. The first
    //             weight presented travels furthest and lands in the bottom row,
    //             so bottom-row-first puts B[i][j] in PE(i,j).
    //   Compute : array row k is fed COLUMN k of A, delayed by k cycles, so
    //             PE(k,j) sees A[n][k] and B[k][j] on the same cycle and the
    //             column accumulates C[n][j] = sum_k A[n][k]*B[k][j].
    //   Collect : sample psum_out[j] on every cycle valid_out[j] is high; the
    //             m-th pulse on column j is C[m][j].
    //
    // reset_first=0 runs straight on from the previous multiply, which is what
    // test_back_to_back() needs.
    // ---------------------------------------------------------------------
    task automatic run_matmul(
        input  logic signed [IN_W-1:0]  A [0:N-1][0:N-1],
        input  logic signed [IN_W-1:0]  B [0:N-1][0:N-1],
        output logic signed [ACC_W-1:0] C [0:N-1][0:N-1],
        input  bit                      reset_first = 1'b1
    );
        int cyc;

        if (reset_first) do_reset();

        // Anything not collected stays X and is reported by check_matrix.
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                C[i][j]         = 'x;
                obs_cycle[i][j] = -1;
            end
        for (int j = 0; j < N; j++) begin
            obs_count[j]   = 0;
            extra_valid[j] = 0;
        end

        // ---- LOAD PHASE : N cycles, bottom row of B first -----------------
        for (int t = 0; t < N; t++) begin
            @(negedge clk);
            wload = 1'b1;
            for (int j = 0; j < N; j++) begin
                weight_top[j] = B[N-1-t][j];
                a_in[j]       = '0;
                valid_in[j]   = 1'b0;   // no MACs while the bus carries weights
            end
        end

        // ---- COMPUTE PHASE : skewed activations + concurrent collection ----
        // Last activation is presented at cycle 2N-2; the last result,
        // C[N-1][N-1], is due at cycle 3N-2. Drive DRAIN extra bubbles past
        // that so a stray late valid pulse is caught.
        for (int t = 0; t <= 3*N - 3 + DRAIN; t++) begin
            @(negedge clk);
            wload = 1'b0;
            for (int j = 0; j < N; j++) weight_top[j] = '0;

            for (int k = 0; k < N; k++) begin
                if ((t - k) >= 0 && (t - k) < N) begin
                    a_in[k]     = A[t-k][k];   // row k carries column k of A
                    valid_in[k] = 1'b1;
                end else begin
                    a_in[k]     = '0;          // bubble
                    valid_in[k] = 1'b0;
                end
            end

            @(posedge clk);
            #SETTLE;
            cyc = t + 1;                       // label of what is now on the outputs

            for (int j = 0; j < N; j++) begin
                if (valid_out[j] === 1'b1) begin
                    if (obs_count[j] < N) begin
                        C[obs_count[j]][j]         = psum_out[j];
                        obs_cycle[obs_count[j]][j] = cyc;
                        obs_count[j]++;
                    end else begin
                        extra_valid[j]++;          // more results than rows
                    end
                end
            end
        end

        // Leave the array idle and quiet for whatever comes next.
        @(negedge clk);
        for (int k = 0; k < N; k++) begin
            a_in[k]     = '0;
            valid_in[k] = 1'b0;
        end
    endtask

    // =====================================================================
    // TEST TASKS
    // =====================================================================

    // ---------------------------------------------------------------------
    // test_golden_sanity
    //   Catches: a broken reference model. Nothing touches the DUT here.
    //   [1 2; 3 4] x [5 6; 7 8] = [19 22; 43 50], zero-padded to N x N -- the
    //   only hand-typed expected values in this file.
    // ---------------------------------------------------------------------
    task automatic test_golden_sanity();
        string tn = begin_test("test_golden_sanity");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1];
        logic signed [IN_W-1:0]  B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] E [0:N-1][0:N-1];

        mat_zero(A);
        mat_zero(B);
        A[0][0] = 8'sd1; A[0][1] = 8'sd2; A[1][0] = 8'sd3; A[1][1] = 8'sd4;
        B[0][0] = 8'sd5; B[0][1] = 8'sd6; B[1][0] = 8'sd7; B[1][1] = 8'sd8;

        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) E[i][j] = '0;
        E[0][0] = 32'sd19; E[0][1] = 32'sd22;
        E[1][0] = 32'sd43; E[1][1] = 32'sd50;

        golden(A, B, C);
        check_matrix(tn, C, E);
    endtask

    // ---------------------------------------------------------------------
    // test_identity_identity
    //   Catches: an [i][j] index swap anywhere in the edge mapping. I x I must
    //   come back as I -- a transposed or shifted identity means the weight
    //   load order or the row/column mapping is wrong.
    // ---------------------------------------------------------------------
    task automatic test_identity_identity();
        string tn = begin_test("test_identity_identity");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1];
        logic signed [IN_W-1:0]  B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] E [0:N-1][0:N-1];

        mat_identity(A);
        mat_identity(B);
        golden(A, B, E);
        run_matmul(A, B, C);
        check_matrix(tn, C, E);
    endtask

    // ---------------------------------------------------------------------
    // test_passthrough
    //   Catches: row/column permutation in the edge mapping. Every element of
    //   the ramp matrix is distinct, so I x B = B and A x I = A only hold if
    //   both edges preserve position exactly.
    // ---------------------------------------------------------------------
    task automatic test_passthrough();
        string tn = begin_test("test_passthrough");
        logic signed [IN_W-1:0]  M [0:N-1][0:N-1];
        logic signed [IN_W-1:0]  I [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] E [0:N-1][0:N-1];

        mat_ramp(1, 1, M);
        mat_identity(I);

        // I x M  -- exercises the weight edge with distinct values.
        golden(I, M, E);
        run_matmul(I, M, C);
        check_matrix(tn, C, E);

        // M x I  -- exercises the activation edge with distinct values.
        golden(M, I, E);
        run_matmul(M, I, C);
        check_matrix(tn, C, E);
    endtask

    // ---------------------------------------------------------------------
    // test_ones
    //   Catches: a single misbehaving PE or column. Every element of the
    //   result must be exactly N, so any wrong element names its own column
    //   and row immediately.
    // ---------------------------------------------------------------------
    task automatic test_ones();
        string tn = begin_test("test_ones");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1];
        logic signed [IN_W-1:0]  B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] E [0:N-1][0:N-1];

        mat_const(8'sd1, A);
        mat_const(8'sd1, B);
        golden(A, B, E);
        run_matmul(A, B, C);
        check_matrix(tn, C, E);

        // Cross-check the reference itself: every element must equal N.
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++)
                check(tn, E[i][j], N, $sformatf("golden ones E[%0d][%0d] must be N", i, j));
    endtask

    // ---------------------------------------------------------------------
    // test_known
    //   Catches: gross dataflow errors, against a result verifiable by hand.
    //   The 2x2 case is embedded in the top-left corner; the zero padding also
    //   confirms that unused rows/columns contribute nothing.
    // ---------------------------------------------------------------------
    task automatic test_known();
        string tn = begin_test("test_known");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1];
        logic signed [IN_W-1:0]  B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] E [0:N-1][0:N-1];

        mat_zero(A);
        mat_zero(B);
        A[0][0] = 8'sd1; A[0][1] = 8'sd2; A[1][0] = 8'sd3; A[1][1] = 8'sd4;
        B[0][0] = 8'sd5; B[0][1] = 8'sd6; B[1][0] = 8'sd7; B[1][1] = 8'sd8;

        golden(A, B, E);          // golden() was sanity-checked against the
        run_matmul(A, B, C);      // hand-computed values in test_golden_sanity
        check_matrix(tn, C, E);
    endtask

    // ---------------------------------------------------------------------
    // test_negative  -- PRIORITY
    //   Catches: zero-extension instead of sign-extension on the top edge
    //   weight-load path. A zero-extended negative weight is still correct in
    //   row 0 (it captures only the low IN_W bits) but corrupt in every row
    //   below, because those rows receive what the PE above re-drove. So the
    //   signature of that bug is: positive tests pass, this one fails, and the
    //   damage grows toward the lower rows of the weight matrix.
    //   All four sign combinations are covered.
    // ---------------------------------------------------------------------
    task automatic test_negative();
        string tn = begin_test("test_negative");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1];
        logic signed [IN_W-1:0]  B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] E [0:N-1][0:N-1];

        // --- (+A, -B): all weights negative, in every row -------------------
        mat_ramp(1, 1, A);
        mat_ramp(-1, -1, B);
        golden(A, B, E);
        run_matmul(A, B, C);
        check_matrix(tn, C, E);

        // --- (-A, +B): all activations negative ------------------------------
        mat_ramp(-1, -1, A);
        mat_ramp(1, 1, B);
        golden(A, B, E);
        run_matmul(A, B, C);
        check_matrix(tn, C, E);

        // --- (-A, -B): both negative, result must come back positive ---------
        mat_ramp(-1, -1, A);
        mat_ramp(-2, -1, B);
        golden(A, B, E);
        run_matmul(A, B, C);
        check_matrix(tn, C, E);

        // --- mixed signs within each matrix, plus the extreme values ---------
        // -128 has the sign bit set and every magnitude bit clear: a classic
        // separator between sign- and zero-extension.
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                A[i][j] = ((i + j) % 2 == 0) ?  IN_W'(i + j + 1) : -IN_W'(i + j + 1);
                B[i][j] = ((i + j) % 2 == 0) ? -IN_W'(2*i + j + 1) : IN_W'(2*i + j + 1);
            end
        A[0][0]     =  8'sd127; A[N-1][N-1] = -8'sd128;
        B[0][0]     = -8'sd128; B[N-1][N-1] =  8'sd127;
        golden(A, B, E);
        run_matmul(A, B, C);
        check_matrix(tn, C, E);

        // --- every weight = -128, i.e. worst case for the whole column -------
        mat_const(-8'sd128, B);
        mat_ramp(1, 1, A);
        golden(A, B, E);
        run_matmul(A, B, C);
        check_matrix(tn, C, E);
    endtask

    // ---------------------------------------------------------------------
    // test_timing  -- PRIORITY
    //   Catches: right answers at the wrong time, broken input skew, a valid
    //   tag that does not travel with its result, and duplicate or extra valid
    //   pulses. Values are checked too, but the point here is WHEN.
    //   Contract: C[n][j] arrives at compute-relative cycle N + n + j.
    // ---------------------------------------------------------------------
    task automatic test_timing();
        string tn = begin_test("test_timing");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1];
        logic signed [IN_W-1:0]  B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] E [0:N-1][0:N-1];

        mat_rand(A);
        mat_rand(B);
        golden(A, B, E);
        run_matmul(A, B, C);
        check_matrix(tn, C, E);

        for (int j = 0; j < N; j++) begin
            // Exactly N results per column, no more, no fewer.
            check(tn, obs_count[j], N,
                  $sformatf("column %0d result count", j));
            check(tn, extra_valid[j], 0,
                  $sformatf("column %0d stray valid_out pulses", j));

            // ...and each one on its contracted cycle.
            for (int n = 0; n < N; n++)
                check(tn, obs_cycle[n][j], N + n + j,
                      $sformatf("arrival cycle of C[%0d][%0d]", n, j));
        end
    endtask

    // ---------------------------------------------------------------------
    // test_random
    //   Catches: anything the directed tests missed. Full-range signed 8-bit
    //   values against golden(), 100 times.
    // ---------------------------------------------------------------------
    task automatic test_random(input int n_iter = 100);
        string tn = begin_test("test_random");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1];
        logic signed [IN_W-1:0]  B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] E [0:N-1][0:N-1];

        for (int it = 0; it < n_iter; it++) begin
            mat_rand(A);
            mat_rand(B);
            golden(A, B, E);
            run_matmul(A, B, C);
            check_matrix(tn, C, E);
        end
    endtask

    // ---------------------------------------------------------------------
    // test_back_to_back
    //   Catches: weights that do not fully reload (stale rows from the previous
    //   pass), and partial-sum residue leaking from one multiply into the next.
    //   Only the FIRST multiply gets a reset; the rest run straight on.
    //   The zero-weight pass in the middle is the sharpest probe: any residue
    //   at all makes the all-zero expectation fail.
    // ---------------------------------------------------------------------
    task automatic test_back_to_back();
        string tn = begin_test("test_back_to_back");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1];
        logic signed [IN_W-1:0]  B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] E [0:N-1][0:N-1];

        do_reset();

        // --- pass 1: large positive weights ---------------------------------
        mat_ramp(1, 1, A);
        mat_ramp(10, 3, B);
        golden(A, B, E);
        run_matmul(A, B, C, 1'b0);
        check_matrix(tn, C, E);

        // --- pass 2: completely different, negative weights, no reset -------
        mat_ramp(2, -1, A);
        mat_ramp(-5, -2, B);
        golden(A, B, E);
        run_matmul(A, B, C, 1'b0);
        check_matrix(tn, C, E);

        // --- pass 3: zero weights -- result must be exactly zero ------------
        mat_ramp(7, 1, A);
        mat_zero(B);
        golden(A, B, E);
        run_matmul(A, B, C, 1'b0);
        check_matrix(tn, C, E);

        // --- pass 4: identity weights right after the zero pass -------------
        mat_ramp(3, 2, A);
        mat_identity(B);
        golden(A, B, E);
        run_matmul(A, B, C, 1'b0);
        check_matrix(tn, C, E);

        // --- passes 5..12: random, still no reset between them ---------------
        for (int it = 0; it < 8; it++) begin
            mat_rand(A);
            mat_rand(B);
            golden(A, B, E);
            run_matmul(A, B, C, 1'b0);
            check_matrix(tn, C, E);
        end
    endtask

    // ---------------------------------------------------------------------
    // Entry points
    // ---------------------------------------------------------------------

    // Full suite -- run on the N=4 instance.
    task automatic run_all();
        test_golden_sanity();
        test_identity_identity();
        test_passthrough();
        test_ones();
        test_known();
        test_negative();
        test_timing();
        test_random(100);
        test_back_to_back();
    endtask

    // ---------------------------------------------------------------------
    // test_scaling subset -- run on the N=2 instance.
    //   Catches: an array that is secretly hardcoded for N=4. Every task below
    //   is parameter-driven, so passing here means the generate loops, the
    //   load ordering, the skew and the N+n+j timing all track N.
    // ---------------------------------------------------------------------
    task automatic run_subset();
        test_golden_sanity();
        test_identity_identity();
        test_passthrough();
        test_ones();
        test_known();
        test_negative();
        test_timing();
        test_random(20);
        test_back_to_back();
    endtask

endmodule


// =============================================================================
// tb_array -- top level
// =============================================================================
module tb_array;

    localparam int  N4     = 4;
    localparam int  N2     = 2;
    localparam int  IN_W   = 8;
    localparam int  ACC_W  = 32;
    localparam time TCLK   = 10ns;              // 10 ns period
    localparam int  SEED   = 32'h5EED_A11A;     // fixed -> reproducible runs

    logic clk;

    // Global totals, merged from every harness.
    int    total_pass;
    int    total_fail;

    // ---------------------------------------------------------------------
    // DUT harnesses. N lives in exactly one place per instance.
    // ---------------------------------------------------------------------
    array_harness #(.N(N4), .IN_W(IN_W), .ACC_W(ACC_W), .TAG(""))
        h4 (.clk(clk));

    array_harness #(.N(N2), .IN_W(IN_W), .ACC_W(ACC_W), .TAG("scaling_N2/"))
        h2 (.clk(clk));

    // ---------------------------------------------------------------------
    // Clock
    // ---------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #(TCLK/2) clk = ~clk;
    end

    // ---------------------------------------------------------------------
    // Waveforms
    // ---------------------------------------------------------------------
    initial begin
        $dumpfile("tb_array.vcd");
        $dumpvars(0, tb_array);
    end

    // ---------------------------------------------------------------------
    // Watchdog
    // ---------------------------------------------------------------------
    initial begin
        #1000000;
        $error("TIMEOUT");
        $finish;
    end

    // ---------------------------------------------------------------------
    // Report
    // ---------------------------------------------------------------------
    `define ROLL_UP(H)                                                        \
        foreach (H.test_order[i]) begin                                       \
            t = H.test_order[i];                                              \
            $display(" %-28s %8d %8d   %s",                                   \
                     t, H.pass_cnt[t], H.fail_cnt[t],                         \
                     (H.fail_cnt[t] == 0) ? "PASS" : "FAIL");                 \
            if (H.fail_cnt[t] != 0) failing.push_back(t);                     \
        end                                                                   \
        total_pass += H.total_pass;                                           \
        total_fail += H.total_fail;

    task automatic report();
        string failing[$];
        string t;

        total_pass = 0;
        total_fail = 0;

        $display("");
        $display("=====================================================================");
        $display(" ARRAY TESTBENCH SUMMARY");
        $display("=====================================================================");
        $display(" %-28s %8s %8s   %s", "TASK", "PASS", "FAIL", "STATUS");
        $display("---------------------------------------------------------------------");

        `ROLL_UP(h4)
        `ROLL_UP(h2)

        $display("---------------------------------------------------------------------");
        $display(" %-28s %8d %8d", "TOTAL", total_pass, total_fail);
        $display("=====================================================================");
        $display("");

        if (total_fail == 0) begin
            $display("=== ARRAY TESTBENCH PASSED ===");
        end else begin
            $display("=== ARRAY TESTBENCH FAILED ===");
            $display("Failing tasks:");
            foreach (failing[i]) $display("  - %s", failing[i]);
        end
    endtask

    // ---------------------------------------------------------------------
    // Main sequence
    // ---------------------------------------------------------------------
    initial begin
        int seed;

        seed = SEED;
        void'($urandom(seed));          // fixed seed for reproducibility

        $display("");
        $display("### N = %0d ###", N4);
        h4.run_all();

        $display("");
        $display("### test_scaling: N = %0d ###", N2);
        h2.run_subset();

        report();
        $finish;
    end

endmodule
