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
  licensing     41 components (THIRD-PARTY.md)
  smoke it      ariza smoke --archive=dist/moneymoor-0.2.0-macos-arm64.tar.gz
```

The archive holds exactly one top-level directory, named after the bundle, so unpacking it anywhere is predictable and never scatters files into the current directory. The `.sha256` sidecar is written in the digest-then-filename shape `shasum -c` and `sha256sum -c` read, so verifying a download is one command with no arguments to remember.

Building a slug the app does not list in `bundle.platforms` is an error rather than a warning: producing an artefact named after a platform the author never claimed is a promise ariza has no business making on their behalf.

A **Windows** build additionally downloads the compiled launcher for the target architecture — from the App-Ariza release named by `resources/RUNNER_VERSION`, verified against `resources/runner-checksums.txt`, cached under `$XDG_CACHE_HOME/ariza/runner` — and stages it as `bin/<exec>.exe `. While that pin file is still empty the bundle is built without it and the build says so; once it is not, a failed download or a digest mismatch fails the build. **The Windows runner**, below, is the whole story.

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
ok   target         rakudo/share/perl6/vendor/bin/moneymoor.raku
ok   precomp        417 precompiled artefacts ship with the bundle
ok   precomp-relocatable 2938 dependency records, all repository-relative
ok   native-audit   26 native binaries resolve inside the bundle
ok   smoke[0]       {exec} → exit 0: App::Moneymoor 0.2.0
ok   smoke[1]       {raku} → exit 0: ok: encrypted database created, written and reopened

ariza: 10 checks passed
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
    share/perl6/vendor/    every Raku module, with warm bytecode
  native/                  notcurses and friends
  VERSION                  app version and component pins, one screen
  ariza-manifest.json      the same, machine-readable, plus every sha256
  THIRD-PARTY.md           every component, its licence, and where that
                           fact came from
  LICENSES/                the text of every licence the above cites

moneymoor-0.2.0-macos-arm64.tar.gz          50 MiB (165 MiB unpacked)
moneymoor-0.2.0-macos-arm64.tar.gz.sha256
```

On Windows, `bin/` holds four files instead of one:

```console
moneymoor-0.2.0-windows-x86_64/
  bin/moneymoor.exe        the launcher — this is the one to run
  bin/moneymoor.ariza      what it reads: the target, and this bundle's
                           environment as ordered directives
  bin/moneymoor.cmd        the same launch as a batch file
  bin/moneymoor.ps1        and as PowerShell
  …
```

  * **The launcher**, `bin/<exec> ` — it resolves its own physical path (through a `readlink` loop, not `readlink -f`, which is a GNU extension), takes the directory above it as the bundle root, points `RAKULIB` and `NOTCURSES_NATIVE_DATA_DIR` at the bundle, adds SQLCipher's location on the platforms that need it, and execs the bundled interpreter. Everything is quoted, so a path with spaces works. On Windows it is `<exec>.exe ` — see **The Windows runner** below — with `<exec>.cmd ` and `<exec>.ps1 ` shipped beside it.

  * **`rakudo/`** — the official runtime archive from `rakudo.org`, pinned by `[rakudo]` in `versions.toml`. On macOS the staged SQLCipher lives in `rakudo/lib`, which is already on the loader's path.

  * **`rakudo/share/perl6/vendor/`** — one `CompUnit::Repository::Installation` holding the app and its whole closure, installed by the **bundled** `zef` so the bytecode matches the runtime that ships. Its precompilation store is warmed at build time: cold, a first launch spends about a minute compiling, and does it again on every launch if the bundle lives somewhere unwritable, which for a downloaded archive is normal.

The location is not decorative. Rakudo records what a compiled module depends on relative to its repository — `vendor#sources/<id> ` — but only for the four repositories the registry has a **name** for: `core`, `vendor` and `site` under the running interpreter's own prefix, and `home` under `$HOME`. Put the app anywhere else, name it in `RAKULIB`, and the dependencies are recorded as absolute paths on the machine that built it — so the first user to unpack the bundle somewhere else gets every one of those units declared outdated and recompiles the entire closure, once, silently. The runtime's own `vendor` prefix is a repository that *has* a name, which is what makes the shipped bytecode usable anywhere. `ariza smoke` checks the records rather than trusting them.

  * **`native/`** — the staged native libraries. Everything in here has been through the audit: every Mach-O, ELF or PE in the bundle must resolve inside it, or the build fails naming the file and the dependency.

  * **`VERSION`** — for a human in a bug report: the app, the platform, one line per pinned component.

  * **`ariza-manifest.json`** — the same facts plus the ones only a machine cares about: every source URL, every SHA-256, every Raku distribution installed with its version and author, and the smoke commands, which is what lets `ariza smoke` check an archive it knows nothing else about.

  * **`THIRD-PARTY.md`** and **`LICENSES/`** — what the bundle redistributes and under what terms, with the text of every licence it cites. Both are generated from what is actually in the bundle rather than written by hand; **Licensing**, below, is the whole story.

Nothing is installed and nothing is written outside the directory, bar a one-line first-run marker under `XDG_STATE_HOME` that suppresses the "first launch takes a few seconds" notice on later runs.

THE WINDOWS RUNNER
==================

`bin/<exec>.exe ` is a small C program — ariza's own, in this repository's `runner/` directory — that does the whole launch with **no `cmd.exe` involved**. It is the documented Windows entry point; the `.cmd` and `.ps1` launchers still ship, do the same job, and are the transparent alternative for anyone who would rather read their launcher than trust it.

Three things it fixes, in the order you are likely to hit them:

  * **Argument fidelity.** A batch launcher ends in `%*`, and `%*` is not what the user typed — it is what the user typed after `cmd.exe` has had a second go at it. `^` is an escape character, `%VAR%` and `!x!` are expansions, and a quoted argument gets re-split. The executable never parses the tail at all: it finds where its own argv[0] ends and copies every byte after it into the child's command line unchanged, so the app's `@*ARGS` is what the shell produced.

  * **Script-execution policy.** AppLocker and Software Restriction Policies have a script rule that blocks `.cmd` and `.ps1` files however they are invoked, and a locked-down `ExecutionPolicy` stops the PowerShell twin on its own. Those environments run executables. A bundle that could not be launched in one was a bundle unusable at half the places these apps are wanted.

  * **Spawnability and pinning.** Something that wants to start the app — a shortcut, a task, another program — can `CreateProcess` an `.exe` directly; a `.cmd` needs an interpreter in front of it. And because the executable is a fixed artefact rather than a rendered script, it is published once per release, pinned by SHA-256, and staged into a bundle only if the bytes match.

What it reads is `bin/<exec>.ariza `, a plain UTF-8 file beside it:

```text
target rakudo\share\perl6\vendor\bin\moneymoor.raku
app-exec moneymoor
app-display Moneymoor
set RAKULIB=inst#{root}\rakudo\share\perl6\vendor
unset PERL6LIB
set NOTCURSES_NATIVE_DATA_DIR={root}\native
prepend-path {root}\native\sqlcipher
set DBIISH_SQLCIPHER_LIB={root}\native\sqlcipher\sqlcipher.dll
```

`{root}` is the bundle root, worked out at run time from the executable's own location, so nothing absolute is baked in and the bundle stays movable. The `set`, `unset` and `prepend-path` directives are applied top to bottom, and **the runner has no idea what any of them mean** — every fact about Rakudo's repository, notcurses' data directory or a bundled DLL lives in ariza's renderer, exactly as it does in the `.cmd` template. A bundle that grows a native dependency grows a line in this file rather than needing a new executable.

Pinning, and the two states of the pin file
-------------------------------------------

The runner is built by ariza's own `runner-release.yml` workflow, in MSYS2 UCRT64 (x86_64) and CLANGARM64 (aarch64), published to the release named by `resources/RUNNER_VERSION`, and pinned by digest in `resources/runner-checksums.txt`. `ariza bundle` downloads the artefact for the target architecture, verifies it, and stages it.

That pin file has exactly two states:

  * **Empty** — a Windows bundle is built **without** the executable and says so once, loudly. The bundle launches from its `.cmd`, which is what ariza produced before the runner existed.

  * **Any pin recorded** — a missing entry, a failed download or a digest mismatch **fails the build**. From that point on a bundle without a verified runner is a regression rather than a stage of bootstrapping.

There is no third state, no `--no-runner` and no `--skip-verify`: an unverified executable staged into a bundle is not a degraded build, it is a different piece of software.

It is not signed
----------------

Not yet. Windows SmartScreen will show its "unrecognised app" prompt the first time a user runs a bundle's `.exe`, and the honest answer is that signing needs a certificate and a signing story that ariza does not have today. `sha256sum -c` against the published `checksums.txt` is what there is, and the `.cmd` launcher is the way past a SmartScreen prompt someone would rather not click through.

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
warm = "--version"                 # run once at install time; false skips it

[updates]
enabled = true                     # weekly managed-install update prompt

[ci]
ariza-source = "fez"               # how the workflows install ariza itself

[licensing]
strict = false                     # an unattributed native pack fails the build

[licensing.app]                    # defaults from the app's own META6
copyright = "Copyright 2026 A Person"

[[licensing.third-party]]          # anything ariza cannot see for itself
name = "Some Artwork"
spdx-license = "CC-BY-4.0"
license-files = ["licenses/CC-BY-4.0.txt"]

[[licensing.dists]]                # a dependency whose own metadata is wrong
name = "Some::Ancient::Module"
spdx-license = "Artistic-2.0"
```

  * **`app.display`** is required rather than derived because the correct capitalisation of a product name is not something a tool should guess at.

  * **`bundle.platforms`** is the closed list of slugs this app is built and tested for. It is what `ariza bundle` enforces, and what the generated installers detect against — so an app that has never built for musl says so on an Alpine box rather than downloading something that cannot run there. An unknown slug here is a hard error; see **Platforms**, below.

  * **`bundle.native`** names the native libraries a *bundle* carries. It is not a statement about what a test run needs on a CI runner, which is why the scaffolded `test.yml` names them and says it is not installing them.

  * **`installer.repo`** is the GitHub `owner/name` the installers download releases from. Optional in the schema — an app published nowhere has no repository to name — and required by `ariza installers`, which says so rather than rendering a script that 404s. Its shape is closed: a full URL or a bare name is an error, not a warning.

  * **`installer.warm`** is what the generated installers run the freshly installed launcher with, once, before they print the parting message. It defaults to `--version` — the same canary `bundle.smoke` uses, chosen because it is the one invocation every bundled app answers and **returns from**. `false` skips the step; a string is a command line split on whitespace; an array is taken word for word. An **empty** value is an error rather than either of the things it might mean: a launcher run with no arguments starts the application, which does not return, and the installers impose no timeout on purpose. See **The generated installers**, below, for what happens when it fails.

  * **`updates.enabled`** opts a bundle into managed-install update prompts. It defaults to `false`, must be a TOML boolean, and requires `installer.repo` because that exact repository is the only release source the generated coordinator will trust. See **Managed-install update prompts**, below.

  * **`ci.ariza-source`** is read only by `ariza scaffold-ci`, and says where the generated workflows install ariza from: `"fez"` (the default) or anything `zef install` accepts, such as a repository URL for an app whose release workflow has to exist before ariza is published. The default resolves `App::Ariza:ver<0.1.4+>:auth<zef:apogee>`, pinning both the compatibility floor and the publisher identity. Whichever source is not in use is rendered beside it as a comment. This is not a closed set, so only an **empty** value is an error — it would render a step that installs nothing and succeeds.

  * **`[licensing]`** is optional in every part. An app that writes none of it still gets a complete `THIRD-PARTY.md`, because everything in that document is read out of the bundle rather than declared. The table is for the two things that cannot be: how strict to be about a payload nobody attributed, and what the app itself ships that ariza cannot see. See **Licensing**, below.

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

  * `{site}` — the module repository, wherever the manifest says the bundle put it.

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

LICENSING
=========

A bundle is a binary redistribution of other people's software: a vendored Rakudo, the C libraries compiled into its MoarVM, every Raku distribution in the closure, a native pack or two, SQLCipher where an app asks for it, and — on Windows — a compiled launcher. Every build writes two files that say so.

```console
moneymoor-0.2.0-macos-arm64/
  THIRD-PARTY.md      one row per component: what, which version, which
                      licence, whose copyright, and where that came from
  LICENSES/           the full text of every licence those rows cite
```

Nothing in it is written down in ariza
--------------------------------------

ariza bundles **anybody's** application, so it holds no table of who wrote what. Every row comes from one of four sources, and each row says which one it came from:

  * **A native pack's own licensing kit.** A pack that ships a `third-party.json` is read from it, component by component, filtered to the platform being built. A pack that ships only the generated `THIRD-PARTY.md` is read from that instead — the same rows, out of a document rather than a manifest.

  * **ariza's own `resources/runtime-third-party.json`.** The vendored Rakudo, NQP and MoarVM, the C libraries MoarVM vendors under its `3rdparty/` (libuv, dyncall, DynASM, LibTomMath, cmp, libatomic_ops, mimalloc, rapidhash, zmij and the rest), SQLCipher and the Windows runner. These arrive as compiled bytes inside archives with no manifest, so there is nothing in the bundle to ask; this file is the answer, and it is data rather than code precisely so that bumping the Rakudo pin to a release whose MoarVM vendors one more library is a row here rather than a patch.

  * **Each installed distribution's `META6.json`.** The `license` field, read out of the repository the app was installed into **and** the runtime's own `site` — which is where the `zef` that came down with Rakudo lives, and which is redistributed like everything else.

  * **The app's `ariza.toml`.** Its own row, and rows for whatever it ships that ariza cannot see: a font, a dataset, artwork, a vendored library of its own.

What fails, and what merely warns
---------------------------------

The rule is that silence is never an option, and the difference between a warning and a failure is whether ariza has anything true to say instead.

  * A native pack with **no licensing kit at all** becomes a visible row saying exactly that, plus a warning on the build. It is not dropped: a redistributed binary nobody attributed is the thing the document exists to make visible. `licensing.strict = true` makes it a failed build, for a project that will not ship one.

  * A distribution with **no `license` field**, or with one ariza has no licence text for, **fails the build** — naming **every** such distribution in the closure at once, with both fixes: the field itself, or a `[[licensing.dists]]` row. There is no "unknown" row for a Raku module: the field exists and filling it in is a one-line change. In a real closure this does fire — the ecosystem has distributions with no `license` field, and a handful that say `NOASSERTION` — so expect to write a few `[[licensing.dists]]` rows the first time, once.

  * A **cited licence text that is nowhere to be found** fails the build naming the identifier and how to supply one. ariza ships the texts for `Artistic-2.0`, `MIT`, `Apache-2.0`, `BSD-2-Clause`, `BSD-3-Clause`, `LGPL-2.1`, `LGPL-3.0`, `GPL-2.0`, `GPL-3.0`, `AGPL-3.0`, `Zlib`, `ISC`, `X11`, `OFL-1.1` and `Unlicense`, plus a public-domain statement — sixteen in all, and the set is a decision rather than a side effect, so a test enumerates it. Anything else comes from a pack's own `LICENSES/` or from a `license-files` entry naming a file in the app's repository.

  * `NOASSERTION` is a **declaration**, not a gap. It is SPDX's spelling for "somebody looked and could not determine the licensing", and an app may write it in a `[[licensing.dists]]` or `[[licensing.third-party]]` row once it has looked. No licence text is looked up (there is none); the row is rendered distinctly, with a sentence saying licensing was not asserted and pointing at the component's own repository; and `ariza-manifest.json` counts those rows apart from the identifier set, so a gate never mistakes one for a permissive licence. It cannot be reached any other way: a distribution whose own metadata says `NOASSERTION` fails like any other missing licence, an application may not say it about itself, and `licensing.strict` refuses a bundle containing one.

  * Two sources offering **the same licence text with different bytes** warn, naming both, and the higher-priority copy ships — **the app's first, then a native pack's, then ariza's own** — so the bundle does not depend on which directory was read first. Nearest to the software wins because ariza's texts are SPDX *templates*, carrying `<year> <owner> ` where a real notice carries a name: an OFL font's text with its Reserved Font Name filled in, or a pack's own copy shipped beside its binaries, is the document that should travel. The template is the fallback for a licence nobody supplied, not a replacement for one somebody did.

What an app can declare
-----------------------

```toml
[licensing]
strict = true

[licensing.app]
# Every field defaults from the app's META6.json and its LICENSE file,
# so most apps write none of this.
copyright   = "Copyright 2026 A Person"
project-url = "https://example.org/moneymoor"

[[licensing.third-party]]
name          = "Inter"
version       = "4.0"
spdx-license  = "OFL-1.1"                  # a text ariza ships, so no
copyright     = "Copyright 2016 The Inter Project Authors"
files         = ["resources/fonts/Inter-*.ttf"]

[[licensing.third-party]]
name          = "The cover artwork"
spdx-license  = "CC-BY-4.0"                # one it does not, so name a
license-files = ["licenses/CC-BY-4.0.txt"] # path in THIS repository
files         = ["resources/art/*.png"]

[[licensing.dists]]
name         = "Some::Ancient::Module"
spdx-license = "Artistic-2.0"
notes        = "Its META6 has no license field; taken from its LICENSE."

[[licensing.dists]]
name         = "Some::Abandoned::Module"
spdx-license = "NOASSERTION"      # only after looking, and say where
project-url  = "https://github.com/someone/Some-Abandoned-Module"
notes        = "No LICENSE file, nothing in the README or on raku.land."
```

The three tables share one vocabulary — `id`, `name`, `version`, `spdx-license`, `conveyed-under`, `copyright`, `project-url`, `source`, `notes`, `license-files`, `files` — and it is deliberately the vocabulary a native pack's `third-party.json` already uses, so an app describes a bundled font in the words a pack describes FFmpeg in.

The summary, for a gate downstream
----------------------------------

`ariza-manifest.json` carries the same conclusion in machine-readable form:

```json
"licensing": {
  "rows": 41,
  "unknown": 0,
  "noassertion": 0,
  "spdx-ids": ["Apache-2.0", "Artistic-2.0", "BSD-2-Clause", "ISC",
               "LGPL-2.1", "MIT", "Unlicense", "X11"],
  "document": "THIRD-PARTY.md",
  "licenses": "LICENSES"
}
```

That is what a release pipeline can gate on without parsing prose: `unknown` above zero means something in the bundle is unattributed, `noassertion` above zero means something in it was looked at and could not be determined, and the identifier set — which never includes `NOASSERTION` — is where a copyleft component that arrived inside a native pack becomes visible to a policy that cares about one.

The document itself is **deterministic**: rows are ordered by kind, then by name, then by id, and nothing in it is a timestamp or a path from the build machine. Two builds of the same inputs produce byte-identical output, so it can be diffed across releases.

MANAGED-INSTALL UPDATE PROMPTS
==============================

An app may add this to `ariza.toml`:

```toml
[updates]
enabled = true
```

The bundle then carries a generated, core-only Raku coordinator and an exact snapshot of its platform installer. On an eligible startup the launcher asks GitHub's `releases/latest` endpoint for `installer.repo`, at most once every seven days. It accepts only a final redirect for that same repository whose tag is exactly three non-empty ASCII decimal components — `1.2.3` and `01.002.0003` are releases; `v1.2.3`, `1.2`, `1.2.3-rc1` and `1.2.3+build` are not. Components compare numerically without a machine-word limit.

The check runs only for an interactive launcher reached through the installer managed `current` pointer. A portable archive, a retained version launched directly, redirected input or output, `CI`, `--help`, `--version`, a guarded post-update relaunch, `ARIZA_NO_UPDATE_CHECK=1`, or a launch whose private challenge could not be created dispatches the application without discovery or update-state mutation.

When a newer version exists, the choices are deliberately the whole policy:

```text
1. Install & use
2. Ask next time
3. Don't ask again for this version
```

`Ask next time` keeps the candidate pending, so the next eligible launch asks again without another network request. `Don't ask again` records that exact version only; a later stable release may be offered. State is bounded and atomically replaced under the managed install's `.ariza/update-v1` directory, and a non-blocking lock makes concurrent launches dispatch rather than prompt twice.

`Install & use` invokes only the trusted installer snapshot already inside the old bundle. Its private interface derives the exact GitHub asset URL, requires the published SHA-256, rejects public `--url`, `--version` and `--insecure-no-verify` controls, and validates the extracted manifest's app, version, repository, protocol and bundle-relative paths before switching `current`. The launcher accepts success only through a per-launch 256-bit nonce and a path-free protocol record; an application's unrelated exit status 75 is returned normally. A valid handoff performs one user-requested relaunch with the original argv and sets a guard so the new process cannot check again.

Windows update-enabled bundles require the native `runner-v2` protocol. Ariza refuses to build one with runner-v1, no pinned runner, or only the `.cmd`/`.ps1` launchers. The transparent scripts delegate to the native runner in opted-in bundles, because only that process can own and authenticate the handoff without losing Windows argument fidelity.

An update-enabled release must use a bare `X.Y.Z` Git tag. The generated publish job enforces that before collecting artefacts, so a release the coordinator can never recognize is not published accidentally.

THE GENERATED INSTALLERS
========================

A bundle is self-contained, so "installing" it is unpacking it somewhere and running the launcher. The four generated scripts do exactly that, and nothing more. They are committed at the app's repository root, because `curl` has to be able to fetch them from somewhere, and what a user runs is one line:

```console
$ curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/HEAD/install.sh | sh
==> Moneymoor 0.2.0 for macos-arm64
==> downloading https://github.com/…/moneymoor-0.2.0-macos-arm64.tar.gz
ok  sha256 verified
ok  added /home/you/.local/bin to PATH in /home/you/.zshrc
ok  Moneymoor 0.2.0 installed
==> warming up -- the first launch does the work the rest never repeat
ok  ready

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

  * **Warms the install up**: runs the launcher once, with `installer.warm`'s arguments (`--version` by default), so that whatever a first launch has to do — paging a few hundred megabytes off a cold disk, creating a per-user state directory — happens here, while a line on screen says that is what is happening, rather than the first time somebody actually wants the program. Every path that reaches the parting message goes through it, including a re-run that found the version already installed.

A warm-up that fails **warns and finishes**; it never fails the install and never changes the exit code. By the time it runs, the bundle has been downloaded, checksummed and put in place, so a warm-up that fails on one machine is far likelier to be that machine — no terminal, a sandbox, an over-eager scanner — than a bad release, and refusing to finish would take a working program away from somebody who has one. The message says what failed and that the app is installed and worth trying.

  * Keeps exactly the newly installed version and the physical version that was `current` immediately before the switch, points `previous` at that exact rollback target, and prunes anything else. Windows records bounded deferred cleanup when the running bundle is still locked, and retries later without following reparse points or deleting `current`, `previous`, or the version that initiated the update.

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

  * **`XDG_CACHE_HOME`** — where the downloaded Rakudo runtime and the Windows runner are cached, under `ariza/rakudo` and `ariza/runner`. Defaults to `~/.cache`.

Set by the bundle's launcher, for the app it starts:

  * **`RAKULIB`** — `inst#<root>/rakudo/share/perl6/vendor `, the bundle's repository and the only one. `PERL6LIB` is unset.

  * **`NOTCURSES_NATIVE_DATA_DIR`** — `<root>/native `, where Notcurses::Native finds its libraries and its terminfo.

  * **`LD_LIBRARY_PATH`** — Linux only: the bundle's SQLCipher directory, prepended.

  * **`DBIISH_SQLCIPHER_LIB`** — the staged SQLCipher library, by absolute path, on the platforms that need it.

  * **`XDG_STATE_HOME`** — read, not set: where the one-line first-run marker lives. Defaults to `~/.local/state`. Windows uses `%LOCALAPPDATA%\<exec>\ ` instead, falling back to `%TEMP%`.

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

  * `App::Ariza::Runner` — the compiled Windows launcher: which artefact a platform gets, and the verification it has to pass.

  * `App::Ariza::Licensing` — what a bundle redistributes, and under what terms.

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

Sixteen files, none of which needs a network, a package manager or a built bundle: renderers are checked against byte-for-byte goldens in `t/golden/` — including the merged `THIRD-PARTY.md`, so a change to what ariza claims about Rakudo or MoarVM's vendored C libraries shows up in review as a diff — and everything that shells out takes a `:&run` seam, as does every download, so the macOS, Linux and Windows branches of each are covered from any one of them.

The Windows runner's own suite is C `ctest`, and runs anywhere:

```console
$ cmake -B build -S runner && cmake --build build
$ ctest --test-dir build --output-on-failure
```

The win32 shell is compiled out off Windows; what those tests cover is the portable core, which is where the rules that are easy to get wrong live — the argv[0] boundary, the quoting, the sidecar grammar. One of them parses `t/golden/launcher-windows-x86_64.ariza` with the real parser, so the file ariza renders and the program that reads it are checked against each other rather than against two copies of an idea.

`xt/` holds the checks that need something external — the live rakudo.org release index, a real PE binary, an end-to-end installer run against a real archive (`ARIZA_E2E_ARCHIVE`), and one that installs ariza into a throwaway repository to ask the **installed** copy where its own data files are, since `zef` stages every resource under a content-hashed name and a checkout cannot tell the difference. `xxt/` holds `linux-selfcontain-proof.sh`, which runs a whole bundle build inside a `manylinux` container, re-checks the result independently in shell, and asserts that three planted defects each make the audit fail.

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

