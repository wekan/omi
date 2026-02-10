## Omi - Optimized Micro Index Version Control

**Omi** is a lightweight, cross-platform version control system that stores complete repository history in a single SQLite database file (.omi).

### Platforms Supported
- **AmigaShell** (Amiga systems) - [cli/omi.amigashell](cli/omi.amigashell)
- **FreeDOS** (.bat scripts) - [cli/omi.bat](cli/omi.bat)
- **Linux/Unix/macOS** (Bash) - [cli/omi.sh](cli/omi.sh)
- **Lua 5.1+** (Cross-platform scripting language) - [cli/omi.lua](cli/omi.lua)
- **Python 3.6+** (Pure Python, no dependencies) - [cli/omi.py](cli/omi.py)
- **Haxe 5.0+** (Multi-target compiled language) - [cli/omi.hx](cli/omi.hx)
- **C# / Mono** (Compiled CLI with .NET compatibility) - [cli/omi.cs](cli/omi.cs)
- **C89** (Portable C implementation for classic/modern systems) - [cli/omi.c](cli/omi.c)
- **Tcl 8.5+** (Tclsh scripting language) - [cli/omi.tcl](cli/omi.tcl)
- **Web Browser** (PHP interface - HTML 3.2 compatible)
- **Web Browser** (JavaScript/Node.js/Bun/Deno server)

### Features
✅ Git-like commands (`init`, `clone`, `add`, `commit`, `push`, `pull`)
✅ File deduplication via SHA256 hashing
✅ SQLite-based storage
✅ Cross-platform CLI and web UI
✅ Web-based file management (upload, download, edit, delete)
✅ Markdown rendering and SVG viewing
✅ Audio/video player support
✅ User account management with 2FA/TOTP
✅ Brute force protection and API rate limiting
✅ HTML 3.2 compatible (works with IBrowse, Dillo, Elinks, w3m)

## Quick Start

### CLI (Bash)
```bash
cd omi/cli
./omi.sh init               # Initialize repository
./omi.sh add --all         # Stage files
./omi.sh commit -m "msg"   # Create commit
./omi.sh push              # Upload to server
./omi.sh pull              # Download from server
./omi.sh list              # Show available repos
```

### Web UI
- **Home**: `http://omi.wekan.fi/`
- **Sign In**: `/sign-in`
- **Create Account**: `/sign-up`
- **Browse Repo**: `/reponame`
- **Manage Users**: `/people` (login required)
- **Settings**: `/settings` (login required)

## Documentation

**Full documentation is in the [`docs/`](docs/) directory:**

Start with **[`docs/README.md`](docs/README.md)** for navigation and quick reference.

Key guides:
- **[FEATURES.md](docs/FEATURES.md)** - Complete feature overview
- **[CLI_PYTHON3.md](docs/CLI_PYTHON3.md)** - CLI for Python 3 (recommended)
- **[CLI_HAXE5.md](docs/CLI_HAXE5.md)** - CLI for Haxe 5 (compiled, multi-target)
- **[CLI_CSHARP.md](docs/CLI_CSHARP.md)** - CLI for C# / Mono (compiled, .NET)
- **[CLI_C89.md](docs/CLI_C89.md)** - CLI for C89 (portable C implementation)
- **[CLI_TCL.md](docs/CLI_TCL.md)** - CLI for Tcl (tclsh)
- **[CLI_BASH.md](docs/CLI_BASH.md)** - CLI for Linux/Unix/macOS
- **[CLI_BAT.md](docs/CLI_BAT.md)** - CLI for FreeDOS/Windows
- **[CLI_AMIGASHELL.md](docs/CLI_AMIGASHELL.md)** - CLI for Amiga
- **[CLI_LUA.md](docs/CLI_LUA.md)** - CLI for Lua (cross-platform)
- **[WEB.md](docs/WEB.md)** - Web interface guide
- **[SERVER_JS.md](docs/SERVER_JS.md)** - JavaScript server (Node.js, Bun, Deno)
- **[SERVER_PHP.md](docs/SERVER_PHP.md)** - PHP server setup
- **[DATABASE_SCHEMA.md](docs/DATABASE_SCHEMA.md)** - Database design

## Setup

Copy `public/index.php` to your web server root. Configure `settings.txt` and `users.txt` as needed.

See **[`docs/SERVER_PHP.md`](docs/SERVER_PHP.md)** for detailed server setup instructions.

## Build Scripts
Use the build menu scripts in the `cli/` directory to compile/transpile Omi to multiple targets. Each script writes outputs to `cli/build/<target>/`.

- **[cli/build.sh](cli/build.sh)** - Unix/Linux/macOS build menu
- **[cli/build.bat](cli/build.bat)** - Windows CMD build menu
- **[cli/build.amigashell](cli/build.amigashell)** - AmigaShell build menu
- **[cli/build.lua](cli/build.lua)** - Lua build menu
- **[cli/build.py](cli/build.py)** - Python build menu

Examples:

```bash
cd cli
./build.sh
python3 build.py
lua build.lua
```



## Related Projects

- [Fossil SCM](https://fossil-scm.org/) - Original DVCS with SQLite
- [WeDOS](https://github.com/wekan/wedos) - Kanban board (FreeDOS + Bash)

## License

Omi is a lightweight alternative to Fossil SCM for cross-platform version control.
