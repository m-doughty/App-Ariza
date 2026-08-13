use App::Ariza::Resources;
use App::Ariza::Tools;

unit class App::Ariza::Runner;

my constant TAG-RESOURCE  = 'RUNNER_VERSION';
my constant PINS-RESOURCE = 'runner-checksums.txt';

#| Where a runner release lives. ariza's own repository, because the
#| runner is ariza's own artefact — the only binary in this distribution
#| that is not somebody else's software.
our constant RELEASE-BASE =
    'https://github.com/m-doughty/App-Ariza/releases/download';

# Platform slug -> the architecture the published artefact is named
# after. Deliberately partial: a slug with no entry is a platform with no
# runner, which is every non-Windows one and is not an error anywhere.
my constant %ARCH =
    'windows-x86_64' => 'x86_64',
    'windows-arm64'  => 'aarch64',
;

# The bootstrap notice is per-process, not per-bundle: a `for` loop over
# four platforms should say it once, not four times.
my $bootstrap-warned = False;

# runner-v2 is the first native launcher that understands the authenticated
# update handoff protocol.  A staged executable is not sufficient evidence:
# runner-v1 launches the coordinator but would simply return its reserved 75
# after a successful install instead of relaunching managed `current`.
method update-handoff-capable(Mu $tag --> Bool:D) {
    return False unless $tag.defined;
    my $match = $tag ~~ /^ 'runner-v' (<[0..9]>+) $/;
    $match.defined && +$match[0] >= 2
}

#| The architecture a slug's runner is built for, or the undefined
#| C<Str> for a platform that has none.
method arch-for(Str:D $slug --> Str) { %ARCH{$slug} // Str }

#| The published artefact's filename for a slug, or the undefined C<Str>.
method artifact-name(Str:D $slug --> Str) {
    my $arch = self.arch-for($slug);
    $arch.defined ?? "ariza-runner-windows-$arch.exe" !! Str
}

#| The release tag the pinned runner comes from, from
#| C<resources/RUNNER_VERSION>. The undefined C<Str> when that file is
#| empty, which is one half of the bootstrap state below.
method tag(--> Str) {
    my $text = resource(TAG-RESOURCE).slurp.trim;
    $text.chars ?? $text !! Str
}

#| The recorded digests, as C<< artefact => sha256 >>.
#|
#| Blank lines and C<#> comments are ignored; every other line has to be
#| C<< <64 hex>  <filename> >>. A line that is not dies naming the file
#| and the line, rather than being skipped — a skipped pin is an
#| unverified download, and this file exists to make that impossible.
#|
#| C<slurp> and then split, never C<< $path.lines >>. That reads the
#| whole file and closes the handle before a single line is examined,
#| which matters because this method's contract is to B<die> part way
#| through a malformed file: C<< IO::Path.lines >> hands back a lazy
#| sequence whose handle is closed when the sequence is exhausted, and
#| a C<die> on line two of ten exhausts nothing. On POSIX the leaked
#| handle is invisible; on Windows the file cannot then be deleted at
#| all — C<Failed to delete file: resource busy or locked> — so a caller
#| that cleans up after itself fails instead of the parse it was
#| testing. A pin file is a few hundred bytes; there is nothing to
#| stream.
method pins(IO() $path = resource(PINS-RESOURCE) --> Hash) {
    my %pins;
    for $path.slurp.lines.kv -> $i, $line {
        my $text = $line.trim;
        next unless $text.chars;
        next if $text.starts-with('#');
        my $m = $text ~~ / ^ (<[0..9a..fA..F]> ** 64) \s+ (\S+) $ /;
        die "ariza: {$path.basename} line {$i + 1} is neither a comment nor"
          ~ " a `<sha256>  <artefact>` entry: $text"
            unless $m;
        %pins{~$m[1]} = (~$m[0]).lc;
    }
    %pins
}

#| The download URL for a slug's runner.
method url(Str:D :$slug!, Str :$tag = self.tag --> Str) {
    my $name = self.artifact-name($slug)
        // die "ariza: no runner is published for '$slug'";
    die "ariza: no runner release tag in resources/{TAG-RESOURCE}"
        unless $tag.defined && $tag.chars;
    "{RELEASE-BASE}/$tag/$name"
}

#| The download cache root: C<$XDG_CACHE_HOME/ariza/runner>, falling
#| back to C<~/.cache> as the XDG spec requires. Keyed by tag inside, so
#| two ariza versions on one machine never hand each other's runner to a
#| bundle.
method cache-dir(--> IO::Path) {
    my $base = %*ENV<XDG_CACHE_HOME> || $*HOME.add('.cache').absolute;
    $base.IO.add('ariza').add('runner')
}

#| Download a slug's runner into the cache, or reuse the cached copy,
#| and return the verified file.
#|
#| Verification is not optional and has no skip path: this is an
#| executable that will be run on a user's machine, so a copy that does
#| not hash to the pin is deleted and the build stops.
method fetch(
    Str:D :$slug!,
    IO() :$cache-dir = self.cache-dir,
    :%pins = self.pins,
    Str :$tag = self.tag,
    :&download = &http-download,
    --> IO::Path
) {
    my $name = self.artifact-name($slug)
        // die "ariza: no runner is published for '$slug'";
    my $want = %pins{$name}
        // die "ariza: {PINS-RESOURCE} records no digest for $name"
             ~ " — a runner that cannot be verified is not one to ship";

    my $dir  = ensure-dir(ensure-dir($cache-dir).add($tag));
    my $file = $dir.add($name);

    if $file.f {
        my $have = sha256-file($file);
        return $file if $have eq $want;
        # A cached executable that no longer matches its pin is either a
        # half-written download or something that changed under us.
        # Either way it is not the file the pin describes.
        note "ariza: cached $name failed its recorded digest, re-downloading";
        $file.unlink;
    }

    download(self.url(:$slug, :$tag), $file);

    my $have = sha256-file($file);
    unless $have eq $want {
        $file.unlink;
        die "ariza: the runner downloaded for $slug does not match its pin\n"
          ~ "    expected  $want\n"
          ~ "    got       $have\n"
          ~ "    from      {self.url(:$slug, :$tag)}";
    }
    $file
}

#| Stage the runner into C<< <bundle>/bin/<exec>.exe >> and return what
#| was staged — C<{ path, artifact, tag, url, sha256 }> — or an empty
#| hash when this bundle gets none.
#|
#| The hash rather than the path alone, because the manifest records
#| every downloaded component with the URL it came from and the digest
#| it was verified against, and the runner is a downloaded component:
#| the one binary in a bundle a reader could otherwise not trace back to
#| a published artefact.
#|
#| Two ways to get nothing back, and they are not the same thing:
#|
#| =item A non-Windows platform, silently — there is nothing to stage.
#|
#| =item Windows, with no pins recorded yet: the bundle is built with
#| its C<.cmd> and C<.ps1> launchers alone and a loud one-off notice
#| explains why. That is the bootstrap state, and it ends the moment a
#| runner release is published and its checksums are committed.
method stage(
    IO() :$bundle-dir!,
    Str:D :$slug!,
    Str:D :$exec!,
    IO() :$cache-dir = self.cache-dir,
    IO() :$pins-path,
    :&download = &http-download,
    --> Hash
) {
    return %() unless self.arch-for($slug).defined;

    my $tag  = self.tag;
    my %pins = $pins-path.defined ?? self.pins($pins-path) !! self.pins;

    unless $tag.defined && %pins {
        unless $bootstrap-warned {
            $bootstrap-warned = True;
            note "ariza: no pinned runner build yet, so this Windows bundle"
               ~ " ships without bin/$exec.exe.\n"
               ~ "    The .cmd and .ps1 launchers are there and work; what is"
               ~ " missing is the compiled\n"
               ~ "    entry point that survives script-execution policy and"
               ~ " passes arguments through\n"
               ~ "    verbatim. Publish a {$tag // 'runner'} release from"
               ~ " runner/ and record its checksums\n"
               ~ "    in resources/{PINS-RESOURCE} to turn it on.";
        }
        return %();
    }

    my $name = self.artifact-name($slug);
    my $src  = self.fetch(:$slug, :$cache-dir, :%pins, :$tag, :&download);
    my $dst  = ensure-dir($bundle-dir.add('bin')).add("$exec.exe");

    %(
        path     => copy-writable($src, $dst),
        artifact => $name,
        tag      => $tag,
        url      => self.url(:$slug, :$tag),
        sha256   => %pins{$name},
    )
}

=begin pod

=head1 NAME

App::Ariza::Runner - the compiled launcher a Windows bundle starts from

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Runner;

say App::Ariza::Runner.artifact-name('windows-arm64');
# ariza-runner-windows-aarch64.exe

say App::Ariza::Runner.tag;                     # runner-v1
say App::Ariza::Runner.pins.keys;               # the artefacts pinned

# What App::Ariza::Launcher does for a Windows bundle:
my %r = App::Ariza::Runner.stage(
    :bundle-dir($work), :slug<windows-x86_64>, :exec<moneymoor>);
say %r ?? "{%r<path>} ({%r<sha256>})" !! 'no runner pinned yet — scripts only';

=end code

=head1 DESCRIPTION

A Windows bundle's documented entry point is C<< bin/<exec>.exe >>: a
small C program, in this repository's C<runner/> directory, that reads
C<< bin/<exec>.ariza >> beside itself, exports the same environment the
C<.cmd> launcher exports, and starts the bundled interpreter with the
caller's arguments B<unchanged>.

This module is the build-time half of that: which artefact a platform
gets, where it is published, and the verification a downloaded
executable has to pass before it is allowed anywhere near a bundle.

=head2 Why a fetched binary rather than a compiled one

Compiling the runner during C<ariza bundle> would put a C toolchain in
the bundling path — on every machine, for every cross-build — to produce
a file that is identical for every app. So it is built once per release
by CI, on the toolchains that build everything else Windows in this
ecosystem (MSYS2 UCRT64 for x86_64, CLANGARM64 for aarch64), published
as a release artefact, and pinned by digest here. A bundle carries a
byte-identical, hash-verified copy of a binary anyone can rebuild from
C<runner/> and compare.

=head2 The bootstrap ladder

C<resources/runner-checksums.txt> starts empty, because the code that
downloads a runner has to exist before the release it downloads can be
published. So:

=item1 B<No pins recorded.> A Windows bundle is built without the
executable — the C<.cmd> and C<.ps1> launchers alone, exactly the output
ariza produced before the runner existed — and the build says so once,
loudly, naming the file to fill in.

=item1 B<Any pin recorded.> The ladder inverts. A missing entry for the
target architecture, a failed download, or a digest mismatch B<fails the
build>. Past that point a bundle without a verified runner is a
regression rather than a stage of bootstrapping, and shipping one
quietly would be the worst of both.

There is deliberately no third rung, no C<--no-runner> and no
C<--skip-verify>: the two states above are the only two that are ever
true, and an unverified executable staged into a bundle is not a
degraded build, it is a different piece of software.

=head1 METHODS

=head2 stage(:$bundle-dir!, :$slug!, :$exec!, :$cache-dir, :$pins-path, :&download --> Hash)

Put the runner at C<< <bundle>/bin/<exec>.exe >> and return
C<{ path, artifact, tag, url, sha256 }>. Returns an B<empty hash> for a
non-Windows platform (nothing to stage) and for the bootstrap state
above (nothing pinned yet), so C<if %r { ... }> is the whole test.

The extra fields are there because C<ariza-manifest.json> records every
downloaded component with its source URL and its verified digest, and
the runner is a downloaded component — the one binary in a bundle a
reader could otherwise not trace back to a published artefact.

C<:$pins-path> reads an alternate pin file, which is what lets a test
exercise both rungs of the ladder — and every way the upper one fails —
against the same code the shipped resource goes through.

=head2 fetch(:$slug!, :$cache-dir, :%pins, :$tag, :&download --> IO::Path)

The cached, digest-verified artefact for a slug, downloading it if this
machine has not got it. A cached copy that fails its pin is deleted and
re-fetched; a fresh download that fails its pin is deleted and the build
stops. C<:&download> is the same seam L<App::Ariza::Rakudo> takes, so
the whole path is testable without a network.

=head2 pins(IO() $path --> Hash)

C<< artefact => sha256 >> from C<resources/runner-checksums.txt>.
Comments and blank lines are ignored; anything else must be a
C<< <64 hex>  <filename> >> entry, and a line that is not dies naming
the file and the line number.

=head2 tag(--> Str) / url(:$slug!, :$tag --> Str) / cache-dir(--> IO::Path)

The release tag from C<resources/RUNNER_VERSION>, the download URL built
from it, and C<$XDG_CACHE_HOME/ariza/runner> (keyed by tag inside, so
two tags never share a file).

=head2 arch-for(Str $slug --> Str) / artifact-name(Str $slug --> Str)

C<windows-x86_64> is C<x86_64> and C<windows-arm64> is C<aarch64>;
everything else is the undefined C<Str>, which is how "this platform has
no runner" is spelled everywhere in this module.

=head2 update-handoff-capable(Mu $tag --> Bool)

True only for an exact C<runner-vN> tag whose numeric C<N> is at least 2.
C<runner-v2> is the first native launcher that can create, validate and honor
the authenticated managed-update handoff; an update-enabled Windows build
must not infer capability merely because some executable was staged.

=head1 SEE ALSO

L<App::Ariza::Launcher>, which calls this and writes the sidecar the
runner reads.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
