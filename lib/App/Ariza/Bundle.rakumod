use JSON::Fast;

use App::Ariza::Config;
use App::Ariza::Installer;
use App::Ariza::Launcher;
use App::Ariza::Licensing;
use App::Ariza::Native;
use App::Ariza::Platform;
use App::Ariza::Rakudo;
use App::Ariza::Resources;
use App::Ariza::Site;
use App::Ariza::Tools;
use App::Ariza::Update;
use App::Ariza::Versions;

unit class App::Ariza::Bundle;

#| The directory name (and archive stem) for a build:
#| C<< <exec>-<version>-<platform> >>.
method bundle-name(Str:D :$exec!, Str:D :$version!, Str:D :$platform! --> Str) {
    "$exec-$version-$platform"
}

#| The app version, read from the checkout's C<META6.json>.
#|
#| Read from the source rather than from the installed distribution
#| because the workdir has to be named before anything is installed —
#| and because a checkout whose META6 says one thing while its installed
#| copy says another is a problem worth failing on, which
#| L<App::Ariza::Site> then does.
method app-version(IO() $app-dir --> Str) {
    my $meta = $app-dir.add('META6.json');
    die "ariza: no META6.json in $app-dir" unless $meta.f;
    my $data = do {
        CATCH { default { die "ariza: malformed META6.json in $app-dir: {.message}" } }
        from-json($meta.slurp);
    }
    my $v = $data<version>;
    die "ariza: $meta has no version" unless $v.defined && $v.chars;
    ~$v
}

#| Build a bundle, end to end, and return everything about it.
method build(
    IO() :$app-dir!,
    Str  :$platform = current-slug(),
    IO() :$out-dir = $*CWD,
    IO() :$sqlcipher-archive,
    Bool :$verbose = True,
    --> Hash
) {
    my $config   = App::Ariza::Config.load($app-dir);
    my $versions = App::Ariza::Versions.load;
    note "ariza: $_" for $versions.warnings;
    note "ariza: $_" for $config.warnings;

    die "ariza: '$platform' is not a platform ariza knows"
      ~ " (expected one of: {known-slugs.join(', ')})"
        unless known-slug($platform);

    # An app that lists its platforms has made a statement about which
    # ones it is tested on; building an unlisted one silently would ship
    # an untested artefact under a name that implies otherwise.
    my @declared = $config.bundle-platforms.list;
    die "ariza: {$config.app-name} does not declare '$platform' in"
      ~ " bundle.platforms ({@declared.join(', ')})"
        if @declared && !@declared.first($platform);

    my $version = self.app-version($app-dir);
    my $name    = self.bundle-name(:exec($config.app-exec), :$version, :$platform);
    my $work    = ensure-dir($out-dir).add($name);

    note "ariza: building $name" if $verbose;
    rm-rf($work);
    ensure-dir($work);

    # Every path from here on is the physical one, not the one that was
    # typed. On macOS the obvious place to build — anything under
    # $TMPDIR — lives beneath /var, which is a symlink to /private/var,
    # and the bundled interpreter works out its own prefix from where
    # its executable really is. Point RAKULIB at the same repository
    # spelled the other way and Rakudo's registry compares the two
    # prefixes as strings, finds no match, and has no *name* for the
    # bundle's repository — which is precisely the condition under which
    # it records precompilation dependencies as absolute paths and the
    # user recompiles the whole closure. L<App::Ariza::Site> refuses to
    # warm a nameless repository, so this would be a failed build rather
    # than a bad bundle; resolving here means it is neither.
    $work = $work.resolve;

    my %rakudo = App::Ariza::Rakudo.provision(
        :bundle-dir($work), :slug($platform), :$versions);
    note "ariza: runtime {%rakudo<tag>}"
       ~ (%rakudo<cached> ?? ' (cached)' !! ' (downloaded)') if $verbose;

    my %site = App::Ariza::Site.build-site(
        :bundle-dir($work), :app-source($app-dir), :$config,
        :zef(%rakudo<zef>), :raku(%rakudo<raku>), :$verbose);

    my %sqlcipher;
    if $config.bundle-native.list.first('sqlcipher') {
        note "ariza: staging SQLCipher" if $verbose;
        %sqlcipher = App::Ariza::Native.stage-sqlcipher(
            :bundle-dir($work), :slug($platform), :$versions,
            :archive($sqlcipher-archive));
        note "ariza: sqlcipher {%sqlcipher<version> // 'of unknown version'}"
           ~ " from {%sqlcipher<origin>}" if $verbose;
    }

    my %audit = App::Ariza::Native.audit(
        :bundle-dir($work), :slug($platform),
        :extra(%sqlcipher<staged> // ()));
    note "ariza: audited {%audit<checked>} native binaries" if $verbose;

    my %updates = self.stage-updater(
        :$work, :$config, :$version, :$platform,
        :application-target(%site<target-rel>));

    my $launcher-target = %updates<coordinator-rel> // %site<target-rel>;
    my %launchers = App::Ariza::Launcher.write(
        :bundle-dir($work), :$config, :slug($platform),
        :target($launcher-target), :site(%site<site-rel>),
        :app-version($version),
        :notcurses-rel(%site<notcurses-lib-rel> // Str),
        :sqlcipher-rel(%sqlcipher<rel> // Str));
    my @launchers = %launchers<written>.list;

    # Before the manifest, because the manifest records what it found:
    # a bundle whose licensing summary is written after the fact is one
    # whose summary can disagree with the document beside it.
    my %licensing = self!licensing(
        :$work, :$config, :$app-dir, :$version, :$platform,
        :%rakudo, :%sqlcipher, :%updates, :runner(%launchers<runner>));
    note "ariza: $_" for %licensing<warnings>.list;
    note "ariza: {%licensing<summary><rows>} licensing rows,"
       ~ " {%licensing<summary><unknown>} unattributed" if $verbose;

    my %manifest = self!manifest(
        :$config, :$versions, :$version, :$platform, :$work,
        :%rakudo, :%site, :%sqlcipher, :%updates, :@launchers,
        :runner(%launchers<runner>), :licensing(%licensing<summary>));

    $work.add('ariza-manifest.json').spurt(to-json(%manifest, :sorted-keys) ~ "\n");
    $work.add('VERSION').spurt(self.version-file(%manifest));

    my %archive = self!package($out-dir, $name, $work, :$verbose);

    {
        name      => $name,
        dir       => $work,
        archive   => %archive<archive>,
        checksum  => %archive<checksum>,
        sha256    => %archive<sha256>,
        compressed   => %archive<compressed>,
        uncompressed => %archive<uncompressed>,
        manifest  => %manifest,
        launchers => @launchers,
        audit     => %audit,
        licensing => %licensing,
        platform  => $platform,
        version   => $version,
    }
}

method !manifest(
    App::Ariza::Config:D :$config!, App::Ariza::Versions:D :$versions!,
    Str:D :$version!, Str:D :$platform!, IO::Path:D :$work!,
    :%rakudo!, :%site!, :%sqlcipher!, :%updates!, :@launchers!,
    :%runner!, :%licensing!,
    --> Hash
) {
    my %m =
        'ariza-manifest' => 1,
        ariza    => (try { $?DISTRIBUTION.meta<version> }) // 'dev',
        built-at => DateTime.now(:timezone(0)).truncated-to('second').Str,
        platform => $platform,
        app => {
            name    => $config.app-name,
            exec    => $config.app-exec,
            display => $config.app-display,
            version => $version,
            installed-version => %site<app-version>,
        },
        launcher => {
            scripts => @launchers.map({ .relative($work).subst('\\', '/', :g) }).List,
            target  => %updates<coordinator-rel> // %site<target-rel>,
            # The repository the launcher points RAKULIB at. Recorded
            # rather than assumed so that anything checking a bundle
            # after the fact — `ariza smoke` above all — reads the
            # answer out of the bundle instead of out of the version of
            # ariza that happens to be installed.
            site    => %site<site-rel>,
        },
        components => {
            rakudo => {
                version  => %rakudo<version>,
                revision => %rakudo<revision>,
                tag      => %rakudo<tag>,
                url      => %rakudo<url>,
                sha256   => %rakudo<sha256>,
                archive  => %rakudo<archive>.basename,
            },
        },
        # `%( )`, not `{ }`: a literal whose body starts with a `.method`
        # call is parsed as a Block, and a Block of pairs returns a list
        # of Pairs — which serialises as an array of one-key objects
        # rather than as one object per distribution.
        dists => %site<dists>.map(-> %d {
            %( name => %d<name>, version => %d<version>, auth => %d<auth> )
        }).List,
        smoke => $config.smoke-argvs.map(*.List).List,
        licensing => %licensing,
    ;

    with %site<notcurses-tag> -> $tag {
        %m<components><notcurses> = self.notcurses-component(%site);
    }

    %m<components><sqlcipher> = self.sqlcipher-component(%sqlcipher) if %sqlcipher;
    %m<components><runner> = self.runner-component(%runner, $work) if %runner;
    %m<updates> = self.updates-component(%updates) if %updates;

    %m
}

#| Stage the generated coordinator and an exact copy of the platform's local
#| installer implementation. Nothing is added for the default, disabled mode.
method stage-updater(
    IO::Path:D :$work!, App::Ariza::Config:D :$config!, Str:D :$version!,
    Str:D :$platform!, Str:D :$application-target!,
    --> Hash
) {
    return %() unless $config.updates-enabled;

    my $repo = $config.installer-repo
        // die "ariza: update-enabled bundles require installer.repo";
    my %written = App::Ariza::Update.write(
        :bundle-dir($work), :app-name($config.app-name),
        :app-exec($config.app-exec), :app-display($config.app-display),
        :app-version($version), :$repo, :slug($platform));

    my $family = $platform.starts-with('windows-') ?? 'windows' !! 'posix';
    my $installer = %written<installer>;
    ensure-dir($installer.parent);
    $installer.spurt(App::Ariza::Installer.snapshot(:$config, :$family));
    $installer.chmod($family eq 'posix' ?? 0o755 !! 0o644);

    %(
        protocol           => 1,
        repository         => $repo,
        coordinator        => %written<coordinator>,
        installer          => $installer,
        'coordinator-rel'  => App::Ariza::Update.coordinator-rel,
        'installer-rel'    => App::Ariza::Update.installer-rel($platform),
        'application-target' => $application-target,
    )
}

#| Public, serialisable form of the updater metadata. Physical build paths do
#| not enter the manifest.
method updates-component(%updates --> Hash) {
    %(
        protocol             => %updates<protocol>,
        enabled              => True,
        repository           => %updates<repository>,
        coordinator          => %updates<coordinator-rel>,
        installer            => %updates<installer-rel>,
        'application-target' => %updates<application-target>,
    )
}

#| The manifest's runner entry: which published artefact was staged,
#| from which release, at which URL, and the digest it was verified
#| against before it went anywhere near the bundle.
#|
#| The runner is downloaded like the runtime archive is, so it is
#| recorded like the runtime archive is. Without this entry it would be
#| the one binary in a bundle a reader could not trace back to something
#| published — which for the file a Windows user actually runs is the
#| worst possible place to have a gap.
method runner-component(%runner, IO::Path $work --> Hash) {
    %(
        artifact => %runner<artifact> // '',
        tag      => %runner<tag> // '',
        url      => %runner<url> // '',
        sha256   => %runner<sha256> // '',
        path     => (%runner<path>.defined
                        ?? %runner<path>.relative($work).subst('\\', '/', :g)
                        !! ''),
    )
}

#| The manifest's notcurses entry. The exact library directory discovered
#| by L<App::Ariza::Site> is retained rather than reconstructed by each
#| launcher or smoke implementation; on Windows that directory is part of
#| the live loader contract as well as component metadata.
method notcurses-component(%site --> Hash) {
    my $tag = %site<notcurses-tag> // '';
    %(
        tag  => $tag,
        path => %site<notcurses-lib-rel>
             // ($tag.chars ?? "native/Notcurses-Native/$tag/lib" !! ''),
    )
}

#| The manifest's SQLCipher entry, from what L<App::Ariza::Native>
#| actually staged.
#|
#| C<version> is the version B<staged>, not the pin: the machine's
#| package manager decides what gets bundled, and a manifest that quotes
#| a number nobody verified is worse than no number at all. The pin
#| travels alongside as C<pinned>, so a reader can see the two disagree
#| — which is the same thing the build warned about at the time.
#|
#| A library whose bytes did not name a version is C<'unknown'> rather
#| than the pin, for the same reason. C<source> is the human-readable
#| provenance sentence — which keg, which bottle, which archive.
method sqlcipher-component(%sqlcipher --> Hash) {
    %(
        version => %sqlcipher<version> // 'unknown',
        pinned  => %sqlcipher<pinned> // 'unpinned',
        path    => %sqlcipher<rel>,
        sha256  => %sqlcipher<sha256>,
        source  => %sqlcipher<origin> // '',
    )
}

#| The human-readable twin of the manifest: what this is, and one line
#| per pinned component. Deliberately fixed-width and greppable — it is
#| the first thing anyone looks at in a bug report.
method version-file(%m --> Str) {
    my @lines =
        "{%m<app><display>} {%m<app><version>} ({%m<platform>})",
        '',
        sprintf('%-12s %s', 'app', "{%m<app><name>} {%m<app><version>}"),
        sprintf('%-12s %s', 'rakudo', %m<components><rakudo><tag>),
    ;
    with %m<components><sqlcipher> {
        @lines.push(sprintf('%-12s %s', 'sqlcipher', .<version>));
    }
    with %m<components><notcurses> {
        @lines.push(sprintf('%-12s %s', 'notcurses', .<tag>));
    }
    with %m<components><runner> {
        @lines.push(sprintf('%-12s %s', 'runner', .<tag>));
    }
    @lines.push(sprintf('%-12s %s', 'ariza', %m<ariza>));
    @lines.push(sprintf('%-12s %s', 'built', %m<built-at>));
    @lines.push('');
    @lines.push("Run bin/{%m<app><exec>} — nothing needs installing.");
    @lines.join("\n") ~ "\n"
}

#| Everything about what this bundle redistributes, in the two files a
#| recipient reads: C<THIRD-PARTY.md> at the bundle root and the
#| C<LICENSES/> directory beside it.
#|
#| Every fact in them is read rather than remembered — a native pack's
#| own licensing kit, ariza's maintained record of the vendored runtime,
#| each installed distribution's own C<META6.json>, the app's
#| C<ariza.toml> — which is what keeps ariza a tool that bundles
#| anybody's application rather than a list of facts about a few.
#|
#| The build knows four things L<App::Ariza::Licensing> cannot work out
#| for itself, and they are all passed in here: which runtime was
#| staged, which SQLCipher (and which files came with it), which runner,
#| and therefore which of the data file's conditional rows apply.
method !licensing(
    IO::Path :$work!, App::Ariza::Config:D :$config!, IO::Path :$app-dir!,
    Str:D :$version!, Str:D :$platform!, :%rakudo!, :%sqlcipher!, :%updates!,
    :%runner!,
    --> Hash
) {
    my @conditions;
    @conditions.push('sqlcipher') if %sqlcipher;
    @conditions.push('runner') if %runner;
    @conditions.push('updater') if %updates;

    App::Ariza::Licensing.write(
        :bundle-dir($work), :$config, :$app-dir,
        :app-version($version), :app-display($config.app-display), :$platform,
        :@conditions,
        :placeholders(%(
            'rakudo-version'    => ~(%rakudo<version> // ''),
            'rakudo-tag'        => ~(%rakudo<tag> // ''),
            'rakudo-url'        => ~(%rakudo<url> // ''),
            'sqlcipher-version' => ~(%sqlcipher<version> // 'unknown'),
            'sqlcipher-source'  => ~(%sqlcipher<origin> // ''),
            'runner-tag'        => ~(%runner<tag> // ''),
            'runner-url'        => ~(%runner<url> // ''),
            'app-exec'          => $config.app-exec,
            'ariza-version'     => (try { $?DISTRIBUTION.meta<version> }) // 'dev',
        )),
        # What the SQLCipher row turned out to cover: the library and
        # every dependency staged beside it. Read off the staging step
        # rather than written down, because which libraries a SQLCipher
        # drags in is a property of the machine it came from.
        :files(%(
            sqlcipher => (%sqlcipher<staged> // ()).list
                            .map(*.basename).unique.sort.List,
            'ariza-updater' => %updates
                ?? (%updates<coordinator-rel>, %updates<installer-rel>)
                !! (),
        )),
    )
}

#| Tar the workdir and write the checksum file beside it.
method !package(IO::Path $out-dir, Str $name, IO::Path $work, Bool :$verbose --> Hash) {
    my $archive = $out-dir.add("$name.tar.gz");
    $archive.unlink if $archive.e;

    note "ariza: packaging $name.tar.gz" if $verbose;
    # `-C <out-dir> <name>` so the archive holds one top-level directory
    # named after the bundle, which is what an `ariza smoke` (and a
    # user's `tar xzf`) expects to find.
    run-checked(['tar', '-c', '-z', '-f', $archive.absolute,
                 '-C', $out-dir.absolute, $name],
                :what('tar'));

    my $sha = sha256-file($archive);
    my $checksum = $out-dir.add("$name.tar.gz.sha256");
    # The `<hex>  <file>` shape `shasum -c` / `sha256sum -c` expect.
    $checksum.spurt("$sha  $name.tar.gz\n");

    {
        archive      => $archive,
        checksum     => $checksum,
        sha256       => $sha,
        compressed   => $archive.s,
        uncompressed => self!tree-size($work),
    }
}

method !tree-size(IO::Path $dir --> Int) {
    my $total = 0;
    my @queue = $dir;
    while @queue {
        my $d = @queue.shift;
        for $d.dir -> $e {
            next if $e.l;
            $e.d ?? @queue.push($e) !! ($total += $e.s);
        }
    }
    $total
}

=begin pod

=head1 NAME

App::Ariza::Bundle - build one self-contained archive of an application

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Bundle;

my %b = App::Ariza::Bundle.build(
    :app-dir('/Users/me/code/App-Moneymoor'),
    :out-dir('/tmp/dist'),
);

say %b<name>;            # moneymoor-0.2.0-macos-arm64
say %b<archive>;         # /tmp/dist/moneymoor-0.2.0-macos-arm64.tar.gz
say %b<sha256>;
say %b<compressed>;      # 76_226_140
say %b<uncompressed>;    # 214_913_002

# Cross-target: a Linux bundle needs a Linux SQLCipher, which this
# machine's package manager cannot supply.
App::Ariza::Bundle.build(
    :app-dir($app), :platform<linux-x86_64-glibc>,
    :sqlcipher-archive('/tmp/libsqlcipher-linux-x86_64.tar.gz'));

=end code

=head1 DESCRIPTION

The orchestrator. Everything a bundle needs is done by another module in
this distribution; this one decides the order, names the artefact, and
writes the three files that describe what was made.

=head2 The order, and why it is that order

=item1 B<L<App::Ariza::Rakudo>> unpacks the pinned runtime into
C<< <work>/rakudo >>. It goes first because everything after it runs
I<under> that runtime.

=item1 B<L<App::Ariza::Site>> installs the app and its closure into the
runtime's own C<vendor> repository — C<< <work>/rakudo/share/perl6/vendor >>,
which is the only kind of place a warm precompilation store survives
being moved to another machine — using the runtime's own C<zef>, stages
notcurses into C<< <work>/native >> as a side effect, and warms that
store.

=item1 B<L<App::Ariza::Native>> stages SQLCipher, then audits every
native binary in the bundle. The audit runs after both staging steps
because it is a statement about the finished bundle, not about any one
component.

=item1 B<L<App::Ariza::Launcher>> writes C<< <work>/bin/<exec> >> and
stages the compiled Windows runner, last, because it needs the target
L<App::Ariza::Site> discovered and the library path
L<App::Ariza::Native> chose.

=item1 B<L<App::Ariza::Licensing>> then reads the finished bundle —
every native pack's licensing kit, every installed distribution's
metadata — and writes C<THIRD-PARTY.md> and C<LICENSES/>. It runs
B<before> the manifest because the manifest records its summary, and a
summary written after the fact is one that can disagree with the
document beside it.

Then C<VERSION> and C<ariza-manifest.json> are written and the whole
directory is tarred.

=head2 The artefact

=begin code :lang<console>

<out-dir>/moneymoor-0.2.0-macos-arm64/          # the bundle, left in place
<out-dir>/moneymoor-0.2.0-macos-arm64.tar.gz    # the thing you publish
<out-dir>/moneymoor-0.2.0-macos-arm64.tar.gz.sha256

=end code

The archive holds exactly one top-level directory, named after the
bundle, so unpacking it anywhere is predictable and never scatters files
into the current directory. The checksum file uses the
C<< <hex>  <file> >> shape C<shasum -c> and C<sha256sum -c> read.

The unpacked workdir is deliberately B<not> deleted: it is what
C<ariza smoke> can be pointed at without a round-trip through tar, and
what you look inside when something is wrong.

=head2 What is inside

=begin code :lang<console>

bin/moneymoor              the launcher, and the only thing a user runs
rakudo/                    the interpreter (plus SQLCipher, on macOS)
  share/perl6/vendor/      every Raku module, with warm bytecode
native/                    notcurses and friends
VERSION                    one screen: app version and component pins
ariza-manifest.json        the machine-readable version of the same
THIRD-PARTY.md             every component, its licence and where that
                           fact came from
LICENSES/                  the text of every licence the above cites

=end code

=head2 VERSION and the manifest

C<VERSION> is for a human in a bug report: the app, the platform, and
one line per pinned component. C<ariza-manifest.json> is the same facts
plus the ones only a machine cares about — every source URL, every
SHA-256, every Raku distribution installed with its version and author,
and the smoke commands, so C<ariza smoke> can check an archive it knows
nothing else about.

=head2 THIRD-PARTY.md and LICENSES/

A bundle redistributes other people's software, so it says so — in one
document listing every component with its version, its licence, its
copyright and B<where that fact came from>, and one directory holding
the text of every licence it cites.

None of it is written down in ariza. L<App::Ariza::Licensing> reads a
native pack's own licensing kit, ariza's maintained data file for the
vendored runtime and MoarVM's vendored C libraries, the C<license> field
of every distribution installed into the bundle, and the app's
C<ariza.toml>. A component it cannot attribute is a visible row and a
warning rather than a silence, and C<licensing.strict> in the app's
config turns that into a failed build.

=head2 Declared platforms are enforced

Building a slug the app does not list in C<bundle.platforms> is an
error. An app that lists its platforms has made a statement about which
ones it is tested on, and producing an artefact named
C<E<lt>appE<gt>-E<lt>verE<gt>-E<lt>slugE<gt>> for one it never claimed
is a promise ariza has no business making on its behalf. An app with no
C<bundle.platforms> at all imposes no such constraint.

=head1 METHODS

=head2 build(:$app-dir!, :$platform, :$out-dir, :$sqlcipher-archive, :$verbose --> Hash)

The whole build. C<:$platform> defaults to this machine's slug;
C<:$out-dir> to the current directory; C<:$sqlcipher-archive> stages a
local SQLCipher archive instead of taking the machine's own copy, which
is what a cross-build or an air-gapped build needs.

Returns C<name>, C<dir>, C<archive>, C<checksum>, C<sha256>,
C<compressed>, C<uncompressed>, C<manifest>, C<launchers>, C<audit>,
C<licensing>, C<platform> and C<version>.

=head2 bundle-name(:$exec!, :$version!, :$platform! --> Str)

C<< <exec>-<version>-<platform> >> — the workdir name and the archive
stem.

=head2 version-file(%manifest --> Str)

The text of C<VERSION>, rendered from a manifest. Public because it is
the one artefact whose exact wording a human reads in a bug report, and
because rendering it is worth testing without building 165MB first.

=head2 runner-component(%runner, IO::Path $work --> Hash)

The manifest's C<components.runner> entry: the published artefact that
was staged, the release it came from, its URL and the digest it was
verified against. The runner is downloaded like the runtime archive is,
so it is recorded like the runtime archive is — without this it would be
the one binary in a bundle a reader could not trace back to something
published, which for the file a Windows user actually runs is the worst
place to have a gap.

=head2 notcurses-component(%site --> Hash)

The manifest's Notcurses tag and exact staged C<lib/> directory from
L<App::Ariza::Site>. Windows launchers and smoke consume the same path;
reconstructing it independently would let metadata and the live loader
contract drift apart.

=head2 sqlcipher-component(%sqlcipher --> Hash)

The manifest's C<components.sqlcipher> entry, built from what
L<App::Ariza::Native> staged: the version B<staged> (or C<'unknown'>),
the C<pinned> one beside it, the bundle-relative path, the digest, and
the provenance sentence. Public because "does the manifest tell the
truth about what was bundled" is worth a test that does not build 165MB
first.

=head2 app-version(IO() $app-dir --> Str)

The version from the checkout's C<META6.json>. Read from source rather
than from the installed distribution because the workdir has to be named
before anything is installed.

=head1 SEE ALSO

L<App::Ariza::Smoke>, which takes the archive this produces and proves
it runs somewhere else.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
