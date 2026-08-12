/* Paths, token expansion, and the one list operation PATH needs.
 *
 * Note what is NOT here: no RAKULIB, no notcurses, no SQLCipher, no
 * knowledge of what any variable a bundle sets is for.  A directive's
 * value arrives with `{root}` in it and leaves with the resolved root in
 * it, and that is the entire extent of the runner's opinion about a
 * bundle's environment.  The values themselves are the renderer's
 * (resources/templates/launcher-windows.ariza.j2), which is what lets a
 * bundle gain a native dependency without a new runner.
 *
 * Nothing here consults the filesystem or the environment.  Strings go
 * in, strings come out, and the platform layer decides what to do with
 * them — which is what makes all of it testable off Windows. */

#include <stdlib.h>

#include "ariza_runner.h"

static int is_sep(arz_char c)
{
	return c == ARZ_T('\\') || c == ARZ_T('/');
}

arz_char *arz_path_join(const arz_char *root, const arz_char *rel)
{
	arz_char *out;
	size_t rootlen;
	size_t at = 0;
	size_t i;

	if (root == NULL)
		return arz_dup(rel);
	if (rel == NULL)
		return arz_dup(root);

	rootlen = arz_len(root);
	/* One separator between the two, however many each brought. */
	while (rootlen > 0 && is_sep(root[rootlen - 1]))
		rootlen--;
	while (is_sep(*rel))
		rel++;

	out = malloc((rootlen + 1 + arz_len(rel) + 1) * sizeof(*out));
	if (out == NULL)
		return NULL;

	for (i = 0; i < rootlen; i++)
		out[at++] = root[i];
	if (rootlen > 0 && rel[0] != ARZ_T('\0'))
		out[at++] = ARZ_T('\\');
	for (i = 0; rel[i] != ARZ_T('\0'); i++)
		out[at++] = rel[i];
	out[at] = ARZ_T('\0');
	return out;
}

arz_char *arz_parent_dir(const arz_char *path)
{
	arz_char *out;
	size_t n;
	size_t i;

	if (path == NULL)
		return NULL;
	n = arz_len(path);
	while (n > 0 && is_sep(path[n - 1]))
		n--;
	while (n > 0 && !is_sep(path[n - 1]))
		n--;
	if (n == 0)
		return NULL;
	/* Keep the separator only where dropping it would change the path
	 * from a root ("C:\") into a drive-relative one ("C:"). */
	while (n > 1 && is_sep(path[n - 1]) && !is_sep(path[n - 2]) &&
	       path[n - 2] != ARZ_T(':'))
		n--;

	out = malloc((n + 1) * sizeof(*out));
	if (out == NULL)
		return NULL;
	for (i = 0; i < n; i++)
		out[i] = path[i];
	out[n] = ARZ_T('\0');
	return out;
}

arz_char *arz_expand(const arz_char *value, const arz_char *root)
{
	size_t rootlen = arz_len(root);
	size_t i;
	size_t out_len = 0;
	size_t at = 0;
	arz_char *out;

	if (value == NULL)
		return NULL;

	/* Measure, then fill: two passes over a few dozen units, and no
	 * arithmetic anybody has to trust. */
	for (i = 0; value[i] != ARZ_T('\0'); ) {
		if (value[i] == ARZ_T('{') && value[i + 1] == ARZ_T('{')) {
			out_len += 1;
			i += 2;
		} else if (value[i] == ARZ_T('{') && value[i + 1] == ARZ_T('r') &&
			   value[i + 2] == ARZ_T('o') && value[i + 3] == ARZ_T('o') &&
			   value[i + 4] == ARZ_T('t') && value[i + 5] == ARZ_T('}')) {
			out_len += rootlen;
			i += 6;
		} else {
			out_len += 1;
			i++;
		}
	}

	out = malloc((out_len + 1) * sizeof(*out));
	if (out == NULL)
		return NULL;

	for (i = 0; value[i] != ARZ_T('\0'); ) {
		if (value[i] == ARZ_T('{') && value[i + 1] == ARZ_T('{')) {
			out[at++] = ARZ_T('{');
			i += 2;
		} else if (value[i] == ARZ_T('{') && value[i + 1] == ARZ_T('r') &&
			   value[i + 2] == ARZ_T('o') && value[i + 3] == ARZ_T('o') &&
			   value[i + 4] == ARZ_T('t') && value[i + 5] == ARZ_T('}')) {
			size_t j;

			for (j = 0; j < rootlen; j++)
				out[at++] = root[j];
			i += 6;
		} else {
			out[at++] = value[i++];
		}
	}
	out[at] = ARZ_T('\0');
	return out;
}

arz_char *arz_env_path_prepend(const arz_char *dir, const arz_char *current)
{
	if (dir == NULL)
		return arz_dup(current);
	/* No trailing ';' when there is nothing to append: an empty PATH
	 * entry is the current directory to Windows, which is exactly the
	 * kind of accidental search path a bundle exists to not have. */
	if (current == NULL || current[0] == ARZ_T('\0'))
		return arz_dup(dir);
	return arz_cat(dir, ARZ_T(";"), current);
}

arz_char *arz_interpreter_path(const arz_char *root)
{
	return arz_path_join(root, ARZ_T("rakudo\\bin\\raku.exe"));
}
