# Quick Start Guide

## Installation

### Prerequisites
- SQLite (with sha256 support)
- cURL (for remote operations)
- Bash (Linux), AmigaShell (Amiga), or CMD (FreeDOS)
- PHP 7.0+ (for web interface)

### Setup

1. **Clone repository**
```bash
git clone https://github.com/wekan/omi.git
cd omi
```

2. **Configure settings.txt**
```bash
SQLITE=sqlite           # Path to sqlite executable
USERNAME=user           # Default user
PASSWORD=pass           # Default password
REPOS=http://localhost  # Server URL
CURL=curl               # Path to curl
```

3. **Create first user in phpusers.txt**
```
myuser:mypassword
```

## CLI Quick Start (Bash)

### Initialize a Repository
```bash
./omi.sh init
# Creates repo.omi SQLite database
```

### Add Files
```bash
./omi.sh add --all
# Stages all files (except repo.omi and .omi)
# OR add specific file:
./omi.sh add README.md
```

### Commit Changes
```bash
./omi.sh commit -m "Initial commit"
# Creates commit record with timestamp and username
```

### Check Status
```bash
./omi.sh status
# Shows staged files and recent commits
```

### Push to Server
```bash
./omi.sh push
# Uploads repo.omi to server
# Requires REPOS, USERNAME, PASSWORD in settings.txt
```

### Pull from Server
```bash
./omi.sh pull
# Downloads latest repo.omi from server
```

### List Available Repos on Server
```bash
./omi.sh list
# Shows all .omi files available on server
```

### Clone a Repository
```bash
./omi.sh clone wekan.omi
# Downloads existing repository from server
```

## Web UI Quick Start

1. **Start Web Server**
   - Copy public/index.php to web root
   - Or use Caddy, Apache, or Nginx (see docs/webserver/)

2. **Visit Home Page**
   ```
   http://localhost/
   ```

3. **Create Account**
   - Click [Sign Up]
   - Enter username and password
   - User is added to phpusers.txt

4. **Sign In**
   - Click [Sign In]
   - Enter your credentials

5. **Browse Repositories**
   - Click repository name to browse
   - Click directory to navigate
   - Click file to view content

6. **Edit Text Files**
   - When logged in, click [Edit] on text file
   - Edit content in textarea
   - Click Save to commit
   - Creates new commit automatically

7. **View Images**
   - Images show with thumbnail link
   - Click to view full image

## Common Tasks

### Create a Repository from Scratch
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

## File Format

All repositories are stored as **SQLite database files** (.omi):
- **wekan.omi** - Repository containing all project files
- **code.omi** - Another repository
- **docs.omi** - Documentation repository

Each .omi file contains:
- Complete file history
- Commit metadata
- User information
- File deduplication by SHA256 hash

## Help

### Show Status
```bash
./omi.sh status
```

### List Available Commands
```bash
./omi.sh
# Shows usage and available commands
```

For complete documentation, see [COMPLETE_GUIDE.md](COMPLETE_GUIDE.md).
