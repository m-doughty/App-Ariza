/* The three string primitives everything else here is built from.
 *
 * Written by hand rather than taken from <string.h> / <wchar.h> because
 * the core is compiled once per character type and the C library spells
 * these differently for each (strlen / wcslen, strcpy / wcscpy).  They
 * are a dozen lines each; a pair of #ifdef'd aliases would be more
 * machinery than the code they alias. */

#include <stdlib.h>

#include "ariza_runner.h"

size_t arz_len(const arz_char *s)
{
	size_t n = 0;

	if (s == NULL)
		return 0;
	while (s[n] != ARZ_T('\0'))
		n++;
	return n;
}

arz_char *arz_cat(const arz_char *a, const arz_char *b, const arz_char *c)
{
	const arz_char *parts[3];
	arz_char *out;
	size_t total = 0;
	size_t at = 0;
	int i;

	parts[0] = a;
	parts[1] = b;
	parts[2] = c;
	for (i = 0; i < 3; i++)
		total += arz_len(parts[i]);

	out = malloc((total + 1) * sizeof(*out));
	if (out == NULL)
		return NULL;

	for (i = 0; i < 3; i++) {
		const arz_char *p = parts[i];
		size_t j;

		if (p == NULL)
			continue;
		for (j = 0; p[j] != ARZ_T('\0'); j++)
			out[at++] = p[j];
	}
	out[at] = ARZ_T('\0');
	return out;
}

arz_char *arz_dup(const arz_char *s)
{
	if (s == NULL)
		return NULL;
	return arz_cat(s, NULL, NULL);
}

int arz_eq_ascii(const arz_char *s, size_t n, const char *name)
{
	size_t i;

	for (i = 0; i < n; i++) {
		if (name[i] == '\0')
			return 0;
		if (s[i] != (arz_char)(unsigned char)name[i])
			return 0;
	}
	return name[n] == '\0';
}
