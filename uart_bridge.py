#!/usr/bin/env python3
"""
uart_bridge.py -- host-side (PC) script that drives the real accelerator_top_fpga
over a UART serial connection, replacing tb_image_demo.sv's role in simulation.

Reads the SAME act_stim.hex / image_meta.txt files produced by image_to_hex.py,
and writes the SAME results_red.hex / results_green.hex / results_blue.hex format
consumed by hex_to_image.py -- neither of those scripts needs to change.

Usage:
    python uart_bridge.py <serial_port> [baud_rate]
    e.g.  python uart_bridge.py COM5
    e.g.  python uart_bridge.py /dev/ttyUSB1

Requires: pip install pyserial
"""
import sys
import time

# ---- protocol constants, must match accelerator_top_fpga.sv exactly ----
CMD_WRITE_WEIGHT  = 0x01
CMD_WRITE_ACT     = 0x02
CMD_SET_K_REAL    = 0x03
CMD_SET_SKIP_LOAD = 0x04
CMD_START         = 0x05
CMD_READ_OUTPUT   = 0x06
ACK_DONE          = 0xAA

BAUD_DEFAULT = 115200
N = 4  # array width / pixels per batch

RED_WEIGHTS   = [[1,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,0]]
GREEN_WEIGHTS = [[0,0,0,0],[0,1,0,0],[0,0,0,0],[0,0,0,0]]
BLUE_WEIGHTS  = [[0,0,0,0],[0,0,0,0],[0,0,1,0],[0,0,0,0]]


class UartLink:
    """Wraps pyserial (real hardware) OR a mock (for protocol testing without hardware)."""
    def __init__(self, port=None, baud=BAUD_DEFAULT, mock=False):
        self.mock = mock
        if mock:
            self.mock_accel_mem = {}   # simple software model for protocol self-test
            self.mock_k_real = 4
            self.mock_skip_load = 0
        else:
            import serial
            self.ser = serial.Serial(port, baud, timeout=5)
            time.sleep(2)  # allow board UART to settle after port open

    def write_bytes(self, data: bytes):
        if self.mock:
            self._mock_consume(data)
        else:
            self.ser.write(data)

    def read_bytes(self, n: int) -> bytes:
        if self.mock:
            return self._mock_produce(n)
        else:
            data = self.ser.read(n)
            if len(data) != n:
                raise TimeoutError(f"Expected {n} bytes, got {len(data)} -- check connection/baud rate")
            return data

    # ---- mock hardware model, used only for protocol logic self-test ----
    def _mock_consume(self, data: bytes):
        self._mock_pending = data

    def _mock_produce(self, n: int) -> bytes:
        data = self._mock_pending
        if data[0] == CMD_START:
            return bytes([ACK_DONE])
        if data[0] == CMD_READ_OUTPUT:
            addr = data[1]
            row = self.mock_accel_mem.get(('act', addr), [0,0,0,0])
            # apply the currently "loaded" weight matrix (mock: assume RED for self-test)
            w = self.mock_accel_mem.get('weights', RED_WEIGHTS)
            result = [sum(row[k]*w[k][j] for k in range(N)) & 0xFF for j in range(N)]
            return bytes(result)
        return b'\x00' * n

    def _mock_write_side_effect(self, data: bytes):
        if data[0] == CMD_WRITE_ACT:
            addr, vals = data[1], list(data[2:6])
            self.mock_accel_mem[('act', addr)] = vals
        elif data[0] == CMD_WRITE_WEIGHT:
            addr, vals = data[1], list(data[2:6])
            self.mock_accel_mem.setdefault('weights_rows', {})[addr] = vals
            self.mock_accel_mem['weights'] = [
                self.mock_accel_mem['weights_rows'].get(r, [0,0,0,0]) for r in range(N)
            ]


def send_write(link, cmd, addr, data4):
    link.write_bytes(bytes([cmd, addr] + list(data4)))
    if link.mock:
        link._mock_write_side_effect(bytes([cmd, addr] + list(data4)))


def send_set(link, cmd, value):
    link.write_bytes(bytes([cmd, value]))


def send_start(link):
    link.write_bytes(bytes([CMD_START]))
    ack = link.read_bytes(1)
    if ack[0] != ACK_DONE:
        raise RuntimeError(f"Expected ACK 0xAA, got {ack[0]:#x}")


def send_read(link, addr):
    link.write_bytes(bytes([CMD_READ_OUTPUT, addr]))
    return link.read_bytes(4)


def load_weights(link, matrix):
    for r in range(N):
        send_write(link, CMD_WRITE_WEIGHT, r, matrix[r])


def run_channel(link, channel_name, weights, pixel_data, num_batches, out_f):
    load_weights(link, weights)
    for batch in range(num_batches):
        pixels = pixel_data[batch*N:(batch+1)*N]
        for r in range(N):
            word = pixels[r]
            lanes = [word & 0xFF, (word>>8)&0xFF, (word>>16)&0xFF, (word>>24)&0xFF]
            send_write(link, CMD_WRITE_ACT, r, lanes)

        send_set(link, CMD_SET_K_REAL, 3)
        send_set(link, CMD_SET_SKIP_LOAD, 0 if batch == 0 else 1)
        send_start(link)

        for r in range(N):
            lanes = send_read(link, r)
            word = lanes[0] | (lanes[1]<<8) | (lanes[2]<<16) | (lanes[3]<<24)
            out_f.write(f"{word:08X}\n")

        if batch % max(1, num_batches // 20) == 0:
            pct = (batch * 100) // num_batches
            print(f"[{channel_name}] batch {batch}/{num_batches} ({pct}%)")


def main(port=None, baud=BAUD_DEFAULT, mock=False):
    with open("image_meta.txt") as f:
        width, height, real_pixels, total_pixels = (int(x) for x in f.read().split())
    with open("act_stim.hex") as f:
        pixel_data = [int(line.strip(), 16) for line in f if line.strip()]

    num_batches = total_pixels // N
    print(f"Image: {width}x{height}, {total_pixels} padded pixels, {num_batches} batches x 3 channels")

    link = UartLink(port, baud, mock=mock)

    for name, weights in (("RED", RED_WEIGHTS), ("GREEN", GREEN_WEIGHTS), ("BLUE", BLUE_WEIGHTS)):
        with open(f"results_{name.lower()}.hex", "w") as out_f:
            run_channel(link, name, weights, pixel_data, num_batches, out_f)

    print("Done. Run hex_to_image.py to reconstruct the channel images.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python uart_bridge.py <serial_port> [baud_rate]")
        print("       python uart_bridge.py --mock-test   (protocol self-test, no hardware)")
        sys.exit(1)
    if sys.argv[1] == "--mock-test":
        main(mock=True)
    else:
        port = sys.argv[1]
        baud = int(sys.argv[2]) if len(sys.argv) > 2 else BAUD_DEFAULT
        main(port, baud)
