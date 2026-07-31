// -----------------------------------------------------------------------------
// tb_pe.sv
//
// Self-checking testbench for processing_element.sv (weight-stationary PE).
//
// Timing convention
// -----------------
//   * Stimulus is driven on the NEGEDGE.
//   * Outputs are sampled on the POSEDGE, after a small settle delay (SETTLE)
//     so the NBA region has committed. Driving and sampling are therefore half
//     a cycle apart in both directions and cannot race.
//   * "One cycle later" means: drive at negedge N, the DUT captures at the
//     following posedge, and tick_sample() reads the result just after that
//     same posedge.
//
// Every test task calls do_reset() first so no state leaks between tests.
// Every expected value comes from golden(); nothing is hand-typed except the
// deliberately-chosen stimulus vectors.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_pe;

    // ---------------------------------------------------------------------
    // Parameters / infrastructure
    // ---------------------------------------------------------------------
    localparam int  IN_W    = 8;
    localparam int  ACC_W   = 32;
    localparam time TCLK    = 10ns;     // 10 ns period, 5 ns half period
    localparam time SETTLE  = 1ns;      // post-edge settle before sampling
    localparam int  SEED    = 32'h5EED_1234;

    logic                    clk;
    logic                    rst_n;
    logic                    wload;
    logic                    valid_in;
    logic                    valid_out;
    logic signed [IN_W-1:0]  a_in;
    logic signed [IN_W-1:0]  a_out;
    logic signed [ACC_W-1:0] psum_in;
    logic signed [ACC_W-1:0] psum_out;

    // Score-keeping: per-task counters plus the order tests were run in.
    string test_order[$];
    int    pass_cnt[string];
    int    fail_cnt[string];
    int    total_pass;
    int    total_fail;

    // ---------------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------------
    processing_element #(
        .IN_W  (IN_W),
        .ACC_W (ACC_W)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .wload     (wload),
        .valid_in  (valid_in),
        .valid_out (valid_out),
        .a_in      (a_in),
        .a_out     (a_out),
        .psum_in   (psum_in),
        .psum_out  (psum_out)
    );

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
        $dumpfile("tb_pe.vcd");
        $dumpvars(0, tb_pe);
    end

    // ---------------------------------------------------------------------
    // Watchdog
    // ---------------------------------------------------------------------
    initial begin
        #500000;
        $error("TIMEOUT");
        $finish;
    end

    // ---------------------------------------------------------------------
    // Golden model — the ONLY source of expected MAC values.
    // ---------------------------------------------------------------------
    function automatic logic signed [ACC_W-1:0] golden
    (
        input logic signed [ACC_W-1:0] psum,
        input logic signed [IN_W-1:0]  w,
        input logic signed [IN_W-1:0]  a
    );
        // w and a are context-extended to ACC_W signed before the multiply.
        return psum + (w * a);
    endfunction

    // Sign-extended weight as it should appear on psum_out during a load.
    function automatic logic signed [ACC_W-1:0] sext_w(input logic signed [IN_W-1:0] w);
        return ACC_W'(w);
    endfunction

    // ---------------------------------------------------------------------
    // Book-keeping
    // ---------------------------------------------------------------------
    task automatic begin_test(input string name);
        test_order.push_back(name);
        pass_cnt[name] = 0;
        fail_cnt[name] = 0;
        $display("---- %s ----", name);
    endtask

    task automatic check
    (
        input string                   tname,
        input logic signed [ACC_W-1:0] got,
        input logic signed [ACC_W-1:0] exp,
        input string                   note
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

    // Any X/Z on an output is a failure in its own right.
    task automatic check_no_x(input string tname, input string note);
        // 0 = clean, 1 = at least one output has an X/Z.
        check(tname, ACC_W'($isunknown({a_out, valid_out, psum_out})), '0,
              {note, " (X/Z on outputs)"});
    endtask

    // ---------------------------------------------------------------------
    // Drive / sample primitives
    // ---------------------------------------------------------------------

    // Synchronous active-low reset: hold low across 2 posedges, release,
    // then let one clean cycle pass.
    task automatic do_reset();
        @(negedge clk);
        rst_n    = 1'b0;
        wload    = 1'b0;
        valid_in = 1'b0;
        a_in     = '0;
        psum_in  = '0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
    endtask

    // Load one stationary weight over the shared psum bus.
    // Upper bits of psum_in are filled with garbage on purpose: the DUT must
    // capture psum_in[IN_W-1:0] only.
    task automatic load_weight(input logic signed [IN_W-1:0] w);
        @(negedge clk);
        wload    = 1'b1;
        valid_in = 1'b0;
        psum_in  = {24'hDEAD_BE, w};
        @(negedge clk);          // the capturing posedge happened in between
        wload   = 1'b0;
        psum_in = '0;
    endtask

    // Drive one compute cycle's worth of stimulus.
    task automatic drive_cycle
    (
        input logic                    wl,
        input logic                    v,
        input logic signed [IN_W-1:0]  a,
        input logic signed [ACC_W-1:0] p
    );
        @(negedge clk);
        wload    = wl;
        valid_in = v;
        a_in     = a;
        psum_in  = p;
    endtask

    // Advance to the next posedge and let the NBA updates settle, so the
    // values read afterwards are the ones the DUT just registered.
    task automatic tick_sample();
        @(posedge clk);
        #SETTLE;
    endtask

    // ---------------------------------------------------------------------
    // test_reset
    //   Catches: async reset (reset that takes effect without a clock edge),
    //   registers that fail to clear, and X's escaping past reset release.
    // ---------------------------------------------------------------------
    task automatic test_reset();
        logic signed [IN_W-1:0]  w, a;
        logic signed [ACC_W-1:0] p;

        begin_test("test_reset");
        do_reset();

        // Outputs must be clean and zero immediately after release.
        check_no_x("test_reset", "after reset release");
        check("test_reset", ACC_W'(a_out),     '0, "a_out after reset");
        check("test_reset", ACC_W'(valid_out), '0, "valid_out after reset");
        check("test_reset", psum_out,          '0, "psum_out after reset");

        // Put real state into every register so a working reset has something
        // visible to clear.
        w = 8'sd37;
        a = 8'sd11;
        p = 32'sd12345;
        load_weight(w);
        drive_cycle(1'b0, 1'b1, a, p);
        tick_sample();
        check("test_reset", psum_out, golden(p, w, a), "state primed before reset");
        check("test_reset", ACC_W'(valid_out), 32'd1, "valid_out primed before reset");

        // Assert reset mid-cycle. Because reset is SYNCHRONOUS the outputs must
        // still hold their old values until the next posedge.
        @(negedge clk);
        rst_n    = 1'b0;
        valid_in = 1'b0;
        #SETTLE;
        check("test_reset", psum_out, golden(p, w, a),
              "psum_out must NOT clear before the clock edge (sync reset)");
        check("test_reset", ACC_W'(valid_out), 32'd1,
              "valid_out must NOT clear before the clock edge (sync reset)");

        // Now the edge arrives: everything clears.
        tick_sample();
        check("test_reset", ACC_W'(a_out),     '0, "a_out cleared on reset edge");
        check("test_reset", ACC_W'(valid_out), '0, "valid_out cleared on reset edge");
        check("test_reset", psum_out,          '0, "psum_out cleared on reset edge");
        check_no_x("test_reset", "while held in reset");

        @(negedge clk);
        rst_n = 1'b1;
    endtask

    // ---------------------------------------------------------------------
    // test_weight_load
    //   Catches: capturing more than IN_W bits of psum_in, zero-extending the
    //   weight onto psum_out instead of sign-extending it, and a weight
    //   register that latches only once instead of on every load.
    // ---------------------------------------------------------------------
    task automatic test_weight_load();
        logic signed [IN_W-1:0]  w1, w2;
        logic signed [ACC_W-1:0] p;

        begin_test("test_weight_load");
        do_reset();

        // --- Only psum_in[7:0] may be captured -----------------------------
        // Garbage in [31:8]; if the DUT captured any of it the MAC below breaks.
        w1 = -8'sd5;
        @(negedge clk);
        wload    = 1'b1;
        valid_in = 1'b0;
        psum_in  = {24'hA5A5_A5, w1};   // upper bits are pure noise

        tick_sample();                  // capturing edge: weight_q <= w1

        // --- psum_out must be the SIGN-EXTENDED weight while wload is high --
        // Loading -5 must show 32'hFFFF_FFFB, not 32'h0000_00FB.
        tick_sample();
        check("test_weight_load", psum_out, sext_w(w1),
              $sformatf("psum_out during wload must be sign-extended w=%0d", w1));

        @(negedge clk);
        wload   = 1'b0;
        psum_in = '0;

        // Prove the upper garbage bits never reached weight_q, via a MAC.
        p = 32'sd100;
        drive_cycle(1'b0, 1'b1, 8'sd7, p);
        tick_sample();
        check("test_weight_load", psum_out, golden(p, w1, 8'sd7),
              "weight_q must ignore psum_in[31:8]");

        // --- A second load overwrites the first -----------------------------
        w2 = 8'sd42;
        load_weight(w2);
        drive_cycle(1'b0, 1'b1, 8'sd7, p);
        tick_sample();
        check("test_weight_load", psum_out, golden(p, w2, 8'sd7),
              "second weight must overwrite the first");

        // Positive weight must sign-extend to zeros in the upper half.
        @(negedge clk);
        wload   = 1'b1;
        psum_in = {24'h0000_00, w2};
        tick_sample();
        tick_sample();
        check("test_weight_load", psum_out, sext_w(w2),
              $sformatf("psum_out during wload, positive w=%0d", w2));
        @(negedge clk);
        wload   = 1'b0;
        psum_in = '0;
    endtask

    // ---------------------------------------------------------------------
    // test_stationarity
    //   Catches: a weight register that is disturbed by compute traffic on the
    //   shared psum bus (i.e. loads whenever psum_in changes, not only on wload).
    // ---------------------------------------------------------------------
    task automatic test_stationarity();
        logic signed [IN_W-1:0]  w, a;
        logic signed [ACC_W-1:0] p;

        begin_test("test_stationarity");
        do_reset();

        w = -8'sd23;
        load_weight(w);

        // 20 cycles of varied activations and psums with wload low the whole
        // time. Every result is checked against the ORIGINAL weight.
        for (int i = 0; i < 20; i++) begin
            a = IN_W'($urandom());
            p = ACC_W'($urandom());
            drive_cycle(1'b0, 1'b1, a, p);
            tick_sample();
            check("test_stationarity", psum_out, golden(p, w, a),
                  $sformatf("cycle %0d: weight drifted? w=%0d a=%0d p=%0d", i, w, a, p));
        end
    endtask

    // ---------------------------------------------------------------------
    // test_hop_timing
    //   Catches: a combinational (0-cycle) pass-through of a_in/valid_in, an
    //   extra pipeline stage (2 cycles), and a_out/valid_out skewed apart.
    // ---------------------------------------------------------------------
    task automatic test_hop_timing();
        logic signed [IN_W-1:0] a_old, a_new;

        begin_test("test_hop_timing");
        do_reset();

        // Establish a known a_out / valid_out.
        a_old = 8'sd0;
        drive_cycle(1'b0, 1'b0, a_old, '0);
        tick_sample();

        // Change a_in and valid_in together.
        a_new = -8'sd77;
        drive_cycle(1'b0, 1'b1, a_new, '0);

        // Before the edge: outputs must still show the OLD values.
        // If they already changed, the path is combinational.
        #SETTLE;
        check("test_hop_timing", ACC_W'(a_out), ACC_W'(a_old),
              "a_out changed in the same cycle (combinational path)");
        check("test_hop_timing", ACC_W'(valid_out), '0,
              "valid_out changed in the same cycle (combinational path)");

        // Exactly one cycle later: both must have moved, on the SAME edge.
        tick_sample();
        check("test_hop_timing", ACC_W'(a_out), ACC_W'(a_new),
              "a_out must follow a_in after exactly 1 cycle");
        check("test_hop_timing", ACC_W'(valid_out), 32'd1,
              "valid_out must follow valid_in after exactly 1 cycle");

        // Hold the inputs steady and drop them together; two cycles after the
        // original change the outputs must reflect the newer input, not lag.
        drive_cycle(1'b0, 1'b0, 8'sd0, '0);
        tick_sample();
        check("test_hop_timing", ACC_W'(a_out), '0,
              "a_out lags by more than 1 cycle (extra register)");
        check("test_hop_timing", ACC_W'(valid_out), '0,
              "valid_out lags by more than 1 cycle (extra register)");
    endtask

    // ---------------------------------------------------------------------
    // test_mac
    //   Catches: wrong operand pairing, missing accumulate, unsigned multiply,
    //   and truncation of the product before the add.
    // ---------------------------------------------------------------------
    task automatic test_mac();
        logic signed [IN_W-1:0]  w, a;
        logic signed [ACC_W-1:0] p;

        begin_test("test_mac");
        do_reset();

        for (int i = 0; i < 32; i++) begin
            w = IN_W'($urandom());
            a = IN_W'($urandom());
            // i==0/1 force the top-of-column case (psum_in = 0); the rest are
            // mid-column cases with a non-zero incoming partial sum.
            p = (i < 2) ? '0 : ACC_W'($urandom());

            load_weight(w);
            drive_cycle(1'b0, 1'b1, a, p);
            tick_sample();
            check("test_mac", psum_out, golden(p, w, a),
                  $sformatf("w=%0d a=%0d psum_in=%0d", w, a, p));
        end
    endtask

    // ---------------------------------------------------------------------
    // test_bubble
    //   Catches: an accumulator that ignores valid_in and MACs on every cycle.
    //   a_in is deliberately non-zero junk (8'h7F) — with a non-zero weight
    //   loaded, broken gating produces psum_in + w*127, which cannot alias.
    // ---------------------------------------------------------------------
    task automatic test_bubble();
        logic signed [IN_W-1:0]  w;
        logic signed [ACC_W-1:0] p;

        begin_test("test_bubble");
        do_reset();

        w = -8'sd91;            // non-zero, so a missed gate is always visible
        load_weight(w);

        for (int i = 0; i < 8; i++) begin
            p = (i == 0) ? 32'sd0 : ACC_W'($urandom());
            drive_cycle(1'b0, 1'b0, 8'sh7F, p);   // junk activation, valid low
            tick_sample();
            check("test_bubble", psum_out, p,
                  $sformatf("bubble %0d must pass psum_in through unchanged (a_in=0x7F, w=%0d)",
                            i, w));
        end

        // A valid cycle immediately after the bubbles must still MAC correctly.
        drive_cycle(1'b0, 1'b1, 8'sd6, 32'sd1000);
        tick_sample();
        check("test_bubble", psum_out, golden(32'sd1000, w, 8'sd6),
              "compute must resume correctly after bubbles");
    endtask

    // ---------------------------------------------------------------------
    // test_signed
    //   Catches: unsigned multiply, zero-extension of operands, and a psum
    //   adder that mishandles negative incoming partial sums.
    // ---------------------------------------------------------------------
    task automatic test_signed();
        logic signed [IN_W-1:0]  ws[4];
        logic signed [IN_W-1:0]  as[4];
        logic signed [ACC_W-1:0] p;

        begin_test("test_signed");
        do_reset();

        ws = '{ 8'sd5, -8'sd5,  8'sd5, -8'sd5};
        as = '{ 8'sd3,  8'sd3, -8'sd3, -8'sd3};

        // All four sign combinations with psum_in = 0.
        for (int i = 0; i < 4; i++) begin
            load_weight(ws[i]);
            drive_cycle(1'b0, 1'b1, as[i], '0);
            tick_sample();
            check("test_signed", psum_out, golden('0, ws[i], as[i]),
                  $sformatf("signed combo w=%0d a=%0d", ws[i], as[i]));
        end

        // Same four combinations with a NEGATIVE partial sum flowing through.
        p = -32'sd1_000_000;
        for (int i = 0; i < 4; i++) begin
            load_weight(ws[i]);
            drive_cycle(1'b0, 1'b1, as[i], p);
            tick_sample();
            check("test_signed", psum_out, golden(p, ws[i], as[i]),
                  $sformatf("negative psum_in=%0d w=%0d a=%0d", p, ws[i], as[i]));
        end

        // Negative psum through a bubble must survive intact (no sign damage).
        drive_cycle(1'b0, 1'b0, 8'sd0, p);
        tick_sample();
        check("test_signed", psum_out, p, "negative psum_in through a bubble");
    endtask

    // ---------------------------------------------------------------------
    // test_boundary
    //   Catches: product truncated to 8 or 16 bits, and an accumulator narrower
    //   than ACC_W (upper psum bits dropped).
    // ---------------------------------------------------------------------
    task automatic test_boundary();
        logic signed [IN_W-1:0]  w, a;
        logic signed [ACC_W-1:0] p;

        begin_test("test_boundary");
        do_reset();

        // 127 * 127 = 16129 — overflows 8 bits, needs >8-bit product.
        w = 8'sd127;  a = 8'sd127;  p = '0;
        load_weight(w);
        drive_cycle(1'b0, 1'b1, a, p);
        tick_sample();
        check("test_boundary", psum_out, golden(p, w, a), "127 * 127");

        // -128 * -128 = +16384 — the classic two's-complement corner.
        w = -8'sd128; a = -8'sd128; p = '0;
        load_weight(w);
        drive_cycle(1'b0, 1'b1, a, p);
        tick_sample();
        check("test_boundary", psum_out, golden(p, w, a), "-128 * -128");

        // -128 * 127 = -16256.
        w = -8'sd128; a = 8'sd127;  p = '0;
        load_weight(w);
        drive_cycle(1'b0, 1'b1, a, p);
        tick_sample();
        check("test_boundary", psum_out, golden(p, w, a), "-128 * 127");

        // Same products on top of partial sums that occupy the HIGH bits of the
        // 32-bit accumulator: a narrow adder would drop them.
        w = 8'sd127; a = 8'sd127; p = 32'sh4000_0000;
        load_weight(w);
        drive_cycle(1'b0, 1'b1, a, p);
        tick_sample();
        check("test_boundary", psum_out, golden(p, w, a),
              "127*127 on a psum_in that uses the upper 32-bit range");

        w = -8'sd128; a = 8'sd127; p = -32'sh4000_0000;
        load_weight(w);
        drive_cycle(1'b0, 1'b1, a, p);
        tick_sample();
        check("test_boundary", psum_out, golden(p, w, a),
              "-128*127 on a large negative psum_in");

        // Extreme weight values must also survive the load path intact.
        load_weight(-8'sd128);
        drive_cycle(1'b0, 1'b1, 8'sd1, '0);
        tick_sample();
        check("test_boundary", psum_out, golden('0, -8'sd128, 8'sd1),
              "weight -128 survives the load path");
    endtask

    // ---------------------------------------------------------------------
    // test_transitions
    //   Catches: a weight that arrives one cycle late (first compute uses the
    //   stale weight), and residue in psum_q left over from a load cycle where
    //   valid_in happened to be high while the shared bus carried a weight.
    // ---------------------------------------------------------------------
    task automatic test_transitions();
        logic signed [IN_W-1:0]  w_old, w_new, a;
        logic signed [ACC_W-1:0] p;

        begin_test("test_transitions");
        do_reset();

        // --- wload high then low: the FIRST compute uses the NEW weight ------
        w_old = 8'sd10;
        w_new = -8'sd60;
        a     = 8'sd9;
        p     = 32'sd500;

        load_weight(w_old);
        load_weight(w_new);
        drive_cycle(1'b0, 1'b1, a, p);
        tick_sample();
        check("test_transitions", psum_out, golden(p, w_new, a),
              "first compute after wload must use the NEW weight");

        // --- wload high WHILE valid_in is high -------------------------------
        // The psum bus carries a weight this cycle, so whatever psum_q computes
        // is a don't-care. What matters is that the NEXT compute cycle is clean.
        w_new = 8'sd33;
        @(negedge clk);
        wload    = 1'b1;
        valid_in = 1'b1;                    // deliberately overlapping
        a_in     = 8'sh7F;                  // junk activation
        psum_in  = {24'h1234_56, w_new};    // weight + garbage on the shared bus
        tick_sample();                      // weight_q <= w_new here

        p = 32'sd777;
        a = -8'sd12;
        drive_cycle(1'b0, 1'b1, a, p);
        tick_sample();
        check("test_transitions", psum_out, golden(p, w_new, a),
              "overlapping wload+valid_in must not corrupt the next compute");

        // --- load -> compute -> load -> compute, twice, no residue -----------
        for (int i = 0; i < 2; i++) begin
            w_old = IN_W'($urandom());
            w_new = IN_W'($urandom());

            load_weight(w_old);
            a = IN_W'($urandom());
            p = ACC_W'($urandom());
            drive_cycle(1'b0, 1'b1, a, p);
            tick_sample();
            check("test_transitions", psum_out, golden(p, w_old, a),
                  $sformatf("round %0d: compute after first load (w=%0d)", i, w_old));

            load_weight(w_new);
            a = IN_W'($urandom());
            p = ACC_W'($urandom());
            drive_cycle(1'b0, 1'b1, a, p);
            tick_sample();
            check("test_transitions", psum_out, golden(p, w_new, a),
                  $sformatf("round %0d: compute after second load (w=%0d)", i, w_new));
        end
    endtask

    // ---------------------------------------------------------------------
    // Report
    // ---------------------------------------------------------------------
    task automatic report();
        string failing[$];
        string t;

        $display("");
        $display("=============================================================");
        $display(" PE TESTBENCH SUMMARY");
        $display("=============================================================");
        $display(" %-20s %8s %8s   %s", "TASK", "PASS", "FAIL", "STATUS");
        $display("-------------------------------------------------------------");
        foreach (test_order[i]) begin
            t = test_order[i];
            $display(" %-20s %8d %8d   %s",
                     t, pass_cnt[t], fail_cnt[t], (fail_cnt[t] == 0) ? "PASS" : "FAIL");
            if (fail_cnt[t] != 0) failing.push_back(t);
        end
        $display("-------------------------------------------------------------");
        $display(" %-20s %8d %8d", "TOTAL", total_pass, total_fail);
        $display("=============================================================");
        $display("");

        if (total_fail == 0) begin
            $display("=== PE TESTBENCH PASSED ===");
        end else begin
            $display("=== PE TESTBENCH FAILED ===");
            $display("Failing tasks:");
            foreach (failing[i]) $display("  - %s", failing[i]);
        end
    endtask

    // ---------------------------------------------------------------------
    // Main sequence
    // ---------------------------------------------------------------------
    initial begin
        int seed;

        total_pass = 0;
        total_fail = 0;

        // Fixed seed so every run is reproducible.
        seed = SEED;
        void'($urandom(seed));

        rst_n    = 1'b1;
        wload    = 1'b0;
        valid_in = 1'b0;
        a_in     = '0;
        psum_in  = '0;

        test_reset();
        test_weight_load();
        test_stationarity();
        test_hop_timing();
        test_mac();
        test_bubble();
        test_signed();
        test_boundary();
        test_transitions();

        report();
        $finish;
    end

endmodule