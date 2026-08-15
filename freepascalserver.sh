#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir"

build_dir="$script_dir/build"
sqlite_version=3530400
sqlite_year=2026
sqlite_archive="$build_dir/sqlite-amalgamation-$sqlite_version.zip"
sqlite_url="https://www.sqlite.org/$sqlite_year/sqlite-amalgamation-$sqlite_version.zip"
sqlite_sha3=628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e

mkdir -p "$build_dir"

# Cache SQLite's official amalgamation in build/. It contains everything Omi
# needs to embed SQLite and is downloaded only when sqlite3.c is absent.
if [ ! -f "$build_dir/sqlite3.c" ]; then
	command -v curl >/dev/null 2>&1 || {
		echo "curl is required to download the SQLite amalgamation." >&2
		exit 1
	}
	command -v unzip >/dev/null 2>&1 || {
		echo "unzip is required to extract the SQLite amalgamation." >&2
		exit 1
	}
	command -v openssl >/dev/null 2>&1 || {
		echo "openssl is required to verify the SQLite amalgamation." >&2
		exit 1
	}

	echo "Downloading SQLite amalgamation $sqlite_version..."
	curl --fail --location --retry 3 --output "$sqlite_archive.part" "$sqlite_url"
	actual_sha3=$(openssl dgst -sha3-256 "$sqlite_archive.part" | awk '{print $NF}')
	if [ "$actual_sha3" != "$sqlite_sha3" ]; then
		echo "SQLite amalgamation checksum mismatch." >&2
		echo "Expected: $sqlite_sha3" >&2
		echo "Actual:   $actual_sha3" >&2
		exit 1
	fi
	mv "$sqlite_archive.part" "$sqlite_archive"
	unzip -p "$sqlite_archive" "sqlite-amalgamation-$sqlite_version/sqlite3.c" > "$build_dir/sqlite3.c.part"
	mv "$build_dir/sqlite3.c.part" "$build_dir/sqlite3.c"
fi

command -v cc >/dev/null 2>&1 || {
	echo "A C compiler is required to embed SQLite." >&2
	exit 1
}

if [ ! -f "$build_dir/sqlite3.o" ] || [ "$build_dir/sqlite3.c" -nt "$build_dir/sqlite3.o" ]; then
	echo "Compiling embedded SQLite..."
	cc -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
		-DSQLITE_OMIT_LOAD_EXTENSION -c "$build_dir/sqlite3.c" \
		-o "$build_dir/sqlite3.o"
fi

# Compile with FreePascal. A portable compiler may live at .tools/fpc, two
# directories above this checkout. Its driver needs the real ppca64 compiler on
# PATH and each installed unit directory passed explicitly when there is no
# system-wide fpc.cfg.
fpc_cmd=fpc
set --
if ! command -v "$fpc_cmd" >/dev/null 2>&1; then
	portable_fpc=../../fpc
	if [ ! -x "$portable_fpc/fpc" ] || [ ! -x "$portable_fpc/3.2.3/ppca64" ]; then
		echo "Free Pascal was not found on PATH or in $portable_fpc." >&2
		exit 1
	fi
	fpc_cmd="$portable_fpc/fpc"
	PATH="$portable_fpc/3.2.3:$PATH"
	export PATH
	for unit_dir in "$portable_fpc"/3.2.3/units/aarch64-linux/*; do
		set -- "$@" "-Fu$unit_dir"
	done
fi

build_log="$(mktemp)"
if "$fpc_cmd" "$@" -FU"$build_dir" -FE"$build_dir" public/server.pas >"$build_log" 2>&1; then
	grep -v -- "-macosx_version_min has been renamed to -macos_version_min" "$build_log" || true
	rm -f "$build_log"
else
	cat "$build_log"
	rm -f "$build_log"
	exit 1
fi

# Keep the public runtime path stable while all compiler output stays in build/.
# Rename atomically so an older running server does not cause "Text file busy".
cp "$build_dir/server" public/server.new
mv public/server.new public/server

# Run server executable binary.
./public/server
