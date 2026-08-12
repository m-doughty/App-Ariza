use Config::TOML;

use App::Ariza::Platform;

unit class App::Ariza::Config;

has Str  $.app-name;
has Str  $.app-exec;
has Str  $.app-display;
has      $.bundle-platforms = ();
has      $.bundle-native = ();
has      $.bundle-smoke;
has Str  $.installer-repo;
has Str  $.ci-ariza-source;
has      $.warnings = ();
has IO::Path $.path;

my sub die-with-key(Str:D $key, Str:D $expected) {
    die "ariza: $key must be $expected";
}

my sub as-str(Str:D $key, $value --> Str) {
    die-with-key($key, 'a string') unless $value.defined && $value ~~ Str;
    $value.Str
}

my sub as-str-list(Str:D $key, $value --> List) {
    die-with-key($key, 'an array of strings') unless $value.defined && $value ~~ Positional;
    for $value.list -> $elem {
        die-with-key($key, 'an array of strings') unless $elem.defined && $elem ~~ Str;
    }
    (|$value,).List
}

my sub as-hash(Str:D $key, $value) {
    die-with-key($key, 'a table') unless $value.defined && $value ~~ Associative;
    $value
}

# `bundle.smoke` is one of:
#
#   "moneymoor --version"                 one command, whitespace-split
#   ["a --flag", ["b", "-e", "code"]]     several, each split or verbatim
#
# The nested-array form exists so a command containing spaces, quotes or
# a whole Raku program can be written as argv and never go near a shell.
my constant SMOKE-SHAPE =
    'a string, or an array whose entries are strings or arrays of strings';

my sub as-smoke(Str:D $key, $value) {
    return $value if $value ~~ Str;
    die-with-key($key, SMOKE-SHAPE) unless $value.defined && $value ~~ Positional;
    for $value.list -> $entry {
        next if $entry ~~ Str;
        die-with-key($key, SMOKE-SHAPE) unless $entry.defined && $entry ~~ Positional;
        die "ariza: $key contains an empty command" unless $entry.list;
        for $entry.list -> $word {
            die-with-key($key, SMOKE-SHAPE) unless $word.defined && $word ~~ Str;
        }
    }
    $value
}

my sub parse-app($value, %attrs, @warnings) {
    my %obj = as-hash('app', $value);
    for %obj.kv -> $key, $v {
        next if $key.starts-with('//');
        given $key {
            when 'name'    { %attrs<app-name>    = as-str('app.name', $v); }
            when 'exec'    { %attrs<app-exec>    = as-str('app.exec', $v); }
            when 'display' { %attrs<app-display> = as-str('app.display', $v); }
            default {
                @warnings.push("unknown key 'app.$key' in ariza.toml (ignored)");
            }
        }
    }
}

my sub parse-bundle($value, %attrs, @warnings) {
    my %obj = as-hash('bundle', $value);
    for %obj.kv -> $key, $v {
        next if $key.starts-with('//');
        given $key {
            when 'platforms' {
                my @slugs = as-str-list('bundle.platforms', $v);
                # A misspelled slug is not a forward-compatibility
                # problem — the supported set is a closed enumeration of
                # what ariza itself can build — and silently dropping it
                # would ship a release quietly missing a platform. Fail
                # at load time instead, naming the whole set.
                for @slugs -> $slug {
                    die "ariza: bundle.platforms contains unknown platform '$slug'"
                      ~ " (expected one of: {known-slugs.join(', ')})"
                        unless known-slug($slug);
                }
                %attrs<bundle-platforms> = @slugs;
            }
            when 'native' { %attrs<bundle-native> = as-str-list('bundle.native', $v); }
            when 'smoke'  { %attrs<bundle-smoke>  = as-smoke('bundle.smoke', $v); }
            default {
                @warnings.push("unknown key 'bundle.$key' in ariza.toml (ignored)");
            }
        }
    }
}

# A GitHub `owner/name`, and nothing else: it is interpolated straight
# into three URLs, so anything that is not that shape produces a 404 at
# the one moment a user is least equipped to debug it.
my constant REPO-SHAPE = / ^ <[\w.-]>+ '/' <[\w.-]>+ $ /;

my sub parse-installer($value, %attrs, @warnings) {
    my %obj = as-hash('installer', $value);
    for %obj.kv -> $key, $v {
        next if $key.starts-with('//');
        given $key {
            when 'repo' {
                my $repo = as-str('installer.repo', $v);
                # A closed shape, like a platform slug: a typo here cannot
                # be a future feature, and the failure it causes lands on
                # a stranger's machine rather than on the author's.
                die "ariza: installer.repo must look like 'owner/name'"
                  ~ " (got '$repo')"
                    unless $repo ~~ REPO-SHAPE;
                %attrs<installer-repo> = $repo;
            }
            default {
                @warnings.push("unknown key 'installer.$key' in ariza.toml (ignored)");
            }
        }
    }
}

my sub parse-ci($value, %attrs, @warnings) {
    my %obj = as-hash('ci', $value);
    for %obj.kv -> $key, $v {
        next if $key.starts-with('//');
        given $key {
            when 'ariza-source' {
                my $src = as-str('ci.ariza-source', $v).trim;
                # Not a closed set — anything `zef install` accepts is
                # valid, and naming them here would date badly — but an
                # empty one renders `zef install --/test` with nothing to
                # install, which is a workflow that succeeds at nothing.
                die "ariza: ci.ariza-source must not be empty"
                  ~ " (use \"fez\", or a URL zef can install from)"
                    unless $src.chars;
                %attrs<ci-ariza-source> = $src;
            }
            default {
                @warnings.push("unknown key 'ci.$key' in ariza.toml (ignored)");
            }
        }
    }
}

#| Load `ariza.toml` from an app's repository. `$dir` is the repository
#| root; the filename is fixed.
method load(App::Ariza::Config:U: IO() $dir = $*CWD --> App::Ariza::Config) {
    self.load-file($dir.add('ariza.toml'));
}

#| Load a config from an exact path, for callers that keep the file
#| somewhere other than the repository root (tests, mostly).
method load-file(App::Ariza::Config:U: IO() $path --> App::Ariza::Config) {
    die "ariza: no ariza.toml at $path" unless $path.f;

    my $content = do {
        CATCH { default { die "ariza: could not read $path: {.message}" } }
        $path.slurp;
    };

    # An empty document is valid TOML — an empty table — but Config::TOML
    # rejects it outright. Short-circuit so an empty manifest fails the
    # honest way, on its missing required keys, rather than as "malformed".
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
            when 'app'       { parse-app($value, %attrs, @warnings); }
            when 'bundle'    { parse-bundle($value, %attrs, @warnings); }
            when 'installer' { parse-installer($value, %attrs, @warnings); }
            when 'ci'        { parse-ci($value, %attrs, @warnings); }
            default {
                @warnings.push("unknown key '$key' in ariza.toml (ignored)");
            }
        }
    }

    for <app.name app.exec app.display> -> $required {
        my $attr = $required.subst('.', '-');
        die "ariza: $required is required in $path" unless %attrs{$attr}.defined;
    }

    App::Ariza::Config.new(|%attrs, :$path, :warnings(@warnings.List));
}

#| Every configured smoke command as raw (unexpanded) argv, in order.
#|
#| A string entry is split on whitespace; an array entry is taken word
#| for word. Empty entries are dropped rather than run.
method smoke-argvs(--> List) {
    return () without $!bundle-smoke;
    my @entries = $!bundle-smoke ~~ Str ?? ($!bundle-smoke,) !! $!bundle-smoke.list;
    my @argvs = @entries.map({
        $_ ~~ Str ?? .words.List !! .list.map(*.Str).List
    }).grep(*.elems);
    @argvs.List
}

#| Every smoke command as argv, with C<{placeholder}> substitutions
#| applied. C<{exec}> always resolves to the app's executable name unless
#| the caller overrides it; other names are whatever the caller supplies
#| (L<App::Ariza::Smoke> supplies real paths into an unpacked bundle).
#|
#| A placeholder with no value left after substitution is an error rather
#| than an empty string: a smoke command with a hole in it would "pass"
#| by running something entirely different.
method smoke-commands(*%vars --> List) {
    my %all = exec => $!app-exec // '', |%vars;
    # Built eagerly, into an Array: a lazy `.map` would defer the
    # unknown-placeholder check until the caller happened to consume the
    # result, which is outside whatever `try` they wrapped this in.
    my @commands;
    for self.smoke-argvs -> @argv {
        my @words;
        for @argv -> $word {
            my $out = $word;
            $out = $out.subst("\{$_\}", ~%all{$_}, :g) for %all.keys;
            die "ariza: bundle.smoke has an unknown placeholder in '$word'"
              ~ " (known: {%all.keys.sort.map({ "\{$_\}" }).join(', ')})"
                if $out ~~ / '{' <[a..z-]>+ '}' /;
            @words.push($out);
        }
        @commands.push(@words.List);
    }
    @commands.List
}

#| The first smoke command as a single display string, with C<{exec}>
#| expanded, or the undefined C<Str> when none is configured. This is for
#| showing a human what will run; C<smoke-commands> is for running it.
method smoke-command(--> Str) {
    my @argvs = self.smoke-argvs;
    return Str unless @argvs;
    @argvs[0].map({ .subst('{exec}', $!app-exec // '', :g) }).join(' ')
}

=begin pod

=head1 NAME

App::Ariza::Config - the per-app C<ariza.toml> manifest

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Config;

my $cfg = App::Ariza::Config.load('/path/to/App-Moneymoor'.IO);

say $cfg.app-name;            # App::Moneymoor
say $cfg.app-exec;            # moneymoor
say $cfg.app-display;         # Moneymoor
say $cfg.bundle-platforms;    # (macos-arm64 linux-x86_64-glibc windows-x86_64)
say $cfg.bundle-native;       # (notcurses sqlcipher)
say $cfg.installer-repo;      # m-doughty/App-Moneymoor
say $cfg.ci-ariza-source;     # fez  (or a URL zef can install from)
say $cfg.smoke-command;       # moneymoor --version

# Every smoke command as argv, with paths substituted in:
.say for $cfg.smoke-commands(:exec($launcher), :raku($raku), :tmp($scratch));
# (/…/bin/moneymoor --version)
# (/…/rakudo/bin/raku -e use App::Moneymoor::DB; … /…/scratch)

.note for $cfg.warnings;      # unrecognised keys, if any

=end code

=head1 DESCRIPTION

C<ariza.toml> lives in the B<app's> repository, not in ariza's. It is
how an application declares what it is and what a bundle of it needs,
so that ariza stays a general tool rather than a list of special cases
about specific apps.

=head1 THE V1 SCHEMA

=begin code :lang<toml>

[app]
name = "App::Moneymoor"      # dist name
exec = "moneymoor"           # launcher/binary name
display = "Moneymoor"

[bundle]
platforms = ["macos-arm64", "linux-x86_64-glibc", "windows-x86_64"]
native = ["notcurses", "sqlcipher"]
smoke = "{exec} --version"   # command template run by ariza smoke

[installer]
repo = "m-doughty/App-Moneymoor"   # where the releases live

[ci]
ariza-source = "fez"         # how the scaffolded workflows install ariza

=end code

=head2 [app]

All three keys are required; a manifest missing any of them dies at
load time naming the key and the file.

=item1 C<name> — the distribution name as C<zef> knows it
(C<App::Moneymoor>, colons and all), I<not> the repository directory
name.

=item1 C<exec> — the launcher name: the command a user types, the
basename of the binary inside a bundle, and the C<{exec}> expansion in
C<bundle.smoke>.

=item1 C<display> — the human-facing name, for window titles, desktop
entries and Start Menu shortcuts. Required rather than derived, because
the correct capitalisation of a product name is not something a tool
should be guessing at.

=head2 [bundle]

Every key optional.

=item1 C<platforms> — which L<App::Ariza::Platform> slugs to build for.
Each entry must be a slug ariza knows; an unknown one is a hard error
(see below). Absent means an empty list.

=item1 C<native> — names of native libraries the bundle has to carry
beyond the Raku runtime itself. Free-form strings in v1; a later phase
gives them meaning.

=item1 C<smoke> — what C<ariza smoke> runs against a freshly built
bundle to prove it works. See below.

=head2 bundle.smoke

Three shapes, in increasing order of how much you need:

=begin code :lang<toml>

# One command:
smoke = "{exec} --version"

# Several:
smoke = ["{exec} --version", "{exec} --help"]

# Commands that must not go anywhere near a shell:
smoke = [
    ["{exec}", "--version"],
    ["{raku}", "-e", '''
use App::Moneymoor::DB;
…
''', "{tmp}"],
]

=end code

A B<string> entry is split on whitespace. An B<array> entry is taken
word for word, verbatim — which is the only way to express a command
containing spaces, quotes, or an entire program, and the reason the
schema grew an array form at all. Nothing is ever passed through a
shell, in either form, so there is no quoting layer to get wrong.

The two entry shapes cannot be B<mixed in one file>: Config::TOML
enforces the pre-1.0 rule that an array's elements are all of one type,
so a list is either all strings or all arrays. That is a limitation of
the parser rather than of this schema — C<smoke-argvs> is happy to
accept either — and the workaround is to write the whole list as argv
arrays, which is the better form anyway.

=head2 [installer]

=item1 C<repo> — the GitHub C<owner/name> whose releases the generated
end-user installers download from. L<App::Ariza::Installer> builds three
URLs out of it: the C<releases/latest> redirect it reads a tag from, the
bundle asset, and that asset's C<.sha256> sibling.

Optional in the schema — an app that is not published anywhere has no
repository to name — but required by C<ariza installers>, which says so
rather than rendering a script that 404s.

The value must be exactly C<owner/name>. A full URL, a trailing
C<.git>, or a stray space is a hard error for the same reason an unknown
platform slug is: the shape is closed, so a typo cannot be a future
feature, and the resulting 404 lands on a stranger's machine rather than
on the author's.

=head3 Placeholders

C<{exec}> is expanded by C<smoke-command> against C<app.exec>.
L<App::Ariza::Smoke> expands rather more, against a bundle it has just
unpacked:

=item1 C<{exec}> — the launcher, C<< <bundle>/bin/<exec> >>
=item1 C<{raku}> — the bundled interpreter
=item1 C<{site}> — the bundle's module repository
=item1 C<{native}> — the staged native libraries
=item1 C<{bundle}> — the bundle root
=item1 C<{tmp}> — a writable scratch directory, created per run

A placeholder that nothing supplies is an error, not an empty string: a
smoke command with a hole in it does not fail, it silently runs
something else.

=head2 [ci]

One key, optional, read only by L<App::Ariza::CI> when it scaffolds an
app's GitHub Actions workflows.

=item1 C<ariza-source> — where the generated C<release.yml> installs
ariza itself from. C<"fez"> (the default) renders
C<zef install --/test App::Ariza>; anything else is passed to C<zef>
verbatim, which is how a repository URL gets used before ariza is
published, or while a release is being tested:

=begin code :lang<toml>

[ci]
ariza-source = "https://github.com/m-doughty/App-Ariza.git"

=end code

Whichever is chosen, the other is rendered B<beside it as a comment>, so
switching between them in a hurry is an uncomment rather than a
remembering exercise.

Unlike a platform slug this is not a closed set — anything C<zef
install> accepts is legitimate, and enumerating those here would date
badly — so only an B<empty> value is an error, because it renders a
workflow step that installs nothing and succeeds.

=head1 UNKNOWN KEYS WARN; WRONG TYPES DIE

The house rule, shared with L<App::Ariza::Versions> and
L<App::Shigur::Config>: unrecognised keys at any level go into
C<warnings> and loading continues, so one manifest can serve several
ariza versions. Wrong I<types> die immediately, naming the dotted path
and the expected shape:

=begin code :lang<console>

ariza: app.name must be a string
ariza: bundle.platforms must be an array of strings
ariza: bundle.native must be an array of strings

=end code

Keys beginning with C<//> are ignored silently, at any level, matching
every other ariza config file.

=head2 The one value that is not forward-compatible

An unknown B<platform slug> in C<bundle.platforms> dies rather than
warning:

=begin code :lang<console>

ariza: bundle.platforms contains unknown platform 'macos-aarch64'
       (expected one of: linux-aarch64-glibc, ..., windows-x86_64)

=end code

C<installer.repo> is the same kind of value and dies the same way:

=begin code :lang<console>

ariza: installer.repo must look like 'owner/name'
       (got 'https://github.com/m-doughty/App-Moneymoor')

=end code

The reasoning is asymmetric on purpose. An unknown I<key> costs
nothing to ignore — some future ariza understands it. An unknown
I<slug> is a closed-set value: the set is exactly what ariza can build
for, so a typo cannot be a future feature, and ignoring it would
produce a release quietly missing a platform the author asked for.
C<macos-aarch64> for C<macos-arm64> is the exact mistake this catches.

=head1 METHODS

=head2 load(IO() $dir = $*CWD --> App::Ariza::Config)

Load C<$dir/ariza.toml>.

=head2 load-file(IO() $path --> App::Ariza::Config)

Load a manifest from an exact path.

Both die — with distinct messages — on a missing file, an unreadable
file, malformed TOML, a document that is not a table, a wrongly-typed
value, or a missing required C<[app]> key.

An empty file is a valid, empty TOML document, so it fails on the
honest complaint — C<"app.name is required"> — rather than as
"malformed". (Config::TOML rejects an empty document outright, so
C<load-file> short-circuits before handing it over.)

=head2 smoke-argvs(--> List)

Every configured smoke command as raw argv, in order: string entries
split on whitespace, array entries verbatim. Empty entries are dropped.

=head2 smoke-commands(*%vars --> List)

The same, with C<{placeholder}> substitutions applied. C<{exec}> defaults
to C<app.exec> and can be overridden; every other name comes from
C<%vars>. A surviving C<{...}> dies naming the known placeholders.

=head2 smoke-command(--> Str)

The B<first> smoke command as one display string with C<{exec}>
expanded, or the undefined C<Str> when none is configured. For showing a
human what will run — C<smoke-commands> is for running it.

=head2 warnings(--> List) / path(--> IO::Path)

The unrecognised keys found while loading, and the file loaded from.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
