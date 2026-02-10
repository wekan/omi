# FreeDOS Batch CLI (omi.bat)

> **Documentation:** [README.md](README.md) | [FEATURES.md](FEATURES.md) | [WEB.md](WEB.md) | [SERVER.md](SERVER.md) | [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)  
> **CLI Options:** [CLI_BASH.md](CLI_BASH.md) | [CLI_BAT.md](CLI_BAT.md) | [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)

The Batch implementation (`omi.bat`) runs on FreeDOS, MS-DOS, and Windows CMD.

## Installation

### Prerequisites
- FreeDOS or MS-DOS (or Windows CMD)
- SQLite executable (sqlite.exe or sqlite3.exe)
- curl executable (curl.exe)

**Verify Installation:**
```batch
SQLITE --version
curl --version
```

### Setup

1. Copy files to your directory:
```batch
COPY omi.bat C:\OMI\
CD C:\OMI
```

2. Configure settings.txt:
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
```batch
omi init
REM Creates repo.omi SQLite database
```

### Add and Commit Files
```batch
omi add --all
REM Stages all files (except repo.omi and .omi)

omi commit -m "Initial commit"
REM Creates commit record with timestamp and username
```

### Check Status
```batch
omi status
REM Shows staged files and recent commits

omi log
REM View commit history
```

### Sync with Server
```batch
omi push
REM Upload to server
REM If 2FA enabled, prompts for OTP code

omi pull
REM Download from server
REM If 2FA enabled, prompts for OTP code
```

### List and Clone
```batch
omi list
REM Shows all .omi files available on server

omi clone wekan.omi
REM Download repository from server
```

## Complete Command Reference

### init

Initializes a new Omi repository.

```batch
omi init
```

**Creates:**
- `repo.omi` - SQLite database file
- `.omi` - Database location reference file
- Tables: blobs, files, commits, staging
- Indexes for optimized queries

### add

Stages files for commit.

```batch
omi add --all              REM Add all files
omi add README.MD          REM Add specific file
omi add SRC\MAIN.C         REM Add file in directory
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

```batch
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

```batch
omi push
```

**Prerequisites:**
- `settings.txt` with REPOS, USERNAME, PASSWORD configured
- Network access to repository server
- API_ENABLED = 1 on server

**Interactive Prompts:**
- If 2FA enabled: "Enter OTP code (6 digits):"
- Wait for 6-digit authenticator code before uploading

**Handles Automatically:**
- Rate limiting (waits and retries if needed)
- API disabled responses (shows error message)
- OTP validation errors (allows retry)

**Returns:**
- Success: "Successfully pushed to %REPOS%"
- Failure: Error message from server

### pull

Downloads latest repository from server.

```batch
omi pull
```

**Prerequisites:**
- `settings.txt` with REPOS, USERNAME, PASSWORD
- Network access to repository server
- API_ENABLED = 1 on server

**Interactive Prompts:**
- If 2FA enabled: "Enter OTP code (6 digits):"

**What it does:**
- Connects to remote server
- Authenticates with username and password
- Prompts for OTP if 2FA enabled
- Downloads latest .omi file
- Replaces local database with server version

**Returns:**
- Success: "Successfully pulled from %REPOS%"
- Failure: Error message from server

### list

Lists available repositories on remote server.

```batch
omi list
```

**Output:**
Shows filenames of all .omi files on the server.

**Prerequisites:**
- REPOS configured in settings.txt
- Network access

### clone

Clones an existing repository from server or local path.

```batch
omi clone wekan.omi         REM From remote server
omi clone C:\REPO\REPO.OMI  REM From local path
```

**What it does:**
- For local files: copies repository file
- For remote: downloads from REPOS server
- Creates .omi file with database reference
- Sets up local working directory

### log

Views commit history with optional limit.

```batch
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

```batch
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
```batch
MD MYPROJECT
CD MYPROJECT
..\omi init
ECHO # My Project > README.MD
..\omi add --all
..\omi commit -m "Initial commit"
..\omi push
```

### Clone and Work on Existing Project
```batch
..\omi clone wekan.omi
CD WEKAN
REM Edit files...
..\omi add --all
..\omi commit -m "My changes"
..\omi push
```

### Sync Latest Changes
```batch
..\omi pull
REM Now you have latest version
```

### View History
```batch
omi log 10          REM Last 10 commits
omi log             REM Last 20 commits (default)
```

## Two-Factor Authentication (2FA)

If 2FA is enabled for your user account, you'll be prompted for an OTP code during push/pull:

```batch
C:\OMI> omi push
Pushing repo.omi to remote...
Enter OTP code (6 digits): 123456
Successfully pushed to http://omi.wekan.fi
```

**Using with Authenticators:**
- Google Authenticator
- Microsoft Authenticator
- Authy
- Any RFC 6238 compatible app

**DOS/Retro Authenticators:**
- NumberStation (dedicated hardware)
- Text-based TOTP generators

**Tips:**
- Code is valid for 30 seconds
- Enter code within time window
- If "Invalid OTP" appears, wait for new code

## Rate Limiting

If you exceed the server's rate limit (default: 60 requests/minute):

```batch
C:\OMI> omi push
Error: Rate limit exceeded. Waiting 45 seconds...
[waits automatically]
Successfully pushed to http://omi.wekan.fi
```

CLI automatically:
- Detects rate limit response from server
- Waits specified number of seconds
- Retries operation

## Troubleshooting

### "Bad command or file name"
- Make sure omi.bat is in current directory or PATH
- Try: `omi.bat status`
- Or navigate to omi.bat directory first

### "sqlite: command not found"
- Install SQLite executable
- Add to PATH or update settings.txt with full path
- Verify: `WHERE SQLITE.EXE`

### "curl: command not found"
- Install curl executable
- Add to PATH or update settings.txt with full path
- Verify: `WHERE CURL.EXE`

### Push/Pull fails with "API is disabled"
- Server has set `API_ENABLED=0` in settings.txt
- Contact server administrator
- You cannot push/pull until API is re-enabled

### "Authentication failed"
```batch
REM Check credentials in settings.txt
FIND "USERNAME=" settings.txt
FIND "PASSWORD=" settings.txt

REM Verify user exists on server
TYPE phpusers.txt
```

### "OTP_REQUIRED" or "Invalid OTP"
- Check authenticator shows correct time
- Verify 6-digit code is correct
- Try again with new code (codes expire after 30 seconds)

### Database Lock Errors
- Another process using the database
- Close all instances of omi
- Wait a few seconds and retry
- Check no SQLite processes still running: `TASKLIST | FIND "SQLITE"`

## Advanced Usage

### Using Different Database

By default, first repository created becomes primary. To use different one:

```batch
REM Edit .omi file
ECHO OMI_DB=other.omi > .omi

REM Now commands use other.omi
omi status
omi log
```

### Manual Database Inspection

Inspect database directly with sqlite:

```batch
sqlite repo.omi

sqlite> SELECT * FROM commits;
sqlite> SELECT filename, size FROM files;
sqlite> SELECT COUNT(*) FROM blobs;
sqlite> .exit
```

### Batch Scripts

Automate multiple operations:

```batch
omi add --all
omi commit -m "Automated commit"
omi push
```

### Environment Variables

Set common settings:

```batch
SET SQLITE=sqlite.exe
SET CURL=curl.exe
SET USERNAME=myuser
SET PASSWORD=mypass
SET REPOS=http://omi.server.com

omi push
```

## Limitations

- No piping between commands (Windows batch limitation)
- Slower than Unix implementations due to batch overhead
- Rate limiting handled via delay loops, not system sleep
- OTP entry uses simple text prompt (no password masking)

## Security Notes

**2FA (TOTP):**
- 6-digit codes valid for 30 seconds
- Time-synchronized 
- Compatible with standard authenticator hardware

**Rate Limiting:**
- Per-user request tracking on server
- Default: 60 requests per 60 seconds
- Manual wait on rate limit

**API Control:**
- Server can disable API entirely (`API_ENABLED=0`)
- Error shown when disabled
- Talk to administrator for re-enabling

**Credentials:**
- Store settings.txt safely
- Never share with others
- Use HTTPS for remote operations

**Password Security:**
- Use strong passwords
- Change regularly
- Enable 2FA for important accounts

---

**Other CLI Versions:** [CLI_BASH.md](CLI_BASH.md) | [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)  
**See Also:** [WEB.md](WEB.md) | [SERVER.md](SERVER.md) | [FEATURES.md](FEATURES.md) | [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) | [README.md](README.md)
