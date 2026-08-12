/* Command lines: where the caller's arguments start, and how the two
 * arguments the runner supplies are quoted.
 *
 * This file is the point of the whole exercise.  A .cmd launcher ends in
 * `"%ARIZA_RAKU%" "%BUNDLE_ROOT%\<target>" %*`, and `%*` is not the
 * caller's arguments — it is the caller's arguments after cmd.exe has
 * had a second go at them.  A '^' is an escape character to cmd, '%x%'
 * and '!x!' are expansions, and a quoted argument containing either
 * arrives at the app as something the user did not type.  The batch file
 * cannot avoid it: by the time `%*` is substituted, the damage is in the
 * substitution.
 *
 * A compiled launcher can avoid it completely, and does, by never
 * parsing the tail at all: it finds where argv[0] ends, and copies every
 * unit after that into the child's command line unchanged.  The child's
 * C runtime then parses exactly the bytes the user's shell produced,
 * which is what it would have done had the user run raku.exe directly. */

#include <stdlib.h>

#include "ariza_runner.h"

static int is_space(arz_char c)
{
	return c == ARZ_T(' ') || c == ARZ_T('\t');
}

const arz_char *arz_cmdline_tail(const arz_char *cmdline)
{
	const arz_char *p = cmdline;

	if (p == NULL)
		return NULL;

	while (is_space(*p))
		p++;

	if (*p == ARZ_T('"')) {
		/* The C runtime's argv[0] rule, which is not the rule for any
		 * other argument: everything between the opening quote and the
		 * next one is the program name, and a backslash inside it is a
		 * backslash.  It can afford to be that simple because argv[0]
		 * has to name a file, and a Windows path cannot contain a
		 * quote.  An unterminated quote swallows the rest of the line,
		 * exactly as the runtime would have it. */
		p++;
		while (*p != ARZ_T('"') && *p != ARZ_T('\0'))
			p++;
		if (*p == ARZ_T('"'))
			p++;
	} else {
		while (*p != ARZ_T('\0') && !is_space(*p))
			p++;
	}

	while (is_space(*p))
		p++;
	return p;
}

arz_char *arz_quote_arg(const arz_char *arg)
{
	arz_char *out;
	size_t worst;
	size_t at = 0;
	size_t i = 0;
	size_t n;

	if (arg == NULL)
		arg = ARZ_T("");
	n = arz_len(arg);

	/* Every unit can at worst double (a backslash run before a quote)
	 * and a quote adds one more, plus the two wrapping quotes. */
	worst = n * 2 + 3;
	out = malloc((worst + 1) * sizeof(*out));
	if (out == NULL)
		return NULL;

	out[at++] = ARZ_T('"');
	while (i < n) {
		size_t slashes = 0;
		size_t k;

		while (i < n && arg[i] == ARZ_T('\\')) {
			slashes++;
			i++;
		}
		if (i == n) {
			/* Trailing backslashes sit immediately before the
			 * closing quote, so they have to be doubled or the
			 * quote is escaped instead of closing. */
			for (k = 0; k < slashes * 2; k++)
				out[at++] = ARZ_T('\\');
			break;
		}
		if (arg[i] == ARZ_T('"')) {
			for (k = 0; k < slashes * 2 + 1; k++)
				out[at++] = ARZ_T('\\');
		} else {
			for (k = 0; k < slashes; k++)
				out[at++] = ARZ_T('\\');
		}
		out[at++] = arg[i++];
	}
	out[at++] = ARZ_T('"');
	out[at] = ARZ_T('\0');
	return out;
}

arz_char *arz_child_cmdline(const arz_char *exe, const arz_char *script,
	const arz_char *tail)
{
	arz_char *qexe = arz_quote_arg(exe);
	arz_char *qscript = arz_quote_arg(script);
	arz_char *head = NULL;
	arz_char *out = NULL;

	if (qexe == NULL || qscript == NULL)
		goto done;

	head = arz_cat(qexe, ARZ_T(" "), qscript);
	if (head == NULL)
		goto done;

	if (tail == NULL || tail[0] == ARZ_T('\0'))
		out = arz_dup(head);
	else
		out = arz_cat(head, ARZ_T(" "), tail);

done:
	free(qexe);
	free(qscript);
	free(head);
	return out;
}
