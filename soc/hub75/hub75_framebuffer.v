/*
 * hub75_framebuffer.v
 *
 * vim: ts=4 sw=4
 *
 * Copyright (C) 2019  Sylvain Munaut <tnt@246tNt.com>
 * All rights reserved.
 *
 * LGPL v3+, see LICENSE.lgpl3
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 */

`default_nettype none

module hub75_framebuffer #(
	parameter integer N_FB     = 2,
	parameter integer N_BANKS  = 2,
	parameter integer N_ROWS   = 32,
	parameter integer N_COLS   = 64,
	parameter integer N_CHANS  = 3,
	parameter integer N_PLANES = 8,
	parameter integer BITDEPTH = 16,	// Only 16 bits supported

	// Auto-set
	parameter integer LOG_N_FB    = $clog2(N_FB),
	parameter integer LOG_N_BANKS = $clog2(N_BANKS),
	parameter integer LOG_N_ROWS  = $clog2(N_ROWS),
	parameter integer LOG_N_COLS  = $clog2(N_COLS)
)(
	// External QPI interface (clk_2x)
	output reg  [23:0] fb_addr,
	input  wire [31:0] fb_rdata,
	output wire fb_do_read,
	input  wire fb_next_word,
	input  wire fb_is_idle,
	input  wire [23:0] fb_base,

	// Read interface - Preload
	input  wire [LOG_N_FB-1:0]   rd_frame_addr,
	input  wire [LOG_N_ROWS-1:0] rd_row_addr,
	input  wire rd_row_load,
	output wire rd_row_rdy,
	input  wire rd_row_swap,

	// Read interface - Access
	output wire [(N_BANKS * N_CHANS * N_PLANES)-1:0] rd_data,
	input  wire [LOG_N_COLS-1:0] rd_col_addr,
	input  wire rd_en,

	// Clock / Reset
	input  wire clk,
	input  wire clk_2x,
	input  wire rst
);

	// Signals
	// -------

	genvar i;

	// DMA state
	localparam
		ST_IDLE = 0,
		ST_BANK_FIRST = 1,
		ST_BANK_NEXT = 2,
		ST_BURST = 3,
		ST_BURST_END = 4,
		ST_BURST_NEXT = 5,
		ST_DONE = 6;

	reg [2:0] dma_state;
	reg [2:0] dma_state_next;

	// DMA control lines
	wire dma_req;
	wire dma_done;
	wire dma_buf_swap;
	reg  dma_buf;

	// DMA counters
	reg [LOG_N_FB-1:0]    dma_frame_addr;	// just latch
	reg [LOG_N_BANKS-1:0] dma_bank_addr;	// inc
	reg [LOG_N_ROWS-1:0]  dma_row_addr;		// just latch
	reg [LOG_N_COLS-1:0]  dma_col_addr;		// inc
	reg [LOG_N_COLS:0]    dma_cnt_col;		// dec
	reg [5:0]             dma_cnt_burst;	// dec

	// Color map
	reg  [ 1:0] cm_wmsk;
	reg  [15:0] cm_nxt;
	wire [15:0] cm_in;
	wire [(N_CHANS * N_PLANES)-1:0] cm_out;

	// Line buffer
	reg  fb_next_word_r;

	reg  [LOG_N_COLS:0] lb_waddr;
	wire [(N_BANKS * N_CHANS * N_PLANES)-1:0] lb_wdata;
	reg  [N_BANKS-1:0] lb_wmsk;
	reg  lb_wen;

	// Control: clk
	reg  rdy;
	wire done;

	// Address
	reg [LOG_N_FB-1:0] rd_frame_addr_x;
	reg [LOG_N_ROWS-1:0] rd_row_addr_x;

	// Read buffer
	reg rd_buf;


	// Write data to line buffer
	// -------------------------
	// FIXME this is hardcoded ...

	// Write enable
	always @(posedge clk_2x)
	begin
		fb_next_word_r <= fb_next_word;
		lb_wen <= fb_next_word | fb_next_word_r;
	end

	// Write mask
	generate
		if (N_BANKS > 1) begin
			for (i=0; i<N_BANKS; i=i+1)
				always @(posedge clk_2x)
					if ((dma_state == ST_BANK_FIRST) || (dma_state == ST_BANK_NEXT))
						cm_wmsk[i] <= (dma_bank_addr == i);
		end else begin
			always @(posedge clk_2x)
				cm_wmsk <= 1'b1;
		end
	endgenerate

	always @(posedge clk_2x)
		lb_wmsk <= cm_wmsk;

	// Write address
	always @(posedge clk_2x)
	begin
		if (fb_next_word)
			lb_waddr <= { dma_buf, dma_col_addr };
		else
			lb_waddr <= { lb_waddr[LOG_N_COLS:1], 1'b1 };
	end

	// Color mapping
	assign cm_in = fb_next_word ? fb_rdata[15:0] : cm_nxt;

	always @(posedge clk_2x)
		cm_nxt <= fb_rdata[31:16];

	hub75_gamma #(
		.IW(5),
		.OW(N_PLANES)
	) gamma_c0_I (
		.in(cm_in[15:11]),
		.out(cm_out[2*N_PLANES+:N_PLANES]),
		.enable(1'b1),
		.clk(clk_2x)
	);

	hub75_gamma #(
		.IW(6),
		.OW(N_PLANES)
	) gamma_c1_I (
		.in(cm_in[10:5]),
		.out(cm_out[1*N_PLANES+:N_PLANES]),
		.enable(1'b1),
		.clk(clk_2x)
	);

	hub75_gamma #(
		.IW(5),
		.OW(N_PLANES)
	) gamma_c2_I (
		.in(cm_in[4:0]),
		.out(cm_out[0*N_PLANES+:N_PLANES]),
		.enable(1'b1),
		.clk(clk_2x)
	);

	assign lb_wdata = { (N_BANKS){cm_out} };


	// Control : clk_2x
	// ----------------

	// State
	always @(posedge clk_2x)
		if (rst)
			dma_state <= ST_IDLE;
		else
			dma_state <= dma_state_next;

	always @(*)
	begin
		// Default is not to move
		dma_state_next = dma_state;

		// Next
		case (dma_state)
			ST_IDLE:
				if (dma_req)
					dma_state_next = ST_BANK_FIRST;

			ST_BANK_FIRST:
				dma_state_next = ST_BURST;

			ST_BANK_NEXT:
				dma_state_next = ST_BURST;

			ST_BURST:
				if (fb_next_word & (dma_cnt_burst[5] | dma_cnt_col[LOG_N_COLS]))
					dma_state_next = ST_BURST_END;

			ST_BURST_END:
				if (fb_next_word) begin
					if (dma_cnt_col[LOG_N_COLS])
						dma_state_next = (dma_bank_addr == N_BANKS[LOG_N_BANKS-1:0]) ? ST_DONE : ST_BANK_NEXT;
					else
						dma_state_next = ST_BURST_NEXT;
				end

			ST_BURST_NEXT:
				dma_state_next = ST_BURST;

			ST_DONE:
				dma_state_next = ST_IDLE;
		endcase
	end

	// Done signals
	assign dma_done = (dma_state == ST_DONE);

	// Buffer swap
	always @(posedge clk_2x)
		if (rst)
			dma_buf <= 1'b1;
		else
			dma_buf <= dma_buf ^ dma_buf_swap;

	// Fetch address
	always @(posedge clk_2x)
		if ((dma_state == ST_BANK_FIRST) || (dma_state == ST_BANK_NEXT))
			fb_addr <= fb_base + { dma_frame_addr, dma_bank_addr, dma_row_addr, {LOG_N_COLS{1'b0}} };
		else if (dma_state == ST_BURST_NEXT)
			fb_addr <= fb_addr + 32'd64;

	// Bank address
	always @(posedge clk_2x)
		if (dma_state == ST_IDLE)
			dma_bank_addr <= 0;
		else if ((dma_state == ST_BANK_FIRST) || (dma_state == ST_BANK_NEXT))
			dma_bank_addr <= dma_bank_addr + 1;

	// Column counter
	always @(posedge clk_2x)
		if ((dma_state == ST_BANK_FIRST) || (dma_state == ST_BANK_NEXT))
			dma_cnt_col <= N_COLS - 3;
		else if (fb_next_word)
			dma_cnt_col <= dma_cnt_col - 2;

	// Column address
	always @(posedge clk_2x)
		if ((dma_state == ST_BANK_FIRST) || (dma_state == ST_BANK_NEXT))
			dma_col_addr <= 0;
		else if (fb_next_word)
			dma_col_addr <= dma_col_addr + 2;

	// Burst counter
	always @(posedge clk_2x)
		if ((dma_state == ST_BANK_FIRST) || (dma_state == ST_BANK_NEXT) || (dma_state == ST_BURST_NEXT))
			dma_cnt_burst <= 6'b011101;
		else if (fb_next_word)
			dma_cnt_burst <= dma_cnt_burst - 1;

	// Memory control
	assign fb_do_read = (dma_state == ST_BURST);


	// Clock - Crossing
	// ----------------

	xclk_strobe xclk_row_swap_I (
		.in_stb(rd_row_swap),
		.in_clk(clk),
		.out_stb(dma_buf_swap),
		.out_clk(clk_2x),
		.rst(rst)
	);

	xclk_strobe xclk_req_I (
		.in_stb(rd_row_load),
		.in_clk(clk),
		.out_stb(dma_req),
		.out_clk(clk_2x),
		.rst(rst)
	);

	xclk_strobe xclk_done_I (
		.in_stb(dma_done),
		.in_clk(clk_2x),
		.out_stb(done),
		.out_clk(clk),
		.rst(rst)
	);

	always @(posedge clk)
		if (rd_row_load) begin
			rd_row_addr_x   <= rd_row_addr;
			rd_frame_addr_x <= rd_frame_addr;
		end

	always @(posedge clk_2x)
		if (dma_req) begin
			dma_row_addr <= rd_row_addr_x;
			dma_frame_addr <= rd_frame_addr_x;
		end


	// Control: clk
	// ------------

	// Buffer swap
	always @(posedge clk)
		if (rst)
			rd_buf <= 1'b0;
		else
			rd_buf <= rd_buf ^ rd_row_swap;

	// Ready status tracking
	always @(posedge clk)
		if (rst)
			rdy <= 1'b0;
		else
			rdy <= (rdy & ~rd_row_load) | done;

	assign rd_row_rdy = rdy;


	// Line buffer
	// -----------

	hub75_linebuffer #(
		.N_WORDS(N_BANKS),
		.WORD_WIDTH(N_CHANS * N_PLANES),
		.ADDR_WIDTH(1 + LOG_N_COLS)
	) lbuf_I (
		.wr_addr(lb_waddr),
		.wr_data(lb_wdata),
		.wr_mask(lb_wmsk),
		.wr_ena(lb_wen),
		.wr_clk(clk_2x),
		.rd_addr({rd_buf, rd_col_addr}),
		.rd_data(rd_data),
		.rd_ena(rd_en),
		.rd_clk(clk)
	);

endmodule // hub75_framebuffer
