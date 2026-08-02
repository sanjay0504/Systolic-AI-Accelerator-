// -----------------------------------------------------------------------------
// accelerator_top.sv
//
// Top level for the reconfigurable weight-stationary matrix-multiplication
// accelerator. Structural wiring of already-verified sub-modules; no sub-module
// internals are reimplemented here.
//
//   weight_mem --> systolic_array (top edge, during LOAD)
//   act_mem    --> skew_buffer(REVERSE=0) --> systolic_array (left edge)
//   systolic_array --> output_processing --> skew_buffer(REVERSE=1) --> output_mem
//   control_unit <-> address_gen drive the whole sequence
//
// External interface: preload weight_mem and act_mem through their write ports,
// pulse `start`, wait for `done`, read C back through out_rd_*. Nothing internal
// is exposed at the boundary.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (verification contract)
// -----------------------------------------------------------------------------
//   * `wload` and `weight_mem.rd_data` become valid on the SAME cycle. Both
//     carry exactly one cycle of delay -- the memory's registered read, and
//     control_unit's internal offset -- and they must land together. No second
//     delay register is added here.
//   * `skew_buffer[skew].valid_in` and `act_mem.rd_data` become valid on the
//     SAME cycle. This needs the one explicit delay register in this file,
//     because act_rd_en leads its own data by a cycle.
//   * `control_unit.array_last_valid` is driven from the DE-SKEWED last-column
//     valid, never the raw array output.
//   * No internal module signal appears on the external port list.
//   * With K_real = N both pad masks are all-zero, so weight_to_array and
//     act_to_skew are identical to the raw memory outputs -- the unpadded case
//     is byte-for-byte unaffected by the padding extension.
//   * The pad muxes add NO latency: they are combinational and sit inside the
//     same cycle the memory data was already valid on, so both timing contracts
//     above are untouched.
//   * valid_in is not muxed on either edge. A padded row is still valid data as
//     far as the pipeline is concerned -- valid-and-zero rather than
//     valid-and-real -- and zero contributes nothing to an accumulation, so the
//     arithmetic comes out right without the array knowing padding exists.
//
// -----------------------------------------------------------------------------
// NEW LOGIC IN THIS FILE (everything else is a direct port connection)
// -----------------------------------------------------------------------------
//   1. act_rd_en delayed by one cycle to form the skew buffer's valid_in.
//      Specified, and explained at the register itself.
//   2. An output row counter paced by de-skewed row arrivals. NOT in the
//      original wiring plan -- see the OUTPUT ROW ADDRESSING block below for the
//      cycle arithmetic that forces it. Read that before changing it.
//
// -----------------------------------------------------------------------------
// PADDING / TILING
// -----------------------------------------------------------------------------
// Out of scope. A future pad[]/tiling control interface would attach here as
// extra top-level inputs fanning out to the two seams already commented in
// address_gen.sv (weight counter range + activation zero-injection mask).
// -----------------------------------------------------------------------------

module accelerator_top #(
    parameter int N        = 4,     // array dimension
    parameter int DEPTH    = 16,    // rows per memory
    parameter int IN_W     = 8,     // activation / weight width
    parameter int ACC_W    = 32,    // accumulator width
    parameter int DW_OUT   = 8,     // post-processing output width
    parameter int USE_BIAS = 0,     // output_processing mode: bias adder
    parameter int USE_RELU = 0,     // output_processing mode: ReLU
    parameter int SHIFT    = 8,     // output_processing scale-down amount
    parameter int ADDR_W   = $clog2(DEPTH)   // derived -- do not override
) (
    input  logic               clk,
    input  logic               rst_n,

    // Run control
    input  logic               start,           // begin one full multiply
    output logic               done,            // held high until the next start

    // Real inner (contraction) dimension for this run, 1..N. N means no padding.
    // Passed straight through to address_gen, which derives the two pad masks.
    input  logic [$clog2(N+1)-1:0] K_real,

    // Setup: load matrix B
    input  logic               weight_wr_en,
    input  logic [ADDR_W-1:0]  weight_wr_addr,
    input  logic [IN_W-1:0]    weight_wr_data [0:N-1],

    // Setup: load matrix A
    input  logic               act_wr_en,
    input  logic [ADDR_W-1:0]  act_wr_addr,
    input  logic [IN_W-1:0]    act_wr_data    [0:N-1],

    // Read-back: retrieve matrix C
    input  logic               out_rd_en,
    input  logic [ADDR_W-1:0]  out_rd_addr,
    output logic [DW_OUT-1:0]  out_rd_data    [0:N-1]
);

    // -------------------------------------------------------------------------
    // Internal nets
    // -------------------------------------------------------------------------
    logic [1:0]        phase;
    logic              wload;
    logic              addr_done;
    logic              array_last_valid;

    logic [ADDR_W-1:0] weight_rd_addr;
    logic              weight_rd_en;
    logic [ADDR_W-1:0] act_rd_addr;
    logic              act_rd_en;
    logic [ADDR_W-1:0] ag_out_wr_addr;      // see OUTPUT ROW ADDRESSING
    logic              ag_out_wr_en;

    logic [IN_W-1:0]   wmem_rd_data [0:N-1];
    logic [IN_W-1:0]   amem_rd_data [0:N-1];

    // Padding masks from address_gen, and the two muxed edge buses they gate.
    logic              pad_weight     [0:N-1];
    logic              pad_act        [0:N-1];
    logic [IN_W-1:0]   weight_to_array[0:N-1];   // wmem_rd_data after the pad mux
    logic [IN_W-1:0]   act_to_skew    [0:N-1];   // amem_rd_data after the pad mux

    logic [IN_W-1:0]   sk_data_out  [0:N-1];
    logic              sk_valid_out [0:N-1];
    logic              sk_valid_in  [0:N-1];

    logic signed [ACC_W-1:0]  arr_psum   [0:N-1];
    logic                     arr_valid  [0:N-1];

    logic signed [DW_OUT-1:0] op_data    [0:N-1];
    logic                     op_valid   [0:N-1];
    logic signed [ACC_W-1:0]  op_bias    [0:N-1];

    logic [DW_OUT-1:0] ds_data_in   [0:N-1];
    logic [DW_OUT-1:0] ds_data_out  [0:N-1];
    logic              ds_valid_out [0:N-1];

    // Sign-reinterpretation hops. The memories and skew buffers carry opaque
    // bits (`logic`), while the array and output_processing declare theirs
    // `signed`. Unpacked-array port connections require equivalent types and
    // signedness is part of the type, so each crossing gets an explicit
    // same-bits reinterpretation rather than a silent connection.
    logic signed [IN_W-1:0]   arr_weight_top [0:N-1];
    logic signed [IN_W-1:0]   arr_a_in       [0:N-1];

    generate
        for (genvar k = 0; k < N; k++) begin : g_type_hops
            assign arr_weight_top[k] = signed'(weight_to_array[k]); // pad mux  -> array
            assign arr_a_in[k]       = signed'(sk_data_out[k]);     // skew     -> array
            assign ds_data_in[k]     = unsigned'(op_data[k]);       // out_proc -> de-skew
            assign op_bias[k]        = '0;                          // see below
        end
    endgenerate

    // output_processing.bias is tied off here because USE_BIAS defaults to 0 and
    // the module then instantiates no adder at all. Driving it explicitly rather
    // than leaving it dangling keeps X out of the waveform. If USE_BIAS=1 is
    // ever selected, replace this tie-off with a real top-level bias input port.

    // =========================================================================
    // CONTROL <-> ADDRESS GENERATION
    // =========================================================================
    control_unit #(
        .N               (N),
        .LAST_VALID_CNT  (N)          // one assertion per result row
    ) u_control (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (start),
        .addr_done        (addr_done),         // <- address_gen
        .array_last_valid (array_last_valid),  // <- de-skewed last column
        .phase            (phase),             // -> address_gen
        .wload            (wload),             // -> systolic_array
        .done             (done)               // -> top level
    );

    address_gen #(
        .N     (N),
        .DEPTH (DEPTH)
    ) u_addrgen (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .phase          (phase),               // <- control_unit
        .K_real         (K_real),              // <- top level
        .pad_weight     (pad_weight),          // -> weight edge mux
        .pad_act        (pad_act),             // -> activation edge mux
        .weight_rd_addr (weight_rd_addr),
        .weight_rd_en   (weight_rd_en),
        .act_rd_addr    (act_rd_addr),
        .act_rd_en      (act_rd_en),
        .out_wr_addr    (ag_out_wr_addr),      // see OUTPUT ROW ADDRESSING
        .out_wr_en      (ag_out_wr_en),
        .addr_done      (addr_done)            // -> control_unit
    );

    // =========================================================================
    // WEIGHT PATH (array top edge)
    //
    // CRITICAL TIMING: weight_mem has a registered read, so rd_data is valid one
    // cycle after weight_rd_addr/rd_en are issued. control_unit.wload is ALREADY
    // delayed one cycle relative to phase becoming LOAD. Those two delays are
    // the same delay, and they land together:
    //
    //   LOAD cycle :  0      1      2    ...  N-1    N
    //   addr issued:  N-1    N-2    N-3  ...  0      --
    //   rd_data    :  --     B[N-1] B[N-2] .. B[1]   B[0]
    //   wload      :  0      1      1    ...  1      1
    //
    // No delay register is added on this path. A second one here would double
    // the offset and load B shifted by a row -- a full, plausible, wrong C.
    //
    // The bottom-row-first ordering comes entirely from address_gen's
    // down-counter. Nothing on this path re-reverses it.
    // =========================================================================
    weight_mem #(
        .N     (N),
        .DW    (IN_W),
        .DEPTH (DEPTH)
    ) u_weight_mem (
        .clk      (clk),
        .rst_n    (rst_n),
        .rd_en    (weight_rd_en),          // <- address_gen
        .rd_addr  (weight_rd_addr),        // <- address_gen
        .rd_data  (wmem_rd_data),          // -> array top edge (via sign hop)
        .wr_en    (weight_wr_en),          // <- top level setup
        .wr_addr  (weight_wr_addr),
        .wr_data  (weight_wr_data)
    );

    // -------------------------------------------------------------------------
    // WEIGHT EDGE PAD MUX -- zero the top edge while a padded row of B is on it.
    //
    // INDEXING, which is the thing to get right here: pad_weight[r] describes
    // ROW r OF B, not lane r. The weight bus carries one whole row of B at a
    // time -- row N-1 first, then N-2, ... -- so the mask has to be selected by
    // WHICH ROW IS CURRENTLY ON THE BUS and then applied to every lane of it.
    //
    // Gating lane k with pad_weight[k] instead would zero B's COLUMNS beyond
    // K_real. Columns of B are output columns of C, and which of those are
    // meaningful is set by N, not K -- so for any run with K_real < N_real that
    // would blank real output columns while the masks themselves still looked
    // perfectly correct.
    //
    // weight_row_q is weight_rd_addr delayed one cycle, because weight_mem's
    // read is registered: the data on the bus this cycle came from the address
    // issued last cycle. The register sits on the ADDRESS path, in parallel with
    // the memory's own, so the data path gains no latency.
    // -------------------------------------------------------------------------
    logic [ADDR_W-1:0] weight_row_q;
    logic              weight_row_is_pad;

    always_ff @(posedge clk) begin
        if (!rst_n) weight_row_q <= '0;
        else        weight_row_q <= weight_rd_addr;
    end

    // Compared rather than used as an index, so an address outside 0..N-1 (which
    // the weight counter never produces, but reset and other phases can leave
    // behind) resolves to "not padded" instead of reading off the end.
    always_comb begin
        weight_row_is_pad = 1'b0;
        for (int r = 0; r < N; r++)
            if (weight_row_q == ADDR_W'(r)) weight_row_is_pad = pad_weight[r];
    end

    generate
        for (genvar k = 0; k < N; k++) begin : g_weight_pad_mux
            assign weight_to_array[k] = weight_row_is_pad ? '0 : wmem_rd_data[k];
        end
    endgenerate

    // =========================================================================
    // ACTIVATION PATH (array left edge)
    //
    // CRITICAL TIMING: act_mem's read is registered too, so rd_data lags
    // act_rd_en by one cycle. Handing act_rd_en straight to the skew buffer
    // would tell it the data is valid a cycle before it exists -- it would
    // stagger a bus still holding the previous contents, and every activation
    // would be one position out.
    //
    // Hence the single delay register below: the ONLY piece of new sequential
    // logic in this file. It exists in no sub-module because no sub-module knows
    // it sits behind a memory.
    //
    // Note on row-vs-column: act_mem holds A row-major and returns a whole row
    // per cycle. On compute cycle t the skew buffer receives row t, so lane k
    // carries A[t][k] -- exactly "column k of A on lane k" as seen from the
    // array. No transpose is needed anywhere.
    // =========================================================================
    act_mem #(
        .N     (N),
        .DW    (IN_W),
        .DEPTH (DEPTH)
    ) u_act_mem (
        .clk      (clk),
        .rst_n    (rst_n),
        .rd_en    (act_rd_en),             // <- address_gen
        .rd_addr  (act_rd_addr),           // <- address_gen
        .rd_data  (amem_rd_data),          // -> skew buffer
        .wr_en    (act_wr_en),             // <- top level setup
        .wr_addr  (act_wr_addr),
        .wr_data  (act_wr_data)
    );

    // The one-cycle alignment register. Every lane is enabled together, since a
    // whole row leaves act_mem at once.
    logic act_rd_en_q;

    always_ff @(posedge clk) begin
        if (!rst_n) act_rd_en_q <= 1'b0;
        else        act_rd_en_q <= act_rd_en;
    end

    generate
        for (genvar k = 0; k < N; k++) begin : g_act_valid
            assign sk_valid_in[k] = act_rd_en_q;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // ACTIVATION EDGE PAD MUX -- zero the lanes beyond the real inner dimension.
    //
    // Here the lane index IS the contraction index: lane k of the left edge
    // carries column k of A and feeds array row k, which holds B's row k. So
    // pad_act[k] gates lane k directly, and zeroing it kills the A[i][k]*B[k][j]
    // term for every i and j at once. That is what makes the arithmetic come out
    // right no matter what the padded memory rows contain.
    //
    // valid_in is deliberately NOT muxed, on this edge or the weight edge. A
    // padded lane still presents valid data; it is valid-and-zero. Suppressing
    // valid instead would punch a bubble in the skew buffer's triangle and
    // desynchronise the whole wavefront, and it would gain nothing -- multiplying
    // by zero already contributes nothing to the accumulation.
    // -------------------------------------------------------------------------
    generate
        for (genvar k = 0; k < N; k++) begin : g_act_pad_mux
            assign act_to_skew[k] = pad_act[k] ? '0 : amem_rd_data[k];
        end
    endgenerate

    skew_buffer #(
        .N       (N),
        .DW      (IN_W),
        .REVERSE (0)                       // input skew
    ) u_skew (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (act_to_skew),          // <- act_mem, via the pad mux
        .valid_in  (sk_valid_in),          // <- act_rd_en delayed one cycle
        .data_out  (sk_data_out),          // -> array left edge (via sign hop)
        .valid_out (sk_valid_out)
    );

    // =========================================================================
    // COMPUTE DATAPATH
    // =========================================================================
    systolic_array #(
        .N     (N),
        .IN_W  (IN_W),
        .ACC_W (ACC_W)
    ) u_array (
        .clk        (clk),
        .rst_n      (rst_n),
        .wload      (wload),               // <- control_unit, already offset
        .a_in       (arr_a_in),            // <- skew buffer
        .valid_in   (sk_valid_out),        // <- skew buffer, tag travels with data
        .weight_top (arr_weight_top),      // <- weight_mem
        .psum_out   (arr_psum),            // -> output_processing
        .valid_out  (arr_valid)
    );

    output_processing #(
        .N        (N),
        .ACC_W    (ACC_W),
        .DW_OUT   (DW_OUT),
        .SHIFT    (SHIFT),
        .USE_BIAS (USE_BIAS),
        .USE_RELU (USE_RELU)
    ) u_outproc (
        .psum_in   (arr_psum),             // <- array bottom edge, raw ACC_W
        .valid_in  (arr_valid),
        .bias      (op_bias),              // tied off, see above
        .data_out  (op_data),              // -> de-skew (via sign hop)
        .valid_out (op_valid)              // combinational passthrough of valid_in
    );

    // De-skew: the array emits results on a diagonal (C[n][j] at cycle N+n+j),
    // and lane j delayed by N-1-j realigns them so a whole row of C emerges on
    // one cycle. output_processing is combinational, so it does not disturb this.
    skew_buffer #(
        .N       (N),
        .DW      (DW_OUT),
        .REVERSE (1)                       // output de-skew
    ) u_deskew (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (ds_data_in),           // <- output_processing
        .valid_in  (op_valid),
        .data_out  (ds_data_out),          // -> output_mem
        .valid_out (ds_valid_out)
    );

    // =========================================================================
    // DRAIN COMPLETION
    //
    // Taken from the DE-SKEWED last-column valid, not the raw array valid: the
    // de-skew buffer adds up to N-1 cycles of pipeline, so the raw valid would
    // report completion before the last row had actually been realigned and
    // written.
    // =========================================================================
    assign array_last_valid = ds_valid_out[N-1];

    // =========================================================================
    // OUTPUT ROW ADDRESSING  -- deviation from the original wiring plan
    //
    // The plan wires address_gen.out_wr_addr/out_wr_en straight to output_mem.
    // That does not work, and the arithmetic says why. Taking absolute cycle 0
    // as LOAD's first cycle:
    //
    //   LOAD    spans cycles 0 .. N          (N+1 cycles)
    //   COMPUTE spans cycles N+1 .. 2N+1     (N+1 cycles)
    //   DRAIN   begins at cycle 2N+2
    //
    //   first activation reaches the array at cycle N+2, so the array's own
    //   compute cycle 0 is absolute N+2;
    //   C[n][j] leaves the array at absolute 2N+2+n+j;
    //   de-skew adds N-1-j, cancelling j, so ROW n lands at absolute 3N+1+n.
    //
    // Rows therefore arrive over cycles 3N+1 .. 4N, while address_gen's
    // DRAIN-paced counter runs 2N+2 .. 3N+1. They overlap for exactly one cycle.
    // Wired directly, row 0 would be written to address N-1 and rows 1..N-1
    // would not be written at all, because out_wr_en has already dropped.
    //
    // The row address must therefore be paced by the ARRIVALS, not by DRAIN
    // cycles. That is what this counter does. Lanes are aligned after de-skew,
    // so lane 0's valid marks a whole row.
    //
    // PROPER FIX, for when the modules are next touched: give address_gen a
    // `row_valid` input and let this counter live there, where the rest of the
    // address generation already is. This local counter is the minimal correct
    // wiring available without changing a verified module's interface.
    // =========================================================================
    logic [ADDR_W-1:0] out_row_q;
    logic              out_row_valid;

    assign out_row_valid = ds_valid_out[0];

    always_ff @(posedge clk) begin
        if (!rst_n || start)     out_row_q <= '0;
        else if (out_row_valid)  out_row_q <= out_row_q + 1'b1;
    end

    // ag_out_wr_addr / ag_out_wr_en are left unconnected downstream on purpose;
    // they become the drivers again once address_gen owns this counter.

    output_mem #(
        .N     (N),
        .DW    (DW_OUT),
        .DEPTH (DEPTH)
    ) u_output_mem (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (out_row_valid),         // row address is valid this cycle
        .wr_addr  (out_row_q),
        .wr_data  (ds_data_out),           // <- de-skew
        .wr_valid (ds_valid_out),          // per-lane, gates each element
        .rd_en    (out_rd_en),             // <- top level read-back
        .rd_addr  (out_rd_addr),
        .rd_data  (out_rd_data)
    );

endmodule
