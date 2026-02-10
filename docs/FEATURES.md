# Omi - Features Overview

> **Documentation Index:** See [README.md](README.md) for documentation overview  
> **Quick Start:** See [README.md](README.md#installation-quick-reference)

Omi is a lightweight Git-like version control system designed for retro systems and modern platforms with SQLite-based storage and SHA256 deduplication.

## Core Features

### Version Control System
- **Git-like interface** - Familiar commands: init, clone, add, commit, push, pull, log, list, status
- **SQLite-based storage** - Lightweight database format with BLOB support
- **SHA256 deduplication** - Automatic content-addressed storage reduces disk usage
- **Commit history** - Full commit tracking with messages, timestamps, and user attribution
- **File staging** - Stage files before committing changes

### Database Features
- **BLOB compression** - Stores file data efficiently in SQLite binary format
- **Indexed queries** - Fast lookups on file hashes and commit IDs
- **Transaction support** - ACID compliance for data integrity
- **Lightweight** - Typical database file is 10-50KB per repository

## Command Line Interface (CLI)

### Core Commands
- **init** - Initialize a new repository
- **clone** - Clone a repository (local or remote)
- **add** - Stage files for commit
- **commit** - Create a commit with staged files
- **push** - Upload repository to remote server
- **pull** - Download repository from remote server
- **list** - List available repositories on remote
- **log** - View commit history with pagination (configurable limit)
- **status** - Show current staging area and recent commits

### Platform Support
- **AmigaShell** - Native script for Commodore Amiga systems
- **FreeDOS Batch** - Compatible with FreeDOS and DOS variants
- **Bash** - Unix/Linux shell script

## Web Interface (public/index.php)

### Features
- **Repository browser** - List and navigate repositories
- **File viewer** - View text files and embedded images
- **Commit history** - Paginated view of repository commits (10 per page)
- **Image gallery** - Display images from repositories with base64 encoding
- **Download support** - Download .omi repository files directly
- **HTML 3.2 compatible** - Works with vintage browsers (IBrowse, Dillo, Mosaic)
- **API endpoint** - JSON API for remote push/pull operations

### User Management (/people)
- **Add users** - Create new user accounts
- **Edit users** - Modify usernames and passwords
- **Delete users** - Remove user accounts
- **OTP management** - Enable/disable 2FA per user
- **QR code display** - Show otpauth:// URLs for 2FA setup

## Security Features

### Authentication
- **Session-based login** - Secure user sessions with PHP sessions
- **Password protection** - User authentication required for uploads
- **User management** - Control who can access the system

### Two-Factor Authentication (2FA)
- **TOTP support** - RFC 6238 compliant time-based one-time passwords
- **6-digit codes** - 30-second time windows
- **QR codes** - otpauth:// URLs compatible with authenticator apps
- **NumberStation compatible** - Works with vintage authenticators
- **Optional per-user** - Enable/disable 2FA individually
- **CLI support** - All platforms prompt for OTP when needed

### Brute Force Protection
- **Account lockout** - Lock accounts after failed attempts
- **Configurable thresholds** - Separate settings for known/unknown users
  - `ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURES_BEFORE` (default: 3)
  - `ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURE_WINDOW` (default: 15 seconds)
  - `ACCOUNTS_LOCKOUT_KNOWN_USERS_PERIOD` (default: 60 seconds)
  - Similar settings for unknown users
- **Time-based unlocking** - Automatic unlock after lockout period

### Directory Traversal Protection
- **Path sanitization** - Remove `../` and `..\\` sequences
- **basename() validation** - Strip directory components
- **realpath() verification** - Verify all file access within REPOS_DIR
- **Character validation** - Only allow alphanumeric, dash, underscore, dot

### API Rate Limiting
- **Request tracking** - Track API requests per user
- **Configurable limits** - Set in settings.txt
  - `API_RATE_LIMIT` (default: 60 requests)
  - `API_RATE_LIMIT_WINDOW` (default: 60 seconds)
- **Rate limit headers** - HTTP headers show remaining requests
- **Automatic retry** - CLI can wait and retry automatically
- **Cleanup** - Automatic removal of entries older than 1 hour

### API Control
- **Global disable** - Set `API_ENABLED=0` to disable API entirely
- **Graceful handling** - CLI shows meaningful error messages
- **Server status** - Returns 503 when API disabled

## Network Features

### Remote Operations
- **Push/Pull support** - Upload/download repositories over HTTP/HTTPS
- **curl-based** - Uses curl for network operations (configurable in settings.txt)
- **Authentication** - Username/password for all remote operations
- **2FA support** - OTP codes sent with push/pull requests
- **Rate limiting** - Server enforces request limits per user

### Server Configuration
- **Web server agnostic** - Works with Apache, Nginx, Caddy
- **HTTPS support** - Recommended for security
- **Remote URL configurable** - Set `REPOS` setting for custom servers
- **Multiple server support** - Can interact with different servers

## Configuration Files

### settings.txt
- SQLite path
- curl path
- Remote repository URL
- Username and password
- Brute force protection thresholds
- API settings (enabled, rate limit, window)

### phpusers.txt
- User database (format: username:password:otpauth_url)
- Plain text with colon-separated fields
- OTP URLs in otpauth:// format

### System Files
- **phpusersbruteforcelocked.txt** - Locked accounts with timestamps
- **phpusersfailedattempts.txt** - Failed login attempts with timestamps
- **api_rate_limit.txt** - API request tracking with timestamps

## Documentation

### Included Documentation
- **README.md** - Documentation index and quick reference
- **FEATURES.md** - This file (feature overview)
- **CLI_BASH.md** - Command line for Linux/Unix/macOS
- **CLI_BAT.md** - Command line for FreeDOS/Windows
- **CLI_AMIGASHELL.md** - Command line for Commodore Amiga
- **WEB.md** - Web interface documentation
- **SERVER.md** - Server setup and configuration
- **DATABASE_SCHEMA.md** - Database structure details

## Performance & Efficiency

### Storage Optimization
- **Content deduplication** - No duplicate data stored
- **Incremental storage** - Only new content increases database size
- **Compression-ready** - SQLite BLOB format suitable for compression
- **Indexed access** - Fast file and commit lookups

### Network Efficiency
- **Rate limiting** - Prevents server overload
- **Binary format** - Efficient .omi file format
- **On-demand sync** - Pull only needed repositories

## Compatibility

### Browser Support
- **Modern browsers** - Chrome, Firefox, Safari, Edge
- **Vintage browsers** - IBrowse, Dillo, Netscape 4.0+
- **Text-only** - Links, Lynx (no JavaScript required)

### System Support
- **Windows** - Via WSL or native batch scripts
- **Linux/UNIX** - Bash implementation
- **macOS** - Bash implementation
- **AmigaOS** - Native AmigaShell script
- **FreeDOS** - Native batch script
- **Retro systems** - Designed for resource-constrained environments

## Limitations & Roadmap

### Current Scope
- Single file version control (not directory trees)
- Linear history (no branching)
- No merge conflict resolution
- No file diff viewer

### Future Enhancements
- Directory tree support
- Branching and merging
- Diff viewer
- Conflict resolution
- Clone operations
- Remote synchronization improvements

---

## See Also

- **[README.md](README.md)** - Documentation index
- **[CLI_BASH.md](CLI_BASH.md)** - CLI commands (Bash)
- **[CLI_BAT.md](CLI_BAT.md)** - CLI commands (FreeDOS)
- **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** - CLI commands (Amiga)
- **[WEB.md](WEB.md)** - Web interface
- **[SERVER.md](SERVER.md)** - Server setup
- **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** - Database design
