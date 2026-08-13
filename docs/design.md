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
The store is content-addressed, and every dependency in it is recorded
relative to the repository that holds it, so warming it at build time
and unpacking the archive somewhere else entirely — including a path
with spaces — loads the same bytecode. That last property is why the
app's repository is the bundled runtime's own `vendor` prefix,
`<bundle>/rakudo/share/perl6/vendor`, and not a directory of ariza's
choosing: Rakudo writes `vendor#sources/<id>` for a repository the
registry has a *name* for — `core`, `vendor` and `site` under the
running interpreter's prefix, `home` under `$HOME` — and an absolute
build-machine path for any other, including one named only in
`RAKULIB`. A store full of the second kind is thrown away wholesale by
the first machine that is not the build machine, which is the bug the
first published bundle shipped with: 52 modules recompiled, ~58
seconds, on every user's first launch, invisible to every check that
ran on the machine that built it. `build-site` now asks the bundled
runtime what it calls the repository before warming anything, and reads
the records back afterwards; `ariza smoke` reads them again in the
unpacked archive.

**The launcher** is the one file a user runs, and the only file in the
bundle they are ever expected to touch. It finds its own bundle by
resolving its own path through a `readlink` loop, not `readlink -f`,
which is a GNU extension absent from macOS before Monterey and from the
BSDs — a launcher that only resolves symlinks on Linux breaks the moment
someone puts one in `~/bin`. It exports
`RAKULIB=inst#<root>/rakudo/share/perl6/vendor` and
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

### 6.6 The install warms the app up, and a failed warm-up is not a failed install

The last thing an install does before it says goodbye is run the thing
it just installed, once: `<exec> --version` by default, or whatever
`installer.warm` names, with its output suppressed and a line on screen
saying what is happening. Whatever a first launch has to do that later
ones do not — paging a few hundred megabytes off a cold disk, creating a
per-user state directory, unlocking a keychain — is done there. A user
who types the command for the first time expecting their application
should get their application, not a progress-free pause of unknown
length.

Every path that reaches the parting message goes through it, including
the re-run that found the version already installed. That re-run is what
somebody tries when the last one did not take, and warming it again
costs a second.

**The ruling: a warm-up that fails warns loudly and the install
succeeds.** No non-zero exit, no rollback, no "installation failed".

This deliberately diverges from the fail-closed posture everywhere else
in this tool. `ariza bundle` dies on a missing licence; `ariza smoke`
fails on a stray library; the audit refuses a dependency it cannot
resolve inside the bundle. The difference is the **failure domain**. All
of those run in our own pipeline, on a machine we control, before
anything is published: there, a failure is cheap, a false negative is
expensive, and the correct response to "something is off" is to stop.
The warm-up runs on a stranger's machine, after the bundle has been
downloaded, checksummed and moved into place. There, the same signal
means something quite different — no terminal, a sandbox, a policy, a
scanner holding the file open, a machine with no display — and the
program on disk is, on the evidence available, fine. Failing the install
would delete a working program from somebody who has one, and would
teach them that this installer is unreliable, on the strength of a
diagnostic step.

So the failure path says two things and stops: what did not complete,
and that the app is installed and its download was verified, so run it
— the first launch may just take longer. That is a true statement about
a bundle in that state, which is the test any message printed on
somebody else's machine has to pass.

Two consequences follow. There is **no timeout** — a mechanism that
would need one implies a warm command that might not return, and the
right fix for that is the command, not a watchdog — which is why an
empty `installer.warm` is a load-time error rather than "run the app
with no arguments". And the default is `--version` rather than anything
cleverer, because it is the one invocation every bundled application
answers and returns from, and it is already the canary `bundle.smoke`
uses.

### 6.7 Windows

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

### 9.1 Never take `.basename` off a resource

The content-hashed staging has a second consequence, and it is the kind
that passes every test and breaks for every user. An installed
distribution's `MIT.txt` is `0E9B31…​.txt` on disk and its
`runtime-third-party.json` is `A3FCDF…​.json`; a checkout's are
themselves. Anything that derives a *name* from a resource's `.basename`
therefore works perfectly in the one place the suite runs and produces
nonsense in the one place users are.

Licensing has two such places by nature — the pool of licence texts is
keyed by the name a row cites, and every runtime row records the data
file it came from — and both were written that way first. The rule is
that a resource's name is its **META6 key**, never its file's basename;
the file is only where the bytes are. `xt/04-installed-resources` is the
check that keeps it true: it installs ariza into a throwaway repository
and asks the installed copy for both, because a checkout cannot tell the
difference.

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

## 11. The Windows runner

A Windows bundle's documented entry point is `bin/<exec>.exe`: a small
C17 program in this repository's `runner/` directory that reads
`bin/<exec>.ariza` beside itself, applies that file's environment
directives, and starts the bundle's own `raku.exe` on the app's script
with the caller's arguments passed through byte for byte. The `.cmd` and
`.ps1` launchers still ship and still work; what changed is which one is
documented, put on `PATH` and exercised by the smoke harness.

### 11.1 Why a full runner, and not a front door

The cheap version of this is an executable that `exec`s the `.cmd`. It
would have solved nothing.

The first problem is **argument fidelity**. A batch launcher ends in
`"%ARIZA_RAKU%" "%BUNDLE_ROOT%\<target>" %*`, and `%*` is not the user's
arguments — it is the user's arguments after `cmd.exe` has had a second
go at them. `^` is cmd's escape character, `%VAR%` and `!x!` are
expansions, and a quoted argument is re-split on substitution. An app
that takes a prompt, a regex, a path or a snippet of code as an argument
receives something the user did not type, and the damage happens inside
the substitution where nothing can intercept it. Spawning cmd from an
exe keeps every bit of that.

The second is **script-execution policy**. AppLocker and Software
Restriction Policies have a script rule that blocks `.cmd` and `.ps1`
files *however they are invoked* — including from a parent process —
and a locked-down `ExecutionPolicy` stops the PowerShell twin on its
own. Those environments run executables. A trampoline that ends in a
script is blocked exactly where the executable was supposed to help.

So the runner does the whole launch itself, with no `cmd.exe` in it at
any point: `GetModuleFileNameW` for its own path, the directory above
`bin/` as the root, `SetEnvironmentVariableW` for the environment,
`CreateProcessW` for the child, and the child's exit code as its own.
The argument tail is found by following the C runtime's argv[0] rule
exactly — leading whitespace skipped, a quoted argv[0] ending at the
next quote with no escape processing, an unquoted one ending at the
first space or tab — and everything after that point is copied into the
child's command line **unchanged**. There is no re-quoting step for
anything to be lost in.

Two consequences worth stating: the `.cmd` and `.ps1` remain in the
bundle as the transparent alternative (a launcher you can read is worth
having, and it is also the way past a SmartScreen prompt), and because
the executable is a fixed artefact rather than a rendered script, it can
be published once and pinned by digest — which a generated script never
could be.

### 11.2 Not Devel::ExecRunnerGenerator

The existing Raku answer to "I want an exe" is
`Devel::ExecRunnerGenerator`, and it is the wrong tool twice over. It
ships prebuilt binary blobs from a third party, which is precisely the
thing every other component in a bundle is pinned, hashed and
inventoried to avoid; and its runner sets a module path and runs a
script, with no mechanism for prepending to `PATH`, which is how Windows
finds a bundled DLL and therefore not optional here. Writing ~400 lines
of C we own, build in the open and hash-verify is a smaller commitment
than depending on someone else's binary for the first thing every
Windows user executes.

### 11.3 The sidecar, and why the config is not baked in

Baking the target script and the environment into the executable at
build time would mean one compiled runner per app, per version, per
platform — i.e. a C toolchain in the bundling path, on every machine,
for every cross-build, to produce a file that is otherwise identical for
every app. A generic runner plus a text file next to it keeps the
executable a fixed, pinned, hash-verified artefact and puts the
per-bundle facts in something a user can read, diff and correct.

The sidecar carries the target, the exec name and the display name, and
then the environment as **ordered directives**:

```
target rakudo\share\perl6\vendor\bin\moneymoor.raku
app-exec moneymoor
app-display Moneymoor
set RAKULIB=inst#{root}\rakudo\share\perl6\vendor
unset PERL6LIB
set NOTCURSES_NATIVE_DATA_DIR={root}\native
prepend-path {root}\native\sqlcipher
set DBIISH_SQLCIPHER_LIB={root}\native\sqlcipher\sqlcipher.dll
```

`{root}` is the bundle root, resolved at run time, so nothing absolute
survives into the file; `{{` is a literal brace. The three verbs are
`set`, `unset` and `prepend-path`, applied top to bottom.

The directives are the ruling worth recording. An earlier draft had
`sqlcipher_dir` and `sqlcipher_lib` keys and a hardcoded
`NOTCURSES_NATIVE_DATA_DIR`, which put knowledge of every native
dependency a bundle might ever carry inside a **pinned binary on its own
release cadence**. Adding a dependency would then have meant a runner
release, a checksum commit and a version skew window in which a new
bundle could not be launched by an old runner. With directives, the
knowledge lives in the renderer beside the `.cmd` template — where it
already was — and adding a dependency is a line in a template. That is
the property ariza needs as native dependencies become app-declared
"recipes" rather than a fixed list: a recipe unit can contribute env
lines without a sidecar format break, a runner rebuild, or anything else
changing.

Two rules keep that generality honest. `#` only starts a comment in the
first non-blank column, because `inst#{root}\rakudo\share\perl6\vendor`
is a real value and
an inline-comment rule would truncate it into a `RAKULIB` that names a
relative directory. And an unrecognised directive, or an unknown
`{token}`, is a **hard error naming the line** rather than something
skipped: a bundle whose configuration mentions something the runner
cannot do would otherwise start an app with a silently incomplete
environment, which fails later, further away, and much worse than not
starting.

### 11.4 The bootstrap ladder

The code that downloads a pinned runner has to exist before the release
it downloads can be published, and neither a placeholder binary nor a
disabled feature flag is an acceptable way through that. So
`resources/runner-checksums.txt` has exactly two states, and which one
it is in decides the behaviour — the same precedent as
Notcurses-Native's `resources/checksums.txt`, which falls back to a
source build when it lists nothing:

- **No pins recorded.** A Windows bundle is built without the
  executable — the `.cmd` and `.ps1` launchers alone, byte-identical to
  what ariza produced before the runner existed — and the build says so
  once, loudly, naming the file to fill in.
- **Any pin recorded.** The ladder inverts. A missing entry for the
  target architecture, a failed download, or a digest mismatch fails the
  build. Past that point a bundle without a verified runner is a
  regression rather than a stage of bootstrapping.

There is deliberately no third rung: no `--no-runner`, no
`--skip-verify`. An unverified executable staged into a bundle is not a
degraded build, it is a different piece of software.

### 11.5 The artefact pipeline

`runner-release.yml` builds both lanes in MSYS2 — UCRT64 for x86_64,
CLANGARM64 for aarch64, the same toolchains that build the notcurses
packs a bundle already carries — runs the C test suite on the x86_64
lane, and publishes to a GitHub release **only** on a pushed `runner-v*`
tag, after checking that tag against `resources/RUNNER_VERSION`. A
`workflow_dispatch` builds and tests and stops, because "validate the
recipe" and "overwrite the artefacts every ariza release verifies
against" should not be one click apart. That is Notcurses-Native's
`BINARY_TAG` gate in miniature, and it is that shape for the same
reason.

MSVC is not a target: one Windows C toolchain story for the whole
ecosystem is worth more than a second compiler's warnings. The
executable is linked statically and the lane then **asserts its import
table** contains nothing but Windows' own DLLs — a `libgcc_s_seh-1.dll`
picked up from the build environment would work on the runner, work on
every machine with a toolchain, and fail on a clean install, which is
the identical failure shape to the `vcruntime140.dll` one in §3.4.

### 11.6 Testing something that only runs on Windows

The runner is split so that the interesting half is portable. Config
parsing, environment-value construction and the command-line-tail rule
are plain C17 over a character type that is `wchar_t` on Windows and
`char` everywhere else; the win32 API calls live in one file that is not
compiled at all on POSIX. `ctest` therefore says something useful on a
Mac or a Linux CI runner: the argv[0] boundary against a table of the
cases a batch file damages (`^`, `%VAR%`, `!x!`, embedded quotes,
trailing backslashes before a closing quote, unicode, an unterminated
quoted argv[0]), the quoting rules, and the sidecar grammar including
every way a damaged one has to be refused.

One of those tests parses `t/golden/launcher-windows-x86_64.ariza` — the
committed output of the Jinja2 template, compared byte for byte by the
Raku suite — with the real C parser. The renderer and the reader are in
different languages and nothing else connects them; that test is the
connection, so a template edit that changes a directive fails in CI
rather than on a user's machine.

What POSIX `ctest` cannot cover is the win32 shell itself. That is the
MSYS2 lanes' job to compile and the **Windows smoke lane's** job to
prove: `App::Ariza::Smoke` runs every `{exec}` smoke command a second
time through `bin/<exec>.exe` when a bundle carries one — in addition to
the `.cmd` run, never instead of it, because the two set the same
environment by completely different means and one passing says nothing
about the other.

### 11.7 Unsigned, and said out loud

The published binaries are not code-signed, so SmartScreen shows its
"unrecognised app" prompt the first time a user runs a bundle's `.exe`.
Signing needs a certificate and a signing story ariza does not have
today; pretending otherwise in the documentation would be worse than the
prompt. The README says so where a user will read it, the release notes
say so, and `sha256sum -c` against the published `checksums.txt` is what
there is in the meantime.

## 12. Licensing: what a bundle redistributes

A bundle is a binary redistribution. It carries a Rakudo built by
somebody else, a MoarVM with a dozen C libraries compiled into it,
every Raku distribution in the app's closure, whatever a native pack
staged, an SQLCipher taken off the build machine, and on Windows an
executable ariza downloaded from its own release page. Until 0.1.0 it
said almost none of that: `LICENSES/COMPONENTS.md` copied the app's
LICENSE and Rakudo's, then rendered a table of native libraries from a
hardcoded list of filename prefixes.

That table was wrong in two ways at once, and the second is the
interesting one. It was factually stale — it declared the notcurses
pack's FFmpeg a GPL build because of `libx264`, which that pack had
stopped shipping — and it was **knowledge about other people's
software living in ariza's source code**, which for a tool that bundles
anybody's application is a category error. A stranger's app with a
native dependency ariza has never heard of would have got a row saying
`(unclassified)`, and the only fix would have been a patch to ariza.

### 12.1 Data, never code

Everything the merged document says now comes from one of four sources,
none of which is a Raku source file, and every row records which one it
came from:

* **A native pack's own licensing kit.** `third-party.json` where the
  pack ships one — component rows, filtered to the platform being
  built — and its generated `THIRD-PARTY.md` where it does not. The
  pack knows what is in the pack; ariza's job is to read it, not to
  remember it.
* **`resources/runtime-third-party.json`.** ariza's maintained record of
  the vendored Rakudo, NQP and MoarVM, the C libraries MoarVM vendors
  under `3rdparty/`, SQLCipher and the runner. These have nowhere else
  to speak from: they arrive as compiled bytes inside archives with no
  manifest, so there is nothing in the bundle to interrogate.
* **Each installed distribution's `META6.json`.** The `license` field,
  from the repository the app was installed into *and* from the
  runtime's own `site` — which is where `zef` lives, and `zef` is
  redistributed like anything else.
* **The app's `ariza.toml`.** Its own row, and rows for what it ships
  that ariza cannot see.

The schema is deliberately the one Notcurses-Native's `third-party.json`
already uses — `id`, `name`, `version`, `spdx-license`,
`conveyed-under`, `license-files`, `copyright`, `project-url`,
`source`, `notes` — because that format is the interface, not a thing to
be reimplemented. ariza adds two fields of its own: `kind`, which orders
the document, and `provenance`, which is the field a reader checks
first, since "who claims this?" should have an answer that is not "the
tool".

The 0.2.0 recipe work adds a fifth contributor without a format break: a
recipe describes a native dependency, and a native dependency's
licensing is rows in exactly that shape.

### 12.2 The MoarVM rows, and the caveat that comes with them

The libraries under MoarVM's `3rdparty/` are the reason the runtime data
file exists. They are not separate files in a bundle — they are inside
`libmoar`, which is why no audit of the bundle's contents can find them
and why they were invisible before. The set was taken from MoarVM's own
`.gitmodules` and in-tree directories and each licence checked against
the `LICENSE` file of the submodule *at the commit MoarVM pins*: libuv
(MIT, plus BSD-2 for `tree.h` and ISC for `inet_pton`), dyncall (ISC),
DynASM (MIT), LibTomMath (public domain), cmp (MIT), libatomic_ops
(MIT — its GPL files are build and test tooling, which MoarVM's own
`3rdparty/README.md` states are in no built binary), mimalloc (MIT),
rapidhash (MIT), zmij (MIT), musl's `memmem` (MIT, in a directory called
`freebsd`), Steve Reid's SHA-1 (public domain) and msinttypes
(BSD-3-Clause).

That set **moves between MoarVM releases**, and which members are
compiled in additionally depends on the platform and on configure flags.
So the data file is documented as a superset for the pinned runtime
rather than a per-file inventory, and it says so in its own `_readme`:
naming a library that did not end up in the binary costs a paragraph,
while omitting one that did is a notice not given. The trigger to
re-check it is a change to the `[rakudo]` pin.

### 12.3 Fail closed, but only where there is nothing true to say

The asymmetry is deliberate, and it is the same reasoning as the
unknown-key-versus-unknown-slug rule in section 8.

**A Raku distribution with no `license` field fails the build.** The
field exists, the whole ecosystem fills it in, and the fix is one line
in a `META6.json` — or, when it is somebody else's distribution, one
`[[licensing.dists]]` row in the app that hit it. An "unknown" row here
would be a permanent hole that nobody ever closes. Not that the whole
ecosystem does fill it in: a scan of a few hundred installed
distributions turned up a dozen with no `license` at all and a couple
saying `NOASSERTION`, so the check reports **every** offender in a
closure at once rather than the first — three unlicensed dependencies
should cost one build, not three.

**A cited licence text that is nowhere fails the build.** A document
citing `LICENSES/Beerware.txt` with no such file is worse than one that
never mentioned it.

**A native pack with no licensing kit is a visible row and a warning.**
Here ariza genuinely has nothing true to say: the pack is a third
party's artefact and its author has not said. Refusing to build would
punish an app for its dependency's packaging, and dropping the pack
would hide a redistributed binary — so the row exists, says
"licensing unknown", names what would fix it, and the build says so out
loud. `licensing.strict = true` promotes it to a failure for a project
that will not ship one, which is a decision that belongs to the app and
not to the tool.

### 12.3.1 NOASSERTION: a declaration, and only a declaration

SPDX has a spelling for "somebody looked and could not determine the
licensing": `NOASSERTION`. It is worth having, because the alternative
for an app that has genuinely exhausted the search is to invent a
licence or to stop shipping — and both are worse than saying so. But it
is worth having *only* as a declaration somebody made, which produced
four rulings (2026-08-12):

* **Only an app can make it**, in a `[[licensing.dists]]` or
  `[[licensing.third-party]]` row. It is never inferred, never a
  fallback, and never what a missing field decays into.
* **A distribution whose own metadata says `NOASSERTION` still fails.**
  That is not a declaration anybody made about this bundle; it is the
  same "nobody has looked" with different spelling, and the fix is for
  somebody to look and then to say so in the app's config, on the
  record, with the evidence in `notes`.
* **An application may not say it about itself.** `NOASSERTION` means a
  third party's licensing could not be determined; there is nobody to
  look on behalf of the thing being built here.
* **`licensing.strict` refuses it.** Strict is the statement that this
  bundle ships nothing it cannot name, and "we could not find out" is
  not a name. That is the same rule the unattributed-pack check
  enforces, applied to the other way a bundle can carry something
  nameless — which is what makes strict a single coherent promise
  rather than two half-checks.

No licence text is looked up for such a row (there is none). Instead the
row carries a generated sentence — not the app's own wording — saying
that licensing was not asserted and pointing at the component's own
repository, so the reader of a bundle is told the same thing every time.
`ariza-manifest.json` counts them in `licensing.noassertion`, apart from
`spdx-ids`, because a gate reading the identifier set must never see
`NOASSERTION` sitting in it looking like a permissive licence.

The licence-text set moved at the same time and for the same reason: a
scan of a real closure turned up live needs for AGPL-3.0, X11 and
OFL-1.1, so ariza now ships sixteen texts rather than thirteen, and a
test enumerates the set so that adding or losing one is a decision
rather than a side effect.

The one place this pragmatism is visible in the code is the fallback for
a pack that ships `THIRD-PARTY.md` but no `third-party.json` — which is
every pack that exists today, since the upstream generator writes the
document into the archive and keeps the manifest in its repository.
Parsing generated prose is not a thing to do casually, so the parser
requires the Summary table's exact generated header, takes only the four
columns and the two labelled Details bullets it understands, and returns
**nothing at all** for a document in any other shape — falling through
to the unattributed row rather than to rows assembled out of the wrong
columns.

### 12.4 Determinism, and the manifest summary

Rows are ordered by kind, then by folded name, then by id — never by the
order a directory happened to be read in — and nothing in the document
is a timestamp or a path from the build machine. Two builds of the same
inputs produce byte-identical output, which is what makes it diffable
across releases and what makes the golden test meaningful. Licence texts
are deduplicated by filename with a fixed priority; two sources offering
the same name with different bytes warn, naming both, and the
higher-priority copy is the one that ships, because the alternative is a
`MIT.txt` that depends on directory order.

The priority is **the app's copy, then a pack's, then ariza's own**
(ruled 2026-08-12, after an initial implementation had it the other way
round). Nearest-to-the-software wins, and the deciding case is the SIL
Open Font License: an OFL text carries a **Reserved Font Name**, filled
in per font, so the file an app names in `license-files` is a *different
document* from the template rather than a formatting variant of it — and
shipping the template instead would replace a real notice with a
placeholder that says `<year> <owner>`. The same argument holds one step
down: a pack's `LICENSES/MIT.txt` is the notice its author shipped
beside the binaries, while ariza's is the SPDX template. So the generic
text is what to fall back to when nobody supplied one, never what to
prefer over one somebody did.

`ariza-manifest.json` gains a `licensing` object — row count, how many
were unattributed, and the sorted set of SPDX identifiers the bundle is
conveyed under. That is the thing a release gate downstream can test
without parsing prose: `unknown > 0` means something is unattributed,
and the identifier set is where a copyleft component that arrived inside
a native pack becomes visible to a policy that cares.

### 12.5 The runner's manifest gap, closed here

The same pass closed a smaller hole. `components.runner` did not exist,
so `bin/<exec>.exe` — the file a Windows user actually runs — was the
only artefact in a bundle with no URL and no digest recorded anywhere,
while the runtime archive and SQLCipher both had one.
`App::Ariza::Runner.stage` now returns what it staged rather than only
where it put it, `App::Ariza::Launcher.write` carries that out with the
paths it wrote, and the manifest records the artefact name, the release
tag, the download URL and the digest the copy was verified against.
Everything a bundle downloads is now traceable to something published.

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
| unreleased | 2026-08-12 | Windows launches from a compiled runner of ariza's own, pinned by digest; its sidecar carries ordered env directives, so a bundle's dependencies are the renderer's business and never the executable's. |
| unreleased | 2026-08-13 | The install pays the first launch: the installers warm the app up under a visible line, and a warm-up that fails warns rather than failing an install that has already been verified. |
| unreleased | 2026-08-12 | A bundle says what it redistributes, out of four sources it reads rather than a table it remembers; a Raku distribution with no licence fails the build, an unattributed native pack is a visible row and, on request, a failure. |
| unreleased | 2026-08-12 | `NOASSERTION` is a declaration an app makes after looking, never a gap ariza fills: not from a distribution's own metadata, not about the app itself, and not at all under `licensing.strict`. |
