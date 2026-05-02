<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Author: Mohamed Shalan <mshalan@aucegypt.edu> -->

# PSRAM AHB-Lite Controller IP — Datasheet

## 1. Overview

A lightweight SPI/QSPI PSRAM controller with an AHB-Lite slave interface. Makes external PSRAM accessible as word-addressable memory to any AHB-Lite bus master (CPU, DMA, etc.). Targets SPI SRAM and PSRAM devices such as the AP Memory APS6404L, Microchip 23LC512/23A512, and similar.

## 2. Features

- AHB-Lite slave interface (ARM IHI 0033A compliant subset)
- SPI Mode 0 (CPOL=0, CPHA=0) with runtime switchable 1-4-4 Quad SPI
- Runtime CSR access for configuration and status monitoring
- Configurable SPI clock divisor (SCLK = sys_clk / (2 x SPI_CLK_DIV))
- Configurable address width (8–23 bits) and SPI address length (16–24 bits)
- Configurable read/write opcodes and dummy clock count for multi-vendor support
- 32-bit word, 16-bit halfword, and 8-bit byte transfers
- Automatic read-modify-write for sub-word (partial) writes
- Power-on initialization sequence (Reset Enable + Reset)
- Software-controlled quad mode entry with configurable switch delay
- Little-endian byte ordering
- Separate `_o`, `_oe`, `_i` signals for bidirectional SIO pins (ASIC/FPGA-friendly)
- Optional direct-mapped read cache with write-through and write buffer
- Verilog-2005 (IEEE 1364-2005)

## 3. Architecture

```
                     +------------------------------------------------------------+
                     |                        ms_psram_ahb                         |
                     |                                                            |
                     |  +----------+  +-----------+  +-----------+  +----------+   |
 AHB-Lite    -----> |  | ahb_slave|  | Optional  |  |           |  |          |   |    +---------+
 Bus (PSRAM)        |  |    _if   |--|   Cache   |--| psram_ctrl|->| SPI PHY  |--+--->|  PSRAM  |
             <----- |  |          |  |           |  |  +CSR if  |  | (inline) |  |    |  Chip   |
                     |  +----------+  +-----------+  +-----------+  +----------+   |    +---------+
                     |                                                            |
 AHB-Lite    -----> |  +----------+                                               |
 Bus (CSR)          |  | psram_csr|  (haddr[27:24] == CSR_REGION)                |
             <----- |  +----------+                                               |
                     +------------------------------------------------------------+
```

Address decoding: `haddr[27:24] == CSR_REGION` selects the CSR slave. All other addresses go to the PSRAM data path. The active slave is latched during the AHB address phase.

### 3.1 AHB Slave Interface (`ahb_slave_if`)

Protocol adapter between the AHB-Lite bus and the core controller. Accepts AHB transfers and converts them into simple request/response transactions.

- Captures address phase (hsel, htrans[1], hwrite, haddr, hsize)
- Generates byte strobes from HSIZE and HADDR[1:0]
- For reads: immediately issues a request to the core controller
- For writes: waits for the data phase (HWDATA), then issues a request
- Stalls the bus (HREADYOUT=0) during PSRAM access

### 3.2 PSRAM Controller (`psram_ctrl`)

Finite state machine that generates the SPI protocol. Contains an inline SPI PHY (no separate PHY module). Accepts runtime configuration from the CSR module for opcode and timing selection.

**State machine:**

```
S_INIT_WAIT --> S_CMD (RST_EN) --> S_INIT_DLY --> S_CMD (RST) --> S_INIT_DLY --> S_IDLE

S_IDLE ──────────────────────────────────────────────────────────────────┐
  |                                                                     |
  +-- (quad_en & !quad_active) --> S_QUAD_CMD --> S_QUAD_DLY ──────────+
  |                                (send enter cmd,  wait delay,        |
  |                                 set quad_active)                     |
  |                                                                     |
  +-- S_CMD --> S_ADDR --> S_DUMMY --> S_DATA --> S_DONE ──────────────+
  |                  |           ^                                       |
  |                  +─(DMY=0)──+                                       |
  |                                                                     |
  +-- S_RMW (read-modify-write for partial writes) ─────────────────────+
```

**Shift engine:** Runs in parallel with the FSM. On SCLK rising edge: sample input (reads) or increment counter. On SCLK falling edge: shift output (writes).

**Quad mode switching:** Controller always initializes in SPI (1-1-1) mode. Software triggers a switch to 1-4-4 via the CTRL CSR. The controller sends `QUAD_ENTER_CMD` in SPI mode, waits `QUAD_SWITCH_DLY` sys_clk cycles, then sets `quad_active`. After switching, all commands use 1-bit CMD + 4-bit ADDR/DATA (1-4-4). The command phase always remains 1-bit.

### 3.3 Read Cache (`psram_cache`, optional)

A small direct-mapped read cache with a write-through policy and write buffer. Enabled via the `CACHE_EN` parameter. Sits between the AHB slave interface and the PSRAM controller.

**Cache organization:**

| Attribute | Value |
|-----------|-------|
| Policy | Write-through, write-no-allocate |
| Size | 2^INDEX_BITS entries x 4 bytes (default: 4 entries = 16 bytes) |
| Associativity | Direct-mapped |
| Line size | 1 word (32 bits, no line fill) |
| Write buffer depth | `CACHE_BUF_DEPTH` entries (default: 2) |
| Index | `addr[INDEX_BITS+1:2]` |
| Tag | `addr[ADDR_WIDTH-1:INDEX_BITS+2]` |

**State machine:**

```
                  +-- background drain (buffer non-empty) --+
                  |                                          |
                  v                                          |
S_IDLE --------> S_DRAIN --------> S_FETCH --------> S_IDLE
  |                  ^                  ^
  |                  |                  |
  +-- read miss -----+  (drain all)    |
  |    (buffer has entries)             |
  |                                     |
  +-- read miss ------------------------+
       (buffer empty)                   |
                                      |
  +-- write buf full --> S_DRAIN ------+
       (drain one)        then S_IDLE
```

**Write path:**
1. Write data is added to the write buffer
2. If the address hits in the cache, the cache line is updated with byte-strobe merge
3. `resp_valid` is asserted immediately (AHB completes without PSRAM latency)
4. Write buffer entries drain to PSRAM during idle cycles (background drain)

**Read path:**
- **Cache hit:** Data returned immediately from cache (0 PSRAM latency). `resp_valid` asserted same cycle.
- **Cache miss, buffer empty:** Fetch from PSRAM -> fill cache line -> return data.
- **Cache miss, buffer has entries:** Drain ALL buffer entries to PSRAM first (ensuring coherency), then fetch. This guarantees the PSRAM has the latest data before the read.

**Coherency:** Write-through ensures PSRAM always receives all writes (via the buffer). On read miss, the buffer is fully drained before fetching, preventing stale data. Cache is updated on write hits with proper byte-strobe merging.

**Write buffer:** FIFO with `BUF_DEPTH` entries (default 2). Uses shift-based management (head always at index 0). When the buffer is full and a new write arrives, one entry is drained first to free space. Background drain sends one entry per idle period.

### 3.4 CSR Module (`psram_csr`)

AHB-Lite slave register file for runtime configuration and status monitoring. Selected when `haddr[27:24] == CSR_REGION`. All registers reset to their parameter defaults, allowing software to override at runtime.

## 4. Supported Devices

| Device | Manufacturer | Size | SPI Addr Bits | Read CMD | Dummy Clocks | Configured With |
|--------|-------------|------|---------------|----------|-------------|-----------------|
| APS6404L | AP Memory | 64 Mbit (8 MB) | 24 | 0x0B | 8 | Default parameters |
| 23LC512 | Microchip | 512 Kbit (64 KB) | 16 | 0x03 | 0 | SPI_ADDR_BITS=16, SPI_DMY_CLKS=0, SPI_CMD_READ=8'h03 |
| 23A512 | Microchip | 512 Kbit (64 KB) | 16 | 0x03 | 0 | SPI_ADDR_BITS=16, SPI_DMY_CLKS=0, SPI_CMD_READ=8'h03 |

New devices can be supported by adjusting `SPI_ADDR_BITS`, `SPI_DMY_CLKS`, `SPI_CMD_READ`, and `SPI_CMD_WRITE`. Runtime reconfiguration is possible via CSRs.

## 5. Interface Signals

### 5.1 AHB-Lite Slave Port

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| hclk | 1 | Input | System clock (rising edge active) |
| hresetn | 1 | Input | Active-low asynchronous reset |
| hsel | 1 | Input | Slave select |
| haddr | 32 | Input | Address (bit [27:24] selects CSR vs PSRAM) |
| htrans | 2 | Input | Transfer type (NONSEQ=10 supported) |
| hwrite | 1 | Input | Write enable |
| hsize | 3 | Input | Transfer size (BYTE=000, HALFWORD=001, WORD=010) |
| hburst | 3 | Input | Burst type (unused, SINGLE=000 expected) |
| hwdata | 32 | Input | Write data |
| hready | 1 | Input | Ready from bus multiplexor |
| hrdata | 32 | Output | Read data |
| hreadyout | 1 | Output | Slave ready (0 = wait states inserted) |
| hresp | 2 | Output | Response (always OKAY=00) |

### 5.2 SPI PSRAM Port

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| spi_cs_n | 1 | Output | Chip select (active-low) |
| spi_sclk | 1 | Output | SPI serial clock |
| spi_sio_o | 4 | Output | SIO output data |
| spi_sio_oe | 4 | Output | SIO output enable (active-high) |
| spi_sio_i | 4 | Input | SIO input data |

**SIO pin mapping (SPI mode):**

| SIO Pin | SPI Function | Direction |
|---------|-------------|-----------|
| SIO[0] | MOSI (SI) | Output from controller |
| SIO[1] | MISO (SO) | Input to controller |
| SIO[2] | NC or WP | Unused in SPI mode |
| SIO[3] | NC or HOLD | Unused in SPI mode |

**SIO pin mapping (Quad SPI mode):**

| SIO Pin | Function | Direction |
|---------|----------|-----------|
| SIO[0] | DQ0 | Bidirectional |
| SIO[1] | DQ1 | Bidirectional |
| SIO[2] | DQ2 | Bidirectional |
| SIO[3] | DQ3 | Bidirectional |

## 6. CSR Register Map

CSRs are accessed at addresses where `haddr[27:24] == CSR_REGION` (default `4'hF`). The CSR offset is `haddr[5:2]` (word-aligned, up to 16 registers).

Example base address (ADDR_WIDTH=23): `0x0F000000`

| Offset | Name | Access | Reset | Bits | Description |
|--------|------|--------|-------|------|-------------|
| 0x00 | CTRL | R/W, SC | 0x00000000 | [0] | QUAD_EN — write 1 to trigger quad mode switch (self-clearing) |
| 0x04 | STATUS | RO | — | [0] | INIT_DONE — 1 when initialization complete |
| | | | | [1] | BUSY — 1 when PSRAM transaction in progress |
| | | | | [2] | QUAD_ACTIVE — 1 when controller is in quad mode |
| 0x08 | SPI_CFG | R/W | (params) | [7:0] | SPI_CMD_READ (default 0x0B) |
| | | | | [15:8] | SPI_CMD_WRITE (default 0x02) |
| | | | | [21:16] | SPI_DMY_CLKS (default 8) |
| 0x0C | QUAD_CFG | R/W | (params) | [7:0] | QUAD_CMD_READ (default 0xEB) |
| | | | | [15:8] | QUAD_CMD_WRITE (default 0x38) |
| | | | | [21:16] | QUAD_DMY_CLKS (default 6) |
| | | | | [29:24] | QUAD_ADDR_CLKS (default 6) |
| 0x10 | QUAD_ENTER | R/W | (param) | [7:0] | QUAD_ENTER_CMD (default 0x35, 0x00 = no command) |
| 0x14 | QUAD_DLY | R/W | 0x00000000 | [31:0] | Delay in sys_clk cycles after quad enter command |

**CTRL register behavior:** Writing bit [0] = 1 triggers the quad switch sequence. The bit self-clears on the next clock edge. The controller will send `QUAD_ENTER_CMD`, wait `QUAD_DLY` cycles, then set `QUAD_ACTIVE`. If `QUAD_ENTER_CMD = 0x00`, the command phase is skipped and the controller switches to quad opcodes immediately after the delay.

**CSR read protocol:** 2 AHB cycles (address phase + data phase). No wait states beyond the standard AHB data phase.

**CSR write protocol:** 2 AHB cycles (address phase + data phase). Register updated on the data phase.

### 6.1 Software Quad Mode Switching Sequence

```
1.  Poll STATUS[0] until INIT_DONE = 1
2.  Write QUAD_CFG register with desired quad opcodes and timing (optional)
3.  Write QUAD_ENTER register with enter command (e.g., 0x35)
4.  Write QUAD_DLY register with required wait time (sys_clk cycles)
5.  Write CTRL = 1 to trigger quad switch
6.  Poll STATUS[2] until QUAD_ACTIVE = 1
7.  Controller now uses 1-4-4 protocol for all transactions
```

**Example (ARM Cortex-M, APS6404L, 50 MHz sys_clk):**

```c
#define CSR_BASE  0x0F000000

#define CSR_CTRL       (*(volatile uint32_t *)(CSR_BASE + 0x00))
#define CSR_STATUS     (*(volatile uint32_t *)(CSR_BASE + 0x04))
#define CSR_SPI_CFG    (*(volatile uint32_t *)(CSR_BASE + 0x08))
#define CSR_QUAD_CFG   (*(volatile uint32_t *)(CSR_BASE + 0x0C))
#define CSR_QUAD_ENTER (*(volatile uint32_t *)(CSR_BASE + 0x10))
#define CSR_QUAD_DLY   (*(volatile uint32_t *)(CSR_BASE + 0x14))

void psram_enter_quad(void) {
    while (!(CSR_STATUS & 0x01));        // wait INIT_DONE
    CSR_QUAD_CFG   = (6 << 24) |         // ADDR_CLKS = 6
                     (6 << 16) |         // DMY_CLKS  = 6
                     (0x38 << 8) |       // CMD_WRITE = 0x38
                     (0xEB << 0);        // CMD_READ  = 0xEB
    CSR_QUAD_ENTER = 0x35;               // enter quad command
    CSR_QUAD_DLY   = 2500;               // 50 us @ 50 MHz
    CSR_CTRL       = 1;                  // trigger switch
    while (!(CSR_STATUS & 0x04));        // wait QUAD_ACTIVE
}
```

## 7. Parameters

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| SPI_CLK_DIV | 1 | 1–65535 | SCLK divisor. SCLK freq = sys_clk / (2 x SPI_CLK_DIV) |
| QUAD_EN | 0 | 0, 1 | 0 = SPI only, 1 = quad mode supported (switched via CSR) |
| ADDR_WIDTH | 23 | 8–23 | AHB address width in bits (byte address) |
| INIT_DLY | 5000 | 0–65535 | Power-up delay before init (system clock cycles) |
| RST_DLY | 2500 | 0–65535 | Delay between Reset Enable and Reset commands |
| SPI_ADDR_BITS | 24 | 16–24 | Number of address bits sent over SPI |
| SPI_DMY_CLKS | 8 | 0–63 | Dummy SCLK cycles between address and read data |
| SPI_CMD_READ | 8'h0B | 8-bit | SPI read opcode (reset default for CSR) |
| SPI_CMD_WRITE | 8'h02 | 8-bit | SPI write opcode (reset default for CSR) |
| QUAD_CMD_READ | 8'hEB | 8-bit | Quad read opcode (reset default for CSR) |
| QUAD_CMD_WRITE | 8'h38 | 8-bit | Quad write opcode (reset default for CSR) |
| QUAD_DMY_CLKS | 6 | 0–63 | Quad mode dummy clocks (reset default for CSR) |
| QUAD_ENTER_CMD | 8'h35 | 8-bit | Quad enter command (reset default for CSR, 0x00 = no command) |
| QUAD_ADDR_CLKS | 6 | 1–63 | Quad mode address clocks (reset default for CSR) |
| CACHE_EN | 0 | 0, 1 | 0 = bypass cache, 1 = enable read cache + write buffer |
| CACHE_INDEX_BITS | 2 | 1–8 | Log2 of cache entries (2 = 4 entries, 16 bytes) |
| CACHE_BUF_DEPTH | 2 | 2 | Write buffer depth in entries |
| CSR_REGION | 4'hF | 4-bit | Address match value for `haddr[27:24]` to select CSR region |

All SPI/QUAD parameters serve as reset defaults for their corresponding CSRs. Software can reconfigure them at runtime.

## 8. Protocol Timing

### 8.1 SPI Clock Generation

```
sys_clk   |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
          |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
spi_sclk      ___________          ___________
          __|           |________|           |________
              <- DIV-1 -><- 1  -><- DIV-1 ->
```

SCLK period = 2 x SPI_CLK_DIV x T_sys_clk

### 8.2 Write Transaction (SPI, full word)

```
CS_N  --.                                                             .--
         ---------------------------------------------------------------
SCLK     _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _
       _| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_

SIO0  --< CMD (8b) >< ADDR[23:16] >< ADDR[15:8] >< ADDR[7:0] >< DATA[31:24] >...

       |<- CMD ->|<- ADDRESS (24b) ->|<- DATA (32b) ->|
       |  8 SCLK |     24 SCLK       |    32 SCLK      |
```

Total write SCLK cycles: 8 + ADDR_CLKS + 32

### 8.3 Read Transaction (SPI, with dummy)

```
CS_N  --.                                                                           .--
         ---------------------------------------------------------------------------
SCLK     _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _
       _| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_

SIO0  --< CMD (8b) >< ADDR (24b) >< DUMMY (8b) >                    (controller input)
SIO1                                      --< DATA[31:24] >< DATA[23:16] >...  (PSRAM output)

       |<- CMD ->|<- ADDRESS ->|<- DMY ->|<- DATA (32b) ->|
       |  8 SCLK |   24 SCLK   | 8 SCLK  |   32 SCLK      |
```

Total read SCLK cycles: 8 + ADDR_CLKS + DMY_CLKS + 32

### 8.4 Write Transaction (1-4-4 Quad, full word)

```
CS_N  --.                                                  .--
         --------------------------------------------------
SCLK     _   _   _   _   _   _   _   _   _   _   _   _   _
       _| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_

SIO0  --< CMD >               <- ADDR (24b, 4b/SCLK) ->  <- DATA (32b, 4b/SCLK) ->
SIO1   (1-bit)   SIO[3:0]          6 SCLKs                     8 SCLKs
SIO2
SIO3

       |<- CMD ->|<- ADDRESS ->|<- DATA ->|
       |  8 SCLK |   6 SCLK    |  8 SCLK   |
```

### 8.5 Transaction Latency

All latencies below assume `SPI_CLK_DIV = 2` (each SPI bit = 4 system clocks).

**SPI transaction phases (APS6404L, standard SPI):**

| Phase | Bits | SCLK Cycles | System Clocks |
|-------|------|-------------|---------------|
| CMD | 8 | 8 | 32 |
| ADDR | 24 | 24 | 96 |
| DUMMY (read) | 8 | 8 | 32 |
| DATA | 32 | 32 | 128 |

**SPI transaction phases (APS6404L, 1-4-4 Quad):**

| Phase | Bits | SCLK Cycles | System Clocks |
|-------|------|-------------|---------------|
| CMD (1-bit) | 8 | 8 | 32 |
| ADDR (4-bit) | 24 | 6 | 24 |
| DUMMY (4-bit, read) | 24 | 6 | 24 |
| DATA (4-bit) | 32 | 8 | 32 |

**Controller latency (SPI shifting only, excludes AHB overhead):**

| Access Type | SPI Sys Clks | QSPI Sys Clks |
|-------------|-------------|---------------|
| Full word write | 256 | 88 |
| Full word read | 288 | 112 |
| Partial write (RMW) | ~546 | ~202 |
| Quad switch | 32 + QUAD_DLY | — |
| Init sequence | ~20 + INIT_DLY + 2×RST_DLY | — |

### 8.6 Performance Analysis

All cycle counts are from the AHB master's perspective (address phase through data phase), with `SPI_CLK_DIV = 2`.

**Cache disabled (CACHE_EN = 0):**

The AHB slave adds ~2–3 system clocks of pipeline overhead (address capture, core request, response register) on top of the SPI shifting time.

| Operation | Total Latency | Breakdown |
|-----------|--------------|-----------|
| Read (full word, SPI) | ~290 sys_clks | SPI read (288) + pipeline (2) |
| Write (full word, SPI) | ~258 sys_clks | SPI write (256) + pipeline (2) |
| Partial write (RMW, SPI) | ~548 sys_clks | SPI read (288) + transition (2) + SPI write (256) + pipeline (2) |
| Read (full word, QSPI) | ~114 sys_clks | QSPI read (112) + pipeline (2) |
| Write (full word, QSPI) | ~90 sys_clks | QSPI write (88) + pipeline (2) |
| Partial write (RMW, QSPI) | ~204 sys_clks | QSPI read (112) + transition (2) + QSPI write (88) + pipeline (2) |

**Cache enabled (CACHE_EN = 1):**

| Scenario | Total Latency | Explanation |
|----------|--------------|-------------|
| **Read hit** | **3 sys_clks** | 2-stage registered pipeline: AHB→cache→AHB (1 addr + 2 wait) |
| **Write, buffer not full** | **4 sys_clks** | AHB write data arrives 1 cycle after address (1 addr + 1 data + 2 wait) |
| **Read miss, buffer empty** | **~292 sys_clks** | SPI read (288) + cache fill + pipeline (4) |
| **Read miss, N buffered** | **N × ~258 + ~292** | Must drain all N buffer entries for coherency (each ~258 clks), then fetch |
| **Write, buffer full** | **~260 sys_clks** | Drain oldest entry (~258 clks), then buffer new write |

**Worst-case scenarios (SPI, CACHE_EN=1, BUF_DEPTH=4):**

| Scenario | Latency | Description |
|----------|---------|-------------|
| Worst read | ~1,324 sys_clks | Drain 4 entries (4×258) + SPI read (292) |
| Worst write | ~260 sys_clks | Drain 1 entry (258) + buffer new write |

**Best-case throughput (cache hit, 50 MHz sys_clk):**

- Read: 4 bytes / 3 cycles × 50 MHz = **~67 MB/s**
- Write: 4 bytes / 4 cycles × 50 MHz = **~50 MB/s**

**Sustained throughput without cache (50 MHz sys_clk):**

- SPI write: 4 bytes / 258 cycles × 50 MHz = **~0.78 MB/s**
- SPI read: 4 bytes / 290 cycles × 50 MHz = **~0.69 MB/s**
- QSPI read: 4 bytes / 114 cycles × 50 MHz = **~1.75 MB/s**

For workloads with high temporal locality, the cache improves read bandwidth by ~100x.

## 9. Partial Write Handling (Read-Modify-Write)

When the AHB master writes with byte strobes != 4'b1111 (sub-word access), the controller performs a read-modify-write:

1. **Read** the full 32-bit word from PSRAM (CMD_READ + ADDR + DUMMY + DATA)
2. **Merge**: combine old data with new data using byte strobes:
   `merged = (old & ~mask) | (new & mask)`
3. **Write** the merged 32-bit word back (CMD_WRITE + ADDR + DATA)

This requires two complete SPI transactions, approximately doubling the latency for partial writes.

## 10. Initialization Sequence

After reset is deasserted, the controller performs:

1. Wait `INIT_DLY` system clock cycles (PSRAM power-up stabilization)
2. Assert CS_N, send Reset Enable command (0x66) in SPI mode
3. Deassert CS_N, wait `RST_DLY` system clock cycles
4. Assert CS_N, send Reset command (0x99) in SPI mode
5. Deassert CS_N, wait `RST_DLY` system clock cycles
6. Enter idle state — ready to accept requests (STATUS.INIT_DONE = 1)

The controller initializes in SPI (1-1-1) mode regardless of `QUAD_EN`. Quad mode must be explicitly triggered by software via the CTRL CSR after initialization completes.

During initialization, `req_ready` is low (controller not in S_IDLE). Any AHB transactions targeting this slave will receive wait states until initialization completes.

## 11. Design Constraints

- Single in-flight PSRAM transaction (no pipelining)
- AHB bus is stalled with wait states during PSRAM access (or cache miss)
- No burst support — each AHB transfer generates a complete SPI transaction
- No error response (HRESP is always OKAY)
- HBURST is not used; only single transfers supported
- Init commands (0x66, 0x99) are always sent regardless of PSRAM device; unsupported commands are ignored by devices that don't need them (e.g., 23LC512)
- CSR accesses share the AHB bus with PSRAM — CSR reads/writes cannot occur while PSRAM is busy

### Cache Limitations

- Write buffer shift-based management only supports BUF_DEPTH=2 (depths > 2 require a circular FIFO)
- On read miss, ALL buffer entries are drained even if unrelated to the read address (simple but conservative coherency)
- No cache flushing or invalidation mechanism (single-master assumption)
- No line fill — each cache entry holds exactly one word (no sub-word validity tracking)
- Cache does not allocate on write miss (write-no-allocate policy)

## 12. Resource Utilization

### 12.1 FPGA Estimates

| Module | LUTs | FFs |
|--------|------|-----|
| ahb_slave_if | ~80 | ~90 |
| psram_ctrl (SPI) | ~200 | ~130 |
| psram_ctrl (with CSR inputs) | ~200 | ~130 |
| psram_cache (INDEX_BITS=2) | ~120 | ~100 |
| psram_csr | ~80 | ~80 |
| **Total (SPI, no cache)** | **~360** | **~300** |
| **Total (SPI, with cache)** | **~480** | **~400** |
| **Total (Quad, with cache)** | **~500** | **~400** |

Estimates for typical FPGA (may vary by device family and synthesis tool).

### 12.2 ASIC (Skywater 130nm HD)

Synthesized with Yosys + ABC, sky130 HD standard cell library. Configuration: `SPI_CLK_DIV=2`, `QUAD_EN=1`, `ADDR_WIDTH=23`, `CACHE_EN=1`, `CACHE_INDEX_BITS=4`, `CACHE_BUF_DEPTH=4`, target period = 8 ns (125 MHz).

**Synthesis flow comparison:**

| Mode | Make Target | Recipe | Cells | Area (um²) | Eq. Gates | WNS Setup (SS) | WNS Hold (FF) |
|------|-------------|--------|-------|-----------|-----------|-----------------|----------------|
| Legacy | `make synth` | ABC default | 4,933 | 43,462 | 11,579 | 0.71 ns | 0.25 ns |
| Flat sweep | `make syn-flat` | retime_delay | 7,879 | 69,652 | 18,556 | 1.00 ns | 0.26 ns |
| Hierarchical | `make syn-hier` | retime_delay | 7,962 | 72,420 | 19,289 | 1.27 ns | 0.26 ns |

**Makefile synthesis targets:**

| Target | Description |
|--------|-------------|
| `make synth` | Legacy direct Yosys call — fast, single recipe, no sweep. Emits `syn/ms_psram_ahb.gl.v` and `tmp/ms_psram_ahb.syn.v`. |
| `make syn-flat` | Flat synthesis via `synth_flow.py` with 14-recipe ABC sweep, pareto-optimal selection, and multi-corner STA (SS/TT/FF). Configured in `syn/synth_flat.yaml`. |
| `make syn-hier` | Hierarchical bottom-up synthesis via `synth_flow.py`. Each module gets its own recipe sweep; winning netlists are composed at the top level. Configured in `syn/synth_hier.yaml`. |
| `make clean` | Removes `syn/`, `work/`, and `results/`. |

### 12.3 Hierarchical Module Breakdown

Winner recipe: `retime_delay` for all modules. Target: 8 ns (125 MHz), sky130 HD, `CACHE_INDEX_BITS=4`.

| Module | Cells | Area (um²) |
|--------|-------|-----------|
| ahb_slave_if | 480 | 5,359 |
| psram_csr | 518 | 6,107 |
| psram_cache | 5,121 | 46,108 |
| psram_ctrl | 1,798 | 14,554 |
| **ms_psram_ahb (top)** | **7,962** | **72,420** |

### 12.4 ABC Recipe Compatibility

The 14-recipe sweep exercises various ABC optimization strategies. With ABC 1.01, only 5 of 14 recipes complete successfully:

| Recipe | Status |
|--------|--------|
| fast | Works |
| balanced | Works |
| delay4 | Works |
| delay_choice | Works |
| retime_delay | Works |
| Other 9 recipes | Crash — missing ABC commands (`rewrite`, `refactor`, `balance`) |

### 12.5 Synthesis Output Artifacts

| Artifact | Description |
|----------|-------------|
| `work/{module}/{recipe}.syn.v` | Pre-tech-mapped netlist per recipe (generic Yosys cells, technology-independent) |
| `work/{module}/{recipe}.v` | Tech-mapped netlist per recipe (sky130 cells) |
| `results/{module}/winner.v` | Winning tech-mapped netlist (pareto-optimal) |
| `results/summary.{md,json,csv}` | Full sweep results summary |
| `syn/ms_psram_ahb.gl.v` | Final netlist (copied from winner) |
| `syn/ms_psram_ahb.sdf` | SDF from multi-corner STA |
| `tmp/ms_psram_ahb.syn.v` | Pre-tech-mapped netlist (from legacy `make synth` target) |

## 13. Gate-Level Simulation

### 13.1 Requirements

Gate-level simulation with iverilog requires behavioral Verilog models for the target standard cell library. For the Skywater 130nm HD library:

- `sky130_hd-clean.v` — behavioral models with internal supply pins (no power port connections needed)
- The file must include a `` `timescale 1ns/1ps `` directive for correct UDP delay resolution
- `primitives.v` is NOT needed — `sky130_hd-clean.v` is self-contained (includes UDP primitives and all cell models)

### 13.2 Lessons Learned

1. **UDP `#1` delays require `timescale**: The sky130 UDP primitives (e.g., `sky130_fd_sc_hd__udp_dff$PR`) use `#1` delays on their output transitions. Without a `timescale` directive in the cell library file, iverilog cannot resolve these delays, and all DFF outputs remain `X` — even after async reset assertion. Adding `` `timescale 1ns/1ps `` to the cell library file resolves this.

2. **No separate `primitives.v`**: The `sky130_hd-clean.v` already contains all UDP primitives, module definitions, and `sky130_ef_sc_hd__*` filler/decap models. Including `primitives.v` alongside it causes duplicate module definition errors in iverilog.

3. **Yosys netlist has no `timescale`**: The netlist produced by `write_verilog -noattr -noexpr -nodec` does not include a `timescale` directive. This is harmless as long as the cell library has one.

4. **SDF annotation**: iverilog supports SDF back-annotation via `+sdf_<module_type>=<file>`. The SDF file must match the module name in the netlist. Use `write_sdf -corner slow` in OpenSTA for worst-case timing.

## 14. Integration Example

### 14.1 Instantiation (APS6404L, 1-4-4 Quad, 50 MHz sys_clk, with cache)

```verilog
ms_psram_ahb #(
    .SPI_CLK_DIV     (4'd2),        // SCLK = 50MHz / (2x2) = 12.5 MHz
    .QUAD_EN         (1),            // Quad mode supported
    .ADDR_WIDTH      (23),           // 23-bit byte address (8 MB)
    .INIT_DLY        (16'd5000),    // 100 us power-up delay
    .RST_DLY         (16'd2500),    // 50 us reset delay
    .SPI_ADDR_BITS   (24),           // 24-bit SPI address
    .SPI_DMY_CLKS    (8),            // 8 dummy clocks for SPI reads
    .SPI_CMD_READ    (8'h0B),       // Fast Read
    .SPI_CMD_WRITE   (8'h02),       // Write
    .QUAD_CMD_READ   (8'hEB),       // Quad I/O Fast Read
    .QUAD_CMD_WRITE  (8'h38),       // Quad I/O Write
    .QUAD_DMY_CLKS   (6'd6),        // 6 dummy clocks for quad reads
    .QUAD_ENTER_CMD  (8'h35),       // Enter quad mode command
    .QUAD_ADDR_CLKS  (6'd6),        // 6 quad address clocks (24/4)
    .CACHE_EN        (1),            // Enable read cache + write buffer
    .CACHE_INDEX_BITS(2),            // 4 cache entries (16 bytes)
    .CACHE_BUF_DEPTH (2),            // 2-entry write buffer
    .CSR_REGION      (4'hF)          // CSR at haddr[27:24] == 0xF
) u_psram (
    .hclk       (hclk),
    .hresetn    (hresetn),
    .hsel       (psram_sel),
    .haddr      (haddr),
    .htrans     (htrans),
    .hwrite     (hwrite),
    .hsize      (hsize),
    .hburst     (hburst),
    .hwdata     (hwdata),
    .hready     (hready),
    .hrdata     (hrdata),
    .hreadyout  (psram_hreadyout),
    .hresp      (psram_hresp),
    .spi_cs_n   (spi_cs_n),
    .spi_sclk   (spi_sclk),
    .spi_sio_o  (spi_sio_o),
    .spi_sio_oe (spi_sio_oe),
    .spi_sio_i  (spi_sio_i)
);
```

### 14.2 Tri-state Buffer Connection (ASIC/FPGA)

```verilog
// SPI mode — only SIO[0] and SIO[1] are active
assign io_psram_sio0 = spi_sio_oe[0] ? spi_sio_o[0] : 1'bz;
assign io_psram_sio1 = spi_sio_oe[1] ? spi_sio_o[1] : 1'bz;
assign spi_sio_i[0]  = io_psram_sio0;
assign spi_sio_i[1]  = io_psram_sio1;
assign spi_sio_i[2]  = 1'b0;
assign spi_sio_i[3]  = 1'b0;

// Quad mode — all four SIO pins active
// For FPGA with dedicated I/O primitives:
// IOBUF u_sio0 (.O(spi_sio_i[0]), .IO(io_psram_sio0), .I(spi_sio_o[0]), .T(~spi_sio_oe[0]));
// IOBUF u_sio1 (.O(spi_sio_i[1]), .IO(io_psram_sio1), .I(spi_sio_o[1]), .T(~spi_sio_oe[1]));
// IOBUF u_sio2 (.O(spi_sio_i[2]), .IO(io_psram_sio2), .I(spi_sio_o[2]), .T(~spi_sio_oe[2]));
// IOBUF u_sio3 (.O(spi_sio_i[3]), .IO(io_psram_sio3), .I(spi_sio_o[3]), .T(~spi_sio_oe[3]));
```

### 14.3 Instantiation (Microchip 23LC512, SPI mode)

```verilog
ms_psram_ahb #(
    .SPI_CLK_DIV  (4'd2),
    .QUAD_EN      (0),
    .ADDR_WIDTH   (16),          // 16-bit byte address (64 KB)
    .INIT_DLY     (16'd200),
    .RST_DLY      (16'd100),
    .SPI_ADDR_BITS(16),          // 16-bit SPI address
    .SPI_DMY_CLKS (0),           // No dummy clocks
    .SPI_CMD_READ (8'h03),      // Read (not Fast Read)
    .SPI_CMD_WRITE(8'h02)       // Write
) u_psram ( /* ... same port connections ... */ );
```

## 15. Revision History

| Version | Date | Description |
|---------|------|-------------|
| 1.0 | 2025-05-01 | Initial release — SPI and QSPI modes, AHB-Lite slave, RMW for partial writes, multi-vendor parameterization |
| 1.1 | 2025-05-01 | Added optional read cache (psram_cache) with write-through and write buffer |
| 1.2 | 2025-05-01 | Added CSR module (psram_csr) for runtime configuration. Runtime quad mode switching (SPI → 1-4-4) with software-controlled enter command and configurable delay. Parameterized CSR address region. |
| 1.3 | 2025-05-02 | Renamed ms_psram_ahb_top → ms_psram_ahb. Added detailed performance analysis (Section 8.6) with cache hit/miss cycle counts. Added ASIC resource utilization (Skywater 130nm). Added gate-level simulation section with iverilog + sky130 lessons learned. Netlist renamed to ms_psram_ahb.gl.v. |
| 1.4 | 2025-05-02 | Added `make syn-flat` and `make syn-hier` synthesis flows with 14-recipe ABC sweep via synth_flow.py. Replaced `make synth-sweep` with syn-flat/syn-hier. Updated ASIC results to CACHE_INDEX_BITS=4, 8ns/125MHz with legacy/flat/hierarchical comparison. Added hierarchical module breakdown, ABC recipe compatibility notes, and synthesis output artifacts. Added `params` config field for Verilog `-chparam` support. Yosys driver now uses `synth -top -flatten -noabc` for robustness. All synthesis flows emit pre-tech-mapped `.syn.v` alongside final `.gl.v`. Added Apache 2.0 SPDX license headers. |

## 16. File List

| File | Description |
|------|-------------|
| rtl/ms_psram_ahb.v | Top-level wrapper (address decode + AHB slave + optional cache + PSRAM controller + CSR) |
| rtl/ahb_slave_if.v | AHB-Lite slave protocol adapter |
| rtl/psram_csr.v | CSR register file (AHB slave for configuration and status) |
| rtl/psram_cache.v | Direct-mapped read cache with write buffer (optional) |
| rtl/psram_ctrl.v | PSRAM SPI/QSPI protocol controller + inline PHY + quad switch FSM |
| dv/tb_ms_psram_ahb.v | Testbench with custom PSRAM model (APS6404L, no cache) |
| dv/tb_psram_cache.v | Testbench with APS6404L model (cache enabled) |
| dv/tb_ms_psram_ahb_23lc512.v | Testbench with Microchip M23LC512 model |
| dv/tb_ms_psram_ahb_gls.v | Gate-level simulation testbench (APS6404L, no cache, no params) |
| dv/23LC512.v | Microchip 23LC512 SPI/QPI SRAM simulation model |
| dv/23A512.v | Microchip 23A512 SPI/QPI SRAM simulation model |
| syn/psram.sdc | Synopsys Design Constraints (clock, I/O delays) |
| syn/synth_flat.yaml | Config for flat synthesis with per-module params |
| syn/synth_hier.yaml | Config for hierarchical synthesis with per-module params |
| synth_flow/synth_flow.py | Synthesis flow automation (recipe sweep, pareto selection, multi-corner STA) |
| synth_flow/area_report.py | Cell count + area reporting from netlist + liberty |
| Makefile | Build targets: rtl-sim, synth, syn-flat, syn-hier, sta, gl-sim, gls-sdf, clean |
| doc/datasheet.md | This document |
