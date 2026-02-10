# Command Line Interface: Python 3

> **Documentation Index:** See [README.md](README.md) for documentation overview  
> **Quick Start:** See [README.md](README.md#installation-quick-reference)

## Overview

The Omi Python 3 CLI is a cross-platform version control tool implemented in pure Python 3. It provides the same functionality as the Bash, FreeDOS, AmigaShell, and Lua implementations with the added benefit of broad Python ecosystem compatibility.

### Platform Support
- **Linux/Unix/macOS** - Primary platforms (Python 3.6+)
- **Windows** - Native Python 3 support (python.exe via PATH)
- **Web Servers** - Run via cron/systemd for automated sync
- **Development Environments** - Use directly in Python projects
- **System Administration** - Integrate with Python automation tools
- **CI/CD Pipelines** - Use in GitHub Actions, GitLab CI, etc.

### Requirements
- **Python 3.6 or newer** - Available from [python.org](https://www.python.org/) or package managers
- **SQLite 3.0+** - Usually included with Python
- **curl** - For remote push/pull operations
- **settings.txt** - Configuration file in project directory

### Why Python 3?
- Widely pre-installed on modern systems
- No compilation required
- Cross-platform compatibility
- Rich standard library (sqlite3, subprocess, hashlib, etc.)
- Easy to extend with additional Python modules
- Ideal for automation and scripting

## Installation

### 1. Install Python 3

**macOS (Homebrew):**
```bash
brew install python3
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install python3
```

**Linux (Fedora/RHEL):**
```bash
sudo dnf install python3
```

**Windows (Chocolatey):**
```powershell
choco install python
```

**From Source:**
Download from https://www.python.org/downloads/ and install according to documentation.

### 2. Make omi.py Executable (Optional)

```bash
chmod +x omi.py
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

| Setting | Description | Default | Notes |
|---------|-------------|---------|-------|
| `SQLITE` | Path to SQLite executable | `/usr/bin/sqlite3` | Only used if needed (Python has built-in sqlite3) |
| `CURL` | Path to curl executable | `/usr/bin/curl` | Required for remote push/pull |
| `USERNAME` | Default username for push/pull | (required) | Can be overridden per command |
| `PASSWORD` | Default password for push/pull | (required) | Restrict file permissions: `chmod 600` |
| `REPOS` | Remote server URL | `http://localhost/omi` | Use HTTPS in production |
| `API_ENABLED` | Enable remote API (0/1) | `1` | Set to 0 to disable push/pull |
| `API_RATE_LIMIT` | Max requests per window | `60` | Requests allowed |
| `API_RATE_LIMIT_WINDOW` | Time window in seconds | `60` | Time period for rate limit |

### 4. Run omi.py

```bash
python3 omi.py <command> [args]
```

Or with shebang (Linux/macOS/Unix):
```bash
./omi.py <command> [args]
```

Or as Windows batch:
```batch
python omi.py <command> [args]
```

## Quick Reference

### Initialize Repository
```bash
python3 omi.py init
# Creates: repo.omi, .omi
```

### Clone Repository
```bash
# From local file
python3 omi.py clone /path/to/repo.omi

# From remote server
python3 omi.py clone myrepo
```

### Add Files
```bash
# Add single file
python3 omi.py add myfile.txt

# Add all files
python3 omi.py add --all
```

### Commit Changes
```bash
python3 omi.py commit -m "Initial commit"
```

### Push to Remote
```bash
python3 omi.py push
# Prompts for 2FA code if enabled
```

### Pull from Remote
```bash
python3 omi.py pull
# Prompts for 2FA code if enabled
```

### View History
```bash
python3 omi.py log
# Shows last 10 commits

python3 omi.py log 20
# Shows last 20 commits
```

### Show Status
```bash
python3 omi.py status
# Shows staged files, recent commits, and statistics
```

### List Remote Repositories
```bash
python3 omi.py list
# Lists available repositories on remote server
```

## Commands in Detail

### init
Initialize a new repository in current directory.

```bash
python3 omi.py init
python3 omi.py init custom_name.omi
```

**Creates:**
- `repo.omi` or specified database file
- `.omi` file (stores database name)
- SQLite tables: blobs, files, commits, staging
- Database indices for fast queries

**Output:**
```
Initializing omi repository...
Repository initialized: repo.omi
```

### clone
Clone a repository from local or remote source.

```bash
# Local clone
python3 omi.py clone /path/to/existing.omi

# Remote clone
python3 omi.py clone myrepo
# Downloads myrepo from REPOS setting
```

**Behavior:**
- Local: Uses shutil.copy for instant cloning
- Remote: Downloads via curl, saves as repo_name
- Updates .omi with database filename
- Preserves complete commit history

**Output:**
```
Cloning from /path/to/existing.omi...
Cloned to repo.omi
```

### add
Stage files for commit.

```bash
# Add single file
python3 omi.py add myfile.txt

# Add all files in directory
python3 omi.py add --all
```

**Behavior:**
- Calculates SHA256 hash for each file (Python hashlib)
- Stores filename, hash, and timestamp in staging table
- Excludes: repo.omi, .omi, subdirectories
- Updates existing staged file if added again
- Uses binary-safe file reading

**Output:**
```
Adding files to staging...
Staged: myfile.txt (hash: abc123def456...)
```

### commit
Create a commit from staged files.

```bash
python3 omi.py commit -m "Fixed bug"
```

**Behavior:**
- Creates commit record with message, timestamp, author (from $USER)
- Processes all staged files
- Implements SHA256 deduplication (blobs table)
- Stores complete file data as SQLite BLOB
- Stores file metadata in files table with commit_id
- Clears staging area after commit
- Supports multi-line messages with quotes

**Commit Message Format:**
Required `-m "message"` flag. Use quotes for messages with spaces.

```bash
python3 omi.py commit -m "Initial import"
python3 omi.py commit -m "Add new feature and fix typo"
python3 omi.py commit -m "Multi-word message"
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
python3 omi.py push
```

**Behavior:**
- Checks if API is enabled on server
- Prompts for OTP code if 2FA enabled (using getpass for security)
- Sends repository as multipart form data via curl
- Displays upload progress
- Handles connection errors gracefully

**With 2FA:**
```bash
$ python3 omi.py push
Pushing repo.omi to remote...
Enter OTP code (6 digits): 
Successfully pushed to http://localhost/omi
```

**Error Handling:**
- Validates database file exists before upload
- API disabled: "Error: API is disabled"
- Upload failure: "Error: Failed to push to remote"
- Network error: Displays curl error output
- OTP error: Prompts to try again with correct code

### pull
Download repository from remote server.

```bash
python3 omi.py pull
```

**Behavior:**
- Downloads repository file from remote via curl
- Overwrites local database with remote version
- Prompts for OTP code if 2FA enabled
- Validates download succeeded before replacing local file
- Preserves file on error

**With 2FA:**
```bash
$ python3 omi.py pull
Pulling repo.omi from remote...
Enter OTP code (6 digits): 
Successfully pulled from http://localhost/omi
```

**Error Handling:**
- API disabled: "Error: API is disabled"
- Download failure: Shows curl error
- Network timeout: Handled by curl with error message
- OTP error: Prompts to try again

### log
View commit history.

```bash
python3 omi.py log
# Shows last 10 commits

python3 omi.py log 50
# Shows last 50 commits
```

**Output Format:**
```
=== Commit History ===
id|datetime|user|message
1|2026-02-10 14:23:45|username|Initial commit
2|2026-02-10 14:25:30|username|Add files
```

**Notes:**
- Ordered by commit ID descending (newest first)
- Default limit is 10 commits
- Specify custom limit as argument

### status
Show repository status.

```bash
python3 omi.py status
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

**Shows:**
- Staged files waiting for commit
- 5 most recent commits
- Total number of unique content blobs (deduplication benefit)
- Total file records across all commits

### list
List remote repositories.

```bash
python3 omi.py list
```

**Output:**
```
=== Available Repositories on http://localhost/omi ===
myrepo1
myrepo2
backup
projects
```

**Notes:**
- Queries remote server for /format=json
- Parses JSON response to extract repository names
- Useful for discovering available repositories before clone

## Two-Factor Authentication (2FA)

### Enable 2FA
2FA is managed through the web interface (`/people` page) or by editing `phpusers.txt`:

```
username:password:otpauth://totp/...
```

### Using with CLI

When 2FA is enabled, push and pull operations prompt for OTP code:

```bash
$ python3 omi.py push
Pushing repo.omi to remote...
Enter OTP code (6 digits): 123456
Successfully pushed to http://localhost/omi
```

**Input Method:**
- Python's `getpass` module (secure, doesn't echo input)
- 6 digits required
- Code must be correct for operation to succeed
- Codes change every 30 seconds

### Compatible Authenticators
- Google Authenticator
- Microsoft Authenticator
- Authy
- FreeOTP
- 1Password
- Bitwarden
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

### HTTP and Network Configuration

Python CLI supports both internal HTTP libraries and external `curl` for push/pull operations.

**New Settings in `settings.txt`:**

```ini
# Use internal HTTP (urllib3) if available, else fall back to curl
USE_INTERNAL_HTTP=1

# HTTP timeout in seconds for remote operations
HTTP_TIMEOUT=30
```

**How it works:**

- **USE_INTERNAL_HTTP=1** (default)
  - Uses Python's urllib3 library if installed
  - Falls back to curl if urllib3 not available
  - No external dependencies for basic operations
  - Faster startup (no external process spawning)

- **USE_INTERNAL_HTTP=0**
  - Always uses external `curl` command
  - Useful if curl is already installed system-wide
  - Requires curl in PATH

**Install urllib3 for internal HTTP (optional):**

```bash
pip3 install urllib3
```

Or with package manager:
```bash
# Ubuntu/Debian
sudo apt-get install python3-urllib3

# Fedora/RHEL
sudo dnf install python3-urllib3
```

Without urllib3, Python CLI automatically falls back to curl (if installed) or will error out.

### Server Behavior

When rate limit is reached:
- Server returns error response
- CLI logs error message
- User should wait before retrying

**Recovery:**
```bash
# Wait the specified window time, then retry
python3 omi.py push  # Wait if rate limited
sleep 60             # Wait 60 seconds (or whatever window is set)
python3 omi.py push  # Try again
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
**Format:** SQLite 3 binary format, readable with any SQLite client

## File Paths

Configuration files (in project root):
- `settings.txt` - Server and authentication settings (chmod 600 for security)
- `phpusers.txt` - User credentials and OTP URLs (on server only)

Working files:
- `repo.omi` - SQLite repository database
- `.omi` - Stores current database name

## Workflow Examples

### Single File Workflow
```bash
python3 omi.py init
echo "Hello World" > hello.txt
python3 omi.py add hello.txt
python3 omi.py commit -m "Add greeting"
python3 omi.py push
```

### Multi-File Workflow
```bash
python3 omi.py init myproject

# ... create multiple files ...
python3 omi.py add --all
python3 omi.py commit -m "Initial project import"
python3 omi.py push
```

### Sync Workflow
```bash
# On Machine A
python3 omi.py init
python3 omi.py add --all
python3 omi.py commit -m "Changes"
python3 omi.py push

# On Machine B
python3 omi.py clone myrepo
# ... make changes ...
python3 omi.py add --all
python3 omi.py commit -m "More changes"
python3 omi.py push

# Back on Machine A
python3 omi.py pull
```

### Automated Backup Workflow
```bash
#!/bin/bash
# backup.sh - Daily backup script

cd /path/to/data
python3 /path/to/omi.py add --all
python3 /path/to/omi.py commit -m "Daily backup $(date +%Y-%m-%d)"
python3 /path/to/omi.py push
```

Run via cron:
```bash
0 2 * * * /home/user/backup.sh  # 2 AM daily backups
```

## Extending with Python

The modular design makes it easy to extend:

```python
from omi import OmiRepository, Settings

# Load settings and create repository
settings = Settings.load()
repo = OmiRepository(settings)

# Use programmatically
repo.init("mydb.omi")
repo.add_files()
repo.commit("Programmatic commit")
repo.push()
```

## Integration with Python Projects

Use as a library in your Python project:

```python
import sys
sys.path.insert(0, '/path/to/omi')
from omi import OmiRepository, Settings

# Your code here using OmiRepository
```

Or import functions from the script similar to a module.

## Troubleshooting

### Python Not Found
**Error:** `python3: command not found`

**Solution:**
- Install Python 3: `brew install python3` or `apt-get install python3`
- Use explicit path: `/usr/bin/python3 omi.py`
- On Windows: `py omi.py` (Python Launcher)
- Check PATH: `which python3`

### settings.txt Not Found
**Error:** `Error: settings.txt not found`

**Solution:**
- Create `settings.txt` in project root
- Copy template from documentation
- Ensure correct permissions: `chmod 600 settings.txt`

### Database Permission Error
**Error:** `Error: database is locked` or `attempt to write a readonly database`

**Solution:**
- Check file permissions: `ls -la repo.omi`
- Ensure directory is writable: `chmod 755 .`
- Close other processes accessing database
- Try again with fresh lock: `rm .omi` then `python3 omi.py init`

### Push/Pull Fails
**Error:** `Error: Failed to push to remote` or `Error: Failed to pull from remote`

**Solution:**
- Verify settings.txt: `cat settings.txt`
- Test connection: `curl "$REPOS"`
- Check credentials: username/password in settings.txt
- Check 2FA: Is OTP code required?
- Check API: Server must have `API_ENABLED=1`
- Check curl availability: `which curl`

### OTP Code Error
**Error:** Code prompt appears but doesn't work

**Solution:**
- Verify correct OTP code (6 digits, changes every 30 seconds)
- Sync device time with server time: `ntpdate -s time.nist.gov`
- Regenerate OTP in web interface (/people page)
- Try again with fresh code

### Import Errors
**Error:** `ModuleNotFoundError: No module named 'sqlite3'`

**Solution:**
- sqlite3 is included with Python 3.6+
- Reinstall Python 3
- Check Python version: `python3 --version` (should be 3.6+)

### File Not Found During Add
**Error:** `Error: File not found: filename`

**Solution:**
- Verify file exists: `ls -la filename`
- Check working directory: `pwd`
- Use relative paths from project root
- Ensure file is readable: `file filename`

### Encoding Issues (Windows)
**Error:** UnicodeDecodeError with non-ASCII filenames

**Solution:**
- Set console encoding: `chcp 65001` (UTF-8)
- Use Python 3.7+ (better Unicode support)
- Rename files to ASCII-only: `file.txt` instead of `filé.txt`

## Performance Notes

### Speed Comparison
- **Initialization:** Python ~10ms (very fast)
- **Adding files:** Python ~50ms per file (fast)
- **Commits:** Python ~100ms (fast)
- **Push/Pull:** Limited by network (typically 1-10s)

### Large Operations
- Add 1000 files: ~1 second
- Commit with 100 files: ~2 seconds
- Push 10 MB database: ~5-10 seconds (network dependent)

### Memory Usage
- Typical operations: <10 MB RAM
- Large file handling: Streamed, not loaded entirely
- Database connections: Properly closed after each operation

## Security Notes

- **Credentials in settings.txt** - Restrict file permissions: `chmod 600 settings.txt`
- **OTP codes** - Using getpass for secure input (no echo to screen)
- **HTTPS recommended** - Use HTTPS for remote URLs in production
- **Database backups** - Regularly backup `.omi` repository files
- **Python updates** - Keep Python 3 updated for security patches

## Performance Advantages

Python 3 implementation benefits:
- **Pure Python** - No external compiled dependencies
- **Cross-platform** - Works identically on all platforms
- **Fast startup** - Minimal initialization overhead
- **Safe I/O** - Python handles encoding automatically
- **Extensible** - Easy to add custom functionality
- **Debuggable** - Can add print statements for troubleshooting

## See Also

- **[README.md](README.md)** - Documentation index
- **[FEATURES.md](FEATURES.md)** - Feature overview
- **[CLI_HAXE5.md](CLI_HAXE5.md)** - CLI alternative (Haxe 5)
- **[CLI_CSHARP.md](CLI_CSHARP.md)** - CLI alternative (C# / Mono)
- **[CLI_C89.md](CLI_C89.md)** - CLI alternative (C89)
- **[CLI_TCL.md](CLI_TCL.md)** - CLI alternative (Tcl)
- **[CLI_BASH.md](CLI_BASH.md)** - CLI alternative (Bash)
- **[CLI_BAT.md](CLI_BAT.md)** - CLI alternative (FreeDOS)
- **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** - CLI alternative (Amiga)
- **[CLI_LUA.md](CLI_LUA.md)** - CLI alternative (Lua)
- **[WEB.md](WEB.md)** - Web interface
- **[SERVER.md](SERVER.md)** - Server setup
- **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** - Database design

## Notes

- Pure Python 3 (no external dependencies beyond Python standard library)
- Compatible with Python 3.6+ (very broad compatibility)
- Works on Windows, macOS, Linux, and any platform with Python 3
- Ideal for automation, CI/CD integration, and system administration
- Same commands and functionality as other CLI implementations
- Configuration via `settings.txt` shared with other CLIs
- Deduplication and history tracking work identically across all platforms

---

**Last Updated:** February 10, 2026  
**Omi Version:** 1.0  
**CLI Version:** Python 3.6+
