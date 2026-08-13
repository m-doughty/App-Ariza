use Template::Jinja2;

use App::Ariza::Config;
use App::Ariza::Resources;
use App::Ariza::Runner;
use App::Ariza::Site;
use App::Ariza::Tools;

unit class App::Ariza::Launcher;

my constant TEMPLATE-PREFIX = 'templates';

# slug family -> the files a bundle for it gets rendered into `bin/`.
# `suffix` is appended to the app's exec name; `mode` is the POSIX
# permission bits (ignored where the filesystem has no concept of them).
#
# The Windows family renders three: the two scripts, and the `.ariza`
# sidecar that the compiled launcher (App::Ariza::Runner) reads for the
# handful of facts that are per-bundle rather than per-runner. The
# sidecar is rendered whether or not a runner is pinned — it costs a few
# hundred bytes, and a bundle whose configuration is present but whose
# executable is not is a much easier thing to reason about than the
# reverse.
my constant %SCRIPTS =
    macos => (
        { template => 'launcher-posix.sh.j2',      suffix => '',       mode => 0o755 },
    ),
    linux => (
        { template => 'launcher-posix.sh.j2',      suffix => '',       mode => 0o755 },
    ),
    windows => (
        { template => 'launcher-windows.ps1.j2',   suffix => '.ps1',   mode => 0o644 },
        { template => 'launcher-windows.cmd.j2',   suffix => '.cmd',   mode => 0o644 },
        { template => 'launcher-windows.ariza.j2', suffix => '.ariza', mode => 0o644 },
    ),
;

#| The launcher files a slug's bundle gets rendered: C<template>,
#| C<suffix> and C<mode>, in write order.
method scripts-for(Str:D $slug --> List) {
    my $family = $slug.split('-').head;
    (%SCRIPTS{$family}
        // die "ariza: no launcher template for platform '$slug'").List
}

#| The Jinja2 context a launcher template renders against.
#|
#| Every path in it is B<relative to the bundle root>, never absolute:
#| the launcher works out its own root at run time, and an absolute path
#| baked in at build time is precisely the thing that makes an archive
#| unmovable.
#|
#| C<:$site> is the module repository C<RAKULIB> is pointed at, and it
#| defaults to L<App::Ariza::Site>'s answer rather than to a literal:
#| a launcher that names a different directory than the one the bundle
#| was installed into is a bundle that finds no modules at all.
method context(
    App::Ariza::Config:D :$config!,
    Str:D :$slug!,
    Str:D :$target!,
    Str:D :$site = App::Ariza::Site.site-rel('.'),
    Str :$app-version = '',
    Str :$sqlcipher-rel,
    --> Hash
) {
    my $family = $slug.split('-').head;
    my $sql-dir = $sqlcipher-rel.defined
        ?? $sqlcipher-rel.subst(/ '/' <-[/]>+ $ /, '')
        !! Str;
    (
        app_exec    => $config.app-exec,
        app_display => $config.app-display,
        app_name    => $config.app-name,
        app_version => $app-version,
        updates_enabled => $config.updates-enabled,
        platform    => $slug,
        os          => $family,
        target      => $target,
        target_win  => $target.subst('/', '\\', :g),
        site        => $site,
        site_win    => $site.subst('/', '\\', :g),
        sqlcipher   => $sqlcipher-rel.defined,
        sqlcipher_lib     => $sqlcipher-rel // '',
        sqlcipher_dir     => $sql-dir // '',
        sqlcipher_lib_win => ($sqlcipher-rel // '').subst('/', '\\', :g),
        sqlcipher_dir_win => ($sql-dir // '').subst('/', '\\', :g),
    ).Hash
}

#| Render one launcher template to a string. Line endings are normalised
#| per family — LF for the POSIX script, CRLF for the Windows ones, since
#| C<cmd.exe> mis-parses an LF-only batch file.
method render(Str:D :$template!, *%ctx --> Str) {
    my $source = resource("{TEMPLATE-PREFIX}/$template").slurp;
    my $out = Template::Jinja2.new.from-string($source).render(|%ctx);
    $out ~= "\n" unless $out.ends-with("\n");
    $template.contains('windows')
        ?? $out.subst("\r\n", "\n", :g).subst("\n", "\r\n", :g)
        !! $out
}

#| Write every launcher a slug's bundle needs into C<< <bundle>/bin >>,
#| stage the compiled Windows runner beside them, and return
#| C<{ written, runner }>: every path written, and what the runner step
#| staged (an empty hash where it staged nothing).
#|
#| The runner detail is carried out rather than dropped because the
#| manifest records every downloaded component with its URL and digest,
#| and this is the only place in a build that knows them.
#|
#| C<:&stage-runner> is the seam L<App::Ariza::Runner> is reached
#| through, so a test can render a bundle's launchers without a network
#| — and so the one platform that fetches anything here is as testable
#| as the three that do not.
method write(
    IO() :$bundle-dir!,
    App::Ariza::Config:D :$config!,
    Str:D :$slug!,
    Str:D :$target!,
    Str:D :$site = App::Ariza::Site.site-rel($bundle-dir),
    Str :$app-version = '',
    Str :$sqlcipher-rel,
    :&stage-runner = -> |c { App::Ariza::Runner.stage(|c) },
    --> Hash
) {
    my %ctx = self.context(:$config, :$slug, :$target, :$site, :$app-version,
                           :$sqlcipher-rel);
    my $bin = ensure-dir($bundle-dir.add('bin'));

    my @written;
    for self.scripts-for($slug) -> %s {
        my $path = $bin.add($config.app-exec ~ %s<suffix>);
        $path.spurt(self.render(:template(%s<template>), |%ctx));
        $path.chmod(%s<mode>);
        @written.push($path);
    }

    # Empty for every non-Windows platform, and for a Windows one built
    # before the first runner release was pinned. Both are ordinary
    # outcomes rather than failures, and both leave a bundle whose
    # scripts do the whole job.
    my %runner = stage-runner(:$bundle-dir, :$slug, :exec($config.app-exec));
    die "ariza: update-enabled Windows bundles require updater-capable runner-v2+"
      ~ " for '$slug'; refusing to ship script launchers that cannot"
      ~ " authenticate an update handoff"
        if $config.updates-enabled
        && $slug.starts-with('windows-')
        && (!%runner<path>.defined
            || !App::Ariza::Runner.update-handoff-capable(%runner<tag>));
    @written.push(%runner<path>) if %runner<path>.defined;

    %( written => @written.List, runner => %runner )
}

=begin pod

=head1 NAME

App::Ariza::Launcher - the one script a user runs

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Launcher;

my %w = App::Ariza::Launcher.write(
    :bundle-dir($work),
    :config($cfg),
    :slug<macos-arm64>,
    :target<rakudo/share/perl6/vendor/bin/moneymoor.raku>,
    :site<rakudo/share/perl6/vendor>,
    :app-version<0.2.0>,
    :sqlcipher-rel<rakudo/lib/libsqlcipher.0.dylib>,
);
say %w<written>;            # (…/bin/moneymoor)
say %w<runner>;             # {} — macOS stages no executable

# Just the text, for a diff or a test:
say App::Ariza::Launcher.render(
    :template<launcher-posix.sh.j2>,
    |App::Ariza::Launcher.context(:$cfg, :slug<linux-x86_64-glibc>,
                                  :target<rakudo/share/perl6/vendor/bin/moneymoor.raku>),
);

=end code

=head1 DESCRIPTION

Everything else in a bundle is inert until something sets three or four
environment variables and starts the right interpreter on the right
script. This module writes the thing that does that — the only file in
the bundle a user is ever expected to touch.

=head2 What the launcher does

=item1 Resolves its B<own> physical path, following symlinks, and takes
the directory above it as the bundle root.

=item1 Refuses, with a readable message, if the interpreter is not where
it should be — the signature of a half-unpacked archive.

=item1 Exports C<RAKULIB=inst#E<lt>rootE<gt>/rakudo/share/perl6/vendor>
and unsets C<PERL6LIB>, so the bundle's repository is the I<only> one. A
C<RAKULIB> left in the user's environment would otherwise put modules
compiled against a different Rakudo ahead of the bundle's. That path is
the bundled runtime's own C<vendor> prefix, and not a directory of
ariza's choosing, because it is the only kind Rakudo has a I<name> for —
see L<App::Ariza::Site> for what a nameless one costs the user.

=item1 Exports C<NOTCURSES_NATIVE_DATA_DIR=E<lt>rootE<gt>/native>, which
is both where L<App::Ariza::Site> staged the notcurses libraries and
where Notcurses::Native looks for them — and, crucially, is B<not>
C<NOTCURSES_NATIVE_LIB_DIR>, which suppresses that module's own
C<TERMINFO_DIRS> setup and leaves a TUI without terminfo.

=item1 On Linux, additionally puts the bundle's SQLCipher directory on
C<LD_LIBRARY_PATH> and points C<DBIISH_SQLCIPHER_LIB> at the library.
macOS needs neither: the library is staged inside C<rakudo/lib>, which
the bundled interpreter's own C<LC_RPATH> already covers.

=item1 Prints a one-line first-run notice to C<STDERR>, once, guarded by
a C<.first-run> sentinel under
C<${XDG_STATE_HOME:-$HOME/.local/state}/E<lt>execE<gt>/>. Nothing is
written into the bundle itself, so a read-only or shared bundle behaves
the same as a private one.

=item1 B<Warns> — never refuses — when C<TERM> is empty, C<dumb> or
C<unknown>. A launcher that second-guesses the user's terminal is worse
than one that mentions it.

=item1 C<exec>s the bundled C<raku> on the app's installed script,
passing every argument through.

=head2 Why not `readlink -f`

C<readlink -f> is a GNU extension. It is absent on macOS before Monterey
and on the BSDs, and a launcher that resolves symlinks only on Linux is
one that breaks the first time someone puts a link to it in C<~/bin> —
which is the single most likely thing a user will do with a bundle. The
POSIX template loops over plain C<readlink> instead.

=head2 Spaces

Every expansion in the script is quoted, every path is built from
C<$BUNDLE_ROOT> rather than assumed, and nothing is passed through
C<eval>. A bundle unpacked into C</Users/someone/My Applications/> works,
and the test suite unpacks into a directory with spaces in the name
specifically to keep it that way.

=head2 Windows

A Windows bundle gets four files in C<bin/>, and only one of them is the
documented entry point.

=item1 C<< <exec>.exe >> — the compiled launcher, staged by
L<App::Ariza::Runner> from a pinned, digest-verified release artefact.
This is what users run and what the installers put on C<PATH>. It does
the whole launch with no C<cmd.exe> anywhere in it, which is what keeps
C<^>, C<%VAR%>, C<!x!> and quote-heavy arguments intact on the way to
the app — a batch file re-parses C<%*> and cannot not damage them — and
what keeps the bundle usable where script-execution policy (AppLocker,
SRP, a locked-down C<ExecutionPolicy>) refuses to run a C<.cmd> or a
C<.ps1> at all.

=item1 C<< <exec>.ariza >> — the runner's sidecar. Rendered like any
other launcher, from the same context, and readable by anyone who wants
to know what the executable is about to do. It carries the target
script, the exec and display names, and then the bundle's environment as
B<ordered directives>:

=begin code :lang<text>

target rakudo\share\perl6\vendor\bin\moneymoor.raku
app-exec moneymoor
app-display Moneymoor
set RAKULIB=inst#{root}\rakudo\share\perl6\vendor
unset PERL6LIB
set NOTCURSES_NATIVE_DATA_DIR={root}\native
prepend-path {root}\native\sqlcipher
set DBIISH_SQLCIPHER_LIB={root}\native\sqlcipher\sqlcipher.dll

=end code

C<{root}> is the bundle root the executable works out at run time, so
nothing absolute is baked in. C<set>, C<unset> and C<prepend-path> are
applied top to bottom, and the runner knows nothing whatever about what
the variables mean — which is the point. Everything ariza knows about
Rakudo's repository, notcurses' data directory and where a bundled DLL
lives is B<here>, in the renderer, exactly as it is in the C<.cmd>
template. A bundle that grows a native dependency grows a line in this
file; it does not need a new executable, and an executable pinned
several releases ago still launches it.

=item1 C<< <exec>.cmd >> and C<< <exec>.ps1 >> — still written and still
supported as transparent launchers. In an update-disabled bundle they carry
the complete script implementation and are the bootstrap fallback before a
runner is pinned. In an update-enabled Windows bundle they delegate to the
required runner-v2 executable, because that process owns the authenticated
handoff and the original argument tail.

C<$PSScriptRoot> and C<%~dp0> already give a resolved directory, so
neither script needs the POSIX symlink loop; the executable asks Windows
where it is with C<GetModuleFileNameW> and takes the directory above
C<bin/>, which is the same rule spelled a third way.

Windows output is CRLF, sidecar included; C<cmd.exe> mis-parses an
LF-only batch file in ways that look nothing like a line-ending problem,
and having one file in C<bin/> disagree with the others about line
endings is a difference nobody should have to think about.

=head1 METHODS

=head2 write(:$bundle-dir!, :$config!, :$slug!, :$target!, :$app-version, :$sqlcipher-rel, :&stage-runner --> Hash)

Render and write every launcher the slug needs into
C<< <bundle>/bin >>, C<chmod 0755> for the POSIX one, stage the compiled
runner where there is one, and return C<{ written, runner }> — every
path written, and L<App::Ariza::Runner>'s account of what it staged
(C<path>, C<artifact>, C<tag>, C<url>, C<sha256>), which is what
C<ariza-manifest.json> records so the executable in a bundle can be
traced back to a published, digest-verified artefact.

C<:&stage-runner> replaces the call into L<App::Ariza::Runner> — the one
thing here that touches the network — so a test can render a Windows
bundle's C<bin/> without one. It is expected to return that same hash,
or an empty one for a bundle that gets no executable: every non-Windows
platform, and a Windows platform built while
C<resources/runner-checksums.txt> is still empty.

C<:$target> is the bundle-relative script the launcher hands to the
interpreter — L<App::Ariza::Site>'s C<target-rel>. C<:$sqlcipher-rel> is
the bundle-relative library path; omitting it renders a launcher with no
SQLCipher wiring at all, which is what an app that does not use it
should get.

=head2 render(:$template!, *%ctx --> Str)

One template, as text. Exposed separately because that is what a
golden-file test compares, and a launcher is a thing worth diffing
rather than merely running.

=head2 context(:$config!, :$slug!, :$target!, :$app-version, :$sqlcipher-rel --> Hash)

The render context. Every path in it is relative to the bundle root:
absolute paths baked in at build time are exactly what makes an archive
unmovable.

=head2 scripts-for(Str $slug --> List)

The C<{ template, suffix, mode }> entries a slug's bundle gets rendered,
in write order. Windows has three — C<.ps1>, C<.cmd> and the runner's
C<.ariza> sidecar; the C<.exe> is not in this list because it is fetched
rather than rendered.

=head1 SEE ALSO

L<App::Ariza::Runner>, which supplies the compiled Windows launcher this
module stages and writes the sidecar for.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
