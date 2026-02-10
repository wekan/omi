# Omi CLI for C# (Mono)

**Other CLI Versions:** [CLI_PYTHON3.md](CLI_PYTHON3.md) | [CLI_HAXE5.md](CLI_HAXE5.md) | [CLI_C89.md](CLI_C89.md) | [CLI_TCL.md](CLI_TCL.md) | [CLI_BASH.md](CLI_BASH.md) | [CLI_BAT.md](CLI_BAT.md) | [CLI_AMIGASHELL.md](CLI_AMIGASHELL.md) | [CLI_LUA.md](CLI_LUA.md)  

## Overview

Omi is available as a C# implementation that can be compiled with Mono for cross-platform use. C# provides:

- **Static typing** - Compile-time error detection
- **.NET Standard Library** - Rich built-in functionality
- **Mono compatibility** - Runs on Linux, macOS, Windows, FreeBSD
- **Performance** - Compiled bytecode with JIT optimization
- **Integration** - Works with existing .NET/Mono projects

This guide covers compilation, installation, and usage on Unix/Linux systems with Mono.

## Installation

### Requirements

- **Mono 5.0+** (includes C# compiler and runtime)
- **SQLite support** (System.Data.SQLite)
- **curl** or **wget** (for remote operations)
- **Text editor** (vim, nano, or similar)

### Install Mono

#### Linux (Ubuntu/Debian)
```bash
sudo apt-get update
sudo apt-get install -y mono-complete
```

#### Linux (Fedora/RedHat)
```bash
sudo dnf install -y mono-devel
```

#### Linux (Arch)
```bash
sudo pacman -S mono
```

#### macOS
```bash
brew install mono
```

#### FreeBSD
```bash
pkg install mono
```

### Install Omi

1. Clone or download the repository:
```bash
git clone https://github.com/wekan/omi.git
cd omi
```

2. Compile the C# implementation:
```bash
mcs -out:omi omi.cs -lib:/usr/lib/mono/4.5 -r:System.Data.SQLite.dll
```

Or with pkg-config for proper library discovery:
```bash
mcs -out:omi omi.cs $(pkg-config --cflags --libs mono) -r:System.Data.SQLite
```

3. Make executable and add to PATH:
```bash
chmod +x omi
sudo cp omi /usr/local/bin/
```

Or use directly:
```bash
./omi init
./omi add file.txt
```

### Verify Installation

```bash
omi --version
# or
mono omi.exe --help
```

## Configuration

### settings.txt

Create or edit `settings.txt` in your repository directory:

```
SERVER_URL=https://omi.example.com
API_KEY=your_api_key_here
OTP_SECRET=your_otp_secret
LOCAL_REPO_PATH=repo.omi
```

All values are optional. Without `SERVER_URL`, push/pull operations show a message.

### Environment Variables

You can also use environment variables:

```bash
export OMI_SERVER_URL=https://omi.example.com
export OMI_API_KEY=your_key
export OMI_OTP_SECRET=your_secret
```

### HTTP and Network Configuration

C# CLI with Mono supports internal .NET HttpClient and fallback to external curl.

**New Settings in `settings.txt`:**

```ini
# Use built-in HttpClient for network operations
USE_INTERNAL_HTTP=1

# HTTP timeout in seconds for remote operations  
HTTP_TIMEOUT=30
```

**How it works:**

- **USE_INTERNAL_HTTP=1** (default)
  - Uses Mono's built-in System.Net.Http.HttpClient
  - No external curl dependency needed
  - Works on all platforms (Linux, macOS, Windows, FreeBSD)
  - Automatic SSL/TLS certificate validation

- **USE_INTERNAL_HTTP=0**
  - Always uses external `curl` command
  - Useful for specific firewall/proxy configurations
  - Requires curl in PATH

**Best Practice:**

Leave `USE_INTERNAL_HTTP=1` for cleaner, dependency-free operation. The C# implementation handles SSL correctly without additional configuration.

```ini
USE_INTERNAL_HTTP=1
HTTP_TIMEOUT=30
```

## Quick Reference

| Command | Description |
|---------|-------------|
| `omi init` | Initialize new repository |
| `omi add <file>` | Stage a single file |
| `omi add --all` | Stage all changed files |
| `omi commit -m "message"` | Create a commit |
| `omi push` | Push to remote (requires OTP) |
| `omi pull` | Pull from remote (requires OTP) |
| `omi clone <url>` | Clone a repository |
| `omi list` | List repositories |
| `omi status` | Show staged files |
| `omi log` | Show commit history |

## Commands in Detail

### init

Initialize a new repository in current directory:

```bash
omi init
```

Creates `repo.omi` SQLite database with tables for blobs, files, commits, and staging.

### add

Stage files for the next commit:

```bash
# Stage single file
omi add src/main.cs

# Stage all files
omi add --all

# Stage multiple files
omi add file1.txt file2.txt file3.txt
```

Files are hashed with SHA256 and stored in the database. Identical content is deduplicated automatically.

### commit

Create a commit with your staged changes:

```bash
omi commit -m "Initial project setup"
omi commit -m "Fix bug in database layer"
```

The commit hash is derived from message, timestamp, and file list. All staged files are moved to the commits table.

### push

Upload commits to remote server:

```bash
omi push
# Enter OTP code when prompted (if 2FA enabled)
```

Requires valid `SERVER_URL` in settings.txt. If 2FA is enabled, you'll be prompted for a one-time password.

### pull

Download commits from remote server:

```bash
omi pull
# Enter OTP code when prompted (if 2FA enabled)
```

Updates local repository with remote commits. Requires `SERVER_URL` configuration.

### clone

Clone a remote repository:

```bash
omi clone https://omi.example.com/user/project
cd project
```

Creates local repository and initializes from remote.

### list

Show all repositories in current context:

```bash
omi list
```

Lists all `.omi` files found in the current directory and subdirectories.

### status

Show current repository status:

```bash
omi status
```

Displays:
- Staged files (ready to commit)
- File paths and modification times
- Current staging area state

### log

Show commit history:

```bash
omi log
```

Displays:
- Commit hash (first 8 characters)
- Commit message
- Timestamp (UTC)
- List of files in each commit

## Compilation Options

### Default Compilation

```bash
mcs -out:omi omi.cs -r:System.Data.SQLite.dll
```

### Optimized Compilation

For better performance, use optimization flags:

```bash
mcs -optimize+ -out:omi omi.cs -r:System.Data.SQLite.dll
```

### Debug Compilation

For development with debugging symbols:

```bash
mcs -debug -out:omi omi.cs -r:System.Data.SQLite.dll
```

### Static Linking (Platform-specific)

To create self-contained executable on Linux:

```bash
mkbundle -o omi omi.exe --machine-config /etc/mono/4.5/machine.config
```

## Two-Factor Authentication (2FA)

### Setup

1. Configure OTP secret in settings.txt:
```
OTP_SECRET=JBSWY3DPEBLW64TMMQ======
```

2. Store the same secret in your authenticator app (Google Authenticator, Authy, Microsoft Authenticator)

### Using 2FA

When pushing or pulling with 2FA enabled:

```bash
omi push
OTP code: ______

# Enter 6-digit code from your authenticator app
```

The OTP code uses HMAC-SHA1 (RFC 6238) time-based one-time passwords.

### Disabling 2FA

Remove or leave empty the `OTP_SECRET` in settings.txt to disable 2FA.

## Rate Limiting

The server (if configured) enforces rate limits per API key:

- **Default:** 100 requests per hour per user
- **Burst:** Up to 10 requests per minute

If you hit the rate limit:

```
Error: Rate limit exceeded
```

Wait for the limit window to reset.

## Database Files

Repository data is stored in SQLite format (`.omi` files):

### Tables

| Table | Purpose | Columns |
|-------|---------|---------|
| blobs | Stored file content | sha256 (PK), data |
| files | Current tracked files | path (PK), sha256, modified |
| commits | Commit history | hash (PK), message, files, timestamp |
| staging | Files staged for commit | path (PK), sha256 |

### Database Size

- Empty repo: ~10 KB
- Per file: ~(file_size + 100 bytes)
- Per commit: ~100 bytes + file paths

To estimate repo size:

```bash
ls -lh repo.omi
# Human-readable size display
du -h repo.omi
```

### Inspecting Database

View database contents with sqlite3 (if installed):

```bash
sqlite3 repo.omi "SELECT COUNT(*) FROM commits;"
sqlite3 repo.omi "SELECT hash, message FROM commits LIMIT 5;"
```

## Workflow Examples

### Basic Workflow

```bash
# Initialize repo
omi init

# Create/edit files
echo "Hello World" > greeting.txt
echo "int main() {}" > program.cs

# Stage files
omi add greeting.txt
omi add program.cs

# Verify staging
omi status

# Create commit
omi commit -m "Add greeting and program"

# View history
omi log

# Push to server
omi push
```

### Multi-File Commit

```bash
# Edit multiple files
nano src/main.cs
nano src/utils.cs
nano docs/README.md

# Stage all changes
omi add --all

# Create commit with detailed message
omi commit -m "Refactor main logic and update docs"

# Push changes
omi push
```

### Pulling Updates

```bash
# Check what's on server
omi pull

# View new commits
omi log

# Continue editing
nano src/feature.cs
omi add src/feature.cs
omi commit -m "Implement new feature"
```

### Repository Cloning

```bash
# Clone existing project
omi clone https://omi.example.com/user/myproject
cd myproject

# See history
omi log

# Add new file
echo "Updated" > update.txt
omi add update.txt
omi commit -m "Add update"
omi push
```

## Network Connectivity

### Using Proxy

If you need to go through a proxy, set curl environment variables:

```bash
export http_proxy=http://proxy.example.com:8080
export https_proxy=https://proxy.example.com:8080
omi push
```

### Offline Use

Omi works offline:

```bash
# Repository operations work without network
omi add files
omi commit -m "Offline work"
omi log

# Push when network is available
omi push
```

## Troubleshooting

### "Command not found: omi"

The executable is not in PATH. Either:

1. Use full path:
```bash
./omi init
# or
/usr/local/bin/omi init
```

2. Add to PATH:
```bash
export PATH=$PATH:/path/to/omi
```

### "System.IO.FileNotFoundException: System.Data.SQLite"

SQLite library is not found. Install it:

**Ubuntu/Debian:**
```bash
sudo apt-get install -y libsqlite3-dev monodevelop-database
```

**Fedora:**
```bash
sudo dnf install -y sqlite-devel
```

**macOS:**
```bash
brew install sqlite
```

### "Commit conflicts"

If push fails due to remote conflicts:

1. Pull first:
```bash
omi pull
```

2. Resolve any issues

3. Create new commit:
```bash
omi add resolved_files
omi commit -m "Merge remote changes"
```

4. Push again:
```bash
omi push
```

### "OTP code invalid"

Check that:
- Your system clock is synchronized (`ntpdate`, `timedatectl`)
- The OTP secret in settings.txt matches your authenticator
- You're entering the code correctly (6 digits)

```bash
# Check system time
date -u
timedatectl

# Verify OTP secret
grep OTP_SECRET settings.txt
```

## Performance

### Performance Characteristics

| Operation | Time | Notes |
|-----------|------|-------|
| init | <100ms | Creates SQLite database |
| add (small file) | 10-50ms | SHA256 hashing |
| add (large file) | Proportional | File I/O bound |
| commit | 5-20ms | Database write |
| log (100 commits) | <100ms | Database query |
| push/pull | Network bound | Depends on server |

### Memory Usage

- Startup: ~20 MB (Mono runtime)
- Per file: ~1 KB (metadata)
- Per commit: ~100 bytes

### Optimization Tips

1. **Compiled binary** is faster than script versions
2. **For large files**, add in batches with delays:
```bash
omi add file1
omi add file2
```

3. **Regular commits** keep database size manageable
4. **Archive old repos** to keep current repo fast

## Security Considerations

### File Permissions

Keep your repository secure:

```bash
# Restrict read access
chmod 600 repo.omi

# Restrict directory access
chmod 700 . 

# Secure settings file
chmod 600 settings.txt
```

### API Key Storage

**Never commit settings.txt** with real API keys:

```bash
# Add to .gitignore
echo "settings.txt" >> .gitignore

# Use separate config for each environment
cp settings.example.txt settings.txt
# Now edit settings.txt with real values
```

### OTP Security

- Store OTP backups in secure location
- Use strong authenticator app passwords
- Never share your OTP secret
- Consider hardware security keys for critical systems

### Network Security

Always use HTTPS for remote operations:

```
SERVER_URL=https://omi.example.com   # ✓ Secure
SERVER_URL=http://omi.example.com    # ✗ Insecure
```

## Mono-Specific Considerations

### Mono Version Compatibility

Tested with:
- Mono 5.0+
- .NET Framework 4.5+ API
- MonoMac (macOS)

### Platform-Specific Issues

#### macOS
Some users report slow SHA256 hashing on M1/M2 due to Rosetta translation. Use native mono:

```bash
arch -arm64 /opt/homebrew/bin/mono omi.exe init
```

#### Linux with SELinux
You may need to add execution context:

```bash
chcon -t bin_t ./omi
```

#### FreeBSD
Use pkg version and add to secure PATH:

```bash
sudo sysctl security.bsd.unprivileged_proc_debug=1
```

## Distribution

### Creating Standalone Binaries

Create a single executable with mkbundle:

```bash
mkbundle -o omi-static omi.exe \
  $(pkg-config --cflags --libs mono)
```

This includes the Mono runtime and all dependencies.

### Packaging for Package Managers

#### Create RPM (Fedora/RedHat)
```bash
# Requires rpm-build
rpmbuild -ba omi.spec
```

#### Create DEB (Debian/Ubuntu)
```bash
# Requires debianutils
dpkg-deb --build omi
```

## Integration with Projects

### Using in C# Projects

Reference from your project:

```csharp
// Your project.cs
using System;

// Omi can be invoked as subprocess
var process = new Process
{
    StartInfo = new ProcessStartInfo
    {
        FileName = "omi",
        Arguments = "add file.txt"
    }
};
process.Start();
process.WaitForExit();
```

### Extending Omi

The source code can be modified for custom features:

1. Edit `omi.cs`
2. Add methods to `OmiRepository` class
3. Recompile:
```bash
mcs -out:omi omi.cs -r:System.Data.SQLite.dll
```

## Advanced Usage

### Batch Operations

Create scripts to automate workflows:

```bash
#!/bin/bash
# backup_project.sh

omi add --all
omi commit -m "Automated backup $(date)"
omi push
```

```bash
chmod +x backup_project.sh
./backup_project.sh
```

### CI/CD Integration

Use in build pipelines (GitLab CI, GitHub Actions, Jenkins):

```yaml
# .gitlab-ci.yml
build:
  script:
    - omi init
    - omi add --all
    - omi commit -m "Build $CI_COMMIT_SHA"
    - omi push
```

### Database Inspection

Debug your repository:

```bash
# Count commits
sqlite3 repo.omi "SELECT COUNT(*) FROM commits;"

# Find largest files
sqlite3 repo.omi \
  "SELECT path, LENGTH(data) FROM blobs WHERE sha256 IN 
   (SELECT sha256 FROM files) ORDER BY LENGTH(data) DESC LIMIT 10;"

# Recent changes
sqlite3 repo.omi \
  "SELECT path, modified FROM files ORDER BY modified DESC LIMIT 20;"
```

## See Also

- **[README.md](README.md)** - Documentation index
- **[FEATURES.md](FEATURES.md)** - Feature overview
- **[CLI_PYTHON3.md](CLI_PYTHON3.md)** - CLI alternative (Python 3)
- **[CLI_HAXE5.md](CLI_HAXE5.md)** - CLI alternative (Haxe 5)
- **[CLI_C89.md](CLI_C89.md)** - CLI alternative (C89)
- **[CLI_TCL.md](CLI_TCL.md)** - CLI alternative (Tcl)
- **[CLI_BASH.md](CLI_BASH.md)** - CLI alternative (Bash)
- **[CLI_BAT.md](CLI_BAT.md)** - CLI alternative (FreeDOS)
- **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** - CLI alternative (Amiga)
- **[CLI_LUA.md](CLI_LUA.md)** - CLI alternative (Lua)
- **[WEB.md](WEB.md)** - Web interface
- **[SERVER_PHP.md](SERVER_PHP.md)** - Server setup
- **[DATABASE_SCHEMA.md](DATABASE_SCHEMA.md)** - Database design
- **[Mono Official Documentation](https://www.mono-project.com/)** - Mono runtime reference
- **[C# Language Reference](https://docs.microsoft.com/en-us/dotnet/csharp/)** - C# syntax and features

## Notes

This C# implementation is ideal for:
- Developers familiar with C# and .NET
- Projects already using Mono
- Cross-platform deployments
- Production environments needing compiled executables
- Integration with existing .NET applications

C# provides excellent type safety and performance for version control operations while maintaining full compatibility across Unix, macOS, Windows, and FreeBSD systems.
