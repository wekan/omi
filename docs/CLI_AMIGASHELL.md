# AmigaShell CLI (omi)

> **Documentation:** [README.md](README.md) | [FEATURES.md](FEATURES.md) | [WEB.md](WEB.md) | [SERVER_PHP.md](SERVER_PHP.md) | [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)  
> **CLI Options:** [CLI_BASH.md](CLI_BASH.md) | [CLI_BAT.md](CLI_BAT.md) | [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md) | [CLI_C89.md](CLI_C89.md) | [CLI_TCL.md](CLI_TCL.md)

The AmigaShell implementation (`omi`) runs on Commodore Amiga and AmigaOS systems.

## Installation

### Prerequisites
- AmigaShell (AmiCLI)
- SQLite (with sha256 support)
- curl (for remote operations)
- Recommended: AmiSSL for HTTPS support

**Verify Installation:**
```
Path: C:
Which sqlite
Which curl
```

### Setup

1. Copy script to your system:
```
COPY omi c:omi
PROTECT c:omi +e          REM Make executable
```

2. Configure settings.txt in your working directory:
```
SQLITE=sqlite
USERNAME=user
PASSWORD=pass
REPOS=http://localhost
CURL=curl
API_ENABLED=1
API_RATE_LIMIT=60
API_RATE_LIMIT_WINDOW=60
```

3. Create first user in phpusers.txt:
```
myuser:mypassword
```

## Quick Start

### Initialize a Repository
```
omi init
REM Creates repo.omi SQLite database
```

### Add and Commit Files
```
omi add --all
REM Stages all files (except repo.omi and .omi)

omi commit -m "Initial commit"
REM Creates commit record with timestamp and username
```

### Check Status
```
omi status
REM Shows staged files and recent commits

omi log
REM View commit history
```

### Sync with Server
```
omi push
REM Upload to server
REM If 2FA enabled, interactive dialog for OTP code

omi pull
REM Download from server
REM If 2FA enabled, interactive dialog for OTP code
```

### List and Clone
```
omi list
REM Shows all .omi files available on server

omi clone wekan.omi
REM Download repository from server
```

## Complete Command Reference

### init

Initializes a new Omi repository.

```
omi init
```

**Creates:**
- `repo.omi` - SQLite database file
- `.omi` - Database location reference file
- Tables: blobs, files, commits, staging
- Indexes for optimized queries

### add

Stages files for commit.

```
omi add --all              REM Add all files
omi add README             REM Add specific file
omi add src/main.c         REM Add file in directory
```

**What it does:**
- Calculates SHA256 hash for each file
- Stores filename and hash in staging table
- Marks file as ready for commit

**Options:**
- `--all` - Add all files (except .omi and database)
- `<filename>` - Add specific file

### commit

Records staged changes as a commit.

```
omi commit -m "Initial commit"
omi commit -m "Fix bug in parser"
```

**What it does:**
- Creates commit record with message, timestamp, username
- For each staged file:
  - Checks if blob with hash exists
  - If not: inserts blob with file content (deduplication)
  - Inserts file metadata record
- Clears staging area

**Options:**
- `-m "message"` - Commit message (required)

### push

Uploads repository to remote server.

```
omi push
```

**Prerequisites:**
- `settings.txt` with REPOS, USERNAME, PASSWORD configured
- Network connection to repository server
- API_ENABLED = 1 on server
- Recommended: AmiSSL for HTTPS

**Interactive Dialogs:**
- If 2FA enabled: RequestString dialog for OTP entry
- Shows: "2FA Required - OTP code needed for this user"
- You can cancel to retry

**Handles Automatically:**
- Rate limiting (waits if needed)
- API disabled responses (shows error)
- OTP validation errors (allows retry)

**Returns:**
- Success: "Successfully pushed to <server>"
- Failure: Error message from server

### pull

Downloads latest repository from server.

```
omi pull
```

**Prerequisites:**
- `settings.txt` with REPOS, USERNAME, PASSWORD
- Network connection to repository server
- API_ENABLED = 1 on server
- Recommended: AmiSSL for HTTPS

**Interactive Dialogs:**
- If 2FA enabled: RequestString dialog for OTP code

**What it does:**
- Connects to remote server
- Authenticates with username and password
- Shows dialog for OTP if 2FA enabled
- Downloads latest .omi file
- Replaces local database with server version

**Returns:**
- Success: "Successfully pulled from <server>"
- Failure: Error message from server

### list

Lists available repositories on remote server.

```
omi list
```

**Output:**
Shows filenames of all .omi files on the server.

**Prerequisites:**
- REPOS configured in settings.txt
- Network access

### clone

Clones an existing repository from server or local path.

```
omi clone wekan.omi         REM From remote server
omi clone dh0:repos/repo.omi REM From local path
```

**What it does:**
- For local files: copies repository file
- For remote: downloads from REPOS server
- Creates .omi file with database reference
- Sets up local working directory

### log

Views commit history with optional limit.

```
omi log              REM Show last 20 commits (default)
omi log 50           REM Show last 50 commits
omi log 100          REM Show last 100 commits
```

**Output Format:**
- Commit: ID (Author)
- Date: Timestamp
- Message: Commit message
- Files: Number of files in commit

**Options:**
- `[limit]` - Number of commits to display (default: 20)

### status

Shows repository status and statistics.

```
omi status
```

**Shows:**
- Staged files (awaiting commit)
- Recent commits (last 5)
- Statistics:
  - Total blobs (deduplicated files)
  - Total file versions

## Common Tasks

### Create Repository from Scratch
```
CD RAM:
omi init
ECHO "# My Project" > README
omi add --all
omi commit -m "Initial commit"
omi push
```

### Clone and Work on Existing Project
```
omi clone wekan.omi
CD wekan
REM Edit files...
omi add --all
omi commit -m "My changes"
omi push
```

### Sync Latest Changes
```
omi pull
REM Now you have latest version
```

### View History
```
omi log 10          REM Last 10 commits
omi log             REM Last 20 commits (default)
```

## Two-Factor Authentication (2FA)

If 2FA is enabled for your user account, you'll see a dialog during push/pull:

```
+-----------------------------+
| 2FA Required                |
| OTP code needed for         |
| this user                   |
+-----------------------------+
[RequestString dialog]
Enter OTP code: 123456
[OK]
```

**Compatible with:**
- NumberStation (hardware TOTP generator)
- Any RFC 6238 compatible authenticator
- Time-based codes (30-second window)

**Tips:**
- Code is valid for 30 seconds
- Enter 6 digits including leading zeros
- If "Invalid OTP", check time synchronization on device
- Wait for new code if time window expires

## Network & HTTPS

### Using HTTPS

AmigaShell with AmiSSL support:

```
REPOS=http://localhost:8000
```

**Setup AmiSSL:**
- Install AmiSSL library
- curl will automatically use for https:// URLs
- Verify: `curl --version` shows SSL/TLS support

### Using HTTP (Unencrypted)

For local networks or testing:

```
REPOS=http://localhost:8080
```

**Warning:** Credentials will be transmitted unencrypted. Use HTTPS in production.

## Rate Limiting

If you exceed the server's rate limit (default: 60 requests/minute):

```
> omi push
Error: Rate limit exceeded.
Waiting 45 seconds...
[waits automatically]
Successfully pushed to [server]
```

CLI automatically:
- Detects rate limit from server
- Calculates wait time
- Waits in background
- Retries operation

## Troubleshooting

### Command not found
- Verify c:omi exists: `DIR c:omi`
- Check if executable: `PROTECT c:omi` to see flags
- Try: `c:omi status`

### "sqlite command not found"
- Install SQLite for Amiga
- Check path: `Path:` (shows all paths)
- Add to path: `Path c:` (if sqlite in c:)
- Verify: `Which sqlite`

### "curl command not found"
- Install curl for Amiga (with AmiTCP)
- MUI for GUI versions available
- Text-mode version: `curl`
- Verify: `Which curl`

### Push/Pull fails with "API is disabled"
- Server has set `API_ENABLED=0`
- Contact system administrator
- You cannot push/pull until API is re-enabled

### "Authentication failed"
```
REM Check settings.txt
Type settings.txt

REM Verify user exists
Type phpusers.txt
```

### OTP dialog won't appear
- Check if 2FA enabled for your user
- In phpusers.txt, your line should have 3rd field (otpauth URL)
- Example: `username:password:otpauth://TOTP/...`

### "AmiSSL not available"
- For HTTP only servers, this is fine
- For HTTPS, install AmiSSL library
- Or use HTTP if server supports both

### Database Lock

If database locked:

```
REM Check if process running
TASKLIST

REM Close AmigaShell or other omi process
REM Wait 10 seconds

REM Try again
omi status
```

## Advanced Usage

### Using Different Database

By default, first repository created becomes primary. To use different one:

```
REM Edit .omi file
ECHO "OMI_DB=other.omi" > .omi

REM Now commands use other.omi
omi status
omi log
```

### Manual Database Inspection

Inspect database directly with sqlite:

```
sqlite repo.omi

sqlite> SELECT * FROM commits;
sqlite> SELECT filename, size FROM files;
sqlite> SELECT COUNT(*) FROM blobs;
sqlite> .quit
```

### Shell Scripts

Create AmigaShell script files:

```
; myscript.omi
omi add --all
omi commit -m "Automated"
omi push
```

Run with:
```
EXECUTE myscript.omi
```

### Using with Workbench

Create project icon:

```
Icon Name: omi.project
Type: Project
Command: c:omi init
```

Click to run commands from GUI.

## Limitations

- No UNIX piping (Amiga limitation)
- Slower database operations on fast machines (optimized for smaller systems)
- OTP entry not password-masked (RequestString limitation)
- HTTPS requires AmiSSL installation
- Maximum path length ~256 characters (AmigaOS limitation)

## Platform-Specific Notes

### Memory Constraints

If low on memory:

```
OMI_LIMIT_ROWS 1000
omi log           REM Shows 1000 commits max
```

### AmiDOS vs AmiCLI

Both supported:

**AmigaCLI:**
```
omi init
```

**AmiDOS (shell):**
```
c:omi init
```

### Hard Drive vs RAM:

```
RAM Disk:
omi init        REM Fast, limited space

DH0: (Hard drive):
omi init        REM Persistent, slower
```

## Security Notes

**2FA (TOTP):**
- 6-digit codes valid for 30 seconds
- Time-synchronized with server
- Compatible with hardware generators

**Rate Limiting:**
- Per-user request tracking on server
- Default: 60 requests per 60 seconds
- CLI waits automatically

**API Control:**
- Server can disable API (`API_ENABLED=0`)
- Error shown when disabled
- Contact administrator for re-enabling

**Credentials:**
- Keep settings.txt in safe location
- Don't share password with others
- Use HTTPS when possible (AmiSSL)

**Password Security:**
- Use strong passwords (8+ characters minimum)
- Change regularly
- Enable 2FA for important accounts

---

**Other CLI Versions:** [CLI_PYTHON3.md](CLI_PYTHON3.md) | [CLI_HAXE5.md](CLI_HAXE5.md) | [CLI_CSHARP.md](CLI_CSHARP.md) | [CLI_BASH.md](CLI_BASH.md) | [CLI_BAT.md](CLI_BAT.md) | [CLI_LUA.md](CLI_LUA.md)  
