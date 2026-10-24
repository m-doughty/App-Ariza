use Config::TOML;

use App::Ariza::Resources;

unit class App::Ariza::Versions;

has Str  $.sqlcipher;
has Str  $.rakudo-version;
has Str  $.rakudo-revision;
has List $.rakudo-test-versions;
has      $.warnings = ();
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

# A Rakudo release as rakudo.org and Raku/setup-raku name it: `YYYY.MM`,
# or `YYYY.MM.N` for a point release (`2025.12.1`). A closed shape,
# because it is quoted straight into a workflow's matrix, and a typo
# there is a job that fails at setup-raku on every runner rather than
# a complaint here.
my constant RELEASE-SHAPE =
	/ ^ \d ** 4 '.' [ '0' <[1..9]> | '1' <[0..2]> ] [ '.' <[1..9]> \d* ]? $ /;

# `rakudo.test-versions`: every entry a release name, none twice, oldest
# first. The order is checked rather than trusted because it is what a
# rendered workflow's comment promises and the order its matrix jobs are
# listed in; a list that says otherwise is a list somebody edited in a
# hurry.
my sub as-test-versions(Str:D $key, $value --> List) {
	die-with-key($key, 'an array of strings')
		unless $value.defined && $value ~~ Positional;
	die "ariza: $key must not be empty (a test matrix with no Rakudo"
	  ~ " release in it runs nothing)"
		unless $value.elems;

	my @releases;
	for $value.list -> $elem {
		# TOML reads an unquoted 2026.07 as a number, so this is the
		# mistake a hand edit is most likely to make — and 2026.10 would
		# come through as 2026.1, which is why it is refused rather than
		# stringified.
		die-with-key($key, "an array of strings (got {$elem.raku}; quote"
						 ~ " every release, since a bare 2026.10 is the"
						 ~ " number 2026.1)")
			unless $elem.defined && $elem ~~ Str;
		die "ariza: $key entry '$elem' is not a Rakudo release (expected"
		  ~ " YYYY.MM or YYYY.MM.N, e.g. 2026.07 or 2025.12.1)"
			unless $elem ~~ RELEASE-SHAPE;
		@releases.push($elem.Str);
	}

	with @releases.repeated.head -> $twice {
		die "ariza: $key names '$twice' more than once (each entry is"
		  ~ " one matrix job per runner)";
	}

	for @releases.rotor(2 => -1) -> ($earlier, $later) {
		die "ariza: $key must list the oldest release first, but"
		  ~ " '$earlier' comes before '$later'"
			unless Version.new($earlier) before Version.new($later);
	}

	@releases.List
}

my sub parse-rakudo($value, %attrs, @warnings) {
	my %obj = as-hash('rakudo', $value);
	for %obj.kv -> $key, $v {
		next if $key.starts-with('//');
		given $key {
			when 'version'  { %attrs<rakudo-version>  = as-str('rakudo.version', $v); }
			when 'revision' { %attrs<rakudo-revision> = as-str('rakudo.revision', $v); }
			when 'test-versions' {
				%attrs<rakudo-test-versions> =
					as-test-versions('rakudo.test-versions', $v);
			}
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
say $v.rakudo-test-versions;                 # (2026.07 2026.09)   (test.yml's matrix)
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
test-versions = ["2026.07", "2026.09"]

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

=head2 The Rakudo a bundle embeds is not the Rakudo an app is tested on

C<[rakudo]> carries a third key, C<test-versions>, that has nothing to
do with the other two. C<version> and C<revision> name the one runtime a
bundle ships; C<test-versions> names every Rakudo release an app's own
suite has to pass on, and C<ariza scaffold-ci> renders it as the
C<raku-version> axis of the generated C<test.yml>'s matrix:

=begin code :lang<yaml>

      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        raku-version: ['2026.07', '2026.09']

=end code

The two move for different reasons. The embedded runtime changes when a
bundle should ship a newer one; the tested set changes when a release
stops being worth supporting, or a new one — a new compiler frontend,
say — becomes the one users are upgrading to. A user who installed Raku
themselves may be on the older of them for a long time, so both stay in
the matrix until the older one is dropped here on purpose.

This key is B<strict> where the others are not, because every entry
becomes a CI job on every runner. It must be a non-empty array of
strings, each a Rakudo release name — C<YYYY.MM>, or C<YYYY.MM.N> for a
point release (C<2026.07>, C<2025.12.1>) — with none repeated, listed
oldest first. Anything else dies naming C<rakudo.test-versions>:

=begin code :lang<console>

ariza: rakudo.test-versions must be an array of strings
ariza: rakudo.test-versions must not be empty (a test matrix with no Rakudo release in it runs nothing)
ariza: rakudo.test-versions must be an array of strings (got 2026.07; quote every release, since a bare 2026.10 is the number 2026.1)
ariza: rakudo.test-versions entry '2026.7' is not a Rakudo release (expected YYYY.MM or YYYY.MM.N, e.g. 2026.07 or 2025.12.1)
ariza: rakudo.test-versions names '2026.07' more than once (each entry is one matrix job per runner)
ariza: rakudo.test-versions must list the oldest release first, but '2026.09' comes before '2026.07'

=end code

The quoting rule is the one most likely to bite: TOML reads an unquoted
C<2026.10> as the number C<2026.1>, so a bare number is refused rather
than turned back into a string that names a different release.

An B<absent> C<test-versions> is not an error here, any more than an
absent C<version> is — every pin in this file is optional to the parser,
and comes back undefined. It is L<App::Ariza::CI> that refuses to
render without one, because a C<test.yml> with no Rakudo in its matrix
tests nothing.

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

=head2 rakudo-test-versions(--> List)

C<rakudo.test-versions>, as a C<List> of release-name strings in file
order — oldest first, which is enforced at load time. The undefined
C<List> type object when the key is absent: never an empty list, since
an empty array in the file dies rather than loading. The rules are
B<The Rakudo a bundle embeds is not the Rakudo an app is tested on>,
above.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
