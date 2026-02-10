# Database Schema Reference

> **Documentation Index:** See [README.md](README.md) for documentation overview  
> **For developers only** - See [FEATURES.md](FEATURES.md) for feature overview

## Overview

Omi uses SQLite to store all repository data. Each .omi file is a SQLite database containing:
- File content (BLOB data)
- File metadata (pathnames, dates)
- Commit history (messages, authors, timestamps)
- Staging area (uncommitted changes)

## Tables

### blobs

Stores unique file content with deduplication.

| Column | Type | Description |
|--------|------|-------------|
| hash | TEXT PRIMARY KEY | SHA256 hash of file content |
| data | BLOB | Complete file contents |
| size | INTEGER | File size in bytes |

**Purpose:** Deduplicate identical files by storing each unique content only once.

**Example:**
```
hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
data: "hello world"
size: 11
```

### files

Stores file metadata for each commit.

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER PRIMARY KEY | Auto-incrementing record ID |
| filename | TEXT | File path and name |
| hash | TEXT | Reference to blob (SHA256) |
| datetime | TEXT | ISO format timestamp |
| commit_id | INTEGER | Which commit this file version belongs to |

**Relationships:**
- `hash` → `blobs.hash` (which content this file contains)
- `commit_id` → `commits.id` (which commit this file is part of)

**Example:**
```
id: 1
filename: "README.md"
hash: "abc123..."
datetime: "2026-02-10 10:30:45"
commit_id: 1
```

### commits

Stores commit metadata (history).

| Column | Type | Description |
|--------|------|-------------|
| id | INTEGER PRIMARY KEY | Auto-incrementing commit number |
| message | TEXT | Commit message |
| datetime | TEXT | ISO format timestamp |
| user | TEXT | Username who made commit |

**Purpose:** Track who made what changes and when.

**Example:**
```
id: 1
message: "Initial commit"
datetime: "2026-02-10 10:15:00"
user: "admin"
```

### staging

Temporary storage for uncommitted changes.

| Column | Type | Description |
|--------|------|-------------|
| filename | TEXT PRIMARY KEY | File path and name |
| hash | TEXT | SHA256 hash of staged content |
| datetime | TEXT | ISO format timestamp |

**Purpose:** Holds files awaiting `commit` command.

**Cleared:** After each commit

**Example:**
```
filename: "main.c"
hash: "xyz789..."
datetime: "2026-02-10 10:45:22"
```

## Indexes

Optimizes query performance:

| Index | On | Purpose |
|-------|----|----|
| idx_files_hash | files(hash) | Find all versions of same content |
| idx_files_commit | files(commit_id) | Find all files in specific commit |
| idx_blobs_hash | blobs(hash) | Fast blob lookup for deduplication |

## Data Flow

### Adding Files

```
Input: file "README.md" with content "hello"
↓
Calculate hash: SHA256("hello") = "abc123..."
↓
Insert into staging:
  filename: "README.md"
  hash: "abc123..."
  datetime: "2026-02-10 10:45:00"
```

### Committing

```
For each file in staging:
  ↓
  Check if blob exists: SELECT * FROM blobs WHERE hash = "abc123..."
  ↓
  NOT FOUND → Insert new blob:
    INSERT INTO blobs: hash="abc123...", data="hello", size=5
  ↓
  Create commit record:
    INSERT INTO commits: message="...", datetime="...", user="..."
    Get commit_id = last_insert_id()
  ↓
  Add file metadata:
    INSERT INTO files: filename="README.md", hash="abc123...",
                       commit_id=1, datetime="..."
  ↓
  Delete from staging
```

### Viewing File History

```
Query: SELECT * FROM files WHERE filename="README.md"
       ORDER BY commit_id DESC
↓
Returns: All versions of README.md
↓
For each version:
  Get commit info: SELECT * FROM commits WHERE id=?
  Get content: SELECT data FROM blobs WHERE hash=?
```

## Deduplication Example

### Storage Without Deduplication
```
File 1: "hello world" → 11 bytes stored
File 2: "hello world" → 11 bytes stored (duplicate!)
Total: 22 bytes
```

### Storage With Deduplication (Omi)
```
File 1: "hello world" → hash abc123 → blob stored once (11 bytes)
File 2: "hello world" → hash abc123 → references same blob
Total: 11 bytes (saved 50%!)
```

### Database Records
```
blobs:
  hash abc123 → data "hello world" (stored once)

files:
  filename: "file1.txt", hash: abc123, commit_id: 1
  filename: "file2.txt", hash: abc123, commit_id: 1
```

## Queries

### List All Files in Latest Commit

```sql
SELECT f.filename, b.size, f.datetime
FROM files f
LEFT JOIN blobs b ON f.hash = b.hash
LEFT JOIN commits c ON f.commit_id = c.id
WHERE c.id = (SELECT MAX(id) FROM commits);
```

### Find File Size Over Time

```sql
SELECT f.filename, f.datetime, b.size, c.message
FROM files f
LEFT JOIN blobs b ON f.hash = b.hash
LEFT JOIN commits c ON f.commit_id = c.id
WHERE f.filename = "README.md"
ORDER BY c.id DESC;
```

### Get Commit Statistics

```sql
SELECT c.id, c.message, c.user, c.datetime, COUNT(*) as files
FROM commits c
LEFT JOIN files f ON c.id = f.commit_id
GROUP BY c.id
ORDER BY c.id DESC;
```

### Find Duplicate Content

```sql
SELECT hash, COUNT(*) as versions, SUM(size) as total_bytes
FROM blobs
GROUP BY hash;
```

## Database Integrity

### Constraints
- `hash` is PRIMARY KEY in blobs (unique)
- `filename` is PRIMARY KEY in staging (one entry per file)
- AUTO INCREMENT on `id` in files and commits

### Foreign Keys
- `files.hash` should reference `blobs.hash`
- `files.commit_id` should reference `commits.id`

Note: SQLite foreign keys must be explicitly enabled

### Recommended Maintenance

```sql
-- Check for orphaned file records
SELECT * FROM files WHERE hash NOT IN (SELECT hash FROM blobs);

-- Vacuum database (removes unused space)
VACUUM;

-- Analyze for query optimization
ANALYZE;
```

## Size Calculation

### Database Size

Total = sum of all blobs + metadata overhead

```
Rough estimation:
- Small file (< 1KB): ~1.5KB in database
- Medium file (1-100KB): ~1.2x file size
- Large file (> 100MB): ~1.1x file size
- Deduplication factor: depends on number of duplicates
```

Example:
- 1000 text files, average 10KB each
- Without deduplication: ~10MB
- With deduplication (50% duplicates): ~5.5MB

## Version Compatibility

### SQLite Compatibility
- Minimum SQLite version: 3.0 (released 2004)
- Required features:
  - BLOB support
  - SHA256 function
  - PRAGMA support

### Upgrade Path
- Omi database format is backward compatible
- SQLite databases can grow indefinitely
- No schema migration needed for version updates

## Performance Tuning

### For Large Repositories (> 1GB)

```sql
-- Improve query speed
CREATE INDEX idx_files_hash ON files(hash);
CREATE INDEX idx_files_commit ON files(commit_id);

-- Reduce database size
VACUUM;

-- Optimize queries
ANALYZE;
```

### For Many Commits (> 10,000)

Add index on commits:
```sql
CREATE INDEX idx_commits_date ON commits(datetime);
```

---

## See Also

- **[README.md](README.md)** - Documentation index
- **[FEATURES.md](FEATURES.md)** - Feature overview
- **[CLI_BASH.md](CLI_BASH.md)** - CLI commands (Bash)
- **[CLI_BAT.md](CLI_BAT.md)** - CLI commands (FreeDOS)
- **[CLI_AMIGASHELL.md](CLI_AMIGASHELL.md)** - CLI commands (Amiga)
- **[WEB.md](WEB.md)** - Web interface
- **[SERVER.md](SERVER.md)** - Server setup

This speeds up queries filtering by date range.
