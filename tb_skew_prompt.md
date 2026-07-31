# Prompt — Generate `tb_skew.sv`

Write `tb_skew.sv` — a self-checking SystemVerilog testbench for `skew_buffer.sv`, the
reusable triangular delay module used for both input skew (`REVERSE=0`) and output
de-skew (`REVERSE=1`). It must be fully self-checking with a reference (golden) delay
model and a per-task scoreboard.

---

## DUT PARAMETERS

```
N       = 4
DW      = 8
REVERSE = 0 or 1   // instantiate BOTH; some tests need each mode
```

Instantiate multiple DUTs as needed: one with `REVERSE=0`, one with `REVERSE=1`, and
(for the round-trip test) the two chained together. Also support re-testing with N=2.

## DUT PORTS

```
clk, rst_n (active-low sync)
data_in  [N] : [DW]     un-staggered input, one value per lane
valid_in [N] : 1        valid per lane
data_out [N] : [DW]     staggered / de-staggered output
valid_out[N] : 1        valid, delayed to match its data
```

---

## GOLDEN MODEL (reference delay model)

This module is about *timing*, not arithmetic — so the golden model is a per-lane
delay predictor, not a matrix multiply.

For a value presented on `data_in[k]` at cycle T with `valid_in[k]` high, it must
appear on `data_out[k]` at cycle `T + expected_delay(k)`, where:

```systemverilog
function automatic int expected_delay(input int k, input bit reverse, input int n);
    return reverse ? (n - 1 - k) : k;
endfunction
```

Implement the check by tagging each input value with the cycle it entered (e.g. push
{value, entry_cycle} into a per-lane queue), then at the output pop and confirm the
value emerged at `entry_cycle + expected_delay(k)` with valid high. `valid_out[k]`
must assert on exactly that cycle — not earlier, not later.

---

## SCOREBOARD

- Per-task and per-lane pass/fail counters, plus global totals.
- A `check(string tname, ...)` helper that logs on mismatch:
  `[FAIL] <tname>: lane %0d value=%0d expected_cycle=%0d got_cycle=%0d`
  and marks the task failed.
- Final summary table: one row per task with pass count, fail count, PASS/FAIL.
- End with `=== SKEW BUFFER PASSED ===` or, if any task failed,
  `=== SKEW BUFFER FAILED ===` followed by a list naming each failing task.
- `$finish`.

---

## INFRASTRUCTURE

- 10 ns clock. Drive on negedge, sample/check on posedge (no races).
- `do_reset()` at the start of every task — no state leaks between tests.
- Fixed `$urandom` seed for reproducibility.
- `$dumpfile`/`$dumpvars` for waveforms.
- Watchdog: `initial begin #500000; $error("TIMEOUT"); $finish; end`

---

## TEST TASKS

### `test_skew_pattern()`   (REVERSE=0)
- Present a distinct value on every lane on one cycle, all valid high
  (e.g. lane k gets value k+1).
- Confirm lane k emerges exactly k cycles later — a descending staircase —
  checked against `expected_delay`.

### `test_deskew_pattern()`   (REVERSE=1)
- Same stimulus, mirrored expectation: lane k emerges (N-1-k) cycles later.

### `test_valid_tracking()`   — PRIORITY
- Drive data with valid high, but ALSO drive **non-zero data on valid=0 cycles**
  (junk that must not be mistaken for real data).
- Confirm `valid_out[k]` asserts on exactly the same cycle as its `data_out[k]`,
  delayed by `expected_delay(k)`.
- A design that delays data but not valid (or by a different amount) must FAIL here.

### `test_roundtrip()`   — PRIORITY
- Chain skew (REVERSE=0) → de-skew (REVERSE=1), nothing between.
- Feed arbitrary data on all lanes; confirm `data_out` equals `data_in` delayed by
  exactly N-1 cycles on EVERY lane, fully aligned (since k + (N-1-k) = N-1).
- This is the strongest single test. But keep the individual-mode tests too, since a
  symmetric bug in both modes could cancel and still round-trip cleanly.

### `test_reset()`
- Assert reset mid-stream; confirm all pipeline stages flush to 0 and no stale value
  survives to the output.

### `test_bubbles()`
- Feed an intermittent valid pattern (valid, invalid, valid, ...).
- Confirm gaps propagate through the delay chain intact and values still emerge at the
  correct staggered cycles.

### `test_scaling()`
- Re-instantiate with N=2 and re-run `test_skew_pattern` and `test_roundtrip` to
  confirm the delay pattern is computed from N, not hardcoded for N=4.

---

## STYLE

- SystemVerilog, tasks for anything consuming time.
- Per-lane queues (or equivalent) as the reference model; no hardcoded expected cycles
  except a small sanity check.
- Comment each task with the bug class it targets.
- Keep the delay golden model and the DUT as the two sources of truth; the scoreboard
  compares one against the other.
