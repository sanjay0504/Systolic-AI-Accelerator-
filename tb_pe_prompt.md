# Prompt — Generate `tb_pe.sv`

Write `tb_pe.sv` — a self-checking SystemVerilog testbench for `processing_element.sv`,
a weight-stationary systolic array PE.

---

## DUT PORTS

```
clk, rst_n (active-low, synchronous), wload, valid_in, valid_out
a_in, a_out         : signed [IN_W-1:0],  IN_W  = 8
psum_in, psum_out   : signed [ACC_W-1:0], ACC_W = 32
```

Instantiate with parameters so widths can be changed in one place.

---

## INFRASTRUCTURE

- 10 ns clock (5 ns half period).
- Drive stimulus on the **negedge**, sample/check on the **posedge**, so there are
  no race conditions between driving and checking.
- `task do_reset()` — assert `rst_n` low for 2 cycles, release, wait 1 cycle.
  Call it at the start of **every** task so no state leaks between tests.
- `task load_weight(input signed [IN_W-1:0] w)` — sets `wload=1`, drives `w` on
  `psum_in[IN_W-1:0]`, waits a cycle, sets `wload=0`.
- `function signed [ACC_W-1:0] golden(psum, w, a)` — returns `psum + w*a`.
  All expected values come from this, never hand-typed.
- `task check(input string tname, input signed [ACC_W-1:0] got, exp, input string note)`
  — increments that task's pass or fail counter, and on failure prints:
  `[FAIL] <tname>: <note> expected=%0d got=%0d at time %0t`
- Per-task pass/fail counters plus global totals.
- Use `$urandom` with a **fixed seed** set at the top so runs are reproducible.
- `$dumpfile` / `$dumpvars` for waveforms.
- A watchdog: `initial begin #500000; $error("TIMEOUT"); $finish; end`

---

## TASKS — one per category, each calling `do_reset()` first

### `test_reset()`
- `rst_n` low: `a_out`, `valid_out`, `psum_out` all 0
- No X on any output after release
- Confirm reset is **synchronous** (takes effect on clock edge, not immediately)

### `test_weight_load()`
- `wload=1`: `weight_q` captures **only** `psum_in[7:0]`; put garbage in `[31:8]`
  and confirm it is ignored
- While `wload=1`, `psum_out` must equal the **sign-extended** weight
  (load `-5`, expect `32'hFFFF_FFFB`, not `32'h0000_00FB`)
- Loading a second weight overwrites the first

### `test_stationarity()`
- Load a weight, drop `wload`, run 20 cycles of varied activations
- Weight must not change; verify via MAC results against `golden()`

### `test_hop_timing()`
- `a_in` change appears on `a_out` exactly **one cycle** later
  (not same cycle = combinational, not two = extra register)
- Same for `valid_in` -> `valid_out`
- `a_out` and `valid_out` must change on the **same edge**

### `test_mac()`
- Randomised: `valid_in=1`, random weight / activation / `psum_in`
- `psum_out == golden(psum_in, weight, a_in)` one cycle later
- Include `psum_in = 0` (top-edge case) and non-zero (mid-column case)

### `test_bubble()`
- `valid_in=0` with **deliberately non-zero junk** on `a_in` (e.g. `8'h7F`)
- `psum_out` must equal `psum_in` exactly, unchanged
- Do **not** use `a_in=0` here; that would pass even if gating is broken

### `test_signed()`
- All four sign combinations: `(+5,+3)`, `(-5,+3)`, `(+5,-3)`, `(-5,-3)`
- Plus a negative `psum_in` flowing through

### `test_boundary()`
- `127*127`, `-128*-128`, `-128*127`
- Confirm no truncation in the 32-bit result

### `test_transitions()`
- `wload` high then low: first compute cycle uses the **new** weight
- `wload` high while `valid_in` also high: confirm it does not corrupt the
  **next** compute cycle
- load -> compute -> load -> compute, twice, no residue

---

## FINAL REPORT

Print a summary table: one row per task with its pass count, fail count, and
PASS/FAIL status. Then global totals.

End with `=== PE TESTBENCH PASSED ===` or, if any task failed,
`=== PE TESTBENCH FAILED ===` followed by a list naming each failing task.

Call `$finish`.

---

## STYLE

- Use tasks (not functions) for anything consuming time.
- No hardcoded expected values — derive from `golden()`.
- Comment each task with what bug it is designed to catch.
