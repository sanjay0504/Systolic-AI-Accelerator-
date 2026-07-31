# Prompt — Generate `skew_buffer.sv`

Write `skew_buffer.sv` — a reusable SystemVerilog module that staggers (or
de-staggers) N parallel data lanes using a triangular chain of delay registers. The
**same module** serves two roles, selected by a parameter:

- **Input skew** (`REVERSE=0`): staggers activations before they enter the array —
  lane 0 passes straight through, lane N-1 is delayed the most.
- **Output de-skew** (`REVERSE=1`): realigns the array's diagonal output back into
  rows — lane 0 is delayed the most, lane N-1 passes straight through.

This module contains **no padding logic** — zero-padding for sub-N×N matrices is
handled in a separate upstream module. Keep this one purely about delaying lanes.

---

## PARAMETERS

```
N       = 4     // number of lanes
DW      = 8     // data width per lane
REVERSE = 0     // 0 = skew (input side), 1 = de-skew (output side)
```

Must be fully parameterizable in N — the delay pattern is computed from N, not
hardcoded.

---

## PORTS

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `clk` | in | 1 | |
| `rst_n` | in | 1 | active-low synchronous reset |
| `data_in [N]` | in | N × DW | one value per lane, un-staggered |
| `valid_in [N]` | in | N × 1 | valid per lane |
| `data_out [N]` | out | N × DW | staggered / de-staggered output |
| `valid_out [N]` | out | N × 1 | valid, delayed to match its data |

Pick one array convention (packed or unpacked) and keep it consistent.

---

## DELAY PATTERN

Each lane `k` passes through `delay[k]` register stages:

```
REVERSE = 0 (skew):     delay[k] = k          // lane 0 = 0 regs, lane N-1 = N-1 regs
REVERSE = 1 (de-skew):  delay[k] = N-1-k      // lane 0 = N-1 regs, lane N-1 = 0 regs
```

A lane with `delay[k] = 0` is a straight pass-through (no register).

---

## CRITICAL REQUIREMENT — valid travels WITH its data

Each register stage must delay the **data and its valid bit together**, by the same
number of stages. Treat each stage as holding `{valid, data}` (DW+1 bits) so the valid
tag can never separate from the value it describes. A design that delays data but not
valid (or by a different amount) is wrong.

On reset, all pipeline stages clear to 0 (data 0, valid 0).

---

## IMPLEMENTATION NOTES

- Build with a `generate` over the N lanes. Each lane instantiates a shift chain whose
  length is `delay[k]` (computed above). Lanes of length 0 are wired straight through.
- Cleanest approach: for each lane, declare a small array of `DW+1`-bit stage
  registers and connect them in series inside an `always_ff`.
- Total storage is `N(N-1)/2 × (DW+1)` bits either direction — same triangle.
- `logic`, `always_ff`, no latches, no combinational loops.

---

## USAGE (for context — do not implement, just design to fit)

```systemverilog
// input skew: activations, 8-bit
skew_buffer #(.N(4), .DW(8), .REVERSE(0)) u_skew (
    .clk, .rst_n,
    .data_in(act_col), .valid_in(act_valid),
    .data_out(a_to_array), .valid_out(valid_to_array)
);

// output de-skew: post-output-processing results, 8-bit
skew_buffer #(.N(4), .DW(8), .REVERSE(1)) u_deskew (
    .clk, .rst_n,
    .data_in(proc_result), .valid_in(proc_valid),
    .data_out(row_aligned), .valid_out(row_valid)
);
```

---

## SELF-CHECK (state as comments at top)

- With `REVERSE=0`, if all N lanes present valid data on the same cycle, then at the
  output lane k appears k cycles later than lane 0 (a descending staircase).
- With `REVERSE=1`, the staircase is mirrored: lane 0 is delayed most, lane N-1 not at
  all, so a diagonal input emerges aligned.
- In both cases `valid_out[k]` is delayed by exactly the same `delay[k]` as
  `data_out[k]`.
