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
  offset required by the memories' registered read latency. Supports a `skip_load`
  input for true weight-stationary reuse: when asserted at `start`, the FSM bypasses
  `LOAD` entirely and the array keeps its resident weights from the previous run — no
  weight re-read, no separate "hold" logic needed, since not re-loading already has
  that effect by construction.
- **Padding** — matrices smaller than 4×4 are supported by zero-injecting unused rows
  at the two input edges (weight and activation), controlled by a runtime `K_real`
  input. The array always computes a full 4×4 result; unused output rows are simply
  never read back. Verified using "poisoned" (non-zero) padding data, so a correct
  result is only possible if the zero-injection is genuinely functioning.
- **Tiling** (matrices larger than 4×4) — designed for but not implemented. Would
  extend the address generator with an outer block-loop and add an accumulation
  stage between the array and output memory; deferred in favor of verification depth
  on the core datapath.

## Application: RGB Channel Extraction via Matrix Multiplication

The accelerator's plain-matmul mode is demonstrated on a real, general-purpose task:
splitting any input image into its isolated red, green, and blue channel images.
Channel isolation is expressed as a matrix multiply — each pixel `[R,G,B]` is
multiplied by a fixed 3×3 diagonal selector matrix (padded to 4×4, `K_real=3`) that
zeroes two channels and passes the third through unchanged. Four pixels are batched
per accelerator run, matching the array's width.

This application was chosen deliberately: RGB's 3-channel data is one short of the
array's native 4×4 size, so it's a natural, non-contrived use of the padding feature,
and the same selector matrix is reused across every pixel batch in a channel — a real
demonstration of weight-stationary reuse rather than a synthetic benchmark.

**Tooling** (`image_to_hex.py`, `hex_to_image.py`): convert any input photo to/from
the accelerator's hex stimulus format, auto-detecting resolution and padding to a
multiple of 4 pixels as needed. Verified against the accelerator's actual output by
summing the three channel images back together (additive color mixing), which exactly
reconstructs the original photo — a simple, visually verifiable correctness check.

## FPGA Deployment

The design has been synthesized, implemented, and run on a real ZedBoard
(xc7z020clg484-1), beyond simulation-only verification.

- **`accelerator_top_fpga.sv`** wraps the unmodified, already-verified
  `accelerator_top` with a UART command interface (`uart_rx_fpga.sv`,
  `uart_tx_fpga.sv`) — a byte-level protocol (write weight/activation, set
  K_real/skip_load, start, read output) that lets a host PC drive the accelerator
  exactly as the simulation testbenches do, over a physical serial link.
- The board's built-in USB-UART port is hardwired to the Zynq PS and unreachable
  from PL logic; the design instead uses an external USB-UART adapter wired to the
  Pmod JB header (confirmed against Digilent's official ZedBoard master
  constraints).
- **`uart_bridge.py`** replaces the simulation testbench's file I/O role on real
  hardware: reads the same `act_stim.hex`/`image_meta.txt` files, drives the
  protocol over serial, and writes the same `results_*.hex` format — so
  `image_to_hex.py`/`hex_to_image.py` are unchanged regardless of whether the
  accelerator is simulated or physically run.
- Verified in stages: a UART loopback test (no accelerator logic) confirmed the
  physical link and pin constraints; a minimal single-batch identity-matrix test
  confirmed the full protocol and datapath; the complete RGB application was then
  run end-to-end on real hardware at 921600 baud.

## Repository structure

```
rtl/        RTL design modules (.sv)
rtl/fpga/   FPGA deployment layer: UART RX/TX, accelerator_top_fpga wrapper
tb/         Self-checking testbenches (.sv)
```

**Host-side tools** (Python): `image_to_hex.py` / `hex_to_image.py` (image ↔ hex
conversion, used identically for simulation or real hardware), `uart_bridge.py` (PC
↔ FPGA serial driver), `uart_minimal_test.py` (single-batch hardware sanity check).

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

The same black-box discipline extends to real hardware: `accelerator_top_fpga`'s UART
protocol was verified in isolation (loopback), then with a minimal known-input test
(identity weight matrix, distinct per-lane values to catch any lane reordering),
before being trusted with the full RGB application.

## Synthesis Results

Synthesized and implemented for xc7z020clg484-1 (Vivado 2020.1):

| Metric | Result |
|---|---|
| Target frequency | 100 MHz |
| Timing | **Met**, WNS = +1.463 ns (theoretical max ≈ 117 MHz) |
| LUTs | 1,694 / 53,200 (3.18%) |
| Registers | 899 / 106,400 (0.84%) |
| Total on-chip power | 0.121 W (0.015 W dynamic, 0.106 W static) |
| Routing | 0 errors, 100% of nets fully routed |
| DRC | 0 errors (1 informational PS7 warning, expected for pure-PL Zynq designs) |

**Cycle count, refined from synthesis-confirmed RTL behavior:** one full matrix
multiply (LOAD + COMPUTE + DRAIN) takes **15 clock cycles**, one more than the
simplified `4N-2=14` theoretical model — the FSM's phase transitions are sampled one
cycle after `addr_done` is asserted (not the same cycle), a real one-cycle latency
the idealized formula doesn't capture. At the achieved 100 MHz, this is **150 ns per
matrix multiply**.

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
| Control unit (FSM, + weight-stationary reuse) | ✅ | ✅ | Verified |
| Top-level integration (+ padding) | ✅ | ✅ | Verified (black-box) |
| Weight / activation / output memory | ✅ | — | Proven correct via top-level tests; no dedicated unit testbench |
| FPGA deployment (UART bridge, ZedBoard) | ✅ | ✅ | Verified on real hardware |
| Application: RGB channel extraction | ✅ | ✅ | Verified in simulation and on real hardware |
| Synthesis (area / timing / power) | ✅ | — | Complete — see Synthesis Results |
| Tiling (matrices > 4×4) | — | — | Designed, not implemented |

**Supported matrix sizes:** any M×K×N up to 4×4×4, via padding. Larger matrices are
not yet supported (see Tiling above).

## License

*(add a license if you plan to make this repo public)*
