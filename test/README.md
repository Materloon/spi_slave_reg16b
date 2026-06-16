# SPI Slave REG 16b

## Overview

This design implements a **16-bit SPI slave controller** intended to receive configuration words from an external SPI master.
The block operates with **CPOL=0 and CPHA=0**: data is sampled on the rising edge of SCK and shifted out on the falling edge.

`REG_DTX` is hard-wired to `16'd10000` (`0x2710`), so the slave always shifts that constant value back to the master on MISO during every transaction.
The received word (from MOSI) is stored internally in `REG_DRX` and a one-cycle `REG_DONE` pulse is generated at the end of each 16-bit frame.

---

## How It Works

### SPI Protocol (CPOL=0, CPHA=0)

| Signal | Role |
|--------|------|
| `REG_CSb` | Active-low chip-select. A transaction starts when CSb goes low and ends when it returns high. |
| `REG_SCK` | SPI clock driven by the master. Data is sampled on the **rising** edge; MISO is updated on the **falling** edge. |
| `REG_MOSI` | 16 bits are clocked in MSB-first. |
| `REG_MISO` | 16 bits are clocked out MSB-first. The value comes from `REG_DTX` (fixed at `0x2710`). |

### Internal FSM

The SPI slave contains a 4-state finite state machine (FSM):

```
IDLE → ARMED → XFER → DONE → IDLE
```

- **IDLE** — waits for CSb assertion; pre-loads `tx_shreg` from `REG_DTX` and pre-drives MISO with `REG_DTX[15]`.
- **ARMED** — CSb is asserted; waits for the first SCK rising edge.
- **XFER** — shifts MOSI bits into `rx_shreg` on every rising SCK; shifts `tx_shreg` out on MISO on every falling SCK. Counts 16 bits.
- **DONE** — latches `rx_shreg` into `REG_DRX`, asserts `REG_DONE` for one CLK cycle, reloads `tx_shreg` for the next frame, then returns to IDLE (or ARMED if CSb is still asserted).

All asynchronous SPI inputs (`REG_SCK`, `REG_CSb`, `REG_MOSI`) pass through **two-stage synchronizers** before entering the CLK domain, preventing metastability.

---

## Pinout

### Inputs (`ui_in`)

| Bit | Signal | Description |
|-----|--------|-------------|
| 7 | — | Unused |
| 6 | — | Unused |
| 5 | `REG_CSb` | SPI chip-select, active low |
| 4 | `REG_SCK` | SPI clock from master |
| 3 | `REG_MOSI` | SPI data in, MSB first |
| 2 | — | Unused |
| 1 | — | Unused |
| 0 | — | Unused |

### Outputs (`uo_out`)

| Bit | Signal | Description |
|-----|--------|-------------|
| 7 | — | Tied low |
| 6 | — | Tied low |
| 5 | `REG_MISO` | SPI data out, MSB first (always shifts out `0x2710`) |
| 4 | — | Tied low |
| 3 | — | Tied low |
| 2 | — | Tied low |
| 1 | — | Tied low |
| 0 | — | Tied low |

### Bidirectional (`uio`)

All `uio` pins are configured as **inputs** (`uio_oe = 0`) and are unused in this design.

### System signals

| Signal | Description |
|--------|-------------|
| `clk` | System clock. The design targets **50 MHz** (20 ns period). |
| `rst_n` | Asynchronous active-low reset. Resets all registers and the FSM to IDLE. |
| `ena` | Always 1 when the design is powered; ignored internally. |

---

## Timing Requirements

The SPI clock must be **significantly slower** than the system clock so that the two-stage synchronizers can capture every SCK edge cleanly.
A ratio of at least **10:1** (CLK:SCK) is recommended.

| Parameter | Recommended value |
|-----------|------------------|
| System CLK | 50 MHz (20 ns) |
| SPI SCK max | 1 MHz (500 ns half-period) |
| CLK cycles per SCK half-period | ≥ 10 |

---

## Test Cases

The cocotb testbench (`test/test.py`) covers six test cases:

### 1. `reset_test`
Asserts `rst_n = 0` for 10 CLK cycles and verifies that `uo_out` is fully zero during reset. Ensures the design powers up in a clean state.

### 2. `single_frame_test`
Sends a single 16-bit word (`0x1234`) via MOSI and checks that MISO returns exactly `0x2710`. Validates the basic end-to-end SPI path and the hardwired `REG_DTX`.

### 3. `multi_frame_test`
Sends three consecutive frames (`0xDEAD`, `0xBEEF`, `0xCAFE`) with a 10-cycle gap between each. Confirms the FSM correctly returns to IDLE, reloads `tx_shreg`, and produces `0x2710` on MISO for every frame.

### 4. `cs_abort_test`
Asserts CSb, sends only 8 of the 16 SCK pulses, then deasserts CSb early. Checks that MISO stays low for 100 CLK cycles afterwards — confirming that the FSM aborts cleanly without producing spurious output.

### 5. `back_to_back_test`
Sends two frames back-to-back with only a 10-cycle inter-frame gap (simulating a fast master). Verifies MISO is correct on both frames, confirming the FSM reloads `tx_shreg` quickly enough between transactions.

### 6. `random_data_test`
Sends 20 randomly generated 16-bit MOSI words (fixed seed 42 for reproducibility) and checks that MISO is `0x2710` every time. Provides broad coverage of the shift register logic across arbitrary bit patterns.

---

## How to Test

### Hardware

1. Connect an SPI master to the TT PCB:
   - `ui[5]` → CS (active low)
   - `ui[4]` → SCK
   - `ui[3]` → MOSI
   - `uo[5]` → MISO
2. Keep SPI clock below 1 MHz when running the design at 50 MHz.
3. Send any 16-bit frame. The slave will receive the word and shift `0x2710` back on MISO.

### Simulation

```bash
# Install dependencies (once)
pip install cocotb cocotb-tools
sudo apt install iverilog

# Run all tests
cd test
make
```

All 6 tests should pass with the output:
```
** TESTS=6 PASS=6 FAIL=0 SKIP=0 **
```

---

## Source Files

| File | Description |
|------|-------------|
| `src/tt_um_top.v` | Tiny Tapeout top-level wrapper. Maps TT pins to the SPI slave and ties unused outputs to 0. |
| `src/spi_slave_reg16b.v` | 16-bit SPI slave core with 4-state FSM and double-flop synchronizers. |
| `test/test.py` | cocotb v2 testbench with 6 test cases. |
