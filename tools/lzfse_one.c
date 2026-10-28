/* Decode exactly one LZFSE stream and report how many source bytes it used.
 * lzfse_decode_buffer() hides this: it returns dst_size when the output fills
 * up, so the caller cannot tell a complete stream from a truncated input. */
#include <stdlib.h>
#include <string.h>
#include "lzfse_internal.h"

size_t
lzfse_dec_one(const uint8_t *src, size_t src_size, uint8_t *dst, size_t dst_cap,
    size_t *consumed, int *status_out)
{
	lzfse_decoder_state *s = malloc(sizeof(*s));
	if (s == NULL) {
		return 0;
	}
	memset(s, 0, sizeof(*s));
	s->src = src;
	s->src_begin = src;
	s->src_end = src + src_size;
	s->dst = dst;
	s->dst_begin = dst;
	s->dst_end = dst + dst_cap;

	int status = lzfse_decode(s);
	*consumed = (size_t)(s->src - src);
	*status_out = status;
	size_t written = (size_t)(s->dst - dst);
	free(s);
	return written;
}
