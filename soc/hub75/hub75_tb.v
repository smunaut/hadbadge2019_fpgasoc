/*
 * hub75_tb.v
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

module hub75_tb;


	// Signals
	// -------

	// Hub75
	wire hub75_addr_inc;
	wire hub75_addr_rst;
	wire [4:0] hub75_addr;
	wire [5:0] hub75_data;
	wire hub75_clk;
	wire hub75_le;
	wire hub75_blank;

	// Memory interface
	wire [23:0] fb_addr;
	wire [31:0] fb_rdata;
	wire fb_do_read;
	wire fb_next_word;
	wire fb_is_idle;

	// Frame buffer swap
	wire frame_swap;
	wire frame_rdy;

	// Clock / Reset
	reg  clk_1x = 0;
	reg  clk_2x = 0;
	reg  rst = 1;


	// Testbench
	// ---------

	// Setup recording
	initial begin
		$dumpfile("hub75_tb.vcd");
		$dumpvars(0,hub75_tb);
	end

	// Reset pulse
	initial begin
		# 200 rst = 0;
		# 1000000 $finish;
	end

	// Clocks
	always #20 clk_1x = !clk_1x;
	always #10 clk_2x = !clk_2x;


	// DUT
	// ---

	hub75_top #(
		.N_BANKS(2),
		.N_ROWS(32),
		.N_COLS(96),
		.N_CHANS(3),
		.N_PLANES(8),
		.BITDEPTH(24),
		.PHY_N(1),
		.PHY_DDR(0),
		.PHY_AIR(0),
		.PANEL_INIT("NONE"),
		.SCAN_MODE("ZIGZAG")
	) dut_I (
		.hub75_addr_inc(hub75_addr_inc),
		.hub75_addr_rst(hub75_addr_rst),
		.hub75_addr(hub75_addr),
		.hub75_data(hub75_data),
		.hub75_clk(hub75_clk),
		.hub75_le(hub75_le),
		.hub75_blank(hub75_blank),
		.fb_addr(fb_addr),
		.fb_rdata(fb_rdata),
		.fb_do_read(fb_do_read),
		.fb_next_word(fb_next_word),
		.fb_is_idle(fb_is_idle),
		.frame_swap(frame_swap),
		.frame_rdy(frame_rdy),
		.ctrl_run(1'b1),
		.cfg_pre_latch_len(8'h00),
		.cfg_latch_len(8'h00),
		.cfg_post_latch_len(8'h00),
		.cfg_bcm_bit_len(8'h03),
		.clk(clk_1x),
		.clk_2x(clk_2x),
		.rst(rst)
	);


	// Memory controller
	// -----------------

	wire [15:0] spi_io_i;
	wire [15:0] spi_io_o;
	wire [ 7:0] spi_io_t;
	wire [1:0] spi_sck_o;
	wire spi_cs_o;

	qpimem_iface_2x2w mem_I (
		.spi_io_i(spi_io_i),
		.spi_io_o(spi_io_o),
		.spi_io_t(spi_io_t),
		.spi_sck_o(spi_sck_o),
		.spi_cs_o(spi_cs_o),
		.qpi_do_read(fb_do_read),
		.qpi_do_write(1'b0),
		.qpi_addr(fb_addr),
		.qpi_is_idle(fb_is_idle),
		.qpi_wdata(32'h00000000),
		.qpi_rdata(fb_rdata),
		.qpi_next_word(fb_next_word),
		.bus_addr(4'h0),
		.bus_wdata(32'h00000000),
		.bus_rdata(),
		.bus_cyc(1'b0),
		.bus_ack(),
		.bus_we(1'b0),
		.clk(clk_2x),
		.rst(rst)
	);


	// Control
	// -------

	assign frame_swap = 1'b0;

endmodule // hub75_tb
