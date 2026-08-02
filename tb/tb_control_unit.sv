// -----------------------------------------------------------------------------
// tb_control_unit.sv -- self-checking testbench for control_unit.sv
//
// No datapath here, only phase sequencing and timing, so the golden model is a
// reference state/timing machine rather than an arithmetic one. address_gen and
// the array are NOT instantiated: the TB drives `addr_done` and
// `array_last_valid` itself, standing in for both.
//
// The reference FSM below consumes the SAME start / addr_done / array_last_valid
// stimulus as the DUT, one cycle at a time, and every single step() compares
// phase, wload and done against it. There are no per-task hardcoded expectations
// -- a task that wants to prove something extra (a boundary, a cycle count) adds
// a check on top of the continuous comparison, it does not replace it.
//
// Timing convention: drive on the negedge, sample in the setup window 1 ns
// before the following posedge. The DUT's outputs are Moore -- decoded from the
// state register and, for wload, registered -- so they are stable across the
// whole cycle; sampling before the edge keeps the observed value paired with the
// stimulus that produced it.
//
// -----------------------------------------------------------------------------
// THE TWO PROPERTIES THAT MATTER
// -----------------------------------------------------------------------------
// 1. wload is offset one cycle later than phase == PH_LOAD, and lasts exactly N
//    cycles. Off by one and the array loads B shifted by a row, producing a
//    complete, plausible, wrong C. Checked at the exact cycle boundaries by
//    test_wload_one_cycle_offset, and independently by counting wload-high
//    cycles across a realistic run.
//
// 2. DRAIN exits on data, not on a cycle count. test_drain_waits_for_last_valid
//    holds array_last_valid low for many cycles and then delivers the pulses
//    with irregular gaps -- a secretly-counting FSM cannot survive that.
//
// -----------------------------------------------------------------------------
// NOTE ON THE wload RULE IN THE REFERENCE MODEL
// -----------------------------------------------------------------------------
// The prompt's sketch says "wload = phase delayed by one cycle == PH_LOAD". Taken
// literally that contradicts the other stated requirement, "wload is asserted for
// exactly N cycles": phase == PH_LOAD spans N+1 cycles (N address-issuing cycles
// plus the cycle in which the last weight row is actually delivered), so a pure
// delayed copy would be N+1 cycles long and would still be high on COMPUTE's
// first cycle.
//
// The reference below therefore encodes the requirement that is checkable and
// physically meaningful: wload is high exactly on the cycles when weight data is
// on the bus -- one cycle after each address is issued -- which is a delayed copy
// of "address_gen is still issuing", i.e. (phase == PH_LOAD) && !addr_done.
// That gives exactly N cycles and deasserts as LOAD ends.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_control_unit;

    // ---------------------------------------------------------------------
    // Parameters / infrastructure
    // ---------------------------------------------------------------------
    localparam int  N   = 4;
    localparam int  LVC = N;         // must match control_unit's LAST_VALID_CNT

    localparam time TCLK   = 10ns;
    localparam time SETTLE = 1ns;

    localparam logic [1:0] PH_IDLE    = 2'd0;
    localparam logic [1:0] PH_LOAD    = 2'd1;
    localparam logic [1:0] PH_COMPUTE = 2'd2;
    localparam logic [1:0] PH_DRAIN   = 2'd3;

    logic       clk;
    logic       rst_n;
    logic       start;
    logic       addr_done;
    logic       array_last_valid;
    logic [1:0] phase;
    logic       wload;
    logic       done;

    control_unit #(.N(N), .LAST_VALID_CNT(LVC)) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .addr_done        (addr_done),
        .array_last_valid (array_last_valid),
        .phase            (phase),
        .wload            (wload),
        .done             (done)
    );

    initial begin clk = 1'b0; forever #(TCLK/2) clk = ~clk; end

    initial begin $dumpfile("tb_control_unit.vcd"); $dumpvars(0, tb_control_unit); end

    initial begin #500000; $error("TIMEOUT"); $finish; end

    // ---------------------------------------------------------------------
    // GOLDEN MODEL -- a reference FSM in behavioural code, stepped by the same
    // stimulus as the DUT. r_state / r_wload always hold the values expected for
    // the CURRENT cycle; ref_update() models the posedge that ends it.
    // ---------------------------------------------------------------------
    typedef enum int { R_IDLE, R_LOAD, R_COMPUTE, R_DRAIN, R_DONE } rstate_e;

    rstate_e r_state;
    bit      r_wload;
    int      r_lv_cnt;
    int      cyc;
    int      wload_cycles;      // wload-high cycles since the last run started

    function automatic logic [1:0] ref_phase();
        case (r_state)
            R_LOAD:    return PH_LOAD;
            R_COMPUTE: return PH_COMPUTE;
            R_DRAIN:   return PH_DRAIN;
            default:   return PH_IDLE;      // R_IDLE, R_DONE
        endcase
    endfunction

    function automatic void ref_reset();
        r_state  = R_IDLE;
        r_wload  = 1'b0;
        r_lv_cnt = 0;
    endfunction

    function automatic void ref_update(input bit st, input bit ad, input bit lv);
        rstate_e ns;
        bit      next_wload;

        ns = r_state;
        case (r_state)
            R_IDLE:    if (st) ns = R_LOAD;
            R_LOAD:    if (ad) ns = R_COMPUTE;
            R_COMPUTE: if (ad) ns = R_DRAIN;
            R_DRAIN:   if (lv && (r_lv_cnt == LVC-1)) ns = R_DONE;
            R_DONE:    if (st) ns = R_LOAD;
            default:   ns = R_IDLE;
        endcase

        // Result-row counter: armed on every entry to DRAIN.
        if (r_state != R_DRAIN)  r_lv_cnt = 0;
        else if (lv)             r_lv_cnt = r_lv_cnt + 1;

        // wload for the NEXT cycle: high one cycle after each weight address is
        // issued, which is exactly when that row's data is on the bus.
        next_wload = (r_state == R_LOAD) && !ad;

        r_state = ns;
        r_wload = next_wload;
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

    // One cycle: drive the stimulus, compare all three outputs against the
    // reference, then advance the reference across the posedge.
    task automatic step(input string tname, input bit st, input bit ad, input bit lv,
                        input string note);
        @(negedge clk);
        start            = st;
        addr_done        = ad;
        array_last_valid = lv;

        #(TCLK/2 - SETTLE);
        check(tname, cyc, int'(phase), int'(ref_phase()),           {note, " phase"});
        check(tname, cyc, int'(wload), int'(r_wload),               {note, " wload"});
        check(tname, cyc, int'(done),  int'(r_state == R_DONE),     {note, " done"});

        if (wload === 1'b1) wload_cycles++;
        ref_update(st, ad, lv);
        cyc++;
    endtask

    // Convenience: an idle cycle with nothing asserted.
    task automatic idle(input string tname, input string note);
        step(tname, 1'b0, 1'b0, 1'b0, note);
    endtask

    task automatic do_reset();
        @(negedge clk);
        rst_n            = 1'b0;
        start            = 1'b0;
        addr_done        = 1'b0;
        array_last_valid = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        ref_reset();
        cyc          = 0;
        wload_cycles = 0;
    endtask

    // ---------------------------------------------------------------------
    // Sequence helpers, all built on step() so the continuous comparison
    // applies to every cycle they drive.
    // ---------------------------------------------------------------------

    // Pulse start from IDLE/DONE. After this returns, the next step() is LOAD
    // cycle 0.
    task automatic pulse_start(input string tname);
        step(tname, 1'b1, 1'b0, 1'b0, "start pulse");
        wload_cycles = 0;                       // count wload per run
    endtask

    // Drive a LOAD phase `len` cycles long, asserting addr_done on the last one
    // (which is how address_gen behaves: N issuing cycles, then addr_done on the
    // extra cycle where the final weight row lands, so len = N+1 is realistic).
    task automatic drive_load(input string tname, input int len);
        for (int i = 0; i < len; i++)
            step(tname, 1'b0, (i == len-1), 1'b0, $sformatf("LOAD cycle %0d", i));
    endtask

    task automatic drive_compute(input string tname, input int len);
        for (int i = 0; i < len; i++)
            step(tname, 1'b0, (i == len-1), 1'b0, $sformatf("COMPUTE cycle %0d", i));
    endtask

    // Sit in DRAIN for `lead` quiet cycles, then deliver LVC result rows with a
    // one-cycle gap between them.
    task automatic drive_drain(input string tname, input int lead);
        for (int i = 0; i < lead; i++)
            step(tname, 1'b0, 1'b0, 1'b0, $sformatf("DRAIN quiet cycle %0d", i));
        for (int r = 0; r < LVC; r++) begin
            step(tname, 1'b0, 1'b0, 1'b1, $sformatf("DRAIN result row %0d", r));
            if (r != LVC-1)
                step(tname, 1'b0, 1'b0, 1'b0, $sformatf("DRAIN gap after row %0d", r));
        end
    endtask

    // A complete, realistic run.
    task automatic full_run(input string tname, input int load_len,
                            input int compute_len, input int drain_lead);
        pulse_start(tname);
        drive_load(tname, load_len);
        drive_compute(tname, compute_len);
        drive_drain(tname, drain_lead);
        idle(tname, "first cycle in DONE");
    endtask

    // =====================================================================
    // TEST TASKS
    // =====================================================================

    // Reset must win from any state, not just from IDLE. Taken from LOAD,
    // COMPUTE and DRAIN in turn, each with real in-flight state to lose.
    task automatic test_reset_state();
        string tn = begin_test("test_reset_state");

        for (int from = 0; from < 3; from++) begin
            do_reset();
            pulse_start(tn);
            drive_load(tn, (from == 0) ? 2 : N+1);          // stop inside LOAD, or finish it
            if (from >= 1) drive_compute(tn, (from == 1) ? 2 : N+1);
            if (from >= 2) step(tn, 1'b0, 1'b0, 1'b0, "inside DRAIN");

            // Confirm we really are where we think we are before resetting.
            check(tn, cyc, int'(phase),
                  int'((from == 0) ? PH_LOAD : (from == 1) ? PH_COMPUTE : PH_DRAIN),
                  "phase before reset");

            // Synchronous reset: applied at this negedge, visible after the
            // posedge that ends the cycle.
            @(negedge clk);
            rst_n            = 1'b0;
            start            = 1'b0;
            addr_done        = 1'b0;
            array_last_valid = 1'b0;
            @(negedge clk);
            #(TCLK/2 - SETTLE);
            check(tn, cyc, int'(phase), int'(PH_IDLE), "phase after reset");
            check(tn, cyc, int'(wload), 0,             "wload after reset");
            check(tn, cyc, int'(done),  0,             "done after reset");

            @(negedge clk);
            rst_n = 1'b1;
            @(negedge clk);
            ref_reset();
            wload_cycles = 0;

            // And it is genuinely usable afterwards, not merely quiet.
            idle(tn, "idle after reset release");
            check(tn, cyc, int'(phase), int'(PH_IDLE), "still idle without start");
        end
    endtask

    // Entry into LOAD, and the first half of the offset rule: phase must be
    // PH_LOAD while wload is still LOW on that very cycle.
    task automatic test_idle_to_load();
        string tn = begin_test("test_idle_to_load");
        do_reset();

        idle(tn, "idle before start");
        check(tn, cyc, int'(phase), int'(PH_IDLE), "phase stays IDLE without start");

        pulse_start(tn);

        step(tn, 1'b0, 1'b0, 1'b0, "LOAD cycle 0");
        check(tn, cyc, int'(phase), int'(PH_LOAD), "phase is LOAD one cycle after start");
        check(tn, cyc, int'(wload), 0,             "wload still LOW on LOAD cycle 0");
    endtask

    // PRIORITY. The exact cycle boundaries of the offset, in both directions,
    // plus an independent count of the assertion length.
    //
    // An off-by-one here loads B shifted by one row and still produces a full,
    // structurally plausible result matrix, so "eventually becomes 1" is not an
    // acceptable check -- both the not-yet cycle and the now cycle are named.
    task automatic test_wload_one_cycle_offset();
        string tn = begin_test("test_wload_one_cycle_offset");
        do_reset();
        pulse_start(tn);

        // --- rising edge of wload ---------------------------------------
        step(tn, 1'b0, 1'b0, 1'b0, "LOAD cycle 0");
        check(tn, cyc, int'(phase), int'(PH_LOAD), "LOAD cycle 0 phase");
        check(tn, cyc, int'(wload), 0,             "wload NOT yet asserted on LOAD cycle 0");

        step(tn, 1'b0, 1'b0, 1'b0, "LOAD cycle 1");
        check(tn, cyc, int'(phase), int'(PH_LOAD), "LOAD cycle 1 phase");
        check(tn, cyc, int'(wload), 1,             "wload asserted on LOAD cycle 1");

        // --- middle of the load pass -------------------------------------
        for (int i = 2; i < N; i++) begin
            step(tn, 1'b0, 1'b0, 1'b0, $sformatf("LOAD cycle %0d", i));
            check(tn, cyc, int'(wload), 1, "wload held through the load pass");
        end

        // --- falling edge: addr_done on LOAD cycle N ---------------------
        // The final weight row is delivered on this cycle, so wload must still
        // be high here and drop on the next.
        step(tn, 1'b0, 1'b1, 1'b0, "LOAD cycle N, addr_done");
        check(tn, cyc, int'(phase), int'(PH_LOAD), "still LOAD on the addr_done cycle");
        check(tn, cyc, int'(wload), 1,             "wload still high when the last row lands");

        step(tn, 1'b0, 1'b0, 1'b0, "first COMPUTE cycle");
        check(tn, cyc, int'(phase), int'(PH_COMPUTE), "phase moved to COMPUTE");
        check(tn, cyc, int'(wload), 0,               "wload deasserted entering COMPUTE");

        // --- independent length check ------------------------------------
        // Counted directly, not derived from the reference model.
        check(tn, cyc, wload_cycles, N, "wload asserted for exactly N cycles");

        // And it stays low for the rest of the run.
        for (int i = 0; i < N; i++) begin
            step(tn, 1'b0, 1'b0, 1'b0, "later COMPUTE cycle");
            check(tn, cyc, int'(wload), 0, "wload stays low outside LOAD");
        end
    endtask

    // Catches a transition taken a cycle early (while the last address is still
    // being issued) or a state that lingers after addr_done.
    task automatic test_load_to_compute();
        string tn = begin_test("test_load_to_compute");
        do_reset();
        pulse_start(tn);

        // Several LOAD cycles with addr_done low: must not advance.
        for (int i = 0; i < N; i++) begin
            step(tn, 1'b0, 1'b0, 1'b0, $sformatf("LOAD cycle %0d", i));
            check(tn, cyc, int'(phase), int'(PH_LOAD), "must stay in LOAD without addr_done");
        end

        step(tn, 1'b0, 1'b1, 1'b0, "addr_done during LOAD");
        check(tn, cyc, int'(phase), int'(PH_LOAD), "still LOAD on the addr_done cycle itself");

        step(tn, 1'b0, 1'b0, 1'b0, "cycle after addr_done");
        check(tn, cyc, int'(phase), int'(PH_COMPUTE), "COMPUTE on the next cycle");

        step(tn, 1'b0, 1'b0, 1'b0, "second COMPUTE cycle");
        check(tn, cyc, int'(phase), int'(PH_COMPUTE), "does not linger or bounce back");
    endtask

    // Same shape, one phase later.
    task automatic test_compute_to_drain();
        string tn = begin_test("test_compute_to_drain");
        do_reset();
        pulse_start(tn);
        drive_load(tn, N+1);

        for (int i = 0; i < N; i++) begin
            step(tn, 1'b0, 1'b0, 1'b0, $sformatf("COMPUTE cycle %0d", i));
            check(tn, cyc, int'(phase), int'(PH_COMPUTE), "must stay in COMPUTE without addr_done");
        end

        step(tn, 1'b0, 1'b1, 1'b0, "addr_done during COMPUTE");
        check(tn, cyc, int'(phase), int'(PH_COMPUTE), "still COMPUTE on the addr_done cycle");

        step(tn, 1'b0, 1'b0, 1'b0, "cycle after addr_done");
        check(tn, cyc, int'(phase), int'(PH_DRAIN), "DRAIN on the next cycle");
    endtask

    // PRIORITY. Proves DRAIN is data-driven rather than secretly counting
    // cycles. It is held with no results for far longer than any plausible fixed
    // count, and the results then arrive with irregular gaps.
    task automatic test_drain_waits_for_last_valid();
        string tn = begin_test("test_drain_waits_for_last_valid");
        do_reset();
        pulse_start(tn);
        drive_load(tn, N+1);
        drive_compute(tn, N+1);

        // 20 cycles of nothing: a cycle-counting FSM leaves here, a data-driven
        // one does not.
        for (int i = 0; i < 20; i++) begin
            step(tn, 1'b0, 1'b0, 1'b0, $sformatf("DRAIN quiet cycle %0d", i));
            check(tn, cyc, int'(phase), int'(PH_DRAIN), "must stay in DRAIN with no results");
            check(tn, cyc, int'(done),  0,              "done must not assert early");
        end

        // Results arrive with growing gaps; the FSM must still be in DRAIN until
        // the last one.
        for (int r = 0; r < LVC-1; r++) begin
            step(tn, 1'b0, 1'b0, 1'b1, $sformatf("result row %0d", r));
            for (int g = 0; g <= r; g++)
                step(tn, 1'b0, 1'b0, 1'b0, "gap between results");
            check(tn, cyc, int'(phase), int'(PH_DRAIN), "still draining before the last row");
            check(tn, cyc, int'(done),  0,              "done must not assert before the last row");
        end

        // The final row.
        step(tn, 1'b0, 1'b0, 1'b1, "final result row");
        check(tn, cyc, int'(phase), int'(PH_DRAIN), "still DRAIN on the final result cycle");

        step(tn, 1'b0, 1'b0, 1'b0, "cycle after the final result");
        check(tn, cyc, int'(done), 1, "done asserts the cycle after the last result");
    endtask

    // done must be a level an external observer cannot miss, not a pulse.
    task automatic test_done_holds();
        string tn = begin_test("test_done_holds");
        do_reset();
        full_run(tn, N+1, N+1, 3);

        for (int i = 0; i < 12; i++) begin
            idle(tn, $sformatf("holding in DONE, cycle %0d", i));
            check(tn, cyc, int'(done),  1,             "done still high");
            check(tn, cyc, int'(phase), int'(PH_IDLE), "phase idle while done");
            check(tn, cyc, int'(wload), 0,             "wload low while done");
        end
    endtask

    // A start while done is high must clear done and begin a fresh sequence,
    // with the same offset behaviour as the first run.
    task automatic test_done_to_next_start();
        string tn = begin_test("test_done_to_next_start");
        do_reset();
        full_run(tn, N+1, N+1, 3);
        check(tn, cyc, int'(done), 1, "done before the second start");

        pulse_start(tn);

        step(tn, 1'b0, 1'b0, 1'b0, "LOAD cycle 0 of the second run");
        check(tn, cyc, int'(done),  0,             "done cleared by start");
        check(tn, cyc, int'(phase), int'(PH_LOAD), "phase back to LOAD");
        check(tn, cyc, int'(wload), 0,             "wload still offset on the second run");

        step(tn, 1'b0, 1'b0, 1'b0, "LOAD cycle 1 of the second run");
        check(tn, cyc, int'(wload), 1, "wload asserts one cycle later, as before");
    endtask

    // The DUT's documented behaviour is that a start is only acted on in IDLE or
    // DONE. This asserts that concretely -- the FSM must remain in COMPUTE and
    // must NOT jump to LOAD -- so the check genuinely fails if the DUT restarts.
    task automatic test_no_start_during_active_run();
        string tn = begin_test("test_no_start_during_active_run");
        do_reset();
        pulse_start(tn);
        drive_load(tn, N+1);

        // Mid-COMPUTE, with a stray start asserted.
        for (int i = 0; i < 3; i++) begin
            step(tn, 1'b1, 1'b0, 1'b0, $sformatf("stray start during COMPUTE %0d", i));
            check(tn, cyc, int'(phase), int'(PH_COMPUTE), "stray start must not restart the run");
            check(tn, cyc, int'(wload), 0,                "stray start must not re-assert wload");
        end

        // Also mid-DRAIN.
        step(tn, 1'b0, 1'b1, 1'b0, "addr_done ends COMPUTE");
        for (int i = 0; i < 3; i++) begin
            step(tn, 1'b1, 1'b0, 1'b0, $sformatf("stray start during DRAIN %0d", i));
            check(tn, cyc, int'(phase), int'(PH_DRAIN), "stray start must not restart during DRAIN");
        end

        // The run still completes normally afterwards.
        for (int r = 0; r < LVC; r++)
            step(tn, 1'b0, 1'b0, 1'b1, $sformatf("result row %0d", r));
        idle(tn, "after the run completes");
        check(tn, cyc, int'(done), 1, "run still completes after the stray starts");
    endtask

    // A complete realistic run with irregular waits everywhere. Every cycle is
    // compared against the reference by step(), so this is a full trace match,
    // not a check of the transition boundaries alone.
    task automatic test_full_sequence_timing();
        string tn = begin_test("test_full_sequence_timing");
        do_reset();

        idle(tn, "quiet before start");
        idle(tn, "quiet before start");
        full_run(tn, N+1, N+3, 5);          // COMPUTE deliberately longer than N

        check(tn, cyc, wload_cycles, N, "wload asserted for exactly N cycles over the run");
        check(tn, cyc, int'(done),   1, "run finished");
    endtask

    // Two full runs back to back, with different phase lengths, confirming no
    // residue: no stuck wload, no spurious re-entry into LOAD, and the same
    // exact-N assertion length the second time.
    task automatic test_back_to_back_full_runs();
        string tn = begin_test("test_back_to_back_full_runs");
        do_reset();

        full_run(tn, N+1, N+1, 2);
        check(tn, cyc, wload_cycles, N, "run 1: wload exactly N cycles");
        check(tn, cyc, int'(done),   1, "run 1 finished");

        idle(tn, "gap between runs");
        idle(tn, "gap between runs");

        full_run(tn, N+1, N+5, 7);
        check(tn, cyc, wload_cycles, N, "run 2: wload exactly N cycles");
        check(tn, cyc, int'(done),   1, "run 2 finished");

        // A third, immediately after, with no idle gap at all.
        full_run(tn, N+1, N+1, 0);
        check(tn, cyc, wload_cycles, N, "run 3: wload exactly N cycles");
        check(tn, cyc, int'(done),   1, "run 3 finished");
    endtask

    // ---------------------------------------------------------------------
    // Report
    // ---------------------------------------------------------------------
    task automatic report();
        string failing[$];
        string t;

        $display("\n=================================================================");
        $display(" CONTROL UNIT TESTBENCH SUMMARY");
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

        if (total_fail == 0) $display("=== CONTROL UNIT PASSED ===");
        else begin
            $display("=== CONTROL UNIT FAILED ===");
            $display("Failing tasks:");
            foreach (failing[i]) $display("  - %s", failing[i]);
        end
    endtask

    // ---------------------------------------------------------------------
    // Main sequence
    // ---------------------------------------------------------------------
    initial begin
        total_pass = 0;  total_fail = 0;

        rst_n            = 1'b1;
        start            = 1'b0;
        addr_done        = 1'b0;
        array_last_valid = 1'b0;
        ref_reset();
        cyc = 0;  wload_cycles = 0;

        test_reset_state();
        test_idle_to_load();
        test_wload_one_cycle_offset();
        test_load_to_compute();
        test_compute_to_drain();
        test_drain_waits_for_last_valid();
        test_done_holds();
        test_done_to_next_start();
        test_no_start_during_active_run();
        test_full_sequence_timing();
        test_back_to_back_full_runs();

        report();
        $finish;
    end

endmodule
