// -----------------------------------------------------------------------------
// uart_rx_fpga.sv
//
// Standard 8-N-1 UART receiver for FPGA deployment. New, standalone hardware:
// it neither modifies nor depends on any module in the accelerator datapath.
//
// Frame format, which is the whole specification:
//
//     idle   start        d0   d1   d2   d3   d4   d5   d6   d7   stop   idle
//     ----\______/`````\____/````\ ... /`````\_________/````````````-------
//          1 bit low    8 data bits, LSB FIRST            1 bit high
//
// No parity. One start bit, eight data bits least-significant first, one stop
// bit. `byte_valid` pulses for exactly one clock cycle when `data_out` holds a
// complete, freshly received byte.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (verification contract)
// -----------------------------------------------------------------------------
//   * A byte with 1s and 0s in mixed positions -- 8'hA5, 8'h3C -- is received
//     with its bits in the right order. All-zero and all-one patterns are NOT
//     sufficient evidence: both survive a reversed shift register unchanged, so
//     an LSB/MSB mix-up would pass unnoticed.
//   * After a byte completes, the receiver is back in S_IDLE within one bit
//     period and can accept a second frame that begins immediately after the
//     first one's stop bit, with no inter-byte gap.
//   * A low glitch on rx_pin shorter than half a bit period does NOT produce a
//     byte. The half-bit start confirmation below is what buys this, and it is
//     the reason S_START exists as a separate state rather than falling straight
//     into data sampling.
//   * `byte_valid` is a single-cycle PULSE, not a level. It is decoded from
//     S_DONE, which the FSM occupies for exactly one cycle.
//   * `data_out` is stable for the whole cycle `byte_valid` is high, and holds
//     its value until the next byte completes.
//   * No latches: every register is assigned in an always_ff with a reset arm,
//     and the outputs are decoded from the state register only.
//
// -----------------------------------------------------------------------------
// MID-BIT SAMPLING -- why the receiver never samples at a bit edge
// -----------------------------------------------------------------------------
// The transmitter is a different device with its own crystal. Its baud rate is
// close to ours but never exactly ours, and neither clock has any phase
// relationship to the other. Sampling near a bit boundary means sampling exactly
// where the line is transitioning and where the two clocks' accumulated drift
// lands -- the value read there is a coin flip.
//
// So the receiver deliberately puts every sample in the MIDDLE of its bit:
//
//   1. On the falling edge that starts a frame, wait HALF a bit period. That
//      lands in the middle of the start bit.
//   2. From there, wait a FULL bit period per sample. Each one lands in the
//      middle of its data bit, because a half plus a whole is a whole plus a
//      half.
//
// This leaves half a bit period of margin on either side of every sample, so
// the link tolerates roughly +/-5% of baud mismatch before the last data bit of
// a frame drifts into the wrong window. That margin is the single reason to
// spend a state on the half-bit wait instead of sampling immediately.
//
// -----------------------------------------------------------------------------
// CYCLES_PER_BIT AND ITS TRUNCATION
// -----------------------------------------------------------------------------
// CYCLES_PER_BIT is the number of clk cycles in one bit time -- how long the
// receiver waits between samples:
//
//     CYCLES_PER_BIT = CLK_FREQ / BAUD_RATE
//                    = 100_000_000 / 115_200
//                    = 868.055...  ->  868 after integer division
//
// The truncation is not free, but it is negligible here: 868 vs 868.055 is a
// 0.0064% period error, so across a full 10-bit frame the sample point creeps
// about half a clock cycle. The available margin is half a bit period -- 434
// cycles -- so the drift is three orders of magnitude smaller than the window.
//
// This is worth re-checking if CLK_FREQ/BAUD_RATE is ever retuned to a ratio
// that divides badly, or to a small quotient where a single cycle of truncation
// is a large fraction of a bit.
// -----------------------------------------------------------------------------

module uart_rx_fpga #(
    parameter int CLK_FREQ  = 100_000_000,   // board clock, Hz
    parameter int BAUD_RATE = 921_600        // standard UART baud rate
) (
    input  logic       clk,
    input  logic       rst_n,        // active-low, synchronous

    input  logic       rx_pin,       // the physical serial input line
    output logic [7:0] data_out,     // the received byte
    output logic       byte_valid    // one-cycle pulse: data_out is new and complete
);

    // Bit-period timing, derived rather than given -- see the header note.
    localparam int CYCLES_PER_BIT = CLK_FREQ / BAUD_RATE;   // full bit time
    localparam int HALF_BIT       = CYCLES_PER_BIT / 2;     // start-bit confirmation

    // Wide enough for the largest count actually loaded, CYCLES_PER_BIT-1.
    localparam int CNT_W = $clog2(CYCLES_PER_BIT);

    typedef enum logic [2:0] {
        S_IDLE  = 3'd0,   // line high, waiting for a falling edge
        S_START = 3'd1,   // half-bit wait, then confirm the start bit is real
        S_DATA  = 3'd2,   // eight full-bit waits, sampling at each midpoint
        S_STOP  = 3'd3,   // one more full-bit wait, landing mid stop bit
        S_DONE  = 3'd4    // exactly one cycle, byte_valid high
    } state_e;

    state_e            state_q;
    logic [CNT_W-1:0]  cnt_q;        // cycles elapsed within the current bit
    logic [2:0]        bit_idx_q;    // which data bit is being received, 0..7
    logic [7:0]        shift_q;      // assembles the byte as it arrives
    logic [7:0]        data_q;

    // -------------------------------------------------------------------------
    // INPUT SYNCHRONIZER -- not optional.
    //
    // rx_pin comes from another device entirely and has no timing relationship
    // to clk, so it will violate setup/hold on this clock domain sooner or
    // later. Feeding it straight into the FSM lets a metastable value fan out to
    // the state register and the shift register at once, and they can resolve
    // DIFFERENTLY -- a corrupt byte, or a state machine in a state its own logic
    // never produced.
    //
    // Two flops in series give the first one a full clock period to settle
    // before anything reads it. Everything downstream reads rx_sync_q, never
    // rx_pin, and this is the only place rx_pin appears in the file.
    //
    // Reset value is 1, the idle line level. Coming out of reset with 0 here
    // would look exactly like a start bit and fabricate a byte from nothing.
    // -------------------------------------------------------------------------
    logic rx_meta_q, rx_sync_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx_meta_q <= 1'b1;
            rx_sync_q <= 1'b1;
        end else begin
            rx_meta_q <= rx_pin;
            rx_sync_q <= rx_meta_q;
        end
    end

    // A bit period is complete when the counter reaches its last cycle. Written
    // once here so the three waiting states cannot drift apart.
    logic bit_elapsed, half_elapsed;

    always_comb begin
        bit_elapsed  = (cnt_q == CNT_W'(CYCLES_PER_BIT - 1));
        half_elapsed = (cnt_q == CNT_W'(HALF_BIT - 1));
    end

    // -------------------------------------------------------------------------
    // RECEIVE FSM
    //
    // One state register, one counter, one shift register, all in this block.
    // The counter is reloaded to zero on every state change and on every
    // completed bit, so each wait measures from where the previous one ended
    // rather than from an absolute frame start -- that is what keeps the sample
    // points from accumulating the reload overhead.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q   <= S_IDLE;
            cnt_q     <= '0;
            bit_idx_q <= '0;
            shift_q   <= '0;
            data_q    <= '0;
        end else begin
            case (state_q)

                // ---------------------------------------------------------
                // IDLE: the line rests high. A low level is a candidate start
                // bit -- candidate, not confirmed. Level-triggered rather than
                // edge-triggered because the line is guaranteed high on entry
                // to this state, so the first low IS the falling edge.
                // ---------------------------------------------------------
                S_IDLE: begin
                    cnt_q     <= '0;
                    bit_idx_q <= '0;
                    if (rx_sync_q == 1'b0) state_q <= S_START;
                end

                // ---------------------------------------------------------
                // START: wait half a bit period and look again.
                //
                // Still low  -> a real start bit. The counter restarts from
                //               here, at the MIDDLE of the start bit, so the
                //               next full-bit wait lands at the middle of data
                //               bit 0. The half-bit offset is established once,
                //               here, and every later sample inherits it.
                //
                // Back high  -> a glitch shorter than half a bit period. Abandon
                //               and return to idle having consumed nothing. This
                //               is the entire noise-rejection mechanism, and it
                //               is why the half-bit wait is a state instead of
                //               being folded into the first data sample.
                // ---------------------------------------------------------
                S_START: begin
                    if (half_elapsed) begin
                        cnt_q   <= '0;
                        state_q <= (rx_sync_q == 1'b0) ? S_DATA : S_IDLE;
                    end else begin
                        cnt_q <= cnt_q + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // DATA: one full bit period per sample, eight times.
                //
                // LSB FIRST, which is what the right-shift implements: the
                // newly sampled bit enters at bit 7 and the earlier bits move
                // down, so after eight samples the FIRST bit received has
                // arrived at bit 0. Shifting the other way ({shift_q[6:0],
                // rx_sync_q}) would assemble every byte bit-reversed -- and
                // would still pass a test that only ever sends 8'h00 and 8'hFF.
                // ---------------------------------------------------------
                S_DATA: begin
                    if (bit_elapsed) begin
                        cnt_q   <= '0;
                        shift_q <= {rx_sync_q, shift_q[7:1]};

                        if (bit_idx_q == 3'd7) state_q   <= S_STOP;
                        else                   bit_idx_q <= bit_idx_q + 1'b1;
                    end else begin
                        cnt_q <= cnt_q + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // STOP: one more full-bit wait, landing in the middle of the
                // stop bit. Waiting it out matters even though its value is not
                // checked -- it is what puts the FSM back in IDLE at the right
                // moment to catch the NEXT frame's falling edge instead of
                // mistaking the tail of this stop bit for one.
                //
                // FUTURE HARDENING: the stop bit should be high. Sampling
                // rx_sync_q here and reporting `framing_error` when it is low
                // would catch a baud-rate mismatch or a desynchronised
                // transmitter -- conditions that currently produce a plausible
                // but wrong byte with no indication. That needs an extra output
                // port, so it is deliberately left out of this first version;
                // this is the one line where it would be sampled.
                // ---------------------------------------------------------
                S_STOP: begin
                    if (bit_elapsed) begin
                        cnt_q   <= '0;
                        data_q  <= shift_q;      // committed before it is announced
                        state_q <= S_DONE;
                    end else begin
                        cnt_q <= cnt_q + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // DONE: unconditionally one cycle long. That, and nothing else,
                // is what makes byte_valid a single-cycle pulse.
                // ---------------------------------------------------------
                S_DONE: state_q <= S_IDLE;

                default: state_q <= S_IDLE;

            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Outputs, decoded from the state register only -- Moore, so nothing
    // downstream sees a glitch when the FSM moves.
    //
    // data_q was loaded on the transition INTO S_DONE, one cycle before
    // byte_valid goes high, so the byte is already settled on the cycle a
    // consumer samples it.
    // -------------------------------------------------------------------------
    assign byte_valid = (state_q == S_DONE);
    assign data_out   = data_q;

endmodule
