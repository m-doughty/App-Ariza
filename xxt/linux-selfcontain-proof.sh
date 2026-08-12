#!/usr/bin/env bash
#
# Prove, in a container, that a Linux bundle's SQLCipher is actually
# self-contained — that App::Ariza::Native copies OpenSSL in beside the
# library, points every staged ELF at its own directory, and refuses to
# pass a bundle where anything still resolves off the machine.
#
# This exists because the Linux hole was invisible from a Mac and
# invisible to any check that only reads the file. A distribution's
# libsqlcipher.so.0 names OpenSSL as a bare `NEEDED libcrypto.so.3`:
# legal ELF, no path, no RPATH, nothing to object to — and at run time it
# is "whatever this machine has", which on a user's machine may be
# nothing at all. Only a real Linux loader, asked in a clean environment,
# can tell the difference, so the proof runs one.
#
# What it does:
#
#   1. Starts a manylinux container (glibc 2.28 — the oldest ariza
#      targets) and puts a real SQLCipher in it, from the distribution
#      package where that package uses the standard soname, and from the
#      source tarball where it does not. It says which path it took.
#   2. Puts an official Rakudo in it and installs App::Ariza's
#      dependencies.
#   3. Runs App::Ariza's own test suite there, so every test that fakes a
#      Linux host on a Mac also runs on a Linux one.
#   4. Drives App::Ariza::Native for real: stages the distribution's
#      library into a scratch bundle, then audits it.
#   5. Re-checks the result in plain shell — patchelf and a clean-env
#      ldd — so the audit is not the only witness to its own verdict.
#   6. Runs three negative controls: an absolute NEEDED planted with
#      patchelf, a deleted dependency, and a stripped rpath. Each one
#      must make the audit fail. A proof that only ever passes proves
#      nothing.
#
# Nothing in t/ needs docker; this is xxt/ (external tooling) and is
# never run by `prove6 t/`.
#
# Usage:
#
#   xxt/linux-selfcontain-proof.sh [--keep] [--no-cache]
#
# Environment:
#
#   ARIZA_PROOF_IMAGE      container image     (default: manylinux_2_28_x86_64)
#   ARIZA_PROOF_PLATFORM   docker --platform   (default: linux/amd64)
#   ARIZA_PROOF_CACHE      host cache dir for the Rakudo tarball, the
#                          SQLCipher build and the installed Raku modules
#                          (default: $TMPDIR/ariza-linux-proof-cache)
#   ARIZA_PROOF_SQLCIPHER  auto | epel | source   (default: auto)
#   ARIZA_PROOF_SQLCIPHER_VERSION   source-build tag   (default: 4.6.1)
#
# On an Apple-silicon host the x86_64 image runs under Rosetta, which is
# fast enough that the whole run is dominated by downloads. There is no
# official Rakudo binary for Linux aarch64 — see App::Ariza::Rakudo's
# %INDEX-PLATFORMS, which is deliberately partial — so the emulated
# x86_64 image is the one that can run a real Raku without building a
# compiler first.

set -euo pipefail

here=$(cd -P -- "$(dirname -- "$0")" && pwd)
repo=$(cd -P -- "$here/.." && pwd)

image=${ARIZA_PROOF_IMAGE:-quay.io/pypa/manylinux_2_28_x86_64}
platform=${ARIZA_PROOF_PLATFORM:-linux/amd64}
cache=${ARIZA_PROOF_CACHE:-${TMPDIR:-/tmp}/ariza-linux-proof-cache}
sqlcipher_from=${ARIZA_PROOF_SQLCIPHER:-auto}
sqlcipher_version=${ARIZA_PROOF_SQLCIPHER_VERSION:-4.6.1}
keep=0

while [ $# -gt 0 ]; do
    case $1 in
        --keep)     keep=1 ;;
        --no-cache) cache='' ;;
        -h|--help)  sed -n '2,60p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

command -v docker >/dev/null 2>&1 || {
    printf 'PROOF FAILED: no docker on this machine\n' >&2
    exit 1
}
docker info >/dev/null 2>&1 || {
    printf 'PROOF FAILED: docker is installed but not running\n' >&2
    exit 1
}

[ -f "$repo/lib/App/Ariza/Native.rakumod" ] || {
    printf 'PROOF FAILED: %s is not an App-Ariza checkout\n' "$repo" >&2
    exit 1
}

stage=$(mktemp -d "${TMPDIR:-/tmp}/ariza-proof-stage.XXXXXX")
cleanup() { [ "$keep" -eq 1 ] || rm -rf "$stage"; }
trap cleanup EXIT

# --------------------------------------------------------------------
# The Raku driver. This is the part that matters: it calls the module,
# not a shell reimplementation of it.
# --------------------------------------------------------------------
cat >"$stage/drive.raku" <<'DRIVER'
#!/usr/bin/env raku
use App::Ariza::Native;
use App::Ariza::Platform;
use App::Ariza::Tools;
use App::Ariza::Versions;

my $root = (@*ARGS[0] // '/work/proof').IO;
my $slug = current-slug();
my $vers = App::Ariza::Versions.load;
my $bad  = 0;

sub ok(Bool() $cond, Str $what) {
    say ($cond ?? '  ok   ' !! '  FAIL ') ~ $what;
    $bad++ unless $cond;
}

#| Stage the machine's real SQLCipher into a fresh bundle directory.
#| No seams: this is `ariza bundle` doing what it does on a Linux CI box.
sub stage(Str:D $name --> Hash) {
    my $dir = $root.add($name);
    rm-rf($dir);
    ensure-dir($dir);
    App::Ariza::Native.stage-sqlcipher(:bundle-dir($dir), :$slug,
                                       :versions($vers))
}

#| The audit must refuse this bundle. Returns the message it refused with.
sub must-fail(IO::Path $dir, Str:D $what --> Str) {
    my $message = '';
    my $passed = True;
    {
        CATCH { default { $passed = False; $message = .message } }
        App::Ariza::Native.audit(:bundle-dir($dir), :$slug);
    }
    ok(!$passed, "negative control: $what fails the audit");
    say "       $_" for $message.lines.head(4);
    $message
}

say "platform slug:  $slug";
say "kernel:         {$*KERNEL.name} {$*KERNEL.hardware}";
say '';

say '--- staging ---';
my %sql = stage('bundle');
say "origin:         {%sql<origin>}";
say "version:        {%sql<version> // 'unknown'} (pin {%sql<pinned> // 'none'})";
say "staged:         {%sql<staged>.map(*.basename).sort.join(', ')}";
say "sha256:         {%sql<sha256>}";
say '';

my $dest = %sql<library>.parent;
my @deps = %sql<staged>.grep({ .basename ne %sql<library>.basename });

# The whole point: the library named OpenSSL, and OpenSSL came with it.
ok(%sql<library>.f, 'the library is staged');
ok(?@deps, 'it brought its dependencies with it');
ok(?@deps.first({ .basename.starts-with('libcrypto.so') }),
   'including libcrypto — the one a bare NEEDED would have borrowed');
# .grep, not .all: a Junction here would autothread `ok` itself and
# report the check once per dependency.
ok(@deps.grep({ !.f }) == 0, 'every dependency is really there');
ok(!$dest.dir.first({ .basename.starts-with('libc.so') }),
   'while libc is left dynamic, as it must be');

say '';
say '--- audit (the real one, on a real loader) ---';
my %audit = App::Ariza::Native.audit(:bundle-dir($root.add('bundle')), :$slug);
ok(%audit<checked> >= 1 + @deps, "audited {%audit<checked>} ELF files");
ok(%audit<findings> == 0, 'and found nothing loading from outside the bundle');

say '';
say '--- negative controls ---';

# 1. An absolute NEEDED. This is what a build machine's path baked into
#    the binary looks like, and the static half of the audit sees it.
my %one = stage('control-needed');
my $dep = %one<staged>.first({ .basename.starts-with('libcrypto.so') });
run-checked(['patchelf', '--replace-needed', $dep.basename,
             "/nonexistent/{$dep.basename}", %one<library>.absolute],
            :what('patchelf --replace-needed'));
my $m1 = must-fail($root.add('control-needed'), 'an absolute NEEDED');
ok($m1.contains('/nonexistent/'), 'and names the path that was planted');

# 2. A missing dependency. Nothing in the file changed at all — only the
#    loader can see this one, which is the entire reason it is checked.
#    On a machine that happens to have OpenSSL installed this does not
#    even fail: the loader quietly takes the system copy, and the bundle
#    "works" until it meets a machine that has not got one. That is the
#    original bug, reproduced on purpose.
my %two = stage('control-missing');
my $gone = %two<staged>.first({ .basename.starts-with('libcrypto.so') }).basename;
$root.add('control-missing/native/sqlcipher').add($gone).unlink;
my $m2 = must-fail($root.add('control-missing'), 'a deleted dependency');
ok($m2.contains($gone) && ($m2.contains('not found') || $m2.contains('=>')),
   'and names it, whether the loader missed it or quietly took the'
 ~ ' system copy instead');

# 3. No rpath. The dependency is right there beside the library, and the
#    loader will still go to /lib64 for it.
my %three = stage('control-rpath');
run-checked(['patchelf', '--remove-rpath', %three<library>.absolute],
            :what('patchelf --remove-rpath'));
my $m3 = must-fail($root.add('control-rpath'), 'a stripped rpath');
ok($m3.contains('rpath') || $m3.contains('=>'),
   'and says why the loader would miss it');

say '';
say $bad == 0 ?? 'driver: all checks passed' !! "driver: $bad check(s) FAILED";
exit($bad == 0 ?? 0 !! 1);
DRIVER

# --------------------------------------------------------------------
# The container side.
# --------------------------------------------------------------------
cat >"$stage/in-container.sh" <<'CONTAINER'
set -euo pipefail

SQLCIPHER_FROM=${SQLCIPHER_FROM:-auto}
SQLCIPHER_VERSION=${SQLCIPHER_VERSION:-4.6.1}
CACHE=/cache
[ -d "$CACHE" ] || CACHE=$(mktemp -d)

step() { printf '\n\033[1m=== %s\033[0m\n' "$*"; }
fail() { printf '\nPROOF FAILED: %s\n' "$*" >&2; exit 1; }
elapsed() { printf '    (%ss)\n' "$(( $(date +%s) - $1 ))"; }

step "container"
sed -n '1,2p' /etc/os-release
printf 'arch:   %s\n' "$(uname -m)"
printf 'glibc:  %s\n' "$(ldd --version | head -1)"
for t in ldd patchelf readelf; do
    command -v "$t" >/dev/null 2>&1 || fail "the image has no $t"
    printf '%-8s%s\n' "$t:" "$(command -v $t)"
done

# ---------------------------------------------------------------- sqlcipher
step "sqlcipher"
t0=$(date +%s)
SQLCIPHER_PATH_TAKEN=none

have_soname() { ldconfig -p | grep -q 'libsqlcipher\.so\.0 '; }

if [ "$SQLCIPHER_FROM" = auto ] || [ "$SQLCIPHER_FROM" = epel ]; then
    echo "trying the distribution package (EPEL)…"
    if dnf install -y epel-release >/dev/null 2>&1 \
       && dnf install -y sqlcipher >/dev/null 2>&1; then
        ldconfig
        if have_soname; then
            SQLCIPHER_PATH_TAKEN=epel
            echo "EPEL provides libsqlcipher.so.0 — using the distribution package"
        else
            # EPEL's EL8 build renames the library to libsqlcipher-3.34.1.so.0
            # so it cannot collide with sqlite. ariza looks for the soname
            # Debian and a source build produce, so this package is not one
            # it can find. Reported, not worked around: a symlink here would
            # hide a real portability question behind the proof.
            echo "EPEL installs $(ldconfig -p | grep -i sqlcipher | head -1 | sed 's/^[[:space:]]*//')"
            echo "which is NOT the soname ariza looks for (libsqlcipher.so.0)"
        fi
    else
        echo "EPEL has no sqlcipher for this arch"
    fi
fi

if [ "$SQLCIPHER_PATH_TAKEN" = none ] && [ "$SQLCIPHER_FROM" != epel ]; then
    echo "building SQLCipher $SQLCIPHER_VERSION from source against system OpenSSL…"
    dnf install -y tcl openssl-devel >/dev/null 2>&1 || fail "no toolchain for a source build"
    src=$CACHE/sqlcipher-$SQLCIPHER_VERSION
    if [ ! -f "$src/.built" ]; then
        mkdir -p "$CACHE"
        tarball=$CACHE/sqlcipher-$SQLCIPHER_VERSION.tar.gz
        [ -f "$tarball" ] || curl -fsSL \
            "https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v$SQLCIPHER_VERSION.tar.gz" \
            -o "$tarball" || fail "could not download SQLCipher $SQLCIPHER_VERSION"
        rm -rf "$src"
        tar xzf "$tarball" -C "$CACHE"
        ( cd "$src" \
          && ./configure --prefix=/usr/local --enable-tempstore=yes \
                 CFLAGS="-DSQLITE_HAS_CODEC" LDFLAGS="-lcrypto" >/tmp/configure.log 2>&1 \
          && make -j"$(nproc)" >/tmp/make.log 2>&1 ) \
            || { tail -30 /tmp/configure.log /tmp/make.log; fail "SQLCipher did not build"; }
        touch "$src/.built"
    else
        echo "(reusing the cached build)"
    fi
    ( cd "$src" && make install >/tmp/install.log 2>&1 ) || fail "make install failed"
    ldconfig
    have_soname || fail "the source build produced no libsqlcipher.so.0"
    SQLCIPHER_PATH_TAKEN=source
fi

if [ "$SQLCIPHER_PATH_TAKEN" = none ]; then
    fail "no SQLCipher on this machine, by either route"
fi
echo "SQLCIPHER PATH TAKEN: $SQLCIPHER_PATH_TAKEN"
ldconfig -p | grep -i sqlcipher | sed 's/^[[:space:]]*/    /'
lib=$(ldconfig -p | grep 'libsqlcipher\.so\.0 ' | head -1 | sed 's/.*=> //')
echo "the library ariza will find, as the machine ships it:"
readelf -d "$lib" | grep -E 'NEEDED|RPATH|RUNPATH|SONAME' | sed 's/^/    /'
echo "    rpath: '$(patchelf --print-rpath "$lib")'"
elapsed "$t0"

# ------------------------------------------------------------------- rakudo
step "rakudo"
t0=$(date +%s)
export PATH=/opt/rakudo/bin:/opt/rakudo/share/perl6/site/bin:$PATH
if [ ! -x /opt/rakudo/bin/raku ]; then
    tarball=$CACHE/rakudo-linux.tar.gz
    if [ ! -f "$tarball" ]; then
        # rakudo.org rejects the default python/urllib user agent, so curl.
        curl -fsSL -A 'ariza-linux-selfcontain-proof' https://rakudo.org/dl/rakudo \
            -o /tmp/rakudo-index.json || fail "could not reach the Rakudo release index"
        url=$(python3 -c '
import json
d = json.load(open("/tmp/rakudo-index.json"))
c = [x for x in d if x.get("platform") == "linux" and x.get("arch") == "x86_64"
     and x.get("type") == "archive" and x.get("backend") == "moar"]
c.sort(key=lambda x: (x.get("ver", ""), x.get("build_rev", "")))
print(c[-1]["url"])
') || fail "the Rakudo release index has no linux/x86_64 archive"
        echo "downloading $url"
        curl -fsSL "$url" -o "$tarball" || fail "could not download Rakudo"
    else
        echo "(reusing the cached runtime)"
    fi
    mkdir -p /opt/rakudo
    tar xzf "$tarball" -C /opt/rakudo --strip-components=1
fi
raku -e 'say "raku ", $*RAKU.version, " on ", $*KERNEL.name, "-", $*KERNEL.hardware'
elapsed "$t0"

step "App::Ariza dependencies"
t0=$(date +%s)
export RAKULIB="inst#$CACHE/rakulib"
mkdir -p "$CACHE/rakulib"
missing=''
for m in Config::TOML JSON::Fast Template::Jinja2; do
    raku -e "use $m;" >/dev/null 2>&1 || missing="$missing $m"
done
if [ -n "$missing" ]; then
    echo "installing:$missing"
    # shellcheck disable=SC2086
    zef install --/test --to="inst#$CACHE/rakulib" $missing >/tmp/zef.log 2>&1 \
        || { tail -20 /tmp/zef.log; fail "could not install App::Ariza's dependencies"; }
else
    echo "(reusing the cached module install)"
fi
elapsed "$t0"

# --------------------------------------------------------------- test suite
step "App::Ariza's own test suite, on Linux"
t0=$(date +%s)
rm -rf /work && mkdir -p /work
tar -C /src -cf - --exclude=.precomp --exclude=.git . | tar -C /work -xf -
cd /work
failed=''
for t in t/*.rakutest; do
    if raku -Ilib "$t" >"/tmp/$(basename "$t").out" 2>&1; then
        printf '  ok   %s\n' "$t"
    else
        printf '  FAIL %s\n' "$t"
        sed 's/^/       /' "/tmp/$(basename "$t").out" | tail -25
        failed="$failed $t"
    fi
done
[ -z "$failed" ] || fail "test files failed on Linux:$failed"
elapsed "$t0"

# ------------------------------------------------------------------- driver
step "staging and auditing a real bundle, through App::Ariza::Native"
t0=$(date +%s)
raku -I/work/lib /proof/drive.raku /work/proof || fail "the driver reported failures"
elapsed "$t0"

# ------------------------------------------------- independent shell re-check
step "re-checking the staged bundle in plain shell"
dir=/work/proof/bundle/native/sqlcipher
[ -d "$dir" ] || fail "nothing was staged at $dir"
ls -la "$dir" | sed 's/^/    /'

echo "--- libcrypto beside the library ---"
ls "$dir" | grep -q '^libcrypto\.so' \
    || fail "no libcrypto beside libsqlcipher.so.0 — the bundle would use the user's"
echo "    ok"

echo "--- RPATH == \$ORIGIN on every staged ELF ---"
bad=0
for f in "$dir"/*; do
    if [ -L "$f" ] || [ ! -f "$f" ]; then continue; fi
    head -c 4 "$f" | grep -q ELF || continue
    rpath=$(patchelf --print-rpath "$f")
    if [ "$rpath" = '$ORIGIN' ]; then
        printf '    ok   %-24s RPATH=$ORIGIN\n' "$(basename "$f")"
    else
        printf '    FAIL %-24s RPATH=%s\n' "$(basename "$f")" "'$rpath'"
        bad=1
    fi
done
[ "$bad" -eq 0 ] || fail "a staged ELF would fall back to /lib64 on a user's machine"

echo "--- clean-env ldd: every non-system dep inside the bundle ---"
bad=0
while IFS= read -r line; do
    case "$line" in *"=>"*) ;; *) continue ;; esac
    name=${line#"${line%%[![:space:]]*}"}
    name=${name%% =>*}
    rest=${line#*=> }
    path=${rest% \(*}
    case "$name" in
        libc.so.*|libc.musl-*|libm.so.*|libmvec.so.*|libpthread.so.*|libdl.so.*|\
        librt.so.*|libstdc++.so.*|libgcc_s.so.*|libresolv.so.*|libnsl.so.*|\
        libutil.so.*|libcrypt.so.*|libatomic.so.*|libthread_db.so.*|\
        ld-linux*|ld-musl-*|ld64.so.*|linux-vdso.so.*|linux-gate.so.*)
            printf '    --   %-24s %s (system, stays dynamic)\n' "$name" "$path"
            continue ;;
    esac
    case "$path" in
        "$dir"/*) printf '    ok   %-24s %s\n' "$name" "$path" ;;
        "not found") printf '    FAIL %-24s NOT FOUND\n' "$name"; bad=1 ;;
        *) printf '    FAIL %-24s %s (outside the bundle)\n' "$name" "$path"; bad=1 ;;
    esac
done <<EOF
$(env -i PATH=/usr/bin:/bin ldd "$dir/libsqlcipher.so.0" 2>&1 || true)
EOF
[ "$bad" -eq 0 ] || fail "a non-system dependency resolves outside the bundle"

printf '\nSQLCIPHER PATH TAKEN: %s\n' "$SQLCIPHER_PATH_TAKEN"
CONTAINER

# --------------------------------------------------------------------
# Run it.
# --------------------------------------------------------------------
printf 'image:     %s (%s)\n' "$image" "$platform"
printf 'checkout:  %s\n' "$repo"
if [ -n "$cache" ]; then
    mkdir -p "$cache"
    printf 'cache:     %s\n' "$cache"
    cache_mount=(-v "$cache:/cache")
else
    printf 'cache:     disabled\n'
    cache_mount=()
fi

started=$(date +%s)
status=0
docker run --rm --platform "$platform" \
    -v "$repo:/src:ro" -v "$stage:/proof:ro" \
    ${cache_mount[@]+"${cache_mount[@]}"} \
    -e "SQLCIPHER_FROM=$sqlcipher_from" \
    -e "SQLCIPHER_VERSION=$sqlcipher_version" \
    "$image" bash /proof/in-container.sh || status=$?
took=$(( $(date +%s) - started ))

printf '\n================================================================\n'
if [ "$status" -eq 0 ]; then
    printf 'PROOF PASSED in %ss — a Linux bundle carries its own OpenSSL,\n' "$took"
    printf 'every staged ELF points at its own directory, nothing resolves\n'
    printf 'outside the bundle, and the audit rejects each case where one\n'
    printf 'would.\n'
else
    printf 'PROOF FAILED in %ss (exit %s). The transcript above says where.\n' \
        "$took" "$status"
fi
printf '================================================================\n'
if [ "$keep" -eq 1 ]; then
    printf 'stage kept at %s\n' "$stage"
fi
exit "$status"
