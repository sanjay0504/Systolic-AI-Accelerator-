// -----------------------------------------------------------------------------
// uart_loopback_test.sv
//
// THROWAWAY TEST DESIGN -- not part of the final accelerator. Its only purpose
// is to confirm the UART RX/TX modules and the physical pin constraints work
// correctly on real ZedBoard hardware, before either module is trusted inside
// accelerator_top_fpga.sv.
//
// Behavior: whatever byte arrives on uart_rx_pin is immediately sent back out
// on uart_tx_pin. Type a character in a serial terminal at 115200 baud -- the
// same character should echo back.
// -----------------------------------------------------------------------------

module uart_loopback_test (
    input  logic clk,       // board clock, 100 MHz -- constrain via timing.xdc
    input  logic rst_n,     // tie to a board button or switch if no reset net exists
    input  logic uart_rx_pin,
    output logic uart_tx_pin
);

    logic [7:0] rx_byte;
    logic       rx_valid;
    logic       tx_busy;
    logic       tx_done;

    uart_rx_fpga u_rx (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_pin     (uart_rx_pin),
        .data_out   (rx_byte),
        .byte_valid (rx_valid)
    );

    // Fire a send the instant a byte is received. uart_tx_fpga ignores `send`
    // while busy, which cannot happen here since we only ever send once per
    // received byte and the receiver can't produce a new byte faster than the
    // transmitter can clear -- both run at the same baud rate.
    uart_tx_fpga u_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .data_in  (rx_byte),
        .send     (rx_valid),
        .tx_pin   (uart_tx_pin),
        .busy     (tx_busy),
        .done     (tx_done)
    );

endmodule
