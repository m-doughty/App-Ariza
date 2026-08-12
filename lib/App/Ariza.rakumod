use App::Ariza::Bundle;
use App::Ariza::CI;
use App::Ariza::Config;
use App::Ariza::Installer;
use App::Ariza::Launcher;
use App::Ariza::Native;
use App::Ariza::Platform;
use App::Ariza::Rakudo;
use App::Ariza::Resources;
use App::Ariza::Runner;
use App::Ariza::Site;
use App::Ariza::Smoke;
use App::Ariza::Tools;
use App::Ariza::Versions;

unit class App::Ariza;

# Inspect the installed App-Ariza distribution itself:
#
#   say App::Ariza.dist.meta<version>;
method dist() { $?DISTRIBUTION }

method dist-version() { $?DISTRIBUTION.meta<version> // 'dev' }

method !versions(--> App::Ariza::Versions) {
    my $versions = App::Ariza::Versions.load;
    note "ariza: $_" for $versions.warnings;
    $versions;
}

#| Human-readable byte size, for build reports. Binary units, because
#| that is what `ls -lh` and every download manager will show.
my sub human-size(Int() $bytes --> Str) {
    my @units = 'B', 'KiB', 'MiB', 'GiB';
    my $n = $bytes.Num;
    my $i = 0;
    while $n >= 1024 && $i < @units.end { $n /= 1024; $i++ }
    $i == 0 ?? "$bytes B" !! sprintf('%.1f %s', $n, @units[$i])
}

method cmd-bundle(
    App::Ariza:U:
    Str :$app!,
    Str :$platform,
    Str :$out-dir,
    Str :$sqlcipher-archive,
    --> Hash
) {
    my %b = App::Ariza::Bundle.build(
        :app-dir($app.IO),
        |($platform.defined ?? (:$platform) !! ()),
        |($out-dir.defined ?? (:out-dir($out-dir.IO)) !! ()),
        |($sqlcipher-archive.defined ?? (:sqlcipher-archive($sqlcipher-archive.IO)) !! ()),
    );

    say '';
    say "ariza: built {%b<name>}";
    say "  archive       {%b<archive>}";
    say "  compressed    {human-size(%b<compressed>)}";
    say "  uncompressed  {human-size(%b<uncompressed>)}";
    say "  sha256        {%b<sha256>}";
    for %b<launchers>.list -> $l {
        say "  launcher      {$l.relative(%b<dir>)}";
    }
    with %b<licensing><summary> -> %l {
        say "  licensing     {%l<rows>} components"
          ~ (%l<unknown> ?? ", {%l<unknown>} UNATTRIBUTED" !! '')
          ~ " ({%l<document>})";
    }
    say "  smoke it      ariza smoke --archive={%b<archive>}";
    %b
}

method cmd-installers(
    App::Ariza:U:
    Str :$app!,
    Str :$out-dir,
    Str :$branch = 'main',
    --> List
) {
    my $app-dir = $app.IO;
    my $config  = App::Ariza::Config.load($app-dir);
    note "ariza: $_" for $config.warnings;

    my @written = App::Ariza::Installer.write(
        :out-dir($out-dir.defined ?? $out-dir.IO !! $app-dir),
        :$config, :$branch);

    say "ariza: wrote $_" for @written;
    say "ariza: rendered {+@written} installer"
      ~ (+@written == 1 ?? '' !! 's') ~ " for {$config.app-display}";
    @written.List;
}

method cmd-scaffold-ci(
    App::Ariza:U:
    Str :$app!,
    Str :$out-dir,
    Bool :$force = False,
    --> List
) {
    my $app-dir = $app.IO;
    my $config  = App::Ariza::Config.load($app-dir);
    note "ariza: $_" for $config.warnings;

    my @done = App::Ariza::CI.write(
        :out-dir($out-dir.defined
            ?? $out-dir.IO
            !! $app-dir.add(App::Ariza::CI::WORKFLOW-DIR)),
        :$config,
        :versions(self!versions),
        :ariza-version(self.dist-version),
        :$force,
    );

    for @done -> %d {
        say %d<action> eq 'wrote'
            ?? "ariza: wrote {%d<path>}"
            !! "ariza: kept {%d<path>} (already there; --force to replace it)";
    }
    say "ariza: scaffolded {+@done.grep({ .<action> eq 'wrote' })} of"
      ~ " {+@done} workflows for {$config.app-display}";
    @done.List;
}

method cmd-smoke(App::Ariza:U: Str :$archive!, Bool :$keep = False --> Hash) {
    my %r = App::Ariza::Smoke.smoke(:archive($archive.IO), :$keep);

    say '';
    for %r<checks>.list -> %c {
        say sprintf('%-4s %-14s %s', %c<ok> ?? 'ok' !! 'FAIL', %c<name>, %c<detail>);
    }
    say '';
    say %r<passed>
        ?? "ariza: {+%r<checks>} checks passed"
        !! "ariza: {+%r<checks>.grep({ !.<ok> })} of {+%r<checks>} checks failed";
    %r
}

=begin pod

=head1 NAME

App::Ariza - bundler and distribution tool for Raku terminal apps

=head1 SYNOPSIS

=begin code :lang<console>

$ ariza bundle --app=../App-Moneymoor --out-dir=dist
$ ariza smoke --archive=dist/moneymoor-0.2.0-macos-arm64.tar.gz
$ ariza installers --app=../App-Moneymoor    # install.sh + three friends
$ ariza scaffold-ci --app=../App-Moneymoor   # the workflows that build all three

$ ariza version                              # ariza's own version
$ ariza help                                 # usage

=end code

=head1 DESCRIPTION

ariza packages Raku TUI applications — Cantina, Kelpie, Mindmoor,
Moneymoor — for people who do not have Raku and should not have to care
that the thing is written in it.

The end state is a B<bundle>: one archive per platform containing the
application, a Rakudo runtime, every Raku dependency, and every native
shared library the app touches (notcurses, SQLCipher, libvips), laid
out so that unpacking it anywhere and running one launcher works, with
no installer, no package manager, no PATH surgery, and nothing left
behind when the directory is deleted. Platforms are named by
L<App::Ariza::Platform>'s slugs, and what a given app needs in its
bundle is declared by that app in an C<ariza.toml>
(L<App::Ariza::Config>).

=head2 What a bundle is

C<ariza bundle> produces one directory and one archive:

=begin code :lang<console>

bin/moneymoor              the launcher, and the only thing a user runs
rakudo/                    the interpreter (plus SQLCipher, on macOS)
site/                      every Raku module, with warm bytecode
native/                    notcurses and friends
VERSION                    app version and component pins, one screen
ariza-manifest.json        the same, machine-readable, plus every sha256
THIRD-PARTY.md             every component, its licence, and where that
                           fact came from
LICENSES/                  the text of every licence the above cites

=end code

Nothing is installed, nothing is written outside the directory (bar a
one-line first-run marker under C<XDG_STATE_HOME>), and deleting the
directory is the uninstall. C<ariza smoke> then unpacks that archive
somewhere with a space in its name, runs it with a replaced environment,
and reports on each check — which is the difference between "the build
finished" and "the bundle works".

=head2 The pieces

=item1 B<L<App::Ariza::Platform>> — names the platform a bundle is for.
The slugs are Notcurses-Native's, exactly, because a bundle carries
that distribution's prebuilt libraries.

=item1 B<L<App::Ariza::Versions>> — the single pin file every artefact
is built against: the Rakudo runtime a bundle embeds, and the SQLCipher
version it expects.

=item1 B<L<App::Ariza::Config>> — the per-app C<ariza.toml> manifest,
which lives in the app's own repository so that ariza never grows a
list of special cases about specific apps.

=item1 B<L<App::Ariza::Resources>> — how all of the above find their
data files, installed or from a checkout.

=item1 B<L<App::Ariza::Tools>> — the shell-out layer. Every C<run>,
download, digest and extraction in ariza goes through it, so failures
read the same way everywhere and no other module contains a bare C<run>.

=item1 B<L<App::Ariza::Rakudo>> — fetches, caches and unpacks the
pinned runtime a bundle embeds.

=item1 B<L<App::Ariza::Site>> — installs the app and its whole closure
into the bundle's own repository, using the B<bundled> C<zef>, and warms
the precompilation store so a user's first launch is not a minute long.

=item1 B<L<App::Ariza::Native>> — stages SQLCipher, makes it
self-contained, and audits every native binary in the bundle for
anything that would load from outside it.

=item1 B<L<App::Ariza::Launcher>> — writes the one script a user runs.

=item1 B<L<App::Ariza::Runner>> — the compiled launcher a Windows
bundle starts from: which artefact a platform gets, where it is
published, and the digest it has to match before it goes anywhere near a
bundle.

=item1 B<L<App::Ariza::Licensing>> — reads a finished bundle and says
what it redistributes: every native pack's own licensing kit, ariza's
maintained record of the vendored runtime, every installed
distribution's C<license>, and the app's own declarations, merged into
C<THIRD-PARTY.md> and C<LICENSES/>.

=item1 B<L<App::Ariza::Installer>> — writes the four scripts that put a
bundle on someone's machine, and take it off again.

=item1 B<L<App::Ariza::CI>> — the GitHub Actions workflows that run all
of the above once per platform, on machines that are actually those
platforms, and publish the result.

=item1 B<L<App::Ariza::Bundle>> — the orchestrator, and the author of
C<VERSION> and C<ariza-manifest.json>.

=item1 B<L<App::Ariza::Smoke>> — unpacks a finished archive somewhere
new, with a replaced environment, and checks it.

=head1 COMMAND METHODS

Every C<ariza> CLI verb is a class method here, so the whole tool is
scriptable from Raku. The methods do the wiring and the reporting; the
work lives in the modules.

=head2 cmd-bundle(:$app!, :$platform, :$out-dir, :$sqlcipher-archive --> Hash)

Build a bundle and report it: archive path, compressed and uncompressed
size, SHA-256, launcher, and the C<ariza smoke> line to check it with.
Returns L<App::Ariza::Bundle>'s result hash.

C<:$platform> defaults to this machine's slug. C<:$sqlcipher-archive>
stages SQLCipher from a local archive instead of from the build
machine's package manager, which is what a cross-build (a Linux bundle
needs a Linux library) or an air-gapped build needs.

=head2 cmd-installers(:$app!, :$out-dir, :$branch --> List)

Render the end-user C<install.sh>, C<install.ps1>, C<uninstall.sh> and
C<uninstall.ps1> from the app's C<ariza.toml>, print what was written,
and return the paths. C<:out-dir> defaults to the app's own repository
root — these are committed artefacts, because C<curl … | sh> has to be
able to fetch them from somewhere. C<:branch> is the branch that
one-liner names (C<main>).

=head2 cmd-scaffold-ci(:$app!, :$out-dir, :$force --> List)

Render the app's C<.github/workflows/test.yml> and C<release.yml> from
its C<ariza.toml>, print what happened to each, and return one
C<{ path, output, action }> per file.

C<release.yml> is derived from C<bundle.platforms> and is rewritten
every time; C<test.yml> is written only when it is absent, because a
test workflow acquires things a generator cannot infer. C<:force>
overwrites both. C<:out-dir> writes somewhere other than the app's own
C<.github/workflows>, which is otherwise created if it does not exist.

=head2 cmd-smoke(:$archive!, :$keep --> Hash)

Unpack an archive somewhere new and check it, printing one line per
check. Returns L<App::Ariza::Smoke>'s result hash; the CLI exits
non-zero when C<passed> is false, so it drops straight into CI.

=head2 dist() / dist-version()

The C<$?DISTRIBUTION> object for App-Ariza itself, and its version
string (C<'dev'> if the metadata has none).

=head1 SEE ALSO

L<App::Ariza::Bundle>, L<App::Ariza::Smoke>, L<App::Ariza::Rakudo>,
L<App::Ariza::Site>, L<App::Ariza::Native>, L<App::Ariza::Launcher>,
L<App::Ariza::Runner>, L<App::Ariza::Installer>, L<App::Ariza::CI>,
L<App::Ariza::Platform>, L<App::Ariza::Versions>,
L<App::Ariza::Config>, L<App::Ariza::Resources>,
L<App::Ariza::Tools>

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
