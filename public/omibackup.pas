{
  Omi - reading and editing github-to-gitea backups
  =================================================

  A backup of NAME (gitea-patches mirror/common/gitea_backup.py, FORMAT 1) is

    <backups dir>/<NAME>/<NAME>.db    SQLite: every record
    <backups dir>/<NAME>/<NAME>.zip   every file, STORED

  one per owner, updated in place by every backup run, or - written before
  github-to-gitea kept one per owner, until it combines them -

    <backups dir>/<NAME>/YYYY-MM-DD_HH-MM-SS/<NAME>.db and <NAME>.zip

  Every writer - github-to-gitea and Omi - holds <NAME>/.backup.lock and
  replaces whole files with the commit protocol of BkCommitFiles: <NAME>.db.tmp
  and <NAME>.zip.tmp, the marker <NAME>/.backup.commit, the renames, the marker
  removed. Omi's own in-place edits keep their append-and-journal scheme below.

  This unit is the part of Omi that touches those two files:

  - SQLite with prepared statements and bound parameters, so a value typed in
    the browser is never part of the SQL text. Reads open the .db read-only;
    writes open it read-write without SQLITE_OPEN_CREATE and run in one
    transaction.
  - A small zip reader and writer for STORED entries with ZIP64 records: the
    end of central directory (and the ZIP64 locator and record), the central
    directory, and each local header for the offset of an entry's bytes. Nothing
    is inflated; a compressed entry is listed but not shown or replaced.

  Replacing an entry APPENDS it: the new local header and bytes go after the end
  of the file, followed by a new central directory (pointing at the new copy,
  and at every other entry where it already was) and a new end record. The old
  bytes stay where they were, so nothing that was readable is ever overwritten.
  Before the first byte is appended, the zip's old length is written to
  <NAME>.zip.omi-save and synced; it is removed after the new end record is
  synced. If the save is interrupted, the next time Omi opens that zip it finds
  the journal, truncates the zip back to the old length - which is exactly the
  old, valid zip - and removes the journal. Other programs reading the zip in
  that window (before Omi has opened it again) see a zip without an end record
  at its end.
}

unit omibackup;

{$MODE OBJFPC}
{$H+}

interface

uses
  {$IFDEF UNIX}
  BaseUnix, Unix,
  {$ENDIF}
  SysUtils, Classes, crc, fpsha256;

const
  ZIP_JOURNAL_SUFFIX = '.omi-save';
  // Shared with github-to-gitea (gitea-patches mirror/common/gitea_backup.py),
  // in the OWNER's directory <BACKUPS_DIR>/<NAME>/ for both layouts.
  BACKUP_LOCK_NAME = '.backup.lock';
  BACKUP_COMMIT_NAME = '.backup.commit';

type
  TSqlRow = array of string;
  TSqlRows = array of TSqlRow;

  TSqlStatement = record
    Sql: string;
    Params: array of string;
  end;
  TSqlStatements = array of TSqlStatement;

  TZipEntry = record
    Name: RawByteString;
    VersionMade, VersionNeeded, Flags, Method, ModTime, ModDate: Word;
    Crc: Cardinal;
    CompSize, Size, LocalOffset: Int64;
    DiskStart: Cardinal;
    IntAttr: Word;
    ExtAttr: Cardinal;
    // Extra fields of the central record WITHOUT the ZIP64 block (0x0001),
    // which the writer rebuilds from the sizes and the offset.
    Extra: RawByteString;
    Comment: RawByteString;
  end;
  TZipEntries = array of TZipEntry;

  TZipDirectory = record
    Entries: TZipEntries;
    CdOffset, CdSize: Int64;
    HasZip64: Boolean;
    Comment: RawByteString;
  end;

  // A read-only window [Start, Start + Len) of a file: a zip entry's bytes,
  // streamed to the browser without reading them into memory.
  TFileWindowStream = class(TStream)
  private
    FFile: TFileStream;
    FStart, FLen, FPos: Int64;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(const FileName: string; AStart, ALen: Int64);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

function SqlStmt(const Sql: string; const Params: array of string): TSqlStatement;
// SELECT with bound text parameters, on a read-only connection.
function BkSqlQuery(const DbPath, Sql: string; const Params: array of string;
  out Rows: TSqlRows; out ErrorText: string): Boolean;
// Statements in ONE transaction on a read-write connection that cannot create
// the file. Changes is the sum of rows changed.
function BkSqlExecAll(const DbPath: string; const Statements: TSqlStatements;
  out Changes: Integer; out ErrorText: string): Boolean;

// A zip entry name Omi accepts: relative, '/'-separated, no '..' or '.'
// segment, no empty segment, no backslash, no NUL or other control character.
function ZipEntryNameIsSafe(const Name: string): Boolean;
function ZipReadDirectory(const ZipPath: string; out Dir: TZipDirectory;
  out ErrorText: string): Boolean;
function ZipFindEntry(const Dir: TZipDirectory; const Name: string): Integer;
function ZipEntryDataOffset(const ZipPath: string; const Entry: TZipEntry;
  out Offset: Int64; out ErrorText: string): Boolean;
// The first MaxBytes (or all, when smaller) of a STORED entry.
function ZipReadEntryBytes(const ZipPath: string; const Entry: TZipEntry;
  MaxBytes: Int64; out Data: RawByteString; out ErrorText: string): Boolean;
function ZipOpenEntryStream(const ZipPath: string; const Entry: TZipEntry;
  out Stream: TStream; out ErrorText: string): Boolean;
// Appends Data as the new content of entry Name (see the unit header).
function ZipReplaceEntry(const ZipPath, Name: string; const Data: RawByteString;
  out ErrorText: string): Boolean;

// Writes every entry of ZipPath except those named in Drop (a sorted list)
// into TmpPath: a new STORED zip with ZIP64 local extras, its own central
// directory and end records, synced. The dropped entries' bytes are not
// copied, so they are freed when TmpPath replaces ZipPath.
function ZipRewriteWithout(const ZipPath, TmpPath: string; Drop: TStringList;
  out DroppedCount: Integer; out DroppedBytes: Int64; out ErrorText: string): Boolean;

// The backup lock, <owner dir>/.backup.lock: created with O_CREAT|O_EXCL,
// one line "<pid> <hostname> omi <UTC ISO time>". A lock of this host whose
// process is gone is stale and taken over once. Holder is the line of the
// program that holds it, when it is held. Content is what Omi wrote, for
// BkLockRelease, which removes the file only while it is still Omi's.
function BkLockAcquire(const OwnerDir: string; out Content, Holder,
  ErrorText: string): Boolean;
procedure BkLockRelease(const OwnerDir, Content: string);
// With the lock held: finishes a commit that broke off after its marker was
// written, or removes what a writer that broke off earlier left.
procedure BkRecoverCommit(const OwnerDir, Name: string);
// The commit: <NAME>/.backup.commit, then zip.tmp -> zip and db.tmp -> db
// (each when that .tmp exists), then the marker removed.
function BkCommitFiles(const OwnerDir, Name: string; out ErrorText: string): Boolean;
function BkCopyFile(const Src, Dst: string; out ErrorText: string): Boolean;
procedure BkSyncFile(const Path: string);
function BkUtcIsoNow: string;

function Sha256Hex(const Data: RawByteString): string;
function IsValidUtf8(const Data: RawByteString): Boolean;
// gitea_backup.safe_part: one folder or file name, never a path.
function BkSafePart(const Text: string): string;

implementation

const
  // The prefix of C symbols ('_' on the Amiga), as omigitea's GT_C.
  {$IFDEF HASAMIGA}
  GT_C = '_';
  {$ELSE}
  GT_C = '';
  {$ENDIF}

const
  SQLITE_OK = 0;
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;
  SQLITE_OPEN_READONLY = $00000001;
  SQLITE_OPEN_READWRITE = $00000002;

  SIG_LOCAL = $04034b50;
  SIG_CENTRAL = $02014b50;
  SIG_EOCD = $06054b50;
  SIG_ZIP64_EOCD = $06064b50;
  SIG_ZIP64_LOCATOR = $07064b50;
  MAX_CD_SIZE = 512 * 1024 * 1024;

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
function sqlite3_changes(Db: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_changes';

var
  ZipLock: TRTLCriticalSection;
  // Omi's own writers, one at a time; the lock file keeps the other programs out.
  WriteLock: TRTLCriticalSection;

procedure SyncHandle(Handle: THandle);
begin
  {$IFDEF UNIX}
  fpfsync(Handle);
  {$ENDIF}
end;

{ --- SQLite ------------------------------------------------------------------ }

function SqlStmt(const Sql: string; const Params: array of string): TSqlStatement;
var
  I: Integer;
begin
  Result.Sql := Sql;
  SetLength(Result.Params, Length(Params));
  for I := 0 to High(Params) do
    Result.Params[I] := Params[I];
end;

function OpenDb(const DbPath: string; Flags: Integer; out Db: Pointer;
  out ErrorText: string): Boolean;
begin
  Db := nil;
  ErrorText := '';
  if not FileExists(DbPath) then
  begin
    ErrorText := 'no such database';
    Exit(False);
  end;
  Result := sqlite3_open_v2(PChar(DbPath), Db, Flags, nil) = SQLITE_OK;
  if not Result then
  begin
    if Assigned(Db) then
    begin
      ErrorText := StrPas(sqlite3_errmsg(Db));
      sqlite3_close(Db);
      Db := nil;
    end
    else
      ErrorText := 'SQLite could not open the database';
    Exit;
  end;
  sqlite3_busy_timeout(Db, 5000);
end;

// Prepares Sql with Params bound as text (?1, ?2 ... or plain ?).
function PrepareBound(Db: Pointer; const Sql: string; const Params: array of string;
  out Stmt: Pointer; out ErrorText: string): Boolean;
var
  I: Integer;
begin
  Stmt := nil;
  ErrorText := '';
  if sqlite3_prepare_v2(Db, PChar(Sql), -1, Stmt, nil) <> SQLITE_OK then
  begin
    ErrorText := StrPas(sqlite3_errmsg(Db));
    Exit(False);
  end;
  for I := 0 to High(Params) do
    // SQLITE_TRANSIENT (-1): SQLite copies the value now.
    if sqlite3_bind_text(Stmt, I + 1, PChar(Params[I]), Length(Params[I]),
      Pointer(-1)) <> SQLITE_OK then
    begin
      ErrorText := StrPas(sqlite3_errmsg(Db));
      sqlite3_finalize(Stmt);
      Stmt := nil;
      Exit(False);
    end;
  Result := True;
end;

function BkSqlQuery(const DbPath, Sql: string; const Params: array of string;
  out Rows: TSqlRows; out ErrorText: string): Boolean;
var
  Db, Stmt: Pointer;
  Rc, Cols, I, N: Integer;
  P: PChar;
  Row: TSqlRow;
  Value: string;
begin
  Rows := nil;
  Result := False;
  if not OpenDb(DbPath, SQLITE_OPEN_READONLY, Db, ErrorText) then
    Exit;
  try
    if not PrepareBound(Db, Sql, Params, Stmt, ErrorText) then
      Exit;
    try
      Cols := sqlite3_column_count(Stmt);
      repeat
        Rc := sqlite3_step(Stmt);
        if Rc = SQLITE_ROW then
        begin
          Row := nil;
          SetLength(Row, Cols);
          for I := 0 to Cols - 1 do
          begin
            P := sqlite3_column_text(Stmt, I);
            N := sqlite3_column_bytes(Stmt, I);
            Value := '';
            if Assigned(P) and (N > 0) then
              SetString(Value, P, N);
            Row[I] := Value;
          end;
          N := Length(Rows);
          SetLength(Rows, N + 1);
          Rows[N] := Row;
        end;
      until Rc <> SQLITE_ROW;
      if Rc <> SQLITE_DONE then
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

function ExecPlain(Db: Pointer; const Sql: string; out ErrorText: string): Boolean;
var
  Stmt: Pointer;
begin
  Result := PrepareBound(Db, Sql, [], Stmt, ErrorText);
  if not Result then
    Exit;
  Result := sqlite3_step(Stmt) = SQLITE_DONE;
  if not Result then
    ErrorText := StrPas(sqlite3_errmsg(Db));
  sqlite3_finalize(Stmt);
end;

function BkSqlExecAll(const DbPath: string; const Statements: TSqlStatements;
  out Changes: Integer; out ErrorText: string): Boolean;
var
  Db, Stmt: Pointer;
  I: Integer;
  Ignored: string;
begin
  Changes := 0;
  Result := False;
  if not OpenDb(DbPath, SQLITE_OPEN_READWRITE, Db, ErrorText) then
    Exit;
  try
    if not ExecPlain(Db, 'BEGIN IMMEDIATE', ErrorText) then
      Exit;
    for I := 0 to High(Statements) do
    begin
      if not PrepareBound(Db, Statements[I].Sql, Statements[I].Params, Stmt, ErrorText) then
      begin
        ExecPlain(Db, 'ROLLBACK', Ignored);
        Exit;
      end;
      if sqlite3_step(Stmt) <> SQLITE_DONE then
      begin
        ErrorText := StrPas(sqlite3_errmsg(Db));
        sqlite3_finalize(Stmt);
        ExecPlain(Db, 'ROLLBACK', Ignored);
        Exit;
      end;
      Inc(Changes, sqlite3_changes(Db));
      sqlite3_finalize(Stmt);
    end;
    if not ExecPlain(Db, 'COMMIT', ErrorText) then
    begin
      ExecPlain(Db, 'ROLLBACK', Ignored);
      Exit;
    end;
    Result := True;
  finally
    sqlite3_close(Db);
  end;
end;

{ --- little-endian helpers --------------------------------------------------- }

function LE16(const S: RawByteString; I: SizeInt): Word; inline;
begin
  Result := Ord(S[I]) or (Word(Ord(S[I + 1])) shl 8);
end;

function LE32(const S: RawByteString; I: SizeInt): Cardinal; inline;
begin
  Result := Cardinal(Ord(S[I])) or (Cardinal(Ord(S[I + 1])) shl 8) or
    (Cardinal(Ord(S[I + 2])) shl 16) or (Cardinal(Ord(S[I + 3])) shl 24);
end;

function LE64(const S: RawByteString; I: SizeInt): Int64; inline;
begin
  Result := Int64(QWord(LE32(S, I)) or (QWord(LE32(S, I + 4)) shl 32));
end;

procedure Put16(var S: RawByteString; V: Word);
begin
  S := S + AnsiChar(V and $FF) + AnsiChar((V shr 8) and $FF);
end;

procedure Put32(var S: RawByteString; V: Cardinal);
begin
  S := S + AnsiChar(V and $FF) + AnsiChar((V shr 8) and $FF) +
    AnsiChar((V shr 16) and $FF) + AnsiChar((V shr 24) and $FF);
end;

procedure Put64(var S: RawByteString; V: Int64);
begin
  Put32(S, Cardinal(QWord(V) and $FFFFFFFF));
  Put32(S, Cardinal(QWord(V) shr 32));
end;

function ReadAt(Stream: TStream; Offset: Int64; Count: SizeInt;
  out Data: RawByteString): Boolean;
begin
  Data := '';
  Result := False;
  if (Offset < 0) or (Count < 0) or (Offset + Count > Stream.Size) then
    Exit;
  SetLength(Data, Count);
  SetCodePage(Data, CP_UTF8, False);
  if Count = 0 then
    Exit(True);
  Stream.Position := Offset;
  Stream.ReadBuffer(Data[1], Count);
  Result := True;
end;

{ --- zip -------------------------------------------------------------------- }

function ZipEntryNameIsSafe(const Name: string): Boolean;
var
  Parts: TStringArray;
  I: Integer;
begin
  Result := False;
  if (Name = '') or (Length(Name) > 4096) then
    Exit;
  for I := 1 to Length(Name) do
    if (Ord(Name[I]) < 32) or (Ord(Name[I]) = 127) or (Name[I] = '\') then
      Exit;
  if (Name[1] = '/') or (Pos(':', Name) > 0) then
    Exit;
  Parts := Name.Split(['/']);
  for I := 0 to High(Parts) do
    if (Parts[I] = '') or (Parts[I] = '.') or (Parts[I] = '..') then
      Exit;
  Result := True;
end;

procedure RecoverJournal(const ZipPath: string);
var
  JournalPath, JournalText: string;
  OldLength: Int64;
  Stream: TFileStream;
begin
  JournalPath := ZipPath + ZIP_JOURNAL_SUFFIX;
  if not FileExists(JournalPath) then
    Exit;
  try
    with TStringList.Create do
    try
      LoadFromFile(JournalPath);
      JournalText := Trim(Text);
    finally
      Free;
    end;
    OldLength := StrToInt64Def(JournalText, -1);
    if OldLength > 0 then
    begin
      Stream := TFileStream.Create(ZipPath, fmOpenReadWrite or fmShareDenyNone);
      try
        if OldLength <= Stream.Size then
        begin
          Stream.Size := OldLength;
          SyncHandle(Stream.Handle);
        end;
      finally
        Stream.Free;
      end;
    end;
    DeleteFile(JournalPath);
  except
    // Without write access the zip stays as it is; reading it then reports
    // the missing end record.
  end;
end;

function ParseDirectory(Stream: TStream; out Dir: TZipDirectory;
  out ErrorText: string): Boolean;
var
  FileSize, TailStart, EocdPos, Z64Pos, Total, I64: Int64;
  TailLen, I, P, NameLen, ExtraLen, CommentLen, BlockLen, Q: SizeInt;
  Tail, Cd, Raw, Loc, Rec: RawByteString;
  Found: Boolean;
  BlockId: Word;
  E: TZipEntry;
  Count: Int64;
begin
  Result := False;
  ErrorText := '';
  Dir.Entries := nil;
  Dir.HasZip64 := False;
  Dir.Comment := '';
  FileSize := Stream.Size;
  if FileSize < 22 then
  begin
    ErrorText := 'not a zip file (too short)';
    Exit;
  end;
  TailLen := 65557;
  if FileSize < TailLen then
    TailLen := FileSize;
  TailStart := FileSize - TailLen;
  ReadAt(Stream, TailStart, TailLen, Tail);
  Found := False;
  I := TailLen - 21;
  while I >= 1 do
  begin
    if (Tail[I] = 'P') and (LE32(Tail, I) = SIG_EOCD) then
    begin
      CommentLen := LE16(Tail, I + 20);
      if I + 21 + CommentLen <= TailLen then
      begin
        Found := True;
        Break;
      end;
    end;
    Dec(I);
  end;
  if not Found then
  begin
    ErrorText := 'no end of central directory record';
    Exit;
  end;
  EocdPos := TailStart + I - 1;
  Dir.Comment := Copy(Tail, I + 22, CommentLen);
  Total := LE16(Tail, I + 10);
  Dir.CdSize := LE32(Tail, I + 12);
  Dir.CdOffset := LE32(Tail, I + 16);
  if (LE16(Tail, I + 4) <> 0) and (LE16(Tail, I + 4) <> $FFFF) then
  begin
    ErrorText := 'multi-disk zip files are not supported';
    Exit;
  end;

  if (EocdPos >= 20) and ReadAt(Stream, EocdPos - 20, 20, Loc) and
    (LE32(Loc, 1) = SIG_ZIP64_LOCATOR) then
  begin
    Z64Pos := LE64(Loc, 9);
    if not ReadAt(Stream, Z64Pos, 56, Rec) or (LE32(Rec, 1) <> SIG_ZIP64_EOCD) then
    begin
      ErrorText := 'bad ZIP64 end of central directory record';
      Exit;
    end;
    Dir.HasZip64 := True;
    Total := LE64(Rec, 33);
    Dir.CdSize := LE64(Rec, 41);
    Dir.CdOffset := LE64(Rec, 49);
    EocdPos := Z64Pos;
  end
  else if (Total = $FFFF) or (Dir.CdSize = $FFFFFFFF) or (Dir.CdOffset = $FFFFFFFF) then
  begin
    ErrorText := 'ZIP64 locator missing';
    Exit;
  end;

  if (Dir.CdOffset < 0) or (Dir.CdSize < 0) or (Dir.CdSize > MAX_CD_SIZE) or
    (Dir.CdOffset + Dir.CdSize > EocdPos) or (Total < 0) or
    (Total * 46 > Dir.CdSize) then
  begin
    ErrorText := 'central directory out of range';
    Exit;
  end;
  if not ReadAt(Stream, Dir.CdOffset, Dir.CdSize, Cd) then
  begin
    ErrorText := 'cannot read the central directory';
    Exit;
  end;

  SetLength(Dir.Entries, Total);
  P := 1;
  Count := 0;
  while Count < Total do
  begin
    if (P + 45 > Length(Cd)) or (LE32(Cd, P) <> SIG_CENTRAL) then
    begin
      ErrorText := 'bad central directory entry';
      Exit;
    end;
    E := Default(TZipEntry);
    E.VersionMade := LE16(Cd, P + 4);
    E.VersionNeeded := LE16(Cd, P + 6);
    E.Flags := LE16(Cd, P + 8);
    E.Method := LE16(Cd, P + 10);
    E.ModTime := LE16(Cd, P + 12);
    E.ModDate := LE16(Cd, P + 14);
    E.Crc := LE32(Cd, P + 16);
    E.CompSize := LE32(Cd, P + 20);
    E.Size := LE32(Cd, P + 24);
    NameLen := LE16(Cd, P + 28);
    ExtraLen := LE16(Cd, P + 30);
    CommentLen := LE16(Cd, P + 32);
    E.DiskStart := LE16(Cd, P + 34);
    E.IntAttr := LE16(Cd, P + 36);
    E.ExtAttr := LE32(Cd, P + 38);
    E.LocalOffset := LE32(Cd, P + 42);
    if P + 46 + NameLen + ExtraLen + CommentLen - 1 > Length(Cd) then
    begin
      ErrorText := 'central directory entry out of range';
      Exit;
    end;
    E.Name := Copy(Cd, P + 46, NameLen);
    Raw := Copy(Cd, P + 46 + NameLen, ExtraLen);
    E.Comment := Copy(Cd, P + 46 + NameLen + ExtraLen, CommentLen);
    Q := 1;
    while Q + 3 <= Length(Raw) do
    begin
      BlockId := LE16(Raw, Q);
      BlockLen := LE16(Raw, Q + 2);
      if Q + 3 + BlockLen > Length(Raw) then
        Break;
      if BlockId = 1 then
      begin
        I64 := Q + 4;
        if (E.Size = $FFFFFFFF) and (I64 + 7 < Q + 4 + BlockLen) then
        begin
          E.Size := LE64(Raw, I64);
          Inc(I64, 8);
        end;
        if (E.CompSize = $FFFFFFFF) and (I64 + 7 < Q + 4 + BlockLen) then
        begin
          E.CompSize := LE64(Raw, I64);
          Inc(I64, 8);
        end;
        if (E.LocalOffset = $FFFFFFFF) and (I64 + 7 < Q + 4 + BlockLen) then
        begin
          E.LocalOffset := LE64(Raw, I64);
          Inc(I64, 8);
        end;
        if (E.DiskStart = $FFFF) and (I64 + 3 < Q + 4 + BlockLen) then
          E.DiskStart := LE32(Raw, I64);
      end
      else
        E.Extra := E.Extra + Copy(Raw, Q, 4 + BlockLen);
      Q := Q + 4 + BlockLen;
    end;
    if (E.Size < 0) or (E.CompSize < 0) or (E.LocalOffset < 0) or
      (E.LocalOffset >= FileSize) or (E.DiskStart <> 0) then
    begin
      ErrorText := 'central directory entry has a bad size or offset';
      Exit;
    end;
    Dir.Entries[Count] := E;
    Inc(Count);
    P := P + 46 + NameLen + ExtraLen + CommentLen;
  end;
  Result := True;
end;

function ReadDirectoryUnlocked(const ZipPath: string; out Dir: TZipDirectory;
  out ErrorText: string): Boolean;
var
  Stream: TFileStream;
begin
  Result := False;
  Dir := Default(TZipDirectory);
  if not FileExists(ZipPath) then
  begin
    ErrorText := 'no such zip file';
    Exit;
  end;
  try
    Stream := TFileStream.Create(ZipPath, fmOpenRead or fmShareDenyNone);
    try
      Result := ParseDirectory(Stream, Dir, ErrorText);
    finally
      Stream.Free;
    end;
  except
    on Ex: Exception do
    begin
      ErrorText := Ex.Message;
      Result := False;
    end;
  end;
end;

function ZipReadDirectory(const ZipPath: string; out Dir: TZipDirectory;
  out ErrorText: string): Boolean;
begin
  EnterCriticalSection(ZipLock);
  try
    RecoverJournal(ZipPath);
    Result := ReadDirectoryUnlocked(ZipPath, Dir, ErrorText);
  finally
    LeaveCriticalSection(ZipLock);
  end;
end;

function ZipFindEntry(const Dir: TZipDirectory; const Name: string): Integer;
var
  I: Integer;
begin
  for I := High(Dir.Entries) downto 0 do
    if Dir.Entries[I].Name = Name then
      Exit(I);
  Result := -1;
end;

function ZipEntryDataOffset(const ZipPath: string; const Entry: TZipEntry;
  out Offset: Int64; out ErrorText: string): Boolean;
var
  Stream: TFileStream;
  Head: RawByteString;
begin
  Result := False;
  Offset := -1;
  ErrorText := '';
  try
    Stream := TFileStream.Create(ZipPath, fmOpenRead or fmShareDenyNone);
    try
      if not ReadAt(Stream, Entry.LocalOffset, 30, Head) or (LE32(Head, 1) <> SIG_LOCAL) then
      begin
        ErrorText := 'bad local file header';
        Exit;
      end;
      Offset := Entry.LocalOffset + 30 + LE16(Head, 27) + LE16(Head, 29);
      if Offset + Entry.CompSize > Stream.Size then
      begin
        ErrorText := 'entry data out of range';
        Exit;
      end;
      Result := True;
    finally
      Stream.Free;
    end;
  except
    on Ex: Exception do
      ErrorText := Ex.Message;
  end;
end;

function CheckStored(const Entry: TZipEntry; out ErrorText: string): Boolean;
begin
  ErrorText := '';
  Result := (Entry.Method = 0) and ((Entry.Flags and 1) = 0) and
    (Entry.CompSize = Entry.Size);
  if not Result then
    ErrorText := 'the entry is compressed or encrypted; only STORED entries are read';
end;

function ZipReadEntryBytes(const ZipPath: string; const Entry: TZipEntry;
  MaxBytes: Int64; out Data: RawByteString; out ErrorText: string): Boolean;
var
  Offset, Count: Int64;
  Stream: TFileStream;
begin
  Data := '';
  Result := False;
  if not CheckStored(Entry, ErrorText) then
    Exit;
  if not ZipEntryDataOffset(ZipPath, Entry, Offset, ErrorText) then
    Exit;
  Count := Entry.Size;
  if (MaxBytes >= 0) and (Count > MaxBytes) then
    Count := MaxBytes;
  try
    Stream := TFileStream.Create(ZipPath, fmOpenRead or fmShareDenyNone);
    try
      Result := ReadAt(Stream, Offset, Count, Data);
      if not Result then
        ErrorText := 'cannot read the entry';
    finally
      Stream.Free;
    end;
  except
    on Ex: Exception do
      ErrorText := Ex.Message;
  end;
end;

function ZipOpenEntryStream(const ZipPath: string; const Entry: TZipEntry;
  out Stream: TStream; out ErrorText: string): Boolean;
var
  Offset: Int64;
begin
  Stream := nil;
  Result := False;
  if not CheckStored(Entry, ErrorText) then
    Exit;
  if not ZipEntryDataOffset(ZipPath, Entry, Offset, ErrorText) then
    Exit;
  try
    Stream := TFileWindowStream.Create(ZipPath, Offset, Entry.Size);
    Result := True;
  except
    on Ex: Exception do
      ErrorText := Ex.Message;
  end;
end;

procedure DosDateTimeNow(out DosTime, DosDate: Word);
var
  Y, Mo, D, H, Mi, S, Ms: Word;
begin
  DecodeDate(Now, Y, Mo, D);
  DecodeTime(Now, H, Mi, S, Ms);
  if Y < 1980 then
    Y := 1980;
  DosTime := (H shl 11) or (Mi shl 5) or (S div 2);
  DosDate := ((Y - 1980) shl 9) or (Mo shl 5) or D;
end;

function CentralRecord(const E: TZipEntry): RawByteString;
var
  Z64: RawByteString;
  NeedSize, NeedComp, NeedOffset: Boolean;
  Needed: Word;
begin
  NeedSize := E.Size >= $FFFFFFFF;
  NeedComp := E.CompSize >= $FFFFFFFF;
  NeedOffset := E.LocalOffset >= $FFFFFFFF;
  Z64 := '';
  if NeedSize then
    Put64(Z64, E.Size);
  if NeedComp then
    Put64(Z64, E.CompSize);
  if NeedOffset then
    Put64(Z64, E.LocalOffset);
  if Z64 <> '' then
  begin
    Z64 := #1#0 + AnsiChar(Length(Z64)) + #0 + Z64;
    Needed := 45;
  end
  else
    Needed := E.VersionNeeded;
  if Needed < E.VersionNeeded then
    Needed := E.VersionNeeded;
  Result := '';
  Put32(Result, SIG_CENTRAL);
  Put16(Result, E.VersionMade);
  Put16(Result, Needed);
  Put16(Result, E.Flags);
  Put16(Result, E.Method);
  Put16(Result, E.ModTime);
  Put16(Result, E.ModDate);
  Put32(Result, E.Crc);
  if NeedComp then Put32(Result, $FFFFFFFF) else Put32(Result, Cardinal(E.CompSize));
  if NeedSize then Put32(Result, $FFFFFFFF) else Put32(Result, Cardinal(E.Size));
  Put16(Result, Length(E.Name));
  Put16(Result, Length(Z64) + Length(E.Extra));
  Put16(Result, Length(E.Comment));
  Put16(Result, 0);
  Put16(Result, E.IntAttr);
  Put32(Result, E.ExtAttr);
  if NeedOffset then Put32(Result, $FFFFFFFF) else Put32(Result, Cardinal(E.LocalOffset));
  Result := Result + E.Name + Z64 + E.Extra + E.Comment;
end;

procedure WriteRaw(Stream: TStream; const S: RawByteString);
begin
  if S <> '' then
    Stream.WriteBuffer(S[1], Length(S));
end;

// The end of a zip: a ZIP64 end record and locator when the zip had them or
// needs them (65535 entries or more, or offsets of 4 GiB or more), then the end
// of central directory record with the zip's comment.
function EndRecords(Count, CdStart, CdSize: Int64; HadZip64: Boolean;
  const Comment: RawByteString): RawByteString;
var
  UseZip64: Boolean;
begin
  UseZip64 := HadZip64 or (Count >= $FFFF) or (CdSize >= $FFFFFFFF) or (CdStart >= $FFFFFFFF);
  Result := '';
  if UseZip64 then
  begin
    Put32(Result, SIG_ZIP64_EOCD);
    Put64(Result, 44);
    Put16(Result, 45);
    Put16(Result, 45);
    Put32(Result, 0);
    Put32(Result, 0);
    Put64(Result, Count);
    Put64(Result, Count);
    Put64(Result, CdSize);
    Put64(Result, CdStart);
    Put32(Result, SIG_ZIP64_LOCATOR);
    Put32(Result, 0);
    Put64(Result, CdStart + CdSize);
    Put32(Result, 1);
  end;
  Put32(Result, SIG_EOCD);
  Put16(Result, 0);
  Put16(Result, 0);
  if UseZip64 and (Count >= $FFFF) then
  begin
    Put16(Result, $FFFF);
    Put16(Result, $FFFF);
  end
  else
  begin
    Put16(Result, Word(Count));
    Put16(Result, Word(Count));
  end;
  if CdSize >= $FFFFFFFF then Put32(Result, $FFFFFFFF) else Put32(Result, Cardinal(CdSize));
  if CdStart >= $FFFFFFFF then Put32(Result, $FFFFFFFF) else Put32(Result, Cardinal(CdStart));
  Put16(Result, Length(Comment));
  Result := Result + Comment;
end;

// A local header as gitea_backup writes one (force_zip64): version 45, the
// sizes in a ZIP64 extra.
function LocalHeader(const E: TZipEntry): RawByteString;
begin
  Result := '';
  Put32(Result, SIG_LOCAL);
  Put16(Result, 45);
  Put16(Result, E.Flags);
  Put16(Result, E.Method);
  Put16(Result, E.ModTime);
  Put16(Result, E.ModDate);
  Put32(Result, E.Crc);
  Put32(Result, $FFFFFFFF);
  Put32(Result, $FFFFFFFF);
  Put16(Result, Length(E.Name));
  Put16(Result, 20);
  Result := Result + E.Name + #1#0#16#0;
  Put64(Result, E.Size);
  Put64(Result, E.CompSize);
end;

function ZipReplaceEntry(const ZipPath, Name: string; const Data: RawByteString;
  out ErrorText: string): Boolean;
var
  Dir: TZipDirectory;
  Idx, I: Integer;
  E: TZipEntry;
  Stream: TFileStream;
  OldLength, NewOffset, CdStart, CdSize: Int64;
  Header, Cd, Tail: RawByteString;
  JournalPath: string;
  Journal: TFileStream;
  JournalText: RawByteString;
  CrcValue: Cardinal;
  DosTime, DosDate: Word;
begin
  Result := False;
  ErrorText := '';
  if not ZipEntryNameIsSafe(Name) then
  begin
    ErrorText := 'unsafe entry name';
    Exit;
  end;
  EnterCriticalSection(ZipLock);
  try
    RecoverJournal(ZipPath);
    if not ReadDirectoryUnlocked(ZipPath, Dir, ErrorText) then
      Exit;
    Idx := ZipFindEntry(Dir, Name);
    if Idx < 0 then
    begin
      ErrorText := 'no such entry';
      Exit;
    end;
    E := Dir.Entries[Idx];
    if not CheckStored(E, ErrorText) then
      Exit;

    JournalPath := ZipPath + ZIP_JOURNAL_SUFFIX;
    try
      Stream := TFileStream.Create(ZipPath, fmOpenReadWrite or fmShareDenyNone);
    except
      on Ex: Exception do
      begin
        ErrorText := 'cannot open the zip for writing: ' + Ex.Message;
        Exit;
      end;
    end;
    try
      OldLength := Stream.Size;
      // 1. The journal: the old length, on disk before any byte is appended.
      JournalText := IntToStr(OldLength) + LineEnding;
      try
        Journal := TFileStream.Create(JournalPath, fmCreate);
        try
          WriteRaw(Journal, JournalText);
          SyncHandle(Journal.Handle);
        finally
          Journal.Free;
        end;
      except
        on Ex: Exception do
        begin
          ErrorText := 'cannot write the save journal: ' + Ex.Message;
          Exit;
        end;
      end;

      try
        // 2. The new local header (with a ZIP64 extra, as gitea_backup writes
        // with force_zip64) and the new bytes, after the end of the file.
        CrcValue := crc32(0, nil, 0);
        if Length(Data) > 0 then
          CrcValue := crc32(CrcValue, PByte(@Data[1]), Length(Data));
        DosDateTimeNow(DosTime, DosDate);
        NewOffset := OldLength;
        Header := '';
        Put32(Header, SIG_LOCAL);
        Put16(Header, 45);
        Put16(Header, E.Flags and $0800);
        Put16(Header, 0);
        Put16(Header, DosTime);
        Put16(Header, DosDate);
        Put32(Header, CrcValue);
        Put32(Header, $FFFFFFFF);
        Put32(Header, $FFFFFFFF);
        Put16(Header, Length(E.Name));
        Put16(Header, 20);
        Header := Header + E.Name + #1#0#16#0;
        Put64(Header, Length(Data));
        Put64(Header, Length(Data));
        Stream.Position := OldLength;
        WriteRaw(Stream, Header);
        WriteRaw(Stream, Data);

        E.VersionNeeded := 45;
        if (E.VersionMade and $FF) < 45 then
          E.VersionMade := (E.VersionMade and $FF00) or 45;
        E.Flags := E.Flags and $0800;
        E.Method := 0;
        E.ModTime := DosTime;
        E.ModDate := DosDate;
        E.Crc := CrcValue;
        E.Size := Length(Data);
        E.CompSize := Length(Data);
        E.LocalOffset := NewOffset;
        Dir.Entries[Idx] := E;

        // 3. A new central directory: every entry where it was, this one at
        // its new copy, and the end records.
        CdStart := NewOffset + Length(Header) + Length(Data);
        Cd := '';
        for I := 0 to High(Dir.Entries) do
          Cd := Cd + CentralRecord(Dir.Entries[I]);
        CdSize := Length(Cd);
        Tail := EndRecords(Length(Dir.Entries), CdStart, CdSize, Dir.HasZip64, Dir.Comment);
        WriteRaw(Stream, Cd);
        WriteRaw(Stream, Tail);
        SyncHandle(Stream.Handle);
      except
        on Ex: Exception do
        begin
          // Roll back now rather than at the next open.
          try
            Stream.Size := OldLength;
            SyncHandle(Stream.Handle);
            DeleteFile(JournalPath);
          except
          end;
          ErrorText := 'cannot write the zip: ' + Ex.Message;
          Exit;
        end;
      end;
    finally
      Stream.Free;
    end;
    // 4. Done: the new end record is on disk, so the journal goes.
    DeleteFile(JournalPath);
    Result := True;
  finally
    LeaveCriticalSection(ZipLock);
  end;
end;

function ZipRewriteWithout(const ZipPath, TmpPath: string; Drop: TStringList;
  out DroppedCount: Integer; out DroppedBytes: Int64; out ErrorText: string): Boolean;
var
  Dir: TZipDirectory;
  Src, Dst: TFileStream;
  Kept: TZipEntries;
  I, Idx: Integer;
  E: TZipEntry;
  Head, Cd: RawByteString;
  DataOffset, Remaining, CdStart: Int64;
  Buf: array of Byte;
  Chunk: Integer;
begin
  Result := False;
  ErrorText := '';
  DroppedCount := 0;
  DroppedBytes := 0;
  EnterCriticalSection(ZipLock);
  try
    RecoverJournal(ZipPath);
    if not ReadDirectoryUnlocked(ZipPath, Dir, ErrorText) then
      Exit;
    Kept := nil;
    Src := nil;
    Dst := nil;
    try
      try
        Src := TFileStream.Create(ZipPath, fmOpenRead or fmShareDenyNone);
        Dst := TFileStream.Create(TmpPath, fmCreate);
        SetLength(Buf, 1 shl 20);
        for I := 0 to High(Dir.Entries) do
        begin
          E := Dir.Entries[I];
          if Drop.Find(E.Name, Idx) then
          begin
            Inc(DroppedCount);
            Inc(DroppedBytes, E.CompSize);
            Continue;
          end;
          if not ReadAt(Src, E.LocalOffset, 30, Head) or (LE32(Head, 1) <> SIG_LOCAL) then
            raise Exception.Create(E.Name + ': bad local file header');
          DataOffset := E.LocalOffset + 30 + LE16(Head, 27) + LE16(Head, 29);
          if DataOffset + E.CompSize > Src.Size then
            raise Exception.Create(E.Name + ': entry data out of range');
          // The sizes are in the new local header: no data descriptor.
          E.Flags := E.Flags and not Word($0008);
          if E.VersionNeeded < 45 then
            E.VersionNeeded := 45;
          if (E.VersionMade and $FF) < 45 then
            E.VersionMade := (E.VersionMade and $FF00) or 45;
          E.LocalOffset := Dst.Position;
          WriteRaw(Dst, LocalHeader(E));
          Src.Position := DataOffset;
          Remaining := E.CompSize;
          while Remaining > 0 do
          begin
            Chunk := Length(Buf);
            if Remaining < Chunk then
              Chunk := Remaining;
            Src.ReadBuffer(Buf[0], Chunk);
            Dst.WriteBuffer(Buf[0], Chunk);
            Dec(Remaining, Chunk);
          end;
          SetLength(Kept, Length(Kept) + 1);
          Kept[High(Kept)] := E;
        end;
        CdStart := Dst.Position;
        Cd := '';
        for I := 0 to High(Kept) do
          Cd := Cd + CentralRecord(Kept[I]);
        WriteRaw(Dst, Cd);
        WriteRaw(Dst, EndRecords(Length(Kept), CdStart, Length(Cd), Dir.HasZip64, Dir.Comment));
        SyncHandle(Dst.Handle);
        Result := True;
      except
        on Ex: Exception do
          ErrorText := 'cannot rewrite the zip: ' + Ex.Message;
      end;
    finally
      Dst.Free;
      Src.Free;
      if not Result then
        DeleteFile(TmpPath);
    end;
  finally
    LeaveCriticalSection(ZipLock);
  end;
end;

{ --- the backup lock and the commit ------------------------------------------ }

function BkUtcIsoNow: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', LocalTimeToUniversal(Now)) + '+00:00';
end;

function ReadFirstLine(const Path: string): string;
begin
  Result := '';
  try
    with TStringList.Create do
    try
      LoadFromFile(Path);
      if Count > 0 then
        Result := Trim(Strings[0]);
    finally
      Free;
    end;
  except
    Result := '';
  end;
end;

function HostName: string;
begin
  {$IFDEF UNIX}
  Result := GetHostName;
  {$ELSE}
  Result := GetEnvironmentVariable('COMPUTERNAME');
  {$ENDIF}
end;

// Stale: written on this host by a process that is gone.
function LockIsStale(const Line: string): Boolean;
var
  Parts: TStringArray;
  Pid: Int64;
begin
  Result := False;
  Parts := Line.Split([' ']);
  if Length(Parts) < 2 then
    Exit;
  Pid := StrToInt64Def(Parts[0], -1);
  if (Pid <= 0) or (Pid > High(LongInt)) or (Parts[1] <> HostName) then
    Exit;
  {$IFDEF UNIX}
  Result := (fpKill(TPid(Pid), 0) <> 0) and (fpGetErrno = ESysESRCH);
  {$ENDIF}
end;

procedure SyncDirectory(const Dir: string);
{$IFDEF UNIX}
var
  Fd: cint;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Fd := fpOpen(PChar(ExcludeTrailingPathDelimiter(Dir)), O_RDONLY);
  if Fd >= 0 then
  begin
    fpFsync(Fd);
    fpClose(Fd);
  end;
  {$ENDIF}
end;

procedure BkSyncFile(const Path: string);
var
  F: TFileStream;
begin
  try
    F := TFileStream.Create(Path, fmOpenReadWrite or fmShareDenyNone);
    try
      SyncHandle(F.Handle);
    finally
      F.Free;
    end;
  except
  end;
end;

function BkLockAcquire(const OwnerDir: string; out Content, Holder,
  ErrorText: string): Boolean;
var
  Path: string;
  Attempt: Integer;
  Line: RawByteString;
  {$IFDEF UNIX}
  Fd: cint;
  Errno: cint;
  {$ENDIF}
begin
  Result := False;
  Holder := '';
  ErrorText := '';
  Path := IncludeTrailingPathDelimiter(OwnerDir) + BACKUP_LOCK_NAME;
  Content := IntToStr(GetProcessID) + ' ' + HostName + ' omi ' + BkUtcIsoNow;
  EnterCriticalSection(WriteLock);
  {$IFDEF UNIX}
  for Attempt := 0 to 2 do
  begin
    Fd := fpOpen(PChar(Path), O_CREAT or O_EXCL or O_WRONLY, &644);
    if Fd >= 0 then
    begin
      Line := Content + #10;
      fpWrite(Fd, Line[1], Length(Line));
      fpFsync(Fd);
      fpClose(Fd);
      Exit(True);
    end;
    Errno := fpGetErrno;
    if Errno <> ESysEEXIST then
    begin
      ErrorText := 'cannot create ' + Path + ' (errno ' + IntToStr(Errno) + ')';
      Break;
    end;
    Holder := ReadFirstLine(Path);
    if not FileExists(Path) then
      Continue; // released just now
    if (Attempt = 0) and LockIsStale(Holder) then
    begin
      DeleteFile(Path);
      Continue;
    end;
    ErrorText := Holder;
    Break;
  end;
  {$ELSE}
  ErrorText := 'locking needs a Unix system';
  {$ENDIF}
  LeaveCriticalSection(WriteLock);
end;

procedure BkLockRelease(const OwnerDir, Content: string);
var
  Path: string;
begin
  Path := IncludeTrailingPathDelimiter(OwnerDir) + BACKUP_LOCK_NAME;
  if ReadFirstLine(Path) = Content then
    DeleteFile(Path);
  LeaveCriticalSection(WriteLock);
end;

function RenameOver(const Src, Dst: string): Boolean;
begin
  {$IFDEF UNIX}
  Result := fpRename(PChar(Src), PChar(Dst)) = 0;
  {$ELSE}
  if FileExists(Dst) then
    DeleteFile(Dst);
  Result := RenameFile(Src, Dst);
  {$ENDIF}
end;

procedure BkRecoverCommit(const OwnerDir, Name: string);
var
  Dir, Marker, Db, Zip: string;
begin
  Dir := IncludeTrailingPathDelimiter(OwnerDir);
  Marker := Dir + BACKUP_COMMIT_NAME;
  Db := Dir + Name + '.db';
  Zip := Dir + Name + '.zip';
  if FileExists(Marker) then
  begin
    if FileExists(Zip + '.tmp') then
      RenameOver(Zip + '.tmp', Zip);
    if FileExists(Db + '.tmp') then
      RenameOver(Db + '.tmp', Db);
    DeleteFile(Marker);
    SyncDirectory(Dir);
  end
  else
  begin
    if FileExists(Db + '.tmp') then
      DeleteFile(Db + '.tmp');
    if FileExists(Zip + '.tmp') then
      DeleteFile(Zip + '.tmp');
  end;
end;

function BkCommitFiles(const OwnerDir, Name: string; out ErrorText: string): Boolean;
var
  Dir, Marker, Db, Zip: string;
  F: TFileStream;
begin
  Result := False;
  ErrorText := '';
  Dir := IncludeTrailingPathDelimiter(OwnerDir);
  Marker := Dir + BACKUP_COMMIT_NAME;
  Db := Dir + Name + '.db';
  Zip := Dir + Name + '.zip';
  try
    F := TFileStream.Create(Marker, fmCreate);
    try
      WriteRaw(F, 'omi ' + BkUtcIsoNow + LineEnding);
      SyncHandle(F.Handle);
    finally
      F.Free;
    end;
  except
    on Ex: Exception do
    begin
      ErrorText := 'cannot write ' + Marker + ': ' + Ex.Message;
      Exit;
    end;
  end;
  SyncDirectory(Dir);
  // From here on the commit is decided: what is not renamed now is renamed by
  // the next writer's recovery.
  if FileExists(Zip + '.tmp') and not RenameOver(Zip + '.tmp', Zip) then
  begin
    ErrorText := 'cannot rename ' + Zip + '.tmp';
    Exit;
  end;
  if FileExists(Db + '.tmp') and not RenameOver(Db + '.tmp', Db) then
  begin
    ErrorText := 'cannot rename ' + Db + '.tmp';
    Exit;
  end;
  DeleteFile(Marker);
  SyncDirectory(Dir);
  Result := True;
end;

function BkCopyFile(const Src, Dst: string; out ErrorText: string): Boolean;
var
  A, B: TFileStream;
begin
  Result := False;
  ErrorText := '';
  try
    A := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
    try
      B := TFileStream.Create(Dst, fmCreate);
      try
        if A.Size > 0 then
          B.CopyFrom(A, A.Size);
        SyncHandle(B.Handle);
      finally
        B.Free;
      end;
    finally
      A.Free;
    end;
    Result := True;
  except
    on Ex: Exception do
    begin
      ErrorText := Ex.Message;
      DeleteFile(Dst);
    end;
  end;
end;

{ --- TFileWindowStream ------------------------------------------------------- }

constructor TFileWindowStream.Create(const FileName: string; AStart, ALen: Int64);
begin
  inherited Create;
  FFile := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  FStart := AStart;
  FLen := ALen;
  FPos := 0;
end;

destructor TFileWindowStream.Destroy;
begin
  FFile.Free;
  inherited Destroy;
end;

function TFileWindowStream.GetSize: Int64;
begin
  Result := FLen;
end;

function TFileWindowStream.Read(var Buffer; Count: Longint): Longint;
var
  Want, Got: Longint;
  P: PByte;
begin
  Result := 0;
  if Count <= 0 then
    Exit;
  if FPos + Count > FLen then
    Count := FLen - FPos;
  if Count <= 0 then
    Exit;
  FFile.Position := FStart + FPos;
  P := @Buffer;
  // Fill the whole request: TStream.CopyFrom stops at the first short read.
  while Result < Count do
  begin
    Want := Count - Result;
    Got := FFile.Read(P[Result], Want);
    if Got <= 0 then
      Break;
    Inc(Result, Got);
  end;
  Inc(FPos, Result);
end;

function TFileWindowStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EStreamError.Create('read-only stream');
  Result := 0;
end;

function TFileWindowStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  case Origin of
    soBeginning: FPos := Offset;
    soCurrent: FPos := FPos + Offset;
    soEnd: FPos := FLen + Offset;
  end;
  if FPos < 0 then
    FPos := 0;
  if FPos > FLen then
    FPos := FLen;
  Result := FPos;
end;

{ --- text helpers ------------------------------------------------------------ }

function Sha256Hex(const Data: RawByteString): string;
var
  H: TSHA256;
  S: AnsiString;
begin
  H.Init;
  if Length(Data) > 0 then
    H.Update(PByte(@Data[1]), Length(Data));
  H.Final;
  H.OutputHexa(S);
  Result := LowerCase(S);
end;

function IsValidUtf8(const Data: RawByteString): Boolean;
var
  I, N, K: SizeInt;
  B: Byte;
begin
  Result := False;
  I := 1;
  N := Length(Data);
  while I <= N do
  begin
    B := Ord(Data[I]);
    if B = 0 then
      Exit;
    if B < $80 then
      K := 0
    else if (B and $E0) = $C0 then
    begin
      if B < $C2 then Exit;
      K := 1;
    end
    else if (B and $F0) = $E0 then
      K := 2
    else if (B and $F8) = $F0 then
    begin
      if B > $F4 then Exit;
      K := 3;
    end
    else
      Exit;
    if I + K > N then
      Exit;
    while K > 0 do
    begin
      Inc(I);
      if (Ord(Data[I]) and $C0) <> $80 then
        Exit;
      Dec(K);
    end;
    Inc(I);
  end;
  Result := True;
end;

function BkSafePart(const Text: string): string;
var
  I: Integer;
begin
  Result := Text;
  for I := 1 to Length(Result) do
    if (Ord(Result[I]) < 32) or (Ord(Result[I]) = 127) or (Result[I] = '/') or
      (Result[I] = '\') then
      Result[I] := '_';
  Result := Trim(Result);
  if (Result = '') or (Result = '.') or (Result = '..') then
    Result := '_';
end;

initialization
  InitCriticalSection(ZipLock);
  InitCriticalSection(WriteLock);

finalization
  DoneCriticalSection(ZipLock);
  DoneCriticalSection(WriteLock);

end.
