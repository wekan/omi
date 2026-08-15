
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
if "$fpc_cmd" "$@" public/server.pas >"$build_log" 2>&1; then
	grep -v -- "-macosx_version_min has been renamed to -macos_version_min" "$build_log" || true
	rm -f "$build_log"
else
	cat "$build_log"
	rm -f "$build_log"
	exit 1
fi

# Run server executeable binary
./public/server
