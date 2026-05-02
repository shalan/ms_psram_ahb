// SPDX-License-Identifier: Apache-2.0
// Author: Mohamed Shalan <mshalan@aucegypt.edu>

`timescale 1ns/1ps

module tb_psram_csr;

    parameter SPI_CLK_DIV = 2;
    parameter ADDR_WIDTH  = 23;
    parameter CLK_PERIOD  = 20;
    parameter CSR_BASE    = 32'h0F000000;

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
        .QUAD_EN    (1),
        .ADDR_WIDTH (ADDR_WIDTH),
        .INIT_DLY   (16'd200),
        .RST_DLY    (16'd100)
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

    reg [7:0]  psram [0:8388607];
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
                    $display("  [PSRAM] CMD=0x%02h", cmd_reg);
                end
                data_sr = {data_sr[6:0], spi_sio_o[0]};
            end
            else if (bit_cnt < 32) begin
                case (bit_cnt)
                    7'd15: addr_reg[23:16] = {data_sr[6:0], spi_sio_o[0]};
                    7'd23: addr_reg[15:8]  = {data_sr[6:0], spi_sio_o[0]};
                    7'd31: begin
                        addr_reg[7:0] = {data_sr[6:0], spi_sio_o[0]};
                        $display("  [PSRAM] ADDR=0x%06h", addr_reg);
                    end
                    default: ;
                endcase
                data_sr = {data_sr[6:0], spi_sio_o[0]};
            end
            else if (cmd_reg == 8'h02) begin
                data_sr = {data_sr[6:0], spi_sio_o[0]};
                if ((bit_cnt - 32) % 8 == 7) begin
                    psram[addr_reg + (bit_cnt - 32) / 8] = data_sr;
                    $display("  [PSRAM] WRITE mem[0x%06h]=0x%02h", addr_reg + (bit_cnt - 32)/8, data_sr);
                end
            end
            else if (cmd_reg == 8'h0B && bit_cnt == 39) begin
                data_sr = psram[addr_reg];
                $display("  [PSRAM] READ preload mem[0x%06h]=0x%02h", addr_reg, data_sr);
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

    task csr_write;
        input [31:0] offset;
        input [31:0] data;
        begin
            ahb_write(CSR_BASE + offset, data, 3'b010);
        end
    endtask

    task csr_read;
        input  [31:0] offset;
        output [31:0] data;
        begin
            ahb_read(CSR_BASE + offset, 3'b010, data);
        end
    endtask

    integer pass_count, fail_count;
    reg [31:0] rd_val;

    task check;
        input [160*8:1] name;
        input [31:0]    actual;
        input [31:0]    expected;
        begin
            if (actual === expected) begin
                $display("  PASS: %0s = 0x%08h", name, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %0s = 0x%08h (exp 0x%08h)", name, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        hclk = 0; hresetn = 0; hsel = 0; haddr = 0; htrans = 0;
        hwrite = 0; hsize = 0; hburst = 0; hwdata = 0; hready = 1;
        sio1_out = 0; sio1_en = 0; bit_cnt = 0;
        pass_count = 0; fail_count = 0;

        #200;
        hresetn = 1;
        repeat (50) @(posedge hclk);

        $display("========================================");
        $display("  TEST 1: Wait for init, check STATUS");
        $display("========================================");
        begin : wait_init
            integer timeout;
            timeout = 0;
            while (timeout < 5000) begin
                csr_read(32'h04, rd_val);
                if (rd_val[0] === 1'b1 && rd_val[1] === 1'b0) begin
                    $display("  INIT_DONE=1, BUSY=0 after %0d CSR reads", timeout + 1);
                    timeout = 5000;
                end
                timeout = timeout + 1;
            end
        end
        check("STATUS.INIT_DONE", rd_val[0], 1'b1);
        check("STATUS.BUSY", rd_val[1], 1'b0);
        check("STATUS.QUAD_ACTIVE", rd_val[2], 1'b0);

        $display("========================================");
        $display("  TEST 2: CTRL read (should be 0)");
        $display("========================================");
        csr_read(32'h00, rd_val);
        check("CTRL", rd_val, 32'h00000000);

        $display("========================================");
        $display("  TEST 3: SPI_CFG read defaults");
        $display("========================================");
        csr_read(32'h08, rd_val);
        check("SPI_CFG", rd_val, 32'h0008020B);

        $display("========================================");
        $display("  TEST 4: SPI_CFG write and readback");
        $display("========================================");
        csr_write(32'h08, 32'h00030155);
        csr_read(32'h08, rd_val);
        check("SPI_CFG_new", rd_val, 32'h00030155);
        csr_write(32'h08, 32'h0008020B);

        $display("========================================");
        $display("  TEST 5: QUAD_CFG read defaults");
        $display("========================================");
        csr_read(32'h0C, rd_val);
        check("QUAD_CFG", rd_val, 32'h060638EB);

        $display("========================================");
        $display("  TEST 6: QUAD_CFG write and readback");
        $display("========================================");
        csr_write(32'h0C, 32'h0503AA55);
        csr_read(32'h0C, rd_val);
        check("QUAD_CFG_new", rd_val, 32'h0503AA55);
        csr_write(32'h0C, 32'h060638EB);

        $display("========================================");
        $display("  TEST 7: QUAD_ENTER read default");
        $display("========================================");
        csr_read(32'h10, rd_val);
        check("QUAD_ENTER", rd_val, 32'h00000035);

        $display("========================================");
        $display("  TEST 8: QUAD_ENTER write and readback");
        $display("========================================");
        csr_write(32'h10, 32'h00000055);
        csr_read(32'h10, rd_val);
        check("QUAD_ENTER_new", rd_val, 32'h00000055);
        csr_write(32'h10, 32'h00000035);

        $display("========================================");
        $display("  TEST 9: QUAD_DLY read default");
        $display("========================================");
        csr_read(32'h14, rd_val);
        check("QUAD_DLY", rd_val, 32'h00000000);

        $display("========================================");
        $display("  TEST 10: QUAD_DLY write and readback");
        $display("========================================");
        csr_write(32'h14, 32'd100);
        csr_read(32'h14, rd_val);
        check("QUAD_DLY_new", rd_val, 32'd100);

        $display("========================================");
        $display("  TEST 11: PSRAM write/read in SPI mode");
        $display("========================================");
        ahb_write(32'h00000100, 32'hCAFEBABE, 3'b010);
        ahb_read(32'h00000100, 3'b010, rd_val);
        check("PSRAM_SPI_READ", rd_val, 32'hCAFEBABE);

        $display("========================================");
        $display("  TEST 12: Trigger quad mode switch");
        $display("========================================");
        csr_write(32'h14, 32'd50);
        csr_write(32'h00, 32'h00000001);

        $display("  Polling STATUS for QUAD_ACTIVE...");
        begin : wait_quad
            integer timeout;
            timeout = 0;
            while (timeout < 500) begin
                csr_read(32'h04, rd_val);
                if (rd_val[2] === 1'b1) begin
                    $display("  QUAD_ACTIVE detected after %0d polls", timeout + 1);
                    timeout = 500;
                end
                timeout = timeout + 1;
            end
        end
        check("STATUS.QUAD_ACTIVE_after_switch", rd_val[2], 1'b1);
        check("STATUS.INIT_DONE_after_switch", rd_val[0], 1'b1);
        check("STATUS.BUSY_after_switch", rd_val[1], 1'b0);

        $display("========================================");
        $display("  TEST 13: CTRL read after quad switch");
        $display("========================================");
        csr_read(32'h00, rd_val);
        check("CTRL_after_quad.bit1_QUAD_ACTIVE", rd_val[1], 1'b1);
        check("CTRL_after_quad.bit0_QUAD_EN_cleared", rd_val[0], 1'b0);

        $display("========================================");
        $display("  TEST 14: CSR after quad switch");
        $display("========================================");
        csr_read(32'h0C, rd_val);
        check("QUAD_CFG_still_valid", rd_val, 32'h060638EB);

        $display("========================================");
        $display("  TEST 15: Address decode non-CSR");
        $display("========================================");
        csr_read(32'h04, rd_val);
        check("CSR_ACCESS_after_PSRAM", rd_val[2], 1'b1);

        $display("\n========================================");
        $display("--- %0d passed, %0d failed ---", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("SOME TESTS FAILED");
        $display("========================================");

        #1000; $finish;
    end

    always #(CLK_PERIOD/2) hclk = ~hclk;

endmodule
