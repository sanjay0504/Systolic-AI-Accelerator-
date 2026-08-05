// -----------------------------------------------------------------------------
// uart_tx_fpga.sv
//
// Standard 8-N-1 UART transmitter for FPGA deployment -- the mirror image of
// uart_rx_fpga.sv. New, standalone hardware: it neither modifies nor depends on
// any module in the accelerator datapath.
//
// Frame format, identical to what the receiver expects:
//
//     idle   start        d0   d1   d2   d3   d4   d5   d6   d7   stop   idle
//     ----\______/`````\____/````\ ... /`````\_________/````````````-------
//          1 bit low    8 data bits, LSB FIRST            1 bit high
//
// No parity. Pulse `send` for one cycle with the byte on `data_in`; `busy` goes
// high for the whole frame and `done` pulses for one cycle as it finishes.
//
// The receiver has to GUESS where the bit boundaries are -- hence its half-bit
// start confirmation and mid-bit sampling. The transmitter DEFINES them, so
// there is no equivalent here: every state simply lasts exactly
// CYCLES_PER_BIT cycles. That asymmetry is the only structural difference
// between the two files.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (verification contract)
// -----------------------------------------------------------------------------
//   * A byte with 1s and 0s in mixed positions -- 8'hA5, 8'h3C -- goes out with
//     its bits in the right order, LSB first. All-zero and all-one patterns are
//     NOT sufficient evidence: both survive a reversed shift register unchanged,
//     so an LSB/MSB mix-up would pass unnoticed.
//   * `busy` is high across the ENTIRE frame -- start bit through the end of the
//     stop bit -- and drops only once the stop bit has been held for its full
//     bit period. It is not high in S_DONE, so `busy` low and `done` high are
//     simultaneous and mean the same thing.
//   * A second `send` issued on the same cycle as the first frame's `done`, or
//     any cycle after it, transmits correctly with no corruption. See the
//     back-to-back note below -- this is the case the FSM is shaped around.
//   * `done` is a single-cycle PULSE, not a level. It is decoded from S_DONE,
//     which the FSM occupies for exactly one cycle.
//   * `tx_pin` is high whenever the transmitter is idle, including immediately
//     out of reset, so a receiver watching the line never sees a phantom start
//     bit from a reset or a power-up.
//   * No latches: every register is assigned in an always_ff with a reset arm,
//     and every output is decoded from a register.
//
// -----------------------------------------------------------------------------
// CORRECTNESS CONTRACT WITH THE CALLER -- `send` while `busy`
// -----------------------------------------------------------------------------
// `send` is examined ONLY in S_IDLE and S_DONE, the two states where `busy` is
// low. A `send` pulse raised at any point during a frame in flight is silently
// DISCARDED: the byte on `data_in` is never latched, never transmitted, and no
// error of any kind is reported.
//
// This is a deliberate contract, not an oversight, and it is the same shape as
// `skip_load` in control_unit.sv -- the module trusts the caller and cannot
// check the claim itself. The alternative, honouring a mid-frame `send`, would
// mean reloading the shift register partway through a byte and emitting a frame
// that is half of one value and half of another. A receiver would accept that
// as a perfectly well-formed byte. Dropping the write is the failure mode that
// loses data visibly (a byte that never arrives) rather than invisibly (a byte
// that arrives wrong).
//
// The caller -- the command-interpreter FSM in accelerator_top_fpga.sv -- owns
// the pacing, and must wait for `done`, or for `busy` to be low, before raising
// `send` again. `busy` is the signal to gate on; it is low in exactly the states
// where `send` is accepted, so "send only while !busy" is not an approximation
// of the rule, it IS the rule.
//
// BACK-TO-BACK SENDS: `send` is accepted in S_DONE as well as S_IDLE, so a
// caller that reacts to `done` combinationally and raises `send` on that very
// cycle is served without losing a byte. The frame that follows begins one cycle
// later, which stretches the preceding stop bit by a single clock cycle out of
// 868. A stop bit only has to be at least one bit time high, so a longer one is
// always legal -- there is nothing to compensate for.
//
// -----------------------------------------------------------------------------
// CYCLES_PER_BIT AND ITS TRUNCATION
// -----------------------------------------------------------------------------
//     CYCLES_PER_BIT = CLK_FREQ / BAUD_RATE
//                    = 100_000_000 / 115_200
//                    = 868.055...  ->  868 after integer division
//
// The transmitter therefore runs at 100e6/868 = 115_207 baud, 0.0064% fast. UART
// links tolerate roughly +/-5% before a receiver's mid-bit sample drifts out of
// its window by the last data bit, so this is three orders of magnitude inside
// the budget. It is worth re-checking only if CLK_FREQ/BAUD_RATE is ever retuned
// to a ratio that divides badly, or to a quotient small enough that one cycle of
// truncation is a large fraction of a bit.
// -----------------------------------------------------------------------------

module uart_tx_fpga #(
    parameter int CLK_FREQ  = 100_000_000,   // board clock, Hz
    parameter int BAUD_RATE = 921_600        // standard UART baud rate
) (
    input  logic       clk,
    input  logic       rst_n,       // active-low, synchronous

    input  logic [7:0] data_in,     // byte to send; sampled on the accepted `send`
    input  logic       send,        // one-cycle pulse: begin transmitting data_in
    output logic       tx_pin,      // the physical serial output line
    output logic       busy,        // high for the whole frame; gate `send` on this
    output logic       done         // one-cycle pulse: the frame has completed
);

    // Bit-period timing, derived rather than given -- see the header note.
    localparam int CYCLES_PER_BIT = CLK_FREQ / BAUD_RATE;

    // Wide enough for the largest count actually loaded, CYCLES_PER_BIT-1.
    localparam int CNT_W = $clog2(CYCLES_PER_BIT);

    typedef enum logic [2:0] {
        S_IDLE  = 3'd0,   // line high, waiting for send
        S_START = 3'd1,   // one bit period low
        S_DATA  = 3'd2,   // eight bit periods, one per data bit, LSB first
        S_STOP  = 3'd3,   // one bit period high
        S_DONE  = 3'd4    // exactly one cycle, done high
    } state_e;

    state_e           state_q;
    logic [CNT_W-1:0] cnt_q;        // cycles elapsed within the current bit
    logic [2:0]       bit_idx_q;    // which data bit is being sent, 0..7
    logic [7:0]       shift_q;      // the byte, consumed from the bottom

    // A bit period is complete on its last cycle. Written once so the three
    // timed states cannot drift apart.
    logic bit_elapsed;
    assign bit_elapsed = (cnt_q == CNT_W'(CYCLES_PER_BIT - 1));

    // `send` is honoured only where busy is low -- the contract above, expressed
    // as a single term so the two accepting states cannot disagree about it.
    logic accept_send;
    assign accept_send = send && ((state_q == S_IDLE) || (state_q == S_DONE));

    // -------------------------------------------------------------------------
    // TRANSMIT FSM
    //
    // One state register, one counter, one shift register, all in this block.
    // The counter is reloaded to zero at every bit boundary rather than counted
    // against an absolute frame start, so each bit period is exactly
    // CYCLES_PER_BIT cycles wide and no rounding accumulates across the frame.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q   <= S_IDLE;
            cnt_q     <= '0;
            bit_idx_q <= '0;
            shift_q   <= '0;
        end else begin
            case (state_q)

                // ---------------------------------------------------------
                // IDLE: line resting high. data_in is latched HERE, on the
                // accepted pulse, and never read again -- so the caller is free
                // to change it the moment busy goes high, and a byte in flight
                // cannot be disturbed by whatever the caller does next.
                // ---------------------------------------------------------
                S_IDLE: begin
                    cnt_q     <= '0;
                    bit_idx_q <= '0;
                    if (accept_send) begin
                        shift_q <= data_in;
                        state_q <= S_START;
                    end
                end

                // ---------------------------------------------------------
                // START: hold low for one full bit period. This is the edge the
                // receiver triggers on and then measures every later sample
                // point from, so its width is the reference for the whole frame.
                // ---------------------------------------------------------
                S_START: begin
                    if (bit_elapsed) begin
                        cnt_q   <= '0;
                        state_q <= S_DATA;
                    end else begin
                        cnt_q <= cnt_q + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // DATA: eight bit periods, driving shift_q[0] each time.
                //
                // LSB FIRST, which is what taking bit 0 and shifting right
                // implements: bit 0 goes out first, then bit 1 moves into its
                // place, and so on. Sending shift_q[7] with a left shift instead
                // would transmit every byte bit-reversed -- and would still pass
                // a test that only ever sends 8'h00 and 8'hFF.
                //
                // Zeros fill in from the top as the byte drains. They are never
                // transmitted: the state leaves after exactly 8 bits, so the
                // fill value is invisible. Zero rather than 1 only so an
                // inspected waveform shows an obviously emptied register.
                // ---------------------------------------------------------
                S_DATA: begin
                    if (bit_elapsed) begin
                        cnt_q   <= '0;
                        shift_q <= {1'b0, shift_q[7:1]};

                        if (bit_idx_q == 3'd7) state_q   <= S_STOP;
                        else                   bit_idx_q <= bit_idx_q + 1'b1;
                    end else begin
                        cnt_q <= cnt_q + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // STOP: hold high for one full bit period. Waiting it out in a
                // state of its own is what guarantees the line is high for a
                // whole bit time before the next start bit can pull it low --
                // return to idle any earlier and two adjacent frames would run
                // together with no separator, and the receiver would read the
                // second one's start bit as part of the first one's stop bit.
                // ---------------------------------------------------------
                S_STOP: begin
                    if (bit_elapsed) begin
                        cnt_q   <= '0;
                        state_q <= S_DONE;
                    end else begin
                        cnt_q <= cnt_q + 1'b1;
                    end
                end

                // ---------------------------------------------------------
                // DONE: one cycle, which is what makes `done` a pulse. `send` is
                // accepted here too, so a caller reacting to `done` on the same
                // cycle does not lose its byte -- see BACK-TO-BACK SENDS above.
                // The line stays high throughout either way.
                // ---------------------------------------------------------
                S_DONE: begin
                    cnt_q     <= '0;
                    bit_idx_q <= '0;
                    if (accept_send) begin
                        shift_q <= data_in;
                        state_q <= S_START;
                    end else begin
                        state_q <= S_IDLE;
                    end
                end

                default: state_q <= S_IDLE;

            endcase
        end
    end

    // -------------------------------------------------------------------------
    // SERIAL OUTPUT -- given its own flop because it leaves the chip.
    //
    // busy and done are consumed on-chip by other synchronous logic, so decoding
    // them straight off the state register is fine. tx_pin is not: it drives a
    // physical pad, and an output pad wants a clean register-to-pin path with no
    // combinational fan-in behind it, so its timing is one flop's clk-to-out and
    // nothing else.
    //
    // The flop delays the line by one cycle. That costs nothing, because it
    // delays EVERY bit by the same one cycle -- the frame shifts a hair later in
    // absolute time and no bit period changes width. There is nothing to
    // compensate elsewhere.
    //
    // Reset drives it high, the idle level. Resetting to 0 would hold the line
    // in what a receiver reads as a start bit and would fabricate a byte on the
    // far end out of nothing.
    // -------------------------------------------------------------------------
    logic tx_d, tx_q;

    always_comb begin
        case (state_q)
            S_START: tx_d = 1'b0;            // the start bit
            S_DATA:  tx_d = shift_q[0];      // LSB first
            default: tx_d = 1'b1;            // IDLE, STOP, DONE -- all idle-high
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) tx_q <= 1'b1;
        else        tx_q <= tx_d;
    end

    assign tx_pin = tx_q;

    // -------------------------------------------------------------------------
    // Status outputs, decoded from the state register only -- Moore, so nothing
    // downstream sees a glitch when the FSM moves.
    //
    // busy covers exactly the states in which `send` is ignored, so the caller's
    // rule ("send only while !busy") and the FSM's rule ("accept only in S_IDLE
    // or S_DONE") are two descriptions of one condition rather than two
    // conditions that have to be kept in step.
    // -------------------------------------------------------------------------
    assign busy = (state_q == S_START) || (state_q == S_DATA) || (state_q == S_STOP);
    assign done = (state_q == S_DONE);

endmodule
