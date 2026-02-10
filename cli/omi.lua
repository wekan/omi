#!/usr/bin/env lua
-- Omi - Version Control for Lua
-- Optimized Micro Index - Git-like commands with SQLite storage

-- Settings module
local Settings = {}

function Settings.load()
  local settings = {}
  
  -- Read settings.txt
  local settings_file = io.open("../settings.txt", "r")
  if not settings_file then
    print("Error: settings.txt not found")
    os.exit(1)
  end
  
  for line in settings_file:lines() do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key then
      settings[key] = value
    end
  end
  settings_file:close()
  
  -- Set defaults
  settings.API_ENABLED = settings.API_ENABLED or "1"
  settings.API_RATE_LIMIT = settings.API_RATE_LIMIT or "60"
  settings.API_RATE_LIMIT_WINDOW = settings.API_RATE_LIMIT_WINDOW or "60"
  
  return settings
end

-- Utility functions
local function read_dotomi()
  local file = io.open(".omi", "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  local omi_db = content:match('OMI_DB="([^"]+)"')
  return omi_db or "repo.omi"
end

local function write_dotomi(db_name)
  local file = io.open(".omi", "w")
  if file then
    file:write('OMI_DB="' .. db_name .. '"\n')
    file:close()
  end
end

local function file_exists(name)
  local file = io.open(name, "r")
  if file then
    file:close()
    return true
  end
  return false
end

local function sqlite_execute(db, query)
  query = query:gsub('"', '\\"')
  local cmd = Settings.SQLITE .. ' "' .. db .. '" "' .. query .. '"'
  local handle = io.popen(cmd, "r")
  if not handle then
    return nil
  end
  local result = handle:read("*a")
  handle:close()
  return result:match("^(.-)%s*$") -- Trim whitespace
end

local function sqlite_execute_return_code(db, query)
  query = query:gsub('"', '\\"')
  local cmd = Settings.SQLITE .. ' "' .. db .. '" "' .. query .. '" > /dev/null 2>&1'
  return os.execute(cmd)
end

local function calculate_sha256(filename)
  if not file_exists(filename) then
    return nil
  end
  -- Use sqlite to calculate SHA256
  local result = sqlite_execute("", "SELECT lower(hex(sha256(readfile('" .. filename .. "'))));")
  if result and result ~= "" then
    return result
  end
  return nil
end

local function prompt_for_otp()
  io.write("Enter OTP code (6 digits): ")
  io.flush()
  return io.read()
end

local function has_2fa_enabled(db, username)
  if not file_exists("phpusers.txt") then
    return false
  end
  
  local file = io.open("phpusers.txt", "r")
  if not file then
    return false
  end
  
  for line in file:lines() do
    local user, _, otpauth = line:match("^([^:]+):([^:]*):(.*)$")
    if user == username and otpauth and otpauth ~= "" then
      file:close()
      return true
    end
  end
  file:close()
  return false
end

local function get_current_datetime(db)
  local result = sqlite_execute(db, "SELECT datetime('now');")
  return result or os.date("%Y-%m-%d %H:%M:%S")
end

-- Command functions
local function init_db(omi_db)
  print("Initializing omi repository...")
  write_dotomi(omi_db)
  
  -- Create database schema
  sqlite_execute(omi_db, "CREATE TABLE IF NOT EXISTS blobs (hash TEXT PRIMARY KEY, data BLOB, size INTEGER);")
  sqlite_execute(omi_db, "CREATE TABLE IF NOT EXISTS files (id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, hash TEXT, datetime TEXT, commit_id INTEGER, FOREIGN KEY(commit_id) REFERENCES commits(id));")
  sqlite_execute(omi_db, "CREATE TABLE IF NOT EXISTS commits (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT, datetime TEXT, user TEXT);")
  sqlite_execute(omi_db, "CREATE TABLE IF NOT EXISTS staging (filename TEXT PRIMARY KEY, hash TEXT, datetime TEXT);")
  sqlite_execute(omi_db, "CREATE INDEX IF NOT EXISTS idx_files_hash ON files(hash);")
  sqlite_execute(omi_db, "CREATE INDEX IF NOT EXISTS idx_files_commit ON files(commit_id);")
  sqlite_execute(omi_db, "CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash);")
  
  print("Repository initialized: " .. omi_db)
end

local function clone_db(url)
  print("Cloning from " .. url .. "...")
  
  local omi_db = "repo.omi"
  
  if file_exists(url) then
    -- Local clone
    os.execute("cp " .. url .. " " .. omi_db)
    write_dotomi(omi_db)
    print("Cloned to " .. omi_db)
  else
    -- Remote clone
    local repo_name = url:match("([^/]+)$") or omi_db
    print("Downloading " .. repo_name .. " from " .. Settings.REPOS .. "...")
    
    local cmd = Settings.CURL .. ' -f -o "' .. repo_name .. '" "' .. Settings.REPOS .. '/?download=' .. repo_name .. '"'
    if os.execute(cmd) == 0 then
      write_dotomi(repo_name)
      print("Cloned to " .. repo_name)
    else
      print("Error: Failed to clone from remote")
      os.exit(1)
    end
  end
end

local function add_files(pattern)
  print("Adding files to staging...")
  
  local omi_db = read_dotomi() or "repo.omi"
  
  if pattern == "--all" then
    -- Add all files in current directory
    for filename in io.popen("ls -1"):lines() do
      if file_exists(filename) and filename ~= omi_db and filename ~= ".omi" then
        add_one_file(omi_db, filename)
      end
    end
  else
    add_one_file(omi_db, pattern)
  end
end

function add_one_file(omi_db, filename)
  if not file_exists(filename) then
    print("Error: File not found: " .. filename)
    return false
  end
  
  local hash = calculate_sha256(filename)
  if not hash then
    print("Error: Could not calculate hash for " .. filename)
    return false
  end
  
  local datetime = get_current_datetime(omi_db)
  
  -- Add to staging
  sqlite_execute(omi_db, "INSERT OR REPLACE INTO staging (filename, hash, datetime) VALUES ('" .. 
    filename:gsub("'", "''") .. "', '" .. hash .. "', '" .. datetime .. "');")
  
  print("Staged: " .. filename .. " (hash: " .. hash .. ")")
  return true
end

local function commit_files(...)
  local message = "No message"
  local args = {...}
  
  -- Parse -m "message"
  for i = 1, #args do
    if args[i] == "-m" and i < #args then
      message = args[i + 1]
      break
    end
  end
  
  print("Committing changes...")
  
  local omi_db = read_dotomi() or "repo.omi"
  local datetime = get_current_datetime(omi_db)
  local user = os.getenv("USER") or "unknown"
  
  -- Create commit and get its ID
  sqlite_execute(omi_db, "INSERT INTO commits (message, datetime, user) VALUES ('" .. 
    message:gsub("'", "''") .. "', '" .. datetime .. "', '" .. user .. "');")
  
  local commit_id_result = sqlite_execute(omi_db, "SELECT last_insert_rowid();")
  local commit_id = commit_id_result and commit_id_result:match("(%d+)") or "1"
  
  -- Process each staged file
  local result = sqlite_execute(omi_db, "SELECT filename, hash, datetime FROM staging;")
  if result then
    for line in result:gmatch("[^\n]+") do
      local filename, hash, filedatetime = line:match("^([^|]*)|([^|]*)|(.*)$")
      if filename then
        commit_one_file(omi_db, filename, hash, filedatetime, commit_id)
      end
    end
  end
  
  -- Clear staging
  sqlite_execute(omi_db, "DELETE FROM staging;")
  
  print("Committed successfully (commit #" .. commit_id .. ")")
end

function commit_one_file(omi_db, filename, hash, filedatetime, commit_id)
  -- Check if blob exists
  local blob_count = sqlite_execute(omi_db, "SELECT COUNT(*) FROM blobs WHERE hash='" .. hash .. "';"):match("(%d+)")
  
  if blob_count == "0" then
    -- Store new blob
    sqlite_execute(omi_db, "INSERT INTO blobs (hash, data, size) VALUES ('" .. hash .. 
      "', readfile('" .. filename:gsub("'", "''") .. "'), length(readfile('" .. 
      filename:gsub("'", "''") .. "')));")
    print("  Stored new blob: " .. hash)
  else
    print("  Blob already exists (deduplicated): " .. hash)
  end
  
  -- Add file record
  sqlite_execute(omi_db, "INSERT INTO files (filename, hash, datetime, commit_id) VALUES ('" .. 
    filename:gsub("'", "''") .. "', '" .. hash .. "', '" .. filedatetime .. "', " .. commit_id .. ");")
end

local function push_changes()
  local omi_db = read_dotomi() or "repo.omi"
  print("Pushing " .. omi_db .. " to remote...")
  
  if not file_exists(omi_db) then
    print("Error: Database file " .. omi_db .. " not found")
    os.exit(1)
  end
  
  if Settings.API_ENABLED == "0" then
    print("Error: API is disabled")
    os.exit(1)
  end
  
  local otp_code = ""
  local curl_opts = ""
  
  if has_2fa_enabled(omi_db, Settings.USERNAME) then
    otp_code = prompt_for_otp()
    curl_opts = ' -F "otp_code=' .. otp_code .. '"'
  end
  
  local cmd = Settings.CURL .. ' -f -X POST ' ..
    ' -F "username=' .. Settings.USERNAME .. '"' ..
    ' -F "password=' .. Settings.PASSWORD .. '"' ..
    ' -F "repo_name=' .. omi_db .. '"' ..
    ' -F "repo_file=@' .. omi_db .. '"' ..
    ' -F "action=Upload"' ..
    curl_opts ..
    ' "' .. Settings.REPOS .. '/" 2>&1'
  
  if os.execute(cmd) == 0 then
    print("Successfully pushed to " .. Settings.REPOS)
  else
    print("Error: Failed to push to remote")
    os.exit(1)
  end
end

local function pull_changes()
  local omi_db = read_dotomi() or "repo.omi"
  print("Pulling " .. omi_db .. " from remote...")
  
  if Settings.API_ENABLED == "0" then
    print("Error: API is disabled")
    os.exit(1)
  end
  
  local otp_code = ""
  local curl_opts = ""
  
  if has_2fa_enabled(omi_db, Settings.USERNAME) then
    otp_code = prompt_for_otp()
    curl_opts = ' -d "otp_code=' .. otp_code .. '"'
  end
  
  local tmp_file = "/tmp/omi_pull_" .. os.time()
  local cmd = Settings.CURL .. ' -f -X POST ' ..
    ' -d "username=' .. Settings.USERNAME .. '"' ..
    ' -d "password=' .. Settings.PASSWORD .. '"' ..
    ' -d "repo_name=' .. omi_db .. '"' ..
    ' -d "action=pull"' ..
    curl_opts ..
    ' -o "' .. tmp_file .. '" ' ..
    ' "' .. Settings.REPOS .. '/" 2>&1'
  
  if os.execute(cmd) == 0 then
    os.execute("mv " .. tmp_file .. " " .. omi_db)
    print("Successfully pulled from " .. Settings.REPOS)
  else
    print("Error: Failed to pull from remote")
    os.remove(tmp_file)
    os.exit(1)
  end
end

local function list_repos()
  print("=== Available Repositories on " .. Settings.REPOS .. " ===")
  
  local cmd = Settings.CURL .. ' -s "' .. Settings.REPOS .. '/?format=json" | grep -o \'"name":"[^"]*"\' | cut -d\'\"\' -f4'
  os.execute(cmd)
end

local function show_status()
  local omi_db = read_dotomi() or "repo.omi"
  
  print("=== Staged Files ===")
  sqlite_execute(omi_db, "SELECT filename, datetime FROM staging;")
  print("")
  
  print("=== Recent Commits ===")
  sqlite_execute(omi_db, "SELECT id, message, datetime FROM commits ORDER BY id DESC LIMIT 5;")
  print("")
  
  print("=== Statistics ===")
  io.write("Total blobs (deduplicated): ")
  sqlite_execute(omi_db, "SELECT COUNT(*) FROM blobs;")
  io.write("Total file versions: ")
  sqlite_execute(omi_db, "SELECT COUNT(*) FROM files;")
end

local function log_commits(limit)
  local omi_db = read_dotomi() or "repo.omi"
  limit = limit or "10"
  
  print("=== Commit History ===")
  sqlite_execute(omi_db, "SELECT id, datetime, user, message FROM commits ORDER BY id DESC LIMIT " .. limit .. ";")
end

-- Main program
local function main()
  Settings = Settings.load()
  
  local cmd = arg[1]
  
  if not cmd then
    print("Usage: omi <command> [args]")
    print("Commands: init, clone, add, commit, push, pull, list, log, status")
    os.exit(1)
  end
  
  -- Remove first argument (command) and keep rest for subcommands
  table.remove(arg, 1)
  
  if cmd == "init" then
    local db_name = arg[1] or "repo.omi"
    init_db(db_name)
  elseif cmd == "clone" then
    clone_db(arg[1])
  elseif cmd == "add" then
    add_files(arg[1])
  elseif cmd == "commit" then
    commit_files(unpack(arg))
  elseif cmd == "push" then
    push_changes()
  elseif cmd == "pull" then
    pull_changes()
  elseif cmd == "list" then
    list_repos()
  elseif cmd == "log" then
    log_commits(arg[1])
  elseif cmd == "status" then
    show_status()
  else
    print("Unknown command: " .. cmd)
    print("Usage: omi <command> [args]")
    print("Commands: init, clone, add, commit, push, pull, list, log, status")
    os.exit(1)
  end
end

main()
