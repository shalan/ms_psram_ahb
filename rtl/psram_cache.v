// SPDX-License-Identifier: Apache-2.0
// Author: Mohamed Shalan <mshalan@aucegypt.edu>

module psram_cache #(
    parameter ADDR_WIDTH  = 23,
    parameter INDEX_BITS  = 2,
    parameter BUF_DEPTH   = 4
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

    output reg                       be_req_valid,
    output reg                       be_req_write,
    output reg  [ADDR_WIDTH-1:0]     be_req_addr,
    output reg  [31:0]               be_req_wdata,
    output reg  [3:0]                be_req_wstrb,
    input  wire                      be_req_ready,
    input  wire [31:0]               be_resp_rdata,
    input  wire                      be_resp_valid
);

    localparam CACHE_ENTRIES = 1 << INDEX_BITS;
    localparam TAG_BITS      = ADDR_WIDTH - INDEX_BITS - 2;
    localparam BUF_IDX_BITS  = $clog2(BUF_DEPTH);
    localparam BUF_CNT_BITS  = $clog2(BUF_DEPTH + 1);

    function [31:0] strb2mask;
        input [3:0] s;
        strb2mask = {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}};
    endfunction

    localparam [1:0]
        S_IDLE  = 2'd0,
        S_DRAIN = 2'd1,
        S_FETCH = 2'd2;

    reg [1:0] state;
    reg       be_sent;
    reg       drain_all;

    reg [TAG_BITS-1:0]  cache_tag   [0:CACHE_ENTRIES-1];
    reg                  cache_valid [0:CACHE_ENTRIES-1];
    reg [31:0]           cache_data  [0:CACHE_ENTRIES-1];

    reg [ADDR_WIDTH-1:0] wr_buf_addr [0:BUF_DEPTH-1];
    reg [31:0]           wr_buf_data [0:BUF_DEPTH-1];
    reg [3:0]            wr_buf_strb [0:BUF_DEPTH-1];
    reg [BUF_CNT_BITS-1:0] wr_buf_cnt;

    reg [ADDR_WIDTH-1:0] fetch_addr;

    wire [INDEX_BITS-1:0] req_idx = req_addr[INDEX_BITS+1:2];
    wire [TAG_BITS-1:0]   req_tag = req_addr[ADDR_WIDTH-1:INDEX_BITS+2];
    wire                  req_hit = cache_valid[req_idx] & (cache_tag[req_idx] == req_tag);

    wire [INDEX_BITS-1:0] fet_idx = fetch_addr[INDEX_BITS+1:2];
    wire [TAG_BITS-1:0]   fet_tag = fetch_addr[ADDR_WIDTH-1:INDEX_BITS+2];

    wire buf_empty = (wr_buf_cnt == 0);
    wire buf_full  = (wr_buf_cnt == BUF_DEPTH[BUF_CNT_BITS-1:0]);

    wire [BUF_IDX_BITS-1:0] wr_tail = wr_buf_cnt[BUF_IDX_BITS-1:0];

    assign req_ready = (state == S_IDLE) & (~req_write | ~buf_full);

    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            resp_valid   <= 1'b0;
            be_req_valid <= 1'b0;
            be_sent      <= 1'b0;
            drain_all    <= 1'b0;
            wr_buf_cnt   <= 0;
            for (i = 0; i < CACHE_ENTRIES; i = i + 1)
                cache_valid[i] <= 1'b0;
        end else begin
            resp_valid   <= 1'b0;
            be_req_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (req_valid & req_write & buf_full) begin
                        drain_all <= 1'b0;
                        be_sent   <= 1'b0;
                        state     <= S_DRAIN;
                    end else if (req_valid & req_ready) begin
                        if (req_write) begin
                            wr_buf_addr[wr_tail] <= req_addr;
                            wr_buf_data[wr_tail] <= req_wdata;
                            wr_buf_strb[wr_tail] <= req_wstrb;
                            wr_buf_cnt <= wr_buf_cnt + 1;

                            if (req_hit)
                                cache_data[req_idx] <=
                                    (req_wdata & strb2mask(req_wstrb)) |
                                    (cache_data[req_idx] & ~strb2mask(req_wstrb));

                            resp_valid <= 1'b1;
                        end else begin
                            if (req_hit) begin
                                resp_rdata <= cache_data[req_idx];
                                resp_valid <= 1'b1;
                            end else begin
                                fetch_addr <= req_addr;
                                if (buf_empty) begin
                                    be_sent <= 1'b0;
                                    state   <= S_FETCH;
                                end else begin
                                    drain_all <= 1'b1;
                                    be_sent   <= 1'b0;
                                    state     <= S_DRAIN;
                                end
                            end
                        end
                    end else if (~buf_empty) begin
                        drain_all <= 1'b0;
                        be_sent   <= 1'b0;
                        state     <= S_DRAIN;
                    end
                end

                S_DRAIN: begin
                    if (be_resp_valid) begin
                        if (wr_buf_cnt > 1) begin
                            wr_buf_addr[0] <= wr_buf_addr[1];
                            wr_buf_data[0] <= wr_buf_data[1];
                            wr_buf_strb[0] <= wr_buf_strb[1];
                        end
                        wr_buf_cnt <= wr_buf_cnt - 1;
                        be_sent <= 1'b0;

                        if (drain_all & (wr_buf_cnt > 1))
                            drain_all <= 1'b1;
                        else if (drain_all)
                            state <= S_FETCH;
                        else
                            state <= S_IDLE;
                    end else if (~be_sent & ~buf_empty & be_req_ready) begin
                        be_req_valid <= 1'b1;
                        be_req_write <= 1'b1;
                        be_req_addr  <= wr_buf_addr[0];
                        be_req_wdata <= wr_buf_data[0];
                        be_req_wstrb <= wr_buf_strb[0];
                        be_sent      <= 1'b1;
                    end
                end

                S_FETCH: begin
                    if (be_resp_valid) begin
                        cache_valid[fet_idx] <= 1'b1;
                        cache_tag[fet_idx]   <= fet_tag;
                        cache_data[fet_idx]  <= be_resp_rdata;
                        resp_rdata           <= be_resp_rdata;
                        resp_valid           <= 1'b1;
                        state                <= S_IDLE;
                    end else if (~be_sent & be_req_ready) begin
                        be_req_valid <= 1'b1;
                        be_req_write <= 1'b0;
                        be_req_addr  <= fetch_addr;
                        be_sent      <= 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
