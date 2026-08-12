use JSON::Fast;
use Template::Jinja2;

use App::Ariza::Config;
use App::Ariza::Resources;
use App::Ariza::Site;
use App::Ariza::Tools;

unit class App::Ariza::Licensing;

my constant RUNTIME-RESOURCE = 'runtime-third-party.json';
my constant LICENSE-PREFIX   = 'licenses';
my constant TEMPLATE         = 'templates/THIRD-PARTY.md.j2';

#| The merged document and the directory of licence texts it cites, both
#| at the bundle root.
our constant DOCUMENT  = 'THIRD-PARTY.md';
our constant DIRECTORY = 'LICENSES';

# What a row can be, in the order the document lists them: the thing the
# user came for, then what runs it, then what it loads, then the Raku
# closure, then whatever the app declared for itself.
my constant @KINDS = <application runtime native module other>;

# The facts a runtime-data row is allowed to be conditional on. A closed
# set: a `condition` ariza does not know cannot be evaluated, and a row
# quietly dropped because of a typo is a notice not given.
my constant @CONDITIONS = <sqlcipher runner>;

# How far below `native/<pack>` a licensing kit is looked for. The
# notcurses pack keeps its kit one level down, beside the libraries
# (`<pack>/<tag>/lib`); the limit is there so a pack that ships a deep
# tree of data files cannot turn the scan into a walk of the whole
# bundle.
my constant KIT-DEPTH = 4;

# The three files a licensing kit is recognised by. `third-party.json`
# is the machine-readable manifest and the source of truth where there
# is one; `THIRD-PARTY.md` is prose generated from it, and is read only
# when the JSON is absent; a bare `LICENSES/` is a notice with no
# inventory, which is the unattributed case.
my constant KIT-MANIFEST = 'third-party.json';
my constant KIT-DOCUMENT = 'THIRD-PARTY.md';

# The exact header the generated Summary table has. Read as a contract:
# a kit whose table does not have this header is not one this parser
# understands, and it falls through to the unattributed path rather
# than guessing at columns.
my constant MD-SUMMARY-HEADER = '| Component | Version | Licence (SPDX) | Source |';

#| Every SPDX licence identifier in an expression, normalised: C<OR>,
#| C<AND> and C<WITH> are separators, brackets are noise, and the
#| C<-or-later> / C<-only> / C<+> suffixes name the same text as the
#| identifier they qualify.
#|
#|   spdx-ids('LGPL-2.1-or-later')                    # (LGPL-2.1)
#|   spdx-ids('GPL-3.0-or-later WITH GCC-exception-3.1')
#|                                     # (GPL-3.0 GCC-exception-3.1)
our sub spdx-ids(Str:D $expr --> List) is export {
    $expr.subst(/ <[()]> /, ' ', :g).words
        .grep({ $_ ne 'AND' && $_ ne 'OR' && $_ ne 'WITH' })
        .map({ .subst(/ '+' $ /, '')
                .subst(/ '-or-later' $ /, '')
                .subst(/ '-only' $ /, '') })
        .grep(*.chars).unique.List
}

#| The licence text file an identifier is looked up as. The whole
#| convention, and the reason C<resources/licenses/> is named after
#| identifiers rather than after projects.
our sub spdx-text-name(Str:D $id --> Str) is export { "$id.txt" }

#| SPDX's own spelling for "somebody looked, and could not determine the
#| licensing". It is a B<declaration>, not a gap: an app writes it in a
#| C<[[licensing.dists]]> or C<[[licensing.third-party]]> row, on the
#| record, after failing to find an answer.
our constant NOASSERTION = 'NOASSERTION';

#| Whether a declared licence is that declaration.
#|
#| The whole value, never part of an expression: C<"MIT OR NOASSERTION">
#| is not a licence anyone can act on, and treating the token as an
#| operand would turn a nonsense value into a row that looks considered.
#| Anything else containing the word falls through to the ordinary
#| identifier path, where it fails for having no licence text.
our sub spdx-not-asserted(Str:D $expr --> Bool) is export {
    $expr.trim eq NOASSERTION
}

#| The sentence a C<NOASSERTION> row carries, over whatever the app
#| wrote. Generated rather than left to the app, because the reader of a
#| bundle needs to be told the same thing every time: this is not a
#| licence, and here is where to go and look.
my sub noassertion-note(Str $url, Str $notes --> Str) {
    my $said = "Licensing not asserted. The application that built this"
             ~ " bundle has declared NOASSERTION for this component rather"
             ~ " than a licence: it could not determine one. Consult"
             ~ ($url.defined && $url.chars
                    ?? " the component's own repository, <$url>,"
                    !! " the component's own repository and source"
                     ~ " distribution")
             ~ " before redistributing this bundle.";
    ($notes.defined && $notes.chars) ?? "$notes\n\n$said" !! $said
}

#| The attribution line for a row whose source is Raku metadata rather
#| than a licence notice.
#|
#| C<META6.json> has an C<authors> list and no copyright field, so what
#| there is to say is who wrote it — and saying it under a bare bullet,
#| where every other row carries a copyright notice, reads as a claim
#| nobody made. A value that already looks like a notice is passed
#| through untouched, which is what a pack manifest and an app's own
#| C<copyright> key supply.
my sub attribution(Str:D $text --> Str) {
    return '' unless $text.trim.chars;
    return $text if $text.starts-with('Copyright')
                 || $text.starts-with('(c)') || $text.starts-with('©')
                 || $text.starts-with('Public domain');
    "Authors: $text"
}

#| The name a data file should be called by in a message or a row.
#|
#| Never C<$path.basename>: an installed distribution stages every
#| resource under a content-hashed filename, so the shipped data file's
#| basename is C<A3FCDF0A….json> and a bundle built by an installed ariza
#| would cite that in every row it contributed. The logical name is the
#| one a reader can look up; a path the caller supplied is its own name.
my sub data-label(IO::Path $path --> Str) {
    my $shipped = try { resource(RUNTIME-RESOURCE) };
    ($shipped.defined && $shipped.absolute eq $path.absolute)
        ?? RUNTIME-RESOURCE
        !! $path.basename
}

#| Whether a string could be an SPDX identifier at all. Not a check that
#| it B<is> one — there is no shipped list of every identifier, and
#| there should not be — only that C<"Same as Perl 6"> is not being
#| treated as three of them.
my sub spdx-shaped(Str:D $id --> Bool) {
    so $id ~~ / ^ <[A..Za..z0..9]> <[A..Za..z0..9 . + -]>* $ /
}

#| One row of the merged inventory. Every collector produces these and
#| nothing else, which is what lets a native pack's manifest, a
#| distribution's META6 and an app's C<ariza.toml> contribute to one
#| document without any of them knowing about the others.
my sub make-row(
    Str:D :$id!,
    Str:D :$name!,
    Str:D :$kind!,
    Str:D :$provenance!,
    Str :$version = '',
    Str :$spdx = '',
    Str :$conveyed = '',
    Str :$copyright = '',
    Str :$url = '',
    Str :$source = '',
    Str :$notes = '',
    :@license-files = (),
    :@files = (),
    --> Hash
) {
    die "ariza: '$kind' is not a licensing row kind (known: {@KINDS.join(', ')})"
        unless @KINDS.first($kind);
    %(
        :$id, :$name, :$kind, :$provenance, :$version, :$spdx, :$conveyed,
        :$copyright, :$url, :$source, :$notes,
        license-files => @license-files.map(*.Str).unique.sort.List,
        files         => @files.map(*.Str).List,
    )
}

my sub kind-rank(%row --> Int) { @KINDS.first(%row<kind>, :k) // +@KINDS }

#| The rows of a merged inventory, in the one order a rebuild will
#| always produce: by kind, then by name folded, then by id. Duplicate
#| ids are a hard error — two rows claiming the same identity means one
#| of them is describing something else.
method merge(@rows --> List) {
    my %seen;
    for @rows -> %r {
        die "ariza: two licensing rows share the id '{%r<id>}'"
          ~ " ({%seen{%r<id>}} and {%r<provenance>})"
            if %seen{%r<id>}:exists;
        %seen{%r<id>} = %r<provenance>;
    }
    @rows.sort({ (kind-rank($^a) <=> kind-rank($^b))
              || ($^a<name>.fc cmp $^b<name>.fc)
              || ($^a<id> cmp $^b<id>) }).List
}

# ---------------------------------------------------------------- #
# The runtime data file
# ---------------------------------------------------------------- #

#| The components ariza itself knows about, straight out of
#| C<resources/runtime-third-party.json> and validated, with no
#| substitution applied. Every field a row needs must be there: a data
#| file is only better than code if it is checked as strictly.
method runtime-components(IO() :$path = resource(RUNTIME-RESOURCE) --> List) {
    my $file = data-label($path);
    my $data = do {
        CATCH { default { die "ariza: malformed $file: {.message}" } }
        from-json($path.slurp);
    }

    die "ariza: $file is not a JSON object"
        unless $data.defined && $data ~~ Associative;
    die "ariza: $file has schema-version {$data<schema-version> // 'none'},"
      ~ " and this ariza reads version 1"
        unless ($data<schema-version> // 0) == 1;
    die "ariza: $file has no components list"
        unless $data<components>.defined && $data<components> ~~ Positional;

    my @out;
    for $data<components>.list.kv -> $i, $c {
        die "ariza: $file component $i is not an object"
            unless $c.defined && $c ~~ Associative;
        for <id name version kind spdx-license copyright project-url source> -> $key {
            die "ariza: $file component {$c<id> // $i} has no '$key'"
                unless $c{$key}.defined && $c{$key} ~~ Str && $c{$key}.chars;
        }
        die "ariza: $file component {$c<id>} has no license-files"
            unless $c<license-files>.defined && $c<license-files> ~~ Positional
                && $c<license-files>.list.elems;
        die "ariza: $file component {$c<id>} has kind"
          ~ " '{$c<kind>}' (known: {@KINDS.join(', ')})"
            unless @KINDS.first($c<kind>);
        with $c<condition> {
            die "ariza: $file component {$c<id>} is conditional on"
              ~ " '$_', which ariza cannot decide"
              ~ " (known: {@CONDITIONS.join(', ')})"
                unless @CONDITIONS.first($_);
        }
        @out.push($c);
    }
    @out.List
}

#| Substitute the C<{placeholder}> values a build knows into a data-file
#| string. A placeholder nothing supplies is an error rather than an
#| empty string, exactly as it is in C<bundle.smoke>: a licence row with
#| a hole in it does not fail, it publishes something wrong.
my sub expand(Str:D $text, %placeholders, Str:D $where --> Str) {
    my $out = $text;
    $out = $out.subst("\{$_\}", ~(%placeholders{$_} // ''), :g)
        for %placeholders.keys;
    die "ariza: $where has an unknown placeholder in \"$out\""
      ~ " (known: {%placeholders.keys.sort.map({ "\{$_\}" }).join(', ')})"
        if $out ~~ / '{' <[a..z-]>+ '}' /;
    $out
}

#| The rows for everything ariza puts in a bundle itself: the vendored
#| runtime and the C libraries inside it, plus SQLCipher and the Windows
#| runner when this bundle has them.
#|
#| C<:@conditions> are the facts that are true of this build;
#| C<:%placeholders> the values substituted into the data file's
#| C<{...}> tokens; C<:%files> the file names a component turned out to
#| cover, keyed by component id, which is how the SQLCipher row can name
#| what was actually staged without the data file pretending to know.
method runtime-rows(
    :%placeholders = %(),
    :@conditions = (),
    :%files = %(),
    IO() :$path = resource(RUNTIME-RESOURCE),
    --> List
) {
    my $file = data-label($path);
    my @rows;
    for self.runtime-components(:$path) -> $c {
        with $c<condition> {
            next unless @conditions.first($_);
        }
        my $where = "$file component {$c<id>}";
        @rows.push(make-row(
            id         => $c<id>,
            name       => expand($c<name>, %placeholders, $where),
            kind       => $c<kind>,
            version    => expand($c<version>, %placeholders, $where),
            spdx       => $c<spdx-license>,
            conveyed   => ($c<conveyed-under> // ''),
            copyright  => $c<copyright>,
            url        => $c<project-url>,
            source     => expand($c<source>, %placeholders, $where),
            notes      => expand(($c<notes> // ''), %placeholders, $where),
            license-files => $c<license-files>.list,
            files      => (%files{$c<id>} // ()).list,
            provenance => "ariza runtime data ($file)",
        ));
    }
    @rows.List
}

#| The C<native/> subdirectory names the runtime data claims, so the
#| pack scan does not report a directory ariza staged itself as one
#| nobody attributed.
method runtime-claims(IO() :$path = resource(RUNTIME-RESOURCE), :@conditions = () --> List) {
    my @claims;
    for self.runtime-components(:$path) -> $c {
        with $c<condition> {
            next unless @conditions.first($_);
        }
        @claims.append(($c<claims> // ()).list.grep(Str));
    }
    @claims.unique.List
}

# ---------------------------------------------------------------- #
# Native pack kits
# ---------------------------------------------------------------- #

#| Every licensing kit under a directory, deepest-last and sorted, where
#| a kit is any directory holding a C<third-party.json>, a
#| C<THIRD-PARTY.md> or a C<LICENSES/>. A kit is not descended into: its
#| own C<LICENSES/> is part of it, not a second kit.
method find-kits(IO() $root, Int :$depth = KIT-DEPTH --> List) {
    return () unless $root.d;
    my @found;
    my @queue = ($root => 0).List;
    while @queue {
        my $entry = @queue.shift;
        my ($dir, $level) = $entry.key, $entry.value;
        if self.kit-dir($dir) {
            @found.push($dir);
            next;
        }
        next if $level >= $depth;
        @queue.append($dir.dir.grep(*.d).sort(*.basename).map({ $_ => $level + 1 }));
    }
    @found.List
}

#| Whether a directory is a licensing kit.
method kit-dir(IO() $dir --> Bool) {
    return False unless $dir.d;
    so $dir.add(KIT-MANIFEST).f
    || $dir.add(KIT-DOCUMENT).f
    || $dir.add(DIRECTORY).d
}

#| A source object from a pack manifest, as the one sentence a reader
#| wants: where the bytes came from.
my sub kit-source($source --> Str) {
    return '' unless $source.defined && $source ~~ Associative;
    given ($source<kind> // '') {
        when 'tarball' {
            "{$source<url> // ''}"
              ~ ($source<sha256> ?? " (sha256 {$source<sha256>})" !! '')
        }
        when 'git'     { "{$source<url> // ''} at commit {$source<ref> // ''}" }
        when 'in-tree' { "{$source<url> // ''}" }
        when 'package-manager' {
            'supplied by the package manager of the machine that built the pack'
        }
        default { ~($source<url> // $source<kind> // '') }
    }
}

#| The components in a pack's own C<third-party.json>, as rows.
#|
#| A component whose C<binaries> section says it ships nothing on this
#| platform is skipped — that is the pack format's own way of saying
#| "somebody else's platform" — while one with no C<binaries> section at
#| all is kept, because a manifest that does not talk about platforms is
#| talking about all of them.
method manifest-rows(
    IO() $manifest,
    Str:D :$family!,
    Str:D :$pack!,
    Str:D :$provenance!,
    --> List
) {
    my $data = do {
        CATCH {
            default {
                die "ariza: {$manifest.absolute} is a native pack's licensing"
                  ~ " manifest and it does not parse: {.message}";
            }
        }
        from-json($manifest.slurp);
    }

    die "ariza: {$manifest.absolute} has no components list"
        unless $data.defined && $data ~~ Associative
            && $data<components>.defined && $data<components> ~~ Positional;

    my @rows;
    for $data<components>.list -> $c {
        next unless $c.defined && $c ~~ Associative;
        my $id = ($c<id> // $c<name> // '').Str;
        die "ariza: a component in {$manifest.absolute} has neither an id nor a name"
            unless $id.chars;

        my @patterns;
        with $c<binaries> {
            next unless $_ ~~ Associative;
            if $_{$family}:exists {
                @patterns = ($_{$family}<patterns> // ()).list.grep(Str);
                next unless @patterns;
            }
        }

        @rows.push(make-row(
            id         => "$pack/$id",
            name       => ($c<name> // $id).Str,
            kind       => 'native',
            version    => ($c<version> // '').Str,
            spdx       => ($c<spdx-license> // '').Str,
            conveyed   => ($c<conveyed-under> // '').Str,
            copyright  => ($c<copyright> // '').Str,
            url        => ($c<project-url> // '').Str,
            source     => kit-source($c<source>),
            notes      => ($c<notes> // '').Str,
            license-files => ($c<license-files> // ()).list.grep(Str),
            files      => @patterns,
            :$provenance,
        ));
    }
    @rows.List
}

#| The components a generated C<THIRD-PARTY.md> describes, read off the
#| document itself: the Summary table for name, version, licence and
#| source, and the Details section for the copyright notice and the
#| licence texts each one cites.
#|
#| Returns the empty list for anything whose Summary table does not have
#| the exact header the generator writes. That is the fallback's whole
#| safety story — a document this cannot read produces nothing rather
#| than rows assembled out of the wrong columns.
method md-components(Str:D $md --> List) {
    my @lines = $md.lines;
    my $at = @lines.first({ .trim eq MD-SUMMARY-HEADER }, :k);
    return () without $at;

    my @summary;
    for @lines[$at + 1 .. *] -> $line {
        my $text = $line.trim;
        last unless $text.starts-with('|');
        # The `|---|---|---|---|` rule under the header.
        next if $text.subst(/ <[|\-: \s]> /, '', :g) eq '';
        my @cells = $text.split('|').map(*.trim);
        # A `| a | b | c | d |` row splits to six, the first and last
        # empty; anything else is not this table's shape.
        next unless @cells == 6;
        @summary.push(%(
            name    => @cells[1],
            version => @cells[2],
            spdx    => @cells[3].subst('`', '', :g),
            source  => @cells[4],
        ));
    }
    return () unless @summary;

    # The Details section: one `### <name> — <version>` heading per
    # component, then bullets. Only two of them are read, and both are
    # matched on a label rather than on position.
    my %copyright;
    my %texts;
    my $heading = '';
    for @lines -> $line {
        my $text = $line.trim;
        if $text.starts-with('### ') {
            $heading = $text.substr(4).trim;
            next;
        }
        next unless $heading.chars && $text.starts-with('* ');
        my $bullet = $text.substr(2).trim;
        if $bullet.starts-with('Licence text:') || $bullet.starts-with('License text:') {
            %texts{$heading} = ($bullet ~~ m:g/ '`' 'LICENSES/' (<-[`]>+) '`' /)
                .map({ ~.[0] }).List;
        }
        elsif $bullet.starts-with('Copyright') || $bullet.starts-with('Public domain') {
            %copyright{$heading} //= $bullet;
        }
    }

    # Headings are matched on `<name> ` or `<name>` exactly, and the
    # candidates are sorted before one is taken: a bare `.starts-with`
    # over unsorted hash keys would let a component called `notcurses`
    # pick up `notcurses-core`'s copyright, and would pick a different
    # one on the next run.
    my sub heading-for(%where, Str:D $name --> Str) {
        %where.keys.sort.first({ $_ eq $name || .starts-with("$name ") }) // Str
    }

    for @summary -> %c {
        my $key = heading-for(%copyright, %c<name>);
        %c<copyright> = ($key.defined ?? %copyright{$key} !! '');
        my $tkey = heading-for(%texts, %c<name>);
        %c<license-files> = ($tkey.defined ?? %texts{$tkey} !! ());
    }
    @summary.List
}

#| Rows for every native pack staged into the bundle, and the licence
#| texts those packs carry.
#|
#| Returns C<{ rows, texts }>, where C<texts> are the C<LICENSES/>
#| directories found inside the packs, in the order they should be
#| merged.
#|
#| A pack with no kit at all is a row saying so, not a silence: a
#| redistributed binary nobody attributed is the exact thing this
#| document exists to make visible. C<:$strict> turns that row into a
#| failed build, which is what an app that will not ship an
#| unattributed payload asks for.
method pack-rows(
    IO() :$bundle-dir!,
    Str:D :$family!,
    IO() :$native-dir = App::Ariza::Site.native-dir($bundle-dir),
    :@claimed = (),
    Bool :$strict = False,
    :@warnings = [],
    --> Hash
) {
    my @rows;
    my @texts;
    return %( rows => @rows.List, texts => @texts.List ) unless $native-dir.d;

    for $native-dir.dir.grep(*.d).sort(*.basename) -> $pack-dir {
        my $pack = $pack-dir.basename;
        next if @claimed.first($pack);

        my @kits = self.find-kits($pack-dir);
        my @pack-rows;

        for @kits -> $kit {
            my $rel = $kit.relative($bundle-dir).subst('\\', '/', :g);
            @texts.push($kit.add(DIRECTORY)) if $kit.add(DIRECTORY).d;

            my $manifest = $kit.add(KIT-MANIFEST);
            if $manifest.f {
                @pack-rows.append(self.manifest-rows($manifest, :$family, :$pack,
                    :provenance("pack manifest ($rel/{KIT-MANIFEST})")));
                next;
            }

            my $document = $kit.add(KIT-DOCUMENT);
            next unless $document.f;
            my @found = self.md-components($document.slurp);
            unless @found {
                @warnings.push("$rel/{KIT-DOCUMENT} is not in the generated"
                             ~ " shape ariza can read, so $pack is listed as"
                             ~ " unattributed");
                next;
            }
            for @found -> %c {
                @pack-rows.push(make-row(
                    id      => "$pack/" ~ %c<name>.lc.subst(/ <-[a..z0..9]>+ /, '-', :g)
                                                   .subst(/ ^ '-' | '-' $ /, '', :g),
                    name    => %c<name>,
                    kind    => 'native',
                    version => %c<version>,
                    spdx    => %c<spdx>,
                    copyright => %c<copyright>,
                    source  => %c<source>,
                    license-files => %c<license-files>.list,
                    provenance => "pack kit ($rel/{KIT-DOCUMENT})",
                ));
            }
        }

        unless @pack-rows {
            my $rel = $pack-dir.relative($bundle-dir).subst('\\', '/', :g);
            my $why = "$pack ships no licensing manifest ariza can read,"
                    ~ " so what is in $rel is redistributed unattributed";
            die "ariza: $why.\n"
              ~ "    licensing.strict is on. Either the pack grows a"
              ~ " {KIT-MANIFEST} (or a generated {KIT-DOCUMENT}), or the app"
              ~ " declares it with a [[licensing.third-party]] row in"
              ~ " ariza.toml."
                if $strict;
            @warnings.push($why);
            @pack-rows.push(make-row(
                id      => "native/$pack",
                name    => $pack,
                kind    => 'native',
                version => '',
                notes   => "Licensing unknown: this pack ships no"
                         ~ " {KIT-MANIFEST} and no {KIT-DOCUMENT}, so ariza"
                         ~ " has nothing to attribute its contents from."
                         ~ " Declare it with a [[licensing.third-party]] row"
                         ~ " in the app's ariza.toml, or ask the pack to ship"
                         ~ " a licensing kit.",
                files   => ($rel,),
                provenance => "bundle scan ($rel)",
            ));
        }

        @rows.append(@pack-rows);
    }

    %( rows => @rows.List, texts => @texts.List )
}

# ---------------------------------------------------------------- #
# The Raku closure
# ---------------------------------------------------------------- #

#| One row per distribution installed in the bundle — its own C<site>
#| repository and the one inside the vendored runtime, which is where
#| C<zef> lives.
#|
#| A distribution with no C<license> in its metadata, or one whose
#| licence ariza has no text for, B<fails the build>. There is no
#| "unknown" row for a Raku module: the field exists, every ecosystem
#| distribution is expected to fill it in, and an app that has hit a
#| distribution which does not can say so once in its own C<ariza.toml>
#| rather than have every bundle quietly under-report.
method site-rows(
    IO() :$bundle-dir!,
    Str :$app-name,
    :@overrides = (),
    :%texts!,
    --> List
) {
    my %by-name;
    for @overrides -> %o {
        %by-name{%o<name>} = %o;
    }

    my @repos =
        %( dir => App::Ariza::Site.site-dir($bundle-dir),
           provenance => 'site META (site/dist)' ),
        %( dir => $bundle-dir.add('rakudo').add('share').add('perl6').add('site'),
           provenance => 'site META (rakudo/share/perl6/site/dist)' ),
    ;

    my @rows;
    my @problems;
    my %seen;
    for @repos -> %repo {
        for App::Ariza::Site.dists-in(%repo<dir>).list -> %d {
            my $name = ~%d<name>;
            next if $app-name.defined && $name eq $app-name;
            next if %seen{$name}++;

            my %o = %by-name{$name} // %();
            my $declared = (%o<spdx-license> // '').trim;
            my $spdx = ($declared.chars ?? $declared !! (%d<license> // '').trim);

            unless $spdx.chars {
                @problems.push("$name declares no licence at all");
                next;
            }

            # NOASSERTION is only ever a DECLARATION, and only an app can
            # make it. A distribution whose own metadata says it is not
            # asserting anything has told ariza nothing an app has looked
            # at, so it fails like any other missing licence — and the fix
            # is for somebody to look, and then to say so on the record.
            my $not-asserted = spdx-not-asserted($declared);
            if !$not-asserted && spdx-not-asserted($spdx) {
                @problems.push("$name declares NOASSERTION in its own"
                             ~ " metadata, which is not a licence ariza will"
                             ~ " pass on unread");
                next;
            }

            my @files = (%o<license-files> // ()).list.map(*.IO.basename);
            if !@files && !$not-asserted {
                my @ids = spdx-ids($spdx);
                my @bad = @ids.grep({ !spdx-shaped($_)
                                   || !%texts{spdx-text-name($_)}.defined });
                if @bad {
                    @problems.push("$name declares \"$spdx\", and ariza has no"
                                 ~ " licence text for {@bad.join(', ')}");
                    next;
                }
                @files = @ids.map({ spdx-text-name($_) });
            }

            @rows.push(make-row(
                id         => "dist/$name",
                name       => $name,
                kind       => 'module',
                version    => ~(%o<version> // %d<version> // ''),
                spdx       => $spdx,
                copyright  => attribution(~(%o<copyright>
                                // (%d<authors> // ()).list.join('; '))),
                url        => ~(%o<project-url> // ''),
                source     => 'installed into the bundle by zef'
                            ~ (%d<auth>.defined ?? " (auth {%d<auth>})" !! ''),
                notes      => ($not-asserted
                    ?? noassertion-note(~(%o<project-url> // ''), ~(%o<notes> // ''))
                    !! ~(%o<notes> // '')),
                license-files => @files,
                provenance => (%o
                    ?? "app config ([[licensing.dists]]), over {%repo<provenance>}"
                    !! %repo<provenance>),
            ));
        }
    }

    # Every offender at once, not the first one: an app whose closure has
    # three distributions with nothing to say about their licences should
    # learn that in one build, not in three.
    die "ariza: {+@problems} distribution(s) in the bundle cannot be"
      ~ " attributed, and ariza will not ship a component it cannot"
      ~ " attribute:\n"
      ~ @problems.map({ "    $_" }).join("\n") ~ "\n"
      ~ "  Fix the distribution's own META6.json \"license\" field where"
      ~ " you can, or declare each one in the app's ariza.toml:\n"
      ~ "      [[licensing.dists]]\n"
      ~ "      name = \"Some::Module\"\n"
      ~ "      spdx-license = \"Artistic-2.0\"\n"
      ~ "  adding license-files = [\"path/in/your/repo.txt\"] for a licence"
      ~ " ariza ships no text for, or spdx-license = \"{NOASSERTION}\" once"
      ~ " you have looked and there is genuinely no answer."
        if @problems;

    @rows.List
}

# ---------------------------------------------------------------- #
# The app's own rows
# ---------------------------------------------------------------- #

#| The application's own row, plus every C<[[licensing.third-party]]>
#| row it declared for things ariza cannot see — a bundled font, a data
#| file, an asset with a licence of its own.
#|
#| The application row's defaults come from the app's own C<META6.json>;
#| C<[licensing.app]> overrides any field of it. Its licence text is the
#| repository's own C<LICENSE> file where there is one, because that is
#| the notice its author actually wrote, and the shipped text for its
#| SPDX identifier otherwise.
method app-rows(
    App::Ariza::Config:D :$config!,
    IO() :$app-dir!,
    Str:D :$app-version!,
    :%texts!,
    Str :$license-file,
    --> List
) {
    my %meta = self.app-meta($app-dir);
    my %own  = $config.licensing-app;

    my $spdx = ~(%own<spdx-license> // %meta<license> // '').trim;
    die "ariza: {$config.app-name} declares no licence: its META6.json has"
      ~ " no \"license\" field and ariza.toml has no"
      ~ " [licensing.app] spdx-license.\n"
      ~ "    A bundle says what it redistributes, and that starts with the"
      ~ " application itself."
        unless $spdx.chars;

    # An application may not decline to say. NOASSERTION means "somebody
    # looked at a third party's work and could not find out"; there is
    # nobody to look for the licence of the thing being built here.
    die "ariza: {$config.app-name} declares {NOASSERTION} as its own"
      ~ " licence.\n"
      ~ "    {NOASSERTION} is for a component whose licensing an app could"
      ~ " not determine. An application knows its own: put an SPDX"
      ~ " identifier in its META6.json \"license\" field, or in"
      ~ " [licensing.app] spdx-license."
        if spdx-not-asserted($spdx);

    my @files = (%own<license-files> // ()).list.map(*.IO.basename);
    @files = ($license-file,) if !@files && $license-file.defined;
    unless @files {
        my @ids = spdx-ids($spdx);
        my @bad = @ids.grep({ !spdx-shaped($_)
                           || !%texts{spdx-text-name($_)}.defined });
        die "ariza: {$config.app-name} declares the licence \"$spdx\", which"
          ~ " ariza has no licence text for ({@bad.join(', ')}), and its"
          ~ " repository has no LICENSE file to copy instead.\n"
          ~ "    Add one, or name a file with [licensing.app] license-files"
          ~ " in ariza.toml."
            if @bad;
        @files = @ids.map({ spdx-text-name($_) });
    }

    # `.push`, not `my @rows = make-row(...)`: assigning a single Hash to
    # an Array flattens it into its Pairs, and the row disappears.
    my @rows;
    @rows.push(make-row(
        id        => 'app',
        name      => ~(%own<name> // $config.app-name),
        kind      => 'application',
        version   => ~(%own<version> // $app-version),
        spdx      => $spdx,
        conveyed  => ~(%own<conveyed-under> // ''),
        copyright => attribution(
                        ~(%own<copyright> // (%meta<authors> // ()).list.join('; '))),
        url       => ~(%own<project-url> // %meta<source-url> // ''),
        source    => ~(%own<source> // 'this bundle is a build of it'),
        notes     => ~(%own<notes> // ''),
        license-files => @files,
        provenance => (%own
            ?? 'app config ([licensing.app]), over the app META6'
            !! 'app META6'),
    ));

    for $config.licensing-third-party.list.kv -> $i, %t {
        my $declared = ~%t<spdx-license>;
        my $not-asserted = spdx-not-asserted($declared);
        my @own-files = (%t<license-files> // ()).list.map(*.IO.basename);
        # No text is looked up for a declaration that there is no licence:
        # there is nothing to look up. A row that names a file anyway
        # keeps it — a NOTICE somebody found is worth carrying even when
        # the licence itself could not be established.
        if !@own-files && !$not-asserted {
            my @ids = spdx-ids($declared);
            my @bad = @ids.grep({ !spdx-shaped($_)
                               || !%texts{spdx-text-name($_)}.defined });
            die "ariza: the [[licensing.third-party]] row for {%t<name>}"
              ~ " declares \"{%t<spdx-license>}\", which ariza has no licence"
              ~ " text for ({@bad.join(', ')}).\n"
              ~ "    Add license-files to that row, naming a file in the"
              ~ " app's repository — or spdx-license = \"{NOASSERTION}\" once"
              ~ " you have looked and there is genuinely no answer."
                if @bad;
            @own-files = @ids.map({ spdx-text-name($_) });
        }
        @rows.push(make-row(
            id        => (%t<id> // "app-third-party/{$i + 1}").Str,
            name      => ~%t<name>,
            kind      => 'other',
            version   => ~(%t<version> // ''),
            spdx      => ~%t<spdx-license>,
            conveyed  => ~(%t<conveyed-under> // ''),
            copyright => ~(%t<copyright> // ''),
            url       => ~(%t<project-url> // ''),
            source    => ~(%t<source> // ''),
            notes     => ($not-asserted
                ?? noassertion-note(~(%t<project-url> // ''), ~(%t<notes> // ''))
                !! ~(%t<notes> // '')),
            license-files => @own-files,
            files     => (%t<files> // ()).list,
            provenance => 'app config ([[licensing.third-party]])',
        ));
    }

    @rows.List
}

#| The app checkout's C<META6.json>, or an empty hash. Read rather than
#| required: the version is L<App::Ariza::Bundle>'s job to insist on, and
#| by the time this runs it has.
method app-meta(IO() $app-dir --> Hash) {
    my $meta = $app-dir.add('META6.json');
    return %() unless $meta.f;
    my $data = try { from-json($meta.slurp) };
    ($data.defined && $data ~~ Associative) ?? $data.Hash !! %()
}

#| The app repository's own licence file — C<LICENSE>, C<LICENCE>,
#| C<LICENSE.md>, whatever it is called — or the undefined C<IO::Path>.
method app-license-file(IO() $app-dir --> IO::Path) {
    return IO::Path unless $app-dir.d;
    $app-dir.dir.grep({ .f && .basename.uc.starts-with('LICEN') })
        .sort(*.basename).head // IO::Path
}

# ---------------------------------------------------------------- #
# Licence texts
# ---------------------------------------------------------------- #

#| The pool of licence texts a bundle can cite, as
#| C<< name => IO::Path >>, where the name is the one a row cites and
#| the one the file is written into C<LICENSES/> under.
#|
#| The key is the B<logical> name, never the source file's basename.
#| ariza's own texts come through L<App::Ariza::Resources>, and an
#| installed distribution stages every resource under a content-hashed
#| filename — so keying on the basename would give a pool of
#| C<0E9B31…​.txt> and every build would fail on a row citing
#| C<MIT.txt>. Checkout and installed runs must produce the same pool,
#| which is the whole point of that module.
#|
#| Priority order, and it matters: B<what the app named> first, then
#| each native pack's C<LICENSES/> in the order the packs were found,
#| then ariza's own C<resources/licenses/> as the fallback.
#|
#| Nearest-to-the-software wins, and the reason is that ariza's texts are
#| SPDX B<templates>: they carry C<< <year> <owner> >> where a real
#| notice carries a name. A pack's copy is the notice its author shipped
#| beside the binaries; an app naming a file has said "this exact text
#| accompanies my component", which for an OFL font with a Reserved Font
#| Name — or any licence whose text is completed per project — is a
#| different document from the template, not a formatting variant of it.
#| The generic text is what to fall back to when nobody supplied one, not
#| what to prefer over one somebody did.
#|
#| Two sources offering the same name with the same bytes is the ordinary
#| case — a licence text is a licence text — and one offering different
#| bytes warns, naming both, and keeps the higher-priority copy, because
#| the alternative is a bundle whose C<MIT.txt> depends on which
#| directory was walked first.
method text-pool(:@extra-dirs = (), :@extra-files = (), :@warnings = [] --> Hash) {
    my %pool;
    my %from;

    my sub offer(Str:D $label, Str:D $name, IO::Path $file) {
        with %pool{$name} -> $have {
            return if $have.absolute eq $file.absolute;
            return if $have.s == $file.s
                   && $have.slurp(:enc<latin-1>) eq $file.slurp(:enc<latin-1>);
            # The warning names the copy that is NOT used, which after
            # the app and the packs is usually ariza's own template.
            @warnings.push("two copies of $name differ: keeping"
                         ~ " {%from{$name}} ({$have.absolute}), not $label"
                         ~ " ({$file.absolute})");
            return;
        }
        %pool{$name} = $file;
        %from{$name} = $label;
    }

    for @extra-files -> $file {
        offer("the app's own copy", $file.basename, $file);
    }
    for @extra-dirs -> $dir {
        next unless $dir.d;
        for $dir.dir.grep({ .f && .basename.ends-with('.txt') }).sort(*.basename) {
            offer("a native pack's copy", .basename, $_);
        }
    }
    for resource-list(LICENSE-PREFIX).list -> $rel {
        offer("ariza's own text", $rel.split('/').tail, resource($rel));
    }

    %pool
}

# ---------------------------------------------------------------- #
# The document
# ---------------------------------------------------------------- #

#| The merged C<THIRD-PARTY.md>, as text. Deterministic: the same rows
#| render the same bytes, with nothing in it that changes between two
#| builds of the same inputs — no timestamp, no build host, no ordering
#| that depends on how a directory happened to be read.
method render(
    :@rows!,
    Str:D :$app-display!,
    Str:D :$app-version!,
    Str:D :$platform!,
    --> Str
) {
    my @view = @rows.map(-> %r {
        %(
            id        => %r<id>,
            name      => %r<name>,
            kind      => %r<kind>,
            heading   => (%r<version>.chars
                            ?? "{%r<name>} — {%r<version>}" !! %r<name>),
            version   => (%r<version>.chars ?? %r<version> !! '—'),
            spdx      => (%r<spdx>.chars ?? %r<spdx> !! 'unknown'),
            conveyed  => %r<conveyed>,
            declined  => spdx-not-asserted(%r<spdx>),
            copyright => %r<copyright>,
            url       => %r<url>,
            source    => %r<source>,
            notes     => %r<notes>,
            provenance => %r<provenance>,
            texts     => %r<license-files>.map({ "`{DIRECTORY}/$_`" }).join(', '),
            files     => %r<files>.map({ "`$_`" }).join(', '),
        )
    }).List;

    my $unknown = +@rows.grep({ !.<spdx>.chars });
    my $not-asserted = +@rows.grep({ spdx-not-asserted(.<spdx>) });
    my %ctx =
        app_display => $app-display,
        app_version => $app-version,
        platform    => $platform,
        rows        => @view,
        row_count   => +@view,
        row_word    => (+@view == 1 ?? 'component' !! 'components'),
        unknown     => $unknown,
        unknown_word => ($unknown == 1 ?? 'component' !! 'components'),
        noassertion  => $not-asserted,
        noassertion_word => ($not-asserted == 1 ?? 'component' !! 'components'),
        noassertion_verb => ($not-asserted == 1 ?? 'is' !! 'are'),
        licenses    => DIRECTORY,
    ;

    my $tpl = resource(TEMPLATE).slurp;
    my $out = Template::Jinja2.new.from-string($tpl).render(|%ctx);
    $out ~= "\n" unless $out.ends-with("\n");
    $out
}

#| Ingest everything, write C<THIRD-PARTY.md> and C<LICENSES/> at the
#| bundle root, and return what was found.
#|
#| Returns C<{ rows, warnings, summary, document, dir }>. C<summary> is
#| what goes into C<ariza-manifest.json>: the row count, how many of
#| them ariza could not attribute, and the set of SPDX identifiers the
#| bundle is conveyed under — which is the thing a release gate
#| downstream can actually test.
method write(
    IO() :$bundle-dir!,
    App::Ariza::Config:D :$config!,
    IO() :$app-dir!,
    Str:D :$app-version!,
    Str:D :$app-display!,
    Str:D :$platform!,
    :%placeholders = %(),
    :@conditions = (),
    :%files = %(),
    IO() :$data-path = resource(RUNTIME-RESOURCE),
    --> Hash
) {
    my @warnings;
    my $family = $platform.split('-').head;

    my %packs = self.pack-rows(
        :$bundle-dir, :$family, :@warnings,
        :claimed(self.runtime-claims(:path($data-path), :@conditions)),
        :strict($config.licensing-strict));

    my $app-license = self.app-license-file($app-dir);
    my $app-license-name = "{$config.app-name.subst('::', '-', :g)}.txt";

    my @app-files = $config.licensing-app<license-files>.defined
        ?? $config.licensing-app<license-files>.list.map({ self!app-file($app-dir, $_) })
        !! ();
    for $config.licensing-third-party.list -> %t {
        @app-files.append((%t<license-files> // ()).list.map({ self!app-file($app-dir, $_) }));
    }
    for $config.licensing-dists.list -> %d {
        @app-files.append((%d<license-files> // ()).list.map({ self!app-file($app-dir, $_) }));
    }

    my %texts = self.text-pool(:extra-dirs(%packs<texts>.list),
                               :extra-files(@app-files), :@warnings);
    # The app's own LICENSE, under a name of its own so it can never
    # collide with an SPDX-named text.
    %texts{$app-license-name} = $app-license if $app-license.defined;

    # `.append` per source, never `flat`: a row is a Hash, and flattening
    # a list of Hashes turns every one of them into its Pairs.
    my @rows;
    @rows.append(self.app-rows(:$config, :$app-dir, :$app-version, :%texts,
        :license-file($app-license.defined ?? $app-license-name !! Str)));
    @rows.append(self.runtime-rows(:%placeholders, :@conditions, :%files,
                                   :path($data-path)));
    @rows.append(%packs<rows>.list);
    @rows.append(self.site-rows(:$bundle-dir, :app-name($config.app-name),
                                :%texts, :overrides($config.licensing-dists.list)));

    my @merged = self.merge(@rows);

    # Strict means every component in this bundle names a licence, and a
    # declaration that one could not be found is not one. It is the same
    # rule the unattributed-pack check enforces, applied to the other way
    # a bundle can ship something nobody can name — and it is checked
    # here, centrally, because a NOASSERTION row can arrive from either
    # of the two places an app can write one.
    my @declined = @merged.grep({ spdx-not-asserted(.<spdx>) });
    die "ariza: {+@declined} component(s) are declared {NOASSERTION}, and"
      ~ " licensing.strict is on:\n"
      ~ @declined.map({ "    {.<name>} ({.<provenance>})" }).join("\n") ~ "\n"
      ~ "  {NOASSERTION} is an honest answer, and strict mode is the"
      ~ " statement that this bundle ships nothing it cannot name. Find the"
      ~ " licence and put it in the row, or turn licensing.strict off."
        if $config.licensing-strict && @declined;

    my $dir = ensure-dir($bundle-dir.add(DIRECTORY));
    my @cited = @merged.map({ .<license-files>.list }).flat.unique.sort;
    for @cited -> $name {
        my $src = %texts{$name}
            // die "ariza: a licensing row cites {DIRECTORY}/$name, and no"
                 ~ " such licence text is available.\n"
                 ~ "    ariza ships texts for"
                 ~ " {resource-list(LICENSE-PREFIX).map({ .subst('licenses/', '') })
                        .join(', ')};"
                 ~ " anything else has to come from a native pack's own"
                 ~ " LICENSES/ or from a license-files entry in the app's"
                 ~ " ariza.toml naming a file in its repository.";
        copy-writable($src, $dir.add($name));
    }

    # Anything left in LICENSES/ from an earlier build would be a text
    # this bundle does not cite, which is exactly as misleading as a
    # missing one.
    for $dir.dir.grep(*.f).sort(*.basename) -> $stale {
        $stale.unlink unless @cited.first($stale.basename);
    }

    my $document = $bundle-dir.add(DOCUMENT);
    $document.spurt(self.render(:rows(@merged), :$app-display, :$app-version,
                                :$platform));

    %(
        rows     => @merged,
        warnings => @warnings.List,
        document => $document,
        dir      => $dir,
        summary  => %(
            rows      => +@merged,
            unknown   => +@merged.grep({ !.<spdx>.chars }),
            # Counted apart from `spdx-ids` on purpose: NOASSERTION is
            # not a licence a bundle is conveyed under, so a gate reading
            # the identifier set must not see it as one — and a gate that
            # cares about undetermined components has a number of its own
            # to test.
            noassertion => +@declined,
            'spdx-ids' => @merged.map({ .<spdx> })
                            .grep({ .chars && !spdx-not-asserted($_) })
                            .map({ spdx-ids($_).Slip }).unique.sort.List,
            document  => DOCUMENT,
            licenses  => DIRECTORY,
        ),
    )
}

#| A file an app named in its C<ariza.toml>, resolved inside the app's
#| own repository. Relative, always: a licence text is part of the
#| repository that declares it, and an absolute path in a committed
#| config file is a path that exists on one machine.
method !app-file(IO::Path $app-dir, $rel --> IO::Path) {
    my $name = ~$rel;
    die "ariza: licensing license-files entries are paths inside the app's"
      ~ " repository, and \"$name\" is absolute"
        if $name.IO.is-absolute;
    my $path = $app-dir.add($name);
    die "ariza: ariza.toml names the licence text \"$name\", and there is no"
      ~ " such file in {$app-dir.absolute}"
        unless $path.f;
    $path
}

=begin pod

=head1 NAME

App::Ariza::Licensing - what a bundle redistributes, and under what terms

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Licensing;

my %l = App::Ariza::Licensing.write(
    :bundle-dir($work),
    :config($cfg),
    :app-dir($app),
    :app-version<0.2.0>,
    :app-display<Moneymoor>,
    :platform<macos-arm64>,
    :placeholders(%( 'rakudo-version' => '2026.07',
                     'rakudo-tag'     => '2026.07-01' )),
    :conditions(<sqlcipher>),
);

say %l<summary><rows>;        # 41
say %l<summary><spdx-ids>;    # (Apache-2.0 Artistic-2.0 BSD-2-Clause …)
.note for %l<warnings>;

# Just the identifiers in an expression:
say spdx-ids('GPL-3.0-or-later WITH GCC-exception-3.1');
# (GPL-3.0 GCC-exception-3.1)

=end code

=head1 DESCRIPTION

A bundle is a binary redistribution of other people's software: a
vendored Rakudo, the C libraries inside its MoarVM, every Raku
distribution in the closure, a native pack or two, SQLCipher where an app
asks for it, and — on Windows — a compiled launcher. This module
collects all of that into one C<THIRD-PARTY.md> at the bundle root and
one C<LICENSES/> directory beside it, and refuses to produce a bundle
whose contents it cannot account for.

=head2 Data, never code

ariza bundles B<anybody's> Raku application, so it cannot hold a table
of who wrote what. Every fact in the merged document comes from one of
four places, and none of them is a Raku source file:

=item1 B<A native pack's own licensing kit> — C<third-party.json> where
the pack ships one, its generated C<THIRD-PARTY.md> where it does not.
The pack knows what is in the pack.

=item1 B<C<resources/runtime-third-party.json>> — ariza's own maintained
record of the vendored runtime, MoarVM's vendored C libraries, SQLCipher
and the Windows runner. Those components have nowhere else to speak
from: they arrive as compiled bytes inside an archive with no manifest.

=item1 B<Each installed distribution's C<META6.json>> — the C<license>
field, read out of the bundle's own site repository I<and> the one
inside the vendored runtime, which is where C<zef> lives.

=item1 B<The app's C<ariza.toml>> — its own row, and rows for anything
it ships that ariza cannot see: a font, a dataset, an asset with a
licence of its own.

The 0.2.0 "recipe" work adds a fifth contributor without changing any of
this: a recipe describes a native dependency, and a native dependency's
licensing is rows in exactly the shape above.

=head2 What fails, and what warns

The rule is that B<silence is never an option>, and that the difference
between a warning and a failure is whether ariza has anything true to
say instead.

=item1 A native pack with B<no licensing kit at all> is a row saying
exactly that, and a warning on the build. It is not dropped, because a
redistributed binary nobody attributed is the thing this document exists
to make visible. C<licensing.strict = true> in the app's C<ariza.toml>
turns it into a failed build.

=item1 A pack whose C<THIRD-PARTY.md> is B<not in the generated shape>
falls back to the same unattributed row rather than to rows assembled
out of the wrong columns.

=item1 A distribution with B<no C<license> field>, or with one ariza has
no text for, B<fails the build> — naming B<every> offender in the
closure at once, not the first one, because an app whose closure has
three of them should learn that in one build rather than three. There is
no unknown row for a Raku module: the field exists, filling it in is a
one-line change, and an app that has hit a distribution which has not
can say so once with C<[[licensing.dists]]>.

=item1 A cited licence text that is B<nowhere to be found> fails the
build naming the identifier, what ariza ships, and how to supply one.

=item1 C<NOASSERTION> is a B<declaration>, not a gap, and only an app
can make it — in a C<[[licensing.dists]]> or
C<[[licensing.third-party]]> row, after looking and failing to find an
answer. No licence text is looked up for it (there is none), the row
carries a generated sentence saying so and pointing at the component's
own repository, and the manifest counts those rows separately from the
identifier set, so a gate never mistakes one for a permissive licence.
A distribution whose B<own metadata> says C<NOASSERTION> fails like any
other missing licence: nobody has looked yet. An B<application> that
declares it about itself fails outright — there is nobody to look on
its behalf. And C<licensing.strict> refuses the lot, because strict
means every component in the bundle names a licence and "we could not
find one" is not one.

=item1 Two sources offering the same licence text with B<different
bytes> warn, naming both, and keep the higher-priority copy — the app's
first, then a native pack's, then ariza's own template last — so the
document is the same on every machine and a real notice is never
replaced by a generic one.

=head2 The row

Every collector produces the same shape, which is what lets four sources
that know nothing about each other end up in one table:

=begin code :lang<raku>

%(
    id => 'notcurses/ffmpeg', name => 'FFmpeg', version => '8.1.2',
    kind => 'native',                  # application runtime native module other
    spdx => 'LGPL-2.1-or-later', conveyed => '',
    copyright => 'Copyright (c) 2000-2026 the FFmpeg developers',
    url => 'https://ffmpeg.org/', source => 'https://…/n8.1.2.tar.gz',
    notes => '', license-files => ('LGPL-2.1.txt',), files => ('libavcodec.*',),
    provenance => 'pack manifest (native/…/lib/third-party.json)',
)

=end code

C<provenance> is ariza's own addition to the pack format, and it is the
field a reader checks first: it says which of the four sources this row's
facts came from, so "who claims this?" has an answer that is not "the
tool".

=head2 Ordering

Rows are sorted by kind, then by name folded, then by id — never by the
order a directory happened to be read in. Two builds of the same inputs
produce byte-identical documents, which is what makes the output
diffable and the golden test meaningful.

=head1 METHODS

=head2 write(:$bundle-dir!, :$config!, :$app-dir!, :$app-version!, :$app-display!, :$platform!, :%placeholders, :@conditions, :%files, :$data-path --> Hash)

The whole job: collect, resolve every cited licence text, write
C<LICENSES/> and C<THIRD-PARTY.md>, and return
C<{ rows, warnings, summary, document, dir }>.

C<:@conditions> are the facts the runtime data file's C<condition> keys
are tested against (C<sqlcipher>, C<runner>); C<:%placeholders> the
values substituted into its C<{...}> tokens; C<:%files> the file names a
component turned out to cover, keyed by component id.

=head2 runtime-rows(:%placeholders, :@conditions, :%files, :$path --> List) / runtime-components(:$path --> List) / runtime-claims(:$path, :@conditions --> List)

The rows from C<resources/runtime-third-party.json>, the validated
components behind them, and the C<native/> subdirectory names those
components account for.

=head2 pack-rows(:$bundle-dir!, :$family!, :$native-dir, :@claimed, :$strict, :@warnings --> Hash)

C<{ rows, texts }> for every native pack staged into the bundle:
rows from each pack's own kit, and the C<LICENSES/> directories those
kits carry.

=head2 site-rows(:$bundle-dir!, :$app-name, :@overrides, :%texts! --> List)

One row per installed distribution, from both of the bundle's
repositories. Fails closed on a missing or unusable C<license> field.

=head2 app-rows(:$config!, :$app-dir!, :$app-version!, :%texts!, :$license-file --> List)

The application's own row and its C<[[licensing.third-party]]> rows.

=head2 md-components(Str $md --> List) / manifest-rows($manifest, :$family!, :$pack!, :$provenance! --> List)

The two readers for a native pack's kit: the JSON manifest, and the
generated document as a fallback. C<md-components> returns the empty
list for anything that is not in the exact generated shape.

=head2 find-kits(IO::Path $root, :$depth --> List) / kit-dir(IO() $dir --> Bool)

Where the licensing kits under a staged pack are, and what counts as
one.

=head2 text-pool(:@extra-dirs, :@extra-files, :@warnings --> Hash)

C<< filename => IO::Path >> for every licence text this build can cite,
in priority order: the app's, then the packs', then ariza's own
templates as the fallback.

=head2 render(:@rows!, :$app-display!, :$app-version!, :$platform! --> Str)

The merged document as text, with nothing in it that varies between two
builds of the same inputs.

=head2 merge(@rows --> List)

Sort into the document's order, and refuse two rows that claim the same
id.

=head2 spdx-ids(Str $expr --> List) / spdx-text-name(Str $id --> Str) / spdx-not-asserted(Str $expr --> Bool)

The identifiers in an SPDX expression, normalised; the file name one is
looked up as; and whether an expression is exactly C<NOASSERTION>. The
last is deliberately a whole-value test — C<"MIT OR NOASSERTION"> is not
a licence anyone can act on, so it falls through to the ordinary path
and fails for having no text.

=head1 SEE ALSO

L<App::Ariza::Bundle>, which calls this once per build and records its
summary in C<ariza-manifest.json>; L<App::Ariza::Config> for the
C<[licensing]> table an app writes.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
