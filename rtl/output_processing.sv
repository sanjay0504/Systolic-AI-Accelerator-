// -----------------------------------------------------------------------------
// output_processing.sv
//
// Shrinks the systolic array's raw accumulator output into a small, storable
// result. Sits between the array's bottom edge and the de-skew buffer:
//
//     array (ACC_W psum_out) -> output_processing -> de-skew (DW_OUT) -> output_mem
//
// Purely combinational: no clock, no reset, no state. `valid` passes straight
// through unchanged, so the tag stays aligned with the value it describes as
// both cross this module in zero cycles.
//
// Every lane is fully independent -- there is no cross-lane logic of any kind.
//
// -----------------------------------------------------------------------------
// PER-LANE PIPELINE -- THE ORDER IS NOT ARBITRARY
// -----------------------------------------------------------------------------
//     psum_in
//       [1] add bias      (if USE_BIAS)  biased    = psum_in + bias
//       [2] ReLU          (if USE_RELU)  activated = biased[ACC_W-1] ? 0 : biased
//       [3] arith shift   (always)       scaled    = activated >>> SHIFT
//       [4] saturate      (always)       clamp to [MIN_OUT, MAX_OUT]
//     data_out
//
// Bias and ReLU are applied at FULL ACC_W precision, before the scale-down.
// Reordering breaks both of them:
//   * scaling first would shift the accumulator down before the bias is added,
//     so a bias sized for accumulator units would land N orders of magnitude off;
//   * ReLU's decision is a sign test, and scaling first makes that test read the
//     sign of already-truncated data. A small negative value that scales to zero
//     would pass ReLU as non-negative.
//
// Step 3 uses >>> (arithmetic), never >> (logical). A logical shift zero-fills
// from the left, turning any negative accumulator into a large positive number.
// This is the same sign-extension discipline the array's weight-load path
// depends on at its top edge.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (verification contract)
// -----------------------------------------------------------------------------
//   * With USE_BIAS=0 and USE_RELU=0 the module reduces to shift + saturate
//     only -- plain matmul mode, with no bias adder or ReLU comparator
//     instantiated at all.
//   * A value that lands within [MIN_OUT, MAX_OUT] after scaling passes through
//     unchanged in its low DW_OUT bits.
//   * With USE_RELU=1 a negative psum_in gives data_out = 0 for that lane
//     whatever SHIFT is -- UNLESS bias pushed it non-negative first. Bias is
//     applied before ReLU, so that is the specified behaviour, not a bug.
//   * Saturation triggers symmetrically at both bounds: MAX_OUT above,
//     MIN_OUT below.
//   * valid_out is valid_in, combinationally, on every lane.
// -----------------------------------------------------------------------------

module output_processing #(
    parameter int N        = 4,    // lanes (matches array width)
    parameter int ACC_W    = 32,   // input width (accumulator)
    parameter int DW_OUT   = 8,    // output width
    parameter int SHIFT    = 8,    // right-shift amount for scaling
    parameter int USE_BIAS = 0,    // 0 = no bias adder instantiated
    parameter int USE_RELU = 0     // 0 = no ReLU comparator instantiated
) (
    input  logic signed [ACC_W-1:0]  psum_in   [0:N-1],   // raw array output
    input  logic                     valid_in  [0:N-1],
    input  logic signed [ACC_W-1:0]  bias      [0:N-1],   // tie to 0 when USE_BIAS=0
    output logic signed [DW_OUT-1:0] data_out  [0:N-1],
    output logic                     valid_out [0:N-1]
);

    // Saturation bounds, derived from DW_OUT rather than hardcoded, so the
    // module stays correct if the output width changes. The literal 1 is cast to
    // ACC_W first: a bare 1 is a 32-bit int and would overflow the shift if
    // ACC_W (and DW_OUT) ever exceeded 32.
    localparam logic signed [ACC_W-1:0] MAX_OUT =  (ACC_W'(1) <<< (DW_OUT-1)) - 1;  //  127 @ DW_OUT=8
    localparam logic signed [ACC_W-1:0] MIN_OUT = -(ACC_W'(1) <<< (DW_OUT-1));      // -128 @ DW_OUT=8

    generate
        for (genvar k = 0; k < N; k++) begin : g_lane

            logic signed [ACC_W-1:0] biased;
            logic signed [ACC_W-1:0] activated;
            logic signed [ACC_W-1:0] scaled;

            // --- [1] bias, at full accumulator precision --------------------
            // The sum is taken at ACC_W and can wrap if a caller supplies a bias
            // near the accumulator's own limits; keeping bias within range is
            // the caller's business, as it is upstream of any saturation.
            if (USE_BIAS != 0) begin : g_bias
                always_comb biased = psum_in[k] + bias[k];
            end else begin : g_no_bias
                // bias is not read at all here, so no adder is inferred.
                always_comb biased = psum_in[k];
            end

            // --- [2] ReLU, still at full precision --------------------------
            if (USE_RELU != 0) begin : g_relu
                always_comb activated = biased[ACC_W-1] ? '0 : biased;
            end else begin : g_no_relu
                always_comb activated = biased;
            end

            // --- [3] arithmetic scale-down ----------------------------------
            // >>> on a signed operand: the sign bit is replicated, so negative
            // values scale toward zero instead of becoming large positives.
            always_comb scaled = activated >>> SHIFT;

            // --- [4] symmetric saturation -----------------------------------
            always_comb begin
                if      (scaled > MAX_OUT) data_out[k] = DW_OUT'(MAX_OUT);
                else if (scaled < MIN_OUT) data_out[k] = DW_OUT'(MIN_OUT);
                else                       data_out[k] = scaled[DW_OUT-1:0];
            end

            // --- valid rides through untouched ------------------------------
            assign valid_out[k] = valid_in[k];

        end
    endgenerate

endmodule
