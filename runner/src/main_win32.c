/* The Windows shell around the portable core: everything that talks to
 * the operating system, and nothing that does not.
 *
 * What it does, in order, is the .cmd launcher's script read out loud:
 *
 *   1. asks Windows where this executable is, and takes the directory
 *      above bin/ as the bundle root — so the bundle stays relocatable
 *      and nothing absolute is baked in anywhere;
 *   2. reads bin/<exec>.ariza beside itself for the four facts that are
 *      per-bundle rather than per-runner;
 *   3. refuses, readably, if the interpreter is not where it should be —
 *      the signature of a half-unpacked archive;
 *   4. applies the sidecar's environment directives in order, without
 *      knowing what any of them mean — `set`, `unset`, `prepend-path`,
 *      with `{root}` expanded to the root it found in step 1;
 *   5. prints the first-run notice once, marked by a file under
 *      %LOCALAPPDATA%\<exec>\ — the only thing any bundle writes outside
 *      its own directory;
 *   6. starts raku.exe on the app's script with the caller's arguments
 *      passed through verbatim, waits, and exits with the child's code.
 *
 * No cmd.exe is involved at any point, which is the reason this exists:
 * a batch trampoline re-parses `%*` (mangling '^', '%x%', '!x!' and
 * quote-heavy arguments), and script-execution policy — AppLocker, SRP,
 * a locked-down ExecutionPolicy — blocks .cmd and .ps1 files however
 * they are invoked, while leaving an .exe alone.  The scripts stay in
 * the bundle as readable alternatives; this is the documented one.
 *
 * A failure here ends the process, so nothing is freed on the way out:
 * the only thing a launcher can usefully do with a broken bundle is say
 * so and stop, and unwinding first would buy nobody anything. */

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>

#include "ariza_runner.h"

/* What the .cmd exits with when it cannot find the interpreter. */
#define ARZ_EXIT_LAUNCH_FAILURE 1

static void write_err(const wchar_t *text)
{
	HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
	DWORD mode;
	DWORD written;
	int bytes;
	char *utf8;

	if (h == NULL || h == INVALID_HANDLE_VALUE || text == NULL)
		return;

	/* A console takes UTF-16 directly; a pipe or a file takes bytes,
	 * and UTF-8 is the only encoding worth writing them in.  Asking
	 * GetConsoleMode which one this is costs nothing and is the
	 * difference between a readable message and mojibake in a
	 * redirected log. */
	if (GetConsoleMode(h, &mode)) {
		WriteConsoleW(h, text, (DWORD)arz_len(text), &written, NULL);
		return;
	}

	bytes = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
	if (bytes <= 1)
		return;
	utf8 = malloc((size_t)bytes);
	if (utf8 == NULL)
		return;
	if (WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8, bytes, NULL, NULL) > 0)
		WriteFile(h, utf8, (DWORD)(bytes - 1), &written, NULL);
	free(utf8);
}

static void err_line(const wchar_t *a, const wchar_t *b, const wchar_t *c)
{
	wchar_t *joined = arz_cat(a, b, c);
	wchar_t *line;

	if (joined == NULL)
		return;
	line = arz_cat(joined, L"\r\n", NULL);
	free(joined);
	if (line == NULL)
		return;
	write_err(line);
	free(line);
}

static void fatal(const wchar_t *a, const wchar_t *b, const wchar_t *c)
{
	err_line(a, b, c);
	ExitProcess(ARZ_EXIT_LAUNCH_FAILURE);
}

static void fatal_oom(void)
{
	fatal(L"ariza: out of memory starting the application.", NULL, NULL);
}

/* The key name, wide, for the one message that needs it.  The core
 * returns an enum precisely so this conversion is a switch here rather
 * than an encoding decision there. */
static const wchar_t *key_wname(arz_key key)
{
	switch (key) {
	case ARZ_KEY_TARGET:
		return L"target";
	case ARZ_KEY_APP_DISPLAY:
		return L"app-display";
	case ARZ_KEY_APP_EXEC:
		return L"app-exec";
	default:
		return L"";
	}
}

/* A number as text, for the two messages that carry one.  No swprintf:
 * the CRT's wide formatting is the one piece of <stdio.h> this program
 * would otherwise need, and both numbers fit in ten digits. */
static void number_to_wide(unsigned long n, wchar_t *buf, size_t cap)
{
	wchar_t rev[24];
	size_t j = 0;
	size_t i = 0;

	if (n == 0) {
		rev[j++] = L'0';
	} else {
		while (n > 0 && j < sizeof(rev) / sizeof(rev[0])) {
			rev[j++] = (wchar_t)(L'0' + (n % 10));
			n /= 10;
		}
	}
	while (j > 0 && i + 1 < cap)
		buf[i++] = rev[--j];
	buf[i] = L'\0';
}

static wchar_t *module_path(void)
{
	DWORD cap = 512;

	for (;;) {
		wchar_t *buf = malloc(cap * sizeof(*buf));
		DWORD n;

		if (buf == NULL)
			return NULL;
		n = GetModuleFileNameW(NULL, buf, cap);
		if (n == 0) {
			free(buf);
			return NULL;
		}
		/* n == cap means truncation, and on older Windows the buffer
		 * is not even terminated — grow rather than trust it. */
		if (n < cap)
			return buf;
		free(buf);
		if (cap >= 65536)
			return NULL;
		cap *= 2;
	}
}

/* bin\<exec>.exe -> bin\<exec>.ariza.  The sidecar is named after the
 * executable rather than after app_exec, because the executable's name
 * is the one thing known before the file is read. */
static wchar_t *sidecar_path(const wchar_t *exe)
{
	size_t n = arz_len(exe);
	size_t base = n;
	wchar_t *stem;
	wchar_t *out;
	size_t i;

	if (n >= 4 && exe[n - 4] == L'.' &&
	    (exe[n - 3] == L'e' || exe[n - 3] == L'E') &&
	    (exe[n - 2] == L'x' || exe[n - 2] == L'X') &&
	    (exe[n - 1] == L'e' || exe[n - 1] == L'E'))
		base = n - 4;

	stem = malloc((base + 1) * sizeof(*stem));
	if (stem == NULL)
		return NULL;
	for (i = 0; i < base; i++)
		stem[i] = exe[i];
	stem[base] = L'\0';

	out = arz_cat(stem, L".ariza", NULL);
	free(stem);
	return out;
}

static int file_exists(const wchar_t *path)
{
	DWORD attrs;

	if (path == NULL)
		return 0;
	attrs = GetFileAttributesW(path);
	return attrs != INVALID_FILE_ATTRIBUTES &&
	       (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

/* Read a UTF-8 file and hand back its text as UTF-16.  `why` is set to a
 * sentence fragment on failure and the return is NULL. */
static wchar_t *read_utf8_file(const wchar_t *path, const wchar_t **why)
{
	HANDLE h;
	LARGE_INTEGER size;
	char *bytes;
	DWORD got = 0;
	DWORD offset = 0;
	int units;
	wchar_t *text;

	h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
		NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
	if (h == INVALID_HANDLE_VALUE) {
		*why = L"it is missing or unreadable";
		return NULL;
	}
	if (!GetFileSizeEx(h, &size)) {
		CloseHandle(h);
		*why = L"its size could not be read";
		return NULL;
	}
	/* A sidecar is a few hundred bytes.  A megabyte of it is not a
	 * sidecar, and reading whatever it is into memory helps nobody. */
	if (size.QuadPart > 1024 * 1024) {
		CloseHandle(h);
		*why = L"it is far too large to be one";
		return NULL;
	}
	if (size.QuadPart == 0) {
		CloseHandle(h);
		text = arz_dup(L"");
		if (text == NULL)
			*why = L"there was not enough memory to read it";
		return text;
	}

	bytes = malloc((size_t)size.QuadPart);
	if (bytes == NULL) {
		CloseHandle(h);
		*why = L"there was not enough memory to read it";
		return NULL;
	}
	while (offset < (DWORD)size.QuadPart) {
		if (!ReadFile(h, bytes + offset, (DWORD)size.QuadPart - offset,
			&got, NULL) || got == 0) {
			CloseHandle(h);
			free(bytes);
			*why = L"it could not be read to the end";
			return NULL;
		}
		offset += got;
	}
	CloseHandle(h);

	/* MB_ERR_INVALID_CHARS, so bad bytes are a refusal rather than a
	 * silent run of U+FFFD in a path. */
	units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes,
		(int)offset, NULL, 0);
	if (units <= 0) {
		free(bytes);
		*why = L"it is not valid UTF-8";
		return NULL;
	}
	text = malloc(((size_t)units + 1) * sizeof(*text));
	if (text == NULL) {
		free(bytes);
		*why = L"there was not enough memory to read it";
		return NULL;
	}
	units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes,
		(int)offset, text, units);
	free(bytes);
	if (units <= 0) {
		free(text);
		*why = L"it is not valid UTF-8";
		return NULL;
	}
	text[units] = L'\0';
	return text;
}

static wchar_t *env_get(const wchar_t *name)
{
	DWORD cap = 256;

	for (;;) {
		wchar_t *buf = malloc(cap * sizeof(*buf));
		DWORD n;

		if (buf == NULL)
			return NULL;
		n = GetEnvironmentVariableW(name, buf, cap);
		if (n == 0) {
			/* Unset, or set to the empty string: the same thing to
			 * everything this program does with one. */
			free(buf);
			return NULL;
		}
		if (n < cap)
			return buf;
		free(buf);
		cap = n + 1;
	}
}

static void env_set(const wchar_t *name, const wchar_t *value)
{
	if (SetEnvironmentVariableW(name, value))
		return;
	/* A deletion is best-effort: removing a variable that was never
	 * there reports ERROR_ENVVAR_NOT_FOUND, which is the ordinary case
	 * for the `unset PERL6LIB` every ariza bundle carries, and not
	 * something to stop a launch over.  A failed *assignment* is
	 * different — the child would run with the wrong environment — so
	 * that one is fatal. */
	if (value == NULL)
		return;
	fatal(L"ariza: could not set ", name, L" for the application.");
}

/* The sidecar's environment directives, in file order.
 *
 * Order is the contract, not an implementation detail: two
 * `prepend-path` lines have to end up in the order they were written,
 * and a `set` after an `unset` of the same variable has to win.  Each
 * prepend reads the PATH the previous one left, which is why this walks
 * rather than batching. */
static void apply_env_ops(const arz_config *cfg, const wchar_t *root)
{
	size_t i;

	for (i = 0; i < cfg->op_count; i++) {
		const arz_env_op *op = &cfg->ops[i];
		wchar_t *value;

		switch (op->kind) {
		case ARZ_OP_UNSET:
			env_set(op->name, NULL);
			break;
		case ARZ_OP_SET:
			value = arz_expand(op->value, root);
			if (value == NULL)
				fatal_oom();
			env_set(op->name, value);
			free(value);
			break;
		case ARZ_OP_PREPEND_PATH: {
			wchar_t *current;
			wchar_t *joined;

			value = arz_expand(op->value, root);
			if (value == NULL)
				fatal_oom();
			current = env_get(L"PATH");
			joined = arz_env_path_prepend(value, current);
			if (joined == NULL)
				fatal_oom();
			env_set(L"PATH", joined);
			free(joined);
			free(current);
			free(value);
			break;
		}
		default:
			/* arz_config_parse produces no other kind; a bundle
			 * that somehow contains one is not one to guess at. */
			fatal(L"ariza: the launcher configuration asks for"
				L" something this runner does not implement.",
				NULL, NULL);
		}
	}
}

/* One notice, once, marked by a file under %LOCALAPPDATA%\<exec>\.
 * Nothing is written into the bundle itself, so a read-only or shared
 * bundle behaves exactly like a private one — and every failure along
 * the way is ignored, because a profile that cannot be written to is a
 * reason to print the notice twice, never a reason not to launch. */
static void first_run_notice(const arz_config *cfg)
{
	wchar_t *base = env_get(L"LOCALAPPDATA");
	wchar_t *dir;
	wchar_t *marker;

	if (base == NULL)
		base = env_get(L"TEMP");

	dir = base != NULL ? arz_path_join(base, cfg->app_exec) : NULL;
	marker = dir != NULL ? arz_path_join(dir, L".first-run") : NULL;

	if (marker != NULL && file_exists(marker)) {
		free(base);
		free(dir);
		free(marker);
		return;
	}

	err_line(cfg->app_display,
		L": first launch can take a few seconds. Later ones are instant.",
		NULL);

	if (dir != NULL)
		CreateDirectoryW(dir, NULL);
	if (marker != NULL) {
		HANDLE h = CreateFileW(marker, GENERIC_WRITE, 0, NULL,
			CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);

		if (h != INVALID_HANDLE_VALUE)
			CloseHandle(h);
	}

	free(base);
	free(dir);
	free(marker);
}

static BOOL WINAPI ctrl_handler(DWORD type)
{
	(void)type;
	/* The console sends Ctrl+C to every process attached to it, so the
	 * child gets its own copy and can shut itself down.  Handling the
	 * event here — by doing nothing with it — keeps the runner alive to
	 * collect the child's exit code, rather than returning the shell's
	 * prompt while the app is still on screen. */
	return TRUE;
}

int wmain(int argc, wchar_t **argv)
{
	wchar_t *exe_path;
	wchar_t *bin_dir;
	wchar_t *root;
	wchar_t *sidecar;
	wchar_t *text;
	const wchar_t *why = L"";
	arz_config cfg;
	size_t bad_line = 0;
	arz_key missing;
	wchar_t *raku;
	wchar_t *target;
	const wchar_t *tail;
	wchar_t *cmdline;
	STARTUPINFOW si;
	PROCESS_INFORMATION pi;
	DWORD code = 0;

	(void)argc;
	(void)argv;

	exe_path = module_path();
	if (exe_path == NULL)
		fatal(L"ariza: Windows would not say where this program is,",
			L" so its bundle cannot be located.", NULL);

	bin_dir = arz_parent_dir(exe_path);
	root = bin_dir != NULL ? arz_parent_dir(bin_dir) : NULL;
	if (root == NULL)
		fatal(L"ariza: \"", exe_path,
			L"\" is not inside a bundle's bin directory.");

	sidecar = sidecar_path(exe_path);
	if (sidecar == NULL)
		fatal_oom();

	text = read_utf8_file(sidecar, &why);
	if (text == NULL) {
		/* `why` rather than one message for four causes: "it is
		 * missing" sends someone to their unpack, "it is not valid
		 * UTF-8" sends them to whatever edited it, and a launcher that
		 * cannot tell them apart sends them to neither. */
		err_line(L"ariza: cannot read the launcher configuration at \"",
			sidecar, arz_cat(L"\" — ", why, L"."));
		err_line(L"  Unpack the whole archive and run this program"
			L" from inside it.", NULL, NULL);
		ExitProcess(ARZ_EXIT_LAUNCH_FAILURE);
	}

	if (arz_config_parse(text, &cfg, &bad_line) != ARZ_OK) {
		wchar_t number[24];

		number_to_wide((unsigned long)bad_line, number,
			sizeof(number) / sizeof(number[0]));
		err_line(L"ariza: \"", sidecar, L"\" is not a launcher"
			L" configuration this runner can read.");
		err_line(L"  Line ", number, L" is neither a comment nor a"
			L" directive it implements; this bundle is damaged.");
		ExitProcess(ARZ_EXIT_LAUNCH_FAILURE);
	}

	missing = arz_config_missing(&cfg);
	if (missing != ARZ_KEY_NONE)
		fatal(L"ariza: \"", sidecar,
			arz_cat(L"\" does not set ", key_wname(missing),
				L"; this bundle is damaged."));

	raku = arz_interpreter_path(root);
	target = arz_path_join(root, cfg.target);
	if (raku == NULL || target == NULL)
		fatal_oom();

	if (!file_exists(raku)) {
		/* Same first line, word for word, as the .cmd and .ps1
		 * launchers print: whichever entry point a user reached, the
		 * search that follows should find one answer. */
		err_line(cfg.app_display,
			L": this bundle is incomplete - no interpreter at \"",
			arz_cat(raku, L"\"", NULL));
		err_line(L"  Unpack the whole archive and run this program"
			L" from inside it.", NULL, NULL);
		ExitProcess(ARZ_EXIT_LAUNCH_FAILURE);
	}

	/* Whatever the bundle said, in the order it said it.  What those
	 * variables are for — that RAKULIB has to name an installation
	 * repository, that PERL6LIB has to be removed rather than emptied,
	 * that a bundled DLL is found by walking PATH — is knowledge held
	 * by the renderer that wrote the sidecar, and deliberately not by
	 * this program. */
	apply_env_ops(&cfg, root);

	first_run_notice(&cfg);

	/* The arguments, exactly as the user's shell produced them: find
	 * where argv[0] ends and copy everything after it. */
	tail = arz_cmdline_tail(GetCommandLineW());
	cmdline = arz_child_cmdline(raku, target, tail);
	if (cmdline == NULL)
		fatal_oom();

	SetConsoleCtrlHandler(ctrl_handler, TRUE);

	ZeroMemory(&si, sizeof(si));
	si.cb = sizeof(si);
	ZeroMemory(&pi, sizeof(pi));

	/* lpApplicationName names the interpreter exactly, so no search
	 * path decides which raku.exe runs; lpCommandLine still opens with
	 * it, because that is what the child reads as its own argv[0].
	 * Handles are inherited and no creation flag is passed, so the
	 * child shares this console: a TUI needs the real one, and a
	 * redirected run needs the pipes. */
	if (!CreateProcessW(raku, cmdline, NULL, NULL, TRUE, 0, NULL, NULL,
		&si, &pi)) {
		wchar_t buf[24];

		number_to_wide((unsigned long)GetLastError(), buf,
			sizeof(buf) / sizeof(buf[0]));
		err_line(cfg.app_display,
			L": could not start the interpreter at \"",
			arz_cat(raku, L"\" (Windows error ",
				arz_cat(buf, L").", NULL)));
		ExitProcess(ARZ_EXIT_LAUNCH_FAILURE);
	}

	WaitForSingleObject(pi.hProcess, INFINITE);
	if (!GetExitCodeProcess(pi.hProcess, &code))
		code = ARZ_EXIT_LAUNCH_FAILURE;
	CloseHandle(pi.hThread);
	CloseHandle(pi.hProcess);

	free(cmdline);
	free(raku);
	free(target);
	free(sidecar);
	free(text);
	free(exe_path);
	free(bin_dir);
	free(root);
	arz_config_free(&cfg);

	return (int)code;
}

#else

/* A POSIX test build compiles the core and nothing else; this file has
 * no business there, and an empty translation unit is not valid C. */
typedef int arz_main_win32_is_windows_only;

#endif /* _WIN32 */
