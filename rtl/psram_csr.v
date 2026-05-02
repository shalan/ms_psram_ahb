// SPDX-License-Identifier: Apache-2.0
// Author: Mohamed Shalan <mshalan@aucegypt.edu>

module psram_csr #(
    parameter [7:0] SPI_CMD_READ  = 8'h0B,
    parameter [7:0] SPI_CMD_WRITE = 8'h02,
    parameter [5:0] SPI_DMY_CLKS  = 6'd8,
    parameter [7:0] QUAD_CMD_READ  = 8'hEB,
    parameter [7:0] QUAD_CMD_WRITE = 8'h38,
    parameter [5:0] QUAD_DMY_CLKS  = 6'd6,
    parameter [7:0] QUAD_ENTER_CMD = 8'h35,
    parameter [5:0] QUAD_ADDR_CLKS = 6'd6
)(
    input  wire                      hclk,
    input  wire                      hresetn,

    input  wire                      hsel,
    input  wire [31:0]               haddr,
    input  wire [1:0]                htrans,
    input  wire                      hwrite,
    input  wire [2:0]                hsize,
    input  wire [31:0]               hwdata,
    input  wire                      hready,
    output reg  [31:0]               hrdata,
    output reg                       hreadyout,

    output reg  [7:0]                csr_spi_cmd_read,
    output reg  [7:0]                csr_spi_cmd_write,
    output reg  [5:0]                csr_spi_dmy_clks,
    output reg  [7:0]                csr_quad_cmd_read,
    output reg  [7:0]                csr_quad_cmd_write,
    output reg  [5:0]                csr_quad_dmy_clks,
    output reg  [7:0]                csr_quad_enter_cmd,
    output reg  [5:0]                csr_quad_addr_clks,
    output reg  [31:0]               csr_quad_switch_dly,
    output reg                       csr_quad_en,

    input  wire                      init_done,
    input  wire                      busy,
    input  wire                      quad_active
);

    localparam [2:0]
        ST_IDLE    = 3'd0,
        ST_WR_DATA = 3'd1,
        ST_RD_DATA = 3'd2;

    reg [2:0]  state;
    reg [3:0]  csr_idx;

    wire addr_phase = hsel & htrans[1] & hready & hreadyout;
    wire [3:0] req_idx = haddr[5:2];

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            state              <= ST_IDLE;
            hreadyout          <= 1'b1;
            hrdata             <= 32'd0;
            csr_idx            <= 4'd0;
            csr_quad_en        <= 1'b0;
            csr_spi_cmd_read   <= SPI_CMD_READ;
            csr_spi_cmd_write  <= SPI_CMD_WRITE;
            csr_spi_dmy_clks   <= SPI_DMY_CLKS;
            csr_quad_cmd_read  <= QUAD_CMD_READ;
            csr_quad_cmd_write <= QUAD_CMD_WRITE;
            csr_quad_dmy_clks  <= QUAD_DMY_CLKS;
            csr_quad_enter_cmd <= QUAD_ENTER_CMD;
            csr_quad_addr_clks <= QUAD_ADDR_CLKS;
            csr_quad_switch_dly<= 32'd0;
        end else begin
            csr_quad_en <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (addr_phase) begin
                        csr_idx   <= req_idx;
                        hreadyout <= 1'b0;
                        if (hwrite)
                            state <= ST_WR_DATA;
                        else
                            state <= ST_RD_DATA;
                    end
                end

                ST_WR_DATA: begin
                    hreadyout <= 1'b1;
                    state     <= ST_IDLE;
                    case (csr_idx)
                        4'd0: csr_quad_en <= hwdata[0];
                        4'd2: begin
                            csr_spi_cmd_read  <= hwdata[7:0];
                            csr_spi_cmd_write <= hwdata[15:8];
                            csr_spi_dmy_clks  <= hwdata[21:16];
                        end
                        4'd3: begin
                            csr_quad_cmd_read  <= hwdata[7:0];
                            csr_quad_cmd_write <= hwdata[15:8];
                            csr_quad_dmy_clks  <= hwdata[21:16];
                            csr_quad_addr_clks <= hwdata[29:24];
                        end
                        4'd4: begin
                            csr_quad_enter_cmd <= hwdata[7:0];
                        end
                        4'd5: begin
                            csr_quad_switch_dly <= hwdata[31:0];
                        end
                        default: ;
                    endcase
                end

                ST_RD_DATA: begin
                    hreadyout <= 1'b1;
                    state     <= ST_IDLE;
                    case (csr_idx)
                        4'd0: hrdata <= {30'd0, quad_active, 1'b0};
                        4'd1: hrdata <= {29'd0, quad_active, busy, init_done};
                        4'd2: hrdata <= {10'd0, csr_spi_dmy_clks, csr_spi_cmd_write, csr_spi_cmd_read};
                        4'd3: hrdata <= {2'd0, csr_quad_addr_clks, 2'd0, csr_quad_dmy_clks, csr_quad_cmd_write, csr_quad_cmd_read};
                        4'd4: hrdata <= {24'd0, csr_quad_enter_cmd};
                        4'd5: hrdata <= csr_quad_switch_dly;
                        default: hrdata <= 32'd0;
                    endcase
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
