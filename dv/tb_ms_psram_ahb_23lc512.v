// SPDX-License-Identifier: Apache-2.0
// Author: Mohamed Shalan <mshalan@aucegypt.edu>

`timescale 1ns/1ps

module tb_psram_ahb_23lc512;

    parameter SPI_CLK_DIV   = 2;
    parameter ADDR_WIDTH    = 16;
    parameter CLK_PERIOD    = 20;
    parameter SPI_ADDR_BITS = 16;
    parameter SPI_DMY_CLKS  = 0;

    reg         hclk;
    reg         hresetn;
    reg         hsel;
    reg  [31:0] haddr;
    reg  [1:0]  htrans;
    reg         hwrite;
    reg  [2:0]  hsize;
    reg  [2:0]  hburst;
    reg  [31:0] hwdata;
    reg         hready;
    wire [31:0] hrdata;
    wire        hreadyout;
    wire [1:0]  hresp;

    wire        spi_cs_n;
    wire        spi_sclk;
    wire [3:0]  spi_sio_o;
    wire [3:0]  spi_sio_oe;
    wire [3:0]  spi_sio_i;

    wire SI_SIO0;
    wire SO_SIO1;
    wire SIO2;
    wire HOLD_N_SIO3;

    assign SI_SIO0      = spi_sio_oe[0] ? spi_sio_o[0] : 1'bz;
    assign SO_SIO1      = spi_sio_oe[1] ? spi_sio_o[1] : 1'bz;
    assign SIO2         = spi_sio_oe[2] ? spi_sio_o[2] : 1'bz;
    assign HOLD_N_SIO3  = spi_sio_oe[3] ? spi_sio_o[3] : 1'bz;

    assign spi_sio_i[0] = SI_SIO0;
    assign spi_sio_i[1] = SO_SIO1;
    assign spi_sio_i[2] = SIO2;
    assign spi_sio_i[3] = HOLD_N_SIO3;

    pullup(SIO2);
    pullup(HOLD_N_SIO3);

    ms_psram_ahb #(
        .SPI_CLK_DIV  (SPI_CLK_DIV),
        .QUAD_EN      (0),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .INIT_DLY     (16'd200),
        .RST_DLY      (16'd100),
        .SPI_ADDR_BITS(SPI_ADDR_BITS),
        .SPI_DMY_CLKS (SPI_DMY_CLKS),
        .SPI_CMD_READ (8'h03),
        .SPI_CMD_WRITE(8'h02)
    ) dut (
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

    M23LC512 sram_model (
        .SI_SIO0     (SI_SIO0),
        .SO_SIO1     (SO_SIO1),
        .SCK         (spi_sclk),
        .CS_N        (spi_cs_n),
        .SIO2        (SIO2),
        .HOLD_N_SIO3 (HOLD_N_SIO3),
        .RESET       (~hresetn)
    );

    task ahb_write;
        input [31:0] addr;
        input [31:0] data;
        input [2:0]  size;
        begin
            @(posedge hclk);
            hsel <= 1'b1; haddr <= addr; htrans <= 2'b10;
            hwrite <= 1'b1; hsize <= size; hburst <= 3'b000; hready <= 1'b1;
            @(posedge hclk);
            while (!hreadyout) @(posedge hclk);
            hwdata <= data; hsel <= 1'b0; htrans <= 2'b00;
            @(posedge hclk);
            while (!hreadyout) @(posedge hclk);
        end
    endtask

    task ahb_read;
        input  [31:0] addr;
        input  [2:0]  size;
        output [31:0] data;
        begin
            @(posedge hclk);
            hsel <= 1'b1; haddr <= addr; htrans <= 2'b10;
            hwrite <= 1'b0; hsize <= size; hburst <= 3'b000; hready <= 1'b1;
            @(posedge hclk);
            while (!hreadyout) @(posedge hclk);
            hsel <= 1'b0; htrans <= 2'b00;
            @(posedge hclk);
            while (!hreadyout) @(posedge hclk);
            data = hrdata;
        end
    endtask

    integer pass_count, fail_count;
    reg [31:0] rd_val;

    initial begin
        hclk = 0; hresetn = 0; hsel = 0; haddr = 0; htrans = 0;
        hwrite = 0; hsize = 0; hburst = 0; hwdata = 0; hready = 1;
        pass_count = 0; fail_count = 0;

        #200;
        hresetn = 1;
        repeat (200) @(posedge hclk);

        $display("--- TEST 1: Write 0xDEADBEEF to addr 0x00 ---");
        ahb_write(32'h0, 32'hDEADBEEF, 3'b010);

        $display("--- TEST 2: Read back addr 0x00 ---");
        ahb_read(32'h0, 3'b010, rd_val);
        if (rd_val === 32'hDEADBEEF) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xDEADBEEF)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 3: Write 0x12345678 to addr 0x04 ---");
        ahb_write(32'h4, 32'h12345678, 3'b010);

        $display("--- TEST 4: Read back addr 0x04 ---");
        ahb_read(32'h4, 3'b010, rd_val);
        if (rd_val === 32'h12345678) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0x12345678)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 5: Re-read addr 0x00 ---");
        ahb_read(32'h0, 3'b010, rd_val);
        if (rd_val === 32'hDEADBEEF) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xDEADBEEF)", rd_val); fail_count = fail_count + 1;
        end

        $display("\n--- %0d passed, %0d failed ---", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("SOME TESTS FAILED");

        #1000; $finish;
    end

    always #(CLK_PERIOD/2) hclk = ~hclk;

endmodule
