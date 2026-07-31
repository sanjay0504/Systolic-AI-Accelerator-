# Prompt — Generate `systolic_array.sv`

Write `systolic_array.sv` — the top-level N×N weight-stationary systolic array for a
matrix-multiplication accelerator. It instantiates N² processing elements and wires
them as a nearest-neighbour mesh. It contains **no control logic, no memories, and no
skew logic** — it assumes correctly-timed data arrives at its edges.

---

## PARAMETERS

```
N      = 4     // array dimension (N×N PEs)
IN_W   = 8     // activation / weight width
ACC_W  = 32    // partial-sum width
```

The design must be fully parameterizable in `N` — a 2×2 or 256×256 array must come
from changing `N` alone, with no other edits.

---

## SUBMODULE

Instantiate `processing_element` (already written). Its ports are:

```
clk, rst_n (active-low sync), wload, valid_in, valid_out
a_in, a_out         : signed [IN_W-1:0]
psum_in, psum_out   : signed [ACC_W-1:0]
```

PE behaviour (for context, do not reimplement):
- holds a stationary weight, loaded from `psum_in[IN_W-1:0]` when `wload` is high
- registers `a_in`→`a_out` and `valid_in`→`valid_out` (one-cycle hop)
- `psum_q = valid_in ? psum_in + weight*a_in : psum_in`
- `psum_out` is muxed: sign-extended weight during load, `psum_q` during compute

---

## PORTS (of the array)

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `clk` | in | 1 | broadcast to all PEs |
| `rst_n` | in | 1 | active-low synchronous, broadcast |
| `wload` | in | 1 | load phase select, broadcast |
| `a_in [N]` | in | N × IN_W (signed) | left edge — activations (already skewed) |
| `valid_in [N]` | in | N × 1 | left edge — valid tags |
| `weight_top [N]` | in | N × IN_W (signed) | top edge — weights during load |
| `psum_out [N]` | out | N × ACC_W (signed) | bottom edge — results |
| `valid_out [N]` | out | N × 1 | bottom edge — result-ready tags |

Use packed arrays or an unpacked vector of N — pick one convention and keep it
consistent. Right-edge `a_out`/`valid_out` are intentionally left unconnected.

---

## INTERNAL WIRING — the oversized-array trick

Declare interconnect arrays one larger than the PE grid in the direction of travel,
so the edges become plain indices:

```systemverilog
logic signed [IN_W-1:0]  a_wire     [0:N-1][0:N];   // N+1 cols: [0]=left in, [N]=dangle
logic                    valid_wire [0:N-1][0:N];
logic signed [ACC_W-1:0] psum_wire  [0:N][0:N-1];   // N+1 rows: [0]=top in, [N]=bottom out
```

Each PE(i,j) connects as:
```
.a_in     (a_wire[i][j])      .a_out    (a_wire[i][j+1])
.valid_in (valid_wire[i][j])  .valid_out(valid_wire[i][j+1])
.psum_in  (psum_wire[i][j])   .psum_out (psum_wire[i+1][j])
```

Build the grid with a nested `generate` (genvar i, j).

---

## EDGE CONNECTIONS

**Left edge** (`j = 0`), for each row i:
```
a_wire[i][0]     = a_in[i]
valid_wire[i][0] = valid_in[i]
```

**Top edge** (`i = 0`), for each column j — this is the muxed, dual-purpose edge:
```
psum_wire[0][j] = wload ? {{(ACC_W-IN_W){weight_top[j][IN_W-1]}}, weight_top[j]}  // sign-extended weight
                        : '0;                                                      // zero during compute
```
The sign-extension MUST match what the PE does internally, or negative weights
corrupt in the lower rows only.

**Bottom edge** (`i = N-1`), for each column j:
```
psum_out[j]  = psum_wire[N][j]
valid_out[j] = valid_wire[N][j]    // valid from bottom PE
```

Note: `valid` travels horizontally (row chains), so the bottom-edge valid comes from
each bottom PE's own `valid_out`. Confirm this lines up with the finished psum on the
same cycle.

**Right edge** (`j = N`): `a_wire[i][N]` and `valid_wire[i][N]` dangle — leave unconnected.

---

## STYLE

- SystemVerilog, `logic`, `always_ff` only inside the PE (this module is structural).
- No latches, no combinational loops.
- Comment the top-edge mux clearly as the weight-load / compute dual-purpose path.
- Comment which physical edge each generate boundary corresponds to.

---

## SELF-CHECK (add as comments at the top)

State the intended behaviour so it can be verified later:
- during LOAD (`wload`=1, N cycles): weights shift down the columns via the psum path,
  bottom row loaded first
- during COMPUTE (`wload`=0): skewed activations enter left, partial sums accumulate
  down each column, results emerge at the bottom edge with their valid tags
- a value C[n][j] emerges at `psum_out[j]` at cycle `N + n + j` (compute-relative)
