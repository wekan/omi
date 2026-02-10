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

Complete documentation is available in the `docs/` directory:

- **[QUICK_START.md](docs/QUICK_START.md)** - Getting started guide
- **[COMPLETE_GUIDE.md](docs/COMPLETE_GUIDE.md)** - Full feature documentation
- **[WEB_INTERFACE.md](docs/WEB_INTERFACE.md)** - Web UI features
- **[CLI_GUIDE.md](docs/CLI_GUIDE.md)** - Command-line interface reference
- **[DATABASE_SCHEMA.md](docs/DATABASE_SCHEMA.md)** - Database structure
- **[webserver/](docs/webserver/)** - Server configuration files
  - `Caddyfile` - Caddy server config
  - `apache.conf` - Apache VirtualHost config
  - `nginx.conf` - Nginx server block config

## Configuration

At settings.txt and phpusers.txt .

## Directory Structure

```
/wekan/
├── omi              # AmigaShell script
├── omi.bat          # FreeDOS batch script
├── omi.sh           # Bash script
├── public/          # Web interface (PHP)
├── docs/            # Documentation
│   ├── webserver/   # Server configurations
│   ├── COMPLETE_GUIDE.md
│   ├── SERVER_SETUP.md
│   ├── QUICK_START.md
│   └── ...
├── repos/           # Repository storage (.omi files)
├── settings.txt     # Configuration
├── phpusers.txt     # User accounts
├── .htaccess        # Apache rewrite rules
└── README.md        # This file
```

## Setup Server

See [docs/webserver/](docs/webserver/) for configuration with:
- **Caddy** (recommended, simplest)
- **Apache** (with .htaccess or VirtualHost)
- **Nginx** (server block)

For detailed setup instructions, see [docs/SERVER_SETUP.md](docs/SERVER_SETUP.md).

## How It Works

1. **Add files** - Files are hashed with SHA256
2. **Commit** - Creates database records with deduplication
3. **Push/Pull** - Synchronize with server via CURL
4. **Web UI** - Browse, edit, and manage files
5. **Deduplication** - Identical files stored only once

## Browser Compatibility

| Browser    | Platform | Support        |
|------------|----------|-----------------|
| IBrowse    | Amiga    | Full (HTML 3.2) |
| Dillo      | FreeDOS  | Full (HTML 3.2) |
| Elinks     | Linux    | Full (text)     |
| w3m        | Linux    | Full (text)     |
| Modern browsers | All  | Full (HTML 5)   |

## Related Projects

- [Fossil SCM](https://fossil-scm.org/) - Original DVCS with SQLite
- [WeDOS](https://github.com/wekan/wedos) - Kanban board (FreeDOS + Bash)

## License

Omi is a lightweight alternative to Fossil SCM for cross-platform version control.
