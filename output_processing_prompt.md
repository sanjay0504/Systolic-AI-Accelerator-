# Prompt — Generate `output_processing.sv`

Write `output_processing.sv` — a purely combinational SystemVerilog module that
converts the systolic array's raw accumulator output into a small, storable result.
It sits between the array's bottom edge and the de-skew buffer:

```
array (32-bit psum_out) -> output_processing -> de-skew (8-bit) -> output_mem
```

No clock, no reset — this is a combinational, per-element pipeline. `valid` passes
straight through unchanged.

---

## PARAMETERS

```
N        = 4      // lanes (matches array width)
ACC_W    = 32      // input width (accumulator)
DW_OUT   = 8        // output width
SHIFT    = 8         // right-shift amount for scaling (tune per workload)
USE_BIAS = 0          // 0 = skip bias add, 1 = apply per-lane bias
USE_RELU = 0          // 0 = skip ReLU, 1 = apply per-lane ReLU
```

`USE_BIAS` and `USE_RELU` must be compile-time toggles (via `generate`/`if`), not just
runtime muxes with the feature always present — when disabled, that logic should not
be instantiated at all, since a plain matrix-multiply application should not pay area
for unused bias adders or ReLU comparators.

---

## PORTS

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `psum_in [N]` | in | N × ACC_W, signed | raw array output, one per column |
| `valid_in [N]` | in | N × 1 | valid per column, from array |
| `bias [N]` | in | N × ACC_W, signed | per-column bias (ignored if `USE_BIAS=0`) |
| `data_out [N]` | out | N × DW_OUT, signed | processed, shrunk result |
| `valid_out [N]` | out | N × 1 | valid, passed through unchanged |

Tie `bias` to zero at the instantiation site when `USE_BIAS=0` — don't rely on the
module to ignore a floating/undriven port.

---

## PER-LANE PIPELINE — apply in this exact order

```
psum_in
  -> [1] add bias        (if USE_BIAS)   : biased = psum_in + bias
  -> [2] ReLU             (if USE_RELU)   : activated = biased[ACC_W-1] ? '0 : biased
  -> [3] arithmetic shift  (always)         : scaled = activated >>> SHIFT
  -> [4] saturate          (always)          : clamp scaled to [-(2^(DW_OUT-1)), 2^(DW_OUT-1)-1]
  -> data_out
```

**Order is not arbitrary — do not reorder.** Bias and ReLU must be applied at full
`ACC_W` precision, BEFORE scaling down. Scaling first would corrupt the bias add and
make ReLU's sign decision happen on already-truncated data.

Use `>>>` (arithmetic right shift) for step 3, never `>>` — a logical shift would
zero-fill instead of sign-extending and corrupt negative values. This mirrors the
sign-extension requirement already used on the array's weight-load path.

## SATURATION LOGIC

```systemverilog
localparam signed [ACC_W-1:0] MAX_OUT = (1 <<< (DW_OUT-1)) - 1;   //  127 for DW_OUT=8
localparam signed [ACC_W-1:0] MIN_OUT = -(1 <<< (DW_OUT-1));      // -128 for DW_OUT=8

always_comb begin
    if      (scaled > MAX_OUT) data_out[k] = DW_OUT'(MAX_OUT);
    else if (scaled < MIN_OUT) data_out[k] = DW_OUT'(MIN_OUT);
    else                       data_out[k] = scaled[DW_OUT-1:0];
end
```

Parameterize the bounds from `DW_OUT` rather than hardcoding 127/-128, so the module
stays correct if `DW_OUT` is ever changed.

---

## STYLE

- `logic`, `always_comb` throughout — no `always_ff`, no latches.
- Build with a `generate` over the N lanes; each lane is fully independent (no
  cross-lane logic at all).
- Comment the pipeline order explicitly, and comment WHY it's this order (bias/ReLU
  before scaling, not after).
- Comment the arithmetic-vs-logical shift choice.

---

## SELF-CHECK (state as comments at top)

- With `USE_BIAS=0, USE_RELU=0`: module reduces to shift + saturate only (plain
  matmul mode).
- A value that fits within [MIN_OUT, MAX_OUT] after scaling passes through unchanged
  in its low `DW_OUT` bits.
- A negative `psum_in`, with `USE_RELU=1`, produces `data_out = 0` for that lane,
  regardless of `SHIFT` or `bias`... unless bias pushes it non-negative first (bias is
  applied before ReLU, so this is expected, not a bug).
- Saturation triggers symmetrically at both the positive and negative bound.
