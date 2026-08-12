/* Shared test support for the runner's portable core: a tiny check
 * harness, and string helpers that let a test write its expectations as
 * plain C literals whichever character type the core was compiled for.
 *
 * The suite runs on every platform, including the ones the runner will
 * never launch anything on.  That is the point: the win32 shell is a few
 * hundred lines of API calls around this core, and the core is where the
 * rules that are easy to get wrong live — the argv[0] boundary, the
 * quoting, the config grammar. */

#ifndef ARIZA_RUNNER_TEST_SUPPORT_H
#define ARIZA_RUNNER_TEST_SUPPORT_H

#include <stdio.h>

#include "ariza_runner.h"

extern int t_checks;
extern int t_fails;

void t_check_impl(int ok, const char *expr, const char *file, int line);
int t_done(const char *suite); /* prints summary, returns exit code */

#define T_CHECK(cond) t_check_impl((cond) ? 1 : 0, #cond, __FILE__, __LINE__)

/* An ASCII literal as an arz_char string, in a small rotating set of
 * static buffers so several can appear in one expression.  Tests that
 * need non-ASCII data use T_U8 below instead. */
const arz_char *t_s(const char *ascii);

/* A UTF-8 byte string as an arz_char string: passed through unchanged
 * where arz_char is char, and decoded where it is wchar_t, so a test can
 * write "café" once and have it mean the same thing in both builds. */
const arz_char *t_u8(const char *utf8);

/* Compare an arz_char string against a UTF-8 literal, and report the
 * difference readably when it fails. */
int t_eq(const arz_char *got, const char *want);

/* A whole file as UTF-8 bytes, NUL-terminated; NULL if it cannot be
 * read.  The caller frees.  Used to parse the committed golden sidecar,
 * so the file ariza renders and the parser that reads it are checked
 * against each other rather than against two copies of an idea. */
char *t_read_file(const char *path);

/* T_EQ frees nothing; T_EQ_OWNED frees `got`, which is what the
 * allocating core functions hand back.  Both stringify the expressions
 * rather than the expected literal, so a table-driven caller passing
 * `CASES[i].want` reports as readably as one passing a literal. */
#define T_EQ(got, want) t_check_impl(t_eq((got), (want)), \
	#got " == " #want, __FILE__, __LINE__)
#define T_EQ_OWNED(got, want) do { \
	arz_char *t_tmp_ = (got); \
	t_check_impl(t_eq(t_tmp_, (want)), #got " == " #want, \
		__FILE__, __LINE__); \
	free(t_tmp_); \
} while (0)

#endif /* ARIZA_RUNNER_TEST_SUPPORT_H */
