<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This design implements a **16-bit SPI slave controller** using the **CPOL=0, CPHA=0** mode:
data is sampled on the **rising** edge of `REG_SCK` and shifted out on the **falling** edge.

The block contains a 4-state FSM (`IDLE → ARMED → XFER → DONE`):

- **IDLE** – waits for `REG_CSb` to go low; pre-loads the internal TX shift register from `REG_DTX` (hard-wired to `0x2710`) and pre-drives `REG_MISO` with the MSB.
- **ARMED** – chip-select is asserted; waits for the first rising edge of `REG_SCK`.
- **XFER** – shifts `REG_MOSI` bits into the RX register on every rising `REG_SCK`; shifts the TX register out on `REG_MISO` on every falling edge. Counts 16 bits.
- **DONE** – latches the received word into `REG_DRX`, pulses `REG_DONE` for one clock cycle, reloads the TX shift register, then returns to `IDLE`.

All asynchronous SPI inputs (`REG_SCK`, `REG_CSb`, `REG_MOSI`) pass through **two-stage synchronizers** before entering the system clock domain, preventing metastability.

`REG_DTX` is tied to `16'd10000` (`0x2710`), so the slave always shifts that constant value back to the master on `REG_MISO` during every transaction.

### Pin mapping

| `ui_in` bit | Signal      | Direction | Description                        |
|:-----------:|-------------|:---------:|------------------------------------|
| 5           | `REG_CSb`   | Input     | SPI chip-select, active low        |
| 4           | `REG_SCK`   | Input     | SPI clock (CPOL=0, CPHA=0)         |
| 3           | `REG_MOSI`  | Input     | SPI data in, MSB first             |
| 7,6,2,1,0   | —           | Input     | Unused, ignored                    |

| `uo_out` bit | Signal      | Direction | Description                        |
|:------------:|-------------|:---------:|------------------------------------|
| 5            | `REG_MISO`  | Output    | SPI data out, MSB first (= 0x2710) |
| 7,6,4,3,2,1,0 | —         | Output    | Unused, tied low                   |

All `uio` pins are unused and configured as inputs (`uio_oe = 0`).

## How to test

### Simulation

A cocotb v2 testbench is provided in `test/test.py`. It covers six test cases:

1. **reset_test** – verifies all outputs are zero during active-low reset.
2. **single_frame_test** – sends `0x1234` on MOSI; checks MISO returns `0x2710`.
3. **multi_frame_test** – sends three frames (`0xDEAD`, `0xBEEF`, `0xCAFE`); checks MISO is `0x2710` every time.
4. **cs_abort_test** – deasserts `REG_CSb` after only 8 SCK pulses; confirms MISO stays low (no spurious output).
5. **back_to_back_test** – two frames with a minimal inter-frame gap; MISO must be correct on both.
6. **random_data_test** – 20 randomly generated MOSI words (seed 42); MISO must be `0x2710` each time.

```bash
cd test
make        # requires iverilog and cocotb v2
```

All 6 tests should report **PASS**.

### Hardware

Connect an SPI master to the TT PCB pads as follows:

| TT pad   | SPI master signal |
|----------|-------------------|
| `ui[5]`  | CS (active low)   |
| `ui[4]`  | SCK               |
| `ui[3]`  | MOSI              |
| `uo[5]`  | MISO              |

Keep the SPI clock below **1 MHz** when running the design at the default 50 MHz system clock (minimum 10:1 CLK:SCK ratio required by the synchronizers).

Send any 16-bit frame. The slave will receive the word internally and shift `0x2710` back on MISO.

## External hardware

No external hardware required. A standard SPI master (microcontroller, FPGA, or USB-SPI adapter) is sufficient to exercise the design using the four signals listed above.
