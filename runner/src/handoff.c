#include <stdlib.h>

#include "ariza_runner.h"

static int is_digit(arz_char c)
{
	return c >= ARZ_T('0') && c <= ARZ_T('9');
}

static int is_lower_hex(arz_char c)
{
	return is_digit(c) || (c >= ARZ_T('a') && c <= ARZ_T('f'));
}

static int field(const arz_char **at, const char *name,
	arz_char **value, int (*valid)(arz_char), size_t exact,
	int version)
{
	const arz_char *p = *at;
	const arz_char *start;
	size_t n = 0;
	size_t i;
	arz_char *copy;

	for (i = 0; name[i] != '\0'; i++) {
		if (p[i] != (arz_char)(unsigned char)name[i])
			return 0;
	}
	p += i;
	if (*p++ != ARZ_T('='))
		return 0;
	start = p;
	if (version) {
		int dots = 0;
		int component = 0;
		while (*p != ARZ_T('\0') && *p != ARZ_T('\r') &&
		       *p != ARZ_T('\n')) {
			if (is_digit(*p)) {
				component = 1;
			} else if (*p == ARZ_T('.') && component && dots < 2) {
				dots++;
				component = 0;
			} else {
				return 0;
			}
			p++;
			n++;
		}
		if (dots != 2 || !component)
			return 0;
	} else {
		while (*p != ARZ_T('\0') && *p != ARZ_T('\r') &&
		       *p != ARZ_T('\n')) {
			if (!valid(*p))
				return 0;
			p++;
			n++;
		}
	}
	if ((exact != 0 && n != exact) || n == 0)
		return 0;
	if (version && *p == ARZ_T('\0')) {
		/* The final record line may omit its newline. */
	} else if (*p == ARZ_T('\r')) {
		p++;
		if (*p++ != ARZ_T('\n'))
			return 0;
	} else if (*p++ != ARZ_T('\n')) {
		return 0;
	}
	copy = malloc((n + 1) * sizeof(*copy));
	if (copy == NULL)
		return -1;
	for (i = 0; i < n; i++)
		copy[i] = start[i];
	copy[n] = ARZ_T('\0');
	*value = copy;
	*at = p;
	return 1;
}

arz_status arz_handoff_parse(const arz_char *text, arz_handoff *handoff)
{
	const arz_char *p = text;
	int result;

	if (handoff == NULL)
		return ARZ_E_SYNTAX;
	handoff->nonce = NULL;
	handoff->candidate = NULL;
	if (p == NULL)
		return ARZ_E_SYNTAX;
	if (arz_len(p) < 11)
		return ARZ_E_SYNTAX;
	if (!(p[0] == ARZ_T('p') && p[1] == ARZ_T('r') &&
	      p[2] == ARZ_T('o') && p[3] == ARZ_T('t') &&
	      p[4] == ARZ_T('o') && p[5] == ARZ_T('c') &&
	      p[6] == ARZ_T('o') && p[7] == ARZ_T('l') &&
	      p[8] == ARZ_T('=') && p[9] == ARZ_T('1')))
		return ARZ_E_SYNTAX;
	p += 10;
	if (*p == ARZ_T('\r'))
		p++;
	if (*p++ != ARZ_T('\n'))
		return ARZ_E_SYNTAX;
	result = field(&p, "nonce", &handoff->nonce, is_lower_hex, 64, 0);
	if (result <= 0)
		goto fail;
	result = field(&p, "candidate", &handoff->candidate, NULL, 0, 1);
	if (result <= 0)
		goto fail;
	if (*p != ARZ_T('\0'))
		goto fail;
	return ARZ_OK;

fail:
	arz_handoff_free(handoff);
	return result < 0 ? ARZ_E_NOMEM : ARZ_E_SYNTAX;
}

int arz_handoff_nonce_matches(const arz_handoff *handoff,
	const arz_char *expected)
{
	size_t i;
	unsigned int difference = 0;

	if (handoff == NULL || handoff->nonce == NULL || expected == NULL)
		return 0;
	for (i = 0; i < 64; i++)
		difference |= (unsigned int)(handoff->nonce[i] ^ expected[i]);
	difference |= (unsigned int)expected[64];
	return difference == 0;
}

void arz_handoff_free(arz_handoff *handoff)
{
	if (handoff == NULL)
		return;
	free(handoff->nonce);
	free(handoff->candidate);
	handoff->nonce = NULL;
	handoff->candidate = NULL;
}
