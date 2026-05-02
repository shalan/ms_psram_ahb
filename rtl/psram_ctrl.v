// SPDX-License-Identifier: Apache-2.0
// Author: Mohamed Shalan <mshalan@aucegypt.edu>

module psram_ctrl #(
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
    parameter [5:0] QUAD_ADDR_CLKS = 6'd6
)(
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire                      req_valid,
    input  wire                      req_write,
    input  wire [ADDR_WIDTH-1:0]     req_addr,
    input  wire [31:0]               req_wdata,
    input  wire [3:0]                req_wstrb,
    output wire                      req_ready,
    output reg  [31:0]               resp_rdata,
    output reg                       resp_valid,

    output reg                       spi_cs_n,
    output reg                       spi_sclk,
    output wire [3:0]                spi_sio_o,
    output wire [3:0]                spi_sio_oe,
    input  wire [3:0]                spi_sio_i,

    input  wire [7:0]                csr_spi_cmd_read,
    input  wire [7:0]                csr_spi_cmd_write,
    input  wire [5:0]                csr_spi_dmy_clks,
    input  wire [7:0]                csr_quad_cmd_read,
    input  wire [7:0]                csr_quad_cmd_write,
    input  wire [5:0]                csr_quad_dmy_clks,
    input  wire [7:0]                csr_quad_enter_cmd,
    input  wire [5:0]                csr_quad_addr_clks,
    input  wire [31:0]               csr_quad_switch_dly,
    input  wire                      csr_quad_en,

    output wire                      init_done,
    output wire                      busy,
    output wire                      quad_active
);

    function [31:0] bswap;
        input [31:0] d;
        bswap = {d[7:0], d[15:8], d[23:16], d[31:24]};
    endfunction

    function [31:0] strb2mask;
        input [3:0] s;
        strb2mask = {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}};
    endfunction

    localparam [7:0] CMD_RST_EN = 8'h66;
    localparam [7:0] CMD_RST    = 8'h99;

    localparam [5:0] ADDR_PAD = 6'd24 - SPI_ADDR_BITS[5:0];

    localparam [3:0]
        S_INIT_WAIT = 4'd0,
        S_CMD       = 4'd1,
        S_ADDR      = 4'd2,
        S_DUMMY     = 4'd3,
        S_DATA      = 4'd4,
        S_DONE      = 4'd5,
        S_INIT_DLY  = 4'd6,
        S_IDLE      = 4'd7,
        S_RMW       = 4'd8,
        S_QUAD_CMD  = 4'd9,
        S_QUAD_DLY  = 4'd10;

    reg [3:0]  state;
    reg [31:0] shift_reg;
    reg [5:0]  sclk_cnt;
    reg [5:0]  phase_total;
    reg        phase_rd;
    reg        phase_quad;
    reg        shifting;
    reg [15:0] clk_cnt;
    reg [31:0] timer;
    reg [1:0]  init_step;
    reg        is_init;
    reg        is_rmw;
    reg        rmw_phase;
    reg [31:0] rmw_rdata;
    reg [31:0] rmw_merged;
    reg [23:0] txn_addr;
    reg [31:0] txn_wdata;
    reg [3:0]  txn_wstrb;
    reg        txn_is_wr;
    reg        quad_active_reg;

    wire clk_div_max = (clk_cnt == SPI_CLK_DIV[15:0] - 16'd1);
    wire phase_done  = shifting && clk_div_max && spi_sclk && (sclk_cnt == phase_total);

    wire [7:0] cur_cmd_read  = quad_active_reg ? csr_quad_cmd_read  : csr_spi_cmd_read;
    wire [7:0] cur_cmd_write = quad_active_reg ? csr_quad_cmd_write : csr_spi_cmd_write;
    wire [5:0] cur_addr_clks = quad_active_reg ? csr_quad_addr_clks : SPI_ADDR_BITS[5:0];
    wire [5:0] cur_dmy_clks  = quad_active_reg ? csr_quad_dmy_clks  : csr_spi_dmy_clks;
    wire [5:0] cur_data_clks = quad_active_reg ? 6'd8                : 6'd32;
    wire       cur_phase_quad = quad_active_reg;

    assign req_ready     = (state == S_IDLE);
    assign init_done     = ~is_init;
    assign busy          = (state != S_IDLE) && ~is_init;
    assign quad_active   = quad_active_reg;

    assign spi_sio_o  = phase_quad ? shift_reg[31:28] : {3'b0, shift_reg[31]};
    assign spi_sio_oe = (phase_rd || !shifting) ? 4'b0000 :
                        phase_quad ? 4'b1111 : 4'b0001;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_INIT_WAIT;
            shifting        <= 1'b0;
            spi_cs_n        <= 1'b1;
            spi_sclk        <= 1'b0;
            clk_cnt         <= 16'd0;
            shift_reg       <= 32'd0;
            sclk_cnt        <= 6'd0;
            phase_total     <= 6'd0;
            phase_rd        <= 1'b0;
            phase_quad      <= 1'b0;
            timer           <= 32'd0;
            init_step       <= 2'd0;
            is_init         <= 1'b0;
            is_rmw          <= 1'b0;
            rmw_phase       <= 1'b0;
            rmw_rdata       <= 32'd0;
            rmw_merged      <= 32'd0;
            txn_addr        <= 24'd0;
            txn_wdata       <= 32'd0;
            txn_wstrb       <= 4'd0;
            txn_is_wr       <= 1'b0;
            resp_valid      <= 1'b0;
            resp_rdata      <= 32'd0;
            quad_active_reg <= 1'b0;
        end else begin
            resp_valid <= 1'b0;

            if (shifting) begin
                if (clk_div_max) begin
                    clk_cnt <= 16'd0;
                    if (!spi_sclk) begin
                        spi_sclk <= 1'b1;
                        if (phase_rd) begin
                            if (phase_quad)
                                shift_reg <= {shift_reg[27:0], spi_sio_i};
                            else
                                shift_reg <= {shift_reg[30:0], spi_sio_i[1]};
                        end
                        sclk_cnt <= sclk_cnt + 6'd1;
                    end else begin
                        spi_sclk <= 1'b0;
                        if (!phase_rd && (sclk_cnt < phase_total)) begin
                            if (phase_quad)
                                shift_reg <= {shift_reg[27:0], 4'b0};
                            else
                                shift_reg <= {shift_reg[30:0], 1'b0};
                        end
                    end
                end else begin
                    clk_cnt <= clk_cnt + 16'd1;
                end
            end else begin
                clk_cnt  <= 16'd0;
                spi_sclk <= 1'b0;
            end

            case (state)
                S_INIT_WAIT: begin
                    if (timer == INIT_DLY) begin
                        timer     <= 32'd0;
                        init_step <= 2'd0;
                        is_init   <= 1'b1;
                        spi_cs_n  <= 1'b0;
                        shifting  <= 1'b1;
                        sclk_cnt  <= 6'd0;
                        phase_total <= 6'd8;
                        phase_rd  <= 1'b0;
                        phase_quad <= 1'b0;
                        shift_reg <= {CMD_RST_EN, 24'd0};
                        state     <= S_CMD;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                S_CMD: begin
                    if (phase_done) begin
                        if (is_init) begin
                            shifting <= 1'b0;
                            spi_cs_n <= 1'b1;
                            timer    <= 32'd0;
                            state    <= S_INIT_DLY;
                        end else begin
                            sclk_cnt    <= 6'd0;
                            phase_total <= cur_addr_clks;
                            phase_rd    <= 1'b0;
                            phase_quad  <= cur_phase_quad;
                            shift_reg   <= ({txn_addr, 8'd0}) << ADDR_PAD;
                            state       <= S_ADDR;
                        end
                    end
                end

                S_ADDR: begin
                    if (phase_done) begin
                        if (txn_is_wr && !is_rmw) begin
                            sclk_cnt    <= 6'd0;
                            phase_total <= cur_data_clks;
                            phase_rd    <= 1'b0;
                            phase_quad  <= cur_phase_quad;
                            shift_reg   <= bswap(txn_wdata);
                            state       <= S_DATA;
                        end else if (is_rmw && rmw_phase) begin
                            sclk_cnt    <= 6'd0;
                            phase_total <= cur_data_clks;
                            phase_rd    <= 1'b0;
                            phase_quad  <= cur_phase_quad;
                            shift_reg   <= rmw_merged;
                            state       <= S_DATA;
                        end else begin
                            sclk_cnt    <= 6'd0;
                            phase_rd    <= 1'b0;
                            phase_quad  <= cur_phase_quad;
                            shift_reg   <= 32'd0;
                            if (cur_dmy_clks == 6'd0) begin
                                phase_total <= cur_data_clks;
                                phase_rd    <= 1'b1;
                                state       <= S_DATA;
                            end else begin
                                phase_total <= cur_dmy_clks;
                                state       <= S_DUMMY;
                            end
                        end
                    end
                end

                S_DUMMY: begin
                    if (phase_done) begin
                        sclk_cnt    <= 6'd0;
                        phase_total <= cur_data_clks;
                        phase_rd    <= 1'b1;
                        phase_quad  <= cur_phase_quad;
                        shift_reg   <= 32'd0;
                        state       <= S_DATA;
                    end
                end

                S_DATA: begin
                    if (phase_done) begin
                        shifting <= 1'b0;
                        spi_cs_n <= 1'b1;
                        state    <= S_DONE;
                    end
                end

                S_DONE: begin
                    if (is_init) begin
                        is_init <= 1'b0;
                        state   <= S_IDLE;
                    end else if (is_rmw && !rmw_phase) begin
                        rmw_rdata <= bswap(shift_reg);
                        state     <= S_RMW;
                    end else begin
                        if (!txn_is_wr)
                            resp_rdata <= bswap(shift_reg);
                        resp_valid <= 1'b1;
                        is_rmw     <= 1'b0;
                        rmw_phase  <= 1'b0;
                        state      <= S_IDLE;
                    end
                end

                S_RMW: begin
                    rmw_merged <= bswap((rmw_rdata & ~strb2mask(txn_wstrb)) |
                                        (txn_wdata  &  strb2mask(txn_wstrb)));
                    rmw_phase  <= 1'b1;
                    spi_cs_n   <= 1'b0;
                    shifting   <= 1'b1;
                    sclk_cnt   <= 6'd0;
                    phase_total <= 6'd8;
                    phase_rd   <= 1'b0;
                    phase_quad <= 1'b0;
                    shift_reg  <= {cur_cmd_write, 24'd0};
                    state      <= S_CMD;
                end

                S_INIT_DLY: begin
                    if (timer == RST_DLY) begin
                        timer <= 32'd0;
                        if (init_step == 2'd0) begin
                            init_step   <= 2'd1;
                            spi_cs_n    <= 1'b0;
                            shifting    <= 1'b1;
                            sclk_cnt    <= 6'd0;
                            phase_total <= 6'd8;
                            phase_rd    <= 1'b0;
                            phase_quad  <= 1'b0;
                            shift_reg   <= {CMD_RST, 24'd0};
                            state       <= S_CMD;
                        end else begin
                            is_init <= 1'b0;
                            state   <= S_IDLE;
                        end
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                S_QUAD_CMD: begin
                    if (phase_done) begin
                        shifting <= 1'b0;
                        spi_cs_n <= 1'b1;
                        timer    <= 32'd0;
                        state    <= S_QUAD_DLY;
                    end
                end

                S_QUAD_DLY: begin
                    if (timer >= csr_quad_switch_dly) begin
                        quad_active_reg <= 1'b1;
                        state           <= S_IDLE;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                S_IDLE: begin
                    if (csr_quad_en && !quad_active_reg) begin
                        spi_cs_n    <= 1'b0;
                        shifting    <= 1'b1;
                        sclk_cnt    <= 6'd0;
                        phase_total <= 6'd8;
                        phase_rd    <= 1'b0;
                        phase_quad  <= 1'b0;
                        shift_reg   <= {csr_quad_enter_cmd, 24'd0};
                        state       <= S_QUAD_CMD;
                    end else if (req_valid) begin
                        txn_is_wr <= req_write;
                        txn_addr  <= {req_addr[ADDR_WIDTH-1:2], 2'b00};
                        txn_wdata <= req_wdata;
                        txn_wstrb <= req_wstrb;

                        if (req_write && (req_wstrb != 4'b1111)) begin
                            is_rmw    <= 1'b1;
                            rmw_phase <= 1'b0;
                        end else begin
                            is_rmw <= 1'b0;
                        end

                        spi_cs_n    <= 1'b0;
                        shifting    <= 1'b1;
                        sclk_cnt    <= 6'd0;
                        phase_total <= 6'd8;
                        phase_rd    <= 1'b0;
                        phase_quad  <= 1'b0;

                        if (req_write && (req_wstrb == 4'b1111))
                            shift_reg <= {cur_cmd_write, 24'd0};
                        else
                            shift_reg <= {cur_cmd_read, 24'd0};

                        state <= S_CMD;
                    end
                end

                default: state <= S_INIT_WAIT;
            endcase
        end
    end

endmodule
