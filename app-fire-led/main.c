#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "mach_defines.h"
#include "sdk.h"
#include "cache.h"
#include "badgetime.h"


#define HUB75_CTL_SCAN_ENA		(1 << 31)
#define HUB75_CTL_IRQ_ENA		(1 << 30)
#define HUB75_CTL_FB(x)			((x) << 28)
#define HUB75_CTL_BCM_LSB_LEN(x)	((x) << 24)
#define HUB75_CTL_FB_ADDR(x)		(((uint32_t)(x) >> 1) & ((1 << 24)-1))


#define FB_N	4
#define FB_W	64
#define FB_H	64

// Pointer to the framebuffer memory.
static uint16_t fire_pal[256];
static uint8_t  fire_data[FB_W * (FB_H + 1)];
static uint16_t *hub75_mem;



static void *
calloc_aligned(size_t nmemb, size_t size, size_t align)
{
	size_t t;
	union {
		void *p;
		uint32_t u;
	} m;

	t = nmemb * size + align;

	m.p = malloc(t);
	if (!m.p)
		return NULL;

	memset(m.p, 0x00, t);

	m.u = (m.u + align - 1) & ~(align - 1);

	return m.p;
}

static void
create_fire_palette(void)
{
	#define COMP_COLOR(R, G, B) ( \
			(((B) >> 3) << 11) | \
			(((G) >> 2) <<  5) | \
			(((R) >> 3) <<  0) \
		)

	for (int i = 0; i < 32; i++) {
		// black to blue
		fire_pal[i      ] = COMP_COLOR(0, 0, i << 1);
		// blue to red
		fire_pal[i +  32] = COMP_COLOR(i << 3, 0, 64 - (i << 1));
		// red to yellow
		fire_pal[i +  64] = COMP_COLOR(0xFF, i << 3, 0);
		// yellow to white
		fire_pal[i +  96] = COMP_COLOR(0xFF, 0xFF,   0 + (i << 2));
		fire_pal[i + 128] = COMP_COLOR(0xFF, 0xFF,  64 + (i << 2));
		fire_pal[i + 160] = COMP_COLOR(0xFF, 0xFF, 128 + (i << 2));
		fire_pal[i + 192] = COMP_COLOR(0xFF, 0xFF, 192 + i);
		fire_pal[i + 224] = COMP_COLOR(0xFF, 0xFF, 224 + i);
	}
}

static void
render_fire(uint16_t *fb_base)
{
	uint32_t rnd;
	uint8_t  *dp;
	uint16_t *fp;
	int x, y, tmp, not_done;

	/* Setup randomized seed */
	dp = &fire_data[FB_W * FB_H];

	for (x=0; x<FB_W; x++)
	{
		if ((x & 15) == 0)
			rnd = MISC_REG(MISC_RNG_REG);

		*dp++ = (rnd & 3) ? 0 : 255;
		rnd >>= 2;
	}

	/* Draw the fire */
	dp = &fire_data[FB_W * FB_H - 1];
	fp = &fb_base[FB_W * FB_H - 1];
	not_done = 1;

	for (y=0; y<FB_H; y++)
	{
		/* If this is an early stop, we still need to clear the lines ! */
		if (!not_done) {
			for (x=0; x<FB_W; x++) {
				*dp-- = 0;
				*fp-- = 0;
			}
			continue;
		}

		not_done = 0;

		/* First colum */
		tmp  = dp[0];
		tmp += dp[FB_W];
		tmp += dp[FB_W+1];
		tmp  = (tmp * 85) >> 8;
		tmp -= !!tmp;

		not_done |= tmp;

		*dp-- = tmp;
		*fp-- = fire_pal[tmp];

		/* Middle colums */
		for (x=1; x<FB_W-1; x++)
		{
			tmp  = dp[0];
			tmp += dp[FB_W];
			tmp += dp[FB_W-1];
			tmp += dp[FB_W+1];
			tmp >>= 2;
			tmp -= !!tmp;

			not_done |= tmp;

			*dp-- = tmp;
			*fp-- = fire_pal[tmp];
		}

		/* Last column */
		tmp  = dp[0];
		tmp += dp[FB_W];
		tmp += dp[FB_W-1];
		tmp  = (tmp * 85) >> 8;
		tmp -= !!tmp;

		not_done |= tmp;

		*dp-- = tmp;
		*fp-- = fire_pal[tmp];
	}

	/* Flush */
		/* In theory we could flush less ... but this creates bugs,
		 * probably this only works for cache aligned sections ... */
	cache_flush(fb_base, &fb_base[FB_W * FB_H]);
}

void main(int argc, char **argv)
{
	uint16_t *fb_base;
	int fb_n = 0;
	bool run;

	/* Console setup */
	FILE *f;
	f=fopen("/dev/console", "w");
	setvbuf(f, NULL, _IONBF, 0); //make console line unbuffered

	fprintf(f, "\0330X\03310YLook at the led panel dummy !!"); // Print a nice greeting.

	/* GFX Setup */
	GFX_REG(GFX_BGNDCOL_REG) = 0x202020; // a soft gray
	GFX_REG(GFX_LAYEREN_REG) = GFX_LAYEREN_TILEA;

	/* Wait until all buttons are released */
	wait_for_button_release();

	/* Allocate aligned frame buffer for HUB75 */
	hub75_mem = calloc_aligned(FB_N * FB_H * FB_W, sizeof(uint16_t), 128);
	cache_flush(&hub75_mem[0], &hub75_mem[FB_N * FB_H * FB_W]);

	/* Clear data */
	memset(&fire_data[0], 0x00, sizeof(fire_data));

	/* Create palette */
	create_fire_palette();

	/* Main loop */
	while ((MISC_REG(MISC_BTN_REG) & BUTTON_A) == 0)
	{
		/* Delay animation */
		delay(0);

		/* Toggle running */
		if ((MISC_REG(MISC_BTN_REG) & BUTTON_B) != 0) {
			run ^= 1;
			wait_for_button_release();
		}

		if (!run)
			continue;

		/* Select next frame and set pointer */
		fb_n = (fb_n + 1) & 3;
		fb_base = &hub75_mem[fb_n * FB_H * FB_H];

		/* Render frame */
		render_fire(fb_base);

		/* Tell hub75 to display new frame */
		MISC_REG(MISC_HUB75_REG) =
			HUB75_CTL_SCAN_ENA |
			HUB75_CTL_FB(fb_n) |
			HUB75_CTL_BCM_LSB_LEN(0) |
			HUB75_CTL_FB_ADDR(hub75_mem);
	}

	/* Disable HUB75 */
	MISC_REG(MISC_HUB75_REG) = 0;
}
