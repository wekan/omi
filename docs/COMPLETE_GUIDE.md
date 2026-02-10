# Omi Version Control System - Complete Implementation

## Overview
Omi is a Git-like version control system that stores files in SQLite databases (.omi files) instead of traditional .git folders. It works across **AmigaShell** (Amiga), **FreeDOS .bat** (DOS), **Bash** (Linux/Unix), and includes a **PHP web interface**.

## Key Features

### 1. File Storage & Deduplication
- Files are stored as **BLOB data** in SQLite
- **SHA256 hashing** ensures the same file content is stored only once
- **File metadata** (filename, datetime, commit ID) is stored separately in the `files` table
- **Commit history** is tracked in the `commits` table

### 2. Database Schema

```
blobs:
  - hash (TEXT PRIMARY KEY)
  - data (BLOB)
  - size (INTEGER)

files:
  - id (INTEGER PRIMARY KEY)
  - filename (TEXT)
  - hash (TEXT)
  - datetime (TEXT)
  - commit_id (INTEGER)

commits:
  - id (INTEGER PRIMARY KEY)
  - message (TEXT)
  - datetime (TEXT)
  - user (TEXT)

staging:
  - filename (TEXT PRIMARY KEY)
  - hash (TEXT)
  - datetime (TEXT)
```

### 3. Configuration (/home/wekan/repos/wekan/settings.txt)

```
SQLITE=sqlite
USERNAME=user
PASSWORD=pass
REPOS=https://omi.wekan.fi
CURL=curl
```

### 4. Users (/home/wekan/repos/wekan/phpusers.txt)

```
username1:password1
username2:password2
```

## CLI Commands

### AmigaShell (`omi`)
```
omi init              # Initialize repository
omi clone <repo>     # Clone repository
omi add --all        # Stage all files
omi commit -m "msg"  # Commit staged files
omi push             # Push to server
omi pull             # Pull from server
omi list             # List available repos
omi status           # Show status
```

### FreeDOS (omi.bat)
Similar to AmigaShell, but uses WAT syntax.

### Bash (omi.sh)
```bash
./omi.sh init
./omi.sh add --all
./omi.sh commit -m "Initial commit"
./omi.sh push
./omi.sh pull
./omi.sh list
```

## Web Interface (public/index.php)

### Authentication
- **URL:** `/sign-in`
- Login with credentials from phpusers.txt
- **URL:** `/sign-up`
- Create new accounts
- **URL:** `/logout`
- Sign out

### Repository Management
- **URL:** `/` - Browse repositories
- **URL:** `/reponame` - Browse repository root
- **URL:** `/reponame/path/to/file` - View file/directory

### File Editing
- Click `[Edit]` on text files when logged in
- Edit in HTML 3.2 textarea
- Save creates new commit with:
  - Username from session
  - Current datetime
  - Commit message: "Edited: filename"
  - File deduplicated by hash

### Image Viewing
- **URL:** `/?image=reponame/path/to/image.jpg`
- Displays images with HTML 3.2 table layout
- Shows file info and navigation

### Settings Management
- **URL:** `/settings` (login required)
- Edit SQLITE, USERNAME, PASSWORD, REPOS, CURL variables
- Saves to settings.txt

### User Management
- **URL:** `/people` (login required)
- View all users
- Add new users
- Edit user passwords
- Delete users
- Saves to phpusers.txt

### Navigation Bar
All pages show:
```
[Home] | [Settings] | [People] | [Repository Root]
```
Top-right corner shows:
- Username and [Logout] when logged in
- [Sign In] when not logged in

## HTML 3.2 Compatibility

All web pages use HTML 3.2 without CSS for maximum compatibility with:
- **IBrowse + AmiSSL** (Amiga)
- **Dillo** (FreeDOS)
- **Elinks / w3m** (Bash/Linux)

Table-based layout, no JavaScript, simple forms.

## File Types

### Text Files
- Viewed as `<pre>` content
- Editable when logged in
- Shows [Edit] button

### Image Files (.jpg, .jpeg, .png, .gif, .bmp)
- Shows image icon in directory listing
- Clickable to view full image
- Image displayed using base64 data URL

### Binary Files
- Shows file size and SHA256 hash
- Not editable

## Server Setup

See `SERVER_SETUP.md` for configuration with:
- **Caddy** (recommended)
- **Apache** (.htaccess or VirtualHost)
- **Nginx** (server block)

### Pretty URLs
All requests without file extensions are rewritten to `index.php`:
- `/` → index.php (repository list)
- `/wekan` → index.php?repo=wekan (browse repo)
- `/wekan/file.txt` → index.php?repo=wekan&path=file.txt (view file)
- `/settings` → index.php?page=settings (settings)
- `/people` → index.php?page=people (user management)
- `/sign-in` → index.php?page=sign-in (login)
- `/sign-up` → index.php?page=sign-up (register)

## Data Flow

### Adding and Committing Files (CLI)

```
1. omi add --all
   ├─ Calculates SHA256 hash for each file
   ├─ Gets current datetime
   └─ Inserts into staging table

2. omi commit -m "Initial commit"
   ├─ Gets commit ID
   ├─ For each staged file:
   │  ├─ Check if blob with hash exists
   │  ├─ If not, insert blob with file content
   │  └─ Insert file metadata record
   └─ Clear staging area

3. omi push
   ├─ Uploads database file to server
   ├─ Authenticates with USERNAME/PASSWORD
   └─ Stores at /repos/reponame.omi
```

### Editing Files (Web UI)

```
1. Browse to /reponame/file.txt
2. Click [Edit]
3. Modify content in textarea
4. Click Save
   ├─ Calculate new SHA256 hash
   ├─ Check if blob exists (deduplication)
   ├─ If new: insert blob
   ├─ Create commit record with username
   └─ Insert file metadata
```

### Cloning and Pulling

```
1. omi clone reponame
   ├─ Download .omi file from server
   └─ Create .omi file with database reference

2. omi pull
   ├─ Download latest database
   └─ Replace local database
```

## Security

- Repositories are stored in `/repos/` (password protected)
- Settings file (`settings.txt`) is protected from web access
- Users file (`phpusers.txt`) is not web-accessible
- HTTP/HTTPS authentication for web UI
- Shell script authentication via username/password for remote operations

## Browser Compatibility

| Browser | Platform | Support |
|---------|----------|---------|
| IBrowse | Amiga | Full (HTML 3.2) |
| Dillo | FreeDOS | Full (HTML 3.2) |
| Elinks | Linux | Full (text mode) |
| w3m | Linux | Full (text mode) |
| Firefox | All | Full (HTML 5) |
| Chrome | All | Full (HTML 5) |

## Limitations & Future Work

### Current Limitations
- Merge conflicts not handled
- No branching support
- Local-only operations on CLI
- Single user per repository at a time

### Roadmap
- [ ] Branching support
- [ ] Merge conflict resolution
- [ ] Diff viewer
- [ ] Blame viewer
- [ ] Tag support
- [ ] Access control per user
- [ ] Repository permissions
- [ ] Webhook support
