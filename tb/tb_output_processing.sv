// -----------------------------------------------------------------------------
// tb_output_processing.sv -- self-checking testbench for output_processing.sv
//
// The DUT is purely combinational, so the clock exists only to sequence vectors
// and make the waveform readable: drive on the negedge, check just after the
// following posedge. There is no DUT latency to wait for.
//
// Five DUTs are instantiated on ONE shared stimulus bus, so every vector is
// checked against every configuration at once:
//
//     A    USE_BIAS=0 USE_RELU=0 SHIFT=8    plain matmul mode
//     B    USE_BIAS=1 USE_RELU=0 SHIFT=8    bias only
//     C    USE_BIAS=1 USE_RELU=1 SHIFT=8    full neural-net mode
//     A4   USE_BIAS=0 USE_RELU=0 SHIFT=4    shift sensitivity
//     A12  USE_BIAS=0 USE_RELU=0 SHIFT=12   shift sensitivity
//
// golden_lane() is the single source of truth. The only hand-typed expected
// values in the file are in test_golden_sanity, which checks the model itself.
//
// NOTE ON THE GOLDEN MODEL: the prompt's sketch declares MAX_OUT/MIN_OUT as
// localparams inside the function body, which SystemVerilog does not allow.
// They are hoisted to module scope here; the arithmetic is unchanged.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_output_processing;

    // ---------------------------------------------------------------------
    // Parameters / infrastructure
    // ---------------------------------------------------------------------
    localparam int  N      = 4;
    localparam int  ACC_W  = 32;
    localparam int  DW_OUT = 8;
    localparam int  SH8    = 8;      // default shift
    localparam int  SH4    = 4;
    localparam int  SH12   = 12;

    localparam time TCLK   = 10ns;
    localparam time SETTLE = 1ns;
    localparam int  SEED   = 32'h5EED_0B77;   // fixed -> reproducible

    // Saturation bounds, derived from DW_OUT exactly as the DUT derives them.
    localparam logic signed [ACC_W-1:0] MAX_OUT =  (ACC_W'(1) <<< (DW_OUT-1)) - 1;
    localparam logic signed [ACC_W-1:0] MIN_OUT = -(ACC_W'(1) <<< (DW_OUT-1));

    // Configuration ids -- index into every per-DUT dispatch below.
    localparam int CFG_A = 0, CFG_B = 1, CFG_C = 2, CFG_A4 = 3, CFG_A12 = 4;
    localparam int NCFG  = 5;

    logic clk;

    // ---------------------------------------------------------------------
    // Shared stimulus bus + one output set per DUT
    // ---------------------------------------------------------------------
    logic signed [ACC_W-1:0]  psum     [0:N-1];
    logic signed [ACC_W-1:0]  bias     [0:N-1];
    logic                     valid_in [0:N-1];

    logic signed [DW_OUT-1:0] a_d  [0:N-1];  logic a_v  [0:N-1];
    logic signed [DW_OUT-1:0] b_d  [0:N-1];  logic b_v  [0:N-1];
    logic signed [DW_OUT-1:0] c_d  [0:N-1];  logic c_v  [0:N-1];
    logic signed [DW_OUT-1:0] a4_d [0:N-1];  logic a4_v [0:N-1];
    logic signed [DW_OUT-1:0] a12_d[0:N-1];  logic a12_v[0:N-1];

    output_processing #(.N(N), .ACC_W(ACC_W), .DW_OUT(DW_OUT), .SHIFT(SH8),
                        .USE_BIAS(0), .USE_RELU(0)) dut_a
        (.psum_in(psum), .valid_in(valid_in), .bias(bias), .data_out(a_d),  .valid_out(a_v));

    output_processing #(.N(N), .ACC_W(ACC_W), .DW_OUT(DW_OUT), .SHIFT(SH8),
                        .USE_BIAS(1), .USE_RELU(0)) dut_b
        (.psum_in(psum), .valid_in(valid_in), .bias(bias), .data_out(b_d),  .valid_out(b_v));

    output_processing #(.N(N), .ACC_W(ACC_W), .DW_OUT(DW_OUT), .SHIFT(SH8),
                        .USE_BIAS(1), .USE_RELU(1)) dut_c
        (.psum_in(psum), .valid_in(valid_in), .bias(bias), .data_out(c_d),  .valid_out(c_v));

    output_processing #(.N(N), .ACC_W(ACC_W), .DW_OUT(DW_OUT), .SHIFT(SH4),
                        .USE_BIAS(0), .USE_RELU(0)) dut_a4
        (.psum_in(psum), .valid_in(valid_in), .bias(bias), .data_out(a4_d), .valid_out(a4_v));

    output_processing #(.N(N), .ACC_W(ACC_W), .DW_OUT(DW_OUT), .SHIFT(SH12),
                        .USE_BIAS(0), .USE_RELU(0)) dut_a12
        (.psum_in(psum), .valid_in(valid_in), .bias(bias), .data_out(a12_d), .valid_out(a12_v));

    initial begin clk = 1'b0; forever #(TCLK/2) clk = ~clk; end

    initial begin $dumpfile("tb_output_processing.vcd"); $dumpvars(0, tb_output_processing); end

    initial begin #500000; $error("TIMEOUT"); $finish; end

    // ---------------------------------------------------------------------
    // GOLDEN MODEL -- the same four steps, in the same order, computed
    // independently of the DUT.
    // ---------------------------------------------------------------------

    // Everything up to but not including saturation. Split out so the tests can
    // ask "did this saturate?" and "did this underflow to zero?" for statistics.
    function automatic logic signed [ACC_W-1:0] golden_scaled(
        input logic signed [ACC_W-1:0] psum_v,
        input logic signed [ACC_W-1:0] bias_v,
        input bit                      use_bias,
        input bit                      use_relu,
        input int                      shift
    );
        logic signed [ACC_W-1:0] biased, activated;
        biased    = use_bias ? (psum_v + bias_v) : psum_v;          // [1] full precision
        activated = use_relu ? (biased[ACC_W-1] ? '0 : biased)      // [2] sign test on
                             : biased;                              //     the POST-bias value
        return activated >>> shift;                                 // [3] arithmetic
    endfunction

    function automatic logic signed [DW_OUT-1:0] golden_lane(
        input logic signed [ACC_W-1:0] psum_v,
        input logic signed [ACC_W-1:0] bias_v,
        input bit                      use_bias,
        input bit                      use_relu,
        input int                      shift
    );
        logic signed [ACC_W-1:0] scaled;
        scaled = golden_scaled(psum_v, bias_v, use_bias, use_relu, shift);
        if      (scaled > MAX_OUT) return MAX_OUT[DW_OUT-1:0];      // [4] saturate
        else if (scaled < MIN_OUT) return MIN_OUT[DW_OUT-1:0];
        else                       return scaled[DW_OUT-1:0];
    endfunction

    // The WRONG pipeline order, used only as a foil: ReLU applied to the raw
    // psum instead of the post-bias value. test_relu asserts the DUT does not
    // match this whenever the two orders disagree.
    function automatic logic signed [DW_OUT-1:0] wrong_order_relu_first(
        input logic signed [ACC_W-1:0] psum_v,
        input logic signed [ACC_W-1:0] bias_v,
        input int                      shift
    );
        logic signed [ACC_W-1:0] activated, biased, scaled;
        activated = psum_v[ACC_W-1] ? '0 : psum_v;                  // ReLU first (wrong)
        biased    = activated + bias_v;
        scaled    = biased >>> shift;
        if      (scaled > MAX_OUT) return MAX_OUT[DW_OUT-1:0];
        else if (scaled < MIN_OUT) return MIN_OUT[DW_OUT-1:0];
        else                       return scaled[DW_OUT-1:0];
    endfunction

    // A logical-shift model, used only as a foil by test_arithmetic_shift.
    function automatic logic signed [DW_OUT-1:0] logical_shift_model(
        input logic signed [ACC_W-1:0] psum_v,
        input int                      shift
    );
        logic [ACC_W-1:0]        u;
        logic signed [ACC_W-1:0] scaled;
        u      = psum_v;                                            // reinterpret unsigned
        scaled = signed'(u >> shift);                               // zero-filled (wrong)
        if      (scaled > MAX_OUT) return MAX_OUT[DW_OUT-1:0];
        else if (scaled < MIN_OUT) return MIN_OUT[DW_OUT-1:0];
        else                       return scaled[DW_OUT-1:0];
    endfunction

    // ---------------------------------------------------------------------
    // Per-configuration dispatch
    // ---------------------------------------------------------------------
    function automatic bit cfg_bias(input int cfg);
        return (cfg == CFG_B) || (cfg == CFG_C);
    endfunction
    function automatic bit cfg_relu(input int cfg);
        return (cfg == CFG_C);
    endfunction
    function automatic int cfg_shift(input int cfg);
        case (cfg)
            CFG_A4:  return SH4;
            CFG_A12: return SH12;
            default: return SH8;
        endcase
    endfunction
    function automatic string cfg_name(input int cfg);
        case (cfg)
            CFG_A:   return "A(no bias,no relu,sh8)";
            CFG_B:   return "B(bias,sh8)";
            CFG_C:   return "C(bias+relu,sh8)";
            CFG_A4:  return "A4(sh4)";
            default: return "A12(sh12)";
        endcase
    endfunction

    task automatic get_out(input  int cfg,
                           output logic signed [DW_OUT-1:0] od [0:N-1],
                           output logic ov [0:N-1]);
        case (cfg)
            CFG_A:   begin od = a_d;   ov = a_v;   end
            CFG_B:   begin od = b_d;   ov = b_v;   end
            CFG_C:   begin od = c_d;   ov = c_v;   end
            CFG_A4:  begin od = a4_d;  ov = a4_v;  end
            default: begin od = a12_d; ov = a12_v; end
        endcase
    endtask

    // ---------------------------------------------------------------------
    // Scoreboard
    // ---------------------------------------------------------------------
    string test_order[$];
    int    pass_cnt[string], fail_cnt[string];
    int    lane_pass[0:N-1], lane_fail[0:N-1];
    int    total_pass, total_fail;

    function automatic string begin_test(input string name);
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
            $display("[FAIL] %s: lane %0d %s expected=%0d got=%0d",
                     tname, lane, note, exp, got);
    endtask

    task automatic end_test(input string tname);
        string s = "     per-lane pass/fail:";
        for (int k = 0; k < N; k++)
            s = {s, $sformatf(" [%0d]=%0d/%0d", k, lane_pass[k], lane_fail[k])};
        $display("%s", s);
    endtask

    // ---------------------------------------------------------------------
    // Drive / check plumbing
    // ---------------------------------------------------------------------
    task automatic drive(input logic signed [ACC_W-1:0] p [0:N-1],
                         input logic signed [ACC_W-1:0] b [0:N-1],
                         input logic                    v [0:N-1]);
        @(negedge clk);
        psum = p;  bias = b;  valid_in = v;
        @(posedge clk);
        #SETTLE;                       // combinational: settled long before this
    endtask

    // Compare one configuration's outputs against the model, lane by lane.
    // valid_out is checked here too, on every vector of every test.
    task automatic check_cfg(input string tname, input int cfg, input string note);
        logic signed [DW_OUT-1:0] od [0:N-1];
        logic                     ov [0:N-1];
        logic signed [DW_OUT-1:0] exp;

        get_out(cfg, od, ov);
        for (int k = 0; k < N; k++) begin
            exp = golden_lane(psum[k], bias[k], cfg_bias(cfg), cfg_relu(cfg), cfg_shift(cfg));
            check(tname, k, int'(od[k]), int'(exp),
                  $sformatf("%s %s psum=%0d bias=%0d", cfg_name(cfg), note, psum[k], bias[k]));
            check(tname, k, int'(ov[k]), int'(valid_in[k]),
                  $sformatf("%s %s valid passthrough", cfg_name(cfg), note));
        end
    endtask

    // Every vector is checked against every configuration.
    task automatic check_all(input string tname, input string note);
        for (int cfg = 0; cfg < NCFG; cfg++) check_cfg(tname, cfg, note);
    endtask

    task automatic apply(input string tname, input string note,
                         input logic signed [ACC_W-1:0] p [0:N-1],
                         input logic signed [ACC_W-1:0] b [0:N-1],
                         input logic                    v [0:N-1]);
        drive(p, b, v);
        check_all(tname, note);
    endtask

    // ---------------------------------------------------------------------
    // Stimulus helpers
    // ---------------------------------------------------------------------
    function automatic void fill(input logic signed [ACC_W-1:0] val,
                                 output logic signed [ACC_W-1:0] arr [0:N-1]);
        for (int k = 0; k < N; k++) arr[k] = val;
    endfunction
    function automatic void fill_rand(output logic signed [ACC_W-1:0] arr [0:N-1]);
        for (int k = 0; k < N; k++) arr[k] = ACC_W'($urandom());   // full signed range
    endfunction
    function automatic void fill_v(input bit x, output logic v [0:N-1]);
        for (int k = 0; k < N; k++) v[k] = x;
    endfunction

    // =====================================================================
    // TEST TASKS
    // =====================================================================

    // Confirms the reference model itself, by hand, before anything trusts it.
    // These are the only hand-typed expected values in the file.
    task automatic test_golden_sanity();
        string tn = begin_test("test_golden_sanity");

        // 25600 >>> 8 = 100, inside [-128,127], passes through.
        check(tn, -1, int'(golden_lane(32'sd25600,  '0, 1'b0, 1'b0, 8)),  100, "25600>>>8");
        // 51200 >>> 8 = 200, above MAX_OUT -> clamp to 127.
        check(tn, -1, int'(golden_lane(32'sd51200,  '0, 1'b0, 1'b0, 8)),  127, "51200>>>8 clamps");
        // -25600 >>> 8 = -100, arithmetic shift keeps it negative.
        check(tn, -1, int'(golden_lane(-32'sd25600, '0, 1'b0, 1'b0, 8)), -100, "-25600>>>8");
        // -51200 >>> 8 = -200, below MIN_OUT -> clamp to -128.
        check(tn, -1, int'(golden_lane(-32'sd51200, '0, 1'b0, 1'b0, 8)), -128, "-51200>>>8 clamps");
        // Zero in, zero out.
        check(tn, -1, int'(golden_lane('0, '0, 1'b0, 1'b0, 8)),             0, "0>>>8");
        // ReLU on a negative -> 0.
        check(tn, -1, int'(golden_lane(-32'sd25600, '0, 1'b0, 1'b1, 8)),    0, "relu(-25600)");
        // Bias first, THEN ReLU: -25600 + 51200 = +25600 -> 100, not 0.
        check(tn, -1, int'(golden_lane(-32'sd25600, 32'sd51200, 1'b1, 1'b1, 8)), 100,
              "bias rescues a negative before relu");
        // Bounds themselves.
        check(tn, -1, int'(MAX_OUT),  127, "MAX_OUT");
        check(tn, -1, int'(MIN_OUT), -128, "MIN_OUT");
        end_test(tn);
    endtask

    // Config A. Catches a bias or ReLU path that is present when it should have
    // been generated away: the same psum is driven twice, once with random bias
    // and once with zero bias, and config A's output must be bit-identical.
    task automatic test_shift_and_saturate_only();
        string tn = begin_test("test_shift_and_saturate_only");
        logic signed [ACC_W-1:0]  p [0:N-1], b [0:N-1], z [0:N-1];
        logic                     v [0:N-1];
        logic signed [DW_OUT-1:0] with_bias [0:N-1];

        fill_v(1'b1, v);
        fill('0, z);

        for (int it = 0; it < 60; it++) begin
            fill_rand(p);  fill_rand(b);

            drive(p, b, v);                       // random bias present
            check_all(tn, "random psum, random bias");
            with_bias = a_d;

            drive(p, z, v);                       // same psum, bias forced to 0
            check_all(tn, "random psum, zero bias");
            for (int k = 0; k < N; k++)
                check(tn, k, int'(with_bias[k]), int'(a_d[k]),
                      "config A output must not depend on bias");
        end
        end_test(tn);
    endtask

    // Config B. Catches a bias added at the wrong precision or the wrong sign.
    // Includes deliberate ACC_W wrap: psum + bias is specified to be taken at
    // accumulator width, so the DUT must wrap exactly as the model does rather
    // than saturate early or go undefined.
    task automatic test_bias_only();
        string tn = begin_test("test_bias_only");
        logic signed [ACC_W-1:0] p [0:N-1], b [0:N-1];
        logic                    v [0:N-1];

        fill_v(1'b1, v);

        // All four sign combinations, at a magnitude where the shift is visible.
        apply(tn, "+psum +bias", '{ 32'sd25600,  32'sd5120,  32'sd256,   32'sd0},
                                  '{ 32'sd2560,   32'sd512,   32'sd25600, 32'sd1}, v);
        apply(tn, "+psum -bias", '{ 32'sd25600,  32'sd5120,  32'sd256,   32'sd0},
                                  '{-32'sd2560,  -32'sd512,  -32'sd25600,-32'sd1}, v);
        apply(tn, "-psum +bias", '{-32'sd25600, -32'sd5120, -32'sd256,  -32'sd0},
                                  '{ 32'sd2560,   32'sd512,   32'sd25600, 32'sd1}, v);
        apply(tn, "-psum -bias", '{-32'sd25600, -32'sd5120, -32'sd256,  -32'sd0},
                                  '{-32'sd2560,  -32'sd512,  -32'sd25600,-32'sd1}, v);

        // Conceptual overflow of the ACC_W add, both directions.
        apply(tn, "positive overflow of psum+bias",
              '{32'sh7FFF_FFFF, 32'sh7FFF_0000, 32'sh4000_0000, 32'sh7FFF_FFFF},
              '{32'sd1,         32'sd65536,     32'sh4000_0000, 32'sh7FFF_FFFF}, v);
        apply(tn, "negative overflow of psum+bias",
              '{32'sh8000_0000, 32'sh8000_0000, 32'shC000_0000, 32'sh8000_0001},
              '{-32'sd1,        32'sh8000_0000, 32'shC000_0000, -32'sd2}, v);

        for (int it = 0; it < 60; it++) begin
            fill_rand(p);  fill_rand(b);
            apply(tn, "random psum and bias", p, b, v);
        end
        end_test(tn);
    endtask

    // Config C, and the sharpest ordering check in the file. ReLU must act on
    // the POST-bias value. Where the two orders disagree the DUT is asserted to
    // match the specified order and NOT to match the reversed one, so a
    // relu-then-bias implementation cannot pass by coincidence.
    task automatic test_relu();
        string tn = begin_test("test_relu");
        logic signed [ACC_W-1:0]  p [0:N-1], b [0:N-1];
        logic                     v [0:N-1];
        logic signed [DW_OUT-1:0] wrong;

        fill_v(1'b1, v);

        // Lane 0: negative before bias, positive after  -> must NOT be zeroed.
        // Lane 1: positive before bias, negative after  -> must be zeroed.
        // Lane 2: clearly negative baseline             -> zero.
        // Lane 3: clearly positive baseline             -> passes.
        p = '{-32'sd25600,  32'sd25600, -32'sd51200,  32'sd25600};
        b = '{ 32'sd51200, -32'sd51200,  32'sd0,      32'sd0};
        apply(tn, "relu ordering", p, b, v);

        for (int k = 0; k < N; k++) begin
            wrong = wrong_order_relu_first(p[k], b[k], SH8);
            if (wrong !== golden_lane(p[k], b[k], 1'b1, 1'b1, SH8))
                check(tn, k, (c_d[k] === wrong) ? 1 : 0, 0,
                      "DUT must not match relu-before-bias ordering");
        end

        // Randomised ordering pressure: biases large enough to flip the sign.
        for (int it = 0; it < 40; it++) begin
            for (int k = 0; k < N; k++) begin
                p[k] = ACC_W'($urandom_range(0, 100000)) - 50000;
                b[k] = ACC_W'($urandom_range(0, 100000)) - 50000;
            end
            apply(tn, "random sign-flipping bias", p, b, v);
            for (int k = 0; k < N; k++) begin
                wrong = wrong_order_relu_first(p[k], b[k], SH8);
                if (wrong !== golden_lane(p[k], b[k], 1'b1, 1'b1, SH8))
                    check(tn, k, (c_d[k] === wrong) ? 1 : 0, 0,
                          "DUT must not match relu-before-bias ordering");
            end
        end
        end_test(tn);
    endtask

    // PRIORITY. Sweeps the exact boundary in both directions: values that scale
    // to one below, exactly at, and one past each bound. A bound computed as
    // 128/-127, or a shift that loses a bit, moves the transition and shows up
    // immediately here.
    //
    // (Note that `>` vs `>=` in the comparison is genuinely invisible -- clamping
    // 127 to MAX_OUT yields 127 either way. What this catches is a WRONG BOUND
    // or a transition in the wrong place, which is the failure that matters.)
    task automatic test_saturation_boundary();
        string tn = begin_test("test_saturation_boundary");
        logic signed [ACC_W-1:0] p [0:N-1], b [0:N-1];
        logic                    v [0:N-1];

        fill_v(1'b1, v);
        fill('0, b);

        // val * 256 scales back to exactly val at SHIFT=8, so this walks the
        // output across both bounds one integer at a time.
        for (int val = -132; val <= 132; val++) begin
            for (int k = 0; k < N; k++) p[k] = ACC_W'(val * 256);
            apply(tn, $sformatf("scaled value %0d", val), p, b, v);
        end

        // The sub-shift bits either side of each bound: truncation must not move
        // the transition point.
        for (int off = -2; off <= 2; off++) begin
            p = '{ACC_W'(127*256 + off), ACC_W'(128*256 + off),
                   ACC_W'(-128*256 + off), ACC_W'(-129*256 + off)};
            apply(tn, $sformatf("boundary +/- %0d lsb", off), p, b, v);
        end
        end_test(tn);
    endtask

    // PRIORITY. Negative values with ReLU off must sign-extend through the
    // shift. Both models are computed explicitly: the DUT must equal the
    // arithmetic result and, wherever the two differ, must NOT equal the
    // logical-shift result -- which for a negative input is a large positive
    // that saturates to +127.
    task automatic test_arithmetic_shift();
        string tn = begin_test("test_arithmetic_shift");
        logic signed [ACC_W-1:0]  p [0:N-1], b [0:N-1];
        logic                     v [0:N-1];
        logic signed [DW_OUT-1:0] arith, logic_shift;

        fill_v(1'b1, v);
        fill('0, b);

        for (int it = 0; it < 60; it++) begin
            for (int k = 0; k < N; k++) begin
                // Strictly negative, spread across magnitudes.
                p[k] = -ACC_W'($urandom_range(1, 32'h4000_0000));
            end
            apply(tn, "negative psum, arithmetic shift", p, b, v);

            for (int k = 0; k < N; k++) begin
                arith       = golden_lane(p[k], '0, 1'b0, 1'b0, SH8);
                logic_shift = logical_shift_model(p[k], SH8);
                check(tn, k, int'(a_d[k]), int'(arith), "must equal the arithmetic-shift model");
                if (arith !== logic_shift)
                    check(tn, k, (a_d[k] === logic_shift) ? 1 : 0, 0,
                          "must NOT equal the logical-shift model");
            end
        end
        end_test(tn);
    endtask

    // Re-runs a random set at SHIFT=4, 8 and 12 and reports how often each
    // saturates and how often small values underflow to zero. Correctness is
    // still checked against the model; the rates are a reportable statistic for
    // the precision-vs-range discussion, not a pass/fail criterion.
    task automatic test_shift_sensitivity();
        string tn = begin_test("test_shift_sensitivity");
        logic signed [ACC_W-1:0] p [0:N-1], b [0:N-1];
        logic                    v [0:N-1];
        logic signed [ACC_W-1:0] sc;
        int sat[0:2], uf[0:2], tot;
        int shifts[0:2];

        shifts = '{SH4, SH8, SH12};
        for (int i = 0; i < 3; i++) begin sat[i] = 0; uf[i] = 0; end
        tot = 0;

        fill_v(1'b1, v);
        fill('0, b);

        for (int it = 0; it < 200; it++) begin
            // Mid-range magnitudes, where the shift choice actually matters.
            for (int k = 0; k < N; k++)
                p[k] = ACC_W'($urandom_range(0, 200000)) - 100000;
            apply(tn, "shift sweep", p, b, v);

            for (int k = 0; k < N; k++) begin
                tot++;
                for (int i = 0; i < 3; i++) begin
                    sc = golden_scaled(p[k], '0, 1'b0, 1'b0, shifts[i]);
                    if (sc > MAX_OUT || sc < MIN_OUT) sat[i]++;
                    else if (sc == 0 && p[k] != 0)    uf[i]++;
                end
            end
        end

        $display("     shift sensitivity over %0d samples:", tot);
        for (int i = 0; i < 3; i++)
            $display("       SHIFT=%2d  saturated %0d (%0d%%)  underflowed to 0 %0d (%0d%%)",
                     shifts[i], sat[i], (100*sat[i])/tot, uf[i], (100*uf[i])/tot);

        // The expected trend, asserted rather than just printed: a smaller shift
        // saturates at least as often, a larger one underflows at least as often.
        check(tn, -1, (sat[0] >= sat[1]) ? 1 : 0, 1, "SHIFT=4 saturates at least as often as 8");
        check(tn, -1, (sat[1] >= sat[2]) ? 1 : 0, 1, "SHIFT=8 saturates at least as often as 12");
        check(tn, -1, (uf[2]  >= uf[1])  ? 1 : 0, 1, "SHIFT=12 underflows at least as often as 8");
        check(tn, -1, (uf[1]  >= uf[0])  ? 1 : 0, 1, "SHIFT=8 underflows at least as often as 4");
        end_test(tn);
    endtask

    // valid_out must mirror valid_in on every lane and every config -- including
    // all-zero, where the data path must still compute correctly, since a
    // stateless block has no reason to gate its own arithmetic.
    task automatic test_valid_passthrough();
        string tn = begin_test("test_valid_passthrough");
        logic signed [ACC_W-1:0] p [0:N-1], b [0:N-1];
        logic                    v [0:N-1];

        fill_rand(p);  fill_rand(b);
        fill_v(1'b0, v);  apply(tn, "all lanes invalid", p, b, v);
        fill_v(1'b1, v);  apply(tn, "all lanes valid",   p, b, v);

        for (int it = 0; it < 40; it++) begin
            fill_rand(p);  fill_rand(b);
            for (int k = 0; k < N; k++) v[k] = $urandom_range(0, 1);
            apply(tn, "random per-lane valid", p, b, v);
        end
        end_test(tn);
    endtask

    // Zero must survive every config, and the ACC_W extremes must run through
    // all of them without corrupting -- the most negative value in particular,
    // which has no positive counterpart.
    task automatic test_zero_and_extremes();
        string tn = begin_test("test_zero_and_extremes");
        logic signed [ACC_W-1:0] p [0:N-1], b [0:N-1];
        logic                    v [0:N-1];

        fill_v(1'b1, v);

        // psum = 0 with bias = 0 must give 0 in every config.
        fill('0, p);  fill('0, b);
        apply(tn, "zero in, zero out", p, b, v);
        for (int cfg = 0; cfg < NCFG; cfg++) begin
            logic signed [DW_OUT-1:0] od [0:N-1];
            logic                     ov [0:N-1];
            get_out(cfg, od, ov);
            for (int k = 0; k < N; k++)
                check(tn, k, int'(od[k]), 0, $sformatf("%s zero in -> zero out", cfg_name(cfg)));
        end

        // ACC_W extremes, with and without bias in play.
        p = '{32'sh7FFF_FFFF, 32'sh8000_0000, 32'sh7FFF_FFFF, 32'sh8000_0000};
        fill('0, b);
        apply(tn, "ACC_W extremes, no bias", p, b, v);

        b = '{32'sh7FFF_FFFF, 32'sh8000_0000, 32'sh8000_0000, 32'sh7FFF_FFFF};
        apply(tn, "ACC_W extremes, extreme bias", p, b, v);

        // One notch inside each extreme.
        p = '{32'sh7FFF_FFFE, 32'sh8000_0001, 32'sd1, -32'sd1};
        fill('0, b);
        apply(tn, "just inside the extremes", p, b, v);
        end_test(tn);
    endtask

    // Every lane must depend only on its own inputs. Beyond checking all lanes
    // against their own model values, one lane's bias is swept while the others
    // are held fixed: any movement in the other lanes is cross-lane leakage.
    task automatic test_all_lanes_independent();
        string tn = begin_test("test_all_lanes_independent");
        logic signed [ACC_W-1:0]  p [0:N-1], b [0:N-1];
        logic                     v [0:N-1];
        logic signed [DW_OUT-1:0] ref_c [0:N-1];

        fill_v(1'b1, v);

        // Deliberately different per lane, including a saturating and a zeroing
        // lane side by side.
        p = '{32'sd25600, -32'sd51200, 32'sd51200, -32'sd256};
        b = '{32'sd0,      32'sd25600, -32'sd25600, 32'sd512};
        apply(tn, "distinct values per lane", p, b, v);
        ref_c = c_d;

        // Now move ONE lane's bias at a time; every other lane must be frozen.
        for (int moving = 0; moving < N; moving++) begin
            logic signed [ACC_W-1:0] b2 [0:N-1];
            b2 = b;
            b2[moving] = b[moving] + 32'sd77000;      // large enough to change it
            apply(tn, $sformatf("only lane %0d bias moved", moving), p, b2, v);
            for (int k = 0; k < N; k++)
                if (k != moving)
                    check(tn, k, int'(c_d[k]), int'(ref_c[k]),
                          $sformatf("lane %0d must be unaffected by lane %0d's bias", k, moving));
        end
        end_test(tn);
    endtask

    // Broad randomised sweep across every config at once. 500 vectors x N lanes
    // x NCFG configs of comparisons against the model.
    task automatic test_random_full_config();
        string tn = begin_test("test_random_full_config");
        logic signed [ACC_W-1:0] p [0:N-1], b [0:N-1];
        logic                    v [0:N-1];

        for (int it = 0; it < 500; it++) begin
            fill_rand(p);  fill_rand(b);
            for (int k = 0; k < N; k++) v[k] = $urandom_range(0, 1);
            apply(tn, "random full-range", p, b, v);
        end
        end_test(tn);
    endtask

    // ---------------------------------------------------------------------
    // Report
    // ---------------------------------------------------------------------
    task automatic report();
        string failing[$];
        string t;

        $display("\n=================================================================");
        $display(" OUTPUT PROCESSING TESTBENCH SUMMARY");
        $display("=================================================================");
        $display(" %-30s %8s %8s   %s", "TASK", "PASS", "FAIL", "STATUS");
        $display("-----------------------------------------------------------------");
        foreach (test_order[i]) begin
            t = test_order[i];
            $display(" %-30s %8d %8d   %s", t, pass_cnt[t], fail_cnt[t],
                     (fail_cnt[t] == 0) ? "PASS" : "FAIL");
            if (fail_cnt[t] != 0) failing.push_back(t);
        end
        $display("-----------------------------------------------------------------");
        $display(" %-30s %8d %8d", "TOTAL", total_pass, total_fail);
        $display("=================================================================\n");

        if (total_fail == 0) $display("=== OUTPUT PROCESSING PASSED ===");
        else begin
            $display("=== OUTPUT PROCESSING FAILED ===");
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

        for (int k = 0; k < N; k++) begin
            psum[k] = '0;  bias[k] = '0;  valid_in[k] = 1'b0;
        end

        test_golden_sanity();
        test_shift_and_saturate_only();
        test_bias_only();
        test_relu();
        test_saturation_boundary();
        test_arithmetic_shift();
        test_shift_sensitivity();
        test_valid_passthrough();
        test_zero_and_extremes();
        test_all_lanes_independent();
        test_random_full_config();

        report();
        $finish;
    end

endmodule
