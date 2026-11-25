#!/usr/bin/env bash
# Omi menu: build, run and test the Omi server, each a step of its own.
#
#   ./build.sh build              build the Free Pascal server: public/server
#   ./build.sh run [args]         run public/server (build it first if it is missing)
#   ./build.sh build-amiga        cross-compile the AmigaOS 3 server: build/amiga/omi68k
#   ./build.sh test [name]        build, then run the tests: gitea, backups, amiga (all by default)
#   ./build.sh test-gitea         create the disposable test Gitea the live tests copy
#   ./build.sh run-node           run the Node.js server (public/server.js)
#   ./build.sh run-php            run the PHP development server (public/, port 8000)
#   ./build.sh translations-pull  pull the translations from Transifex
#   ./build.sh translations-push  push the English source to Transifex
#
# Building never starts anything, and running never builds what is already
# built: they were one script (freepascalserver.sh), which ran the server
# after every build unless OMI_BUILD_ONLY=1 was set.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir"

# The Free Pascal server, with SQLite's official amalgamation compiled in.
build_server() (
	set -eu
	build_dir="$script_dir/build"
	sqlite_version=3530400
	sqlite_release=3.53.4
	sqlite_year=2026
	sqlite_archive="$build_dir/sqlite-amalgamation-$sqlite_version.zip"
	sqlite_url="https://www.sqlite.org/$sqlite_year/sqlite-amalgamation-$sqlite_version.zip"
	sqlite_sha3=628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e

	mkdir -p "$build_dir"

	# Cache SQLite's official amalgamation in build/. Reuse sqlite3.c only when it
	# is the pinned release; when extraction is needed, reuse a verified archive
	# before going to the network.
	cached_sqlite_release=
	if [ -f "$build_dir/sqlite3.c" ]; then
		cached_sqlite_release=$(sed -n 's/^#define SQLITE_VERSION[[:space:]]*"\([^"]*\)".*/\1/p' "$build_dir/sqlite3.c" | head -1)
	fi

	if [ "$cached_sqlite_release" = "$sqlite_release" ]; then
		echo "Using cached SQLite amalgamation $sqlite_release."
	else
		command -v unzip >/dev/null 2>&1 || {
			echo "unzip is required to extract the SQLite amalgamation." >&2
			exit 1
		}
		command -v openssl >/dev/null 2>&1 || {
			echo "openssl is required to verify the SQLite amalgamation." >&2
			exit 1
		}

		archive_ready=0
		if [ -f "$sqlite_archive" ]; then
			actual_sha3=$(openssl dgst -sha3-256 "$sqlite_archive" | awk '{print $NF}')
			if [ "$actual_sha3" = "$sqlite_sha3" ]; then
				echo "Using cached SQLite amalgamation archive $sqlite_release."
				archive_ready=1
			else
				echo "Cached SQLite archive has the wrong checksum; downloading it again."
			fi
		fi

		if [ "$archive_ready" -eq 0 ]; then
			command -v curl >/dev/null 2>&1 || {
				echo "curl is required to download the SQLite amalgamation." >&2
				exit 1
			}
			echo "Downloading SQLite amalgamation $sqlite_release..."
			curl --fail --location --retry 3 --output "$sqlite_archive.part" "$sqlite_url"
			actual_sha3=$(openssl dgst -sha3-256 "$sqlite_archive.part" | awk '{print $NF}')
			if [ "$actual_sha3" != "$sqlite_sha3" ]; then
				echo "SQLite amalgamation checksum mismatch." >&2
				echo "Expected: $sqlite_sha3" >&2
				echo "Actual:   $actual_sha3" >&2
				exit 1
			fi
			mv "$sqlite_archive.part" "$sqlite_archive"
		fi

		unzip -p "$sqlite_archive" "sqlite-amalgamation-$sqlite_version/sqlite3.c" > "$build_dir/sqlite3.c.part"
		mv "$build_dir/sqlite3.c.part" "$build_dir/sqlite3.c"
	fi

	command -v cc >/dev/null 2>&1 || {
		echo "A C compiler is required to embed SQLite." >&2
		exit 1
	}

	if [ ! -f "$build_dir/sqlite3.o" ] || [ "$build_dir/sqlite3.c" -nt "$build_dir/sqlite3.o" ]; then
		echo "Compiling embedded SQLite $sqlite_release..."
		cc -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
			-DSQLITE_OMIT_LOAD_EXTENSION -c "$build_dir/sqlite3.c" \
			-o "$build_dir/sqlite3.o"
	else
		echo "Linking cached compiled SQLite $sqlite_release."
	fi

	# Compile with FreePascal. A portable compiler may live at .tools/fpc, two
	# directories above this checkout. Its driver needs the real ppca64 compiler on
	# PATH and each installed unit directory passed explicitly when there is no
	# system-wide fpc.cfg.
	fpc_cmd=fpc
	set --
	fpcup_dir=../../bin/fpcupdeluxe/fpc
	fpcup_target=$(uname -m | sed 's/^arm64$/aarch64/')-linux
	if ! command -v "$fpc_cmd" >/dev/null 2>&1 && [ -x "$fpcup_dir/bin/$fpcup_target/ppca64" -o -x "$fpcup_dir/bin/$fpcup_target/ppcx64" ]; then
		# fpcupdeluxe under .tools/bin: its fpc.cfg names the machine it was
		# installed on, so ignore it (-n) and pass the unit directories here.
		fpc_cmd="$fpcup_dir/bin/$fpcup_target/fpc"
		PATH="$fpcup_dir/bin/$fpcup_target:$PATH"
		export PATH
		set -- -n -O2 -Xs -Sgic
		for unit_dir in "$fpcup_dir"/units/"$fpcup_target"/*; do
			set -- "$@" "-Fu$unit_dir"
		done
	elif ! command -v "$fpc_cmd" >/dev/null 2>&1; then
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
)

run_server() {
	[ -x public/server ] || build_server
	exec ./public/server "$@"
}

# The disposable test Gitea the live tests copy (tests/gitea_live.py): a work
# folder in WeKan's .tools/tmp with an app.ini, a database Gitea itself
# migrated, an admin user and its API token. The tests only ever copy it.
test_gitea() (
	set -eu
	tools="$(cd "$script_dir/../.." && pwd)"
	gitea="${OMI_TEST_GITEA_BINARY:-$tools/w/gitea/gitea}"
	dir="${OMI_TEST_GITEA_DIR:-$tools/tmp/gitea-backup-test}"
	if [ -f "$dir/token" ] && [ -f "$dir/data/gitea.db" ]; then
		echo "The test Gitea is there: $dir"
		exit 0
	fi
	[ -x "$gitea" ] || { echo "No Gitea program at $gitea (OMI_TEST_GITEA_BINARY): the live tests are skipped." >&2; exit 1; }
	mkdir -p "$dir/custom/conf" "$dir/data/home"
	cat > "$dir/custom/conf/app.ini" <<INI
APP_NAME = Omi test Gitea
RUN_MODE = prod
WORK_PATH = $dir

[server]
HTTP_ADDR = 127.0.0.1
HTTP_PORT = 3399
ROOT_URL = http://127.0.0.1:3399/
APP_DATA_PATH = $dir/data
DISABLE_SSH = true
LFS_START_SERVER = true

[database]
DB_TYPE = sqlite3
PATH = $dir/data/gitea.db

[repository]
ROOT = $dir/data/repos

[security]
INSTALL_LOCK = true

[service]
DISABLE_REGISTRATION = true

[log]
ROOT_PATH = $dir/log
LEVEL = Warn

[lfs]
PATH = $dir/data/lfs
INI
	export HOME="$dir/data/home" GITEA_WORK_DIR="$dir"
	"$gitea" --config "$dir/custom/conf/app.ini" migrate >/dev/null
	"$gitea" --config "$dir/custom/conf/app.ini" admin user create --admin --username omitest \
		--password "$(head -c 18 /dev/urandom | base64)" --email omitest@example.com --must-change-password=false >/dev/null
	umask 077
	"$gitea" --config "$dir/custom/conf/app.ini" admin user generate-access-token --username omitest --scopes all --raw > "$dir/token"
	echo "Created the test Gitea: $dir"
)

run_tests() {
	build_server
	local names=("$@") rc=0
	[ ${#names[@]} -gt 0 ] || names=(gitea backups amiga)
	for name in "${names[@]}"; do
		[ "$name" = gitea ] && { test_gitea || true; }
		echo "===== tests/${name}_test.py"
		OMI_SKIP_BUILD=1 python3 -I "tests/${name}_test.py" || rc=1
	done
	return "$rc"
}

command="${1:-}"
if [ -z "$command" ]; then
	printf '1) Build the Free Pascal server (public/server)
2) Run the server
3) Build the AmigaOS 3 server (build/amiga/omi68k)
4) Run the tests
5) Create the test Gitea for the live tests
6) Run the Node.js server
7) Run the PHP development server
8) Pull the translations from Transifex
9) Push the English source to Transifex
0) Exit
Selection: '
	read -r choice
	case "$choice" in
		1) command=build;; 2) command=run;; 3) command=build-amiga;; 4) command=test;;
		5) command=test-gitea;; 6) command=run-node;; 7) command=run-php;;
		8) command=translations-pull;; 9) command=translations-push;; 0) exit 0;;
		*) echo 'Invalid selection' >&2; exit 2;;
	esac
else
	shift
fi
case "$command" in
	build) build_server ;;
	run) run_server "$@" ;;
	build-amiga) exec sh releases/amiga/build.sh "$@" ;;
	test) run_tests "$@" ;;
	test-gitea) test_gitea ;;
	run-node) exec node public/server.js "$@" ;;
	run-php) exec php -S "${OMI_PHP_LISTEN:-localhost:8000}" -t public/ ;;
	translations-pull) exec sh releases/translations/pull-translations.sh ;;
	translations-push) exec sh releases/translations/push-english-base-translation.sh ;;
	*) echo "Usage: $0 [build|run [args]|build-amiga|test [gitea|backups|amiga]...|test-gitea|run-node|run-php|translations-pull|translations-push]" >&2; exit 2 ;;
esac
