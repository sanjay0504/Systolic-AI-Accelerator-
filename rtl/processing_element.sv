// -----------------------------------------------------------------------------
// processing_element.sv
//
// Processing element (PE) for a weight-stationary systolic array.
//
// Each PE holds one stationary weight and performs a multiply-accumulate on the
// partial sum flowing down the column while the activation flows across the row.
//
//   a_in  ->[ weight_q ]-> a_out      (activation, 1 cycle of skew)
//   psum_in -> (+) -> psum_out        (partial sum, 1 cycle of skew)
//
// Dual-purpose psum path:
//   The psum wires are time-shared between weight loading and compute so the
//   array needs no separate weight-distribution network.
//     wload = 1 : psum_in carries a weight; its low IN_W bits are captured into
//                 weight_q, and psum_out drives the sign-extended weight_q back
//                 out combinationally so weights can be shifted down the column
//                 one PE per cycle.
//     wload = 0 : psum_in/psum_out carry the accumulating partial sum, and
//                 psum_out drives the registered psum_q.
//   The mux on psum_out is what makes the shared wires work: during a load pass
//   the column behaves as a shift register of weights, during compute it behaves
//   as an accumulator chain.
// -----------------------------------------------------------------------------

module processing_element #(
    parameter int IN_W  = 8,
    parameter int ACC_W = 32
) (
    input  logic                    clk,
    input  logic                    rst_n,     // active-low, synchronous

    input  logic                    wload,     // 1 = weight-load pass, 0 = compute
    input  logic                    valid_in,
    output logic                    valid_out,

    input  logic signed [IN_W-1:0]  a_in,
    output logic signed [IN_W-1:0]  a_out,

    input  logic signed [ACC_W-1:0] psum_in,   // weight during wload, psum otherwise
    output logic signed [ACC_W-1:0] psum_out   // weight during wload, psum otherwise
);

    logic signed [IN_W-1:0]  weight_q;
    logic signed [IN_W-1:0]  a_q;
    logic                    valid_q;
    logic signed [ACC_W-1:0] psum_q;

    // Stationary weight: captured from the low bits of the shared psum bus.
    always_ff @(posedge clk) begin
        if (!rst_n)     weight_q <= '0;
        else if (wload) weight_q <= psum_in[IN_W-1:0];
        // else: hold
    end

    // Activation and its valid flag march across the row every cycle.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a_q     <= '0;
            valid_q <= 1'b0;
        end else begin
            a_q     <= a_in;
            valid_q <= valid_in;
        end
    end

    // MAC on the partial sum. When the incoming activation is not valid the
    // partial sum is passed along unchanged so bubbles do not corrupt the column.
    always_ff @(posedge clk) begin
        if (!rst_n)         psum_q <= '0;
        else if (valid_in)  psum_q <= psum_in + ACC_W'(weight_q * a_in);
        else                psum_q <= psum_in;
    end

    assign a_out     = a_q;
    assign valid_out = valid_q;

    // Shared psum output: weight on the way down during a load pass, accumulated
    // partial sum during compute.
    assign psum_out = wload ? ACC_W'(weight_q) : psum_q;

endmodule
