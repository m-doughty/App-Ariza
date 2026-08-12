use Template::Jinja2;

use App::Ariza::Config;
use App::Ariza::Resources;
use App::Ariza::Tools;

unit class App::Ariza::Launcher;

my constant TEMPLATE-PREFIX = 'templates';

# slug family -> the scripts a bundle for it gets. `suffix` is appended
# to the app's exec name; `mode` is the POSIX permission bits (ignored
# where the filesystem has no concept of them).
my constant %SCRIPTS =
    macos => (
        { template => 'launcher-posix.sh.j2',      suffix => '',     mode => 0o755 },
    ),
    linux => (
        { template => 'launcher-posix.sh.j2',      suffix => '',     mode => 0o755 },
    ),
    windows => (
        { template => 'launcher-windows.ps1.j2',   suffix => '.ps1', mode => 0o644 },
        { template => 'launcher-windows.cmd.j2',   suffix => '.cmd', mode => 0o644 },
    ),
;

#| The launcher scripts a slug's bundle gets: C<template>, C<suffix> and
#| C<mode>, in write order.
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
method context(
    App::Ariza::Config:D :$config!,
    Str:D :$slug!,
    Str:D :$target!,
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
        platform    => $slug,
        os          => $family,
        target      => $target,
        target_win  => $target.subst('/', '\\', :g),
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
#| and return the paths written.
method write(
    IO() :$bundle-dir!,
    App::Ariza::Config:D :$config!,
    Str:D :$slug!,
    Str:D :$target!,
    Str :$app-version = '',
    Str :$sqlcipher-rel,
    --> List
) {
    my %ctx = self.context(:$config, :$slug, :$target, :$app-version,
                           :$sqlcipher-rel);
    my $bin = ensure-dir($bundle-dir.add('bin'));

    my @written;
    for self.scripts-for($slug) -> %s {
        my $path = $bin.add($config.app-exec ~ %s<suffix>);
        $path.spurt(self.render(:template(%s<template>), |%ctx));
        $path.chmod(%s<mode>);
        @written.push($path);
    }
    @written.List
}

=begin pod

=head1 NAME

App::Ariza::Launcher - the one script a user runs

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Launcher;

my @written = App::Ariza::Launcher.write(
    :bundle-dir($work),
    :config($cfg),
    :slug<macos-arm64>,
    :target<site/bin/moneymoor.raku>,
    :app-version<0.2.0>,
    :sqlcipher-rel<rakudo/lib/libsqlcipher.0.dylib>,
);
say @written;               # (…/bin/moneymoor)

# Just the text, for a diff or a test:
say App::Ariza::Launcher.render(
    :template<launcher-posix.sh.j2>,
    |App::Ariza::Launcher.context(:$cfg, :slug<linux-x86_64-glibc>,
                                  :target<site/bin/moneymoor.raku>),
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

=item1 Exports C<RAKULIB=inst#E<lt>rootE<gt>/site> and unsets
C<PERL6LIB>, so the bundle's repository is the I<only> one. A C<RAKULIB>
left in the user's environment would otherwise put modules compiled
against a different Rakudo ahead of the bundle's.

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

The C<.ps1> and C<.cmd> twins are written from the same context and are
shipped for slugs in the C<windows> family. C<$PSScriptRoot> and C<%~dp0>
already give a resolved directory, so neither needs the symlink loop.

Windows output is CRLF; C<cmd.exe> mis-parses an LF-only batch file, in
ways that look nothing like a line-ending problem.

=head1 METHODS

=head2 write(:$bundle-dir!, :$config!, :$slug!, :$target!, :$app-version, :$sqlcipher-rel --> List)

Render and write every launcher the slug needs into
C<< <bundle>/bin >>, C<chmod 0755> for the POSIX one, and return the
paths.

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

The C<{ template, suffix, mode }> entries a slug's bundle gets, in write
order.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
