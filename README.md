# Reconfigurable Dataflow Matrix Multiplication Accelerator

A parameterizable systolic-array accelerator for integer matrix multiplication,
implemented in SystemVerilog and verified in ModelSim. Built around a weight-stationary
4×4 processing array, with a modular output-processing stage that lets the same core
serve as a general matrix multiplier or a neural-network inference building block.

## Architecture

```
weight_mem ──▶ [pad mux] ──┐
                            ├──▶ systolic_array ──▶ output_processing ──▶ de-skew ──▶ output_mem
act_mem ──▶ [pad mux] ──▶ skew_buffer ──▶ (array left edge)

address_gen ──▶ drives read/write addresses + padding masks for all of the above
control_unit ──▶ sequences LOAD → COMPUTE → DRAIN → DONE, drives address_gen and wload
```

- **Processing element (PE)** — weight-stationary multiply-accumulate unit. Reuses the
  partial-sum interconnect for weight loading, eliminating a dedicated weight-distribution
  network.
- **Systolic array** — 4×4 grid of PEs, parameterizable in N, wired as a nearest-neighbour
  mesh.
- **Skew / de-skew buffer** — a single reusable module (`REVERSE` parameter) that staggers
  activations into the array and realigns the diagonal output back into rows.
- **Memory subsystem** — separate activation, weight, and output memories, wide
  (row-at-a-time) access, synchronous read, 1-cycle registered latency.
- **Output processing** — combinational per-lane stage: optional bias and ReLU, always-on
  scale (arithmetic shift) and saturate, converting 32-bit accumulator values into 8-bit
  results.
- **Address generator** — produces weight/activation read addresses (including the
  bottom-row-first weight load order) and output write addresses, sequenced per phase.
  Also generates padding masks (see below).
- **Control unit (FSM)** — sequences `IDLE → LOAD → COMPUTE → DRAIN → DONE`, driving
  `address_gen`'s phase and the array's `wload` with the correct one-cycle timing
  offset required by the memories' registered read latency.
- **Padding** — matrices smaller than 4×4 are supported by zero-injecting unused rows
  at the two input edges (weight and activation), controlled by a runtime `K_real`
  input. The array always computes a full 4×4 result; unused output rows are simply
  never read back. Verified using "poisoned" (non-zero) padding data, so a correct
  result is only possible if the zero-injection is genuinely functioning.
- **Tiling** (matrices larger than 4×4) — designed for but not implemented. Would
  extend the address generator with an outer block-loop and add an accumulation
  stage between the array and output memory; deferred in favor of verification depth
  on the core datapath.

## Repository structure

```
rtl/    RTL design modules (.sv)
tb/     Self-checking testbenches (.sv)
```

## Verification approach

Every module is verified independently, bottom-up, before integration:

```
PE → Systolic Array → Skew/De-skew Buffer → Address Generator → Control Unit → Top-level
```

Each testbench is self-checking against a golden reference model, with a per-task
pass/fail scoreboard. Test design specifically targets failure modes likely to hide
silently — signed-arithmetic errors, bubble/valid-gating gaps, reset incompleteness,
and off-by-one timing — rather than only nominal-case functionality.

The top-level design (`accelerator_top`) is verified as a **black box**, driven only
through its external ports (`start`/`done` and the memory read/write interfaces) —
mirroring how a real host would use the accelerator, so a passing result reflects the
system as a whole, not just its parts in isolation. Padding correctness is confirmed
using deliberately non-zero ("poisoned") data in unused matrix regions, so a passing
result is only possible if zero-injection is genuinely functioning, not coincidental.

## Running the testbenches

From the project root, using ModelSim/Questa:

```bash
vlib work
vlog -sv rtl/*.sv tb/tb_pe.sv
vsim -c -voptargs="+acc" tb_pe -do "run -all; quit"
```

Substitute the relevant testbench (`tb_array`, `tb_skew`, `tb_output_processing`, etc.)
and its dependent RTL files as needed.

## Status

| Module | RTL | Testbench | Status |
|---|---|---|---|
| Processing element | ✅ | ✅ | Verified |
| Systolic array | ✅ | ✅ | Verified |
| Skew / de-skew buffer | ✅ | ✅ | Verified |
| Output processing (incl. bias / ReLU) | ✅ | ✅ | Verified |
| Address generator (+ padding) | ✅ | ✅ | Verified |
| Control unit (FSM) | ✅ | ✅ | Verified |
| Top-level integration (+ padding) | ✅ | ✅ | Verified (black-box) |
| Weight / activation / output memory | ✅ | — | Proven correct via top-level tests; no dedicated unit testbench |
| Tiling (matrices > 4×4) | — | — | Designed, not implemented |
| Synthesis (area / timing / power) | — | — | Planned next |

**Supported matrix sizes:** any M×K×N up to 4×4×4, via padding. Larger matrices are
not yet supported (see Tiling above).

## License

*(add a license if you plan to make this repo public)*
