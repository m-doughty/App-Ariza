use Template::Jinja2;

use App::Ariza::Config;
use App::Ariza::Resources;
use App::Ariza::Tools;

unit class App::Ariza::Installer;

my constant TEMPLATE-PREFIX = 'templates';

# The four scripts an app publishes beside its releases, in write order.
# `family` is the platform family whose declared slugs the script serves:
# an app that ships no Windows bundle has no business shipping an
# install.ps1 that can only ever say "nothing for your machine".
my constant @SCRIPTS =
    { template => 'install-posix.sh.j2',      output => 'install.sh',
      family => 'posix',   mode => 0o755, crlf => False },
    { template => 'install-windows.ps1.j2',   output => 'install.ps1',
      family => 'windows', mode => 0o644, crlf => True  },
    { template => 'uninstall-posix.sh.j2',    output => 'uninstall.sh',
      family => 'posix',   mode => 0o755, crlf => False },
    { template => 'uninstall-windows.ps1.j2', output => 'uninstall.ps1',
      family => 'windows', mode => 0o644, crlf => True  },
;

#| The platform family a slug belongs to for installer purposes:
#| C<windows>, or C<posix> for everything else. Coarser than
#| L<App::Ariza::Launcher>'s split, because macOS and Linux share one
#| installer — the difference between them is a runtime C<uname> away,
#| and a user should not have to know which file to download.
method family-of(Str:D $slug --> Str) {
    $slug.starts-with('windows') ?? 'windows' !! 'posix'
}

#| The declared platform slugs in one family, in manifest order.
method slugs-for(App::Ariza::Config:D $config, Str:D $family --> List) {
    $config.bundle-platforms.list.grep({ self.family-of($_) eq $family }).List
}

#| The scripts this app gets: the C<{ template, output, family, mode,
#| crlf }> entries whose family it declares at least one platform for.
method scripts-for(App::Ariza::Config:D $config --> List) {
    @SCRIPTS.grep({ self.slugs-for($config, .<family>).elems }).List
}

#| The environment variable that overrides where a generated installer
#| fetches from: the executable name, uppercased, with anything that is
#| not a word character replaced by C<_>, plus C<_BUNDLE_URL>.
method env-url(App::Ariza::Config:D $config --> Str) {
    $config.app-exec.uc.subst(/<-[A..Z0..9]>/, '_', :g) ~ '_BUNDLE_URL'
}

#| One word, quoted for a POSIX shell: single quotes, with any single
#| quote in the word spliced out and back in as C<'\''>.
#|
#| The warm-up arguments come out of the app's C<ariza.toml> and are
#| written into a generated script as a command line, which is the one
#| place in these templates where somebody else's string becomes shell
#| syntax. Quoting it here rather than trusting it there means an
#| argument containing a space, a C<$> or a quote is an argument rather
#| than an injection.
method sh-quote(Str:D $word --> Str) {
    "'" ~ $word.subst("'", "'\\''", :g) ~ "'"
}

#| The same for PowerShell, where a single quote is escaped by doubling
#| it and nothing inside single quotes is expanded.
method ps-quote(Str:D $word --> Str) {
    "'" ~ $word.subst("'", "''", :g) ~ "'"
}

#| The Jinja2 context an installer template renders against.
#|
#| C<:$branch> is the git ref the C<curl | sh> one-liner reads the
#| scripts from. It defaults to C<HEAD>, which raw.githubusercontent
#| resolves to the repository's default branch whatever that branch is
#| called — a hardcoded name is a 404 for every repository that chose
#| the other convention (raw URLs do not redirect; the first real
#| install attempt against a C<master>-defaulted repo proved it), and
#| the printed uninstall hint carries the same URL, so a wrong ref here
#| is a broken instruction in the user's terminal, not a cosmetic slip.
method context(
    App::Ariza::Config:D :$config!,
    Str :$branch = 'HEAD',
    --> Hash
) {
    my $repo = $config.installer-repo
        // die "ariza: {$config.app-name} has no installer.repo in its"
             ~ " ariza.toml, and an installer with no repository to"
             ~ " download from is not worth generating";

    my @posix   = self.slugs-for($config, 'posix');
    my @windows = self.slugs-for($config, 'windows');
    my $env-url = self.env-url($config);
    my @warm    = $config.warm-argv;

    (
        # The warm-up: whether there is one, the argument list in each
        # shell's own quoting, and the same thing as one flat string for
        # the message that names what was run. `warm_display` is quoted
        # too — it is interpolated into a shell word, and an argument
        # with a quote in it would otherwise end the string early.
        warm         => ?@warm,
        warm_args    => @warm.map({ self.sh-quote($_) }).join(' '),
        warm_args_ps => @warm.map({ self.ps-quote($_) }).join(', '),
        warm_display    => self.sh-quote(@warm.join(' ')),
        warm_display_ps => self.ps-quote(@warm.join(' ')),
        app_exec    => $config.app-exec,
        app_display => $config.app-display,
        app_name    => $config.app-name,
        repo        => $repo,
        raw_base    => "https://raw.githubusercontent.com/$repo/$branch",
        slugs       => @posix.join(' '),
        # `@('a', 'b')` element list, already quoted: PowerShell has no
        # word-splitting, so the array has to be written out.
        slugs_ps    => @windows.map({ "'$_'" }).join(', '),
        env_url     => $env-url,
        # The whole expansion, not just the name: `${` immediately
        # followed by a Jinja2 `{{` is ambiguous to the template parser,
        # and the shell has no way to spell "expand the variable this
        # other variable names" without `eval`.
        env_url_expr => "\"\$\{$env-url:-\}\"",
        lib_posix   => resource("{TEMPLATE-PREFIX}/installer-common-posix.sh").slurp,
        lib_windows => resource("{TEMPLATE-PREFIX}/installer-common-windows.ps1").slurp,
    ).Hash
}

#| Render one installer template to a string. Line endings are normalised
#| per family — LF for the POSIX scripts, CRLF for the PowerShell ones,
#| which is what every other file in a Windows repository looks like and
#| what a here-string in a `.ps1` expects.
method render(Str:D :$template!, *%ctx --> Str) {
    my $out = Template::Jinja2.new
        .from-string(resource("{TEMPLATE-PREFIX}/$template").slurp)
        .render(|%ctx);
    $out ~= "\n" unless $out.ends-with("\n");
    $template.contains('windows')
        ?? $out.subst("\r\n", "\n", :g).subst("\n", "\r\n", :g)
        !! $out
}

#| Render every installer this app gets into C<:$out-dir>, and return the
#| paths written.
method write(
    IO() :$out-dir!,
    App::Ariza::Config:D :$config!,
    Str :$branch = 'HEAD',
    --> List
) {
    die "ariza: {$config.app-name} declares no bundle.platforms, so there"
      ~ " is nothing for an installer to detect or download"
        unless $config.bundle-platforms.list;

    # Deliberately not created for you: the default target is the app's
    # own repository, and silently creating one would turn a typo into a
    # successful render nobody can find.
    die "ariza: output directory does not exist: $out-dir" unless $out-dir.d;

    my %ctx = self.context(:$config, :$branch);

    my @written;
    for self.scripts-for($config) -> %s {
        my $path = $out-dir.add(%s<output>);
        $path.spurt(self.render(:template(%s<template>), |%ctx));
        $path.chmod(%s<mode>);
        @written.push($path);
    }
    @written.List
}

=begin pod

=head1 NAME

App::Ariza::Installer - the four scripts a user actually runs

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Config;
use App::Ariza::Installer;

my $cfg = App::Ariza::Config.load('/path/to/App-Moneymoor'.IO);

my @written = App::Ariza::Installer.write(:out-dir($repo), :config($cfg));
say @written;   # (…/install.sh …/install.ps1 …/uninstall.sh …/uninstall.ps1)

# Just the text, for a diff or a test:
say App::Ariza::Installer.render(
    :template<install-posix.sh.j2>,
    |App::Ariza::Installer.context(:config($cfg)),
);

=end code

=head1 DESCRIPTION

L<App::Ariza::Bundle> produces an archive; this produces the thing that
puts one on someone's machine. Four files, committed at the app's
repository root beside the launcher-less bundles they install:

=begin code :lang<console>

install.sh      macOS and Linux, curl-pipeable and runnable as a file
install.ps1     Windows
uninstall.sh
uninstall.ps1

=end code

=begin code :lang<console>

$ curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/HEAD/install.sh | sh
==> Moneymoor 0.2.0 for macos-arm64
==> downloading https://github.com/…/moneymoor-0.2.0-macos-arm64.tar.gz
ok  sha256 verified
ok  added /home/you/.local/bin to PATH in /home/you/.zshrc
ok  Moneymoor 0.2.0 installed

    run it:        moneymoor
    installed in:  /home/you/.local/share/moneymoor/versions/0.2.0
    uninstall:     curl -fsSL https://raw.githubusercontent.com/…/uninstall.sh | sh

=end code

=head2 One POSIX script, not two

The installer scripts that came before a bundle shipped
C<install-macos.sh> and C<install-linux.sh> separately, because they did
genuinely different things: one drove Homebrew, the other drove five
package managers.

A bundle installer does none of that. The only per-platform decision
left is B<which asset to download>, which is a C<uname> call away at run
time — so there is one script, it detects, and a user copying a
C<curl … | sh> line off a README does not have to know which of two
files applies to them.

=head2 What it does, and does not do

=item1 Downloads a prebuilt bundle and B<verifies its SHA-256> against
the C<.sha256> asset published beside it. No digest, no install.

=item1 Unpacks into
C<< $XDG_DATA_HOME/<exec>/versions/<version>/ >>, beside whatever is
already there, then flips a C<current> symlink and links
C<< ~/.local/bin/<exec> >> at it. A failed or interrupted download
cannot damage a working install, because nothing that exists is touched
until the new tree is complete.

=item1 Puts C<~/.local/bin> on C<PATH> B<only if it is not there
already>, through one marked block appended to each shell rc file that
exists. Re-running never duplicates it; the uninstaller removes exactly
that block and nothing else.

=item1 Keeps B<one> previous version, so a bad release can be rolled
back to by hand, and prunes anything older, saying which.

=item1 Needs no root, no compiler, no package manager and no Raku.

It does not create desktop entries, register file associations, install
a terminal emulator, or write to any shared location. A bundle needs
none of it, and the shared registry the older installer scripts kept
existed only to refcount things this one never installs.

=head2 Re-running is a repair

Asking for a version that is already installed does not re-download it.
The existing tree is checked, the C<current> symlink and the
C<~/.local/bin> link are re-pointed, the PATH block is re-checked, and
the script exits 0 saying "already installed". That makes "run the
installer again" the correct advice for the most common breakage — a
link someone deleted or a shell that never picked up C<PATH>.

An existing version directory with no runnable launcher in it is not a
version, and is replaced rather than trusted.

=head2 The escape hatch

C<--url> (and the C<< <EXEC>_BUNDLE_URL >> environment variable, e.g.
C<MONEYMOOR_BUNDLE_URL>) installs from a source the user names, and
bypasses GitHub entirely. It accepts a B<plain file path> as readily as
a URL, which is what makes an air-gapped install, a release candidate,
and this distribution's own end-to-end test possible without a network
or a published release.

C<--insecure-no-verify> applies to that path B<only>. A source someone
named themselves may legitimately have no C<.sha256> beside it, and the
script says so loudly before continuing. A published release always
has one, so a missing digest there means a tampered or half-uploaded
release and stays fatal however many flags are passed.

=head2 Version resolution without a JSON parser

The default is "latest", read from the C<location:> header of
C<<https://github.com/<repo>/releases/latest>> — one HEAD request,
no API token, no C<jq> on a machine that may have neither. C<--version>
names a tag instead.

For an explicit C<--url>, the version comes from the archive's own name.
That parse strips a B<known slug> off the end rather than splitting on
dashes, because C<moneymoor-1.0-rc1-macos-arm64> has to mean version
C<1.0-rc1> and not C<1.0>. If the name does not parse, the unpacked
bundle's own directory name is tried, and only then does it give up.

=head2 Unknown platforms say so

Detection produces one of the slugs the app B<declares> in
C<bundle.platforms> or nothing at all. There is no nearest match: a
glibc bundle does not run on Alpine and an arm64 one does not run on an
Intel Mac, so a wrong guess is a download followed by an exec format
error. What a user gets instead names their machine and points at the
releases page:

=begin code :lang<console>

error no prebuilt Moneymoor bundle for Linux ppc64le yet -- see
      https://github.com/owner/repo/releases for what is published

=end code

The Linux branch probes for a C<ld-musl-*.so.1> loader before choosing
between C<-glibc> and C<-musl>, the same conclusive test
L<App::Ariza::Platform> uses.

=head2 The install pays for the first launch

The last thing an install does before the parting message is run the
launcher it has just linked — C<< <exec> --version >> by default, or
whatever C<installer.warm> names — with its output suppressed and a
line on screen saying what is happening:

=begin code :lang<console>

ok  Moneymoor 0.3.0 installed
==> warming up -- the first launch does the work the rest never repeat
ok  ready

=end code

Whatever a first launch has to do that later ones do not — paging a few
hundred megabytes off a cold disk, creating a per-user state directory
— happens there, while an installer is visibly working, rather than the
first time somebody actually wants the program. Every path that reaches
the parting message goes through it, B<including> the re-run that found
the version already installed: that re-run is what people try when the
last one did not take.

A warm-up that fails B<warns and the install succeeds>. No non-zero
exit, no rollback, no "installation failed".

That is a deliberate divergence from how everything else here behaves,
and the difference is where the failure happens. C<ariza bundle> and
C<ariza smoke> run in our own pipeline, before anything is published,
where stopping is cheap and a false negative is expensive. This runs on
a stranger's machine, B<after> the bundle has been downloaded,
checksummed and moved into place — where the same signal much more
often means the machine (no terminal, a sandbox, a scanner holding a
file open) than the release, and where failing the install would delete
a working program from somebody who has one. So the message says what
did not complete, and that the app is installed and its download was
verified, so run it.

There is no timeout, on purpose: a mechanism that needed one would
imply a warm command that might not return, and the fix for that is the
command. Which is why an empty C<installer.warm> is a load-time error
rather than "run it with no arguments" — see L<App::Ariza::Config>.

The arguments are the one place in these templates where an app's own
string becomes script syntax, so they are quoted here rather than
trusted there: C<sh-quote> per word for C<sh>, C<ps-quote> per word for
PowerShell, splatted at the call site so an argument list cannot arrive
as one argument with spaces in it.

=head2 Curl-pipeable, and therefore silent

A script read from a pipe is executed as it arrives, so this one is
entirely function definitions with a single C<main "$@"> at the end: a
truncated download cannot half-run it.

It also never reads standard input — no confirmation prompts, no
C<read> — because when the script arrives I<on> standard input there is
nothing to read from. That is not a limitation worth working around;
an installer that cannot be interrogated is one that can be run from a
CI job.

=head2 Windows

The same shape in PowerShell:
C<%LOCALAPPDATA%\E<lt>DisplayE<gt>\versions\E<lt>versionE<gt>>, a
C<current> B<junction> (a symlink would need administrator rights or
Developer Mode, which a per-user install has no business demanding),
and C<...\current\bin> added once to the user C<PATH> in
C<HKCU\Environment>. Because the PATH entry points through the junction,
an upgrade needs no PATH change at all.

Archives are unpacked with C<tar.exe>, which has shipped in Windows
since 10 1803 and reads the C<.tar.gz> ariza packages every platform's
bundle as; C<Expand-Archive> handles a C<.zip> if one is ever pointed at
with C<-Url>.

Output is CRLF.

=head1 METHODS

=head2 write(:$out-dir!, :$config!, :$branch --> List)

Render every installer this app gets into C<:$out-dir> and return the
paths, C<chmod 0755> for the POSIX pair. The directory must already
exist — the default target is the app's own repository, and silently
creating one would turn a typo into a successful render nobody can find.

Dies when the app declares no C<bundle.platforms> (there would be
nothing to detect or download) or no C<installer.repo> (nowhere to
download it from).

=head2 render(:$template!, *%ctx --> Str)

One template, as text. Exposed separately because that is what a
golden-file test compares, and an installer is a thing worth diffing.

=head2 context(:$config!, :$branch --> Hash)

The render context: the app's names, the repository, the declared slugs
for each family, the C<< <EXEC>_BUNDLE_URL >> variable, the warm-up
(C<warm>, and its arguments quoted for each shell) and the two inlined
runtime libraries.

=head2 sh-quote(Str $word --> Str) / ps-quote(Str $word --> Str)

One word, quoted for C<sh> and for PowerShell respectively. The warm-up
arguments are the only part of a generated installer that comes from
the app rather than from ariza, and they are written into it as script
syntax, so they are quoted where they are rendered rather than trusted
where they land.

=head2 scripts-for(App::Ariza::Config $config --> List)

The C<{ template, output, family, mode, crlf }> entries this app gets,
in write order. An app that declares no Windows platform gets no
C<install.ps1>: a script whose only possible answer is "there is no
bundle for your machine" is worse than its absence.

=head2 slugs-for(App::Ariza::Config $config, Str $family --> List) / family-of(Str $slug --> Str)

The declared slugs in one family, and the family of a slug —
C<windows>, or C<posix> for everything else.

=head2 env-url(App::Ariza::Config $config --> Str)

The name of the source-override environment variable:
C<MONEYMOOR_BUNDLE_URL> for C<moneymoor>.

=head1 SEE ALSO

L<App::Ariza::Bundle>, which builds what this installs;
L<App::Ariza::Launcher>, which writes what it links to.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
