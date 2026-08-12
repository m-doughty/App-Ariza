# Third-party components in this bundle

Moneymoor 0.2.0 for `macos-arm64`.

A bundle is self-contained: it carries a Raku runtime, every Raku module
the application needs, and every native library it loads, so that
unpacking it is the whole installation. That also makes it a binary
redistribution of other people's software. Everything in it is listed
below with the licence it is conveyed under, who holds the copyright,
and where that fact came from. Full licence texts are in `LICENSES/`
beside this file.

`Provenance` is the last of those and the one worth reading. It says
which source each row's facts came from — a native pack's own licensing
kit, ariza's maintained record of the vendored runtime, an installed
distribution's own `META6.json`, or the application's `ariza.toml`. No
row here was written by hand into a tool.

## Summary

18 components.

| Component | Version | Licence (SPDX) | Provenance |
|---|---|---|---|
| App::Moneymoor | 0.2.0 | `Artistic-2.0` | app META6 |
| cmp (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `MIT` | ariza runtime data (runtime-third-party.json) |
| DynASM (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `MIT` | ariza runtime data (runtime-third-party.json) |
| dyncall (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `ISC` | ariza runtime data (runtime-third-party.json) |
| libatomic_ops (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `MIT` | ariza runtime data (runtime-third-party.json) |
| LibTomMath (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `Unlicense` | ariza runtime data (runtime-third-party.json) |
| libuv (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `MIT AND BSD-2-Clause AND ISC` | ariza runtime data (runtime-third-party.json) |
| memmem (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `MIT` | ariza runtime data (runtime-third-party.json) |
| mimalloc (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `MIT` | ariza runtime data (runtime-third-party.json) |
| MoarVM | as shipped in Rakudo 2026.07 | `Artistic-2.0` | ariza runtime data (runtime-third-party.json) |
| msinttypes (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `BSD-3-Clause` | ariza runtime data (runtime-third-party.json) |
| NQP | as shipped in Rakudo 2026.07 | `Artistic-2.0` | ariza runtime data (runtime-third-party.json) |
| Rakudo | 2026.07 | `Artistic-2.0` | ariza runtime data (runtime-third-party.json) |
| rapidhash (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `MIT` | ariza runtime data (runtime-third-party.json) |
| SHA-1 (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `LicenseRef-public-domain` | ariza runtime data (runtime-third-party.json) |
| zmij (vendored by MoarVM) | as vendored in Rakudo 2026.07 | `MIT` | ariza runtime data (runtime-third-party.json) |
| SQLCipher | 4.14.0 | `BSD-3-Clause` | ariza runtime data (runtime-third-party.json) |
| zef | 1.1.3 | `Artistic-2.0` | site META (rakudo/share/perl6/site/dist) |

## Details

### App::Moneymoor — 0.2.0

* Kind: application
* Licence: `Artistic-2.0`
* Licence text: `LICENSES/App-Moneymoor.txt`
* Authors: A Person
* Upstream: <https://example.invalid/moneymoor.git>
* Source: this bundle is a build of it
* Provenance: app META6

### cmp (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `MIT`
* Licence text: `LICENSES/MIT.txt`
* Copyright (c) 2014 Charles Gunyon
* Upstream: <https://github.com/camgunz/cmp>
* Source: MoarVM's fork at https://github.com/MoarVM/cmp, compiled into MoarVM
* Provenance: ariza runtime data (runtime-third-party.json)

A MessagePack implementation, used by MoarVM's heap snapshot and profiler output.

### DynASM (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `MIT`
* Licence text: `LICENSES/MIT.txt`
* Copyright (C) 2005-2014 Mike Pall
* Upstream: <https://luajit.org/dynasm.html>
* Source: MoarVM's fork at https://github.com/MoarVM/dynasm, compiled into MoarVM
* Provenance: ariza runtime data (runtime-third-party.json)

LuaJIT's dynamic assembler. Its generator is a build-time Lua program, but the `dasm_*.h` encoding runtime it emits is compiled into MoarVM's JIT, so it is redistributed here rather than merely used to build.

### dyncall (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `ISC`
* Licence text: `LICENSES/ISC.txt`
* Copyright (c) 2007-2020 Daniel Adler and Tassilo Philipp
* Upstream: <https://dyncall.org/>
* Source: MoarVM's fork at https://github.com/MoarVM/dyncall, compiled into MoarVM
* Provenance: ariza runtime data (runtime-third-party.json)

The foreign-function call machinery every `is native` subroutine in a Raku program goes through, which for a bundled TUI application is most of what talks to the terminal.

### libatomic_ops (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `MIT`
* Licence text: `LICENSES/MIT.txt`
* Copyright (c) Hans Boehm, Ivan Maidanski and the libatomic_ops contributors
* Upstream: <https://github.com/ivmai/libatomic_ops>
* Source: MoarVM's fork at https://github.com/MoarVM/libatomic_ops, compiled into MoarVM
* Provenance: ariza runtime data (runtime-third-party.json)

Portable atomic operations. The package also contains GPL-2.0 files, and none of them are here: upstream confines them to `libatomic_ops_gpl` plus the configure, build and test tooling, and MoarVM's own 3rdparty/README states they are not included in any built binary. A few sysdeps files are inherited from the Boehm-Demers-Weiser collector under a permissive notice of the same shape as the MIT text that travels with this row.

### LibTomMath (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `Unlicense`
* Licence text: `LICENSES/Unlicense.txt`
* Public domain; written by Tom St Denis and contributors
* Upstream: <https://www.libtom.net/LibTomMath/>
* Source: MoarVM's fork at https://github.com/MoarVM/libtommath, compiled into MoarVM
* Provenance: ariza runtime data (runtime-third-party.json)

Arbitrary-precision integers -- Raku's `Int` past 64 bits. The commit MoarVM pins carries the LibTom public-domain dedication, which is the Unlicense text under another heading.

### libuv (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `MIT AND BSD-2-Clause AND ISC`
* Licence text: `LICENSES/BSD-2-Clause.txt`, `LICENSES/ISC.txt`, `LICENSES/MIT.txt`
* Copyright (c) 2015-present libuv project contributors; Copyright Joyent, Inc. and other Node contributors; tree.h copyright Niels Provos; inet_pton/inet_ntop copyright Internet Systems Consortium, Inc.
* Upstream: <https://libuv.org/>
* Source: MoarVM's fork at https://github.com/MoarVM/libuv, compiled into MoarVM
* Provenance: ariza runtime data (runtime-third-party.json)

Event loop, filesystem, process and socket layer. libuv's LICENSE is MIT; its LICENSE-extra names the two externally maintained pieces it carries -- `tree.h` from FreeBSD under the two-clause BSD licence, and the `inet_pton`/`inet_ntop` implementations under the ISC licence -- which is why three texts travel with it.

### memmem (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `MIT`
* Licence text: `LICENSES/MIT.txt`
* Copyright (c) 2005-2014 Rich Felker, et al.
* Upstream: <https://musl.libc.org/>
* Source: MoarVM's own tree, 3rdparty/freebsd/memmem.c
* Provenance: ariza runtime data (runtime-third-party.json)

A substring search compiled in only where the platform C library has no `memmem` -- Windows, macOS and Solaris. The directory is called `freebsd`; the file in it is musl's implementation and carries musl's MIT notice.

### mimalloc (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `MIT`
* Licence text: `LICENSES/MIT.txt`
* Copyright (c) 2018-2025 Microsoft Corporation, Daan Leijen
* Upstream: <https://github.com/microsoft/mimalloc>
* Source: https://github.com/microsoft/mimalloc, vendored by MoarVM and compiled into it
* Provenance: ariza runtime data (runtime-third-party.json)

General-purpose allocator. A recent arrival in MoarVM's 3rdparty/ -- see the MoarVM caveat at the top of this file.

### MoarVM — as shipped in Rakudo 2026.07

* Kind: runtime
* Licence: `Artistic-2.0`
* Licence text: `LICENSES/Artistic-2.0.txt`
* Copyright 2012-2015 Jonathan Worthington and others
* Upstream: <https://moarvm.org/>
* Source: built into the Rakudo binary release 2026.07-01
* Provenance: ariza runtime data (runtime-third-party.json)

The virtual machine Rakudo runs on. Its own LICENSE says the Artistic License 2.0 applies to the project but that some portions are redistributed under other licences: those portions are the libraries MoarVM vendors under 3rdparty/, and each of them has its own row below.

### msinttypes (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `BSD-3-Clause`
* Licence text: `LICENSES/BSD-3-Clause.txt`
* Copyright (c) 2006-2013 Alexander Chemeris
* Upstream: <https://github.com/chemeris/msinttypes>
* Source: MoarVM's own tree, 3rdparty/msinttypes/
* Provenance: ariza runtime data (runtime-third-party.json)

`stdint.h` and `inttypes.h` for Visual C++ compilers old enough not to ship them. Headers only, and only on Windows builds; listed because a header that ends up compiled into a shipped binary is redistributed like anything else.

### NQP — as shipped in Rakudo 2026.07

* Kind: runtime
* Licence: `Artistic-2.0`
* Licence text: `LICENSES/Artistic-2.0.txt`
* Copyright the NQP contributors
* Upstream: <https://github.com/Raku/nqp>
* Source: built into the Rakudo binary release 2026.07-01
* Provenance: ariza runtime data (runtime-third-party.json)

Not Quite Perl: the bootstrap language Rakudo's compiler is written in. It has no separate archive -- it is inside the one Rakudo release ariza downloads.

### Rakudo — 2026.07

* Kind: runtime
* Licence: `Artistic-2.0`
* Licence text: `LICENSES/Artistic-2.0.txt`
* Copyright the Rakudo contributors
* Upstream: <https://rakudo.org/>
* Source: official binary release 2026.07-01, downloaded unmodified from https://rakudo.org/dl/rakudo/x.tar.gz
* Provenance: ariza runtime data (runtime-third-party.json)

The compiler. Its own LICENSE file travels in the bundle at `rakudo/LICENSE` as well, unchanged from the archive it came in.

### rapidhash (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `MIT`
* Licence text: `LICENSES/MIT.txt`
* Copyright (C) 2025 Nicolas De Carli; based on wyhash by Wang Yi
* Upstream: <https://github.com/Nicoshev/rapidhash>
* Source: https://github.com/Nicoshev/rapidhash, vendored by MoarVM and compiled into it
* Provenance: ariza runtime data (runtime-third-party.json)

The string hash behind every Raku hash lookup. Also a recent arrival.

### SHA-1 (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `LicenseRef-public-domain`
* Licence text: `LICENSES/LicenseRef-public-domain.txt`
* Public domain; written by Steve Reid
* Upstream: <https://github.com/MoarVM/MoarVM>
* Source: MoarVM's own tree, 3rdparty/sha1/
* Provenance: ariza runtime data (runtime-third-party.json)

Steve Reid's public-domain SHA-1, used for MoarVM's serialization identities. Its own header says `this file is in the public domain`, which is a licensing situation SPDX has no identifier for.

### zmij (vendored by MoarVM) — as vendored in Rakudo 2026.07

* Kind: runtime
* Licence: `MIT`
* Licence text: `LICENSES/MIT.txt`
* Copyright (c) 2025 Victor Zverovich
* Upstream: <https://github.com/vitaut/zmij>
* Source: https://github.com/vitaut/zmij, vendored by MoarVM and compiled into it
* Provenance: ariza runtime data (runtime-third-party.json)

Floating-point formatting and parsing. Also a recent arrival.

### SQLCipher — 4.14.0

* Kind: native
* Licence: `BSD-3-Clause`
* Licence text: `LICENSES/BSD-3-Clause.txt`
* Copyright (c) 2008-2024 Zetetic LLC; SQLite itself is in the public domain
* Upstream: <https://www.zetetic.net/sqlcipher/>
* Source: homebrew keg: /opt/x/lib/libsqlcipher.0.dylib
* Files: `libsqlcipher.0.dylib`
* Provenance: ariza runtime data (runtime-third-party.json)

SQLite with an encryption layer. Zetetic's licence is the three-clause BSD licence with the project's own name in the third clause, and the text in LICENSES/ is the SPDX BSD-3-Clause template rather than Zetetic's copy of it -- the authoritative wording travels in the library's own source distribution. SQLCipher's dependency closure is staged beside it (an OpenSSL on the platforms whose SQLCipher links one dynamically); those files are conveyed under their own upstream licences, which ariza cannot name from the bytes and which an app can declare with `[[licensing.third-party]]` rows in its ariza.toml.

### zef — 1.1.3

* Kind: module
* Licence: `Artistic-2.0`
* Licence text: `LICENSES/Artistic-2.0.txt`
* Authors: Nick Logan
* Source: installed into the bundle by zef (auth zef:ugexe)
* Provenance: site META (rakudo/share/perl6/site/dist)

---

Generated by ariza from four sources it read rather than remembered: the
licensing kit inside each native pack, `resources/runtime-third-party.json`
in ariza's own distribution, the `license` field of every distribution
installed into this bundle, and the application's `ariza.toml`. Nothing
here is edited by hand — a correction belongs in whichever of those four
was wrong.
