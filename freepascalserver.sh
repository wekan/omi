
# Compile with FreePascal
build_log="$(mktemp)"
if fpc public/server.pas >"$build_log" 2>&1; then
	grep -v -- "-macosx_version_min has been renamed to -macos_version_min" "$build_log" || true
	rm -f "$build_log"
else
	cat "$build_log"
	rm -f "$build_log"
	exit 1
fi

# Run server executeable binary
./public/server
