// SPDX-License-Identifier: Apache-2.0
// Author: Mohamed Shalan <mshalan@aucegypt.edu>

`timescale 1ns/1ps

module tb_psram_cache;

    parameter SPI_CLK_DIV = 2;
    parameter ADDR_WIDTH  = 23;
    parameter CLK_PERIOD  = 20;

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

    reg         sio1_out;
    reg         sio1_en;

    assign spi_sio_i[0] = 1'bz;
    assign spi_sio_i[1] = sio1_en ? sio1_out : 1'bz;
    assign spi_sio_i[2] = 1'bz;
    assign spi_sio_i[3] = 1'bz;

    ms_psram_ahb #(
        .SPI_CLK_DIV(SPI_CLK_DIV),
        .QUAD_EN    (0),
        .ADDR_WIDTH (ADDR_WIDTH),
        .INIT_DLY   (16'd200),
        .RST_DLY    (16'd100),
        .CACHE_EN   (1),
        .CACHE_INDEX_BITS(2),
        .CACHE_BUF_DEPTH (2)
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

    reg [7:0] psram [0:8388607];

    reg [6:0]  bit_cnt;
    reg [7:0]  cmd_reg;
    reg [23:0] addr_reg;
    reg [7:0]  data_sr;

    always @(posedge spi_cs_n) begin
        bit_cnt  = 0;
        sio1_en  = 0;
        sio1_out = 0;
        cmd_reg  = 0;
        addr_reg = 0;
        data_sr  = 0;
    end

    always @(posedge spi_sclk) begin
        if (!spi_cs_n) begin
            if (bit_cnt < 8) begin
                if (bit_cnt == 7) begin
                    cmd_reg = {data_sr[6:0], spi_sio_o[0]};
                end
                data_sr = {data_sr[6:0], spi_sio_o[0]};
            end
            else if (bit_cnt < 32) begin
                case (bit_cnt)
                    7'd15: addr_reg[23:16] = {data_sr[6:0], spi_sio_o[0]};
                    7'd23: addr_reg[15:8]  = {data_sr[6:0], spi_sio_o[0]};
                    7'd31: addr_reg[7:0]   = {data_sr[6:0], spi_sio_o[0]};
                    default: ;
                endcase
                data_sr = {data_sr[6:0], spi_sio_o[0]};
            end
            else if (cmd_reg == 8'h02) begin
                data_sr = {data_sr[6:0], spi_sio_o[0]};
                if ((bit_cnt - 32) % 8 == 7) begin
                    psram[addr_reg + (bit_cnt - 32) / 8] = data_sr;
                end
            end
            else if (cmd_reg == 8'h0B && bit_cnt == 39) begin
                data_sr = psram[addr_reg];
            end
            bit_cnt = bit_cnt + 1;
        end
    end

    always @(negedge spi_sclk) begin
        if (!spi_cs_n && cmd_reg == 8'h0B && bit_cnt >= 40) begin
            sio1_out = data_sr[7];
            sio1_en  = 1;
            if ((bit_cnt - 40) % 8 == 7) begin
                data_sr = psram[addr_reg + (bit_cnt - 39) / 8];
            end else
                data_sr = {data_sr[6:0], 1'b0};
        end
    end

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
        sio1_out = 0; sio1_en = 0; bit_cnt = 0;
        pass_count = 0; fail_count = 0;

        #200;
        hresetn = 1;
        repeat (200) @(posedge hclk);

        $display("--- TEST 1: Write then read (cache miss + fill) ---");
        ahb_write(32'h0, 32'hDEADBEEF, 3'b010);
        repeat (20) @(posedge hclk);
        ahb_read(32'h0, 3'b010, rd_val);
        if (rd_val === 32'hDEADBEEF) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xDEADBEEF)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 2: Read same addr again (cache hit) ---");
        ahb_read(32'h0, 3'b010, rd_val);
        if (rd_val === 32'hDEADBEEF) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xDEADBEEF)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 3: Write second addr, read back ---");
        ahb_write(32'h4, 32'h12345678, 3'b010);
        repeat (20) @(posedge hclk);
        ahb_read(32'h4, 3'b010, rd_val);
        if (rd_val === 32'h12345678) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0x12345678)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 4: Re-read first addr (should still be cached) ---");
        ahb_read(32'h0, 3'b010, rd_val);
        if (rd_val === 32'hDEADBEEF) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xDEADBEEF)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 5: Cache eviction (4 entries, idx[3:2]) ---");
        ahb_write(32'h00, 32'hAABBCCDD, 3'b010);
        ahb_write(32'h04, 32'h11223344, 3'b010);
        ahb_write(32'h08, 32'h55667788, 3'b010);
        ahb_write(32'h0C, 32'h99AABBCC, 3'b010);
        repeat (40) @(posedge hclk);
        ahb_write(32'h10, 32'hDDEEFF00, 3'b010);
        repeat (40) @(posedge hclk);
        ahb_read(32'h00, 3'b010, rd_val);
        if (rd_val === 32'hAABBCCDD) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xAABBCCDD)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 6: Partial byte write (RMW through cache) ---");
        ahb_write(32'h20, 32'hFFFFFFFF, 3'b010);
        repeat (40) @(posedge hclk);
        ahb_write(32'h20, 32'h000000AB, 3'b000);
        repeat (20) @(posedge hclk);
        ahb_read(32'h20, 3'b010, rd_val);
        if (rd_val === 32'hFFFFFFAB) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xFFFFFFAB)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 7: Multiple writes to same addr ---");
        ahb_write(32'h30, 32'h11111111, 3'b010);
        ahb_write(32'h30, 32'h22222222, 3'b010);
        repeat (40) @(posedge hclk);
        ahb_read(32'h30, 3'b010, rd_val);
        if (rd_val === 32'h22222222) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0x22222222)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 8: Read from addr written but evicted ---");
        ahb_write(32'h40, 32'hCAFEBABE, 3'b010);
        repeat (40) @(posedge hclk);
        ahb_write(32'h00, 32'h11111111, 3'b010);
        ahb_write(32'h04, 32'h22222222, 3'b010);
        ahb_write(32'h08, 32'h33333333, 3'b010);
        ahb_write(32'h0C, 32'h44444444, 3'b010);
        repeat (60) @(posedge hclk);
        ahb_read(32'h40, 3'b010, rd_val);
        if (rd_val === 32'hCAFEBABE) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xCAFEBABE)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 9: Write buffer full (3 rapid writes) ---");
        ahb_write(32'h100, 32'hAAAAAAAA, 3'b010);
        ahb_write(32'h104, 32'hBBBBBBBB, 3'b010);
        ahb_write(32'h108, 32'hCCCCCCCC, 3'b010);
        repeat (80) @(posedge hclk);
        ahb_read(32'h100, 3'b010, rd_val);
        if (rd_val === 32'hAAAAAAAA) begin
            $display("  PASS: addr 0x100 = 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: addr 0x100 = 0x%08h (exp 0xAAAAAAAA)", rd_val); fail_count = fail_count + 1;
        end
        ahb_read(32'h104, 3'b010, rd_val);
        if (rd_val === 32'hBBBBBBBB) begin
            $display("  PASS: addr 0x104 = 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: addr 0x104 = 0x%08h (exp 0xBBBBBBBB)", rd_val); fail_count = fail_count + 1;
        end
        ahb_read(32'h108, 3'b010, rd_val);
        if (rd_val === 32'hCCCCCCCC) begin
            $display("  PASS: addr 0x108 = 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: addr 0x108 = 0x%08h (exp 0xCCCCCCCC)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 10: Read miss with buffered write to SAME addr ---");
        ahb_write(32'h200, 32'hDDDDDDDD, 3'b010);
        ahb_read(32'h200, 3'b010, rd_val);
        if (rd_val === 32'hDDDDDDDD) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xDDDDDDDD)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 11: Partial write to non-cached addr, then read ---");
        ahb_write(32'h304, 32'hFFFFFFFF, 3'b010);
        repeat (60) @(posedge hclk);
        ahb_read(32'h304, 3'b010, rd_val);
        if (rd_val === 32'hFFFFFFFF) begin
            $display("  PASS: initial = 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: initial = 0x%08h (exp 0xFFFFFFFF)", rd_val); fail_count = fail_count + 1;
        end
        ahb_write(32'h304, 32'h00000012, 3'b001);
        ahb_read(32'h304, 3'b010, rd_val);
        if (rd_val === 32'hFFFF0012) begin
            $display("  PASS: after halfword = 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: after halfword = 0x%08h (exp 0xFFFF0012)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 12: Write to non-cached addr, evict, read back ---");
        ahb_write(32'h400, 32'h1A2B3C4D, 3'b010);
        repeat (40) @(posedge hclk);
        ahb_write(32'h00, 32'h11111111, 3'b010);
        ahb_write(32'h04, 32'h22222222, 3'b010);
        ahb_write(32'h08, 32'h33333333, 3'b010);
        ahb_write(32'h0C, 32'h44444444, 3'b010);
        repeat (80) @(posedge hclk);
        ahb_read(32'h400, 3'b010, rd_val);
        if (rd_val === 32'h1A2B3C4D) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0x1A2B3C4D)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 13: Background drain - write then immediate read to diff addr ---");
        ahb_write(32'h500, 32'hEE111111, 3'b010);
        ahb_read(32'h504, 3'b010, rd_val);
        repeat (60) @(posedge hclk);
        ahb_read(32'h500, 3'b010, rd_val);
        if (rd_val === 32'hEE111111) begin
            $display("  PASS: 0x%08h (drain + fetch)", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xEE111111)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- TEST 14: Write buffer full + read to different addr ---");
        repeat (80) @(posedge hclk);
        ahb_write(32'h600, 32'hA1A1A1A1, 3'b010);
        ahb_write(32'h604, 32'hB2B2B2B2, 3'b010);
        ahb_read(32'h608, 3'b010, rd_val);
        repeat (60) @(posedge hclk);
        ahb_read(32'h600, 3'b010, rd_val);
        if (rd_val === 32'hA1A1A1A1) begin
            $display("  PASS: 0x600 = 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x600 = 0x%08h (exp 0xA1A1A1A1)", rd_val); fail_count = fail_count + 1;
        end
        ahb_read(32'h604, 3'b010, rd_val);
        if (rd_val === 32'hB2B2B2B2) begin
            $display("  PASS: 0x604 = 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x604 = 0x%08h (exp 0xB2B2B2B2)", rd_val); fail_count = fail_count + 1;
        end

        $display("\n--- %0d passed, %0d failed ---", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("SOME TESTS FAILED");

        #1000; $finish;
    end

    always #(CLK_PERIOD/2) hclk = ~hclk;

endmodule
