# -----------------------------------------------------------------------------
# uart_fpga.xdc  (fully corrected -- wiring AND timing, single file)
#
# The ZedBoard's built-in USB-UART port is hardwired directly to the Zynq PS
# (processor system) via dedicated MIO pins -- it is NOT reachable from PL
# (FPGA fabric) logic under any pin assignment. Confirmed against the
# official ZedBoard Hardware User's Guide and Digilent's published master
# XDC, which lists no PL-side UART pins at all.
#
# Fix: use the Pmod JB header instead (confirmed real PL pins from
# Digilent's official Zedboard-Master.xdc), connected to an external
# USB-to-UART/TTL adapter cable.
#
# Wiring:
#   adapter TX  -> Pmod JB pin 1  (this design's RX input)
#   adapter RX  -> Pmod JB pin 2  (this design's TX output)
#   adapter GND -> Pmod JB GND
#
# Reset: the top-level port is `btn_raw`, NOT `rst_n`. BTNC (P16) is
# active-HIGH (idle=0, pressed=1) on real hardware -- the design inverts it
# internally (rst_n = ~btn_raw) to get the active-low reset every module
# expects. Do not connect a port literally named `rst_n` here; the top-level
# module no longer has one.
#
# This single file covers both WIRING (pin assignments) and TIMING (the
# create_clock line below) -- no separate timing.xdc is needed alongside it.
# -----------------------------------------------------------------------------

set_property PACKAGE_PIN W12 [get_ports uart_rx_pin]
set_property IOSTANDARD  LVCMOS33 [get_ports uart_rx_pin]

set_property PACKAGE_PIN W11 [get_ports uart_tx_pin]
set_property IOSTANDARD  LVCMOS33 [get_ports uart_tx_pin]

set_property PACKAGE_PIN Y9 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name clk [get_ports clk]

set_property PACKAGE_PIN P16 [get_ports btn_raw]
set_property IOSTANDARD LVCMOS18 [get_ports btn_raw]
