# Omi Server - FreePascal Implementation

> **Documentation Index:** See [README.md](README.md) for documentation overview  
> **Quick Start:** See [README.md](README.md#web-interface) for web interface guide

## Overview

This guide covers setting up Omi's web server using the FreePascal standalone compiled implementation. The FreePascal server provides a feature-complete, lightweight HTTP server with SQLite backend storage.

**Key Advantage:** Single compiled executable with no external dependencies (except SQLite). Ideal for retro systems and minimal deployments.

## Requirements

### FreePascal Compiler
- **FreePascal 3.0+** (recommended: 3.2+)
- Available for Linux, macOS, Windows, FreeBSD, AmigaOS, and other platforms

### Required Units
The FreePascal server uses standard library units:
- `fphttpapp` - HTTP application framework
- `HTTPDefs`, `httproute` - HTTP routing
- `fpjson`, `jsonparser` - JSON handling
- `SysUtils`, `Classes`, `StrUtils`, `Math` - Standard utilities
- `Process` - External process handling
- `inifiles` - Configuration file parsing

### SQLite Database
- SQLite3 library (available on most systems)
- Used via external `sqlite3` command-line tool
- Or compiled SQLite library binding (alternative)

## Installation

### Install FreePascal Compiler

**Linux/Unix:**
```bash
# Debian/Ubuntu
sudo apt install fp-compiler libfpc3.0

# Fedora
sudo dnf install fpc

# macOS
brew install fpc

# Generic
Download from https://www.freepascal.org/download.html
```

**Windows:**
```cmd
# Download from https://www.freepascal.org/download.html
# Run installer
fpc-3.2.2.exe
```

**AmigaOS:**
```
# Download from Aminet or AmiCygnix
# Follow included installation instructions
```

### Verify Installation
```bash
fpc -v            # Show version
fpc -h | head     # Show help
```

## Building the Server

### Compile FreePascal Server

**Basic Compilation:**
```bash
cd /path/to/wekan
fpc -o public/server public/server.pas
```

**Optimized Build (Release):**
```bash
fpc -O3 -o public/server public/server.pas
```

**With Debug Info:**
```bash
fpc -g -o public/server public/server.pas
```

**Production Build (Optimized + Stripped):**
```bash
fpc -O3 -Xs -o public/server public/server.pas
# Strip debug symbols (Unix only)
strip public/server
```

### Build Output

After successful compilation:
```
Free Pascal Compiler version 3.2.0
Copyright (c) 1993-2021 by Florian Klaempfl and others
Target OS: Linux for x86-64
Compiling public/server.pas
Linking public/server
21 lines compiled, 0.1 sec
```

The compiled executable is ready to run: `public/server`

## Running the Server

### Start Server

**Basic Run:**
```bash
./public/server
```

**With Custom Configuration:**
```bash
# Server auto-loads settings.txt from parent directory
# Configure settings.txt before running
./public/server
```

**Background/Daemonized:**
```bash
nohup ./public/server > server.log 2>&1 &
# Or with screen/tmux
tmux new-session -d -s omi './public/server'
```

### Verify Server is Running

```bash
# Test locally (another terminal)
curl http://localhost:3001/

# Or with wget
wget http://localhost:3001/ -O -

# Check port is listening
netstat -tuln | grep 3001
ss -tuln | grep 3001              # Modern Linux
```

### Server Output

Upon startup, server logs:
```
Omi Server v1.0.0 starting...
WARNING: settings.txt not found, using defaults
Default admin credentials:
  Username: admin
  Password: password
Listening on port 3001...
Press Ctrl+C to stop
```

## Configuration

### settings.txt

Located in project root (parent directory of public/). Controls server behavior:

```cfg
SQLITE=/usr/bin/sqlite3
USERNAME=admin
PASSWORD=password
REPOS=http://localhost:3001
CURL=/usr/bin/curl
API_ENABLED=1
API_RATE_LIMIT=60
API_RATE_LIMIT_WINDOW=60
ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURES_BEFORE=3
ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURE_WINDOW=15
ACCOUNTS_LOCKOUT_KNOWN_USERS_PERIOD=60
ACCOUNTS_LOCKOUT_UNKNOWN_USERS_FAILURES_BEFORE=3
ACCOUNTS_LOCKOUT_UNKNOWN_USERS_FAILURE_WINDOW=15
ACCOUNTS_LOCKOUT_UNKNOWN_USERS_LOCKOUT_PERIOD=60
```

**Parameters:**
- **SQLITE** - Path to sqlite3 executable
- **USERNAME** - Default username for CLI
- **PASSWORD** - Default password for CLI
- **REPOS** - Server root URL (used by CLI for push/pull)
- **CURL** - Path to curl executable (optional, for integration)
- **API_ENABLED** - Enable/disable API (1 or 0)
- **API_RATE_LIMIT** - Max requests per window
- **API_RATE_LIMIT_WINDOW** - Time window in seconds
- **ACCOUNTS_LOCKOUT_*** - Brute force protection settings

### Default Configuration
If settings.txt is not found, server uses defaults:
- **Port:** 3001
- **SQLite:** `sqlite3` (system PATH)
- **Admin:** `admin:password`
- **Repos:** `http://localhost:3001`

**Creating/Editing settings.txt:**
```cfg
SQLITE=/usr/bin/sqlite3
USERNAME=admin
PASSWORD=mySecurePassword123
REPOS=http://myserver.com:3001
CURL=/usr/bin/curl
API_ENABLED=1
API_RATE_LIMIT=60
API_RATE_LIMIT_WINDOW=60
ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURES_BEFORE=3
ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURE_WINDOW=15
ACCOUNTS_LOCKOUT_KNOWN_USERS_PERIOD=60
```

### User Management

Users are stored in `users.txt` with format: `username:password:otpauth_url:language`

**Manual Format:**
```
admin:password123:otpauth://totp/Omi/admin?secret=BASE32SECRET&issuer=Omi:en
user1:password456::en
```

**Fields:**
- **username** - Login name
- **password** - Password (plaintext in file, sent over HTTPS in production)
- **otpauth_url** - RFC 6238 OTP secret (empty if 2FA disabled)
- **language** - UI language code (en, de, fr, etc.)

**Creating via Web:**
1. Access `/people` (requires login)
2. Click "Add New User"
3. Enter username and password
4. Click "Add User"

**2FA Setup:**
- Users can enable TOTP in their account settings
- Generates RFC 6238 compatible secret
- QR code provided for authenticator apps

### Other Configuration Files

- **users.txt** - User accounts (created/edited via web)
- **usersbruteforcelocked.txt** - Locked accounts (auto-managed)
- **api_rate_limit.txt** - API request tracking (auto-managed)

## Port Configuration

By default, FreePascal server listens on **port 3001**.

### Change Default Port

**Option 1: Edit source before compilation**
```pascal
// In public/server.pas, find:
const
  DEFAULT_PORT = 3001;

// Change to:
const
  DEFAULT_PORT = 8080;

// Then recompile:
fpc -o public/server public/server.pas
```

**Option 2: Use reverse proxy**
Configure Nginx/Caddy to forward to port 3001:

**Nginx example:**
```nginx
upstream omi_server {
    server localhost:3001;
}

server {
    listen 80;
    server_name myserver.com;

    location / {
        proxy_pass http://omi_server;
    }
}
```

## Web Server Routing

Unlike PHP (which needs Apache/Nginx) or JavaScript (which needs Node/Bun/Deno), the FreePascal server is **self-hosting** - it's a complete web server in one binary.

### Direct Access (No Reverse Proxy)
```bash
# Access directly on port 3001
http://localhost:3001/
http://localhost:3001/wekan
http://localhost:3001/wekan/src
```

### With Reverse Proxy (Recommended for Production)
Use **Caddy**, **Nginx**, or **Apache** as a reverse proxy to:
- Add HTTPS/TLS support
- Handle SSL certificates
- Load balance multiple instances
- Add additional security headers

**Caddy Reverse Proxy Example:**
```
example.com {
    reverse_proxy localhost:3001
}
```

## Features

✅ User authentication with session management
✅ Repository browsing and file management  
✅ File upload, edit, delete, rename operations
✅ Markdown rendering with basic formatting
✅ Image display (JPEG, PNG, GIF, BMP, WebP)
✅ Translation system support (1,723 i18n keys)
✅ SQLite database backend
✅ OTP/2FA support ready
✅ HTML 3.2 compatible (retro browsers)
✅ API with rate limiting
✅ Brute force protection
✅ Works on Unix, macOS, Windows, FreeBSD, AmigaOS

## Quick Reference

### Web Routes
| Route | Method | Description |
|-------|--------|-------------|
| `/` | GET | Repository list |
| `/sign-in` | GET/POST | User authentication |
| `/sign-up` | GET/POST | User registration |
| `/logout` | GET | End session |
| `/settings` | GET/POST | Server settings (auth required) |
| `/people` | GET/POST | User management (auth required) |
| `/{repo}` | GET | Browse repository |
| `/?format=json` | GET | List repos as JSON |
| `/?download={repo}.omi` | GET | Download repository |

### API Authentication

All API requests require:
- HTTP POST with `username`, `password`, and optional `otp_code`
- Returns JSON responses with status and rate limit headers

## HTML 3.2 Compatibility

The web interface uses HTML 3.2 with no JavaScript or CSS for compatibility with retro browsers:

**Test Environments:**
- **IBrowse with AmiSSL** - Commodore Amiga
- **Dillo** - FreeDOS/old Linux
- **Elinks** - Linux text mode
- **w3m** - Linux text mode
- **Lynx** - Old Unix/retro systems

**Design Features:**
- Table-based layout (no CSS)
- Simple form inputs (no JavaScript)
- Works with text-only browsers
- Minimal bandwidth usage

## Character Encoding

**Current Status:** UTF-8 support with known issues

**Known Issue:** Scandinavian characters (å, ä, ö) may not display correctly in some cases. This is a documented limitation that requires:
1. Enhanced Unicode normalization
2. Platform-specific character handling
3. Browser-level encoding negotiation

**Workaround:** Use ASCII-compatible filenames and content when possible.

**Future Fix:** Will be addressed in upcoming updates with improved UTF-8 handling.

## Security Considerations

### HTTPS/TLS
- FreePascal server runs on HTTP only (no built-in HTTPS)
- Use reverse proxy (Caddy/Nginx/Apache) for HTTPS in production
- Caddy provides automatic Let's Encrypt certificates

**Caddy Reverse Proxy with HTTPS:**
```
example.com {
    reverse_proxy localhost:3001
}
```

### File Permissions
```bash
# Repository directory readable/writable
chmod 755 repos/
chmod 644 repos/*.omi

# Configuration files readable
chmod 644 settings.txt users.txt
```

### Credentials
- Change default credentials in settings.txt
- Use strong passwords (15+ chars recommended)
- Enable 2FA for important accounts

### Access Control
- Only authenticated users can edit files
- Settings page requires login
- User management requires login

### API Security
- Brute force protection with configurable lockouts
- API rate limiting per user
- Rate limit headers returned:
  - `X-RateLimit-Limit`
  - `X-RateLimit-Remaining`
  - `X-RateLimit-Reset`

## Compilation Options

### Platform-Specific Compilation

**Linux 64-bit:**
```bash
fpc -Px86_64 -o public/server public/server.pas
```

**macOS (Intel):**
```bash
fpc -Px86_64 -o public/server public/server.pas
```

**macOS (Apple Silicon/ARM64):**
```bash
fpc -Paarch64 -o public/server public/server.pas
```

**Windows 32-bit:**
```bash
fpc -Pi386 -o public/server.exe public/server.pas
```

**Windows 64-bit:**
```bash
fpc -Px86_64 -o public/server.exe public/server.pas
```

**FreeBSD:**
```bash
fpc -Px86_64 -o public/server public/server.pas
```

**AmigaOS (m68k):**
```bash
fpc -Pm68k -Tamiga -o public/server public/server.pas
```

## Deployment Checklist

- [ ] Install FreePascal compiler
- [ ] Compile FreePascal server: `fpc -o public/server public/server.pas`
- [ ] Create/configure `settings.txt`
- [ ] Create `users.txt` with admin account
- [ ] Create `repos/` directory with proper permissions
- [ ] Test server: `./public/server`
- [ ] Verify local access: `curl http://localhost:3001/`
- [ ] Test sign-in: Go to `/sign-in`
- [ ] Test file operations (upload, edit, download)
- [ ] (Optional) Set up reverse proxy for HTTPS
- [ ] Configure firewall rules
- [ ] Enable auto-start (systemd/cron/etc.)

## Systemd Service (Linux)

Create `/etc/systemd/system/omi-server.service`:
```ini
[Unit]
Description=Omi Server (FreePascal)
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/path/to/wekan
ExecStart=/path/to/wekan/public/server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable omi-server
sudo systemctl start omi-server
sudo systemctl status omi-server
```

## Troubleshooting

### Compilation Fails
```
Error: Can't find unit fphttpapp
```
Solution: Install FreePascal development package with httpd components

**Linux:** `sudo apt install fp-units-http`  
**macOS:** `brew install fpc` (includes units)

### Server Won't Start
```
Error: Cannot find sqlite3 executable
```
Solution: Install SQLite or update SQLITE path in settings.txt

**Install SQLite:**
```bash
# Linux
sudo apt install sqlite3

# macOS
brew install sqlite

# Windows
Download from https://www.sqlite.org/download.html
```

### Port Already in Use
```
Error: Address already in use (port 3001)
```
Solution: Use different port (edit source and recompile) or kill existing process

```bash
# Find process using port 3001
netstat -tuln | grep 3001
ps aux | grep server
kill <PID>
```

### File Permissions Denied
```
Error: Permission denied when creating .omi files
```
Solution: Check repos/ directory permissions

```bash
chmod 755 repos/
chmod 644 settings.txt users.txt
```

### Authentication Issues
- Clear cookies if locked out
- Check users.txt format: `username:password:otpauth:language`
- Verify OTP secret format if 2FA enabled
- Check usersbruteforcelocked.txt for locked accounts

### SQLite Errors
```
Error: database disk image malformed
```
Solution: Check repository .omi files are valid SQLite databases

```bash
sqlite3 repos/myrepo.omi "PRAGMA integrity_check;"
```

## Performance

### Binary Size
Default FreePascal builds: ~8-15 MB (includes runtime)
Stripped/optimized: ~2-4 MB

### Memory Usage
- Typical idle: 5-10 MB
- Per connection: ~1-2 MB
- Session storage: ~100 bytes per session

### Concurrent Users
- Tested with 50+ concurrent users
- Message queue for processing uploads
- Efficient file streaming

## Differences from PHP/JavaScript Versions

| Feature | FreePascal | PHP | JavaScript |
|---------|-----------|-----|-----------|
| **Deployment** | Single binary | Needs web server | Needs Node/Bun |
| **Dependencies** | SQLite only | Apache/Nginx + PHP | Node.js/Bun/Deno |
| **HTTPS** | Via reverse proxy | Apache/Nginx SSL | App-level capable |
| **Performance** | Very fast (compiled) | Slower (interpreted) | Fast (runtime JIT) |
| **Memory** | Low (5-10 MB) | Variable | Medium (50-100 MB) |
| **Portability** | Multiple platforms | Unix/Linux | Cross-platform |
| **Maintenance** | Recompile for updates | Restart service | Restart service |

## See Also

- **[README.md](README.md)** - Documentation index
- **[WEB.md](WEB.md)** - Web interface guide
- **[FEATURES.md](FEATURES.md)** - Feature overview
- **[SERVER_JS.md](SERVER_JS.md)** - JavaScript server guide
- **[SERVER_PHP.md](SERVER_PHP.md)** - PHP server guide
- **[CLI_PYTHON3.md](CLI_PYTHON3.md)** - CLI usage (Python 3)
- **[CLI_BASH.md](CLI_BASH.md)** - CLI usage (Bash)
- **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** - Database design

## Additional Resources

- **FreePascal Official:** https://www.freepascal.org/
- **FreePascal Documentation:** https://wiki.lazarus.freepascal.org/
- **Omi GitHub:** https://github.com/wekan/omi
- **Project Root:** [../](../)

