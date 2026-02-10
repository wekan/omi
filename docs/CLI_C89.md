# Omi CLI for C89 (omi.c)

**Other CLI Versions:** [CLI_PYTHON3.md](CLI_PYTHON3.md) | [CLI_HAXE5.md](CLI_HAXE5.md) | [CLI_CSHARP.md](CLI_CSHARP.md) | [CLI_BASH.md](CLI_BASH.md) | [CLI_BAT.md](CLI_BAT.md) | [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md) | [CLI_LUA.md](CLI_LUA.md)  

## Overview

The C89 CLI is a portable, single-file C implementation designed for retro and modern platforms. It can compile on AmigaOS, Windows, macOS, BSD, and Linux using standard C89 toolchains.

Key properties:

- **C89 compatible** - works with classic compilers
- **Cross-platform** - AmigaOS, Windows, macOS, BSD, Linux
- **SQLite storage** - same database schema as other CLIs
- **Internal or external HTTP** - controlled by `USE_INTERNAL_HTTP`
- **SHA256 built-in** - no external hash tool required

## Requirements

- C89 compiler (gcc, clang, vbcc, SAS/C, MSVC)
- SQLite3 development headers and library
- `curl` executable (for external HTTP mode)
- Optional: libcurl development headers (for internal HTTP mode)

## Build Instructions

### Linux / BSD

```bash
gcc -std=c89 -O2 -o omi omi.c -lsqlite3
```

Enable internal HTTP with libcurl:

```bash
gcc -std=c89 -O2 -o omi omi.c -lsqlite3 -lcurl -DUSE_LIBCURL
```

### macOS

```bash
clang -std=c89 -O2 -o omi omi.c -lsqlite3
```

With libcurl:

```bash
clang -std=c89 -O2 -o omi omi.c -lsqlite3 -lcurl -DUSE_LIBCURL
```

### Windows (MinGW)

```bash
gcc -std=c89 -O2 -o omi.exe omi.c -lsqlite3
```

With libcurl:

```bash
gcc -std=c89 -O2 -o omi.exe omi.c -lsqlite3 -lcurl -DUSE_LIBCURL
```

### Windows (MSVC)

```bat
cl /O2 omi.c sqlite3.lib
```

With libcurl (if installed):

```bat
cl /O2 omi.c sqlite3.lib libcurl.lib /DUSE_LIBCURL
```

### AmigaOS (vbcc)

```bash
vc -O2 -o omi omi.c -lsqlite3
```

### AmigaOS (gcc / GeekGadgets)

```bash
gcc -O2 -o omi omi.c -lsqlite3
```

Note: libcurl is optional. If not compiled with `-DUSE_LIBCURL`, Omi uses external curl based on settings.

## Configuration

Create `settings.txt` in the repository root:

```ini
SQLITE=sqlite3
CURL=curl
USERNAME=user
PASSWORD=pass
REPOS=https://omi.example.com
API_ENABLED=1
API_RATE_LIMIT=60
API_RATE_LIMIT_WINDOW=60
USE_INTERNAL_HTTP=1
HTTP_TIMEOUT=30
```

### Internal vs External HTTP

Omi supports two modes for push/pull:

- **Internal HTTP** (`USE_INTERNAL_HTTP=1`)
  - Uses libcurl if compiled with `-DUSE_LIBCURL`
  - No external curl dependency
  - Recommended for embedded and restricted systems

- **External HTTP** (`USE_INTERNAL_HTTP=0`)
  - Uses external `curl` executable
  - Works without libcurl development headers
  - Useful for compatibility or debugging

If internal HTTP is enabled but libcurl is not compiled in, Omi falls back to external curl automatically.

## Quick Reference

| Command | Description |
|---------|-------------|
| `omi init` | Initialize new repository |
| `omi add <file>` | Stage a single file |
| `omi add --all` | Stage all files |
| `omi commit -m "msg"` | Create a commit |
| `omi push` | Push to remote (OTP if enabled) |
| `omi pull` | Pull from remote (OTP if enabled) |
| `omi status` | Show staging status |
| `omi log` | Show commit history |

## Common Workflows

### Initialize and Commit

```bash
omi init
omi add --all
omi commit -m "Initial commit"
```

### Push and Pull

```bash
omi push
omi pull
```

### Status and Log

```bash
omi status
omi log
```

## 2FA / OTP

If OTP is enabled for the user in `phpusers.txt`, Omi prompts for a 6-digit code during push and pull.

```
Enter OTP code (6 digits): 123456
```

## Platform Notes

### AmigaOS

- Use AmiSSL for HTTPS when using external curl
- If curl is not available, compile with libcurl (if supported in your toolchain)
- Keep repo.omi on a filesystem with long filename support

### Windows

- Use `omi.exe` and ensure `curl.exe` is in PATH
- SQLite library must be available to the compiler and linker

### BSD

- Install sqlite3 and libcurl from ports/pkg

```bash
pkg install sqlite3 curl
```

## Troubleshooting

### "Error: Database file repo.omi not found"

Run init first:

```bash
omi init
```

### "Internal HTTP failed, falling back to curl"

This means the binary was compiled without libcurl. Either:

1. Rebuild with libcurl:
```bash
gcc -std=c89 -O2 -o omi omi.c -lsqlite3 -lcurl -DUSE_LIBCURL
```

2. Or set external curl explicitly:
```ini
USE_INTERNAL_HTTP=0
```

### "Error: Failed to push"

- Check credentials in settings.txt
- Ensure REPOS points to your server URL
- Verify curl works: `curl --version`

## See Also

- **[README.md](README.md)** - Documentation index
- **[FEATURES.md](FEATURES.md)** - Feature overview
- **[CLI_PYTHON3.md](CLI_PYTHON3.md)** - CLI alternative (Python 3)
- **[CLI_HAXE5.md](CLI_HAXE5.md)** - CLI alternative (Haxe 5)
- **[CLI_CSHARP.md](CLI_CSHARP.md)** - CLI alternative (C# / Mono)
- **[CLI_TCL.md](CLI_TCL.md)** - CLI alternative (Tcl)
- **[CLI_BASH.md](CLI_BASH.md)** - CLI alternative (Bash)
- **[CLI_BAT.md](CLI_BAT.md)** - CLI alternative (FreeDOS)
- **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** - CLI alternative (Amiga)
- **[CLI_LUA.md](CLI_LUA.md)** - CLI alternative (Lua)
- **[WEB.md](WEB.md)** - Web interface
- **[SERVER_PHP.md](SERVER_PHP.md)** - Server setup
- **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** - Database design

## Notes

- C89 implementation uses a built-in SHA256 to avoid external hash dependencies
- If you need SSL certificate customization, prefer external curl
- For very large repositories, increase OS file descriptor limits

---

**Last Updated:** February 10, 2026  
**Omi Version:** 1.0  
**CLI Version:** C89
