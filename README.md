# MS PSRAM AHB Controller

An AHB-Lite slave interface for Pseudo-SRAM chips (APS6404L, Microchip
23LC512/23A512, and compatible SPI/QSPI SRAM devices).

## Features

- **AHB-Lite slave** — single in-flight transaction, no FIFO, wait-state stalls
- **SPI Mode 0** (CPOL=0, CPHA=0) with optional Quad SPI (1-4-4)
- **Multi-vendor** — parameterized opcodes, address width, dummy clocks
- **Read cache** — write-through, write-no-allocate, direct-mapped (configurable depth)
- **Write buffer** — up to 4 pending writes absorbed before stalling
- **CSR region** — runtime configuration of SPI/quad opcodes, delays, quad switch
- **Separate I/O** — `_o`, `_oe`, `_i` signals for bidirectional SIO (ASIC/FPGA)
- **Little-endian** byte ordering with byte-swap support
- **Synthesis-ready** — sky130 HD, multi-corner STA (SS/TT/FF), GLS verified

## Supported Devices

| Device | Capacity | Address Width | Quad |
|--------|----------|---------------|------|
| APMemory APS6404L | 8 MB | 23-bit | Yes |
| Microchip 23LC512 | 64 KB | 16-bit | Yes |
| Microchip 23A512 | 64 KB | 16-bit | Yes |

## Module Hierarchy

```
ms_psram_ahb (top)
├── ahb_slave_if    — AHB protocol adapter, byte-strobe generation
├── psram_cache     — direct-mapped read cache + write buffer
├── psram_ctrl      — SPI/QSPI FSM engine
└── psram_csr       — configuration register file (6 CSRs)
```

## Quick Start

### Integration Example — APS6404L with Quad + Cache

```verilog
ms_psram_ahb #(
    .SPI_CLK_DIV       (2),
    .QUAD_EN           (1),
    .ADDR_WIDTH        (23),
    .CACHE_EN          (1),
    .CACHE_INDEX_BITS  (4)
) u_psram (
    .hclk      (hclk),
    .hresetn   (hresetn),
    .hsel      (hsel),
    .haddr     (haddr),
    .htrans    (htrans),
    .hwrite    (hwrite),
    .hsize     (hsize),
    .hburst    (hburst),
    .hwdata    (hwdata),
    .hready    (hready),
    .hrdata    (hrdata),
    .hreadyout (hreadyout),
    .hresp     (hresp),
    .spi_cs_n  (spi_cs_n),
    .spi_sclk  (spi_sclk),
    .spi_sio_o (spi_sio_o),
    .spi_sio_oe(spi_sio_oe),
    .spi_sio_i (spi_sio_i)
);
```

### Simulation

```bash
make rtl-sim    # 47 checks across 4 testbenches
```

### Synthesis (requires [synth_flow](https://github.com/shalan/synth_flow))

```bash
make synth      # legacy single-recipe synthesis
make syn-flat   # flat sweep (14 recipes, pareto selection)
make syn-hier   # hierarchical bottom-up sweep
make sta        # multi-corner STA (SS/TT/FF)
make gl-sim     # gate-level simulation
make gls-sdf    # GLS with SDF back-annotation
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SPI_CLK_DIV` | 1 | SCLK = sys_clk / (2 × SPI_CLK_DIV) |
| `QUAD_EN` | 0 | Enable Quad SPI mode |
| `ADDR_WIDTH` | 23 | PSRAM address width (23 for APS6404L, 16 for 23LC512) |
| `INIT_DLY` | 5000 | Initialization delay (clock cycles) |
| `RST_DLY` | 2500 | Reset recovery delay (clock cycles) |
| `CACHE_EN` | 0 | Enable read cache + write buffer |
| `CACHE_INDEX_BITS` | 2 | Cache line index bits (2^n lines) |
| `CACHE_BUF_DEPTH` | 4 | Write buffer depth |
| `CSR_REGION` | 4'hF | AHB address[27:24] for CSR access |

## CSR Map

Base address: `haddr[27:24] == CSR_REGION`

| Offset | Name | Description |
|--------|------|-------------|
| 0x00 | STATUS | INIT_DONE, BUSY, QUAD_ACTIVE (read-only) |
| 0x04 | CTRL | QUAD_EN control |
| 0x08 | SPI_CFG | CMD_READ, CMD_WRITE, DMY_CLKS, clock divider |
| 0x0C | QUAD_CFG | QUAD_CMD_READ/WRITE, DMY_CLKS, ADDR_CLKS |
| 0x10 | QUAD_ENTER | Enter quad mode command |
| 0x14 | QUAD_DLY | Quad switch delay |

## Synthesis Results — sky130 HD, 125 MHz (8 ns)

| Metric | Value |
|--------|-------|
| Total cells | 7,612 |
| Area | 69,329 um² |
| Eq. gate count | 18,470 |
| WNS setup (SS) | +1.54 ns |
| WNS hold (FF) | +0.26 ns |

## Directory Structure

```
rtl/          Verilog source files
dv/           Testbenches + simulation models
syn/          Synthesis configs, netlists, SDF, SDC
doc/          Datasheet
Makefile      Build targets
```

## License

Apache-2.0 — see [LICENSE](LICENSE).

## Author

Mohamed Shalan — [mshalan@aucegypt.edu](mailto:mshalan@aucegypt.edu)
