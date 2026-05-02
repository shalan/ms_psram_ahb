// SPDX-License-Identifier: Apache-2.0
// Author: Mohamed Shalan <mshalan@aucegypt.edu>

`timescale 1ns/1ps

module tb_psram_ahb_gls;

    parameter CLK_PERIOD  = 12;

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

    ms_psram_ahb dut (
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
                $display("  [PSRAM] READ preload mem[0x%06h]=0x%02h ...", addr_reg, data_sr);
            end
            bit_cnt = bit_cnt + 1;
        end
    end

    always @(negedge spi_sclk) begin
        if (!spi_cs_n && cmd_reg == 8'h0B && bit_cnt >= 40) begin
            sio1_out = data_sr[7];
            sio1_en  = 1;
            if (bit_cnt == 40)
                $display("  [PSRAM] READ output bit_cnt=%0d sr[7]=%b data_sr=0x%02h", bit_cnt, data_sr[7], data_sr);
            if ((bit_cnt - 40) % 8 == 7) begin
                data_sr = psram[addr_reg + (bit_cnt - 39) / 8];
                $display("  [PSRAM] READ load next byte mem[0x%06h]=0x%02h", addr_reg + (bit_cnt-39)/8, psram[addr_reg + (bit_cnt-39)/8]);
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
            hsel   <= 1'b1; haddr <= addr; htrans <= 2'b10;
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
        repeat (8000) @(posedge hclk);

        $display("--- GLS TEST 1: Write 0xDEADBEEF to addr 0x00 ---");
        ahb_write(32'h0, 32'hDEADBEEF, 3'b010);

        $display("--- GLS TEST 2: Read back addr 0x00 ---");
        ahb_read(32'h0, 3'b010, rd_val);
        if (rd_val === 32'hDEADBEEF) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xDEADBEEF)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- GLS TEST 3: Write 0x12345678 to addr 0x04 ---");
        ahb_write(32'h4, 32'h12345678, 3'b010);

        $display("--- GLS TEST 4: Read back addr 0x04 ---");
        ahb_read(32'h4, 3'b010, rd_val);
        if (rd_val === 32'h12345678) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0x12345678)", rd_val); fail_count = fail_count + 1;
        end

        $display("--- GLS TEST 5: Re-read addr 0x00 ---");
        ahb_read(32'h0, 3'b010, rd_val);
        if (rd_val === 32'hDEADBEEF) begin
            $display("  PASS: 0x%08h", rd_val); pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: 0x%08h (exp 0xDEADBEEF)", rd_val); fail_count = fail_count + 1;
        end

        $display("\n--- GLS: %0d passed, %0d failed ---", pass_count, fail_count);
        if (fail_count == 0) $display("ALL GLS TESTS PASSED");
        else                 $display("SOME GLS TESTS FAILED");

        #1000; $finish;
    end

    always #(CLK_PERIOD/2) hclk = ~hclk;

endmodule
