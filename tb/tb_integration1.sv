// -----------------------------------------------------------------------------
// tb_integration1.sv
//
// Integration stage 1: skew_buffer (REVERSE=0) + systolic_array, wired together.
// Both modules are individually verified; this testbench targets the BOUNDARY
// between them.
//
// Out of scope here: memories, de-skew, output processing, address generator,
// control unit. The TB drives weights and un-skewed activations itself and reads
// the array's raw 32-bit diagonal output.
//
//   TB --> u_skew.data_in/valid_in       (one column of A per lane, UN-staggered)
//   u_skew.data_out/valid_out --> u_array.a_in/valid_in     (left edge)
//   TB --> u_array.weight_top, u_array.wload                (weights bypass the skew)
//   u_array.psum_out/valid_out --> TB                       (bottom edge, raw)
//
// -----------------------------------------------------------------------------
// WHY THE TWO MODULES LINE UP WITH NO GLUE
// -----------------------------------------------------------------------------
// The array wants row k of its left edge to receive column k of A delayed by k
// cycles. The skew buffer delays lane k by exactly k, and its lane 0 is a
// combinational pass-through -- zero delay, not one. So presenting all N lanes
// together at TB cycle t puts A[t][0] on a_in[0] during that same cycle t, and
// A[t-k][k] on a_in[k], which is precisely the array's expected triangle with NO
// added latency.
//
// That is the whole integration risk in one sentence: if the skew buffer had
// registered its delay-0 lane, every lane would arrive one cycle late, the array
// would still produce a full set of plausible-looking results, and only the
// values would be wrong. test_alignment_offset exists to catch exactly that, by
// checking the wire between the two modules every single cycle rather than
// inferring it from the final matrix.
//
// Compute-relative cycle 0 = the cycle the first un-skewed column is presented.
// Because the boundary adds no latency, the array's own contract carries over
// unchanged: C[n][j] appears on psum_out[j] at cycle N + n + j.
//
// Timing convention: drive on the negedge; check the skew-to-array boundary in
// the setup window 1 ns BEFORE the posedge (a_in[0] is combinational, so it is
// only distinguishable from a registered lane there); sample the array's
// registered outputs just after the posedge.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

// =============================================================================
// integ1_harness -- one wired-up pair plus everything needed to drive it.
// =============================================================================
module integ1_harness #(
    parameter int    N     = 4,
    parameter int    IN_W  = 8,
    parameter int    ACC_W = 32,
    parameter string TAG   = ""
) (
    input logic clk
);

    localparam time TCLK   = 10ns;
    localparam time SETTLE = 1ns;
    localparam int  DRAIN  = 3;        // idle cycles past the last expected result

    // ---------------------------------------------------------------------
    // DUTs and the wire between them
    // ---------------------------------------------------------------------
    logic                    rst_n;
    logic                    wload;

    logic [IN_W-1:0]         sk_din  [0:N-1];   // TB -> skew buffer (un-staggered)
    logic                    sk_vin  [0:N-1];
    logic [IN_W-1:0]         sk_dout [0:N-1];   // skew buffer -> array
    logic                    sk_vout [0:N-1];

    // skew_buffer's data ports are unsigned logic and systolic_array's are
    // signed. Same bits, different declared type, so an explicit reinterpreting
    // hop keeps the unpacked-array port types equivalent on both sides.
    logic signed [IN_W-1:0]  arr_a   [0:N-1];

    logic signed [IN_W-1:0]  weight_top [0:N-1];
    logic signed [ACC_W-1:0] psum_out   [0:N-1];
    logic                    valid_out  [0:N-1];

    generate
        for (genvar k = 0; k < N; k++) begin : g_sign
            assign arr_a[k] = signed'(sk_dout[k]);
        end
    endgenerate

    skew_buffer #(.N(N), .DW(IN_W), .REVERSE(0)) u_skew (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (sk_din),
        .valid_in  (sk_vin),
        .data_out  (sk_dout),
        .valid_out (sk_vout)
    );

    systolic_array #(.N(N), .IN_W(IN_W), .ACC_W(ACC_W)) u_array (
        .clk        (clk),
        .rst_n      (rst_n),
        .wload      (wload),
        .a_in       (arr_a),
        .valid_in   (sk_vout),
        .weight_top (weight_top),
        .psum_out   (psum_out),
        .valid_out  (valid_out)
    );

    // ---------------------------------------------------------------------
    // Observation state, filled by run_matmul
    // ---------------------------------------------------------------------
    int obs_cycle   [0:N-1][0:N-1];    // cycle C[n][j] arrived
    int obs_count   [0:N-1];           // results collected on column j
    int extra_valid [0:N-1];           // valid pulses beyond the expected N

    // ---------------------------------------------------------------------
    // Scoreboard
    // ---------------------------------------------------------------------
    string test_order[$];
    int    pass_cnt[string], fail_cnt[string];
    int    total_pass, total_fail;

    initial begin total_pass = 0; total_fail = 0; end

    function automatic string begin_test(input string base);
        string name = {TAG, base};
        test_order.push_back(name);
        pass_cnt[name] = 0;  fail_cnt[name] = 0;
        $display("---- %s ----", name);
        return name;
    endfunction

    task automatic score(input string tname, input bit ok);
        if (ok) begin pass_cnt[tname]++; total_pass++; end
        else    begin fail_cnt[tname]++; total_fail++; end
    endtask

    task automatic check(input string tname, input int got, input int exp,
                         input string note);
        score(tname, (got === exp));
        if (got !== exp)
            $display("[FAIL] %s: %s expected=%0d got=%0d at time %0t",
                     tname, note, exp, got, $time);
    endtask

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
                for (int k = 0; k < N; k++)
                    C[i][j] += A[i][k] * B[k][j];   // ACC_W context, both signed
            end
    endfunction

    task automatic check_matrix(
        input string                   tname,
        input logic signed [ACC_W-1:0] C_got [0:N-1][0:N-1],
        input logic signed [ACC_W-1:0] C_exp [0:N-1][0:N-1]
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
    function automatic void mat_rand(output logic signed [IN_W-1:0] M [0:N-1][0:N-1]);
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++)
            M[i][j] = IN_W'($urandom());
    endfunction

    // ---------------------------------------------------------------------
    // Reset. Called at the start of every test task.
    // ---------------------------------------------------------------------
    task automatic do_reset();
        @(negedge clk);
        rst_n = 1'b0;
        wload = 1'b0;
        for (int k = 0; k < N; k++) begin
            sk_din[k] = '0;  sk_vin[k] = 1'b0;  weight_top[k] = '0;
        end
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
    endtask

    // ---------------------------------------------------------------------
    // THE CENTRAL DRIVER
    //
    // Differs from tb_array.sv's driver in exactly one respect, which is the
    // point of this stage: activations go in UN-SKEWED, all N lanes together
    // every cycle, and the skew buffer produces the stagger. Nothing here
    // pre-skews.
    //
    // Every cycle it also checks the skew-to-array wire against the buffer's
    // timing model, scored to whichever task is running -- so the boundary is
    // verified continuously, not just in test_alignment_offset.
    // ---------------------------------------------------------------------
    task automatic run_matmul(
        input  string                   tname,
        input  logic signed [IN_W-1:0]  A [0:N-1][0:N-1],
        input  logic signed [IN_W-1:0]  B [0:N-1][0:N-1],
        output logic signed [ACC_W-1:0] C [0:N-1][0:N-1],
        input  bit                      reset_first = 1'b1
    );
        int cyc;
        bit exp_v;

        if (reset_first) do_reset();

        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                C[i][j] = 'x;                    // uncollected stays X and fails
                obs_cycle[i][j] = -1;
            end
        for (int j = 0; j < N; j++) begin obs_count[j] = 0; extra_valid[j] = 0; end

        // ---- LOAD PHASE: weights bypass the skew buffer entirely -----------
        for (int t = 0; t < N; t++) begin
            @(negedge clk);
            wload = 1'b1;
            for (int j = 0; j < N; j++) weight_top[j] = B[N-1-t][j];
            for (int k = 0; k < N; k++) begin
                sk_din[k] = IN_W'($urandom());   // junk: must not reach the array
                sk_vin[k] = 1'b0;
            end
            #(TCLK/2 - SETTLE);
            // Nothing may be presented to the array while the psum bus carries
            // weights -- including residue left in the skew buffer by a previous
            // multiply, which is what test_back_to_back is hunting.
            for (int k = 0; k < N; k++)
                check(tname, int'(sk_vout[k]), 0, $sformatf("lane %0d valid during weight load", k));
        end

        // ---- COMPUTE PHASE: un-skewed in, staggered by the buffer -----------
        // Last column of A goes in at cycle N-1; the last result, C[N-1][N-1],
        // is due at cycle 3N-2. Drive DRAIN cycles past that to catch stragglers.
        for (int t = 0; t <= 3*N - 3 + DRAIN; t++) begin
            @(negedge clk);
            wload = 1'b0;
            for (int j = 0; j < N; j++) weight_top[j] = '0;

            for (int k = 0; k < N; k++) begin
                if (t < N) begin
                    sk_din[k] = A[t][k];         // column k on lane k, NO stagger
                    sk_vin[k] = 1'b1;            // all lanes together
                end else begin
                    sk_din[k] = IN_W'($urandom());   // junk after the matrix
                    sk_vin[k] = 1'b0;
                end
            end

            // --- boundary check, in the setup window ------------------------
            // a_in[0] comes through combinationally, so this is the only point
            // where a lane that is one cycle late looks different from one that
            // is on time.
            #(TCLK/2 - SETTLE);
            for (int k = 0; k < N; k++) begin
                exp_v = ((t - k) >= 0) && ((t - k) < N);
                check(tname, int'(sk_vout[k]), int'(exp_v),
                      $sformatf("a_in valid on array row %0d at cycle %0d", k, t));
                if (exp_v)
                    check(tname, int'(arr_a[k]), int'(A[t-k][k]),
                          $sformatf("a_in[%0d] at cycle %0d must be A[%0d][%0d]", k, t, t-k, k));
            end

            // --- sample the array's registered outputs ----------------------
            @(posedge clk);
            #SETTLE;
            cyc = t + 1;
            for (int j = 0; j < N; j++) begin
                if (valid_out[j] === 1'b1) begin
                    if (obs_count[j] < N) begin
                        C[obs_count[j]][j]         = psum_out[j];
                        obs_cycle[obs_count[j]][j] = cyc;
                        obs_count[j]++;
                    end else extra_valid[j]++;
                end
            end
        end

        @(negedge clk);                          // leave the inputs quiet
        for (int k = 0; k < N; k++) begin sk_din[k] = '0; sk_vin[k] = 1'b0; end
    endtask

    // =====================================================================
    // TEST TASKS
    // Each targets something the standalone testbenches could not see: they
    // verified each module against its own contract, these verify that the two
    // contracts actually meet.
    // =====================================================================

    // Checks the reference model before anything trusts it. The only hand-typed
    // expected values in the file.
    task automatic test_golden_sanity();
        string tn = begin_test("test_golden_sanity");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        mat_zero(A);  mat_zero(B);
        A[0][0] = 1; A[0][1] = 2; A[1][0] = 3; A[1][1] = 4;
        B[0][0] = 5; B[0][1] = 6; B[1][0] = 7; B[1][1] = 8;
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) E[i][j] = '0;
        E[0][0] = 19; E[0][1] = 22; E[1][0] = 43; E[1][1] = 50;

        golden(A, B, C);
        check_matrix(tn, C, E);
    endtask

    // The core interface check: the skew buffer's stagger must line up with the
    // array's input timing. Run first, and debug this one before trusting any
    // other test -- if the boundary is off by a cycle everything below lies.
    task automatic test_known();
        string tn = begin_test("test_known");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        mat_zero(A);  mat_zero(B);
        A[0][0] = 1; A[0][1] = 2; A[1][0] = 3; A[1][1] = 4;
        B[0][0] = 5; B[0][1] = 6; B[1][0] = 7; B[1][1] = 8;

        golden(A, B, E);
        run_matmul(tn, A, B, C);
        check_matrix(tn, C, E);
    endtask

    // Catches lane-mapping errors introduced AT THE BOUNDARY -- e.g. skew buffer
    // lane k wired to the wrong array row. Every element is distinct, so a
    // permutation cannot cancel out, and both operands are exercised in turn.
    task automatic test_identity_passthrough();
        string tn = begin_test("test_identity_passthrough");
        logic signed [IN_W-1:0]  M [0:N-1][0:N-1], I [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        mat_ramp(1, 1, M);  mat_identity(I);

        golden(I, M, E);  run_matmul(tn, I, M, C);  check_matrix(tn, C, E);  // I x B = B
        golden(M, I, E);  run_matmul(tn, M, I, C);  check_matrix(tn, C, E);  // A x I = A
    endtask

    // PRIORITY -- the test most specific to this integration.
    //
    // run_matmul already checks a_in[k] and its valid on every cycle against the
    // skew model; this task adds the other half: that the results then emerge on
    // the array's contracted cycles, N+n+j, with exactly N per column and no
    // strays. Together they pin the boundary at both ends.
    //
    // An unaccounted register stage anywhere in this path shifts every lane by
    // one cycle. The array would still emit a full, plausible set of results --
    // only wrong -- so this is checked element by element and cycle by cycle,
    // never by a total.
    task automatic test_alignment_offset();
        string tn = begin_test("test_alignment_offset");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        // Distinct, asymmetric values: a one-cycle slip must change the answer.
        mat_ramp(1, 1, A);
        mat_ramp(2, 3, B);
        golden(A, B, E);
        run_matmul(tn, A, B, C);
        check_matrix(tn, C, E);

        for (int j = 0; j < N; j++) begin
            check(tn, obs_count[j],   N, $sformatf("column %0d result count", j));
            check(tn, extra_valid[j], 0, $sformatf("column %0d stray valid_out", j));
            for (int n = 0; n < N; n++)
                check(tn, obs_cycle[n][j], N + n + j,
                      $sformatf("arrival cycle of C[%0d][%0d]", n, j));
        end

        // Repeat with a second shape so a lucky-looking ramp cannot carry it.
        mat_rand(A);  mat_rand(B);
        golden(A, B, E);
        run_matmul(tn, A, B, C);
        check_matrix(tn, C, E);
        for (int j = 0; j < N; j++)
            for (int n = 0; n < N; n++)
                check(tn, obs_cycle[n][j], N + n + j,
                      $sformatf("arrival cycle of C[%0d][%0d], random operands", n, j));
    endtask

    // Negative weights and activations through the integrated path. The skew
    // buffer carries raw bits, so this re-confirms nothing in the boundary
    // conversion drops or mangles the sign.
    task automatic test_negative();
        string tn = begin_test("test_negative");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        mat_ramp(1, 1, A);    mat_ramp(-1, -1, B);   // +A, -B
        golden(A, B, E);  run_matmul(tn, A, B, C);  check_matrix(tn, C, E);

        mat_ramp(-1, -1, A);  mat_ramp(1, 1, B);     // -A, +B
        golden(A, B, E);  run_matmul(tn, A, B, C);  check_matrix(tn, C, E);

        mat_ramp(-1, -1, A);  mat_ramp(-2, -1, B);   // -A, -B
        golden(A, B, E);  run_matmul(tn, A, B, C);  check_matrix(tn, C, E);

        // Mixed signs plus the two-complement extremes.
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                A[i][j] = ((i+j) % 2 == 0) ?  IN_W'(i+j+1)   : -IN_W'(i+j+1);
                B[i][j] = ((i+j) % 2 == 0) ? -IN_W'(2*i+j+1) :  IN_W'(2*i+j+1);
            end
        A[0][0] = 127;  A[N-1][N-1] = -128;
        B[0][0] = -128; B[N-1][N-1] = 127;
        golden(A, B, E);  run_matmul(tn, A, B, C);  check_matrix(tn, C, E);
    endtask

    // 100 random matrices end to end through the real skew buffer.
    task automatic test_random(input int n_iter = 100);
        string tn = begin_test("test_random");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        for (int it = 0; it < n_iter; it++) begin
            mat_rand(A);  mat_rand(B);
            golden(A, B, E);
            run_matmul(tn, A, B, C);
            check_matrix(tn, C, E);
        end
    endtask

    // Consecutive multiplies with no reset between them. Two pipelines can now
    // hold residue -- the array's psums AND the skew buffer's delay registers --
    // and the second is new at this stage. The load-phase valid check inside
    // run_matmul is what catches a skew buffer still draining into the array
    // while the next set of weights is being shifted in.
    task automatic test_back_to_back();
        string tn = begin_test("test_back_to_back");
        logic signed [IN_W-1:0]  A [0:N-1][0:N-1], B [0:N-1][0:N-1];
        logic signed [ACC_W-1:0] C [0:N-1][0:N-1], E [0:N-1][0:N-1];

        do_reset();

        mat_ramp(1, 1, A);   mat_ramp(10, 3, B);
        golden(A, B, E);  run_matmul(tn, A, B, C, 1'b0);  check_matrix(tn, C, E);

        mat_ramp(2, -1, A);  mat_ramp(-5, -2, B);         // different weights
        golden(A, B, E);  run_matmul(tn, A, B, C, 1'b0);  check_matrix(tn, C, E);

        mat_ramp(7, 1, A);   mat_zero(B);                 // zero weights: C must be 0
        golden(A, B, E);  run_matmul(tn, A, B, C, 1'b0);  check_matrix(tn, C, E);

        for (int it = 0; it < 6; it++) begin
            mat_rand(A);  mat_rand(B);
            golden(A, B, E);  run_matmul(tn, A, B, C, 1'b0);  check_matrix(tn, C, E);
        end
    endtask

    // ---------------------------------------------------------------------
    // Entry points
    // ---------------------------------------------------------------------
    task automatic run_all();
        test_golden_sanity();
        test_known();
        test_identity_passthrough();
        test_alignment_offset();
        test_negative();
        test_random(100);
        test_back_to_back();
    endtask

    // test_scaling: N=2. A second elaboration of the same wiring, so a boundary
    // that only happens to line up at N=4 cannot survive it.
    task automatic run_subset();
        test_golden_sanity();
        test_known();
        test_alignment_offset();
        test_random(20);
    endtask

endmodule


// =============================================================================
module tb_integration1;

    localparam time TCLK = 10ns;
    localparam int  SEED = 32'h5EED_17EC;        // fixed -> reproducible

    logic clk;
    int   total_pass, total_fail;

    integ1_harness #(.N(4), .IN_W(8), .ACC_W(32), .TAG(""))
        h4 (.clk(clk));
    integ1_harness #(.N(2), .IN_W(8), .ACC_W(32), .TAG("scaling_N2/"))
        h2 (.clk(clk));

    initial begin clk = 1'b0; forever #(TCLK/2) clk = ~clk; end

    initial begin $dumpfile("tb_integration1.vcd"); $dumpvars(0, tb_integration1); end

    initial begin #1000000; $error("TIMEOUT"); $finish; end

    `define INTEG1_ROLL_UP(H)                                                 \
        foreach (H.test_order[i]) begin                                       \
            t = H.test_order[i];                                              \
            $display(" %-30s %8d %8d   %s", t, H.pass_cnt[t], H.fail_cnt[t],  \
                     (H.fail_cnt[t] == 0) ? "PASS" : "FAIL");                 \
            if (H.fail_cnt[t] != 0) failing.push_back(t);                     \
        end                                                                   \
        total_pass += H.total_pass;  total_fail += H.total_fail;

    task automatic report();
        string failing[$];
        string t;
        total_pass = 0;  total_fail = 0;

        $display("\n=================================================================");
        $display(" INTEGRATION-1 SUMMARY  (skew_buffer + systolic_array)");
        $display("=================================================================");
        $display(" %-30s %8s %8s   %s", "TASK", "PASS", "FAIL", "STATUS");
        $display("-----------------------------------------------------------------");
        `INTEG1_ROLL_UP(h4)
        `INTEG1_ROLL_UP(h2)
        $display("-----------------------------------------------------------------");
        $display(" %-30s %8d %8d", "TOTAL", total_pass, total_fail);
        $display("=================================================================\n");

        if (total_fail == 0) $display("=== INTEGRATION-1 PASSED ===");
        else begin
            $display("=== INTEGRATION-1 FAILED ===");
            $display("Failing tasks:");
            foreach (failing[i]) $display("  - %s", failing[i]);
        end
    endtask

    initial begin
        int seed;
        seed = SEED;
        void'($urandom(seed));

        $display("\n### N = 4 ###");
        h4.run_all();
        $display("\n### test_scaling: N = 2 ###");
        h2.run_subset();

        report();
        $finish;
    end

endmodule
