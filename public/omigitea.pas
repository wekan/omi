{
  Omi - reading a Gitea folder
  ============================

  A Gitea installation is a work directory with custom/conf/app.ini, its
  SQLite database and its storage folders:

    <work>/custom/conf/app.ini
    <APP_DATA_PATH>/gitea.db                 [database] PATH
    <ROOT>/<owner>/<repo>.git, .wiki.git     [repository] ROOT
    <attachments>/<uuid[0]>/<uuid[1]>/<uuid> [attachment] PATH
    <lfs>/<oid[0:2]>/<oid[2:4]>/<oid[4:]>    [lfs] PATH
    <packages>/<sha[0:2]>/<sha[2:4]>/<sha>   [packages] PATH
    <avatars>/<user.avatar>                  [avatar] PATH / [picture] AVATAR_UPLOAD_PATH
    <repo-avatars>/<repository.avatar>       [repo-avatar] PATH / [picture] REPOSITORY_AVATAR_UPLOAD_PATH
    <actions_log>/<owner>/<repo>/<xx>/<id>.log
    <actions_artifacts>/<storage_path>
    <repo-archive>/<repo id>/<sha[:2]>/<sha>.<type>

  with the defaults and the resolution rules of Gitea's modules/setting
  (server.go, repository.go, database.go, storage.go): APP_DATA_PATH defaults
  to <work>/data; a relative ROOT or database PATH is beside the work
  directory, a relative storage PATH beside APP_DATA_PATH; a storage without a
  PATH of its own is [storage.<name>] PATH, else [storage] PATH/<name>, else
  <APP_DATA_PATH>/<name>.

  This unit only reads. It opens the database read-only (file:...?mode=ro),
  never selects a secret column (passwords, salts, tokens, keys, e-mail
  addresses), and measures the folders into a cached index - the sizes of
  ~900k files are not read again for every page. The index is a text file:

    #omi-gitea-index 1
    #source <disk | tree:FILE>
    #time   <UTC time>
    R <owner dir> <repo dir> <bytes> <files>   a git directory
    A <relative path> <bytes>                   an attachment file
    L ... LFS, P ... package blob, V ... avatar, W ... repository avatar,
    G ... actions log, F ... actions artifact, X ... repository archive,
    O <name> <bytes> <files>                    the rest of APP_DATA_PATH

  It is made by walking the folders, or from the output of `tree -s` (or
  `tree -a -s -F`) run in the work directory on the Gitea server, so a copy of
  the database can be measured somewhere else.

  Writes - importing from GitHub and deleting - are public/omigiteaw.pas's,
  which takes the lock and refuses while Gitea runs.
}

unit omigitea;

{$MODE OBJFPC}
{$H+}

interface

uses
  {$IFDEF UNIX}
  BaseUnix, Unix,
  {$ENDIF}
  SysUtils, Classes, DateUtils, Generics.Collections;

const
  // The prefix of C symbols: the Amiga's C compilers put '_' before each
  // name (sqlite3_open_v2 is _sqlite3_open_v2 in the m68k SQLite object).
  {$IFDEF HASAMIGA}
  GT_C = '_';
  {$ELSE}
  GT_C = '';
  {$ENDIF}
  // The largest file this platform can address. AmigaOS 3's dos.library has
  // 32-bit signed offsets (Seek, fib_Size): a file of 2 GiB or more is
  // refused there with a clear error instead of being read or written wrong.
  {$IFDEF HASAMIGA}
  GT_MAX_FILE = Int64(High(LongInt));
  {$ELSE}
  GT_MAX_FILE = High(Int64);
  {$ENDIF}

type
  TGtRow = array of string;
  TGtRows = array of TGtRow;
  TGtSizeMap = specialize TDictionary<string, Int64>;

  TGtPaths = record
    AppIni, WorkPath, AppDataPath, DbType, DbPath, RepoRoot: string;
    Attachments, Lfs, Packages, Avatars, RepoAvatars, ActionsLog,
    ActionsArtifacts, RepoArchive: string;
    // Storages that are not on the local disk (minio, azureblob).
    NonLocal: string;
    HttpAddr: string;
    HttpPort: Integer;
    // [repository] SCRIPT_TYPE: the shell of Gitea's hooks.
    ScriptType: string;
  end;

  TGtRepoSize = record
    Id, OwnerId: Int64;
    Owner, Name, LowerOwner, LowerName: string;
    DbSize, DbGit, DbLfs: Int64;
    HasDir, HasWiki: Boolean;
    DiskGit, DiskWiki, DiskFiles: Int64;
    LfsRows, LfsRowBytes, LfsDisk, LfsMissing: Int64;
    AttRows, AttRowBytes, AttDisk, AttMissing: Int64;
    Issues, Pulls: Int64;
    Total: Int64;
    Mismatch: string;
  end;

  TGtOwnerSize = record
    Id: Int64;
    Name: string;
    Kind: Integer; // 0 user, 1 organization
    Repos: Integer;
    Git, Wiki, Lfs, Attachments, Packages, Avatar, Total, DbSize: Int64;
    Mismatches: Integer;
  end;

  TGtReport = record
    Repos: array of TGtRepoSize;
    Owners: array of TGtOwnerSize;
    // kind TAB path TAB bytes TAB reason
    Orphans: TStringList;
    IndexTime, IndexSource: string;
    // Set when a delete changed the folders after the index was made.
    IndexStale: string;
    TotalGit, TotalWiki, TotalLfs, TotalAttachments, TotalPackages,
    TotalAvatars, TotalRepoAvatars, TotalActionsLog, TotalArtifacts,
    TotalArchives, TotalOther, TotalOrphanBytes: Int64;
  end;

  // What a path is, without following a symbolic link.
  TGtKind = (gkNone, gkFile, gkDir, gkLink, gkOther);
  EGtTooLarge = class(Exception);

  // Forwards every write to Target and refuses (EGtTooLarge) the byte that
  // would make the file larger than GT_MAX_FILE: a download or a pack is
  // streamed, never held in memory, and never cut silently at 2 GiB.
  TGtLimitStream = class(TStream)
  private
    FTarget: TStream;
    FWhat: string;
    FCount: Int64;
  public
    constructor Create(ATarget: TStream; const AWhat: string);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Count: Int64 read FCount;
  end;

{ --- the file system, portably ---------------------------------------------------
  Every path of the Gitea folder is built with GtPath (PathDelim, and no '/'
  after an Amiga volume name: "Work:" + "gitea" is "Work:gitea"). What only a
  Unix system has - lstat, fsync, rename over a file, O_EXCL, kill(pid, 0),
  realpath - is compiled only on Unix here, with the portable SysUtils
  equivalent elsewhere. }

// The parts joined with the platform's directory separator.
function GtPath(const Parts: array of string): string;
// Absolute: "/x" on Unix, "Volume:x" on the Amiga, "C:\x" on Windows.
function GtIsAbs(const Path: string): Boolean;
// Path is inside Root (not Root itself); both as given, not resolved.
function GtUnder(const Root, Path: string): Boolean;
// What Path is (a symbolic link is not followed) and, for a file, its size.
function GtKind(const Path: string; out Size: Int64): TGtKind;
// Anything at Path, a dangling symbolic link too.
function GtExists(const Path: string): Boolean;
// The names in Dir, without '.' and '..'; empty when Dir cannot be read.
function GtListDir(const Dir: string): TStringList;
// Symbolic links resolved where the platform has them.
function GtRealPath(const Path: string): string;
// The whole file written and flushed to the disk (fsync where there is one).
function GtWriteSynced(const Path, Text: string): Boolean;
// A line appended and flushed.
function GtAppendSynced(const Path, Text: string): Boolean;
// The directory's entries flushed (Unix; elsewhere closing a file does it).
procedure GtSyncDir(const Dir: string);
// Src renamed over Dst: atomic on Unix; elsewhere Dst is deleted first.
function GtRenameOver(const Src, Dst: string): Boolean;
// A directory renamed (Dst must not exist).
function GtRenameDir(const Src, Dst: string): Boolean;
// Creates Path with Text only when nothing is there (O_EXCL on Unix).
function GtCreateExclusive(const Path, Text: string): Boolean;
function GtPid: Int64;
// Whether process Pid of this host lives. Known is False where the platform
// cannot tell (then the answer is True: assume it lives).
function GtPidAlive(Pid: Int64; out Known: Boolean): Boolean;
function GtHostName: string;
// Dir and the directories above it made. SysUtils' ForceDirectories cannot
// do it on the Amiga: it asks for "Work:/" (the parent of a volume), which
// does not exist.
function GtForceDirs(const Dir: string): Boolean;
// Permission bits where the platform has them.
procedure GtChmod(const Path: string; Mode: LongInt);
// Raises EGtTooLarge when Size cannot be a file on this platform.
procedure GtCheckSize(Size: Int64; const What: string);

var
  // GT_MAX_FILE, or less when the tests say so (OMI_TEST_MAX_FILE): the
  // refusal is tested without writing 2 GiB.
  GtMaxFile: Int64 = GT_MAX_FILE;

// app.ini as "section.KEY=value" lines (the keys before the first section are
// ".KEY"); sections lowercase, keys uppercase, quotes removed.
function GtParseIni(const Path: string; Ini: TStringList; out ErrorText: string): Boolean;
function GtIniValue(Ini: TStringList; const Section, Key: string): string;
function GtResolvePaths(const AppIni: string; out P: TGtPaths; out ErrorText: string): Boolean;

// One owner or repository name as Gitea allows it: [A-Za-z0-9_.-], not '.'
// or '..', no leading '.' or '-'. A name that is not is never a path.
function GtNameIsSafe(const Name: string): Boolean;
// A repository name as Gitea takes one (models/repo/repo.go IsUsableRepoName):
// letters, digits, '_', '-' and '.', no '..', not '.', '..' or '-', and not
// ending in .wiki, .git, .rss or .atom - so .github is one. Unlike Gitea,
// not starting with '-', so a name is never read as a command's option.
function GtRepoNameIsValid(const Name: string): Boolean;

// A read-only query (file:...?mode=ro). MaxRows 0 is every row.
function GtQuery(const DbPath, Sql: string; const Params: array of string;
  out Rows: TGtRows; out ErrorText: string; MaxRows: Integer = 0): Boolean;
function GtHasColumn(const DbPath, Table, Column: string): Boolean;

function GtIndexPathFor(const IndexPath: string): string;
// Walks the folders (TreeFile = '') or reads `tree -s` output, and writes the
// index (IndexPath.tmp, then renamed).
function GtBuildIndex(const P: TGtPaths; const TreeFile, IndexPath: string;
  out Files: Int64; out ErrorText: string): Boolean;
// The sizes of every owner and repository from the index and the database,
// the mismatches between them and the orphans.
// The app.ini a size index was made for ('' when the file has none).
function GtIndexAppIni(const IndexPath: string): string;
function GtLoadReport(const P: TGtPaths; const IndexPath: string;
  out R: TGtReport; out ErrorText: string): Boolean;
procedure GtFreeReport(var R: TGtReport);

// Sorting: 'name', 'total', 'git', 'lfs', 'attachments', 'packages', 'repos';
// numbers largest first.
procedure GtSortOwners(var R: TGtReport; const Key: string);
procedure GtSortRepos(var Repos: array of TGtRepoSize; const Key: string);

function GtUnixToText(const Value: string): string;

implementation

const
  SQLITE_OK = 0;
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;
  SQLITE_OPEN_READONLY = $00000001;
  SQLITE_OPEN_URI = $00000040;
  INDEX_MAGIC = '#omi-gitea-index 1';

function sqlite3_open_v2(FileName: PChar; var Db: Pointer; Flags: Integer;
  Vfs: PChar): Integer; cdecl; external name GT_C + 'sqlite3_open_v2';
function sqlite3_close(Db: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_close';
function sqlite3_errmsg(Db: Pointer): PChar; cdecl; external name GT_C + 'sqlite3_errmsg';
function sqlite3_busy_timeout(Db: Pointer; Ms: Integer): Integer; cdecl; external name GT_C + 'sqlite3_busy_timeout';
function sqlite3_prepare_v2(Db: Pointer; Sql: PChar; NBytes: Integer;
  var Stmt: Pointer; Tail: PPChar): Integer; cdecl; external name GT_C + 'sqlite3_prepare_v2';
function sqlite3_bind_text(Stmt: Pointer; Index: Integer; Value: PChar;
  NBytes: Integer; Destructor_: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_bind_text';
function sqlite3_step(Stmt: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_step';
function sqlite3_column_count(Stmt: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_column_count';
function sqlite3_column_text(Stmt: Pointer; Col: Integer): PChar; cdecl; external name GT_C + 'sqlite3_column_text';
function sqlite3_column_bytes(Stmt: Pointer; Col: Integer): Integer; cdecl; external name GT_C + 'sqlite3_column_bytes';
function sqlite3_finalize(Stmt: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_finalize';


{ --- the file system, portably ----------------------------------------------- }

{$IFDEF UNIX}
function c_realpath(Path, Resolved: PChar): PChar; cdecl; external 'c' name 'realpath';
{$ENDIF}

var
  ExclusiveLock: TRTLCriticalSection;

constructor TGtLimitStream.Create(ATarget: TStream; const AWhat: string);
begin
  inherited Create;
  FTarget := ATarget;
  FWhat := AWhat;
  FCount := 0;
end;

function TGtLimitStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := FTarget.Read(Buffer, Count);
end;

function TGtLimitStream.Write(const Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  GtCheckSize(FCount + Count, FWhat);
  Result := FTarget.Write(Buffer, Count);
  if Result > 0 then
    Inc(FCount, Result);
end;

function TGtLimitStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Offset = 0) and (Origin = soCurrent) then
    Result := FCount
  else
    Result := FTarget.Seek(Offset, Origin);
end;

procedure GtCheckSize(Size: Int64; const What: string);
begin
  if (Size < 0) or (Size > GtMaxFile) then
    raise EGtTooLarge.Create(What + ' is ' + IntToStr(Size) + ' bytes or more; this platform addresses files of at ' +
      'most ' + IntToStr(GtMaxFile) + ' bytes.');
end;

function GtPath(const Parts: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Parts) do
    if Parts[I] = '' then
      Continue
    else if Result = '' then
      Result := Parts[I]
    else if PathDelim <> '/' then
      // A part may be a Gitea relative name ("ab/cd/x"): '/' in it is a separator.
      Result := IncludeTrailingPathDelimiter(Result) +
        ExcludeLeadingPathDelimiter(StringReplace(Parts[I], '/', PathDelim, [rfReplaceAll]))
    else
      Result := IncludeTrailingPathDelimiter(Result) + ExcludeLeadingPathDelimiter(Parts[I]);
end;

function GtIsAbs(const Path: string): Boolean;
begin
  {$IFDEF HASAMIGA}
  Result := Pos(DriveSeparator, Path) > 0;
  {$ELSE}
  Result := (Path <> '') and ((Path[1] in AllowDirectorySeparators) or (ExtractFileDrive(Path) <> ''));
  {$ENDIF}
end;

function GtUnder(const Root, Path: string): Boolean;
var
  R: string;
begin
  if Root = '' then
    Exit(False);
  R := IncludeTrailingPathDelimiter(Root);
  Result := (Length(Path) > Length(R)) and (Copy(Path, 1, Length(R)) = R);
end;

function GtKind(const Path: string; out Size: Int64): TGtKind;
{$IFDEF UNIX}
var
  St: Stat;
begin
  Size := 0;
  if fpLStat(Path, St) <> 0 then
    Exit(gkNone);
  if fpS_ISREG(St.st_mode) then
  begin
    Size := St.st_size;
    Result := gkFile;
  end
  else if fpS_ISDIR(St.st_mode) then
    Result := gkDir
  else if fpS_ISLNK(St.st_mode) then
    Result := gkLink
  else
    Result := gkOther;
end;
{$ELSE}
var
  Sr: TSearchRec;
begin
  Size := 0;
  Result := gkNone;
  if DirectoryExists(Path) then
    Exit(gkDir);
  if FindFirst(Path, faAnyFile, Sr) = 0 then
  begin
    if (Sr.Attr and faDirectory) <> 0 then
      Result := gkDir
    else
    begin
      Result := gkFile;
      Size := Sr.Size;
    end;
    FindClose(Sr);
  end
  else if FileExists(Path) then
    Result := gkFile;
end;
{$ENDIF}

function GtExists(const Path: string): Boolean;
var
  Size: Int64;
begin
  Result := GtKind(Path, Size) <> gkNone;
end;

function GtListDir(const Dir: string): TStringList;
{$IFDEF UNIX}
var
  D: pDir;
  Entry: pDirent;
  Name: string;
begin
  Result := TStringList.Create;
  D := fpOpenDir(Dir);
  if D = nil then
    Exit;
  try
    repeat
      Entry := fpReadDir(D^);
      if Entry = nil then
        Break;
      Name := StrPas(@Entry^.d_name[0]);
      if (Name <> '.') and (Name <> '..') then
        Result.Add(Name);
    until False;
  finally
    fpCloseDir(D^);
  end;
end;
{$ELSE}
var
  Sr: TSearchRec;
begin
  Result := TStringList.Create;
  if FindFirst(GtPath([Dir, '*']), faAnyFile or faDirectory, Sr) = 0 then
  begin
    repeat
      if (Sr.Name <> '.') and (Sr.Name <> '..') and (Sr.Name <> '') then
        Result.Add(Sr.Name);
    until FindNext(Sr) <> 0;
    FindClose(Sr);
  end;
end;
{$ENDIF}

function GtRealPath(const Path: string): string;
{$IFDEF UNIX}
var
  Buf: array[0..4095] of Char;
begin
  if c_realpath(PChar(Path), @Buf[0]) <> nil then
    Result := StrPas(@Buf[0])
  else
    Result := ExpandFileName(Path);
end;
{$ELSE}
begin
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(Path));
end;
{$ENDIF}

{$IFDEF UNIX}
function WriteFd(const Path, Text: string; Flags: cint): Boolean;
var
  Fd: cint;
begin
  Fd := fpOpen(Path, Flags, &644);
  if Fd < 0 then
    Exit(False);
  try
    Result := (Length(Text) = 0) or (fpWrite(Fd, Text[1], Length(Text)) = Length(Text));
    fpFsync(Fd);
  finally
    fpClose(Fd);
  end;
end;
{$ELSE}
function WriteHandle(const Path, Text: string; Append: Boolean): Boolean;
var
  H: THandle;
begin
  {$IFDEF HASAMIGA}
  // FreePascal 3.2.3's FileCreate leaves its result unset when AmigaDOS'
  // Open() fails: a file in a drawer that is not there is refused here.
  if not DirectoryExists(ExtractFileDir(ExpandFileName(Path))) then
    Exit(False);
  {$ENDIF}
  if Append and FileExists(Path) then
  begin
    H := FileOpen(Path, fmOpenReadWrite or fmShareDenyNone);
    if H <> THandle(-1) then
      FileSeek(H, 0, fsFromEnd);
  end
  else
    H := FileCreate(Path);
  if (H = THandle(-1)) or (H = 0) then
    Exit(False);
  try
    Result := (Length(Text) = 0) or (FileWrite(H, Text[1], Length(Text)) = Length(Text));
    FileFlush(H);
  finally
    FileClose(H);
  end;
end;
{$ENDIF}

function GtForceDirs(const Dir: string): Boolean;
var
  D, Parent: string;
begin
  D := ExcludeTrailingPathDelimiter(Dir);
  if (D = '') or DirectoryExists(D) then
    Exit(True);
  {$IFDEF HASAMIGA}
  // A volume or an assign is there or not; it is never made.
  if D[Length(D)] = DriveSeparator then
    Exit(False);
  {$ENDIF}
  Parent := ExtractFileDir(D);
  if (Parent <> '') and (Parent <> D) and not GtForceDirs(Parent) then
    Exit(False);
  Result := CreateDir(D) or DirectoryExists(D);
end;

function GtWriteSynced(const Path, Text: string): Boolean;
begin
  {$IFDEF UNIX}
  Result := WriteFd(Path, Text, O_WRONLY or O_CREAT or O_TRUNC);
  {$ELSE}
  Result := WriteHandle(Path, Text, False);
  {$ENDIF}
end;

function GtAppendSynced(const Path, Text: string): Boolean;
begin
  {$IFDEF UNIX}
  Result := WriteFd(Path, Text, O_WRONLY or O_CREAT or O_APPEND);
  {$ELSE}
  Result := WriteHandle(Path, Text, True);
  {$ENDIF}
end;

procedure GtSyncDir(const Dir: string);
{$IFDEF UNIX}
var
  Fd: cint;
begin
  Fd := fpOpen(ExcludeTrailingPathDelimiter(Dir), O_RDONLY);
  if Fd >= 0 then
  begin
    fpFsync(Fd);
    fpClose(Fd);
  end;
end;
{$ELSE}
begin
end;
{$ENDIF}

function GtRenameOver(const Src, Dst: string): Boolean;
begin
  {$IFDEF UNIX}
  Result := fpRename(Src, Dst) = 0;
  {$ELSE}
  if FileExists(Dst) then
    DeleteFile(Dst);
  Result := RenameFile(Src, Dst);
  {$ENDIF}
end;

function GtRenameDir(const Src, Dst: string): Boolean;
begin
  if GtExists(Dst) then
    Exit(False);
  {$IFDEF UNIX}
  Result := fpRename(Src, Dst) = 0;
  {$ELSE}
  Result := RenameFile(Src, Dst);
  {$ENDIF}
end;

function GtCreateExclusive(const Path, Text: string): Boolean;
begin
  {$IFDEF UNIX}
  Result := WriteFd(Path, Text, O_CREAT or O_EXCL or O_WRONLY);
  {$ELSE}
  // No O_EXCL: checked and created under this process's lock. On the Amiga
  // Omi is the only program that writes the Gitea folder.
  EnterCriticalSection(ExclusiveLock);
  try
    Result := not GtExists(Path) and WriteHandle(Path, Text, False);
  finally
    LeaveCriticalSection(ExclusiveLock);
  end;
  {$ENDIF}
end;

function GtPid: Int64;
begin
  Result := GetProcessID;
end;

function GtPidAlive(Pid: Int64; out Known: Boolean): Boolean;
begin
  {$IFDEF UNIX}
  Known := True;
  Result := (Pid > 0) and (Pid <= High(LongInt)) and ((fpKill(TPid(Pid), 0) = 0) or (fpGetErrno = ESysEPERM));
  {$ELSE}
  Known := False;
  Result := True;
  {$ENDIF}
end;

function GtHostName: string;
begin
  {$IFDEF UNIX}
  Result := GetHostName;
  {$ELSE}
  Result := GetEnvironmentVariable('HOSTNAME');
  if Result = '' then
    Result := GetEnvironmentVariable('COMPUTERNAME');
  if Result = '' then
    Result := 'localhost';
  {$ENDIF}
end;

procedure GtChmod(const Path: string; Mode: LongInt);
begin
  {$IFDEF UNIX}
  fpChmod(Path, Mode);
  {$ENDIF}
end;

{ --- app.ini ------------------------------------------------------------------- }

function Unquote(const S: string): string;
begin
  Result := S;
  if (Length(Result) >= 2) and (((Result[1] = '"') and (Result[Length(Result)] = '"')) or
    ((Result[1] = '`') and (Result[Length(Result)] = '`'))) then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function GtParseIni(const Path: string; Ini: TStringList; out ErrorText: string): Boolean;
var
  Lines: TStringList;
  I, Eq: Integer;
  Line, Section, Key, Value: string;
begin
  Result := False;
  ErrorText := '';
  Ini.Clear;
  if not FileExists(Path) then
  begin
    ErrorText := 'no such file: ' + Path;
    Exit;
  end;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(Path);
    except
      on E: Exception do
      begin
        ErrorText := E.Message;
        Exit;
      end;
    end;
    Section := '';
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] = ';') or (Line[1] = '#') then
        Continue;
      if (Line[1] = '[') and (Line[Length(Line)] = ']') then
      begin
        Section := LowerCase(Trim(Copy(Line, 2, Length(Line) - 2)));
        Continue;
      end;
      Eq := Pos('=', Line);
      if Eq = 0 then
        Continue;
      Key := UpperCase(Trim(Copy(Line, 1, Eq - 1)));
      Value := Unquote(Trim(Copy(Line, Eq + 1, MaxInt)));
      Ini.Values[Section + '.' + Key] := Value;
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

function GtIniValue(Ini: TStringList; const Section, Key: string): string;
begin
  Result := Ini.Values[LowerCase(Section) + '.' + UpperCase(Key)];
end;

function JoinPath(const Base, Rel: string): string;
begin
  if Rel = '' then
    Result := Base
  else if GtIsAbs(Rel) then
    Result := Rel
  else
    Result := GtPath([Base, Rel]);
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(Result));
end;

function GtResolvePaths(const AppIni: string; out P: TGtPaths; out ErrorText: string): Boolean;
var
  Ini: TStringList;
  Conf, V: string;

  function Val(const Section, Key: string): string;
  begin
    Result := GtIniValue(Ini, Section, Key);
  end;

  procedure NoteType(const Name, StorageType: string);
  begin
    if (StorageType <> '') and not SameText(StorageType, 'local') then
    begin
      if P.NonLocal <> '' then
        P.NonLocal := P.NonLocal + ',';
      P.NonLocal := P.NonLocal + Name;
    end;
  end;

  // modules/setting/storage.go getStorageForLocal: the override section's
  // PATH, else [storage.<name>] PATH, else [storage] PATH/<name>, else
  // APP_DATA_PATH/<name>; relative to APP_DATA_PATH.
  function Storage(const Name, Override, OverridePath: string): string;
  var
    T: string;
  begin
    T := '';
    if Override <> '' then
      T := Val(Override, 'STORAGE_TYPE');
    // STORAGE_TYPE may name a [storage.<x>] section instead of a type.
    if (T <> '') and not SameText(T, 'local') and (Ini.IndexOfName('storage.' + LowerCase(T) + '.PATH') >= 0) then
      T := Val('storage.' + LowerCase(T), 'STORAGE_TYPE');
    if T = '' then
      T := Val('storage.' + Name, 'STORAGE_TYPE');
    if T = '' then
      T := Val('storage', 'STORAGE_TYPE');
    NoteType(Name, T);
    if OverridePath <> '' then
      Result := JoinPath(P.AppDataPath, OverridePath)
    else if Val('storage.' + Name, 'PATH') <> '' then
      Result := JoinPath(P.AppDataPath, Val('storage.' + Name, 'PATH'))
    else if Val('storage', 'PATH') <> '' then
      Result := JoinPath(JoinPath(P.AppDataPath, Val('storage', 'PATH')), Name)
    else
      Result := JoinPath(P.AppDataPath, Name);
  end;

begin
  Result := False;
  P := Default(TGtPaths);
  Conf := ExpandFileName(AppIni);
  P.AppIni := Conf;
  Ini := TStringList.Create;
  try
    if not GtParseIni(Conf, Ini, ErrorText) then
      Exit;
    // WORK_PATH, else GITEA_WORK_DIR, else <work>/custom/conf/app.ini.
    V := Val('', 'WORK_PATH');
    if V = '' then
      V := GetEnvironmentVariable('GITEA_WORK_DIR');
    if V = '' then
    begin
      V := ExtractFileDir(Conf);
      if SameText(ExtractFileName(V), 'conf') and
        SameText(ExtractFileName(ExtractFileDir(V)), 'custom') then
        V := ExtractFileDir(ExtractFileDir(V));
    end;
    P.WorkPath := ExcludeTrailingPathDelimiter(ExpandFileName(V));
    P.AppDataPath := JoinPath(P.WorkPath, Val('server', 'APP_DATA_PATH'));
    if Val('server', 'APP_DATA_PATH') = '' then
      P.AppDataPath := JoinPath(P.WorkPath, 'data');
    if Val('repository', 'ROOT') <> '' then
      P.RepoRoot := JoinPath(P.WorkPath, Val('repository', 'ROOT'))
    else
      P.RepoRoot := JoinPath(P.AppDataPath, 'gitea-repositories');
    P.DbType := LowerCase(Val('database', 'DB_TYPE'));
    if P.DbType = '' then
      P.DbType := 'sqlite3';
    if Val('database', 'PATH') <> '' then
      P.DbPath := JoinPath(P.WorkPath, Val('database', 'PATH'))
    else
      P.DbPath := JoinPath(P.AppDataPath, 'gitea.db');

    P.Attachments := Storage('attachments', 'attachment', Val('attachment', 'PATH'));
    V := Val('lfs', 'PATH');
    if V = '' then
      V := Val('server', 'LFS_CONTENT_PATH');
    P.Lfs := Storage('lfs', 'lfs', V);
    P.Packages := Storage('packages', 'packages', Val('packages', 'PATH'));
    V := Val('avatar', 'PATH');
    if V = '' then
      V := Val('picture', 'AVATAR_UPLOAD_PATH');
    P.Avatars := Storage('avatars', 'avatar', V);
    V := Val('repo-avatar', 'PATH');
    if V = '' then
      V := Val('picture', 'REPOSITORY_AVATAR_UPLOAD_PATH');
    P.RepoAvatars := Storage('repo-avatars', 'repo-avatar', V);
    P.ActionsLog := Storage('actions_log', '', '');
    P.ActionsArtifacts := Storage('actions_artifacts', 'actions.artifacts', Val('actions.artifacts', 'PATH'));
    P.RepoArchive := Storage('repo-archive', 'repo-archive', Val('repo-archive', 'PATH'));

    P.ScriptType := Val('repository', 'SCRIPT_TYPE');
    if P.ScriptType = '' then
      P.ScriptType := 'bash';
    P.HttpAddr := Val('server', 'HTTP_ADDR');
    if (P.HttpAddr = '') or (P.HttpAddr = '0.0.0.0') then
      P.HttpAddr := '127.0.0.1';
    P.HttpPort := StrToIntDef(Val('server', 'HTTP_PORT'), 3000);
    if SameText(Val('server', 'PROTOCOL'), 'http+unix') then
      P.HttpPort := 0;
    Result := True;
  finally
    Ini.Free;
  end;
end;

function GtNameIsSafe(const Name: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (Name = '') or (Length(Name) > 255) or (Name = '.') or (Name = '..') or
    (Name[1] = '.') or (Name[1] = '-') then
    Exit;
  for I := 1 to Length(Name) do
    if not (Name[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-']) then
      Exit;
  if Pos('..', Name) > 0 then
    Exit;
  Result := True;
end;

const
  RESERVED_REPO_SUFFIXES: array[0..3] of string = ('.wiki', '.git', '.rss', '.atom');

function GtRepoNameIsValid(const Name: string): Boolean;
var
  I: Integer;
  L: string;
begin
  Result := False;
  if (Name = '') or (Length(Name) > 255) or (Name[1] = '-') or (Pos('..', Name) > 0) then
    Exit;
  for I := 1 to Length(Name) do
    if not (Name[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-']) then
      Exit;
  L := LowerCase(Name);
  if (L = '.') or (L = '-') then
    Exit;
  for I := 0 to 3 do
    if Copy(L, Length(L) - Length(RESERVED_REPO_SUFFIXES[I]) + 1, MaxInt) = RESERVED_REPO_SUFFIXES[I] then
      Exit;
  Result := True;
end;

{ --- SQLite, read-only ---------------------------------------------------------- }

function UriPath(const Path: string): string;
var
  I: Integer;
begin
  Result := 'file:';
  for I := 1 to Length(Path) do
    case Path[I] of
      '%', '?', '#': Result := Result + '%' + IntToHex(Ord(Path[I]), 2);
    else
      Result := Result + Path[I];
    end;
  Result := Result + '?mode=ro';
end;

function GtQuery(const DbPath, Sql: string; const Params: array of string;
  out Rows: TGtRows; out ErrorText: string; MaxRows: Integer): Boolean;
var
  Db, Stmt: Pointer;
  Rc, Cols, I, N, Count: Integer;
  PValue: PChar;
  Row: TGtRow;
  Value: string;
begin
  Rows := nil;
  Result := False;
  ErrorText := '';
  if not FileExists(DbPath) then
  begin
    ErrorText := 'no such database: ' + DbPath;
    Exit;
  end;
  Db := nil;
  if sqlite3_open_v2(PChar(UriPath(DbPath)), Db, SQLITE_OPEN_READONLY or SQLITE_OPEN_URI, nil) <> SQLITE_OK then
  begin
    if Assigned(Db) then
    begin
      ErrorText := StrPas(sqlite3_errmsg(Db));
      sqlite3_close(Db);
    end
    else
      ErrorText := 'SQLite could not open the database';
    Exit;
  end;
  try
    sqlite3_busy_timeout(Db, 5000);
    Stmt := nil;
    if sqlite3_prepare_v2(Db, PChar(Sql), -1, Stmt, nil) <> SQLITE_OK then
    begin
      ErrorText := StrPas(sqlite3_errmsg(Db));
      Exit;
    end;
    try
      for I := 0 to High(Params) do
        if sqlite3_bind_text(Stmt, I + 1, PChar(Params[I]), Length(Params[I]), Pointer(-1)) <> SQLITE_OK then
        begin
          ErrorText := StrPas(sqlite3_errmsg(Db));
          Exit;
        end;
      Cols := sqlite3_column_count(Stmt);
      Count := 0;
      SetLength(Rows, 64);
      repeat
        Rc := sqlite3_step(Stmt);
        if Rc = SQLITE_ROW then
        begin
          Row := nil;
          SetLength(Row, Cols);
          for I := 0 to Cols - 1 do
          begin
            PValue := sqlite3_column_text(Stmt, I);
            N := sqlite3_column_bytes(Stmt, I);
            Value := '';
            if Assigned(PValue) and (N > 0) then
              SetString(Value, PValue, N);
            Row[I] := Value;
          end;
          if Count = Length(Rows) then
            SetLength(Rows, Count * 2);
          Rows[Count] := Row;
          Inc(Count);
          if (MaxRows > 0) and (Count >= MaxRows) then
            Break;
        end;
      until Rc <> SQLITE_ROW;
      SetLength(Rows, Count);
      if (Rc <> SQLITE_DONE) and (Rc <> SQLITE_ROW) then
      begin
        ErrorText := StrPas(sqlite3_errmsg(Db));
        Exit;
      end;
      Result := True;
    finally
      sqlite3_finalize(Stmt);
    end;
  finally
    sqlite3_close(Db);
  end;
end;

function GtHasColumn(const DbPath, Table, Column: string): Boolean;
var
  Rows: TGtRows;
  E: string;
begin
  Result := GtQuery(DbPath, 'SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2',
    [Table, Column], Rows, E) and (Length(Rows) = 1) and (Rows[0][0] = '1');
end;

{ --- the index ---------------------------------------------------------------- }

type
  TIndexWriter = class
  private
    FOut: TextFile;
    FOpen: Boolean;
    FRepoBytes: TGtSizeMap;
    FRepoFiles: TGtSizeMap;
    FOtherBytes: TGtSizeMap;
    FOtherFiles: TGtSizeMap;
  public
    Paths: TGtPaths;
    Files: Int64;
    constructor Create;
    destructor Destroy; override;
    function Open(const FileName, Source: string; out E: string): Boolean;
    procedure Line(const Kind, Rel: string; Size: Int64);
    // One file anywhere in the work directory, by its absolute path.
    procedure Classify(const AbsPath: string; Size: Int64);
    procedure Finish;
  end;

constructor TIndexWriter.Create;
begin
  FRepoBytes := TGtSizeMap.Create;
  FRepoFiles := TGtSizeMap.Create;
  FOtherBytes := TGtSizeMap.Create;
  FOtherFiles := TGtSizeMap.Create;
end;

destructor TIndexWriter.Destroy;
begin
  if FOpen then
    CloseFile(FOut);
  FRepoBytes.Free;
  FRepoFiles.Free;
  FOtherBytes.Free;
  FOtherFiles.Free;
  inherited Destroy;
end;

function TIndexWriter.Open(const FileName, Source: string; out E: string): Boolean;
begin
  Result := False;
  E := '';
  try
    AssignFile(FOut, FileName);
    Rewrite(FOut);
    FOpen := True;
  except
    on Ex: Exception do
    begin
      E := Ex.Message;
      Exit;
    end;
  end;
  WriteLn(FOut, INDEX_MAGIC);
  WriteLn(FOut, '#source'#9, Source);
  WriteLn(FOut, '#time'#9, FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', LocalTimeToUniversal(Now)));
  WriteLn(FOut, '#appini'#9, Paths.AppIni);
  Result := True;
end;

procedure TIndexWriter.Line(const Kind, Rel: string; Size: Int64);
begin
  WriteLn(FOut, Kind, #9, Rel, #9, Size);
  Inc(Files);
end;

procedure AddTo(Map: TGtSizeMap; const Key: string; Value: Int64);
var
  Old: Int64;
begin
  if Map.TryGetValue(Key, Old) then
    Map[Key] := Old + Value
  else
    Map.Add(Key, Value);
end;

// Rel is the part of Path under Root, with '/' between its names whatever
// the platform's separator (the index's format).
function Under(const Root, Path: string; out Rel: string): Boolean;
begin
  Result := GtUnder(Root, Path);
  if Result then
  begin
    Rel := Copy(Path, Length(IncludeTrailingPathDelimiter(Root)) + 1, MaxInt);
    if PathDelim <> '/' then
      Rel := StringReplace(Rel, PathDelim, '/', [rfReplaceAll]);
  end
  else
    Rel := '';
end;

procedure TIndexWriter.Classify(const AbsPath: string; Size: Int64);
var
  Rel, Best, BestKind, R, Owner, Repo: string;
  Slash: Integer;

  procedure Try_(const Root, Kind: string);
  begin
    if Under(Root, AbsPath, R) and (Length(Root) > Length(Best)) then
    begin
      Best := Root;
      BestKind := Kind;
      Rel := R;
    end;
  end;

begin
  Best := '';
  BestKind := '';
  Rel := '';
  Try_(Paths.RepoRoot, 'R');
  Try_(Paths.Attachments, 'A');
  Try_(Paths.Lfs, 'L');
  Try_(Paths.Packages, 'P');
  Try_(Paths.Avatars, 'V');
  Try_(Paths.RepoAvatars, 'W');
  Try_(Paths.ActionsLog, 'G');
  Try_(Paths.ActionsArtifacts, 'F');
  Try_(Paths.RepoArchive, 'X');
  if BestKind = 'R' then
  begin
    // <owner>/<repo>.git/...
    Slash := Pos('/', Rel);
    if Slash = 0 then
      Exit;
    Owner := Copy(Rel, 1, Slash - 1);
    R := Copy(Rel, Slash + 1, MaxInt);
    Slash := Pos('/', R);
    if Slash = 0 then
      Exit;
    Repo := Copy(R, 1, Slash - 1);
    AddTo(FRepoBytes, Owner + #9 + Repo, Size);
    AddTo(FRepoFiles, Owner + #9 + Repo, 1);
    Inc(Files);
  end
  else if BestKind <> '' then
    Line(BestKind, Rel, Size)
  else if Under(Paths.AppDataPath, AbsPath, R) then
  begin
    Slash := Pos('/', R);
    if Slash > 0 then
      R := Copy(R, 1, Slash - 1);
    AddTo(FOtherBytes, R, Size);
    AddTo(FOtherFiles, R, 1);
    Inc(Files);
  end;
end;

procedure TIndexWriter.Finish;
var
  Key: string;
  N: Int64;
begin
  for Key in FRepoBytes.Keys do
  begin
    if not FRepoFiles.TryGetValue(Key, N) then
      N := 0;
    WriteLn(FOut, 'R'#9, Key, #9, FRepoBytes[Key], #9, N);
  end;
  for Key in FOtherBytes.Keys do
  begin
    if not FOtherFiles.TryGetValue(Key, N) then
      N := 0;
    WriteLn(FOut, 'O'#9, Key, #9, FOtherBytes[Key], #9, N);
  end;
  CloseFile(FOut);
  FOpen := False;
end;

// Every regular file under Dir (symbolic links are not followed).
procedure WalkDisk(W: TIndexWriter; const Dir: string; Depth: Integer);
var
  Names: TStringList;
  I: Integer;
  Full: string;
  Size: Int64;
begin
  if Depth > 64 then
    Exit;
  Names := GtListDir(Dir);
  try
    for I := 0 to Names.Count - 1 do
    begin
      Full := GtPath([Dir, Names[I]]);
      case GtKind(Full, Size) of
        gkDir: WalkDisk(W, Full, Depth + 1);
        gkFile: W.Classify(Full, Size);
      end;
    end;
  finally
    Names.Free;
  end;
end;

// `tree -s` output: "├── [       4096]  name", with "│   " or "    " per level
// (tree writes no-break spaces there). A directory is an entry followed by a
// deeper one, or, with -F, a name ending in '/'.
procedure WalkTree(W: TIndexWriter; const TreeFile: string);
var
  F: TextFile;
  Buf: array[0..65535] of Byte;
  Line, Prefix, Name, Rest: string;
  Stack: array of string;
  Depth, PrevDepth, I, Close_: Integer;
  Size, PrevSize: Int64;
  PrevPath: string;
  HavePrev, NoSlashes: Boolean;

  function ParseLine(const S: string; out D: Integer; out Sz: Int64; out N: string): Boolean;
  var
    P, Units_: Integer;
    C: string;
  begin
    Result := False;
    D := 0;
    P := 1;
    // Indentation units of 4 columns: "│" (3 bytes) or a space, then two
    // spaces or no-break spaces (2 bytes each), then a space.
    while True do
    begin
      if Copy(S, P, 3) = #$E2#$94#$82 then
        Inc(P, 3)
      else if Copy(S, P, 1) = ' ' then
        Inc(P, 1)
      else
        Break;
      Units_ := 0;
      while Units_ < 2 do
      begin
        if Copy(S, P, 2) = #$C2#$A0 then
          Inc(P, 2)
        else if Copy(S, P, 1) = ' ' then
          Inc(P, 1)
        else
          Exit;
        Inc(Units_);
      end;
      if Copy(S, P, 1) <> ' ' then
        Exit;
      Inc(P);
      Inc(D);
    end;
    C := Copy(S, P, 3);
    if (C <> #$E2#$94#$9C) and (C <> #$E2#$94#$94) then // ├ or └
      Exit;
    Inc(P, 3);
    if Copy(S, P, 6) <> #$E2#$94#$80#$E2#$94#$80 then // ──
      Exit;
    Inc(P, 6);
    if Copy(S, P, 2) <> ' [' then
      Exit;
    Inc(P, 2);
    C := Copy(S, P, MaxInt);
    I := Pos(']', C);
    if I = 0 then
      Exit;
    Sz := StrToInt64Def(Trim(Copy(C, 1, I - 1)), -1);
    if Sz < 0 then
      Exit;
    N := Copy(C, I + 1, MaxInt);
    if Copy(N, 1, 2) = '  ' then
      N := Copy(N, 3, MaxInt);
    Result := N <> '';
  end;

  // Without -F an empty directory looks like a file of its own size (4096 on
  // most file systems). Such a leaf is a directory unless its name is one of
  // the content files Gitea names by a UUID or a hash.
  function LooksLikeEmptyDir(const Path: string; Size: Int64): Boolean;
  var
    B: string;
    K: Integer;
  begin
    Result := False;
    if Size <> 4096 then
      Exit;
    B := ExtractFileName(Path);
    if Length(B) >= 32 then
    begin
      Result := True;
      for K := 1 to Length(B) do
        if not (B[K] in ['0'..'9', 'a'..'f', '-']) then
          Exit;
      Result := False;
      Exit;
    end;
    Result := True;
  end;

  procedure EmitPrev(IsDir: Boolean);
  begin
    if HavePrev and not IsDir and not (NoSlashes and LooksLikeEmptyDir(PrevPath, PrevSize)) then
      W.Classify(GtPath([W.Paths.WorkPath, PrevPath]), PrevSize);
  end;

begin
  AssignFile(F, TreeFile);
  SetTextBuf(F, Buf, SizeOf(Buf));
  Reset(F);
  try
    Stack := nil;
    HavePrev := False;
    // tree -F marks directories with '/'; then nothing needs guessing.
    NoSlashes := True;
    PrevDepth := 0;
    PrevSize := 0;
    PrevPath := '';
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      if not ParseLine(Line, Depth, Size, Name) then
        Continue;
      // The entry before this one was a directory when this one is deeper.
      EmitPrev(HavePrev and (Depth > PrevDepth));
      Close_ := 0;
      if (Length(Name) > 1) and (Name[Length(Name)] = '/') then
      begin
        Name := Copy(Name, 1, Length(Name) - 1);
        Close_ := 1;
        NoSlashes := False;
      end;
      // A symbolic link "name -> target" is not followed.
      Rest := '';
      I := Pos(' -> ', Name);
      if I > 0 then
      begin
        Rest := Name;
        Name := Copy(Name, 1, I - 1);
      end;
      SetLength(Stack, Depth + 1);
      Stack[Depth] := Name;
      Prefix := '';
      for I := 0 to Depth do
      begin
        if I > 0 then
          Prefix := Prefix + '/';
        Prefix := Prefix + Stack[I];
      end;
      PrevPath := Prefix;
      PrevSize := Size;
      PrevDepth := Depth;
      // A name ending in '/' (tree -F) is a directory; a link is not a file.
      HavePrev := (Close_ = 0) and (Rest = '');
    end;
    EmitPrev(False);
  finally
    CloseFile(F);
  end;
end;

function GtIndexPathFor(const IndexPath: string): string;
begin
  Result := IndexPath;
end;

function GtBuildIndex(const P: TGtPaths; const TreeFile, IndexPath: string;
  out Files: Int64; out ErrorText: string): Boolean;
var
  W: TIndexWriter;
  Tmp, Source: string;
  Names: TStringList;
  Full: string;
  Size: Int64;
  Roots: array[0..8] of string;
  I, K: Integer;
  Skip: Boolean;
begin
  Result := False;
  Files := 0;
  ErrorText := '';
  Tmp := IndexPath + '.tmp';
  W := TIndexWriter.Create;
  try
    W.Paths := P;
    if TreeFile <> '' then
      Source := 'tree:' + ExpandFileName(TreeFile)
    else
      Source := 'disk';
    if (TreeFile <> '') and not FileExists(TreeFile) then
    begin
      ErrorText := 'no such file: ' + TreeFile;
      Exit;
    end;
    if not W.Open(Tmp, Source, ErrorText) then
      Exit;
    try
      if TreeFile <> '' then
        WalkTree(W, TreeFile)
      else
      begin
        Roots[0] := P.RepoRoot;
        Roots[1] := P.Attachments;
        Roots[2] := P.Lfs;
        Roots[3] := P.Packages;
        Roots[4] := P.Avatars;
        Roots[5] := P.RepoAvatars;
        Roots[6] := P.ActionsLog;
        Roots[7] := P.ActionsArtifacts;
        Roots[8] := P.RepoArchive;
        for I := 0 to High(Roots) do
          WalkDisk(W, Roots[I], 0);
        // The rest of APP_DATA_PATH: its database, indexers, sessions...
        Names := GtListDir(P.AppDataPath);
        try
          for K := 0 to Names.Count - 1 do
          begin
            Full := GtPath([P.AppDataPath, Names[K]]);
            Skip := False;
            for I := 0 to High(Roots) do
              if (Roots[I] = Full) or GtUnder(Full, Roots[I]) then
                Skip := True;
            if Skip then
              Continue;
            case GtKind(Full, Size) of
              gkDir: WalkDisk(W, Full, 0);
              gkFile: W.Classify(Full, Size);
            end;
          end;
        finally
          Names.Free;
        end;
      end;
      W.Finish;
    except
      on E: Exception do
      begin
        ErrorText := E.Message;
        DeleteFile(Tmp);
        Exit;
      end;
    end;
    Files := W.Files;
  finally
    W.Free;
  end;
  if FileExists(IndexPath) then
    DeleteFile(IndexPath);
  if not RenameFile(Tmp, IndexPath) then
  begin
    ErrorText := 'could not write ' + IndexPath;
    Exit;
  end;
  Result := True;
end;

{ --- the report --------------------------------------------------------------- }

procedure GtFreeReport(var R: TGtReport);
begin
  FreeAndNil(R.Orphans);
  R.Repos := nil;
  R.Owners := nil;
end;

function GtUnixToText(const Value: string): string;
var
  N: Int64;
begin
  N := StrToInt64Def(Value, 0);
  if N <= 0 then
    Result := ''
  else
    Result := FormatDateTime('yyyy-mm-dd hh:nn', UnixToDateTime(N));
end;

function LooksLikeUuid(const S: string): Boolean;
var
  I: Integer;
begin
  Result := Length(S) = 36;
  if Result then
    for I := 1 to 36 do
      if I in [9, 14, 19, 24] then
      begin
        if S[I] <> '-' then
          Exit(False);
      end
      else if not (S[I] in ['0'..'9', 'a'..'f', 'A'..'F']) then
        Exit(False);
end;

function GtIndexAppIni(const IndexPath: string): string;
var
  F: TextFile;
  Line: string;
  N: Integer;
begin
  Result := '';
  if not FileExists(IndexPath) then
    Exit;
  AssignFile(F, IndexPath);
  try
    Reset(F);
  except
    Exit;
  end;
  try
    N := 0;
    while (not Eof(F)) and (N < 10) do
    begin
      ReadLn(F, Line);
      Inc(N);
      if Copy(Line, 1, 8) = '#appini'#9 then
      begin
        Result := Copy(Line, 9, MaxInt);
        Break;
      end;
    end;
  finally
    CloseFile(F);
  end;
end;

function GtLoadReport(const P: TGtPaths; const IndexPath: string;
  out R: TGtReport; out ErrorText: string): Boolean;
var
  F: TextFile;
  Buf: array[0..65535] of Byte;
  Line, Kind, Rel, Key, Base: string;
  Parts: TStringArray;
  Size, Files, V, OwnerId: Int64;
  RepoDisk, RepoFiles, AttDisk, LfsDisk, PkgDisk, AvatarDisk, RepoAvatarDisk: TGtSizeMap;
  AttPath: specialize TDictionary<string, string>;
  Rows: TGtRows;
  I, J, K: Integer;
  OwnerIndex: specialize TDictionary<Int64, Integer>;
  RepoIndex: specialize TDictionary<Int64, Integer>;
  KnownRepoDirs, LfsSeenOwner, LfsSeen, PkgSeenOwner: specialize TDictionary<string, Boolean>;
  LfsRepoOids: TStringList;
  E, Oid, Uuid, GitCol, LfsCol: string;
  Tol: Int64;

  procedure Orphan(const OKind, OPath: string; Bytes: Int64; const Reason: string);
  begin
    R.Orphans.Add(OKind + #9 + OPath + #9 + IntToStr(Bytes) + #9 + Reason);
    if Bytes > 0 then
      Inc(R.TotalOrphanBytes, Bytes);
  end;

  function Get(Map: TGtSizeMap; const AKey: string; out Value: Int64): Boolean;
  begin
    Result := Map.TryGetValue(AKey, Value);
    if not Result then
      Value := 0;
  end;

begin
  Result := False;
  ErrorText := '';
  R := Default(TGtReport);
  R.Orphans := TStringList.Create;
  if not FileExists(IndexPath) then
  begin
    ErrorText := 'no index yet';
    Exit;
  end;
  RepoDisk := TGtSizeMap.Create;
  RepoFiles := TGtSizeMap.Create;
  AttDisk := TGtSizeMap.Create;
  LfsDisk := TGtSizeMap.Create;
  PkgDisk := TGtSizeMap.Create;
  AvatarDisk := TGtSizeMap.Create;
  RepoAvatarDisk := TGtSizeMap.Create;
  AttPath := specialize TDictionary<string, string>.Create;
  OwnerIndex := specialize TDictionary<Int64, Integer>.Create;
  RepoIndex := specialize TDictionary<Int64, Integer>.Create;
  KnownRepoDirs := specialize TDictionary<string, Boolean>.Create;
  LfsSeenOwner := specialize TDictionary<string, Boolean>.Create;
  LfsSeen := specialize TDictionary<string, Boolean>.Create;
  PkgSeenOwner := specialize TDictionary<string, Boolean>.Create;
  LfsRepoOids := TStringList.Create;
  try
    // --- the index ---
    AssignFile(F, IndexPath);
    SetTextBuf(F, Buf, SizeOf(Buf));
    try
      Reset(F);
    except
      on Ex: Exception do
      begin
        ErrorText := Ex.Message;
        Exit;
      end;
    end;
    try
      if Eof(F) then
      begin
        ErrorText := 'empty index';
        Exit;
      end;
      ReadLn(F, Line);
      if Line <> INDEX_MAGIC then
      begin
        ErrorText := 'not an Omi Gitea index: ' + IndexPath;
        Exit;
      end;
      while not Eof(F) do
      begin
        ReadLn(F, Line);
        Parts := Line.Split([#9]);
        if Length(Parts) < 2 then
          Continue;
        Kind := Parts[0];
        if Kind = '#source' then
        begin
          R.IndexSource := Parts[1];
          Continue;
        end;
        if Kind = '#time' then
        begin
          R.IndexTime := Parts[1];
          Continue;
        end;
        if Kind = '#stale' then
        begin
          R.IndexStale := Parts[1];
          Continue;
        end;
        // An index measures ONE Gitea folder. Read against another folder's
        // database, every row and file would look orphaned (an index left by
        // `server gitea ... --config <another app.ini>` did exactly that), so
        // an index of another app.ini is not used: measure again.
        if (Kind = '#appini') and (Parts[1] <> P.AppIni) then
        begin
          ErrorText := 'the size index is of another Gitea folder (' + Parts[1] + '): measure again';
          Exit;
        end;
        if (Kind <> '') and (Kind[1] = '#') then
          Continue;
        if Kind = 'R' then
        begin
          if Length(Parts) < 5 then
            Continue;
          Key := LowerCase(Parts[1] + '/' + Parts[2]);
          Size := StrToInt64Def(Parts[3], 0);
          Files := StrToInt64Def(Parts[4], 0);
          AddTo(RepoDisk, Key, Size);
          AddTo(RepoFiles, Key, Files);
          if Copy(Parts[2], Length(Parts[2]) - 8, 9) = '.wiki.git' then
            Inc(R.TotalWiki, Size)
          else
            Inc(R.TotalGit, Size);
          Continue;
        end;
        if Length(Parts) < 3 then
          Continue;
        Rel := Parts[1];
        Size := StrToInt64Def(Parts[2], 0);
        Base := ExtractFileName(Rel);
        case Kind of
          'A':
            begin
              Inc(R.TotalAttachments, Size);
              // <uuid[0]>/<uuid[1]>/<uuid>
              if LooksLikeUuid(Base) and (LowerCase(Rel) = LowerCase(Base[1] + '/' + Base[2] + '/' + Base)) then
              begin
                AddTo(AttDisk, LowerCase(Base), Size);
                AttPath.AddOrSetValue(LowerCase(Base), Rel);
              end
              else
                Orphan('attachment-file', Rel, Size, 'not an attachment path');
            end;
          'L':
            begin
              Inc(R.TotalLfs, Size);
              Oid := LowerCase(StringReplace(Rel, '/', '', [rfReplaceAll]));
              if (Length(Oid) = 64) and (Length(Rel) = 66) then
                AddTo(LfsDisk, Oid, Size)
              else
                Orphan('lfs-file', Rel, Size, 'not an LFS object path');
            end;
          'P':
            begin
              Inc(R.TotalPackages, Size);
              AddTo(PkgDisk, LowerCase(Base), Size);
            end;
          'V':
            begin
              Inc(R.TotalAvatars, Size);
              AddTo(AvatarDisk, Rel, Size);
            end;
          'W':
            begin
              Inc(R.TotalRepoAvatars, Size);
              AddTo(RepoAvatarDisk, Rel, Size);
            end;
          'G': Inc(R.TotalActionsLog, Size);
          'F': Inc(R.TotalArtifacts, Size);
          'X': Inc(R.TotalArchives, Size);
          'O': Inc(R.TotalOther, Size);
        end;
      end;
    finally
      CloseFile(F);
    end;

    // --- owners ---
    if not GtQuery(P.DbPath, 'SELECT id, name, COALESCE(type, 0), COALESCE(avatar, '''') FROM user ' +
      'WHERE COALESCE(type, 0) IN (0, 1) ORDER BY lower_name', [], Rows, ErrorText) then
      Exit;
    SetLength(R.Owners, Length(Rows));
    for I := 0 to High(Rows) do
    begin
      R.Owners[I] := Default(TGtOwnerSize);
      R.Owners[I].Id := StrToInt64Def(Rows[I][0], 0);
      R.Owners[I].Name := Rows[I][1];
      R.Owners[I].Kind := StrToIntDef(Rows[I][2], 0);
      if (Rows[I][3] <> '') and Get(AvatarDisk, Rows[I][3], V) then
      begin
        R.Owners[I].Avatar := V;
        AvatarDisk.Remove(Rows[I][3]);
      end;
      OwnerIndex.AddOrSetValue(R.Owners[I].Id, I);
    end;

    // --- repositories ---
    GitCol := '0';
    LfsCol := '0';
    if GtHasColumn(P.DbPath, 'repository', 'git_size') then
      GitCol := 'COALESCE(git_size, 0)';
    if GtHasColumn(P.DbPath, 'repository', 'lfs_size') then
      LfsCol := 'COALESCE(lfs_size, 0)';
    if not GtQuery(P.DbPath, 'SELECT id, COALESCE(owner_id, 0), COALESCE(owner_name, ''''), lower_name, name, ' +
      'COALESCE(size, 0), ' + GitCol + ', ' + LfsCol + ', COALESCE(num_issues, 0), COALESCE(num_pulls, 0), ' +
      'COALESCE(avatar, '''') FROM repository ORDER BY lower(owner_name), lower_name', [], Rows, ErrorText) then
      Exit;
    SetLength(R.Repos, Length(Rows));
    for I := 0 to High(Rows) do
    begin
      R.Repos[I] := Default(TGtRepoSize);
      with R.Repos[I] do
      begin
        Id := StrToInt64Def(Rows[I][0], 0);
        OwnerId := StrToInt64Def(Rows[I][1], 0);
        Owner := Rows[I][2];
        LowerOwner := LowerCase(Owner);
        Name := Rows[I][4];
        LowerName := LowerCase(Rows[I][3]);
        DbSize := StrToInt64Def(Rows[I][5], 0);
        DbGit := StrToInt64Def(Rows[I][6], 0);
        DbLfs := StrToInt64Def(Rows[I][7], 0);
        Issues := StrToInt64Def(Rows[I][8], 0);
        Pulls := StrToInt64Def(Rows[I][9], 0);
        Key := LowerOwner + '/' + LowerName + '.git';
        HasDir := Get(RepoDisk, Key, DiskGit);
        Get(RepoFiles, Key, DiskFiles);
        KnownRepoDirs.AddOrSetValue(Key, True);
        Key := LowerOwner + '/' + LowerName + '.wiki.git';
        HasWiki := Get(RepoDisk, Key, DiskWiki);
        KnownRepoDirs.AddOrSetValue(Key, True);
        if (Rows[I][10] <> '') and Get(RepoAvatarDisk, Rows[I][10], V) then
          RepoAvatarDisk.Remove(Rows[I][10]);
      end;
      RepoIndex.AddOrSetValue(R.Repos[I].Id, I);
      if OwnerIndex.TryGetValue(R.Repos[I].OwnerId, J) then
        Inc(R.Owners[J].Repos)
      else
        Orphan('repository-row', R.Repos[I].Owner + '/' + R.Repos[I].Name, 0, 'its owner is not in the user table');
    end;
    // git directories without a repository row
    for Key in RepoDisk.Keys do
      if not KnownRepoDirs.ContainsKey(Key) then
        Orphan('git-directory', Key, RepoDisk[Key], 'no repository row');

    // --- attachments ---
    if not GtQuery(P.DbPath, 'SELECT lower(COALESCE(uuid, '''')), COALESCE(repo_id, 0), COALESCE(size, 0), ' +
      'COALESCE(name, '''') FROM attachment', [], Rows, ErrorText) then
      Exit;
    for I := 0 to High(Rows) do
    begin
      Uuid := Rows[I][0];
      Size := StrToInt64Def(Rows[I][2], 0);
      J := -1;
      if RepoIndex.TryGetValue(StrToInt64Def(Rows[I][1], 0), K) then
        J := K;
      if J >= 0 then
      begin
        Inc(R.Repos[J].AttRows);
        Inc(R.Repos[J].AttRowBytes, Size);
      end;
      if Get(AttDisk, Uuid, V) then
      begin
        if J >= 0 then
          Inc(R.Repos[J].AttDisk, V);
        if V <> Size then
          Orphan('attachment-size', AttPath[Uuid], V, 'the row says ' + IntToStr(Size) + ' bytes');
        AttDisk.Remove(Uuid);
      end
      else
      begin
        if J >= 0 then
          Inc(R.Repos[J].AttMissing);
        Orphan('attachment-row', Uuid, Size, 'no file (' + Rows[I][3] + ')');
      end;
    end;
    for Key in AttDisk.Keys do
      Orphan('attachment-file', AttPath[Key], AttDisk[Key], 'no attachment row');

    // --- LFS ---
    if not GtQuery(P.DbPath, 'SELECT lower(oid), COALESCE(size, 0), COALESCE(repository_id, 0) FROM lfs_meta_object',
      [], Rows, ErrorText) then
      Exit;
    for I := 0 to High(Rows) do
    begin
      Oid := Rows[I][0];
      Size := StrToInt64Def(Rows[I][1], 0);
      LfsSeen.AddOrSetValue(Oid, True);
      if not RepoIndex.TryGetValue(StrToInt64Def(Rows[I][2], 0), J) then
      begin
        Orphan('lfs-row', Oid, Size, 'its repository is not in the repository table');
        Continue;
      end;
      Inc(R.Repos[J].LfsRows);
      Inc(R.Repos[J].LfsRowBytes, Size);
      if Get(LfsDisk, Oid, V) then
      begin
        Inc(R.Repos[J].LfsDisk, V);
        // An owner's LFS objects count once, however many repositories have them.
        if OwnerIndex.TryGetValue(R.Repos[J].OwnerId, K) and
          not LfsSeenOwner.ContainsKey(IntToStr(R.Repos[J].OwnerId) + ':' + Oid) then
        begin
          LfsSeenOwner.Add(IntToStr(R.Repos[J].OwnerId) + ':' + Oid, True);
          Inc(R.Owners[K].Lfs, V);
        end;
      end
      else
      begin
        Inc(R.Repos[J].LfsMissing);
        Orphan('lfs-row', Oid, Size, 'no file (' + R.Repos[J].Owner + '/' + R.Repos[J].Name + ')');
      end;
    end;
    for Key in LfsDisk.Keys do
      if not LfsSeen.ContainsKey(Key) then
        Orphan('lfs-file', Copy(Key, 1, 2) + '/' + Copy(Key, 3, 2) + '/' + Copy(Key, 5, MaxInt),
          LfsDisk[Key], 'no lfs_meta_object row');

    // --- packages ---
    if GtQuery(P.DbPath, 'SELECT lower(pb.hash_sha256), COALESCE(pb.size, 0), COALESCE(p.owner_id, -1) ' +
      'FROM package_blob pb LEFT JOIN package_file pf ON pf.blob_id = pb.id ' +
      'LEFT JOIN package_version pv ON pv.id = pf.version_id LEFT JOIN package p ON p.id = pv.package_id',
      [], Rows, E) then
    begin
      LfsSeen.Clear;
      for I := 0 to High(Rows) do
      begin
        Oid := Rows[I][0];
        LfsSeen.AddOrSetValue(Oid, True);
        OwnerId := StrToInt64Def(Rows[I][2], -1);
        if Get(PkgDisk, Oid, V) then
        begin
          if OwnerIndex.TryGetValue(OwnerId, K) and
            not PkgSeenOwner.ContainsKey(IntToStr(OwnerId) + ':' + Oid) then
          begin
            PkgSeenOwner.Add(IntToStr(OwnerId) + ':' + Oid, True);
            Inc(R.Owners[K].Packages, V);
          end;
        end
        else if not PkgSeenOwner.ContainsKey('missing:' + Oid) then
        begin
          PkgSeenOwner.Add('missing:' + Oid, True);
          Orphan('package-row', Oid, StrToInt64Def(Rows[I][1], 0), 'no blob file');
        end;
      end;
      for Key in PkgDisk.Keys do
        if not LfsSeen.ContainsKey(Key) then
          Orphan('package-file', Copy(Key, 1, 2) + '/' + Copy(Key, 3, 2) + '/' + Key, PkgDisk[Key],
            'no package_blob row');
    end;

    for Key in AvatarDisk.Keys do
      Orphan('avatar-file', Key, AvatarDisk[Key], 'no user has this avatar');
    for Key in RepoAvatarDisk.Keys do
      Orphan('repo-avatar-file', Key, RepoAvatarDisk[Key], 'no repository has this avatar');

    // --- totals and mismatches ---
    for I := 0 to High(R.Repos) do
      with R.Repos[I] do
      begin
        Total := DiskGit + DiskWiki + LfsDisk + AttDisk;
        Mismatch := '';
        if not HasDir then
          Mismatch := Mismatch + 'no git directory; ';
        // Gitea measures git_size when the repository changes: a difference of
        // more than 1% and 64 KiB is worth a look.
        Tol := DbGit div 100;
        if Tol < 65536 then
          Tol := 65536;
        if HasDir and (Abs(DiskGit - DbGit) > Tol) then
          Mismatch := Mismatch + 'git_size ' + IntToStr(DbGit) + ' <> disk ' + IntToStr(DiskGit) + '; ';
        if LfsRowBytes <> DbLfs then
          Mismatch := Mismatch + 'lfs_size ' + IntToStr(DbLfs) + ' <> LFS rows ' + IntToStr(LfsRowBytes) + '; ';
        if DbSize <> DbGit + DbLfs then
          Mismatch := Mismatch + 'size ' + IntToStr(DbSize) + ' <> git_size + lfs_size; ';
        if LfsMissing > 0 then
          Mismatch := Mismatch + IntToStr(LfsMissing) + ' LFS files missing; ';
        if AttMissing > 0 then
          Mismatch := Mismatch + IntToStr(AttMissing) + ' attachment files missing; ';
        if AttRowBytes <> AttDisk + 0 then
          if AttMissing = 0 then
            Mismatch := Mismatch + 'attachment rows ' + IntToStr(AttRowBytes) + ' <> files ' + IntToStr(AttDisk) + '; ';
        if Mismatch <> '' then
          Mismatch := Copy(Mismatch, 1, Length(Mismatch) - 2);
        if OwnerIndex.TryGetValue(OwnerId, K) then
        begin
          Inc(R.Owners[K].Git, DiskGit);
          Inc(R.Owners[K].Wiki, DiskWiki);
          Inc(R.Owners[K].Attachments, AttDisk);
          Inc(R.Owners[K].DbSize, DbSize);
          if Mismatch <> '' then
            Inc(R.Owners[K].Mismatches);
        end;
      end;
    for I := 0 to High(R.Owners) do
      with R.Owners[I] do
        Total := Git + Wiki + Lfs + Attachments + Packages + Avatar;
    Result := True;
  finally
    RepoDisk.Free;
    RepoFiles.Free;
    AttDisk.Free;
    LfsDisk.Free;
    PkgDisk.Free;
    AvatarDisk.Free;
    RepoAvatarDisk.Free;
    AttPath.Free;
    OwnerIndex.Free;
    RepoIndex.Free;
    KnownRepoDirs.Free;
    LfsSeenOwner.Free;
    LfsSeen.Free;
    PkgSeenOwner.Free;
    LfsRepoOids.Free;
  end;
end;

function OwnerKey(const O: TGtOwnerSize; const Key: string): Int64;
begin
  if Key = 'git' then
    Result := O.Git + O.Wiki
  else if Key = 'lfs' then
    Result := O.Lfs
  else if Key = 'attachments' then
    Result := O.Attachments
  else if Key = 'packages' then
    Result := O.Packages
  else if Key = 'repos' then
    Result := O.Repos
  else if Key = 'db' then
    Result := O.DbSize
  else
    Result := O.Total;
end;

function OwnerLess(const A, B: TGtOwnerSize; const Key: string): Boolean;
var
  X, Y: Int64;
begin
  if Key = 'name' then
    Exit(LowerCase(A.Name) < LowerCase(B.Name));
  X := OwnerKey(A, Key);
  Y := OwnerKey(B, Key);
  if X <> Y then
    Result := X > Y
  else
    Result := LowerCase(A.Name) < LowerCase(B.Name);
end;

procedure GtSortOwners(var R: TGtReport; const Key: string);
var
  I, J: Integer;
  Tmp: TGtOwnerSize;
begin
  // Insertion sort: owners are few.
  for I := 1 to High(R.Owners) do
  begin
    Tmp := R.Owners[I];
    J := I - 1;
    while (J >= 0) and OwnerLess(Tmp, R.Owners[J], Key) do
    begin
      R.Owners[J + 1] := R.Owners[J];
      Dec(J);
    end;
    R.Owners[J + 1] := Tmp;
  end;
end;

function RepoKey(const A: TGtRepoSize; const Key: string): Int64;
begin
  if Key = 'git' then
    Result := A.DiskGit + A.DiskWiki
  else if Key = 'lfs' then
    Result := A.LfsDisk
  else if Key = 'attachments' then
    Result := A.AttDisk
  else if Key = 'db' then
    Result := A.DbSize
  else if Key = 'issues' then
    Result := A.Issues + A.Pulls
  else
    Result := A.Total;
end;

function RepoLess(const A, B: TGtRepoSize; const Key: string): Boolean;
var
  X, Y: Int64;
begin
  if Key = 'name' then
    Exit(LowerCase(A.Owner + '/' + A.Name) < LowerCase(B.Owner + '/' + B.Name));
  X := RepoKey(A, Key);
  Y := RepoKey(B, Key);
  if X <> Y then
    Result := X > Y
  else
    Result := LowerCase(A.Owner + '/' + A.Name) < LowerCase(B.Owner + '/' + B.Name);
end;

procedure GtSortRepos(var Repos: array of TGtRepoSize; const Key: string);

  procedure QSort(L, H: Integer);
  var
    I, J: Integer;
    Pivot, Tmp: TGtRepoSize;
  begin
    while L < H do
    begin
      Pivot := Repos[(L + H) div 2];
      I := L;
      J := H;
      repeat
        while RepoLess(Repos[I], Pivot, Key) do
          Inc(I);
        while RepoLess(Pivot, Repos[J], Key) do
          Dec(J);
        if I <= J then
        begin
          Tmp := Repos[I];
          Repos[I] := Repos[J];
          Repos[J] := Tmp;
          Inc(I);
          Dec(J);
        end;
      until I > J;
      if J - L < H - I then
      begin
        QSort(L, J);
        L := I;
      end
      else
      begin
        QSort(I, H);
        H := J;
      end;
    end;
  end;

begin
  if Length(Repos) > 1 then
    QSort(0, High(Repos));
end;

initialization
  InitCriticalSection(ExclusiveLock);
  if (StrToInt64Def(GetEnvironmentVariable('OMI_TEST_MAX_FILE'), 0) > 0) and
    (StrToInt64Def(GetEnvironmentVariable('OMI_TEST_MAX_FILE'), 0) < GtMaxFile) then
    GtMaxFile := StrToInt64Def(GetEnvironmentVariable('OMI_TEST_MAX_FILE'), 0);

finalization
  DoneCriticalSection(ExclusiveLock);

end.
