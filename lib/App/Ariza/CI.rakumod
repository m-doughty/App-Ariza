use Template::Jinja2;

use App::Ariza::Config;
use App::Ariza::Resources;
use App::Ariza::Tools;
use App::Ariza::Versions;

unit class App::Ariza::CI;

my constant TEMPLATE-PREFIX = 'templates/ci';

#| Where ariza installs from when an app has not said otherwise, and the
#| repository the alternative line names. Both appear in every generated
#| workflow — one as the command, the other as the comment beside it —
#| because "install ariza from the repository" is what a bootstrap needs
#| and "install ariza from fez" is what everything after it needs.
our constant ARIZA-FEZ = 'App::Ariza:ver<0.1.2+>:auth<zef:apogee>';
our constant ARIZA-REPO-URL = 'https://github.com/m-doughty/App-Ariza.git';

#| The tag shapes the generated release workflow triggers on. Two,
#| because the two tools that create release tags disagree: humans (and
#| most of GitHub) write `v0.3.0`, while mi6 — the release tool this
#| scaffold's own audience uses — tags the bare version, `0.3.0`. The
#| first real mi6 release of a scaffolded app produced a tag no
#| workflow fired on; these are GitHub Actions filter globs (not
#| regexes), so the bare shape is spelled `[0-9]*.[0-9]*.[0-9]*`.
our constant TAG-GLOBS = ('v*', '[0-9]*.[0-9]*.[0-9]*');

# One build lane per platform ariza can scaffold a job for:
#
#   template — the job's own Jinja2 template, rendered separately and
#              pasted into release.yml's `jobs:` section
#   job      — the job id, which the publish job has to name in `needs:`
#   floor    — what a user reading the release notes needs to know about
#              the machine this archive will run on, wrapped by hand
#              because it is prose in a file nothing reflows
#   smoke    — the clean-machine installer-smoke recipe for this platform,
#              in the same C<{ template, job }> shape, or absent when no
#              GitHub-hosted runner can prove this platform's installer
#              end to end yet. Independent of the build lane above it: a
#              platform ariza can bundle for is not automatically one it
#              can smoke-test the installer on.
#
# Deliberately partial, and for the same reason App::Ariza::Rakudo's
# platform map is: these are the slugs with both a GitHub-hosted runner
# and an official Rakudo build behind them. A bundle for any other slug
# is built by hand today, and its lane would be a guess.
my constant %LANES =
    'macos-arm64' => {
        template => 'lane-macos-arm64.yml.j2',
        job      => 'bundle-macos-arm64',
        floor    => ('Apple silicon, macOS 11 (Big Sur) or newer.',),
        smoke    => {
            template => 'smoke-installer-macos-arm64.yml.j2',
            job      => 'smoke-installer-macos-arm64',
        },
    },
    'linux-x86_64-glibc' => {
        template => 'lane-linux-x86_64-glibc.yml.j2',
        job      => 'bundle-linux-x86_64-glibc',
        floor    => ('x86_64, glibc 2.28 or newer: RHEL 8+, Ubuntu 18.10+,',
                     'Debian 10+. Not Alpine or any other musl distribution.'),
        smoke    => {
            template => 'smoke-installer-linux-x86_64-glibc.yml.j2',
            job      => 'smoke-installer-linux-x86_64-glibc',
        },
    },
    'windows-x86_64' => {
        template => 'lane-windows-x86_64.yml.j2',
        job      => 'bundle-windows-x86_64',
        floor    => ('x86_64, Windows 10 or newer.',),
        smoke    => {
            template => 'smoke-installer-windows-x86_64.yml.j2',
            job      => 'smoke-installer-windows-x86_64',
        },
    },
;

# The two workflows, in write order. `overwrite` is the whole difference
# between them: release.yml is derived from bundle.platforms and is
# rewritten whenever that changes, while test.yml is a starting point
# that becomes the repository's own the moment it is committed.
my constant @WORKFLOWS =
    { template => 'test.yml.j2',    output => 'test.yml',    overwrite => False },
    { template => 'release.yml.j2', output => 'release.yml', overwrite => True  },
;

#| Where the workflows go, relative to an app's repository root.
our constant WORKFLOW-DIR = '.github/workflows';

#| Every platform slug ariza can scaffold a build lane for, sorted.
method lane-slugs(--> List) { %LANES.keys.sort.List }

#| One slug's lane recipe: C<template>, C<job>, C<floor>. Dies naming the
#| set for a slug with no lane.
method lane-for(Str:D $slug --> Hash) {
    %LANES{$slug}
        // die "ariza: ariza has no CI build lane for '$slug'"
             ~ " (can scaffold: {self.lane-slugs.join(', ')}).\n"
             ~ "    Those are the platforms with both a GitHub-hosted"
             ~ " runner and an official Rakudo build behind them. A bundle"
             ~ " for '$slug' is built by hand today, and a generated job"
             ~ " for it would be a guess rather than a recipe.";
}

#| The lanes an app gets, in the order it declares them, each with its
#| C<slug> folded in.
method lanes-for(App::Ariza::Config:D $config --> List) {
    # Built into an Array first: `.map(...).List` hands back a lazy list,
    # which would defer the unknown-slug death until whatever consumed
    # it — outside whatever `try` the caller wrote, and, for a caller
    # that only counts the lanes, never at all.
    my @lanes = $config.bundle-platforms.list.map({
        %( slug => $_, |self.lane-for($_) )
    });
    @lanes.List
}

#| The workflow files ariza writes: C<{ template, output, overwrite }>,
#| in write order.
method workflows(--> List) { @WORKFLOWS }

#| ariza's own version, for the provenance line in every generated file.
#| C<'dev'> from a checkout, where there is no distribution metadata to
#| read — the same answer C<ariza version> gives.
method ariza-version(--> Str) {
    (((try { $?DISTRIBUTION.meta<version> }) // '').Str) || 'dev'
}

#| The two forms of "install ariza", as C<(command, @note-lines)>.
#| Whichever C<ci.ariza-source> selects is the command; the other is
#| rendered beside it as a comment, so switching in a hurry is an
#| uncomment rather than a remembering exercise. The note carries ariza's
#| own version too, which is the only provenance a generated file has.
method install-lines(App::Ariza::Config:D $config, Str:D :$ariza-version! --> List) {
    my $source = $config.ci-ariza-source // 'fez';
    # Angle brackets are shell syntax in both POSIX lanes and PowerShell.
    # Quote the whole identity so zef receives it as one literal argument.
    my $fez = "zef install --/test '{ARIZA-FEZ}'";
    my $git = "zef install --/test {ARIZA-REPO-URL}";

    $source eq 'fez'
        ?? ($fez, (
                "Scaffolded by ariza $ariza-version. Before App::Ariza is",
                "published, or to cut a release against an unreleased ariza,",
                "install it from the repository instead:",
                "  run: $git",
            ).List)
        !! ("zef install --/test $source", (
                "Scaffolded by ariza $ariza-version, installing ariza from the",
                "source ci.ariza-source names. The published one is:",
                "  run: $fez",
            ).List)
}

#| The Jinja2 context every CI template renders against.
#|
#| C<lane_jobs> in it is B<already rendered>: release.yml's C<jobs:>
#| section is one template per declared platform, pasted in, because a
#| macOS lane and a manylinux one have almost nothing in common but their
#| last three steps and pretending otherwise would produce a template
#| nobody can read.
method context(
    App::Ariza::Config:D :$config!,
    App::Ariza::Versions :$versions = App::Ariza::Versions.load,
    Str :$ariza-version = self.ariza-version,
    --> Hash
) {
    my @lanes = self.lanes-for($config);
    die "ariza: {$config.app-name} declares no bundle.platforms, so there"
      ~ " is nothing for a release workflow to build"
        unless @lanes;

    # A workflow that cannot say which runtime the bundle embeds is a
    # workflow whose comments are decoration. The pin is in ariza's own
    # resources, so this only fires for a hand-edited versions.toml.
    my $rakudo-tag = $versions.rakudo-tag
        // die "ariza: versions.toml has no [rakudo] pin, so a generated"
             ~ " workflow cannot name the runtime a bundle embeds";

    # The workflow compares it numerically, as the release index records
    # it, so it has to be a number before it is written into one — the
    # same complaint App::Ariza::Rakudo makes about the same pin, made
    # here rather than by python inside a container.
    my $revision = $versions.rakudo-revision;
    die "ariza: rakudo revision '$revision' is not a number, so a"
      ~ " generated workflow cannot look the runtime up in the release"
      ~ " index"
        unless $revision ~~ / ^ \d+ $ /;

    my $linux = ?@lanes.first({ .<slug> eq 'linux-x86_64-glibc' });
    die "ariza: versions.toml has no sqlcipher pin, and the"
      ~ " linux-x86_64-glibc lane builds SQLCipher from source at exactly"
      ~ " that version"
        if $linux && !$versions.sqlcipher.defined;

    # Taken by index rather than destructured: the second value is itself
    # a list, and `my ($a, @b) = ...` would slurp it into a one-element
    # array whose only element renders as a gist.
    my @install = self.install-lines($config, :$ariza-version);

    my %ctx =
        app_name    => $config.app-name,
        app_exec    => $config.app-exec,
        app_display => $config.app-display,
        repo        => $config.installer-repo // '',
        native      => $config.bundle-native.list.join(', '),

        ariza_version      => $ariza-version,
        ariza_install      => @install[0],
        ariza_install_note => @install[1].List,

        rakudo_tag        => $rakudo-tag,
        rakudo_version    => $versions.rakudo-version,
        rakudo_revision_int => $revision.Int,
        sqlcipher_version   => $versions.sqlcipher // '',

        tag_globs   => TAG-GLOBS,
        slugs       => @lanes.map(*.<slug>).List,
        job_names   => @lanes.map(*.<job>).List,
        floors      => @lanes.map({ %( slug => .<slug>, note => .<floor>.List ) }).List,
    ;

    %ctx<lane_jobs> = @lanes
        .map({ self.render(:template(.<template>), |%ctx) })
        .join("\n").chomp;

    # One clean-runner installer smoke per declared platform that has one
    # (see %LANES's `smoke` key) — each installs the archive B<just
    # published>, with the app's own committed installer, and runs the
    # result under a stripped environment. Gated on installer.repo the same
    # way the build lanes are gated on bundle.platforms: no repo, nothing
    # published, nothing to smoke.
    my @smoke-lanes    = $config.installer-repo.defined
        ?? @lanes.grep(*.<smoke>.defined)
        !! ();
    my @no-smoke-lanes = $config.installer-repo.defined
        ?? @lanes.grep({ !.<smoke>.defined })
        !! ();

    %ctx<smoke_installer>     = ?@smoke-lanes;
    %ctx<smoke_job_names>     = @smoke-lanes.map(*.<smoke><job>).List;
    %ctx<no_smoke_platforms>  = @no-smoke-lanes.map(*.<slug>).List;
    %ctx<smoke_jobs> = @smoke-lanes
        .map({ self.render(:template(.<smoke><template>), |%ctx) })
        .join("\n").chomp;

    %ctx
}

#| Render one CI template to a string. Always LF: a workflow file is read
#| by Linux runners and by git, never by cmd.exe, and every other file in
#| C<.github/> is LF whatever the machine that wrote it.
method render(Str:D :$template!, *%ctx --> Str) {
    my $out = Template::Jinja2.new
        .from-string(resource("{TEMPLATE-PREFIX}/$template").slurp)
        .render(|%ctx);
    $out ~= "\n" unless $out.ends-with("\n");
    $out.subst("\r\n", "\n", :g)
}

#| Render the workflows into C<:$out-dir>, and say what happened to each.
#|
#| Returns one C<{ path, output, action }> per workflow, where C<action>
#| is C<'wrote'> or C<'skipped'>. C<test.yml> is only written when it is
#| absent — a project's test workflow acquires things a generator cannot
#| guess at, and clobbering them would make C<scaffold-ci> a command you
#| can only run once — unless C<:force> says otherwise. C<release.yml> is
#| derived from C<bundle.platforms> and is always rewritten.
method write(
    IO() :$out-dir!,
    App::Ariza::Config:D :$config!,
    App::Ariza::Versions :$versions = App::Ariza::Versions.load,
    Str :$ariza-version = self.ariza-version,
    Bool :$force = False,
    --> List
) {
    my %ctx = self.context(:$config, :$versions, :$ariza-version);

    # Created rather than demanded, unlike App::Ariza::Installer's output
    # directory: .github/workflows is a path with one spelling, and in a
    # repository with no CI it is a directory that by definition does not
    # exist yet.
    ensure-dir($out-dir);

    my @written;
    for self.workflows -> %w {
        my $path = $out-dir.add(%w<output>);
        if $path.e && !%w<overwrite> && !$force {
            @written.push(%( :$path, output => %w<output>, action => 'skipped' ));
            next;
        }
        $path.spurt(self.render(:template(%w<template>), |%ctx));
        @written.push(%( :$path, output => %w<output>, action => 'wrote' ));
    }
    @written.List
}

=begin pod

=head1 NAME

App::Ariza::CI - the GitHub Actions workflows that build, smoke and publish an app's bundles

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::CI;
use App::Ariza::Config;

my $cfg = App::Ariza::Config.load('/path/to/App-Moneymoor'.IO);

my @done = App::Ariza::CI.write(
    :out-dir('/path/to/App-Moneymoor/.github/workflows'.IO),
    :config($cfg),
);
say @done.map({ "{.<action>} {.<output>}" });
# (skipped test.yml wrote release.yml)

# Just the text, for a diff or a test:
say App::Ariza::CI.render(
    :template<release.yml.j2>,
    |App::Ariza::CI.context(:config($cfg)),
);

# What this app's release workflow will contain:
say App::Ariza::CI.lanes-for($cfg).map(*.<job>);
# (bundle-macos-arm64 bundle-linux-x86_64-glibc bundle-windows-x86_64)

=end code

=head1 DESCRIPTION

L<App::Ariza::Bundle> builds one bundle on one machine. A release needs
one per platform, each built on that platform, each proved to run, and
all of them published together — which is a CI problem, and this is the
CI.

C<ariza scaffold-ci> writes two files into an app's
C<.github/workflows/>:

=begin code :lang<console>

test.yml      the ordinary Raku test workflow, written once
release.yml   build every declared platform, smoke each, publish on a tag

=end code

Neither is ariza's to run. They are committed to the B<app's> repository
and run by GitHub, exactly as C<install.sh> is committed and run by a
user — ariza's job is to make sure the file says the right thing about
this app.

=head2 What release.yml does

One build job per slug in the app's C<bundle.platforms>, in parallel:

=item1 B<C<bundle-macos-arm64>> — C<macos-latest>, Rakudo from
C<Raku/setup-raku>, SQLCipher from C<brew install sqlcipher>.

=item1 B<C<bundle-linux-x86_64-glibc>> — C<ubuntu-latest> inside the
C<quay.io/pypa/manylinux_2_28_x86_64> container, so the archive's glibc
floor is 2.28 rather than whatever the runner image ships this month.
Rakudo comes from the rakudo.org release index by hand (C<setup-raku>
installs into the runner's tool cache, which is not in the container's
filesystem) and SQLCipher is built from source at the pinned version.

=item1 B<C<bundle-windows-x86_64>> — C<windows-latest>, C<setup-raku>,
and SQLCipher from MSYS2's C<mingw-w64-ucrt-x86_64-sqlcipher>, installed
with the C<pacman> every windows runner already has, with
C<SQLCIPHER_LIB_DIR> pointed at the result — which is the sourcing
contract L<App::Ariza::Native> documents for Windows. The UCRT package
rather than vcpkg's port, because an MSVC-built SQLCipher imports
C<vcruntime140.dll>, which is not part of Windows and which the PE audit
therefore refuses to ship.

Each of them then runs the same three steps — C<ariza bundle>,
C<ariza smoke>, upload the archive and its C<.sha256> — because the
difference between platforms is entirely in what has to be installed
before ariza can start.

Then, on a tag only:

=item1 B<C<publish>> — collects every lane's artefact, flattens them,
recomputes a combined C<checksums.txt>, checks that against the sidecars
ariza wrote, and creates the GitHub release with a body that says what a
bundle is, which machines each archive runs on, and how to verify a
download.

=item1 B<C<smoke-installer-macos-arm64>>, B<C<smoke-installer-linux-x86_64-glibc>>,
B<C<smoke-installer-windows-x86_64>> — one per declared platform with a
clean-machine smoke recipe (C<%LANES>'s C<smoke> key), each on a plain
runner with nothing installed on it: it downloads the archive that was
B<just published>, installs it with the repository's own committed
C<install.sh> or C<install.ps1>, and runs the installed launcher under a
stripped environment (C<env -i> on POSIX; a from-scratch
C<System.Diagnostics.Process> on Windows, which has no C<env -i>). These
are the only jobs that test the artefact a user will actually receive,
through the path they will actually take — macOS's incidentally being the
only place C<install.sh>'s BSD branches (C<shasum -a 256>, bsdtar) ever
run in CI. Scaffolded only for an app with an C<installer.repo> to
publish to; a declared platform with a build lane but no smoke recipe yet
renders no job for it, and a comment in the workflow says so instead of
leaving the gap silent.

=head2 Dispatch before you tag

The workflow triggers on C<workflow_dispatch> as well as on
C<push: tags: ['v*']>, and the dispatch run stops after the build lanes:
C<publish> and every C<smoke-installer-*> job are gated on
C<startsWith(github.ref, 'refs/tags/')>.

That is the iteration loop, and it is the reason the dispatch trigger
exists. A recipe that is wrong — a package that has been renamed, a
runner image that has moved on — costs a run and a push to a branch,
rather than a burnt tag and a deleted release. The dispatch input
C<ref> takes a branch, so the lane being fixed does not have to be on
the default branch to be tried.

=head2 Which Raku is which

Every lane installs a Raku B<to run ariza with>. It is not the runtime
that ends up in the bundle: ariza downloads the pinned Rakudo
(C<[rakudo]> in C<versions.toml>) for itself, verifies it, and unpacks
that into the archive. The lane's own Rakudo can be any version at all,
which is why C<setup-raku> is pinned to C<latest> rather than to
anything.

The manylinux lane is the exception in mechanism rather than in
principle: C<setup-raku> cannot install into a container, so the lane
resolves the pin against the same rakudo.org JSON index
L<App::Ariza::Rakudo> reads and unpacks the archive itself. There is no
URL to construct — upstream filenames carry a toolchain suffix — so the
index is the only honest route.

=head2 What is regenerated, and what is yours

C<release.yml> is B<derived> from C<bundle.platforms>: add a platform to
C<ariza.toml>, re-run C<ariza scaffold-ci>, and the file gains a lane and
a C<needs:> entry. It is rewritten in place every time, so hand edits to
it are edits you will make twice.

C<test.yml> is written B<only when it is absent>. A test workflow grows
system dependencies, extra jobs and skip conditions that no generator
can infer from a manifest — this one is a starting point in the house
shape, and the moment it is committed it belongs to the repository.
C<:force> overwrites it anyway, for when the house shape has moved on
and the local edits are known to be nothing.

The generated header of each file says which of the two it is, so nobody
has to remember.

=head2 Where ariza comes from

By default the lanes run
C«zef install --/test 'App::Ariza:ver<0.1.2+>:auth<zef:apogee>'»,
with the repository URL beside it as a comment. C<ci.ariza-source> in
the app's C<ariza.toml> swaps them:

=begin code :lang<toml>

[ci]
ariza-source = "https://github.com/m-doughty/App-Ariza.git"

=end code

That is the bootstrap case — an app whose release workflow has to exist
before ariza is published — and the case where a change to ariza is
being tested against a real release before it is cut. Whichever is not
in use is rendered as a comment on the next line, along with the version
of ariza that scaffolded the file, so a reader can tell what produced it
and swap without looking anything up.

=head1 METHODS

=head2 write(:$out-dir!, :$config!, :$versions, :$ariza-version, :$force --> List)

Render the workflows and return one
C<{ path, output, action }> per file, C<action> being C<'wrote'> or
C<'skipped'>.

The output directory is B<created> if it does not exist — unlike
L<App::Ariza::Installer>'s, which refuses. C<.github/workflows> has one
spelling and, in a repository with no CI, is by definition not there
yet, so a missing one is the expected case rather than a typo.

=head2 render(:$template!, *%ctx --> Str)

One template, as text, always with LF line endings. Exposed separately
because that is what a golden-file test compares.

=head2 context(:$config!, :$versions, :$ariza-version --> Hash)

The render context: the app's names, the pins the workflows quote, the
declared lanes and their job ids, the platform floors for the release
body, and C<lane_jobs> — release.yml's whole C<jobs:> section, rendered
from one template per lane and pasted in. A macOS lane and a manylinux
one share their last three steps and nothing else, so they are separate
files rather than a template full of conditionals.

Dies when the app declares no platforms, when C<versions.toml> has no
C<[rakudo]> pin (or a revision that is not a number, which the
manylinux lane compares numerically against the release index), or when
a C<linux-x86_64-glibc> lane is wanted and there is no C<sqlcipher> pin
for it to build.

=head2 lanes-for(App::Ariza::Config $config --> List) / lane-for(Str $slug --> Hash) / lane-slugs(--> List)

The lanes an app gets in manifest order, one slug's recipe, and every
slug ariza can scaffold a lane for.

An undeclarable slug is a die rather than a skip, for the same reason
an unknown platform in C<bundle.platforms> is: silently dropping a
platform the author asked for produces a release quietly missing it.
The set is deliberately the same shape as L<App::Ariza::Rakudo>'s — a
platform with no official Rakudo build has no bundle to publish, so a
lane for it would be a guess.

=head2 workflows(--> List)

The C<{ template, output, overwrite }> entries, in write order.

=head2 install-lines(App::Ariza::Config $config, :$ariza-version! --> List)

C<(command, @note-lines)>: the C<zef install> a lane runs, and the
comment rendered beside it — which names the alternative source and the
ariza version that scaffolded the file, wrapped, because a workflow is
read as text.

=head2 ariza-version(--> Str)

ariza's own version for the provenance line, or C<'dev'> from a
checkout.

=head1 SEE ALSO

L<App::Ariza::Bundle> and L<App::Ariza::Smoke>, which are what every
build lane runs; L<App::Ariza::Installer>, whose C<install.sh> the
installer smoke job drives; L<App::Ariza::Native>, whose Windows
sourcing contract the C<pacman> step satisfies; L<App::Ariza::Rakudo>, whose
release-index lookup the manylinux lane repeats in shell.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
