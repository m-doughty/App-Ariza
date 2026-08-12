/* Paths, token expansion, and PATH.
 *
 * The values in these cases are the ones every ariza bundle's sidecar
 * happens to carry, which makes them readable — but nothing here knows
 * that, and that is the point: the runner substitutes one token and
 * joins paths, and what the results mean belongs to the renderer that
 * wrote them. */

#include <stdlib.h>

#include "support.h"

static void test_path_join(void)
{
	T_EQ_OWNED(arz_path_join(t_s("C:\\b"), t_s("site")), "C:\\b\\site");

	/* However many separators each side brought, exactly one comes
	 * out — and it is a backslash, because that is what the sidecar
	 * records and what a Windows error message should show. */
	T_EQ_OWNED(arz_path_join(t_s("C:\\b\\"), t_s("site")), "C:\\b\\site");
	T_EQ_OWNED(arz_path_join(t_s("C:\\b"), t_s("\\site")), "C:\\b\\site");
	T_EQ_OWNED(arz_path_join(t_s("C:\\b\\\\"), t_s("\\\\site")), "C:\\b\\site");
	T_EQ_OWNED(arz_path_join(t_s("C:/b/"), t_s("/site")), "C:/b\\site");

	/* Multi-component relatives are the ordinary case: every path in
	 * the sidecar is bundle-relative. */
	T_EQ_OWNED(arz_path_join(t_s("C:\\b"), t_s("site\\bin\\a.raku")),
		"C:\\b\\site\\bin\\a.raku");

	/* A path with spaces, which is most of C:\Users\… */
	T_EQ_OWNED(arz_path_join(t_s("C:\\Program Files\\My App"), t_s("native")),
		"C:\\Program Files\\My App\\native");

	/* UNC roots keep both leading separators. */
	T_EQ_OWNED(arz_path_join(t_s("\\\\host\\share\\b"), t_s("site")),
		"\\\\host\\share\\b\\site");

	T_EQ_OWNED(arz_path_join(t_s("C:\\b"), t_s("")), "C:\\b");
	T_EQ_OWNED(arz_path_join(t_s("C:\\b"), NULL), "C:\\b");
	T_EQ_OWNED(arz_path_join(NULL, t_s("site")), "site");
}

static void test_parent_dir(void)
{
	/* The runner walks bin\<exec>.exe up twice to reach the bundle
	 * root, so both steps are this function. */
	T_EQ_OWNED(arz_parent_dir(t_s("C:\\b\\bin\\a.exe")), "C:\\b\\bin");
	T_EQ_OWNED(arz_parent_dir(t_s("C:\\b\\bin")), "C:\\b");
	T_EQ_OWNED(arz_parent_dir(t_s("C:\\b\\bin\\")), "C:\\b");
	/* Forward slashes are accepted as separators, and left as they were
	 * found: this only ever strips, so nothing is normalised behind the
	 * caller's back. */
	T_EQ_OWNED(arz_parent_dir(t_s("C:/b/bin/a.exe")), "C:/b/bin");

	/* A drive root keeps its separator: "C:" alone is drive-relative
	 * and means something else entirely. */
	T_EQ_OWNED(arz_parent_dir(t_s("C:\\a")), "C:\\");

	T_EQ_OWNED(arz_parent_dir(t_s("\\\\host\\share\\b\\bin")),
		"\\\\host\\share\\b");

	/* Nothing to strip: a bare name has no parent, and the win32
	 * layer treats that as "this is not inside a bundle". */
	T_CHECK(arz_parent_dir(t_s("a.exe")) == NULL);
	T_CHECK(arz_parent_dir(t_s("")) == NULL);
	T_CHECK(arz_parent_dir(NULL) == NULL);
}

static void test_expand(void)
{
	/* The four values every ariza bundle's sidecar carries, expanded.
	 * The runner has no idea what any of them are for; it substitutes
	 * one token and hands the result to SetEnvironmentVariableW. */
	T_EQ_OWNED(arz_expand(t_s("inst#{root}\\site"), t_s("C:\\b")),
		"inst#C:\\b\\site");
	T_EQ_OWNED(arz_expand(t_s("{root}\\native"), t_s("C:\\b")),
		"C:\\b\\native");
	T_EQ_OWNED(arz_expand(t_s("{root}\\native\\sqlcipher"),
		t_s("C:\\Program Files\\My App")),
		"C:\\Program Files\\My App\\native\\sqlcipher");

	/* A value need not mention the root at all, and may mention it more
	 * than once. */
	T_EQ_OWNED(arz_expand(t_s("plain"), t_s("C:\\b")), "plain");
	T_EQ_OWNED(arz_expand(t_s(""), t_s("C:\\b")), "");
	T_EQ_OWNED(arz_expand(t_s("{root};{root}\\x"), t_s("C:\\b")),
		"C:\\b;C:\\b\\x");
	T_EQ_OWNED(arz_expand(t_s("{root}"), t_s("C:\\b")), "C:\\b");

	/* `{{` is the way to write a literal brace, so a value that needs
	 * one is expressible rather than a reason to loosen the parser's
	 * refusal of unknown tokens. */
	T_EQ_OWNED(arz_expand(t_s("{{root}"), t_s("C:\\b")), "{root}");
	T_EQ_OWNED(arz_expand(t_s("{{{root}}}"), t_s("C:\\b")), "{C:\\b}}");

	/* Non-ASCII on both sides. */
	T_EQ_OWNED(arz_expand(t_u8("{root}\\café"), t_u8("C:\\Ünïcode")),
		"C:\\Ünïcode\\café");

	T_CHECK(arz_expand(NULL, t_s("C:\\b")) == NULL);
}

static void test_interpreter(void)
{
	T_EQ_OWNED(arz_interpreter_path(t_s("C:\\b")),
		"C:\\b\\rakudo\\bin\\raku.exe");
	T_EQ_OWNED(arz_interpreter_path(t_s("C:\\Program Files\\My App")),
		"C:\\Program Files\\My App\\rakudo\\bin\\raku.exe");
}

static void test_path_prepend(void)
{
	T_EQ_OWNED(arz_env_path_prepend(t_s("C:\\b\\native\\sqlcipher"),
		t_s("C:\\Windows\\system32;C:\\Windows")),
		"C:\\b\\native\\sqlcipher;C:\\Windows\\system32;C:\\Windows");

	/* No trailing ';' when there is nothing to keep: an empty PATH
	 * entry is the current directory to Windows, and a launcher that
	 * quietly adds one has widened the DLL search of every process the
	 * app starts. */
	T_EQ_OWNED(arz_env_path_prepend(t_s("C:\\b\\native\\sqlcipher"), NULL),
		"C:\\b\\native\\sqlcipher");
	T_EQ_OWNED(arz_env_path_prepend(t_s("C:\\b\\native\\sqlcipher"), t_s("")),
		"C:\\b\\native\\sqlcipher");
}

int main(void)
{
	test_path_join();
	test_parent_dir();
	test_expand();
	test_interpreter();
	test_path_prepend();
	return t_done("env");
}
