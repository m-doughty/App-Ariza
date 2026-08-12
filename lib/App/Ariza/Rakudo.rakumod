use JSON::Fast;

use App::Ariza::Tools;
use App::Ariza::Versions;

unit class App::Ariza::Rakudo;

#| The machine-readable release index rakudo.org publishes: a flat JSON
#| array, one object per downloadable file, going back to 2009.
our constant INDEX-URL = 'https://rakudo.org/dl/rakudo';

# ariza's platform slugs -> the (platform, arch) pair the index uses.
#
# Deliberately partial. rakudo.org publishes official binary builds for
# four platforms; the other four slugs ariza knows are real platforms
# with no upstream archive to embed, and a bundle for one of them is a
# different project (build Rakudo yourself, then teach this map about
# it). An absent entry produces a die naming what *is* available, which
# is far better than a 404 from a URL assembled out of hope.
my constant %INDEX-PLATFORM =
    'macos-arm64'        => { platform => 'macos', arch => 'arm64'  },
    'macos-x86_64'       => { platform => 'macos', arch => 'x86_64' },
    'linux-x86_64-glibc' => { platform => 'linux', arch => 'x86_64' },
    'windows-x86_64'     => { platform => 'win',   arch => 'x86_64' },
;

#| Every slug this module can fetch a runtime for, sorted.
method fetchable-slugs(--> List) { %INDEX-PLATFORM.keys.sort.List }

#| The C<(platform, arch)> index coordinates for a slug, or a die naming
#| every slug that has coordinates.
method index-platform(Str:D $slug --> Hash) {
    %INDEX-PLATFORM{$slug}
        // die "ariza: rakudo.org publishes no binary build for '$slug'"
             ~ " (bundleable platforms: {self.fetchable-slugs.join(', ')})";
}

#| The download cache root: C<$XDG_CACHE_HOME/ariza/rakudo>, falling back
#| to C<~/.cache> as the XDG spec requires.
method cache-dir(--> IO::Path) {
    my $base = %*ENV<XDG_CACHE_HOME> || $*HOME.add('.cache').absolute;
    $base.IO.add('ariza').add('rakudo')
}

#| Fetch and parse the release index. C<:&fetch> replaces the HTTP call
#| for tests; C<:$url> replaces the endpoint.
method fetch-index(Str :$url = INDEX-URL, :&fetch = &http-get --> List) {
    my $body = do {
        CATCH {
            default {
                die "ariza: could not reach the Rakudo release index at $url"
                  ~ " ({.message.subst(/^ 'ariza: '/, '')});"
                  ~ " a bundle needs network access the first time it is built";
            }
        }
        fetch($url);
    }

    my $data = do {
        CATCH { default { die "ariza: the Rakudo release index at $url is not JSON: {.message}" } }
        from-json($body);
    }

    die "ariza: the Rakudo release index at $url is not a list of releases"
        unless $data ~~ Positional;

    $data.grep(* ~~ Associative).List
}

#| Pick the one index entry for a slug at an exact pinned version and
#| revision, dying with a diagnostic if there isn't exactly one.
#|
#| C<$revision> is the C<build_rev> in the index — C<"01"> in a pin file,
#| C<1> in the JSON — so it is compared numerically.
method select-entry(
    @entries,
    Str:D :$slug!,
    Str:D :$version!,
    Str:D :$revision!,
    --> Hash
) {
    my %want = self.index-platform($slug);
    my $rev = do { CATCH { default { die "ariza: rakudo revision '$revision' is not a number" } }; $revision.Int };

    my @matches = @entries.grep({
             (.<type>     // '') eq 'archive'
          && (.<platform> // '') eq %want<platform>
          && (.<arch>     // '') eq %want<arch>
          && (.<ver>      // '') eq $version
          && (.<build_rev> // -1) == $rev
          && (.<url>      // '').chars
    });

    if !@matches {
        my @near = @entries.grep({
                 (.<type>     // '') eq 'archive'
              && (.<platform> // '') eq %want<platform>
              && (.<arch>     // '') eq %want<arch>
        }).map({ "{.<ver>}-{(.<build_rev> // 0).fmt('%02d')}" }).unique.sort;
        die "ariza: no Rakudo {$version}-{$revision} build for $slug"
          ~ " ({%want<platform>}/{%want<arch>}) in the release index"
          ~ (@near ?? "; that platform has: {@near.tail(6).join(', ')}" !! '');
    }

    # More than one match means upstream published two archives for the
    # same platform, version and revision (a second toolchain, say).
    # Refuse to guess: the pin file is where that choice belongs.
    die "ariza: the release index has {+@matches} archives for"
      ~ " Rakudo {$version}-{$revision} on $slug"
      ~ " ({@matches.map({ .<url>.split('/').tail }).join(', ')})"
        if @matches > 1;

    @matches[0].Hash
}

#| Download an index entry's archive into the cache, or reuse the cached
#| copy after verifying its recorded digest.
#|
#| Returns C<{ archive, sha256, cached }>. C<:&download> replaces the
#| transfer for tests.
method fetch-archive(
    %entry,
    IO() :$cache-dir = self.cache-dir,
    :&download = &http-download,
    --> Hash
) {
    my $url = %entry<url> // die "ariza: release index entry has no url";
    my $file = $url.split('/').tail;
    die "ariza: release index entry has an unusable url ($url)" unless $file.chars;

    ensure-dir($cache-dir);
    my $archive = $cache-dir.add($file);
    my $sidecar = $cache-dir.add($file ~ '.sha256');

    if $archive.f && $sidecar.f {
        my $recorded = $sidecar.slurp.trim.lc;
        my $actual   = sha256-file($archive);
        return %( archive => $archive, sha256 => $actual, cached => True )
            if $recorded eq $actual;
        # A cached archive that no longer matches what was recorded for
        # it is corrupt (a half-written file from a killed process, a
        # touched disk). Throwing it away and re-fetching is right;
        # trusting it is how a broken byte gets into every bundle built
        # on this machine from now on.
        note "ariza: cached {$file} failed its recorded digest, re-downloading";
        $archive.unlink;
        $sidecar.unlink;
    }
    elsif $archive.f {
        # Present but never recorded: an archive from an interrupted
        # earlier run, or one dropped in by hand. Record it now rather
        # than re-download, then verify on every subsequent build.
        my $actual = sha256-file($archive);
        $sidecar.spurt($actual ~ "\n");
        return { archive => $archive, sha256 => $actual, cached => True };
    }

    download($url, $archive);
    my $sha = sha256-file($archive);
    $sidecar.spurt($sha ~ "\n");
    { archive => $archive, sha256 => $sha, cached => False }
}

#| Unpack a runtime archive into C<< <$bundle-dir>/rakudo >>, stripping
#| the single wrapper directory every official build ships. Any existing
#| C<rakudo/> is replaced.
method unpack(IO() $archive, IO() $bundle-dir --> IO::Path) {
    my $root    = ensure-dir($bundle-dir).add('rakudo');
    my $staging = $bundle-dir.add('.rakudo-staging');

    rm-rf($staging);
    rm-rf($root);
    LEAVE rm-rf($staging);

    extract-archive($archive, $staging);
    my $top = sole-child($staging);
    die "ariza: {$archive.basename} does not contain a runtime directory"
        unless $top.d;

    $top.rename($root);
    die "ariza: unpacking {$archive.basename} produced no $root" unless $root.d;
    $root
}

#| The bundled C<raku> interpreter inside an unpacked runtime.
method raku-bin(IO() $root, Str:D :$slug --> IO::Path) {
    $root.add('bin').add($slug.starts-with('windows') ?? 'raku.exe' !! 'raku')
}

#| The bundled C<zef> inside an unpacked runtime.
#|
#| This is the shell (or batch) wrapper shipped in the runtime's own site
#| repository, not a Raku script: it locates its sibling C<raku>
#| relocatably and execs it. Run it B<directly>. Handing it to
#| C<bin/raku> as a script is a syntax error, because it is C<sh>.
method zef-bin(IO() $root, Str:D :$slug --> IO::Path) {
    my $bin = $root.add('share').add('perl6').add('site').add('bin');
    $bin.add($slug.starts-with('windows') ?? 'zef.bat' !! 'zef')
}

#| Resolve, download, cache and unpack the pinned runtime into a bundle.
#|
#| Returns everything later stages need to know about it: the unpacked
#| root, the C<raku> and C<zef> entry points, the cached archive and its
#| digest, and the URL it came from (for the manifest).
method provision(
    IO() :$bundle-dir!,
    Str:D :$slug!,
    App::Ariza::Versions:D :$versions!,
    IO() :$cache-dir = self.cache-dir,
    Str :$url = INDEX-URL,
    :&fetch = &http-get,
    :&download = &http-download,
    --> Hash
) {
    my $version  = $versions.rakudo-version
        // die "ariza: {$versions.path} has no rakudo.version to bundle";
    my $revision = $versions.rakudo-revision
        // die "ariza: {$versions.path} has no rakudo.revision to bundle";

    # Before the network: a slug with no upstream build cannot be
    # satisfied by any index, and downloading 260KB of JSON to discover
    # that is both slow and a needless dependency on being online.
    self.index-platform($slug);

    my @entries = self.fetch-index(:$url, :&fetch);
    my %entry   = self.select-entry(@entries, :$slug, :$version, :$revision);
    my %got     = self.fetch-archive(%entry, :$cache-dir, :&download);
    my $root    = self.unpack(%got<archive>, $bundle-dir);

    my $raku = self.raku-bin($root, :$slug);
    my $zef  = self.zef-bin($root, :$slug);
    die "ariza: the unpacked runtime has no interpreter at $raku"
        unless $raku.f;
    die "ariza: the unpacked runtime has no zef wrapper at $zef"
        unless $zef.f;

    {
        root     => $root,
        raku     => $raku,
        zef      => $zef,
        archive  => %got<archive>,
        sha256   => %got<sha256>,
        cached   => %got<cached>,
        url      => %entry<url>,
        version  => $version,
        revision => $revision,
        tag      => "$version-$revision",
    }
}

=begin pod

=head1 NAME

App::Ariza::Rakudo - fetch, cache and unpack the Rakudo runtime a bundle embeds

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Rakudo;
use App::Ariza::Versions;

my %rt = App::Ariza::Rakudo.provision(
    :bundle-dir($work),
    :slug<macos-arm64>,
    :versions(App::Ariza::Versions.load),
);

say %rt<root>;      # …/moneymoor-0.2.0-macos-arm64/rakudo
say %rt<raku>;      # …/rakudo/bin/raku
say %rt<zef>;       # …/rakudo/share/perl6/site/bin/zef
say %rt<tag>;       # 2026.07-01
say %rt<sha256>;    # 9f3c…
say %rt<cached>;    # True on the second build

# The pieces, separately:
my @entries = App::Ariza::Rakudo.fetch-index;
my %entry   = App::Ariza::Rakudo.select-entry(@entries,
                  :slug<linux-x86_64-glibc>, :version<2026.07>, :revision<01>);
say %entry<url>;

=end code

=head1 DESCRIPTION

A bundle carries its own interpreter, so nothing about the user's
machine — whether Raku is installed, which version, which module
repositories are in the chain — can affect it. This module puts that
interpreter in the bundle.

The runtime is B<not> built: it is the official archive from
C<rakudo.org>, pinned in L<App::Ariza::Versions> by
C<[rakudo] version> and C<revision>, downloaded once and cached for
every subsequent build.

=head2 The release index

C<https://rakudo.org/dl/rakudo> serves a JSON array, one object per
downloadable file, covering every release since 2009. The fields that
matter are C<platform> (C<macos>, C<linux>, C<win>, C<src>), C<arch>,
C<ver>, C<build_rev>, C<type> (only C<archive> is a runtime; the rest
are signatures and checksum files) and C<url>.

Matching is exact on all five. A pin of C<2026.07> / C<01> selects
C<build_rev> C<1> and nothing else — never "the newest 2026.07", never
"whatever is C<latest>" — because the whole point of the pin is that two
builds a month apart embed the same bytes.

=head2 Which platforms can be bundled

rakudo.org publishes binaries for four of the eight slugs
L<App::Ariza::Platform> knows:

=item1 C<macos-arm64>, C<macos-x86_64>
=item1 C<linux-x86_64-glibc>
=item1 C<windows-x86_64>

The others — musl, Linux aarch64, Windows on ARM — are real platforms
with no upstream archive to embed. Asking for one dies naming the four
that work, rather than assembling a URL that will 404. Making one of
them bundleable means building a runtime and publishing it somewhere
this map can point at; it is not a code change here.

=head2 Caching: record, then verify

Archives land in C<$XDG_CACHE_HOME/ariza/rakudo> (C<~/.cache/…> when
that is unset), each beside a C<.sha256> sidecar written at download
time.

There is no upstream checksum to compare against — rakudo.org publishes
one, but fetching it only moves the trust boundary — so the digest is
B<recorded> on first download and B<verified> on every reuse. That
catches exactly the failure this cache can actually suffer: a file that
changed after it was written, because a process was killed mid-transfer
or a disk lied. A mismatch is not fatal; the cached copy is discarded,
noted on C<STDERR>, and re-downloaded.

Downloads themselves land in a C<.part> file and are renamed on success
(see L<App::Ariza::Tools>), so an interrupted transfer is never mistaken
for a cache hit. An archive that is present but has no sidecar — dropped
in by hand, or left by a much older run — is adopted: its digest is
recorded now and verified from then on.

=head1 METHODS

=head2 provision(:$bundle-dir!, :$slug!, :$versions!, :$cache-dir, :$url, :&fetch, :&download --> Hash)

The whole job: resolve the pin against the index, fetch or reuse the
archive, unpack it to C<< <bundle-dir>/rakudo >> (stripping the wrapper
directory), and verify that the two entry points later stages need
actually exist.

Returns C<root>, C<raku>, C<zef>, C<archive>, C<sha256>, C<cached>,
C<url>, C<version>, C<revision> and C<tag>.

=head2 fetch-index(:$url, :&fetch --> List)

The index, parsed. An unreachable host dies saying so explicitly —
"a bundle needs network access the first time it is built" — rather
than as a JSON parse error on an empty body.

=head2 select-entry(@entries, :$slug!, :$version!, :$revision! --> Hash)

The one matching archive entry. No match dies listing the most recent
versions the index does have for that platform, so a stale pin is
obvious. B<Two> matches also dies: upstream publishing two archives for
one platform, version and revision (a second toolchain, say) is a choice
that belongs in the pin file, not in a tiebreak here.

=head2 fetch-archive(%entry, :$cache-dir, :&download --> Hash)

Download or reuse. Returns C<archive>, C<sha256> and C<cached>.

=head2 unpack(IO() $archive, IO() $bundle-dir --> IO::Path)

Extract into C<< <bundle-dir>/rakudo >>, stripping the single top-level
directory the archive wraps everything in. Any existing C<rakudo/> is
replaced, so a rebuild into the same workdir is clean.

=head2 raku-bin(IO() $root, :$slug --> IO::Path) / zef-bin(IO() $root, :$slug --> IO::Path)

The interpreter and the C<zef> entry point inside an unpacked runtime
(C<.exe> / C<.bat> on Windows).

C<zef-bin> is a B<shell wrapper>, not a Raku script — it finds its
sibling C<raku> relocatably and execs it. Run it directly. Passing it to
C<bin/raku> as a script is a syntax error, because it is C<sh>.

=head2 cache-dir(--> IO::Path) / fetchable-slugs(--> List) / index-platform(Str --> Hash)

The cache root, the bundleable slugs, and a slug's index coordinates.

=head1 SEE ALSO

L<App::Ariza::Versions> for the pin, L<App::Ariza::Site> for what is
installed into the runtime once it is unpacked.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
