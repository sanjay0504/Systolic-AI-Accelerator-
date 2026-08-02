// -----------------------------------------------------------------------------
// tb_address_gen.sv -- self-checking testbench for address_gen.sv
//
// This module has no datapath, only address SEQUENCES, so the golden model is a
// set of reference sequence functions rather than any arithmetic. The TB also
// stands in for the controller: it drives `phase` through
// IDLE -> LOAD -> COMPUTE -> DRAIN -> IDLE itself.
//
// Timing convention: drive on the negedge, sample in the setup window 1 ns
// BEFORE the following posedge.
//
// Sampling before the edge is required here, not stylistic. The addresses are
// registered counters but the enables are combinational off `phase`, and the
// counters advance on the very edge that ends the cycle being observed. Sampling
// after the posedge would read the NEXT cycle's address alongside this cycle's
// phase -- the whole sequence would appear shifted by one, the last address
// would be missed, and a genuinely off-by-one DUT would look correct.
//
// -----------------------------------------------------------------------------
// THE TIMING CONTRACT UNDER TEST
// -----------------------------------------------------------------------------
// All three memories have a 1-cycle registered read: an address issued on cycle
// t delivers data on cycle t+1. address_gen issues its first address on the
// FIRST cycle of a phase, so the array consumes that phase's first datum on the
// SECOND cycle. test_memory_latency_offset models that memory explicitly and
// checks the delivered row, rather than only checking that the address values
// are numerically right -- a sequence issued one cycle late is numerically
// perfect and completely wrong.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_address_gen;

    // ---------------------------------------------------------------------
    // Parameters / infrastructure
    // ---------------------------------------------------------------------
    localparam int  N      = 4;
    localparam int  DEPTH  = 16;
    localparam int  ADDR_W = $clog2(DEPTH);

    localparam time TCLK   = 10ns;
    localparam time SETTLE = 1ns;

    // Phase encoding -- must match address_gen.sv.
    localparam logic [1:0] PH_IDLE    = 2'd0;
    localparam logic [1:0] PH_LOAD    = 2'd1;
    localparam logic [1:0] PH_COMPUTE = 2'd2;
    localparam logic [1:0] PH_DRAIN   = 2'd3;

    logic              clk;
    logic              rst_n;
    logic              start;
    logic [1:0]        phase;

    logic [ADDR_W-1:0] weight_rd_addr;
    logic              weight_rd_en;
    logic [ADDR_W-1:0] act_rd_addr;
    logic              act_rd_en;
    logic [ADDR_W-1:0] out_wr_addr;
    logic              out_wr_en;
    logic              addr_done;

    // Padding extension.
    localparam int KW = $clog2(N+1);          // width of K_real

    logic [KW-1:0]     K_real;
    logic              pad_weight [0:N-1];
    logic              pad_act    [0:N-1];

    address_gen #(.N(N), .DEPTH(DEPTH)) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .phase          (phase),
        .K_real         (K_real),
        .pad_weight     (pad_weight),
        .pad_act        (pad_act),
        .weight_rd_addr (weight_rd_addr),
        .weight_rd_en   (weight_rd_en),
        .act_rd_addr    (act_rd_addr),
        .act_rd_en      (act_rd_en),
        .out_wr_addr    (out_wr_addr),
        .out_wr_en      (out_wr_en),
        .addr_done      (addr_done)
    );

    initial begin clk = 1'b0; forever #(TCLK/2) clk = ~clk; end

    initial begin $dumpfile("tb_address_gen.vcd"); $dumpvars(0, tb_address_gen); end

    initial begin #500000; $error("TIMEOUT"); $finish; end

    // ---------------------------------------------------------------------
    // MEMORY MODEL -- a faithful 1-cycle registered read, used by
    // test_memory_latency_offset. It records WHICH ROW would be delivered on
    // each cycle, which is the thing the timing contract is actually about.
    // ---------------------------------------------------------------------
    logic [ADDR_W-1:0] w_deliv_row;   logic w_deliv_val;
    logic [ADDR_W-1:0] a_deliv_row;   logic a_deliv_val;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_deliv_val <= 1'b0;
            a_deliv_val <= 1'b0;
        end else begin
            w_deliv_val <= weight_rd_en;
            a_deliv_val <= act_rd_en;
            if (weight_rd_en) w_deliv_row <= weight_rd_addr;
            if (act_rd_en)    a_deliv_row <= act_rd_addr;
        end
    end

    // ---------------------------------------------------------------------
    // GOLDEN MODEL -- the reference sequences, computed independently.
    // ---------------------------------------------------------------------

    // LOAD: N-1, N-2, ... 1, 0. Down-counter, because the weight presented
    // first travels furthest down the column and lands in the bottom row.
    function automatic int expected_weight_addr(input int cycle_in_load_phase);
        return (N - 1) - cycle_in_load_phase;
    endfunction

    // COMPUTE: 0, 1, ... N-1, then stop. No stagger here -- the skew buffer
    // downstream does that.
    function automatic int expected_act_addr(input int cycle_in_compute_phase);
        return cycle_in_compute_phase;
    endfunction

    // One row address per completed output row.
    function automatic int expected_out_addr(input int row_index);
        return row_index;
    endfunction

    // Padding masks: row k is padding when it is at or beyond the real inner
    // dimension. Note none of the three sequence functions above take k_real --
    // that is the point of the extension, and test_pad_addressing_unaffected
    // exists to prove the DUT agrees.
    function automatic void golden_pad_masks(
        input  int   k_real,
        output logic pad_weight_exp [0:N-1],
        output logic pad_act_exp    [0:N-1]
    );
        for (int k = 0; k < N; k++) begin
            pad_weight_exp[k] = (k >= k_real);
            pad_act_exp[k]    = (k >= k_real);
        end
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

    task automatic check(input string tname, input int cycle,
                         input int got, input int exp, input string note);
        if (got === exp) begin pass_cnt[tname]++; total_pass++; end
        else begin
            fail_cnt[tname]++; total_fail++;
            $display("[FAIL] %s: cycle %0d %s expected=%0d got=%0d",
                     tname, cycle, note, exp, got);
        end
    endtask

    // ---------------------------------------------------------------------
    // Drive plumbing
    // ---------------------------------------------------------------------

    // One cycle at the given phase. Returns positioned in the setup window, so
    // the caller reads exactly what this cycle presented.
    task automatic step(input logic [1:0] ph, input bit st);
        @(negedge clk);
        phase = ph;
        start = st;
        #(TCLK/2 - SETTLE);
    endtask

    // Reset with phase held in IDLE, which is what the controller will do -- the
    // enables are gated by phase, so a reset taken in any other phase would
    // assert a read enable while the counters reload.
    // K_real defaults to N here, so every pre-existing task runs fully populated
    // and exercises exactly the behaviour it did before the padding extension.
    // The new tasks override it after calling this.
    task automatic do_reset();
        @(negedge clk);
        rst_n  = 1'b0;
        phase  = PH_IDLE;
        start  = 1'b0;
        K_real = KW'(N);
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
    endtask

    // Change the run's inner dimension. Driven on a negedge like every other
    // input, so it is stable well before the posedge that samples `start`.
    task automatic set_k(input int k);
        @(negedge clk);
        K_real = KW'(k);
    endtask

    // Compare both mask outputs against the reference for the given k_real.
    task automatic check_pad(input string tname, input int cycle,
                             input int k_real, input string note);
        logic pw_exp [0:N-1];
        logic pa_exp [0:N-1];
        golden_pad_masks(k_real, pw_exp, pa_exp);
        for (int k = 0; k < N; k++) begin
            check(tname, cycle, int'(pad_weight[k]), int'(pw_exp[k]),
                  $sformatf("%s pad_weight[%0d] at K_real=%0d", note, k, k_real));
            check(tname, cycle, int'(pad_act[k]), int'(pa_exp[k]),
                  $sformatf("%s pad_act[%0d] at K_real=%0d", note, k, k_real));
        end
    endtask

    // start is pulsed in IDLE, one cycle before the LOAD phase begins. Pulsing
    // it during LOAD would reload the counter on the same edge that should have
    // advanced it, re-issuing address N-1 twice.
    task automatic pulse_start();
        step(PH_IDLE, 1'b1);
        step(PH_IDLE, 1'b0);
    endtask

    // Walk one full LOAD phase, checking every cycle against the golden
    // sequence. Shared by several tests.
    task automatic run_load(input string tname);
        for (int t = 0; t < N; t++) begin
            step(PH_LOAD, 1'b0);
            check(tname, t, int'(weight_rd_addr), expected_weight_addr(t), "weight_rd_addr");
            check(tname, t, int'(weight_rd_en),   1,                       "weight_rd_en");
        end
    endtask

    task automatic run_compute(input string tname);
        for (int t = 0; t < N; t++) begin
            step(PH_COMPUTE, 1'b0);
            check(tname, t, int'(act_rd_addr), expected_act_addr(t), "act_rd_addr");
            check(tname, t, int'(act_rd_en),   1,                    "act_rd_en");
        end
    endtask

    task automatic run_drain(input string tname);
        for (int r = 0; r < N; r++) begin
            step(PH_DRAIN, 1'b0);
            check(tname, r, int'(out_wr_addr), expected_out_addr(r), "out_wr_addr");
            check(tname, r, int'(out_wr_en),   1,                    "out_wr_en");
        end
    endtask

    // The full sequence, start to finish.
    task automatic run_sequence(input string tname);
        pulse_start();
        run_load(tname);
        run_compute(tname);
        run_drain(tname);
        step(PH_IDLE, 1'b0);
    endtask

    // =====================================================================
    // TEST TASKS
    // =====================================================================

    // Catches a weight counter that counts the wrong way, starts at the wrong
    // value, or skips. The direction is the point: an up-counter here loads B
    // upside down and every result is wrong but plausible.
    task automatic test_weight_load_sequence();
        string tn = begin_test("test_weight_load_sequence");
        do_reset();
        pulse_start();
        run_load(tn);
    endtask

    // Catches a stuck-high read enable -- spurious memory reads outside the
    // phase that owns them. Checked for all three enables in every other phase.
    task automatic test_weight_load_boundary();
        string tn = begin_test("test_weight_load_boundary");
        do_reset();

        // Before start, sitting in IDLE.
        for (int t = 0; t < 3; t++) begin
            step(PH_IDLE, 1'b0);
            check(tn, t, int'(weight_rd_en), 0, "weight_rd_en in IDLE before start");
            check(tn, t, int'(act_rd_en),    0, "act_rd_en in IDLE before start");
            check(tn, t, int'(out_wr_en),    0, "out_wr_en in IDLE before start");
        end

        pulse_start();

        // During LOAD only the weight enable may be high.
        for (int t = 0; t < N; t++) begin
            step(PH_LOAD, 1'b0);
            check(tn, t, int'(act_rd_en), 0, "act_rd_en during LOAD");
            check(tn, t, int'(out_wr_en), 0, "out_wr_en during LOAD");
        end

        // During COMPUTE the weight enable must be low again.
        for (int t = 0; t < N; t++) begin
            step(PH_COMPUTE, 1'b0);
            check(tn, t, int'(weight_rd_en), 0, "weight_rd_en during COMPUTE");
            check(tn, t, int'(out_wr_en),    0, "out_wr_en during COMPUTE");
        end

        // During DRAIN neither read enable may fire.
        for (int t = 0; t < N; t++) begin
            step(PH_DRAIN, 1'b0);
            check(tn, t, int'(weight_rd_en), 0, "weight_rd_en during DRAIN");
            check(tn, t, int'(act_rd_en),    0, "act_rd_en during DRAIN");
        end

        // And back in IDLE afterwards.
        for (int t = 0; t < 3; t++) begin
            step(PH_IDLE, 1'b0);
            check(tn, t, int'(weight_rd_en), 0, "weight_rd_en in IDLE after the run");
            check(tn, t, int'(act_rd_en),    0, "act_rd_en in IDLE after the run");
            check(tn, t, int'(out_wr_en),    0, "out_wr_en in IDLE after the run");
        end
    endtask

    // Catches an activation counter that starts at the wrong value or skips.
    task automatic test_act_addr_sequence();
        string tn = begin_test("test_act_addr_sequence");
        do_reset();
        pulse_start();
        run_load(tn);
        run_compute(tn);
    endtask

    // PRIORITY. The real controller holds COMPUTE far longer than N cycles --
    // the array's compute and drain overlap it. The counter must issue exactly
    // N addresses and then stop dead: no wrapping back to 0 (which would re-read
    // column 0 into the middle of the run) and no counting past N-1 into
    // addresses that hold nothing.
    task automatic test_act_addr_stops();
        string tn = begin_test("test_act_addr_stops");
        do_reset();
        pulse_start();
        run_load(tn);
        run_compute(tn);                     // the N legitimate addresses

        // Hold COMPUTE for another 2N cycles, as the controller will.
        for (int t = 0; t < 2*N; t++) begin
            step(PH_COMPUTE, 1'b0);
            check(tn, N+t, int'(act_rd_en), 0,
                  "act_rd_en must stay low after N addresses");
            check(tn, N+t, int'(act_rd_addr), N-1,
                  "act_rd_addr must hold, not wrap or advance");
        end
    endtask

    // Catches an output row counter that advances on the wrong cycles. Note the
    // completion trigger for this DUT is simply a DRAIN cycle -- the module has
    // no row_done input, so "one completed row" is "one DRAIN cycle". The IDLE
    // gap in the middle is the real check: the counter must not move on cycles
    // that are not completion events.
    task automatic test_output_addr_sequence();
        string tn = begin_test("test_output_addr_sequence");
        do_reset();
        pulse_start();
        run_load(tn);
        run_compute(tn);

        // First two rows.
        for (int r = 0; r < 2; r++) begin
            step(PH_DRAIN, 1'b0);
            check(tn, r, int'(out_wr_addr), expected_out_addr(r), "out_wr_addr");
            check(tn, r, int'(out_wr_en),   1,                    "out_wr_en");
        end

        // A gap with no completion events: the address must freeze.
        for (int g = 0; g < 3; g++) begin
            step(PH_IDLE, 1'b0);
            check(tn, 2, int'(out_wr_addr), 2, "out_wr_addr must hold across a gap");
            check(tn, 2, int'(out_wr_en),   0, "out_wr_en must be low across a gap");
        end

        // Remaining rows resume where they left off.
        for (int r = 2; r < N; r++) begin
            step(PH_DRAIN, 1'b0);
            check(tn, r, int'(out_wr_addr), expected_out_addr(r), "out_wr_addr after the gap");
            check(tn, r, int'(out_wr_en),   1,                    "out_wr_en after the gap");
        end

        // And it stops after N rows rather than wrapping.
        for (int g = 0; g < N; g++) begin
            step(PH_DRAIN, 1'b0);
            check(tn, N+g, int'(out_wr_en),   0,   "out_wr_en after all N rows");
            check(tn, N+g, int'(out_wr_addr), N-1, "out_wr_addr must hold at N-1");
        end
    endtask

    // PRIORITY -- the most important test in this file. It checks the OFFSET,
    // not the values.
    //
    // The memory model above delivers, on cycle t, whatever address was issued
    // on cycle t-1. The contract says the array consumes a phase's first datum
    // on that phase's SECOND cycle, so:
    //   * nothing may be delivered on the first cycle of a phase;
    //   * on cycle t (t>=1) the delivered row must be the one the array needs at
    //     its own load/compute cycle t-1.
    //
    // A sequence issued one cycle late is numerically identical and fails here
    // on every single cycle -- which is exactly the bug a value-only test misses.
    task automatic test_memory_latency_offset();
        string tn = begin_test("test_memory_latency_offset");
        do_reset();
        pulse_start();

        // ---- LOAD -------------------------------------------------------
        for (int t = 0; t <= N; t++) begin
            step(PH_LOAD, 1'b0);
            if (t == 0) begin
                check(tn, t, int'(w_deliv_val), 0,
                      "no weight data may be delivered on the first LOAD cycle");
            end else begin
                check(tn, t, int'(w_deliv_val), 1,
                      "weight data must be delivered from the second LOAD cycle on");
                // The row the array needs at its load cycle (t-1).
                check(tn, t, int'(w_deliv_row), expected_weight_addr(t-1),
                      "delivered weight row vs the array's need one cycle earlier");
                check(tn, t, int'(w_deliv_row), (N-1)-(t-1),
                      "delivered weight row expressed as N-1-(load cycle)");
            end
        end

        // ---- COMPUTE ----------------------------------------------------
        for (int t = 0; t <= N; t++) begin
            step(PH_COMPUTE, 1'b0);
            if (t == 0) begin
                check(tn, t, int'(a_deliv_val), 0,
                      "no activation data may be delivered on the first COMPUTE cycle");
            end else begin
                check(tn, t, int'(a_deliv_val), 1,
                      "activation data must be delivered from the second COMPUTE cycle on");
                check(tn, t, int'(a_deliv_row), expected_act_addr(t-1),
                      "delivered activation column vs the array's need one cycle earlier");
            end
        end
    endtask

    // Catches addr_done asserting a cycle early (the controller would advance
    // while the last address is still being issued) or a cycle late (a wasted
    // cycle, and a stall the array's timing does not expect).
    task automatic test_addr_done_timing();
        string tn = begin_test("test_addr_done_timing");
        do_reset();

        // IDLE: there is no sequence to finish.
        for (int t = 0; t < 2; t++) begin
            step(PH_IDLE, 1'b0);
            check(tn, t, int'(addr_done), 0, "addr_done in IDLE");
        end

        pulse_start();

        // Low across all N issuing cycles, high on the cycle after the last.
        for (int t = 0; t < N; t++) begin
            step(PH_LOAD, 1'b0);
            check(tn, t, int'(addr_done), 0, "addr_done during LOAD issuing");
        end
        for (int t = 0; t < 2; t++) begin
            step(PH_LOAD, 1'b0);
            check(tn, N+t, int'(addr_done), 1, "addr_done after LOAD's last address");
        end

        for (int t = 0; t < N; t++) begin
            step(PH_COMPUTE, 1'b0);
            check(tn, t, int'(addr_done), 0, "addr_done during COMPUTE issuing");
        end
        for (int t = 0; t < 2; t++) begin
            step(PH_COMPUTE, 1'b0);
            check(tn, N+t, int'(addr_done), 1, "addr_done after COMPUTE's last address");
        end

        for (int r = 0; r < N; r++) begin
            step(PH_DRAIN, 1'b0);
            check(tn, r, int'(addr_done), 0, "addr_done during DRAIN issuing");
        end
        for (int t = 0; t < 2; t++) begin
            step(PH_DRAIN, 1'b0);
            check(tn, N+t, int'(addr_done), 1, "addr_done after DRAIN's last row");
        end

        // Back to IDLE: per-phase, so it reads 0 again regardless of history.
        step(PH_IDLE, 1'b0);
        check(tn, 0, int'(addr_done), 0, "addr_done back in IDLE");
    endtask

    // Catches counter state that survives a reset. Reset is taken mid-LOAD and
    // again mid-COMPUTE, with the phase held, so there is real in-flight state
    // to lose.
    task automatic test_reset_mid_sequence();
        string tn = begin_test("test_reset_mid_sequence");

        // --- reset partway through LOAD ----------------------------------
        do_reset();
        pulse_start();
        for (int t = 0; t < 2; t++) begin           // two addresses issued
            step(PH_LOAD, 1'b0);
            check(tn, t, int'(weight_rd_addr), expected_weight_addr(t), "pre-reset weight_rd_addr");
        end

        @(negedge clk);                              // assert reset, phase held
        rst_n = 1'b0;
        phase = PH_IDLE;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;

        // Counter must be back at its start value, not wherever it had reached.
        for (int t = 0; t < N; t++) begin
            step(PH_LOAD, 1'b0);
            check(tn, t, int'(weight_rd_addr), expected_weight_addr(t),
                  "weight sequence restarts cleanly after reset");
            check(tn, t, int'(weight_rd_en), 1, "weight_rd_en after reset");
        end

        // --- reset partway through COMPUTE -------------------------------
        do_reset();
        pulse_start();
        run_load(tn);
        for (int t = 0; t < 2; t++) begin
            step(PH_COMPUTE, 1'b0);
            check(tn, t, int'(act_rd_addr), expected_act_addr(t), "pre-reset act_rd_addr");
        end

        @(negedge clk);
        rst_n = 1'b0;
        phase = PH_IDLE;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;

        for (int t = 0; t < N; t++) begin
            step(PH_COMPUTE, 1'b0);
            check(tn, t, int'(act_rd_addr), expected_act_addr(t),
                  "activation sequence restarts cleanly after reset");
        end

        // --- and a full clean run afterwards ------------------------------
        do_reset();
        run_sequence(tn);
    endtask

    // Catches residue between runs: a second start immediately after the first
    // sequence completes must reload every counter, including ones that had
    // already stopped.
    task automatic test_back_to_back_runs();
        string tn = begin_test("test_back_to_back_runs");
        do_reset();

        for (int run = 0; run < 3; run++) begin
            run_sequence(tn);
        end

        // A start issued while the previous run's counters are all exhausted --
        // the case most likely to leave a stopped counter stopped.
        pulse_start();
        run_load(tn);
        run_compute(tn);
        run_drain(tn);
        step(PH_IDLE, 1'b0);
    endtask

    // =====================================================================
    // PADDING EXTENSION TESTS
    //
    // Everything above this line predates the K_real input and runs with
    // K_real = N, forced by do_reset(). Those tasks are the regression net:
    // if the extension disturbed the fully-populated case, they fail, and the
    // tasks below are what tell padding-specific bugs apart from that.
    // =====================================================================

    // Run FIRST of the padding tasks. Re-runs the core weight and activation
    // stimulus with K_real = N explicitly driven, and additionally requires both
    // masks to read all-zero on every cycle. A failure here means the extension
    // broke the base case, not that padding is wrong -- which is exactly the
    // distinction that makes the rest of these tasks readable.
    task automatic test_regression_full_k();
        string tn = begin_test("test_regression_full_k");
        do_reset();
        set_k(N);
        pulse_start();

        for (int t = 0; t < N; t++) begin
            step(PH_LOAD, 1'b0);
            check(tn, t, int'(weight_rd_addr), expected_weight_addr(t), "weight_rd_addr at K_real=N");
            check(tn, t, int'(weight_rd_en),   1,                       "weight_rd_en at K_real=N");
            check_pad(tn, t, N, "during LOAD");
        end

        for (int t = 0; t < N; t++) begin
            step(PH_COMPUTE, 1'b0);
            check(tn, t, int'(act_rd_addr), expected_act_addr(t), "act_rd_addr at K_real=N");
            check(tn, t, int'(act_rd_en),   1,                    "act_rd_en at K_real=N");
            check_pad(tn, t, N, "during COMPUTE");
        end

        // Stated as its own explicit check, since "all zero" is the whole claim.
        for (int k = 0; k < N; k++) begin
            check(tn, 0, int'(pad_weight[k]), 0, $sformatf("pad_weight[%0d] must be 0 at K_real=N", k));
            check(tn, 0, int'(pad_act[k]),    0, $sformatf("pad_act[%0d] must be 0 at K_real=N", k));
        end
    endtask

    // Catches an off-by-one in the mask boundary in either direction. Every
    // valid sub-N value is swept, and the boundary is checked index by index --
    // with K_real=2, lanes 0-1 must be real and 2-3 padded, not 0-2/3 or 0-1/2.
    task automatic test_pad_mask_values();
        string tn = begin_test("test_pad_mask_values");
        do_reset();

        for (int k_real = 1; k_real < N; k_real++) begin
            set_k(k_real);
            step(PH_IDLE, 1'b0);
            check_pad(tn, k_real, k_real, "combinational, in IDLE");

            // The boundary itself, named explicitly rather than inferred from
            // the loop above.
            check(tn, k_real, int'(pad_weight[k_real-1]), 0,
                  $sformatf("last real row %0d must NOT be padded", k_real-1));
            check(tn, k_real, int'(pad_weight[k_real]), 1,
                  $sformatf("first padded row %0d must BE padded", k_real));
        end
    endtask

    // Padding is a property of the run, not of the cycle. Catches a mask that
    // accidentally depends on phase or on a counter -- checked on every cycle of
    // a full LOAD and COMPUTE, which covers start, middle and end of both.
    task automatic test_pad_mask_stability();
        string tn = begin_test("test_pad_mask_stability");

        for (int k_real = 1; k_real <= N; k_real++) begin
            do_reset();
            set_k(k_real);
            pulse_start();
            check_pad(tn, 0, k_real, "before LOAD");

            for (int t = 0; t < N; t++) begin
                step(PH_LOAD, 1'b0);
                check_pad(tn, t, k_real, "mid LOAD");
            end
            step(PH_LOAD, 1'b1);                    // addr_done cycle
            check_pad(tn, N, k_real, "end of LOAD");

            for (int t = 0; t < N; t++) begin
                step(PH_COMPUTE, 1'b0);
                check_pad(tn, t, k_real, "mid COMPUTE");
            end
            step(PH_COMPUTE, 1'b1);
            check_pad(tn, N, k_real, "end of COMPUTE");

            for (int r = 0; r < N; r++) begin
                step(PH_DRAIN, 1'b0);
                check_pad(tn, r, k_real, "during DRAIN");
            end
        end
    endtask

    // PRIORITY. Exists specifically to catch a design that conflates "padded"
    // with "not issued". The masks are informational: a padded row's address is
    // still read, and only the edge mux downstream discards the data.
    //
    // The K_real=N sequence is captured first and every other K_real is compared
    // against that CAPTURE, not merely against the golden functions -- so an
    // implementation that skipped padded addresses would fail here even if its
    // masks were perfect, and even if someone had made the golden functions
    // K-dependent by mistake.
    task automatic test_pad_addressing_unaffected();
        string tn = begin_test("test_pad_addressing_unaffected");
        int ref_w_addr [0:N-1], ref_w_en [0:N-1];
        int ref_a_addr [0:N-1], ref_a_en [0:N-1];

        // --- capture the fully-populated reference sequence ----------------
        do_reset();
        set_k(N);
        pulse_start();
        for (int t = 0; t < N; t++) begin
            step(PH_LOAD, 1'b0);
            ref_w_addr[t] = int'(weight_rd_addr);
            ref_w_en[t]   = int'(weight_rd_en);
        end
        step(PH_LOAD, 1'b1);
        for (int t = 0; t < N; t++) begin
            step(PH_COMPUTE, 1'b0);
            ref_a_addr[t] = int'(act_rd_addr);
            ref_a_en[t]   = int'(act_rd_en);
        end

        // The capture must itself be right, or the comparisons below are
        // comparing against nonsense.
        for (int t = 0; t < N; t++) begin
            check(tn, t, ref_w_addr[t], expected_weight_addr(t), "captured reference weight_rd_addr");
            check(tn, t, ref_a_addr[t], expected_act_addr(t),    "captured reference act_rd_addr");
        end

        // --- every other K_real must reproduce it exactly -------------------
        for (int k_real = 1; k_real <= N; k_real++) begin
            do_reset();
            set_k(k_real);
            pulse_start();

            for (int t = 0; t < N; t++) begin
                step(PH_LOAD, 1'b0);
                check(tn, t, int'(weight_rd_addr), ref_w_addr[t],
                      $sformatf("K_real=%0d weight_rd_addr must match the K_real=N sequence", k_real));
                check(tn, t, int'(weight_rd_en), ref_w_en[t],
                      $sformatf("K_real=%0d weight_rd_en must match the K_real=N sequence", k_real));
            end

            // Still exactly N addresses, so addr_done still lands on cycle N.
            step(PH_LOAD, 1'b0);
            check(tn, N, int'(addr_done), 1,
                  $sformatf("K_real=%0d addr_done still asserts after N weight addresses", k_real));

            for (int t = 0; t < N; t++) begin
                step(PH_COMPUTE, 1'b0);
                check(tn, t, int'(act_rd_addr), ref_a_addr[t],
                      $sformatf("K_real=%0d act_rd_addr must match the K_real=N sequence", k_real));
                check(tn, t, int'(act_rd_en), ref_a_en[t],
                      $sformatf("K_real=%0d act_rd_en must match the K_real=N sequence", k_real));
            end

            step(PH_COMPUTE, 1'b0);
            check(tn, N, int'(addr_done), 1,
                  $sformatf("K_real=%0d addr_done still asserts after N act addresses", k_real));
        end
    endtask

    // The two extremes, where an off-by-one in the mask is most likely to show:
    // K_real=1 leaves exactly one real row, K_real=N leaves none padded.
    task automatic test_k_real_boundary_values();
        string tn = begin_test("test_k_real_boundary_values");

        // --- maximum padding ---------------------------------------------
        do_reset();
        set_k(1);
        step(PH_IDLE, 1'b0);
        check_pad(tn, 0, 1, "K_real=1");
        check(tn, 0, int'(pad_weight[0]), 0, "row 0 is the one real row at K_real=1");
        for (int k = 1; k < N; k++)
            check(tn, 0, int'(pad_weight[k]), 1,
                  $sformatf("row %0d is padded at K_real=1", k));

        // It must still run a complete, normally-timed sequence.
        pulse_start();
        run_load(tn);
        run_compute(tn);
        run_drain(tn);

        // --- no padding ---------------------------------------------------
        do_reset();
        set_k(N);
        step(PH_IDLE, 1'b0);
        check_pad(tn, 0, N, "K_real=N");
        for (int k = 0; k < N; k++)
            check(tn, 0, int'(pad_weight[k]), 0,
                  $sformatf("row %0d is real at K_real=N", k));

        pulse_start();
        run_load(tn);
        run_compute(tn);
        run_drain(tn);
    endtask

    // The DUT flags an out-of-range K_real with $error at `start`. A testbench
    // cannot capture $error directly, so this task announces the window in which
    // those messages are EXPECTED -- their absence from the transcript is the
    // failure, and their presence is the pass.
    //
    // What is machine-checkable is that the module stays deterministic while
    // misconfigured rather than emitting X: K_real=0 marks every row padded
    // (which is why 0 is worth rejecting -- it would compute an all-zero product
    // that looks like a working accelerator fed zeros), and K_real>N marks none.
    task automatic test_k_real_invalid();
        string tn = begin_test("test_k_real_invalid");

        $display("     NOTE: two address_gen K_real range errors are EXPECTED below.");

        // --- K_real = 0 ---------------------------------------------------
        do_reset();
        set_k(0);
        pulse_start();                       // the DUT should $error here
        step(PH_IDLE, 1'b0);
        for (int k = 0; k < N; k++) begin
            check(tn, 0, int'(pad_weight[k]), 1, $sformatf("K_real=0 marks row %0d padded", k));
            check(tn, 0, int'(pad_act[k]),    1, $sformatf("K_real=0 marks act row %0d padded", k));
        end

        // --- K_real = N+1 --------------------------------------------------
        do_reset();
        set_k(N+1);
        pulse_start();                       // and again here
        step(PH_IDLE, 1'b0);
        for (int k = 0; k < N; k++) begin
            check(tn, 0, int'(pad_weight[k]), 0, $sformatf("K_real=N+1 marks row %0d unpadded", k));
            check(tn, 0, int'(pad_act[k]),    0, $sformatf("K_real=N+1 marks act row %0d unpadded", k));
        end

        $display("     NOTE: end of the expected-error window.");

        // A valid K_real afterwards must behave normally -- a rejected
        // configuration must not leave the module wedged.
        do_reset();
        set_k(2);
        pulse_start();
        check_pad(tn, 0, 2, "recovery after an invalid K_real");
        run_load(tn);
        run_compute(tn);
    endtask

    // ---------------------------------------------------------------------
    // Report
    // ---------------------------------------------------------------------
    task automatic report();
        string failing[$];
        string t;

        $display("\n=================================================================");
        $display(" ADDRESS GENERATOR TESTBENCH SUMMARY");
        $display("=================================================================");
        $display(" %-32s %8s %8s   %s", "TASK", "PASS", "FAIL", "STATUS");
        $display("-----------------------------------------------------------------");
        foreach (test_order[i]) begin
            t = test_order[i];
            $display(" %-32s %8d %8d   %s", t, pass_cnt[t], fail_cnt[t],
                     (fail_cnt[t] == 0) ? "PASS" : "FAIL");
            if (fail_cnt[t] != 0) failing.push_back(t);
        end
        $display("-----------------------------------------------------------------");
        $display(" %-32s %8d %8d", "TOTAL", total_pass, total_fail);
        $display("=================================================================\n");

        if (total_fail == 0) $display("=== ADDRESS GENERATOR PASSED ===");
        else begin
            $display("=== ADDRESS GENERATOR FAILED ===");
            $display("Failing tasks:");
            foreach (failing[i]) $display("  - %s", failing[i]);
        end
    endtask

    // ---------------------------------------------------------------------
    // Main sequence
    // ---------------------------------------------------------------------
    initial begin
        total_pass = 0;  total_fail = 0;

        rst_n  = 1'b1;
        start  = 1'b0;
        phase  = PH_IDLE;
        K_real = KW'(N);        // fully populated, as every original task assumes

        // Original tasks, unchanged and in their original order. These all run
        // at K_real = N and are the regression net for the padding extension.
        test_weight_load_sequence();
        test_weight_load_boundary();
        test_act_addr_sequence();
        test_act_addr_stops();
        test_output_addr_sequence();
        test_memory_latency_offset();
        test_addr_done_timing();
        test_reset_mid_sequence();
        test_back_to_back_runs();

        // Padding extension. test_regression_full_k runs first so a broken base
        // case is named as such before any K_real < N result is interpreted.
        test_regression_full_k();
        test_pad_mask_values();
        test_pad_mask_stability();
        test_pad_addressing_unaffected();
        test_k_real_boundary_values();
        test_k_real_invalid();

        report();
        $finish;
    end

endmodule
