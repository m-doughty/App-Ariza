#!/bin/sh
# Rebuilds the ELF fixtures that t/23-elf.rakutest and t/11-native.rakutest
# read, and records what binutils' readelf and patchelf say about each
# one, so the suite can hold App::Ariza::ELF to both tools on every host
# -- including the ones that have neither.
#
# Needs clang, lld, gcc, binutils and patchelf. On Debian:
#
#     apt-get install clang lld gcc binutils patchelf
#
# and then, from this directory:
#
#     sh build.sh
#
# Every fixture but one is linked with -nostdlib against stub libraries
# built here, so nothing in it comes from the machine that built it: the
# C library a fixture names in DT_NEEDED is stub.c under the soname
# libc.so.6. The exception is the gcc fixture, which links the real C
# library with GNU ld, for GNU ld's own layout, and is built for whatever
# architecture this machine's gcc targets. -nostartfiles keeps the
# toolchain's start files (crt*.o) out of it, so the only code in any
# fixture is fixture.c's and stub.c's.
#
# Outputs, per fixture NAME:
#
#     NAME.elf       the file itself
#     NAME.readelf   `readelf -d NAME.elf`, verbatim
#     NAME.rpath     `patchelf --print-rpath NAME.elf`, verbatim, or the
#                    line "no dynamic section" where patchelf refuses
#
# The stubs, and every intermediate, are deleted on the way out.
set -eu

CFLAGS='-O2 -fPIC -fno-asynchronous-unwind-tables -fno-ident'
LDFLAGS='-fuse-ld=lld -nostdlib -Wl,--build-id=none -Wl,--hash-style=gnu -s'

work=$(mktemp -d)
trap 'rm -f "$work"/*; rmdir "$work"' EXIT

# stub TARGET SONAME -- a shared object answering to SONAME, for TARGET.
stub() {
    out="$work/$1-$(echo "$2" | tr -c 'a-z0-9\n' '_').so"
    clang --target="$1" $CFLAGS $LDFLAGS -shared -Wl,-soname,"$2" \
        -o "$out" stub.c
    echo "$out"
}

# shared NAME TARGET LINK-FLAGS... -- a shared object named NAME.elf.
shared() {
    name=$1; target=$2; shift 2
    clang --target="$target" $CFLAGS $LDFLAGS -shared -o "$name.elf" \
        fixture.c "$@"
}

record() {
    readelf -d "$1.elf" > "$1.readelf"
    patchelf --print-rpath "$1.elf" > "$1.rpath" 2>/dev/null \
        || echo 'no dynamic section' > "$1.rpath"
}

# ELF64, little-endian. RUNPATH with two entries, both relocatable.
crypto=$(stub x86_64-linux-gnu libcrypto.so.3)
libc=$(stub x86_64-linux-gnu libc.so.6)
shared x86_64-runpath x86_64-linux-gnu "$crypto" "$libc" \
    -Wl,--enable-new-dtags -Wl,-rpath,'$ORIGIN:$ORIGIN/../lib'

# The old tag, pointing at the build machine first.
shared x86_64-rpath x86_64-linux-gnu "$crypto" \
    -Wl,--disable-new-dtags -Wl,-rpath,'/opt/build/lib:$ORIGIN'

# Neither: a file that needs only the C library.
shared x86_64-bare x86_64-linux-gnu "$libc"

# Neither, and an OpenSSL: the shape of a distribution's libsqlcipher
# before ariza stages it, which loads whatever libcrypto.so.3 the
# machine it runs on happens to have.
shared x86_64-unpatched x86_64-linux-gnu "$crypto" "$libc"

# That file after the staging pass's `patchelf --set-rpath '$ORIGIN'`,
# which is the layout every library ariza stages on Linux ends up with:
# the string table moved, a segment added to hold it, DT_RUNPATH added.
cp x86_64-unpatched.elf x86_64-patchelf.elf
patchelf --set-rpath '$ORIGIN' x86_64-patchelf.elf

# No dynamic section at all: a static executable, and an object file,
# which has no program headers either.
clang --target=x86_64-linux-gnu $CFLAGS -fuse-ld=lld -nostdlib -static \
    -Wl,--build-id=none -Wl,-e,ariza_fixture -s -o x86_64-static.elf fixture.c
clang --target=x86_64-linux-gnu $CFLAGS -c -o x86_64-object.elf fixture.c

# ELF32, little-endian.
crypto=$(stub i686-linux-gnu libcrypto.so.3)
libc=$(stub i686-linux-gnu libc.so.6)
shared i686-runpath i686-linux-gnu "$crypto" "$libc" \
    -Wl,--enable-new-dtags -Wl,-rpath,'$ORIGIN'

# ELF64, big-endian.
crypto=$(stub s390x-linux-gnu libcrypto.so.3)
shared s390x-runpath s390x-linux-gnu "$crypto" \
    -Wl,--enable-new-dtags -Wl,-rpath,'$ORIGIN'

# ELF32, big-endian, and the old tag again.
crypto=$(stub powerpc-linux-gnu libcrypto.so.3)
shared powerpc-rpath powerpc-linux-gnu "$crypto" \
    -Wl,--disable-new-dtags -Wl,-rpath,'/opt/build/lib'

# GNU ld and the real C library: the layout a distribution's build of a
# library has, at the smallest page size the format allows.
# --no-as-needed because fixture.c calls nothing: Debian's gcc links
# --as-needed by default, and would drop both DT_NEEDED entries.
crypto="$work/gcc-libcrypto.so"
gcc $CFLAGS -shared -nostdlib -Wl,-soname,libcrypto.so.3 -o "$crypto" stub.c
gcc $CFLAGS -shared -nostartfiles -s -Wl,--build-id=none -Wl,-z,noseparate-code \
    -Wl,-z,max-page-size=4096 -Wl,--enable-new-dtags -Wl,-rpath,'$ORIGIN' \
    -Wl,--no-as-needed -o gcc-runpath.elf fixture.c "$crypto"

for f in x86_64-runpath x86_64-rpath x86_64-bare x86_64-unpatched \
         x86_64-patchelf x86_64-static x86_64-object i686-runpath s390x-runpath \
         powerpc-rpath gcc-runpath; do
    record "$f"
done

ls -l ./*.elf
