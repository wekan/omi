# Command Line Interface: Lua

> **Documentation Index:** See [README.md](README.md) for documentation overview  
> **Quick Start:** See [README.md](README.md#installation-quick-reference)

## Overview

The Omi Lua CLI is a cross-platform version control tool implemented in Lua programming language. It provides the same functionality as the Bash, FreeDOS, and AmigaShell implementations but uses Lua's standard libraries and system calls.

### Platform Support
- **Linux/Unix/macOS** - Primary platforms (Lua 5.1+)
- **Windows** - With Lua interpreter installed (lua.exe via PATH or WSL)
- **Embedded Systems** - Any platform with Lua 5.1+ and SQLite 3.0+
- **Development Environments** - IDEs that support Lua scripting

### Requirements
- **Lua 5.1 or newer** - Available from [lua.org](https://www.lua.org/) or package managers
- **SQLite 3.0+** - For database operations
- **curl** - For remote push/pull operations
- **settings.txt** - Configuration file in project directory

## Installation

### 1. Install Lua

**macOS (Homebrew):**
```bash
brew install lua
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install lua5.3
```

**Linux (Fedora/RHEL):**
```bash
sudo dnf install lua
```

**Windows (Chocolatey):**
```powershell
choco install lua
```

**From Source:**
Download from https://www.lua.org/download.html and compile according to documentation.

### 2. Make omi.lua Executable (Optional)

```bash
chmod +x omi.lua
```

### 3. Configure settings.txt

Create `settings.txt` with these settings:

```ini
SQLITE=/usr/bin/sqlite3
CURL=/usr/bin/curl
USERNAME=your_username
PASSWORD=your_password
REPOS=http://localhost/omi
API_ENABLED=1
API_RATE_LIMIT=60
API_RATE_LIMIT_WINDOW=60
```

#### Setting Details

| Setting | Description | Default |
|---------|-------------|---------|
| `SQLITE` | Path to SQLite executable | `/usr/bin/sqlite3` |
| `CURL` | Path to curl executable | `/usr/bin/curl` |
| `USERNAME` | Default username for push/pull | (required) |
| `PASSWORD` | Default password for push/pull | (required) |
| `REPOS` | Remote server URL | `http://localhost/omi` |
| `API_ENABLED` | Enable remote API (0/1) | `1` |
| `API_RATE_LIMIT` | Max requests per window | `60` |
| `API_RATE_LIMIT_WINDOW` | Time window in seconds | `60` |

### 4. Run omi.lua

```bash
lua omi.lua <command> [args]
```

Or with shebang (Linux/macOS/Unix):
```bash
./omi.lua <command> [args]
```

## Quick Reference

### Initialize Repository
```bash
lua omi.lua init
# Creates: repo.omi, .omi
```

### Clone Repository
```bash
# From local file
lua omi.lua clone /path/to/repo.omi

# From remote server
lua omi.lua clone myrepo
```

### Add Files
```bash
# Add single file
lua omi.lua add myfile.txt

# Add all files
lua omi.lua add --all
```

### Commit Changes
```bash
lua omi.lua commit -m "Initial commit"
```

### Push to Remote
```bash
lua omi.lua push
# Prompts for 2FA code if enabled
```

### Pull from Remote
```bash
lua omi.lua pull
# Prompts for 2FA code if enabled
```

### View History
```bash
lua omi.lua log
# Shows last 10 commits

lua omi.lua log 20
# Shows last 20 commits
```

### Show Status
```bash
lua omi.lua status
# Shows staged files, recent commits, and statistics
```

### List Remote Repositories
```bash
lua omi.lua list
# Lists available repositories on remote server
```

## Commands in Detail

### init
Initialize a new repository in current directory.

```bash
lua omi.lua init
lua omi.lua init custom_name.omi
```

**Creates:**
- `repo.omi` or specified database file
- `.omi` file (stores database name)
- SQLite tables: blobs, files, commits, staging

**Output:**
```
Initializing omi repository...
Repository initialized: repo.omi
```

### clone
Clone a repository from local or remote source.

```bash
# Local clone
lua omi.lua clone /path/to/existing.omi

# Remote clone
lua omi.lua clone myrepo
# Downloads myrepo from REPOS setting
```

**Output:**
```
Cloning from /path/to/existing.omi...
Cloned to repo.omi
```

### add
Stage files for commit.

```bash
# Add single file
lua omi.lua add myfile.txt

# Add all files in directory
lua omi.lua add --all
```

**Behavior:**
- Calculates SHA256 hash for each file
- Stores in staging table
- Excludes: repo.omi, .omi, subdirectories
- Updates existing staged file if added again

**Output:**
```
Adding files to staging...
Staged: myfile.txt (hash: abc123def456...)
```

### commit
Create a commit from staged files.

```bash
lua omi.lua commit -m "Fixed bug"
```

**Behavior:**
- Creates commit record with message, timestamp, user
- Processes all staged files
- Implements SHA256 deduplication (blobs table)
- Stores file metadata (files table)
- Clears staging area

**Commit Message Format:**
Required `-m "message"` flag. Use quotes for messages with spaces.

```bash
lua omi.lua commit -m "Initial import"
lua omi.lua commit -m "Add new feature and fix typo"
```

**Output:**
```
Committing changes...
  Stored new blob: abc123def456...
  Blob already exists (deduplicated): def456abc123...
Committed successfully (commit #1)
```

### push
Upload repository to remote server.

```bash
lua omi.lua push
```

**Behavior:**
- Checks if API is enabled on server
- Prompts for OTP code if 2FA enabled
- Handles rate limiting with automatic retry
- Sends repository as multipart form data

**With 2FA:**
```bash
$ lua omi.lua push
Pushing repo.omi to remote...
Enter OTP code (6 digits): 123456
Successfully pushed to http://localhost/omi
```

**Error Handling:**
- API disabled: "Error: API is disabled"
- OTP required: "2FA code required. Please try again with the correct OTP code."
- Rate limit: Waits and retries automatically
- Connection error: "Error: Failed to push to remote"

### pull
Download repository from remote server.

```bash
lua omi.lua pull
```

**Behavior:**
- Downloads repository file from remote
- Overwrites local database with remote version
- Prompts for OTP code if 2FA enabled
- Handles rate limiting automatically

**With 2FA:**
```bash
$ lua omi.lua pull
Pulling repo.omi from remote...
Enter OTP code (6 digits): 123456
Successfully pulled from http://localhost/omi
```

**Error Handling:**
- API disabled: "Error: API is disabled"
- OTP required: "2FA code required. Please try again with the correct OTP code."
- Rate limit: Waits and retries automatically

### log
View commit history.

```bash
lua omi.lua log
# Shows last 10 commits

lua omi.lua log 50
# Shows last 50 commits
```

**Output:**
```
=== Commit History ===
1|2026-02-10 14:23:45|username|Initial commit
```

### status
Show repository status.

```bash
lua omi.lua status
```

**Output:**
```
=== Staged Files ===
myfile.txt|2026-02-10 14:23:45

=== Recent Commits ===
1|Initial commit|2026-02-10 14:23:45

=== Statistics ===
Total blobs (deduplicated): 1
Total file versions: 1
```

### list
List remote repositories.

```bash
lua omi.lua list
```

**Output:**
```
=== Available Repositories on http://localhost/omi ===
myrepo1
myrepo2
backup
projects
```

## Two-Factor Authentication (2FA)

### Enable 2FA
2FA is managed through the web interface (`/people` page) or by editing `phpusers.txt`:

```
username:password:otpauth://totp/...
```

### Using with CLI

When 2FA is enabled, push and pull operations prompt for OTP code:

```bash
$ lua omi.lua push
Pushing repo.omi to remote...
Enter OTP code (6 digits): 123456
Successfully pushed to http://localhost/omi
```

OTP codes:
- 6 digits
- Change every 30 seconds
- Generated by authenticator apps (Google Authenticator, Authy, etc.)

### Compatible Authenticators
- Google Authenticator
- Microsoft Authenticator
- Authy
- FreeOTP
- NumberStation (vintage)

## Rate Limiting

API rate limiting protects the server from abuse.

### Configuration

Set in `settings.txt`:

```ini
API_RATE_LIMIT=60
API_RATE_LIMIT_WINDOW=60
```

Means: 60 requests per 60 seconds

### Behavior

When rate limit is reached:
- Server returns `rate_limit` error
- CLI logs: "Rate limited. Waiting Xs..."
- CLI waits automatically
- CLI retries request

**Example:**
```bash
$ lua omi.lua push push push push
(4 requests exceed limit)
Rate limited. Waiting 30s...
(automatic retry after 30 seconds)
```

## Database Files

### .omi
Stores the name of the current database file.

**Content:**
```
OMI_DB="repo.omi"
```

**Used by:** CLI to determine which database to operate on

### repo.omi
SQLite database file containing:
- `blobs` table - SHA256 deduplicated file content
- `files` table - File metadata and commit history
- `commits` table - Commit records with messages
- `staging` table - Files staged for next commit

**Size:** Typically 10-50 KB for small repositories

## File Paths

Configuration files (in project root):
- `settings.txt` - Server and authentication settings
- `phpusers.txt` - User credentials and OTP URLs (on server only)

Working files:
- `repo.omi` - SQLite repository database
- `.omi` - Stores current database name

Staging:
- Temporary files in `/tmp/omi_pull_*` during pull operations

## Workflow Examples

### Single File Workflow
```bash
lua omi.lua init
echo "Hello World" > hello.txt
lua omi.lua add hello.txt
lua omi.lua commit -m "Add greeting"
lua omi.lua push
```

### Multi-File Workflow
```bash
lua omi.lua init myproject

# ... create multiple files ...
cp *.txt ../myproject
cp *.lua ../myproject
cd myproject

lua omi.lua add --all
lua omi.lua commit -m "Initial project import"
lua omi.lua push
```

### Sync Workflow
```bash
# On Machine A
lua omi.lua init
lua omi.lua add --all
lua omi.lua commit -m "Changes"
lua omi.lua push

# On Machine B
lua omi.lua clone myrepo
# ... make changes ...
lua omi.lua add --all
lua omi.lua commit -m "More changes"
lua omi.lua push

# Back on Machine A
lua omi.lua pull
```

## Troubleshooting

### Command Not Found
**Error:** `lua: command not found` or `./omi.lua: command not found`

**Solution:**
- Install Lua: `brew install lua` or `apt-get install lua5.3`
- Use explicit path: `/usr/bin/lua omi.lua`
- Check PATH: `which lua`

### settings.txt Not Found
**Error:** `Error: settings.txt not found`

**Solution:**
- Create `settings.txt` in project root
- Copy template from documentation
- Ensure correct permissions: `chmod 600 settings.txt`

### Database Locked
**Error:** `database is locked` or `attempt to write a readonly database`

**Solution:**
- Check file permissions: `ls -la repo.omi`
- Ensure directory is writable: `chmod 755 .`
- Close other omi processes
- Verify no other locks: `lsof repo.omi`

### Push/Pull Fails
**Error:** `Failed to push to remote` or `Failed to pull from remote`

**Solution:**
- Verify settings.txt: `cat settings.txt`
- Test connection: `curl "$REPOS"`
- Check credentials: username/password in settings.txt
- Check 2FA: Is OTP code required? Try push again
- Check API enabled: Server must have `API_ENABLED=1`

### OTP Code Error
**Error:** `2FA code required. Please try again with the correct OTP code.`

**Solution:**
- Verify correct OTP code (changes every 30 seconds)
- Sync device time with server time
- Regenerate OTP in web interface (/people page)

### Rate Limit Exceeded
**Error:** `Rate limited. Waiting Xs...`

**Normal behavior** - CLI waits and retries automatically.

**To reduce rate limiting:**
- Increase `API_RATE_LIMIT_WINDOW` in settings.txt
- Increase `API_RATE_LIMIT` in settings.txt
- Space out push/pull operations
- Contact server admin if limits are too strict

### SQLite Not Found
**Error:** `sqlite3` command not found

**Solution:**
- Install SQLite: `brew install sqlite` or `apt-get install sqlite3`
- Verify installation: `which sqlite3`
- Update settings.txt with correct path: `SQLITE=/usr/bin/sqlite3`

### Lua Version Issues
**Error:** `bad argument` or `attempt to index nil value`

**Solution:**
- Check Lua version: `lua -v`
- Upgrade to Lua 5.1+
- Some Lua features (like `table.unpack`) require Lua 5.2+ or compatibility layer

### File Not Found During Add
**Error:** `Error: File not found: filename`

**Solution:**
- Verify file exists: `ls -la filename`
- Check working directory: `pwd`
- Use relative paths from project root
- Ensure file is readable: `file filename`

## Performance

### Large Files
- Storing large files (>100 MB) is slow
- Deduplication saves space if same content appears multiple times
- Consider splitting large files into chunks

### Many Files
- `add --all` may be slow with thousands of files
- Use `add filename` for individual files instead
- Consider excluding large directories

### Remote Operations
- Push/pull speed limited by network connection
- Rate limiting may slow operations
- Consider bandwidth: 1 MB file ~1 second on typical connection

## Security Notes

- **Credentials in settings.txt** - Restrict file permissions: `chmod 600 settings.txt`
- **OTP codes** - Don't share OTP codes; they change every 30 seconds
- **HTTPS recommended** - Use HTTPS for remote URLs in production
- **Database backups** - Regularly backup `.omi` repository files
- **Keep Lua updated** - Use Lua 5.3+ for security patches

## See Also

- **[README.md](README.md)** - Documentation index
- **[FEATURES.md](FEATURES.md)** - Feature overview
- **[CLI_PYTHON3.md](CLI_PYTHON3.md)** - CLI alternative (Python 3)
- **[CLI_HAXE5.md](CLI_HAXE5.md)** - CLI alternative (Haxe 5)
- **[CLI_CSHARP.md](CLI_CSHARP.md)** - CLI alternative (C# / Mono)
- **[CLI_BASH.md](CLI_BASH.md)** - CLI alternative (Bash)
- **[CLI_BAT.md](CLI_BAT.md)** - CLI alternative (FreeDOS)
- **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** - CLI alternative (Amiga)
- **[WEB.md](WEB.md)** - Web interface
- **[SERVER.md](SERVER.md)** - Server setup
- **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** - Database design

## Notes

- Lua 5.1+ required (most systems have Lua installed or available via package manager)
- Compatible with Linux, macOS, Unix, Windows (via WSL or Lua interpreter)
- Same commands and functionality as other CLI implementations
- Configuration via `settings.txt` shared with other CLIs
- Deduplication and history tracking work identically across all platforms

---

**Last Updated:** February 10, 2026  
**Omi Version:** 1.0  
**CLI Version:** Lua 5.1+
