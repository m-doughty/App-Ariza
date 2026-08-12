/* bin/<exec>.ariza — the sidecar the runner reads at startup.
 *
 * Two decisions are visible in this file, and they are the interesting
 * ones about the whole runner.
 *
 * The first is that there is a sidecar at all.  Baking the target
 * script and the environment into the executable at build time would
 * mean one compiled runner per app, per version, per platform, produced
 * by whoever built the bundle — i.e. a C toolchain in the bundling
 * path.  A generic runner plus a text file next to it keeps the
 * executable a fixed, pinned, hash-verified artefact and puts the
 * per-bundle facts in something a user can read, diff and correct.
 *
 * The second is that the environment arrives as ORDERED DIRECTIVES
 * rather than as named settings.  An earlier draft had `sqlcipher_dir`
 * and `sqlcipher_lib` keys and a hardcoded NOTCURSES_NATIVE_DATA_DIR,
 * which meant the runner — a pinned binary, updated on its own release
 * cadence — had to learn about every native dependency any bundle might
 * ever carry.  It does not.  It applies `set`, `unset` and
 * `prepend-path` lines in the order it finds them, and what those lines
 * mean is entirely the business of whatever rendered the file.  Adding
 * a dependency to a bundle is then a change in the renderer and nothing
 * else: no new sidecar keys, no new runner, no version skew between the
 * two.
 *
 * The parser is deliberately lenient in one direction and unforgiving
 * in the other: whitespace, comments, CRLF and a stray BOM are all
 * tolerated, because that is what an editor produces; an unrecognised
 * directive is a hard error naming the line, because a bundle whose
 * configuration says something this runner cannot do would otherwise
 * start an app with a silently incomplete environment. */

#include <stdlib.h>

#include "ariza_runner.h"

static const arz_char *skip_bom(const arz_char *p)
{
#ifdef _WIN32
	/* MultiByteToWideChar leaves a UTF-8 BOM as one U+FEFF unit. */
	if (p[0] == (arz_char)0xFEFF)
		return p + 1;
#else
	if ((unsigned char)p[0] == 0xEF && (unsigned char)p[1] == 0xBB &&
	    (unsigned char)p[2] == 0xBF)
		return p + 3;
#endif
	return p;
}

static int is_blank(arz_char c)
{
	return c == ARZ_T(' ') || c == ARZ_T('\t') || c == ARZ_T('\r');
}

static arz_char *copy_range(const arz_char *from, const arz_char *to)
{
	size_t n = (size_t)(to - from);
	arz_char *out = malloc((n + 1) * sizeof(*out));
	size_t i;

	if (out == NULL)
		return NULL;
	for (i = 0; i < n; i++)
		out[i] = from[i];
	out[n] = ARZ_T('\0');
	return out;
}

/* Every `{` in a value has to open either `{root}` or `{{`.  Checked at
 * parse time, where there is a line number to report, so that
 * arz_expand can be total. */
static int tokens_are_known(const arz_char *from, const arz_char *to)
{
	const arz_char *p = from;

	while (p < to) {
		if (*p != ARZ_T('{')) {
			p++;
			continue;
		}
		if (p + 1 < to && p[1] == ARZ_T('{')) {
			p += 2;
			continue;
		}
		if (to - p >= 6 && p[1] == ARZ_T('r') && p[2] == ARZ_T('o') &&
		    p[3] == ARZ_T('o') && p[4] == ARZ_T('t') &&
		    p[5] == ARZ_T('}')) {
			p += 6;
			continue;
		}
		return 0;
	}
	return 1;
}

static arz_status push_op(arz_config *cfg, arz_op_kind kind, arz_char *name,
	arz_char *value)
{
	/* Doubling from four: a bundle has a handful of directives, and a
	 * fixed cap is exactly the kind of limit that turns into a bug the
	 * first time a recipe adds a fifth library. */
	if (cfg->op_count % 4 == 0) {
		size_t want = cfg->op_count + 4;
		arz_env_op *grown = realloc(cfg->ops, want * sizeof(*grown));

		if (grown == NULL) {
			free(name);
			free(value);
			return ARZ_E_NOMEM;
		}
		cfg->ops = grown;
	}
	cfg->ops[cfg->op_count].kind = kind;
	cfg->ops[cfg->op_count].name = name;
	cfg->ops[cfg->op_count].value = value;
	cfg->op_count++;
	return ARZ_OK;
}

/* One directive line, already trimmed at both ends and known to be
 * neither blank nor a comment. */
static arz_status parse_line(arz_config *cfg, const arz_char *line,
	const arz_char *end)
{
	const arz_char *verb = line;
	const arz_char *verb_end = line;
	const arz_char *arg;
	size_t vlen;

	while (verb_end < end && !is_blank(*verb_end))
		verb_end++;
	vlen = (size_t)(verb_end - verb);

	arg = verb_end;
	while (arg < end && is_blank(*arg))
		arg++;

	if (arz_eq_ascii(verb, vlen, "target") ||
	    arz_eq_ascii(verb, vlen, "app-exec") ||
	    arz_eq_ascii(verb, vlen, "app-display")) {
		arz_char **slot;
		arz_char *copy;

		if (arg == end)
			return ARZ_E_SYNTAX;
		copy = copy_range(arg, end);
		if (copy == NULL)
			return ARZ_E_NOMEM;

		if (arz_eq_ascii(verb, vlen, "target"))
			slot = &cfg->target;
		else if (arz_eq_ascii(verb, vlen, "app-exec"))
			slot = &cfg->app_exec;
		else
			slot = &cfg->app_display;

		/* A repeated directive takes its last value. */
		free(*slot);
		*slot = copy;
		return ARZ_OK;
	}

	if (arz_eq_ascii(verb, vlen, "set")) {
		const arz_char *eq = arg;
		arz_char *name;
		arz_char *value;

		while (eq < end && *eq != ARZ_T('='))
			eq++;
		/* `set` needs a name and an '='; the value after it may be
		 * empty, which is a set-but-empty variable and a different
		 * thing from `unset`. */
		if (eq == end || eq == arg)
			return ARZ_E_SYNTAX;
		if (!tokens_are_known(eq + 1, end))
			return ARZ_E_SYNTAX;

		name = copy_range(arg, eq);
		value = copy_range(eq + 1, end);
		if (name == NULL || value == NULL) {
			free(name);
			free(value);
			return ARZ_E_NOMEM;
		}
		return push_op(cfg, ARZ_OP_SET, name, value);
	}

	if (arz_eq_ascii(verb, vlen, "unset")) {
		arz_char *name;

		if (arg == end)
			return ARZ_E_SYNTAX;
		name = copy_range(arg, end);
		if (name == NULL)
			return ARZ_E_NOMEM;
		return push_op(cfg, ARZ_OP_UNSET, name, NULL);
	}

	if (arz_eq_ascii(verb, vlen, "prepend-path")) {
		arz_char *value;

		if (arg == end)
			return ARZ_E_SYNTAX;
		if (!tokens_are_known(arg, end))
			return ARZ_E_SYNTAX;
		value = copy_range(arg, end);
		if (value == NULL)
			return ARZ_E_NOMEM;
		return push_op(cfg, ARZ_OP_PREPEND_PATH, NULL, value);
	}

	/* Fail closed.  A directive this runner does not implement is one
	 * whose effect on the environment would simply be absent, and an
	 * app that starts with half its libraries unfindable is a much
	 * worse failure than one that does not start. */
	return ARZ_E_SYNTAX;
}

arz_status arz_config_parse(const arz_char *text, arz_config *cfg,
	size_t *error_line)
{
	const arz_char *p;
	size_t lineno = 0;

	cfg->target = NULL;
	cfg->app_display = NULL;
	cfg->app_exec = NULL;
	cfg->ops = NULL;
	cfg->op_count = 0;
	if (error_line != NULL)
		*error_line = 0;

	if (text == NULL)
		return ARZ_OK;

	p = skip_bom(text);
	while (*p != ARZ_T('\0')) {
		const arz_char *line = p;
		const arz_char *end;
		arz_status st;

		lineno++;
		while (*p != ARZ_T('\0') && *p != ARZ_T('\n'))
			p++;
		end = p;
		if (*p == ARZ_T('\n'))
			p++;

		while (line < end && is_blank(*line))
			line++;
		while (end > line && is_blank(end[-1]))
			end--;

		if (line == end || *line == ARZ_T('#'))
			continue;

		st = parse_line(cfg, line, end);
		if (st != ARZ_OK) {
			if (error_line != NULL && st == ARZ_E_SYNTAX)
				*error_line = lineno;
			return st;
		}
	}
	return ARZ_OK;
}

static int empty(const arz_char *s)
{
	return s == NULL || s[0] == ARZ_T('\0');
}

arz_key arz_config_missing(const arz_config *cfg)
{
	if (empty(cfg->target))
		return ARZ_KEY_TARGET;
	if (empty(cfg->app_display))
		return ARZ_KEY_APP_DISPLAY;
	if (empty(cfg->app_exec))
		return ARZ_KEY_APP_EXEC;
	return ARZ_KEY_NONE;
}

const char *arz_key_name(arz_key key)
{
	switch (key) {
	case ARZ_KEY_NONE:
		return "";
	case ARZ_KEY_TARGET:
		return "target";
	case ARZ_KEY_APP_DISPLAY:
		return "app-display";
	case ARZ_KEY_APP_EXEC:
		return "app-exec";
	default:
		return "";
	}
}

void arz_config_free(arz_config *cfg)
{
	size_t i;

	if (cfg == NULL)
		return;
	free(cfg->target);
	free(cfg->app_display);
	free(cfg->app_exec);
	for (i = 0; i < cfg->op_count; i++) {
		free(cfg->ops[i].name);
		free(cfg->ops[i].value);
	}
	free(cfg->ops);
	cfg->target = NULL;
	cfg->app_display = NULL;
	cfg->app_exec = NULL;
	cfg->ops = NULL;
	cfg->op_count = 0;
}
