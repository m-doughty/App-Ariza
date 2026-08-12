use JSON::Fast;

use App::Ariza::Native;
use App::Ariza::Tools;

unit class App::Ariza::Smoke;

# Deliberately awkward: a bundle that only works from a path without
# spaces is broken for half of macOS ("My Documents", "Application
# Support") and every Windows user. If the launcher's quoting slips,
# this is what notices.
my constant SCRATCH-PREFIX = 'ariza smoke ';

#| A scratch directory with a space in its name, under C<:$work-dir>
#| (C<$*TMPDIR> by default).
method scratch-dir(IO() :$work-dir = $*TMPDIR --> IO::Path) {
    ensure-dir($work-dir).add(SCRATCH-PREFIX ~ "{$*PID}-{(^1_000_000).pick}")
}

#| The environment a bundle is entitled to assume, and nothing else.
#|
#| Not a filtered copy of the caller's environment — a replacement.
#| C<run>'s C<:env> substitutes the child's environment wholesale, which
#| is C<env -i> without needing C<env>. That matters because the failure
#| this check exists to catch is a bundle that quietly uses something
#| from the developer's shell: a system Rakudo on C<PATH>, a
#| C<DBIISH_SQLCIPHER_LIB> pointing at Homebrew, a C<RAKULIB> with the
#| app already installed in it.
method base-env(--> Hash) {
    my %env = PATH => ($*DISTRO.is-win ?? %*ENV<PATH> // '' !! '/usr/bin:/bin');
    %env<HOME> = ~$_ with %*ENV<HOME>;
    %env<TERM> = ~$_ with %*ENV<TERM>;
    # Windows processes cannot start without these; they are not
    # "the user's environment" in any meaningful sense.
    for <SystemRoot windir TEMP TMP USERPROFILE> -> $k {
        %env{$k} = ~$_ with %*ENV{$k};
    }
    %env
}

#| The extra variables the launcher would have exported, for commands
#| that run the bundled interpreter directly instead of going through it.
method runtime-env(IO() $root, %manifest --> Hash) {
    my %env =
        RAKULIB => 'inst#' ~ $root.add('site').absolute,
        NOTCURSES_NATIVE_DATA_DIR => $root.add('native').absolute,
    ;
    with %manifest<components><sqlcipher><path> -> $rel {
        my $platform = %manifest<platform> // '';
        my $lib = $root.add($rel);
        if $platform.starts-with('windows') {
            # Windows has no loader-time library path — a DLL is found
            # by walking PATH, the same way the launcher templates do it.
            # base-env's own Windows PATH *is* %*ENV<PATH> verbatim (see
            # above), so prepending onto that here — rather than onto
            # whatever base-env computed — lands on the same value while
            # keeping this method self-contained.
            %env<DBIISH_SQLCIPHER_LIB> = $lib.absolute;
            %env<PATH> = $lib.parent.absolute
                ~ (%*ENV<PATH> ?? ';' ~ %*ENV<PATH> !! '');
        }
        elsif !$platform.starts-with('macos') {
            %env<DBIISH_SQLCIPHER_LIB> = $lib.absolute;
            %env<LD_LIBRARY_PATH> = $lib.parent.absolute;
        }
    }
    %env
}

#| Unpack a bundle archive and prove it works somewhere it has never been.
#|
#| Returns C<{ passed, checks, dir, root, manifest }>. Every check runs;
#| nothing short-circuits, because "the launcher failed" and "the
#| launcher failed I<and> the audit found a stray library" are different
#| bug reports.
method smoke(
    IO() :$archive!,
    IO() :$work-dir = $*TMPDIR,
    Bool :$keep = False,
    Bool :$verbose = True,
    --> Hash
) {
    die "ariza: no bundle archive at $archive" unless $archive.f;

    my $dir = self.scratch-dir(:$work-dir);
    my @checks;
    my $root;
    my %manifest;

    my $ok = True;
    {
        CATCH {
            default {
                # `%( )`, and the message bound first: a `{ }` literal
                # containing a `.method` call is parsed as a Block, not a
                # Hash, and lands in the results as an uncallable closure.
                my $why = .message;
                my $where = @checks ?? 'manifest' !! 'unpack';
                @checks.push(%( name => $where, ok => False, detail => $why ));
                $ok = False;
            }
        }
        note "ariza: unpacking into $dir" if $verbose;
        extract-archive($archive, $dir);
        $root = sole-child($dir);
        die "ariza: {$archive.basename} does not contain a bundle directory"
            unless $root.d;
        @checks.push({ name => 'unpack', ok => True,
                       detail => "extracted to {$root.basename}" });

        my $mf = $root.add('ariza-manifest.json');
        die "ariza: no ariza-manifest.json in the bundle" unless $mf.f;
        %manifest = from-json($mf.slurp);

        # The manifest is the only thing here that describes the bundle,
        # so its shape is checked rather than assumed. `dists` in
        # particular has to be a list of objects: a Raku `{ }` literal
        # whose body starts with a `.method` call is a Block, and one of
        # those quietly serialises as an array of one-key objects — a
        # manifest that parses, reads plausibly, and lists nothing.
        die "ariza: ariza-manifest.json has no app.name"
            unless (%manifest<app> // {})<name>;
        for (%manifest<dists> // ()).list -> $d {
            die "ariza: ariza-manifest.json lists a distribution that is not"
              ~ " an object with a name"
                unless $d ~~ Associative && $d<name>;
        }

        @checks.push({ name => 'manifest', ok => True,
                       detail => "{%manifest<app><name>} {%manifest<app><version>}"
                               ~ ", {+(%manifest<dists> // ()).list} distributions"
                               ~ " for {%manifest<platform>}" });
    }

    if $root.defined && %manifest {
        @checks.append: self!layout-checks($root, %manifest);
        @checks.append: self!audit-check($root, %manifest);
        @checks.append: self!command-checks($root, %manifest, $verbose);
    }

    $ok = !@checks.first({ !.<ok> });

    # A failed smoke leaves the tree behind: the whole value of the
    # check is the state it failed in, and deleting it means the next
    # person has to reproduce a build to see anything.
    if $ok && !$keep {
        rm-rf($dir);
    }
    elsif $verbose {
        note "ariza: bundle left unpacked at $dir";
    }

    {
        passed   => $ok,
        checks   => @checks.List,
        dir      => $dir,
        root     => $root,
        manifest => %manifest,
        kept     => (!$ok || $keep),
    }
}

method !layout-checks(IO::Path $root, %manifest --> List) {
    my @checks;
    my $exec = %manifest<app><exec> // '';
    my $win  = (%manifest<platform> // '').starts-with('windows');

    my $launcher = $root.add('bin').add($exec ~ ($win ?? '.cmd' !! ''));
    @checks.push({
        name => 'launcher',
        ok => ($launcher.f && ($win || $launcher.x)),
        detail => $launcher.f
            ?? ($win || $launcher.x ?? "bin/{$launcher.basename}"
                                    !! "bin/{$launcher.basename} is not executable")
            !! "missing bin/{$launcher.basename}",
    });

    # The compiled Windows launcher, when the bundle carries one. Its
    # absence is not a failure — a bundle built before the first runner
    # release was pinned ships the scripts alone, and that is a
    # deliberate state rather than a broken one — but a runner without
    # its sidecar is a bundle that cannot start, so the two are checked
    # together and reported as one.
    if $win {
        my $runner  = $root.add('bin').add("$exec.exe");
        my $sidecar = $root.add('bin').add("$exec.ariza");
        @checks.push({
            name => 'runner',
            ok => (!$runner.f || $sidecar.f),
            detail => $runner.f
                ?? ($sidecar.f
                    ?? "bin/$exec.exe with bin/$exec.ariza beside it"
                    !! "bin/$exec.exe has no bin/$exec.ariza to read")
                !! "no bin/$exec.exe — this bundle launches from bin/$exec.cmd",
        });
    }

    my $raku = $root.add('rakudo').add('bin').add($win ?? 'raku.exe' !! 'raku');
    @checks.push({
        name => 'runtime',
        ok => $raku.f,
        detail => $raku.f ?? "rakudo {%manifest<components><rakudo><tag> // '?'}"
                          !! "missing {$raku.relative($root)}",
    });

    my $target = $root.add(%manifest<launcher><target> // 'site');
    @checks.push({
        name => 'target',
        ok => $target.f,
        detail => $target.f ?? ~(%manifest<launcher><target>)
                            !! "missing {%manifest<launcher><target> // '(none recorded)'}",
    });

    my $precomp = $root.add('site').add('precomp');
    my $files = $precomp.d ?? self!count-files($precomp) !! 0;
    @checks.push({
        name => 'precomp',
        ok => $files > 0,
        detail => $files > 0
            ?? "$files precompiled artefacts ship with the bundle"
            !! 'the precompilation store is empty — first launch will compile everything',
    });

    @checks.List
}

method !audit-check(IO::Path $root, %manifest --> List) {
    my @extra;
    with %manifest<components><sqlcipher><path> -> $rel {
        my $lib = $root.add($rel);
        if $lib.f {
            @extra.push($lib);
            # A macOS SQLCipher drags its OpenSSL in beside it, in
            # rakudo/lib. Everything in there that is not libmoar is
            # something ariza put there, and is ariza's to answer for;
            # the runtime's own files came out of the upstream archive
            # untouched and are not this audit's business.
            @extra.append: $lib.parent.dir.grep({
                .f && !.l && !.basename.starts-with('libmoar')
            });
        }
    }

    my %result;
    my $ok = True;
    my $detail;
    {
        CATCH {
            default {
                $ok = False;
                $detail = .message;
            }
        }
        %result = App::Ariza::Native.audit(
            :bundle-dir($root), :slug(%manifest<platform> // ''), :extra(@extra));
        $detail = "{%result<checked>} native binaries resolve inside the bundle";
    }
    ({ name => 'native-audit', ok => $ok, detail => $detail },)
}

method !command-checks(IO::Path $root, %manifest, Bool $verbose --> List) {
    my @argvs = (%manifest<smoke> // ()).list.map(*.list.map(~*).List);
    return ({ name => 'smoke-commands', ok => True,
              detail => 'the app declares none' },) unless @argvs;

    my $exec = %manifest<app><exec> // '';
    my $win  = (%manifest<platform> // '').starts-with('windows');
    my $tmp  = ensure-dir($root.parent.add('scratch'));

    # The compiled launcher, where the bundle has one. Every {exec}
    # command is run a second time through it — in addition to the .cmd,
    # never instead of it — because the two are separate implementations
    # of one contract and a bundle ships both.
    my $runner = $win ?? $root.add('bin').add("$exec.exe") !! IO::Path;

    my %vars =
        exec   => $root.add('bin').add($exec ~ ($win ?? '.cmd' !! '')).absolute,
        raku   => $root.add('rakudo').add('bin').add($win ?? 'raku.exe' !! 'raku').absolute,
        site   => $root.add('site').absolute,
        native => $root.add('native').absolute,
        bundle => $root.absolute,
        tmp    => $tmp.absolute,
    ;

    my %base    = self.base-env;
    my %runtime = %base, self.runtime-env($root, %manifest);

    my @checks;
    for @argvs.kv -> $i, @raw {
        my @argv = @raw.map(-> $word {
            my $out = $word;
            $out = $out.subst("\{$_\}", ~%vars{$_}, :g) for %vars.keys;
            $out
        });

        if @argv.grep(/ '{' <[a..z-]>+ '}' /) {
            @checks.push({
                name => "smoke[$i]", ok => False,
                detail => "unresolved placeholder in: {@raw.join(' ')}",
            });
            next;
        }

        # Going through the launcher is a test *of* the launcher, so it
        # gets nothing but HOME/TERM/PATH. A command that drives the
        # bundled interpreter directly is standing in for code running
        # inside the app, so it gets what the launcher would have
        # exported — otherwise it would be testing the absence of a
        # launcher rather than the bundle.
        my %env = @raw.head eq '{raku}' ?? %runtime !! %base;

        @checks.push(self!run-check("smoke[$i]", @raw, @argv, %env, $verbose));

        # The same command again through bin/<exec>.exe. The scripts and
        # the executable set the same environment by two entirely
        # different routes — batch `set` against SetEnvironmentVariableW,
        # `%*` against a verbatim command-line tail — so proving one says
        # nothing about the other, and the executable is the one a user
        # will actually run.
        next unless $runner.defined && $runner.f && @raw.head eq '{exec}';
        my @exe-argv = @argv;
        @exe-argv[0] = $runner.absolute;
        @checks.push(self!run-check("smoke[$i].exe", @raw, @exe-argv,
                                    %env, $verbose));
    }
    @checks.List
}

#| Run one resolved smoke command and report it. C<@raw> is the
#| unexpanded argv, which is what a reader recognises; C<@argv> is what
#| is actually run.
method !run-check(Str $name, @raw, @argv, %env, Bool $verbose --> Hash) {
    note "ariza: running $name ({@raw.head}) …" if $verbose;
    my ($code, $out, $err) = try-run(@argv, :%env);
    my $summary = ($out.trim || $err.trim).lines.grep(*.trim).head // '';
    %(
        name   => $name,
        ok     => $code == 0,
        detail => $code == 0
            ?? "{@raw.head} → exit 0" ~ ($summary ?? ": $summary" !! '')
            !! "{@raw.join(' ').substr(0, 60)} → exit $code\n"
             ~ ($err.trim || $out.trim).lines.head(8).map({ "        $_" }).join("\n"),
        output => $out,
    )
}

method !count-files(IO::Path $dir --> Int) {
    my $n = 0;
    my @queue = $dir;
    while @queue {
        my $d = @queue.shift;
        for $d.dir -> $e {
            next if $e.l;
            $e.d ?? @queue.push($e) !! $n++;
        }
    }
    $n
}

=begin pod

=head1 NAME

App::Ariza::Smoke - prove a built bundle works somewhere it has never been

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Smoke;

my %r = App::Ariza::Smoke.smoke(:archive($tarball));

say %r<passed>;                     # True
for %r<checks> -> %c {
    say "{%c<ok> ?? 'ok  ' !! 'FAIL'} {%c<name>}: {%c<detail>}";
}
# ok   unpack: extracted to moneymoor-0.2.0-macos-arm64
# ok   manifest: App::Moneymoor 0.2.0 for macos-arm64
# ok   launcher: bin/moneymoor
# ok   runtime: rakudo 2026.07-01
# ok   target: site/bin/moneymoor.raku
# ok   precomp: 395 precompiled artefacts ship with the bundle
# ok   native-audit: 32 native binaries resolve inside the bundle
# ok   smoke[0]: {exec} → exit 0: App::Moneymoor 0.2.0
# ok   smoke[1]: {raku} → exit 0: ok: encrypted database created …

=end code

=head1 DESCRIPTION

A build that finishes is not a build that works. C<smoke> takes the
archive, unpacks it somewhere the build never touched, and runs it the
way a stranger would.

=head2 The scratch directory has a space in its name

On purpose. C<ariza smoke 51234-882931/> is where the bundle goes, and
if the launcher's quoting slips anywhere, that is what notices — before
a user with C<~/Application Support/> or C<C:\Program Files\> does.

=head2 The environment is replaced, not filtered

C<run>'s C<:env> substitutes the child's whole environment, which is
C<env -i> without needing C<env>. Commands get C<PATH=/usr/bin:/bin>,
C<HOME> and C<TERM> (plus C<SystemRoot> and friends on Windows, without
which no process starts at all) — and nothing else.

That is the entire point. The failure this catches is a bundle that
quietly relies on the developer's shell: a system Rakudo on C<PATH>, a
C<DBIISH_SQLCIPHER_LIB> pointing into Homebrew, a C<RAKULIB> that
already has the app installed in it. Any of those makes a broken bundle
look perfect on the machine that built it.

=head3 Two environments, for two kinds of command

A command that starts with C<{exec}> goes through the B<launcher>, so it
gets the bare environment above: that run is a test of the launcher's
ability to set up its own world.

A command that starts with C<{raku}> drives the bundled interpreter
directly. It is standing in for code running I<inside> the app, so it
additionally gets exactly what the launcher would have exported —
C<RAKULIB>, C<NOTCURSES_NATIVE_DATA_DIR>, and the SQLCipher variables:
C<LD_LIBRARY_PATH> on Linux, and on Windows a C<PATH> prepended with the
DLL's directory, since that is how Windows resolves a library by name.
C<DBIISH_SQLCIPHER_LIB> is set on both, exactly as the launcher templates
set it. Without any of that it would be testing the absence of a
launcher rather than the bundle.

=head2 Placeholders

Smoke commands come from the bundle's own C<ariza-manifest.json>, so an
archive can be checked with no access to the app's repository. Each argv
word is expanded against:

=item1 C<{exec}> — the launcher
=item1 C<{raku}> — the bundled interpreter
=item1 C<{site}> — the module repository
=item1 C<{native}> — the staged native libraries
=item1 C<{bundle}> — the bundle root
=item1 C<{tmp}> — a writable scratch directory beside the unpacked bundle

Nothing goes through a shell, so a smoke command can contain an entire
Raku program without a quoting layer to get wrong — which is what makes
it reasonable for an app to smoke-test its database engine and not just
C<--version>. See L<App::Ariza::Config> for how to write one.

=head2 The checks

=item1 B<unpack> — the archive extracts to exactly one directory.
=item1 B<manifest> — C<ariza-manifest.json> is present, readable, and
the right B<shape>: it names an app, and every entry in C<dists> is an
object with a name. That last one is not paranoia. A Raku C<{ }> literal
whose body starts with a C<.method> call is parsed as a I<Block>, and a
Block of pairs serialises as an array of one-key objects — producing a
manifest that parses, reads plausibly, and lists nothing at all.
=item1 B<launcher> — C<< bin/<exec> >> exists and is executable.
=item1 B<runner> — Windows only: C<< bin/<exec>.exe >> and its
C<< bin/<exec>.ariza >> sidecar. Their B<absence> passes and says so —
a bundle built before the first runner release was pinned launches from
its C<.cmd> and is not broken — but an executable with no sidecar to
read is a bundle that cannot start, so the pair is checked together.
=item1 B<runtime> — the bundled interpreter is there.
=item1 B<target> — the script the launcher execs is there.
=item1 B<precomp> — the precompilation store shipped warm. An empty one
is not a crash, so nothing else would catch it; it just makes every
launch slow, forever, on a read-only bundle.
=item1 B<native-audit> — L<App::Ariza::Native>'s audit, re-run over the
B<unpacked> tree rather than the build directory, because that is the
tree a user has.
=item1 B<smoke[n]> — each declared command, in order.
=item1 B<smoke[n].exe> — on Windows, each C<{exec}> command again
through C<< bin/<exec>.exe >>, when the bundle carries one. In addition
to the C<.cmd> run, never instead of it: the script and the executable
implement one contract by two completely different routes — batch
C<set> against C<SetEnvironmentVariableW>, C<%*> against a verbatim
command-line tail — so a passing script says nothing at all about the
executable, and the executable is the one a user will actually run.

Every check runs; nothing short-circuits. "The launcher failed" and "the
launcher failed I<and> the audit found a stray library" are different
bug reports and should not require two runs to distinguish.

=head2 Failure leaves the evidence

On success the scratch directory is removed. On failure — or with
C<:keep> — it stays, and its path is printed. The whole value of a
failed smoke is the state it failed in; deleting it means reproducing a
build to see anything.

=head1 METHODS

=head2 smoke(:$archive!, :$work-dir, :$keep, :$verbose --> Hash)

C<{ passed, checks, dir, root, manifest, kept }>. Each check is
C<{ name, ok, detail }>, and command checks also carry C<output>.

=head2 base-env(--> Hash) / runtime-env(IO() $root, %manifest --> Hash)

The replacement environment, and the launcher-equivalent additions.

=head2 scratch-dir(:$work-dir --> IO::Path)

A fresh directory with a space in its name.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
