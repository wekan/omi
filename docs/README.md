# Omi Documentation

> **Quick Navigation:** [FEATURES.md](FEATURES.md) | [CLI](#cli-documentation) | [WEB.md](WEB.md) | [SERVER_FREEPASCAL.md](SERVER_FREEPASCAL.md) | [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)

## Getting Started

Omi is a lightweight Git-like version control system for retro systems and modern platforms.

**New users:** Start with [FEATURES.md](FEATURES.md) for an overview of what's possible.

## Documentation Files

| Document | Purpose | Audience |
|----------|---------|----------|
| **[FEATURES.md](FEATURES.md)** | Feature overview and capabilities | Everyone |
| **[CLI_PYTHON3.md](CLI_PYTHON3.md)** | Command line for Python 3 (recommended) | Python developers |
| **[CLI_HAXE5.md](CLI_HAXE5.md)** | Command line for Haxe 5 (typed, compiled) | Haxe developers |
| **[CLI_CSHARP.md](CLI_CSHARP.md)** | Command line for C# / Mono (compiled) | .NET developers |
| **[CLI_C89.md](CLI_C89.md)** | Command line for C89 (portable C) | C developers |
| **[CLI_TCL.md](CLI_TCL.md)** | Command line for Tcl (tclsh) | Tcl developers |
| **[CLI_BASH.md](CLI_BASH.md)** | Command line for Linux/Unix/macOS | Bash users |
| **[CLI_BAT.md](CLI_BAT.md)** | Command line for FreeDOS/Windows CMD | DOS users |
| **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** | Command line for Commodore Amiga | Amiga users |
| **[CLI_LUA.md](CLI_LUA.md)** | Command line for Lua (cross-platform) | Lua developers |
| **[WEB.md](WEB.md)** | Web interface and browser access | Web users |
| **[SERVER_JS.md](SERVER_JS.md)** | Web server (JavaScript runtimes) | Node.js/Bun/Deno developers |
| **[SERVER_FREEPASCAL.md](SERVER_FREEPASCAL.md)** | Web server (FreePascal compiled) | System admins |
| **[SERVER_PHP.md](SERVER_PHP.md)** | Web server (PHP with Apache/Nginx) | PHP/web admins |
| **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** | Database structure and design | Developers |

## CLI Documentation

Choose the CLI guide for your platform:

- **Python 3 (Recommended):** [CLI_PYTHON3.md](CLI_PYTHON3.md)
  - Pure Python, no external dependencies
  - Works on Windows, macOS, Linux
  - Ideal for automation and CI/CD

- **Haxe 5 (Multi-target Compiled):** [CLI_HAXE5.md](CLI_HAXE5.md)
  - Typed language with compile-time safety
  - Compiles to native binary, Python, JavaScript, C#
  - High performance and cross-platform

- **C# / Mono (Compiled):** [CLI_CSHARP.md](CLI_CSHARP.md)
  - .NET language with full type system
  - Compiles to IL bytecode with JIT
  - Works on Linux, macOS, Windows, FreeBSD

- **C89 (Portable C):** [CLI_C89.md](CLI_C89.md)
  - C89 compatible for classic compilers
  - Builds on AmigaOS, Windows, macOS, BSD, Linux
  - Optional internal HTTP via libcurl

- **Tcl (tclsh):** [CLI_TCL.md](CLI_TCL.md)
  - Tcl 8.5+ with sqlite3 and http packages
  - Internal HTTP via Tcl http, curl fallback
  - Works on Unix, Windows, macOS, BSD

- **Bash (Linux/macOS/Unix):** [CLI_BASH.md](CLI_BASH.md)
  - Installation, commands, usage examples
  - 2FA support, rate limiting
  - Troubleshooting

- **FreeDOS (DOS/Windows CMD):** [CLI_BAT.md](CLI_BAT.md)
  - Batch script syntax
  - Commands translated to DOS
  - Specific requirements and limitations

- **AmigaShell (Commodore Amiga):** [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)
  - AmigaShell syntax
  - AmiSSL HTTPS support
  - Memory and hardware considerations

- **Lua (Cross-platform):** [CLI_LUA.md](CLI_LUA.md)
  - Lua 5.1+ required
  - Works on any platform with Lua
  - Development and embedded systems

## Key Features

- **Git-like interface** - init, add, commit, push, pull, log, status
- **SQLite storage** - Efficient database-based repositories
- **SHA256 deduplication** - Content-addressed storage reduces disk usage
- **2FA/TOTP** - RFC 6238 compatible authentication
- **Brute force protection** - Account lockout after failed attempts
- **API rate limiting** - Per-user request limits
- **HTML 3.2 compatible** - Works with retro browsers
- **Multi-platform** - Bash, FreeDOS, AmigaShell, C89, Tcl, web interface

See [FEATURES.md](FEATURES.md) for complete feature list.

## Installation Quick Reference

### Bash (Linux/macOS)
```bash
git clone https://github.com/wekan/omi.git
cd omi
./omi.sh init
./omi.sh add --all
./omi.sh commit -m "Initial"
./omi.sh push
```

### FreeDOS
```batch
REM Download omi.bat
omi init
omi add --all
omi commit -m "Initial"
omi push
```

### AmigaShell
```
COPY omi c:omi
omi init
omi add --all
omi commit -m "Initial"
omi push
```

### Web Interface
1. Copy `public/index.php` to web root
2. Configure `settings.txt`
3. Visit `http://localhost/`

See [CLI_BASH.md](CLI_BASH.md), [CLI_BAT.md](CLI_BAT.md), [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md), or [WEB.md](WEB.md) for detailed setup.

## Configuration Files

Located in project root:

- **settings.txt** - Server, authentication, API settings
- **phpusers.txt** - User credentials format: `username:password:otpauth_url`
- **phpusersbruteforcelocked.txt** - Locked accounts
- **phpusersfailedattempts.txt** - Failed login attempts
- **api_rate_limit.txt** - API request tracking

## Server Deployment

Choose your server implementation:

**Option 1: FreePascal Server (Recommended for retro systems)**
- Single compiled binary, minimal dependencies
- See [SERVER_FREEPASCAL.md](SERVER_FREEPASCAL.md) for setup

**Option 2: JavaScript Server (Node.js, Bun, or Deno)**
- Multi-runtime support, modern tooling
- See [SERVER_JS.md](SERVER_JS.md) for setup

**Option 3: PHP Server (Apache, Nginx, or Caddy)**
- Traditional web server deployment
- See [SERVER_PHP.md](SERVER_PHP.md) for setup

Configuration examples in [webserver/](webserver/) directory:
- **Caddyfile** - Caddy (recommended)
- **apache.conf** - Apache
- **nginx.conf** - Nginx

## Code Files

Project files:

- **omi.sh** (~320 lines) - Bash implementation
- **omi.bat** (~240 lines) - FreeDOS implementation
- **omi** (~210 lines) - AmigaShell implementation
- **omi.c** (~500 lines) - C89 implementation
- **omi.tcl** (~350 lines) - Tcl implementation
- **public/server.js** (~800 lines) - JavaScript web server (Node.js, Bun, Deno)
- **public/index.php** (~1530 lines) - Web interface
- **repos/** - Directory for repository files
- Database files: `*.omi` (SQLite format)

## Platform Support

| Platform | CLI Implementation | Web Access |
|----------|-------------------|----------|
| Linux | [CLI_PYTHON3.md](CLI_PYTHON3.md) ✅ [CLI_HAXE5.md](CLI_HAXE5.md) ✅ [CLI_CSHARP.md](CLI_CSHARP.md) ✅ [CLI_C89.md](CLI_C89.md) ✅ [CLI_TCL.md](CLI_TCL.md) ✅ [CLI_BASH.md](CLI_BASH.md) ✅ [CLI_LUA.md](CLI_LUA.md) ✅ | Yes |
| macOS | [CLI_PYTHON3.md](CLI_PYTHON3.md) ✅ [CLI_HAXE5.md](CLI_HAXE5.md) ✅ [CLI_CSHARP.md](CLI_CSHARP.md) ✅ [CLI_C89.md](CLI_C89.md) ✅ [CLI_TCL.md](CLI_TCL.md) ✅ [CLI_BASH.md](CLI_BASH.md) ✅ [CLI_LUA.md](CLI_LUA.md) ✅ | Yes |
| Windows | [CLI_PYTHON3.md](CLI_PYTHON3.md) ✅ [CLI_HAXE5.md](CLI_HAXE5.md) ✅ [CLI_CSHARP.md](CLI_CSHARP.md) ✅ [CLI_C89.md](CLI_C89.md) ✅ [CLI_TCL.md](CLI_TCL.md) ✅ [CLI_BASH.md](CLI_BASH.md) via WSL | Yes |
| FreeDOS | [CLI_BAT.md](CLI_BAT.md) ✅ | Yes (with Dillo) |
| Commodore Amiga | [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md) ✅ | Yes (with IBrowse) |
| Generic Unix | [CLI_PYTHON3.md](CLI_PYTHON3.md) ✅ [CLI_HAXE5.md](CLI_HAXE5.md) ✅ [CLI_CSHARP.md](CLI_CSHARP.md) ✅ [CLI_C89.md](CLI_C89.md) ✅ [CLI_BASH.md](CLI_BASH.md) ✅ [CLI_LUA.md](CLI_LUA.md) ✅ | Yes |
| Python Environments | [CLI_PYTHON3.md](CLI_PYTHON3.md) ✅ | Yes |
| Haxe Projects | [CLI_HAXE5.md](CLI_HAXE5.md) ✅ | Yes |
| .NET Projects | [CLI_CSHARP.md](CLI_CSHARP.md) ✅ | Yes |
| C Projects | [CLI_C89.md](CLI_C89.md) ✅ | Yes |
| Tcl Environments | [CLI_TCL.md](CLI_TCL.md) ✅ | Yes |
| Lua Environments | [CLI_LUA.md](CLI_LUA.md) ✅ | Yes (if web access available) |

## Common Workflows

### CLI Workflow
```bash
./omi.sh init                 # Create repository
./omi.sh add --all            # Stage files
./omi.sh commit -m "message"  # Create commit
./omi.sh push                 # Upload to server
./omi.sh pull                 # Download from server
./omi.sh log                  # View history
```

### Web Workflow
1. Visit `/` - Browse repositories
2. Click repo name - Browse contents
3. Click file - View content (text, image, markdown, SVG, audio, video)
4. Click `[Edit]` - Edit text file (creates commit)
5. Click `[Download]` - Download file to computer
6. Click `[Delete]` - Remove file (creates "Deleted" commit)
7. Click `[Upload]` - Add new file to repository

### Server Workflow
1. Choose server: [SERVER_FREEPASCAL.md](SERVER_FREEPASCAL.md) | [SERVER_JS.md](SERVER_JS.md) | [SERVER_PHP.md](SERVER_PHP.md)
2. Configure [settings.txt](../settings.txt)
3. Create users in [users.txt](../users.txt)
4. Users can push/pull via CLI
5. Browse via web interface

## Security

**Features:**
- 2FA/TOTP authentication
- Brute force protection
- API rate limiting
- Directory traversal prevention
- Session-based web access

See [FEATURES.md](FEATURES.md) for complete security information.

## Troubleshooting

### For CLI Issues
- **Bash:** [CLI_BASH.md](CLI_BASH.md#troubleshooting)
- **FreeDOS:** [CLI_BAT.md](CLI_BAT.md#troubleshooting)
- **AmigaShell:** [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md#troubleshooting)

### For Web Issues
- [WEB.md](WEB.md#troubleshooting)

### For Server Issues
- **FreePascal:** [SERVER_FREEPASCAL.md](SERVER_FREEPASCAL.md#troubleshooting)
- **JavaScript:** [SERVER_JS.md](SERVER_JS.md#troubleshooting)
- **PHP:** [SERVER_PHP.md](SERVER_PHP.md#troubleshooting)

### For Database Issues
- [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)

## Additional Resources

- **GitHub:** https://github.com/wekan/omi
- **Project Root:** [../](../)
- **Web Server Configs:** [webserver/](webserver/)

## Document Index

| File | Size | Purpose |
|------|------|----------|
| FEATURES.md | Brief | What can you do with Omi |
| CLI_PYTHON3.md | Detailed | Python 3 CLI guide (recommended) |
| CLI_HAXE5.md | Detailed | Haxe 5 CLI guide (compiled, multi-target) |
| CLI_CSHARP.md | Detailed | C# / Mono CLI guide (compiled) |
| CLI_C89.md | Detailed | C89 CLI guide (portable C) |
| CLI_TCL.md | Detailed | Tcl CLI guide (tclsh) |
| CLI_BASH.md | Detailed | Linux/Unix CLI guide |
| CLI_BAT.md | Detailed | DOS/Windows CLI guide |
| CLI_AMIGASHELL.md | Detailed | Amiga CLI guide |
| CLI_LUA.md | Detailed | Lua CLI guide (cross-platform) |
| WEB.md | Detailed | Web interface guide |
| SERVER_JS.md | Detailed | JavaScript server guide (Node.js/Bun/Deno) |
| SERVER_FREEPASCAL.md | Detailed | FreePascal server guide (compiled) |
| SERVER_PHP.md | Detailed | PHP server guide (Apache/Nginx) |
| DATABASE_SCHEMA.md | Reference | Database technical details |
| README.md | Navigation | This file |

---

**Last Updated:** February 10, 2026  
**Omi Version:** 1.0
