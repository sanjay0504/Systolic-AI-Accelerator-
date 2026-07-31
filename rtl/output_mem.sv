// -----------------------------------------------------------------------------
// output_mem.sv
//
// Holds matrix C -- the results.
//
// Access pattern: written during operation, read at the end. Results arrive from
// the output side of the array (after de-skew, if used) as one aligned row per
// cycle; the testbench reads them back afterwards to compare against a golden
// matrix.
//
// READ LATENCY IS EXACTLY ONE CYCLE. rd_data reflects the row at rd_addr on the
// cycle AFTER the address is presented with rd_en high, which models a real
// synchronous SRAM.
//
// -----------------------------------------------------------------------------
// PER-LANE WRITE ENABLE
// -----------------------------------------------------------------------------
// wr_valid[k] gates the write of element k independently. Results leave the
// array on a diagonal -- column j finishes at cycle N+n+j -- so during the
// fill and drain periods only some lanes of a row carry real data. A row-wide
// write enable would stamp garbage into the lanes that have not finished yet.
//
// If the output side de-skews into full rows, every lane will usually be valid
// together and this degenerates to a normal row write. The granularity is kept
// anyway: it costs nothing and it is the difference between a partially-written
// row being correct and being silently corrupted.
//
// -----------------------------------------------------------------------------
// NOTE ON DW
// -----------------------------------------------------------------------------
// C entries are accumulator-width, not activation-width. Instantiate this with
// DW = ACC_W (32 in the 4x4 build), not DW = 8 -- an N x N product of 8-bit
// signed values needs far more than 8 bits.
//
// -----------------------------------------------------------------------------
// SELF-CHECK (verification contract)
// -----------------------------------------------------------------------------
//   * A row written to wr_addr with wr_en and all lanes valid is readable one
//     cycle after rd_addr points at it with rd_en high.
//   * Read latency is exactly one cycle; back-to-back reads to different
//     addresses pipeline correctly, one row per cycle with no gaps.
//   * A lane with wr_valid[k] = 0 leaves that element's PREVIOUS contents
//     untouched -- writing a row with one lane masked must not disturb the
//     other lanes, nor the masked lane's old value.
//   * With rd_en low the read register holds its previous value.
//   * A write and a read to the same address on the same cycle returns the OLD
//     row (read-before-write), since both are non-blocking updates.
// -----------------------------------------------------------------------------

module output_mem #(
    parameter int N     = 4,     // elements per row (array lanes)
    parameter int DW    = 8,    // bits per element -- accumulator width
    parameter int DEPTH = 16     // rows storable (>= N)
) (
    input  logic                     clk,
    input  logic                     rst_n,      // active-low, synchronous

    // Write port -- results arriving from the array's output side
    input  logic                     wr_en,
    input  logic [$clog2(DEPTH)-1:0] wr_addr,
    input  logic [DW-1:0]            wr_data  [0:N-1],
    input  logic                     wr_valid [0:N-1],   // per-lane write enable

    // Read-back port -- for the testbench to check C against a golden matrix
    input  logic                     rd_en,
    input  logic [$clog2(DEPTH)-1:0] rd_addr,
    output logic [DW-1:0]            rd_data  [0:N-1]    // registered, 1-cycle latency
);

    localparam int ROW_W = N * DW;

    // Storage is packed one row per location; the ports are unpacked so they
    // connect straight to the de-skew buffer. Element k occupies bits
    // [k*DW +: DW], i.e. lane 0 sits in the least significant bits.
    //
    // No $readmemh preload: this memory starts empty and is filled by the array.
    logic [ROW_W-1:0] mem [0:DEPTH-1];
    logic [ROW_W-1:0] rd_row_q;

    // ------------------------------------------------------------------ write
    // Each lane is written only if its own valid is high, so a partial row
    // leaves the other lanes exactly as they were.
    always_ff @(posedge clk) begin
        if (wr_en) begin
            for (int k = 0; k < N; k++)
                if (wr_valid[k])
                    mem[wr_addr][k*DW +: DW] <= wr_data[k];
        end
    end

    // ------------------------------------------------------------------- read
    // Registered: this is the one cycle of latency. Reset clears the output
    // register only -- the array itself is left alone, as a real SRAM has no
    // reset on its storage. A testbench that wants a known starting state should
    // write zeros, or check only the rows it filled.
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
