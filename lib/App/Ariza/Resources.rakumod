unit module App::Ariza::Resources;

#| The distribution's own root when App-Ariza is running from a source
#| checkout (`raku -Ilib`), otherwise the undefined `IO::Path` type
#| object. This file lives at `lib/App/Ariza/Resources.rakumod`, so four
#| parents up is the distribution root — and that root is only meaningful
#| as a checkout if it still has the `resources/` tree beside it.
our sub checkout-root(--> IO::Path) is export {
    my $root = $?FILE.IO.resolve.parent(4);
    $root.add('resources').d ?? $root !! IO::Path
}

#| Locate one resource file by its distribution-relative path (the same
#| string used as a key in META6 `resources`, e.g.
#| `templates/ci/release.yml.j2`).
#|
#| `%?RESOURCES` is consulted first, which is what an installed
#| distribution has; zef stages resources under content-hashed names, so
#| the returned path will not look like the source path. When that lookup
#| comes up empty — the ordinary case under `raku -Ilib` — the checkout
#| path is used instead. Dies naming both attempts if neither exists,
#| because a missing resource is always a packaging bug (an unlisted
#| entry in META6 `resources`) rather than anything a user can fix.
our sub resource(Str:D $rel --> IO::Path) is export {
    with staged-resource($rel) -> $staged {
        return $staged;
    }
    with checkout-root() -> $root {
        my $path = $root.add('resources').add($rel);
        # `.f`, not `.e`: every resource is a file, and a prefix that
        # happens to name a directory must fail like any other missing
        # resource rather than being handed back as an unopenable path.
        return $path if $path.f;
        die "ariza: missing resource '$rel' (looked in {$path})";
    }
    die "ariza: missing resource '$rel' (not in %?RESOURCES and no source checkout found)";
}

#| Every resource whose distribution-relative path starts with `$prefix`,
#| as a sorted list of distribution-relative paths (not `IO::Path`s — feed
#| each one back through `resource` to open it).
#|
#| Directory listing is not something `%?RESOURCES` can do: an installed
#| distribution's resources are flat, content-hashed files with no
#| surviving directory structure. The distribution metadata does still
#| carry the original relative paths, so an installed run enumerates
#| `$?DISTRIBUTION.meta<resources>`; a checkout walks the real directory,
#| which keeps a freshly-added-but-not-yet-listed resource visible while
#| you are working on it.
our sub resource-list(Str:D $prefix --> List) is export {
    with checkout-root() -> $root {
        my $dir = $root.add('resources').add($prefix);
        if $dir.d {
            my $base = $root.add('resources').absolute;
            # These are META6 `resources` keys, not filesystem paths, and
            # a key is forward-slash by spec on every platform — it is
            # what gets fed back through `resource` and compared against
            # the manifest. `.absolute` speaks the native separator, so
            # Windows would otherwise hand back `templates\ci\...` here
            # and nowhere else. Normalise at this one seam, where the
            # filesystem is consulted, so a checkout and an installed run
            # return identical strings.
            return $dir.dir.grep(*.f).map({
                .absolute.substr($base.chars + 1).subst('\\', '/', :g)
            }).sort.List;
        }
    }
    declared-resources()
        .grep({ .starts-with($prefix ~ '/') })
        .grep({ !.substr($prefix.chars + 1).contains('/') })
        .sort.List
}

#| The distribution-relative paths this distribution declares in META6
#| `resources`, as a list. Empty when the metadata is not reachable —
#| which is the ordinary case under `raku -Ilib`, where there is no
#| META6-backed distribution object at all.
my sub declared-resources(--> List) {
    ((try { $?DISTRIBUTION.meta<resources>.list }) // ()).grep(Str).List
}

#| `%?RESOURCES` lookup, hardened, returning the staged path or the
#| undefined `IO::Path` so the caller can fall back to the checkout.
#|
#| Three failure modes are folded into "no staged copy":
#|
#|   1. `%?RESOURCES` is absent entirely (`raku -Ilib`).
#|   2. The key was never declared in META6 `resources`. This one does
#|      NOT fail cleanly on its own: `Distribution::Resources` hands back
#|      a resource for any key at all, whose path degrades to the
#|      resource *store directory* — with an "uninitialized value"
#|      warning on the way — so an undeclared key would otherwise come
#|      back as a real, existing directory. Membership is checked against
#|      the declared list first, which both prevents that and keeps the
#|      warning off the user's terminal.
#|   3. The declared key stages to something that is not a file.
my sub staged-resource(Str:D $rel --> IO::Path) {
    my @declared = declared-resources();
    return IO::Path if @declared && !@declared.first($rel);
    my $res = try { %?RESOURCES{$rel} };
    return IO::Path without $res;
    my $path = try { $res.IO };
    return IO::Path without $path;
    $path.f ?? $path !! IO::Path
}

=begin pod

=head1 NAME

App::Ariza::Resources - find ariza's own bundled data files, installed or in a checkout

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Resources;

# One file, by its META6 `resources` key:
my $toml = resource('versions.toml').slurp;
my $tpl  = resource('templates/launcher-posix.sh.j2').slurp;

# Everything under a directory:
for resource-list('templates/ci') -> $rel {
    say $rel;                       # templates/ci/release.yml.j2
    say resource($rel).slurp;
}

# Where the checkout is, if this is a checkout at all:
with checkout-root() -> $root {
    say "running from source at $root";
}

=end code

=head1 DESCRIPTION

ariza ships data — Jinja2 templates, shell partials, the pinned
C<versions.toml> — and has to read it in two very different worlds:

=item1 B<Installed.> C<zef install> copies every file listed in META6
C<resources> into the installation's resource store under a
content-hashed name. The original directory structure is gone;
C<%?RESOURCES{'templates/launcher-posix.sh.j2'}> is the only way
back to the bytes.

=item1 B<A source checkout.> Running C<raku -Ilib bin/ariza ...> from
the distribution directory usually leaves C<%?RESOURCES> unpopulated,
but the files are sitting right there in C<resources/>.

Every module in ariza reads its data through this one module so that
neither world is a special case anywhere else, and so that "I added a
resource but forgot to list it in META6" fails the same way everywhere:
loudly, naming the path it tried.

=head1 SUBROUTINES

=head2 resource(Str $rel --> IO::Path)

Resolve a distribution-relative resource path to a real, existing
C<IO::Path>. C<$rel> is exactly the string used as the META6
C<resources> entry, always with forward slashes and never with a
leading C<resources/>.

Order of attempts:

=item1 C<%?RESOURCES{$rel}>, if it yields a path that exists.

=item1 C<< <checkout-root>/resources/$rel >>, if a checkout was found
and the file exists.

Dies otherwise. The message names the path that was tried, since the
cause is nearly always a resource that exists on disk but is missing
from META6 C<resources> — in which case the installed distribution
simply does not contain it.

Only files count. A C<$rel> that names a directory — C<templates/ci>
rather than C<templates/ci/release.yml.j2> — dies like any
other missing resource. That is not pedantry: installed,
C<Distribution::Resources> answers I<any> key with a resource whose
path degrades to the resource store directory, so without this rule a
mistyped path would come back as a real, existing directory and fail
much later as something inexplicable ("malformed TOML in
.../resources").

=head2 resource-list(Str $prefix --> List)

The sorted, distribution-relative paths of every resource file directly
under C<$prefix> (one level; subdirectories are not descended into).
Returns an empty list for a prefix with no resources.

The paths come back with B<forward slashes on every platform>, including
Windows. They are META6 C<resources> keys — the strings you hand back to
C<resource>, and the strings the manifest is written with — rather than
paths into the filesystem, so the separator is fixed by the packaging
spec and not by the machine. The checkout branch walks a real directory
and normalises before returning.

In a checkout this is a directory read, so a file you have just created
shows up before you have listed it in META6. Installed, it comes from
C<< $?DISTRIBUTION.meta<resources> >>, so it shows exactly what was
packaged. That asymmetry is deliberate and useful: development sees the
working tree, production sees the manifest.

=head2 checkout-root(--> IO::Path)

The distribution root when running from source, or the undefined
C<IO::Path> type object when running installed. Test with C<with>:

=begin code :lang<raku>

with checkout-root() -> $root {
    # e.g. reach a sibling app repository checked out next to ariza
    my $app = $root.parent.add('App-Moneymoor');
}

=end code

Detection is structural rather than environmental: the path four
parents above this source file must still have a C<resources/>
directory next to it. An installed copy of the module lives under the
repository's C<sources/> store, where that is not true.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
