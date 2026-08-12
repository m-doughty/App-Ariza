use JSON::Fast;

use App::Ariza::Config;
use App::Ariza::Tools;

unit class App::Ariza::Site;

# Notcurses-Native stages its prebuilt libraries under
# <data-dir>/Notcurses-Native/<BINARY_TAG>/lib. The tag is that
# distribution's business (it names a notcurses build, not a release of
# ours) and is read back off disk rather than pinned here.
my constant NOTCURSES-DIR = 'Notcurses-Native';

#| The module repository a bundle's Raku code is installed into.
method site-dir(IO() $bundle-dir --> IO::Path) { $bundle-dir.add('site') }

#| The directory native payloads are staged into, and the value
#| C<NOTCURSES_NATIVE_DATA_DIR> takes both at build time and at run time.
method native-dir(IO() $bundle-dir --> IO::Path) { $bundle-dir.add('native') }

#| The environment a bundled-runtime child process needs.
#|
#| Three deliberate choices:
#|
#|   * C<RAKULIB> names the bundle's own repository — during the install
#|     as well as afterwards. zef will happily install into a repository
#|     that is not in the chain, but it precompiles nothing when it does,
#|     and the user pays for all of it on first launch.
#|   * C<PERL6LIB> is *removed*, not blanked. An empty-but-set PERL6LIB
#|     makes Rakudo print a v6.e deprecation warning for the whole run.
#|   * C<NOTCURSES_NATIVE_DATA_DIR> — never C<NOTCURSES_NATIVE_LIB_DIR>,
#|     which suppresses Notcurses::Native's own C<TERMINFO_DIRS> setup
#|     and leaves the bundle without terminfo.
method child-env(IO() $bundle-dir --> Hash) {
    App::Ariza::Tools::child-env(
        RAKULIB   => 'inst#' ~ self.site-dir($bundle-dir).absolute,
        PERL6LIB  => Str,
        NOTCURSES_NATIVE_DATA_DIR => self.native-dir($bundle-dir).absolute,
    )
}

#| Every distribution installed in a bundle's site repository, as
#| C<{ name, version, auth, provides }> hashes sorted by name.
method installed-dists(IO() $bundle-dir --> List) {
    my $dist-dir = self.site-dir($bundle-dir).add('dist');
    return () unless $dist-dir.d;
    $dist-dir.dir.grep(*.f).map({
        my $meta = try { from-json(.slurp) };
        next without $meta;
        %(
            name     => $meta<name>,
            version  => $meta<ver> // $meta<version>,
            auth     => $meta<auth>,
            provides => ($meta<provides> // {}).keys.sort.List,
            depends  => ($meta<depends> // ()).list.grep(Str).List,
        )
    }).grep({ .<name>.defined }).sort(*.<name>).List
}

#| Install the app and its whole dependency closure into the bundle,
#| warm the precompilation store, and check the result.
#|
#| C<:$zef> is the B<bundled> runtime's zef wrapper — the one that came
#| out of L<App::Ariza::Rakudo>. Using the system zef here would compile
#| every module against the system Rakudo's bytecode version, and the
#| bundle would silently recompile the entire closure on first launch.
method build-site(
    IO() :$bundle-dir!,
    IO() :$app-source!,
    App::Ariza::Config:D :$config!,
    IO() :$zef!,
    IO() :$raku!,
    Int  :$attempts = 2,
    Bool :$verbose = True,
    --> Hash
) {
    die "ariza: no application source at $app-source" unless $app-source.d;
    die "ariza: no bundled zef at $zef" unless $zef.f;

    my $site   = ensure-dir(self.site-dir($bundle-dir));
    my $native = ensure-dir(self.native-dir($bundle-dir));
    my %env    = self.child-env($bundle-dir);

    self!zef-install($zef, $site, $app-source, %env, $attempts, $verbose);

    my @dists = self.installed-dists($bundle-dir);
    my %app = @dists.first({ .<name> eq $config.app-name })
        // die "ariza: {$config.app-name} is not in the bundle's site repository"
             ~ " after installing $app-source"
             ~ (@dists ?? " (installed: {@dists.map(*.<name>).join(', ')})" !! '');

    my @gaps = self.closure-gaps(@dists);
    die "ariza: the bundle's dependency closure is incomplete: {@gaps.join('; ')}"
        if @gaps;

    my $target = self.exec-target($site, :$config);
    my @warmed = self!warm-precomp($raku, %app<provides>, %env, $verbose);
    self!check-precomp($site, +@warmed);

    my $tag = self!notcurses-tag($native, $config);

    {
        site          => $site,
        native        => $native,
        dists         => @dists,
        app           => %app,
        app-version   => %app<version>,
        target        => $target,
        target-rel    => $target.relative($bundle-dir).subst('\\', '/', :g),
        notcurses-tag => $tag,
        notcurses-lib => ($tag.defined
            ?? $native.add(NOTCURSES-DIR).add($tag).add('lib')
            !! IO::Path),
        warmed        => @warmed.List,
    }
}

method !zef-install(IO::Path $zef, IO::Path $site, IO::Path $app-source,
                    %env, Int $attempts, Bool $verbose) {
    my @cmd = $zef.absolute, 'install', '--/test',
              '--to=inst#' ~ $site.absolute, $app-source.absolute;

    my $last-err = '';
    for 1..max($attempts, 1) -> $try {
        note "ariza: installing {$app-source.basename} into the bundle"
           ~ ($try > 1 ?? " (attempt $try)" !! '') if $verbose;
        my ($code, $out, $err) = try-run(@cmd, :%env);
        return if $code == 0;
        $last-err = ($err || $out).trim;
        # zef's own fetch step is the one genuinely flaky part of this:
        # a CDN hiccup aborts the whole install with "Aborting due to
        # fetch failure". Everything zef did before that point is
        # already installed, so re-running costs only the failed leg.
        last unless $last-err.contains('fetch failure')
                 || $last-err.contains('Failed to resolve');
    }
    die "ariza: zef could not install $app-source into $site"
      ~ ($last-err ?? ":\n" ~ $last-err.lines.map({ "    $_" }).join("\n") !! '');
}

#| Every installed distribution's `depends` that does not name another
#| installed distribution, as C<"A needs B"> strings.
#|
#| A gap means zef resolved a dependency against a repository outside the
#| bundle — the classic way a bundle works on the machine that built it
#| and nowhere else. Empty is the only acceptable answer, but it is
#| returned rather than thrown so the check is testable and so a caller
#| can report all of them at once.
method closure-gaps(@dists --> List) {
    my %installed = @dists.map({ .<name> => True });
    my @gaps;
    for @dists -> %d {
        for (%d<depends> // ()).list -> $dep {
            next unless $dep ~~ Str;
            # A dependency spec is `Name:ver<…>:auth<…>:api<…>`, and the
            # name itself contains `::`. Strip from the first adverb
            # rather than splitting on `:`, which turns JSON::Fast into
            # a dependency on "JSON".
            my $name = $dep.subst(/ ':' <[a..z]>+ '<' .* $ /, '').trim;
            next unless $name;
            @gaps.push("{%d<name>} needs $name") unless %installed{$name};
        }
    }
    @gaps.List
}

#| The script the launcher should hand to the bundled `raku`.
#|
#| zef installs two things per `bin/` script: a `sh`/`.bat` wrapper named
#| after the executable, and a `<name>.raku` stub that calls
#| C<CompUnit::RepositoryRegistry.run-script>. The wrapper is not usable
#| from a bundle — it execs a bare C<rakudo> found on C<PATH>, which on a
#| user's machine is either absent or the wrong Rakudo entirely — so the
#| stub is what the launcher targets, run by the bundled interpreter.
method exec-target(IO() $site, App::Ariza::Config:D :$config! --> IO::Path) {
    my $bin = $site.add('bin');
    die "ariza: the site repository has no bin/ directory at $bin" unless $bin.d;

    my $stub = $bin.add($config.app-exec ~ '.raku');
    return $stub if $stub.f;

    my $plain = $bin.add($config.app-exec);
    die "ariza: {$config.app-name} installed no '{$config.app-exec}' script"
      ~ " (bin/ has: {$bin.dir.map(*.basename).sort.join(', ')})"
        unless $plain.f;

    # No .raku stub means an older zef layout; the plain file is the
    # Raku script itself rather than a shell wrapper. Fall back to it,
    # but only after the stub, which is the shape every current zef
    # produces.
    $plain
}

#| Precompile the app's modules into the bundle's own precomp store.
#|
#| C<zef install --to=inst#…> does B<not> do this for us: it writes
#| sources and metadata, and the first process to load a module compiles
#| it. Left alone, the user's first launch pays for the entire closure —
#| measured at ~55s for Moneymoor against ~0.5s once warm — and pays it
#| again on every launch if the bundle sits somewhere unwritable.
#|
#| The store is content-addressed and position-independent, so warming it
#| here and shipping it works: a bundle unpacked at a different path (with
#| spaces in it) loads the same bytecode.
method !warm-precomp(IO::Path $raku, @modules, %env, Bool $verbose --> List) {
    return () unless @modules;
    note "ariza: precompiling {+@modules} modules into the bundle" if $verbose;

    my @todo = @modules.List;
    my @done;
    my @failed;

    # Each module is loaded by a child that reports progress as it goes,
    # so a module that takes the process down with it (rather than
    # throwing something `try` can catch) costs only itself: the parent
    # resumes at the next one.
    while @todo {
        # `$*REPO.need` rather than `require ::($mod)`: it is the exact
        # primitive `use` compiles down to, so it precompiles the same
        # way, and it does not try to bind a symbol of that name into
        # the current scope — which `require` does, and which fails
        # ("No such symbol") for any module that declares no package
        # matching its own filename.
        my $prog = q:to/RAKU/;
            for @*ARGS -> $mod {
                my $ok = True;
                {
                    CATCH { default { $ok = False; note "ariza-warm-error $mod: {.message.lines.head}" } }
                    $*REPO.need(CompUnit::DependencySpecification.new(:short-name($mod)));
                }
                say ($ok ?? 'ariza-warm-ok ' !! 'ariza-warm-fail ') ~ $mod;
                $*OUT.flush;
            }
            RAKU

        my ($code, $out, $err) = try-run(
            [$raku.absolute, '-e', $prog, |@todo], :%env);

        my %seen;
        for $out.lines -> $line {
            if $line ~~ / ^ 'ariza-warm-' (ok|fail) ' ' (.+) $ / {
                %seen{~$1} = True;
                ~$0 eq 'ok' ?? @done.push(~$1) !! @failed.push(~$1);
            }
        }

        my @rest = @todo.grep({ !%seen{$_} });
        if @rest == @todo {
            # The child made no progress at all: re-running would loop.
            die "ariza: precompiling the bundle's modules made no progress"
              ~ " (exit $code)"
              ~ ($err.trim ?? ":\n" ~ $err.trim.lines.map({ "    $_" }).join("\n") !! '');
        }
        @todo = @rest;
    }

    die "ariza: {+@failed} module(s) in the bundle do not load:"
      ~ "\n" ~ @failed.map({ "    $_" }).join("\n")
      ~ "\n  The dependency closure or a native library is missing from the bundle."
        if @failed;

    @done.List
}

#| A precomp store that exists but is empty means the warm-up silently
#| did nothing, which looks identical to success until a user's first
#| launch takes a minute. One artefact per module warmed is the floor.
method !check-precomp(IO::Path $site, Int $warmed) {
    my $precomp = $site.add('precomp');
    die "ariza: the bundle has no precompilation store at $precomp"
        unless $precomp.d;

    my @files = self!files-under($precomp);
    my $bytes = @files.map(*.s).sum;

    die "ariza: the bundle's precompilation store holds {+@files} files"
      ~ " for $warmed warmed modules — the warm-up did not take"
        if @files < $warmed;
    die "ariza: the bundle's precompilation store is empty"
        unless $bytes > 0;
}

method !files-under(IO::Path $dir --> List) {
    return () unless $dir.d;
    my @out;
    my @queue = $dir;
    while @queue {
        my $d = @queue.shift;
        for $d.dir -> $e {
            next if $e.l;
            $e.d ?? @queue.push($e) !! @out.push($e);
        }
    }
    @out.List
}

#| The C<BINARY_TAG> Notcurses-Native staged under, read back off disk.
#|
#| Never hardcoded: the tag names a notcurses build
#| (C<binaries-notcurses-3.0.17-r9>) and changes whenever that
#| distribution rebuilds its libraries. Absent is only acceptable when
#| the app never asked for notcurses.
method !notcurses-tag(IO::Path $native, App::Ariza::Config:D $config --> Str) {
    my $wants = so $config.bundle-native.list.first('notcurses');
    my $root  = $native.add(NOTCURSES-DIR);

    unless $root.d {
        die "ariza: {$config.app-name} declares native 'notcurses' but"
          ~ " nothing was staged into $root — check that the app's"
          ~ " dependency closure really includes Notcurses::Native"
            if $wants;
        return Str;
    }

    my @tags = $root.dir.grep(*.d).map(*.basename).sort;
    die "ariza: $root holds {+@tags} notcurses builds ({@tags.join(', ')});"
      ~ " expected exactly one"
        unless @tags == 1;

    my $lib = $root.add(@tags[0]).add('lib');
    my @libs = $lib.d ?? $lib.dir.grep({ !.d }) !! ();
    die "ariza: the staged notcurses build at $lib is empty" unless @libs;

    @tags[0]
}

=begin pod

=head1 NAME

App::Ariza::Site - install the app and its closure into the bundle's own module repository

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Site;

my %site = App::Ariza::Site.build-site(
    :bundle-dir($work),
    :app-source('/path/to/App-Moneymoor'),
    :config($cfg),
    :zef(%rt<zef>),     # from App::Ariza::Rakudo.provision
    :raku(%rt<raku>),
);

say %site<target-rel>;      # site/bin/moneymoor.raku
say %site<app-version>;     # 0.2.0
say %site<notcurses-tag>;   # binaries-notcurses-3.0.17-r9
say +%site<dists>;          # 8
say +%site<warmed>;         # 50

=end code

=head1 DESCRIPTION

The bundle's Raku code lives in one C<CompUnit::Repository::Installation>
at C<< <bundle>/site >>, and nothing else — no user repository, no
system repository, no C<~/.raku>. This module fills it.

=head2 The install has to run under the bundled runtime

C<zef> is invoked as C<< <bundle>/rakudo/share/perl6/site/bin/zef >>: the
copy that came down inside the runtime archive. That wrapper is a
B<shell script> which locates its sibling C<raku> relocatably and execs
it, so it is run directly — feeding it to C<bin/raku> as if it were a
Raku script is a syntax error.

Using the I<system> zef instead would work, and would produce a bundle
that recompiles its entire closure on first launch, because precompiled
bytecode is tied to the exact Rakudo that produced it.

=head2 RAKULIB during the install, not just after it

The site repository is named in C<RAKULIB> for the C<zef> child as well
as C<--to>. zef installs into a repository that is not in the chain
perfectly happily — and precompiles nothing at all when it does. With
the target in the chain some precompilation happens during install; the
rest is done explicitly (below).

C<PERL6LIB> is B<removed> from the child environment rather than set
empty, because an empty-but-set C<PERL6LIB> makes Rakudo print a v6.e
deprecation warning across the whole run.

=head2 Warming the precompilation store

Even with the repository in the chain, C<zef install> leaves most of the
closure uncompiled: the first process to C<use> a module is what
compiles it. Shipping that state means the user's first launch compiles
everything — measured at B<~55 seconds> for Moneymoor, against B<~0.5s>
once warm — and pays it again on every launch if the bundle lives
somewhere unwritable, which for a downloaded archive is entirely normal.

So C<build-site> loads every module the app distribution C<provides>,
under the bundled runtime, with the bundle's environment. That pulls the
transitive closure (Selkie, DBIish, Notcurses::Native…) into the store
as a side effect of loading what actually uses it.

The store is content-addressed and position-independent: warming it at
build time and unpacking the bundle somewhere else entirely — including
a path with spaces — loads the same bytecode. That is verified, not
assumed.

Loading happens in a child that reports each module as it finishes, so a
module that takes the process down rather than throwing something
catchable costs only itself; the parent resumes at the next one. A
module that fails to load is B<fatal>: at this point every dependency is
supposed to be in the bundle, so a load failure is the closure being
incomplete, which is exactly the bug a bundle exists to prevent.

=head2 What is checked before the bundle is called good

=item1 The app distribution is in the site repository, by the name
declared in C<ariza.toml> (which is also where its version comes from —
the app's own C<META6.json> as installed).

=item1 Every installed distribution's C<depends> names another installed
distribution. A gap means zef satisfied something from a repository
outside the bundle: the classic bundle that runs only on the machine
that built it.

=item1 Every module the app provides loads.

=item1 The precomp store holds at least one artefact per module warmed,
and is not empty.

=item1 Notcurses-Native staged a non-empty library directory, if the app
asked for notcurses in C<bundle.native>.

=head2 The notcurses tag is read, never written

Notcurses::Native's C<Build.rakumod> stages its prebuilt libraries to
C<< <NOTCURSES_NATIVE_DATA_DIR>/Notcurses-Native/<BINARY_TAG>/lib >>.
Pointing that variable at C<< <bundle>/native >> during the install puts
them straight into the bundle, and pointing it at the same place at run
time is how they are found again — which is the launcher's job.

The tag (C<binaries-notcurses-3.0.17-r9>) names a notcurses build, not
anything of ariza's, and changes whenever that distribution rebuilds. It
is read back off disk after the install and carried into the manifest.
Exactly one staged tag is expected; more than one means a stale build is
in the bundle and is an error rather than a coin toss.

Note C<NOTCURSES_NATIVE_DATA_DIR> and not C<NOTCURSES_NATIVE_LIB_DIR>:
the latter suppresses the module's own C<TERMINFO_DIRS> setup, and a TUI
without terminfo is a blank screen.

=head1 METHODS

=head2 build-site(:$bundle-dir!, :$app-source!, :$config!, :$zef!, :$raku!, :$attempts, :$verbose --> Hash)

Install, warm, check. Returns C<site>, C<native>, C<dists>, C<app>,
C<app-version>, C<target>, C<target-rel>, C<notcurses-tag>,
C<notcurses-lib> and C<warmed>.

C<:$attempts> (default 2) retries the C<zef> run, but B<only> when the
failure looks like a fetch or resolution problem — a CDN hiccup aborts
the whole install with "Aborting due to fetch failure", and everything
zef completed before that point is already installed, so the retry costs
only the failed leg. A compile error is not retried.

=head2 The launcher's target

C<target-rel> is the path, relative to the bundle root, that the
launcher hands to the bundled C<raku>: C<site/bin/E<lt>execE<gt>.raku>.

zef installs two files per C<bin/> script — a C<sh> (or C<.bat>) wrapper
named after the executable, and a C<E<lt>nameE<gt>.raku> stub calling
C<CompUnit::RepositoryRegistry.run-script>. The wrapper is useless in a
bundle: it execs a bare C<rakudo> off C<PATH>, which on a user's machine
is absent or is a different Rakudo. The stub, run by the bundled
interpreter with C<RAKULIB> pointing at the bundle, is the correct
target.

=head2 exec-target(IO() $site, :$config! --> IO::Path)

The script the launcher hands to the interpreter: the C<.raku> stub if
zef installed one, else the plain C<bin/E<lt>execE<gt>> file. Dies
listing what C<bin/> does contain when neither exists.

=head2 closure-gaps(@dists --> List)

Every C<"A needs B"> where B is not installed in the bundle. Returned
rather than thrown so all of them can be reported at once — and so the
rule is testable without building anything.

The dependency name is taken by stripping from the first C<:adverb<>>,
not by splitting on C<:>, which would turn a dependency on
C<JSON::Fast> into one on C<JSON>.

=head2 installed-dists(IO() $bundle-dir --> List)

C<{ name, version, auth, provides, depends }> for every distribution in
the site repository, sorted by name. Read from the repository's own C<dist/>
metadata, so it describes what is B<in the bundle> rather than what the
app asked for.

=head2 child-env(IO() $bundle-dir --> Hash) / site-dir / native-dir

The environment a bundled-runtime child needs, and the two directories
it names.

=head1 SEE ALSO

L<App::Ariza::Rakudo> for the runtime this installs into,
L<App::Ariza::Launcher> for the run-time twin of C<child-env>.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
