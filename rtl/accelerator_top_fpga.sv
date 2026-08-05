// -----------------------------------------------------------------------------
// accelerator_top_fpga.sv
//
// FPGA deployment wrapper. Three instances and one FSM:
//
//     uart_rx_fpga  --> command-interpreter FSM --> accelerator_top
//     uart_tx_fpga  <-- command-interpreter FSM <-- accelerator_top
//
// The board exposes four pins -- clk, rst_n, and the two UART lines -- so this
// file's job is to turn a byte stream into calls on accelerator_top's existing
// external interface, and turn its results back into a byte stream.
//
// -----------------------------------------------------------------------------
// THIS FILE ADDS COMMUNICATION LOGIC AND NOTHING ELSE
// -----------------------------------------------------------------------------
// `accelerator_top` is instantiated UNMODIFIED, through the same external ports
// tb_top.sv drives -- start/done, the two write ports, the read-back port,
// K_real and skip_load. Every question about matrix multiplication lives inside
// it and is already answered:
//
//   * WHEN a run is finished              -> accelerator_top.done. This file
//                                            waits for it and never predicts it.
//   * HOW LONG the phases take            -> control_unit's data-driven FSM.
//   * WHICH address is read when          -> address_gen.
//   * WHAT the padding masks do           -> the pad muxes in accelerator_top.
//   * WHETHER reusing weights is safe     -> nobody's; see the skip_load note.
//
// The FSM below decodes bytes, counts bytes, and pulses enables. It does not
// model, mirror, shadow, or second-guess any of the above. If a number comes out
// wrong on the wire, the bug is in this file's byte handling or in the host
// script -- the datapath is verified by tb_top.sv independently of anything
// here.
//
// -----------------------------------------------------------------------------
// PROTOCOL -- PC to FPGA (received by uart_rx_fpga)
// -----------------------------------------------------------------------------
//   0x01  WRITE_WEIGHT   + 1 addr byte + 4 data bytes (lane0, lane1, lane2, lane3)
//   0x02  WRITE_ACT      + 1 addr byte + 4 data bytes (lane0, lane1, lane2, lane3)
//   0x03  SET_K_REAL     + 1 value byte (1..N)
//   0x04  SET_SKIP_LOAD  + 1 value byte (0 or 1)
//   0x05  START          + no payload
//   0x06  READ_OUTPUT    + 1 addr byte
//
// PROTOCOL -- FPGA to PC (sent by uart_tx_fpga)
//
//   after START        : 0xAA, once accelerator_top.done asserts
//   after READ_OUTPUT  : 4 raw data bytes, lane0 first, one UART frame each
//
// Lane order on the wire is lane0-first in BOTH directions, matching act_mem's
// convention that lane 0 is the low byte -- so the host packs and unpacks a row
// the same way whichever direction it is going.
//
// -----------------------------------------------------------------------------
// CORRECTNESS CONTRACT WITH THE HOST -- the protocol is self-pacing
// -----------------------------------------------------------------------------
// Received bytes are examined only in WAIT_CMD and COLLECT. A byte that arrives
// while the FSM is waiting for accel_done or driving the transmitter is DROPPED
// -- not queued, not reported. There is no receive FIFO in this design.
//
// This is safe for exactly one reason, and it is worth being explicit about it:
// the only two commands that make the FSM leave the receiving states are START
// and READ_OUTPUT, and both of them send a reply. A host that waits for that
// reply before sending its next command can never lose a byte. The commands with
// no reply -- the writes and the two setters -- pass through EXECUTE in a single
// clock cycle and are back in WAIT_CMD roughly 860 cycles before the next UART
// frame can possibly complete, so they can be streamed back-to-back freely.
//
// So the rule for the host is: after START, wait for 0xAA. After READ_OUTPUT,
// wait for all four bytes. Everything else can be sent as fast as the link runs.
// Violating that loses a command silently, which is why it is stated here rather
// than left to be discovered.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (verification contract)
// -----------------------------------------------------------------------------
//   * WRITE_WEIGHT / WRITE_ACT assert their write-enable for EXACTLY ONE clock
//     cycle, with addr and all four lanes stable on that cycle. One cycle is the
//     write contract weight_mem/act_mem document and every existing testbench
//     drives; the enable is decoded from the single-cycle EXECUTE state, so its
//     width cannot drift.
//   * SET_K_REAL and SET_SKIP_LOAD update HELD registers, not pulses. Both feed
//     accelerator_top continuously and survive any number of intervening
//     commands until another setter changes them.
//   * After START the FSM waits for accel_done however long it takes. There is
//     no timeout and no cycle count anywhere in this file -- the same
//     data-driven-not-schedule-driven principle control_unit.sv uses for DRAIN.
//   * READ_OUTPUT observes output_mem's one-cycle registered-read latency before
//     sampling out_rd_data, then sends four bytes lane0-first, each one waiting
//     for the previous frame's tx_done before the next tx_send.
//   * No latches: every always_comb assigns every output on every path through
//     its default block, and every register has a reset arm.
//   * No combinational loops: the only combinational logic is the output decode,
//     which reads state_q/cmd_q/payload_q and drives module inputs. Nothing
//     feeds back.
// -----------------------------------------------------------------------------

module accelerator_top_fpga #(
    // ---- board / link -------------------------------------------------------
    parameter int CLK_FREQ  = 100_000_000,
    parameter int BAUD_RATE = 921_600,

    // ---- accelerator geometry, passed straight through ----------------------
    parameter int N      = 4,
    parameter int DEPTH  = 16,
    parameter int IN_W   = 8,
    parameter int ACC_W  = 32,
    parameter int DW_OUT = 8,

    // SHIFT defaults to 0 here, NOT to accelerator_top's own default of 8.
    //
    // The deployed application is the RGB channel split: a selector matrix of
    // ones and zeros, whose products are single pixel bytes. At SHIFT=8 every
    // one of those is divided by 256 and the board would return an all-zero
    // image over the UART -- which is also exactly what a completely dead
    // datapath returns, making the two indistinguishable from the host's side.
    // Same reasoning, and the same value, as tb_top.sv and tb_image_demo.sv.
    parameter int SHIFT    = 0,
    parameter int USE_BIAS = 0,
    parameter int USE_RELU = 0
) (
    input  logic clk,
    input  logic btn_raw,          // active-HIGH, idle=0/pressed=1 -- inverted below

    input  logic uart_rx_pin,    // serial in, from the PC
    output logic uart_tx_pin     // serial out, to the PC
);

    localparam int ADDR_W = $clog2(DEPTH);
    localparam int KW     = $clog2(N+1);

    // One output lane must fit in one UART byte for the READ_OUTPUT reply to be
    // a straight copy. It does at DW_OUT=8; anything wider needs the reply to be
    // multi-byte per lane and the host unpacker changed to match.
    // synthesis translate_off
    initial if (DW_OUT != 8)
        $error("accelerator_top_fpga: DW_OUT=%0d does not fit one UART byte per lane", DW_OUT);
    // synthesis translate_on

    // =========================================================================
    // UART <-> FSM nets
    // =========================================================================
    logic [7:0] rx_byte;
    logic       rx_valid;

    logic [7:0] tx_byte;
    logic       tx_send;
    logic       tx_busy;
    logic       tx_done;

    // =========================================================================
    // FSM <-> accelerator nets. Names and widths are accelerator_top's, taken
    // from its port list unchanged.
    // =========================================================================
    logic              accel_start;
    logic              accel_done;

    logic              weight_wr_en;
    logic [ADDR_W-1:0] weight_wr_addr;
    logic [IN_W-1:0]   weight_wr_data [0:N-1];

    logic              act_wr_en;
    logic [ADDR_W-1:0] act_wr_addr;
    logic [IN_W-1:0]   act_wr_data    [0:N-1];

    logic              out_rd_en;
    logic [ADDR_W-1:0] out_rd_addr;
    logic [DW_OUT-1:0] out_rd_data    [0:N-1];

    logic rst_n;

    assign rst_n = ~btn_raw;

    // =========================================================================
    // SERIAL FRONT END
    // =========================================================================
    uart_rx_fpga #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_rx (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_pin     (uart_rx_pin),
        .data_out   (rx_byte),
        .byte_valid (rx_valid)
    );

    uart_tx_fpga #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_tx (
        .clk     (clk),
        .rst_n   (rst_n),
        .data_in (tx_byte),
        .send    (tx_send),
        .tx_pin  (uart_tx_pin),
        // Connected for observation only. The FSM paces itself on tx_done, which
        // is strictly stronger than !tx_busy: waiting for the completion pulse
        // means the previous frame's stop bit is fully out on the wire, not
        // merely that the transmitter would accept a new byte.
        .busy    (tx_busy),
        .done    (tx_done)
    );

    // =========================================================================
    // THE ACCELERATOR -- instantiated as-is, driven only through its documented
    // external interface. No internal signal of this instance is referenced
    // anywhere in this file, exactly as in tb_top.sv.
    // =========================================================================
    logic [KW-1:0] k_real_q;
    logic          skip_load_q;

    accelerator_top #(
        .N        (N),
        .DEPTH    (DEPTH),
        .IN_W     (IN_W),
        .ACC_W    (ACC_W),
        .DW_OUT   (DW_OUT),
        .USE_BIAS (USE_BIAS),
        .USE_RELU (USE_RELU),
        .SHIFT    (SHIFT)
    ) u_accel (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (accel_start),
        .done           (accel_done),
        .skip_load      (skip_load_q),      // held register, not a pulse
        .K_real         (k_real_q),         // held register, not a pulse
        .weight_wr_en   (weight_wr_en),
        .weight_wr_addr (weight_wr_addr),
        .weight_wr_data (weight_wr_data),
        .act_wr_en      (act_wr_en),
        .act_wr_addr    (act_wr_addr),
        .act_wr_data    (act_wr_data),
        .out_rd_en      (out_rd_en),
        .out_rd_addr    (out_rd_addr),
        .out_rd_data    (out_rd_data)
    );

    // =========================================================================
    // COMMAND INTERPRETER
    // =========================================================================
    localparam logic [7:0] CMD_WRITE_WEIGHT  = 8'h01;
    localparam logic [7:0] CMD_WRITE_ACT     = 8'h02;
    localparam logic [7:0] CMD_SET_K_REAL    = 8'h03;
    localparam logic [7:0] CMD_SET_SKIP_LOAD = 8'h04;
    localparam logic [7:0] CMD_START         = 8'h05;
    localparam logic [7:0] CMD_READ_OUTPUT   = 8'h06;

    localparam logic [7:0] REPLY_ACK         = 8'hAA;

    // Longest payload is WRITE_WEIGHT / WRITE_ACT: 1 address + N lanes.
    localparam int MAX_PAYLOAD = 1 + N;
    localparam int PCNT_W      = $clog2(MAX_PAYLOAD + 1);

    typedef enum logic [2:0] {
        S_WAIT_CMD   = 3'd0,   // watching for an opcode byte
        S_COLLECT    = 3'd1,   // gathering this command's payload bytes
        S_EXECUTE    = 3'd2,   // ONE cycle: drive the accelerator port(s)
        S_ACCEL_WAIT = 3'd3,   // START: wait for accel_done, no timeout
        S_RD_WAIT    = 3'd4,   // READ_OUTPUT: output_mem's one-cycle latency
        S_TX_SEND    = 3'd5,   // ONE cycle: pulse tx_send with the next byte
        S_TX_WAIT    = 3'd6    // wait for that frame's tx_done
    } state_e;

    state_e                state_q;
    logic [7:0]            cmd_q;
    logic [7:0]            payload_q [0:MAX_PAYLOAD-1];   // [0]=addr/value, [1..N]=lanes
    logic [PCNT_W-1:0]     need_q;      // payload bytes this command wants
    logic [PCNT_W-1:0]     got_q;       // payload bytes collected so far

    logic [7:0]            reply_q [0:N-1];   // bytes queued for the transmitter
    logic [PCNT_W-1:0]     tx_len_q;          // how many of them are in use
    logic [PCNT_W-1:0]     tx_idx_q;          // which one is going out now

    // How many payload bytes each opcode carries. An unrecognised opcode is
    // reported as zero and rejected below rather than being collected -- see
    // the resynchronisation note in S_WAIT_CMD.
    function automatic logic [PCNT_W-1:0] payload_len(input logic [7:0] opcode);
        case (opcode)
            CMD_WRITE_WEIGHT,
            CMD_WRITE_ACT:     return PCNT_W'(1 + N);
            CMD_SET_K_REAL,
            CMD_SET_SKIP_LOAD,
            CMD_READ_OUTPUT:   return PCNT_W'(1);
            CMD_START:         return PCNT_W'(0);
            default:           return PCNT_W'(0);
        endcase
    endfunction

    function automatic logic is_known_cmd(input logic [7:0] opcode);
        case (opcode)
            CMD_WRITE_WEIGHT, CMD_WRITE_ACT, CMD_SET_K_REAL,
            CMD_SET_SKIP_LOAD, CMD_START, CMD_READ_OUTPUT: return 1'b1;
            default:                                       return 1'b0;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Sequential part: state, byte collection, held config, reply buffer.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q     <= S_WAIT_CMD;
            cmd_q       <= '0;
            need_q      <= '0;
            got_q       <= '0;
            tx_len_q    <= '0;
            tx_idx_q    <= '0;

            // Reset defaults chosen for safety, not for convenience:
            //
            //   K_real = N        -- fully populated, no padding. This is what
            //                        every pre-existing test runs at, so a board
            //                        that is reset and immediately started
            //                        behaves like the verified base case.
            //
            //   skip_load = 0     -- always load weights. The dangerous
            //                        direction is 1: control_unit's contract
            //                        says asserting it when the resident weights
            //                        are wrong yields a silently wrong result
            //                        with no error of any kind. Resetting to 0
            //                        means a host that forgets to send
            //                        SET_SKIP_LOAD gets correct-but-slower
            //                        behaviour rather than fast nonsense.
            k_real_q    <= KW'(N);
            skip_load_q <= 1'b0;

            for (int i = 0; i < MAX_PAYLOAD; i++) payload_q[i] <= '0;
            for (int i = 0; i < N;           i++) reply_q[i]   <= '0;
        end else begin
            case (state_q)

                // ---------------------------------------------------------
                // WAIT_CMD: the first byte of a command is its opcode.
                //
                // An unrecognised opcode is DISCARDED and the FSM stays here.
                // That is the resynchronisation behaviour: if the host and the
                // board ever fall out of frame, every stray byte is consumed one
                // at a time until a valid opcode appears, and the link recovers
                // on its own. Treating an unknown byte as a command with zero
                // payload would instead execute it, and treating it as a command
                // with a payload would swallow the bytes that follow -- both
                // turn a single lost byte into a permanently desynchronised
                // link.
                // ---------------------------------------------------------
                S_WAIT_CMD: begin
                    got_q <= '0;
                    if (rx_valid && is_known_cmd(rx_byte)) begin
                        cmd_q  <= rx_byte;
                        need_q <= payload_len(rx_byte);
                        state_q <= (payload_len(rx_byte) == '0) ? S_EXECUTE : S_COLLECT;
                    end
                end

                // ---------------------------------------------------------
                // COLLECT: accumulate exactly need_q payload bytes, in arrival
                // order. payload_q[0] is the address or value byte; for the two
                // write commands payload_q[1..N] are lane 0..N-1, in that order.
                // ---------------------------------------------------------
                S_COLLECT: begin
                    if (rx_valid) begin
                        payload_q[got_q] <= rx_byte;
                        got_q            <= got_q + 1'b1;
                        if (got_q == need_q - 1'b1) state_q <= S_EXECUTE;
                    end
                end

                // ---------------------------------------------------------
                // EXECUTE: exactly one cycle, always. The write enables and
                // accel_start are decoded from being IN this state, so their
                // pulse width is this state's dwell time and nothing else --
                // there is no counter to get wrong and no branch that can hold
                // an enable high for a second cycle.
                //
                // The two setters do their work here as register updates; the
                // three port-driving commands do theirs in the combinational
                // block below.
                // ---------------------------------------------------------
                S_EXECUTE: begin
                    case (cmd_q)
                        // Held, not pulsed. accelerator_top samples K_real at
                        // the start edge and address_gen uses it all run, so it
                        // has to be a steady level, and it stays valid across
                        // any number of later commands until another
                        // SET_K_REAL arrives.
                        //
                        // Out-of-range values are DROPPED and the previous
                        // K_real persists. K_real is defined over 1..N; 0 has no
                        // meaning to address_gen and is not something a verified
                        // module should be handed. Dropping is a stated
                        // behaviour rather than a silent one -- it is written
                        // down here and the host is expected to stay in range.
                        CMD_SET_K_REAL:
                            if (payload_q[0] >= 8'd1 && payload_q[0] <= 8'(N))
                                k_real_q <= KW'(payload_q[0]);

                        // Also held. Any non-zero byte means 1, so the host may
                        // send 0x01 or 0xFF interchangeably.
                        CMD_SET_SKIP_LOAD:
                            skip_load_q <= (payload_q[0] != 8'd0);

                        // START: queue the acknowledgement now, send it once the
                        // run reports done.
                        CMD_START: begin
                            reply_q[0] <= REPLY_ACK;
                            tx_len_q   <= PCNT_W'(1);
                            tx_idx_q   <= '0;
                        end

                        default: ;   // writes and READ_OUTPUT act combinationally
                    endcase

                    case (cmd_q)
                        CMD_START:       state_q <= S_ACCEL_WAIT;
                        CMD_READ_OUTPUT: state_q <= S_RD_WAIT;
                        default:         state_q <= S_WAIT_CMD;
                    endcase
                end

                // ---------------------------------------------------------
                // ACCEL_WAIT: wait for done. No timeout, no cycle count -- the
                // run takes as long as it takes, and control_unit is the only
                // thing that knows when that is.
                //
                // TIMING, and this is the trap worth naming: accel_done is a
                // LEVEL held high from the end of one run until the next start,
                // so on the cycle START is issued it is very likely STILL HIGH
                // from the previous run. Sampling it there would report instant
                // completion and send 0xAA before a single weight had loaded --
                // and every subsequent READ_OUTPUT would return the previous
                // run's results, which look entirely plausible.
                //
                // It is safe here because this state is entered the cycle AFTER
                // the one that drove accel_start: control_unit leaves S_DONE on
                // that same edge, so done is already low by the first cycle this
                // state can observe it. The one-cycle separation is the whole
                // guard, which is why EXECUTE must stay a state of its own and
                // must not be merged into this one.
                // ---------------------------------------------------------
                S_ACCEL_WAIT: begin
                    if (accel_done) state_q <= S_TX_SEND;
                end

                // ---------------------------------------------------------
                // RD_WAIT: output_mem's read is registered, so the row named by
                // out_rd_addr in EXECUTE lands on out_rd_data on the NEXT cycle
                // -- this one. Sampling it in EXECUTE would capture whatever the
                // previous read left in the output register.
                //
                // All N lanes are copied into reply_q in one go rather than read
                // from the port as each byte is transmitted. output_mem does
                // hold rd_row_q while rd_en is low, so reading it live would
                // work today, but that makes four UART frames' worth of
                // transmission depend on a hold behaviour of a module this file
                // is supposed to treat as a black box. One copy costs N bytes
                // and removes the dependency.
                // ---------------------------------------------------------
                S_RD_WAIT: begin
                    for (int k = 0; k < N; k++) reply_q[k] <= out_rd_data[k];
                    tx_len_q <= PCNT_W'(N);
                    tx_idx_q <= '0;
                    state_q  <= S_TX_SEND;
                end

                // ---------------------------------------------------------
                // TX_SEND: one cycle, pulsing tx_send with reply_q[tx_idx_q].
                // uart_tx_fpga latches data_in on the accepted pulse and never
                // reads it again, so reply_q may change freely afterwards.
                // ---------------------------------------------------------
                S_TX_SEND: state_q <= S_TX_WAIT;

                // ---------------------------------------------------------
                // TX_WAIT: one frame is ~10 bit periods, so this is where nearly
                // all the time goes. Waiting for tx_done rather than firing the
                // next tx_send immediately is REQUIRED, not merely tidy:
                // uart_tx_fpga ignores send while busy and reports nothing when
                // it does, so four back-to-back sends would put one byte on the
                // wire and discard three, and the host would sit waiting for a
                // reply that is three bytes short.
                // ---------------------------------------------------------
                S_TX_WAIT: begin
                    if (tx_done) begin
                        if (tx_idx_q == tx_len_q - 1'b1) begin
                            state_q <= S_WAIT_CMD;
                        end else begin
                            tx_idx_q <= tx_idx_q + 1'b1;
                            state_q  <= S_TX_SEND;
                        end
                    end
                end

                default: state_q <= S_WAIT_CMD;

            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Combinational output decode.
    //
    // Every signal is assigned unconditionally at the top of the block before
    // any case statement, so no path through it leaves anything unassigned --
    // that is what keeps this latch-free. The enables are the only signals the
    // case arms touch, and they are high only in S_EXECUTE / S_TX_SEND, both of
    // which are unconditionally one cycle long.
    //
    // Address and data are driven from payload_q on EVERY cycle, not just the
    // one where the enable is high. The memories only sample them under wr_en,
    // and holding them steady means the data is already settled well before the
    // enable rises rather than changing on the same edge as it.
    // -------------------------------------------------------------------------
    always_comb begin
        weight_wr_en = 1'b0;
        act_wr_en    = 1'b0;
        out_rd_en    = 1'b0;
        accel_start  = 1'b0;
        tx_send      = 1'b0;

        // payload_q[0] is the address byte for all three addressed commands.
        weight_wr_addr = payload_q[0][ADDR_W-1:0];
        act_wr_addr    = payload_q[0][ADDR_W-1:0];
        out_rd_addr    = payload_q[0][ADDR_W-1:0];

        // payload_q[1..N] are lanes 0..N-1, in wire order.
        for (int k = 0; k < N; k++) begin
            weight_wr_data[k] = payload_q[k+1][IN_W-1:0];
            act_wr_data[k]    = payload_q[k+1][IN_W-1:0];
        end

        case (state_q)
            S_EXECUTE: begin
                case (cmd_q)
                    CMD_WRITE_WEIGHT: weight_wr_en = 1'b1;
                    CMD_WRITE_ACT:    act_wr_en    = 1'b1;
                    CMD_READ_OUTPUT:  out_rd_en    = 1'b1;
                    CMD_START:        accel_start  = 1'b1;
                    default:          ;    // setters need no port activity
                endcase
            end

            S_TX_SEND: tx_send = 1'b1;

            default: ;
        endcase
    end

    // The byte currently being handed to the transmitter. tx_idx_q is a
    // register, so this is a plain mux with no feedback.
    assign tx_byte = reply_q[tx_idx_q];

endmodule
