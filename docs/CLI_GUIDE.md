# Command Line Interface Guide

## Overview

Omi CLI is available for:
- **Bash** (`omi.sh`)
- **FreeDOS** (`omi.bat`)
- **AmigaShell** (`omi`)

All three implementations support the same commands and work identically.

## Commands

### init - Initialize Repository

Creates a new Omi repository.

**Usage:**
```bash
./omi.sh init
```

**Result:**
- Creates `repo.omi` SQLite database
- Creates `.omi` file with database location
- Initializes database tables:
  - `blobs` - File content storage
  - `files` - File metadata
  - `commits` - Commit history
  - `staging` - Uncommitted changes

### add - Stage Files

Adds files to staging area for next commit.

**Usage:**
```bash
./omi.sh add --all           # Add all files
./omi.sh add README.md       # Add specific file
./omi.sh add src/main.c      # Add file in directory
```

**What it does:**
- Calculates SHA256 hash for each file
- Stores filename and hash in staging table
- Marks file as ready for commit

**Options:**
- `--all` - Add all files (except .omi and database)
- `<filename>` - Add specific file

### commit - Create Commit

Records staged changes as a commit.

**Usage:**
```bash
./omi.sh commit -m "Initial commit"
./omi.sh commit -m "Fix bug in parser"
```

**What it does:**
- Creates commit record with:
  - Message (from -m flag)
  - Current datetime
  - Username from settings.txt
- For each staged file:
  - Check if blob with hash exists
  - If not: insert blob with file content (deduplication)
  - Insert file metadata record
- Clears staging area

**Options:**
- `-m "message"` - Commit message (required)

### push - Upload to Server

Uploads repository to remote server.

**Usage:**
```bash
./omi.sh push
```

**Prerequisites:**
- `settings.txt` configured with:
  - REPOS - Server URL
  - USERNAME - Credentials
  - PASSWORD - Credentials
  - CURL - Path to curl executable

**What it does:**
- Uploads .omi file to server
- Authenticates with USERNAME/PASSWORD
- Server stores file at /repos/

### pull - Download from Server

Downloads latest repository from server.

**Usage:**
```bash
./omi.sh pull
```

**Prerequisites:**
- `settings.txt` configured
- Server must have repository

**What it does:**
- Downloads latest .omi file from server
- Replaces local database
- Overwrites any local commits not pushed

### clone - Copy Repository

Downloads repository from server.

**Usage:**
```bash
./omi.sh clone wekan.omi      # Clone remote repo
./omi.sh clone /path/to/repo.omi  # Clone local file
```

**What it does:**
- For local: copies .omi file
- For remote: downloads via HTTP
- Creates .omi config file
- Ready to use (no init needed)

### list - Show Available Repositories

Lists all repositories available on server.

**Usage:**
```bash
./omi.sh list
```

**What it does:**
- Connects to server (REPOS URL)
- Retrieves JSON list of repositories
- Displays names of all .omi files

### status - Show Current Status

Shows repository status and recent commits.

**Usage:**
```bash
./omi.sh status
```

**What it shows:**
- Staged files (waiting to be committed)
- Recent commits (last 5)
- Statistics:
  - Total blobs (deduplicated files)
  - Total file versions

## Configuration (settings.txt)

Required settings for remote operations:

```
SQLITE=sqlite              # SQLite executable path
USERNAME=user              # Default credentials
PASSWORD=pass              # Default credentials
REPOS=https://omi.wekan.fi # Server URL
CURL=curl                  # CURL executable path
```

### SQLITE
Path to SQLite executable:
- Linux: `/usr/bin/sqlite3` or just `sqlite`
- Amiga: `sqlite` or full path
- FreeDOS: `sqlite.exe` or full path

### USERNAME / PASSWORD
Credentials for server authentication:
- Used by `push` and `pull` commands
- Should match entry in phpusers.txt on server

### REPOS
Server URL:
- Example: `https://omi.wekan.fi`
- Must be accessible via HTTP/HTTPS
- Server must run `public/index.php`

### CURL
Path to CURL executable:
- Linux: `/usr/bin/curl` or just `curl`
- Amiga: path to curl
- FreeDOS: `curl.exe` or full path

## Database Files

### repo.omi (default) or custom name
SQLite database containing:

**blobs table:**
- `hash` - SHA256 hash (unique identifier)
- `data` - File content (BLOB)
- `size` - File size in bytes

**files table:**
- `id` - Record ID
- `filename` - Path and name
- `hash` - Reference to blob
- `datetime` - When file was committed
- `commit_id` - Which commit this file belongs to

**commits table:**
- `id` - Commit number
- `message` - Commit message
- `datetime` - When commit was made
- `user` - Username who made commit

**staging table:**
- `filename` - File to be added
- `hash` - SHA256 of file
- `datetime` - When file was staged

### .omi file
Configuration file pointing to database:
```
OMI_DB="repo.omi"
```

This allows scripts to find the database file.

## Workflow Examples

### Example 1: Create and Push Repository

```bash
# Initialize new repository
./omi.sh init

# Create some files
echo "# My Project" > README.md
echo "print('hello')" > main.py

# Stage all files
./omi.sh add --all

# Commit changes
./omi.sh commit -m "Initial commit"

# Show status
./omi.sh status

# Push to server
./omi.sh push
```

### Example 2: Clone and Pull

```bash
# Clone existing repository
./omi.sh clone wekan.omi

# Navigate to repository
cd wekan

# Check status
./omi.sh status

# Make changes...
echo "updated" >> README.md

# Stage change
./omi.sh add README.md

# Commit
./omi.sh commit -m "Update README"

# Push back to server
./omi.sh push
```

### Example 3: Sync Latest

```bash
# Get latest from server
./omi.sh pull

# Now database is up-to-date
# Add your changes...
./omi.sh add --all
./omi.sh commit -m "My changes"
./omi.sh push
```

## Deduplication

Omi automatically deduplicates identical files:

```
File 1: "hello world" → SHA256: abc123
File 2: "hello world" → SHA256: abc123 (same!)
```

**Result:**
- Blob stored only once
- File records reference same blob
- Saves storage space

## Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `Unknown command` | Typo in command | Check command name |
| `repo.omi not found` | No repository | Run `init` first |
| `Failed to clone` | Server unreachable | Check REPOS URL |
| `Authentication failed` | Wrong credentials | Check USERNAME/PASSWORD |
| `Failed to push` | Server error | Check server is running |

## Tips

1. **Always stage before commit:** `add` then `commit`
2. **Use meaningful messages:** `"Fixed login bug"`
3. **Push after commit:** Don't forget to `push`
4. **Pull before pushing:** `pull` first to sync changes
5. **Check status:** Use `status` to see what's staged
6. **Use --all:** `add --all` for convenience when adding many files

## Advanced

### Manual Database Inspection

You can inspect the .omi database with sqlite directly:

```bash
sqlite3 repo.omi
sqlite> SELECT * FROM commits;
sqlite> SELECT filename, size FROM files;
sqlite> .exit
```

### Specifying Different Database

The first file created/cloned becomes the default. To use a different one:

```bash
# Edit .omi file
echo 'OMI_DB="other.omi"' > .omi

# Now commands use other.omi
./omi.sh status
```
