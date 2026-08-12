unit module App::Ariza::Tools;

#| Create `$dir` and every missing parent, and hand it back. Idempotent:
#| an existing directory is fine, an existing *file* at that path is not.
our sub ensure-dir(IO() $dir --> IO::Path) is export {
    die "ariza: $dir exists and is not a directory" if $dir.e && !$dir.d;
    $dir.mkdir unless $dir.d;
    die "ariza: could not create directory $dir" unless $dir.d;
    $dir
}

#| Recursively remove a file, directory or symlink. Missing paths are not
#| an error, so this is safe as a `LEAVE` cleanup.
#|
#| Symlinked directories are unlinked rather than descended into — a
#| bundle contains symlinks (`libsqlcipher.dylib` next to
#| `libsqlcipher.0.dylib`) and following one out of the tree while
#| deleting is how a cleanup becomes an incident.
our sub rm-rf(IO() $path) is export {
    return unless $path.e || $path.l;
    if $path.l || !$path.d {
        $path.unlink;
        return;
    }
    rm-rf($_) for $path.dir;
    $path.rmdir;
}

#| Run a command, capturing both streams. Returns
#| C<(exitcode, stdout, stderr)> and never throws for a non-zero exit —
#| this is the form for probes ("is there an `otool`?"), where failure is
#| an answer rather than an error.
#|
#| C<:%env> replaces the child's whole environment when given; C<:$cwd>
#| its working directory. A command that cannot be spawned at all comes
#| back as exit code -1 with the reason on the captured C<stderr>, so a
#| missing binary and a failing binary are handled by the same code.
our sub try-run(@cmd, :%env, :$cwd --> List) is export {
    my %opts = :out, :err;
    %opts<env> = %env if %env;
    %opts<cwd> = $cwd if $cwd.defined;
    my $proc = try { run |@cmd, |%opts };
    return (-1, '', "could not run '{@cmd.head}': {$! ?? $!.message !! 'unknown error'}")
        without $proc;

    my $out  = $proc.out.slurp(:close);
    my $err  = $proc.err.slurp(:close);
    my $code = $proc.exitcode;

    # A command that could not be spawned comes back as a negative exit
    # code with both streams empty and no exception anywhere — which
    # leaves `run-checked` saying "failed (exit -1)" and nothing else.
    # Say what actually happened instead.
    $err = "could not run '{@cmd.head}': no such command, or it could not"
         ~ " be started (is the argument list flattened?)"
        if $code < 0 && !$err.trim && !$out.trim;

    ($code, $out, $err)
}

#| Run a command that is expected to succeed, and return its C<stdout>.
#|
#| A non-zero exit dies with a message naming what was being attempted
#| (C<:$what>, defaulting to the command name), the exit code, and the
#| child's C<stderr> — indented, because the whole point of capturing it
#| is that the user gets to read it.
our sub run-checked(@cmd, :%env, :$cwd, Str :$what --> Str) is export {
    my ($code, $out, $err) = try-run(@cmd, :%env, :$cwd);
    return $out if $code == 0;
    my $label = $what // @cmd.head;
    my $detail = ($err || $out).trim;
    die "ariza: $label failed (exit $code)"
      ~ ($detail ?? ":\n" ~ $detail.lines.map({ "    $_" }).join("\n") !! '');
}

#| True if C<$name> can be spawned at all. Used to choose between
#| interchangeable system tools (C<shasum> vs C<sha256sum>), and to say
#| "install C<patchelf>" before a build fails halfway through — never to
#| skip work.
#|
#| C<:&run> is the same seam every other caller of C<try-run> takes, so a
#| test can answer "yes, there is a C<patchelf>" without one.
our sub have-command(Str:D $name, :&run = &try-run --> Bool) is export {
    my ($code, $, $) = run([$*DISTRO.is-win ?? 'where' !! 'which', $name]);
    $code == 0
}

#| An environment hash for a child process: this process's C<%*ENV> with
#| C<%overrides> applied, and any key whose value is undefined removed.
#|
#| Removal, not blanking, is the point. C<PERL6LIB=""> is not "unset" to
#| Rakudo — it is a set-but-empty variable, and 6.d prints a deprecation
#| warning for the whole run because of it. Passing
#| C<:PERL6LIB(Str)> deletes the key instead.
our sub child-env(*%overrides --> Hash) is export {
    my %env = %*ENV;
    for %overrides.kv -> $key, $value {
        $value.defined ?? (%env{$key} = ~$value) !! (%env{$key}:delete);
    }
    %env
}

#| Fetch a URL and return the response body as text.
#|
#| Shelling out to `curl` (falling back to `wget`) rather than taking a
#| Raku HTTP client as a dependency is deliberate, and is what every
#| C<Build.rakumod> in this tree already does: ariza fetches exactly
#| three things, all from static hosts, and a TLS-capable dependency
#| chain would be a much larger surface than the feature justifies.
our sub http-get(Str:D $url --> Str) is export {
    my @cmd;
    if have-command('curl') {
        @cmd = |<curl --fail --location --silent --show-error>, $url;
    }
    elsif have-command('wget') {
        @cmd = |<wget --quiet -O ->, $url;
    }
    else {
        die "ariza: need curl or wget to fetch $url";
    }
    run-checked(@cmd, :what("fetching $url"))
}

#| Download a URL to a path. Writes to a `.part` sibling and renames on
#| success, so an interrupted download can never be mistaken for a
#| complete one by a later cache hit.
our sub http-download(Str:D $url, IO() $dest) is export {
    ensure-dir($dest.parent);
    my $part = $dest.parent.add($dest.basename ~ '.part');
    $part.unlink if $part.e;
    my @cmd;
    if have-command('curl') {
        @cmd = |<curl --fail --location --silent --show-error --retry 3 -o>,
               $part.absolute, $url;
    }
    elsif have-command('wget') {
        @cmd = |<wget --quiet --tries=3 -O>, $part.absolute, $url;
    }
    else {
        die "ariza: need curl or wget to download $url";
    }
    {
        CATCH { default { $part.unlink if $part.e; .rethrow } }
        run-checked(@cmd, :what("downloading $url"));
    }
    die "ariza: download of $url produced nothing" unless $part.e && $part.s > 0;
    $part.rename($dest, :createonly(False));
    $dest
}

#| The SHA-256 of a file, lowercase hex.
#|
#| Probes C<sha256sum>, then C<shasum -a 256>, then Windows'
#| C<certutil -hashfile>, and dies if none of them is available. There is
#| deliberately no "skip the check" path: every digest ariza computes is
#| load-bearing (cache reuse, the bundle manifest), and a silently
#| unverified artefact is worse than a failed build.
our sub sha256-file(IO() $path --> Str) is export {
    die "ariza: cannot digest missing file $path" unless $path.f;

    if have-command('sha256sum') {
        my $out = run-checked(['sha256sum', $path.absolute], :what('sha256sum'));
        return normalise-digest($out.words.head, $path);
    }
    if have-command('shasum') {
        my $out = run-checked(['shasum', '-a', '256', $path.absolute], :what('shasum'));
        return normalise-digest($out.words.head, $path);
    }
    if have-command('certutil') {
        my $out = run-checked(['certutil', '-hashfile', $path.absolute, 'SHA256'],
                              :what('certutil'));
        # certutil prints a banner, the hex (possibly space-separated on
        # older builds), then a completion line.
        my $hex = $out.lines.grep({ / ^ [ <[0..9a..fA..F]> \s* ] ** 32..* $ / })
                      .head // '';
        return normalise-digest($hex.subst(/\s+/, '', :g), $path);
    }
    die "ariza: no sha256 tool found (looked for sha256sum, shasum, certutil)";
}

my sub normalise-digest($raw, IO::Path $path --> Str) {
    my $hex = ($raw // '').lc;
    die "ariza: could not read a sha256 digest for $path"
        unless $hex ~~ / ^ <[0..9a..f]> ** 64 $ /;
    $hex
}

#| Extract a `.tar.gz`/`.tgz` or `.zip` archive into an existing-or-created
#| directory, and return that directory.
#|
#| `.zip` prefers `unzip` and falls back to `tar -xf`, which handles zip
#| under bsdtar (macOS, Windows 10+) though not under GNU tar — hence the
#| preference order rather than picking one.
our sub extract-archive(IO() $archive, IO() $into --> IO::Path) is export {
    die "ariza: cannot extract missing archive $archive" unless $archive.f;
    ensure-dir($into);
    my $name = $archive.basename.lc;

    my @cmd;
    if $name.ends-with('.zip') {
        @cmd = have-command('unzip')
            ?? (|<unzip -q -o>, $archive.absolute, '-d', $into.absolute)
            !! (|<tar -x -f>, $archive.absolute, '-C', $into.absolute);
    }
    elsif $name.ends-with('.tar.gz') || $name.ends-with('.tgz') {
        @cmd = |<tar -x -z -f>, $archive.absolute, '-C', $into.absolute;
    }
    else {
        die "ariza: don't know how to extract $archive"
          ~ " (expected .tar.gz, .tgz or .zip)";
    }

    run-checked(@cmd, :what("extracting {$archive.basename}"));
    $into
}

#| The single entry directly inside `$dir`, for archives that wrap their
#| payload in one top-level directory (every official Rakudo build does).
#| Dies naming what it found if there is not exactly one.
our sub sole-child(IO() $dir --> IO::Path) is export {
    my @entries = $dir.dir.sort;
    die "ariza: expected exactly one entry in $dir, found {+@entries}"
      ~ (@entries ?? " ({@entries.map(*.basename).join(', ')})" !! '')
        unless @entries == 1;
    @entries[0]
}

#| Copy a file, preserving nothing but the bytes, and make it writable by
#| the owner.
#|
#| The writability is not incidental. Homebrew ships libraries mode 444;
#| a bundler that copies the mode along cannot then run
#| C<install_name_tool> over its own copy, and the failure surfaces
#| several steps later as an unexplained "permission denied".
our sub copy-writable(IO() $from, IO() $to --> IO::Path) is export {
    $to.unlink if $to.e || $to.l;
    ensure-dir($to.parent);
    $from.copy($to);
    $to.chmod(0o755);
    $to
}

=begin pod

=head1 NAME

App::Ariza::Tools - the shell-out layer: run, fetch, digest, extract

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Tools;

# Processes
my ($code, $out, $err) = try-run(<otool -L /bin/ls>);        # never dies
my $text = run-checked(<git rev-parse HEAD>, :what<git>);    # dies on failure
my %env  = child-env(:PERL6LIB(Str), :NOTCURSES_NATIVE_DATA_DIR($dir));

# Network
my $json = http-get('https://rakudo.org/dl/rakudo');
http-download($url, $cache.add('rakudo.tar.gz'));

# Files
ensure-dir($bundle.add('native'));
my $sha = sha256-file($archive);              # lowercase hex, 64 chars
extract-archive($archive, $staging);
my $top = sole-child($staging);               # the one wrapper directory
copy-writable($src, $dest);
rm-rf($staging);

=end code

=head1 DESCRIPTION

Building a bundle is mostly I<driving other programs>: C<curl>, C<tar>,
C<zef>, C<otool>, C<install_name_tool>, C<codesign>. This module is the
one place that knows how to do that safely, so no other module in ariza
contains a bare C<run> and every failure reads the same way.

There are no new distribution dependencies here on purpose. The
C<Build.rakumod> of every native-wrapping distribution these apps
depend on already downloads with C<curl> and unpacks with C<tar>;
ariza fetches three artefacts from static hosts,
and pulling in a TLS stack to do it would be a much larger surface than
the feature justifies.

=head1 RUNNING PROCESSES

=head2 try-run(@cmd, :%env, :$cwd --> List)

C<(exitcode, stdout, stderr)>. Never throws. A command that cannot be
spawned at all — no such binary — comes back as exit code C<-1> with the
reason on C<stderr>, so callers need one error path, not two.

=head2 run-checked(@cmd, :%env, :$cwd, :$what --> Str)

C<stdout>, or a die naming C<:$what> (defaulting to the command),
the exit code, and the child's C<stderr> indented beneath. Captured
C<stderr> that nobody prints is the reason build tools are hated; this
one prints it.

=head2 have-command(Str, :&run --> Bool)

Whether a command can be spawned. Used to choose between
interchangeable tools — C<sha256sum> or C<shasum> — and to say
"install C<patchelf>" I<before> a build gets half way through, never to
skip work. C<:&run> replaces the probe, so a test can assert on the
"there is no C<patchelf>" branch without uninstalling one.

=head2 child-env(*%overrides --> Hash)

C<%*ENV> plus C<%overrides>, with any key whose override is B<undefined>
I<removed>.

Removal matters more than it looks. Setting C<PERL6LIB=""> does not unset
it: Rakudo sees a set-but-empty variable and prints a v6.e deprecation
warning across the entire child run, which is exactly what happens when
you try to keep a stray C<PERL6LIB> out of a C<zef> invocation the
obvious way. C<child-env(:PERL6LIB(Str))> deletes the key.

=head1 NETWORK

=head2 http-get(Str $url --> Str)

The response body as text, via C<curl --fail> or C<wget>. Dies on any
HTTP error, which is what C<--fail> buys over a 404 page silently
becoming your JSON.

=head2 http-download(Str $url, IO() $dest --> IO::Path)

Download to C<$dest>. The transfer lands in a C<.part> sibling and is
renamed into place only on success, so an interrupted download cannot be
picked up as a cache hit by the next run. A partial file is removed on
failure.

=head1 FILES

=head2 sha256-file(IO() --> Str)

Lowercase hex digest. Probes C<sha256sum>, C<shasum -a 256> and
C<certutil -hashfile> in that order, and dies if none exists. There is
no "skip verification" fallback. Every digest here is
either gating a cache reuse or being written into a manifest a user may
check, and both are worse than useless if they can silently be absent.

=head2 extract-archive(IO() $archive, IO() $into --> IO::Path)

Unpack a C<.tar.gz>, C<.tgz> or C<.zip>. Zip prefers C<unzip> and falls
back to C<tar -xf> (bsdtar reads zip; GNU tar does not), so both a Linux
box with C<unzip> and a Windows box with only C<tar> work.

=head2 sole-child(IO() $dir --> IO::Path)

The single entry inside a directory, for archives that wrap everything
in one top-level folder. Dies naming what it found otherwise, rather
than guessing at the first alphabetically.

=head2 ensure-dir(IO() --> IO::Path) / rm-rf(IO()) / copy-writable(IO(), IO() --> IO::Path)

Create a directory tree; remove one; copy a file and make the copy
writable.

C<rm-rf> unlinks symlinks rather than descending through them: a bundle
contains symlinked libraries, and following one out of the tree during a
cleanup is how a delete becomes an incident. A missing path is not an
error, so it is safe in C<LEAVE>.

C<copy-writable> exists because Homebrew ships libraries mode C<444>. A
bundler that preserves that mode cannot run C<install_name_tool> over
its own copy, and the failure surfaces several steps later as an
inexplicable "permission denied".

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
