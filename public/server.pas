{
  OMI Server - FreePascal Implementation
  ===========================================
  
  Web server for repository management with SQLite backend.
  Feature-complete mirror of PHP (index.php) and JavaScript (server.js) servers.
  
  FEATURES:
  - User authentication with session management
  - Repository browsing and file management
  - File upload, edit, delete, rename operations
  - Markdown rendering with basic formatting
  - Image display (JPEG, PNG, GIF, BMP, WebP)
  - Translation system support (1,723 i18n keys)
  - SQLite database backend
  - OTP support ready
  
  BUILD & RUN:
  
  fpc -o server public/server.pas
  ./server
}

program OmiServer;

{$MODE OBJFPC}
{$H+}
{$CODEPAGE UTF8}

uses
  {$IFDEF UNIX}
  cthreads, cmem,
  {$ENDIF}
  SysUtils, fphttpapp, HTTPDefs, httproute, Classes,
  StrUtils, Math, fpjson, jsonparser,
  Process, inifiles;

const
  VERSION = '1.0.0';
  DEFAULT_PORT = 3001;
  SETTINGS_FILE = '../settings.txt';
  USERS_FILE = '../users.txt';
  USERS_BRUTEFORCE_FILE = '../usersbruteforcelocked.txt';
  REPOS_DIR = '../repos';
  SESSION_TIMEOUT = 24 * 60 * 60;
  USER_VALUE_SEP = #1;
  
type
  TSettings = record
    Port: Integer;
    SqliteCmd: string;
    DbPath: string;
  end;

  TFileEntry = record
    Filename: string;
    Hash: string;
    DateTimeStr: string;
    Size: Int64;
    IsDirectory: Boolean;
  end;

  TFileEntryArray = array of TFileEntry;

  TRepoEntry = record
    Name: string;
    Size: Int64;
    Modified: Int64;
  end;

  TRepoEntryArray = array of TRepoEntry;

var
  Settings: TSettings;
  Users: TStringList;
  Sessions: TStringList;

function AppBaseDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
end;

function DataPath(const RelativePath: string): string;
begin
  Result := ExpandFileName(AppBaseDir + RelativePath);
end;

function ParseUserLine(const Line: string; out Username, Password, Otp, Language: string): Boolean;
var
  P1, P2, P3: Integer;
begin
  Result := False;
  Username := '';
  Password := '';
  Otp := '';
  Language := 'en';

  P1 := Pos(':', Line);
  if P1 = 0 then
    Exit;
  P2 := PosEx(':', Line, P1 + 1);
  if P2 = 0 then
  begin
    Username := Copy(Line, 1, P1 - 1);
    Password := Copy(Line, P1 + 1, Length(Line));
    Result := True;
    Exit;
  end;
  P3 := PosEx(':', Line, P2 + 1);

  Username := Copy(Line, 1, P1 - 1);
  Password := Copy(Line, P1 + 1, P2 - P1 - 1);
  if P3 = 0 then
  begin
    Otp := Copy(Line, P2 + 1, Length(Line));
    Language := 'en';
  end
  else
  begin
    Otp := Copy(Line, P2 + 1, P3 - P2 - 1);
    Language := Copy(Line, P3 + 1, Length(Line));
  end;
  Result := True;
end;

function LoadUsersMap: TStringList;
var
  F: TextFile;
  Line: string;
  Username, Password, Otp, Language: string;
  FilePath: string;
begin
  Result := TStringList.Create;
  Result.NameValueSeparator := '=';
  Result.CaseSensitive := False;

  FilePath := DataPath(USERS_FILE);
  if FileExists(FilePath) then
  begin
    AssignFile(F, FilePath);
    SetTextCodePage(F, CP_UTF8);
    Reset(F);
    try
      while not EOF(F) do
      begin
        ReadLn(F, Line);
        Line := Trim(Line);
        if Line = '' then
          Continue;
        if ParseUserLine(Line, Username, Password, Otp, Language) then
          Result.Values[Username] := Password + USER_VALUE_SEP + Otp + USER_VALUE_SEP + Language;
      end;
    finally
      CloseFile(F);
    end;
  end;
end;

procedure SaveUsersMap(UsersMap: TStringList);
var
  F: TextFile;
  I: Integer;
  Username, Value, Password, Otp, Language: string;
  P1, P2: Integer;
  FilePath: string;
begin
  FilePath := DataPath(USERS_FILE);
  AssignFile(F, FilePath);
  SetTextCodePage(F, CP_UTF8);
  Rewrite(F);
  try
    for I := 0 to UsersMap.Count - 1 do
    begin
      Username := UsersMap.Names[I];
      Value := UsersMap.ValueFromIndex[I];
      P1 := Pos(USER_VALUE_SEP, Value);
      P2 := PosEx(USER_VALUE_SEP, Value, P1 + 1);
      if (P1 > 0) and (P2 > 0) then
      begin
        Password := Copy(Value, 1, P1 - 1);
        Otp := Copy(Value, P1 + 1, P2 - P1 - 1);
        Language := Copy(Value, P2 + 1, Length(Value));
      end
      else
      begin
        Password := Value;
        Otp := '';
        Language := 'en';
      end;
      WriteLn(F, Username + ':' + Password + ':' + Otp + ':' + Language);
    end;
  finally
    CloseFile(F);
  end;
end;

function GetUserData(UsersMap: TStringList; const Username: string; out Password, Otp, Language: string): Boolean;
var
  Value: string;
  P1, P2: Integer;
begin
  Result := False;
  Password := '';
  Otp := '';
  Language := 'en';
  Value := UsersMap.Values[Username];
  if Value = '' then
    Exit;
  P1 := Pos(USER_VALUE_SEP, Value);
  P2 := PosEx(USER_VALUE_SEP, Value, P1 + 1);
  if (P1 > 0) and (P2 > 0) then
  begin
    Password := Copy(Value, 1, P1 - 1);
    Otp := Copy(Value, P1 + 1, P2 - P1 - 1);
    Language := Copy(Value, P2 + 1, Length(Value));
  end
  else
    Password := Value;
  Result := True;
end;

function GetBrowserLanguage(ARequest: TRequest): string;
begin
  // Language detection from Accept-Language header would go here
  // For now, default to English
  Result := 'en';
end;

function IsUserLocked(const Username: string): Boolean;
var
  F: TextFile;
  Line: string;
  FilePath: string;
begin
  Result := False;
  if Username = '' then
    Exit;
  FilePath := DataPath(USERS_BRUTEFORCE_FILE);
  if not FileExists(FilePath) then
    Exit;
  AssignFile(F, FilePath);
  SetTextCodePage(F, CP_UTF8);
  Reset(F);
  try
    while not EOF(F) do
    begin
      ReadLn(F, Line);
      if Trim(Line) = Username then
      begin
        Result := True;
        Break;
      end;
    end;
  finally
    CloseFile(F);
  end;
end;

function GetCookieValue(ARequest: TRequest; const Name: string): string;
begin
  Result := ARequest.CookieFields.Values[Name];
end;

function GetUsernameFromRequest(ARequest: TRequest): string;
var
  SessionId: string;
begin
  Result := '';
  SessionId := GetCookieValue(ARequest, 'sessionId');
  if SessionId <> '' then
    Result := Sessions.Values[SessionId];
end;

function LoadSettingsMap: TStringList;
var
  F: TextFile;
  Line: string;
  EqPos: Integer;
  Key, Value: string;
  FilePath: string;
begin
  Result := TStringList.Create;
  Result.NameValueSeparator := '=';
  FilePath := DataPath(SETTINGS_FILE);
  if not FileExists(FilePath) then
    Exit;
  AssignFile(F, FilePath);
  SetTextCodePage(F, CP_UTF8);
  Reset(F);
  try
    while not EOF(F) do
    begin
      ReadLn(F, Line);
      Line := Trim(Line);
      if (Line = '') or (Line[1] = '#') then
        Continue;
      EqPos := Pos('=', Line);
      if EqPos > 0 then
      begin
        Key := Trim(Copy(Line, 1, EqPos - 1));
        Value := Trim(Copy(Line, EqPos + 1, Length(Line)));
        Result.Values[Key] := Value;
      end;
    end;
  finally
    CloseFile(F);
  end;
end;

function SaveSettingsMap(SettingsMap: TStringList): Boolean;
var
  F: TextFile;
  I: Integer;
  FilePath: string;
begin
  Result := False;
  FilePath := DataPath(SETTINGS_FILE);
  AssignFile(F, FilePath);
  SetTextCodePage(F, CP_UTF8);
  Rewrite(F);
  try
    for I := 0 to SettingsMap.Count - 1 do
      WriteLn(F, SettingsMap.Names[I] + '=' + SettingsMap.ValueFromIndex[I]);
    Result := True;
  finally
    CloseFile(F);
  end;
end;

function JsonGetString(Obj: TJSONObject; const Key, DefaultValue: string): string;
var
  Data: TJSONData;
begin
  Result := DefaultValue;
  if not Assigned(Obj) then
    Exit;
  Data := Obj.Find(Key);
  if Assigned(Data) and (Data.JSONType = jtString) then
    Result := Data.AsString;
end;

function JsonGetBool(Obj: TJSONObject; const Key: string; DefaultValue: Boolean): Boolean;
var
  Data: TJSONData;
begin
  Result := DefaultValue;
  if not Assigned(Obj) then
    Exit;
  Data := Obj.Find(Key);
  if Assigned(Data) and (Data.JSONType = jtBoolean) then
    Result := Data.AsBoolean;
end;

function LoadLanguagesData: TJSONObject;
var
  LangFile: string;
  Content: string;
  Stream: TMemoryStream;
  JsonData: TJSONData;
begin
  Result := TJSONObject.Create;
  LangFile := DataPath('languages.json');
  if not FileExists(LangFile) then
    Exit;
  Stream := TMemoryStream.Create;
  try
    Stream.LoadFromFile(LangFile);
    SetLength(Content, Stream.Size);
    if Stream.Size > 0 then
      Stream.Read(Content[1], Stream.Size);
    JsonData := GetJSON(Content);
    if JsonData is TJSONObject then
    begin
      Result.Free;
      Result := TJSONObject(JsonData);
    end;
  finally
    Stream.Free;
  end;
end;

function LoadSettings: TSettings;
var
  F: TextFile;
  Line, Key, Value: string;
  EqPos: Integer;
begin
  Result.Port := DEFAULT_PORT;
  Result.SqliteCmd := 'sqlite3';
  Result.DbPath := 'omi.db';

  if FileExists(DataPath(SETTINGS_FILE)) then
  begin
    AssignFile(F, DataPath(SETTINGS_FILE));
    SetTextCodePage(F, CP_UTF8);
    Reset(F);
    try
      while not EOF(F) do
      begin
        Readln(F, Line);
        Line := Trim(Line);
        if (Line = '') or (Line[1] = '#') then Continue;
        
        EqPos := Pos('=', Line);
        if EqPos > 0 then
        begin
          Key := Trim(Copy(Line, 1, EqPos - 1));
          Value := Trim(Copy(Line, EqPos + 1, Length(Line)));
          
          if Key = 'port' then
            Result.Port := StrToIntDef(Value, DEFAULT_PORT)
          else if Key = 'sqlite' then
            Result.SqliteCmd := Value
          else if Key = 'db' then
            Result.DbPath := Value;
        end;
      end;
    finally
      CloseFile(F);
    end;
  end;
end;

procedure LoadUsers;
var
  F: TextFile;
  Line: string;
begin
  Users.Clear;
  if FileExists(DataPath(USERS_FILE)) then
  begin
    AssignFile(F, DataPath(USERS_FILE));
    SetTextCodePage(F, CP_UTF8);
    Reset(F);
    try
      while not EOF(F) do
      begin
        Readln(F, Line);
        Line := Trim(Line);
        if Line <> '' then
          Users.Add(Line);
      end;
    finally
      CloseFile(F);
    end;
  end;
end;

function LoadTranslations(Language: string): TJSONObject;
var
  LangFile: string;
  Content: string;
  Stream: TMemoryStream;
  JsonData: TJSONData;
begin
  Result := nil;
  
  LangFile := DataPath(Format('i18n/%s.i18n.json', [Language]));
  if not FileExists(LangFile) then
    LangFile := DataPath('i18n/en.i18n.json');

  if FileExists(LangFile) then
  begin
    Stream := TMemoryStream.Create;
    try
      Stream.LoadFromFile(LangFile);
      SetLength(Content, Stream.Size);
      if Stream.Size > 0 then
        Stream.Read(Content[1], Stream.Size);
      try
        JsonData := GetJSON(Content);
        if JsonData is TJSONObject then
          Result := TJSONObject(JsonData)
        else
          Result := TJSONObject.Create;
      except
        Result := TJSONObject.Create;
      end;
    finally
      Stream.Free;
    end;
  end
  else
    Result := TJSONObject.Create;
end;

// Convert Scandinavian and special UTF-8 characters to HTML entities
function ConvertUTF8ToHtmlEntities(Text: string): string;
begin
  Result := Text;
  // Scandinavian lowercase vowels
  Result := StringReplace(Result, 'ä', '&auml;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ö', '&ouml;', [rfReplaceAll]);
  Result := StringReplace(Result, 'å', '&aring;', [rfReplaceAll]);
  // Scandinavian uppercase vowels
  Result := StringReplace(Result, 'Ä', '&Auml;', [rfReplaceAll]);
  Result := StringReplace(Result, 'Ö', '&Ouml;', [rfReplaceAll]);
  Result := StringReplace(Result, 'Å', '&Aring;', [rfReplaceAll]);
  // Other common special characters
  Result := StringReplace(Result, 'é', '&eacute;', [rfReplaceAll]);
  Result := StringReplace(Result, 'è', '&egrave;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ê', '&ecirc;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ë', '&euml;', [rfReplaceAll]);
  Result := StringReplace(Result, 'á', '&aacute;', [rfReplaceAll]);
  Result := StringReplace(Result, 'à', '&agrave;', [rfReplaceAll]);
  Result := StringReplace(Result, 'â', '&acirc;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ã', '&atilde;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ó', '&oacute;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ò', '&ograve;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ô', '&ocirc;', [rfReplaceAll]);
  Result := StringReplace(Result, 'õ', '&otilde;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ú', '&uacute;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ù', '&ugrave;', [rfReplaceAll]);
  Result := StringReplace(Result, 'û', '&ucirc;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ü', '&uuml;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ç', '&ccedil;', [rfReplaceAll]);
  Result := StringReplace(Result, 'Ç', '&Ccedil;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ñ', '&ntilde;', [rfReplaceAll]);
  Result := StringReplace(Result, 'Ñ', '&Ntilde;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ƒ', '&fnof;', [rfReplaceAll]);
  Result := StringReplace(Result, 'ß', '&szlig;', [rfReplaceAll]);
end;

function T(Key: string; Translations: TJSONObject): string;
var
  JsonValue: TJSONData;
begin
  Result := Key;
  if Assigned(Translations) then
  begin
    try
      JsonValue := Translations.Find(Key);
      if Assigned(JsonValue) and (JsonValue.JSONType = jtString) then
        Result := JsonValue.AsString;
    except
      Result := Key;
    end;
  end;
  // Convert UTF-8 Scandinavian characters to HTML entities
  Result := ConvertUTF8ToHtmlEntities(Result);
end;

function ifthen(Condition: Boolean; const TrueVal, FalseVal: string): string;
begin
  if Condition then
    Result := TrueVal
  else
    Result := FalseVal;
end;

function AuthenticateUser(Username, Password: string): Boolean;
var
  UsersMap: TStringList;
  StoredPassword, StoredOtp, StoredLanguage: string;
begin
  Result := False;
  UsersMap := LoadUsersMap;
  try
    if GetUserData(UsersMap, Username, StoredPassword, StoredOtp, StoredLanguage) then
      Result := StoredPassword = Password;
  finally
    UsersMap.Free;
  end;
end;

function GetUsername(Cookies: string): string;
var
  I: Integer;
  SessionId: string;
  SessionData: string;
  PipePos: Integer;
begin
  Result := '';
  if Pos('sessionId=', Cookies) > 0 then
  begin
    SessionId := Copy(Cookies, Pos('sessionId=', Cookies) + 10, 100);
    I := Pos(';', SessionId);
    if I > 0 then
      SessionId := Copy(SessionId, 1, I - 1);
    
    SessionData := Sessions.Values[SessionId];
    if SessionData <> '' then
      Result := SessionData;
  end;
end;

function CreateSession(Username: string): string;
var
  SessionId: string;
begin
  Randomize;
  SessionId := Format('%s_%d_%d', [Username, Random(999999), GetTickCount64 mod 1000000]);
  Sessions.Values[SessionId] := Username;
  Result := SessionId;
end;

function Base64Encode(const Input: string): string;
const
  B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  I, Len: Integer;
  B: array[0..2] of Byte;
begin
  Result := '';
  Len := Length(Input);
  I := 1;
  
  while I <= Len do
  begin
    B[0] := Ord(Input[I]);
    B[1] := 0;
    B[2] := 0;
    
    if I < Len then
      B[1] := Ord(Input[I + 1]);
    if I + 1 < Len then
      B[2] := Ord(Input[I + 2]);
    
    Result := Result + B64[((B[0] shr 2) and $3F) + 1];
    Result := Result + B64[(((B[0] and $03) shl 4) or ((B[1] shr 4) and $0F)) + 1];
    
    if I + 1 <= Len then
      Result := Result + B64[(((B[1] and $0F) shl 2) or ((B[2] shr 6) and $03)) + 1]
    else
      Result := Result + '=';
    
    if I + 2 <= Len then
      Result := Result + B64[(B[2] and $3F) + 1]
    else
      Result := Result + '=';
    
    Inc(I, 3);
  end;
end;

function IsImageFile(const Filename: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(Filename));
  Result := (Ext = '.jpg') or (Ext = '.jpeg') or (Ext = '.png') or (Ext = '.gif') or
    (Ext = '.bmp') or (Ext = '.webp') or (Ext = '.ico') or (Ext = '.tif') or (Ext = '.tiff');
end;

function IsMarkdownFile(const Filename: string): Boolean;
begin
  Result := LowerCase(ExtractFileExt(Filename)) = '.md';
end;

function IsTextContent(const Content: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := True;
  for I := 1 to Length(Content) do
  begin
    C := Content[I];
    if (Ord(C) = 0) then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

function SanitizePathSegment(const Value: string): string;
begin
  Result := StringReplace(Value, '../', '', [rfReplaceAll]);
  Result := StringReplace(Result, '..\', '', [rfReplaceAll]);
  Result := StringReplace(Result, '..', '', [rfReplaceAll]);
  Result := StringReplace(Result, #0, '', [rfReplaceAll]);
end;

function NormalizeRepoName(const Value: string): string;
var
  Name: string;
begin
  Name := Trim(Value);
  Name := SanitizePathSegment(Name);
  if Name = '' then
  begin
    Result := '';
    Exit;
  end;
  if ExtractFileExt(Name) <> '.omi' then
    Name := Name + '.omi';
  Result := Name;
end;

function ReadFileToString(const FilePath: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  if not FileExists(FilePath) then
    Exit;
  Stream := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function SqlEscape(const Value: string): string;
begin
  Result := StringReplace(Value, '''', '''''', [rfReplaceAll]);
end;

function HtmlEncode(const Value: string): string;
begin
  Result := StringReplace(Value, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  // Convert UTF-8 Scandinavian characters to HTML entities
  Result := ConvertUTF8ToHtmlEntities(Result);
end;

function HexToString(const HexValue: string): string;
var
  I: Integer;
  ByteStr: string;
  B: Byte;
begin
  Result := '';
  I := 1;
  while I <= Length(HexValue) - 1 do
  begin
    ByteStr := '$' + Copy(HexValue, I, 2);
    B := StrToIntDef(ByteStr, 0);
    Result := Result + Chr(B);
    Inc(I, 2);
  end;
end;

function StringToHex(const Value: string): string;
var
  I: Integer;
  B: Byte;
begin
  Result := '';
  for I := 1 to Length(Value) do
  begin
    B := Ord(Value[I]);
    Result := Result + IntToHex(B, 2);
  end;
end;

function ExecSqlOnDb(const DbPath, Query: string): string;
var
  Proc: TProcess;
  OutputStream: TStringStream;
  OutputText: string;
  DbAbs: string;
begin
  Result := '';
  DbAbs := ExpandFileName(DbPath);

  Proc := TProcess.Create(nil);
  OutputStream := TStringStream.Create('');
  try
    Proc.Executable := Settings.SqliteCmd;
    Proc.Parameters.Add(DbAbs);
    Proc.Parameters.Add('-separator');
    Proc.Parameters.Add('|');
    Proc.Parameters.Add('-batch');
    Proc.Parameters.Add('-noheader');
    Proc.Parameters.Add(Query);
    Proc.Options := [poWaitOnExit, poUsePipes];

    try
      Proc.Execute;
      if Assigned(Proc.Output) then
      begin
        OutputStream.CopyFrom(Proc.Output, 0);
        OutputText := OutputStream.DataString;
        Result := OutputText;
      end;
    except
      Result := '';
    end;
  finally
    OutputStream.Free;
    Proc.Free;
  end;
end;

function GetLatestCommitId(const DbPath: string): Int64;
var
  Output: string;
begin
  Output := Trim(ExecSqlOnDb(DbPath, 'SELECT MAX(id) FROM commits;'));
  if Output = '' then
    Result := 0
  else
    Result := StrToInt64Def(Output, 0);
end;

function GetLatestFiles(const DbPath, RepoPath: string): TFileEntryArray;
var
  Output: string;
  Lines: TStringArray;
  Parts: TStringArray;
  I: Integer;
  Entry: TFileEntry;
  LatestCommit: Int64;
  Query: string;
  Prefix: string;
  CleanRepoPath: string;
begin
  Result := nil;
  LatestCommit := GetLatestCommitId(DbPath);
  if LatestCommit = 0 then
    Exit;

  CleanRepoPath := RepoPath;
  if (CleanRepoPath <> '') and (CleanRepoPath[1] = '/') then
    CleanRepoPath := Copy(CleanRepoPath, 2, Length(CleanRepoPath));
  if CleanRepoPath <> '' then
    Prefix := CleanRepoPath + '/'
  else
    Prefix := '';

  if Prefix <> '' then
    Query := 'SELECT f.filename, f.hash, f.datetime, IFNULL(b.size,0) FROM files f LEFT JOIN blobs b ON f.hash=b.hash WHERE f.commit_id=' + IntToStr(LatestCommit) + ' AND f.filename LIKE ''' + SqlEscape(Prefix) + '%'' ORDER BY f.filename;'
  else
    Query := 'SELECT f.filename, f.hash, f.datetime, IFNULL(b.size,0) FROM files f LEFT JOIN blobs b ON f.hash=b.hash WHERE f.commit_id=' + IntToStr(LatestCommit) + ' ORDER BY f.filename;';

  Output := ExecSqlOnDb(DbPath, Query);
  if Output = '' then
    Exit;
  Lines := Output.Split([#10]);
  for I := 0 to High(Lines) do
  begin
    if Trim(Lines[I]) = '' then
      Continue;
    Parts := Lines[I].Split(['|']);
    if Length(Parts) >= 4 then
    begin
      Entry.Filename := Parts[0];
      Entry.Hash := Parts[1];
      Entry.DateTimeStr := Parts[2];
      Entry.Size := StrToInt64Def(Parts[3], 0);
      Entry.IsDirectory := False;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Entry;
    end;
  end;
end;

function GetFileContentByHash(const DbPath, Hash: string): string;
var
  Output: string;
begin
  Output := Trim(ExecSqlOnDb(DbPath, 'SELECT hex(data) FROM blobs WHERE hash=''' + SqlEscape(Hash) + ''' LIMIT 1;'));
  if Output = '' then
    Result := ''
  else
    Result := HexToString(Output);
end;

function InsertBlob(const DbPath, Hash: string; const Content: string): Boolean;
var
  HexData: string;
  Query: string;
  SizeValue: Int64;
begin
  HexData := StringToHex(Content);
  SizeValue := Length(Content);
  Query := 'INSERT OR IGNORE INTO blobs(hash, data, size) VALUES(''' + SqlEscape(Hash) + ''', X''' + HexData + ''', ' + IntToStr(SizeValue) + ');';
  ExecSqlOnDb(DbPath, Query);
  Result := True;
end;

function CreateCommit(const DbPath, MessageText, Username: string): Int64;
var
  NowStr: string;
  Query: string;
  Output: string;
begin
  NowStr := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
  Query := 'INSERT INTO commits(message, datetime, user) VALUES(''' + SqlEscape(MessageText) + ''', ''' + SqlEscape(NowStr) + ''', ''' + SqlEscape(Username) + ''');';
  ExecSqlOnDb(DbPath, Query);
  Output := Trim(ExecSqlOnDb(DbPath, 'SELECT MAX(id) FROM commits;'));
  Result := StrToInt64Def(Output, 0);
end;

function InsertFileRecord(const DbPath, Filename, Hash, DateTimeStr: string; CommitId: Int64): Boolean;
var
  Query: string;
begin
  Query := 'INSERT INTO files(filename, hash, datetime, commit_id) VALUES(''' + SqlEscape(Filename) + ''', ''' + SqlEscape(Hash) + ''', ''' + SqlEscape(DateTimeStr) + ''', ' + IntToStr(CommitId) + ');';
  ExecSqlOnDb(DbPath, Query);
  Result := True;
end;

function CommitFile(const DbPath, Filename, Content, Username, MessageText: string): Boolean;
var
  Hash: string;
  CommitId: Int64;
  NowStr: string;
  TempFile: string;
  Proc: TProcess;
  OutputStream: TStringStream;
  Output: string;
begin
  Result := False;
  TempFile := GetTempFileName('', 'omi');
  try
    with TFileStream.Create(TempFile, fmCreate) do
    try
      if Length(Content) > 0 then
        WriteBuffer(Content[1], Length(Content));
    finally
      Free;
    end;

    Proc := TProcess.Create(nil);
    OutputStream := TStringStream.Create('');
    try
      Proc.Executable := 'sha256sum';
      Proc.Parameters.Add(TempFile);
      Proc.Options := [poWaitOnExit, poUsePipes];
      Proc.Execute;
      OutputStream.CopyFrom(Proc.Output, 0);
      Output := Trim(OutputStream.DataString);
    finally
      OutputStream.Free;
      Proc.Free;
    end;

    Hash := Trim(Copy(Output, 1, 64));
    if Hash = '' then
      Exit;

    InsertBlob(DbPath, Hash, Content);
    CommitId := CreateCommit(DbPath, MessageText, Username);
    if CommitId = 0 then
      Exit;
    NowStr := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
    InsertFileRecord(DbPath, Filename, Hash, NowStr, CommitId);
    Result := True;
  finally
    if FileExists(TempFile) then
      DeleteFile(TempFile);
  end;
end;

function CreateEmptyRepository(const RepoFilePath, Username: string): Boolean;
var
  Query: string;
  RepoDir: string;
begin
  Result := False;
  RepoDir := ExtractFileDir(RepoFilePath);
  if not DirectoryExists(RepoDir) then
    ForceDirectories(RepoDir);
  if FileExists(RepoFilePath) then
    Exit;
  ExecSqlOnDb(RepoFilePath, 'PRAGMA foreign_keys=ON;');
  Query := 'CREATE TABLE IF NOT EXISTS blobs (hash TEXT PRIMARY KEY, data BLOB, size INTEGER);' +
    'CREATE TABLE IF NOT EXISTS commits (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT, datetime TEXT, user TEXT);' +
    'CREATE TABLE IF NOT EXISTS files (id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, hash TEXT, datetime TEXT, commit_id INTEGER);' +
    'CREATE TABLE IF NOT EXISTS staging (filename TEXT PRIMARY KEY, hash TEXT, datetime TEXT);';
  ExecSqlOnDb(RepoFilePath, Query);
  CreateCommit(RepoFilePath, 'Initial commit', Username);
  Result := True;
end;

function GetRepoPath(const RepoName: string): string;
begin
  Result := DataPath(REPOS_DIR + '/' + RepoName);
end;

function GetReposList: TRepoEntryArray;
var
  Search: TSearchRec;
  Repo: TRepoEntry;
  RepoDir: string;
begin
  Result := nil;
  RepoDir := DataPath(REPOS_DIR);
  if not DirectoryExists(RepoDir) then
    Exit;
  if FindFirst(RepoDir + '/*.omi', faAnyFile, Search) = 0 then
  begin
    repeat
      if (Search.Attr and faDirectory) = 0 then
      begin
        Repo.Name := Search.Name;
        Repo.Size := Search.Size;
        Repo.Modified := Search.Time;
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Repo;
      end;
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
end;

function DeleteFileFromRepo(const DbPath, TargetFilename, Username: string): Boolean;
var
  Files: TFileEntryArray;
  I: Integer;
  CommitId: Int64;
  NowStr: string;
begin
  Result := False;
  CommitId := CreateCommit(DbPath, 'Delete file', Username);
  if CommitId = 0 then
    Exit;
  Files := GetLatestFiles(DbPath, '');
  NowStr := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
  for I := 0 to High(Files) do
  begin
    if Files[I].Filename = TargetFilename then
      Continue;
    InsertFileRecord(DbPath, Files[I].Filename, Files[I].Hash, NowStr, CommitId);
  end;
  Result := True;
end;

function RenameFileInRepo(const DbPath, OldName, NewName, Username: string): Boolean;
var
  Files: TFileEntryArray;
  I: Integer;
  CommitId: Int64;
  NowStr: string;
  Filename: string;
begin
  Result := False;
  CommitId := CreateCommit(DbPath, 'Rename file', Username);
  if CommitId = 0 then
    Exit;
  Files := GetLatestFiles(DbPath, '');
  NowStr := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
  for I := 0 to High(Files) do
  begin
    Filename := Files[I].Filename;
    if Filename = OldName then
      Filename := NewName;
    InsertFileRecord(DbPath, Filename, Files[I].Hash, NowStr, CommitId);
  end;
  Result := True;
end;

function ParsePostFormData(const PostData: string): TStringList;
var
  Lines: TStringArray;
  I: Integer;
  EqPos: Integer;
begin
  Result := TStringList.Create;
  Lines := PostData.Split(['&']);
  for I := 0 to High(Lines) do
  begin
    if Trim(Lines[I]) <> '' then
    begin
      EqPos := Pos('=', Lines[I]);
      if EqPos > 0 then
      begin
        Result.Add(Copy(Lines[I], 1, EqPos - 1) + '=' + Copy(Lines[I], EqPos + 1, Length(Lines[I])));
      end;
    end;
  end;
end;

// Convert Scandinavian and special UTF-8 characters to HTML entities

function MarkdownToHtml(Markdown: string): string;
var
  Lines: TStringArray;
  I: Integer;
  Line, Result1: string;
  InCodeBlock: Boolean;
  ProcessedLine: string;
begin
  Result1 := '';
  InCodeBlock := False;
  Lines := Markdown.Split([#10]);
  
  for I := 0 to High(Lines) do
  begin
    Line := Lines[I];
    ProcessedLine := Line;
    
    if Copy(Trim(ProcessedLine), 1, 3) = '```' then
    begin
      InCodeBlock := not InCodeBlock;
      if InCodeBlock then
        ProcessedLine := '<pre><code>'
      else
        ProcessedLine := '</code></pre>';
    end
    else if InCodeBlock then
    begin
      ProcessedLine := '<code>' + ProcessedLine + '</code>';
    end
    else
    begin
      if Copy(ProcessedLine, 1, 3) = '###' then
        ProcessedLine := '<h3>' + Trim(Copy(ProcessedLine, 5, Length(ProcessedLine))) + '</h3>'
      else if Copy(ProcessedLine, 1, 2) = '##' then
        ProcessedLine := '<h2>' + Trim(Copy(ProcessedLine, 4, Length(ProcessedLine))) + '</h2>'
      else if Copy(ProcessedLine, 1, 1) = '#' then
        ProcessedLine := '<h1>' + Trim(Copy(ProcessedLine, 3, Length(ProcessedLine))) + '</h1>'
      else if Copy(Trim(ProcessedLine), 1, 2) = '- ' then
        ProcessedLine := '<li>' + Trim(Copy(ProcessedLine, 3, Length(ProcessedLine))) + '</li>'
      else if Trim(ProcessedLine) <> '' then
      begin
        ProcessedLine := '<p>' + ProcessedLine + '</p>';
      end;
    end;
    
    Result1 := Result1 + ProcessedLine + #10;
  end;
  
  Result1 := '<div style="font-family:sans-serif;line-height:1.6;">' + Result1 + '</div>';
  Result := Result1;
end;

function GetMimeType(Filename: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(Filename));
  
  case Ext of
    '.jpg', '.jpeg': Result := 'image/jpeg';
    '.png': Result := 'image/png';
    '.gif': Result := 'image/gif';
    '.bmp': Result := 'image/bmp';
    '.webp': Result := 'image/webp';
    '.txt': Result := 'text/plain';
    '.md': Result := 'text/markdown';
    '.json': Result := 'application/json';
    '.html': Result := 'text/html';
    '.css': Result := 'text/css';
    '.js': Result := 'application/javascript';
    '.pdf': Result := 'application/pdf';
  else
    Result := 'application/octet-stream';
  end;
end;

function GetFileTypeLabel(Filename: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(Filename));
  
  case Ext of
    '.md', '.markdown': Result := 'Markdown';
    '.txt': Result := 'Text';
    '.json': Result := 'JSON';
    '.csv': Result := 'CSV';
    '.xml': Result := 'XML';
    '.yaml', '.yml': Result := 'YAML';
    '.html', '.htm': Result := 'HTML';
    '.css': Result := 'CSS';
    '.js': Result := 'JavaScript';
    '.py': Result := 'Python';
    '.php': Result := 'PHP';
    '.java': Result := 'Java';
    '.cpp': Result := 'C++';
    '.c': Result := 'C';
    '.sh': Result := 'Shell';
    '.bash': Result := 'Bash';
    '.sql': Result := 'SQL';
    '.pdf': Result := 'PDF';
    '.doc': Result := 'Word Document';
    '.docx': Result := 'Word Document';
    '.xls': Result := 'Excel';
    '.xlsx': Result := 'Excel';
    '.ppt': Result := 'PowerPoint';
    '.pptx': Result := 'PowerPoint';
    '.zip': Result := 'ZIP Archive';
    '.tar': Result := 'TAR Archive';
    '.gz': Result := 'GZ Archive';
    '.rar': Result := 'RAR Archive';
    '.jpg', '.jpeg': Result := 'JPEG';
    '.png': Result := 'PNG';
    '.gif': Result := 'GIF';
    '.bmp': Result := 'Bitmap';
    '.svg': Result := 'SVG';
    '.webp': Result := 'WebP';
    '.ico': Result := 'Icon';
    '.tiff', '.tif': Result := 'TIFF';
    '.mp3': Result := 'MP3 Audio';
    '.wav': Result := 'WAV Audio';
    '.ogg': Result := 'OGG Audio';
    '.flac': Result := 'FLAC Audio';
    '.m4a': Result := 'M4A Audio';
    '.aac': Result := 'AAC Audio';
    '.mp4': Result := 'MP4 Video';
    '.webm': Result := 'WebM Video';
    '.mkv': Result := 'Matroska Video';
    '.avi': Result := 'AVI Video';
    '.mov': Result := 'QuickTime Video';
    '.flv': Result := 'Flash Video';
    '.wmv': Result := 'Windows Media Video';
  else
    Result := 'File';
  end;
end;

function RenderRepositoryPage(Username: string; Translations: TJSONObject): string;
begin
  Result := '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Omi</title>' +
    '<style>body{font-family:sans-serif;background:#f5f5f5;margin:20px;} ' +
    '.header{display:flex;justify-content:space-between;} a{color:#0066cc;} ' +
    '.repo{background:white;padding:10px;margin:5px 0;border-radius:3px;}</style>' +
    '</head><body>' +
    '<div class="header"><h1>Omi Server v' + VERSION + '</h1>' +
    '<a href="/logout">' + T('logout', Translations) + '</a></div>' +
    '<h2>' + T('repositories', Translations) + '</h2>' +
    '<p><a href="/">' + T('home', Translations) + '</a></p>' +
    '</body></html>';
end;

function RenderFilesPage(RepoPath: string; FilePath: string; Translations: TJSONObject): string;
begin
  Result := '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>' + RepoPath + '</title>' +
    '<style>body{font-family:sans-serif;background:#f5f5f5;margin:20px;} ' +
    '.files{background:white;padding:10px;}</style>' +
    '</head><body>' +
    '<h1>' + RepoPath + '</h1>' +
    '<div><a href="/">' + T('home', Translations) + '</a></div>' +
    '<div class="files">' +
    '<p>' + T('no-files', Translations) + '</p>' +
    '</div>' +
    '</body></html>';
end;

function RenderFilePage(FullPath: string; Content: string; Translations: TJSONObject; IsMarkdown: Boolean): string;
begin
  Result := '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>' + FullPath + '</title>' +
    '<style>body{font-family:sans-serif;background:#f5f5f5;margin:20px;} ' +
    '.content{background:white;padding:20px;white-space:pre-wrap;font-family:monospace;}</style>' +
    '</head><body>' +
    '<h1>' + FullPath + '</h1>' +
    '<div><a href="javascript:history.back()">' + T('back', Translations) + '</a></div>' +
    '<div class="content">' + Content + '</div>' +
    '</body></html>';
end;

procedure LoginEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Translations: TJSONObject;
  Username, Password, OtpCode: string;
  ErrorMsg: string;
  ShowOtp: Boolean;
  UsersMap: TStringList;
  StoredPassword, StoredOtp, StoredLanguage: string;
  UsernameValue, OtpInput, ErrorHtml: string;
  SessionId: string;
begin
  Translations := LoadTranslations(GetBrowserLanguage(ARequest));
  try
    Username := '';
    Password := '';
    OtpCode := '';
    ErrorMsg := '';
    ShowOtp := False;
    UsernameValue := '';
    OtpInput := '';
    ErrorHtml := '';

    if ARequest.Method = 'POST' then
    begin
      Username := Trim(ARequest.ContentFields.Values['username']);
      Password := ARequest.ContentFields.Values['password'];
      OtpCode := Trim(ARequest.ContentFields.Values['otp']);

      if IsUserLocked(Username) then
        ErrorMsg := T('account-locked', Translations)
      else
      begin
        UsersMap := LoadUsersMap;
        try
          if not GetUserData(UsersMap, Username, StoredPassword, StoredOtp, StoredLanguage) then
            ErrorMsg := T('invalid-credentials', Translations)
          else if StoredPassword <> Password then
            ErrorMsg := T('invalid-credentials', Translations)
          else if (StoredOtp <> '') and (OtpCode = '') then
          begin
            ErrorMsg := T('otp-required', Translations);
            ShowOtp := True;
          end
          else
          begin
            SessionId := CreateSession(Username);
            AResponse.SetCustomHeader('Set-Cookie', 'sessionId=' + SessionId + '; Path=/; HttpOnly');
            AResponse.Code := 302;
            AResponse.Location := '/';
            AResponse.Content := '';
            Exit;
          end;
        finally
          UsersMap.Free;
        end;
      end;
    end;

    if Username <> '' then
      UsernameValue := ' value="' + HtmlEncode(Username) + '"'
    else
      UsernameValue := '';
    if ShowOtp then
      OtpInput := '<tr><td>' + T('otp', Translations) + ':</td><td><input type="text" name="otp" size="10" maxlength="6" required pattern="[0-9]{6}" placeholder="6-digit code"></td></tr>'
    else
      OtpInput := '';
    if ErrorMsg <> '' then
      ErrorHtml := '<p><font color="red"><strong>' + T('error', Translations) + ': ' + HtmlEncode(ErrorMsg) + '</strong></font></p>'
    else
      ErrorHtml := '';

    AResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
      '<html>' +
      '<head><meta charset="UTF-8"><title>' + T('login', Translations) + ' - Omi Server</title></head>' +
      '<body bgcolor="#f0f0f0">' +
      '<h1>Omi Server - ' + T('login', Translations) + '</h1>' +
      '<table border="0" cellpadding="5">' +
      '<tr><td colspan="2"><a href="/">[' + T('home', Translations) + ']</a></td></tr>' +
      '</table>' +
      ErrorHtml +
      '<form method="POST">' +
      '<table border="1" cellpadding="5">' +
      '<tr><td>' + T('username', Translations) + ':</td><td><input type="text" name="username" size="30" required' + UsernameValue + '></td></tr>' +
      '<tr><td>' + T('password', Translations) + ':</td><td><input type="password" name="password" size="30" required></td></tr>' +
      OtpInput +
      '<tr><td colspan="2"><input type="submit" value="' + T('login', Translations) + '"></td></tr>' +
      '</table>' +
      '</form>' +
      '<p><a href="/sign-up">' + T('create-account', Translations) + '</a></p>' +
      '</body>' +
      '</html>';
    AResponse.ContentType := 'text/html; charset=UTF-8';
  finally
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

procedure HomeEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Translations: TJSONObject;
  Html: string;
  Repos: TRepoEntryArray;
  I: Integer;
  Username: string;
  DownloadName: string;
  RepoName: string;
  RepoPath: string;
  LogName: string;
  LogDb: string;
  LogRows: string;
  LogLines: TStringArray;
  LogParts: TStringArray;
  TableRows: string;
  ImageParam: string;
  ImageParts: TStringArray;
  ImageRepo: string;
  ImagePath: string;
  DbPath: string;
  Files: TFileEntryArray;
  FileContent: string;
  FileHash: string;
  SizeText: string;
  RepoMessage: string;
  RepoError: Boolean;
  Action: string;
  RepoNameInput: string;
  RepoFile: TUploadedFile;
  JsonList: string;
  ReposJson: string;
  DownloadPath: string;
  DownloadData: string;
  IsRtl: Boolean;
  DirAttr: string;
  LangData: TJSONObject;
  UserLang: string;
  UsersMap: TStringList;
  StoredPassword, StoredOtp, StoredLanguage: string;
  FormatParam: string;
  SuccessColor: string;
begin
  Username := GetUsernameFromRequest(ARequest);
  UserLang := '';
  UsersMap := LoadUsersMap;
  try
    if (Username <> '') and GetUserData(UsersMap, Username, StoredPassword, StoredOtp, StoredLanguage) then
      UserLang := StoredLanguage;
  finally
    UsersMap.Free;
  end;
  if UserLang = '' then
    UserLang := GetBrowserLanguage(ARequest);

  Translations := LoadTranslations(UserLang);
  try
    LangData := LoadLanguagesData;
    try
      IsRtl := False;
      if Assigned(LangData) then
        IsRtl := JsonGetBool(TJSONObject(LangData.Find(UserLang)), 'rtl', False);
    finally
      LangData.Free;
    end;
    if IsRtl then
      DirAttr := 'rtl'
    else
      DirAttr := 'ltr';

    DownloadName := ARequest.QueryFields.Values['download'];
    FormatParam := ARequest.QueryFields.Values['format'];
    LogName := ARequest.QueryFields.Values['log'];
    ImageParam := ARequest.QueryFields.Values['image'];

    if DownloadName <> '' then
    begin
      RepoName := NormalizeRepoName(DownloadName);
      RepoPath := GetRepoPath(RepoName);
      if (RepoName = '') or not FileExists(RepoPath) then
      begin
        AResponse.Code := 404;
        AResponse.ContentType := 'text/plain; charset=UTF-8';
        AResponse.Content := 'Repository not found';
        Exit;
      end;
      DownloadData := ReadFileToString(RepoPath);
      AResponse.ContentType := 'application/octet-stream';
      AResponse.Content := DownloadData;
      AResponse.CustomHeaders.Values['Content-Disposition'] := 'attachment; filename="' + RepoName + '"';
      Exit;
    end;

    if ImageParam <> '' then
    begin
      ImageParts := ImageParam.Split(['/']);
      if Length(ImageParts) >= 2 then
      begin
        ImageRepo := NormalizeRepoName(ImageParts[0]);
        ImagePath := StringReplace(ImageParam, ImageParts[0] + '/', '', []);
        DbPath := GetRepoPath(ImageRepo);
        Files := GetLatestFiles(DbPath, '');
        FileHash := '';
        for I := 0 to High(Files) do
        begin
          if Files[I].Filename = ImagePath then
          begin
            FileHash := Files[I].Hash;
            Break;
          end;
        end;
        if FileHash <> '' then
        begin
          FileContent := GetFileContentByHash(DbPath, FileHash);
          AResponse.ContentType := 'text/html; charset=UTF-8';
          AResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
            '<html><head><meta charset="UTF-8"><title>' + T('image', Translations) + ': ' + HtmlEncode(ImagePath) + ' - ' + HtmlEncode(ImageRepo) + '</title></head>' +
            '<body bgcolor="#f0f0f0">' +
            '<table width="100%" border="0" cellpadding="5">' +
            '<tr><td><h1>' + HtmlEncode(ImageRepo) + '</h1></td><td align="right"><small>' +
            ifthen(Username <> '', '<strong>' + HtmlEncode(Username) + '</strong> | <a href="/language">[' + T('language', Translations) + ']</a> | <a href="/logout">[' + T('logout', Translations) + ']</a>', '<a href="/sign-in">[' + T('login', Translations) + ']</a>') +
            '</small></td></tr></table>' +
            '<p><a href="/">[' + T('home', Translations) + ']</a> | <a href="/settings">[' + T('settings', Translations) + ']</a> | <a href="/people">[' + T('people', Translations) + ']</a></p>' +
            '<h2>' + T('image', Translations) + ': ' + HtmlEncode(ImagePath) + '</h2><hr>' +
            '<div style="text-align:center"><img src="data:' + GetMimeType(ImagePath) + ';base64,' + Base64Encode(FileContent) + '" alt="' + HtmlEncode(ExtractFileName(ImagePath)) + '"></div>' +
            '<hr><p><small>Omi Server</small></p></body></html>';
          Exit;
        end;
      end;
      AResponse.Code := 404;
      AResponse.ContentType := 'text/plain; charset=UTF-8';
      AResponse.Content := 'Image not found';
      Exit;
    end;

    if LogName <> '' then
    begin
      RepoName := NormalizeRepoName(LogName);
      LogDb := GetRepoPath(RepoName);
      LogRows := ExecSqlOnDb(LogDb, 'SELECT c.id, c.message, c.user, c.datetime, COUNT(f.id) FROM commits c LEFT JOIN files f ON c.id=f.commit_id GROUP BY c.id ORDER BY c.id DESC;');
      LogLines := LogRows.Split([#10]);
      TableRows := '';
      for I := 0 to High(LogLines) do
      begin
        if Trim(LogLines[I]) = '' then
          Continue;
        LogParts := LogLines[I].Split(['|']);
        if Length(LogParts) >= 5 then
          TableRows := TableRows + '<tr><td><strong>' + HtmlEncode(LogParts[0]) + '</strong></td><td>' + HtmlEncode(LogParts[1]) + '</td><td>' + HtmlEncode(LogParts[2]) + '</td><td>' + HtmlEncode(LogParts[3]) + '</td><td>' + HtmlEncode(LogParts[4]) + '</td></tr>';
      end;

      Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
        '<html dir="' + DirAttr + '"><head><meta charset="UTF-8"><title>' + T('commit-history', Translations) + ' - ' + HtmlEncode(RepoName) + '</title></head>' +
        '<body bgcolor="#f0f0f0" dir="' + DirAttr + '">' +
        '<table width="100%" border="0" cellpadding="5">' +
        '<tr><td><h1>' + T('commit-history', Translations) + ' - ' + HtmlEncode(RepoName) + '</h1></td><td align="right"><small>' +
        ifthen(Username <> '', '<strong>' + HtmlEncode(Username) + '</strong> | <a href="/language">[' + T('language', Translations) + ']</a> | <a href="/logout">[' + T('logout', Translations) + ']</a>', '<a href="/sign-in">[' + T('login', Translations) + ']</a>') +
        '</small></td></tr></table>' +
        '<p><a href="/">[' + T('home', Translations) + ']</a> | <a href="/settings">[' + T('settings', Translations) + ']</a> | <a href="/people">[' + T('people', Translations) + ']</a> | <a href="/' + HtmlEncode(StringReplace(RepoName, '.omi', '', [])) + '">[' + T('repository-root', Translations) + ']</a></p>' +
        '<hr>' +
        '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
        '<tr bgcolor="#333333"><th><font color="white">' + T('commit-id', Translations) + '</font></th><th><font color="white">' + T('message', Translations) + '</font></th><th><font color="white">' + T('author', Translations) + '</font></th><th><font color="white">' + T('date', Translations) + '</font></th><th><font color="white">' + T('files', Translations) + '</font></th></tr>' +
        TableRows +
        '</table>' +
        '<hr><p><small>Omi Server</small></p>' +
        '</body></html>';
      AResponse.Content := Html;
      AResponse.ContentType := 'text/html; charset=UTF-8';
      Exit;
    end;

    if FormatParam = 'json' then
    begin
      Repos := GetReposList;
      ReposJson := '';
      for I := 0 to High(Repos) do
      begin
        if ReposJson <> '' then
          ReposJson := ReposJson + ',';
        ReposJson := ReposJson + '"' + StringReplace(Repos[I].Name, '"', '\"', [rfReplaceAll]) + '"';
      end;
      JsonList := '{"repos":[' + ReposJson + ']}';
      AResponse.ContentType := 'application/json';
      AResponse.Content := JsonList;
      Exit;
    end;

    RepoMessage := '';
    RepoError := False;
    if (ARequest.Method = 'POST') then
    begin
      Action := ARequest.ContentFields.Values['action'];
      if Action = 'create_repo' then
      begin
        RepoNameInput := ARequest.ContentFields.Values['repo_name'];
        RepoName := NormalizeRepoName(RepoNameInput);
        if RepoName = '' then
        begin
          RepoMessage := T('repository-name', Translations);
          RepoError := True;
        end
        else
        begin
          RepoPath := GetRepoPath(RepoName);
          if CreateEmptyRepository(RepoPath, Username) then
            RepoMessage := T('repository-created', Translations)
          else
          begin
            RepoMessage := T('repository-create-failed', Translations);
            RepoError := True;
          end;
        end;
      end
      else if Action = T('upload', Translations) then
      begin
        if ARequest.Files.Count > 0 then
        begin
          RepoFile := ARequest.Files[0];
          RepoName := NormalizeRepoName(ARequest.ContentFields.Values['repo_name']);
          if RepoName = '' then
          begin
            RepoName := NormalizeRepoName(RepoFile.FileName);
          end;
          if RepoName = '' then
          begin
            RepoMessage := T('repository-name', Translations);
            RepoError := True;
          end
           else
           begin
             DownloadPath := GetRepoPath(RepoName);
             DownloadData := ReadFileToString(RepoFile.LocalFileName);
             if DownloadData <> '' then
             begin
               if not DirectoryExists(ExtractFileDir(DownloadPath)) then
                 ForceDirectories(ExtractFileDir(DownloadPath));
               with TFileStream.Create(DownloadPath, fmCreate) do
               try
                 WriteBuffer(DownloadData[1], Length(DownloadData));
               finally
                 Free;
               end;
               RepoMessage := T('upload', Translations) + ' OK';
             end
             else
             begin
               RepoMessage := T('upload-failed', Translations);
               RepoError := True;
             end;
           end;
         end;
       end;
    end;

    Repos := GetReposList;
    Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
      '<html dir="' + DirAttr + '"><head><meta charset="UTF-8"><title>Omi Server - ' + T('repositories', Translations) + '</title></head>' +
      '<body bgcolor="#f0f0f0" dir="' + DirAttr + '">' +
      '<table width="100%" border="0" cellpadding="5">' +
      '<tr><td><h1>Omi Server - ' + T('repositories', Translations) + '</h1></td><td align="right"><small>' +
      ifthen(Username <> '', '<strong>' + HtmlEncode(Username) + '</strong> | <a href="/language">[' + T('language', Translations) + ']</a> | <a href="/logout">[' + T('logout', Translations) + ']</a>', '<a href="/sign-in">[' + T('login', Translations) + ']</a>') +
      '</small></td></tr></table>' +
      '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
      '<tr bgcolor="#e8f4f8"><td colspan="4"><strong>' + T('server', Translations) + ':</strong> localhost<br>' +
      '<strong>' + T('protocol', Translations) + ':</strong> HTTP<br>' +
      '<strong>' + T('repositories', Translations) + ':</strong> ' + IntToStr(Length(Repos)) + '</td></tr></table>' +
      ifthen(RepoMessage <> '', '<p><font color="' + ifthen(RepoError, 'red', 'green') + '"><strong>' + HtmlEncode(RepoMessage) + '</strong></font></p>', '') +
      '<h2>' + T('available-repositories', Translations) + '</h2>' +
      '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
      '<tr bgcolor="#333333"><th><font color="white">' + T('repository', Translations) + '</font></th><th><font color="white">' + T('size-bytes', Translations) + '</font></th><th><font color="white">' + T('last-modified', Translations) + '</font></th><th><font color="white">' + T('actions', Translations) + '</font></th></tr>';

    if Length(Repos) = 0 then
      Html := Html + '<tr><td colspan="4">' + T('no-repositories', Translations) + '</td></tr>'
    else
    begin
      for I := 0 to High(Repos) do
      begin
        SizeText := IntToStr(Repos[I].Size);
        Html := Html + '<tr><td><a href="/' + HtmlEncode(StringReplace(Repos[I].Name, '.omi', '', [])) + '">' + HtmlEncode(Repos[I].Name) + '</a></td>' +
          '<td>' + HtmlEncode(SizeText) + '</td>' +
          '<td>' + HtmlEncode(FormatDateTime('yyyy-mm-dd hh:nn:ss', FileDateToDateTime(Repos[I].Modified))) + '</td>' +
          '<td><a href="?download=' + HtmlEncode(Repos[I].Name) + '">' + T('download', Translations) + '</a> | <a href="?log=' + HtmlEncode(Repos[I].Name) + '">[' + T('log', Translations) + ']</a></td></tr>';
      end;
    end;

    Html := Html + '</table>';

    if Username <> '' then
    begin
      Html := Html + '<h2>' + T('create-repository', Translations) + '</h2>' +
        '<form method="POST"><table border="0" cellpadding="5">' +
        '<tr><td>' + T('repository-name', Translations) + ':</td><td><input type="text" name="repo_name" size="30"> (e.g., wekan.omi)</td></tr>' +
        '<tr><td colspan="2"><input type="hidden" name="action" value="create_repo"><input type="submit" value="' + T('create-repository', Translations) + '"></td></tr>' +
        '</table></form>' +
        '<h2>' + T('upload-repository', Translations) + '</h2>' +
        '<form method="POST" enctype="multipart/form-data">' +
        '<table border="0" cellpadding="5">' +
        '<tr><td>' + T('repository-name', Translations) + ':</td><td><input type="text" name="repo_name" size="30"> (e.g., wekan.omi)</td></tr>' +
        '<tr><td>' + T('file', Translations) + ':</td><td><input type="file" name="repo_file"></td></tr>' +
        '<tr><td colspan="2"><input type="submit" name="action" value="' + T('upload', Translations) + '"></td></tr>' +
        '</table></form>';
    end
    else
      Html := Html + '<p><a href="/sign-in">[' + T('sign-in-to-upload', Translations) + ']</a></p>';

    Html := Html + '<h2>' + T('api-endpoints', Translations) + '</h2>' +
      '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
      '<tr><td><strong>List repos (JSON):</strong></td><td>GET /?format=json</td></tr>' +
      '<tr><td><strong>Download repo:</strong></td><td>GET /?download=wekan.omi</td></tr>' +
      '<tr><td><strong>Upload repo:</strong></td><td>POST with repo_name, repo_file</td></tr>' +
      '</table>' +
      '<hr><p><small>Omi Server</small></p>' +
      '</body></html>';

    AResponse.Content := Html;
    AResponse.ContentType := 'text/html; charset=UTF-8';
  finally
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

procedure LogoutEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  SessionId: string;
begin
  SessionId := GetCookieValue(ARequest, 'sessionId');
  if SessionId <> '' then
    Sessions.Values[SessionId] := '';
  AResponse.SetCustomHeader('Set-Cookie', 'sessionId=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly');
  AResponse.Code := 302;
  AResponse.Location := '/';
  AResponse.Content := '';
end;

procedure RegisterEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Translations: TJSONObject;
  Html: string;
  Username, Password, Password2: string;
  ErrorMsg, SuccessMsg: string;
  UsersMap: TStringList;
  BrowserLanguage: string;
  FormHtml: string;
begin
  Translations := LoadTranslations(GetBrowserLanguage(ARequest));
  try
    ErrorMsg := '';
    SuccessMsg := '';

    if ARequest.Method = 'POST' then
    begin
      Username := Trim(ARequest.ContentFields.Values['username']);
      Password := ARequest.ContentFields.Values['password'];
      Password2 := ARequest.ContentFields.Values['password2'];

      if IsUserLocked(Username) then
        ErrorMsg := T('account-locked', Translations)
      else if (Username = '') or (Password = '') then
        ErrorMsg := T('username-password-required', Translations)
      else if Password <> Password2 then
        ErrorMsg := T('password-mismatch', Translations)
      else if Length(Username) < 3 then
        ErrorMsg := T('username-too-short', Translations)
      else
      begin
        UsersMap := LoadUsersMap;
        try
          if UsersMap.Values[Username] <> '' then
            ErrorMsg := T('user-exists', Translations)
          else
          begin
            BrowserLanguage := GetBrowserLanguage(ARequest);
            UsersMap.Values[Username] := Password + USER_VALUE_SEP + '' + USER_VALUE_SEP + BrowserLanguage;
            SaveUsersMap(UsersMap);
            SuccessMsg := T('account-created', Translations);
          end;
        finally
          UsersMap.Free;
        end;
      end;
    end;

    if SuccessMsg <> '' then
      FormHtml := ''
    else
      FormHtml := '<form method="POST">' +
        '<table border="1" cellpadding="5">' +
        '<tr><td>' + T('username', Translations) + ':</td><td><input type="text" name="username" size="30" required></td></tr>' +
        '<tr><td>' + T('password', Translations) + ':</td><td><input type="password" name="password" size="30" required></td></tr>' +
        '<tr><td>' + T('confirm', Translations) + ':</td><td><input type="password" name="password2" size="30" required></td></tr>' +
        '<tr><td colspan="2"><input type="submit" value="' + T('create-account', Translations) + '"></td></tr>' +
        '</table>' +
        '</form>' +
        '<p><a href="/sign-in">' + T('already-account', Translations) + '</a></p>';

    Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
      '<html>' +
      '<head><meta charset="UTF-8"><title>' + T('create-account', Translations) + ' - Omi Server</title></head>' +
      '<body bgcolor="#f0f0f0">' +
      '<h1>Omi Server - ' + T('create-account', Translations) + '</h1>' +
      '<table border="0" cellpadding="5">' +
      '<tr><td colspan="2"><a href="/">[' + T('home', Translations) + ']</a></td></tr>' +
      '</table>' +
      (ifthen(ErrorMsg <> '', '<p><font color="red"><strong>' + T('error', Translations) + ': ' + HtmlEncode(ErrorMsg) + '</strong></font></p>', '')) +
      (ifthen(SuccessMsg <> '', '<p><font color="green"><strong>' + HtmlEncode(SuccessMsg) + '</strong></font></p><p><a href="/sign-in">' + T('login', Translations) + '</a></p>', '')) +
      FormHtml +
      '</body></html>';
    AResponse.Content := Html;
    AResponse.ContentType := 'text/html; charset=UTF-8';
  finally
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

procedure ForgotPasswordEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Translations: TJSONObject;
  Html: string;
begin
  Translations := LoadTranslations('en');
  try
    Html := '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>' + T('forgot-password', Translations) + '</title></head>' +
      '<body><h1>' + T('forgot-password', Translations) + '</h1>' +
      '<p>' + T('not-implemented', Translations) + '</p></body></html>';
    AResponse.Content := Html;
    AResponse.ContentType := 'text/html; charset=UTF-8';
  finally
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

procedure SettingsEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Translations: TJSONObject;
  Html: string;
  Username: string;
  SettingsMap: TStringList;
  SuccessMsg: string;
  ErrorMsg: string;
begin
  Username := GetUsernameFromRequest(ARequest);
  if Username = '' then
  begin
    AResponse.Code := 302;
    AResponse.Location := '/sign-in';
    AResponse.Content := '';
    Exit;
  end;

  Translations := LoadTranslations('en');
  try
    SettingsMap := LoadSettingsMap;
    try
      SuccessMsg := '';
      ErrorMsg := '';
      if ARequest.Method = 'POST' then
      begin
        if ARequest.ContentFields.Values['SQLITE'] <> '' then
          SettingsMap.Values['SQLITE'] := ARequest.ContentFields.Values['SQLITE'];
        if ARequest.ContentFields.Values['USERNAME'] <> '' then
          SettingsMap.Values['USERNAME'] := ARequest.ContentFields.Values['USERNAME'];
        if ARequest.ContentFields.Values['PASSWORD'] <> '' then
          SettingsMap.Values['PASSWORD'] := ARequest.ContentFields.Values['PASSWORD'];
        if ARequest.ContentFields.Values['REPOS'] <> '' then
          SettingsMap.Values['REPOS'] := ARequest.ContentFields.Values['REPOS'];
        if ARequest.ContentFields.Values['CURL'] <> '' then
          SettingsMap.Values['CURL'] := ARequest.ContentFields.Values['CURL'];

        if SaveSettingsMap(SettingsMap) then
          SuccessMsg := T('settings-updated', Translations)
        else
          ErrorMsg := T('settings-update-failed', Translations);
      end;

      if SettingsMap.Values['SQLITE'] = '' then
        SettingsMap.Values['SQLITE'] := 'sqlite3';
      if SettingsMap.Values['CURL'] = '' then
        SettingsMap.Values['CURL'] := 'curl';

      Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
        '<html><head><meta charset="UTF-8"><title>' + T('settings', Translations) + ' - Omi Server</title></head>' +
        '<body bgcolor="#f0f0f0">' +
        '<table width="100%" border="0" cellpadding="5">' +
        '<tr><td><h1>' + T('settings', Translations) + '</h1></td>' +
        '<td align="right"><small><strong>' + HtmlEncode(Username) + '</strong> | <a href="/language">[' + T('language', Translations) + ']</a> | <a href="/logout">[' + T('logout', Translations) + ']</a></small></td></tr>' +
        '</table>' +
        '<p><a href="/">[' + T('home', Translations) + ']</a> | <a href="/settings">[' + T('settings', Translations) + ']</a> | <a href="/people">[' + T('people', Translations) + ']</a></p>' +
        '<hr>' +
        (ifthen(SuccessMsg <> '', '<p><font color="green"><strong>' + HtmlEncode(SuccessMsg) + '</strong></font></p>', '')) +
        (ifthen(ErrorMsg <> '', '<p><font color="red"><strong>' + HtmlEncode(ErrorMsg) + '</strong></font></p>', '')) +
        '<form method="POST">' +
        '<table border="1" cellpadding="5">' +
        '<tr><td>SQLITE executable:</td><td><input type="text" name="SQLITE" size="50" value="' + HtmlEncode(SettingsMap.Values['SQLITE']) + '"></td></tr>' +
        '<tr><td>USERNAME:</td><td><input type="text" name="USERNAME" size="50" value="' + HtmlEncode(SettingsMap.Values['USERNAME']) + '"></td></tr>' +
        '<tr><td>PASSWORD:</td><td><input type="password" name="PASSWORD" size="50" value="' + HtmlEncode(SettingsMap.Values['PASSWORD']) + '"></td></tr>' +
        '<tr><td>REPOS (server URL):</td><td><input type="text" name="REPOS" size="50" value="' + HtmlEncode(SettingsMap.Values['REPOS']) + '"></td></tr>' +
        '<tr><td>CURL executable:</td><td><input type="text" name="CURL" size="50" value="' + HtmlEncode(SettingsMap.Values['CURL']) + '"></td></tr>' +
        '<tr><td colspan="2"><input type="submit" value="' + T('save', Translations) + '"></td></tr>' +
        '</table>' +
        '</form>' +
        '<hr>' +
        '<p><small>Omi Server</small></p>' +
        '</body></html>';
    finally
      SettingsMap.Free;
    end;
    AResponse.Content := Html;
    AResponse.ContentType := 'text/html; charset=UTF-8';
  finally
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

procedure LanguageEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Translations: TJSONObject;
  Html: string;
  Username: string;
  UsersMap: TStringList;
  Password, Otp, CurrentLanguage: string;
  LangData: TJSONObject;
  I: Integer;
  LangCode, LangName: string;
  LangInfo: TJSONObject;
  IsRtl: Boolean;
  SuccessMsg: string;
  UpdatedLanguage: Boolean;
  NewLanguage: string;
  FormHtml: string;
begin
  Username := GetUsernameFromRequest(ARequest);
  if Username = '' then
  begin
    AResponse.Code := 302;
    AResponse.Location := '/sign-in';
    AResponse.Content := '';
    Exit;
  end;

  UsersMap := LoadUsersMap;
  SuccessMsg := '';
  UpdatedLanguage := False;
  NewLanguage := '';
  try
    if not GetUserData(UsersMap, Username, Password, Otp, CurrentLanguage) then
      CurrentLanguage := 'en';

    if ARequest.Method = 'POST' then
    begin
      if ARequest.ContentFields.Values['language'] <> '' then
      begin
        NewLanguage := ARequest.ContentFields.Values['language'];
        CurrentLanguage := NewLanguage;
        UsersMap.Values[Username] := Password + USER_VALUE_SEP + Otp + USER_VALUE_SEP + CurrentLanguage;
        SaveUsersMap(UsersMap);
        UpdatedLanguage := True;
      end;
    end;
  finally
    UsersMap.Free;
  end;

  Translations := LoadTranslations(CurrentLanguage);
  try
    if UpdatedLanguage then
      SuccessMsg := T('language-updated', Translations);

    LangData := LoadLanguagesData;
    try
      FormHtml := '<form method="POST"><table border="1" cellpadding="5">' +
        '<tr bgcolor="#333333"><th><font color="white">Language</font></th></tr>';

      for I := 0 to LangData.Count - 1 do
      begin
        LangCode := LangData.Names[I];
        LangInfo := TJSONObject(LangData.Items[I]);
        LangName := JsonGetString(LangInfo, 'name', LangCode);
        IsRtl := JsonGetBool(LangInfo, 'rtl', False);
        FormHtml := FormHtml + '<tr><td><input type="radio" name="language" value="' + HtmlEncode(LangCode) + '"' +
          ifthen(CurrentLanguage = LangCode, ' checked', '') + '> ' + HtmlEncode(LangName) + ' (' + HtmlEncode(LangCode) + ')' +
          ifthen(IsRtl, ' (RTL)', '') + '</td></tr>';
      end;

      FormHtml := FormHtml + '</table><br>' +
        '<input type="submit" value="' + T('save-language', Translations) + '">' +
        '</form>';

      Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
        '<html>' +
        '<head><meta charset="UTF-8"><title>' + T('language-selection', Translations) + ' - Omi Server</title></head>' +
        '<body bgcolor="#f0f0f0">' +
        '<table width="100%" border="0" cellpadding="5">' +
        '<tr><td><h1>Omi Server</h1></td><td align="right"><small><strong>' + HtmlEncode(Username) + '</strong> | <a href="/language">[' + T('language', Translations) + ']</a> | <a href="/logout">[' + T('logout', Translations) + ']</a></small></td></tr>' +
        '</table>' +
        '<p><a href="/">[' + T('home', Translations) + ']</a> | <a href="/people">[' + T('people', Translations) + ']</a> | <a href="/settings">[' + T('settings', Translations) + ']</a></p>' +
        '<hr>' +
        '<h2>' + T('select-language', Translations) + '</h2>' +
        (ifthen(SuccessMsg <> '', '<p><font color="green"><strong>' + HtmlEncode(SuccessMsg) + '</strong></font></p>', '')) +
        FormHtml +
        '<hr>' +
        '<p><small>Omi Server</small></p>' +
        '</body></html>';
    finally
      LangData.Free;
    end;
    AResponse.Content := Html;
    AResponse.ContentType := 'text/html; charset=UTF-8';
  finally
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

procedure PeopleEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Translations: TJSONObject;
  Html: string;
  Username: string;
  UsersMap: TStringList;
  I: Integer;
  UserKey: string;
  Password, Otp, Language: string;
  Action: string;
  SuccessMsg: string;
  ErrorMsg: string;
  NewUser, NewPass: string;
  UpUser, UpPass: string;
  DelUser: string;
  OtpUser: string;
  EmailValue: string;
  Secret: string;
  OtpUrl: string;
  UsersTable: string;
  EditSections: string;
  OtpSections: string;
  SelfUser: string;

  function GenerateSecret(LengthValue: Integer): string;
  const
    Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var
    J: Integer;
  begin
    Result := '';
    Randomize;
    for J := 1 to LengthValue do
      Result := Result + Chars[Random(32) + 1];
  end;

begin
  Username := GetUsernameFromRequest(ARequest);
  if Username = '' then
  begin
    AResponse.Code := 302;
    AResponse.Location := '/sign-in';
    AResponse.Content := '';
    Exit;
  end;

  Translations := LoadTranslations('en');
  UsersMap := LoadUsersMap;
  try
    SuccessMsg := '';
    ErrorMsg := '';
    Action := ARequest.ContentFields.Values['action'];

    if (ARequest.Method = 'POST') and (Action <> '') then
    begin
      if Action = 'add' then
      begin
        NewUser := Trim(ARequest.ContentFields.Values['newuser']);
        NewPass := ARequest.ContentFields.Values['newpass'];
        if (NewUser <> '') and (NewPass <> '') then
        begin
          if UsersMap.Values[NewUser] = '' then
          begin
            UsersMap.Values[NewUser] := NewPass + USER_VALUE_SEP + '' + USER_VALUE_SEP + 'en';
            SaveUsersMap(UsersMap);
            SuccessMsg := 'User added successfully';
          end
          else
            ErrorMsg := 'User already exists';
        end
        else
          ErrorMsg := 'Username and password are required';
      end
      else if Action = 'delete' then
      begin
        DelUser := ARequest.ContentFields.Values['deluser'];
        if UsersMap.Values[DelUser] <> '' then
        begin
          UsersMap.Values[DelUser] := '';
          SaveUsersMap(UsersMap);
          SuccessMsg := 'User deleted successfully';
        end
        else
          ErrorMsg := 'User not found';
      end
      else if Action = 'update' then
      begin
        UpUser := ARequest.ContentFields.Values['upuser'];
        UpPass := ARequest.ContentFields.Values['uppass'];
        if (UpUser <> '') and (UpPass <> '') and GetUserData(UsersMap, UpUser, Password, Otp, Language) then
        begin
          UsersMap.Values[UpUser] := UpPass + USER_VALUE_SEP + Otp + USER_VALUE_SEP + Language;
          SaveUsersMap(UsersMap);
          SuccessMsg := 'User updated successfully';
        end
        else
          ErrorMsg := 'Failed to update user';
      end
      else if Action = 'enable_otp' then
      begin
        OtpUser := ARequest.ContentFields.Values['otpuser'];
        EmailValue := ARequest.ContentFields.Values['email'];
        if GetUserData(UsersMap, OtpUser, Password, Otp, Language) then
        begin
          Secret := GenerateSecret(32);
          if EmailValue = '' then
            EmailValue := OtpUser;
          OtpUrl := 'otpauth://totp/Omi (' + EmailValue + '):' + EmailValue + '?secret=' + Secret + '&issuer=omi&digits=6&period=30';
          UsersMap.Values[OtpUser] := Password + USER_VALUE_SEP + OtpUrl + USER_VALUE_SEP + Language;
          SaveUsersMap(UsersMap);
          SuccessMsg := 'OTP enabled successfully';
        end
        else
          ErrorMsg := 'Failed to enable OTP';
      end
      else if Action = 'disable_otp' then
      begin
        OtpUser := ARequest.ContentFields.Values['otpuser'];
        if GetUserData(UsersMap, OtpUser, Password, Otp, Language) then
        begin
          UsersMap.Values[OtpUser] := Password + USER_VALUE_SEP + '' + USER_VALUE_SEP + Language;
          SaveUsersMap(UsersMap);
          SuccessMsg := 'OTP disabled successfully';
        end
        else
          ErrorMsg := 'Failed to disable OTP';
      end;
    end;

    UsersTable := '';
    EditSections := '';
    OtpSections := '';

    for I := 0 to UsersMap.Count - 1 do
    begin
      UserKey := UsersMap.Names[I];
      if UserKey = '' then
        Continue;
      if not GetUserData(UsersMap, UserKey, Password, Otp, Language) then
        Continue;

      UsersTable := UsersTable + '<tr><td>' + HtmlEncode(UserKey) + '</td>' +
        '<td>' + ifthen(Otp <> '', '<font color="green">✓ ' + T('enabled', Translations) + '</font>', '<font color="gray">' + T('disabled', Translations) + '</font>') + '</td>' +
        '<td><form method="POST" style="display:inline">' +
        '<input type="hidden" name="action" value="delete">' +
        '<input type="hidden" name="deluser" value="' + HtmlEncode(UserKey) + '">' +
        '<input type="submit" value="' + T('delete', Translations) + '" onclick="return confirm(''Delete user ' + HtmlEncode(UserKey) + ' ?'')"></form> | ' +
        '<a href="#" onclick="document.getElementById(''edit_' + HtmlEncode(UserKey) + ''').style.display=''block''; return false;">[' + T('edit', Translations) + ']</a>' +
        (ifthen(UserKey = Username, ' | <a href="#" onclick="document.getElementById(''otp_' + HtmlEncode(UserKey) + ''').style.display=''block''; return false;">[' + T('otp', Translations) + ']</a>', '')) +
        '</td></tr>';

      EditSections := EditSections + '<div id="edit_' + HtmlEncode(UserKey) + '" style="display:none;border:1px solid #ccc;padding:10px;margin:10px 0">' +
        '<form method="POST"><table border="0" cellpadding="5">' +
        '<tr><td>' + T('username', Translations) + ':</td><td><strong>' + HtmlEncode(UserKey) + '</strong></td></tr>' +
        '<tr><td>' + T('new-password', Translations) + ':</td><td><input type="password" name="uppass" size="30" required></td></tr>' +
        '<tr><td colspan="2"><input type="hidden" name="action" value="update">' +
        '<input type="hidden" name="upuser" value="' + HtmlEncode(UserKey) + '">' +
        '<input type="submit" value="' + T('update', Translations) + '"> | ' +
        '<a href="#" onclick="document.getElementById(''edit_' + HtmlEncode(UserKey) + ''').style.display=''none''; return false;">[' + T('cancel', Translations) + ']</a></td></tr>' +
        '</table></form></div>';

      if UserKey = Username then
      begin
        if Otp = '' then
          OtpSections := OtpSections + '<div id="otp_' + HtmlEncode(UserKey) + '" style="display:none;border:1px solid #ccc;padding:10px;margin:10px 0">' +
            '<h3>' + T('otp-for-user', Translations) + ': ' + HtmlEncode(UserKey) + '</h3>' +
            '<form method="POST"><table border="0" cellpadding="5">' +
            '<tr><td>' + T('email-optional', Translations) + ':</td><td><input type="text" name="email" size="30" value="' + HtmlEncode(UserKey) + '"></td></tr>' +
            '<tr><td colspan="2"><small>' + T('otp-email-help', Translations) + '</small></td></tr>' +
            '<tr><td colspan="2"><input type="hidden" name="action" value="enable_otp">' +
            '<input type="hidden" name="otpuser" value="' + HtmlEncode(UserKey) + '">' +
            '<input type="submit" value="' + T('enable-otp', Translations) + '"></td></tr>' +
            '</table></form><p><a href="#" onclick="document.getElementById(''otp_' + HtmlEncode(UserKey) + ''').style.display=''none''; return false;">[' + T('close', Translations) + ']</a></p></div>'
        else
          OtpSections := OtpSections + '<div id="otp_' + HtmlEncode(UserKey) + '" style="display:none;border:1px solid #ccc;padding:10px;margin:10px 0">' +
            '<h3>' + T('otp-for-user', Translations) + ': ' + HtmlEncode(UserKey) + '</h3>' +
            '<p><font color="green">✓ ' + T('otp-enabled', Translations) + '</font></p>' +
            '<p><small>' + T('otp-url-stored', Translations) + '</small></p>' +
            '<form method="POST" style="display:inline">' +
            '<input type="hidden" name="action" value="disable_otp">' +
            '<input type="hidden" name="otpuser" value="' + HtmlEncode(UserKey) + '">' +
            '<input type="submit" value="' + T('disable-otp', Translations) + '"></form>' +
            '<p><a href="#" onclick="document.getElementById(''otp_' + HtmlEncode(UserKey) + ''').style.display=''none''; return false;">[' + T('close', Translations) + ']</a></p></div>';
      end;
    end;

    Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
      '<html><head><meta charset="UTF-8"><title>' + T('people', Translations) + ' - Omi Server</title></head>' +
      '<body bgcolor="#f0f0f0">' +
      '<table width="100%" border="0" cellpadding="5">' +
      '<tr><td><h1>' + T('user-management', Translations) + '</h1></td><td align="right"><small><strong>' + HtmlEncode(Username) + '</strong> | <a href="/language">[' + T('language', Translations) + ']</a> | <a href="/logout">[' + T('logout', Translations) + ']</a></small></td></tr>' +
      '</table>' +
      '<p><a href="/">[' + T('home', Translations) + ']</a> | <a href="/settings">[' + T('settings', Translations) + ']</a> | <a href="/people">[' + T('people', Translations) + ']</a></p>' +
      '<hr>' +
      ifthen(SuccessMsg <> '', '<p><font color="green"><strong>' + HtmlEncode(SuccessMsg) + '</strong></font></p>', '') +
      ifthen(ErrorMsg <> '', '<p><font color="red"><strong>' + HtmlEncode(ErrorMsg) + '</strong></font></p>', '') +
      '<h2>' + T('manage-users', Translations) + '</h2>' +
      '<table border="1" cellpadding="5" width="100%">' +
      '<tr bgcolor="#333333"><th><font color="white">' + T('username', Translations) + '</font></th><th><font color="white">' + T('otp-status', Translations) + '</font></th><th><font color="white">' + T('actions', Translations) + '</font></th></tr>' +
      UsersTable +
      '</table>' +
      '<h2>' + T('add-new-user', Translations) + '</h2>' +
      '<form method="POST"><table border="0" cellpadding="5">' +
      '<tr><td>' + T('username', Translations) + ':</td><td><input type="text" name="newuser" size="30" required></td></tr>' +
      '<tr><td>' + T('password', Translations) + ':</td><td><input type="password" name="newpass" size="30" required></td></tr>' +
      '<tr><td colspan="2"><input type="hidden" name="action" value="add"><input type="submit" value="' + T('add-user', Translations) + '"></td></tr>' +
      '</table></form>' +
      '<h2>' + T('edit-user-password', Translations) + '</h2>' +
      EditSections +
      '<h2>' + T('manage-otp', Translations) + '</h2>' +
      OtpSections +
      '<hr><p><small>Omi Server</small></p>' +
      '</body></html>';

    AResponse.Content := Html;
    AResponse.ContentType := 'text/html; charset=UTF-8';
  finally
    UsersMap.Free;
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

procedure RepoEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Translations: TJSONObject;
  Html: string;
  PathInfo: string;
  Parts: TStringArray;
  RepoName: string;
  RepoPath: string;
  DbPath: string;
  Files: TFileEntryArray;
  I: Integer;
  FileEntry: TFileEntry;
  IsFile: Boolean;
  FileContent: string;
  FileHash: string;
  Username: string;
  IsText: Boolean;
  InEdit: Boolean;
  ShowDeleteConfirm: Boolean;
  SuccessMsg: string;
  ErrorMsg: string;
  DownloadFlag: string;
  DeleteFlag: string;
  EditFlag: string;
  UploadMsg: string;
  UploadError: string;
  Action: string;
  Target: string;
  NewName: string;
  DirName: string;
  FileName: string;
  FileData: string;
  UploadFile: TUploadedFile;
  RepoRootLink: string;
  DirList: TStringList;
  FileList: TStringList;
  Relative: string;
  SlashPos: Integer;
  ParentPath: string;
  TableRows: string;
  EntryPath: string;
  DisplayName: string;
  RowActions: string;
  NewContent: string;
  MarkdownHtml: string;
  Base64Data: string;
  MimeType: string;
  IsMarkdown: Boolean;
  IsImage: Boolean;
  DirHeader: string;

  function RepoToRoot(const Name: string): string;
  begin
    Result := '/' + StringReplace(Name, '.omi', '', []);
  end;

begin
  PathInfo := ARequest.PathInfo;
  if (PathInfo = '/') or (PathInfo = '') then
    Exit;

  Parts := PathInfo.Split(['/']);
  if Length(Parts) < 2 then
  begin
    AResponse.Code := 404;
    AResponse.Content := 'Not found';
    Exit;
  end;

  RepoName := NormalizeRepoName(Parts[1]);
  if RepoName = '' then
  begin
    AResponse.Code := 404;
    AResponse.Content := 'Repository not found';
    Exit;
  end;

  RepoPath := '';
  if Length(Parts) > 2 then
  begin
    RepoPath := '';
    for I := 2 to High(Parts) do
    begin
      if Parts[I] = '' then
        Continue;
      if RepoPath <> '' then
        RepoPath := RepoPath + '/';
      RepoPath := RepoPath + Parts[I];
    end;
  end;

  DbPath := GetRepoPath(RepoName);
  if not FileExists(DbPath) then
  begin
    AResponse.Code := 404;
    AResponse.Content := 'Repository not found';
    Exit;
  end;

  Username := GetUsernameFromRequest(ARequest);
  Translations := LoadTranslations('en');
  try
    DownloadFlag := ARequest.QueryFields.Values['download'];
    DeleteFlag := ARequest.QueryFields.Values['delete'];
    EditFlag := ARequest.QueryFields.Values['edit'];

    Files := GetLatestFiles(DbPath, RepoPath);
    IsFile := False;
    FileHash := '';

    for I := 0 to High(Files) do
    begin
      if Files[I].Filename = RepoPath then
      begin
        IsFile := True;
        FileHash := Files[I].Hash;
        FileEntry := Files[I];
        Break;
      end;
    end;

    SuccessMsg := '';
    ErrorMsg := '';
    UploadMsg := '';
    UploadError := '';

    if IsFile then
    begin
      if DownloadFlag = '1' then
      begin
        FileContent := GetFileContentByHash(DbPath, FileHash);
        AResponse.ContentType := 'application/octet-stream';
        AResponse.Content := FileContent;
        AResponse.CustomHeaders.Values['Content-Disposition'] := 'attachment; filename="' + HtmlEncode(ExtractFileName(RepoPath)) + '"';
        Exit;
      end;

      if (ARequest.Method = 'POST') and (ARequest.ContentFields.Values['delete_confirm'] = '1') and (Username <> '') then
      begin
        if DeleteFileFromRepo(DbPath, RepoPath, Username) then
        begin
          AResponse.Code := 302;
          AResponse.Location := RepoToRoot(RepoName);
          AResponse.Content := '';
          Exit;
        end
        else
          ErrorMsg := T('file-delete-failed', Translations);
      end;

      ShowDeleteConfirm := (DeleteFlag = '1') and (Username <> '');

      FileContent := GetFileContentByHash(DbPath, FileHash);
      IsText := IsTextContent(FileContent);
      InEdit := (EditFlag = '1') and (Username <> '') and IsText;

      if (ARequest.Method = 'POST') and (ARequest.ContentFields.Values['save_file'] <> '') and IsText and (Username <> '') then
      begin
        NewContent := ARequest.ContentFields.Values['file_content'];
        if CommitFile(DbPath, RepoPath, NewContent, Username, 'Edit file') then
        begin
          FileContent := NewContent;
          SuccessMsg := T('file-saved-success', Translations);
        end
        else
          ErrorMsg := T('file-save-failed', Translations);
      end;

      Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
        '<html><head><meta charset="UTF-8"><title>' + T('file', Translations) + ': ' + HtmlEncode(RepoPath) + ' - ' + HtmlEncode(RepoName) + '</title></head>' +
        '<body bgcolor="#f0f0f0">' +
        '<table width="100%" border="0" cellpadding="5">' +
        '<tr><td><h1>' + HtmlEncode(RepoName) + '</h1></td><td align="right"><small>' +
        ifthen(Username <> '', '<strong>' + HtmlEncode(Username) + '</strong> | <a href="/language">[' + T('language', Translations) + ']</a> | <a href="/logout">[' + T('logout', Translations) + ']</a>', '<a href="/sign-in">[' + T('login', Translations) + ']</a>') +
        '</small></td></tr></table>' +
        '<p><a href="/">[' + T('home', Translations) + ']</a> | <a href="?log=' + HtmlEncode(RepoName) + '">[' + T('log', Translations) + ']</a> | <a href="' + RepoToRoot(RepoName) + '">[' + T('repository-root', Translations) + ']</a></p>' +
        '<h2>' + T('file', Translations) + ': ' + HtmlEncode(RepoPath) + '</h2>';

      if ShowDeleteConfirm then
      begin
        Html := Html + '<div style="border:2px solid #ff0000; padding:10px; background-color:#ffcccc;">' +
          '<p><font color="red"><strong>⚠️ ' + T('confirm-delete', Translations) + '</strong></font></p>' +
          '<p>' + T('delete-file-question', Translations) + ' <strong>' + HtmlEncode(RepoPath) + '</strong>?</p>' +
          '<p>' + T('delete-file-warning', Translations) + '</p>' +
          '<form method="POST"><input type="hidden" name="delete_confirm" value="1">' +
          '<input type="submit" value="' + T('confirm-delete', Translations) + '"> | <a href="?">[' + T('cancel', Translations) + ']</a></form>' +
          '</div><hr>';
      end
      else
      begin
        if Username <> '' then
        begin
          Html := Html + '<div style="display:flex; align-items:center; justify-content:space-between; gap:12px;">' +
            '<div><form method="GET" style="display:inline"><input type="submit" formaction="?download=1" value="' + T('download', Translations) + '"></form>' +
            ifthen(IsText, '<form method="GET" style="display:inline"><input type="hidden" name="edit" value="1"><input type="submit" value="' + T('edit', Translations) + '"></form>', '') +
            '</div><div><form method="GET" style="display:inline"><input type="hidden" name="delete" value="1"><input type="submit" value="' + T('delete', Translations) + '"></form></div></div>';
        end;
      end;

      if SuccessMsg <> '' then
        Html := Html + '<p><font color="green"><strong>' + HtmlEncode(SuccessMsg) + '</strong></font></p>';
      if ErrorMsg <> '' then
        Html := Html + '<p><font color="red"><strong>' + HtmlEncode(ErrorMsg) + '</strong></font></p>';

      Html := Html + '<hr>';

      if InEdit then
      begin
        Html := Html + '<form method="POST">' +
          '<textarea name="file_content" rows="20" cols="80" style="width:100%; max-width:800px; font-family:monospace; box-sizing:border-box;">' + HtmlEncode(FileContent) + '</textarea><br><br>' +
          '<input type="submit" name="save_file" value="Save"> ' +
          '<input type="submit" formaction="?" formmethod="GET" value="Cancel">' +
          '</form>';
      end
      else if IsText then
      begin
        IsMarkdown := IsMarkdownFile(RepoPath);
        IsImage := IsImageFile(RepoPath);
        if IsMarkdown then
        begin
          MarkdownHtml := MarkdownToHtml(FileContent);
          Html := Html + '<div style="font-family: Arial, sans-serif; line-height: 1.6;">' + MarkdownHtml + '</div>';
        end
        else if IsImage then
        begin
          Base64Data := Base64Encode(FileContent);
          MimeType := GetMimeType(RepoPath);
          Html := Html + '<div style="border:1px solid #ccc; padding:10px; background-color:white; display:inline-block;">' +
            '<img src="data:' + MimeType + ';base64,' + Base64Data + '" alt="' + HtmlEncode(ExtractFileName(RepoPath)) + '" style="max-width:100%; height:auto; max-height:500px;">' +
            '</div>';
        end
        else
          Html := Html + '<pre>' + HtmlEncode(FileContent) + '</pre>';
      end
      else
      begin
        if IsImageFile(RepoPath) then
        begin
          Base64Data := Base64Encode(FileContent);
          MimeType := GetMimeType(RepoPath);
          Html := Html + '<div style="border:1px solid #ccc; padding:10px; background-color:white; display:inline-block;">' +
            '<img src="data:' + MimeType + ';base64,' + Base64Data + '" alt="' + HtmlEncode(ExtractFileName(RepoPath)) + '" style="max-width:100%; height:auto; max-height:500px;">' +
            '</div>';
        end
        else
          Html := Html + '<p><strong>Binary file (' + IntToStr(Length(FileContent)) + ' bytes)</strong></p>';
      end;

      Html := Html + '<hr><p><small>Omi Server</small></p></body></html>';
      AResponse.Content := Html;
      AResponse.ContentType := 'text/html; charset=UTF-8';
      Exit;
    end;

    DirList := TStringList.Create;
    FileList := TStringList.Create;
    try
      DirList.Sorted := True;
      DirList.Duplicates := dupIgnore;
      FileList.Sorted := True;
      FileList.Duplicates := dupIgnore;

      for I := 0 to High(Files) do
      begin
        Relative := Files[I].Filename;
        if RepoPath <> '' then
        begin
          if Pos(RepoPath + '/', Relative) = 1 then
            Relative := Copy(Relative, Length(RepoPath) + 2, Length(Relative));
        end;
        SlashPos := Pos('/', Relative);
        if SlashPos > 0 then
          DirList.Add(Copy(Relative, 1, SlashPos - 1))
        else if Relative <> '' then
          FileList.Add(Relative);
      end;

      if (ARequest.Method = 'POST') and (Username <> '') then
      begin
        Action := ARequest.ContentFields.Values['action'];
        if Action = 'delete_file' then
        begin
          Target := SanitizePathSegment(ARequest.ContentFields.Values['target']);
          EntryPath := RepoPath;
          if EntryPath <> '' then
            EntryPath := EntryPath + '/' + Target
          else
            EntryPath := Target;
          if DeleteFileFromRepo(DbPath, EntryPath, Username) then
            UploadMsg := 'File deleted'
          else
            UploadError := T('file-delete-failed', Translations);
        end
        else if Action = 'rename_file' then
        begin
          Target := SanitizePathSegment(ARequest.ContentFields.Values['target']);
          NewName := SanitizePathSegment(ARequest.ContentFields.Values['new_name']);
          if (Target <> '') and (NewName <> '') then
          begin
            EntryPath := RepoPath;
            if EntryPath <> '' then
              EntryPath := EntryPath + '/' + Target
            else
              EntryPath := Target;
            if RepoPath <> '' then
              NewName := RepoPath + '/' + NewName;
            if RenameFileInRepo(DbPath, EntryPath, NewName, Username) then
              UploadMsg := 'File renamed'
            else
              UploadError := 'Failed to rename file';
          end
          else
            UploadError := 'File name and new name are required';
        end
        else if Action = 'create_dir' then
        begin
          DirName := SanitizePathSegment(ARequest.ContentFields.Values['dir_name']);
          if DirName <> '' then
          begin
            EntryPath := RepoPath;
            if EntryPath <> '' then
              EntryPath := EntryPath + '/' + DirName + '/.omidir'
            else
              EntryPath := DirName + '/.omidir';
            if CommitFile(DbPath, EntryPath, '', Username, 'Create directory') then
              UploadMsg := 'Directory created'
            else
              UploadError := 'Failed to create directory';
          end
          else
            UploadError := 'Directory name is required';
        end
        else if Action = 'create_file' then
        begin
          FileName := SanitizePathSegment(ARequest.ContentFields.Values['file_name']);
          FileData := ARequest.ContentFields.Values['file_content'];
          if FileName <> '' then
          begin
            EntryPath := RepoPath;
            if EntryPath <> '' then
              EntryPath := EntryPath + '/' + FileName
            else
              EntryPath := FileName;
            if CommitFile(DbPath, EntryPath, FileData, Username, 'Create file') then
              UploadMsg := 'File created'
            else
              UploadError := 'Failed to create file';
          end
          else
            UploadError := 'File name is required';
        end
        else if (ARequest.Files.Count > 0) then
        begin
          UploadFile := ARequest.Files[0];
          FileName := SanitizePathSegment(UploadFile.FileName);
          if FileName <> '' then
          begin
            EntryPath := RepoPath;
            if EntryPath <> '' then
              EntryPath := EntryPath + '/' + FileName
            else
              EntryPath := FileName;
            FileData := ReadFileToString(UploadFile.LocalFileName);
            if CommitFile(DbPath, EntryPath, FileData, Username, 'Upload file') then
              UploadMsg := 'File uploaded successfully'
            else
              UploadError := 'Failed to upload file';
          end
          else
            UploadError := 'Invalid filename';
        end;

        Files := GetLatestFiles(DbPath, RepoPath);
      end;

      TableRows := '';

      if RepoPath <> '' then
      begin
        ParentPath := ExtractFileDir(RepoPath);
        if ParentPath = '.' then
          ParentPath := '';
        RepoRootLink := RepoToRoot(RepoName);
        if ParentPath <> '' then
          RepoRootLink := RepoRootLink + '/' + ParentPath;
        TableRows := TableRows + '<tr><td><a href="' + RepoRootLink + '">' + T('directory', Translations) + ' ..</a></td><td>-</td><td>-</td><td>-</td></tr>';
      end;

      for I := 0 to DirList.Count - 1 do
      begin
        DisplayName := DirList[I];
        EntryPath := RepoToRoot(RepoName);
        if RepoPath <> '' then
          EntryPath := EntryPath + '/' + RepoPath;
        EntryPath := EntryPath + '/' + DisplayName;
        TableRows := TableRows + '<tr><td><a href="' + EntryPath + '">' + T('directory', Translations) + ' ' + HtmlEncode(DisplayName) + '/</a></td><td>-</td><td>-</td><td>-</td></tr>';
      end;

      for I := 0 to FileList.Count - 1 do
      begin
        DisplayName := FileList[I];
        EntryPath := RepoToRoot(RepoName);
        if RepoPath <> '' then
          EntryPath := EntryPath + '/' + RepoPath;
        EntryPath := EntryPath + '/' + DisplayName;
        RowActions := '-';
        if Username <> '' then
        begin
          RowActions := '<div style="display:flex; align-items:center; justify-content:space-between; gap:12px;">' +
            '<div>' +
            '<form method="GET" action="' + EntryPath + '" style="display:inline">' +
            '<input type="hidden" name="edit" value="1">' +
            '<input type="submit" value="' + T('edit', Translations) + '"></form> ' +
            '<form method="POST" style="display:inline">' +
            '<input type="hidden" name="action" value="rename_file">' +
            '<input type="hidden" name="target" value="' + HtmlEncode(DisplayName) + '">' +
            '<input type="text" name="new_name" size="12" placeholder="' + T('new-name', Translations) + '">' +
            '<input type="submit" value="' + T('rename', Translations) + '"></form>' +
            '</div>' +
            '<div>' +
            '<form method="POST" style="display:inline">' +
            '<input type="hidden" name="action" value="delete_file">' +
            '<input type="hidden" name="target" value="' + HtmlEncode(DisplayName) + '">' +
            '<input type="submit" value="' + T('delete', Translations) + '"></form>' +
            '</div>' +
            '</div>';
        end;
        TableRows := TableRows + '<tr><td><a href="' + EntryPath + '">[' + HtmlEncode(GetFileTypeLabel(DisplayName)) + '] ' + HtmlEncode(DisplayName) + '</a></td><td>-</td><td>-</td><td>' + RowActions + '</td></tr>';
      end;

      if TableRows = '' then
        TableRows := '<tr><td colspan="4">' + T('no-files-directory', Translations) + '</td></tr>';

      DirHeader := RepoPath;
      if DirHeader = '' then
        DirHeader := T('root', Translations);

      Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
        '<html><head><title>' + HtmlEncode(RepoPath) + ' - ' + HtmlEncode(RepoName) + '</title></head>' +
        '<body bgcolor="#f0f0f0">' +
        '<table width="100%" border="0" cellpadding="5">' +
        '<tr><td><h1>' + HtmlEncode(RepoName) + '</h1></td><td align="right"><small>' +
        ifthen(Username <> '', '<strong>' + HtmlEncode(Username) + '</strong> | <a href="/language">[' + T('language', Translations) + ']</a> | <a href="/logout">[' + T('logout', Translations) + ']</a>', '<a href="/sign-in">[' + T('login', Translations) + ']</a>') +
        '</small></td></tr></table>' +
        '<p><a href="/">[' + T('home', Translations) + ']</a> | <a href="?log=' + HtmlEncode(RepoName) + '">[' + T('log', Translations) + ']</a></p>' +
        '<h2>' + T('directory', Translations) + ': /' + HtmlEncode(RepoPath) + '</h2>' +
        '<hr>' +
        '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
        '<tr bgcolor="#333333"><th><font color="white">' + T('name', Translations) + '</font></th><th><font color="white">' + T('size', Translations) + '</font></th><th><font color="white">' + T('last-modified', Translations) + '</font></th><th><font color="white">' + T('actions', Translations) + '</font></th></tr>' +
        TableRows +
        '</table>' +
        '<hr>' +
        ifthen(UploadMsg <> '', '<p><font color="green"><strong>' + HtmlEncode(UploadMsg) + '</strong></font></p>', '') +
        ifthen(UploadError <> '', '<p><font color="red"><strong>' + HtmlEncode(UploadError) + '</strong></font></p>', '') +
        ifthen(Username <> '',
          '<p><b>' + T('create-directory', Translations) + '</b></p>' +
          '<form method="POST"><input type="text" name="dir_name" size="30" placeholder="new-folder">' +
          '<input type="hidden" name="action" value="create_dir">' +
          '<input type="submit" value="' + T('create-directory', Translations) + '"></form>' +
          '<p><b>' + T('create-text-file', Translations) + '</b></p>' +
          '<form method="POST"><input type="text" name="file_name" size="30" placeholder="notes.txt"><br>' +
          '<textarea name="file_content" rows="6" cols="60" placeholder="' + T('write-file-contents', Translations) + '"></textarea><br>' +
          '<input type="hidden" name="action" value="create_file">' +
          '<input type="submit" value="' + T('create-file', Translations) + '"></form>' +
          '<p><b>' + T('upload-file-directory', Translations) + '</b></p>' +
          '<form method="POST" enctype="multipart/form-data">' +
          '<input type="file" name="upload_file" required>' +
          '<input type="submit" value="' + T('upload', Translations) + '"></form>',
          '<p><small><a href="/sign-in">[' + T('login', Translations) + ']</a> ' + T('login-to-upload-files', Translations) + '</small></p>') +
        '<hr><p><small>Omi Server</small></p>' +
        '</body></html>';

      AResponse.Content := Html;
      AResponse.ContentType := 'text/html; charset=UTF-8';
    finally
      DirList.Free;
      FileList.Free;
    end;
  finally
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

begin
  Settings := LoadSettings;
  Users := TStringList.Create;
  Sessions := TStringList.Create;
  Sessions.NameValueSeparator := '=';

  WriteLn('Omi Server v', VERSION);
  WriteLn('Port: ', Settings.Port);
  WriteLn('SQLite: ', Settings.SqliteCmd);
  WriteLn('Users file: ', DataPath(USERS_FILE));
  WriteLn('Repos dir: ', DataPath(REPOS_DIR));
  WriteLn('');

  Application.Port := Settings.Port;
  Application.Threaded := True;

  HTTPRouter.RegisterRoute('/', rmGet, @HomeEndpoint);
  HTTPRouter.RegisterRoute('/', rmPost, @HomeEndpoint);
  HTTPRouter.RegisterRoute('/logout', rmGet, @LogoutEndpoint);
  HTTPRouter.RegisterRoute('/logout', rmPost, @LogoutEndpoint);
  HTTPRouter.RegisterRoute('/sign-in', rmGet, @LoginEndpoint);
  HTTPRouter.RegisterRoute('/sign-in', rmPost, @LoginEndpoint);
  HTTPRouter.RegisterRoute('/sign-up', rmGet, @RegisterEndpoint);
  HTTPRouter.RegisterRoute('/sign-up', rmPost, @RegisterEndpoint);
  HTTPRouter.RegisterRoute('/forgot-password', rmGet, @ForgotPasswordEndpoint);
  HTTPRouter.RegisterRoute('/forgot-password', rmPost, @ForgotPasswordEndpoint);
  HTTPRouter.RegisterRoute('/settings', rmGet, @SettingsEndpoint);
  HTTPRouter.RegisterRoute('/settings', rmPost, @SettingsEndpoint);
  HTTPRouter.RegisterRoute('/language', rmGet, @LanguageEndpoint);
  HTTPRouter.RegisterRoute('/language', rmPost, @LanguageEndpoint);
  HTTPRouter.RegisterRoute('/people', rmGet, @PeopleEndpoint);
  HTTPRouter.RegisterRoute('/people', rmPost, @PeopleEndpoint);
  HTTPRouter.RegisterRoute('/*', rmGet, @RepoEndpoint);
  HTTPRouter.RegisterRoute('/*', rmPost, @RepoEndpoint);

  Application.Initialize;
  Application.Run;

  Users.Free;
  Sessions.Free;
end.
