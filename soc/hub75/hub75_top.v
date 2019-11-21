/*
 * hub75_top.v
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

module hub75_top #(
	parameter integer N_FB     = 2,		// # of frame buffers
	parameter integer N_BANKS  = 2,		// # of parallel readout rows
	parameter integer N_ROWS   = 32,	// # of rows (must be power of 2!!!)
	parameter integer N_COLS   = 64,	// # of columns
	parameter integer N_CHANS  = 3,		// # of data channel
	parameter integer N_PLANES = 8,		// # bitplanes
	parameter integer BITDEPTH = 24,	// # bits per color
	parameter integer PHY_N    = 1,		// # of PHY in //
	parameter integer PHY_DDR  = 0,		// PHY DDR data output
	parameter integer PHY_AIR  = 0,		// PHY Address Inc/Reset

	parameter PANEL_INIT = "NONE",		// 'NONE' or 'FM6126'
	parameter SCAN_MODE = "ZIGZAG",		// 'LINEAR' or 'ZIGZAG'

	// Auto-set
	parameter integer SDW         = N_BANKS * N_CHANS,
	parameter integer ESDW        = SDW / (PHY_DDR ? 2 : 1),
	parameter integer LOG_N_FB    = $clog2(N_FB),
	parameter integer LOG_N_BANKS = $clog2(N_BANKS),
	parameter integer LOG_N_ROWS  = $clog2(N_ROWS),
	parameter integer LOG_N_COLS  = $clog2(N_COLS)
)(
	// Hub75 interface pads
	output wire [PHY_N-1:0] hub75_addr_inc,
	output wire [PHY_N-1:0] hub75_addr_rst,
	output wire [(PHY_N*LOG_N_ROWS)-1:0] hub75_addr,
	output wire [ESDW-1 :0] hub75_data,
	output wire [PHY_N-1:0] hub75_clk,
	output wire [PHY_N-1:0] hub75_le,
	output wire [PHY_N-1:0] hub75_blank,

	// Frame Buffer
		// External QPI interface (clk_2x)
	output wire [23:0] fb_addr,
	input  wire [31:0] fb_rdata,
	output wire fb_do_read,
	input  wire fb_next_word,
	input  wire fb_is_idle,

		// Frame buffer selection
	input  wire [LOG_N_FB-1:0] frame_req,
	output wire [LOG_N_FB-1:0] frame_cur,
	output reg  frame_start,

	// Control / Config
	input  wire ctrl_run,

	input  wire [7:0] cfg_pre_latch_len,
	input  wire [7:0] cfg_latch_len,
	input  wire [7:0] cfg_post_latch_len,
	input  wire [7:0] cfg_bcm_bit_len,

	input  wire [23:0] cfg_fb_base,

	// Clock / Reset
	input  wire clk,
	input  wire clk_2x,
	input  wire rst
);

	// Signals
	// -------

	// Frame swap logic
	reg [LOG_N_FB-1:0] fbr_frame_addr;

	// PHY interface
	wire phy_addr_inc;
	wire phy_addr_rst;
	wire [LOG_N_ROWS-1:0] phy_addr;
	wire [SDW-1:0] phy_data;
	wire phy_clk;
	wire phy_le;
	wire phy_blank;

	wire phz_addr_inc;
	wire phz_addr_rst;
	wire [LOG_N_ROWS-1:0] phz_addr;
	wire [SDW-1:0] phz_data;
	wire phz_clk;
	wire phz_le;
	wire phz_blank;

	// Frame Buffer access
		// Read - Back Buffer loading
	wire [LOG_N_ROWS-1:0] fbr_row_addr;
	wire fbr_row_load;
	wire fbr_row_rdy;
	wire fbr_row_swap;

		// Read - Front Buffer access
	wire [(N_BANKS*N_CHANS*N_PLANES)-1:0] fbr_data;
	wire [LOG_N_COLS-1:0] fbr_col_addr;
	wire fbr_rden;

	// Scanning
	wire scan_go;
	wire scan_rdy;

	// Binary Code Modulator
	wire [LOG_N_ROWS-1:0] bcm_row;
	wire bcm_row_first;
	wire bcm_go;
	wire bcm_rdy, bcm_rdz;

	// Shifter
	wire [N_PLANES-1:0] shift_plane;
	wire shift_go;
	wire shift_rdy;

	// Blanking control
	wire [N_PLANES-1:0] blank_plane;
	wire blank_go;
	wire blank_rdy;


	// Sub-blocks
	// ----------

	// Synchronized frame swap logic
	assign scan_go = scan_rdy & ctrl_run;

	always @(posedge clk)
	begin
		frame_start <= scan_go;
		fbr_frame_addr <= frame_req;
	end

	assign frame_cur = fbr_frame_addr;


	// The signal direction usage legend to the right of the modules has the
	// following structure:
	// * Signal direction -> (output from the module)
	// * Signal direction <- (input to the module)
	// * top: signal is connected to top and exposed to the world
	// * pad: signal is a gpio pad id the direction indicates if the pad is an
	//        input (<-), output (->) or bidir (<->)
	// * local: signal is conneted to some local module logic
	// * hub75_*: signal is connected to the module hub75_*

	// Frame Buffer
	hub75_framebuffer #(
		.N_FB(N_FB),
		.N_BANKS(N_BANKS),
		.N_ROWS(N_ROWS),
		.N_COLS(N_COLS),
		.N_CHANS(N_CHANS),
		.N_PLANES(N_PLANES),
		.BITDEPTH(BITDEPTH)
	) fb_I (
		.fb_addr(fb_addr),				// -> top
		.fb_rdata(fb_rdata),			// <- top
		.fb_do_read(fb_do_read),		// -> top
		.fb_next_word(fb_next_word),	// <- top
		.fb_is_idle(fb_is_idle),		// <- top
		.fb_base(cfg_fb_base),			// <- top
		.rd_frame_addr(fbr_frame_addr), // <- local
		.rd_row_addr(fbr_row_addr),		// <- hub75_scan
		.rd_row_load(fbr_row_load),		// <- hub75_scan
		.rd_row_rdy(fbr_row_rdy),		// -> hub75_scan
		.rd_row_swap(fbr_row_swap),		// <- hub75_scan
		.rd_data(fbr_data),				// -> hub75_shift
		.rd_col_addr(fbr_col_addr),		// <- hub75_shift
		.rd_en(fbr_rden),				// <- hub75_shift
		.clk(clk),						// <- top
		.clk_2x(clk_2x),				// <- top
		.rst(rst)						// <- top
	);

	// Scan
	hub75_scan #(
		.N_ROWS(N_ROWS),
		.SCAN_MODE(SCAN_MODE)
	) scan_I (
		.bcm_row(bcm_row),				// -> hub75_bcm
		.bcm_row_first(bcm_row_first),	// -> hub75_bcm
		.bcm_go(bcm_go),				// -> hub75_bcm
		.bcm_rdy(bcm_rdz),				// <- hub75_bcm
		.fb_row_addr(fbr_row_addr),		// -> hub75_framebuffer
		.fb_row_load(fbr_row_load),		// -> hub75_framebuffer
		.fb_row_rdy(fbr_row_rdy),		// <- hub75_framebuffer
		.fb_row_swap(fbr_row_swap),		// -> hub75_framebuffer
		.ctrl_go(scan_go),				// <- local
		.ctrl_rdy(scan_rdy),			// -> local
		.clk(clk),						// <- top
		.rst(rst)						// <- top
	);

	// Binary Code Modulator control
	hub75_bcm #(
		.N_PLANES(N_PLANES)
	) bcm_I (
		.phy_addr_inc(phy_addr_inc),	// -> hub75_phy
		.phy_addr_rst(phy_addr_rst),	// -> hub75_phy
		.phy_addr(phy_addr),			// -> hub75_phy
		.phy_le(phy_le),				// -> hub75_phy
		.shift_plane(shift_plane),		// -> hub75_shift
		.shift_go(shift_go),			// -> hub75_shift
		.shift_rdy(shift_rdy),			// <- hub75_shift
		.blank_plane(blank_plane),		// -> hub75_blanking
		.blank_go(blank_go),			// -> hub75_blanking
		.blank_rdy(blank_rdy),			// <- hub75_blanking
		.ctrl_row(bcm_row),				// <- hub75_scan
		.ctrl_row_first(bcm_row_first),	// <- hub75_scan
		.ctrl_go(bcm_go),				// <- hub75_scan
		.ctrl_rdy(bcm_rdy),				// -> hub75_scan
		.cfg_pre_latch_len(cfg_pre_latch_len),		// <- top
		.cfg_latch_len(cfg_latch_len),				// <- top
		.cfg_post_latch_len(cfg_post_latch_len),	// <- top
		.clk(clk),						// <- top
		.rst(rst)						// <- top
	);

	// Shifter
	hub75_shift #(
		.N_BANKS(N_BANKS),
		.N_COLS(N_COLS),
		.N_CHANS(N_CHANS),
		.N_PLANES(N_PLANES)
	) shift_I (
		.phy_data(phy_data),			// -> hub75_phy
		.phy_clk(phy_clk),				// -> hub75_phy
		.ram_data(fbr_data),			// <- hub75_framebuffer
		.ram_col_addr(fbr_col_addr),	// -> hub75_framebuffer
		.ram_rden(fbr_rden),			// -> hub75_framebuffer
		.ctrl_plane(shift_plane),		// <- hub75_bcm
		.ctrl_go(shift_go),				// <- hub75_bcm
		.ctrl_rdy(shift_rdy),			// -> hub75_bcm
		.clk(clk),						// <- top
		.rst(rst)						// <- top
	);

	// Blanking control
	hub75_blanking #(
		.N_PLANES(N_PLANES)
	) blank_I (
		.phy_blank(phy_blank),			// -> hub75_phy
		.ctrl_plane(blank_plane),		// <- hub75_bcm
		.ctrl_go(blank_go),				// <- hub75_bcm
		.ctrl_rdy(blank_rdy),			// -> hub75_bcm
		.cfg_bcm_bit_len(cfg_bcm_bit_len),	// <- top
		.clk(clk),						// <- top
		.rst(rst)						// <- top
	);

	// Init injector
	generate
		if (PANEL_INIT == "NONE") begin

			// Direct PHY connection
			assign phz_addr_inc	= phy_addr_inc;
			assign phz_addr_rst	= phy_addr_rst;
			assign phz_addr		= phy_addr;
			assign phz_data		= phy_data;
			assign phz_clk		= phy_clk;
			assign phz_le		= phy_le;
			assign phz_blank	= phy_blank;

			// No gating
			assign bcm_rdz = bcm_rdy;

		end else begin

			hub75_init_inject #(
				.N_BANKS(N_BANKS),
				.N_ROWS(N_ROWS),
				.N_COLS(N_COLS),
				.N_CHANS(N_CHANS)
			) init_I (
				.phy_in_addr_inc(phy_addr_inc),
				.phy_in_addr_rst(phy_addr_rst),
				.phy_in_addr(phy_addr),
				.phy_in_data(phy_data),
				.phy_in_clk(phy_clk),
				.phy_in_le(phy_le),
				.phy_in_blank(phy_blank),
				.phy_out_addr_inc(phz_addr_inc),
				.phy_out_addr_rst(phz_addr_rst),
				.phy_out_addr(phz_addr),
				.phy_out_data(phz_data),
				.phy_out_clk(phz_clk),
				.phy_out_le(phz_le),
				.phy_out_blank(phz_blank),
				.init_req(1'b1),
				.scan_go_in(scan_go),
				.bcm_rdy_in(bcm_rdy),
				.bcm_rdy_out(bcm_rdz),
				.shift_rdy_in(shift_rdy),
				.blank_rdy_in(blank_rdy),
				.clk(clk),
				.rst(rst)
			);

		end
	endgenerate

	// Physical layer control
	generate
		if (PHY_DDR == 0)
			hub75_phy #(
				.N_BANKS(N_BANKS),
				.N_ROWS(N_ROWS),
				.N_CHANS(N_CHANS),
				.PHY_N(PHY_N),
				.PHY_AIR(PHY_AIR)
			) phy_I (
				.hub75_addr_inc(hub75_addr_inc),// -> pad
				.hub75_addr_rst(hub75_addr_rst),// -> pad
				.hub75_addr(hub75_addr),		// -> pad
				.hub75_data(hub75_data),		// -> pad
				.hub75_clk(hub75_clk),			// -> pad
				.hub75_le(hub75_le),			// -> pad
				.hub75_blank(hub75_blank),		// -> pad
				.phy_addr_inc(phz_addr_inc),	// <- hub75_bcm
				.phy_addr_rst(phz_addr_rst),	// <- hub75_bcm
				.phy_addr(phz_addr),			// <- hub75_bcm
				.phy_data(phz_data),			// <- hub75_shift
				.phy_clk(phz_clk),				// <- hub75_shift
				.phy_le(phz_le),				// <- hub75_bcm
				.phy_blank(phz_blank),			// <- hub75_blanking
				.clk(clk),						// <- top
				.rst(rst)						// <- top
			);
		else
			hub75_phy_ddr #(
				.N_BANKS(N_BANKS),
				.N_ROWS(N_ROWS),
				.N_CHANS(N_CHANS),
				.PHY_N(PHY_N),
				.PHY_DDR(PHY_DDR),
				.PHY_AIR(PHY_AIR)
			) phy_I (
				.hub75_addr_inc(hub75_addr_inc),// -> pad
				.hub75_addr_rst(hub75_addr_rst),// -> pad
				.hub75_addr(hub75_addr),		// -> pad
				.hub75_data(hub75_data),		// -> pad
				.hub75_clk(hub75_clk),			// -> pad
				.hub75_le(hub75_le),			// -> pad
				.hub75_blank(hub75_blank),		// -> pad
				.phy_addr_inc(phz_addr_inc),	// <- hub75_bcm
				.phy_addr_rst(phz_addr_rst),	// <- hub75_bcm
				.phy_addr(phz_addr),			// <- hub75_bcm
				.phy_data(phz_data),			// <- hub75_shift
				.phy_clk(phz_clk),				// <- hub75_shift
				.phy_le(phz_le),				// <- hub75_bcm
				.phy_blank(phz_blank),			// <- hub75_blanking
				.clk(clk),						// <- top
				.clk_2x(clk_2x),				// <- top
				.rst(rst)						// <- top
			);
	endgenerate

endmodule // hub75_top
