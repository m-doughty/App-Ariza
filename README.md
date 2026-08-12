[![Actions Status](https://github.com/m-doughty/App-Ariza/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/App-Ariza/actions)

NAME
====

App::Ariza - bundler and distribution tool for Raku terminal apps

SYNOPSIS
========

```console
# Build a self-contained bundle of an app, and prove it works:
$ ariza bundle --app=../App-Moneymoor --out-dir=dist
$ ariza smoke  --archive=dist/moneymoor-0.2.0-macos-arm64.tar.gz

# Render the four scripts an end user runs, into the app's repository:
$ ariza installers --app=../App-Moneymoor

# Write the workflows that build one bundle per declared platform, on
# machines that are actually those platforms, and publish them on a tag:
$ ariza scaffold-ci --app=../App-Moneymoor

$ ariza version
$ ariza help
```

From Raku, every verb is a class method, and the machinery underneath is a library in its own right:

```raku
use App::Ariza;

my %b = App::Ariza.cmd-bundle(:app<../App-Moneymoor>, :out-dir<dist>);
App::Ariza.cmd-smoke(:archive(%b<archive>));
App::Ariza.cmd-installers(:app<../App-Moneymoor>);
App::Ariza.cmd-scaffold-ci(:app<../App-Moneymoor>);

say current-slug;                                  # macos-arm64
say App::Ariza::Versions.load.rakudo-tag;          # 2026.07-01
say App::Ariza::Config.load($app-repo).bundle-platforms;
```

DESCRIPTION
===========

ariza packages Raku TUI applications — Cantina, Kelpie, Mindmoor, Moneymoor — for people who do not have Raku and should not have to care that the thing is written in it.

The bundle
----------

The end state ariza is built towards is a **bundle**: one archive per platform containing the application, a Rakudo runtime, every Raku dependency, and every native shared library the app touches — notcurses, SQLCipher, libvips — laid out so that unpacking it anywhere and running a single launcher works.

The properties that matter, and that shape everything below:

  * **Self-contained.** Nothing is fetched at run time and nothing is assumed to be present. A machine with no Raku, no Homebrew and no compiler runs the app.

  * **Per-platform, and honest about it.** A glibc binary does not run on Alpine; an arm64 dylib does not run on an Intel Mac. Every artefact is named after exactly one platform slug and contains binaries for exactly that platform.

  * **Relocatable.** No absolute paths baked in, no install step, no PATH surgery. It runs from a home directory, a USB stick or `/opt`.

  * **Removable.** Deleting the directory removes the software. Nothing is registered, nothing is scattered, nothing is left behind.

What is in a bundle
-------------------

```console
moneymoor-0.2.0-macos-arm64/
  bin/moneymoor            the launcher, and the only thing a user runs
  rakudo/                  the interpreter (plus SQLCipher, on macOS)
  site/                    every Raku module, with warm bytecode
  native/                  notcurses and friends
  VERSION                  app version and component pins, one screen
  ariza-manifest.json      the same, machine-readable, plus every sha256
  LICENSES/                app + Rakudo licence text, and COMPONENTS.md

moneymoor-0.2.0-macos-arm64.tar.gz          50 MiB (165 MiB unpacked)
moneymoor-0.2.0-macos-arm64.tar.gz.sha256
```

How it is built
---------------

  * **The runtime** is the official archive from `rakudo.org`, pinned by `[rakudo]` in `versions.toml`, downloaded once into `$XDG_CACHE_HOME/ariza/rakudo` and unpacked into the bundle. The cache records a SHA-256 on first download and verifies it on every reuse.

  * **The Raku closure** is installed by the **bundled** `zef` into the bundle's own repository, so the precompiled bytecode matches the runtime that ships rather than whatever Rakudo the build machine had.

  * **The bytecode is warmed at build time.** `zef` does not do this, and it matters: a cold bundle spends about 55 seconds compiling on its first launch — and does it again on every launch if the bundle happens to live somewhere unwritable, which for a downloaded archive is normal. Warm it is half a second. The store is position-independent, so warming it here and unpacking the archive somewhere else entirely works.

  * **Native libraries** are staged and then **audited**: every Mach-O, ELF or PE ariza put in the bundle must resolve inside it, or the build fails naming the file and the dependency. That is the difference between a bundle that works on the machine that built it and one that works anywhere.

  * **The launcher** is the one file a user runs. It finds its own bundle by resolving its own path (through a `readlink` loop, not `readlink -f`, which is a GNU extension), points `RAKULIB` and `NOTCURSES_NATIVE_DATA_DIR` at the bundle, and execs the bundled interpreter. Everything is quoted, so a path with spaces works.

Where SQLCipher comes from
--------------------------

notcurses arrives on its own — Notcurses-Native's prebuilt pack is staged as a side effect of the `zef` install. SQLCipher has no such hook, so ariza takes it from the build machine's own package manager:

  * **macOS** — the installed Homebrew keg (`brew --prefix sqlcipher`), or, if it is not installed, the bottle `brew fetch --formula sqlcipher` puts in the cache.

  * **Linux** — whatever `ldconfig -p` resolves `libsqlcipher.so.0` to, falling back to the Debian multiarch, Red Hat and Alpine library directories. CI installs the distribution package (`apt install libsqlcipher0`) before it calls `ariza bundle`.

  * **Windows** — a vcpkg tree under `VCPKG_ROOT`, or wherever `SQLCIPHER_LIB_DIR` points.

There is deliberately **no** ariza-operated mirror to download from. SQLCipher's ABI does not move often enough to justify a second piece of release infrastructure with its own signing story, its own staleness and its own outages — and what makes a library safe to redistribute is not where it was downloaded from but what happens to it next: every dependency it names outside the bundle is copied in beside it and rewritten to load from there, and the audit then refuses to ship the bundle if anything still points off the machine.

### Self-containment on Linux, and why it needs a Linux machine

ELF hides the same problem better than Mach-O does, which is why it went unnoticed longer. A Homebrew library names its OpenSSL by absolute path, so it is obvious. A distribution's `libsqlcipher.so.0` names its OpenSSL as a bare `NEEDED libcrypto.so.3` — no path, no `RPATH`, nothing in the file for an audit to object to — and at run time that means "whatever `libcrypto.so.3` this machine has", which on a user's machine may be nothing at all.

So a Linux bundle gets the same treatment a macOS one does, spelled the way ELF spells it: `ldd` (the loader itself, so its answer is the one the machine will really give) reports where each dependency resolves; every non-system one is copied in beside the library under its soname and recursed into; and `patchelf --set-rpath '$ORIGIN'` on the library and every copy makes each find its siblings in its own directory wherever the bundle is unpacked. What stays dynamic is the loader, `libc` and the compiler runtime — a second copy of those is a conflict, not insurance. `libcrypto` and `libssl` are **not** in that category: SQLCipher without OpenSSL is SQLite.

The audit then adds two checks that only exist on a Linux host, because both tools answer for the machine they are on: `patchelf --print-rpath` must be `$ORIGIN`-relative, and `ldd` run with the environment **replaced** by a bare `PATH` — the user's view, not the build's — must resolve every non-system dependency inside the bundle. Cross-inspecting an ELF from a Mac does the static half and says so, rather than pretending to more; which is the long way of saying the Linux bundle is built on Linux.

That claim is proved rather than asserted: `xxt/linux-selfcontain-proof.sh` runs the whole thing in a `manylinux` container — real SQLCipher, real Rakudo, the test suite, a real bundle staged and audited, the result re-checked independently in shell, and three negative controls (a planted absolute `NEEDED`, a deleted dependency, a stripped rpath) that must each make the audit fail.

Two overrides beat the package managers, in this order: `--sqlcipher-archive=FILE` (an archive to unpack) and `SQLCIPHER_LIB_DIR` (a directory holding the library). Both are how a cross-build works, because they are the only way to be honest about it: a library installed on this machine is built **for** this machine, so ariza refuses to take one when the platform being built is not the platform it is building on. Missing entirely, on any platform, is a death naming the package to install **and** the override to pass — never a silent bundle without a database.

The version in `versions.toml` is **advisory**. The package manager decides what is actually installed, so ariza reads the version out of the staged library's own bytes and warns if it disagrees with the pin:

```console
ariza: sqlcipher 4.17.0 staged, pin says 4.14.0
```

The build continues, and `ariza-manifest.json` records the version that was **staged**, the pin beside it, the digest of the library as it came off the machine, and which keg, bottle or archive it came from. A manifest that quotes a number nobody verified is worse than no number at all.

Proving it, rather than hoping
------------------------------

`ariza smoke` takes the finished archive, unpacks it into a scratch directory **with a space in its name**, and runs it with a **replaced** environment — `PATH`, `HOME`, `TERM` and nothing else:

```console
$ ariza smoke --archive=dist/moneymoor-0.2.0-macos-arm64.tar.gz
ok   unpack         extracted to moneymoor-0.2.0-macos-arm64
ok   manifest       App::Moneymoor 0.2.0, 8 distributions for macos-arm64
ok   launcher       bin/moneymoor
ok   runtime        rakudo 2026.07-01
ok   target         site/bin/moneymoor.raku
ok   precomp        398 precompiled artefacts ship with the bundle
ok   native-audit   26 native binaries resolve inside the bundle
ok   smoke[0]       {exec} → exit 0: App::Moneymoor 0.2.0
ok   smoke[1]       {raku} → exit 0: ok: encrypted database created, written and reopened

ariza: 9 checks passed
```

The replaced environment is the point. The failure this catches is a bundle that quietly uses something from the developer's shell — a system Rakudo on `PATH`, a `DBIISH_SQLCIPHER_LIB` pointing into Homebrew — which makes a broken bundle look perfect on the machine that built it.

Every check runs; nothing short-circuits. A failing run leaves the unpacked tree behind and prints where, because the state it failed in is the whole value of the exercise.

GETTING A BUNDLE ONTO A MACHINE
===============================

A bundle is self-contained, so "installing" it is unpacking it somewhere and running the launcher. `ariza installers` writes the four scripts that do exactly that, and nothing more, from the app's own manifest:

```console
$ ariza installers --app=../App-Moneymoor
ariza: wrote /Users/you/Code/App-Moneymoor/install.sh
ariza: wrote /Users/you/Code/App-Moneymoor/install.ps1
ariza: wrote /Users/you/Code/App-Moneymoor/uninstall.sh
ariza: wrote /Users/you/Code/App-Moneymoor/uninstall.ps1
ariza: rendered 4 installers for Moneymoor
```

They are committed at the app's repository root, because `curl` has to be able to fetch them from somewhere. What a user runs is one line:

```console
$ curl -fsSL https://raw.githubusercontent.com/m-doughty/App-Moneymoor/main/install.sh | sh
==> Moneymoor 0.2.0 for macos-arm64
==> downloading https://github.com/…/moneymoor-0.2.0-macos-arm64.tar.gz
ok  sha256 verified
ok  added /home/you/.local/bin to PATH in /home/you/.zshrc
ok  Moneymoor 0.2.0 installed

    run it:        moneymoor
    installed in:  /home/you/.local/share/moneymoor/versions/0.2.0
    uninstall:     curl -fsSL https://raw.githubusercontent.com/…/uninstall.sh | sh
```

That raw URL is built from `installer.repo` in the app's `ariza.toml` and the `--branch` flag (`main` by default). It only becomes a working link once the repository is public — until then the same script runs just as well as a file: `sh install.sh`.

What it does
------------

  * Detects the platform and downloads the matching release asset — one of the slugs the app **declares**, never a nearest match, because a glibc bundle does not run on Alpine and an arm64 one does not run on an Intel Mac.

  * **Verifies the SHA-256** against the `.sha256` asset published beside it. No digest, no install.

  * Unpacks into `$XDG_DATA_HOME/<exec>/versions/<version>/ ` — beside whatever is already there — and only then flips a `current` symlink and links `~/.local/bin/<exec> ` at it. A failed or interrupted download cannot damage a working install.

  * Adds `~/.local/bin` to `PATH` **only if it is not there already**, through one marked block in each shell rc file that exists. Re-running never duplicates it; the uninstaller removes exactly that block.

  * Keeps one previous version to roll back to and prunes anything older, saying which.

  * Needs no root, no compiler, no package manager, and no Raku.

Re-running it for a version that is already installed does not download anything: it re-points the symlinks, re-checks the PATH block and exits saying "already installed" — which makes "run the installer again" the correct advice for the most common breakage.

Version, source, and the escape hatch
-------------------------------------

The default is the latest release, read from the `location:` header of `https://github.com/<repo>/releases/latest`: one HEAD request, no API token, no `jq`. `--version v1.2.3` names a tag instead.

`--url` — or `<EXEC>_BUNDLE_URL `, e.g. `MONEYMOOR_BUNDLE_URL` — installs from a source you name and bypasses GitHub entirely. It takes a **plain file path** as readily as a URL, which is what makes an air-gapped install, a release candidate, and ariza's own end-to-end test possible with no network and no published release.

`--insecure-no-verify` applies to that path only. A source you named yourself may legitimately have no `.sha256` beside it, and the script says so loudly before continuing; a published release always has one, so a missing digest there stays fatal however many flags are passed.

One POSIX script, not two
-------------------------

The installer scripts that came before a bundle shipped `install-macos.sh` and `install-linux.sh` separately because they did genuinely different things — one drove Homebrew, the other five package managers. A bundle installer does none of that, so the only per-platform decision left is which asset to download, and that is a `uname` call away at run time. One script, one `curl` line in a README, and nobody has to work out which of two files applies to them.

Windows
-------

The same shape in PowerShell: `%LOCALAPPDATA%\E<lt>DisplayE<gt>\versions\E<lt>versionE<gt>`, a `current` **junction** rather than a symlink (which would need administrator rights or Developer Mode, and a per-user install has no business demanding either), and `...\current\bin` added once to the user `PATH` in `HKCU\Environment`. Because the PATH entry points through the junction, an upgrade needs no PATH change at all.

It is meant to be piped, so it never asks
-----------------------------------------

A script read from a pipe is executed as it arrives, so the generated one is entirely definitions with a single `main "$@"` on the last line: a truncated download cannot half-run it. It also never reads standard input — no prompts, no confirmations — because when the script arrives *on* standard input there is nothing left to read from. That is not a limitation to work around; it is what makes the thing runnable from CI.

Platform slugs
--------------

`App::Ariza::Platform` names the platform an artefact is for:

```console
macos-arm64            macos-x86_64
linux-x86_64-glibc     linux-aarch64-glibc
linux-x86_64-musl      linux-aarch64-musl
windows-x86_64         windows-arm64
```

These strings are not ariza's to choose. They are Notcurses-Native's platform slugs, character for character, because a bundle carries that distribution's prebuilt notcurses libraries and the two have to agree about what platform they are on.

Detection reads `$*KERNEL` and, on Linux only, probes the C library: a `ld-musl-*.so.1` loader under `/lib` or `/usr/lib` settles it immediately, otherwise `ldd --version` is parsed for a glibc version. A Linux system with neither — uclibc, a static busybox image — produces an honest "unsupported platform" rather than a bundle that will not run.

Setting `ARIZA_PLATFORM` to a known slug short-circuits detection, which is what makes cross-builds and CI matrices possible. An override that is not a known slug is a hard error: every other input is a system fact that might legitimately be unnameable, but an override is a human typing a string, and quietly ignoring a misspelled one would produce an artefact for the wrong platform.

Pinned versions
---------------

`App::Ariza::Versions` parses `resources/versions.toml`, the one file every artefact's version numbers come from, so that a bump re-renders everything in lockstep and nothing drifts:

```toml
sqlcipher = "4.14.0"

[rakudo]
version  = "2026.07"
revision = "01"
```

`[rakudo]` is the runtime a **bundle** embeds, where nothing is installed at all and the interpreter travels inside the artefact; `revision` disambiguates rebuilds of the same upstream release without pretending upstream cut a new version.

`sqlcipher` is the one pin ariza cannot enforce, and does not pretend to: a bundle's SQLCipher comes from the build machine's package manager, so this is the version **expected**, a mismatch warns, and the manifest records what was really staged.

The per-app manifest
--------------------

What a given app needs is declared by that app, in an `ariza.toml` in its own repository — so ariza stays a general tool instead of growing a list of special cases about specific applications:

```toml
[app]
name = "App::Moneymoor"      # dist name
exec = "moneymoor"           # launcher/binary name
display = "Moneymoor"

[bundle]
platforms = ["macos-arm64", "linux-x86_64-glibc", "windows-x86_64"]
native = ["notcurses", "sqlcipher"]
smoke = "{exec} --version"   # command run by ariza smoke

[installer]
repo = "m-doughty/App-Moneymoor"   # where the releases live

[ci]
ariza-source = "fez"         # how the workflows install ariza itself
```

All three `[app]` keys are required. `display` is required rather than derived because the correct capitalisation of a product name is not something a tool should guess at.

Building a platform the app does not list in `bundle.platforms` is an error: an app that lists its platforms has said which ones it is tested on, and producing an artefact named after one it never claimed is a promise ariza has no business making on its behalf. The same list is what the generated installers detect against, so an app that has never built for musl says so on an Alpine box rather than downloading something that cannot run there.

`installer.repo` is the GitHub `owner/name` the installers download releases from. It is optional in the schema — an app published nowhere has no repository to name — and required by `ariza installers`, which says so rather than rendering a script that 404s. Its shape is closed like a platform slug's: a full URL or a bare name is a hard error, not a warning.

`ci.ariza-source` is read only by `ariza scaffold-ci`, and says where the generated workflows install ariza from: `"fez"` (the default), or anything `zef install` accepts — a repository URL, for an app whose release workflow has to exist before ariza is published. Whichever is not in use is rendered beside it as a comment. Unlike a platform slug this is not a closed set, so only an **empty** value is an error: it would render a step that installs nothing and succeeds.

Smoke commands
--------------

`bundle.smoke` is a command, a list of commands, or a list of **argv arrays**. Nothing goes through a shell, in any form, so the argv shape can carry an entire program with no quoting layer to get wrong — which is what makes it reasonable for an app to smoke-test its database engine rather than only `--version`:

```toml
smoke = [
    ["{exec}", "--version"],
    ["{raku}", "-e", '''
use App::Moneymoor::DB;
# create, write and reopen an encrypted database under {tmp}
''', "{tmp}"],
]
```

`{exec}` is the launcher, `{raku}` the bundled interpreter, and `{site}`, `{native}`, `{bundle}` and `{tmp}` the rest of the bundle plus a scratch directory. A command that starts with `{exec}` is run with nothing but `PATH`/`HOME`/`TERM`, because that run is a test *of* the launcher; one that starts with `{raku}` additionally gets what the launcher would have exported, because it is standing in for code running inside the app.

Unknown keys warn; wrong types die
----------------------------------

Both config files follow the same rule, shared with `App::Shigur`: an unrecognised key at any level is collected into `warnings` and loading continues, so one file can serve several ariza versions in either direction. A wrongly-*typed* value dies immediately, naming the dotted path and the expected shape — `ariza: bundle.platforms must be an array of strings` — because a mistyped pin would otherwise be silently baked into an artefact. Keys beginning with `//` are ignored entirely, without a warning, in every ariza config file.

There is exactly one value-level exception. An unknown platform slug in `bundle.platforms` dies rather than warning, because the supported set is closed: a typo cannot be a future feature, and ignoring it would ship a release quietly missing a platform the author asked for. `macos-aarch64` for `macos-arm64` is the mistake this catches.

BUILDING ALL OF THEM: CI
========================

`ariza bundle` builds one bundle, on one machine, for the platform that machine is. A release needs one per declared platform, each built on a machine that **is** that platform — SQLCipher comes off the build host, so there is no cross-build to fall back on — and all of them published together. That is a CI problem, and `ariza scaffold-ci` writes the CI:

```console
$ ariza scaffold-ci --app=../App-Moneymoor
ariza: wrote /Users/you/Code/App-Moneymoor/.github/workflows/test.yml
ariza: wrote /Users/you/Code/App-Moneymoor/.github/workflows/release.yml
ariza: scaffolded 2 of 2 workflows for Moneymoor
```

Neither file is ariza's to run. Both are committed to the **app's** repository and run by GitHub, exactly as `install.sh` is committed and run by a user.

What release.yml does
---------------------

One build job per slug in `bundle.platforms`, in parallel, each doing the same three things after it has installed what ariza needs:

```console
bundle-macos-arm64           macos-latest, setup-raku, brew install sqlcipher
bundle-linux-x86_64-glibc    ubuntu-latest in a manylinux_2_28 container,
                             Rakudo from the rakudo.org index, SQLCipher
                             built from source at the pin
bundle-windows-x86_64        windows-latest, setup-raku, vcpkg + SQLCIPHER_LIB_DIR

                             …then: ariza bundle, ariza smoke, upload
```

The Linux lane is the one with a shape of its own, for two converging reasons. It builds inside `quay.io/pypa/manylinux_2_28_x86_64` so the archive's glibc floor is 2.28 — RHEL 8+, Ubuntu 18.10+, Debian 10+ — rather than whatever `ubuntu-latest` happens to ship this month; a bundle cannot be older than the machine that built it. And `Raku/setup-raku` cannot install into a container (it writes to the runner's tool cache, which is not in the container's filesystem), so the lane resolves the `[rakudo]` pin against the same JSON release index `App::Ariza::Rakudo` reads and unpacks the archive itself. There is no URL to construct — upstream filenames carry a toolchain suffix — so the index is the only honest route.

Then, on a tag only:

  * **`publish`** collects every lane's artefact, flattens it, recomputes a combined `checksums.txt`, checks that against the `.sha256` sidecars `ariza bundle` wrote — a release whose digest refuses its own archive is worse than one with no digest — and cuts the GitHub release with a body saying what a bundle is, which machines each archive runs on, and how to verify a download.

  * **`smoke-installer`** takes the archive that was **just published**, on a plain `ubuntu-latest` runner with nothing installed on it, installs it with the repository's own committed `install.sh`, and runs the installed launcher under `env -i`. It is the only job that exercises the artefact a user will actually receive, by the path they will actually take. Scaffolded for an app that declares `linux-x86_64-glibc` and has an `installer.repo`.

Dispatch before you tag
-----------------------

The workflow triggers on `workflow_dispatch` as well as on `push: tags: ['v*']`, and a dispatch run **stops after the build lanes**: `publish` and `smoke-installer` are both gated on `startsWith(github.ref, 'refs/tags/')`.

That is the iteration loop, and the reason the dispatch trigger exists. A recipe that has gone stale — a renamed package, a runner image that moved on, a vcpkg port that is not there any more — costs a run and a push to a branch, rather than a burnt tag and a deleted release. The dispatch input `ref` takes a branch, so the lane being fixed does not have to be on the default branch to be tried.

Which Raku is which
-------------------

Every lane installs a Raku **to run ariza with**, and it is not the runtime that ends up in the bundle: ariza downloads the pinned Rakudo for itself, verifies it, and unpacks that into the archive. The lane's own Raku can be any version, which is why `setup-raku` asks for `latest` rather than for anything in particular.

What is regenerated, and what is yours
--------------------------------------

`release.yml` is **derived** from `bundle.platforms`: add a platform, re-run `scaffold-ci`, and the file gains a lane and a `needs:` entry. It is rewritten in place every time, so a hand edit to it is an edit you will make twice.

`test.yml` is written **only when it is absent**. A test workflow acquires system dependencies, extra jobs and skip conditions that no generator can infer from a manifest — the scaffolded one is a starting point in the house shape (three runners, `zef install --deps-only`, `prove6 -I. t`), and the moment it is committed it is the repository's. `--force` overwrites it anyway. Each generated file's header says which of the two it is, so nobody has to remember.

For the same reason, an app whose **test suite** needs its native libraries has to add those steps itself: `bundle.native` says what a *bundle* carries, which is a different question from what a test run needs on the runner. The scaffolded `test.yml` names the libraries and says it is not installing them, rather than guessing either way.

The platforms it will scaffold
------------------------------

`macos-arm64`, `linux-x86_64-glibc` and `windows-x86_64`: the slugs with both a GitHub-hosted runner and an official Rakudo build behind them. A declared platform outside that set is a **hard error**, not a skipped job — the same reasoning as an unknown slug in `bundle.platforms`, since silently dropping one produces a release quietly missing a platform the author asked for. A bundle for one of the other five is built by hand today, and a generated lane for it would be a guess rather than a recipe.

FINDING RESOURCES
=================

ariza ships data: Jinja2 templates, shell partials, the pin file. It has to read them both when installed (where `zef` has staged every resource under a content-hashed name and `%?RESOURCES` is the only way back to the bytes) and from a source checkout (where `%?RESOURCES` is typically unpopulated and the files are sitting in `resources/`).

`App::Ariza::Resources` is the single place that knows this, so neither world is a special case anywhere else:

```raku
use App::Ariza::Resources;

resource('versions.toml').slurp;
resource('templates/launcher-posix.sh.j2').slurp;
resource-list('templates/ci');      # (templates/ci/lane-macos-arm64.yml.j2, …)
```

`resource-list` exists because `%?RESOURCES` cannot list a directory — an installed distribution's resources are flat. A checkout reads the working tree, so a file you just created is visible before you have listed it in META6; an installed run enumerates the distribution manifest, so it shows exactly what was packaged. Either way the paths come back with forward slashes, on Windows as much as anywhere else: these are META6 `resources` keys rather than paths into the filesystem, and the separator is the packaging spec's to choose. A resource that is missing from both fails loudly, naming the path it tried, because the cause is always the same packaging bug: a file on disk that nobody added to META6 `resources`.

COMMANDS
========

ariza bundle --app=DIR [--platform=SLUG] [--out-dir=DIR] [--sqlcipher-archive=FILE]
-----------------------------------------------------------------------------------

Build a bundle. `--platform` defaults to this machine's slug. `--sqlcipher-archive` stages SQLCipher from a local archive instead of from the build machine's package manager, which is what a cross-build (a Linux bundle needs a Linux library) or an air-gapped build needs. `SQLCIPHER_LIB_DIR` does the same job with a directory.

ariza smoke --archive=FILE [--keep]
-----------------------------------

Unpack a built archive somewhere new and check it. Exits non-zero if any check fails, so it drops straight into CI. `--keep` keeps the unpacked tree even on success.

ariza installers --app=DIR [--out-dir=DIR] [--branch=NAME]
----------------------------------------------------------

Render `install.sh`, `install.ps1`, `uninstall.sh` and `uninstall.ps1` from the app's `ariza.toml`. `--out-dir` defaults to the app's own repository root, since these are committed artefacts; `--branch` is the branch the `curl … | sh` one-liner names, `main` by default. An app declaring no Windows platform gets no `.ps1` pair — a script whose only possible answer is "there is no bundle for your machine" is worse than its absence.

ariza scaffold-ci --app=DIR [--out-dir=DIR] [--force]
-----------------------------------------------------

Write `.github/workflows/test.yml` and `release.yml` into the app's repository, from its `ariza.toml`. `release.yml` is derived from `bundle.platforms` and is rewritten every time; `test.yml` is written only when it is absent, because a test workflow acquires things a generator cannot infer. `--force` overwrites both. `--out-dir` writes somewhere else; the app's own `.github/workflows` is created if it is not there, which in a repository with no CI is the ordinary case.

ariza version
-------------

ariza's own distribution version.

ariza help
----------

Usage.

MODULES
=======

  * `App::Ariza` — the facade; one `cmd-*` class method per CLI verb.

  * `App::Ariza::Platform` — platform slugs and detection.

  * `App::Ariza::Versions` — the pinned component versions.

  * `App::Ariza::Config` — the per-app `ariza.toml` manifest.

  * `App::Ariza::Rakudo` — fetching, caching and unpacking the runtime.

  * `App::Ariza::Site` — installing the app's closure, and warming it.

  * `App::Ariza::Native` — staging SQLCipher, and the self-containment audit.

  * `App::Ariza::Launcher` — the one script a user runs.

  * `App::Ariza::Installer` — the four scripts that put a bundle on someone's machine, and take it off again.

  * `App::Ariza::CI` — the workflows that build every platform's bundle and publish them.

  * `App::Ariza::Bundle` — the orchestrator, and the bundle's metadata.

  * `App::Ariza::Smoke` — proving a finished archive works elsewhere.

  * `App::Ariza::Tools` — the shell-out layer: run, fetch, digest, extract.

  * `App::Ariza::Resources` — locating ariza's own data files.

AUTHOR
======

Matt Doughty

COPYRIGHT AND LICENSE
=====================

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

