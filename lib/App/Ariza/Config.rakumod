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
has      $.installer-warm;
has Bool $.updates-enabled = False;
has Str  $.ci-ariza-source;
has Bool $.licensing-strict = False;
has      $.licensing-app = {};
has      $.licensing-third-party = ();
has      $.licensing-dists = ();
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

# The arguments the generated installers hand the freshly installed
# launcher, once, so that whatever a first launch does is done while the
# installer is still on screen saying so.
#
# `--version` because it is the one invocation every bundled app answers
# and returns from — it is what `bundle.smoke` uses as its own canary —
# and because a warm-up that does not exit is an installer that hangs.
my constant WARM-DEFAULT = ('--version',);

# `installer.warm` is one of:
#
#   (omitted) / true         --version
#   "--check --quiet"        one command line, whitespace-split
#   ["--check", "--quiet"]   the same, word for word
#   false                    no warm-up step at all
my constant WARM-SHAPE = 'a string, an array of strings, or false';

my sub as-warm(Str:D $key, $value) {
    return $value if $value ~~ Bool;
    if $value ~~ Str {
        # An empty string is not "the default" and it is not "off"; it is
        # a launcher run with no arguments, which for a full-screen
        # application never returns. Both intentions have a spelling, so
        # say which one is meant rather than guessing.
        die "ariza: $key is empty — use `false` to skip the warm-up, or"
          ~ " arguments the app returns from"
            unless $value.words;
        return $value;
    }
    die-with-key($key, WARM-SHAPE) unless $value.defined && $value ~~ Positional;
    die "ariza: $key is empty — use `false` to skip the warm-up, or"
      ~ " arguments the app returns from"
        unless $value.list;
    for $value.list -> $word {
        die-with-key($key, WARM-SHAPE) unless $word.defined && $word ~~ Str;
    }
    $value
}

my sub parse-installer($value, %attrs, @warnings) {
    my %obj = as-hash('installer', $value);
    for %obj.kv -> $key, $v {
        next if $key.starts-with('//');
        given $key {
            when 'warm' { %attrs<installer-warm> = as-warm('installer.warm', $v); }
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

my sub parse-updates($value, %attrs, @warnings) {
    my %obj = as-hash('updates', $value);
    for %obj.kv -> $key, $v {
        next if $key.starts-with('//');
        given $key {
            when 'enabled' {
                die-with-key('updates.enabled', 'true or false')
                    unless $v.defined && $v ~~ Bool;
                %attrs<updates-enabled> = $v;
            }
            default {
                @warnings.push("unknown key 'updates.$key' in ariza.toml (ignored)");
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

# The fields of a licensing row, which is the same shape everywhere:
# App::Ariza::Licensing's rows, a native pack's third-party.json
# components, and the three places an app can write one here. Keeping
# the vocabulary identical is what lets an app describe a bundled font
# in the same words the notcurses pack describes FFmpeg in.
my constant ROW-STRINGS =
    <id name version spdx-license conveyed-under copyright project-url
     source notes>;
my constant ROW-LISTS = <license-files files>;

# What each of the three tables accepts. `licensing.app` has no `id`
# (there is only one application) and no `files` (the bundle is the
# file); a `licensing.dists` override describes a distribution ariza
# already found, so it names it and corrects it rather than inventing
# provenance for it.
my constant APP-KEYS =
    <name version spdx-license conveyed-under copyright project-url source
     notes license-files>;
my constant THIRD-PARTY-KEYS = (|ROW-STRINGS, |ROW-LISTS);
my constant DIST-KEYS =
    <name version spdx-license conveyed-under copyright project-url notes
     license-files>;

my sub parse-row(Str:D $key, $value, @warnings, :@allow!, :@require = () --> Hash) {
    my %obj = as-hash($key, $value);
    my %row;
    for %obj.kv -> $k, $v {
        next if $k.starts-with('//');
        my $dotted = $key ~ '.' ~ $k;
        unless @allow.first($k) {
            @warnings.push("unknown key '$dotted' in ariza.toml (ignored)");
            next;
        }
        %row{$k} = ROW-LISTS.first($k)
            ?? as-str-list($dotted, $v)
            !! as-str($dotted, $v);
    }
    for @require -> $required {
        die "ariza: {$key}.{$required} is required"
            unless %row{$required}.defined && %row{$required}.chars;
    }
    %row
}

my sub parse-rows(Str:D $key, $value, @warnings, :@allow!, :@require = () --> List) {
    die-with-key($key, 'an array of tables')
        unless $value.defined && $value ~~ Positional;
    # An explicit loop, not `.map(...).List`: the map is lazy, so a row
    # missing a required key would not be complained about until
    # something happened to consume the result — which is outside
    # whatever the caller wrapped this in, and a long way from the file
    # that is wrong.
    my @rows;
    @rows.push(parse-row($key, $_, @warnings, :@allow, :@require))
        for $value.list;
    @rows.List
}

my sub parse-licensing($value, %attrs, @warnings) {
    my %obj = as-hash('licensing', $value);
    for %obj.kv -> $key, $v {
        next if $key.starts-with('//');
        given $key {
            when 'strict' {
                die-with-key('licensing.strict', 'true or false')
                    unless $v.defined && $v ~~ Bool;
                %attrs<licensing-strict> = $v;
            }
            when 'app' {
                %attrs<licensing-app> =
                    parse-row('licensing.app', $v, @warnings, :allow(APP-KEYS));
            }
            when 'third-party' {
                %attrs<licensing-third-party> =
                    parse-rows('licensing.third-party', $v, @warnings,
                               :allow(THIRD-PARTY-KEYS),
                               :require(<name spdx-license>));
            }
            when 'dists' {
                %attrs<licensing-dists> =
                    parse-rows('licensing.dists', $v, @warnings,
                               :allow(DIST-KEYS), :require(('name',)));
            }
            default {
                @warnings.push("unknown key 'licensing.$key' in ariza.toml (ignored)");
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
            when 'updates'   { parse-updates($value, %attrs, @warnings); }
            when 'ci'        { parse-ci($value, %attrs, @warnings); }
            when 'licensing' { parse-licensing($value, %attrs, @warnings); }
            default {
                @warnings.push("unknown key '$key' in ariza.toml (ignored)");
            }
        }
    }

    for <app.name app.exec app.display> -> $required {
        my $attr = $required.subst('.', '-');
        die "ariza: $required is required in $path" unless %attrs{$attr}.defined;
    }

    die "ariza: updates.enabled requires installer.repo in $path"
        if %attrs<updates-enabled> && !%attrs<installer-repo>.defined;

    App::Ariza::Config.new(|%attrs, :$path, :warnings(@warnings.List));
}

#| The arguments a generated installer runs the newly installed launcher
#| with, or the empty list when the app has turned the warm-up off.
#|
#| C<()> is unambiguous: an empty C<installer.warm> is rejected at load
#| time precisely so that "no arguments" cannot be confused with "no
#| warm-up" here — the first would launch the application itself, which
#| is a full-screen program that never returns, inside an installer with
#| no timeout.
method warm-argv(--> List) {
    return () if $!installer-warm ~~ Bool && !$!installer-warm;
    return WARM-DEFAULT.List
        if !$!installer-warm.defined || $!installer-warm ~~ Bool;
    $!installer-warm ~~ Str
        ?? $!installer-warm.words.List
        !! $!installer-warm.list.map(*.Str).List
}

#| Whether the generated installers warm this app up at all.
method warm-enabled(--> Bool) { so self.warm-argv }

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
say $cfg.updates-enabled;     # False unless [updates] opts in
say $cfg.ci-ariza-source;     # fez  (or a URL zef can install from)
say $cfg.smoke-command;       # moneymoor --version
say $cfg.licensing-strict;    # False
say $cfg.licensing-third-party;   # ({name => Inter, spdx-license => OFL-1.1})

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
warm = "--version"                 # run once at install time; false skips it

[updates]
enabled = true                     # weekly managed-install prompt

[ci]
ariza-source = "fez"         # how the scaffolded workflows install ariza

[licensing]
strict = false               # an unattributed native pack fails the build

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

=item1 C<warm> — the arguments the generated installers run the freshly
installed launcher with, once, before they print the parting message.
Defaults to C<--version>.

Whatever a first launch has to do that later ones do not — paging a few
hundred megabytes off a cold disk, building a per-user state directory,
touching a keychain — is done there, while the installer is on screen
saying so, rather than the first time the user actually wants the
application.

Four spellings:

=begin code :lang<toml>

[installer]
warm = "--version"            # arguments, whitespace-split
warm = ["--check", "--quiet"] # the same, word for word
warm = true                   # the default arguments, said out loud
warm = false                  # no warm-up step at all

=end code

An B<empty> string or array is an error rather than either of the two
things it might mean. Running the launcher with no arguments starts the
application, and a full-screen application does not return — the
installers deliberately impose no timeout, so that spelling would be a
hang. C<false> is how you say "skip it", and arguments the app returns
from are how you say anything else.

The warm-up B<never fails an install>. See L<App::Ariza::Installer>.

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

=head2 [updates]

C<enabled> is a boolean and defaults to C<false>. When true, bundles carry the
managed-install update coordinator and trusted local installer snapshot
described by L<App::Ariza::Update>. The coordinator checks at most weekly and
offers the user install-now, ask-next-time and ignore-this-version choices.

Enabling updates requires C<installer.repo>. The repository is not duplicated
in this table: discovery and the private exact-candidate installer must use the
same GitHub release identity as the public generated installers.

=head2 [ci]

One key, optional, read only by L<App::Ariza::CI> when it scaffolds an
app's GitHub Actions workflows.

=item1 C<ariza-source> — where the generated C<release.yml> installs
ariza itself from. C<"fez"> (the default) renders
C«zef install --/test
'App::Ariza:ver<0.1.4+>:auth<zef:apogee>'»; the version
floor prevents an older bundler from silently rebuilding a release and
the author qualifier prevents a same-named distribution from satisfying
it. Anything else is passed to C<zef> verbatim, which is how a repository
URL gets used before ariza is published, or while a release is being tested:

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

=head2 [licensing]

Everything about what a bundle redistributes is read out of the bundle
itself — a native pack's own licensing kit, each installed
distribution's C<META6.json> C<license>, ariza's record of the vendored
runtime. This table is for the two things that are not readable from
anywhere: how strict to be about a payload nobody attributed, and what
the B<app> ships that ariza cannot see.

Every key is optional, and an app that writes none of it still gets a
complete C<THIRD-PARTY.md>.

=begin code :lang<toml>

[licensing]
# A native pack with no licensing manifest is a warning and a visible
# "unattributed" row by default. `true` makes it a failed build.
strict = true

# The application's own row. Every field defaults from the app's
# META6.json (and its LICENSE file), so most apps need none of this.
[licensing.app]
copyright = "Copyright 2026 A Person"
project-url = "https://example.org/moneymoor"
notes = "The bundled build enables the encrypted-store feature."

# Anything the app ships that ariza cannot see: fonts, datasets,
# artwork, a vendored C library of its own.
[[licensing.third-party]]
name = "Inter"
version = "4.0"
spdx-license = "OFL-1.1"                   # a text ariza ships
copyright = "Copyright 2016 The Inter Project Authors"
project-url = "https://rsms.me/inter/"
files = ["resources/fonts/Inter-*.ttf"]

[[licensing.third-party]]
name = "The cover artwork"
spdx-license = "CC-BY-4.0"                 # one it does not: name a file
license-files = ["licenses/CC-BY-4.0.txt"] # path in THIS repository
files = ["resources/art/*.png"]

# A distribution in the closure whose own metadata is wrong or absent.
[[licensing.dists]]
name = "Some::Ancient::Module"
spdx-license = "Artistic-2.0"
notes = "Its META6 has no license field; confirmed from its LICENSE."

=end code

The three row tables share one vocabulary — C<id>, C<name>, C<version>,
C<spdx-license>, C<conveyed-under>, C<copyright>, C<project-url>,
C<source>, C<notes>, C<license-files>, C<files> — and it is deliberately
the same vocabulary a native pack's C<third-party.json> uses, so an app
describes a bundled font in the words a pack describes FFmpeg in.
C<licensing.app> takes neither C<id> (there is one application) nor
C<files> (the bundle is the file); C<licensing.dists> corrects a
distribution ariza already found, so it takes neither C<id>, C<source>
nor C<files>.

C<license-files> entries are paths B<inside the app's repository>, never
absolute: a licence text belongs to the repository that declares it, and
an absolute path in a committed config file is a path that exists on one
machine. Where a row omits them, ariza uses the text it ships for the
row's SPDX identifier — it ships C<Artistic-2.0>, C<MIT>, C<Apache-2.0>,
C<BSD-2-Clause>, C<BSD-3-Clause>, C<LGPL-2.1>, C<LGPL-3.0>, C<GPL-2.0>,
C<GPL-3.0>, C<AGPL-3.0>, C<Zlib>, C<ISC>, C<X11>, C<OFL-1.1>,
C<Unlicense> and a public-domain statement — and an identifier it has no
text for is a hard error naming this key as the fix.

=head3 NOASSERTION

C<spdx-license = "NOASSERTION"> is SPDX's own spelling for "somebody
looked and could not determine the licensing", and it is accepted in a
C<[[licensing.dists]]> or C<[[licensing.third-party]]> row — after
looking, as a declaration on the record. No licence text is looked up
for it, since there is none, and the generated document says in words
that licensing was not asserted and points at the component's own
repository.

It is available B<nowhere else>. A distribution whose own metadata says
C<NOASSERTION> fails like any other missing licence (nobody has looked
yet), C<[licensing.app]> may not say it about the application itself
(there is nobody to look on its behalf), and C<licensing.strict> refuses
a bundle that contains one — strict means every component names a
licence, and "we could not find one" is not a name.

C<name> and C<spdx-license> are required in a C<[[licensing.third-party]]>
row, C<name> in a C<[[licensing.dists]]> one; anything else is optional.
See L<App::Ariza::Licensing> for what is done with them.

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

=head2 licensing-strict(--> Bool) / licensing-app(--> Hash) / licensing-third-party(--> List) / licensing-dists(--> List)

The C<[licensing]> table: whether an unattributed native pack fails the
build, the app's own row, the rows it declared for what ariza cannot
see, and the corrections it declared for distributions whose metadata is
wrong. All four are empty-but-defined for a config that omits the
table, so a caller never has to test for it.

=head2 warnings(--> List) / path(--> IO::Path)

The unrecognised keys found while loading, and the file loaded from.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
