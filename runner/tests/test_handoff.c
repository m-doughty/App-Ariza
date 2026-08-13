#include <stdlib.h>

#include "support.h"

static const char *NONCE =
	"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

static void accepts_protocol_record(void)
{
	arz_handoff handoff;
	const arz_char *text = t_s(
		"protocol=1\n"
		"nonce=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
		"candidate=01.002.3\n");

	T_CHECK(arz_handoff_parse(text, &handoff) == ARZ_OK);
	T_EQ(handoff.candidate, "01.002.3");
	T_CHECK(arz_handoff_nonce_matches(&handoff, t_s(NONCE)));
	T_CHECK(!arz_handoff_nonce_matches(&handoff, t_s(
		"1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")));
	arz_handoff_free(&handoff);

	T_CHECK(arz_handoff_parse(t_s(
		"protocol=1\n"
		"nonce=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n"
		"candidate=1.2.3"), &handoff) == ARZ_OK);
	T_EQ(handoff.candidate, "1.2.3");
	arz_handoff_free(&handoff);
}

static void rejects_untrusted_shapes(void)
{
	const char *bad[] = {
		"",
		"p",
		"protocol=1",
		"protocol=2\nnonce=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\ncandidate=1.2.3\n",
		"protocol=1\nnonce=ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789\ncandidate=1.2.3\n",
		"protocol=1\nnonce=short\ncandidate=1.2.3\n",
		"protocol=1\nnonce=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\ncandidate=v1.2.3\n",
		"protocol=1\nnonce=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\ncandidate=1.2.3-rc1\n",
		"protocol=1\ncandidate=1.2.3\nnonce=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n",
		"protocol=1\nnonce=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\ncandidate=1.2.3\npath=C:\\evil.exe\n",
	};
	size_t i;

	for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
		arz_handoff handoff;
		T_CHECK(arz_handoff_parse(t_s(bad[i]), &handoff) == ARZ_E_SYNTAX);
	}
}

int main(void)
{
	accepts_protocol_record();
	rejects_untrusted_shapes();
	return t_done("handoff");
}
