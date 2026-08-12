#include <stdlib.h>
#include <string.h>

#include "support.h"

int t_checks = 0;
int t_fails = 0;

void t_check_impl(int ok, const char *expr, const char *file, int line)
{
	t_checks++;
	if (!ok) {
		t_fails++;
		fprintf(stderr, "FAIL %s:%d: %s\n", file, line, expr);
	}
}

int t_done(const char *suite)
{
	fprintf(stderr, "%s: %d checks, %d failures\n", suite, t_checks,
		t_fails);
	return t_fails == 0 ? 0 : 1;
}

char *t_read_file(const char *path)
{
	FILE *f = fopen(path, "rb");
	char *buf;
	long size;
	size_t got;

	if (f == NULL)
		return NULL;
	if (fseek(f, 0, SEEK_END) != 0 || (size = ftell(f)) < 0 ||
	    fseek(f, 0, SEEK_SET) != 0) {
		fclose(f);
		return NULL;
	}
	buf = malloc((size_t)size + 1);
	if (buf == NULL) {
		fclose(f);
		return NULL;
	}
	got = fread(buf, 1, (size_t)size, f);
	fclose(f);
	buf[got] = '\0';
	return buf;
}

#define T_SLOTS 8
#define T_SLOT_UNITS 4096

static arz_char t_buf[T_SLOTS][T_SLOT_UNITS];
static int t_slot;

/* UTF-8 -> arz_char, into one of the rotating slots.
 *
 * Where arz_char is char this is a copy; where it is wchar_t it is a
 * decode to UTF-16, surrogate pairs and all, so a test can write one
 * literal and have both builds mean the same string by it. */
const arz_char *t_u8(const char *utf8)
{
	arz_char *out = t_buf[t_slot];
	size_t at = 0;
	const unsigned char *p = (const unsigned char *)utf8;

	t_slot = (t_slot + 1) % T_SLOTS;

	while (*p != '\0' && at + 2 < T_SLOT_UNITS) {
#ifdef _WIN32
		unsigned long cp;
		int extra;

		if (*p < 0x80) {
			cp = *p++;
			extra = 0;
		} else if ((*p & 0xE0) == 0xC0) {
			cp = (unsigned long)(*p++ & 0x1F);
			extra = 1;
		} else if ((*p & 0xF0) == 0xE0) {
			cp = (unsigned long)(*p++ & 0x0F);
			extra = 2;
		} else {
			cp = (unsigned long)(*p++ & 0x07);
			extra = 3;
		}
		while (extra-- > 0 && (*p & 0xC0) == 0x80)
			cp = (cp << 6) | (unsigned long)(*p++ & 0x3F);

		if (cp > 0xFFFF) {
			cp -= 0x10000;
			out[at++] = (arz_char)(0xD800 + (cp >> 10));
			out[at++] = (arz_char)(0xDC00 + (cp & 0x3FF));
		} else {
			out[at++] = (arz_char)cp;
		}
#else
		out[at++] = (arz_char)*p++;
#endif
	}
	out[at] = ARZ_T('\0');
	return out;
}

const arz_char *t_s(const char *ascii)
{
	return t_u8(ascii);
}

int t_eq(const arz_char *got, const char *want)
{
	const arz_char *expected;
	size_t i;

	if (got == NULL)
		return 0;
	expected = t_u8(want);
	for (i = 0; expected[i] != ARZ_T('\0'); i++) {
		if (got[i] != expected[i]) {
			fprintf(stderr, "  differs at unit %lu; wanted [%s]\n",
				(unsigned long)i, want);
			return 0;
		}
	}
	if (got[i] != ARZ_T('\0')) {
		fprintf(stderr, "  longer than wanted [%s] (%lu units)\n",
			want, (unsigned long)arz_len(got));
		return 0;
	}
	return 1;
}
