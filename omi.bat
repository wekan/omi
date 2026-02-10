@ECHO OFF
REM Omi - Version Control for FreeDOS
REM Optimized Micro Index - Git-like commands with SQLite storage

REM Read settings from settings.txt
FOR /F "tokens=2 delims==" %%A IN ('FIND "SQLITE=" settings.txt') DO SET SQLITE=%%A
FOR /F "tokens=2 delims==" %%A IN ('FIND "USERNAME=" settings.txt') DO SET USERNAME=%%A
FOR /F "tokens=2 delims==" %%A IN ('FIND "PASSWORD=" settings.txt') DO SET PASSWORD=%%A
FOR /F "tokens=2 delims==" %%A IN ('FIND "REPOS=" settings.txt') DO SET REPOS=%%A
FOR /F "tokens=2 delims==" %%A IN ('FIND "CURL=" settings.txt') DO SET CURL=%%A

REM Database file
IF NOT EXIST .omi (
  SET OMI_DB=repo.omi
) ELSE (
  FOR /F "tokens=2 delims==" %%A IN ('TYPE .omi') DO SET OMI_DB=%%A
)

REM Get command
SET CMD=%1
SHIFT

REM Command dispatcher
IF "%CMD%"=="init" GOTO INIT_DB
IF "%CMD%"=="clone" GOTO CLONE_DB
IF "%CMD%"=="add" GOTO ADD_FILES
IF "%CMD%"=="commit" GOTO COMMIT_FILES
IF "%CMD%"=="push" GOTO PUSH_CHANGES
IF "%CMD%"=="pull" GOTO PULL_CHANGES
IF "%CMD%"=="list" GOTO LIST_REPOS
IF "%CMD%"=="log" GOTO LOG_COMMITS
IF "%CMD%"=="status" GOTO SHOW_STATUS

ECHO Unknown command: %CMD%
ECHO Usage: omi ^<command^> [args]
ECHO Commands: init, clone, add, commit, push, pull, list, log, status
GOTO END

:INIT_DB
  ECHO Initializing omi repository...
  ECHO OMI_DB=%OMI_DB% > .omi
  
  REM Create database schema with deduplication support
  %SQLITE% %OMI_DB% "CREATE TABLE IF NOT EXISTS blobs (hash TEXT PRIMARY KEY, data BLOB, size INTEGER);"
  %SQLITE% %OMI_DB% "CREATE TABLE IF NOT EXISTS files (id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, hash TEXT, datetime TEXT, commit_id INTEGER);"
  %SQLITE% %OMI_DB% "CREATE TABLE IF NOT EXISTS commits (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT, datetime TEXT, user TEXT);"
  %SQLITE% %OMI_DB% "CREATE TABLE IF NOT EXISTS staging (filename TEXT PRIMARY KEY, hash TEXT, datetime TEXT);"
  %SQLITE% %OMI_DB% "CREATE INDEX IF NOT EXISTS idx_files_hash ON files(hash);"
  %SQLITE% %OMI_DB% "CREATE INDEX IF NOT EXISTS idx_files_commit ON files(commit_id);"
  %SQLITE% %OMI_DB% "CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash);"
  
  ECHO Repository initialized: %OMI_DB%
  GOTO END

:CLONE_DB
  SET URL=%1
  ECHO Cloning from %URL%...
  
  REM For local files, just copy
  IF EXIST "%URL%" (
    COPY "%URL%" "%OMI_DB%"
    ECHO Cloned to %OMI_DB%
    ECHO OMI_DB=%OMI_DB% > .omi
  ) ELSE (
    REM Remote clone using curl
    FOR %%F IN ("%URL%") DO SET REPO_NAME=%%~nxF
    IF "%REPO_NAME%"==" " SET REPO_NAME=%OMI_DB%
    
    ECHO Downloading %REPO_NAME% from %REPOS%...
    %CURL% -f -o "%REPO_NAME%" "%REPOS%/?download=%REPO_NAME%"
    
    IF ERRORLEVEL 0 (
      ECHO Cloned to %REPO_NAME%
      ECHO OMI_DB=%REPO_NAME% > .omi
    ) ELSE (
      ECHO Error: Failed to clone from remote
    )
  )
  GOTO END

:ADD_FILES
  SET ARG=%1
  ECHO Adding files to staging...
  
  IF "%ARG%"=="--all" (
    REM Add all files in directory
    FOR %%F IN (*.*) DO (
      IF NOT "%%F"=="%OMI_DB%" (
        IF NOT "%%F"==".omi" (
          CALL :ADD_ONE_FILE "%%F"
        )
      )
    )
  ) ELSE (
    CALL :ADD_ONE_FILE "%ARG%"
  )
  GOTO END

:ADD_ONE_FILE
  SET ADDFILE=%~1
  IF NOT EXIST "%ADDFILE%" GOTO :EOF
  
  REM Calculate SHA256 hash
  %SQLITE% %OMI_DB% "SELECT lower(hex(sha256(readfile('%ADDFILE%'))));" > _hash.tmp
  SET /P HASH=<_hash.tmp
  
  REM Get current datetime in SQLite format
  %SQLITE% %OMI_DB% "SELECT datetime('now');" > _date.tmp
  SET /P DATETIME=<_date.tmp
  
  REM Add to staging area
  %SQLITE% %OMI_DB% "INSERT OR REPLACE INTO staging (filename, hash, datetime) VALUES ('%ADDFILE%', '%HASH%', '%DATETIME%');"
  
  ECHO Staged: %ADDFILE% (hash: %HASH%)
  
  DEL _hash.tmp _date.tmp
  GOTO :EOF

:COMMIT_FILES
  REM Parse commit message from -m "message"
  SET MSG=%~2
  IF "%MSG%"=="" SET MSG=No message
  
  ECHO Committing changes...
  
  REM Get current datetime
  %SQLITE% %OMI_DB% "SELECT datetime('now');" > _date.tmp
  SET /P DATETIME=<_date.tmp
  
  REM Get username
  SET USER=%USERNAME%
  IF "%USER%"=="" SET USER=unknown
  
  REM Create commit record
  %SQLITE% %OMI_DB% "INSERT INTO commits (message, datetime, user) VALUES ('%MSG%', '%DATETIME%', '%USER%'); SELECT last_insert_rowid();" > _commitid.tmp
  SET /P COMMIT_ID=<_commitid.tmp
  
  REM Process each staged file
  FOR /F "tokens=1,2,3" %%A IN ('%SQLITE% %OMI_DB% "SELECT filename, hash, datetime FROM staging;"') DO (
    CALL :COMMIT_ONE_FILE "%%A" "%%B" "%%C" "%COMMIT_ID%"
  )
  
  REM Clear staging area
  %SQLITE% %OMI_DB% "DELETE FROM staging;"
  
  ECHO Committed successfully (commit #%COMMIT_ID%)
  DEL _date.tmp _commitid.tmp
  GOTO END

:COMMIT_ONE_FILE
  SET FILENAME=%~1
  SET HASH=%~2
  SET FILEDATETIME=%~3
  SET CID=%~4
  
  REM Check if blob with this hash already exists (deduplication)
  %SQLITE% %OMI_DB% "SELECT COUNT(*) FROM blobs WHERE hash='%HASH%';" > _count.tmp
  SET /P BLOB_EXISTS=<_count.tmp
  
  IF "%BLOB_EXISTS%"=="0" (
    REM Blob doesn't exist, store it
    %SQLITE% %OMI_DB% "INSERT INTO blobs (hash, data, size) VALUES ('%HASH%', readfile('%FILENAME%'), length(readfile('%FILENAME%')));"
    ECHO Stored new blob: %HASH%
  ) ELSE (
    ECHO Blob already exists (deduplicated): %HASH%
  )
  
  REM Add file record (always add metadata even if blob exists)
  %SQLITE% %OMI_DB% "INSERT INTO files (filename, hash, datetime, commit_id) VALUES ('%FILENAME%', '%HASH%', '%FILEDATETIME%', %CID%);"
  
  DEL _count.tmp
  GOTO :EOF

:PUSH_CHANGES
  ECHO Pushing %OMI_DB% to remote...
  
  IF NOT EXIST "%OMI_DB%" (
    ECHO Error: Database file %OMI_DB% not found
    GOTO END
  )
  
  REM Upload using curl
  %CURL% -f -X POST -F "username=%USERNAME%" -F "password=%PASSWORD%" -F "repo_name=%OMI_DB%" -F "repo_file=@%OMI_DB%" -F "action=Upload" "%REPOS%/"
  
  IF ERRORLEVEL 0 (
    ECHO Successfully pushed to %REPOS%
  ) ELSE (
    ECHO Error: Failed to push to remote
  )
  GOTO END

:PULL_CHANGES
  ECHO Pulling %OMI_DB% from remote...
  
  FOR %%F IN ("%OMI_DB%") DO SET REPO_NAME=%%~nxF
  
  REM Download using curl with authentication
  %CURL% -f -X POST -d "username=%USERNAME%" -d "password=%PASSWORD%" -d "repo_name=%REPO_NAME%" -d "action=pull" -o "%OMI_DB%" "%REPOS%/"
  
  IF ERRORLEVEL 0 (
    ECHO Successfully pulled from %REPOS%
  ) ELSE (
    ECHO Error: Failed to pull from remote
  )
  GOTO END

:LIST_REPOS
  ECHO === Available Repositories on %REPOS% ===
  %CURL% -s "%REPOS%/?format=json"
  GOTO END

:LOG_COMMITS
  SET LIMIT=%1
  IF "%LIMIT%"=="" SET LIMIT=20
  ECHO === Commit History ===
  ECHO.
  %SQLITE% %OMI_DB% "SELECT 'Commit: ' || id || ' (' || user || ')' as info, 'Date: ' || datetime, 'Message: ' || message, '' as sep, (SELECT COUNT(*) FROM files WHERE commit_id = commits.id) || ' files' FROM commits ORDER BY id DESC LIMIT %LIMIT%;"
  GOTO END

:SHOW_STATUS
  ECHO === Staged Files ===
  %SQLITE% %OMI_DB% "SELECT filename, datetime FROM staging;"
  ECHO.
  ECHO === Recent Commits ===
  %SQLITE% %OMI_DB% "SELECT id, message, datetime FROM commits ORDER BY id DESC LIMIT 5;"
  GOTO END

:END
