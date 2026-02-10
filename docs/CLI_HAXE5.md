# Command Line Interface: Haxe 5

> **Documentation Index:** See [README.md](README.md) for documentation overview  
> **Quick Start:** See [README.md](README.md#installation-quick-reference)

## Overview

The Omi Haxe 5 CLI is a typed, cross-platform version control tool implemented in Haxe 5 programming language. Haxe compiles to native binaries and multiple targets, making it ideal for high-performance applications while maintaining static type safety.

### Key Features
- **Typed language** - Catches errors at compile time
- **Multi-target compilation** - Compile to native binary, Python, JavaScript, C++, C#, Java, etc.
- **High performance** - Compiled executable is faster than interpreted languages
- **Single source code** - Compile from omi.hx to multiple target platforms
- **Cross-platform** - Same code compiles on Windows, macOS, Linux

### Platform Support
- **Linux/Unix/macOS** - Native binary via C++ or native target
- **Windows** - Native binary via C++ or compiled .exe
- **Embedded systems** - Can compile to C++ for embedded platforms
- **WebAssembly** - Can compile to WASM for browser environments
- **Performance-critical applications** - Suitable for high-frequency operations
- **Development environments** - Integrate into Haxe-based projects

### Requirements
- **Haxe 5.0+** - Compiler from [haxe.org](https://haxe.org/)
- **SQLite 3.0+** - For database operations (built-in via Haxe)
- **curl** - For remote push/pull operations
- **settings.txt** - Configuration file in project directory
- **C++ compiler** - For native compilation (g++, clang, MSVC, etc.)

### Why Haxe 5?
- **Static typing** - Type safety with compile-time error checking
- **Performance** - Compiled executables are fast and efficient
- **Multiple targets** - Single source, multiple deployment options
- **Cross-platform** - Same code compiles everywhere
- **Professional** - Used in commercial game development
- **Mature ecosystem** - Rich standard library and extensions

## Installation

### 1. Install Haxe 5

**macOS (Homebrew):**
```bash
brew install haxe
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install haxe
```

**Linux (Fedora/RHEL):**
```bash
sudo dnf install haxe
```

**Windows (Chocolatey):**
```powershell
choco install haxe
```

**Direct Download:**
Download from https://haxe.org/download/ and install according to documentation.

### 2. Verify Installation

```bash
haxe --version
# Should output: version 5.x.x or later
```

### 3. Compile omi.hx

**To native binary (C++ backend):**
```bash
haxe -main Omi -cpp output --each -cp .
./output/Omi init
```

**To Python:**
```bash
haxe -main Omi -python output.py --each
python3 output.py init
```

**To JavaScript:**
```bash
haxe -main Omi -js output.js --each
node output.js init
```

**To C#:**
```bash
haxe -main Omi -cs output --each
mono output/bin/Omi.exe init
# or on Windows
output\bin\Omi.exe init
```

### 4. Configure settings.txt

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

## Quick Reference

### Compile and Initialize Repository
```bash
# Compile to native binary
haxe -main Omi -cpp output --each -cp .

# Create repository
./output/Omi init
```

### Clone Repository
```bash
./output/Omi clone myrepo
```

### Add Files
```bash
# Add single file
./output/Omi add myfile.txt

# Add all files
./output/Omi add --all
```

### Commit Changes
```bash
./output/Omi commit -m "Initial commit"
```

### Push to Remote
```bash
./output/Omi push
# Prompts for 2FA code if enabled
```

### Pull from Remote
```bash
./output/Omi pull
```

### View History
```bash
./output/Omi log
# Shows last 10 commits

./output/Omi log 20
# Shows last 20 commits
```

### Show Status
```bash
./output/Omi status
```

### List Remote Repositories
```bash
./output/Omi list
```

## Compilation Targets

### Native Binary (Recommended)

**Compile to C++ and build native executable:**
```bash
haxe -main Omi -cpp output --each -cp .
./output/Omi init
```

**Advantages:**
- Fastest execution
- No runtime required
- Single executable file
- Suitable for distribution

**Output:**
- `output/Omi` (Linux/macOS)
- `output\Omi.exe` (Windows)

### JavaScript

**Compile to JavaScript for Node.js:**
```bash
haxe -main Omi -js output.js --each
node output.js init
```

**Advantages:**
- Cross-platform (anywhere Node.js runs)
- Easy to distribute
- Can integrate with Node.js projects

**Requirements:**
- Node.js 10+

### Python

**Compile to Python:**
```bash
haxe -main Omi -python output.py --each
python3 output.py init
```

**Advantages:**
- Readable generated Python code
- Can integrate with Python projects
- Cross-platform compatibility

**Requirements:**
- Python 3.6+

### C# (Mono/Windows)

**Compile to C#:**
```bash
haxe -main Omi -cs output --each
mono output/bin/Omi.exe init
# or on Windows
output\bin\Omi.exe init
```

**Advantages:**
- Native Windows support
- Can integrate with .NET projects
- Good performance

**Requirements:**
- Mono (Linux/macOS) or .NET (Windows)

## Commands in Detail

### init
Initialize a new repository.

```bash
./output/Omi init
./output/Omi init custom.omi
```

**Creates:**
- `repo.omi` - SQLite database file
- `.omi` - Configuration file storing database name
- Database tables and indices

**Output:**
```
Initializing omi repository...
Repository initialized: repo.omi
```

### clone
Clone a repository.

```bash
# Local clone
./output/Omi clone /path/to/repo.omi

# Remote clone
./output/Omi clone myrepo
```

**Behavior:**
- Local: Copies file directly
- Remote: Downloads via curl
- Updates .omi with database name
- Preserves complete history

### add
Stage files for commit.

```bash
./output/Omi add myfile.txt
./output/Omi add --all
```

**Behavior:**
- Calculates SHA256 using Haxe crypto
- Stores in staging table
- Excludes: database file, .omi, subdirectories
- Binary-safe file handling

**Output:**
```
Adding files to staging...
Staged: myfile.txt (hash: abc123def456...)
```

### commit
Create a commit from staged files.

```bash
./output/Omi commit -m "Fixed bug"
```

**Behavior:**
- Creates commit record
- Implements SHA256 deduplication
- Stores file data and metadata
- Clears staging area

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
./output/Omi push
```

**Behavior:**
- Checks API is enabled
- Prompts for OTP if 2FA enabled
- Uploads via curl multipart form

**With 2FA:**
```bash
$ ./output/Omi push
Pushing repo.omi to remote...
Enter OTP code (6 digits): 123456
Successfully pushed to http://localhost/omi
```

### pull
Download repository from remote server.

```bash
./output/Omi pull
```

**Behavior:**
- Downloads via curl
- Overwrites local database
- Prompts for OTP if 2FA enabled

### log
View commit history.

```bash
./output/Omi log
# Shows last 10 commits

./output/Omi log 50
# Shows last 50 commits
```

### status
Show repository status.

```bash
./output/Omi status
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
./output/Omi list
```

## Two-Factor Authentication (2FA)

2FA is enabled per user in `phpusers.txt`:

```
username:password:otpauth://totp/...
```

When 2FA is enabled, push/pull operations prompt for OTP code:

```bash
$ ./output/Omi push
Enter OTP code (6 digits): 123456
```

- Uses secure input (no echo to terminal)
- 6-digit codes change every 30 seconds
- Works with any TOTP-compatible authenticator

## Rate Limiting

API rate limiting configuration in `settings.txt`:

```ini
API_RATE_LIMIT=60
API_RATE_LIMIT_WINDOW=60
```

When rate limit is reached:
- Server returns error
- Retry after specified window
- CLI shows informational message

## Database Files

### .omi
Stores the database filename.

**Content:**
```
OMI_DB="repo.omi"
```

### repo.omi
SQLite 3 database containing:
- `blobs` table - Deduplicated file content
- `files` table - File metadata and history
- `commits` table - Commit records
- `staging` table - Staged files

**Size:** Typically 10-50 KB

## Workflow Examples

### Single File Workflow
```bash
haxe -main Omi -cpp output --each -cp .
./output/Omi init
echo "Hello World" > hello.txt
./output/Omi add hello.txt
./output/Omi commit -m "Add greeting"
./output/Omi push
```

### Multi-Target Distribution

Compile for all platforms:
```bash
# Compile to native binary
haxe -main Omi -cpp output-native --each -cp .

# Compile to Python
haxe -main Omi -python output.py --each -cp .

# Compile to JavaScript
haxe -main Omi -js output.js --each -cp .

# Compile to C#
haxe -main Omi -cs output-cs --each -cp .
```

Then distribute appropriate binary for target platform.

### Integration with Haxe Projects

Use omi as dependency in your Haxe project:

```haxe
// In your main.hx
import Omi;

// Use OmiRepository class
var settings = Settings.load();
var repo = new OmiRepository(settings);
repo.init("mydb.omi");
```

## Compilation Options

### Optimization

**Build optimized binary:**
```bash
haxe -main Omi -cpp output --each -cp . -D release
```

**Remove debugging info for smaller binary:**
```bash
haxe -main Omi -cpp output --each -cp . -D strip
```

### Static Linking

**Compile with static linking (no runtime deps):**
```bash
haxe -main Omi -cpp output --each -cp . -D HXCPP_STATIC_LINK
```

### Target-Specific Options

**C++ with optimization flags:**
```bash
haxe -main Omi -cpp output --each -cp . -D HXCPP_OPTIMIZATION_FLAGS="-O3"
```

## Troubleshooting

### Haxe Compiler Not Found
**Error:** `haxe: command not found`

**Solution:**
- Install Haxe 5: `brew install haxe` or `apt-get install haxe`
- Use explicit path: `/usr/bin/haxe -main Omi -cpp output --each`
- Check PATH: `which haxe`

### C++ Compiler Not Found
**Error:** `g++: command not found` or compiler error

**Solution:**
- Install build tools: 
  - macOS: `xcode-select --install`
  - Linux: `apt-get install build-essential`
  - Windows: Install MSVC or MinGW

### SQLite Module Error
**Error:** `Class not found : haxe.db.sqlite.Database`

**Solution:**
- Haxe sqlite3 support may need `hxsqlite3` haxelib
- Install: `haxelib install hxsqlite3`
- Add to compile command: `-lib hxsqlite3`

### settings.txt Not Found
**Error:** `Error: settings.txt not found`

**Solution:**
- Create settings.txt in project root
- Use template from documentation
- Ensure correct file permissions

### Database Errors
**Error:** `database is locked` or similar

**Solution:**
- Check file permissions: `ls -la repo.omi`
- Close other processes accessing database
- Ensure directory is writable

### Compilation Fails
**Error:** Type errors or compilation failure

**Solution:**
- Check Haxe version: `haxe --version` (need 5.0+)
- Verify all source files in working directory
- Check for typos in class/function names
- Ensure settings.txt exists

## Performance Characteristics

### Compilation Time
- First compile: ~2-5 seconds
- Incremental: ~0.5-1 second
- Full clean build: ~3-5 seconds

### Runtime Performance
- **Native binary**: Milliseconds for operations
- **Python target**: Slightly slower than Python CLI due to type overhead
- **JavaScript target**: Medium speed via Node.js
- **C# target**: Good performance via .NET

### Memory Usage
- Native binary: <10 MB typical
- Staging operations: Streamed, not loaded entirely
- Database connections: Proper cleanup after operations

### Comparison
- **Haxe native:** Fastest execution
- **Python target:** Similar to pure Python CLI
- **JavaScript target:** Good for web/Node.js
- **C#:** Windows/.NET optimized

## Security Notes

- **Credentials in settings.txt** - Restrict permissions: `chmod 600 settings.txt`
- **Type safety** - Haxe prevents common errors at compile time
- **HTTPS recommended** - Use HTTPS URLs in settings.txt
- **Secure input** - OTP codes use unseen input
- **Backend selection** - Choose appropriate target for security requirements

## Distribution

### Creating Standalone Executables

**For distribution, compile and include:**

```bash
# Create release binary
haxe -main Omi -cpp release --each -cp . -D release

# Create distribution package
mkdir omi-cli
cp release/Omi omi-cli/
cp settings.txt omi-cli/
tar -czf omi-cli.tar.gz omi-cli/
```

**Users can then:**
```bash
tar -xzf omi-cli.tar.gz
cd omi-cli
./Omi init
```

### Cross-Compilation

**On Linux, compile for Windows:**
```bash
# May require cross-compiler setup
haxe -main Omi -cpp output-win --each -cp . -D target_gcc=i686-w64-mingw32
```

## Advanced Usage

### Custom Extensions

Extend Omi by modifying omi.hx:

```haxe
// Add custom command
case "mycmd":
    myCustomCommand();
```

Recompile and use immediately.

### Integration with Build Systems

Use Omi in Haxe build scripts:

```haxe
// In hxml build file
-cmd ./output/Omi commit -m "Build commit"
-cmd ./output/Omi push
```

## See Also

- **[README.md](README.md)** - Documentation index
- **[FEATURES.md](FEATURES.md)** - Feature overview
- **[CLI_PYTHON3.md](CLI_PYTHON3.md)** - CLI alternative (Python 3)
- **[CLI_BASH.md](CLI_BASH.md)** - CLI alternative (Bash)
- **[CLI_CSHARP.md](CLI_CSHARP.md)** - CLI alternative (C# / Mono)
- **[CLI_BAT.md](CLI_BAT.md)** - CLI alternative (FreeDOS)
- **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** - CLI alternative (Amiga)
- **[CLI_LUA.md](CLI_LUA.md)** - CLI alternative (Lua)
- **[WEB.md](WEB.md)** - Web interface
- **[SERVER.md](SERVER.md)** - Server setup
- **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** - Database design
- **[Haxe Official Documentation](https://haxe.org/manual/)** - Language reference

## Notes

- Haxe 5.0+ required (version 4.x may work with adjustments)
- Single source code (omi.hx) compiles to multiple platforms
- Type safety catches errors before runtime
- Native compilation provides best performance
- Ideal for performance-critical applications
- Perfect for developers already using Haxe

---

**Last Updated:** February 10, 2026  
**Omi Version:** 1.0  
**CLI Version:** Haxe 5.0+
