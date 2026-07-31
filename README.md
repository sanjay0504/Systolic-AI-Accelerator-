# Reconfigurable Dataflow Matrix Multiplication Accelerator

A parameterizable systolic-array accelerator for integer matrix multiplication,
implemented in SystemVerilog and verified in ModelSim. Built around a weight-stationary
4×4 processing array, with a modular output-processing stage that lets the same core
serve as a general matrix multiplier or a neural-network inference building block.

## Architecture

```
weight_mem ──┐
             ├──▶ systolic_array ──▶ output_processing ──▶ de-skew ──▶ output_mem
act_mem ──▶ skew_buffer ──▶ (array left edge)
```

- **Processing element (PE)** — weight-stationary multiply-accumulate unit. Reuses the
  partial-sum interconnect for weight loading, eliminating a dedicated weight-distribution
  network.
- **Systolic array** — 4×4 grid of PEs, parameterizable in N, wired as a nearest-neighbour
  mesh.
- **Skew / de-skew buffer** — a single reusable module (`REVERSE` parameter) that staggers
  activations into the array and realigns the diagonal output back into rows.
- **Memory subsystem** — separate activation, weight, and output memories, wide
  (row-at-a-time) access, synchronous read.
- **Output processing** — combinational per-lane stage: optional bias and ReLU, always-on
  scale (arithmetic shift) and saturate, converting 32-bit accumulator values into 8-bit
  results.
- **Address generator / control FSM** — *in progress*.

## Repository structure

```
rtl/    RTL design modules (.sv)
tb/     Self-checking testbenches (.sv)
```

## Verification approach

Every module is verified independently, bottom-up, before integration:

```
PE → Systolic Array → Skew/De-skew Buffer → Memories → Address Generator → Control Unit → Top-level
```

Each testbench is self-checking against a golden reference model, with a per-task
pass/fail scoreboard. Test design specifically targets failure modes likely to hide
silently — signed-arithmetic errors, bubble/valid-gating gaps, reset incompleteness,
and off-by-one timing — rather than only nominal-case functionality.

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
| Weight / activation / output memory | ✅ | — | In progress |
| Output processing | ✅ | — | In progress |
| Address generator | — | — | Not started |
| Control unit (FSM) | — | — | Not started |
| Top-level integration | — | — | Not started |

## License

*(add a license if you plan to make this repo public)*
