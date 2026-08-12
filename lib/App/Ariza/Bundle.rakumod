use JSON::Fast;
use Template::Jinja2;

use App::Ariza::Config;
use App::Ariza::Launcher;
use App::Ariza::Native;
use App::Ariza::Platform;
use App::Ariza::Rakudo;
use App::Ariza::Resources;
use App::Ariza::Site;
use App::Ariza::Tools;
use App::Ariza::Versions;

unit class App::Ariza::Bundle;

# Native libraries shipped in the notcurses pack, grouped by upstream
# project, for LICENSES/COMPONENTS.md. Matched on the filename prefix in
# order, so `libnotcurses_native_shim` has to come before `libnotcurses`.
#
# This exists because a redistributed binary with no attribution is not
# something to ship, and a generated inventory is the only kind that
# stays true when the pack changes.
my constant @NATIVE-LICENSES =
    'libnotcurses_native_shim' => ('Notcurses-Native (this project)', 'Artistic-2.0'),
    'libnotcurses'   => ('notcurses',   'Apache-2.0'),
    'libav'          => ('FFmpeg',      'GPL-2.0-or-later (see note)'),
    'libsw'          => ('FFmpeg',      'GPL-2.0-or-later (see note)'),
    'libpostproc'    => ('FFmpeg',      'GPL-2.0-or-later (see note)'),
    'libx264'        => ('x264',        'GPL-2.0-or-later'),
    'libx265'        => ('x265',        'GPL-2.0-or-later'),
    'libSvtAv1'      => ('SVT-AV1',     'BSD-3-Clause-Clear'),
    'libdav1d'       => ('dav1d',       'BSD-2-Clause'),
    'libvpx'         => ('libvpx',      'BSD-3-Clause'),
    'libaom'         => ('libaom',      'BSD-2-Clause'),
    'libopus'        => ('Opus',        'BSD-3-Clause'),
    'libmp3lame'     => ('LAME',        'LGPL-2.0-or-later'),
    'libvmaf'        => ('VMAF',        'BSD-2-Clause-Patent'),
    'libvorbis'      => ('Vorbis',      'BSD-3-Clause'),
    'libogg'         => ('Ogg',         'BSD-3-Clause'),
    'libtheora'      => ('Theora',      'BSD-3-Clause'),
    'libcrypto'      => ('OpenSSL',     'Apache-2.0'),
    'libssl'         => ('OpenSSL',     'Apache-2.0'),
    'libncurses'     => ('ncurses',     'MIT-like (X11)'),
    'libunistring'   => ('GNU libunistring', 'LGPL-3.0-or-later'),
    'libdeflate'     => ('libdeflate',  'MIT'),
    'libz'           => ('zlib',        'Zlib'),
    'libsqlcipher'   => ('SQLCipher',   'BSD-style (Zetetic LLC)'),
;

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

    my @launchers = App::Ariza::Launcher.write(
        :bundle-dir($work), :$config, :slug($platform),
        :target(%site<target-rel>), :app-version($version),
        :sqlcipher-rel(%sqlcipher<rel> // Str));

    my %manifest = self!manifest(
        :$config, :$versions, :$version, :$platform, :$work,
        :%rakudo, :%site, :%sqlcipher, :@launchers);

    $work.add('ariza-manifest.json').spurt(to-json(%manifest, :sorted-keys) ~ "\n");
    $work.add('VERSION').spurt(self.version-file(%manifest));
    self!licenses($work, $config, $app-dir, %manifest, %site);

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
        platform  => $platform,
        version   => $version,
    }
}

method !manifest(
    App::Ariza::Config:D :$config!, App::Ariza::Versions:D :$versions!,
    Str:D :$version!, Str:D :$platform!, IO::Path:D :$work!,
    :%rakudo!, :%site!, :%sqlcipher!, :@launchers!,
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
            target  => %site<target-rel>,
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
    ;

    with %site<notcurses-tag> -> $tag {
        %m<components><notcurses> = {
            tag  => $tag,
            path => "native/Notcurses-Native/$tag/lib",
        };
    }

    %m<components><sqlcipher> = self.sqlcipher-component(%sqlcipher) if %sqlcipher;

    %m
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
    @lines.push(sprintf('%-12s %s', 'ariza', %m<ariza>));
    @lines.push(sprintf('%-12s %s', 'built', %m<built-at>));
    @lines.push('');
    @lines.push("Run bin/{%m<app><exec>} — nothing needs installing.");
    @lines.join("\n") ~ "\n"
}

#| Assemble `LICENSES/`: the app's own licence, Rakudo's, and a
#| generated inventory of everything else the bundle redistributes.
method !licenses(IO::Path $work, App::Ariza::Config:D $config,
                 IO::Path $app-dir, %m, %site) {
    my $dir = ensure-dir($work.add('LICENSES'));

    my $app-license-file = "{$config.app-name.subst('::', '-', :g)}.txt";
    my $app-license = $app-dir.dir.first({
        .f && .basename.uc.starts-with('LICENSE')
    });
    with $app-license {
        $dir.add($app-license-file).spurt(.slurp);
    }
    else {
        $dir.add($app-license-file).spurt(
            "{$config.app-name} ships no LICENSE file in its repository.\n"
          ~ "Its metadata declares: {self!meta-license($app-dir) // 'nothing'}\n");
    }

    my $rakudo-license = $work.add('rakudo').add('LICENSE');
    $dir.add('rakudo.txt').spurt(
        $rakudo-license.f ?? $rakudo-license.slurp
                          !! "Rakudo's LICENSE file was not present in the"
                           ~ " runtime archive; see https://rakudo.org/.\n");

    $dir.add('COMPONENTS.md').spurt(self!components-md($work, $config, $app-dir, %m, %site));
}

method !meta-license(IO::Path $app-dir --> Str) {
    my $meta = $app-dir.add('META6.json');
    return Str unless $meta.f;
    my $data = try { from-json($meta.slurp) };
    ($data // {})<license> // Str
}

method !components-md(IO::Path $work, App::Ariza::Config:D $config,
                      IO::Path $app-dir, %m, %site --> Str) {
    my @rows = self.native-inventory(%site<notcurses-lib>);

    my %ctx =
        app_name     => $config.app-name,
        app_display  => $config.app-display,
        app_version  => %m<app><version>,
        app_license  => self!meta-license($app-dir) // 'see LICENSES/',
        app_license_file => "{$config.app-name.subst('::', '-', :g)}.txt",
        platform     => %m<platform>,
        ariza_version => %m<ariza>,
        built_at     => %m<built-at>,
        rakudo_tag   => %m<components><rakudo><tag>,
        rakudo_url   => %m<components><rakudo><url>,
        rakudo_sha256 => %m<components><rakudo><sha256>,
        notcurses_tag => (%m<components><notcurses> andthen .<tag>) // '',
        native_rows  => @rows,
        sqlcipher_version => (%m<components><sqlcipher> andthen .<version>) // '',
        sqlcipher_rel     => (%m<components><sqlcipher> andthen .<path>) // '',
        sqlcipher_sha256  => (%m<components><sqlcipher> andthen .<sha256>) // '',
        sqlcipher_source  => (%m<components><sqlcipher> andthen .<source>) // '',
    ;

    my $tpl = resource('templates/COMPONENTS.md.j2').slurp;
    Template::Jinja2.new.from-string($tpl).render(|%ctx)
}

#| Group the staged native libraries by upstream project, as
#| C<{ project, license, files }> rows sorted by project.
#|
#| Read off the staged directory rather than written down, so the licence
#| inventory describes what is actually in B<this> bundle rather than what
#| was in one when somebody last edited a document. A library the table
#| does not recognise is listed as C<(unclassified)> — visible, and
#| therefore fixable — rather than dropped.
method native-inventory($lib-dir --> List) {
    return () unless $lib-dir.defined && $lib-dir.d;

    my %by-project;
    for $lib-dir.dir.grep({ !.d }).map(*.basename).sort -> $file {
        next if $file.ends-with('.srchash');
        my $hit = @NATIVE-LICENSES.first({ $file.starts-with(.key) });
        my ($project, $license) = $hit
            ?? $hit.value
            !! ('(unclassified)', 'see upstream');
        %by-project{$project} //= { files => [], license => $license };
        %by-project{$project}<files>.push($file);
    }

    %by-project.sort(*.key).map(-> $p {
        %(
            project => $p.key,
            license => $p.value<license>,
            files   => $p.value<files>.map({ "`$_`" }).join(', '),
        )
    }).List
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

=item1 B<L<App::Ariza::Site>> installs the app and its closure into
C<< <work>/site >> using the runtime's own C<zef>, stages notcurses into
C<< <work>/native >> as a side effect, and warms the precompilation
store.

=item1 B<L<App::Ariza::Native>> stages SQLCipher, then audits every
native binary in the bundle. The audit runs after both staging steps
because it is a statement about the finished bundle, not about any one
component.

=item1 B<L<App::Ariza::Launcher>> writes C<< <work>/bin/<exec> >>, last,
because it needs the target L<App::Ariza::Site> discovered and the
library path L<App::Ariza::Native> chose.

Then C<VERSION>, C<ariza-manifest.json> and C<LICENSES/> are written and
the whole directory is tarred.

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
site/                      every Raku module, with warm bytecode
native/                    notcurses and friends
VERSION                    one screen: app version and component pins
ariza-manifest.json        the machine-readable version of the same
LICENSES/                  app + Rakudo licence text, and COMPONENTS.md

=end code

=head2 VERSION and the manifest

C<VERSION> is for a human in a bug report: the app, the platform, and
one line per pinned component. C<ariza-manifest.json> is the same facts
plus the ones only a machine cares about — every source URL, every
SHA-256, every Raku distribution installed with its version and author,
and the smoke commands, so C<ariza smoke> can check an archive it knows
nothing else about.

=head2 LICENSES/

A bundle redistributes other people's software, so it says so. The app's
own C<LICENSE> and Rakudo's are copied in verbatim;
C<LICENSES/COMPONENTS.md> is generated — the native inventory is read
off the staged libraries rather than written by hand, because a
hand-written one stops being true the first time the pack changes.

The inventory is grouped by upstream project and includes an explicit
note that this notcurses pack's FFmpeg is built with C<libx264> and
C<libx265>, and is therefore a GPL build rather than the LGPL one FFmpeg
ships by default. That has redistribution consequences, so it is stated
where someone will see it rather than left to be discovered.

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
C<platform> and C<version>.

=head2 bundle-name(:$exec!, :$version!, :$platform! --> Str)

C<< <exec>-<version>-<platform> >> — the workdir name and the archive
stem.

=head2 native-inventory(IO() $lib-dir --> List)

C<{ project, license, files }> for every staged native library, grouped
by upstream project. This is what C<LICENSES/COMPONENTS.md> is rendered
from, and it is read off the directory rather than written down: a
hand-maintained inventory stops being true the first time the notcurses
pack changes.

=head2 version-file(%manifest --> Str)

The text of C<VERSION>, rendered from a manifest. Public because it is
the one artefact whose exact wording a human reads in a bug report, and
because rendering it is worth testing without building 165MB first.

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
