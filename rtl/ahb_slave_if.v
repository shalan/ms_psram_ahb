// SPDX-License-Identifier: Apache-2.0
// Author: Mohamed Shalan <mshalan@aucegypt.edu>

module ahb_slave_if #(
    parameter ADDR_WIDTH = 23
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
    output reg  [31:0]               hrdata,
    output reg                       hreadyout,
    output wire [1:0]                hresp,

    output reg                       core_req_valid,
    output reg                       core_req_write,
    output reg  [ADDR_WIDTH-1:0]     core_req_addr,
    output reg  [31:0]               core_req_wdata,
    output reg  [3:0]                core_req_wstrb,
    input  wire                      core_req_ready,
    input  wire [31:0]               core_resp_rdata,
    input  wire                      core_resp_valid
);

    assign hresp = 2'b00;

    localparam [1:0]
        ST_IDLE      = 2'd0,
        ST_WR_DATA   = 2'd1,
        ST_WAIT      = 2'd2;

    reg [1:0]  state;
    reg [31:0] captured_addr;
    reg        captured_write;
    reg [2:0]  captured_size;
    reg [3:0]  byte_strobe;

    wire addr_phase = hsel && htrans[1] && hready && hreadyout;

    always @(*) begin
        case (captured_size)
            3'b000:
                case (captured_addr[1:0])
                    2'b00: byte_strobe = 4'b0001;
                    2'b01: byte_strobe = 4'b0010;
                    2'b10: byte_strobe = 4'b0100;
                    2'b11: byte_strobe = 4'b1000;
                    default: byte_strobe = 4'b0001;
                endcase
            3'b001:
                case (captured_addr[1:0])
                    2'b00: byte_strobe = 4'b0011;
                    2'b10: byte_strobe = 4'b1100;
                    default: byte_strobe = 4'b0000;
                endcase
            3'b010:
                byte_strobe = (captured_addr[1:0] == 2'b00) ? 4'b1111 : 4'b0000;
            default:
                byte_strobe = 4'b0000;
        endcase
    end

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            state           <= ST_IDLE;
            hreadyout       <= 1'b1;
            hrdata          <= 32'd0;
            core_req_valid  <= 1'b0;
            core_req_write  <= 1'b0;
            core_req_addr   <= {ADDR_WIDTH{1'b0}};
            core_req_wdata  <= 32'd0;
            core_req_wstrb  <= 4'b0000;
            captured_addr   <= 32'd0;
            captured_write  <= 1'b0;
            captured_size   <= 3'b000;
        end else begin
            case (state)
                ST_IDLE: begin
                    core_req_valid <= 1'b0;
                    if (addr_phase) begin
                        captured_addr  <= haddr;
                        captured_write <= hwrite;
                        captured_size  <= hsize;
                        hreadyout      <= 1'b0;
                        if (hwrite) begin
                            state <= ST_WR_DATA;
                        end else begin
                            core_req_valid <= 1'b1;
                            core_req_write <= 1'b0;
                            core_req_addr  <= haddr[ADDR_WIDTH-1:0];
                            core_req_wstrb <= 4'b0000;
                            state <= ST_WAIT;
                        end
                    end
                end

                ST_WR_DATA: begin
                    core_req_valid <= 1'b1;
                    core_req_write <= 1'b1;
                    core_req_addr  <= captured_addr[ADDR_WIDTH-1:0];
                    core_req_wdata <= hwdata;
                    core_req_wstrb <= byte_strobe;
                    state <= ST_WAIT;
                end

                ST_WAIT: begin
                    if (core_resp_valid) begin
                        hrdata    <= core_resp_rdata;
                        hreadyout <= 1'b1;
                        core_req_valid <= 1'b0;
                        state <= ST_IDLE;
                    end else if (core_req_ready) begin
                        core_req_valid <= 1'b0;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
