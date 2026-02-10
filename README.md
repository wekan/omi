## Omi - Optimized Micro Index Version Control

**Omi** is a lightweight, cross-platform version control system that stores complete repository history in a single SQLite database file (.omi).

### Platforms Supported
- **AmigaShell** (Amiga systems)
- **FreeDOS** (.bat scripts)  
- **Linux/Unix** (Bash)
- **Web Browser** (PHP interface - HTML 3.2 compatible)

### Features
✅ Git-like commands (`init`, `clone`, `add`, `commit`, `push`, `pull`)
✅ File deduplication via SHA256 hashing
✅ SQLite-based storage
✅ Cross-platform CLI and web UI
✅ Web-based file editing and image viewing
✅ User account management
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
- **[CLI_BASH.md](docs/CLI_BASH.md)** - CLI for Linux/Unix/macOS
- **[CLI_BAT.md](docs/CLI_BAT.md)** - CLI for FreeDOS/Windows
- **[CLI_AMIGASHELL.md](docs/CLI_AMIGASHELL.md)** - CLI for Amiga
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
