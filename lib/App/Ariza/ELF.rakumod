unit module App::Ariza::ELF;

# The parts of the System V ABI this reader acts on. Everything else in
# an ELF file -- symbols, relocations, the section table -- is the static
# linker's business, not the loader's, and is not read.
my constant DT-NULL    = 0;
my constant DT-NEEDED  = 1;
my constant DT-STRTAB  = 5;
my constant DT-STRSZ   = 10;
my constant DT-RPATH   = 15;
my constant DT-RUNPATH = 29;

my constant PT-LOAD    = 1;
my constant PT-DYNAMIC = 2;

my constant ET-EXEC = 2;
my constant ET-DYN  = 3;

# e_phnum's escape value: the real count did not fit in 16 bits and is
# in section header 0's sh_info instead.
my constant PN-XNUM = 0xFFFF;

# Where each field this reads lives, per class. Offsets are into the ELF
# header, a program header, a section header or a dynamic entry, as the
# key says; `word` is the width of an address, an offset and a d_val.
my constant %LAYOUT =
	32 => %(
		word => 4, ehsize => 52, phentsize => 32, shentsize => 40, dynent => 8,
		e-phoff => 28, e-shoff => 32,
		e-phentsize => 42, e-phnum => 44, e-shentsize => 46,
		p-offset => 4, p-vaddr => 8, p-filesz => 16, p-memsz => 20,
		sh-info => 28,
	),
	64 => %(
		word => 8, ehsize => 64, phentsize => 56, shentsize => 64, dynent => 16,
		e-phoff => 32, e-shoff => 40,
		e-phentsize => 54, e-phnum => 56, e-shentsize => 58,
		p-offset => 8, p-vaddr => 16, p-filesz => 32, p-memsz => 40,
		sh-info => 44,
	),
;

my sub elf-die(IO::Path $file, Str:D $why) {
	die "ariza: cannot read the dynamic section of {$file.absolute}: $why";
}

#| An unsigned field of C<$width> bytes at C<$at>, in the file's own byte
#| order. Every caller has already bounded C<$b> to the bytes it asked
#| for, so the read cannot run off the end.
my sub field(Blob:D $b, Int:D $at, Int:D $width, Endian:D $endian --> Int) {
	given $width {
		when 2 { $b.read-uint16($at, $endian) }
		when 4 { $b.read-uint32($at, $endian) }
		default { $b.read-uint64($at, $endian) }
	}
}

#| What the loader will read out of an ELF file's dynamic section:
#| C<{ class, endian, dynamic, needed, rpath, runpath }>.
#|
#| C<class> is 32 or 64 and C<endian> is C<'little'> or C<'big'>, as the
#| file's identification bytes say. C<dynamic> is whether there is a
#| dynamic section at all; a static executable and an object file have
#| none, which is legal, and answer with empty C<needed> and undefined
#| C<rpath>/C<runpath>. C<needed> is the C<DT_NEEDED> sonames in file
#| order; C<rpath> and C<runpath> are the C<DT_RPATH> and C<DT_RUNPATH>
#| strings, or the undefined C<Str> where the file has none.
#|
#| The dynamic section is found the way the loader finds it -- the
#| C<PT_DYNAMIC> program header -- and its string table through
#| C<DT_STRTAB>, an address mapped back to a file offset through the
#| C<PT_LOAD> segment that holds it.
#|
#| Anything that does not parse is a die naming the file and what was
#| wrong with it. There is no "I could not tell" answer: the callers are
#| an audit and a staging pass, and an empty one for a file this cannot
#| read would pass both.
our sub elf-dynamic(IO() $file --> Hash) is export {
	elf-die($file, 'it is not a file') unless $file.f;
	my $size = $file.s;
	my $h = try $file.open(:bin);
	elf-die($file, "it could not be opened ({$!.message})") without $h;
	LEAVE { .close with $h }

	# Exactly $len bytes from $at, or a death saying which structure
	# wanted them -- a truncated file is the commonest malformation, and
	# "the program headers want 112 bytes at offset 64" says which part
	# of it is missing.
	my sub read-at(Int:D $at, Int:D $len, Str:D $what --> Blob) {
		elf-die($file, "reading $what needs $len bytes at offset $at, and the"
					 ~ " file is $size bytes long")
			if $at < 0 || $len < 0 || $at + $len > $size;
		return Blob.new unless $len;
		$h.seek($at, SeekFromBeginning);
		my $b = $h.read($len);
		elf-die($file, "$what: only {$b.elems} of $len bytes at offset $at"
					 ~ " could be read")
			unless $b.elems == $len;
		$b
	}

	my $ident = read-at(0, 16, 'the ELF identification');
	elf-die($file, 'it does not begin with the ELF magic number (7F 45 4C 46)')
		unless $ident[0] == 0x7F && $ident[1] == 0x45
			&& $ident[2] == 0x4C && $ident[3] == 0x46;

	my $class = do given $ident[4] {
		when 1  { 32 }
		when 2  { 64 }
		default {
			elf-die($file, "its EI_CLASS byte is $_, which is neither"
						 ~ " ELFCLASS32 (1) nor ELFCLASS64 (2)");
		}
	};
	my $endian = do given $ident[5] {
		when 1  { LittleEndian }
		when 2  { BigEndian }
		default {
			elf-die($file, "its EI_DATA byte is $_, which is neither"
						 ~ " ELFDATA2LSB (1) nor ELFDATA2MSB (2)");
		}
	};
	elf-die($file, "its EI_VERSION byte is {$ident[6]}, and the only ELF"
				 ~ " version there is is 1")
		unless $ident[6] == 1;

	my %L    = %LAYOUT{$class};
	my $word = %L<word>;
	my $eh   = read-at(0, %L<ehsize>, "the ELF$class header");

	my $type      = field($eh, 16, 2, $endian);
	my $phoff     = field($eh, %L<e-phoff>, $word, $endian);
	my $shoff     = field($eh, %L<e-shoff>, $word, $endian);
	my $phentsize = field($eh, %L<e-phentsize>, 2, $endian);
	my $phnum     = field($eh, %L<e-phnum>, 2, $endian);
	my $shentsize = field($eh, %L<e-shentsize>, 2, $endian);

	my %result = class => $class,
				 endian => ($endian == LittleEndian ?? 'little' !! 'big'),
				 dynamic => False, needed => (), rpath => Str, runpath => Str;

	if $phnum == PN-XNUM {
		elf-die($file, 'its e_phnum is PN_XNUM (0xFFFF), which puts the real'
					 ~ ' count in section header 0, and it has no section'
					 ~ ' headers')
			unless $shoff;
		elf-die($file, "its section headers are $shentsize bytes each, where"
					 ~ " ELF$class says {%L<shentsize>}")
			unless $shentsize == %L<shentsize>;
		$phnum = field(read-at($shoff, $shentsize, 'section header 0'),
					   %L<sh-info>, 4, $endian);
	}

	# No program headers: nothing a loader could map. Legal for an object
	# file, which has no dynamic section to read; for an executable or a
	# shared object it is a file no loader can load, and saying it needs
	# nothing would be a guess.
	unless $phnum {
		elf-die($file, "it is an ELF {$type == ET-DYN ?? 'shared object' !! 'executable'}"
					 ~ " with no program headers, so no loader could map it")
			if $type == ET-EXEC | ET-DYN;
		return %result;
	}

	elf-die($file, "its program headers are $phentsize bytes each, where"
				 ~ " ELF$class says {%L<phentsize>}")
		unless $phentsize == %L<phentsize>;
	elf-die($file, "its program headers are at offset $phoff, inside the"
				 ~ " {%L<ehsize>}-byte ELF header")
		if $phoff < %L<ehsize>;

	my $ph = read-at($phoff, $phnum * $phentsize, "its $phnum program headers");
	my (@loads, @dynamic);
	for ^$phnum -> $i {
		my $at = $i * $phentsize;
		my $kind = field($ph, $at, 4, $endian);
		next unless $kind == PT-LOAD | PT-DYNAMIC;
		my %seg = offset => field($ph, $at + %L<p-offset>, $word, $endian),
				  vaddr  => field($ph, $at + %L<p-vaddr>,  $word, $endian),
				  filesz => field($ph, $at + %L<p-filesz>, $word, $endian),
				  memsz  => field($ph, $at + %L<p-memsz>,  $word, $endian);
		$kind == PT-LOAD ?? @loads.push(%seg) !! @dynamic.push(%seg);
	}

	# A static executable: no dynamic section, so nothing is loaded on
	# its behalf. Not a malformation.
	return %result unless @dynamic;
	elf-die($file, "it has {+@dynamic} PT_DYNAMIC program headers, and a"
				 ~ " loader reads exactly one")
		if @dynamic > 1;
	%result<dynamic> = True;

	my %dyn = @dynamic.head;
	my $entries = read-at(%dyn<offset>, %dyn<filesz>, 'its dynamic section');
	my $dynent = %L<dynent>;
	my (@needed, @rpath, @runpath, @strtab, @strsz);
	my $terminated = False;
	loop (my $at = 0; $at + $dynent <= $entries.elems; $at += $dynent) {
		my $tag = field($entries, $at, $word, $endian);
		my $val = field($entries, $at + $word, $word, $endian);
		given $tag {
			when DT-NULL    { $terminated = True; last }
			when DT-NEEDED  { @needed.push($val) }
			when DT-RPATH   { @rpath.push($val) }
			when DT-RUNPATH { @runpath.push($val) }
			when DT-STRTAB  { @strtab.push($val) }
			when DT-STRSZ   { @strsz.push($val) }
		}
	}
	elf-die($file, "its dynamic section runs out after {%dyn<filesz>} bytes"
				 ~ " without the DT_NULL entry that ends it")
		unless $terminated;

	# Two of any of these is a file no linker writes, and which one the
	# loader honours is not something to guess at on a release's behalf.
	for (DT_RPATH => @rpath, DT_RUNPATH => @runpath,
		 DT_STRTAB => @strtab, DT_STRSZ => @strsz) -> $p {
		elf-die($file, "it has {+$p.value} {$p.key} entries, where a dynamic"
					 ~ " section holds at most one")
			if $p.value > 1;
	}

	return %result unless @needed || @rpath || @runpath;
	elf-die($file, 'it has DT_NEEDED, DT_RPATH or DT_RUNPATH entries and no'
				 ~ ' DT_STRTAB to spell them with')
		unless @strtab;

	# DT_STRTAB is an address, not an offset: the segment that maps it is
	# the only thing that says where in the file its bytes are. Part of a
	# segment can be address space with no bytes behind it (memsz past
	# filesz), and a string table cannot live there.
	my $addr = @strtab.head;
	my ($str-at, $str-room);
	for @loads -> %seg {
		my $span = max(%seg<memsz>, %seg<filesz>);
		next unless $addr >= %seg<vaddr> && $addr - %seg<vaddr> < $span;
		my $into = $addr - %seg<vaddr>;
		elf-die($file, sprintf('its string table is at address 0x%X, in the'
							 ~ ' part of a segment that has no bytes in the'
							 ~ ' file', $addr))
			if $into >= %seg<filesz>;
		$str-at   = %seg<offset> + $into;
		$str-room = %seg<filesz> - $into;
		last;
	}
	elf-die($file, sprintf('its string table is at address 0x%X, which falls in'
						 ~ ' none of its %d loadable segment(s)', $addr, +@loads))
		without $str-at;

	my $strsz = @strsz ?? @strsz.head !! $str-room;
	elf-die($file, "its DT_STRSZ says the string table is $strsz bytes, and"
				 ~ " the segment holding it has $str-room from where it starts")
		if $strsz > $str-room;
	my $strtab = read-at($str-at, $strsz, 'its string table');

	my sub string-at(Int:D $offset, Str:D $what --> Str) {
		elf-die($file, "its $what string is at offset $offset, past the end of"
					 ~ " a {$strsz}-byte string table")
			if $offset >= $strsz;
		my $end = $offset;
		$end++ while $end < $strsz && $strtab[$end];
		elf-die($file, "its $what string at offset $offset runs to the end of"
					 ~ " the string table without a terminating NUL")
			if $end >= $strsz;
		$strtab.subbuf($offset, $end - $offset).decode('utf8-c8')
	}

	my @names;
	for @needed -> $offset {
		my $name = string-at($offset, 'DT_NEEDED');
		elf-die($file, "a DT_NEEDED entry names the empty string, at string"
					 ~ " table offset $offset")
			unless $name.chars;
		@names.push($name);
	}
	%result<needed>  = @names.List;
	%result<rpath>   = string-at(@rpath.head, 'DT_RPATH') if @rpath;
	%result<runpath> = string-at(@runpath.head, 'DT_RUNPATH') if @runpath;
	%result
}

#| The search path the loader will actually use for an C<elf-dynamic>
#| result: C<DT_RUNPATH> where there is one, C<DT_RPATH> where there is
#| only that, and the empty string where there is neither.
#|
#| The precedence is the loader's own -- a C<DT_RUNPATH> makes it ignore
#| C<DT_RPATH> outright -- and it is exactly what
#| C<patchelf --print-rpath> prints.
our sub elf-loader-rpath(%dynamic --> Str) is export {
	%dynamic<runpath> // %dynamic<rpath> // ''
}

=begin pod

=head1 NAME

App::Ariza::ELF - read what an ELF file asks the loader for, with no toolchain installed

=head1 SYNOPSIS

=begin code :lang<raku>

use App::Ariza::ELF;

my %d = elf-dynamic('native/sqlcipher/libsqlcipher.so.0');

say %d<class>;      # 64
say %d<endian>;     # little
say %d<needed>;     # (libcrypto.so.3 libc.so.6)
say %d<runpath>;    # $ORIGIN
say %d<rpath>;      # (Str) -- this file has no DT_RPATH

# What the loader will search, which is what `patchelf --print-rpath`
# prints: DT_RUNPATH where there is one, DT_RPATH otherwise.
say elf-loader-rpath(%d);                   # $ORIGIN

# A file built with the old tag, pointing at the machine that built it:
say elf-loader-rpath(elf-dynamic('libfoo.so'));   # /opt/build/lib:$ORIGIN

# A static executable has nothing to ask for, and says so:
my %s = elf-dynamic('static-tool');
say %s<dynamic>;    # False
say %s<needed>;     # ()

# Anything that does not parse is a death, never a guess:
elf-dynamic('truncated.so');
# ariza: cannot read the dynamic section of /…/truncated.so: reading its
# dynamic section needs 400 bytes at offset 600, and the file is 700
# bytes long

=end code

=head1 DESCRIPTION

Everything L<App::Ariza::Native> needs to know about an ELF shared
library before it will let one into a bundle is in three entries of its
dynamic section: the C<DT_NEEDED> sonames it asks the loader for, and the
C<DT_RPATH> or C<DT_RUNPATH> the loader is told to search for them. This
module reads those, and nothing else, out of the file's bytes.

It exists because the tools that otherwise answer the question are not
on the machines that need the answer. C<readelf> comes with binutils,
which a stock Linux install, a slim container image and every Mac lack;
C<patchelf> is a package almost nothing installs by default. An audit
that dies because a tool is missing cannot run where it is wanted, and
one that answers "no dependencies" when the tool is missing passes the
bundle it exists to stop. Reading the format directly has neither
failure, and gives the same answer on every host — an ELF bundle can be
checked from a Mac or a Windows box exactly as it is checked on Linux.

=head2 What is read, and how

The walk is the loader's, not the static linker's:

=item1 The identification bytes: the C<\x7FELF> magic, C<EI_CLASS>
(32- or 64-bit), C<EI_DATA> (little- or big-endian) and C<EI_VERSION>.
Every field after them is read at the width and in the byte order they
name, so one reader covers x86_64 and i686, aarch64 and s390x, PowerPC
both ways round.

=item1 The ELF header, for where the program headers are, how many there
are, and how big each one is.

=item1 The program headers: the C<PT_LOAD> segments, which are the map
between the addresses a dynamic section records and the bytes in the
file, and the one C<PT_DYNAMIC> segment, which is the dynamic section.

=item1 The dynamic section's entries, up to the C<DT_NULL> that ends it.

=item1 The string table, found through C<DT_STRTAB> — an B<address>,
mapped to a file offset through the C<PT_LOAD> segment that holds it —
and bounded by C<DT_STRSZ>.

The section table is not read. It is the static linker's account of the
file, it can be stripped without changing what loads, and it can
disagree with the segments; the loader reads only the segments, so this
does too. The one exception is the format's own: when C<e_phnum> is
C<PN_XNUM> (C<0xFFFF>), the real program-header count is in section
header 0, and is read from there.

C<$ORIGIN> is not expanded and no search is performed. This reports what
the file asks for; where the asking would end up on a given machine is
C<ldd>'s question, and only that machine can answer it.

=head2 What counts as malformed

Each of these is a die that names the file and the part of it that was
wrong, rather than an answer:

=item1 a file too short for the structure being read — the commonest
case, and the message says which structure wanted how many bytes where;
=item1 no ELF magic number, or an C<EI_CLASS>, C<EI_DATA> or
C<EI_VERSION> byte that is not one the format defines;
=item1 a program header size that is not the one the class defines, or
program headers that overlap the ELF header;
=item1 an executable or shared object with no program headers, which no
loader could map;
=item1 more than one C<PT_DYNAMIC>;
=item1 a dynamic section with no C<DT_NULL> inside it;
=item1 more than one C<DT_RPATH>, C<DT_RUNPATH>, C<DT_STRTAB> or
C<DT_STRSZ>, which no linker writes, and between which the loader's
choice is not something to guess at;
=item1 C<DT_NEEDED>, C<DT_RPATH> or C<DT_RUNPATH> entries and no
C<DT_STRTAB>;
=item1 a C<DT_STRTAB> address that is in no C<PT_LOAD>, or in the part of
one that has no bytes in the file, or a C<DT_STRSZ> that runs past its
segment;
=item1 a string offset past the end of the string table, a string with no
terminating NUL inside it, or a C<DT_NEEDED> naming the empty string.

Two things that look odd are B<not> malformed, and are answered rather
than refused: a file with no C<PT_DYNAMIC> (a static executable) or no
program headers at all (an object file) has C<dynamic> False and needs
nothing; and a file with both C<DT_RPATH> and C<DT_RUNPATH> — which older
GNU linkers wrote for C<--enable-new-dtags> — reports both, with
C<elf-loader-rpath> choosing as the loader does.

=head1 FUNCTIONS

=head2 elf-dynamic(IO() $file --> Hash)

C<{ class, endian, dynamic, needed, rpath, runpath }>, as described
above; or a die. C<needed> is a C<List> in file order, duplicates and
all; C<rpath> and C<runpath> are C<Str>, undefined where the tag is
absent and the empty string where the tag is present and empty. Strings
are decoded as C<utf8-c8>, so a path that is not valid UTF-8 survives the
round trip byte for byte. Exported.

=head2 elf-loader-rpath(%dynamic --> Str)

The search path the loader uses, from an C<elf-dynamic> result:
C<runpath> if defined, else C<rpath> if defined, else the empty string.
That is the loader's precedence and C<patchelf --print-rpath>'s output.
Exported.

=head1 SEE ALSO

L<App::Ariza::Native>, whose Linux audit and staging pass read ELF files
through this module, and C<t/fixtures/elf/>, whose C<build.sh> builds the
fixtures the tests read and records what C<readelf -d> and
C<patchelf --print-rpath> say about each one.

=head1 AUTHOR

Matt Doughty

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Matt Doughty

This library is free software; you can redistribute it and/or modify it
under the Artistic License 2.0.

=end pod
