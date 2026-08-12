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

Every verb is also a class method, so the whole tool is scriptable and the machinery underneath is a library in its own right:

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

ariza packages a Raku terminal application into something a stranger can run: a **bundle**, one archive per platform holding the app, a Rakudo runtime, every Raku dependency with its bytecode already compiled, and every native shared library the app touches — notcurses, SQLCipher, libvips — laid out so that unpacking it anywhere and running one launcher works. Nothing is fetched at run time, nothing is compiled on the user's machine, nothing needs root, and deleting the directory is the uninstall.

Around that are the two things a release needs either side of it. `ariza installers` renders the `install.sh` / `install.ps1` pair (and their uninstallers) that download a published bundle, verify its SHA-256, unpack it and put it on `PATH`. `ariza scaffold-ci` writes the GitHub Actions workflows that build one bundle per declared platform, on machines that are actually those platforms, and publish them together on a tag. `ariza smoke` is the gate between the two: it unpacks a finished archive somewhere it has never been, with a replaced environment, and reports on every check.

What a given app needs is declared by that app, in an `ariza.toml` in its own repository, so ariza stays a general tool rather than growing a list of special cases about particular applications.

The reasoning behind the shape of all this — why a bundle rather than a zef install, why the runtime is vendored and its bytecode warmed, why the native audit refuses to ship a bundle it cannot vouch for, where SQLCipher is allowed to come from — is recorded in `docs/design.md`. This document is how to use the tool.

INSTALLING
==========

```console
$ zef install App::Ariza
```

ariza runs on the machine that **builds** a release, and drives programs that are already on such a machine rather than pulling in libraries of its own:

  * `curl` or `wget`, and `tar` (plus `unzip` on Windows).

  * a SHA-256 tool — `sha256sum`, `shasum -a 256` or `certutil`, whichever is there.

  * **macOS**: `otool`, `install_name_tool` and `codesign`, from the Xcode command line tools.

  * **Linux**: `ldd` and `patchelf`. A missing `patchelf` is reported before the build starts, not half way through it.

  * **Windows**: nothing extra. PE import tables are read in Raku, because `dumpbin` ships only with Visual Studio and `objdump` with neither.

The one component ariza does not download for itself is SQLCipher; see **Where SQLCipher comes from**, below.

QUICK START
===========

Given an app repository with a `META6.json` and a `bin/` script:

```console
# 1. Declare what the app needs, once, in its own repository.
$ $EDITOR ../App-Moneymoor/ariza.toml

# 2. Build a bundle for this machine, and prove it runs elsewhere.
$ ariza bundle --app=../App-Moneymoor --out-dir=dist
$ ariza smoke  --archive=dist/moneymoor-0.2.0-macos-arm64.tar.gz

# 3. Generate the end-user scripts and the release workflows, and
#    commit them to the app's repository.
$ ariza installers  --app=../App-Moneymoor
$ ariza scaffold-ci --app=../App-Moneymoor

# 4. Tag. The workflow builds every declared platform, smokes each
#    bundle, publishes them, then installs the published artefacts
#    with the committed installers on clean runners.
```

COMMANDS
========

ariza bundle
------------

Build one self-contained bundle: the app, a Rakudo runtime, every Raku dependency, and every native library, in one directory and one archive.

```console
ariza bundle --app=DIR [--platform=SLUG] [--out-dir=DIR]
             [--sqlcipher-archive=FILE]
```

  * `--app=DIR` — the application's repository. Required. Its `META6.json` gives the version, its `ariza.toml` everything else.

  * `--platform=SLUG` — the platform to build for. Defaults to this machine's slug, and must be one the app declares in `bundle.platforms`.

  * `--out-dir=DIR` — where the bundle directory and archive are written. Defaults to the current directory.

  * `--sqlcipher-archive=FILE` — stage SQLCipher from a local archive instead of from this machine's package manager, which is what a cross-build or an air-gapped build needs. `SQLCIPHER_LIB_DIR` does the same job with a directory.

It produces three things beside each other, and leaves the unpacked bundle directory in place so `ariza smoke` (and you) can look inside it:

```console
$ ariza bundle --app=../App-Moneymoor --out-dir=dist

ariza: built moneymoor-0.2.0-macos-arm64
  archive       dist/moneymoor-0.2.0-macos-arm64.tar.gz
  compressed    50.4 MiB
  uncompressed  165.2 MiB
  sha256        6f0c…
  launcher      bin/moneymoor
  smoke it      ariza smoke --archive=dist/moneymoor-0.2.0-macos-arm64.tar.gz
```

The archive holds exactly one top-level directory, named after the bundle, so unpacking it anywhere is predictable and never scatters files into the current directory. The `.sha256` sidecar is written in the digest-then-filename shape `shasum -c` and `sha256sum -c` read, so verifying a download is one command with no arguments to remember.

Building a slug the app does not list in `bundle.platforms` is an error rather than a warning: producing an artefact named after a platform the author never claimed is a promise ariza has no business making on their behalf.

ariza smoke
-----------

Unpack a built archive somewhere new and check it, one line per check. Exits non-zero if any check fails, so it drops straight into CI.

```console
ariza smoke --archive=FILE [--keep]
```

  * `--archive=FILE` — the `.tar.gz` to check. Required.

  * `--keep` — keep the unpacked tree even on success. (A failed run keeps it regardless, and prints where.)

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

Two things about that run are worth knowing before you write a smoke command. The scratch directory it unpacks into has **a space in its name**, deliberately, so a launcher whose quoting slips is caught here rather than by a user with `~/Application Support/`. And each command runs with a **replaced** environment — `PATH`, `HOME`, `TERM`, and on Windows the handful of variables without which no process starts — so a bundle cannot pass by borrowing something from your shell. The commands themselves come from the archive's own `ariza-manifest.json`, so an archive can be checked with no access to the app's repository.

Every check runs; nothing short-circuits, because "the launcher failed" and "the launcher failed *and* the audit found a stray library" are different bug reports.

ariza installers
----------------

Render the four end-user scripts from the app's `ariza.toml`, into the app's own repository.

```console
ariza installers --app=DIR [--out-dir=DIR] [--branch=NAME]
```

  * `--app=DIR` — the application's repository. Required, and must have an `installer.repo` in its `ariza.toml` — the scripts download releases from it.

  * `--out-dir=DIR` — write somewhere else. The directory must exist. Defaults to the app's repository root, since these are committed artefacts.

  * `--branch=NAME` — the branch the `curl … | sh` one-liner in the generated header names. `main` by default.

```console
$ ariza installers --app=../App-Moneymoor
ariza: wrote /home/you/code/App-Moneymoor/install.sh
ariza: wrote /home/you/code/App-Moneymoor/install.ps1
ariza: wrote /home/you/code/App-Moneymoor/uninstall.sh
ariza: wrote /home/you/code/App-Moneymoor/uninstall.ps1
ariza: rendered 4 installers for Moneymoor
```

An app declaring no Windows platform gets no `.ps1` pair: a script whose only possible answer is "there is no bundle for your machine" is worse than its absence. What the generated scripts do on a user's machine is **The generated installers**, below.

ariza scaffold-ci
-----------------

Write `.github/workflows/test.yml` and `release.yml` into the app's repository, from its `ariza.toml`.

```console
ariza scaffold-ci --app=DIR [--out-dir=DIR] [--force]
```

  * `--app=DIR` — the application's repository. Required.

  * `--out-dir=DIR` — write somewhere other than the app's own `.github/workflows`, which is otherwise created if it is not there.

  * `--force` — replace `test.yml` too. By default it is written only when absent, while `release.yml` is always regenerated.

```console
$ ariza scaffold-ci --app=../App-Moneymoor
ariza: wrote /home/you/code/App-Moneymoor/.github/workflows/test.yml
ariza: wrote /home/you/code/App-Moneymoor/.github/workflows/release.yml
ariza: scaffolded 2 of 2 workflows for Moneymoor
```

Neither file is ariza's to run: both are committed to the **app's** repository and run by GitHub, exactly as `install.sh` is committed and run by a user. What they contain is **The generated workflows**, below.

ariza version
-------------

ariza's own distribution version.

ariza help
----------

Usage. `ariza --help` and `ariza -h` do the same.

THE BUNDLE
==========

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

  * **The launcher**, `bin/<exec> ` — it resolves its own physical path (through a `readlink` loop, not `readlink -f`, which is a GNU extension), takes the directory above it as the bundle root, points `RAKULIB` and `NOTCURSES_NATIVE_DATA_DIR` at the bundle, adds SQLCipher's location on the platforms that need it, and execs the bundled interpreter. Everything is quoted, so a path with spaces works. On Windows there are two, `<exec>.cmd ` and `<exec>.ps1 `.

  * **`rakudo/`** — the official runtime archive from `rakudo.org`, pinned by `[rakudo]` in `versions.toml`. On macOS the staged SQLCipher lives in `rakudo/lib`, which is already on the loader's path.

  * **`site/`** — one `CompUnit::Repository::Installation` holding the app and its whole closure, installed by the **bundled** `zef` so the bytecode matches the runtime that ships. Its precompilation store is warmed at build time: cold, a first launch spends about 55 seconds compiling, and does it again on every launch if the bundle lives somewhere unwritable, which for a downloaded archive is normal.

  * **`native/`** — the staged native libraries. Everything in here has been through the audit: every Mach-O, ELF or PE in the bundle must resolve inside it, or the build fails naming the file and the dependency.

  * **`VERSION`** — for a human in a bug report: the app, the platform, one line per pinned component.

  * **`ariza-manifest.json`** — the same facts plus the ones only a machine cares about: every source URL, every SHA-256, every Raku distribution installed with its version and author, and the smoke commands, which is what lets `ariza smoke` check an archive it knows nothing else about.

  * **`LICENSES/`** — the app's own `LICENSE` and Rakudo's, copied verbatim, plus a generated `COMPONENTS.md` whose native inventory is read off the staged libraries rather than written by hand. It notes explicitly that the notcurses pack's FFmpeg is a GPL build (`libx264`, `libx265`) rather than the LGPL one FFmpeg ships by default, because that has redistribution consequences.

Nothing is installed and nothing is written outside the directory, bar a one-line first-run marker under `XDG_STATE_HOME` that suppresses the "first launch takes a few seconds" notice on later runs.

THE PER-APP MANIFEST: ariza.toml
================================

Every verb reads this file out of the app's own repository. The complete schema:

```toml
[app]
name    = "App::Moneymoor"   # dist name, as zef knows it        (required)
exec    = "moneymoor"        # launcher / binary name            (required)
display = "Moneymoor"        # the product name, capitalised     (required)

[bundle]
platforms = ["macos-arm64", "linux-x86_64-glibc", "windows-x86_64"]
native    = ["notcurses", "sqlcipher"]
smoke     = "{exec} --version"     # command(s) `ariza smoke` runs

[installer]
repo = "m-doughty/App-Moneymoor"   # owner/name the releases live under

[ci]
ariza-source = "fez"               # how the workflows install ariza itself
```

  * **`app.display`** is required rather than derived because the correct capitalisation of a product name is not something a tool should guess at.

  * **`bundle.platforms`** is the closed list of slugs this app is built and tested for. It is what `ariza bundle` enforces, and what the generated installers detect against — so an app that has never built for musl says so on an Alpine box rather than downloading something that cannot run there. An unknown slug here is a hard error; see **Platforms**, below.

  * **`bundle.native`** names the native libraries a *bundle* carries. It is not a statement about what a test run needs on a CI runner, which is why the scaffolded `test.yml` names them and says it is not installing them.

  * **`installer.repo`** is the GitHub `owner/name` the installers download releases from. Optional in the schema — an app published nowhere has no repository to name — and required by `ariza installers`, which says so rather than rendering a script that 404s. Its shape is closed: a full URL or a bare name is an error, not a warning.

  * **`ci.ariza-source`** is read only by `ariza scaffold-ci`, and says where the generated workflows install ariza from: `"fez"` (the default) or anything `zef install` accepts, such as a repository URL for an app whose release workflow has to exist before ariza is published. Whichever is not in use is rendered beside it as a comment. This is not a closed set, so only an **empty** value is an error — it would render a step that installs nothing and succeeds.

Smoke commands
--------------

`bundle.smoke` is a command, a list of commands, or a list of **argv arrays**. Nothing goes through a shell in any form, so the argv shape can carry an entire program with no quoting layer to get wrong — which is what makes it reasonable for an app to smoke-test its database engine rather than only `--version`:

```toml
smoke = [
    ["{exec}", "--version"],
    ["{raku}", "-e", '''
use App::Moneymoor::DB;
# create, write and reopen an encrypted database under {tmp}
''', "{tmp}"],
]
```

Each argv word is expanded against the unpacked bundle:

  * `{exec}` — the launcher, `bin/<exec> `.

  * `{raku}` — the bundled interpreter.

  * `{site}` — the module repository.

  * `{native}` — the staged native libraries.

  * `{bundle}` — the bundle root.

  * `{tmp}` — a writable scratch directory beside the unpacked bundle.

Which environment a command gets depends on how it starts. One starting with `{exec}` goes through the launcher and so gets nothing but `PATH`, `HOME` and `TERM`: that run is a test *of* the launcher's ability to set up its own world. One starting with `{raku}` additionally gets exactly what the launcher would have exported — `RAKULIB`, `NOTCURSES_NATIVE_DATA_DIR` and the SQLCipher variables — because it is standing in for code running *inside* the app.

Unknown keys warn; wrong types die
----------------------------------

Both `ariza.toml` and `versions.toml` follow the same rule: an unrecognised key at any level is collected into `warnings` and loading continues, so one file can serve several ariza versions in either direction. A wrongly-*typed* value dies immediately, naming the dotted path and the expected shape — `ariza: bundle.platforms must be an array of strings` — because a mistyped pin would otherwise be silently baked into an artefact. Keys beginning with `//` are ignored entirely, without a warning, in every ariza config file.

There is exactly one value-level exception. An unknown platform slug in `bundle.platforms` dies rather than warning, because the supported set is closed: a typo cannot be a future feature, and ignoring it would ship a release quietly missing a platform the author asked for. `macos-aarch64` for `macos-arm64` is the mistake this catches.

PINNED VERSIONS: versions.toml
==============================

`App::Ariza::Versions` parses `resources/versions.toml`, ariza's own copy of the one file every artefact's version numbers come from, so that a bump re-renders everything in lockstep and nothing drifts:

```toml
sqlcipher = "4.14.0"

[rakudo]
version  = "2026.07"
revision = "01"
```

`[rakudo]` is the runtime a bundle embeds; `revision` disambiguates rebuilds of the same upstream release — a repackaged runtime, a patched MoarVM — without pretending upstream cut a new version. `rakudo-tag` joins the two as `2026.07-01`, and `ariza scaffold-ci` quotes it into the generated workflows.

`sqlcipher` is **advisory**. The build machine's package manager decides what is actually installed, so ariza reads the version out of the staged library's own bytes and warns if it disagrees:

```console
ariza: sqlcipher 4.17.0 staged, pin says 4.14.0
```

The build continues, and `ariza-manifest.json` records the version that was **staged**, the pin beside it, the digest of the library as it came off the machine, and which keg, bottle or archive it came from.

PLATFORMS
=========

`App::Ariza::Platform` names the platform an artefact is for:

```console
macos-arm64            macos-x86_64
linux-x86_64-glibc     linux-aarch64-glibc
linux-x86_64-musl      linux-aarch64-musl
windows-x86_64         windows-arm64
```

These strings are not ariza's to choose: they are Notcurses-Native's platform slugs, character for character, because a bundle carries that distribution's prebuilt notcurses libraries and the two have to agree about what platform they are on.

Detection reads `$*KERNEL` and, on Linux only, probes the C library — a `ld-musl-*.so.1` loader under `/lib` or `/usr/lib` settles it immediately, otherwise `ldd --version` is parsed for a glibc version. A Linux system with neither (uclibc, a static busybox image) produces an honest "unsupported platform" rather than a bundle that will not run.

Setting `ARIZA_PLATFORM` to a known slug short-circuits detection, which is what makes cross-builds and CI matrices possible. An override that is not a known slug is a hard error: every other input is a system fact that might legitimately be unnameable, but an override is a human typing a string.

`ariza scaffold-ci` generates lanes for `macos-arm64`, `linux-x86_64-glibc` and `windows-x86_64` — the slugs with both a GitHub-hosted runner and an official Rakudo build behind them. A declared platform outside that set is a hard error there too, not a skipped job. Bundles for the other five are built by hand.

WHERE SQLCIPHER COMES FROM
==========================

notcurses arrives on its own — Notcurses-Native's prebuilt pack is staged as a side effect of the `zef` install. SQLCipher has no such hook, so ariza takes it from the build machine's own package manager, and there is deliberately no ariza-operated mirror to download from.

  * **macOS** — the installed Homebrew keg (`brew --prefix sqlcipher`), or, if it is not installed, the bottle `brew fetch --formula sqlcipher` puts in the cache.

  * **Linux** — whatever `ldconfig -p` resolves `libsqlcipher.so.0` to, falling back to the Debian multiarch, Red Hat and Alpine library directories. CI installs the distribution package before it calls `ariza bundle`.

  * **Windows** — an MSYS2 environment's `bin` (`MSYSTEM_PREFIX`, then `C:\msys64\ucrt64\bin`), a vcpkg tree under `VCPKG_ROOT`, or wherever `SQLCIPHER_LIB_DIR` points. The two package managers disagree about the name — `libsqlcipher-0.dll` against `sqlcipher.dll` — so ariza accepts either, newest first, and stages whatever it finds under the canonical one. CI takes MSYS2's `mingw-w64-ucrt-x86_64-sqlcipher` rather than vcpkg's port, because an MSVC-built SQLCipher imports `vcruntime140.dll`, which is not part of Windows.

Two overrides beat the package managers, in this order:

  * **`--sqlcipher-archive=FILE`** — an archive to unpack.

  * **`SQLCIPHER_LIB_DIR`** — a directory holding the library.

Both are how a cross-build works, and they are the only way to be honest about one: a library installed on this machine is built **for** this machine, so ariza refuses to take one when the platform being built is not the platform it is building on. Missing entirely, on any platform, is a death naming the package to install **and** the override to pass — never a silent bundle without a database.

Whatever is staged is then made self-contained: every library it names outside the bundle is copied in beside it and rewritten to load from there (`install_name_tool` on macOS, `patchelf --set-rpath '$ORIGIN'` on Linux, one directory on Windows, which is how PE resolves imports anyway), and the audit refuses to ship the bundle if anything still points off the machine. `docs/design.md` has the per-format detail, including why a Linux bundle has to be built on Linux and a Windows one does not have to be built on Windows.

THE GENERATED INSTALLERS
========================

A bundle is self-contained, so "installing" it is unpacking it somewhere and running the launcher. The four generated scripts do exactly that, and nothing more. They are committed at the app's repository root, because `curl` has to be able to fetch them from somewhere, and what a user runs is one line:

```console
$ curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | sh
==> Moneymoor 0.2.0 for macos-arm64
==> downloading https://github.com/…/moneymoor-0.2.0-macos-arm64.tar.gz
ok  sha256 verified
ok  added /home/you/.local/bin to PATH in /home/you/.zshrc
ok  Moneymoor 0.2.0 installed

    run it:        moneymoor
    installed in:  /home/you/.local/share/moneymoor/versions/0.2.0
    uninstall:     curl -fsSL https://raw.githubusercontent.com/…/uninstall.sh | sh
```

That raw URL is built from `installer.repo` and the `--branch` flag. It only becomes a working link once the repository is public — until then the same script runs just as well as a file, `sh install.sh`.

What it does:

  * Detects the platform and downloads the matching release asset — one of the slugs the app **declares**, never a nearest match.

  * **Verifies the SHA-256** against the `.sha256` asset published beside it. No digest, no install.

  * Unpacks into `$XDG_DATA_HOME/<exec>/versions/<version>/ `, beside whatever is already there, and only then flips a `current` symlink and links `~/.local/bin/<exec> ` at it. A failed or interrupted download cannot damage a working install.

  * Adds `~/.local/bin` to `PATH` **only if it is not there already**, through one marked block in each shell rc file that exists. Re-running never duplicates it; the uninstaller removes exactly that block and nothing else.

  * Keeps one previous version to roll back to, prunes anything older, and says which.

  * Needs no root, no compiler, no package manager and no Raku.

Re-running it for a version that is already installed downloads nothing: it re-points the symlinks, re-checks the PATH block and exits saying "already installed" — which makes "run the installer again" the correct advice for the most common breakage. An existing version directory with no runnable launcher in it is not a version, and is replaced rather than trusted.

Choosing a version, and the escape hatch
----------------------------------------

The default is the latest release, read from the `location:` header of `https://github.com/<owner>/<repo>/releases/latest` — one HEAD request, no API token, no `jq`. `--version v1.2.3` names a tag instead.

`--url`, or the `<EXEC>_BUNDLE_URL ` environment variable (e.g. `MONEYMOOR_BUNDLE_URL`), installs from a source you name and bypasses GitHub entirely. It takes a **plain file path** as readily as a URL, which is what makes an air-gapped install, a release candidate, and ariza's own end-to-end test possible with no network and no published release.

`--insecure-no-verify` applies to that path **only**. A source you named yourself may legitimately have no `.sha256` beside it, and the script says so loudly before continuing; a published release always has one, so a missing digest there stays fatal however many flags are passed.

Windows
-------

The same shape in PowerShell: `%LOCALAPPDATA%\<Display>\versions\<version> `, a `current` **junction** rather than a symlink (which would need administrator rights or Developer Mode, and a per-user install has no business demanding either), and `...\current\bin` added once to the user `PATH` in `HKCU\Environment`. Because the PATH entry points through the junction, an upgrade needs no PATH change at all.

It is meant to be piped, so it never asks
-----------------------------------------

A script read from a pipe is executed as it arrives, so the generated one is entirely definitions with a single `main "$@"` on the last line: a truncated download cannot half-run it. It also never reads standard input — no prompts, no confirmations — because when the script arrives *on* standard input there is nothing left to read from. That is what makes it runnable from CI.

THE GENERATED WORKFLOWS
=======================

`ariza bundle` builds one bundle, on one machine, for the platform that machine is. A release needs one per declared platform, each built on a machine that **is** that platform, and all of them published together. `ariza scaffold-ci` writes the CI that does it.

release.yml
-----------

One build job per slug in `bundle.platforms`, in parallel, each doing the same three things — `ariza bundle`, `ariza smoke`, upload the archive and its `.sha256` — after it has installed what ariza needs:

```console
bundle-macos-arm64           macos-latest, setup-raku, brew install sqlcipher
bundle-linux-x86_64-glibc    ubuntu-latest in a manylinux_2_28 container,
                             Rakudo from the rakudo.org index, SQLCipher
                             built from source at the pin
bundle-windows-x86_64        windows-latest, setup-raku, MSYS2 pacman
                             (mingw-w64-ucrt-x86_64-sqlcipher) +
                             SQLCIPHER_LIB_DIR
```

The Linux lane has a shape of its own for two converging reasons. It builds inside `quay.io/pypa/manylinux_2_28_x86_64` so the archive's glibc floor is 2.28 — RHEL 8+, Ubuntu 18.10+, Debian 10+ — rather than whatever `ubuntu-latest` happens to ship this month; a bundle cannot be older than the machine that built it. And `Raku/setup-raku` cannot install into a container, so the lane resolves the `[rakudo]` pin against the same JSON release index `App::Ariza::Rakudo` reads and unpacks the archive itself.

Every lane installs a Raku **to run ariza with**, and it is not the runtime that ends up in the bundle: ariza downloads the pinned Rakudo for itself, verifies it, and unpacks that into the archive. The lane's own Raku can be any version, which is why `setup-raku` asks for `latest`.

Then, on a tag only:

  * **`publish`** collects every lane's artefact, flattens it, recomputes a combined `checksums.txt`, checks that against the `.sha256` sidecars `ariza bundle` wrote — a release whose digest refuses its own archive is worse than one with no digest — and cuts the GitHub release with a body saying what a bundle is, which machines each archive runs on, and how to verify a download.

  * **`smoke-installer-macos-arm64`**, **`smoke-installer-linux-x86_64-glibc`** and **`smoke-installer-windows-x86_64`** each take the archive that was **just published**, on a plain runner with nothing installed on it, and install it with the repository's own committed `install.sh` or `install.ps1`, then run the installed launcher under a stripped environment (`env -i` on POSIX; a from-scratch `System.Diagnostics.Process` on Windows, which has no `env -i`). These are the only jobs that exercise the artefact a user will actually receive, by the path they will actually take. They are scaffolded for an app with an `installer.repo`; a declared platform with a build lane but no smoke recipe yet gets no job here, and the workflow says so in a comment rather than leaving the gap silent.

Dispatch before you tag
-----------------------

The workflow triggers on `workflow_dispatch` as well as on `push: tags: ['v*']`, and a dispatch run **stops after the build lanes**: `publish` and every `smoke-installer-*` job are gated on `startsWith(github.ref, 'refs/tags/')`.

That is the iteration loop. A recipe that has gone stale — a renamed package, a runner image that moved on — costs a run and a push to a branch, rather than a burnt tag and a deleted release. The dispatch input `ref` takes a branch, so the lane being fixed does not have to be on the default branch to be tried.

What is regenerated, and what is yours
--------------------------------------

`release.yml` is **derived** from `bundle.platforms`: add a platform, re-run `scaffold-ci`, and the file gains a lane and a `needs:` entry. It is rewritten in place every time, so a hand edit to it is an edit you will make twice.

`test.yml` is written **only when it is absent**. A test workflow acquires system dependencies, extra jobs and skip conditions that no generator can infer from a manifest — the scaffolded one is a starting point in the house shape (three runners, `zef install --deps-only`, `prove6 -I. t`), and the moment it is committed it is the repository's. `--force` overwrites it anyway. Each generated file's header says which of the two it is, so nobody has to remember.

ENVIRONMENT
===========

Read by ariza while it builds:

  * **`ARIZA_PLATFORM`** — force the platform slug, bypassing detection. Must be a known slug; anything else is a hard error.

  * **`SQLCIPHER_LIB_DIR`** — a directory holding the SQLCipher library. Beats every package-manager source; `--sqlcipher-archive` beats it.

  * **`MSYSTEM_PREFIX`** — Windows: the MSYS2 environment whose `bin` is searched for the library, before `VCPKG_ROOT` and the default prefixes.

  * **`VCPKG_ROOT`** — Windows: a vcpkg tree whose `installed/<triplet>/bin ` is searched.

  * **`XDG_CACHE_HOME`** — where the downloaded Rakudo runtime is cached, under `ariza/rakudo`. Defaults to `~/.cache`.

Set by the bundle's launcher, for the app it starts:

  * **`RAKULIB`** — `inst#<root>/site `, the bundle's repository and the only one. `PERL6LIB` is unset.

  * **`NOTCURSES_NATIVE_DATA_DIR`** — `<root>/native `, where Notcurses::Native finds its libraries and its terminfo.

  * **`LD_LIBRARY_PATH`** — Linux only: the bundle's SQLCipher directory, prepended.

  * **`DBIISH_SQLCIPHER_LIB`** — the staged SQLCipher library, by absolute path, on the platforms that need it.

  * **`XDG_STATE_HOME`** — read, not set: where the one-line first-run marker lives. Defaults to `~/.local/state`.

Read by the generated installers:

  * `<EXEC>_BUNDLE_URL ` — e.g. `MONEYMOOR_BUNDLE_URL`. Install from this URL or plain file path instead of from GitHub releases; the same as `--url`.

  * **`XDG_DATA_HOME`** — the POSIX install root, holding `<exec>/versions/<version> `. Windows uses `%LOCALAPPDATA%`.

Read by ariza's own test suite:

  * **`ARIZA_E2E_ARCHIVE`** — a built bundle archive for `xt/02-installer-e2e`. Without it that file skips, because there is nothing honest to test.

  * **`ARIZA_REGENERATE_GOLDEN`** — rewrite the `t/golden/` launcher, installer and workflow fixtures after an intentional change.

  * **`ARIZA_PROOF_*`** — knobs for `xxt/linux-selfcontain-proof.sh`: `_IMAGE`, `_PLATFORM`, `_CACHE`, `_SQLCIPHER` and `_SQLCIPHER_VERSION`.

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

Each module's Pod is the reference for its own corner; the ones most worth reading directly are `App::Ariza::Native` (the audit) and `App::Ariza::Config` (the manifest).

Finding ariza's own data files
------------------------------

ariza ships data — Jinja2 templates, shell partials, the pin file — and has to read it both when installed (where `zef` has staged every resource under a content-hashed name and `%?RESOURCES` is the only way back to the bytes) and from a source checkout (where `%?RESOURCES` is typically unpopulated and the files are sitting in `resources/`). `App::Ariza::Resources` is the single place that knows this:

```raku
use App::Ariza::Resources;

resource('versions.toml').slurp;
resource('templates/launcher-posix.sh.j2').slurp;
resource-list('templates/ci');      # (templates/ci/lane-macos-arm64.yml.j2, …)
```

`resource-list` exists because `%?RESOURCES` cannot list a directory: an installed distribution's resources are flat. Paths come back with forward slashes on every platform, because these are META6 `resources` keys rather than paths into the filesystem. A resource missing from both worlds fails loudly, naming the path it tried — the cause is always a file on disk that nobody added to META6 `resources`.

TESTING
=======

```console
$ prove6 -Ilib t/
```

Fourteen files, none of which needs a network, a package manager or a built bundle: renderers are checked against byte-for-byte goldens in `t/golden/`, and everything that shells out takes a `:&run` seam, so the macOS, Linux and Windows branches of each are covered from any one of them.

`xt/` holds the checks that need something external — the live rakudo.org release index, a real PE binary, and an end-to-end installer run against a real archive (`ARIZA_E2E_ARCHIVE`). `xxt/` holds `linux-selfcontain-proof.sh`, which runs a whole bundle build inside a `manylinux` container, re-checks the result independently in shell, and asserts that three planted defects each make the audit fail.

SEE ALSO
========

`docs/design.md` — the design record: the decisions behind bundles, the vendored runtime, the native self-containment stance, SQLCipher sourcing, the smoke harness and the release pipeline, with the reasoning that produced each.

AUTHOR
======

Matt Doughty

COPYRIGHT AND LICENSE
=====================

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

