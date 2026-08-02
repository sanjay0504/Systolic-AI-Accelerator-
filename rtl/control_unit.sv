// -----------------------------------------------------------------------------
// control_unit.sv
//
// Top-level control FSM for the weight-stationary systolic array accelerator.
// Sequences LOAD -> COMPUTE -> DRAIN, drives `phase` into address_gen and
// `wload` into the array, and reports completion.
//
// This module answers "WHICH PHASE, right now". address_gen answers "which
// address, given the phase". The split is deliberate: phase sequencing and
// address sequencing fail in different ways and are far easier to debug apart.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (verification contract)
// -----------------------------------------------------------------------------
//   * `wload` is asserted for exactly N cycles, offset one cycle later than
//     `phase == PH_LOAD`.
//   * The FSM never starts a new run while still draining a previous one: a
//     `start` pulse is only acted on in IDLE or DONE.
//   * `done` is a LEVEL held high from completion until the next `start`, not a
//     single-cycle pulse.
//   * Reset returns the FSM to IDLE with done=0, wload=0, phase=PH_IDLE, from
//     whatever state it was in.
//
// -----------------------------------------------------------------------------
// THE ONE-CYCLE OFFSET CONTRACT -- the most important detail in this module
// -----------------------------------------------------------------------------
// address_gen issues its first LOAD address on the FIRST cycle of PH_LOAD, and
// the memories have a 1-cycle registered read, so B's bottom row does not appear
// on weight_mem.rd_data until the SECOND cycle of LOAD.
//
// `wload` therefore asserts one cycle AFTER phase becomes PH_LOAD. Asserting it
// on the same cycle feeds the array whatever was on the bus beforehand and
// shifts the whole weight matrix down one row -- which still produces a full,
// plausible-looking C, just the wrong one. That is the failure this module
// exists to prevent, and it is implemented explicitly below rather than falling
// out of the state encoding.
//
// LOAD therefore lasts N+1 cycles, and the arithmetic works out exactly:
//
//     LOAD cycle :  0     1     2    ...   N-1    N
//     addr issued:  N-1   N-2   N-3  ...   0      --      (N addresses)
//     data valid :  --    N-1   N-2  ...   1      0       (N rows delivered)
//     wload      :  0     1     1    ...   1      1       (N cycles, offset by 1)
//     addr_done  :  0     0     0    ...   0      1
//
// The trailing cycle is not slack -- it is when the last weight row actually
// arrives.
// -----------------------------------------------------------------------------

module control_unit #(
    parameter int N = 4,

    // How many assertions of `array_last_valid` mark the end of the run.
    //
    // The port is documented as "the array's last column, valid_out[N-1]", and
    // that signal pulses ONCE PER RESULT ROW -- N times, with C[N-1][N-1] on the
    // last of them. Leaving DRAIN on the first pulse would cut the run short
    // after a single row, so the default counts N.
    //
    // If a top level instead supplies a single pre-qualified end-of-run pulse,
    // set this to 1. It is a parameter precisely because the two readings of
    // that port are incompatible and the choice must be visible.
    parameter int LAST_VALID_CNT = N
) (
    input  logic       clk,
    input  logic       rst_n,             // active-low, synchronous
    input  logic       start,             // pulse: begin one full sequence
    input  logic       addr_done,         // from address_gen, current phase
    input  logic       array_last_valid,  // from the array's last column

    output logic [1:0] phase,             // to address_gen
    output logic       wload,             // to the systolic array
    output logic       done               // held high until the next start
);

    // Phase encoding -- must match address_gen.sv exactly.
    localparam logic [1:0] PH_IDLE    = 2'd0;
    localparam logic [1:0] PH_LOAD    = 2'd1;
    localparam logic [1:0] PH_COMPUTE = 2'd2;
    localparam logic [1:0] PH_DRAIN   = 2'd3;

    typedef enum logic [2:0] {
        S_IDLE    = 3'd0,
        S_LOAD    = 3'd1,
        S_COMPUTE = 3'd2,
        S_DRAIN   = 3'd3,
        S_DONE    = 3'd4
    } state_e;

    state_e state_q, state_d;

    // Counts result rows seen during DRAIN. Wide enough to hold N.
    logic [$clog2(N+1)-1:0] lv_cnt_q;
    logic                   drain_complete;

    logic wload_q;

    // -------------------------------------------------------------------------
    // Next-state logic
    //
    // `start` is only examined in IDLE and DONE, so a stray pulse mid-run cannot
    // restart the phase sequence on top of a multiply already in flight.
    //
    // SYSTEM-LEVEL NOTE: address_gen reloads its counters on `start`
    // unconditionally, whatever phase it is in. This FSM ignoring a mid-run
    // start is therefore not sufficient on its own -- the top level must not
    // pulse start until `done` is high, or must gate it with (done | idle).
    // -------------------------------------------------------------------------
    always_comb begin
        state_d = state_q;
        case (state_q)
            S_IDLE:    if (start)          state_d = S_LOAD;

            // N addresses issued; addr_done is visible on the extra cycle in
            // which the last weight row is actually delivered.
            S_LOAD:    if (addr_done)      state_d = S_COMPUTE;

            // addr_done here means all N activation columns have been ISSUED --
            // not that results have finished emerging. DRAIN exists to wait out
            // the remaining pipeline latency.
            S_COMPUTE: if (addr_done)      state_d = S_DRAIN;

            S_DRAIN:   if (drain_complete) state_d = S_DONE;

            S_DONE:    if (start)          state_d = S_LOAD;

            default:                       state_d = S_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) state_q <= S_IDLE;
        else        state_q <= state_d;
    end

    // -------------------------------------------------------------------------
    // DRAIN completion.
    //
    // Data-driven, not a fixed cycle count, and deliberately so. The number of
    // cycles between the last activation address and the last result depends on
    // N and on how many pipeline stages sit in the datapath -- skew buffer,
    // output processing, de-skew. A hardcoded count would be silently wrong the
    // first time N changes or anyone inserts a register stage, and the symptom
    // would be a truncated result matrix rather than an obvious break. Counting
    // actual results cannot drift out of step with the hardware.
    // -------------------------------------------------------------------------
    always_comb
        drain_complete = array_last_valid &&
                         (lv_cnt_q == ($clog2(N+1))'(LAST_VALID_CNT - 1));

    always_ff @(posedge clk) begin
        if (!rst_n)                      lv_cnt_q <= '0;
        else if (state_q != S_DRAIN)     lv_cnt_q <= '0;   // armed on every entry
        else if (array_last_valid)       lv_cnt_q <= lv_cnt_q + 1'b1;
    end

    // -------------------------------------------------------------------------
    // wload -- THE ONE-CYCLE OFFSET, implemented explicitly.
    //
    // wload is a registered copy of "address_gen is actively issuing weight
    // addresses". Since a weight row issued on cycle t arrives on cycle t+1,
    // delaying that flag by one cycle makes wload high exactly on the cycles
    // when weight data is present on the bus -- never on LOAD's first cycle,
    // when the bus still holds whatever preceded it.
    //
    //   NOT  wload = (state_q == S_LOAD)          <-- one cycle too early
    //   NOT  wload = (state_q == S_LOAD) delayed  <-- one cycle too long, leaks
    //                                                 into COMPUTE
    //
    // Excluding the cycle where addr_done is already high is what trims that
    // trailing cycle, giving exactly N. Registered, so it is glitch-free where
    // it crosses into the array.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) wload_q <= 1'b0;
        else        wload_q <= (state_q == S_LOAD) && !addr_done;
    end

    assign wload = wload_q;

    // -------------------------------------------------------------------------
    // Moore outputs, decoded from the state register only, so nothing
    // combinationally downstream sees a glitch on a phase change.
    //
    // `done` is the S_DONE state itself: the FSM parks there and holds done high
    // until a start moves it to LOAD, which is what makes done a level rather
    // than a pulse. S_IDLE is only ever reached from reset.
    // -------------------------------------------------------------------------
    always_comb begin
        case (state_q)
            S_LOAD:    phase = PH_LOAD;
            S_COMPUTE: phase = PH_COMPUTE;
            S_DRAIN:   phase = PH_DRAIN;
            default:   phase = PH_IDLE;      // S_IDLE, S_DONE
        endcase
    end

    assign done = (state_q == S_DONE);

endmodule
