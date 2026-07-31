# Prompt — Generate `tb_integration1.sv`

Write `tb_integration1.sv` — a self-checking SystemVerilog testbench that integrates
and verifies **`skew_buffer.sv` + `systolic_array.sv`** wired together. Both modules
are already individually verified; this test targets the **interface between them**
(timing/alignment at the boundary), not their internal correctness.

**Explicitly out of scope for this integration stage:** no memories, no de-skew, no
output processing, no address generator, no control unit. The testbench itself drives
weights and un-skewed activations directly and reads the array's raw 32-bit diagonal
output.

---

## DUTs AND WIRING

```
Instantiate:
  skew_buffer   #(.N(N), .DW(IN_W), .REVERSE(0))  u_skew
  systolic_array #(.N(N), .IN_W(IN_W), .ACC_W(ACC_W))  u_array

Wiring:
  TB drives skew_buffer.data_in / valid_in  (un-staggered activations, one column of A per cycle)
  skew_buffer.data_out / valid_out  -->  systolic_array.a_in / valid_in   (left edge)
  TB drives systolic_array.weight_top directly (bypasses any weight memory)
  TB drives systolic_array.wload
  systolic_array.psum_out / valid_out  -->  TB reads directly (bottom edge, raw 32-bit)
```

Parameters: `N = 4`, `IN_W = 8`, `ACC_W = 32`. Also re-run key tests at `N = 2`.

---

## GOLDEN MODEL

Same nested-loop matrix multiply as previous testbenches:

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

Sanity-check it once against `[1 2;3 4] × [5 6;7 8] = [19 22;43 50]` before trusting it.

---

## THE CENTRAL DRIVER TASK — `run_matmul(A, B, C_out)`

This is the piece that's different from the standalone array testbench: activations are
now fed **un-skewed** into the skew buffer (the buffer does the staggering), rather than
being hand-skewed by the testbench itself. This is the actual thing being integrated.

1. Reset both DUTs.
2. **Load phase** — drive `wload=1` on the array, present `weight_top` with matrix B
   **bottom row first**, one row per cycle, for N cycles (identical to before — this
   path is untouched by the skew buffer, since weights bypass it entirely). `wload=0`
   after.
3. **Compute phase** — feed the skew buffer **column k of A on lane k, un-staggered**
   (all N lanes presented together, every cycle, valid high) — this is the key
   difference from `tb_array.sv`'s driver, which pre-skewed by hand. Let the skew
   buffer produce the staggered pattern; do NOT stagger in the testbench.
4. **Collect** — watch `systolic_array.valid_out[j]` / `psum_out[j]` (raw, 32-bit, no
   de-skew). Assemble C the same diagonal-collection way as `tb_array.sv`'s driver
   (per-column row counters), since there is no de-skew buffer to realign it yet.
5. Return C.

Debug this task first against the known `[19 22;43 50]` case before trusting any other
test — same discipline as before.

---

## INFRASTRUCTURE

- 10 ns clock, drive on negedge / check on posedge.
- `do_reset()` at the start of every task.
- Fixed `$urandom` seed.
- `$dumpfile` / `$dumpvars`.
- Watchdog: `initial begin #1000000; $error("TIMEOUT"); $finish; end`
- Per-task scoreboard (pass/fail counters), final summary table, and
  `=== INTEGRATION-1 PASSED ===` / `=== INTEGRATION-1 FAILED ===` with failing tasks
  named, same style as previous testbenches.

---

## TEST TASKS

### `test_known()`
- The hand-checked `[1 2;3 4] × [5 6;7 8] = [19 22;43 50]` case (padded to N×N).
- Confirms the skew buffer's staggering lines up correctly with the array's expected
  input timing — the core interface check of this whole test.

### `test_identity_passthrough()`
- I × B = B, A × I = A, run through the real skew buffer (not hand-skewed).
- Catches any lane-mapping error introduced at the skew-buffer-to-array boundary
  specifically (e.g. lane k of the skew buffer wired to the wrong array row).

### `test_alignment_offset()`   — PRIORITY
- This is the test most specific to integration: deliberately check that
  `systolic_array.a_in[k]` receives its value on the EXACT cycle the skew buffer's
  timing model predicts (lane k delayed by k cycles from when the un-skewed column
  was presented), and that this lines up with the array's own internal one-hop-per-
  cycle assumption. A one-cycle mismatch here (e.g. from an unaccounted register
  stage) will silently produce wrong products at specific rows only — check element-
  by-element, not just final totals, so a partial misalignment doesn't hide inside an
  otherwise-plausible sum.

### `test_negative()`
- Negative weights and activations, run through the full integrated path.

### `test_random()`
- 100 random matrices vs `golden()`, through the real skew buffer end to end.

### `test_back_to_back()`
- Two consecutive multiplies with different weights and inputs; confirm no residue
  from the skew buffer's pipeline registers leaks into the next run.

### `test_scaling()`
- Re-run `test_known` and `test_random` at N = 2.

---

## STYLE

- SystemVerilog, tasks for time-consuming operations.
- No hardcoded expected values except the single golden-model sanity check.
- Comment each task with what interface bug it targets, distinct from what the
  standalone array/skew testbenches already covered.
- Keep `run_matmul` and `golden()` as the two sources of truth.
