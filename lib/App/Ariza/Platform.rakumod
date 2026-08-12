unit module App::Ariza::Platform;

# Deliberately identical to Notcurses-Native's %PLATFORM-SLUGS (see that
# distribution's Build.rakumod). A bundle carries Notcurses-Native's
# prebuilt shared libraries, so the slug ariza builds under has to be the
# exact string that distribution's binary fetcher will look for later —
# any divergence here produces a bundle whose native libs silently fail to
# resolve on the target machine.
#
# Both `win32-` and `mswin32-` keys are present because `$*KERNEL.name`
# has historically reported either on Windows depending on the build.
#
# Typed `Str` so a missing-key lookup yields the `Str` type object rather
# than `Any`, which keeps `detect-slug`'s `--> Str` return constraint
# satisfiable and lets callers write `without $slug { ... }`.
my Str %PLATFORM-SLUGS =
    'darwin-arm64'          => 'macos-arm64',
    'darwin-x86_64'         => 'macos-x86_64',
    'linux-x86_64-glibc'    => 'linux-x86_64-glibc',
    'linux-x86_64-musl'     => 'linux-x86_64-musl',
    'linux-aarch64-glibc'   => 'linux-aarch64-glibc',
    'linux-aarch64-musl'    => 'linux-aarch64-musl',
    'win32-x86_64'          => 'windows-x86_64',
    'win32-aarch64'         => 'windows-arm64',
    'mswin32-x86_64'        => 'windows-x86_64',
    'mswin32-aarch64'       => 'windows-arm64',
;

#| The name of the environment variable that overrides platform
#| detection. Exported as a constant so tests and callers never spell it
#| as a bare string literal.
our constant PLATFORM-ENV = 'ARIZA_PLATFORM';

#| Every platform slug ariza knows how to name, sorted and deduplicated.
#| Two keys map to `windows-x86_64` and two to `windows-arm64`, so this is
#| shorter than the key map.
our sub known-slugs(--> List) is export {
    %PLATFORM-SLUGS.values.unique.sort.List
}

#| Every C<os-hardware[-libc]> key the slug map recognises, sorted. Useful
#| in diagnostics: it says which probe results ariza can name, which is a
#| different question from which slugs exist.
our sub known-platform-keys(--> List) is export {
    %PLATFORM-SLUGS.keys.sort.List
}

#| True if C<$slug> is one of C<known-slugs>.
our sub known-slug(Str $slug --> Bool) is export {
    $slug.defined && so %PLATFORM-SLUGS.values.first($slug)
}

#| The system glibc version from `ldd --version`, or an undefined
#| `Version` when `ldd` is absent, exits non-zero (musl's `ldd` does), or
#| prints something unparseable. Only meaningful on Linux.
our sub detect-glibc-version(--> Version) is export {
    my $proc = try { run 'ldd', '--version', :out, :err };
    return Version without $proc;
    my $out = $proc.out.slurp(:close);
    $proc.err.slurp(:close);
    return Version unless $proc.exitcode == 0;
    my $first = $out.lines.head // '';
    $first ~~ /(\d+ '.' \d+ [ '.' \d+ ]?) \s* $/
        ?? Version.new(~$0)
        !! Version
}

#| Detect the system C library. Probe order:
#|
#|   1. musl loader presence — a `ld-musl-*.so.1` file under `/lib` or
#|      `/usr/lib` is unambiguous.
#|   2. glibc, if `ldd --version` runs and reports a version.
#|
#| Returns the `Str` type object off Linux (there is no libc axis to
#| report), and also on a Linux system with neither loader visible —
#| uclibc, a statically-linked busybox image — which produces a platform
#| key the slug map has no entry for, and so an honest "unknown platform"
#| rather than a wrong guess.
#|
#| `:lib-dirs` and `:glibc-probe` exist so tests can drive every branch
#| without a container: the first replaces the directories searched for a
#| musl loader, the second replaces the `ldd` call with any callable
#| returning a `Version` or an undefined value.
our sub detect-libc(
    Str :$os = $*KERNEL.name.lc,
    :@lib-dirs = </lib /usr/lib>,
    :&glibc-probe = &detect-glibc-version,
    --> Str
) is export {
    return Str unless $os eq 'linux';
    for @lib-dirs -> $d {
        next unless $d.IO.d;
        return 'musl' if try {
            $d.IO.dir.first(*.basename.starts-with('ld-musl-'))
        };
    }
    return 'glibc' if glibc-probe().defined;
    Str
}

#| The C<os-hardware[-libc]> key that detection looks up. Linux keys carry
#| a libc suffix because glibc and musl need different binaries; every
#| other OS has no libc axis to disambiguate, so its key is just
#| C<os-hardware>.
our sub platform-key(
    Str :$os       = $*KERNEL.name.lc,
    Str :$hardware = $*KERNEL.hardware.lc,
    Str :$libc     = detect-libc(:$os),
    --> Str
) is export {
    $libc ?? "$os-$hardware-$libc" !! "$os-$hardware"
}

#| The platform slug for this machine, or the `Str` type object when the
#| probes produce a combination ariza has no slug for. Never dies — this
#| is the "ask politely" form, for callers that want to report an unknown
#| platform in their own words.
#|
#| The `ARIZA_PLATFORM` override still applies, and is still validated: an
#| override is the one input that is definitely a human mistake if it is
#| wrong, so a bad one dies even here.
our sub detect-slug(
    Str :$os       = $*KERNEL.name.lc,
    Str :$hardware = $*KERNEL.hardware.lc,
    Str :$libc     = detect-libc(:$os),
    Str :$override = %*ENV{PLATFORM-ENV} // Str,
    --> Str
) is export {
    with $override {
        my $trimmed = .trim;
        if $trimmed {
            die "ariza: {PLATFORM-ENV}='$trimmed' is not a platform ariza knows"
              ~ " (expected one of: {known-slugs.join(', ')})"
                unless known-slug($trimmed);
            return $trimmed;
        }
    }
    %PLATFORM-SLUGS{platform-key(:$os, :$hardware, :$libc)} // Str
}

#| The platform slug for this machine, dying with a diagnostic naming the
#| probe result and the supported set if there isn't one. This is the form
#| commands should use: a bundler that cannot name its own platform has
#| nothing useful left to do.
our sub current-slug(
    Str :$os       = $*KERNEL.name.lc,
    Str :$hardware = $*KERNEL.hardware.lc,
    Str :$libc     = detect-libc(:$os),
    Str :$override = %*ENV{PLATFORM-ENV} // Str,
    --> Str
) is export {
    my $slug = detect-slug(:$os, :$hardware, :$libc, :$override);
    return $slug if $slug.defined;
    my $key = platform-key(:$os, :$hardware, :$libc);
    die "ariza: unsupported platform '$key'"
      ~ " (ariza knows: {known-platform-keys.join(', ')});"
      ~ " set {PLATFORM-ENV} to force one of: {known-slugs.join(', ')}";
}

=begin pod

=head1 NAME

App::Ariza::Platform - name the machine ariza is building for

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Platform;

say current-slug;             # macos-arm64
say known-slugs;              # (linux-aarch64-glibc linux-aarch64-musl ...)

# Non-fatal form: Str type object instead of a die
without detect-slug() -> $ {
    say "no bundle for this box";
}

# Force a slug (cross-builds, CI matrices, tests):
%*ENV<ARIZA_PLATFORM> = 'linux-x86_64-musl';
say current-slug;             # linux-x86_64-musl

# Inject probe results instead of touching the real system:
say detect-slug(:os<linux>, :hardware<aarch64>, :libc<musl>, :override(Str));
# linux-aarch64-musl

=end code

=head1 DESCRIPTION

A self-contained bundle is only self-contained for I<one> platform, so
every artefact ariza produces is named after one. This module produces
that name and nothing else: it has no state, touches no configuration,
and its only side effects are reading C<$*KERNEL>, C<%*ENV>, C</lib>,
and (on Linux) running C<ldd --version>.

=head2 The slugs

=item1 C<macos-arm64>, C<macos-x86_64>
=item1 C<linux-x86_64-glibc>, C<linux-aarch64-glibc>
=item1 C<linux-x86_64-musl>, C<linux-aarch64-musl>
=item1 C<windows-x86_64>, C<windows-arm64>

These strings are B<not> ariza's to choose. They are exactly
Notcurses-Native's platform slugs, because a bundle ships that
distribution's prebuilt notcurses libraries and has to agree with it
about what platform it is on. If Notcurses-Native ever gains a slug,
this map gains it in the same shape.

=head2 Detection

The probe builds a key from C<$*KERNEL.name.lc> and
C<$*KERNEL.hardware.lc>, plus — on Linux only — a libc suffix, then
looks that key up:

=begin code :lang<console>

darwin-arm64          -> macos-arm64
linux-x86_64-glibc    -> linux-x86_64-glibc
linux-aarch64-musl    -> linux-aarch64-musl
mswin32-x86_64        -> windows-x86_64

=end code

Windows reports its kernel name as either C<win32> or C<mswin32>
depending on the build, so both keys are mapped.

The libc axis exists because a glibc binary does not run on Alpine and
a musl binary does not run on Debian. C<detect-libc> looks for a
C<ld-musl-*.so.1> loader under C</lib> or C</usr/lib> first (its
presence is conclusive), then falls back to parsing C<ldd --version>
for a glibc version. A Linux system with neither — uclibc, a static
busybox image — yields no libc, hence no matching key, hence an honest
"unsupported platform" rather than a bundle that will not run.

=head2 The ARIZA_PLATFORM override

Setting C<ARIZA_PLATFORM> to a known slug short-circuits all detection.
This is what makes cross-building and CI matrices possible, and what
lets this distribution's own tests exercise Linux and Windows paths on
a Mac.

An override that is I<not> a known slug is a hard error, in both
C<current-slug> and C<detect-slug>. Every other input to this module is
a system fact that might legitimately be something ariza cannot name;
an override is a human typing a string, and silently ignoring a
misspelled one would produce a bundle for the wrong platform. An empty
or whitespace-only value is treated as unset, so C<ARIZA_PLATFORM=>
in a shell profile does not wedge the tool.

=head1 SUBROUTINES

=head2 current-slug(:$os, :$hardware, :$libc, :$override --> Str)

The slug for this machine. Dies if there isn't one, with a message
naming the probed key, every key ariza recognises, and the override
that would force the issue.

=head2 detect-slug(:$os, :$hardware, :$libc, :$override --> Str)

Same, but returns the undefined C<Str> type object instead of dying on
an unknown platform. A bad C<ARIZA_PLATFORM> still dies.

=head2 detect-libc(:$os, :@lib-dirs, :&glibc-probe --> Str)

C<'musl'>, C<'glibc'>, or the undefined C<Str>. Off Linux, always the
undefined C<Str>. C<:@lib-dirs> and C<:&glibc-probe> replace the two
system probes, so every branch is reachable from a test on any host.

=head2 detect-glibc-version(--> Version)

The version C<ldd --version> reports, or an undefined C<Version>.

=head2 platform-key(:$os, :$hardware, :$libc --> Str)

The C<os-hardware[-libc]> string detection looks up. Exposed for
diagnostics.

=head2 known-slugs(--> List) / known-platform-keys(--> List) / known-slug(Str --> Bool)

The supported slugs, the recognised probe keys, and a membership test.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
