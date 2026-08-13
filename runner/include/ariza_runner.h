/* ariza runner — the portable core of the compiled Windows launcher.
 *
 * A bundle's Windows entry point is bin/<exec>.exe: a small program that
 * sets the same environment the .cmd and .ps1 launchers set, then starts
 * the bundled interpreter on the app's script with the user's arguments
 * passed through BYTE FOR BYTE.  Everything in this header is the half
 * of that job which has nothing to do with Windows — parsing the sidecar
 * config, building environment values out of a bundle root, and deciding
 * where the caller's arguments begin in a raw command line — so it can be
 * compiled and tested anywhere, which is where the test suite runs.
 *
 * One type parameter, two instantiations.  The whole core is written in
 * terms of `arz_char`, which is `wchar_t` under Windows (where every
 * string in play is UTF-16: GetCommandLineW, GetModuleFileNameW,
 * SetEnvironmentVariableW) and `char` everywhere else (where the tests
 * feed it UTF-8).  The code is identical in both: it only ever inspects
 * ASCII structure characters — '#', '=', quotes, spaces, separators —
 * and copies everything else through untouched, so a UTF-8 byte and a
 * UTF-16 unit are equally opaque to it.
 *
 * Every function that returns `arz_char *` returns freshly allocated
 * memory the caller frees, or NULL when the allocation failed.  Nothing
 * here writes to a stream, exits, or knows what an error message looks
 * like; that is the platform layer's business.
 */

#ifndef ARIZA_RUNNER_H
#define ARIZA_RUNNER_H

#include <stddef.h>

#ifdef _WIN32
#include <wchar.h>
typedef wchar_t arz_char;
#define ARZ_T(s) L##s
#else
typedef char arz_char;
#define ARZ_T(s) s
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum arz_status {
	ARZ_OK = 0,
	ARZ_E_NOMEM,
	ARZ_E_SYNTAX
} arz_status;

/* The required directives, as an enum, so the platform layer can name a
 * missing one in its own character type rather than being handed a
 * `char *` it would have to convert. */
typedef enum arz_key {
	ARZ_KEY_NONE = 0,
	ARZ_KEY_TARGET,
	ARZ_KEY_APP_DISPLAY,
	ARZ_KEY_APP_EXEC
} arz_key;

/* The environment directives, in the order the file lists them. */
typedef enum arz_op_kind {
	ARZ_OP_SET = 1,
	ARZ_OP_UNSET,
	ARZ_OP_PREPEND_PATH
} arz_op_kind;

/* One environment directive.  `name` is the variable for `set` and
 * `unset` and NULL for `prepend-path`, which always means PATH; `value`
 * is the unexpanded text for `set` and `prepend-path` and NULL for
 * `unset`. */
typedef struct arz_env_op {
	arz_op_kind kind;
	arz_char *name;
	arz_char *value;
} arz_env_op;

/* bin/<exec>.ariza, parsed.
 *
 * The three strings are what the runner itself needs to know; `ops` is
 * everything it does NOT — a list of environment changes to apply in
 * order, whose meaning belongs entirely to whatever built the bundle.
 * The runner has no idea what RAKULIB is, that notcurses exists, or
 * that some bundles carry a SQLCipher: it discovers its root, applies
 * the directives it was given, and starts the interpreter. */
typedef struct arz_config {
	arz_char *target;
	arz_char *app_display;
	arz_char *app_exec;
	arz_env_op *ops;
	size_t op_count;
} arz_config;

/* The deliberately tiny authenticated handoff record written after an
 * updater transaction commits.  It contains no path: the platform launcher
 * derives the managed `current` entry point itself, so a writable state file
 * can never choose an executable. */
typedef struct arz_handoff {
	arz_char *nonce;
	arz_char *candidate;
} arz_handoff;

/* ------------------------------------------------------------------ */
/* Strings                                                             */
/* ------------------------------------------------------------------ */

size_t arz_len(const arz_char *s);

/* Concatenate up to three parts, skipping NULL ones.  The workhorse
 * everything else here is built from. */
arz_char *arz_cat(const arz_char *a, const arz_char *b, const arz_char *c);

arz_char *arz_dup(const arz_char *s);

/* True when `s`, of `n` units, is exactly the ASCII `name`. */
int arz_eq_ascii(const arz_char *s, size_t n, const char *name);

/* ------------------------------------------------------------------ */
/* The sidecar config                                                  */
/* ------------------------------------------------------------------ */

/* Parse `text` into `cfg`, which is zeroed first.  On ARZ_E_SYNTAX,
 * `*error_line` (when not NULL) is the 1-based line that could not be
 * read; it is 0 otherwise.
 *
 * The format, which resources/templates/launcher-windows.ariza.j2 emits
 * a description of into every file it writes:
 *
 *   * UTF-8, one directive per line, LF or CRLF, applied in order.
 *   * A '#' in the first non-blank column starts a comment line; blank
 *     lines are ignored.  A '#' anywhere else is an ordinary character,
 *     which matters more than it sounds: `inst#{root}\site` is a real
 *     value and an inline-comment rule would truncate it.
 *   * A leading UTF-8 BOM is skipped — nothing ariza writes has one, but
 *     an editor that has been near the file may have added it.
 *
 * The directives:
 *
 *   target PATH            the script the interpreter is given
 *   app-exec NAME          names the first-run marker directory
 *   app-display NAME       the name messages are printed under
 *   set NAME=VALUE         set an environment variable
 *   unset NAME             remove one
 *   prepend-path VALUE     put VALUE at the front of PATH
 *
 * In a VALUE, `{root}` is the bundle root and `{{` is a literal '{'.
 * Any other '{' is a syntax error rather than literal text, so a
 * mistyped token fails at launch instead of reaching an app as a path
 * that does not exist.
 *
 * An unrecognised directive is ARZ_E_SYNTAX, deliberately: a bundle
 * whose configuration mentions something this runner cannot do is a
 * bundle whose environment would be silently incomplete, and an app
 * that starts with half its libraries unfindable fails later and much
 * worse than one that does not start.
 *
 * Missing directives are NOT a parse error — see arz_config_missing. */
arz_status arz_config_parse(const arz_char *text, arz_config *cfg,
	size_t *error_line);

/* The first required directive missing from a parsed config, or
 * ARZ_KEY_NONE.  Environment directives are all optional: a bundle with
 * none is a legitimate, if unusual, bundle. */
arz_key arz_config_missing(const arz_config *cfg);

/* The directive's name in the file, ASCII, for messages and tests. */
const char *arz_key_name(arz_key key);

void arz_config_free(arz_config *cfg);

/* Parse exactly:
 *
 *   protocol=1\n
 *   nonce=<64 lowercase hexadecimal characters>\n
 *   candidate=<ASCII digits>.<ASCII digits>.<ASCII digits>\n
 *
 * with an optional final newline.  No duplicate, reordered, unknown or
 * trailing fields are accepted. */
arz_status arz_handoff_parse(const arz_char *text, arz_handoff *handoff);

/* Constant-time comparison for a parsed nonce and an expected 64-character
 * lowercase hexadecimal nonce. */
int arz_handoff_nonce_matches(const arz_handoff *handoff,
	const arz_char *expected);

void arz_handoff_free(arz_handoff *handoff);

/* ------------------------------------------------------------------ */
/* Paths and environment values                                        */
/* ------------------------------------------------------------------ */

/* `root` and `rel` joined with a single backslash, whatever mixture of
 * trailing and leading separators they arrive with.  Either separator is
 * accepted on input; a backslash is always what comes out, because that
 * is what the sidecar records and what a Windows user sees in an error
 * message. */
arz_char *arz_path_join(const arz_char *root, const arz_char *rel);

/* `path` with its last component removed, or NULL when it has no
 * separator to remove one at.  Any trailing separators are ignored
 * first, so both `C:\a\b` and `C:\a\b\` give `C:\a`. */
arz_char *arz_parent_dir(const arz_char *path);

/* A directive's value with `{root}` replaced by `root` and `{{` by a
 * literal '{'.  The value has already been through arz_config_parse,
 * which rejects any other token, so the only failure left here is an
 * allocation one (NULL). */
arz_char *arz_expand(const arz_char *value, const arz_char *root);

/* <dir>;<current> — or just <dir> when `current` is NULL or empty, since
 * a trailing separator on PATH is an empty entry, which Windows reads as
 * the current directory. */
arz_char *arz_env_path_prepend(const arz_char *dir, const arz_char *current);

/* <root>\rakudo\bin\raku.exe */
arz_char *arz_interpreter_path(const arz_char *root);

/* ------------------------------------------------------------------ */
/* Command lines                                                       */
/* ------------------------------------------------------------------ */

/* Where the caller's arguments begin in a raw command line, as a pointer
 * into `cmdline` — never NULL, and pointing at the terminating NUL when
 * there are none.
 *
 * This is the whole reason the runner exists, so it follows the C
 * runtime's argv[0] rule exactly rather than approximately:
 *
 *   * leading whitespace is skipped;
 *   * a command line starting with '"' has an argv[0] that ends at the
 *     NEXT '"' — inside it a backslash is a literal backslash and never
 *     an escape, because argv[0] has to be a path and a path cannot
 *     contain a quote;
 *   * otherwise argv[0] ends at the first space or tab;
 *   * whitespace between argv[0] and the rest is skipped.
 *
 * Everything after that point is handed to the child untouched.  No
 * re-quoting, no expansion, no splitting: that is what stops '^', '%x%',
 * '!x!', embedded quotes and trailing backslashes from being mangled on
 * the way through, which is what a .cmd trampoline cannot avoid doing. */
const arz_char *arz_cmdline_tail(const arz_char *cmdline);

/* `arg` quoted for a Windows command line, by the rules the C runtime
 * parses back: the whole argument is wrapped in quotes, a backslash run
 * immediately before a quote (or before the closing quote) is doubled,
 * and an embedded quote is escaped.
 *
 * Used for the two arguments the runner itself supplies — the
 * interpreter and the script — and for nothing the user typed. */
arz_char *arz_quote_arg(const arz_char *arg);

/* The child's command line: the quoted interpreter, the quoted script,
 * then `tail` verbatim if there is any.  `tail` may be NULL or empty. */
arz_char *arz_child_cmdline(const arz_char *exe, const arz_char *script,
	const arz_char *tail);

#ifdef __cplusplus
}
#endif

#endif /* ARIZA_RUNNER_H */
