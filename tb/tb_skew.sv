// -----------------------------------------------------------------------------
// tb_skew.sv -- self-checking testbench for skew_buffer.sv
//
// Golden model: a per-lane delay predictor. Every value driven with valid high
// is tagged {value, entry_cycle} and pushed into a per-lane queue; when it
// emerges the TB pops it and confirms it came out with the right value on cycle
// entry_cycle + expected_delay(k). Early, late, missing and spurious all fail.
//
// Timing: drive on the negedge, sample in the setup window 1 ns BEFORE the next
// posedge. Sampling before the edge is required, not stylistic -- a delay-0 lane
// is combinational, so it presents its value in the same cycle it was driven and
// a delay-1 lane one cycle later. After the posedge both show the same drive and
// the two are indistinguishable; the setup window is the only point where 0 and
// 1 cycles of delay differ, which is the whole point of this DUT.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module skew_harness #(
    parameter int    N   = 4,
    parameter int    DW  = 8,
    parameter string TAG = ""
) (
    input logic clk
);

    localparam time TCLK   = 10ns;
    localparam time SETTLE = 1ns;
    localparam int  SKEW   = 0, DESKEW = 1, RT = 2;   // which path a test drives

    logic          rst_n;
    logic [DW-1:0] a_d [0:N-1];  logic a_v [0:N-1];   // stimulus: skew + roundtrip
    logic [DW-1:0] b_d [0:N-1];  logic b_v [0:N-1];   // stimulus: deskew
    logic [DW-1:0] sk_d[0:N-1];  logic sk_v[0:N-1];
    logic [DW-1:0] ds_d[0:N-1];  logic ds_v[0:N-1];
    logic [DW-1:0] rt_d[0:N-1];  logic rt_v[0:N-1];

    // u_skew doubles as the first half of the round-trip chain, so the same
    // REVERSE=0 instance is verified standalone and in the chain.
    skew_buffer #(.N(N), .DW(DW), .REVERSE(0)) u_skew
        (.clk, .rst_n, .data_in(a_d),  .valid_in(a_v),  .data_out(sk_d), .valid_out(sk_v));
    skew_buffer #(.N(N), .DW(DW), .REVERSE(1)) u_deskew
        (.clk, .rst_n, .data_in(b_d),  .valid_in(b_v),  .data_out(ds_d), .valid_out(ds_v));
    skew_buffer #(.N(N), .DW(DW), .REVERSE(1)) u_chain
        (.clk, .rst_n, .data_in(sk_d), .valid_in(sk_v), .data_out(rt_d), .valid_out(rt_v));

    // ------------------------------------------------------------------ model
    typedef struct { logic [DW-1:0] val; int cyc; } evt_t;

    evt_t exp_q [0:N-1][$];
    int   cyc;
    int   last_cyc [0:N-1];              // cycle of the most recent valid_out[k]

    function automatic int expected_delay(input int k, input bit reverse, input int n);
        return reverse ? (n - 1 - k) : k;
    endfunction

    // Round trip is the sum of both directions: k + (N-1-k) = N-1 on every lane.
    function automatic int mode_delay(input int mode, input int k);
        case (mode)
            SKEW:    return expected_delay(k, 1'b0, N);
            DESKEW:  return expected_delay(k, 1'b1, N);
            default: return expected_delay(k, 1'b0, N) + expected_delay(k, 1'b1, N);
        endcase
    endfunction

    // ------------------------------------------------------------- scoreboard
    string test_order[$];
    int    pass_cnt[string], fail_cnt[string];
    int    lane_pass[0:N-1], lane_fail[0:N-1];
    int    total_pass, total_fail;

    initial begin total_pass = 0; total_fail = 0; end

    function automatic string begin_test(input string base);
        string name = {TAG, base};
        test_order.push_back(name);
        pass_cnt[name] = 0;  fail_cnt[name] = 0;
        for (int k = 0; k < N; k++) begin lane_pass[k] = 0; lane_fail[k] = 0; end
        $display("---- %s ----", name);
        return name;
    endfunction

    task automatic score(input string tname, input int lane, input bit ok);
        if (ok) begin pass_cnt[tname]++; total_pass++; if (lane >= 0) lane_pass[lane]++; end
        else    begin fail_cnt[tname]++; total_fail++; if (lane >= 0) lane_fail[lane]++; end
    endtask

    task automatic check(input string tname, input int lane,
                         input int got, input int exp, input string note);
        score(tname, lane, (got === exp));
        if (got !== exp)
            $display("[FAIL] %s: lane %0d %s expected=%0d got=%0d at cycle %0d",
                     tname, lane, note, exp, got, cyc);
    endtask

    // Per-lane breakdown, so one bad lane names itself instead of hiding in a total.
    task automatic end_test(input string tname);
        string s = "     per-lane pass/fail:";
        for (int k = 0; k < N; k++)
            s = {s, $sformatf(" [%0d]=%0d/%0d", k, lane_pass[k], lane_fail[k])};
        $display("%s", s);
    endtask

    // --------------------------------------------------------------- stimulus
    function automatic void mk_ramp(output logic [DW-1:0] d [0:N-1]);
        for (int k = 0; k < N; k++) d[k] = DW'(k + 1);
    endfunction
    // Junk is deliberately non-zero: leaked data must not hide behind a zero payload.
    function automatic void mk_junk(output logic [DW-1:0] d [0:N-1]);
        for (int k = 0; k < N; k++) d[k] = DW'($urandom_range(1, (1 << DW) - 1));
    endfunction
    function automatic void set_v(input bit x, output logic v [0:N-1]);
        for (int k = 0; k < N; k++) v[k] = x;
    endfunction

    // ----------------------------------------------------------------- engine
    // One cycle: drive, predict, sample in the setup window, check.
    task automatic step(input string tname, input int mode,
                        input logic [DW-1:0] d [0:N-1], input logic v [0:N-1]);
        logic [DW-1:0] od [0:N-1];
        logic          ov [0:N-1];
        evt_t          e;

        @(negedge clk);
        if (mode == DESKEW) begin b_d = d; b_v = v; end
        else                begin a_d = d; a_v = v; end

        for (int k = 0; k < N; k++)
            if (v[k] === 1'b1) begin
                e.val = d[k];  e.cyc = cyc + mode_delay(mode, k);
                exp_q[k].push_back(e);
            end

        #(TCLK/2 - SETTLE);                       // setup window, before the posedge
        case (mode)
            SKEW:    begin od = sk_d; ov = sk_v; end
            DESKEW:  begin od = ds_d; ov = ds_v; end
            default: begin od = rt_d; ov = rt_v; end
        endcase

        for (int k = 0; k < N; k++) begin
            // An X on either output is a failure in its own right -- it would
            // otherwise slip past the === comparisons below as "not equal".
            if ($isunknown({ov[k], od[k]})) begin
                score(tname, k, 1'b0);
                $display("[FAIL] %s: lane %0d X/Z on outputs (valid=%b data=%0h) at cycle %0d",
                         tname, k, ov[k], od[k], cyc);
            end

            if (ov[k] === 1'b1) begin
                last_cyc[k] = cyc;
                if (exp_q[k].size() == 0) begin   // junk got validated
                    score(tname, k, 1'b0);
                    $display("[FAIL] %s: lane %0d spurious valid_out data=%0d at cycle %0d",
                             tname, k, od[k], cyc);
                end else begin
                    e = exp_q[k].pop_front();
                    // Cycle and value scored separately: a value can be both
                    // late and wrong, and each says something different.
                    score(tname, k, (e.cyc == cyc));
                    if (e.cyc != cyc)
                        $display("[FAIL] %s: lane %0d value=%0d expected_cycle=%0d got_cycle=%0d",
                                 tname, k, e.val, e.cyc, cyc);
                    score(tname, k, (od[k] === e.val));
                    if (od[k] !== e.val)
                        $display("[FAIL] %s: lane %0d data expected=%0d got=%0d at cycle %0d",
                                 tname, k, e.val, od[k], cyc);
                end
            end else if (exp_q[k].size() > 0 && exp_q[k][0].cyc == cyc) begin
                // Due now but no tag: valid was dropped, or delayed by a
                // different number of stages than its data.
                score(tname, k, 1'b0);
                $display("[FAIL] %s: lane %0d value=%0d expected_cycle=%0d got_cycle=%0d",
                         tname, k, exp_q[k][0].val, exp_q[k][0].cyc, -1);
                void'(exp_q[k].pop_front());
            end
        end
        cyc++;
    endtask

    // Idle cycles with junk on the bus, to walk the pipeline empty.
    task automatic drain(input string tname, input int mode, input int n_cyc);
        logic [DW-1:0] d [0:N-1];  logic v [0:N-1];
        set_v(1'b0, v);
        for (int i = 0; i < n_cyc; i++) begin mk_junk(d); step(tname, mode, d, v); end
    endtask

    task automatic check_drained(input string tname);
        for (int k = 0; k < N; k++)
            check(tname, k, exp_q[k].size(), 0, "values still stuck in the pipe");
    endtask

    // Reset also clears the reference model, so no state leaks between tests.
    task automatic do_reset();
        @(negedge clk);
        rst_n = 1'b0;
        for (int k = 0; k < N; k++) begin
            a_d[k] = '0; a_v[k] = 1'b0; b_d[k] = '0; b_v[k] = 1'b0;
        end
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        for (int k = 0; k < N; k++) begin exp_q[k].delete(); last_cyc[k] = -1; end
        cyc = 0;
    endtask

    // ====================================================================== tests

    // Sanity-checks the reference model itself -- the only hardcoded cycles here.
    task automatic test_delay_model();
        string tn = begin_test("test_delay_model");
        int sum_fwd = 0, sum_rev = 0;
        for (int k = 0; k < N; k++) begin
            check(tn, k, expected_delay(k, 1'b0, N), k,         "skew delay");
            check(tn, k, expected_delay(k, 1'b1, N), N - 1 - k, "deskew delay");
            check(tn, k, mode_delay(RT, k),          N - 1,     "roundtrip delay");
            sum_fwd += expected_delay(k, 1'b0, N);
            sum_rev += expected_delay(k, 1'b1, N);
        end
        // Both directions are the same triangle.
        check(tn, -1, sum_fwd, (N * (N - 1)) / 2, "skew delays sum to the triangle");
        check(tn, -1, sum_rev, (N * (N - 1)) / 2, "deskew delays sum to the triangle");
        end_test(tn);
    endtask

    // Catches: wrong chain length, off-by-one in the lane index, pattern not from N.
    task automatic test_skew_pattern();
        string tn = begin_test("test_skew_pattern");
        logic [DW-1:0] d [0:N-1];  logic v [0:N-1];
        do_reset();
        mk_ramp(d); set_v(1'b1, v);
        step(tn, SKEW, d, v);                    // one cycle, all lanes valid
        drain(tn, SKEW, N + 2);
        check_drained(tn);
        for (int k = 1; k < N; k++)              // descending staircase
            check(tn, k, last_cyc[k] - last_cyc[k-1], 1, "staircase step");
        end_test(tn);
    endtask

    // Catches: REVERSE ignored, or a mirror computed as something other than N-1-k.
    task automatic test_deskew_pattern();
        string tn = begin_test("test_deskew_pattern");
        logic [DW-1:0] d [0:N-1];  logic v [0:N-1];
        do_reset();
        mk_ramp(d); set_v(1'b1, v);
        step(tn, DESKEW, d, v);
        drain(tn, DESKEW, N + 2);
        check_drained(tn);
        for (int k = 1; k < N; k++)              // mirrored staircase
            check(tn, k, last_cyc[k] - last_cyc[k-1], -1, "mirrored staircase step");
        end_test(tn);
    endtask

    // PRIORITY. Catches: valid delayed by a different amount than its data, or not
    // at all. Data is non-zero on invalid cycles too, so junk is indistinguishable
    // from payload unless the tag really travels with its value. A design that
    // delays data but not valid asserts against a queue head that is not due yet
    // and fails the cycle check; one that delays valid but not data fails the
    // value check.
    task automatic test_valid_tracking();
        string tn = begin_test("test_valid_tracking");
        logic [DW-1:0] d [0:N-1];  logic v [0:N-1];
        for (int mode = SKEW; mode <= DESKEW; mode++) begin
            do_reset();
            for (int t = 0; t < 24; t++) begin
                mk_junk(d);
                for (int k = 0; k < N; k++) v[k] = $urandom_range(0, 1);
                step(tn, mode, d, v);            // lanes gate independently
            end
            drain(tn, mode, N + 2);
            check_drained(tn);
        end
        end_test(tn);
    endtask

    // PRIORITY. Skew -> de-skew must be a pure N-1 pipeline on every lane, fully
    // aligned. Strongest single test -- but a bug symmetric in both directions
    // cancels here, which is why the two single-mode tests above stay.
    task automatic test_roundtrip();
        string tn = begin_test("test_roundtrip");
        logic [DW-1:0] d [0:N-1];  logic v [0:N-1];

        do_reset();
        mk_ramp(d); set_v(1'b1, v);
        step(tn, RT, d, v);
        drain(tn, RT, 2*N + 2);
        check_drained(tn);
        for (int k = 1; k < N; k++)              // every lane on the same cycle
            check(tn, k, last_cyc[k], last_cyc[0], "roundtrip output alignment");

        do_reset();                              // then a gapless stream
        for (int t = 0; t < 20; t++) begin
            mk_junk(d); set_v(1'b1, v);
            step(tn, RT, d, v);
        end
        drain(tn, RT, 2*N + 2);
        check_drained(tn);

        do_reset();                              // and an intermittent one
        for (int t = 0; t < 20; t++) begin
            mk_junk(d);
            for (int k = 0; k < N; k++) v[k] = $urandom_range(0, 1);
            step(tn, RT, d, v);
        end
        drain(tn, RT, 2*N + 2);
        check_drained(tn);
        end_test(tn);
    endtask

    // Catches: stages that do not clear, reset losing to incoming data, and stale
    // in-flight values surviving to the output.
    //
    // Reset is asserted with the chain full AND with non-zero junk driven at
    // valid_in=1 throughout, so reset has to beat live traffic, not just idle
    // wires. The delay-0 lane is a combinational pass-through by design, so it
    // still mirrors its input during reset -- that lane is checked against the
    // input and the registered lanes are the ones checked for a hard zero.
    task automatic test_reset();
        string tn = begin_test("test_reset");
        logic [DW-1:0] d [0:N-1];  logic v [0:N-1];

        do_reset();
        for (int t = 0; t < N; t++) begin        // fill the chain
            mk_junk(d); set_v(1'b1, v);
            step(tn, SKEW, d, v);
        end

        @(negedge clk);                          // yank reset mid-stream
        rst_n = 1'b0;
        mk_junk(d); set_v(1'b1, v);              // junk, and claiming to be valid
        a_d = d;  a_v = v;
        for (int k = 0; k < N; k++) exp_q[k].delete();   // in-flight values are void

        @(posedge clk);

        repeat (2) begin
            #(TCLK/2 - SETTLE);
            for (int k = 0; k < N; k++) begin
                if (expected_delay(k, 1'b0, N) != 0) begin
                    check(tn, k, int'(sk_v[k]), 0, "valid_out during reset");
                    check(tn, k, int'(sk_d[k]), 0, "registered lane must flush to 0");
                end else begin
                    check(tn, k, int'(sk_v[k]), int'(v[k]), "delay-0 lane passes valid through");
                    check(tn, k, int'(sk_d[k]), int'(d[k]), "delay-0 lane passes data through");
                end
            end
            @(negedge clk);
            mk_junk(d);                          // fresh junk every reset cycle
            a_d = d;
        end

        rst_n = 1'b1;
        for (int k = 0; k < N; k++) begin a_d[k] = '0; a_v[k] = 1'b0; end
        cyc = 0;

        // Nothing captured during reset may surface now: any survivor fires as a
        // spurious valid, and any X shows up in step()'s X check.
        drain(tn, SKEW, N + 2);
        check_drained(tn);

        // And the buffer still works afterwards.
        mk_ramp(d); set_v(1'b1, v);
        step(tn, SKEW, d, v);
        drain(tn, SKEW, N + 2);
        check_drained(tn);
        for (int k = 1; k < N; k++)
            check(tn, k, last_cyc[k] - last_cyc[k-1], 1, "staircase intact after reset");
        end_test(tn);
    endtask

    // Catches: gaps that collapse or shift -- e.g. a chain that stalls on invalid
    // cycles instead of shifting the bubble through, so values bunch up.
    task automatic test_bubbles();
        string tn = begin_test("test_bubbles");
        logic [DW-1:0] d [0:N-1];  logic v [0:N-1];
        for (int mode = SKEW; mode <= DESKEW; mode++) begin
            do_reset();
            for (int t = 0; t < 16; t++) begin   // valid, invalid, valid, ...
                mk_junk(d); set_v((t % 2 == 0), v);
                step(tn, mode, d, v);
            end
            drain(tn, mode, N + 2);
            check_drained(tn);

            // A gap longer than the chain, then a burst: the pipe must restart
            // cleanly rather than emit whatever it was holding.
            for (int burst = 0; burst < 2; burst++) begin
                for (int t = 0; t < 3; t++) begin
                    mk_junk(d); set_v(1'b1, v);
                    step(tn, mode, d, v);
                end
                drain(tn, mode, N + 4);
                check_drained(tn);
            end

            // One lone value on one lane at a time: no cross-lane coupling.
            for (int k = 0; k < N; k++) begin
                mk_junk(d);
                set_v(1'b0, v);  v[k] = 1'b1;
                step(tn, mode, d, v);
                drain(tn, mode, N + 2);
                check_drained(tn);
            end
        end
        end_test(tn);
    endtask

    task automatic run_all();
        test_delay_model();  test_skew_pattern();  test_deskew_pattern();
        test_valid_tracking();  test_roundtrip();  test_reset();  test_bubbles();
    endtask

endmodule


// =============================================================================
// tb_skew -- top level. The N=2 harness is test_scaling: the whole suite runs
// again against a second elaboration, so a delay pattern hardcoded for N=4
// cannot survive it.
// =============================================================================
module tb_skew;

    localparam time TCLK = 10ns;
    localparam int  SEED = 32'h5EED_5CE1;        // fixed -> reproducible

    logic clk;
    int   total_pass, total_fail;

    skew_harness #(.N(4), .DW(8), .TAG(""))            h4 (.clk(clk));
    skew_harness #(.N(2), .DW(8), .TAG("scaling_N2/")) h2 (.clk(clk));

    initial begin clk = 1'b0; forever #(TCLK/2) clk = ~clk; end

    initial begin $dumpfile("tb_skew.vcd"); $dumpvars(0, tb_skew); end

    initial begin #500000; $error("TIMEOUT"); $finish; end

    `define SKEW_ROLL_UP(H)                                                   \
        foreach (H.test_order[i]) begin                                       \
            t = H.test_order[i];                                              \
            $display(" %-26s %8d %8d   %s", t, H.pass_cnt[t], H.fail_cnt[t],  \
                     (H.fail_cnt[t] == 0) ? "PASS" : "FAIL");                 \
            if (H.fail_cnt[t] != 0) failing.push_back(t);                     \
        end                                                                   \
        total_pass += H.total_pass;  total_fail += H.total_fail;

    task automatic report();
        string failing[$];
        string t;
        total_pass = 0;  total_fail = 0;

        $display("\n=============================================================");
        $display(" SKEW BUFFER TESTBENCH SUMMARY");
        $display("=============================================================");
        $display(" %-26s %8s %8s   %s", "TASK", "PASS", "FAIL", "STATUS");
        $display("-------------------------------------------------------------");
        `SKEW_ROLL_UP(h4)
        `SKEW_ROLL_UP(h2)
        $display("-------------------------------------------------------------");
        $display(" %-26s %8d %8d", "TOTAL", total_pass, total_fail);
        $display("=============================================================\n");

        if (total_fail == 0) $display("=== SKEW BUFFER PASSED ===");
        else begin
            $display("=== SKEW BUFFER FAILED ===");
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
        h2.run_all();

        report();
        $finish;
    end

endmodule
