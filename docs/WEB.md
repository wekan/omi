# Web Interface Guide

> **Documentation Index:** See [README.md](README.md) for documentation overview  
> **Quick Start:** See [README.md](README.md#installation-quick-reference)

## Overview

The Omi web interface is a PHP application that provides:
- Repository browsing
- File viewing and editing
- User account management
- Settings configuration
- Image viewing
- HTML 3.2 compatible for retro browsers

## Accessing the Web UI

### URLs

| URL | Purpose |
|-----|---------|
| `/` | Home - list all repositories |
| `/reponame` | Browse repository root directory |
| `/reponame/path/to/file.txt` | View file content |
| `/sign-in` | User login |
| `/sign-up` | Create new account |
| `/logout` | Sign out |
| `/settings` | Edit configuration (admin only) |
| `/people` | Manage users (admin only) |
| `/?image=reponame/path/image.jpg` | View image |

## Authentication

### Sign Up (Register)
1. Click [Sign Up] from home page
2. Enter username (3+ characters)
3. Enter password
4. Confirm password
5. Click "Create Account"
6. Account added to phpusers.txt

### Sign In
1. Click [Sign In] from home page
2. Enter username
3. Enter password
4. Click "Sign In"
5. Creates PHP session

### Sign Out
1. Click [Logout] button (top right)
2. Session destroyed
3. Redirected to home

## Repository Browsing

### View Repository
- Click repository name on home page
- Shows root directory contents
- Lists subdirectories and files
- Files show size and last modified date

### Navigate Directories
- Click on directory name to open
- Breadcrumb shows current path
- Click [Repository Root] to go back to root

### View Files

#### Text Files (.txt, .md, .html, .php, etc.)
- Displayed in <pre> tag (monospace)
- Shows complete file content
- When logged in, shows [Edit] button

#### Image Files (.jpg, .png, .gif, .bmp)
- Shows image icon (🖼️) in directory listing
- Click to view full image
- Displays with HTML 3.2 compatible layout

#### Binary Files (executable, .zip, .rar, etc.)
- Shows file size in bytes
- Shows SHA256 hash
- Not directly viewable

## File Editing

### Edit a Text File
1. View text file
2. Click [Edit] button (must be logged in)
3. Textarea appears with file content
4. Make your changes
5. Click [Save]
6. New commit created automatically

### Cancel Editing
1. Click [Cancel] to discard changes
2. Returns to viewing mode

#### Markdown Files (.md)
- **Markdown rendering** - Automatically convert markdown to HTML
- **Preview styled** - Displays formatted text, headers, bold, italic, links, lists, code blocks
- **Source view** - Shows original markdown when logged in
- **Edit support** - Can edit markdown source (changes create new commit)

#### SVG Files (.svg)
- **Vector graphics support** - Display scalable SVG images
- **Security scanning** - Automatically checks for dangerous JavaScript and XML entities
- **Safety warning** - Shows alert if SVG contains suspicious content
- **GIF fallback** - For browsers without native SVG support, automatically converts using ImageMagick
- **Source available** - When logged in, can view and edit SVG source code

#### Audio Files (.mp3, .ogg, .wav, .flac, etc.)
- **Native HTML5 player** - Built-in audio controls
- **No JavaScript required** - Works in HTML 3.2 browsers
- **Standard controls** - Play, pause, volume, seek
- **Fallback download** - For very old browsers, shows download link

#### Video Files (.mp4, .webm, .ogv, .mov, etc.)
- **Native HTML5 player** - Built-in video controls with full player UI
- **No JavaScript required** - Works in HTML 3.2 compliant browsers
- **Standard controls** - Play, pause, volume, fullscreen, seek
- **Fallback download** - For unsupported formats, shows download link

## File Upload

### Upload a File
1. Navigate to desired directory
2. Scroll to "Upload New File" form (must be logged in)
3. Enter filename (e.g., `document.txt`, `image.png`)
4. Enter file content (paste for text, or upload button for images)
5. Click [Upload]
6. File added to repository with new commit

### Commit Information
When you upload a file:
- **Message**: "Uploaded: filename"
- **Author**: Your username
- **Datetime**: Current timestamp
- **Deduplication**: Identical content reuses existing blob (same file twice = 1 blob)

### Supported Upload Types
- Text files (.txt, .md, .html, .php, .sh, .bat, .asm, etc.)
- Images (.jpg, .png, .gif, .bmp, .svg, etc.)
- Archives (.zip, .rar, .7z, .tar, .gz, etc.)
- Media (.mp3, .ogg, .wav, .mp4, .webm, .flv, etc.)
- Any file type (binary safe)

## File Download

### Download a File
1. Navigate to file in repository
2. Click file name or link
3. File details displayed
4. Click [Download] button
5. File downloaded to your computer

### What Gets Downloaded
- **Text files** - Original unchanged text
- **Images** - Original image file in native format
- **Archives** - Original archive file
- **Media** - Original audio/video file
- **Any file** - Byte-for-byte copy from repository

### SHA256 Verification
- File SHA256 hash displayed
- Verify integrity after download if needed
- Deduplication uses this hash

## File Deletion

### Delete a File
1. Navigate to file in repository
2. Must be logged in
3. Click [Delete] button
4. Confirmation page appears
5. Review filename and confirm deletion
6. Click [Confirm Delete]
7. File marked as deleted (creates "Deleted" commit)

### Commit Information
When you delete a file:
- **Message**: "Deleted: filename"
- **Author**: Your username
- **Datetime**: Current timestamp
- **History preserved** - File still exists in commit history (can be recovered)
- **No blob deletion** - File content remains in database (may be needed by other commits)

## Image Viewing

### View Image
1. Browse to directory containing image
2. Image shows with thumbnail icon (🖼️)
3. Click image name
4. Full image displayed in browser
5. Shows image info and navigation

### Supported Formats
- .jpg / .jpeg
- .png
- .gif
- .bmp

## User Management (/people)

**Requires login to access. User must exist in phpusers.txt**

### View All Users
- Lists all usernames
- Shows [Delete] and [Edit] options

### Add New User
1. Scroll to "Add New User" section
2. Enter username (3+ characters)
3. Enter password
4. Click [Add User]
5. User added to phpusers.txt

### Edit User Password
1. Click [Edit] button next to username
2. Edit form appears
3. Enter new password
4. Click [Update]
5. Password changed in phpusers.txt

### Delete User
1. Click [Delete] button
2. Confirmation dialog appears
3. Confirm deletion
4. User removed from phpusers.txt

## Settings (/settings)

**Requires login to access. User must exist in phpusers.txt**

### Edit Configuration
1. Go to /settings
2. Form shows current settings from settings.txt
3. Edit any field:
   - **SQLITE**: Path to sqlite executable
   - **USERNAME**: Default username for CLI
   - **PASSWORD**: Default password for CLI
   - **REPOS**: Server URL
   - **CURL**: Path to curl executable
4. Click [Save Settings]
5. Changes written to settings.txt

### Settings File Location
- `/home/wekan/repos/wekan/settings.txt` (production)
- Settings file is not web-accessible for security

## Navigation

### Top Bar
Displayed on every page:

```
[Home] | [Settings] | [People]
                                    [Username] | [Logout]
```

Or when not logged in:
```
[Home] | [Settings] | [People]
                                    [Sign In]
```

### Directory Navigation
When viewing repository:
```
[Home] | [Settings] | [People] | [Repository Root]
```

## Browser Compatibility

The web interface is HTML 3.2 compatible for maximum browser support:

| Browser | Platform | Status |
|---------|----------|--------|
| IBrowse + AmiSSL | Amiga | ✓ Full |
| Dillo | FreeDOS | ✓ Full |
| Elinks | Linux | ✓ Full (text mode) |
| w3m | Linux | ✓ Full (text mode) |
| Firefox | All | ✓ Full |
| Chrome | All | ✓ Full |
| Safari | Mac/iOS | ✓ Full |

## Data Storage

### Sessions
- Uses PHP sessions (server-side)
- Session data in temporary directory
- Cleared on logout

### Repositories
- Stored in `repos/` directory
- Each repo is a .omi SQLite file
- Files are deduplicated by SHA256 hash

### Users
- Stored in `phpusers.txt`
- Format: `username:password`
- Plain text, one per line

### Settings
- Stored in `settings.txt`
- Format: `KEY=value`
- Not web-accessible

## Troubleshooting

### Can't Log In
- Check phpusers.txt has correct username:password
- Verify password is correct
- Create new account with [Sign Up]

### Can't Edit Files
- Must be logged in (shows "🔓 locked" when not logged in)
- Only logged-in users can edit
- Check file is text format (not binary)

### Settings Not Saving
- Check web server has write permission to settings.txt
- Click [Save Settings] again
- Check error messages

### Users Not Appearing
- Check phpusers.txt file exists
- Verify file has correct format: username:password
- Restart web server

## Security Notes

- Credentials should use HTTPS in production
- Settings.txt is protected from direct web access
- phpusers.txt is protected from direct web access

---

## See Also

- **[README.md](README.md)** - Documentation index
- **[FEATURES.md](FEATURES.md)** - Web interface features
- **[CLI_PYTHON3.md](CLI_PYTHON3.md)** - CLI alternative (Python 3)
- **[CLI_HAXE5.md](CLI_HAXE5.md)** - CLI alternative (Haxe 5)
- **[CLI_CSHARP.md](CLI_CSHARP.md)** - CLI alternative (C# / Mono)
- **[CLI_BASH.md](CLI_BASH.md)** - CLI alternative (Bash)
- **[CLI_BAT.md](CLI_BAT.md)** - CLI alternative (FreeDOS)
- **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** - CLI alternative (Amiga)
- **[CLI_LUA.md](CLI_LUA.md)** - CLI alternative (Lua)
- **[SERVER.md](SERVER.md)** - Web server configuration
- **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** - Database design

**Notes:**
- Sessions are server-side (no client-side cookies)
- Use strong passwords in production
