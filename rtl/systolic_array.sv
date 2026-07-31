// -----------------------------------------------------------------------------
// systolic_array.sv
//
// Top-level N x N weight-stationary systolic array for a matrix-multiplication
// accelerator. Purely structural: it instantiates N^2 `processing_element`s and
// wires them as a nearest-neighbour mesh.
//
// This module contains NO control logic, NO memories and NO skew logic. It
// assumes correctly-timed data is presented at its edges by the surrounding
// controller / feeder.
//
//   dataflow:   activations  ->  left  to right   (one PE per cycle)
//               valid tags   ->  left  to right   (travels with the activation)
//               partial sums ->  top   to bottom  (one PE per cycle)
//               weights      ->  top   to bottom  (during the load pass, on the
//                                                  shared psum wires)
//
// -----------------------------------------------------------------------------
// INTENDED BEHAVIOUR (self-check / verification contract)
// -----------------------------------------------------------------------------
//
// LOAD phase (`wload` = 1, held for N cycles):
//   `weight_top[j]` is sign-extended onto the top of column j and shifts down the
//   column via the psum path, one PE per cycle, because each PE drives its own
//   captured weight back out combinationally while wload is high. The weight
//   presented on the FIRST load cycle travels furthest and therefore lands in the
//   BOTTOM row; the weight presented on the LAST (Nth) load cycle stays in row 0.
//   So column j must be fed bottom-row weight first.
//
// COMPUTE phase (`wload` = 0):
//   Row-skewed activations enter the left edge with their valid tags. Partial sums
//   accumulate down each column starting from a zero injected at the top edge, and
//   finished results emerge at the bottom edge together with their valid tags.
//
// TIMING:
//   With compute-relative cycle 0 = the cycle the first activation is presented on
//   `a_in[0]`, and with the standard triangular input skew (row i delayed by i
//   cycles), the result C[n][j] appears on `psum_out[j]` at cycle N + n + j.
//
//   Rationale: an activation presented at cycle t on row i reaches PE(i,j) at cycle
//   t + j (one register hop per column). The partial sum for that product leaves
//   PE(i,j) one cycle later. Walking a product down all N rows and across to
//   column j costs exactly N + j cycles from the row-0 injection, plus n for the
//   nth result in the stream.
//
// VALID ALIGNMENT:
//   `valid` travels HORIZONTALLY with the activation, not down the column, so the
//   bottom-edge valid for column j is the bottom PE's own `valid_out`
//   (= valid_wire[N-1][j+1]), not something arriving on psum_wire. That valid_out
//   and psum_wire[N][j] are driven by registers inside PE(N-1,j) that sample the
//   same `valid_in` / `psum_in` cycle, so a result and its tag assert on the SAME
//   cycle.
//
// -----------------------------------------------------------------------------

module systolic_array #(
    parameter int N     = 4,   // array dimension (N x N PEs)
    parameter int IN_W  = 8,   // activation / weight width
    parameter int ACC_W = 32   // partial-sum width
) (
    input  logic                    clk,
    input  logic                    rst_n,               // active-low, synchronous
    input  logic                    wload,               // 1 = weight load, 0 = compute

    // Left edge -- activations (already skewed by the feeder) and their valid tags
    input  logic signed [IN_W-1:0]  a_in       [0:N-1],
    input  logic                    valid_in   [0:N-1],

    // Top edge -- weights during the load pass
    input  logic signed [IN_W-1:0]  weight_top [0:N-1],

    // Bottom edge -- results and their valid tags
    output logic signed [ACC_W-1:0] psum_out   [0:N-1],
    output logic                    valid_out  [0:N-1]
);

    // -------------------------------------------------------------------------
    // Interconnect: declared one element larger than the PE grid in the direction
    // of travel, so the array edges become plain indices instead of special cases.
    //
    //   a_wire / valid_wire : N+1 columns, [i][0] = left input, [i][N] dangles
    //   psum_wire           : N+1 rows,    [0][j] = top input,  [N][j] = result
    // -------------------------------------------------------------------------
    logic signed [IN_W-1:0]  a_wire     [0:N-1][0:N];
    logic                    valid_wire [0:N-1][0:N];
    logic signed [ACC_W-1:0] psum_wire  [0:N]  [0:N-1];

    genvar i, j;

    // -------------------------------------------------------------------------
    // LEFT EDGE (j = 0): activations and valid tags enter here.
    // -------------------------------------------------------------------------
    generate
        for (i = 0; i < N; i++) begin : g_left_edge
            assign a_wire[i][0]     = a_in[i];
            assign valid_wire[i][0] = valid_in[i];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // TOP EDGE (i = 0): the dual-purpose weight-load / compute path.
    //
    // The psum wires are time-shared. During the load pass the top of each column
    // carries a weight, which the column shifts downward like a shift register.
    // During compute the same wire injects a zero so the accumulation chain starts
    // clean.
    //
    // The sign extension here MUST match the PE's internal `ACC_W'(weight_q)`
    // (weight_q is signed, so that cast replicates the sign bit). If this edge
    // zero-extended instead, a negative weight would still be correct in row 0 --
    // which captures only psum_in[IN_W-1:0] -- but corrupt in every row below it,
    // because those rows receive the value the PE above re-drove after sign
    // extension.
    // -------------------------------------------------------------------------
    generate
        for (j = 0; j < N; j++) begin : g_top_edge
            assign psum_wire[0][j] = wload
                ? {{(ACC_W-IN_W){weight_top[j][IN_W-1]}}, weight_top[j]}  // weight, sign-extended
                : '0;                                                     // zero seed for the MAC chain
        end
    endgenerate

    // -------------------------------------------------------------------------
    // PE GRID: row i, column j. Every PE is identical; position is expressed only
    // through the interconnect indices.
    //
    //   a_in     = a_wire[i][j]      a_out     -> a_wire[i][j+1]      (rightward)
    //   valid_in = valid_wire[i][j]  valid_out -> valid_wire[i][j+1]  (rightward)
    //   psum_in  = psum_wire[i][j]   psum_out  -> psum_wire[i+1][j]   (downward)
    // -------------------------------------------------------------------------
    generate
        for (i = 0; i < N; i++) begin : g_row
            for (j = 0; j < N; j++) begin : g_col
                processing_element #(
                    .IN_W  (IN_W),
                    .ACC_W (ACC_W)
                ) u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .wload     (wload),

                    .valid_in  (valid_wire[i][j]),
                    .valid_out (valid_wire[i][j+1]),

                    .a_in      (a_wire[i][j]),
                    .a_out     (a_wire[i][j+1]),

                    .psum_in   (psum_wire[i][j]),
                    .psum_out  (psum_wire[i+1][j])
                );
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // BOTTOM EDGE (i = N-1): finished partial sums leave the array here.
    //
    // psum_out[j] is the extra row of the oversized psum array, driven by the
    // bottom PE. valid_out[j] is taken from that same PE's horizontal valid chain
    // (see VALID ALIGNMENT in the header) -- both come from registers clocked off
    // the same sampling cycle, so a result and its tag appear together.
    // -------------------------------------------------------------------------
    generate
        for (j = 0; j < N; j++) begin : g_bottom_edge
            assign psum_out[j]  = psum_wire[N][j];
            assign valid_out[j] = valid_wire[N-1][j+1];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // RIGHT EDGE (j = N): a_wire[i][N] and valid_wire[i][N] are intentionally left
    // dangling. Activations that have crossed the last column have no further
    // consumer.
    // -------------------------------------------------------------------------

endmodule
