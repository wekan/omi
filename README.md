## Omi - Optimized Micro Index Version Control

**Omi** is a lightweight, cross-platform version control system that stores complete repository history in a single SQLite database file (.omi).

### Platforms Supported
- **AmigaShell** (Amiga systems)
- **FreeDOS** (.bat scripts)  
- **Linux/Unix/macOS** (Bash)
- **Lua 5.1+** (Cross-platform scripting language)
- **Python 3.6+** (Pure Python, no dependencies)
- **Haxe 5.0+** (Multi-target compiled language)
- **C# / Mono** (Compiled CLI with .NET compatibility)
- **Web Browser** (PHP interface - HTML 3.2 compatible)

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
- **[CLI_BASH.md](docs/CLI_BASH.md)** - CLI for Linux/Unix/macOS
- **[CLI_BAT.md](docs/CLI_BAT.md)** - CLI for FreeDOS/Windows
- **[CLI_AMIGASHELL.md](docs/CLI_AMIGASHELL.md)** - CLI for Amiga
- **[CLI_LUA.md](docs/CLI_LUA.md)** - CLI for Lua (cross-platform)
- **[WEB.md](docs/WEB.md)** - Web interface guide
- **[SERVER.md](docs/SERVER.md)** - Server setup
- **[DATABASE_SCHEMA.md](docs/DATABASE_SCHEMA.md)** - Database design

## Setup

Copy `public/index.php` to your web server root. Configure `settings.txt` and `phpusers.txt` as needed.

See **[`docs/SERVER.md`](docs/SERVER.md)** for detailed server setup instructions.



## Related Projects

- [Fossil SCM](https://fossil-scm.org/) - Original DVCS with SQLite
- [WeDOS](https://github.com/wekan/wedos) - Kanban board (FreeDOS + Bash)

## License

Omi is a lightweight alternative to Fossil SCM for cross-platform version control.
