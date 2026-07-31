// -----------------------------------------------------------------------------
// skew_buffer.sv
//
// Triangular delay bank for N parallel lanes. One module, two roles, selected by
// the REVERSE parameter:
//
//   REVERSE = 0  INPUT SKEW    lane k is delayed by k stages.
//                              Lane 0 passes straight through, lane N-1 is
//                              delayed the most. Turns a rectangular block of
//                              activations into the diagonal wavefront the
//                              systolic array expects at its left edge.
//
//   REVERSE = 1  OUTPUT DE-SKEW lane k is delayed by N-1-k stages.
//                              Lane 0 is delayed the most, lane N-1 passes
//                              straight through. Undoes the diagonal in which
//                              results leave the array's bottom edge, realigning
//                              them into rows.
//
// The two directions are mirror images of the same triangle, so both cost
// N(N-1)/2 x (DW+1) bits of storage.
//
// This module does delays and nothing else: no padding, no zero-fill for
// sub-N x N matrices, no flow control. Padding lives in a separate upstream
// module.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (the verification contract)
// -----------------------------------------------------------------------------
//
//   * With REVERSE = 0, if all N lanes present valid data on the SAME cycle,
//     then at the output lane k appears k cycles later than lane 0 -- a
//     descending staircase.
//
//   * With REVERSE = 1, the staircase is mirrored: lane 0 is delayed most and
//     lane N-1 not at all, so a diagonal input emerges aligned on one cycle.
//
//   * In both cases valid_out[k] is delayed by exactly the same delay[k] as
//     data_out[k]. Each pipeline stage holds {valid, data} as a single DW+1 bit
//     register, so a valid tag physically cannot separate from the value it
//     describes.
//
//   * After reset every stage reads back zero: data 0, valid 0.
//
// -----------------------------------------------------------------------------
// NOTE ON DELAY-0 LANES
//   The lane whose delay is 0 (lane 0 when REVERSE=0, lane N-1 when REVERSE=1)
//   is a plain combinational pass-through -- no register, no cycle of latency.
//   That is deliberate: the skew pattern is defined RELATIVE to that lane, so
//   registering it would add a uniform cycle of latency without changing the
//   stagger, and would break the "lane k appears k cycles after lane 0" contract
//   only in the sense of shifting the whole wavefront. Callers that need the
//   whole bank pipelined should add their own stage outside.
// -----------------------------------------------------------------------------

module skew_buffer #(
    parameter int N       = 4,   // number of parallel lanes
    parameter int DW      = 8,   // data width per lane
    parameter int REVERSE = 0    // 0 = skew (input side), 1 = de-skew (output side)
) (
    input  logic          clk,
    input  logic          rst_n,             // active-low, synchronous

    input  logic [DW-1:0] data_in   [0:N-1],
    input  logic          valid_in  [0:N-1],

    output logic [DW-1:0] data_out  [0:N-1],
    output logic          valid_out [0:N-1]
);

    // -------------------------------------------------------------------------
    // Per-lane delay depth, computed from N -- never hardcoded.
    //
    //   REVERSE = 0 :  delay[k] = k        (0, 1, 2, ... N-1)
    //   REVERSE = 1 :  delay[k] = N-1-k    (N-1, ... 2, 1, 0)
    // -------------------------------------------------------------------------
    function automatic int lane_delay(input int k);
        return (REVERSE != 0) ? (N - 1 - k) : k;
    endfunction

    genvar k, s;

    generate
        for (k = 0; k < N; k++) begin : g_lane

            localparam int D = (REVERSE != 0) ? (N - 1 - k) : k;

            if (D == 0) begin : g_passthrough
                // -------------------------------------------------------------
                // Zero-delay lane: straight wire. No register is declared here,
                // which is also why the shift chain below can safely assume
                // D >= 1 when it sizes its stage array.
                // -------------------------------------------------------------
                assign data_out[k]  = data_in[k];
                assign valid_out[k] = valid_in[k];

            end else begin : g_chain
                // -------------------------------------------------------------
                // D-deep shift chain. Each stage is one DW+1 bit register
                // holding {valid, data} together, so the tag and its value move
                // as a single unit and can never drift apart.
                // -------------------------------------------------------------
                logic [DW:0] stage [0:D-1];

                always_ff @(posedge clk) begin
                    if (!rst_n) begin
                        for (int i = 0; i < D; i++)
                            stage[i] <= '0;                    // data 0, valid 0
                    end else begin
                        stage[0] <= {valid_in[k], data_in[k]};
                        for (int i = 1; i < D; i++)
                            stage[i] <= stage[i-1];
                    end
                end

                assign data_out[k]  = stage[D-1][DW-1:0];
                assign valid_out[k] = stage[D-1][DW];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Elaboration-time sanity: the delay pattern must be a permutation of
    // 0 .. N-1 in either direction, and the storage must come to the triangle.
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    initial begin
        int total;
        total = 0;
        for (int i = 0; i < N; i++) total += lane_delay(i);
        if (total != (N * (N - 1)) / 2)
            $error("skew_buffer: delay pattern sums to %0d, expected %0d",
                   total, (N * (N - 1)) / 2);
    end
`endif

endmodule
