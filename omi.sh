#!/bin/bash
# Omi - Version Control for Bash
# Optimized Micro Index - Git-like commands with SQLite storage

# Read settings from settings.txt
SQLITE=$(grep "^SQLITE=" settings.txt | cut -d'=' -f2)
USERNAME=$(grep "^USERNAME=" settings.txt | cut -d'=' -f2)
PASSWORD=$(grep "^PASSWORD=" settings.txt | cut -d'=' -f2)
REPOS=$(grep "^REPOS=" settings.txt | cut -d'=' -f2)
CURL=$(grep "^CURL=" settings.txt | cut -d'=' -f2)

# Database file
if [ ! -f .omi ]; then
  OMI_DB="repo.omi"
else
  source .omi
fi

# Command dispatcher
CMD="$1"
shift

case "$CMD" in
  init)
    init_db "$@"
    ;;
  clone)
    clone_db "$@"
    ;;
  add)
    add_files "$@"
    ;;
  commit)
    commit_files "$@"
    ;;
  push)
    push_changes "$@"
    ;;
  pull)
    pull_changes "$@"
    ;;
  list)
    list_repos "$@"
    ;;
  log)
    log_commits "$@"
    ;;
  status)
    show_status "$@"
    ;;
  *)
    echo "Unknown command: $CMD"
    echo "Usage: omi <command> [args]"
    echo "Commands: init, clone, add, commit, push, pull, list, log, status"
    exit 1
    ;;
esac

function init_db() {
  echo "Initializing omi repository..."
  echo "OMI_DB=\"$OMI_DB\"" > .omi

  # Create database schema with deduplication support
  $SQLITE "$OMI_DB" "CREATE TABLE IF NOT EXISTS blobs (
    hash TEXT PRIMARY KEY,
    data BLOB,
    size INTEGER
  );"

  $SQLITE "$OMI_DB" "CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT,
    hash TEXT,
    datetime TEXT,
    commit_id INTEGER,
    FOREIGN KEY(commit_id) REFERENCES commits(id)
  );"

  $SQLITE "$OMI_DB" "CREATE TABLE IF NOT EXISTS commits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    message TEXT,
    datetime TEXT,
    user TEXT
  );"

  $SQLITE "$OMI_DB" "CREATE TABLE IF NOT EXISTS staging (
    filename TEXT PRIMARY KEY,
    hash TEXT,
    datetime TEXT
  );"

  $SQLITE "$OMI_DB" "CREATE INDEX IF NOT EXISTS idx_files_hash ON files(hash);"
  $SQLITE "$OMI_DB" "CREATE INDEX IF NOT EXISTS idx_files_commit ON files(commit_id);"
  $SQLITE "$OMI_DB" "CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash);"

  echo "Repository initialized: $OMI_DB"
}

function clone_db() {
  local url="$1"
  echo "Cloning from $url..."

  # For local files, just copy
  if [ -f "$url" ]; then
    cp "$url" "$OMI_DB"
    echo "Cloned to $OMI_DB"
    echo "OMI_DB=\"$OMI_DB\"" > .omi
  else
    # Remote clone using curl
    local repo_name=$(basename "$url")
    if [ -z "$repo_name" ]; then
      repo_name="$OMI_DB"
    fi

    echo "Downloading $repo_name from $REPOS..."
    $CURL -f -o "$repo_name" "$REPOS/?download=$repo_name"

    if [ $? -eq 0 ]; then
      echo "Cloned to $repo_name"
      echo "OMI_DB=\"$repo_name\"" > .omi
    else
      echo "Error: Failed to clone from remote"
      exit 1
    fi
  fi
}

function add_files() {
  local arg="$1"
  echo "Adding files to staging..."

  if [ "$arg" = "--all" ]; then
    # Add all files in directory
    for file in *; do
      if [ -f "$file" ] && [ "$file" != "$OMI_DB" ] && [ "$file" != ".omi" ]; then
        add_one_file "$file"
      fi
    done
  else
    add_one_file "$arg"
  fi
}

function add_one_file() {
  local filename="$1"

  if [ ! -f "$filename" ]; then
    echo "Error: File not found: $filename"
    return 1
  fi

  # Calculate SHA256 hash using SQLite
  local hash=$($SQLITE "$OMI_DB" "SELECT lower(hex(sha256(readfile('$filename'))));")

  # Get current datetime in SQLite format
  local datetime=$($SQLITE "$OMI_DB" "SELECT datetime('now');")

  # Add to staging area
  $SQLITE "$OMI_DB" "INSERT OR REPLACE INTO staging (filename, hash, datetime)
    VALUES ('$filename', '$hash', '$datetime');"

  echo "Staged: $filename (hash: $hash)"
}

function commit_files() {
  local message=""

  # Parse commit message from -m "message"
  while [ $# -gt 0 ]; do
    case "$1" in
      -m)
        shift
        message="$1"
        ;;
    esac
    shift
  done

  if [ -z "$message" ]; then
    message="No message"
  fi

  echo "Committing changes..."

  # Get current datetime
  local datetime=$($SQLITE "$OMI_DB" "SELECT datetime('now');")

  # Get username
  local user="${USER:-unknown}"

  # Create commit record and get its ID
  local commit_id=$($SQLITE "$OMI_DB" "INSERT INTO commits (message, datetime, user)
    VALUES ('$message', '$datetime', '$user');
    SELECT last_insert_rowid();")

  # Process each staged file
  $SQLITE "$OMI_DB" "SELECT filename, hash, datetime FROM staging;" | \
  while IFS='|' read -r filename hash filedatetime; do
    commit_one_file "$filename" "$hash" "$filedatetime" "$commit_id"
  done

  # Clear staging area
  $SQLITE "$OMI_DB" "DELETE FROM staging;"

  echo "Committed successfully (commit #$commit_id)"
}

function commit_one_file() {
  local filename="$1"
  local hash="$2"
  local filedatetime="$3"
  local commit_id="$4"

  # Check if blob with this hash already exists (deduplication)
  local blob_exists=$($SQLITE "$OMI_DB" "SELECT COUNT(*) FROM blobs WHERE hash='$hash';")

  if [ "$blob_exists" = "0" ]; then
    # Blob doesn't exist, store it
    $SQLITE "$OMI_DB" "INSERT INTO blobs (hash, data, size)
      VALUES ('$hash', readfile('$filename'), length(readfile('$filename')));"
    echo "  Stored new blob: $hash"
  else
    echo "  Blob already exists (deduplicated): $hash"
  fi

  # Add file record (always add metadata even if blob exists)
  $SQLITE "$OMI_DB" "INSERT INTO files (filename, hash, datetime, commit_id)
    VALUES ('$filename', '$hash', '$filedatetime', $commit_id);"
}

function push_changes() {
  echo "Pushing $OMI_DB to remote..."

  if [ ! -f "$OMI_DB" ]; then
    echo "Error: Database file $OMI_DB not found"
    exit 1
  fi

  # Upload using curl
  $CURL -f -X POST \
    -F "username=$USERNAME" \
    -F "password=$PASSWORD" \
    -F "repo_name=$(basename $OMI_DB)" \
    -F "repo_file=@$OMI_DB" \
    -F "action=Upload" \
    "$REPOS/"

  if [ $? -eq 0 ]; then
    echo "Successfully pushed to $REPOS"
  else
    echo "Error: Failed to push to remote"
    exit 1
  fi
}

function pull_changes() {
  echo "Pulling $OMI_DB from remote..."

  local repo_name=$(basename "$OMI_DB")

  # Download using curl with authentication
  $CURL -f -X POST \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD" \
    -d "repo_name=$repo_name" \
    -d "action=pull" \
    -o "$OMI_DB" \
    "$REPOS/"

  if [ $? -eq 0 ]; then
    echo "Successfully pulled from $REPOS"
  else
    echo "Error: Failed to pull from remote"
    exit 1
  fi
}

function list_repos() {
  echo "=== Available Repositories on $REPOS ==="

  # Get JSON list of repos
  $CURL -s "$REPOS/?format=json" | grep -o '"name":"[^"]*"' | cut -d'"' -f4

  if [ $? -ne 0 ]; then
    echo "Error: Failed to retrieve repository list"
    exit 1
  fi
}

function show_status() {
  echo "=== Staged Files ==="
  $SQLITE "$OMI_DB" "SELECT filename, datetime FROM staging;"
  echo ""
  echo "=== Recent Commits ==="
  $SQLITE "$OMI_DB" "SELECT id, message, datetime FROM commits ORDER BY id DESC LIMIT 5;"
  echo ""
  echo "=== Statistics ==="
  echo -n "Total blobs (deduplicated): "
  $SQLITE "$OMI_DB" "SELECT COUNT(*) FROM blobs;"
  echo -n "Total file versions: "
  $SQLITE "$OMI_DB" "SELECT COUNT(*) FROM files;"
}
