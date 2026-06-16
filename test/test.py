"""
cocotb v2 Testbench – SPI Slave REG 16b (via tt_um_top / tb wrapper)
======================================================================
Signal mapping through the TT tb wrapper:
  ui_in[5]  → REG_CSb
  ui_in[4]  → REG_SCK
  ui_in[3]  → REG_MOSI
  uo_out[5] ← REG_MISO

System CLK period : 20 ns (50 MHz)
SPI SCK half-period: 500 ns  → ~25 CLK cycles per half-period
                               (gives synchronisers plenty of margin)

REG_DTX is tied to 16'd10000 (0x2710) in tt_um_top.
"""

import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────
CLK_PERIOD_NS      = 20          # must match your design
SCK_HALF_PERIOD_NS = 500         # 1 MHz SPI → 25 CLK cycles per half-period
EXPECTED_MISO      = 0x2710      # 16'd10000 tied on REG_DTX

# ─────────────────────────────────────────────────────────────────────────────
# ui_in bit positions
# ─────────────────────────────────────────────────────────────────────────────
BIT_CSb  = 5
BIT_SCK  = 4
BIT_MOSI = 3

# ─────────────────────────────────────────────────────────────────────────────
# Driver state  – single source of truth for ui_in avoids read-modify-write
# glitches when cocotb reads a not-yet-settled value back from the simulator.
# ─────────────────────────────────────────────────────────────────────────────
_ui = 0b00100000   # CSb=1, SCK=0, MOSI=0  (idle)

def _apply(dut):
    dut.ui_in.value = _ui

def _set_bit(bit, val):
    global _ui
    if val:
        _ui |=  (1 << bit)
    else:
        _ui &= ~(1 << bit)

def set_csb(dut, val):
    _set_bit(BIT_CSb, val)
    _apply(dut)

def set_sck(dut, val):
    _set_bit(BIT_SCK, val)
    _apply(dut)

def set_mosi(dut, val):
    _set_bit(BIT_MOSI, val)
    _apply(dut)

def get_miso(dut):
    return (int(dut.uo_out.value) >> 5) & 1

# ─────────────────────────────────────────────────────────────────────────────
# Reset
# ─────────────────────────────────────────────────────────────────────────────

async def reset_dut(dut):
    global _ui
    _ui = 0b00100000          # CSb=1, SCK=0, MOSI=0
    dut.ui_in.value  = _ui
    dut.uio_in.value = 0
    dut.rst_n.value  = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value  = 1
    # Wait for FSM to reach IDLE and pre-load tx_shreg from REG_DTX.
    # Need > 2 synchroniser stages × 2 FF each = at least 4 CLK cycles;
    # we wait 20 to be safe.
    await ClockCycles(dut.clk, 20)

# ─────────────────────────────────────────────────────────────────────────────
# SPI transfer  (CPOL=0, CPHA=0, MSB first)
# ─────────────────────────────────────────────────────────────────────────────

async def spi_transfer(dut, tx_word: int, num_bits: int = 16) -> int:
    """
    Drive a full SPI frame via Timer-based SCK toggling.
    SCK half-period is SCK_HALF_PERIOD_NS, which must be >> CLK_PERIOD_NS
    so the double-flop synchronisers inside the DUT can capture every edge.
    Returns the word read back from MISO.
    """
    miso_word = 0

    set_sck(dut, 0)
    set_csb(dut, 0)                                    # assert CS
    await Timer(SCK_HALF_PERIOD_NS, unit="ns")         # setup time

    for bit_idx in range(num_bits):
        # Drive MOSI before rising edge (MSB first)
        set_mosi(dut, (tx_word >> (num_bits - 1 - bit_idx)) & 1)
        await Timer(SCK_HALF_PERIOD_NS // 2, unit="ns")

        # Rising edge – DUT samples MOSI
        set_sck(dut, 1)
        await Timer(SCK_HALF_PERIOD_NS, unit="ns")

        # Sample MISO at the middle of the high phase
        miso_word = (miso_word << 1) | get_miso(dut)

        # Falling edge – DUT shifts next MISO bit
        set_sck(dut, 0)
        await Timer(SCK_HALF_PERIOD_NS // 2, unit="ns")

    # Hold time then deassert CS
    await Timer(SCK_HALF_PERIOD_NS, unit="ns")
    set_csb(dut, 1)

    # Give FSM time to return to IDLE and reload tx_shreg
    await ClockCycles(dut.clk, 20)
    return miso_word

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

@cocotb.test()
async def reset_test(dut):
    """During reset uo_out must be all-zero."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())

    global _ui
    _ui = 0
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    dut.rst_n.value  = 0
    await ClockCycles(dut.clk, 10)

    assert int(dut.uo_out.value) == 0, \
        f"uo_out=0x{int(dut.uo_out.value):02X} expected 0x00 during reset"

    dut._log.info("reset_test PASSED")


@cocotb.test()
async def single_frame_test(dut):
    """Send 0x1234 via MOSI; MISO must shift out 0x2710 (REG_DTX)."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    miso = await spi_transfer(dut, 0x1234)

    assert miso == EXPECTED_MISO, \
        f"MISO=0x{miso:04X} expected 0x{EXPECTED_MISO:04X}"
    dut._log.info(f"single_frame_test PASSED  (MISO=0x{miso:04X})")


@cocotb.test()
async def multi_frame_test(dut):
    """Three frames; MISO must be 0x2710 every time."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    for i, word in enumerate([0xDEAD, 0xBEEF, 0xCAFE]):
        miso = await spi_transfer(dut, word)
        assert miso == EXPECTED_MISO, \
            f"Frame {i}: MISO=0x{miso:04X} expected 0x{EXPECTED_MISO:04X}"

    dut._log.info("multi_frame_test PASSED")


@cocotb.test()
async def cs_abort_test(dut):
    """Deassert CSb after 8 bits; MISO must stay 0 throughout."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    set_sck(dut, 0)
    set_csb(dut, 0)
    await Timer(SCK_HALF_PERIOD_NS, unit="ns")

    for bit_idx in range(8):
        set_mosi(dut, (0xAB >> (7 - bit_idx)) & 1)
        await Timer(SCK_HALF_PERIOD_NS // 2, unit="ns")
        set_sck(dut, 1)
        await Timer(SCK_HALF_PERIOD_NS, unit="ns")
        set_sck(dut, 0)
        await Timer(SCK_HALF_PERIOD_NS // 2, unit="ns")

    # Abort
    set_csb(dut, 1)
    await Timer(SCK_HALF_PERIOD_NS, unit="ns")

    # MISO must not go high for 100 CLK cycles after abort
    for _ in range(100):
        await RisingEdge(dut.clk)
        assert get_miso(dut) == 0, \
            "REG_MISO unexpectedly non-zero after aborted frame"

    dut._log.info("cs_abort_test PASSED")


@cocotb.test()
async def back_to_back_test(dut):
    """Two frames; MISO must be 0x2710 on both."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    for i, word in enumerate([0xAAAA, 0x5555]):
        miso = await spi_transfer(dut, word)
        assert miso == EXPECTED_MISO, \
            f"Frame {i}: MISO=0x{miso:04X} expected 0x{EXPECTED_MISO:04X}"

    dut._log.info("back_to_back_test PASSED")


@cocotb.test()
async def random_data_test(dut):
    """20 random MOSI words; MISO must be 0x2710 each time."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    await reset_dut(dut)

    random.seed(42)
    for i in range(20):
        word = random.randint(0, 0xFFFF)
        miso = await spi_transfer(dut, word)
        assert miso == EXPECTED_MISO, \
            f"Frame {i} (MOSI=0x{word:04X}): MISO=0x{miso:04X} expected 0x{EXPECTED_MISO:04X}"

    dut._log.info("random_data_test PASSED  (20 frames OK)")