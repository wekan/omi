# Omi Documentation

> **Quick Navigation:** [FEATURES.md](FEATURES.md) | [CLI](#cli-documentation) | [WEB.md](WEB.md) | [SERVER.md](SERVER.md) | [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)

## Getting Started

Omi is a lightweight Git-like version control system for retro systems and modern platforms.

**New users:** Start with [FEATURES.md](FEATURES.md) for an overview of what's possible.

## Documentation Files

| Document | Purpose | Audience |
|----------|---------|----------|
| **[FEATURES.md](FEATURES.md)** | Feature overview and capabilities | Everyone |
| **[CLI_BASH.md](CLI_BASH.md)** | Command line for Linux/Unix/macOS | Bash users |
| **[CLI_BAT.md](CLI_BAT.md)** | Command line for FreeDOS/Windows CMD | DOS users |
| **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** | Command line for Commodore Amiga | Amiga users |
| **[WEB.md](WEB.md)** | Web interface and browser access | Web users |
| **[SERVER.md](SERVER.md)** | Server setup and configuration | System admins |
| **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** | Database structure and design | Developers |

## CLI Documentation

Choose the CLI guide for your platform:

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

## Key Features

- **Git-like interface** - init, add, commit, push, pull, log, status
- **SQLite storage** - Efficient database-based repositories
- **SHA256 deduplication** - Content-addressed storage reduces disk usage
- **2FA/TOTP** - RFC 6238 compatible authentication
- **Brute force protection** - Account lockout after failed attempts
- **API rate limiting** - Per-user request limits
- **HTML 3.2 compatible** - Works with retro browsers
- **Multi-platform** - Bash, FreeDOS, AmigaShell, web interface

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

To run Omi on a web server:

1. Configure [settings.txt](../settings.txt)
2. Place [public/index.php](../public/index.php) on web server
3. Choose web server: Caddy, Apache, or Nginx
4. See [SERVER.md](SERVER.md) for detailed setup

Configuration examples in [webserver/](webserver/) directory:
- **Caddyfile** - Caddy (recommended)
- **apache.conf** - Apache
- **nginx.conf** - Nginx

## Code Files

Project files:

- **omi.sh** (~320 lines) - Bash implementation
- **omi.bat** (~240 lines) - FreeDOS implementation
- **omi** (~210 lines) - AmigaShell implementation
- **public/index.php** (~1530 lines) - Web interface
- **repos/** - Directory for repository files
- Database files: `*.omi` (SQLite format)

## Platform Support

| Platform | CLI Implementation | Web Access |
|----------|-------------------|----------|
| Linux | [CLI_BASH.md](CLI_BASH.md) ✅ | Yes |
| macOS | [CLI_BASH.md](CLI_BASH.md) ✅ | Yes |
| FreeDOS | [CLI_BAT.md](CLI_BAT.md) ✅ | Yes (with Dillo) |
| Commodore Amiga | [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md) ✅ | Yes (with IBrowse) |
| Windows | [CLI_BASH.md](CLI_BASH.md) or WSL | Yes |
| Generic Unix | [CLI_BASH.md](CLI_BASH.md) ✅ | Yes |

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
3. Click file - View content
4. Click `[Edit]` - Edit text file
5. Click `Save` - Create commit

### Server Workflow
1. Set up [SERVER.md](SERVER.md)
2. Configure [settings.txt](../settings.txt)
3. Create users in [phpusers.txt](../phpusers.txt)
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
- [SERVER.md](SERVER.md)

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
| CLI_BASH.md | Detailed | Linux/Unix CLI guide |
| CLI_BAT.md | Detailed | DOS/Windows CLI guide |
| CLI_AMIGASHELL.md | Detailed | Amiga CLI guide |
| WEB.md | Detailed | Web interface guide |
| SERVER.md | Detailed | Server setup guide |
| DATABASE_SCHEMA.md | Reference | Database technical details |
| README.md | Navigation | This file |

---

**Last Updated:** February 10, 2026  
**Omi Version:** 1.0
