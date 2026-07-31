# Prompt — Generate the three memory modules

Write three separate SystemVerilog memory modules for a weight-stationary systolic
array accelerator: `weight_mem.sv`, `act_mem.sv`, and `output_mem.sv`. They share a
skeleton (synchronous, wide row-at-a-time access, `$readmemh` init) but each has a
distinct access pattern. Keep them as three explicit modules — do not merge into one.

---

## SHARED CONVENTIONS (apply to all three)

```
Parameters:  N  = 4      // lanes / row width
             DW = 8      // data width per element
             DEPTH = 16  // number of rows storable (>= N; 16 gives headroom)
```

- **Wide access:** each memory location holds a full row of `N` elements, i.e. the
  storage is `DEPTH` locations of `N*DW` bits. Read/write a whole row per cycle.
- **Synchronous read:** the read data appears **one cycle after** the address is
  presented (registered read, models real SRAM). State this latency in a header
  comment — the address generator must issue addresses one cycle early.
- **Active-low synchronous reset** `rst_n`.
- `logic`, `always_ff`, no latches.
- Expose row data as an unpacked vector `[0:N-1]` of `DW`-bit elements on the ports
  (so it connects directly to the array / skew buffer), even though internal storage
  may be packed `N*DW`. Pick one convention and convert cleanly at the port.

---

## MODULE 1 — `weight_mem.sv`  (holds matrix B)

Read-mostly. Written once at setup (or preloaded from file); read during the LOAD
phase, **bottom row first**.

Ports:
```
clk, rst_n
rd_en
rd_addr        : [$clog2(DEPTH)-1:0]     // row address
rd_data [N]    : [DW]  (registered, 1-cycle latency)
// write side (for testbench / setup load):
wr_en
wr_addr        : [$clog2(DEPTH)-1:0]
wr_data [N]    : [DW]
```

- The **reverse-order (bottom-row-first)** read is NOT done inside this module — the
  address generator supplies the reversed addresses. This memory just reads whatever
  `rd_addr` it is given. Note this in a comment so nobody adds reversing logic here.
- `$readmemh` init (guarded by `ifndef SYNTHESIS`) from a parameterizable filename
  (e.g. `WEIGHT_INIT`), so a testbench can preload B.

---

## MODULE 2 — `act_mem.sv`  (holds matrix A)

Read-mostly. Read during COMPUTE, one row/column per cycle, feeding the skew buffer.

Ports: same shape as `weight_mem` (rd_en/rd_addr/rd_data + wr_en/wr_addr/wr_data),
with its own `$readmemh` init filename (e.g. `ACT_INIT`).

- Comment that its `rd_data` feeds the skew buffer's `data_in`, and that this memory
  performs NO skewing — the skew buffer does that downstream.

---

## MODULE 3 — `output_mem.sv`  (holds matrix C)

Write-during-operation, read-at-end. Receives results from the output side (after
de-skew, if used), one aligned row per cycle.

Ports:
```
clk, rst_n
wr_en
wr_addr        : [$clog2(DEPTH)-1:0]
wr_data [N]    : [DW]
wr_valid [N]                            // per-lane valid (write only valid lanes)
// read-back for verification:
rd_en
rd_addr        : [$clog2(DEPTH)-1:0]
rd_data [N]    : [DW]  (registered, 1-cycle latency)
```

- Support **per-lane write-enable** via `wr_valid[k]`: only lanes whose valid is high
  are written that cycle (so partial rows and the diagonal-fill period don't clobber
  slots with garbage). If the output side de-skews into full rows, all lanes will
  usually be valid together, but keep per-lane granularity for safety.
- No `$readmemh` init (starts empty). Optionally initialize to 0 on reset.
- The read-back port is for the testbench to check results against a golden matrix.

---

## STYLE

- Three separate files, each self-contained.
- Header comment on each: what it holds, its access pattern, and the 1-cycle read
  latency.
- Comment explicitly where responsibility does NOT lie (weight_mem doesn't reverse;
  act_mem doesn't skew) — these are the two most likely places someone wrongly adds
  logic.
- Parameterizable in N, DW, DEPTH.

---

## SELF-CHECK (state as comments)

- A write to `wr_addr` with `wr_en` (and valid lanes) is readable one cycle after
  `rd_addr` points at it with `rd_en`.
- Read latency is exactly one cycle; back-to-back reads to different addresses produce
  correctly pipelined data.
- output_mem: a lane with `wr_valid[k]=0` leaves that element's previous contents
  untouched.
