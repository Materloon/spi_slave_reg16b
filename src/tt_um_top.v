/*******************************************************************
Autor: Manuel Monge
Description:
    Top-level file for a Tiny Tapeout Project.
Copyright (c) 2026 Manuel Monge
SPDX-License-Identifier: Apache-2.0
*******************************************************************/

`default_nettype none

module tt_um_top (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // *****************************************************************
    // BEGIN: Description of your design
    // *****************************************************************
    
    // ── SPI Slave REG 16b ───────────────────────────────────────────────────
    wire        reg_miso;
    wire [15:0] reg_drx;
    wire        reg_done;
 
    spi_slave_reg16b u_reg_spi (
        .RSTB     ( rst_n       ),
        .CLK      ( clk         ),
        .REG_CSb  ( ui_in[5]    ),
        .REG_SCK  ( ui_in[4]    ),
        .REG_MOSI ( ui_in[3]    ),
        .REG_MISO ( reg_miso    ),
        .REG_DRX  ( reg_drx     ),
        .REG_DTX  ( 16'd10000   ),  // tie to some value; replace when TX data is available
        .REG_DONE ( reg_done    )
    );
 
    // ── Output assignments ──────────────────────────────────────────────────
    assign uo_out[7] = 1'b0;
    assign uo_out[6] = 1'b0;
    assign uo_out[5] = reg_miso;
    assign uo_out[4] = 1'b0;
    assign uo_out[3] = 1'b0;
    assign uo_out[2] = 1'b0;
    assign uo_out[1] = 1'b0;
    assign uo_out[0] = 1'b0;
 
   

    // *****************************************************************
    // END: Description of your design
    // *****************************************************************

    // *****************************************************************
    // BEGIN: Unused inputs and outputs
    // *****************************************************************

    // All output pins must be assigned. If not used, assign to 0.
     // uio used as inputs only
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    // Suppress unused-input warnings
    wire _unused = &{ena, ui_in[7:6], ui_in[2:0], uio_in[7:0]};
 
    // *****************************************************************
    // END: Unused inputs and outputs
    // *****************************************************************

endmodule


// =============================================================================
// SPI Slave REG 16b
// -----------------------------------------------------------------------------
// SPI slave controller to interface with an external unit.
// Protocol: CPOL=0, CPHA=0
//   - Data is captured on the RISING  edge of REG_SCK
//   - Data is shifted  on the FALLING edge of REG_SCK
//   - REG_CSb is active-low chip select
//   - Transfer width: 16 bits (MSB first)
//
// Ports
//   RSTB        : I  – Asynchronous, active-low reset (system domain)
//   CLK         : I  – System input clock (used for synchronisation)
//   REG_CSb     : I  – SPI chip-select, active low
//   REG_SCK     : I  – SPI clock from master
//   REG_MOSI    : I  – Master-Out Slave-In data
//   REG_MISO    : O  – Master-In  Slave-Out data
//   REG_DRX[15:0]: O – Received data; valid when REG_DONE is 1
//   REG_DTX[15:0]: I – Data to transmit; must be ready right after REG_DONE=1
//   REG_DONE    : O  – Active-high; pulses for one CLK cycle when 16-bit
//                      frame has been fully received / transmitted
// =============================================================================

module spi_slave_reg16b (
    // System
    input  wire        RSTB,          // async active-low reset
    input  wire        CLK,           // system clock (for sync & output domain)

    // SPI interface
    input  wire        REG_CSb,       // chip-select (active low)
    input  wire        REG_SCK,       // SPI clock
    input  wire        REG_MOSI,      // MOSI
    output reg         REG_MISO,      // MISO

    // User interface
    output reg  [15:0] REG_DRX,       // received word
    input  wire [15:0] REG_DTX,       // word to transmit
    output reg         REG_DONE       // transfer-complete strobe (1 CLK wide)
);

// ---------------------------------------------------------------------------
// 1.  Double-flop synchronisers for SCK, CSb and MOSI (CLK domain)
//     Prevents metastability when CLK >> SCK.
// ---------------------------------------------------------------------------
reg [1:0] sck_sync;
reg [1:0] csb_sync;
reg [1:0] mosi_sync;

always @(posedge CLK or negedge RSTB) begin
    if (!RSTB) begin
        sck_sync  <= 2'b00;
        csb_sync  <= 2'b11;   // deasserted (high)
        mosi_sync <= 2'b00;
    end else begin
        sck_sync  <= {sck_sync[0],  REG_SCK};
        csb_sync  <= {csb_sync[0],  REG_CSb};
        mosi_sync <= {mosi_sync[0], REG_MOSI};
    end
end

// Stable (synchronised) versions of SPI signals in CLK domain
wire sck_s  = sck_sync[1];
wire csb_s  = csb_sync[1];
wire mosi_s = mosi_sync[1];

// Edge detection on SCK (previous value is bit [1], current is captured next)
reg sck_prev;
always @(posedge CLK or negedge RSTB) begin
    if (!RSTB) sck_prev <= 1'b0;
    else        sck_prev <= sck_s;
end

wire sck_rising  = ( sck_s & ~sck_prev);   // CPOL=0,CPHA=0 → sample
wire sck_falling = (~sck_s &  sck_prev);   // CPOL=0,CPHA=0 → shift

// ---------------------------------------------------------------------------
// 2.  Bit counter and shift registers
// ---------------------------------------------------------------------------
reg [3:0]  bit_cnt;        // counts 0..15
reg [15:0] rx_shreg;       // shift-in  register
reg [15:0] tx_shreg;       // shift-out register

// ---------------------------------------------------------------------------
// 3.  Main state machine (CLK domain)
// ---------------------------------------------------------------------------
// States
localparam IDLE  = 2'b00;
localparam ARMED = 2'b01;   // CSb asserted, waiting for first SCK rise
localparam XFER  = 2'b10;   // shifting bits
localparam DONE  = 2'b11;   // 16 bits done, assert REG_DONE for 1 cycle

reg [1:0] state;

always @(posedge CLK or negedge RSTB) begin
    if (!RSTB) begin
        state     <= IDLE;
        bit_cnt   <= 4'd0;
        rx_shreg  <= 16'd0;
        tx_shreg  <= 16'd0;
        REG_DRX   <= 16'd0;
        REG_DONE  <= 1'b0;
        REG_MISO  <= 1'b0;
    end else begin
        // Default: clear single-cycle signals
        REG_DONE <= 1'b0;

        case (state)
            // ------------------------------------------------------------------
            IDLE: begin
                REG_MISO <= REG_DTX[15];   // pre-drive MSB on MISO
                if (!csb_s) begin
                    // CSb just asserted → load TX shift-register, go ARMED
                    tx_shreg <= REG_DTX;
                    REG_MISO <= REG_DTX[15];
                    bit_cnt  <= 4'd0;
                    state    <= ARMED;
                end
            end

            // ------------------------------------------------------------------
            // CSb is low; wait for the first rising edge of SCK
            ARMED: begin
                if (csb_s) begin
                    // CS deasserted before any clock → back to IDLE
                    state <= IDLE;
                end else if (sck_rising) begin
                    // Sample MOSI on first rising edge
                    rx_shreg <= {rx_shreg[14:0], mosi_s};
                    bit_cnt  <= bit_cnt + 4'd1;
                    state    <= XFER;
                end else if (sck_falling) begin
                    // Shift out next TX bit on falling edge (pre-shift for bit 0)
                    tx_shreg <= {tx_shreg[14:0], 1'b0};
                    REG_MISO <= tx_shreg[14];   // next bit is [14] after shift
                end
            end

            // ------------------------------------------------------------------
            XFER: begin
                if (csb_s) begin
                    // Unexpected CS deassert mid-frame → abort
                    state <= IDLE;
                end else begin
                    // Falling edge: shift out next TX bit
                    if (sck_falling) begin
                        tx_shreg <= {tx_shreg[14:0], 1'b0};
                        REG_MISO <= tx_shreg[14];
                    end

                    // Rising edge: sample MOSI
                    if (sck_rising) begin
                        rx_shreg <= {rx_shreg[14:0], mosi_s};
                        bit_cnt  <= bit_cnt + 4'd1;

                        if (bit_cnt == 4'd15) begin
                            // This was the 16th (last) bit
                            state <= DONE;
                        end
                    end
                end
            end

            // ------------------------------------------------------------------
            DONE: begin
                // Latch received word and signal done for one clock
                REG_DRX  <= rx_shreg;
                REG_DONE <= 1'b1;

                // Pre-load next TX word immediately so master can start a new
                // frame right after CSb is re-asserted
                tx_shreg <= REG_DTX;
                REG_MISO <= REG_DTX[15];

                // Return to IDLE (or ARMED if CSb is still asserted)
                if (!csb_s) begin
                    // Back-to-back frames: stay ready
                    bit_cnt <= 4'd0;
                    state   <= ARMED;
                end else begin
                    state <= IDLE;
                end
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule