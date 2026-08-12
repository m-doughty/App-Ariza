use App::Ariza::Platform;
use App::Ariza::Tools;
use App::Ariza::Versions;

unit class App::Ariza::Native;

# What SQLCipher is called on each platform ariza can name, and which
# sourcing strategy and audit apply to it.
#
#   family  — the platform family: picks the strategy and the audit
#   lib     — the file the loader opens, and the name it is staged under
#   alias   — the second name the loader may ask for, symlinked (or Str)
#
# `lib` is the name the staged copy gets, which is not always the name
# the source file had: EPEL renames the Linux soname per version, and
# MSYS2 calls the Windows DLL `libsqlcipher-0.dll` where vcpkg calls it
# `sqlcipher.dll`. Both searches widen past the canonical name and both
# stage under it — see the Pod on why that rename is safe.
#
# Every slug App::Ariza::Platform knows is here, because SQLCipher is now
# taken from the machine ariza is building on rather than from a
# published archive: there is no per-slug availability question left to
# answer, only "is it installed".
my constant %SQLCIPHER =
    'macos-arm64' => {
        family => 'macos',
        lib => 'libsqlcipher.0.dylib', alias => 'libsqlcipher.dylib',
    },
    'macos-x86_64' => {
        family => 'macos',
        lib => 'libsqlcipher.0.dylib', alias => 'libsqlcipher.dylib',
    },
    'linux-x86_64-glibc' => {
        family => 'linux',
        lib => 'libsqlcipher.so.0', alias => 'libsqlcipher.so',
    },
    'linux-x86_64-musl' => {
        family => 'linux',
        lib => 'libsqlcipher.so.0', alias => 'libsqlcipher.so',
    },
    'linux-aarch64-glibc' => {
        family => 'linux',
        lib => 'libsqlcipher.so.0', alias => 'libsqlcipher.so',
    },
    'linux-aarch64-musl' => {
        family => 'linux',
        lib => 'libsqlcipher.so.0', alias => 'libsqlcipher.so',
    },
    'windows-x86_64' => {
        family => 'windows',
        lib => 'sqlcipher.dll', alias => Str,
    },
    'windows-arm64' => {
        family => 'windows',
        lib => 'sqlcipher.dll', alias => Str,
    },
;

# Where a Linux distribution puts a shared library, for when `ldconfig`
# is unavailable (it lives in /sbin, which is not always on a user's
# PATH) or its cache is stale. Debian multiarch first, then the Red Hat
# and Alpine layouts, then /usr/local for a hand-built install.
my constant @LINUX-LIB-DIRS =
    '/usr/lib/x86_64-linux-gnu', '/usr/lib/aarch64-linux-gnu',
    '/lib/x86_64-linux-gnu', '/lib/aarch64-linux-gnu',
    '/usr/lib64', '/lib64', '/usr/lib', '/lib', '/usr/local/lib',
;

# The vcpkg triplets whose `bin` directory is worth a look when
# VCPKG_ROOT is set. Not a substitute for SQLCIPHER_LIB_DIR — a
# convenience for the layout vcpkg actually produces.
my constant @VCPKG-TRIPLETS =
    'x64-windows', 'arm64-windows', 'x64-windows-static-md';

# Where MSYS2 puts the DLLs of a `mingw-w64-<env>-*` package, for a
# default installation. `MSYSTEM_PREFIX` is consulted first and names
# whichever environment the shell is actually in; these are the two
# fallbacks worth having, UCRT first because that is the environment
# ariza wants (see below).
my constant @MSYS2-BIN-DIRS =
    'C:\msys64\ucrt64\bin', 'C:\msys64\mingw64\bin';

# What a SQLCipher DLL can be called on Windows once the canonical name
# has failed. vcpkg's port produces `sqlcipher.dll`; MSYS2's
# `mingw-w64-ucrt-x86_64-sqlcipher` produces `libsqlcipher-0.dll`, and
# libtool's naming being what it is, the number will move.
#
# This is the Windows spelling of the same widening the Linux search
# does for EPEL's renamed soname, and it is safe for the same reason:
# whatever is found is staged under the canonical name, and a DLL is
# opened by the leaf name on disk. The internal name in a PE's export
# directory is no more consulted by `LoadLibrary` than `DT_SONAME` is by
# `dlopen`.
#
# Matched case-insensitively, because the loader is and because a
# Windows bundle is routinely assembled on a case-sensitive filesystem.
my constant WINDOWS-LIB-GLOB = 'libsqlcipher*.dll';

# A library big enough that reading it whole to look for a version
# string is no longer a cheap probe. SQLCipher is ~1MB; this is three
# orders of magnitude of headroom before the probe quietly gives up.
my constant PROBE-MAX-BYTES = 64 * 1024 * 1024;

#| The environment variable naming a directory that holds the SQLCipher
#| library, checked on every platform and the one Windows CI actually
#| uses: ariza probes MSYS2 and vcpkg by itself, but a lane that has just
#| installed the package knows exactly where it went.
our constant SQLCIPHER-DIR-ENV = 'SQLCIPHER_LIB_DIR';

#| The SQLCipher version a library reports about itself, or the undefined
#| C<Str> when its bytes do not say so unambiguously.
#|
#| SQLCipher stores C<CIPHER_VERSION> as a NUL-terminated C<X.Y.Z> string
#| constant, so this reads the file and looks for exactly that shape. It
#| is deliberately conservative: zero matches or more than one is
#| C<Str> — "I do not know" — because a wrong version in the manifest is
#| worse than an absent one.
#|
#| The alternative — parsing the versioned filename, or the soname —
#| gives the wrong answer everywhere. A Homebrew keg's real file is
#| C<libsqlcipher.3.51.3.dylib> (SQLite's version, which SQLCipher
#| inherits), and Debian's is C<libsqlcipher.so.0.8.6> (libtool's
#| C<current.revision.age>). Neither is the C<4.x> number anyone means by
#| "the SQLCipher version".
our sub sqlcipher-version-of(IO() $lib --> Str) is export {
    return Str unless $lib.f && $lib.s > 0 && $lib.s <= PROBE-MAX-BYTES;
    my $bytes = try $lib.slurp(:bin);
    return Str without $bytes;
    my @found = ($bytes.decode('latin-1') ~~ m:g/ "\0" (\d+ '.' \d+ '.' \d+) "\0" /)
        .map({ ~.[0] }).unique;
    @found == 1 ?? @found.head !! Str
}

#| The real file behind a library path, following symlinks, so what is
#| copied into a bundle is bytes rather than a link into a keg that will
#| not exist on the user's machine.
#|
#| Falls back to the path itself when it does not resolve to a file —
#| including on Windows, where C<IO::Path.resolve> does not chase
#| symlinks at all and DLLs are not symlinked anyway.
my sub real-file(IO::Path $path --> IO::Path) {
    my $resolved = try { $path.resolve };
    $resolved.defined && $resolved.f ?? $resolved !! $path
}

#| The version in a Homebrew keg path: C<.../Cellar/sqlcipher/4.14.0>.
#| The undefined C<Str> for anything not shaped like a version, which is
#| what an unresolvable C<opt> symlink produces.
my sub keg-version(IO::Path $prefix --> Str) {
    my $real = (try { $prefix.resolve }) // $prefix;
    my $name = $real.basename;
    $name ~~ / ^ \d+ [ '.' \d+ ]* $ / ?? $name !! Str
}

#| A Mach-O dependency is self-contained if it is bundle-relative
#| (C<@loader_path>, C<@rpath>, C<@executable_path>) or belongs to macOS
#| itself (C</usr/lib>, C</System>). Anything else — a Homebrew prefix,
#| C</usr/local> — loads from outside the bundle or not at all.
our constant MACHO-ALLOWED = rx/ ^ [ '@loader_path/' | '@rpath/'
                                   | '@executable_path/' | '/usr/lib/'
                                   | '/System/' ] /;

#| Every dependency in `otool -L` output that is not self-contained.
#|
#| Takes the raw text so it is testable without a Mach-O file. The first
#| line is C<otool>'s C<"path:"> banner and is dropped; the C<LC_ID_DYLIB>
#| line that follows for a shared library is B<not> — an absolute install
#| name is baked into everything that links against it later, which is
#| the same bug one step removed.
our sub macho-strays(Str:D $otool-output --> List) is export {
    $otool-output.lines.skip(1)
        .map(*.trim).grep(*.chars)
        .map(*.words.head)
        .grep({ $_ !~~ MACHO-ALLOWED })
        .unique.List
}

# The shared libraries a Linux bundle must NOT carry a copy of: the
# loader, the C library and the compiler runtime — the pieces every
# process on the machine has already mapped, and where a second copy is
# not belt-and-braces but a conflict (two libcs in one address space, a
# loader that disagrees with the one that started the process).
# Everything else is fair game, and gets copied in.
#
# This is Notcurses-Native's scripts/ci/bundle-elf.sh skiplist with one
# deliberate difference: libcrypto and libssl are NOT here. That script
# leaves them dynamic because ffmpeg's use of them is optional;
# SQLCipher's is the entire point of SQLCipher, and a bundle that
# borrows the user's OpenSSL is a bundle that opens their database with
# whatever version that machine happens to have, or does not open it at
# all.
#
# Patterns, matched against the leaf name, where `*` is the only
# metacharacter.
our constant ELF-SYSTEM-LIBS =
    'ld-linux*', 'ld-musl-*', 'ld64.so.*', 'ld.so.*',
    'libc.so.*', 'libc.musl-*', 'libm.so.*', 'libmvec.so.*',
    'libpthread.so.*', 'libdl.so.*', 'librt.so.*', 'libthread_db.so.*',
    'libgcc_s.so.*', 'libstdc++.so.*', 'libatomic.so.*',
    'libresolv.so.*', 'libnsl.so.*', 'libutil.so.*', 'libcrypt.so.*',
    'linux-vdso.so.*', 'linux-gate.so.*',
;

# The markers the ELF audit puts before `patchelf --print-rpath`'s
# answer and before clean-environment `ldd` output, when it is running on
# a Linux host and can ask the loader itself rather than only reading the
# file. See "Two host-only checks" in the Pod below.
our constant ELF-RPATH-SECTION is export = '=== ariza:rpath ===';
our constant ELF-LDD-SECTION   is export = '=== ariza:ldd ===';

#| Glob match, where C<*> is the only metacharacter. Small enough to
#| write out, and a good deal easier to reason about than assembling a
#| regex from a string at run time.
my sub glob-match(Str:D $name, Str:D $pattern --> Bool) {
    my @parts = $pattern.split('*');
    return $name eq $pattern if @parts == 1;
    return False unless $name.starts-with(@parts[0]);
    return False unless $name.ends-with(@parts[*-1]);

    my $pos = @parts[0].chars;
    for @parts[1 .. *-2] -> $middle {
        next unless $middle.chars;
        my $at = $name.index($middle, $pos);
        return False without $at;
        $pos = $at + $middle.chars;
    }
    # The leading and trailing literals must not have to overlap to fit.
    $pos <= $name.chars - @parts[*-1].chars
}

#| Whether a resolved dependency path lies under one of the bundle's own
#| directory prefixes.
#|
#| A resolved target is spelled in the host's native separators
#| (backslashes, on Windows) while C<@inside>'s prefixes may not share
#| that spelling — they can arrive already forward-slashed (as, for
#| instance, App::Ariza::Resources always returns them). Containment is a
#| path-identity question, not a byte question, so both sides are
#| normalised to forward slashes before the prefix check. (A Windows
#| drive letter can also differ in case, C<c:> vs C<C:>; that has not
#| been the cause of a failure here, so it is left alone rather than
#| folding case for a normalisation this narrow.)
#|
#| Shared by the ELF and PE audits, which ask exactly the same question
#| of two different loaders.
my sub path-inside(Str:D $target, @inside --> Bool) {
    my $path = $target.subst('\\', '/', :g);
    so @inside.first({ $path.starts-with($_.subst('\\', '/', :g) ~ '/') })
}

#| The file called C<$name> in C<$dir>, matched the way Windows matches
#| it: exactly if it can, case-insensitively otherwise. The undefined
#| C<IO::Path> when there is none.
#|
#| The case fold is not cosmetic. An import table records
#| C<KERNEL32.dll> where the file on disk is C<kernel32.dll>, vcpkg's own
#| casing varies by port, and a bundle built on a case-insensitive
#| filesystem must audit the same on a case-sensitive one.
my sub find-beside(IO::Path $dir, Str:D $name --> IO::Path) {
    my $exact = $dir.add($name);
    return $exact if $exact.f;
    return IO::Path unless $dir.d;
    $dir.dir.first({ .f && .basename.lc eq $name.lc }) // IO::Path
}

#| Compares two library filenames the way a version number should be
#| compared: digit runs numerically, everything else as text — so
#| C<libsqlcipher-3.34.1.so.0> sorts above C<libsqlcipher-3.9.0.so.0>,
#| which a plain string C<cmp> gets backwards (C<'9'> follows C<'3'>).
my sub natural-cmp(Str:D $a, Str:D $b --> Order) {
    my @ta = $a.comb(/ \d+ | \D+ /);
    my @tb = $b.comb(/ \d+ | \D+ /);
    for ^max(@ta.elems, @tb.elems) -> $i {
        my $x = @ta[$i] // '';
        my $y = @tb[$i] // '';
        my $o = ($x ~~ / ^ \d+ $ / && $y ~~ / ^ \d+ $ /)
            ?? (+$x <=> +$y)
            !! ($x cmp $y);
        return $o unless $o == Order::Same;
    }
    Order::Same
}

#| The parenthetical the manifest carries when the file found on the
#| machine was not called what it is going to be staged as — and the
#| empty string when it was, so nothing is said about a rename that did
#| not happen.
#|
#| The comparison folds case: on Windows two spellings of a name are one
#| file, and reporting C<SQLCipher.dll> as renamed to C<sqlcipher.dll>
#| would be noise about nothing.
my sub staged-as(Str:D $canonical, Str $found --> Str) {
    !$found.defined || $found.lc eq $canonical.lc
        ?? ''
        !! " (staged as $canonical; found as $found)"
}

#| A SQLCipher DLL in one of C<@dirs>, as C<(IO::Path, matched)> — or
#| the empty list when there is none.
#|
#| The canonical name wins outright, in the directory order given, and
#| is matched the way Windows matches it (C<find-beside>: exactly if it
#| can, case-insensitively otherwise). Only where no directory holds it
#| does the search widen to C<WINDOWS-LIB-GLOB>, and then the newest
#| match by a numeric-aware comparison of the filename is taken — the
#| same rule, and the same ordering trap, as the Linux C<:$glob> pass.
my sub windows-lib-in(Str:D $name, @dirs --> List) {
    for @dirs -> $dir {
        my $exact = find-beside($dir.IO, $name);
        return ($exact, $exact.basename) with $exact;
    }

    my @found;
    for @dirs -> $dir {
        next unless $dir.IO.d;
        for $dir.IO.dir -> $entry {
            next unless $entry.f && !$entry.l
                     && glob-match($entry.basename.lc, WINDOWS-LIB-GLOB);
            @found.push($entry);
        }
    }
    return () unless @found;

    my $best = @found.sort({ natural-cmp($^b.basename, $^a.basename) }).head;
    ($best, $best.basename)
}

#| Whether a soname names a library a bundle leaves dynamic. Takes a
#| soname or a path; only the leaf name is considered.
our sub elf-system-lib(Str:D $soname --> Bool) is export {
    my $name = $soname.split('/').tail;
    so ELF-SYSTEM-LIBS.first({ glob-match($name, $_) })
}

#| The C<DT_NEEDED> sonames in C<readelf -d> output, in file order.
#| C<eu-readelf> prints the same C<Shared library: [name]> shape, so this
#| reads both.
our sub elf-needed(Str:D $readelf-output --> List) is export {
    $readelf-output.lines
        .map({ / 'Shared library:' \s* '[' (<-[\]]>+) ']' / ?? ~$0 !! Str })
        .grep(*.defined).unique.List
}

#| The dependencies in C<ldd> output, as C<soname => path> pairs, with
#| the undefined C<Str> for a value C<ldd> reported as C<not found>.
#|
#| Only C<name =E<gt> path> lines are read. The two other shapes C<ldd>
#| emits — C<linux-vdso.so.1 (0x…)>, and the loader's own absolute path —
#| carry no name/path pair to act on, and a C<NEEDED> entry that is
#| itself an absolute path (which prints in that second shape) is caught
#| by C<elf-strays> instead, where it belongs: nothing can be I<copied>
#| to fix it.
our sub ldd-deps(Str:D $ldd-output --> List) is export {
    my @deps;
    for $ldd-output.lines -> $line {
        # "	libcrypto.so.3 => /lib64/libcrypto.so.3 (0x00007f…)"
        my $entry = $line.trim.subst(/ \s* '(' <-[)]>* ')' $ /, '');
        next unless $entry.contains(' => ');
        my ($name, $path) = $entry.split(' => ', 2).map(*.trim);
        next unless $name.chars;
        @deps.push($name => ($path.chars && $path ne 'not found' ?? $path !! Str));
    }
    @deps.unique(as => *.key).List
}

#| Everything about an ELF file that would load from outside the bundle.
#|
#| ELF resolves differently from Mach-O: C<NEEDED> entries are bare
#| sonames looked up at load time, so a slash in one is an absolute path
#| baked into the binary. C<RPATH>/C<RUNPATH> must be C<$ORIGIN>-relative
#| for a relocatable bundle; an absolute one points at the build machine.
#| Those two are readable from the file itself, on any host, and are
#| always checked.
#|
#| A report produced B<on Linux> carries two more sections, and they are
#| the ones that catch the failure the static checks cannot see: a bare
#| C<NEEDED libcrypto.so.3> is perfectly legal ELF and resolves happily
#| from the build machine's C</lib64>.
#|
#| Under C<ELF-RPATH-SECTION>, what C<patchelf --print-rpath> reports:
#| every entry must be C<$ORIGIN>-relative, and a file with a non-system
#| C<NEEDED> must have at least one, since without it nothing tells the
#| loader to look beside the file.
#|
#| Under C<ELF-LDD-SECTION>, what C<ldd> resolved to in a clean
#| environment: every non-system dependency must resolve to a path under
#| one of C<:@inside> (the bundle), and C<not found> is a finding. With
#| no C<:@inside> given, containment cannot be judged and only
#| C<not found> is reported. The comparison is separator-normalised, so
#| a resolved target and an C<:@inside> prefix spelled with opposite
#| path separators still agree.
our sub elf-strays(Str:D $report, :@inside = () --> List) is export {
    my (@static, @rpath, @ldd);
    my %have;
    my $section := @static;
    for $report.lines -> $line {
        given $line.trim {
            when ELF-RPATH-SECTION { $section := @rpath; %have<rpath> = True }
            when ELF-LDD-SECTION   { $section := @ldd;   %have<ldd>   = True }
            default                { $section.push($line) }
        }
    }

    my $readelf = @static.join("\n");
    my @needed  = elf-needed($readelf);
    my @strays;

    for @static -> $line {
        if $line ~~ / 'Shared library:' \s* '[' (<-[\]]>+) ']' / {
            # Bind before testing: the inner match would reset `$/` and
            # leave `$0` Nil by the time it was pushed.
            my $soname = ~$0;
            @strays.push($soname) if $soname.contains('/');
        }
        elsif $line ~~ / ['RUNPATH'|'RPATH'] \D* '[' (<-[\]]>*) ']' / {
            for (~$0).split(':').grep(*.chars) -> $entry {
                @strays.push($entry) unless $entry.starts-with('$ORIGIN');
            }
        }
    }

    if %have<rpath> {
        # Deliberately the same finding text as the static check above,
        # so a bad rpath seen by both is reported once.
        my @entries = @rpath.join("\n").trim.split(':').grep(*.chars);
        @strays.push($_) for @entries.grep({ !.starts-with('$ORIGIN') });
        @strays.push('no rpath: nothing tells the loader to look beside this'
                   ~ ' file (expected $ORIGIN)')
            if !@entries && @needed.grep({ !elf-system-lib($_) });
    }

    if %have<ldd> {
        for ldd-deps(@ldd.join("\n")) -> $dep {
            next if elf-system-lib($dep.key);
            without $dep.value {
                @strays.push("{$dep.key} => not found");
                next;
            }
            next unless @inside;
            @strays.push("{$dep.key} => {$dep.value}")
                unless path-inside($dep.value, @inside);
        }
    }

    @strays.unique.List
}

#| The format of a binary file, by magic number: C<'Mach-O'>, C<'ELF'>,
#| C<'PE'>, or the undefined C<Str> for anything else (a text file, a
#| C<.srchash> sidecar, a directory, a file too short to say).
#|
#| Four bytes, rather than shelling out to C<file>: a format probe that
#| answers "not a binary" when its helper is missing turns the audit into
#| a loop that checks nothing and passes B<silently>, and C<file> is
#| exactly the sort of tool a minimal build image leaves out.
our sub binary-format(IO() $file --> Str) is export {
    return Str unless $file.f && $file.s >= 4;
    my $magic = try { my $h = $file.open(:bin); LEAVE $h.close; $h.read(4) };
    return Str without $magic;

    my $be = ($magic[0] +< 24) +| ($magic[1] +< 16)
           +| ($magic[2] +< 8) +| $magic[3];
    return 'ELF' if $be == 0x7F45_4C46;
    # Mach-O in both byte orders, plus the fat/universal wrappers.
    return 'Mach-O' if $be == any(0xFEED_FACE, 0xFEED_FACF,
                                  0xCEFA_EDFE, 0xCFFA_EDFE,
                                  0xCAFE_BABE, 0xBEBA_FECA);
    return 'PE' if $magic[0] == 0x4D && $magic[1] == 0x5A;   # "MZ"
    Str
}

# The Visual C++ Redistributable family: the runtime an MSVC-built DLL
# links against, and the one part of a Windows dependency closure that
# looks like Windows and is not.
#
# `vcruntime140.dll` and friends ship with Visual Studio and with the
# redistributable installer, not with the OS. A machine that has never
# had either — a fresh Windows install, which is exactly the machine a
# bundle exists for — cannot load a DLL that imports one, and the
# failure is the same silent `LoadLibrary` refusal a missing OpenSSL
# produces. CI runners all have the redistributable, so the gap is
# invisible precisely where it would otherwise be caught.
#
# These are not copied in (they are Microsoft's to redistribute, on
# Microsoft's terms, and app-local deployment of them is a decision
# ariza does not get to make on an author's behalf) and they are not
# waved through either: the audit reports one that is imported and not
# in the bundle, and says what to do about it. See "The redistributable
# gate" in the Pod.
#
# The UCRT is deliberately absent: `ucrtbase.dll` is part of Windows 10
# and later, which is why a UCRT-built library is the fix rather than
# another instance of the problem.
our constant PE-REDIST-DLLS =
    'vcruntime*.dll', 'msvcp*.dll', 'concrt*.dll', 'vcomp*.dll',
;

# The DLLs a Windows bundle must NOT carry a copy of: Windows' own, the
# Visual C++ redistributable, and the API-set stubs the loader maps out
# of the OS itself. Everything else is fair game, and gets copied in —
# which on a vcpkg-sourced SQLCipher means OpenSSL, the entire point of
# SQLCipher and a library no user's machine has.
#
# Every name here ships with Windows, and the list is not speculative:
# it is the core set, plus exactly the DLLs the payloads ariza actually
# stages import and do not carry — measured by walking the import table
# of all 119 DLLs in the notcurses Windows pack and taking the names that
# resolve nowhere inside it.
#
# Erring narrow is deliberate, and the asymmetry is the reason. A DLL
# that belongs here and is missing fails the build loudly, naming itself
# and this constant, which is a one-line fix. One that does not belong
# here and is added anyway ships a bundle that loads a stranger's copy of
# a library it needed to carry — invisible until a user's machine turns
# out not to have it.
#
# Patterns, matched case-insensitively against the leaf name, where `*`
# is the only metacharacter.
our constant PE-SYSTEM-DLLS =
    # The core Win32 set.
    'kernel32.dll', 'kernelbase.dll', 'user32.dll', 'advapi32.dll',
    'gdi32.dll', 'gdiplus.dll', 'msimg32.dll', 'ntdll.dll',
    'rpcrt4.dll', 'shell32.dll', 'shlwapi.dll', 'ole32.dll',
    'oleaut32.dll', 'version.dll', 'userenv.dll', 'cfgmgr32.dll',
    # Sockets and networking.
    'ws2_32.dll', 'wsock32.dll', 'iphlpapi.dll', 'dnsapi.dll',
    # Cryptography and security.
    'bcrypt.dll', 'bcryptprimitives.dll', 'crypt32.dll', 'ncrypt.dll',
    'secur32.dll',
    # Text, media and device stacks.
    'dwrite.dll', 'usp10.dll', 'winmm.dll', 'avrt.dll', 'avicap32.dll',
    # The C runtimes: the OS's own, the UCRT (Windows 10 and later ship
    # it in System32), and the Visual C++ redistributable — which is a
    # prerequisite rather than a payload, and is audited as one.
    'msvcrt.dll', 'ucrtbase.dll', |PE-REDIST-DLLS,
    # The API sets, which are not files on disk at all: the loader
    # resolves them out of the OS.
    'api-ms-win-*.dll', 'ext-ms-*.dll',
;

# A PE file is read whole to walk its import table; this is the same
# headroom `sqlcipher-version-of` allows itself. A DLL past it is not a
# DLL anyone is shipping.
#
# The two walk limits are there so a malformed file cannot turn the
# parser into a loop: the real numbers are 96 sections (the PE format's
# own ceiling), a few dozen imports, and DLL names well under 64
# characters.
my constant PE-MAX-IMPORTS = 4096;
my constant PE-MAX-NAME    = 512;

# Where the PE header fields this reads live. All little-endian, all
# fixed by the format.
my constant PE-LFANEW      = 0x3C;      # in the DOS header
my constant PE32-MAGIC     = 0x010B;
my constant PE32PLUS-MAGIC = 0x020B;

#| The leaf of an imported DLL name, folded — how the loader compares
#| two spellings of one file, and how both skiplist tests below do.
my sub pe-leaf(Str:D $name --> Str) {
    $name.split('/').tail.split('\\').tail.lc
}

#| Whether an imported DLL name is one Windows itself provides, and so
#| one a bundle neither carries nor audits. Takes a name or a path; only
#| the leaf is considered, and the comparison is case-insensitive because
#| the loader's is (C<KERNEL32.dll> and C<kernel32.dll> are one file).
our sub pe-system-dll(Str:D $name --> Bool) is export {
    so PE-SYSTEM-DLLS.first({ glob-match(pe-leaf($name), $_) })
}

#| Whether an imported DLL name belongs to the Visual C++
#| Redistributable — the runtime an MSVC build links against, which is
#| not part of Windows and which no clean machine has.
#|
#| Every one of these is also on C<PE-SYSTEM-DLLS>, so nothing copies
#| one in; this is the second, narrower question the audit asks about
#| the same names. Takes a name or a path, folds case, as its sibling
#| does.
our sub pe-redist-dll(Str:D $name --> Bool) is export {
    so PE-REDIST-DLLS.first({ glob-match(pe-leaf($name), $_) })
}

my sub pe-die(IO::Path $file, Str:D $why) {
    die "ariza: cannot read the imports of {$file.absolute}: $why";
}

my sub pe-u16(Blob:D $b, Int:D $at, IO::Path $file, Str:D $what --> Int) {
    pe-die($file, "$what wants 2 bytes at offset $at, and the file is"
                ~ " {$b.elems} bytes long")
        if $at < 0 || $at + 2 > $b.elems;
    $b[$at] +| ($b[$at + 1] +< 8)
}

my sub pe-u32(Blob:D $b, Int:D $at, IO::Path $file, Str:D $what --> Int) {
    pe-die($file, "$what wants 4 bytes at offset $at, and the file is"
                ~ " {$b.elems} bytes long")
        if $at < 0 || $at + 4 > $b.elems;
    $b[$at] +| ($b[$at + 1] +< 8) +| ($b[$at + 2] +< 16) +| ($b[$at + 3] +< 24)
}

#| The NUL-terminated ASCII string at a file offset — how a PE stores
#| every imported DLL name.
my sub pe-string(Blob:D $b, Int:D $at, IO::Path $file --> Str) {
    my $end = $at;
    $end++ while $end < $b.elems && $end - $at < PE-MAX-NAME && $b[$end];
    pe-die($file, "an imported DLL name at offset $at runs to the end of the"
                ~ " file without a terminating NUL")
        if $end >= $b.elems || $end - $at >= PE-MAX-NAME;
    pe-die($file, "an imported DLL name at offset $at is empty")
        unless $end > $at;
    $b.subbuf($at, $end - $at).decode('latin-1')
}

my sub pe-bytes(IO::Path $file --> Blob) {
    pe-die($file, 'it is not a file') unless $file.f;
    pe-die($file, "it is {$file.s} bytes, past the {PROBE-MAX-BYTES}-byte"
                ~ " ceiling this reader will read into memory")
        if $file.s > PROBE-MAX-BYTES;
    my $bytes = try $file.slurp(:bin);
    pe-die($file, 'its bytes could not be read') without $bytes;
    $bytes
}

#| The DLLs a PE file imports, by name, in the order its import table
#| lists them.
#|
#| This is the Windows half of the self-containment story, and it is
#| written out rather than shelled out to because there is nothing to
#| shell out I<to>: C<dumpbin> ships with Visual Studio, not with
#| Windows, and C<objdump> ships with neither. A staging pass whose
#| dependency walk silently finds nothing when its helper is missing
#| produces exactly the bundle the pass exists to prevent — so the
#| format is parsed here, from the bytes, on any host.
#|
#| It is also what makes cross-inspection work: reading a C<.dll>'s
#| imports needs no Windows, so the audit is as strong from a Mac as it
#| is on the machine the bundle is for.
#|
#| The walk is the standard one — DOS header C<e_lfanew> to the C<PE\0\0>
#| signature, COFF header for the section count and optional-header size,
#| optional header (PE32 and PE32+ both, which differ only in where the
#| data directories start), data directory 1 for the import table's RVA,
#| then each 20-byte import descriptor's name RVA, mapped back to a file
#| offset through the section table.
#|
#| Anything that does not parse is a die naming the file and what was
#| wrong with it. There is no undefined-C<Str>-for-"I don't know" return:
#| the caller is either staging a DLL's dependencies or auditing them,
#| and a quiet "no imports" answer for a file this cannot read would pass
#| both.
#|
#| Delay-load imports (data directory 13) are B<not> read. They are rare
#| — no vcpkg-built OpenSSL or SQLCipher uses them — and the descriptor
#| carries a format ambiguity (older linkers store virtual addresses
#| where newer ones store RVAs) that would have this guessing. A
#| delay-loaded dependency would go unstaged and unreported; if one ever
#| turns up here, it belongs in this parser rather than in a workaround.
our sub pe-imports(IO() $file --> List) is export {
    my $b = pe-bytes($file);

    pe-die($file, 'it does not begin with "MZ", so it is not a PE file at all')
        unless $b.elems >= 2 && $b[0] == 0x4D && $b[1] == 0x5A;

    my $pe = pe-u32($b, PE-LFANEW, $file, "the DOS header's e_lfanew");
    pe-die($file, "its e_lfanew points at offset $pe, which is past the end"
                ~ " of a {$b.elems}-byte file")
        if $pe < 0 || $pe + 24 > $b.elems;
    pe-die($file, "there is no \"PE\\0\\0\" signature at offset $pe, where"
                ~ " e_lfanew points")
        unless $b[$pe] == 0x50 && $b[$pe + 1] == 0x45
            && $b[$pe + 2] == 0 && $b[$pe + 3] == 0;

    my $coff     = $pe + 4;
    my $sections = pe-u16($b, $coff + 2,  $file, 'NumberOfSections');
    my $opt-size = pe-u16($b, $coff + 16, $file, 'SizeOfOptionalHeader');
    my $opt      = $coff + 20;

    # An object file (or a pure-resource DLL built as one) has no
    # optional header, and so no data directories and no imports.
    return () unless $opt-size;

    my $magic = pe-u16($b, $opt, $file, 'the optional header magic');
    my ($dirs, $dir-count-at) = do given $magic {
        when PE32-MAGIC     { ($opt + 96,  $opt + 92)  }
        when PE32PLUS-MAGIC { ($opt + 112, $opt + 108) }
        default {
            pe-die($file, sprintf('its optional header magic is 0x%04X, which'
                                ~ ' is neither PE32 (0x010B) nor PE32+'
                                ~ ' (0x020B)', $magic));
        }
    };

    # A file with fewer than two data directories has no import table
    # entry to read — legal, and means it imports nothing.
    my $ndirs = pe-u32($b, $dir-count-at, $file, 'NumberOfRvaAndSizes');
    return () if $ndirs < 2;

    my $imports = pe-u32($b, $dirs + 8, $file, "the import table's RVA");
    return () unless $imports;

    my $table = $opt + $opt-size;
    pe-die($file, "its $sections section header(s) do not fit inside a"
                ~ " {$b.elems}-byte file")
        if $sections < 1 || $table + 40 * $sections > $b.elems;

    my @sections = (^$sections).map(-> $i {
        my $s = $table + 40 * $i;
        %( rva   => pe-u32($b, $s + 12, $file, 'a section VirtualAddress'),
           vsize => pe-u32($b, $s + 8,  $file, 'a section VirtualSize'),
           raw   => pe-u32($b, $s + 20, $file, 'a section PointerToRawData'),
           rsize => pe-u32($b, $s + 16, $file, 'a section SizeOfRawData') )
    });

    # RVA to file offset: the section table is the only map between the
    # addresses a PE records and the bytes on disk. A section's virtual
    # size can exceed what is stored (zero-filled tail), which is why the
    # span and the on-disk length are checked separately.
    my sub at(Int:D $rva, Str:D $what --> Int) {
        for @sections -> %s {
            my $span = %s<vsize> || %s<rsize>;
            next unless $span && $rva >= %s<rva> && $rva - %s<rva> < $span;
            my $offset = %s<raw> + $rva - %s<rva>;
            pe-die($file, sprintf('%s is at RVA 0x%X, which falls in a section'
                                ~ ' that has no bytes for it in the file',
                                  $what, $rva))
                if $rva - %s<rva> >= %s<rsize> || $offset >= $b.elems;
            return $offset;
        }
        pe-die($file, sprintf('%s is at RVA 0x%X, which falls in none of its'
                            ~ ' %d section(s)', $what, $rva, +@sections));
    }

    my $descriptors = at($imports, 'the import table');
    my @names;
    my $terminated = False;
    for ^PE-MAX-IMPORTS -> $i {
        my $d = $descriptors + 20 * $i;
        # The array ends with an all-zero descriptor; a file that runs
        # out of bytes before one is truncated, and pe-u32 says so.
        my $thunk = pe-u32($b, $d,      $file, 'an import descriptor');
        my $name  = pe-u32($b, $d + 12, $file, "an import descriptor's name RVA");
        my $first = pe-u32($b, $d + 16, $file, 'an import descriptor');
        if !$thunk && !$name && !$first {
            $terminated = True;
            last;
        }
        @names.push(pe-string($b, at($name, 'an imported DLL name'), $file));
    }
    pe-die($file, "its import table has more than {PE-MAX-IMPORTS} entries and"
                ~ " no terminator, so it is not an import table")
        unless $terminated;

    @names.unique.List
}

#| The C<readelf> on this machine, C<eu-readelf> where elfutils stands in
#| for binutils, or the undefined C<Str> where there is neither.
my sub elf-reader(:&run! --> Str) {
    for <readelf eu-readelf> -> $tool {
        return $tool if have-command($tool, :&run);
    }
    Str
}

#| C<patchelf --print-rpath>, which is what the loader will actually use,
#| rather than what a tag in the file says.
my sub elf-rpath(IO::Path $file, :&run! --> Str) {
    my ($code, $out, $err) = run(['patchelf', '--print-rpath', $file.absolute]);
    die "ariza: patchelf --print-rpath failed on {$file.absolute}"
      ~ (($err || $out).trim ?? ": {($err || $out).trim.lines.head}" !! '')
        unless $code == 0;
    $out.trim
}

#| C<ldd> with the environment B<replaced> by a bare C<PATH> — C<env -i>,
#| in one call rather than two.
#|
#| The distinction is the whole point of the check. A build that exported
#| C<LD_LIBRARY_PATH> (ariza's own launcher does, and so does anyone
#| building against a cached prefix) gets a plain C<ldd> resolving
#| through it, which paints a picture no user will ever see. Wiping the
#| environment is the user's view of the same file.
my sub elf-clean-ldd(IO::Path $file, :&run! --> Str) {
    my ($code, $out, $err) = run(['ldd', $file.absolute],
                                 :env(%( PATH => '/usr/bin:/bin' )));
    die "ariza: ldd failed on {$file.absolute}"
      ~ (($err || $out).trim ?? ": {($err || $out).trim.lines.head}" !! '')
        unless $code == 0 || $out.contains('=>');
    $out
}

#| Every slug ariza knows how to stage SQLCipher for, sorted.
method sqlcipher-slugs(--> List) { %SQLCIPHER.keys.sort.List }

#| A slug's SQLCipher naming: C<family>, C<lib>, C<alias>. Dies naming
#| the known set for a slug ariza has no entry for.
method sqlcipher-layout(Str:D $slug --> Hash) {
    %SQLCIPHER{$slug}
        // die "ariza: ariza does not know what SQLCipher is called on '$slug'"
             ~ " (knows: {self.sqlcipher-slugs.join(', ')})";
}

#| Where a slug's SQLCipher library is staged inside the bundle.
#|
#| macOS puts it in C<rakudo/lib>, which is not where the other native
#| payloads go, for two converging reasons: it is on the bundled
#| interpreter's C<LC_RPATH> (C<@executable_path/../lib>), so
#| C<is native('sqlcipher')> resolves the bare name with no environment
#| at all; and it is exactly the directory App::Moneymoor's entry point
#| probes before deciding whether to pay for C<MacOS::NativeLib>'s
#| C<brew config> round-trip.
#|
#| Linux and Windows have no equivalent implicit path, so their copies
#| live under C<native/sqlcipher> and the launcher names them explicitly
#| (C<LD_LIBRARY_PATH> + C<DBIISH_SQLCIPHER_LIB>, C<PATH> on Windows).
method sqlcipher-dir(IO() $bundle-dir, Str:D :$slug! --> IO::Path) {
    self.sqlcipher-layout($slug)<family> eq 'macos'
        ?? $bundle-dir.add('rakudo').add('lib')
        !! $bundle-dir.add('native').add('sqlcipher')
}

#| The bundle-relative path of the staged library, for the launcher and
#| the manifest.
method sqlcipher-rel(Str:D :$slug! --> Str) {
    my %l = self.sqlcipher-layout($slug);
    (%l<family> eq 'macos' ?? 'rakudo/lib/' !! 'native/sqlcipher/') ~ %l<lib>
}

#| Decide where this build's SQLCipher comes from, without copying
#| anything. Returns C<{ kind, path, origin, version }>, where C<kind> is
#| C<'library'> (a file to copy straight in) or C<'archive'> (a tarball
#| to unpack and search), C<origin> is the sentence that goes in the
#| manifest, and C<version> is whatever the source knew about itself —
#| often the undefined C<Str>, since the staged library is asked directly
#| afterwards.
#|
#| Resolution order:
#|
#|   1. C<:$archive> — C<--sqlcipher-archive>, which beats everything.
#|   2. C<SQLCIPHER_LIB_DIR> — a directory the operator named.
#|   3. the platform's package manager: a Homebrew keg (or bottle) on
#|      macOS, the distribution's library on Linux, an MSYS2 prefix or a
#|      vcpkg tree on Windows.
#|
#| Both explicit forms bypass the cross-build guard, because a human
#| naming a file has said which platform it is for; the package-manager
#| strategies do not, because a library installed on this machine is
#| built for this machine.
#|
#| C<:$host-slug>, C<:%env>, C<:&run> and C<:@search> are the seams: they
#| make every branch — including the Linux and Windows ones — reachable
#| from a test on any machine, with no package manager and no network.
method sqlcipher-source(
    Str:D :$slug!,
    IO() :$archive,
    Str :$host-slug = detect-slug(),
    :%env = %*ENV,
    :&run = &try-run,
    :@search = (),
    --> Hash
) {
    my %l = self.sqlcipher-layout($slug);

    with $archive {
        die "ariza: no SQLCipher archive at $archive" unless .f;
        return %( kind => 'archive', path => .self, version => Str,
                  origin => "local archive: {.basename}" );
    }

    my $named = (%env{SQLCIPHER-DIR-ENV} // '').trim;
    if $named.chars {
        # Windows is the one family whose library has more than one name
        # in circulation, so it is the one family whose named directory
        # is searched rather than indexed. Everywhere else the canonical
        # name is the only name.
        my ($lib, $found) = %l<family> eq 'windows'
            ?? windows-lib-in(%l<lib>, [$named])
            !! ($named.IO.add(%l<lib>), %l<lib>);
        # An operator who names a directory has ruled out every other
        # source; falling through to a different library when the named
        # one is absent would stage something they did not ask for.
        die "ariza: {SQLCIPHER-DIR-ENV}=$named holds no {%l<lib>}"
          ~ (%l<family> eq 'windows' ?? " (nor any {WINDOWS-LIB-GLOB})" !! '')
          ~ " — it must name the directory containing the SQLCipher library"
            unless $lib.defined && $lib.f;
        return %( kind => 'library', path => real-file($lib), version => Str,
                  origin => "{SQLCIPHER-DIR-ENV}: {$lib.absolute}"
                          ~ staged-as(%l<lib>, $found) );
    }

    die "ariza: SQLCipher for '$slug' cannot be taken from this machine"
      ~ ($host-slug.defined ?? " (which is $host-slug)"
                            !! " (whose platform ariza cannot name)")
      ~ " — a library installed here is built for the machine it is on.\n"
      ~ "    Build on a $slug machine, pass --sqlcipher-archive=FILE holding"
      ~ " a $slug build, or point {SQLCIPHER-DIR-ENV} at a directory with one."
        unless $host-slug.defined && $host-slug eq $slug;

    given %l<family> {
        when 'macos'   { self!sqlcipher-from-brew(%l<lib>, :&run) }
        when 'linux'   { self!sqlcipher-from-system(%l<lib>, :&run, :@search) }
        when 'windows' { self!sqlcipher-from-windows(%l<lib>, :%env, :@search) }
        default { die "ariza: no SQLCipher sourcing strategy for '$slug'" }
    }
}

#| macOS: an installed Homebrew keg, else the bottle Homebrew can fetch.
method !sqlcipher-from-brew(Str:D $lib-name, :&run! --> Hash) {
    my ($code, $out, $err) = run(['brew', '--prefix', 'sqlcipher']);

    # `brew --prefix <formula>` answers with the *would-be* keg path and
    # exits 0 whether or not the formula is installed, so the existence
    # of the library is the test, not the exit code. A non-zero exit
    # means no Homebrew at all (or no such formula), which is a different
    # problem with a different remedy.
    die "ariza: no SQLCipher on this machine, and no Homebrew to fetch it with.\n"
      ~ "    Install it with `brew install sqlcipher`, or pass"
      ~ " --sqlcipher-archive=FILE holding a prebuilt library, or point"
      ~ " {SQLCIPHER-DIR-ENV} at a directory containing $lib-name."
      ~ (($err || $out).trim ?? "\n    (brew --prefix sqlcipher: "
                                ~ ($err || $out).trim.lines.head ~ ')' !! '')
        unless $code == 0;

    my $prefix = $out.lines.map(*.trim).first(*.chars);
    with $prefix {
        my $lib = .IO.add('lib').add($lib-name);
        return %( kind => 'library', path => real-file($lib),
                  version => keg-version(.IO),
                  origin => "homebrew keg: {$lib.absolute}" )
            if $lib.f;
    }

    # Not installed, but Homebrew knows the formula: fetch the bottle and
    # take the library out of it. A bottle is the same binary `brew
    # install` would place in the keg, so this is the identical artefact
    # without touching the build machine's own software.
    my ($fetch-code, $, $fetch-err) = run(['brew', 'fetch', '--formula', 'sqlcipher']);
    die "ariza: sqlcipher is not installed and `brew fetch sqlcipher` failed.\n"
      ~ "    Install it with `brew install sqlcipher`, or pass"
      ~ " --sqlcipher-archive=FILE.\n"
      ~ ($fetch-err.trim ?? $fetch-err.trim.lines.map({ "    $_" }).join("\n") !! '')
        unless $fetch-code == 0;

    my ($cache-code, $cache-out, $cache-err) =
        run(['brew', '--cache', '--formula', 'sqlcipher']);
    my $bottle = $cache-code == 0
        ?? ($cache-out.lines.map(*.trim).first(*.chars) // '')
        !! '';
    die "ariza: `brew fetch sqlcipher` left nothing at the path"
      ~ " `brew --cache` names, so there is no bottle to stage from.\n"
      ~ "    Install sqlcipher with Homebrew, or pass --sqlcipher-archive=FILE."
      ~ ($cache-err.trim ?? "\n    ({$cache-err.trim.lines.head})" !! '')
        unless $bottle.chars && $bottle.IO.f;

    # `<sha>--sqlcipher--4.17.0.arm64_tahoe.bottle.tar.gz`
    my $version = $bottle.IO.basename ~~ / '--sqlcipher--' (\d+ [ '.' \d+ ]*) /
        ?? ~$0 !! Str;

    %( kind => 'archive', path => $bottle.IO, :$version,
       origin => "homebrew bottle: {$bottle.IO.basename}" )
}

#| Linux: whatever the dynamic loader already resolves, else the standard
#| library directories.
method !sqlcipher-from-system(Str:D $lib-name, :&run!, :@search --> Hash) {
    my @dirs = @search || @LINUX-LIB-DIRS;

    # The canonical soname first; where it is nowhere, EPEL's `sqlcipher`
    # package (and possibly others) renames the soname per version and
    # ships nothing called that at all — so the search widens to
    # anything shaped like the library from the same two sources.
    my ($path, $how, $found) = self!find-system-lib($lib-name, :&run, :@dirs,
                                                     :glob('libsqlcipher*.so*'));
    with $path {
        return %( kind => 'library', path => real-file($_), version => Str,
                  origin => "system library: {.absolute}"
                          ~ ($how eq 'ldconfig' ?? ' (ldconfig)' !! '')
                          ~ staged-as($lib-name, $found) );
    }

    die "ariza: no $lib-name on this machine.\n"
      ~ "    Install the distribution package — Debian/Ubuntu"
      ~ " `apt install libsqlcipher0`, Fedora/RHEL `dnf install sqlcipher`,"
      ~ " Alpine `apk add sqlcipher-libs` — or pass --sqlcipher-archive=FILE,"
      ~ " or point {SQLCIPHER-DIR-ENV} at a directory containing it.\n"
      ~ "    Looked in: {@dirs.join(', ')}";
}

#| Windows: an MSYS2 environment's C<bin>, or a vcpkg tree named by
#| C<VCPKG_ROOT> — C<SQLCIPHER_LIB_DIR>, which beats both, having already
#| been tried by C<sqlcipher-source>.
#|
#| Directory order is priority order, and within a directory the
#| canonical C<sqlcipher.dll> beats any C<libsqlcipher*.dll> variant. The
#| label the manifest records comes from which list answered, so
#| C<origin> still says where the bytes came from rather than only where
#| they are.
method !sqlcipher-from-windows(Str:D $lib-name, :%env!, :@search --> Hash) {
    my @dirs = @search
        ?? @search.map({ 'directory' => ~$_ })
        !! self!windows-dirs(%env);

    for @dirs -> $dir {
        my ($lib, $found) = windows-lib-in($lib-name, [$dir.value]);
        with $lib {
            return %( kind => 'library', path => real-file($_), version => Str,
                      origin => "{$dir.key}: {.absolute}"
                              ~ staged-as($lib-name, $found) );
        }
    }

    die "ariza: no $lib-name (nor any {WINDOWS-LIB-GLOB}) on this machine.\n"
      ~ "    Install MSYS2's UCRT build —"
      ~ " `pacman -S mingw-w64-ucrt-x86_64-sqlcipher`, which is prebuilt and"
      ~ " links against the ucrtbase.dll Windows itself ships — or build the"
      ~ " vcpkg port, then point {SQLCIPHER-DIR-ENV} at the directory holding"
      ~ " the DLL. Or pass --sqlcipher-archive=FILE.\n"
      ~ "    Looked in: {@dirs.map(*.value).join(', ')}";
}

#| The directories a Windows build looks in, as C<< label => path >>
#| pairs, in priority order: whichever MSYS2 environment this shell is
#| in, a vcpkg tree under C<VCPKG_ROOT>, then MSYS2's default prefixes.
#|
#| MSYS2 comes first on purpose. Its C<mingw-w64-ucrt-x86_64-*> packages
#| are built against the UCRT, whose C<ucrtbase.dll> is part of Windows
#| 10 and later; vcpkg's are built with MSVC and import
#| C<vcruntime140.dll>, which is B<not> — it arrives with the Visual C++
#| Redistributable, which a clean machine has no reason to have. Both are
#| still probed, because a machine that has only vcpkg's should build
#| rather than stop; the PE audit is what refuses to ship the result.
method !windows-dirs(%env --> List) {
    my @dirs;

    # Set by MSYS2's own shells, and by `msys2.cmd`/`setup-msys2`: the
    # prefix of the environment in use, e.g. C:\msys64\ucrt64.
    my $prefix = (%env<MSYSTEM_PREFIX> // '').trim;
    @dirs.push('msys2' => $prefix.IO.add('bin').absolute) if $prefix.chars;

    my $root = (%env<VCPKG_ROOT> // '').trim;
    @dirs.append(@VCPKG-TRIPLETS.map({
        'vcpkg' => $root.IO.add('installed').add($_).add('bin').absolute
    })) if $root.chars;

    @dirs.append(@MSYS2-BIN-DIRS.map({ 'msys2' => $_ }));
    @dirs.List
}

#| Where a library with this leaf name lives on this machine, as
#| C<(IO::Path, how, matched)> — C<how> is C<'ldconfig'> or
#| C<'directory'>, C<matched> is C<$name> itself — or the empty list
#| when it is nowhere.
#|
#| C<ldconfig -p> is the authority, because it reports what the loader
#| will actually find; but it lives in C</sbin>, which is not on every
#| user's C<PATH>, so the absolute path is tried too, and the standard
#| library directories after that (a fresh install with a stale cache).
#|
#| C<:$glob> widens the search past the exact name, once it has failed,
#| for a distribution that renames the soname per version — EPEL's
#| C<sqlcipher> ships C<libsqlcipher-3.34.1.so.0> and nothing literally
#| called C<libsqlcipher.so.0>. It is tried against the same two sources
#| (C<ldconfig -p>'s own soname column, and every regular file — not a
#| symlink — in C<@dirs>), and the newest match — by a numeric-aware
#| comparison of the filename, not a plain string sort, which would rank
#| C<-3.9.> above C<-3.34.> — is returned, with C<matched> naming the
#| leaf actually found so the caller can say what it renamed.
method !find-system-lib(Str:D $name, :&run!, :@dirs, Str :$glob --> List) {
    for <ldconfig /sbin/ldconfig> -> $tool {
        my ($code, $out, $) = run([$tool, '-p']);
        next unless $code == 0;
        for $out.lines -> $line {
            next unless $line.contains($name);
            $line ~~ / '=>' \s* (\S+) \s* $ / or next;
            my $path = (~$0).IO;
            next unless $path.f && $path.basename eq $name;
            return ($path, 'ldconfig', $name);
        }
    }

    for @dirs -> $dir {
        my $lib = $dir.IO.add($name);
        return ($lib, 'directory', $name) if $lib.f;
    }

    return () without $glob;

    my @found;
    for <ldconfig /sbin/ldconfig> -> $tool {
        my ($code, $out, $) = run([$tool, '-p']);
        next unless $code == 0;
        for $out.lines -> $line {
            $line ~~ / ^ \s* (\S+) \s+ .*? '=>' \s* (\S+) \s* $ / or next;
            my ($soname, $target) = ~$0, (~$1).IO;
            @found.push({ name => $soname, path => $target, how => 'ldconfig' })
                if glob-match($soname, $glob) && $target.f;
        }
    }
    for @dirs -> $dir {
        next unless $dir.IO.d;
        for $dir.IO.dir -> $entry {
            next unless $entry.f && !$entry.l && glob-match($entry.basename, $glob);
            @found.push({ name => $entry.basename, path => $entry, how => 'directory' });
        }
    }

    return () unless @found;
    my $best = @found.sort({ natural-cmp($^b<name>, $^a<name>) }).head;
    ($best<path>, $best<how>, $best<name>)
}

#| Put SQLCipher into the bundle: source it, place it, make it
#| self-contained, and (where the loader asks for a second name) alias
#| it.
#|
#| The pinned version is B<advisory>: the machine's package manager
#| decides what is actually staged, and a mismatch with C<versions.toml>
#| warns rather than failing the build. What goes in the manifest is what
#| was staged.
method stage-sqlcipher(
    IO() :$bundle-dir!,
    Str:D :$slug!,
    App::Ariza::Versions:D :$versions!,
    IO() :$archive,
    Str :$host-slug = detect-slug(),
    Str:D :$host-kernel = $*KERNEL.name.lc,
    :%env = %*ENV,
    :&run = &try-run,
    :@search = (),
    --> Hash
) {
    my %l   = self.sqlcipher-layout($slug);
    my %src = self.sqlcipher-source(:$slug, :$archive, :$host-slug, :%env,
                                    :&run, :@search);

    my $dest-dir = ensure-dir(self.sqlcipher-dir($bundle-dir, :$slug));
    my $staging  = $bundle-dir.add('.sqlcipher-staging');
    rm-rf($staging);
    LEAVE rm-rf($staging);

    my $src = do given %src<kind> {
        when 'archive' {
            extract-archive(%src<path>, $staging);
            # A bottle nests its payload under `sqlcipher/<version>/lib`,
            # a hand-rolled archive usually does not, and searching costs
            # nothing next to being wrong about either.
            self!find-under($staging, %l<lib>)
                // die "ariza: {%src<path>.basename} does not contain {%l<lib>}";
        }
        default { %src<path> }
    };

    # Digested before the copy, so the manifest records the library as it
    # came off the machine — a number the reader can reproduce with
    # `shasum` against their own keg. Install-name rewriting below
    # changes the bundled copy's bytes, by design.
    my $sha = sha256-file($src);

    my $lib = copy-writable($src, $dest-dir.add(%l<lib>));
    my @staged = $lib;

    if %l<family> eq 'macos' {
        # `@rpath/` for the library itself, because that is the install
        # name the loader was verified to resolve through the bundled
        # interpreter's `@executable_path/../lib` rpath; `@loader_path/`
        # for anything dragged in beside it, which is loaded relative to
        # the library that needs it.
        @staged.append: self!make-self-contained($lib, $dest-dir,
                                                 :id-prefix('@rpath/'));
    }
    elsif %l<family> eq 'linux' {
        @staged.append: self!stage-elf-deps($lib, $dest-dir, :$host-kernel, :&run);
    }
    elsif %l<family> eq 'windows' {
        # The source library's own directory is the search space, and
        # $src is the file itself — for an archive, the copy unpacked
        # into the staging directory, whose siblings came out of the same
        # archive.
        @staged.append: self!stage-pe-deps($lib, $dest-dir, $src.parent);
    }

    with %l<alias> -> $alias {
        self!alias-library($lib, $dest-dir.add($alias));
    }

    my $version = sqlcipher-version-of($lib) // %src<version>;
    my $pinned  = $versions.sqlcipher;

    # Neither of these is fatal, and both are said out loud: a build that
    # quietly ships a library it cannot name is the thing the manifest
    # exists to prevent.
    without $version {
        note "ariza: {%l<lib>} does not say what version it is, so the"
           ~ " manifest will record 'unknown' rather than the pin";
    }
    note "ariza: sqlcipher $version staged, pin says $pinned"
        if $version.defined && $pinned.defined && $version ne $pinned;

    {
        version   => $version,
        pinned    => $pinned,
        library   => $lib,
        rel       => self.sqlcipher-rel(:$slug),
        alias     => %l<alias>,
        staged    => @staged.List,
        origin    => %src<origin>,
        source    => %src<path>,
        kind      => %src<kind>,
        sha256    => $sha,
    }
}

#| Rewrite a staged Mach-O so every dependency resolves inside the
#| bundle, copying in whatever it needs, and re-sign everything touched.
#|
#| Returns the extra files copied alongside. Recursive: a dependency's
#| own dependencies get the same treatment.
method !make-self-contained(IO::Path $file, IO::Path $dir,
                            Str:D :$id-prefix = '@loader_path/',
                            :%seen = {} --> List) {
    my @added;
    %seen{$file.absolute} = True;

    my $base = $file.basename;
    my @changed;

    # The install name is not a dependency — it is what other binaries
    # will record when they link this one — so it is rewritten rather
    # than resolved. Getting this wrong means trying to copy the build
    # machine's own path in as if it were a library the file needs.
    my $id = self!macho-id($file);
    if $id.defined && $id !~~ MACHO-ALLOWED {
        run-checked(['install_name_tool', '-id', $id-prefix ~ $base,
                     $file.absolute], :what('install_name_tool -id'));
        @changed.push($id);
    }

    for self!macho-deps($file, $id) -> $dep {
        my $dep-base = $dep.split('/').tail;
        my $src      = $dep.IO;
        die "ariza: {$file.basename} needs $dep, which is not on this machine"
          ~ " — the archive is not self-contained and cannot be made so here"
            unless $src.f;

        my $copy = $dir.add($dep-base);
        unless $copy.e {
            copy-writable($src, $copy);
            @added.push($copy);
            @added.append: self!make-self-contained($copy, $dir, :%seen)
                unless %seen{$copy.absolute};
        }

        run-checked(['install_name_tool', '-change', $dep,
                     "\@loader_path/$dep-base", $file.absolute],
                    :what('install_name_tool -change'));
        @changed.push($dep);
    }

    # install_name_tool invalidates the ad-hoc signature the linker
    # emitted, and macOS on arm64 refuses to load an incorrectly signed
    # library. Every file that was rewritten is re-signed by the call
    # that rewrote it, so the recursion above has already handled the
    # copies.
    self!codesign($file) if @changed;

    @added.List
}

#| The C<LC_ID_DYLIB> of a Mach-O shared library, or the undefined
#| C<Str> for anything without one (an executable, an object file).
method !macho-id(IO::Path $file --> Str) {
    my ($code, $out, $) = try-run(['otool', '-D', $file.absolute]);
    return Str unless $code == 0;
    my $id = $out.lines.skip(1).map(*.trim).first(*.chars);
    $id // Str
}

#| The dependencies of a Mach-O that do not resolve inside a bundle,
#| with its own install name excluded.
method !macho-deps(IO::Path $file, Str $id --> List) {
    macho-strays(self!otool($file)).grep({ !$id.defined || $_ ne $id }).List
}

#| Make a staged ELF self-contained: copy every non-system dependency in
#| beside it, and set C<RUNPATH> to C<$ORIGIN> on the lot so the loader
#| looks in the bundle's own directory first.
#|
#| Returns the extra files copied alongside, for the manifest and the
#| audit.
#|
#| Two things stop the pass rather than let it run badly. First, a file
#| that is not an ELF at all: there are no dependencies to walk, and the
#| audit — which reads magic numbers too — skips it in exactly the same
#| way. Second, a host that is not Linux: walking an ELF's dependencies
#| means resolving its sonames against I<this> machine's libraries, and a
#| Mac has none of them, nor an C<ldd> or a C<patchelf> to ask. That
#| second case gets a loud warning rather than a silent skip, because the
#| bundle it produces is exactly the thing this pass exists to prevent —
#| one that loads the user's OpenSSL.
method !stage-elf-deps(IO::Path $lib, IO::Path $dir,
                       Str:D :$host-kernel!, :&run! --> List) {
    return () unless (binary-format($lib) // '') eq 'ELF';

    unless $host-kernel eq 'linux' {
        note "ariza: {$lib.basename} is an ELF being staged on a $host-kernel"
           ~ " host, so its dependencies cannot be resolved or copied in"
           ~ " here — this bundle will load them from whatever the user's"
           ~ " machine happens to have.\n"
           ~ "    Build the Linux bundle on Linux, or pass"
           ~ " --sqlcipher-archive=FILE holding a library that is already"
           ~ " self-contained.";
        return ();
    }

    die "ariza: making {$lib.basename} self-contained needs patchelf, and"
      ~ " there is none on this machine.\n"
      ~ "    Install it — `dnf install patchelf`, `apt install patchelf`,"
      ~ " `apk add patchelf` — because without it the bundle would resolve"
      ~ " OpenSSL from the user's system instead of from beside the library."
        unless have-command('patchelf', :&run);

    my @added = self!copy-elf-deps($lib, $dir, :&run);

    # After the walk, not during it: a dependency is discovered by asking
    # the loader where it resolves *today*, and giving a file $ORIGIN
    # half way through would have it resolve against a directory that
    # does not hold the answer yet.
    self!set-origin-rpath($_, :&run) for $lib, |@added;

    @added
}

#| Copy an ELF's non-system dependencies in beside it, recursively.
method !copy-elf-deps(IO::Path $file, IO::Path $dir, :&run!,
                      :%seen = {} --> List) {
    my @added;
    %seen{$file.absolute} = True;

    for self!elf-deps($file, :&run) -> $dep {
        my $name = $dep.key;
        die "ariza: {$file.basename} needs $name, which the loader cannot"
          ~ " find on this machine — the library is not self-contained and"
          ~ " cannot be made so here"
            without $dep.value;

        my $copy = $dir.add($name);
        unless $copy.e {
            copy-writable(real-file($dep.value.IO), $copy);
            @added.push($copy);
            @added.append: self!copy-elf-deps($copy, $dir, :&run, :%seen)
                unless %seen{$copy.absolute};
        }
    }

    @added.List
}

#| The non-system dependencies of an ELF, as C<soname => path> pairs.
#|
#| C<ldd> first, because it I<is> the loader: its answer is the one the
#| machine will give at run time, including whatever the build exported
#| in C<LD_LIBRARY_PATH> to point at a hand-built prefix. Where there is
#| no C<ldd> to run, C<readelf -d> plus the loader's own search path is
#| the same question asked the long way round.
method !elf-deps(IO::Path $file, :&run! --> List) {
    my ($code, $out, $) = run(['ldd', $file.absolute]);
    return ldd-deps($out).grep({ !elf-system-lib(.key) }).List
        if $code == 0 || $out.contains('=>');

    my $reader = elf-reader(:&run)
        // die "ariza: resolving {$file.basename}'s dependencies needs ldd or"
             ~ " readelf, and this machine has neither. Install glibc's ldd,"
             ~ " binutils or elfutils.";

    my ($rc, $rout, $rerr) = run([$reader, '-d', $file.absolute]);
    die "ariza: $reader failed on {$file.absolute}"
      ~ (($rerr || $rout).trim ?? ": {($rerr || $rout).trim.lines.head}" !! '')
        unless $rc == 0;

    elf-needed($rout).grep({ !elf-system-lib($_) })
        .map({ $_ => self!resolve-soname($_, :&run) }).List
}

#| Where the loader would find a bare soname, or the undefined C<Str>.
method !resolve-soname(Str:D $soname, :&run! --> Str) {
    my ($path, $) = self!find-system-lib($soname, :&run, :dirs(@LINUX-LIB-DIRS));
    $path.defined ?? $path.absolute !! Str
}

#| C<patchelf --set-rpath '$ORIGIN'>, with no C<|| true> anywhere near
#| it: a silently unpatched library falls back to C</lib64> on the user's
#| machine, which is precisely the bug being fixed and is invisible on
#| the machine that built it.
method !set-origin-rpath(IO::Path $file, :&run!) {
    my ($code, $out, $err) = run(['patchelf', '--set-rpath', '$ORIGIN',
                                  $file.absolute]);
    die "ariza: patchelf --set-rpath failed on {$file.absolute} (exit $code)"
      ~ (($err || $out).trim
            ?? ":\n" ~ ($err || $out).trim.lines.map({ "    $_" }).join("\n")
            !! '')
        unless $code == 0;
}

#| Make a staged PE self-contained: copy every non-system DLL it imports
#| in beside it, and recurse into each copy.
#|
#| Returns the extra files copied alongside, for the manifest and the
#| audit.
#|
#| There is no rpath step and no rewriting: Windows resolves an import by
#| name, and the first place it looks is the directory of the module
#| doing the importing. Putting the DLLs in one directory I<is> the
#| relocation story, which is why this pass is shorter than the other
#| two and why its audit is a containment check rather than a tag check.
#|
#| Nor is there a host guard. C<pe-imports> reads the file rather than
#| asking the machine, so a Windows bundle assembled from an archive on a
#| Mac gets exactly the same walk, the same copies and the same audit as
#| one built on Windows.
#|
#| A file that is not a PE is skipped, the same way the ELF pass skips a
#| non-ELF and the audit skips both: there is nothing to walk.
method !stage-pe-deps(IO::Path $lib, IO::Path $dir, IO::Path $from --> List) {
    return () unless (binary-format($lib) // '') eq 'PE';
    self!copy-pe-deps($lib, $dir, $from)
}

#| Copy a PE's non-system imports in beside it, recursively, out of
#| C<$from>.
#|
#| C<$from> is the directory the staged library itself came from, and it
#| is the only place searched. That is a contract with the source rather
#| than a shortcut: a vcpkg port installs its whole runtime closure into
#| one C<installed/E<lt>tripletE<gt>/bin>, so C<sqlcipher.dll>'s OpenSSL
#| is the C<libcrypto-3-x64.dll> sitting beside it — and searching wider
#| (C<PATH>, C<System32>) would pick up a same-named DLL from a different
#| build of a different version, which is precisely the bug a bundle
#| exists to avoid. An import that is not there is fatal and says both
#| the name and the directory, because there is nothing honest to do with
#| it.
method !copy-pe-deps(IO::Path $file, IO::Path $dir, IO::Path $from,
                     :%seen = {} --> List) {
    my @added;
    %seen{$file.basename.lc} = True;

    for pe-imports($file).grep({ !pe-system-dll($_) }) -> $name {
        my $src = find-beside($from, $name)
            // die "ariza: {$file.basename} imports $name, which is not in"
                 ~ " {$from.absolute}.\n"
                 ~ "    That directory is where ariza looks for everything a"
                 ~ " staged DLL needs, because the package that shipped the"
                 ~ " DLL puts its whole runtime closure there. Point"
                 ~ " {SQLCIPHER-DIR-ENV} at a directory holding"
                 ~ " {$file.basename} and every DLL it imports, or — if"
                 ~ " $name is part of Windows itself — add it to"
                 ~ " App::Ariza::Native's PE-SYSTEM-DLLS.";

        my $copy = $dir.add($name);
        unless $copy.e {
            copy-writable($src, $copy);
            @added.push($copy);
        }
        # Keyed by name rather than by path, and folded, because Windows
        # resolves imports that way: one file answers for every spelling.
        @added.append: self!copy-pe-deps($copy, $dir, $from, :%seen)
            unless %seen{$name.lc};
    }

    @added.List
}

#| Give a staged library its second name — C<libsqlcipher.dylib> beside
#| C<libsqlcipher.0.dylib> — so both resolve to one loaded image.
#|
#| Shelling out to C<ln -s> rather than using C<IO::Path.symlink>, which
#| absolutises its target: a link into the build machine's checkout
#| survives being tarred and points at nothing on the user's disk. The
#| link has to be C<libsqlcipher.0.dylib>, relative, and only C<ln> will
#| write it that way.
#|
#| Windows has no C<ln> and, without developer mode, no unprivileged
#| symlinks either, so there it is a copy — one duplicated library, and
#| honest.
method !alias-library(IO::Path $lib, IO::Path $link) {
    $link.unlink if $link.e || $link.l;

    unless $*DISTRO.is-win {
        my ($code, $, $) = try-run(['ln', '-s', $lib.basename, $link.absolute]);
        return if $code == 0 && ($link.e || $link.l);
    }
    copy-writable($lib, $link);
}

method !codesign(IO::Path $file) {
    return unless $*KERNEL.name.lc eq 'darwin';
    try-run(['codesign', '--remove-signature', $file.absolute]);
    run-checked(['codesign', '--sign', '-', '--force', $file.absolute],
                :what("codesigning {$file.basename}"));
}

method !otool(IO::Path $file --> Str) {
    run-checked(['otool', '-L', $file.absolute], :what("otool -L {$file.basename}"))
}

method !find-under(IO::Path $dir, Str:D $name --> IO::Path) {
    my @queue = $dir;
    while @queue {
        my $d = @queue.shift;
        for $d.dir -> $e {
            return $e if !$e.d && $e.basename eq $name;
            @queue.push($e) if $e.d && !$e.l;
        }
    }
    IO::Path
}

#| Every dependency a PE audit can object to.
#|
#| The report is the same C<< name => path >> shape C<ldd> produces, one
#| line per non-system import, with C<not found> for an import that is
#| nowhere the loader would look. Any other non-empty line is a finding
#| in its own words — that is how C<empty file> and C<not a PE file>
#| reach the failure message.
#|
#| Every dependency must resolve to a path under one of C<:@inside> (the
#| bundle), by the same separator-normalised comparison the ELF audit
#| uses. With no C<:@inside> given, containment cannot be judged and only
#| C<not found> is reported.
our sub pe-strays(Str:D $report, :@inside = () --> List) is export {
    my @strays;
    for $report.lines.map(*.trim).grep(*.chars) -> $line {
        unless $line.contains(' => ') {
            @strays.push($line);
            next;
        }
        my ($name, $path) = $line.split(' => ', 2).map(*.trim);
        next unless $name.chars;
        # The inspector has already dropped these; a hand-written report
        # (a test, a future inspector) should not be judged differently.
        # The redistributable family is the exception: it is on the
        # skiplist so that nothing copies it in, and judged anyway.
        my $redist = pe-redist-dll($name);
        next if pe-system-dll($name) && !$redist;
        unless $path.chars && $path ne 'not found' {
            @strays.push($redist ?? redist-finding($name, 'not found')
                                 !! "$name => not found");
            next;
        }
        next unless @inside;
        unless path-inside($path, @inside) {
            @strays.push($redist ?? redist-finding($name, $path) !! $line);
        }
    }
    @strays.unique.List
}

#| What the audit says about an imported Visual C++ runtime the bundle
#| does not carry: the consequence, and both ways out of it.
#|
#| Spelled out in full rather than left to the failure's closing
#| sentence, because this finding contradicts what the person reading it
#| just saw with their own eyes — the bundle worked on the machine that
#| built it, and it worked on the CI runner, because both of those have
#| the redistributable installed. Nothing but the whole explanation is
#| going to be believed.
my sub redist-finding(Str:D $name, Str:D $where --> Str) {
    "$name => $where (Visual C++ Redistributable: not part of Windows and"
  ~ " not in the bundle, so this file loads only on a machine that has"
  ~ " installed it — which every CI runner has and a clean install does"
  ~ " not. Use a UCRT-built library instead: MSYS2's"
  ~ " mingw-w64-ucrt-x86_64-* packages import ucrtbase.dll, which Windows"
  ~ " has shipped since Windows 10. Or put $name in the bundle yourself —"
  ~ " it is Microsoft's to redistribute, so ariza will not copy it in for"
  ~ " you.)"
}

#| The report the PE audit judges: every non-system import of a staged
#| DLL, resolved the way Windows resolves it for a bundled library —
#| beside the file that imports it.
#|
#| Beside, and nowhere else, is the whole rule. The loader searches the
#| loading module's own directory first, and everything ariza stages for
#| Windows lands in one directory, so an import that is not there is one
#| the user's C<PATH> would have to answer for — which is the failure
#| this audit exists to catch.
#|
#| The path is resolved before it is reported, so a link pointing out of
#| the bundle is judged by where it goes rather than by where it sits.
#|
#| The Visual C++ runtime is reported too, though it is on the skiplist:
#| it is the one family of names that is neither shipped by Windows nor
#| copied in by ariza, so "where did it resolve" is a question worth
#| asking about it. See C<redist-finding>.
my sub pe-report(IO::Path $file --> Str) {
    my @judged = pe-imports($file)
        .grep({ !pe-system-dll($_) || pe-redist-dll($_) });
    @judged.map(-> $name {
        my $found = find-beside($file.parent, $name);
        "$name => " ~ ($found.defined
            ?? ((try { $found.resolve.absolute }) // $found.absolute)
            !! 'not found')
    }).join("\n")
}

#| Audit every native binary ariza put into the bundle.
#|
#| Returns C<{ checked, skipped, findings, family }>. Dies — loudly,
#| naming each offending file and each offending dependency — if anything
#| would load from outside the bundle at run time.
#|
#| C<:@extra> adds paths outside C<native/>; that is how the macOS
#| SQLCipher library gets audited, since it lives in C<rakudo/lib> beside
#| files ariza did not put there and has no business inspecting.
#|
#| C<:&inspect> replaces the tool call: it takes an C<IO::Path> and
#| returns the report text for that file, or an undefined C<Str> for a
#| file of the wrong format (which is counted as skipped). Every branch
#| of the audit's judgement is then reachable from a test on any machine
#| — including the Linux and Windows verdicts from a Mac.
method audit(
    IO() :$bundle-dir!,
    Str:D :$slug!,
    :@extra = (),
    :&inspect,
    Str:D :$host-kernel = $*KERNEL.name.lc,
    :&run = &try-run,
    --> Hash
) {
    my @files = flat(
        self!files-under($bundle-dir.add('native')),
        @extra.map(*.IO).grep({ .f && !.l }),
    ).unique(as => *.absolute);

    # Both spellings of the bundle's own path: the loader reports where
    # it resolved $ORIGIN to, and a build directory reached through a
    # symlink (/tmp on a Mac, a CI workspace mount) is not spelled the
    # same way twice.
    my @inside = ($bundle-dir.absolute,
                  (try { $bundle-dir.resolve.absolute }) // Str)
                 .grep(*.defined).unique;

    my $family = $slug.split('-').head;
    my &strays = do given $family {
        when 'macos'   { &macho-strays }
        when 'linux'   { -> Str $r { elf-strays($r, :@inside) } }
        when 'windows' { -> Str $r { pe-strays($r, :@inside) } }
        default { die "ariza: no native audit knows how to check '$slug'" }
    };
    my &probe = &inspect // self!default-inspector($family, :$host-kernel, :&run);

    my %result = checked => 0, skipped => 0, findings => [], family => $family;

    for @files -> $f {
        my $report = probe($f);
        without $report { %result<skipped>++; next }
        %result<checked>++;
        my @found = strays($report);
        %result<findings>.push({ file => $f.absolute, strays => @found })
            if @found;
    }

    if %result<findings> {
        my $detail = %result<findings>.map({
            "    {.<file>}\n" ~ .<strays>.map({ "        $_" }).join("\n")
        }).join("\n");
        die "ariza: {+%result<findings>} native file(s) in the bundle load"
          ~ " libraries from outside it:\n$detail\n"
          ~ "  A bundle that resolves a library off the build machine works"
          ~ " here and nowhere else.";
    }

    %result
}

#| The tool that produces a report for one file, per platform family.
#| Returns the undefined C<Str> for a file of the wrong format.
#|
#| The Linux inspector asks the loader as well as the file, but only when
#| it is running B<on> Linux: C<patchelf> and C<ldd> answer for the
#| machine they are on, and there is no cross-inspecting them. Auditing
#| an ELF from a Mac is the static half, and says so in the Pod rather
#| than pretending to more.
method !default-inspector(Str:D $family, Str:D :$host-kernel!,
                          :&run! --> Callable) {
    given $family {
        when 'macos' {
            -> IO::Path $f {
                (binary-format($f) // '') eq 'Mach-O' ?? self!otool($f) !! Str
            }
        }
        when 'linux' {
            my $tool = elf-reader(:&run)
                // die "ariza: auditing a Linux bundle needs readelf"
                     ~ " (binutils or elfutils)";
            my $host = $host-kernel eq 'linux';

            die "ariza: auditing a Linux bundle on Linux needs patchelf, to"
              ~ " read back the rpath the loader will use.\n"
              ~ "    Install it — `dnf install patchelf`, `apt install"
              ~ " patchelf`, `apk add patchelf`."
                if $host && !have-command('patchelf', :&run);

            -> IO::Path $f {
                if (binary-format($f) // '') eq 'ELF' {
                    my ($code, $out, $err) = run([$tool, '-d', $f.absolute]);
                    die "ariza: $tool failed on {$f.absolute}: {$err.trim}"
                        unless $code == 0;
                    my @report = $out.chomp;
                    if $host {
                        @report.push(ELF-RPATH-SECTION, elf-rpath($f, :&run));
                        @report.push(ELF-LDD-SECTION, elf-clean-ldd($f, :&run));
                    }
                    @report.join("\n")
                }
                else { Str }
            }
        }
        when 'windows' {
            # No `return` here: a pointy block is a Block, not a Routine,
            # and returning from one dies outside its dynamic scope.
            -> IO::Path $f {
                if (binary-format($f) // '') eq 'PE' {
                    pe-report($f)
                }
                # A file named like a DLL that is not one is a finding,
                # not a skip: something put it there, and the loader will
                # be asked for it by name.
                elsif $f.basename.lc.ends-with('.dll') {
                    $f.s > 0 ?? 'not a PE file, though it is named like one'
                             !! 'empty file'
                }
                else { Str }
            }
        }
        default { die "ariza: no native audit knows how to check '$family'" }
    }
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
    @out.sort(*.absolute).List
}

=begin pod

=head1 NAME

App::Ariza::Native - stage SQLCipher into a bundle, and prove nothing loads from outside it

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::Native;
use App::Ariza::Versions;

my %sql = App::Ariza::Native.stage-sqlcipher(
    :bundle-dir($work),
    :slug<macos-arm64>,
    :versions(App::Ariza::Versions.load),
);

say %sql<rel>;              # rakudo/lib/libsqlcipher.0.dylib
say %sql<version>;          # 4.14.0   (what was staged)
say %sql<pinned>;           # 4.14.0   (what versions.toml expected)
say %sql<origin>;           # homebrew keg: /opt/homebrew/opt/sqlcipher/lib/...
say %sql<sha256>;           # digest of the library as it came off the machine

# Everything that had to travel with it. On Linux this is the library
# plus the OpenSSL a bare NEEDED would otherwise have borrowed from the
# user's machine, each with its rpath set to $ORIGIN:
say %sql<staged>.map(*.basename);   # (libsqlcipher.so.0 libcrypto.so.3 libz.so.1)

# Where it would come from, without staging anything:
say App::Ariza::Native.sqlcipher-source(:slug<macos-arm64>)<origin>;

# Stage from a file instead — an air-gapped build, or a cross-build:
App::Ariza::Native.stage-sqlcipher(..., :archive('/tmp/libsqlcipher-linux-x86_64.tar.gz'));

# Everything ariza put in the bundle must resolve inside it:
my %audit = App::Ariza::Native.audit(
    :bundle-dir($work), :slug<macos-arm64>, :extra(%sql<staged>));
say %audit<checked>;        # 31

# The verdict functions are pure, and take tool output as text:
say macho-strays(qq:to/OUT/);
    libfoo.dylib:
    	/opt/homebrew/lib/libcrypto.3.dylib (compatibility version 3.0.0)
    OUT
# (/opt/homebrew/lib/libcrypto.3.dylib)

# Windows needs no tool: a PE's import table is read out of its bytes,
# from any host.
say pe-imports('sqlcipher.dll'.IO);
# (libcrypto-3-x64.dll KERNEL32.dll api-ms-win-crt-heap-l1-1-0.dll)
say pe-imports('sqlcipher.dll'.IO).grep({ !pe-system-dll($_) });
# (libcrypto-3-x64.dll)

# ...with one family on that skiplist the audit judges anyway, because
# Windows does not actually ship it:
say pe-redist-dll('vcruntime140.dll');      # True
say pe-redist-dll('ucrtbase.dll');          # False — that one is the OS

=end code

=head1 DESCRIPTION

Two jobs, deliberately together: putting native libraries into a bundle,
and refusing to ship one that would load a library from anywhere else.

The notcurses side needs no work here — L<App::Ariza::Site> stages it as
a side effect of the C<zef> install, by pointing
C<NOTCURSES_NATIVE_DATA_DIR> at the bundle. SQLCipher has no such hook,
so this module finds a copy on the build machine and places it.

=head1 SQLCIPHER

=head2 Where it goes, and why macOS is different

=item1 B<macOS> — C<< <bundle>/rakudo/lib >>.
=item1 B<Linux> — C<< <bundle>/native/sqlcipher >>.
=item1 B<Windows> — C<< <bundle>/native/sqlcipher >>.

macOS is the odd one out because two separate things resolve there for
free. The bundled C<moar> carries C<LC_RPATH @executable_path/../lib>, so
C<is native('sqlcipher')> — which is how C<DBDish::SQLCipher> binds every
one of its functions, with a bare library name and no environment
variable in sight — finds the library with no launcher involvement at
all. And it is exactly the directory App::Moneymoor's entry script probes
before deciding whether to pay for C<MacOS::NativeLib>'s C<brew config>
round-trip, so staging there also removes about a second from every
launch.

That C<is native('sqlcipher')> binding is worth dwelling on, because it
is why C<DBIISH_SQLCIPHER_LIB> alone is not enough anywhere:
C<DBDish::SQLCipher> uses that variable to pre-C<dlopen> a library by
absolute path, but its actual FFI declarations still name C<sqlcipher>
by leaf name, so the leaf name has to resolve too. Linux and Windows get
both — C<LD_LIBRARY_PATH>/C<PATH> for the leaf name and
C<DBIISH_SQLCIPHER_LIB> for the pre-load — from the launcher.

Each platform also gets the second name the loader may ask for
(C<libsqlcipher.dylib> beside C<libsqlcipher.0.dylib>) as a symlink, so
one image serves both, falling back to a copy where symlinks are not
available.

=head2 Where it comes from: the machine's own package manager

There is no ariza-operated SQLCipher mirror, and there is not going to
be one. SQLCipher's ABI does not move often enough to justify a second
piece of release infrastructure with its own signing story, its own
staleness and its own outage; CI installs the distribution package
before it calls C<ariza bundle>, exactly as a developer does on a
laptop. What makes a package-manager library safe to redistribute is the
self-containment pass and the audit below, not where it was downloaded
from.

So sourcing resolves in this order:

=item1 C<:archive> (C<--sqlcipher-archive=FILE>) — a tarball or zip to
unpack and search. It beats everything, and is the answer for an
air-gapped build or a cross-build.

=item1 C<SQLCIPHER_LIB_DIR> — a directory holding the library. Named by a
human, so it also beats the package managers. If the directory does not
contain the library, that is fatal rather than a silent fall-through:
someone who names a directory has ruled out every other source.

=item1 The platform's package manager:

=item2 B<macOS> — C<brew --prefix sqlcipher>, and the keg's
C<lib/libsqlcipher.0.dylib> (symlinks chased, so what is copied is
bytes rather than a link into a Cellar that will not exist on the user's
machine). Not installed but Homebrew present:
C<brew fetch --formula sqlcipher> and the bottle out of C<brew --cache>,
which is the same binary C<brew install> would have placed. No Homebrew
at all is a die naming C<brew install sqlcipher> and
C<--sqlcipher-archive>.

=item2 B<Linux> — C<ldconfig -p> (tried as both C<ldconfig> and
C</sbin/ldconfig>, which is not on every user's C<PATH>), then the
Debian multiarch, Red Hat and Alpine library directories. The exact
canonical name — C<libsqlcipher.so.0> — wins outright when it is there;
where it is not, EPEL's C<sqlcipher> package renames the soname per
version and ships nothing literally called that, so any
C<libsqlcipher*.so*> from the same two sources is considered too, and
the newest of them — by a numeric-aware comparison, not a plain string
sort — is taken, with C<origin> naming what was actually found. That
rename is safe: C<is native('sqlcipher')> dlopens the staged copy by
leaf name through C<LD_LIBRARY_PATH>, which resolves by filename and
never consults the file's own C<DT_SONAME>, so a distro library staged
under the canonical name loads exactly as if it had been called that on
the machine that built it. Absent is a die naming
C<dnf install sqlcipher>, C<apt install libsqlcipher0> and
C<apk add sqlcipher-libs>, and C<--sqlcipher-archive>.

=item2 B<Windows> — an MSYS2 environment's C<bin> (C<MSYSTEM_PREFIX>,
then C<C:\msys64\ucrt64\bin> and C<C:\msys64\mingw64\bin>) and a vcpkg
tree under C<VCPKG_ROOT>, in that order. Absent is a die naming
C<pacman -S mingw-w64-ucrt-x86_64-sqlcipher>, vcpkg,
C<SQLCIPHER_LIB_DIR> and C<--sqlcipher-archive>. Whichever directory
answers, it is more than where the DLL is found: it is also the search
space for everything that DLL imports (see below), because both package
managers install a port's whole runtime closure into one directory
(C<installed/E<lt>tripletE<gt>/bin>, C<ucrt64/bin>).

MSYS2 is preferred, and the reason is C<vcruntime140.dll>. vcpkg builds
with MSVC, so its C<sqlcipher.dll> imports the Visual C++ runtime, which
is B<not> part of Windows: it arrives with the Visual C++
Redistributable, which every CI runner and every developer machine has
and a clean install has not. MSYS2's C<mingw-w64-ucrt-x86_64-*> packages
import C<ucrtbase.dll> instead, which Windows 10 and later ship in
C<System32>. They are also prebuilt, which removes the fifteen-minute
source build the vcpkg lane needed and the cache it needed to avoid it.
"The redistributable gate" below is what happens if an MSVC-built
library is staged anyway.

The two package managers do not agree on what the library is called,
either: vcpkg's port produces C<sqlcipher.dll> and MSYS2's produces
C<libsqlcipher-0.dll>. So the canonical name wins where it is found —
per directory, in priority order, matched case-insensitively as the
loader matches it — and where no directory holds it the search widens to
C<libsqlcipher*.dll>, newest first by the same numeric-aware comparison
the Linux pass uses (C<-3.34.> above C<-3.9.>, which a string sort gets
backwards). C<origin> names what was actually found.

Whatever is found is staged under the canonical C<sqlcipher.dll>, and
that rename is safe for exactly the reason the Linux one is:
C<LoadLibrary> resolves a DLL by the leaf name on disk and never
consults the module's internal name in its export directory, just as
C<dlopen> never consults C<DT_SONAME>. A C<libsqlcipher-0.dll> staged as
C<sqlcipher.dll> loads as if it had been built under that name.

=head2 A system library only fits the system it came from

Taking C<macos-arm64>'s library off this machine while building a
C<macos-x86_64> or C<linux-x86_64-glibc> bundle would produce an
artefact that fails at C<dlopen> on every machine it was built for, so
the package-manager strategies refuse to run unless the requested slug
I<is> this machine's slug. The two explicit forms — C<:archive> and
C<SQLCIPHER_LIB_DIR> — bypass that check, because a human naming a file
has already said which platform it is for.

That is the whole cross-build story: build C<linux-x86_64-glibc> on
Linux (which is what CI does), or hand ariza a Linux library.

=head2 The pinned version is advisory

C<versions.toml> keeps C<sqlcipher = "4.14.0">, but it is now the
version ariza I<expects>, not one it can enforce: the machine's package
manager decides what is actually installed. A mismatch prints

=begin code :lang<console>

ariza: sqlcipher 4.17.0 staged, pin says 4.14.0

=end code

and the build continues. The manifest records what was staged, never the
pin — a manifest that quotes a number nobody verified is worse than no
number at all — with the pin alongside it as C<pinned>.

The version is read out of the staged library: SQLCipher keeps
C<CIPHER_VERSION> as a NUL-terminated C<X.Y.Z> constant, and
C<sqlcipher-version-of> looks for exactly that, reporting the undefined
C<Str> unless it finds exactly one candidate. Filenames are no use here
— a Homebrew keg's real file is C<libsqlcipher.3.51.3.dylib> (SQLite's
version, inherited) and Debian's is C<libsqlcipher.so.0.8.6> (libtool's
C<current.revision.age>); neither is the C<4.x> number anyone means.

=head2 Making the staged library self-contained (macOS)

A Homebrew library names its OpenSSL dependency by absolute path —
C</opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib> — which exists on
the machine that built the bundle and on no user's machine at all.
Rewriting the library's own install name does not touch that.

This pass, and the audit that follows it, are what make a
package-manager-sourced library safe to ship at all; they are the reason
the mirror was never needed.

So after placing the library, every dependency that is not
bundle-relative or part of macOS is copied in beside it, rewritten to
C<@loader_path/E<lt>nameE<gt>>, and recursed into. Then everything
touched is re-signed: C<install_name_tool> invalidates the linker's
ad-hoc signature, and macOS on arm64 will not load an incorrectly signed
library — a failure that surfaces as an unexplained C<dlopen> error, not
as a signature complaint.

A dependency that is missing from the build machine is fatal. There is
nothing honest to do with it: the archive is not self-contained and
cannot be made so from here.

=head2 Making the staged library self-contained (Linux)

ELF hides the same problem better, which is why it went unnoticed
longer. A distribution's C<libsqlcipher.so.0> names its OpenSSL as a
bare C<DT_NEEDED libcrypto.so.3> — no path, no C<RPATH>, nothing an
audit that only reads the file can object to. It is also, at run time,
"whatever C<libcrypto.so.3> this machine has", which for a bundle whose
entire promise is that it carries its own dependencies is the one thing
it must not be: no OpenSSL 3 on the user's box and the database never
opens; a different OpenSSL 3 and it opens with code nobody tested.

So Linux gets the same three steps macOS gets, spelled the way ELF
spells them:

=item1 B<Walk.> C<ldd> — which I<is> the loader, and therefore answers
with what the machine will really do, including whatever the build
exported in C<LD_LIBRARY_PATH> — reports where each C<NEEDED> soname
resolves. Where there is no C<ldd>, C<readelf -d> plus C<ldconfig -p>
and the standard library directories ask the same question the long way
round.

=item1 B<Copy in.> Every dependency that is not on the skiplist is
copied in beside the library under its soname, and recursed into. The
skiplist is Notcurses-Native's C<scripts/ci/bundle-elf.sh> list — the
loader, C<libc>, C<libm>, C<libpthread>, C<libdl>, C<librt>,
C<libgcc_s>, C<libstdc++> and friends, which must stay dynamic or two
C libraries end up in one address space — with one deliberate
difference: B<C<libcrypto> and C<libssl> are not on it>. That script
leaves them dynamic because ffmpeg's use of them is optional. SQLCipher
without OpenSSL is SQLite.

=item1 B<Point at them.> C<patchelf --set-rpath '$ORIGIN'> on the
library and on every copy, so each finds its siblings in its own
directory wherever the bundle is unpacked. This runs after the walk, not
during it: a file given C<$ORIGIN> half way through would resolve
against a directory that does not hold the answer yet. There is no
C<|| true> on it — a silently unpatched library falls back to
C</lib64> on the user's machine, which is invisible on the machine that
built it.

The launcher still exports C<LD_LIBRARY_PATH> for the bundle's SQLCipher
directory, and still should: C<$ORIGIN> covers the library's own
dependencies, and C<LD_LIBRARY_PATH> covers C<is native('sqlcipher')>
asking for a bare leaf name with no C<NEEDED> entry pointing anywhere.
They answer different questions and each is load-bearing.

This pass needs a Linux machine, and says so rather than pretending: it
resolves sonames against I<this> machine's libraries, with C<ldd> and
C<patchelf>. Staging an ELF anywhere else — a Mac cross-building from
C<--sqlcipher-archive> — prints a warning naming what could not be done
and carries on, because the archive may already be self-contained (one
made by C<bundle-elf.sh> is) and refusing would take away the only
cross-build route there is. C<ariza> having no C<patchelf> on a Linux
host is fatal, and names the package to install.

=head2 Making the staged library self-contained (Windows)

Windows hides the problem worst of all, because it does not record it
anywhere. A vcpkg C<sqlcipher.dll> imports C<libcrypto-3-x64.dll> by bare
name — no path, no C<rpath>, no C<RUNPATH>, nothing a file-reading audit
had anything to say about. Staging the DLL on its own therefore produced
a bundle whose SQLCipher could not load B<at all>: not "loads the user's
OpenSSL", which is the Unix failure, but C<LoadLibrary> failing during
import resolution, which surfaces as

=begin code :lang<console>

DBDish::SQLCipher needs 'sqlcipher.dll', not found

=end code

— a message about the DLL that I<is> there, produced by the DLL that is
not. Two earlier fixes for that symptom (putting the bundle's
C<native/sqlcipher> on the smoke's C<PATH>, and naming C<zef.raku>
rather than C<zef.bat>) were both real bugs and neither could have made
it go away, because there was no OpenSSL in the bundle for any C<PATH>
to point at.

So Windows gets the same walk-and-copy the other two get, spelled the
way PE spells it:

=item1 B<Walk.> C<pe-imports> reads the import table out of the file:
DOS header to C<PE\0\0>, the optional header (PE32 or PE32+), data
directory 1, and each descriptor's name RVA mapped back through the
section table. No tool is involved, because there is no tool to involve
— C<dumpbin> ships with Visual Studio and C<objdump> with neither — and
a dependency walk that finds nothing when its helper is absent produces
exactly the bundle this pass exists to prevent.

=item1 B<Copy in.> Every import that is not on C<PE-SYSTEM-DLLS> is
copied in beside the library and recursed into. The skiplist is Windows'
own DLLs, the API sets, and the Visual C++ redistributable; it is not
guessed at, but measured — the core Win32 set plus exactly the names the
119 DLLs of the notcurses Windows pack import and do not carry, which
C<xt/03-pe-imports.rakutest> re-measures against the published pack.
B<C<libcrypto> is not on it>, for the same reason it is not on the ELF
one.

=item1 B<Nothing else.> There is no third step. Windows resolves an
import by name from the directory of the module doing the importing, so
putting the DLLs in one directory I<is> the relocation story — no
C<install_name_tool>, no C<patchelf>, nothing to re-sign.

The search space for the copy is one directory: the one the staged
library itself came from. That is a contract with the source rather than
a shortcut. Both Windows package managers install a port's whole runtime
closure into a single C<bin> — vcpkg's
C<installed/E<lt>tripletE<gt>/bin>, MSYS2's C<ucrt64/bin> — so
C<sqlcipher.dll>'s OpenSSL is the C<libcrypto-3-x64.dll> sitting next to
it, and an MSYS2 build's C<libgcc_s_seh-1.dll> and
C<libwinpthread-1.dll> are there too. Searching wider (C<PATH>,
C<System32>) would find a same-named DLL from a different build of a
different version, which is the bug a bundle exists to avoid rather than
a fallback worth having. An import that is not in that directory is
fatal, and the death names the import, the directory, and the two things
it could mean.

Unlike the ELF pass, this one needs no host of its own. Reading a PE's
imports needs no Windows, so a Windows bundle assembled from
C<--sqlcipher-archive> on a Mac gets the same walk, the same copies and
the same audit as one built on Windows. Windows is, as of this pass, the
platform ariza cross-builds most completely.

=head1 THE AUDIT

C<audit> walks every file ariza put into the bundle's native
directories, plus C<:@extra> (the macOS SQLCipher library, which lives
among Rakudo's own files and so cannot be found by walking a directory),
and fails the build if any of them would load a library from outside the
bundle.

This is not a formality. It is the difference between a bundle that
works on the machine that built it and one that works anywhere, and it
is a regression guard: the notcurses pack is already clean, so what the
audit really watches is the next library someone adds.

=head2 Mach-O

Every non-C<@loader_path>/C<@rpath>/C<@executable_path>/C</usr/lib>/
C</System> entry in C<otool -L> is a finding. The C<LC_ID_DYLIB> line is
checked too, not just the dependencies: an absolute install name is
copied into everything that links against the library later, which is
the same bug one step removed.

=head2 ELF

Two static checks, on any host. C<readelf -d>: a C<NEEDED> soname
containing a slash is an absolute path baked into the binary, and an
C<RPATH>/C<RUNPATH> entry that is not C<$ORIGIN>-relative points at the
build machine.

=head3 Two host-only checks

Those two are necessary and nowhere near sufficient, and this is the
exact shape of the bug they missed: a bare C<NEEDED libcrypto.so.3> with
no C<RPATH> at all passes both, and loads the build machine's OpenSSL.
Nothing I<in> the file says so. You have to ask the loader.

So when the audit runs B<on Linux> it adds C<bundle-elf.sh>'s two:

=item1 C<patchelf --print-rpath> — every entry must be
C<$ORIGIN>-relative, and a file with a non-system C<NEEDED> must have at
least one, or nothing tells the loader to look beside it. (A file whose
only dependency is C<libc> is allowed no rpath: there is nothing beside
it to find. And C<$ORIGIN:$ORIGIN/../lib> passes — it is relocatable,
which is the property being checked, not a spelling.)

=item1 C<ldd> with the environment B<replaced> by a bare C<PATH>
(C<env -i>, in one call): every non-system dependency must resolve to a
path inside the bundle, and C<not found> is a finding. The clean
environment is the point — a plain C<ldd> in a build that exported
C<LD_LIBRARY_PATH> paints a picture no user will ever see.

Both tools answer for the machine they are on, so from a Mac
cross-inspecting an ELF the audit does the static half and says so
rather than pretending to more. Which is another way of saying: the
Linux bundle gets built on Linux, and C<xxt/linux-selfcontain-proof.sh>
runs the whole thing — staging, copy-in, rpath, audit, and three
negative controls — in a C<manylinux> container to prove it.

The two extra sections travel as text, under the C<ELF-RPATH-SECTION>
and C<ELF-LDD-SECTION> markers, appended to the C<readelf> output. That
keeps C<:&inspect> a seam that returns B<a report>, and keeps
C<elf-strays> a pure function of text — so the Linux verdicts, including
these two, are reachable from a test on a Mac.

=head2 PE

Every non-system DLL a staged C<.dll> imports must be a file inside the
bundle, and the audit resolves each one to find out.

This used to be a presence check — "the payload is there and is not
empty" — on the reasoning that a PE records no C<rpath> to inspect, so
there was nothing to audit. That reasoning was wrong, and expensively:
what a PE records is its B<import table>, which is the entire question.
A bundle holding C<sqlcipher.dll> and nothing else passed the presence
check with two files and no findings, and failed at C<LoadLibrary> on
the first Windows machine that ran it. An audit that cannot see the hole
its own staging leaves is worse than no audit, because it is quoted in
the release notes.

So the audit reads the same import table C<pe-imports> reads for
staging, drops the C<PE-SYSTEM-DLLS> names, and resolves what is left
against the directory the file sits in — which is how Windows itself
resolves it for a bundled DLL, and everything ariza stages for Windows
lands in one directory. C<not found> is a finding; so is a dependency
that resolves outside C<:@inside> (the bundle), by the same
separator-normalised containment check the ELF audit uses. A file named
like a DLL that is not a PE, or is empty, is a finding in those words,
and a PE the parser cannot read stops the audit rather than passing
through it as "checked".

It needs no Windows to do any of this: the file is read, not run. The
Windows verdict is as strong from a Mac as it is on the machine the
bundle is for — which is the opposite of the ELF story, and worth saying
because the platforms are usually assumed to rank the other way round.

=head3 The redistributable gate

One family of names is on the skiplist and audited anyway:
C<vcruntime*.dll>, C<msvcp*.dll>, C<concrt*.dll> and C<vcomp*.dll> —
C<PE-REDIST-DLLS>, the Visual C++ Redistributable.

They look like Windows and they are not. C<kernel32.dll> and
C<ucrtbase.dll> are in C<System32> on every Windows 10 machine ever
installed; C<vcruntime140.dll> arrives with Visual Studio, or with the
redistributable installer, or dragged in by some other application that
shipped it. A DLL importing one loads on the machine that built it, on
every CI runner, and on most developer laptops — and fails on a clean
install with the same wordless C<LoadLibrary> refusal a missing OpenSSL
gives. It is the exact shape of gap this audit exists to close, made
worse by the fact that every machine likely to run the audit is a
machine where the gap is invisible.

So an import from that family which does not resolve inside the bundle
is a finding, and the finding carries the whole argument — consequence,
and both ways out — rather than a bare path, because the reader has just
watched the bundle work:

=begin code :lang<console>

vcruntime140.dll => not found (Visual C++ Redistributable: not part of
Windows and not in the bundle, so this file loads only on a machine that
has installed it — which every CI runner has and a clean install does
not. Use a UCRT-built library instead: ...)

=end code

The fix ariza recommends is the source, not the copy: an MSYS2
C<mingw-w64-ucrt-x86_64-*> library imports C<ucrtbase.dll> and the
question does not arise. Putting the runtime in the bundle by hand also
satisfies the audit — the check is "not in the bundle", not "never
imported" — but ariza will not copy it in on an author's behalf. It is
Microsoft's to redistribute, on Microsoft's terms, and app-local
deployment of it is a decision that belongs to whoever signs the
release.

The UCRT itself is deliberately not in this family. C<ucrtbase.dll> is
part of the OS, which is the entire reason a UCRT build is the answer
rather than another instance of the question.

=head2 The verdict functions are pure, and the tool call is a seam

C<macho-strays>, C<elf-strays> and C<pe-strays> take B<report text> and
return the offending entries — no file, no tool, no platform.

C<audit> itself takes C<:&inspect>, which maps a file to its report text
(or the undefined C<Str> for a file of the wrong format). Between them,
every branch of the audit — counting, skipping, the finding list, the
wording of the failure — is reachable from a test on any machine,
including the Linux and Windows verdicts from a Mac.

=head1 METHODS

=head2 stage-sqlcipher(:$bundle-dir!, :$slug!, :$versions!, :$archive, :$host-slug, :$host-kernel, :%env, :&run, :@search --> Hash)

Source it, place it, make it self-contained, alias it. Returns
C<version> (what was staged, possibly the undefined C<Str>), C<pinned>,
C<library>, C<rel>, C<alias>, C<staged> (the library B<and> everything
copied in beside it), C<origin>, C<source>, C<kind> and C<sha256>.

C<:$host-kernel> defaults to C<$*KERNEL.name.lc> and decides whether the
ELF self-containment pass can run at all — C<ldd> and C<patchelf> answer
for the machine they are on. With C<:&run>, it makes the Linux staging
path reachable from a test on a Mac.

=head2 sqlcipher-source(:$slug!, :$archive, :$host-slug, :%env, :&run, :@search --> Hash)

The decision on its own, copying nothing:
C<{ kind, path, origin, version }>. C<kind> is C<'library'> or
C<'archive'>.

C<:$host-slug> is the machine's own slug (the cross-build guard),
C<:%env> the environment C<SQLCIPHER_LIB_DIR>, C<MSYSTEM_PREFIX> and
C<VCPKG_ROOT> are read from, C<:&run> the process runner every C<brew>
and C<ldconfig> call goes through, and C<:@search> replaces the
directories probed (on Linux and on Windows both). Together
they make every platform's resolution — and every death message —
reachable from a test on any machine.

=head2 audit(:$bundle-dir!, :$slug!, :@extra, :&inspect, :$host-kernel, :&run --> Hash)

C<{ checked, skipped, findings, family }>, or a die naming every
offending file and dependency. C<:&inspect> replaces the tool call
outright; C<:$host-kernel> and C<:&run> replace only the machine it is
standing on, which is what the two host-only ELF checks are decided by.

=head2 sqlcipher-version-of(IO() --> Str)

The version a library reports about itself, read out of its bytes;
the undefined C<Str> when they do not say so unambiguously. Exported.

=head2 sqlcipher-dir / sqlcipher-rel / sqlcipher-layout / sqlcipher-slugs

The naming and placement rules, exposed individually so the manifest and
the launcher template agree with what was actually staged.

=head2 macho-strays(Str --> List) / elf-strays(Str, :@inside --> List) / pe-strays(Str, :@inside --> List)

The pure verdict functions, exported. C<:@inside> is the list of
directory prefixes a dependency is allowed to resolve under — the
bundle, spelled both as given and as resolved. With none, the
containment half has nothing to judge against and only C<not found> is
reported. ELF and PE share the comparison, which normalises separators
on both sides: a resolved target is spelled in the host's separators
(backslashes, on Windows) and C<:@inside>'s prefixes may not be.

=head2 binary-format(IO() --> Str)

C<'Mach-O'>, C<'ELF'>, C<'PE'> or the undefined C<Str>, by magic number.
Exported.

=head2 pe-imports(IO() --> List)

The DLLs a PE file imports, by name, in import-table order. Reads the
bytes — DOS header, PE signature, COFF header, optional header (PE32 and
PE32+ both), data directory 1, the import descriptors, and the section
table that maps their RVAs back to file offsets — so it answers on any
host, for any C<.dll> or C<.exe>, with no toolchain installed. Exported.

Anything that does not parse is a die naming the file and what was wrong
with it: an empty answer for an unreadable file would pass both callers
(staging and the audit) silently, which is the failure mode the whole
pass exists to remove. Delay-load imports (data directory 13) are not
read; the Pod above says why.

=head2 elf-system-lib(Str --> Bool) / pe-system-dll(Str --> Bool) / pe-redist-dll(Str --> Bool)

The skiplist membership tests: whether a soname or an imported DLL name
is one the platform provides and a bundle must therefore not carry.
C<pe-system-dll> folds case, because the Windows loader does. All three
take a name or a path and consider only the leaf. Exported.

C<pe-redist-dll> is the narrower second question, asked of names that
are already on the skiplist: whether this is the Visual C++
Redistributable, which is neither shipped by Windows nor copied in by
ariza, and which the audit therefore reports when it does not resolve
inside the bundle. "The redistributable gate" above says why.

=head2 elf-needed(Str --> List) / ldd-deps(Str --> List)

The C<DT_NEEDED> sonames in C<readelf -d> output, and the
C<soname =E<gt> path> pairs in C<ldd> output (the undefined C<Str> for
C<not found>). Both pure, both exported.

=head1 SEE ALSO

L<App::Ariza::Site> (which stages notcurses), L<App::Ariza::Launcher>
(which names the Linux and Windows library paths at run time),
C<xxt/linux-selfcontain-proof.sh> (which proves the Linux half of this
module in a container, negative controls included), and
C<xt/03-pe-imports.rakutest> (which runs the PE parser and the skiplist
over the 119 DLLs of the published notcurses Windows pack).

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
