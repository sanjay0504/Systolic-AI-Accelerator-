# Prompt — Generate `tb_array.sv`

Write `tb_array.sv` — a self-checking SystemVerilog testbench for `systolic_array.sv`,
an N×N weight-stationary systolic array. The PE is already verified; this testbench
targets **wiring, edge, timing, and dataflow** bugs, not arithmetic. It must be fully
self-checking with a golden reference model and a per-task scoreboard.

---

## DUT PARAMETERS

```
N     = 4
IN_W  = 8
ACC_W = 32
```

Instantiate so N can be changed in one place (also test with N=2 to confirm scaling).

## DUT PORTS

```
clk, rst_n (active-low sync), wload
a_in       [N] : signed [IN_W-1:0]   left edge (activations, already skewed by the TB)
valid_in   [N] : [N] × 1             left edge valid
weight_top [N] : signed [IN_W-1:0]   top edge (weights during load)
psum_out   [N] : signed [ACC_W-1:0]  bottom edge (results)
valid_out  [N] : [N] × 1             bottom edge valid
```

---

## GOLDEN MODEL (reference)

A plain nested-loop matrix multiply the testbench computes independently. Every
expected value comes from this — never hand-type expected matrices except the single
sanity case used to check the golden model itself.

```systemverilog
function automatic void golden(
    input  logic signed [IN_W-1:0]  A [N][N],
    input  logic signed [IN_W-1:0]  B [N][N],
    output logic signed [ACC_W-1:0] C [N][N]
);
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) begin
            C[i][j] = '0;
            for (int k = 0; k < N; k++)
                C[i][j] += A[i][k] * B[k][j];
        end
endfunction
```

Sanity-check the golden model once against the hand-computed case
`[1 2;3 4] × [5 6;7 8] = [19 22;43 50]` before trusting it.

---

## THE CENTRAL DRIVER TASK — `run_matmul(A, B, C_out)`

This is the hardest and most important part. One task that performs a complete
multiply on the DUT and returns the collected result. Every test calls it, so if it
is correct the tests are trivial, and if it is wrong everything fails misleadingly.
**Debug this task first, using the [19 22;43 50] case, before trusting any test.**

It must:
1. Reset the DUT.
2. **Load phase** — drive `wload=1`, stream B into `weight_top` **bottom row first**
   (row N-1 on the first load cycle), for N cycles. Then `wload=0`.
3. **Compute phase** — feed A into the left edge, **skewed**: array row k receives
   **column k of A**, and row k starts one cycle later than row k-1. Set `valid_in[k]`
   high only on the cycles that row is presenting real data; low (bubble) otherwise.
4. **Collect** — watch each column's `valid_out[j]`; when high, capture `psum_out[j]`
   as C[row_counter[j]][j], incrementing that column's row counter. Handle the
   diagonal arrival (column j's results appear at cycle N + n + j).
5. Return the fully assembled C matrix.

Provide helper tasks: `do_reset()`, and a `check_matrix(string tname, C_got, C_exp)`
that compares element-by-element and updates the scoreboard.

---

## INFRASTRUCTURE

- 10 ns clock. Drive on negedge, sample/check on posedge (no race conditions).
- `do_reset()` called at the start of every test task — no state leaks between tests.
- Fixed `$urandom` seed at top for reproducibility.
- `$dumpfile`/`$dumpvars` for waveforms.
- Watchdog: `initial begin #1000000; $error("TIMEOUT"); $finish; end`

---

## SCOREBOARD

- Per-task pass and fail counters, plus global totals.
- `check_matrix()` increments the calling task's counters; on any element mismatch it
  prints:
  `[FAIL] <tname>: C[%0d][%0d] expected=%0d got=%0d`
  and marks that task failed.
- At the end, print a summary table: one row per task with pass count, fail count, and
  PASS/FAIL status, then global totals.
- End with `=== ARRAY TESTBENCH PASSED ===` or, if any task failed,
  `=== ARRAY TESTBENCH FAILED ===` followed by a list naming each failing task.
- Call `$finish`.

---

## TEST TASKS — in this order (each exposes a specific class of wiring bug)

### `test_identity_identity()`
- I × I should give I. A transposed or shifted identity means an `[i][j]` index swap.

### `test_passthrough()`
- I × B should give B exactly; A × I should give A exactly.
- Catches row/column permutation in the edge mapping.

### `test_ones()`
- all-ones × all-ones: every element of C must equal exactly N.
- A single wrong element localizes the misbehaving column/PE immediately.

### `test_known()`
- The hand-checked `[1 2;3 4] × [5 6;7 8] = [19 22;43 50]` case (pad to N×N with
  zeros / identity as needed). Direct check against known values.

### `test_negative()`  — PRIORITY
- Matrices with **negative weights and negative activations**.
- This exercises the top-edge sign-extension on the weight-load path. If positive
  tests pass but this fails — especially if it fails only in the lower rows — the
  top-edge mux is zero-extending instead of sign-extending.
- Include all four sign combinations across the matrices.

### `test_timing()`  — PRIORITY
- Verify the dataflow, not just final values: confirm `C[n][j]` appears on
  `psum_out[j]` with `valid_out[j]` high at cycle **N + n + j** (compute-relative).
- Catches right-answers-at-wrong-times bugs and broken skew.

### `test_random()`
- 100 random matrices vs `golden()`. Full-range signed values.

### `test_back_to_back()`
- Two (and then several) multiplies with different weights in succession.
- Confirms weights reload cleanly and no partial sum residue leaks between runs.

### `test_scaling()`
- Re-run a representative subset with N=2 (separate DUT instance or parameter) to
  confirm the array is genuinely parameterizable and not hardcoded for N=4.

---

## STYLE

- SystemVerilog, tasks for anything consuming time.
- No hardcoded expected values except the single golden-model sanity check.
- Comment each task with the bug class it targets.
- Keep `run_matmul` and the golden model as the two sources of truth; everything else
  compares one against the other.
