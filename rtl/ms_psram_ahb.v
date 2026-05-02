// SPDX-License-Identifier: Apache-2.0
// Author: Mohamed Shalan <mshalan@aucegypt.edu>

module ms_psram_ahb #(
    parameter SPI_CLK_DIV   = 1,
    parameter QUAD_EN       = 0,
    parameter ADDR_WIDTH    = 23,
    parameter INIT_DLY      = 16'd5000,
    parameter RST_DLY       = 16'd2500,
    parameter SPI_ADDR_BITS = 24,
    parameter SPI_DMY_CLKS  = 8,
    parameter [7:0] SPI_CMD_READ  = 8'h0B,
    parameter [7:0] SPI_CMD_WRITE = 8'h02,
    parameter [7:0] QUAD_CMD_READ  = 8'hEB,
    parameter [7:0] QUAD_CMD_WRITE = 8'h38,
    parameter [5:0] QUAD_DMY_CLKS  = 6'd6,
    parameter [7:0] QUAD_ENTER_CMD = 8'h35,
    parameter [5:0] QUAD_ADDR_CLKS = 6'd6,
    parameter CACHE_EN      = 0,
    parameter CACHE_INDEX_BITS = 2,
    parameter CACHE_BUF_DEPTH  = 4,
    parameter [3:0] CSR_REGION = 4'hF
)(
    input  wire                      hclk,
    input  wire                      hresetn,

    input  wire                      hsel,
    input  wire [31:0]               haddr,
    input  wire [1:0]                htrans,
    input  wire                      hwrite,
    input  wire [2:0]                hsize,
    input  wire [2:0]                hburst,
    input  wire [31:0]               hwdata,
    input  wire                      hready,
    output wire [31:0]               hrdata,
    output wire                      hreadyout,
    output wire [1:0]                hresp,

    output wire                      spi_cs_n,
    output wire                      spi_sclk,
    output wire [3:0]                spi_sio_o,
    output wire [3:0]                spi_sio_oe,
    input  wire [3:0]                spi_sio_i
);

    wire csr_sel   = hsel & (haddr[27:24] == CSR_REGION);
    wire psram_sel = hsel & ~csr_sel;

    reg csr_active;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            csr_active <= 1'b0;
        else if (hsel & htrans[1] & hready & hreadyout)
            csr_active <= csr_sel;
    end

    assign hresp = 2'b00;

    wire [31:0] psram_hrdata;
    wire        psram_hreadyout;
    wire [31:0] csr_hrdata;
    wire        csr_hreadyout;

    assign hrdata     = csr_active ? csr_hrdata     : psram_hrdata;
    assign hreadyout  = csr_active ? csr_hreadyout   : psram_hreadyout;

    wire                      ahb_req_valid;
    wire                      ahb_req_write;
    wire [ADDR_WIDTH-1:0]     ahb_req_addr;
    wire [31:0]               ahb_req_wdata;
    wire [3:0]                ahb_req_wstrb;
    wire                      ahb_req_ready;
    wire [31:0]               ahb_resp_rdata;
    wire                      ahb_resp_valid;

    wire                      core_req_valid;
    wire                      core_req_write;
    wire [ADDR_WIDTH-1:0]     core_req_addr;
    wire [31:0]               core_req_wdata;
    wire [3:0]                core_req_wstrb;
    wire                      core_req_ready;
    wire [31:0]               core_resp_rdata;
    wire                      core_resp_valid;

    wire [7:0]  csr_spi_cmd_read;
    wire [7:0]  csr_spi_cmd_write;
    wire [5:0]  csr_spi_dmy_clks;
    wire [7:0]  csr_quad_cmd_read;
    wire [7:0]  csr_quad_cmd_write;
    wire [5:0]  csr_quad_dmy_clks;
    wire [7:0]  csr_quad_enter_cmd;
    wire [5:0]  csr_quad_addr_clks;
    wire [31:0] csr_quad_switch_dly;
    wire        csr_quad_en;

    wire        ctrl_init_done;
    wire        ctrl_busy;
    wire        ctrl_quad_active;

    ahb_slave_if #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_ahb_slave (
        .hclk           (hclk),
        .hresetn        (hresetn),
        .hsel           (psram_sel),
        .haddr          (haddr),
        .htrans         (htrans),
        .hwrite         (hwrite),
        .hsize          (hsize),
        .hburst         (hburst),
        .hwdata         (hwdata),
        .hready         (hready),
        .hrdata         (psram_hrdata),
        .hreadyout      (psram_hreadyout),
        .hresp          (),

        .core_req_valid (ahb_req_valid),
        .core_req_write (ahb_req_write),
        .core_req_addr  (ahb_req_addr),
        .core_req_wdata (ahb_req_wdata),
        .core_req_wstrb (ahb_req_wstrb),
        .core_req_ready (ahb_req_ready),
        .core_resp_rdata(ahb_resp_rdata),
        .core_resp_valid(ahb_resp_valid)
    );

    generate
        if (CACHE_EN) begin : gen_cache
            psram_cache #(
                .ADDR_WIDTH (ADDR_WIDTH),
                .INDEX_BITS (CACHE_INDEX_BITS),
                .BUF_DEPTH  (CACHE_BUF_DEPTH)
            ) u_cache (
                .clk           (hclk),
                .rst_n         (hresetn),

                .req_valid     (ahb_req_valid),
                .req_write     (ahb_req_write),
                .req_addr      (ahb_req_addr),
                .req_wdata     (ahb_req_wdata),
                .req_wstrb     (ahb_req_wstrb),
                .req_ready     (ahb_req_ready),
                .resp_rdata    (ahb_resp_rdata),
                .resp_valid    (ahb_resp_valid),

                .be_req_valid  (core_req_valid),
                .be_req_write  (core_req_write),
                .be_req_addr   (core_req_addr),
                .be_req_wdata  (core_req_wdata),
                .be_req_wstrb  (core_req_wstrb),
                .be_req_ready  (core_req_ready),
                .be_resp_rdata (core_resp_rdata),
                .be_resp_valid (core_resp_valid)
            );
        end else begin : gen_nocache
            assign ahb_req_ready     = core_req_ready;
            assign ahb_resp_rdata    = core_resp_rdata;
            assign ahb_resp_valid    = core_resp_valid;
            assign core_req_valid    = ahb_req_valid;
            assign core_req_write    = ahb_req_write;
            assign core_req_addr     = ahb_req_addr;
            assign core_req_wdata    = ahb_req_wdata;
            assign core_req_wstrb    = ahb_req_wstrb;
        end
    endgenerate

    psram_ctrl #(
        .SPI_CLK_DIV  (SPI_CLK_DIV),
        .QUAD_EN      (QUAD_EN),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .INIT_DLY     (INIT_DLY),
        .RST_DLY      (RST_DLY),
        .SPI_ADDR_BITS(SPI_ADDR_BITS),
        .SPI_DMY_CLKS (SPI_DMY_CLKS),
        .SPI_CMD_READ (SPI_CMD_READ),
        .SPI_CMD_WRITE(SPI_CMD_WRITE),
        .QUAD_CMD_READ (QUAD_CMD_READ),
        .QUAD_CMD_WRITE(QUAD_CMD_WRITE),
        .QUAD_DMY_CLKS (QUAD_DMY_CLKS),
        .QUAD_ENTER_CMD(QUAD_ENTER_CMD),
        .QUAD_ADDR_CLKS(QUAD_ADDR_CLKS)
    ) u_psram_core (
        .clk           (hclk),
        .rst_n         (hresetn),

        .req_valid     (core_req_valid),
        .req_write     (core_req_write),
        .req_addr      (core_req_addr),
        .req_wdata     (core_req_wdata),
        .req_wstrb     (core_req_wstrb),
        .req_ready     (core_req_ready),
        .resp_rdata    (core_resp_rdata),
        .resp_valid    (core_resp_valid),

        .spi_cs_n      (spi_cs_n),
        .spi_sclk      (spi_sclk),
        .spi_sio_o     (spi_sio_o),
        .spi_sio_oe    (spi_sio_oe),
        .spi_sio_i     (spi_sio_i),

        .csr_spi_cmd_read   (csr_spi_cmd_read),
        .csr_spi_cmd_write  (csr_spi_cmd_write),
        .csr_spi_dmy_clks   (csr_spi_dmy_clks),
        .csr_quad_cmd_read  (csr_quad_cmd_read),
        .csr_quad_cmd_write (csr_quad_cmd_write),
        .csr_quad_dmy_clks  (csr_quad_dmy_clks),
        .csr_quad_enter_cmd (csr_quad_enter_cmd),
        .csr_quad_addr_clks (csr_quad_addr_clks),
        .csr_quad_switch_dly(csr_quad_switch_dly),
        .csr_quad_en        (csr_quad_en),

        .init_done    (ctrl_init_done),
        .busy         (ctrl_busy),
        .quad_active  (ctrl_quad_active)
    );

    psram_csr #(
        .SPI_CMD_READ  (SPI_CMD_READ),
        .SPI_CMD_WRITE (SPI_CMD_WRITE),
        .SPI_DMY_CLKS  (SPI_DMY_CLKS),
        .QUAD_CMD_READ  (QUAD_CMD_READ),
        .QUAD_CMD_WRITE (QUAD_CMD_WRITE),
        .QUAD_DMY_CLKS  (QUAD_DMY_CLKS),
        .QUAD_ENTER_CMD (QUAD_ENTER_CMD),
        .QUAD_ADDR_CLKS (QUAD_ADDR_CLKS)
    ) u_csr (
        .hclk           (hclk),
        .hresetn        (hresetn),
        .hsel           (csr_sel),
        .haddr          (haddr),
        .htrans         (htrans),
        .hwrite         (hwrite),
        .hsize          (hsize),
        .hwdata         (hwdata),
        .hready         (hready),
        .hrdata         (csr_hrdata),
        .hreadyout      (csr_hreadyout),

        .csr_spi_cmd_read   (csr_spi_cmd_read),
        .csr_spi_cmd_write  (csr_spi_cmd_write),
        .csr_spi_dmy_clks   (csr_spi_dmy_clks),
        .csr_quad_cmd_read  (csr_quad_cmd_read),
        .csr_quad_cmd_write (csr_quad_cmd_write),
        .csr_quad_dmy_clks  (csr_quad_dmy_clks),
        .csr_quad_enter_cmd (csr_quad_enter_cmd),
        .csr_quad_addr_clks (csr_quad_addr_clks),
        .csr_quad_switch_dly(csr_quad_switch_dly),
        .csr_quad_en        (csr_quad_en),

        .init_done    (ctrl_init_done),
        .busy         (ctrl_busy),
        .quad_active  (ctrl_quad_active)
    );

endmodule
