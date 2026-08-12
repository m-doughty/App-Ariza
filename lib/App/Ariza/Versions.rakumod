use Config::TOML;

use App::Ariza::Resources;

unit class App::Ariza::Versions;

has Str $.sqlcipher;
has Str $.rakudo-version;
has Str $.rakudo-revision;
has     $.warnings = ();
has IO::Path $.path;

my sub die-with-key(Str:D $key, Str:D $expected) {
    die "ariza: $key must be $expected";
}

my sub as-str(Str:D $key, $value --> Str) {
    die-with-key($key, 'a string') unless $value.defined && $value ~~ Str;
    $value.Str
}

my sub as-hash(Str:D $key, $value) {
    die-with-key($key, 'a table') unless $value.defined && $value ~~ Associative;
    $value
}

my sub parse-rakudo($value, %attrs, @warnings) {
    my %obj = as-hash('rakudo', $value);
    for %obj.kv -> $key, $v {
        next if $key.starts-with('//');
        given $key {
            when 'version'  { %attrs<rakudo-version>  = as-str('rakudo.version', $v); }
            when 'revision' { %attrs<rakudo-revision> = as-str('rakudo.revision', $v); }
            default {
                @warnings.push("unknown key 'rakudo.$key' in versions.toml (ignored)");
            }
        }
    }
}

#| Load the pin file. With no argument this is ariza's own shipped
#| `resources/versions.toml`, which is the only sensible source in
#| production; the argument exists for tests and for anyone wanting to
#| render against an alternate pin set.
method load(App::Ariza::Versions:U: IO() $path = resource('versions.toml') --> App::Ariza::Versions) {
    die "ariza: no versions file at $path" unless $path.f;

    my $content = do {
        CATCH { default { die "ariza: could not read $path: {.message}" } }
        $path.slurp;
    };

    # An empty document is valid TOML — an empty table — but Config::TOML
    # rejects it outright, which would report a perfectly legal (if
    # useless) pin file as malformed. Short-circuit before it gets there.
    my $data = $content.trim
        ?? do {
            CATCH { default { die "ariza: malformed TOML in $path: {.message}" } }
            from-toml($content);
        }
        !! {};

    die "ariza: $path must contain a TOML table"
        unless $data.defined && $data ~~ Associative;

    my @warnings;
    my %attrs;

    for $data.kv -> $key, $value {
        next if $key.starts-with('//');
        given $key {
            when 'sqlcipher' { %attrs<sqlcipher> = as-str($key, $value); }
            when 'rakudo'    { parse-rakudo($value, %attrs, @warnings); }
            default {
                @warnings.push("unknown key '$key' in versions.toml (ignored)");
            }
        }
    }

    App::Ariza::Versions.new(|%attrs, :$path, :warnings(@warnings.List));
}

#| The embedded Rakudo runtime's full identity, `version-revision` — e.g.
#| `2026.07-01`. Undefined `Str` if either half is missing, since half an
#| identity names nothing.
method rakudo-tag(--> Str) {
    return Str unless $!rakudo-version.defined && $!rakudo-revision.defined;
    "{$!rakudo-version}-{$!rakudo-revision}"
}

=begin pod

=head1 NAME

App::Ariza::Versions - the pinned component versions every ariza artefact is built against

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Versions;

my $v = App::Ariza::Versions.load;          # ariza's shipped resources/versions.toml

say $v.rakudo-version;                       # 2026.07   (bundled runtime)
say $v.rakudo-revision;                      # 01
say $v.rakudo-tag;                           # 2026.07-01
say $v.sqlcipher;                            # 4.14.0    (advisory — see below)

.note for $v.warnings;                       # unrecognised keys, if any

# An alternate pin set (tests, experiments):
my $alt = App::Ariza::Versions.load('/tmp/versions.toml'.IO);

=end code

=head1 DESCRIPTION

Everything ariza produces — a bundle, a generated installer, a CI
workflow — quotes version numbers of software ariza does not own: a
Rakudo release, a SQLCipher build. Those numbers live in exactly one
file, C<resources/versions.toml>, so that bumping a pin regenerates
every app's artefacts in lockstep and nothing can drift.

This class is that file, parsed. It holds no logic beyond parsing:
consumers ask it for a string and put the string where it belongs.

=head1 THE FILE

=begin code :lang<toml>

sqlcipher = "4.14.0"

[rakudo]
version  = "2026.07"
revision = "01"

=end code

=head2 The SQLCipher pin is advisory

C<sqlcipher> is the version ariza B<expects>, not one it can enforce. A
bundle's SQLCipher comes from the build machine's package manager
(L<App::Ariza::Native>) — there is no ariza-operated mirror, because
SQLCipher's ABI does not move often enough to justify release
infrastructure of its own — and a package manager ships what it ships.
So a staged library whose version differs from this pin B<warns> and the
build continues, and the manifest records the version that was actually
staged with the pin alongside it.

=head2 One flat pin, one nested

C<sqlcipher> and C<[rakudo]> are not shaped the same, and the shapes are
not interchangeable:

=item1 C<sqlcipher> is a flat pin — a single string, compared against
whatever the build machine's package manager actually staged. See above.

=item1 C<[rakudo]> is a table, because the runtime a bundle embeds needs
two coordinates, C<version> and C<revision>, not one. C<revision>
disambiguates rebuilds of the same upstream release — a repackaged
runtime, a patched MoarVM — without pretending upstream cut a new
version. C<rakudo-tag> joins the two as C<version-revision>.

=head2 Unknown keys warn; wrong types die

The house rule, shared with L<App::Ariza::Config> and
L<App::Shigur::Config>: an unrecognised key at any level is collected
into C<warnings> and parsing continues, so a pin file written for a
newer ariza still loads in an older one (and vice versa). A key whose
I<value> is the wrong type dies immediately, naming the dotted path and
the expected shape — C<"ariza: rakudo.version must be a string"> —
because a mistyped pin would otherwise be silently baked into an
artefact.

Keys beginning with C<//> are ignored entirely, without a warning. TOML
has real comments, so this convention is redundant here; it is kept
because every ariza config file behaves the same way, and a config
author should never have to remember which file format they are in.

=head1 METHODS

=head2 load(IO() $path = resource('versions.toml') --> App::Ariza::Versions)

Parse a pin file. The default is ariza's own shipped copy, located
through L<App::Ariza::Resources> so it works installed and from a
checkout alike.

Dies if the file is missing, unreadable, not valid TOML, or not a TOML
table — each with its own message naming the path, so an unreadable
file is never confused with a malformed one.

An empty (or whitespace-only) file is B<not> an error: an empty
document is a valid, empty TOML table, and every pin comes back
undefined. Config::TOML rejects it outright, so C<load> short-circuits
before handing it over rather than reporting a legal file as malformed.

=head2 warnings(--> List)

Human-readable strings naming every unrecognised key found while
loading. Empty when the file was clean.

=head2 path(--> IO::Path)

The file this instance was loaded from. Useful in error messages from
consumers ("pin X missing from {$v.path}").

=head2 sqlcipher

The flat top-level pin, as a string. Undefined C<Str> if absent from the
file.

=head2 rakudo-version / rakudo-revision / rakudo-tag

The C<[rakudo]> table's two keys, and the C<version-revision> join of
them. C<rakudo-tag> is the undefined C<Str> unless both halves are
present.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
