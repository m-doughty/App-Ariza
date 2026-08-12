/* The argv[0] boundary, the quoting, and the child command line.
 *
 * This is the file that says what the runner is FOR.  Each tail case
 * below is an argument that a .cmd trampoline damages on the way to the
 * app — '^' is cmd's escape character, '%x%' and '!x!' are its
 * expansions, and a quoted argument is re-split by `%*` — and the
 * expectation is always the same: the bytes after argv[0], unchanged. */

#include <stdlib.h>

#include "support.h"

struct tail_case {
	const char *cmdline;
	const char *tail;
	const char *why;
};

/* The table is deliberately written as raw command lines, the way
 * GetCommandLineW hands them over, rather than as argv arrays: the whole
 * point is that the runner never turns one into the other. */
static const struct tail_case TAILS[] = {
	{ "exampleapp.exe", "",
	  "no arguments at all" },
	{ "exampleapp.exe foo bar", "foo bar",
	  "the ordinary case" },
	{ "exampleapp.exe   foo   bar  ", "foo   bar  ",
	  "spacing between and after arguments is the caller's, not ours" },
	{ "  exampleapp.exe foo", "foo",
	  "a command line may begin with whitespace" },
	{ "exampleapp.exe\tfoo\tbar", "foo\tbar",
	  "a tab separates argv[0] as readily as a space" },
	{ "\"C:\\Program Files\\App\\exampleapp.exe\" foo", "foo",
	  "a quoted argv[0] with spaces in it — the common Explorer case" },
	{ "\"C:\\Program Files\\App\\exampleapp.exe\"", "",
	  "quoted, and no arguments" },
	{ "\"C:\\dir\\exampleapp.exe\"   --flag  \"a b\"", "--flag  \"a b\"",
	  "quotes in the tail are the caller's and stay exactly where they are" },
	{ "\"C:\\dir\\prog\".exe foo", ".exe foo",
	  "a quoted argv[0] ends at the closing quote, and the runtime would"
	  " read '.exe' as the next argument — so we hand over the same" },
	{ "\"C:\\dir\\unterminated foo bar", "",
	  "an unterminated quote swallows the line, exactly as the runtime"
	  " has it" },
	{ "exampleapp.exe ^", "^",
	  "a caret: cmd's escape character, and nothing to us" },
	{ "exampleapp.exe a^^b ^\"q^\"", "a^^b ^\"q^\"",
	  "carets in quantity, which is what a batch file cannot survive" },
	{ "exampleapp.exe %PATH% %%x %", "%PATH% %%x %",
	  "percent signs are not expanded here; the shell already did or"
	  " did not" },
	{ "exampleapp.exe !x! !!", "!x! !!",
	  "delayed-expansion syntax, likewise" },
	{ "exampleapp.exe \"say \\\"hi\\\"\"", "\"say \\\"hi\\\"\"",
	  "an escaped quote inside a quoted argument survives intact" },
	{ "exampleapp.exe C:\\dir\\", "C:\\dir\\",
	  "a trailing backslash" },
	{ "exampleapp.exe \"C:\\dir\\\\\"", "\"C:\\dir\\\\\"",
	  "backslashes before a closing quote, which is the case every"
	  " hand-rolled re-quoter gets wrong" },
	{ "exampleapp.exe --name=Caffè --emoji=☕", "--name=Caffè --emoji=☕",
	  "non-ASCII arguments pass through as units, not bytes to reinterpret" },
	{ "", "",
	  "an empty command line" },
	{ "   ", "",
	  "whitespace only" },
};

static void test_tail(void)
{
	size_t i;

	for (i = 0; i < sizeof(TAILS) / sizeof(TAILS[0]); i++) {
		const arz_char *line = t_u8(TAILS[i].cmdline);
		const arz_char *got = arz_cmdline_tail(line);

		if (!t_eq(got, TAILS[i].tail)) {
			fprintf(stderr, "FAIL tail[%lu]: %s\n",
				(unsigned long)i, TAILS[i].why);
			fprintf(stderr, "  cmdline: %s\n", TAILS[i].cmdline);
			fprintf(stderr, "  wanted:  %s\n", TAILS[i].tail);
			t_fails++;
		}
		t_checks++;

		/* The tail is a pointer INTO the command line, never a copy:
		 * there is no re-encoding step for anything to be lost in. */
		T_CHECK(got >= line && got <= line + arz_len(line));
	}

	T_CHECK(arz_cmdline_tail(NULL) == NULL);
}

struct quote_case {
	const char *arg;
	const char *quoted;
};

/* The runner quotes exactly two things — the interpreter and the
 * script — and both are paths it built itself.  The rules are still the
 * C runtime's, because the child parses them back with the C runtime. */
static const struct quote_case QUOTES[] = {
	{ "plain", "\"plain\"" },
	{ "", "\"\"" },
	{ "C:\\b\\rakudo\\bin\\raku.exe", "\"C:\\b\\rakudo\\bin\\raku.exe\"" },
	{ "C:\\Program Files\\My App\\raku.exe",
	  "\"C:\\Program Files\\My App\\raku.exe\"" },
	/* A trailing backslash sits immediately before the closing quote,
	 * where an undoubled one would escape the quote instead. */
	{ "C:\\dir\\", "\"C:\\dir\\\\\"" },
	{ "C:\\dir\\\\", "\"C:\\dir\\\\\\\\\"" },
	{ "a\"b", "\"a\\\"b\"" },
	{ "a\\\"b", "\"a\\\\\\\"b\"" },
	{ "a\\b", "\"a\\b\"" },
	{ "Caffè ☕", "\"Caffè ☕\"" },
};

static void test_quote(void)
{
	size_t i;

	for (i = 0; i < sizeof(QUOTES) / sizeof(QUOTES[0]); i++)
		T_EQ_OWNED(arz_quote_arg(t_u8(QUOTES[i].arg)),
			QUOTES[i].quoted);

	T_EQ_OWNED(arz_quote_arg(NULL), "\"\"");
}

static void test_child_cmdline(void)
{
	T_EQ_OWNED(arz_child_cmdline(t_s("C:\\b\\rakudo\\bin\\raku.exe"),
		t_s("C:\\b\\site\\bin\\a.raku"), t_s("--flag \"a b\" ^%x%")),
		"\"C:\\b\\rakudo\\bin\\raku.exe\" \"C:\\b\\site\\bin\\a.raku\""
		" --flag \"a b\" ^%x%");

	/* No trailing space when there are no arguments: a command line
	 * ending in one is harmless but shows up in every error message and
	 * every process listing. */
	T_EQ_OWNED(arz_child_cmdline(t_s("C:\\b\\rakudo\\bin\\raku.exe"),
		t_s("C:\\b\\site\\bin\\a.raku"), t_s("")),
		"\"C:\\b\\rakudo\\bin\\raku.exe\" \"C:\\b\\site\\bin\\a.raku\"");
	T_EQ_OWNED(arz_child_cmdline(t_s("C:\\b\\rakudo\\bin\\raku.exe"),
		t_s("C:\\b\\site\\bin\\a.raku"), NULL),
		"\"C:\\b\\rakudo\\bin\\raku.exe\" \"C:\\b\\site\\bin\\a.raku\"");

	/* End to end: a raw command line in, the child's command line out,
	 * with the tail carried across untouched. */
	T_EQ_OWNED(arz_child_cmdline(t_s("C:\\b\\rakudo\\bin\\raku.exe"),
		t_s("C:\\b\\site\\bin\\a.raku"),
		arz_cmdline_tail(t_u8(
			"\"C:\\Program Files\\b\\bin\\a.exe\" --note=\"50%% ^ done\" !x!"))),
		"\"C:\\b\\rakudo\\bin\\raku.exe\" \"C:\\b\\site\\bin\\a.raku\""
		" --note=\"50%% ^ done\" !x!");
}

int main(void)
{
	test_tail();
	test_quote();
	test_child_cmdline();
	return t_done("cmdline");
}
