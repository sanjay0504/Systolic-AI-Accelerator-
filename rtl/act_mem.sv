// -----------------------------------------------------------------------------
// act_mem.sv
//
// Holds matrix A -- the activations.
//
// Access pattern: read-mostly. Read one row per cycle during the COMPUTE phase
// and handed straight to the skew buffer, which staggers it into the diagonal
// wavefront the array's left edge expects.
//
// READ LATENCY IS EXACTLY ONE CYCLE. rd_data reflects the row at rd_addr on the
// cycle AFTER the address is presented with rd_en high, which models a real
// synchronous SRAM. The address generator must therefore issue every address one
// cycle early.
//
// -----------------------------------------------------------------------------
// WHAT THIS MODULE DOES NOT DO
// -----------------------------------------------------------------------------
// rd_data drives skew_buffer.data_in (REVERSE=0). This memory performs NO
// skewing: every lane of a row leaves here on the same cycle, un-staggered. The
// triangular delay that makes row k arrive k cycles late belongs entirely to the
// skew buffer downstream.
//
// Do not add stagger logic to this file. Skewing in both places would double the
// stagger, and the array would compute products from mismatched positions of A
// and B -- a wrong C with no obvious symptom at the edges.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (verification contract)
// -----------------------------------------------------------------------------
//   * A row written to wr_addr with wr_en high is readable one cycle after
//     rd_addr points at it with rd_en high.
//   * Read latency is exactly one cycle; back-to-back reads to different
//     addresses pipeline correctly, one row per cycle with no gaps.
//   * With rd_en low the read register holds its previous value -- it does not
//     go stale, zero, or X.
//   * A write and a read to the same address on the same cycle returns the OLD
//     row (read-before-write), since both are non-blocking updates.
// -----------------------------------------------------------------------------

module act_mem #(
    parameter int    N        = 4,    // elements per row (array lanes)
    parameter int    DW       = 8,    // bits per element
    parameter int    DEPTH    = 16   // rows storable (>= N)
    // parameter string ACT_INIT = ""    // optional $readmemh preload file
) (
    input  logic                     clk,
    input  logic                     rst_n,      // active-low, synchronous

    // Read port -- used during the COMPUTE phase, feeds the skew buffer
    input  logic                     rd_en,
    input  logic [$clog2(DEPTH)-1:0] rd_addr,
    output logic [DW-1:0]            rd_data [0:N-1],   // registered, 1-cycle latency

    // Write port -- setup / testbench load
    input  logic                     wr_en,
    input  logic [$clog2(DEPTH)-1:0] wr_addr,
    input  logic [DW-1:0]            wr_data [0:N-1]
);

    localparam int ROW_W = N * DW;

    // Storage is packed one row per location; the ports are unpacked so they
    // connect straight to the skew buffer. Element k occupies bits
    // [k*DW +: DW], i.e. lane 0 sits in the least significant bits -- the same
    // convention $readmemh files must follow.
    logic [ROW_W-1:0] mem [0:DEPTH-1];
    logic [ROW_W-1:0] rd_row_q;

    // ---------------------------------------------------------------- preload
    // One hex word per line, ROW_W bits wide, lane 0 in the low DW bits.
// `ifndef SYNTHESIS
//     initial begin
//         if (ACT_INIT != "") $readmemh(ACT_INIT, mem);
//     end
// `endif

    // ------------------------------------------------------------------ write
    always_ff @(posedge clk) begin
        if (wr_en) begin
            for (int k = 0; k < N; k++)
                mem[wr_addr][k*DW +: DW] <= wr_data[k];
        end
    end

    // ------------------------------------------------------------------- read
    // Registered: this is the one cycle of latency. Reset clears the output
    // register only -- the array itself is left alone, as a real SRAM has no
    // reset on its storage.
    always_ff @(posedge clk) begin
        if (!rst_n)     rd_row_q <= '0;
        else if (rd_en) rd_row_q <= mem[rd_addr];
        // else: hold
    end

    // Unpack the registered row onto the port.
    generate
        for (genvar k = 0; k < N; k++) begin : g_unpack
            assign rd_data[k] = rd_row_q[k*DW +: DW];
        end
    endgenerate

endmodule
