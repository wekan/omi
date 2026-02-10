# Omi CLI for Tcl (omi.tcl)

**Other CLI Versions:** [CLI_PYTHON3.md](CLI_PYTHON3.md) | [CLI_HAXE5.md](CLI_HAXE5.md) | [CLI_CSHARP.md](CLI_CSHARP.md) | [CLI_C89.md](CLI_C89.md) | [CLI_BASH.md](CLI_BASH.md) | [CLI_BAT.md](CLI_BAT.md) | [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md) | [CLI_LUA.md](CLI_LUA.md)  

## Overview

The Tcl CLI is a portable implementation of Omi using Tcl 8.5+ with SQLite and HTTP support. It supports both internal HTTP (Tcl `http` package) and external curl, controlled by `USE_INTERNAL_HTTP`.

Highlights:

- **Portable** - Tcl runs on Unix, Windows, macOS, BSD, and Amiga ports
- **SQLite-based** - Same database schema as other CLIs
- **Internal HTTP** - Tcl `http` package for push/pull
- **External HTTP** - curl fallback when needed
- **SHA256** - Uses Tcllib `sha2` when available, or external tools

## Requirements

- Tcl 8.5 or newer (`tclsh`)
- SQLite extension for Tcl (`sqlite3` package)
- Tcl `http` package (usually included)
- Tcllib `sha2` package (recommended)
- curl executable (optional fallback)

### Verify Installation

```bash
tclsh <<< "puts [info patchlevel]"
tclsh <<< "package require sqlite3"
tclsh <<< "package require http"
```

For SHA256 (recommended):

```bash
tclsh <<< "package require sha2"
```

## Installation

1. Clone or download Omi:

```bash
git clone https://github.com/wekan/omi.git
cd omi
```

2. Run Tcl CLI:

```bash
tclsh omi.tcl init
tclsh omi.tcl add --all
tclsh omi.tcl commit -m "Initial"
```

## Configuration

Create `settings.txt`:

```ini
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

- **USE_INTERNAL_HTTP=1** (default)
  - Uses Tcl `http` package for push/pull
  - No external curl required
  - Recommended on systems with Tcl `http`

- **USE_INTERNAL_HTTP=0**
  - Always uses external `curl`
  - Useful when Tcl `http` is limited or blocked

### SHA256 Handling

- **Preferred:** Tcllib `sha2` package (`package require sha2`)
- **Fallback:** `sha256sum` or `openssl dgst -sha256` if Tcllib is missing

## Quick Reference

| Command | Description |
|---------|-------------|
| `omi.tcl init` | Initialize new repository |
| `omi.tcl add <file>` | Stage a single file |
| `omi.tcl add --all` | Stage all files |
| `omi.tcl commit -m "msg"` | Create a commit |
| `omi.tcl push` | Push to remote (OTP if enabled) |
| `omi.tcl pull` | Pull from remote (OTP if enabled) |
| `omi.tcl status` | Show staging status |
| `omi.tcl log` | Show commit history |
| `omi.tcl list` | List repositories |
| `omi.tcl clone <url>` | Clone repository (pull from URL) |

## 2FA / OTP

If OTP is enabled for the user in `phpusers.txt`, Omi prompts for a 6-digit code during push and pull.

```
Enter OTP code (6 digits): 123456
```

## Troubleshooting

### "No SHA256 implementation found"

Install Tcllib or a system tool:

```bash
# Tcllib
sudo apt-get install tcllib

# Or ensure sha256sum/openssl is available
sha256sum --version
openssl version
```

### "package require sqlite3" failed

Install Tcl SQLite bindings:

```bash
# Debian/Ubuntu
sudo apt-get install tcl sqlite3 tcl8.6 tcl8.6-dev

# Fedora
sudo dnf install tcl sqlite3 tcl-devel
```

### "Error: Failed to push"

- Check credentials in settings.txt
- Verify REPOS points to your server URL
- Check curl availability: `which curl`
- Try external mode: `USE_INTERNAL_HTTP=0`

## See Also

- **[README.md](README.md)** - Documentation index
- **[FEATURES.md](FEATURES.md)** - Feature overview
- **[CLI_PYTHON3.md](CLI_PYTHON3.md)** - CLI alternative (Python 3)
- **[CLI_HAXE5.md](CLI_HAXE5.md)** - CLI alternative (Haxe 5)
- **[CLI_CSHARP.md](CLI_CSHARP.md)** - CLI alternative (C# / Mono)
- **[CLI_C89.md](CLI_C89.md)** - CLI alternative (C89)
- **[CLI_BASH.md](CLI_BASH.md)** - CLI alternative (Bash)
- **[CLI_BAT.md](CLI_BAT.md)** - CLI alternative (FreeDOS)
- **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** - CLI alternative (Amiga)
- **[CLI_LUA.md](CLI_LUA.md)** - CLI alternative (Lua)
- **[WEB.md](WEB.md)** - Web interface
- **[SERVER_PHP.md](SERVER_PHP.md)** - Server setup
- **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** - Database design

## Notes

- Tcl implementation shares settings.txt with other CLIs
- Works on Windows, macOS, Linux, BSD, and Amiga ports with Tcl
- Internal HTTP mode is recommended when Tcl `http` works reliably
- For embedded systems, external curl may be simpler

---

**Last Updated:** February 10, 2026  
**Omi Version:** 1.0  
**CLI Version:** Tcl 8.5+
