# ariza — design record

Decisions and their reasons. The README says how to use ariza; this says
why it is shaped the way it is, and what each shape is protecting
against. Where a decision arrived with a release, the release and its
date are named — `Changes` has the full entry.

Everything here is a ruling that something in `lib/` or `resources/`
now depends on. If one of them stops being true, the code is what has to
change, not this file.

---

## 1. Why a bundle, and not a zef install

ariza packages Raku TUI applications — Cantina, Kelpie, Mindmoor,
Moneymoor — for people who do not have Raku and should not have to care
that the thing is written in it.

The alternative was the one every Raku project starts with: tell the
user to install Rakudo, then `zef install App::Whatever`, then install
the native libraries their platform spells differently from everyone
else's. For a developer that is a two-minute job. For the person these
apps are actually for it is a support conversation with five branches
in it, most of which end in a compiler error inside a dependency they
have never heard of.

So the end state ariza is built towards is a **bundle**: one archive per
platform containing the application, a Rakudo runtime, every Raku
dependency, and every native shared library the app touches —
notcurses, SQLCipher, libvips — laid out so that unpacking it anywhere
and running a single launcher works.

The properties that matter, and that shape everything below:

- **Self-contained.** Nothing is fetched at run time and nothing is
  assumed to be present. A machine with no Raku, no Homebrew and no
  compiler runs the app.
- **Per-platform, and honest about it.** A glibc binary does not run on
  Alpine; an arm64 dylib does not run on an Intel Mac. Every artefact is
  named after exactly one platform slug and contains binaries for
  exactly that platform.
- **Relocatable.** No absolute paths baked in, no install step, no PATH
  surgery. It runs from a home directory, a USB stick or `/opt`.
- **Removable.** Deleting the directory removes the software. Nothing is
  registered, nothing is scattered, nothing is left behind.

The corollary, taken in 0.0.1 (2026-08-12): there is exactly **one**
distribution mechanism. The legacy installer machinery — `App::Ariza::Legacy`,
eight templates and two shell partials, per-app configs, a SQLCipher
mirror reference, `ariza render-legacy` and a parity test — was retired
in that release rather than carried alongside the bundle path. Apps get
retired rather than carried, and an app that is ready to ship ships the
way Moneymoor does: a bundle, four generated installer scripts, two
workflows. Keeping a second mechanism alive for one unreleased app meant
two ways to install everything, two things to keep true of every pin
bump, and a parity gate that could only ever say "the old thing still
renders the old bytes".

The absorption was not wasted. The parts of the legacy partials a bundle
installer still needs — the marker-block PATH persistence, the shell-rc
detection — were adapted into
`resources/templates/installer-common-{posix.sh,windows.ps1}`. What was
deleted is only what drove package managers, refcounted a shared
registry and installed a terminal emulator: everything a bundle exists
to not do.

---

## 2. The vendored runtime, the closure, and the warm store

**The runtime** is the official archive from `rakudo.org`, pinned by
`[rakudo]` in `versions.toml`, downloaded once into
`$XDG_CACHE_HOME/ariza/rakudo` and unpacked into the bundle. The cache
records a SHA-256 on first download and verifies it on every reuse.

**The Raku closure** is installed by the **bundled** `zef` into the
bundle's own repository, so the precompiled bytecode matches the runtime
that ships rather than whatever Rakudo the build machine had. Using the
system zef would work, and would produce a bundle that recompiles its
entire closure on first launch, because precompiled bytecode is tied to
the exact Rakudo that produced it.

**The bytecode is warmed at build time.** `zef` does not do this, and it
matters: a cold bundle spends about 55 seconds compiling on its first
launch — measured for Moneymoor, against ~0.5s once warm — and does it
again on every launch if the bundle happens to live somewhere
unwritable, which for a downloaded archive is normal. Even with the
repository in the chain, `zef install` leaves most of the closure
uncompiled, because the first process to `use` a module is what compiles
it; so `build-site` loads every module the app distribution `provides`,
under the bundled runtime, with the bundle's environment, and the
transitive closure comes in as a side effect of loading what uses it.
The store is content-addressed and position-independent, so warming it
at build time and unpacking the archive somewhere else entirely —
including a path with spaces — loads the same bytecode. That is
verified, not assumed.

**The launcher** is the one file a user runs, and the only file in the
bundle they are ever expected to touch. It finds its own bundle by
resolving its own path through a `readlink` loop, not `readlink -f`,
which is a GNU extension absent from macOS before Monterey and from the
BSDs — a launcher that only resolves symlinks on Linux breaks the moment
someone puts one in `~/bin`. It exports `RAKULIB=inst#<root>/site` and
unsets `PERL6LIB`, so the bundle's repository is the *only* one: a
`RAKULIB` left in the user's environment would otherwise put modules
compiled against a different Rakudo ahead of the bundle's. It exports
`NOTCURSES_NATIVE_DATA_DIR` and deliberately **not**
`NOTCURSES_NATIVE_LIB_DIR`, which suppresses Notcurses::Native's own
`TERMINFO_DIRS` setup and leaves a TUI without terminfo. Everything is
quoted, so a path with spaces works.

Two smaller rulings live in the launcher. A wrong `TERM` produces a
**warning, never a refusal**: `TERM` is frequently wrong in environments
where the app still runs fine, and a launcher that second-guesses the
user's terminal is worse than one that mentions it. And the first launch
prints one notice about paging a few hundred megabytes off disk, marked
by a single file under `XDG_STATE_HOME` — the only thing any bundle
writes outside its own directory.

---

## 3. Native self-containment, and an audit that refuses to ship

Native libraries are staged and then **audited**: every Mach-O, ELF or
PE ariza put in the bundle must resolve inside it, or the build fails
naming the file and the dependency. That is the difference between a
bundle that works on the machine that built it and one that works
anywhere.

The audit is not advisory. It is the last step before an archive is
written, and a finding stops the build. This matters more than it
sounds, because every machine likely to run it is a machine where the
gap it is looking for is invisible.

### 3.1 macOS

A Homebrew library names its dependencies by absolute path, so the
problem is obvious and the fix is mechanical: copy each non-system
dependency in beside the library, rewrite the load commands with
`install_name_tool` so they resolve relative to the bundle, and
re-`codesign` anything that was modified.

### 3.2 Linux, and why it needs a Linux machine

ELF hides the same problem better than Mach-O does, which is why it went
unnoticed longer. A Homebrew library names its OpenSSL by absolute path,
so it is obvious. A distribution's `libsqlcipher.so.0` names its OpenSSL
as a bare `NEEDED libcrypto.so.3` — no path, no `RPATH`, nothing in the
file for an audit to object to — and at run time that means "whatever
`libcrypto.so.3` this machine has", which on a user's machine may be
nothing at all.

So a Linux bundle gets the same treatment a macOS one does, spelled the
way ELF spells it: `ldd` (the loader itself, so its answer is the one
the machine will really give) reports where each dependency resolves;
every non-system one is copied in beside the library under its soname
and recursed into; and `patchelf --set-rpath '$ORIGIN'` on the library
and every copy makes each find its siblings in its own directory
wherever the bundle is unpacked.

What stays dynamic is the loader, `libc` and the compiler runtime — a
second copy of those is a conflict, not insurance. `libcrypto` and
`libssl` are **not** in that category: SQLCipher without OpenSSL is
SQLite.

The audit then adds two checks that only exist on a Linux host, because
both tools answer for the machine they are on: `patchelf --print-rpath`
must be `$ORIGIN`-relative, and `ldd` run with the environment
**replaced** by a bare `PATH` — the user's view, not the build's — must
resolve every non-system dependency inside the bundle. Cross-inspecting
an ELF from a Mac does the static half and says so, rather than
pretending to more; which is the long way of saying the Linux bundle is
built on Linux.

That claim is proved rather than asserted.
`xxt/linux-selfcontain-proof.sh` runs the whole thing in a `manylinux`
container — real SQLCipher, real Rakudo, the test suite, a real bundle
staged and audited, the result re-checked independently in shell, and
three negative controls (a planted absolute `NEEDED`, a deleted
dependency, a stripped rpath) that must each make the audit fail.

### 3.3 Windows, and why it needs no Windows machine

PE hides it worst of all, because it records nothing to hide. A vcpkg
`sqlcipher.dll` imports `libcrypto-3-x64.dll` by bare name — no path, no
`rpath`, nothing in the file that an audit reading tags could object to
— and a bundle staging the DLL alone does not load the user's OpenSSL
the way the Unix failure does. It does not load **at all**:
`LoadLibrary` fails resolving imports, and the app reports
`DBDish::SQLCipher needs 'sqlcipher.dll', not found` — a message about
the file that is there, produced by the file that is not.

This is the bug fixed in 0.0.6 (2026-08-12), and it is worth recording
that the two previous fixes for the same symptom (0.0.5's `runtime-env`
PATH, 0.0.4's `zef.raku`) were both real bugs and neither could have
made it go away, because there was no OpenSSL in the bundle for any PATH
to point at.

So a Windows bundle gets the same walk-and-copy, spelled the way PE
spells it. ariza reads the DLL's own import table — DOS header, PE
signature, optional header, data directory, section table; about eighty
lines of Raku, because there is no tool to shell out to. `dumpbin` ships
with Visual Studio and `objdump` with neither, and a dependency walk
that silently finds nothing when its helper is missing is how this hole
stayed open. Everything that is not Windows' own — not `KERNEL32`, not
the API sets, not the Visual C++ redistributable (§3.4) — is copied in
beside the library and recursed into. There is no third step: Windows
resolves imports from the importing module's own directory, so putting
them in one directory *is* the relocation story.

The search space is exactly one directory: the one the library came
from. Both Windows package managers install a port's whole runtime
closure into a single `bin` — vcpkg's `installed/<triplet>/bin`, MSYS2's
`ucrt64/bin` — so `sqlcipher.dll`'s OpenSSL is the file sitting next to
it, and searching wider (`PATH`, `System32`) would find a same-named DLL
from a different build of a different version, which is the bug a bundle
exists to avoid. An import that is not there fails the build, naming it
and the directory searched.

And unlike the Linux pass, none of this needs the platform it is for:
reading a PE's imports means reading bytes, not running a loader. A
Windows bundle can be assembled, walked and audited from a Mac and get
exactly the same verdict it would get on Windows — which makes Windows,
counter-intuitively, the platform ariza cross-builds most completely.

### 3.4 The one import that looks like Windows and is not

`vcruntime140.dll` is on the skiplist — ariza does not copy it in — and
the audit reports it anyway when the bundle does not carry it, because
it is not part of Windows. The Visual C++ Redistributable arrives with
Visual Studio, with its own installer, or dragged in by some other
application; `kernel32.dll` and `ucrtbase.dll` are in `System32` on
every Windows 10 machine ever installed, and `vcruntime140.dll` is not
on any of them by default.

That makes it the worst kind of dependency to have: a DLL importing it
loads on the machine that built the bundle, on every CI runner, and on
most developer laptops — and refuses to load on a clean install, which
is the only machine a bundle exists for. Every machine likely to run the
audit is a machine where the gap is invisible; the release lane in
particular could not have caught it, because a GitHub runner has the
redistributable.

An MSVC-built SQLCipher imports it; that is why ariza's own CI lane
takes MSYS2's UCRT package instead of vcpkg's port. If one is staged
anyway the audit fails the build and says all of that, because the
person reading the failure has just watched the bundle work. Carrying
the runtime in the bundle satisfies the check too — it is containment
that is being asked about, not abstinence — but ariza will not copy it
in on an author's behalf: it is Microsoft's to redistribute, on
Microsoft's terms, and app-local deployment of it is a decision that
belongs to whoever signs the release.

The gate is a family, not one file: `vcruntime*.dll`, `msvcp*.dll`,
`concrt*.dll`, `vcomp*.dll`. `ucrtbase.dll` is deliberately **not** in
it, which is the entire reason a UCRT build is the answer and not
another instance of the question. (Unreleased, following 0.0.6,
2026-08-12.)

---

## 4. Where SQLCipher is allowed to come from

notcurses arrives on its own — Notcurses-Native's prebuilt pack is
staged as a side effect of the `zef` install. SQLCipher has no such
hook, so ariza takes it from the build machine's own package manager:

- **macOS** — the installed Homebrew keg (`brew --prefix sqlcipher`),
  or, if it is not installed, the bottle `brew fetch --formula sqlcipher`
  puts in the cache.
- **Linux** — whatever `ldconfig -p` resolves `libsqlcipher.so.0` to,
  falling back to the Debian multiarch, Red Hat and Alpine library
  directories. CI installs the distribution package before it calls
  `ariza bundle`.
- **Windows** — an MSYS2 environment's `bin` (`MSYSTEM_PREFIX`, then
  `C:\msys64\ucrt64\bin`), a vcpkg tree under `VCPKG_ROOT`, or wherever
  `SQLCIPHER_LIB_DIR` points.

### 4.1 No mirror

There is deliberately **no** ariza-operated mirror to download from.
SQLCipher's ABI does not move often enough to justify a second piece of
release infrastructure with its own signing story, its own staleness and
its own outages — and what makes a library safe to redistribute is not
where it was downloaded from but what happens to it next: every
dependency it names outside the bundle is copied in beside it and
rewritten to load from there, and the audit then refuses to ship the
bundle if anything still points off the machine.

### 4.2 Two package managers, two names, one staged file

vcpkg's port produces `sqlcipher.dll` and MSYS2's produces
`libsqlcipher-0.dll`. ariza accepts either — the canonical name wins
where it is found, per directory, in priority order, matched
case-insensitively as the loader matches it; where no directory holds it
the search widens to `libsqlcipher*.dll`, newest first by the same
numeric-aware comparison the Linux pass uses for EPEL's renamed soname
— and stages whatever it finds under the canonical one.

That rename is safe for exactly the reason the Linux one is:
`LoadLibrary` resolves a DLL by the leaf name on disk and never consults
the module's internal name, just as `dlopen` never consults `DT_SONAME`.
The manifest's `origin` records what was actually found, so nothing is
quietly renamed behind the author's back. (Unreleased, following 0.0.6,
2026-08-12.)

### 4.3 UCRT, not MSVC

ariza's own Windows CI lane installs `mingw-w64-ucrt-x86_64-sqlcipher`
with the `pacman` every windows runner already has at `C:\msys64`,
rather than building vcpkg's port. Two reasons, and the first is §3.4:
an MSVC build imports `vcruntime140.dll` and an MSYS2 UCRT build imports
`ucrtbase.dll`, which Windows 10 and later ship. The second is
mechanical — the MSYS2 package is prebuilt where the vcpkg port was a
fifteen-minute source build, which is why the lane used to carry an
`actions/cache` restore/save pair wrapped around it. Both are gone.
`pacman -Sy` refreshes the databases first, deliberately: the runner
image's copy is as old as the image, and MSYS2's mirrors keep only
current versions, so a stale database sends pacman after a file that is
no longer there.

vcpkg is still probed rather than dropped — a machine that has only that
should build rather than stop — and the audit is what refuses to ship
the result.

### 4.4 The overrides, and the cross-build refusal

Two overrides beat the package managers, in this order:
`--sqlcipher-archive=FILE` (an archive to unpack) and
`SQLCIPHER_LIB_DIR` (a directory holding the library). Both are how a
cross-build works, because they are the only way to be honest about it:
a library installed on this machine is built **for** this machine, so
ariza refuses to take one when the platform being built is not the
platform it is building on. Missing entirely, on any platform, is a
death naming the package to install **and** the override to pass — never
a silent bundle without a database.

### 4.5 The pin is advisory, the manifest is not

The version in `versions.toml` is **advisory**. The package manager
decides what is actually installed, so ariza reads the version out of
the staged library's own bytes and warns if it disagrees with the pin:

```console
ariza: sqlcipher 4.17.0 staged, pin says 4.14.0
```

The build continues, and `ariza-manifest.json` records the version that
was **staged**, the pin beside it, the digest of the library as it came
off the machine, and which keg, bottle or archive it came from. A
manifest that quotes a number nobody verified is worse than no number at
all.

---

## 5. Proving it, rather than hoping: the smoke harness

`ariza smoke` takes the finished archive, unpacks it into a scratch
directory **with a space in its name**, and runs it with a **replaced**
environment — `PATH`, `HOME`, `TERM` and nothing else (plus the handful
of variables without which no process starts on Windows).

**The replaced environment is the point.** `run`'s `:env` substitutes
the child's whole environment, which is `env -i` without needing `env`.
The failure this catches is a bundle that quietly uses something from
the developer's shell — a system Rakudo on `PATH`, a
`DBIISH_SQLCIPHER_LIB` pointing into Homebrew, a `RAKULIB` that already
has the app installed in it. Any of those makes a broken bundle look
perfect on the machine that built it.

**The space in the path is also the point.** `ariza smoke 51234-882931/`
is where the bundle goes, and if the launcher's quoting slips anywhere,
that is what notices — before a user with `~/Application Support/` or
`C:\Program Files\` does.

**Two environments, for two kinds of command.** A command that starts
with `{exec}` goes through the launcher, so it gets the bare environment
above: that run is a test of the launcher's ability to set up its own
world. A command that starts with `{raku}` drives the bundled
interpreter directly, standing in for code running *inside* the app, so
it additionally gets exactly what the launcher would have exported —
`RAKULIB`, `NOTCURSES_NATIVE_DATA_DIR`, and the SQLCipher variables:
`LD_LIBRARY_PATH` on Linux, and on Windows a `PATH` prepended with the
DLL's directory, since that is how Windows resolves a library by name
(0.0.5, 2026-08-12). Without any of that it would be testing the absence
of a launcher rather than the bundle.

**Nothing goes through a shell**, in any form, which is what makes it
reasonable for an app to smoke-test its database engine rather than only
`--version`: the argv shape can carry an entire Raku program with no
quoting layer to get wrong.

**Every check runs; nothing short-circuits.** "The launcher failed" and
"the launcher failed *and* the audit found a stray library" are
different bug reports and should not require two runs to distinguish.

**Failure leaves the evidence.** On success the scratch directory is
removed; on failure — or with `--keep` — it stays, and its path is
printed. The whole value of a failed smoke is the state it failed in.

One check exists for a bug that nothing else would catch. The manifest
check asserts the *shape* — that every entry in `dists` is an object
with a name — because a Raku `{ }` literal whose body starts with a
`.method` call is parsed as a **Block**, and a Block of pairs serialises
as an array of one-key objects, producing a manifest that parses, reads
plausibly and lists nothing at all. The `precomp` check is the same
class of thing: an empty precompilation store is not a crash, it just
makes every launch slow, forever, on a read-only bundle.

---

## 6. Getting a bundle onto a machine

A bundle is self-contained, so "installing" it is unpacking it somewhere
and running the launcher. The generated installers do exactly that, and
nothing more.

### 6.1 One POSIX script, not two

The installer scripts that came before a bundle shipped
`install-macos.sh` and `install-linux.sh` separately, because they did
genuinely different things: one drove Homebrew, the other five package
managers. A bundle installer does none of that, so the only
per-platform decision left is which asset to download, and that is a
`uname` call away at run time. One script, one `curl` line in a README,
and nobody has to work out which of two files applies to them.

### 6.2 It is meant to be piped, so it never asks

A script read from a pipe is executed as it arrives, so the generated
one is entirely definitions with a single `main "$@"` on the last line:
a truncated download cannot half-run it. It also never reads standard
input — no prompts, no confirmations — because when the script arrives
*on* standard input there is nothing left to read from. That is not a
limitation to work around; it is what makes the thing runnable from CI.

### 6.3 Nothing that exists is touched until the new tree is complete

The download unpacks into `$XDG_DATA_HOME/<exec>/versions/<version>/`,
beside whatever is already there, and only then is the `current` symlink
flipped and `~/.local/bin/<exec>` linked at it. A failed or interrupted
download cannot damage a working install. One previous version is kept,
so a bad release can be rolled back by hand, and anything older is
pruned with a line saying which.

`~/.local/bin` goes on `PATH` **only if it is not there already**,
through one marked block appended to each shell rc file that exists.
Re-running never duplicates it; the uninstaller removes exactly that
block and nothing else.

It does not create desktop entries, register file associations, install
a terminal emulator, or write to any shared location. A bundle needs
none of it, and the shared registry the older installer scripts kept
existed only to refcount things this one never installs.

### 6.4 Re-running is a repair

Asking for a version that is already installed does not re-download it:
the existing tree is checked, both links are re-pointed, the PATH block
is re-checked, and the script exits 0 saying "already installed". That
makes "run the installer again" the correct advice for the most common
breakage — a link someone deleted, or a shell that never picked up
`PATH`. An existing version directory with no runnable launcher in it is
not a version, and is replaced rather than trusted.

### 6.5 The escape hatch, and the one flag it applies to

`--url` (and `<EXEC>_BUNDLE_URL`) installs from a source the user names
and bypasses GitHub entirely. It takes a **plain file path** as readily
as a URL, which is what makes an air-gapped install, a release
candidate, and ariza's own end-to-end test possible with no network and
no published release.

`--insecure-no-verify` applies to **that path only**. A source someone
named themselves may legitimately have no `.sha256` beside it, and the
script says so loudly before continuing; a published release always has
one, so a missing digest there stays fatal however many flags are
passed.

The default source is the latest release, read from the `location:`
header of `https://github.com/<owner>/<repo>/releases/latest`: one HEAD
request, no API token, no `jq`.

### 6.6 Windows

The same shape in PowerShell: `%LOCALAPPDATA%\<Display>\versions\<version>`,
a `current` **junction** rather than a symlink — which would need
administrator rights or Developer Mode, and a per-user install has no
business demanding either — and `...\current\bin` added once to the user
`PATH` in `HKCU\Environment`. Because the PATH entry points through the
junction, an upgrade needs no PATH change at all.

---

## 7. The release pipeline

`ariza bundle` builds one bundle, on one machine, for the platform that
machine is. A release needs one per declared platform, each built on a
machine that **is** that platform — SQLCipher comes off the build host,
so there is no cross-build to fall back on — and all of them published
together. That is a CI problem, and `ariza scaffold-ci` writes the CI.

Neither generated file is ariza's to run. Both are committed to the
**app's** repository and run by GitHub, exactly as `install.sh` is
committed and run by a user. ariza's job is to make sure the file says
the right thing about this app.

### 7.1 The Linux lane's shape

It builds inside `quay.io/pypa/manylinux_2_28_x86_64` so the archive's
glibc floor is 2.28 — RHEL 8+, Ubuntu 18.10+, Debian 10+ — rather than
whatever `ubuntu-latest` happens to ship this month; a bundle cannot be
older than the machine that built it. And `Raku/setup-raku` cannot
install into a container (it writes to the runner's tool cache, which is
not in the container's filesystem), so the lane resolves the `[rakudo]`
pin against the same JSON release index `App::Ariza::Rakudo` reads and
unpacks the archive itself. There is no URL to construct — upstream
filenames carry a toolchain suffix — so the index is the only honest
route.

### 7.2 Which Raku is which

Every lane installs a Raku **to run ariza with**, and it is not the
runtime that ends up in the bundle: ariza downloads the pinned Rakudo
for itself, verifies it, and unpacks that into the archive. The lane's
own Raku can be any version, which is why `setup-raku` asks for `latest`
rather than for anything in particular.

### 7.3 Dispatch before you tag

The workflow triggers on `workflow_dispatch` as well as on
`push: tags: ['v*']`, and a dispatch run **stops after the build lanes**:
`publish` and every `smoke-installer-*` job are gated on
`startsWith(github.ref, 'refs/tags/')`.

That is the iteration loop, and the reason the dispatch trigger exists.
A recipe that has gone stale — a renamed package, a runner image that
moved on, a package version the mirror no longer keeps — costs a run and
a push to a branch, rather than a burnt tag and a deleted release. The
dispatch input `ref` takes a branch, so the lane being fixed does not
have to be on the default branch to be tried.

Every one of those hazards has been real. 0.0.3 and 0.0.4 (2026-08-12)
between them fixed a dead configure flag (`--enable-tempstore`, which
SQLCipher's move to SQLite's autosetup respells `--with-tempstore`), an
OpenSSL 3 requirement EL8 parallel-ships rather than installing as the
system OpenSSL, a library autosetup names `libsqlite3` unless told
otherwise, an `ldconfig`-based sanity check that could never match
because the SONAME is deliberately `libsqlite3.so.0`, and a
`shell: bash` default that made zef resolve `tar` off Git Bash's MSYS
build, which reads a leading `C:` as a remote hostname.

### 7.4 The publish gate

`publish` collects every lane's artefact, flattens it, recomputes a
combined `checksums.txt`, and checks that against the `.sha256` sidecars
`ariza bundle` wrote — a release whose digest refuses its own archive is
worse than one with no digest — before cutting the GitHub release with a
body saying what a bundle is, which machines each archive runs on, and
how to verify a download.

### 7.5 One installer smoke per platform

0.0.3 (2026-08-12) generalised what had been a Linux-only job. Every
declared platform with a GitHub-hosted runner gets its own
clean-machine installer smoke: `smoke-installer-macos-arm64`,
`smoke-installer-linux-x86_64-glibc`, `smoke-installer-windows-x86_64`.
Each takes the archive that was **just published**, on a plain runner
with nothing installed on it, installs it with the repository's own
committed `install.sh` or `install.ps1`, and runs the installed launcher
under a stripped environment — `env -i` on POSIX, a from-scratch
`System.Diagnostics.Process` on Windows, which has no `env -i`.

The principle: these are the only jobs that exercise the artefact a user
will actually receive, by the path they will actually take. Everything
before them tests something ariza made; this tests what a stranger
downloads. macOS's is incidentally the only place `install.sh`'s BSD
branches (`shasum -a 256`, bsdtar) ever run in CI.

The macOS/Linux/Windows split lives in one place, `%LANES` in
`App::Ariza::CI`, alongside each platform's build lane. A platform with
a build lane but no smoke recipe yet renders no smoke job and a comment
in the workflow says so, instead of silently having none.

### 7.6 What is regenerated, and what is yours

`release.yml` is **derived** from `bundle.platforms`: add a platform,
re-run `scaffold-ci`, and the file gains a lane and a `needs:` entry. It
is rewritten in place every time, so a hand edit to it is an edit you
will make twice.

`test.yml` is written **only when it is absent**. A test workflow
acquires system dependencies, extra jobs and skip conditions that no
generator can infer from a manifest — the scaffolded one is a starting
point in the house shape, and the moment it is committed it is the
repository's. `--force` overwrites it anyway, for when the house shape
has moved on and the local edits are known to be nothing. Each generated
file's header says which of the two it is, so nobody has to remember.

For the same reason, an app whose **test suite** needs its native
libraries has to add those steps itself: `bundle.native` says what a
*bundle* carries, which is a different question from what a test run
needs on the runner. The scaffolded `test.yml` names the libraries and
says it is not installing them, rather than guessing either way.

### 7.7 The platforms it will scaffold

`macos-arm64`, `linux-x86_64-glibc` and `windows-x86_64`: the slugs with
both a GitHub-hosted runner and an official Rakudo build behind them. A
declared platform outside that set is a **hard error**, not a skipped
job — the same reasoning as an unknown slug in `bundle.platforms`, since
silently dropping one produces a release quietly missing a platform the
author asked for. A bundle for one of the other five is built by hand
today, and a generated lane for it would be a guess rather than a
recipe.

---

## 8. Configuration rulings

### 8.1 The app declares; ariza does not know about apps

What a given app needs is declared by that app, in an `ariza.toml` in
its own repository — so ariza stays a general tool instead of growing a
list of special cases about specific applications. All three `[app]`
keys are required, and `display` is required rather than derived because
the correct capitalisation of a product name is not something a tool
should guess at.

### 8.2 Declared platforms are enforced

Building a platform the app does not list in `bundle.platforms` is an
error: an app that lists its platforms has said which ones it is tested
on, and producing an artefact named after one it never claimed is a
promise ariza has no business making on its behalf. The same list is
what the generated installers detect against, so an app that has never
built for musl says so on an Alpine box rather than downloading
something that cannot run there.

### 8.3 Unknown keys warn; wrong types die

The house rule, shared with `App::Shigur`: an unrecognised key at any
level is collected into `warnings` and loading continues, so one file
can serve several ariza versions in either direction. A wrongly-*typed*
value dies immediately, naming the dotted path and the expected shape —
`ariza: bundle.platforms must be an array of strings` — because a
mistyped pin would otherwise be silently baked into an artefact. Keys
beginning with `//` are ignored entirely, without a warning, in every
ariza config file; TOML has real comments, so the convention is
redundant there, and it is kept only so a config author never has to
remember which format they are in.

### 8.4 The closed sets

There are exactly three value-level exceptions to "unknown warns", and
each is a set that cannot grow by a user's typo:

- **A platform slug** in `bundle.platforms` dies rather than warning. A
  typo cannot be a future feature, and ignoring it would ship a release
  quietly missing a platform the author asked for. `macos-aarch64` for
  `macos-arm64` is the mistake this catches.
- **`installer.repo`** must be a bare GitHub `owner/name`. It is
  interpolated straight into three URLs, so anything that is not that
  shape produces a 404 at the one moment a user is least equipped to
  debug it.
- **`ARIZA_PLATFORM`** must name a known slug. Every other input to
  detection is a system fact that might legitimately be unnameable, but
  an override is a human typing a string, and quietly ignoring a
  misspelled one would produce an artefact for the wrong platform.

`ci.ariza-source` is deliberately *not* closed — it is anything
`zef install` accepts — so only an **empty** value is an error, because
that would render a step that installs nothing and succeeds.

### 8.5 Platform slugs belong to Notcurses-Native

The eight slugs are not ariza's to choose. They are Notcurses-Native's
platform slugs, character for character, because a bundle carries that
distribution's prebuilt notcurses libraries and the two have to agree
about what platform they are on. Detection on Linux probes for a musl
loader first (its presence is conclusive) and falls back to parsing
`ldd --version`; a system with neither — uclibc, a static busybox image
— produces an honest "unsupported platform" rather than a bundle that
will not run.

### 8.6 One pin file, two shapes

`sqlcipher` is a flat pin compared against whatever the build machine
staged (§4.5). `[rakudo]` is a table, because the runtime a bundle
embeds needs two coordinates: `version` and `revision`, where `revision`
disambiguates rebuilds of the same upstream release — a repackaged
runtime, a patched MoarVM — without pretending upstream cut a new
version. The shapes are not interchangeable, and a bump to either
re-renders every artefact in lockstep, which is the entire reason the
numbers live in one file.

---

## 9. Finding ariza's own data files

ariza ships data: Jinja2 templates, shell partials, the pin file. It has
to read them both when installed (where `zef` has staged every resource
under a content-hashed name and `%?RESOURCES` is the only way back to
the bytes) and from a source checkout (where `%?RESOURCES` is typically
unpopulated and the files are sitting in `resources/`).
`App::Ariza::Resources` is the single place that knows this, so neither
world is a special case anywhere else.

`resource-list` exists because `%?RESOURCES` cannot list a directory —
an installed distribution's resources are flat. A checkout reads the
working tree, so a file you just created is visible before you have
listed it in META6; an installed run enumerates the distribution
manifest, so it shows exactly what was packaged. Either way the paths
come back with **forward slashes**, on Windows as much as anywhere else:
these are META6 `resources` keys rather than paths into the filesystem,
and the separator is the packaging spec's to choose (0.0.2,
2026-08-12).

A resource that is missing from both fails loudly, naming the path it
tried, because the cause is always the same packaging bug: a file on
disk that nobody added to META6 `resources`.

---

## 10. Cross-platform hygiene

0.0.2 (2026-08-12) is the release where the suite first ran on a real
Windows machine, and the ruling it produced is worth stating plainly:
**every failure was a genuine portability bug rather than a test being
fussy**, and four of them were in `lib/`. The fixes are fixture-tested
from every platform, which is the standing pattern — everything that
shells out takes a `:&run` seam, so the macOS, Linux and Windows
branches of each are covered from any one of them.

The three that generalise beyond their own bug:

- **Fall through, do not stop at the first disappointment.**
  `sha256-file` tries `sha256sum`, `shasum -a 256` and `certutil` in
  turn, and absence, an unspawnable binary, a non-zero exit and output
  holding no digest are all "try the next one"; only an exhausted list
  dies, naming what every attempt did. A GitHub runner has a `shasum` on
  `PATH` that is a Perl script with no interpreter association, so
  `where` finds it and `CreateProcess` refuses it — which took down
  every digest on the machine while `certutil` sat untried behind it.
  There is still no "skip verification" path.
- **Bytes are bytes.** `.gitattributes` declares `* -text`, because the
  goldens in `t/` are compared with `slurp(:bin)` precisely so a
  line-ending difference cannot be shrugged off, and Windows CI images
  set `core.autocrlf=true`. Conversion off in both directions also
  preserves the goldens that are deliberately CRLF — the Windows
  launcher twins and the PowerShell installers, which exist because
  `cmd.exe` mis-parses an LF-only batch file in ways that look nothing
  like a line-ending problem.
- **Containment is a path-identity question, not a byte question.** The
  ELF audit normalises both sides to forward slashes before deciding
  whether a resolved dependency lands inside the bundle, because a
  bundled `libcrypto.so.3` genuinely inside `native/sqlcipher` was
  flagged as a stray purely because one side had backslashes.

---

## Timeline

| Release | Date | The decision it carried |
| --- | --- | --- |
| 0.0.1 | 2026-08-12 | One distribution mechanism: the legacy installer machinery retired, bundles only. |
| 0.0.2 | 2026-08-12 | Windows portability is a lib/ concern, not a test concern; digest fallthrough, `* -text`, separator normalisation. |
| 0.0.3 | 2026-08-12 | One clean-machine installer smoke per platform, not just Linux. |
| 0.0.4 | 2026-08-12 | The bundled zef is invoked by what the file is, not by what the platform is (`zef.raku` under the bundled raku on Windows). |
| 0.0.5 | 2026-08-12 | A `{raku}` smoke command gets the launcher's environment, including the Windows `PATH` that resolves a DLL by name. |
| 0.0.6 | 2026-08-12 | PE gets the same dependency walk ELF and Mach-O get. |
| unreleased | 2026-08-12 | The redistributable gate: an MSVC-built dependency is a clean-machine failure, so the CI lane takes UCRT and the audit refuses the alternative. |
