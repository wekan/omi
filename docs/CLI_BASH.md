# Bash CLI (omi.sh)

> **Documentation:** [README.md](README.md) | [FEATURES.md](FEATURES.md) | [WEB.md](WEB.md) | [SERVER.md](SERVER.md) | [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)  
> **CLI Options:** [CLI_BASH.md](CLI_BASH.md) | [CLI_BAT.md](CLI_BAT.md) | [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)

The Bash implementation (`omi.sh`) runs on Linux, macOS, Unix and any system with Bash 3.0+.

## Installation

### Prerequisites
- Bash shell (version 3.0+)
- SQLite (with sha256 support)
- cURL (for remote operations)

**Verify Installation:**
```bash
bash --version
which sqlite3
which curl
```

### Setup

1. Clone repository:
```bash
git clone https://github.com/wekan/omi.git
cd omi
chmod +x omi.sh
```

2. Configure settings.txt:
```
SQLITE=sqlite3          # Path to sqlite executable
USERNAME=user           # Default user
PASSWORD=pass           # Default password
REPOS=http://localhost  # Server URL
CURL=curl               # Path to curl
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
```bash
./omi.sh init
# Creates repo.omi SQLite database
```

### Add and Commit Files
```bash
./omi.sh add --all
# Stages all files (except repo.omi and .omi)

./omi.sh commit -m "Initial commit"
# Creates commit record with timestamp and username
```

### Check Status
```bash
./omi.sh status
# Shows staged files and recent commits

./omi.sh log
# View commit history (default: last 20 commits)
```

### Sync with Server
```bash
./omi.sh push
# Uploads repo.omi to server
# If 2FA enabled, prompts for OTP code
# Respects rate limiting from server

./omi.sh pull
# Downloads latest repo.omi from server
# If 2FA enabled, prompts for OTP code
```

### List and Clone
```bash
./omi.sh list
# Shows all .omi files available on server

./omi.sh clone wekan.omi
# Downloads existing repository from server
```

## Complete Command Reference

### init

Initializes a new Omi repository.

```bash
./omi.sh init
```

**Creates:**
- `repo.omi` - SQLite database file
- `.omi` - Database location reference file
- Tables: blobs, files, commits, staging
- Indexes for optimized queries

### add

Stages files for commit.

```bash
./omi.sh add --all              # Add all files
./omi.sh add README.md          # Add specific file
./omi.sh add src/main.c         # Add file in directory
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

```bash
./omi.sh commit -m "Initial commit"
./omi.sh commit -m "Fix bug in parser"
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

```bash
./omi.sh push
```

**Prerequisites:**
- `settings.txt` with REPOS, USERNAME, PASSWORD configured
- Network access to repository server
- API_ENABLED = 1 on server

**Interactive Prompts:**
- If 2FA enabled: "Enter OTP code (6 digits):"
- Waits for 6-digit authenticator code before uploading

**Handles Automatically:**
- Rate limiting (waits and retries if needed)
- API disabled responses (shows clear error)
- OTP validation errors (allows retry)

**Returns:**
- Success: "Successfully pushed to $REPOS"
- Failure: Error message from server

### pull

Downloads latest repository from server.

```bash
./omi.sh pull
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
- Success: "Successfully pulled from $REPOS"
- Failure: Error message from server

### list

Lists available repositories on remote server.

```bash
./omi.sh list
```

**Output:**
Shows filenames of all .omi files on the server.

**Prerequisites:**
- REPOS configured in settings.txt
- Network access

### clone

Clones an existing repository from server or local path.

```bash
./omi.sh clone wekan.omi         # From remote server
./omi.sh clone /path/to/repo.omi # From local path
```

**What it does:**
- For local files: copies repository file
- For remote: downloads from REPOS server
- Creates .omi file with database reference
- Sets up local working directory

### log

Views commit history with optional limit.

```bash
./omi.sh log              # Show last 20 commits (default)
./omi.sh log 50           # Show last 50 commits
./omi.sh log 100          # Show last 100 commits
```

**Output Format:**
- Commit: ID (Author)
- Date: Timestamp
- Message: Commit message
- Files: Number of files in commit

**Options:**
- `[limit]` - Number of commits to display (default: 20, max: 1000)

### status

Shows repository status and statistics.

```bash
./omi.sh status
```

**Shows:**
- Staged files (awaiting commit)
- Recent commits (last 5)
- Statistics:
  - Total blobs (deduplicated files)
  - Total file versions

## Common Tasks

### Create Repository from Scratch
```bash
mkdir myproject
cd myproject
../omi.sh init
echo "# My Project" > README.md
../omi.sh add --all
../omi.sh commit -m "Initial commit"
../omi.sh push
```

### Clone and Work on Existing Project
```bash
../omi.sh clone wekan.omi
cd wekan
# Edit files...
../omi.sh add --all
../omi.sh commit -m "My changes"
../omi.sh push
```

### Sync Latest Changes
```bash
../omi.sh pull
# Now you have latest version
```

### View History
```bash
./omi.sh log 10          # Last 10 commits
./omi.sh log             # Last 20 commits (default)
```

## Two-Factor Authentication (2FA)

If 2FA is enabled for your user account, you'll be prompted for an OTP code during push/pull:

```bash
$ ./omi.sh push
Pushing repo.omi to remote...
2FA Required
Enter OTP code (6 digits): 123456
Successfully pushed to https://omi.wekan.fi
```

**Using with Authenticators:**
- Google Authenticator
- Authy
- Authenticator Pro
- Any RFC 6238 compatible app

**Tips:**
- Code is valid for 30 seconds
- Enter code within time window
- If "Invalid OTP" appears, wait for new code

## Rate Limiting

If you exceed the server's rate limit (default: 60 requests/minute):

```bash
$ ./omi.sh push
Error: Rate limit exceeded. Waiting 45s...
[waits automatically]
Successfully pushed to https://omi.wekan.fi
```

CLI automatically:
- Detects rate limit response
- Reads `Retry-After` header
- Waits specified seconds
- Retries operation

## Troubleshooting

### "command not found: omi.sh"
```bash
# Make sure it has execute permissions
chmod +x omi.sh

# Run with ./
./omi.sh status
```

### "sqlite3: command not found"
```bash
# Install SQLite
# macOS:
brew install sqlite

# Ubuntu/Debian:
sudo apt-get install sqlite3

# Then update settings.txt:
SQLITE=sqlite3
```

### "curl: command not found"
```bash
# Install curl
# macOS:
brew install curl

# Ubuntu/Debian:
sudo apt-get install curl
```

### Push/Pull fails with "API is disabled"
- Server has set `API_ENABLED=0` in settings.txt
- Contact server administrator
- You cannot push/pull until API is re-enabled

### "Authentication failed"
```bash
# Check credentials in settings.txt
grep USERNAME settings.txt
grep PASSWORD settings.txt

# Verify user exists on server
cat phpusers.txt
```

### "OTP_REQUIRED" or "Invalid OTP"
- Check authenticator app shows correct time
- Verify 6-digit code is correct
- Try again with new code (codes expire after 30 seconds)

## Advanced Usage

### Using Different Database

By default, first repository created becomes primary. To use different one:

```bash
# Edit .omi file
echo 'OMI_DB="other.omi"' > .omi

# Now commands use other.omi
./omi.sh status
./omi.sh log
```

### Manual Database Inspection

Inspect database directly with sqlite:

```bash
sqlite3 repo.omi

sqlite> SELECT * FROM commits;
sqlite> SELECT filename, size FROM files;
sqlite> SELECT COUNT(*) FROM blobs;
sqlite> .exit
```

### Bash Functions

Use in shell scripts:

```bash
# Source the script
source omi.sh

# Call functions directly
init_db
add_files --all
commit_files -m "Message"
push_changes
pull_changes
```

### Batch Operations

Add multiple files:

```bash
./omi.sh add file1.txt
./omi.sh add file2.txt
./omi.sh add file3.txt
./omi.sh commit -m "Add multiple files"
./omi.sh push
```

## Security Notes

**2FA (TOTP):**
- 6-digit codes valid for 30 seconds
- Time-synchronized via NTP
- Compatible with standard authenticator apps

**Rate Limiting:**
- Per-user request tracking on server
- Default: 60 requests per 60 seconds
- Automatic retry on rate limit

**API Control:**
- Server can disable API entirely (`API_ENABLED=0`)
- Clear error messages when disabled
- Check with administrator for re-enabling

**Credentials:**
- Store settings.txt safely
- Never commit credentials to public repos
- Use HTTPS for remote operations

**Password Security:**
- Use strong passwords (20+ characters)
- Change regularly
- Enable 2FA for important accounts

---

**Other CLI Versions:** [CLI_BAT.md](CLI_BAT.md) | [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)  
**See Also:** [WEB.md](WEB.md) | [SERVER.md](SERVER.md) | [FEATURES.md](FEATURES.md) | [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) | [README.md](README.md)
