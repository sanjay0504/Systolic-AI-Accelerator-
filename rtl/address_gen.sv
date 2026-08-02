// -----------------------------------------------------------------------------
// address_gen.sv
//
// Address generation for a fixed 4x4 weight-stationary systolic array. Produces
// the read addresses for weight_mem and act_mem and the row address for
// output_mem, sequenced per phase.
//
// This module answers "WHICH ADDRESS, given the current phase". It does not
// decide phases -- that is the controller's job, and `phase` arrives here as an
// input. Keeping the two apart is deliberate: address sequencing and phase
// sequencing fail in different ways and are easier to debug separately.
//
// One full multiply per run. Matrices SMALLER than the array are supported via
// padding: `K_real` gives the real inner (contraction) dimension, and the two
// mask outputs mark which rows are structurally padding. Tiling (matrices larger
// than the array) is still out of scope.
//
// -----------------------------------------------------------------------------
// PADDING -- what this module does and does not do
// -----------------------------------------------------------------------------
// Only K matters here. A is padded in its columns beyond K_real and B in its
// rows beyond K_real, and both are the same unused inner-dimension rows. M (rows
// of A/C) and N (columns of B/C) decide which OUTPUT rows and columns are
// meaningful, which is a read-back concern for the host: the array computes a
// full NxN output either way and the host simply does not read the unused part.
// There are deliberately no M_real/N_real ports.
//
// Padding does NOT mean "issue fewer addresses". Every address is still issued
// and every enable still asserts for all N cycles whatever K_real is; the masks
// only tell the two edge muxes in accelerator_top to substitute zero for what
// those reads return. That keeps this module's cycle timing identical for every
// K_real, which is precisely what lets control_unit stay untouched. Reading a
// padded row costs one irrelevant memory access and nothing else.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (verification contract for the padding extension)
// -----------------------------------------------------------------------------
//   * With K_real = N, pad_weight and pad_act are all-zero -- the full-size case
//     is byte-for-byte unaffected by this extension.
//   * With K_real < N, exactly the top N-K_real rows (indices K_real .. N-1) are
//     marked padded and the bottom K_real rows are not.
//   * Address sequences, enables and addr_done timing are IDENTICAL regardless
//     of K_real. Only the two mask outputs change.
//
// -----------------------------------------------------------------------------
// THE ONE-CYCLE READ LATENCY CONTRACT -- read this before wiring the controller
// -----------------------------------------------------------------------------
// All three memories have a registered read: an address presented on cycle t
// yields data on cycle t+1. This module issues one address per cycle of its
// phase, starting on the phase's first cycle. Therefore:
//
//     THE CONTROLLER MUST ASSERT EACH PHASE ONE CYCLE BEFORE THE ARRAY NEEDS
//     THE FIRST PIECE OF DATA FROM THAT PHASE.
//
// Concretely, for the load phase: this module issues address N-1 on the first
// LOAD cycle, so B's bottom row appears on weight_mem.rd_data on the SECOND
// LOAD cycle. The array's `wload` must therefore be asserted one cycle after
// `phase` becomes LOAD, and stay high for N cycles.
//
// Get this wrong in either direction and the array loads B shifted by one row --
// which still produces a full, plausible-looking C, just the wrong one.
//
// -----------------------------------------------------------------------------
// PHASE ENCODING
// -----------------------------------------------------------------------------
// `phase` is a plain 2-bit input rather than an enum so it can cross a module
// boundary without a shared package. The controller must use this same encoding;
// when the controller lands, consider hoisting these four values into a package
// so there is one definition rather than two that must agree.
// -----------------------------------------------------------------------------

module address_gen #(
    parameter int N      = 4,               // array dimension
    parameter int DEPTH  = 16,              // rows per memory
    parameter int ADDR_W = $clog2(DEPTH)    // derived -- do not override
) (
    input  logic                     clk,
    input  logic                     rst_n,   // active-low, synchronous
    input  logic                     start,   // pulse: begin one full sequence
    input  logic [1:0]               phase,   // from the controller

    // Real inner (contraction) dimension for this run, 1..N. N means no padding.
    input  logic [$clog2(N+1)-1:0]   K_real,

    // Padding masks -- combinational in K_real only, not in phase or the
    // counters. Consumed by the two edge muxes in accelerator_top.
    output logic                     pad_weight [0:N-1],
    output logic                     pad_act    [0:N-1],

    // weight_mem read port
    output logic [ADDR_W-1:0] weight_rd_addr,
    output logic              weight_rd_en,

    // act_mem read port
    output logic [ADDR_W-1:0] act_rd_addr,
    output logic              act_rd_en,

    // output_mem write port -- row address only, see the note below
    output logic [ADDR_W-1:0] out_wr_addr,
    output logic              out_wr_en,

    // this module has issued its full address sequence for the current phase
    output logic              addr_done
);

    // Phase encoding -- must match the controller.
    localparam logic [1:0] PH_IDLE    = 2'd0;
    localparam logic [1:0] PH_LOAD    = 2'd1;
    localparam logic [1:0] PH_COMPUTE = 2'd2;
    localparam logic [1:0] PH_DRAIN   = 2'd3;

    // -------------------------------------------------------------------------
    // Counters. Each has an `active` flag rather than being allowed to wrap:
    // once a sequence has issued its last address it stops dead until the next
    // start, so a phase held longer than expected cannot re-read address 0 and
    // quietly corrupt the run.
    // -------------------------------------------------------------------------
    logic [ADDR_W-1:0] w_addr_q;   logic w_active_q;   // weights: down-counter
    logic [ADDR_W-1:0] a_addr_q;   logic a_active_q;   // activations: up-counter
    logic [ADDR_W-1:0] o_addr_q;   logic o_active_q;   // output rows: up-counter

    // Issue conditions, shared by the counter updates and the enables below.
    logic w_issue, a_issue, o_issue;

    always_comb begin
        w_issue = (phase == PH_LOAD)    && w_active_q;
        a_issue = (phase == PH_COMPUTE) && a_active_q;
        o_issue = (phase == PH_DRAIN)   && o_active_q;
    end

    // -------------------------------------------------------------------------
    // WEIGHT LOAD COUNTER -- counts DOWN, from N-1 to 0.
    //
    // The direction is the whole point. During the load pass a weight entering
    // the top of a column shifts down one PE per cycle, so the weight presented
    // FIRST travels furthest and lands in the BOTTOM row. Column j must
    // therefore be fed B's bottom row first, which with B stored row-major means
    // reading addresses N-1, N-2, ... 1, 0.
    //
    // The reversal lives here and ONLY here. weight_mem reads whatever address
    // it is given -- if it reversed as well, the two would cancel and B would
    // load upside down.
    //
    // Address issued on cycle t -> data available on cycle t+1 (registered read).
    //
    // The counter's RANGE is deliberately untouched by padding: it still walks
    // N-1 down to 0 for every K_real. See the header for why padding masks
    // rather than shortens the sequence.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            w_addr_q   <= ADDR_W'(N-1);
            w_active_q <= 1'b1;
        end else if (w_issue) begin
            if (w_addr_q == '0) w_active_q <= 1'b0;    // 0 was the last address
            else                w_addr_q   <= w_addr_q - 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // WEIGHT PADDING MASK  (replaces the PADDING SEAM that was here)
    //
    // Row k of B is real if k < K_real and padding otherwise. This indexes B's
    // rows directly -- the row that would be read at address k -- not the load
    // cycle, so the down-counter's ordering does not enter into it. The top-edge
    // mux in accelerator_top substitutes zero for a masked row.
    // -------------------------------------------------------------------------
    always_comb begin
        for (int k = 0; k < N; k++)
            pad_weight[k] = (k >= int'(K_real));
    end

    // -------------------------------------------------------------------------
    // ACTIVATION ADDRESS COUNTER -- counts UP, 0 to N-1, then stops.
    //
    // One column of A per cycle, walked forward. This module does NOT stagger
    // anything: the columns leave act_mem un-skewed, all lanes together, and the
    // skew buffer downstream produces the triangular wavefront the array needs.
    //
    // Once all N columns have been issued the counter stops and act_rd_en drops.
    // It does not wrap and does not keep incrementing past N-1.
    //
    // Address issued on cycle t -> data available on cycle t+1 (registered read).
    //
    // As with the weight counter, the range is untouched by padding: all N
    // addresses are issued for every K_real.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            a_addr_q   <= '0;
            a_active_q <= 1'b1;
        end else if (a_issue) begin
            if (a_addr_q == ADDR_W'(N-1)) a_active_q <= 1'b0;
            else                          a_addr_q   <= a_addr_q + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // ACTIVATION PADDING MASK  (replaces the PADDING SEAM that was here)
    //
    // Lane k of the left edge carries column k of A, so lane k is real if
    // k < K_real and padding otherwise. The zero-injection mux ahead of the skew
    // buffer substitutes zero for a masked lane.
    //
    // This ends up identical to pad_weight, because both describe the same
    // unused inner-dimension rows. They are kept as two separately-named outputs
    // on purpose: a later reader wiring the two edges should not have to derive
    // from first principles that weight and activation padding always coincide.
    // -------------------------------------------------------------------------
    always_comb begin
        for (int k = 0; k < N; k++)
            pad_act[k] = (k >= int'(K_real));
    end

    // -------------------------------------------------------------------------
    // OUTPUT ROW COUNTER -- counts UP, 0 to N-1, one row per DRAIN cycle.
    //
    // Results reach output_mem as full, de-skewed rows, one per cycle, so the
    // row address simply advances once per cycle the drain phase is active.
    //
    // NOTE ON out_wr_en: the decision to write a given LANE belongs to that
    // lane's valid_out after de-skew, not to this module. out_wr_en here means
    // "the row address is valid this cycle" -- AND it with the per-lane valid at
    // the memory, do not use it alone as a row-wide write enable.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || start) begin
            o_addr_q   <= '0;
            o_active_q <= 1'b1;
        end else if (o_issue) begin
            if (o_addr_q == ADDR_W'(N-1)) o_active_q <= 1'b0;
            else                          o_addr_q   <= o_addr_q + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Address / enable derivation. Addresses are the raw counters; the enables
    // are what say whether they mean anything this cycle.
    // -------------------------------------------------------------------------
    always_comb begin
        weight_rd_addr = w_addr_q;
        act_rd_addr    = a_addr_q;
        out_wr_addr    = o_addr_q;

        weight_rd_en   = w_issue;
        act_rd_en      = a_issue;
        out_wr_en      = o_issue;
    end

    // -------------------------------------------------------------------------
    // addr_done -- "my sequence for the phase you are currently in is finished".
    // The controller uses this to know when it may advance. It is per-phase, not
    // global: in IDLE there is no sequence to finish, so it reads 0.
    // -------------------------------------------------------------------------
    always_comb begin
        case (phase)
            PH_LOAD:    addr_done = !w_active_q;
            PH_COMPUTE: addr_done = !a_active_q;
            PH_DRAIN:   addr_done = !o_active_q;
            default:    addr_done = 1'b0;      // PH_IDLE
        endcase
    end

    // -------------------------------------------------------------------------
    // K_real range check, simulation only.
    //
    // K_real = 0 or K_real > N is a configuration error by the host, not a case
    // this module should quietly produce garbage for: K_real=0 would mask every
    // row and compute an all-zero product that looks like a working accelerator
    // fed zeros. Checked at `start`, which is the moment the value is committed
    // to for the run.
    // -------------------------------------------------------------------------
`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && start)
            if (!((K_real >= 1) && (int'(K_real) <= N)))
                $error("address_gen: K_real=%0d out of range 1..%0d at start (time %0t)",
                       K_real, N, $time);
    end
`endif

endmodule
