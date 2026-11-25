#!/bin/sh
# Omi's server for AmigaOS 3.x on the 68020 (with a 68881/68882 or the
# 68040's FPU), cross-compiled on Linux: build/amiga/omi68k.
#
# What it needs, all outside this repository (OMI_AMIGA_CROSS, by default
# WeKan's .tools/tmp/welite-amiga-cross, which WeLite's docs/cross.md
# describes):
#
#   install/lib/fpc/3.2.3/ppcross68k and units/m68k-amiga
#                       FreePascal 3.2.3 for m68k-amiga
#   newer-bin/          m68k-amiga-vasmm68k_std and m68k-amiga-vlink (0.18a)
#   gcc/m68k-amigaos-gcc-16.2/
#                       bebbo's m68k-amigaos GCC with libnix, for SQLite
#   sqlite-port/source/ gfopensqlite (its AmigaDOS patches and compat/)
#
# and build/sqlite3.c, the SQLite amalgamation ./build.sh build caches
# and checks.
#
# libnix numbers its files from 0, so SQLite must not keep descriptors 0-2
# free by opening /dev/null (SQLITE_MINIMUM_FILE_DESCRIPTOR=0).
#
# SQLite is compiled as gfopensqlite compiles it, except that WAL is kept -
# Gitea's database is a WAL database - with SQLITE_DEFAULT_LOCKING_MODE=1:
# in EXCLUSIVE locking mode WAL's index is in SQLite's own memory, so the
# missing mmap() (releases/amiga/omi_amiga.c) is never called. The threads
# are left out (-dOMI_THREADS would take FreePascal's athreads), and https://
# cannot be fetched: FreePascal has no TLS for the Amiga.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)
cross=${OMI_AMIGA_CROSS:-$repo/../../tmp/welite-amiga-cross}
cross=$(CDPATH= cd -- "$cross" && pwd)
out=$repo/build/amiga
fpc=$cross/install/lib/fpc/3.2.3/ppcross68k
units=$cross/install/lib/fpc/3.2.3/units/m68k-amiga
bin=$cross/newer-bin
gcc_root=$cross/gcc/m68k-amigaos-gcc-16.2
cc=$gcc_root/bin/m68k-amigaos-gcc
objcopy=$gcc_root/bin/m68k-amigaos-objcopy
# The compiler's tools are x86-64 programs. On another host they run as the
# compiler's own wrapper runs it: under QEMU, with its x86-64 libraries.
x86=
if [ "$(uname -m)" != x86_64 ]; then
	x86=$(sed -n 's/^exec \(.*\) -0 "\$0" .*/\1/p' "$cc")
fi
gfo=$cross/sqlite-port/source

for need in "$fpc" "$bin/m68k-amiga-vlink" "$bin/m68k-amiga-vasmm68k_std" "$cc" "$objcopy" \
	"$gfo/patches/sqlite-3.53.4-amiga-paths.patch" "$gfo/compat/sqlite_amiga.c" "$repo/build/sqlite3.c" \
	"$repo/build/sqlite-amalgamation-3530400.zip"; do
	if [ ! -e "$need" ]; then
		echo "missing: $need" >&2
		exit 1
	fi
done
mkdir -p "$out/lib"

cpu="-m68020 -m68881 -mcrt=nix20"
cflags="-O2 $cpu -fno-delete-null-pointer-checks -D_DEFAULT_SOURCE=1 -D_POSIX_TIMERS=1 \
-D_POSIX_REALTIME_SIGNALS=1 -fno-common -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION \
-DSQLITE_DEFAULT_LOCKING_MODE=1 -DSQLITE_MAX_MMAP_SIZE=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0 \
-DSQLITE_DISABLE_DIRSYNC -DHAVE_USLEEP=1 -DSQLITE_OS_UNIX=1 -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
-DSQLITE_MINIMUM_FILE_DESCRIPTOR=0 \
-DSQLITE_DEFAULT_UNIX_VFS=\"unix-dotfile\" -DSQLITE_EXTRA_AUTOEXT=sqlite_amiga_autoext \
-I$here/include -include $gfo/compat/sqlite_amiga_pre.h"

# SQLite, patched for AmigaDOS, compiled for the 68020 (a few minutes: the
# compiler runs under QEMU on an ARM host).
if [ ! -f "$out/sqlite3.o" ] || [ "$repo/build/sqlite3.c" -nt "$out/sqlite3.o" ] || [ "$0" -nt "$out/sqlite3.o" ]; then
	cp "$repo/build/sqlite3.c" "$out/sqlite3.c"
	(cd "$out" && patch -s -p1 < "$gfo/patches/sqlite-3.53.4-amiga-paths.patch" &&
		patch -s -p1 < "$gfo/patches/sqlite-3.53.4-amiga-seek.patch")
	echo "Compiling SQLite for m68k-amigaos..."
	# shellcheck disable=SC2086
	"$cc" $cflags -I"$out" -c "$out/sqlite3.c" -o "$out/sqlite3.o"
fi
# sqlite3.h, for gfopensqlite's compat/sqlite_amiga.c, from the archive
# ./build.sh build checked.
unzip -p "$repo/build/sqlite-amalgamation-3530400.zip" sqlite-amalgamation-3530400/sqlite3.h > "$out/sqlite3.h"
# shellcheck disable=SC2086
"$cc" $cflags -I"$out" -c "$gfo/compat/sqlite_amiga.c" -o "$out/sqlite_amiga.o"
# shellcheck disable=SC2086
"$cc" $cflags -c "$here/omi_amiga.c" -o "$out/omi_amiga.o"

# libnix and libgcc for the 68020 with an FPU, without their debug sections:
# vlink cannot relocate the DWARF of _muldi3.o (WeLite's docs/cross.md).
gl=$gcc_root/m68k-amigaos
for lib in "$gl/libnix/lib/libm020/libnix20.a:nix20" "$gl/libnix/lib/libm020/libnix.a:nix" \
	"$gl/libnix/lib/libm020/libm881/libm.a:m" "$gl/libnix/lib/libm020/libstubs.a:stubs" \
	"$gl/lib/libm020/libm881/libamiga.a:amiga" "$gcc_root/lib/gcc/m68k-amigaos/16/libm020/libm881/libgcc.a:gcc"; do
	src=${lib%:*}
	name=${lib##*:}
	# shellcheck disable=SC2086
	$x86 "$objcopy" --strip-debug "$src" "$out/lib/libomi$name.a"
done

set --
for d in "$units"/*; do
	set -- "$@" "-Fu$d"
done
cd "$repo"
log=$out/fpc.log
if "$fpc" -n -Tamiga -Pm68k -O2 -Xs -Sgic -XV -Avasm -FD"$bin" -XPm68k-amiga- "$@" \
	-k-L"$out/lib" -k-lominix20 -k-lominix -k-lomim -k-lomiamiga -k-lomigcc \
	-FU"$out" -FE"$out" -oomi68k public/server.pas >"$log" 2>&1; then
	grep -E "Error|Fatal|Linking" "$log" || true
else
	grep -v -E "Hint|Note|Warning" "$log" | tail -40
	exit 1
fi
echo "Built $out/omi68k"
