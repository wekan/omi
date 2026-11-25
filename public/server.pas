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
// The embedded SQLite: build/sqlite3.o, or on the Amiga public/omiamiga.pas's
// m68k objects (releases/amiga/build.sh).
{$IF not DEFINED(OMI_NO_SQLITE_LINK) and not DEFINED(HASAMIGA)}
{$LINK ../build/sqlite3.o}
{$ENDIF}
// No threads on the Amiga unless the build asks for them (-dOMI_THREADS, with
// FreePascal's athreads): the web server then answers one request at a time
// and a Gitea job runs inside the request that starts it.
{$IF DEFINED(HASAMIGA) and not DEFINED(OMI_THREADS)}
{$DEFINE OMI_NO_THREADS}
{$ENDIF}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IF DEFINED(HASAMIGA) and DEFINED(OMI_THREADS)}
  athreads,
  {$ENDIF}
  {$IF DEFINED(HASAMIGA) and not DEFINED(OMI_NO_SQLITE_LINK)}
  omiamiga,
  {$ENDIF}
  SysUtils, fphttpapp, HTTPDefs, httproute, Classes,
  StrUtils, Math, fpjson, jsonparser,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Sockets,
  // ssockets: for ESocketError, so "that port is already in use" can be caught
  // and reported instead of ending the program with a core dump.
  ssockets,
  Process, inifiles, DateUtils,
  // Backups: SQLite statements and the STORED/ZIP64 zip reader and writer.
  omibackup,
  // A Gitea folder: app.ini, its database read-only, and the size index.
  omigitea,
  // Writing into a stopped Gitea folder: deleting, the sync exclude file.
  omigiteaw,
  // git in Pascal: the repositories the import fetches, without git.
  omigit;

const
  VERSION = '1.0.0';
  SQLITE_OK = 0;
  DEFAULT_PORT = 3001;
  // Settings in settings/, Omi's own database in db/ (both in .gitignore).
  SETTINGS_FILE = '../settings/settings.ini';
  USERS_FILE = '../settings/users.ini';
  USERS_BRUTEFORCE_FILE = '../settings/usersbruteforcelocked.ini';
  ACTIVITY_DB_FILE = '../db/activity.db';
  REPOS_DIR = '../repos';
  SESSION_TIMEOUT = 24 * 60 * 60;
  USER_VALUE_SEP = #1;
  SESSION_META_SEP = #2;
  
type
  TSqliteExecCallback = function(UserData: Pointer; ColumnCount: Integer;
    Values, ColumnNames: PPChar): Integer; cdecl;
  TPCharArray = array[0..(MaxInt div SizeOf(PChar)) - 1] of PChar;
  PPCharArray = ^TPCharArray;

  TSettings = record
    Port: Integer;
    DbPath: string;
  end;

  TFileEntry = record
    Filename: string;
    Hash: string;
    DateTimeStr: string;
    UploadedAt: string;
    UploadedBy: string;
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

function sqlite3_open(FileName: PChar; var Db: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_open';
function sqlite3_close(Db: Pointer): Integer; cdecl; external name GT_C + 'sqlite3_close';
function sqlite3_exec(Db: Pointer; Sql: PChar; Callback: TSqliteExecCallback;
  UserData: Pointer; var ErrorMessage: PChar): Integer; cdecl; external name GT_C + 'sqlite3_exec';
procedure sqlite3_free(Value: Pointer); cdecl; external name GT_C + 'sqlite3_free';
function sqlite3_errmsg(Db: Pointer): PChar; cdecl; external name GT_C + 'sqlite3_errmsg';
function sqlite3_libversion: PChar; cdecl; external name GT_C + 'sqlite3_libversion';

var
  Settings: TSettings;
  Users: TStringList;
  Sessions: TStringList;
  SessionMeta: TStringList;
  ActivityDbReady: Boolean;
  FallbackTranslations: TJSONObject;
  // --port / -p on the command line, read in the main block below.
  ArgIndex: Integer;
  PreferredPort: Integer;

function GetLogoutIdleSeconds: Int64; forward;
// The GitHub token's file (Gitea folder imports), for the Settings page.
function GetGithubTokenFile: string; forward;
procedure LogActivity(const Username, SessionId, ActionName, StatusText, DetailText: string; ARequest: TRequest; ClickCounter: Int64); forward;
procedure InvalidateSessionsForUserAndPassword(const Username, PasswordRef: string); forward;
function HtmlEncode(const Value: string): string; forward;
function BuildAuthHiddenFields(ARequest: TRequest; const ActionName: string): string; forward;
function ReadFileToString(const FilePath: string): string; forward;

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
var
  CookieHeader: string;
  CookieParts: TStringArray;
  CookieItem: string;
  EqPos: Integer;
  I: Integer;
begin
  Result := ARequest.CookieFields.Values[Name];
  if Result <> '' then
    Exit;

  CookieHeader := ARequest.CustomHeaders.Values['Cookie'];
  if CookieHeader = '' then
    Exit;

  CookieParts := CookieHeader.Split([';']);
  for I := 0 to High(CookieParts) do
  begin
    CookieItem := Trim(CookieParts[I]);
    EqPos := Pos('=', CookieItem);
    if EqPos > 0 then
    begin
      if SameText(Trim(Copy(CookieItem, 1, EqPos - 1)), Name) then
      begin
        Result := Trim(Copy(CookieItem, EqPos + 1, Length(CookieItem)));
        Exit;
      end;
    end;
  end;
end;

function UrlDecodeLegacy(const Value: string): string;
var
  I: Integer;
  HexText: string;
  HexValue: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(Value) do
  begin
    if Value[I] = '+' then
      Result := Result + ' '
    else if (Value[I] = '%') and (I + 2 <= Length(Value)) then
    begin
      HexText := Copy(Value, I + 1, 2);
      HexValue := StrToIntDef('$' + HexText, -1);
      if HexValue >= 0 then
      begin
        Result := Result + Chr(HexValue);
        Inc(I, 2);
      end
      else
        Result := Result + Value[I];
    end
    else
      Result := Result + Value[I];
    Inc(I);
  end;
end;

function GetFormFieldValue(ARequest: TRequest; const Name: string): string;
var
  RawContent: string;
  Pairs: TStringArray;
  PairItem: string;
  EqPos: Integer;
  I: Integer;
  KeyName: string;
  KeyValue: string;
begin
  Result := ARequest.ContentFields.Values[Name];
  if Result <> '' then
    Exit;

  if UpperCase(ARequest.Method) <> 'POST' then
    Exit;

  RawContent := ARequest.Content;
  if RawContent = '' then
    Exit;

  Pairs := RawContent.Split(['&']);
  for I := 0 to High(Pairs) do
  begin
    PairItem := Pairs[I];
    EqPos := Pos('=', PairItem);
    if EqPos > 0 then
    begin
      KeyName := UrlDecodeLegacy(Copy(PairItem, 1, EqPos - 1));
      KeyValue := UrlDecodeLegacy(Copy(PairItem, EqPos + 1, Length(PairItem)));
      if SameText(KeyName, Name) then
      begin
        Result := KeyValue;
        Exit;
      end;
    end;
  end;
end;

function GetSessionIdFromRequest(ARequest: TRequest): string;
begin
  Result := Trim(GetFormFieldValue(ARequest, 'sessionId'));
end;

function GetClientIp(ARequest: TRequest): string;
begin
  Result := Trim(ARequest.CustomHeaders.Values['X-Forwarded-For']);
  if Result = '' then
    Result := Trim(ARequest.RemoteAddress);
  if Result = '' then
    Result := '0.0.0.0';
end;

function GetRequestUserAgent(ARequest: TRequest): string;
begin
  Result := Trim(ARequest.UserAgent);
  if Result = '' then
    Result := Trim(ARequest.CustomHeaders.Values['User-Agent']);
end;

function HashText(const Value: string): string;
var
  I: Integer;
  H: QWord;
begin
  H := 1469598103934665603;
  for I := 1 to Length(Value) do
  begin
    H := H xor Ord(Value[I]);
    H := H * 1099511628211;
  end;
  Result := IntToHex(H, 16);
end;

procedure SaveSessionMeta(const SessionId, Username, PasswordRef, IpAddress, UserAgent: string; LoginAt, LastActivityAt, ClickCounter: Int64);
begin
  SessionMeta.Values[SessionId] := Username + SESSION_META_SEP + PasswordRef + SESSION_META_SEP +
    IntToStr(LoginAt) + SESSION_META_SEP + IntToStr(LastActivityAt) + SESSION_META_SEP +
    IpAddress + SESSION_META_SEP + UserAgent + SESSION_META_SEP + IntToStr(ClickCounter);
end;

function LoadSessionMeta(const SessionId: string; out Username, PasswordRef, IpAddress, UserAgent: string; out LoginAt, LastActivityAt, ClickCounter: Int64): Boolean;
var
  Raw: string;
  Parts: TStringArray;
begin
  Result := False;
  Username := '';
  PasswordRef := '';
  IpAddress := '';
  UserAgent := '';
  LoginAt := 0;
  LastActivityAt := 0;
  ClickCounter := 0;

  Raw := SessionMeta.Values[SessionId];
  if Raw = '' then
    Exit;
  Parts := Raw.Split([SESSION_META_SEP]);
  if Length(Parts) < 7 then
    Exit;

  Username := Parts[0];
  PasswordRef := Parts[1];
  LoginAt := StrToInt64Def(Parts[2], 0);
  LastActivityAt := StrToInt64Def(Parts[3], 0);
  IpAddress := Parts[4];
  UserAgent := Parts[5];
  ClickCounter := StrToInt64Def(Parts[6], 0);
  Result := True;
end;

function BuildActionHash(const SessionId, Username, PasswordRef, IpAddress, UserAgent, ActionName: string; LoginAt, ClickCounter: Int64): string;
begin
  Result := HashText(ActionName + '|' + Username + '|' + PasswordRef + '|' + IpAddress + '|' +
    UserAgent + '|' + IntToStr(LoginAt) + '|' + IntToStr(ClickCounter) + '|' + SessionId);
end;

function ValidateSessionContext(ARequest: TRequest; const SessionId, Username: string; out PasswordRef: string): Boolean;
var
  MetaUsername, MetaPassword, MetaIp, MetaUa: string;
  LoginAt, LastActivityAt, ClickCounter: Int64;
  NowTs: Int64;
begin
  Result := False;
  PasswordRef := '';
  if not LoadSessionMeta(SessionId, MetaUsername, MetaPassword, MetaIp, MetaUa, LoginAt, LastActivityAt, ClickCounter) then
    Exit;
  if not SameText(MetaUsername, Username) then
    Exit;

  NowTs := DateTimeToUnix(Now);
  if (GetLogoutIdleSeconds > 0) and (NowTs - LastActivityAt > GetLogoutIdleSeconds) then
  begin
    Sessions.Values[SessionId] := '';
    SessionMeta.Values[SessionId] := '';
    LogActivity(Username, SessionId, 'session-check', 'idle-timeout', 'idle timeout reached', ARequest, ClickCounter);
    Exit;
  end;

  if (MetaIp <> GetClientIp(ARequest)) or (MetaUa <> GetRequestUserAgent(ARequest)) then
  begin
    InvalidateSessionsForUserAndPassword(Username, MetaPassword);
    LogActivity(Username, SessionId, 'session-check', 'context-mismatch', 'ip/user-agent mismatch', ARequest, ClickCounter);
    Exit;
  end;

  PasswordRef := MetaPassword;
  SaveSessionMeta(SessionId, MetaUsername, MetaPassword, MetaIp, MetaUa, LoginAt, NowTs, ClickCounter);
  Result := True;
end;

// Consume = False checks the token the same way but keeps the click counter,
// so the buttons of the page the browser stays on still work: for a download,
// which shows no new page. Every other action consumes its token.
function VerifyActionTokenInternal(ARequest: TRequest;
  const RequiredAction, SessionId, Username: string;
  out FailureReason: string; Consume: Boolean): Boolean;
var
  MetaUsername, PasswordRef, MetaIp, MetaUa: string;
  LoginAt, LastActivityAt, ClickCounter: Int64;
  PostedAction, PostedHash: string;
  PostedCounter: Int64;
  ExpectedHash: string;
begin
  Result := False;
  FailureReason := '';
  PostedAction := GetFormFieldValue(ARequest, 'auth_action');
  PostedHash := GetFormFieldValue(ARequest, 'auth_hash');
  PostedCounter := StrToInt64Def(GetFormFieldValue(ARequest, 'auth_counter'), -1);

  if (PostedAction = '') or (PostedHash = '') then
  begin
    FailureReason := 'The page did not send all required token fields. Reload the page and try again.';
    Exit;
  end;
  if not SameText(PostedAction, RequiredAction) then
  begin
    FailureReason := 'The token belongs to a different action. Reload the page and try again.';
    Exit;
  end;
  if not LoadSessionMeta(SessionId, MetaUsername, PasswordRef, MetaIp, MetaUa, LoginAt, LastActivityAt, ClickCounter) then
  begin
    FailureReason := 'The session has expired or the server restarted. Log in again.';
    Exit;
  end;
  if not SameText(MetaUsername, Username) then
  begin
    FailureReason := 'The token belongs to a different user. Log in again.';
    Exit;
  end;
  if PostedCounter <> ClickCounter then
  begin
    FailureReason := 'This one-time page token was already used. Reload the page and try again.';
    Exit;
  end;
  if (MetaIp <> GetClientIp(ARequest)) or (MetaUa <> GetRequestUserAgent(ARequest)) then
  begin
    InvalidateSessionsForUserAndPassword(Username, PasswordRef);
    FailureReason := 'The IP address or browser identity changed. Log in again.';
    Exit;
  end;

  ExpectedHash := BuildActionHash(SessionId, Username, PasswordRef, MetaIp, MetaUa, RequiredAction, LoginAt, ClickCounter);
  if not SameText(ExpectedHash, PostedHash) then
  begin
    FailureReason := 'The action token signature is invalid. Reload the page and try again.';
    Exit;
  end;

  if not Consume then
  begin
    SaveSessionMeta(SessionId, MetaUsername, PasswordRef, MetaIp, MetaUa, LoginAt, DateTimeToUnix(Now), ClickCounter);
    LogActivity(Username, SessionId, RequiredAction, 'ok', 'token checked (kept)', ARequest, ClickCounter);
    Exit(True);
  end;
  SaveSessionMeta(SessionId, MetaUsername, PasswordRef, MetaIp, MetaUa, LoginAt, DateTimeToUnix(Now), ClickCounter + 1);
  LogActivity(Username, SessionId, RequiredAction, 'ok', 'token accepted', ARequest, ClickCounter + 1);
  Result := True;
end;

function VerifyAndConsumeActionTokenDetailed(ARequest: TRequest;
  const RequiredAction, SessionId, Username: string;
  out FailureReason: string): Boolean;
begin
  Result := VerifyActionTokenInternal(ARequest, RequiredAction, SessionId,
    Username, FailureReason, True);
end;

function VerifyActionTokenKeepingCounter(ARequest: TRequest;
  const RequiredAction, SessionId, Username: string): Boolean;
var
  FailureReason: string;
begin
  Result := VerifyActionTokenInternal(ARequest, RequiredAction, SessionId,
    Username, FailureReason, False);
end;

function VerifyAndConsumeActionToken(ARequest: TRequest;
  const RequiredAction, SessionId, Username: string): Boolean;
var
  FailureReason: string;
begin
  Result := VerifyAndConsumeActionTokenDetailed(ARequest, RequiredAction,
    SessionId, Username, FailureReason);
end;

function BuildActionButton(ARequest: TRequest; const Path, ActionName, LabelText: string): string;
var
  AuthFields: string;
begin
  AuthFields := BuildAuthHiddenFields(ARequest, ActionName);
  if AuthFields = '' then
  begin
    Result := '<a href="' + HtmlEncode(Path) + '">' + HtmlEncode(LabelText) + '</a>';
    Exit;
  end;
  Result := '<form method="POST" action="' + HtmlEncode(Path) + '" style="display:inline; margin:0; padding:0;">' +
    AuthFields +
    '<input type="submit" value="' + HtmlEncode(LabelText) + '" style="padding:0 2px;">' +
    '</form>';
end;

function BuildNavTargetButton(ARequest: TRequest; const PostPath, TargetPath, ActionName, LabelText: string): string;
begin
  Result := BuildActionButton(ARequest, TargetPath, ActionName, LabelText);
end;

function BuildNavRow(const Items: array of string): string;
var
  I: Integer;
begin
  Result := '<table border="0" cellpadding="2" cellspacing="0"><tr>';
  for I := Low(Items) to High(Items) do
  begin
    if Trim(Items[I]) <> '' then
      Result := Result + '<td valign="middle">' + Items[I] + '</td>';
  end;
  Result := Result + '</tr></table>';
end;

procedure RedirectToPublicHome(ARequest: TRequest; AResponse: TResponse);
begin
  if ARequest.Method = 'POST' then
    AResponse.Code := 303
  else
    AResponse.Code := 302;
  AResponse.Location := '/';
  AResponse.Content := '';
end;

function PrettyHtml32(const Html: string): string;
var
  Normalized: string;
  SourceLines, PrettyLines: TStringList;
  I, Indent: Integer;
  LineText: string;
  IsClosing, IsDeclaration, IsSelfClosing, HasInlineClose: Boolean;
begin
  if Pos('<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 FINAL//EN">', UpperCase(Html)) = 0 then
  begin
    Result := Html;
    Exit;
  end;

  Normalized := StringReplace(Html, #13#10, #10, [rfReplaceAll]);
  Normalized := StringReplace(Normalized, #13, #10, [rfReplaceAll]);
  Normalized := StringReplace(Normalized, '><', '>' + LineEnding + '<', [rfReplaceAll]);

  SourceLines := TStringList.Create;
  PrettyLines := TStringList.Create;
  try
    SourceLines.Text := Normalized;
    Indent := 0;

    for I := 0 to SourceLines.Count - 1 do
    begin
      LineText := Trim(SourceLines[I]);
      if LineText = '' then
        Continue;

      IsClosing := Pos('</', LineText) = 1;
      IsDeclaration := (Pos('<!', LineText) = 1) or (Pos('<?', LineText) = 1);
      IsSelfClosing := (Pos('/>', LineText) > 0) or
        (Pos('<br', LowerCase(LineText)) = 1) or (Pos('<hr', LowerCase(LineText)) = 1) or
        (Pos('<img', LowerCase(LineText)) = 1) or (Pos('<input', LowerCase(LineText)) = 1) or
        (Pos('<meta', LowerCase(LineText)) = 1) or (Pos('<link', LowerCase(LineText)) = 1);
      HasInlineClose := (Pos('</', LineText) > 1) and (Pos('<', LineText) = 1);

      if IsClosing and (Indent > 0) then
        Dec(Indent);

      PrettyLines.Add(StringOfChar(' ', Indent * 2) + LineText);

      if (not IsClosing) and (not IsDeclaration) and (not IsSelfClosing) and (not HasInlineClose) and (Pos('<', LineText) = 1) then
        Inc(Indent);
    end;

    Result := PrettyLines.Text;
  finally
    SourceLines.Free;
    PrettyLines.Free;
  end;
end;

function BuildAuthHiddenFields(ARequest: TRequest; const ActionName: string): string;
var
  SessionId, Username, PasswordRef, MetaIp, MetaUa: string;
  LoginAt, LastActivityAt, ClickCounter: Int64;
  Token: string;
begin
  SessionId := GetSessionIdFromRequest(ARequest);
  Username := '';
  if SessionId <> '' then
    Username := Sessions.Values[SessionId];
  if (SessionId = '') or (Username = '') then
  begin
    Result := '';
    Exit;
  end;

  if not LoadSessionMeta(SessionId, Username, PasswordRef, MetaIp, MetaUa, LoginAt, LastActivityAt, ClickCounter) then
  begin
    Result := '';
    Exit;
  end;

  Token := BuildActionHash(SessionId, Username, PasswordRef, MetaIp, MetaUa, ActionName, LoginAt, ClickCounter);
  Result := '<input type="hidden" name="sessionId" value="' + HtmlEncode(SessionId) + '">' +
    '<input type="hidden" name="auth_action" value="' + HtmlEncode(ActionName) + '">' +
    '<input type="hidden" name="auth_counter" value="' + IntToStr(ClickCounter) + '">' +
    '<input type="hidden" name="auth_hash" value="' + HtmlEncode(Token) + '">';
end;

function GetUsernameFromRequest(ARequest: TRequest): string;
var
  SessionId: string;
  PasswordRef: string;
begin
  Result := '';
  SessionId := GetSessionIdFromRequest(ARequest);
  if SessionId <> '' then
  begin
    Result := Sessions.Values[SessionId];
    if (Result <> '') and not ValidateSessionContext(ARequest, SessionId, Result, PasswordRef) then
      Result := '';
  end;
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
  JsonData: TJSONData;
begin
  Result := TJSONObject.Create;
  LangFile := DataPath('languages.json');
  if not FileExists(LangFile) then
    Exit;

  Content := ReadFileToString(LangFile);
  if Content = '' then
    Exit;

  try
    JsonData := GetJSON(Content);
    if JsonData is TJSONObject then
    begin
      Result.Free;
      Result := TJSONObject(JsonData);
    end
    else
      JsonData.Free;
  except
    // keep empty object
  end;
end;

function LoadSettings: TSettings;
var
  F: TextFile;
  Line, Key, Value: string;
  EqPos: Integer;
begin
  Result.Port := DEFAULT_PORT;
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
          // LOWERCASED, because settings.ini writes its keys in capitals and
          // these comparisons use lowercase literals.
          Key := LowerCase(Trim(Copy(Line, 1, EqPos - 1)));
          Value := Trim(Copy(Line, EqPos + 1, Length(Line)));

          if Key = 'port' then
            Result.Port := StrToIntDef(Value, DEFAULT_PORT)
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
  JsonData: TJSONData;
begin
  Result := nil;
  
  LangFile := DataPath(Format('i18n/%s.i18n.json', [Language]));
  if not FileExists(LangFile) then
    LangFile := DataPath('i18n/en.i18n.json');

  if FileExists(LangFile) then
  begin
    Content := ReadFileToString(LangFile);
    if Content = '' then
    begin
      Result := TJSONObject.Create;
      Exit;
    end;

    try
      JsonData := GetJSON(Content);
      if JsonData is TJSONObject then
        Result := TJSONObject(JsonData)
      else
      begin
        JsonData.Free;
        Result := TJSONObject.Create;
      end;
    except
      Result := TJSONObject.Create;
    end;
  end
  else
    Result := TJSONObject.Create;
end;

function ResolveTranslationKey(const Key: string): string;
var
  L: string;
begin
  Result := Key;
  L := LowerCase(Key);

  if (L = 'language-selection') or (L = 'select-language') then Exit('language');
  if (L = 'save-language') or (L = 'language-updated') or (L = 'file-saved-success') or (L = 'otp-enabled-success') then Exit('save');
  if (L = 'settings-update-failed') or (L = 'file-save-failed') or (L = 'file-delete-failed') or (L = 'repository-create-failed') or (L = 'invalid-action-token') or (L = 'invalid-logout-token') then Exit('error');
  if (L = 'repository-created') then Exit('create');

  if Pos('create', L) > 0 then Exit('create');
  if Pos('delete', L) > 0 then Exit('delete');
  if Pos('upload', L) > 0 then Exit('upload');
  if Pos('download', L) > 0 then Exit('download');
  if Pos('repository', L) > 0 then Exit('repository');
  if (Pos('directory', L) > 0) or (L = 'root') then Exit('repository');
  if (L = 'files') or (L = 'no-files') or (L = 'no-files-directory') then Exit('file');
  if Pos('file', L) > 0 then Exit('file');
  if Pos('otp', L) > 0 then Exit('otp');
  if Pos('password', L) > 0 then Exit('password');
  if Pos('email', L) > 0 then Exit('email');
  if Pos('name', L) > 0 then Exit('name');
  if Pos('user', L) > 0 then Exit('username');
  if (Pos('author', L) > 0) or (Pos('message', L) > 0) or (Pos('image', L) > 0) then Exit('activity');
  if (Pos('commit', L) > 0) or (Pos('activity', L) > 0) then Exit('activity');
  if Pos('login', L) > 0 then Exit('login');
  if Pos('logout', L) > 0 then Exit('logout');
  if Pos('setting', L) > 0 then Exit('settings');
  if L = 'update' then Exit('save');
  if Pos('enable', L) > 0 then Exit('save');
  if Pos('disable', L) > 0 then Exit('save');
  if Pos('updated', L) > 0 then Exit('save');
  if Pos('saved', L) > 0 then Exit('save');
  if Pos('failed', L) > 0 then Exit('error');
  if Pos('invalid', L) > 0 then Exit('error');
  if Pos('not-implemented', L) > 0 then Exit('error');
end;

function T(Key: string; Translations: TJSONObject): string;
var
  JsonValue: TJSONData;
  ResolvedKey: string;
  Candidate: string;
begin
  Result := Key;
  ResolvedKey := ResolveTranslationKey(Key);
  if Assigned(Translations) then
  begin
    try
      JsonValue := Translations.Find(Key);
      if Assigned(JsonValue) and (JsonValue.JSONType = jtString) then
      begin
        Candidate := JsonValue.AsString;
        if Candidate <> Key then
          Result := Candidate;
      end;
    except
      Result := Key;
    end;
  end;
  if (Result = Key) and (ResolvedKey <> Key) and Assigned(Translations) then
  begin
    try
      JsonValue := Translations.Find(ResolvedKey);
      if Assigned(JsonValue) and (JsonValue.JSONType = jtString) then
      begin
        Candidate := JsonValue.AsString;
        if Candidate <> ResolvedKey then
          Result := Candidate;
      end;
    except
      Result := Key;
    end;
  end;
  if (Result = Key) and Assigned(FallbackTranslations) then
  begin
    try
      JsonValue := FallbackTranslations.Find(Key);
      if Assigned(JsonValue) and (JsonValue.JSONType = jtString) then
      begin
        Candidate := JsonValue.AsString;
        if Candidate <> Key then
          Result := Candidate;
      end;
    except
      Result := Key;
    end;
  end;
  if (Result = Key) and (ResolvedKey <> Key) and Assigned(FallbackTranslations) then
  begin
    try
      JsonValue := FallbackTranslations.Find(ResolvedKey);
      if Assigned(JsonValue) and (JsonValue.JSONType = jtString) then
      begin
        Candidate := JsonValue.AsString;
        if Candidate <> ResolvedKey then
          Result := Candidate;
      end;
    except
      Result := Key;
    end;
  end;
  if (Result = Key) and (ResolvedKey <> Key) then
    Result := ResolvedKey;
end;

function BuildHiddenInput(const Name, Value: string): string;
begin
  Result := '<input type="hidden" name="' + HtmlEncode(Name) +
    '" value="' + HtmlEncode(Value) + '">';
end;

function BuildSignedInlineForm(ARequest: TRequest; const TokenAction,
  FieldsHtml, ControlsHtml: string): string;
begin
  Result := '<form method="POST" style="display:inline; margin:0; padding:0;">' +
    BuildAuthHiddenFields(ARequest, TokenAction) + FieldsHtml + ControlsHtml +
    '</form>';
end;

function BuildRepositoryEntryActions(ARequest: TRequest; const Target,
  EntryKind, EditButton: string; Translations: TJSONObject): string;
var
  RenameAction, DeleteAction: string;
  RenameForm, DeleteForm: string;
begin
  RenameAction := 'rename_' + EntryKind;
  DeleteAction := 'delete_' + EntryKind;
  RenameForm := BuildSignedInlineForm(ARequest,
    'repo-' + EntryKind + '-rename-' + Target,
    BuildHiddenInput('action', RenameAction) +
    BuildHiddenInput('target', Target),
    '<input type="text" name="new_name" size="12" placeholder="' +
    HtmlEncode(T('new-name', Translations)) + '">' +
    '<input type="submit" value="' + HtmlEncode(T('rename', Translations)) + '">');
  DeleteForm := BuildSignedInlineForm(ARequest,
    'repo-' + EntryKind + '-delete-' + Target,
    BuildHiddenInput('action', DeleteAction) +
    BuildHiddenInput('target', Target),
    '<input type="submit" value="' + HtmlEncode(T('delete', Translations)) + '">');
  Result := '<div style="display:flex; align-items:center; ' +
    'justify-content:space-between; gap:12px;"><div>' + EditButton +
    RenameForm + '</div><div>' + DeleteForm + '</div></div>';
end;

function TE(const Key: string; Translations: TJSONObject): string;
begin
  Result := HtmlEncode(T(Key, Translations));
end;

function ifthen(Condition: Boolean; const TrueVal, FalseVal: string): string;
begin
  if Condition then
    Result := TrueVal
  else
    Result := FalseVal;
end;

function ExtractOtpSecret(const OtpValue: string): string;
var
  LowerOtp, SecretPart: string;
  StartPos, EndPos, I: Integer;
begin
  Result := '';
  LowerOtp := LowerCase(Trim(OtpValue));
  if LowerOtp = '' then
    Exit;

  StartPos := Pos('secret=', LowerOtp);
  if StartPos = 0 then
    Exit;

  SecretPart := Copy(Trim(OtpValue), StartPos + Length('secret='), Length(OtpValue));
  EndPos := Pos('&', SecretPart);
  if EndPos > 0 then
    SecretPart := Copy(SecretPart, 1, EndPos - 1);
  SecretPart := Trim(SecretPart);
  if SecretPart = '' then
    Exit;

  for I := 1 to Length(SecretPart) do
    if not (UpCase(SecretPart[I]) in ['A'..'Z', '2'..'7']) then
      Exit;

  Result := UpperCase(SecretPart);
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

function CreateSession(ARequest: TRequest; const Username, PasswordRef: string): string;
var
  SessionId: string;
  NowTs: Int64;
begin
  Randomize;
  SessionId := Format('%s_%d_%d', [Username, Random(999999), GetTickCount64 mod 1000000]);
  Sessions.Values[SessionId] := Username;
  NowTs := DateTimeToUnix(Now);
  SaveSessionMeta(SessionId, Username, PasswordRef, GetClientIp(ARequest), GetRequestUserAgent(ARequest), NowTs, NowTs, 0);
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

function JoinRepoPath(const DirectoryName, EntryName: string): string;
begin
  if DirectoryName = '' then
    Result := EntryName
  else if EntryName = '' then
    Result := DirectoryName
  else
    Result := DirectoryName + '/' + EntryName;
end;

function FormatByteSize(const ByteCount: Int64): string;
const
  UnitNames: array[0..4] of string = ('B', 'KB', 'MB', 'GB', 'TB');
var
  UnitIndex: Integer;
  DisplayValue: Double;
begin
  if ByteCount < 0 then
    Exit('-');
  DisplayValue := ByteCount;
  UnitIndex := 0;
  while (DisplayValue >= 1024) and (UnitIndex < High(UnitNames)) do
  begin
    DisplayValue := DisplayValue / 1024;
    Inc(UnitIndex);
  end;
  if UnitIndex = 0 then
    Result := IntToStr(ByteCount) + ' ' + UnitNames[UnitIndex]
  else
    Result := FormatFloat('0.##', DisplayValue) + ' ' + UnitNames[UnitIndex];
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
  RawContent: RawByteString;
begin
  Result := '';
  if not FileExists(FilePath) then
    Exit;
  Stream := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(RawContent, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(RawContent[1], Stream.Size);
    SetCodePage(RawContent, CP_UTF8, False);
    Result := string(RawContent);
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
end;

function ResolveExecutablePath(const CommandName: string): string;
var
  PathDirs: TStringArray;
  PathDir: string;
  Candidate: string;
begin
  Result := CommandName;
  if ExtractFilePath(CommandName) <> '' then
    Exit;

  PathDirs := GetEnvironmentVariable('PATH').Split([PathSeparator]);
  for PathDir in PathDirs do
  begin
    if PathDir = '' then
      Candidate := ExpandFileName(CommandName)
    else
      Candidate := IncludeTrailingPathDelimiter(PathDir) + CommandName;
    if FileExists(Candidate) then
      Exit(Candidate);
  end;
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

function CollectSqlRows(UserData: Pointer; ColumnCount: Integer;
  Values, ColumnNames: PPChar): Integer; cdecl;
var
  I: Integer;
  ValueArray: PPCharArray;
  Output: PString;
begin
  Result := 0;
  Output := PString(UserData);
  ValueArray := PPCharArray(Values);
  for I := 0 to ColumnCount - 1 do
  begin
    if I > 0 then
      Output^ := Output^ + '|';
    if Assigned(ValueArray^[I]) then
      Output^ := Output^ + StrPas(ValueArray^[I]);
  end;
  Output^ := Output^ + LineEnding;
end;

function RunSqlOnDb(const DbPath, Query: string; out OutputText, ErrorText: string): Boolean;
var
  Db: Pointer;
  SqlError: PChar;
  ReturnCode: Integer;
  DbAbs: string;
begin
  Result := False;
  OutputText := '';
  ErrorText := '';
  DbAbs := ExpandFileName(DbPath);
  Db := nil;
  SqlError := nil;

  ReturnCode := sqlite3_open(PChar(DbAbs), Db);
  if ReturnCode <> SQLITE_OK then
  begin
    if Assigned(Db) then
      ErrorText := StrPas(sqlite3_errmsg(Db))
    else
      ErrorText := 'SQLite could not allocate a database handle';
    if Assigned(Db) then
      sqlite3_close(Db);
    Exit;
  end;

  try
    ReturnCode := sqlite3_exec(Db, PChar(Query), @CollectSqlRows,
      @OutputText, SqlError);
    Result := ReturnCode = SQLITE_OK;
    if not Result then
    begin
      if Assigned(SqlError) then
        ErrorText := StrPas(SqlError)
      else
        ErrorText := StrPas(sqlite3_errmsg(Db));
    end;
  finally
    if Assigned(SqlError) then
      sqlite3_free(SqlError);
    sqlite3_close(Db);
  end;
end;

function ExecSqlOnDb(const DbPath, Query: string): string;
var
  ErrorText: string;
begin
  RunSqlOnDb(DbPath, Query, Result, ErrorText);
end;

procedure EnsureActivityDb;
var
  DbPath: string;
begin
  if ActivityDbReady then
    Exit;
  DbPath := DataPath(ACTIVITY_DB_FILE);
  ExecSqlOnDb(DbPath,
    'CREATE TABLE IF NOT EXISTS activity (' +
    'id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    'event_time INTEGER NOT NULL,' +
    'username TEXT,' +
    'session_id TEXT,' +
    'ip TEXT,' +
    'user_agent TEXT,' +
    'action_name TEXT,' +
    'status_text TEXT,' +
    'detail_text TEXT,' +
    'click_counter INTEGER' +
    ');');
  ActivityDbReady := True;
end;

procedure InvalidateSessionsForUserAndPassword(const Username, PasswordRef: string);
var
  I: Integer;
  SessionId, MetaUsername, MetaPassword, MetaIp, MetaUa: string;
  LoginAt, LastActivityAt, ClickCounter: Int64;
begin
  for I := 0 to SessionMeta.Count - 1 do
  begin
    SessionId := SessionMeta.Names[I];
    if SessionId = '' then
      Continue;
    if LoadSessionMeta(SessionId, MetaUsername, MetaPassword, MetaIp, MetaUa, LoginAt, LastActivityAt, ClickCounter) then
    begin
      if SameText(MetaUsername, Username) and (MetaPassword = PasswordRef) then
      begin
        Sessions.Values[SessionId] := '';
        SessionMeta.Values[SessionId] := '';
      end;
    end;
  end;
end;

function GetLogoutIdleSeconds: Int64;
var
  SettingsMap: TStringList;
  IdleHours: Int64;
begin
  Result := SESSION_TIMEOUT;
  SettingsMap := LoadSettingsMap;
  try
    IdleHours := StrToInt64Def(Trim(SettingsMap.Values['LOGOUT_ON_HOURS']), 0);
    if IdleHours > 0 then
      Result := IdleHours * 60 * 60;
  finally
    SettingsMap.Free;
  end;
end;

procedure LogActivity(const Username, SessionId, ActionName, StatusText, DetailText: string; ARequest: TRequest; ClickCounter: Int64);
var
  DbPath: string;
  Query: string;
begin
  EnsureActivityDb;
  DbPath := DataPath(ACTIVITY_DB_FILE);
  Query := 'INSERT INTO activity(event_time,username,session_id,ip,user_agent,action_name,status_text,detail_text,click_counter) VALUES(' +
    IntToStr(DateTimeToUnix(Now)) + ',''' + SqlEscape(Username) + ''',''' + SqlEscape(SessionId) + ''',''' +
    SqlEscape(GetClientIp(ARequest)) + ''',''' + SqlEscape(GetRequestUserAgent(ARequest)) + ''',''' +
    SqlEscape(ActionName) + ''',''' + SqlEscape(StatusText) + ''',''' + SqlEscape(DetailText) + ''',' +
    IntToStr(ClickCounter) + ');';
  ExecSqlOnDb(DbPath, Query);
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

procedure EnsureFileOriginMetadata(const DbPath: string);
var
  TableInfo: string;
begin
  TableInfo := ExecSqlOnDb(DbPath, 'PRAGMA table_info(files);');
  if Pos('|uploaded_at|', '|' + TableInfo) = 0 then
    ExecSqlOnDb(DbPath, 'ALTER TABLE files ADD COLUMN uploaded_at TEXT;');
  if Pos('|uploaded_by|', '|' + TableInfo) = 0 then
    ExecSqlOnDb(DbPath, 'ALTER TABLE files ADD COLUMN uploaded_by TEXT;');
  ExecSqlOnDb(DbPath,
    'UPDATE files SET uploaded_at=COALESCE(NULLIF(uploaded_at,''''),' +
    '(SELECT c.datetime FROM files origin JOIN commits c ON c.id=origin.commit_id ' +
    'WHERE origin.filename=files.filename ORDER BY origin.commit_id LIMIT 1),datetime),' +
    'uploaded_by=COALESCE(NULLIF(uploaded_by,''''),' +
    '(SELECT c.user FROM files origin JOIN commits c ON c.id=origin.commit_id ' +
    'WHERE origin.filename=files.filename ORDER BY origin.commit_id LIMIT 1),'''') ' +
    'WHERE uploaded_at IS NULL OR uploaded_at='''' OR uploaded_by IS NULL OR uploaded_by='''';');
end;

function GetLatestFiles(const DbPath, RepoPath: string; CommitId: Int64 = 0): TFileEntryArray;
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
  EnsureFileOriginMetadata(DbPath);
  if CommitId > 0 then
    LatestCommit := CommitId
  else
    LatestCommit := GetLatestCommitId(DbPath);
  if LatestCommit = 0 then
    Exit;

  CleanRepoPath := RepoPath;
  if (CleanRepoPath <> '') and (CleanRepoPath[1] = '/') then
    CleanRepoPath := Copy(CleanRepoPath, 2, Length(CleanRepoPath));
  
  if CleanRepoPath <> '' then
  begin
    // Check if this is a file (exact match) or a directory (prefix match)
    Prefix := CleanRepoPath + '/';
    Query := 'SELECT f.filename, f.hash, f.datetime, IFNULL(b.size,0),IFNULL(f.uploaded_at,f.datetime),IFNULL(f.uploaded_by,'''') FROM files f LEFT JOIN blobs b ON f.hash=b.hash WHERE f.commit_id=' + IntToStr(LatestCommit) + ' AND (f.filename = ''' + SqlEscape(CleanRepoPath) + ''' OR f.filename LIKE ''' + SqlEscape(Prefix) + '%'') ORDER BY f.filename;';
  end
  else
    Query := 'SELECT f.filename, f.hash, f.datetime, IFNULL(b.size,0),IFNULL(f.uploaded_at,f.datetime),IFNULL(f.uploaded_by,'''') FROM files f LEFT JOIN blobs b ON f.hash=b.hash WHERE f.commit_id=' + IntToStr(LatestCommit) + ' ORDER BY f.filename;';

  Output := ExecSqlOnDb(DbPath, Query);
  if Output = '' then
    Exit;
  Lines := Output.Split([#10]);
  for I := 0 to High(Lines) do
  begin
    if Trim(Lines[I]) = '' then
      Continue;
    Parts := Lines[I].Split(['|']);
    if Length(Parts) >= 6 then
    begin
      Entry.Filename := Parts[0];
      Entry.Hash := Parts[1];
      Entry.DateTimeStr := Parts[2];
      Entry.Size := StrToInt64Def(Parts[3], 0);
      Entry.UploadedAt := Parts[4];
      Entry.UploadedBy := Parts[5];
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

function InsertFileRecord(const DbPath, Filename, Hash, DateTimeStr,
  UploadedAt, UploadedBy: string; CommitId: Int64): Boolean;
var
  Query: string;
begin
  Query := 'INSERT INTO files(filename, hash, datetime, uploaded_at, uploaded_by, commit_id) VALUES(''' +
    SqlEscape(Filename) + ''', ''' + SqlEscape(Hash) + ''', ''' +
    SqlEscape(DateTimeStr) + ''', ''' + SqlEscape(UploadedAt) + ''', ''' +
    SqlEscape(UploadedBy) + ''', ' + IntToStr(CommitId) + ');';
  ExecSqlOnDb(DbPath, Query);
  Result := True;
end;

function CommitFile(const DbPath, Filename, Content, Username, MessageText: string): Boolean;
var
  Hash: string;
  CommitId: Int64;
  NowStr: string;
  Files: TFileEntryArray;
  I: Integer;
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
      Proc.Executable := ResolveExecutablePath('sha256sum');
      Proc.Parameters.Add(TempFile);
      Proc.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
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

    Files := GetLatestFiles(DbPath, '');

    InsertBlob(DbPath, Hash, Content);
    CommitId := CreateCommit(DbPath, MessageText, Username);
    if CommitId = 0 then
      Exit;
    NowStr := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);

    for I := 0 to High(Files) do
    begin
      if Files[I].Filename = Filename then
        Continue;
      InsertFileRecord(DbPath, Files[I].Filename, Files[I].Hash,
        Files[I].DateTimeStr, Files[I].UploadedAt, Files[I].UploadedBy, CommitId);
    end;

    for I := 0 to High(Files) do
      if Files[I].Filename = Filename then
      begin
        InsertFileRecord(DbPath, Filename, Hash, NowStr, Files[I].UploadedAt,
          Files[I].UploadedBy, CommitId);
        Exit(True);
      end;
    InsertFileRecord(DbPath, Filename, Hash, NowStr, NowStr, Username, CommitId);
    Result := True;
  finally
    if FileExists(TempFile) then
      DeleteFile(TempFile);
  end;
end;

function CreateEmptyRepository(const RepoFilePath, Username: string; out ErrorMessage: string): Boolean;
var
  Query: string;
  RepoDir: string;
  InitialCommitId: Int64;
  SqlOutput: string;
  SqlError: string;
begin
  Result := False;
  ErrorMessage := '';
  RepoDir := ExtractFileDir(RepoFilePath);
  if not DirectoryExists(RepoDir) and not ForceDirectories(RepoDir) then
  begin
    ErrorMessage := 'Could not create repository directory: ' + RepoDir;
    Exit;
  end;
  if FileExists(RepoFilePath) then
  begin
    ErrorMessage := 'Repository file already exists: ' + RepoFilePath;
    Exit;
  end;
  Query := 'PRAGMA foreign_keys=ON;' +
    'CREATE TABLE IF NOT EXISTS blobs (hash TEXT PRIMARY KEY, data BLOB, size INTEGER);' +
    'CREATE TABLE IF NOT EXISTS commits (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT, datetime TEXT, user TEXT);' +
    'CREATE TABLE IF NOT EXISTS files (id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, hash TEXT, datetime TEXT, uploaded_at TEXT, uploaded_by TEXT, commit_id INTEGER);' +
    'CREATE TABLE IF NOT EXISTS staging (filename TEXT PRIMARY KEY, hash TEXT, datetime TEXT);';
  if not RunSqlOnDb(RepoFilePath, Query, SqlOutput, SqlError) then
    ErrorMessage := 'Could not create SQLite schema: ' + SqlError
  else
  begin
    Query := 'INSERT INTO commits(message, datetime, user) VALUES(''Initial commit'', ''' +
      SqlEscape(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)) + ''', ''' +
      SqlEscape(Username) + '''); SELECT last_insert_rowid();';
    if not RunSqlOnDb(RepoFilePath, Query, SqlOutput, SqlError) then
      ErrorMessage := 'Could not create initial commit: ' + SqlError
    else
    begin
      InitialCommitId := StrToInt64Def(Trim(SqlOutput), 0);
      if InitialCommitId < 1 then
        ErrorMessage := 'SQLite did not return an initial commit ID'
      else if not FileExists(RepoFilePath) then
        ErrorMessage := 'SQLite reported success but did not create: ' + RepoFilePath
      else
        Result := True;
    end;
  end;
  if not Result and FileExists(RepoFilePath) then
    if not DeleteFile(RepoFilePath) then
      ErrorMessage := ErrorMessage + '. The incomplete file could not be removed: ' + RepoFilePath;
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
begin
  Result := False;
  Files := GetLatestFiles(DbPath, '');
  CommitId := CreateCommit(DbPath, 'Delete file', Username);
  if CommitId = 0 then
    Exit;
  for I := 0 to High(Files) do
  begin
    if Files[I].Filename = TargetFilename then
      Continue;
    InsertFileRecord(DbPath, Files[I].Filename, Files[I].Hash,
      Files[I].DateTimeStr, Files[I].UploadedAt, Files[I].UploadedBy, CommitId);
  end;
  Result := True;
end;

function RenameFileInRepo(const DbPath, OldName, NewName, Username: string): Boolean;
var
  Files: TFileEntryArray;
  I: Integer;
  CommitId: Int64;
  Filename: string;
begin
  Result := False;
  Files := GetLatestFiles(DbPath, '');
  CommitId := CreateCommit(DbPath, 'Rename file', Username);
  if CommitId = 0 then
    Exit;
  for I := 0 to High(Files) do
  begin
    Filename := Files[I].Filename;
    if Filename = OldName then
      Filename := NewName;
    InsertFileRecord(DbPath, Filename, Files[I].Hash, Files[I].DateTimeStr,
      Files[I].UploadedAt, Files[I].UploadedBy, CommitId);
  end;
  Result := True;
end;

function DeleteDirectoryFromRepo(const DbPath, DirectoryName,
  Username: string): Boolean;
var
  Files: TFileEntryArray;
  I: Integer;
  CommitId: Int64;
  DirectoryPrefix: string;
  FoundDirectory: Boolean;
begin
  Result := False;
  if DirectoryName = '' then
    Exit;
  DirectoryPrefix := DirectoryName + '/';
  Files := GetLatestFiles(DbPath, '');
  FoundDirectory := False;
  for I := 0 to High(Files) do
    if Pos(DirectoryPrefix, Files[I].Filename) = 1 then
    begin
      FoundDirectory := True;
      Break;
    end;
  if not FoundDirectory then
    Exit;

  CommitId := CreateCommit(DbPath, 'Delete directory', Username);
  if CommitId = 0 then
    Exit;
  for I := 0 to High(Files) do
  begin
    if Pos(DirectoryPrefix, Files[I].Filename) = 1 then
      Continue;
    InsertFileRecord(DbPath, Files[I].Filename, Files[I].Hash,
      Files[I].DateTimeStr, Files[I].UploadedAt, Files[I].UploadedBy, CommitId);
  end;
  Result := True;
end;

function RenameDirectoryInRepo(const DbPath, OldName, NewName,
  Username: string): Boolean;
var
  Files: TFileEntryArray;
  I: Integer;
  CommitId: Int64;
  OldPrefix: string;
  NewPrefix: string;
  Filename: string;
  FoundDirectory: Boolean;
begin
  Result := False;
  if (OldName = '') or (NewName = '') or SameText(OldName, NewName) then
    Exit;
  OldPrefix := OldName + '/';
  NewPrefix := NewName + '/';
  if Pos(OldPrefix, NewPrefix) = 1 then
    Exit;

  Files := GetLatestFiles(DbPath, '');
  FoundDirectory := False;
  for I := 0 to High(Files) do
  begin
    if Pos(OldPrefix, Files[I].Filename) = 1 then
      FoundDirectory := True
    else if (Files[I].Filename = NewName) or
      (Pos(NewPrefix, Files[I].Filename) = 1) then
      Exit;
  end;
  if not FoundDirectory then
    Exit;

  CommitId := CreateCommit(DbPath, 'Rename directory', Username);
  if CommitId = 0 then
    Exit;
  for I := 0 to High(Files) do
  begin
    Filename := Files[I].Filename;
    if Pos(OldPrefix, Filename) = 1 then
      Filename := NewName + Copy(Filename, Length(OldName) + 1,
        Length(Filename));
    InsertFileRecord(DbPath, Filename, Files[I].Hash,
      Files[I].DateTimeStr, Files[I].UploadedAt, Files[I].UploadedBy, CommitId);
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
  ImgStart, AltStart, AltEnd, UrlStart, UrlEnd: Integer;
  AltText, ImgUrl: string;
  IsImage: Boolean;
begin
  Result1 := '';
  InCodeBlock := False;
  Lines := Markdown.Split([#10]);
  
  for I := 0 to High(Lines) do
  begin
    Line := Lines[I];
    ProcessedLine := Line;
    IsImage := False;
    
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
        // Check for image syntax ![alt](url)
        ImgStart := Pos('![', ProcessedLine);
        if ImgStart > 0 then
        begin
          // Find the closing ] of the alt text
          AltStart := ImgStart + 2;
          AltEnd := Pos(']', Copy(ProcessedLine, AltStart, Length(ProcessedLine)));
          if AltEnd > 0 then
          begin
            AltText := Copy(ProcessedLine, AltStart, AltEnd - 1);
            // Check if there's an opening ( right after ]
            if (AltStart + AltEnd) <= Length(ProcessedLine) then
            begin
              if ProcessedLine[AltStart + AltEnd] = '(' then
              begin
                // Find the closing )
                UrlStart := AltStart + AltEnd + 1;
                UrlEnd := Pos(')', Copy(ProcessedLine, UrlStart, Length(ProcessedLine)));
                if UrlEnd > 0 then
                begin
                  ImgUrl := Copy(ProcessedLine, UrlStart, UrlEnd - 1);
                  ProcessedLine := '<img src="' + ImgUrl + '" alt="' + AltText + '" style="max-width: 100%; height: auto; border: 1px solid #ccc; margin: 10px 0;">';
                  IsImage := True;
                end;
              end;
            end;
          end;
        end;
        
        if not IsImage then
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

procedure LoginEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Translations: TJSONObject;
  Username, Password, OtpCode: string;
  ErrorMsg: string;
  ShowOtp: Boolean;
  UsersMap: TStringList;
  StoredPassword, StoredOtp, StoredLanguage: string;
  OtpSecret: string;
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
      Username := Trim(GetFormFieldValue(ARequest, 'username'));
      Password := GetFormFieldValue(ARequest, 'password');
      OtpCode := Trim(GetFormFieldValue(ARequest, 'otp'));

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
          else
          begin
            OtpSecret := ExtractOtpSecret(StoredOtp);
            if (OtpSecret <> '') and (OtpCode = '') then
            begin
              ErrorMsg := T('otp-required', Translations);
              ShowOtp := True;
            end
            else
            begin
              SessionId := CreateSession(ARequest, Username, StoredPassword);
              LogActivity(Username, SessionId, 'login', 'ok', 'login success', ARequest, 0);
              ARequest.ContentFields.Values['sessionId'] := SessionId;
              AResponse.ContentType := 'text/html; charset=UTF-8';
              AResponse.Content := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
                '<html><head><meta charset="UTF-8"><title>' +
                T('login', Translations) + ' - Omi Server</title></head>' +
                '<body bgcolor="#f0f0f0"><h1>Omi Server</h1><p><strong>' +
                HtmlEncode(Username) + '</strong></p><p>' +
                BuildActionButton(ARequest, '/', 'login-continue',
                  T('continue', Translations)) + '</p></body></html>';
              Exit;
            end;
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
      OtpInput := '<tr><td>' + T('otp', Translations) + ':</td><td><input type="text" name="otp" size="10" maxlength="6" required pattern="[0-9]{6}" placeholder="' + T('otp', Translations) + '"></td></tr>'
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
      '<tr><td colspan="2"><a href="/">' + T('home', Translations) + '</a></td></tr>' +
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

function GetGiteaAppIni: string; forward;

// The start page and the startup output name the configured Gitea folder:
// its pages are under /gitea, and nothing else says where to find them.
function GiteaFolderLine(ARequest: TRequest; const Translations: TJSONObject): string;
var
  AppIni: string;
begin
  Result := '';
  AppIni := GetGiteaAppIni;
  if AppIni = '' then
    Exit;
  Result := '<br><strong>' + T('gitea', Translations) + ':</strong> <tt>' + HtmlEncode(AppIni) + '</tt> ';
  if FileExists(AppIni) then
    Result := Result + BuildActionButton(ARequest, '/gitea', 'home-gitea', T('gitea', Translations))
  else
    Result := Result + '<font color="red"><strong>' + T('error', Translations) + ': ' +
      HtmlEncode(T('gitea-app-ini', Translations)) + '</strong></font> ' +
      BuildActionButton(ARequest, '/settings', 'home-gitea-settings', T('settings', Translations));
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
  RepoCreateError: string;
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
  HeaderRight: string;
  MainNav: string;
  CreateRepoAuth: string;
  UploadRepoAuth: string;
  PostedAuthAction: string;
  TokenFailureReason: string;
  SessionId: string;
  RepoRootPath: string;
  PendingDeleteRepo: string;
  DeleteRepoAuth: string;
  DeleteConfirmAuth: string;
begin
  Username := GetUsernameFromRequest(ARequest);
  SessionId := GetSessionIdFromRequest(ARequest);

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

    if ARequest.Method = 'POST' then
    begin
      if Username = '' then
      begin
        RedirectToPublicHome(ARequest, AResponse);
        Exit;
      end;
      PostedAuthAction := GetFormFieldValue(ARequest, 'auth_action');
      if PostedAuthAction = '' then
        TokenFailureReason := 'The page did not send an action token. Reload the page and try again.';
      if (PostedAuthAction = '') or not VerifyAndConsumeActionTokenDetailed(
        ARequest, PostedAuthAction, SessionId, Username, TokenFailureReason) then
      begin
        LogActivity(Username, SessionId, 'home-post', 'forbidden',
          TokenFailureReason, ARequest, -1);
        RedirectToPublicHome(ARequest, AResponse);
        Exit;
      end;
    end;

    if DownloadName <> '' then
    begin
      RepoName := NormalizeRepoName(DownloadName);
      RepoPath := GetRepoPath(RepoName);
      if (RepoName = '') or not FileExists(RepoPath) then
      begin
        AResponse.Code := 404;
        AResponse.ContentType := 'text/plain; charset=UTF-8';
        AResponse.Content := T('error', Translations);
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
            '<tr><td><h1>' + HtmlEncode(ImageRepo) + '</h1></td><td align="right"><small></small></td></tr></table>' +
            BuildNavRow([
              BuildActionButton(ARequest, '/', 'nav-home', T('home', Translations)),
              ifthen(Username <> '', BuildActionButton(ARequest, '/language', 'nav-language', T('language', Translations)), ''),
              ifthen(Username <> '', BuildActionButton(ARequest, '/settings', 'nav-settings', T('settings', Translations)), ''),
              ifthen(Username <> '', BuildActionButton(ARequest, '/people', 'nav-people', T('people', Translations)), ''),
              ifthen(Username <> '', BuildActionButton(ARequest, '/activity', 'nav-activity', T('activity', Translations)), ''),
              ifthen(Username <> '', BuildActionButton(ARequest, '/backups', 'nav-backups', T('backups', Translations)), ''),
              ifthen(Username <> '', BuildActionButton(ARequest, '/gitea', 'nav-gitea', T('gitea', Translations)), ''),
              ifthen(Username <> '', '<strong>' + HtmlEncode(Username) + '</strong>', '<a href="/sign-in">' + T('login', Translations) + '</a>'),
              ifthen(Username <> '', BuildActionButton(ARequest, '/logout', 'nav-logout', T('logout', Translations)), '')
            ]) +
            '<h2>' + T('image', Translations) + ': ' + HtmlEncode(ImagePath) + '</h2><hr>' +
            '<div style="text-align:center"><img src="data:' + GetMimeType(ImagePath) + ';base64,' + Base64Encode(FileContent) + '" alt="' + HtmlEncode(ExtractFileName(ImagePath)) + '"></div>' +
            '<hr><p><small>Omi Server</small></p></body></html>';
          Exit;
        end;
      end;
      AResponse.Code := 404;
      AResponse.ContentType := 'text/plain; charset=UTF-8';
      AResponse.Content := T('error', Translations);
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
          TableRows := TableRows + '<tr><td><strong>' +
            BuildNavTargetButton(ARequest, '/', '/' +
              StringReplace(RepoName, '.omi', '', []) + '?commit=' +
              LogParts[0], 'home-log-commit-id-' + LogParts[0], LogParts[0]) +
            '</strong></td><td>' + HtmlEncode(LogParts[1]) + '</td><td>' +
            HtmlEncode(LogParts[2]) + '</td><td>' + HtmlEncode(LogParts[3]) +
            '</td><td>' + HtmlEncode(LogParts[4]) + '</td><td>' +
            BuildNavTargetButton(ARequest, '/', '/' +
              StringReplace(RepoName, '.omi', '', []) + '?commit=' +
              LogParts[0], 'home-log-commit-view-' + LogParts[0],
              T('view', Translations)) + '</td></tr>';
      end;

      Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
        '<html dir="' + DirAttr + '"><head><meta charset="UTF-8"><title>' + T('commit-history', Translations) + ' - ' + HtmlEncode(RepoName) + '</title></head>' +
        '<body bgcolor="#f0f0f0" dir="' + DirAttr + '">' +
        '<table width="100%" border="0" cellpadding="5">' +
        '<tr><td><h1>' + T('commit-history', Translations) + ' - ' + HtmlEncode(RepoName) + '</h1></td><td align="right"><small></small></td></tr></table>' +
        BuildNavRow([
          BuildActionButton(ARequest, '/', 'nav-home', T('home', Translations)),
          ifthen(Username <> '', BuildActionButton(ARequest, '/language', 'nav-language', T('language', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/settings', 'nav-settings', T('settings', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/people', 'nav-people', T('people', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/activity', 'nav-activity', T('activity', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/backups', 'nav-backups', T('backups', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/gitea', 'nav-gitea', T('gitea', Translations)), ''),
          ifthen(Username <> '', '<strong>' + HtmlEncode(Username) + '</strong>', '<a href="/sign-in">' + T('login', Translations) + '</a>'),
          ifthen(Username <> '', BuildActionButton(ARequest, '/logout', 'nav-logout', T('logout', Translations)), ''),
          BuildNavTargetButton(ARequest, '/', '/' + HtmlEncode(StringReplace(RepoName, '.omi', '', [])), 'home-log-repo-root', T('repository-root', Translations))
        ]) +
        '<hr>' +
        '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
        '<tr bgcolor="#333333"><th><font color="white">' + T('commit-id', Translations) + '</font></th><th><font color="white">' + T('message', Translations) + '</font></th><th><font color="white">' + T('author', Translations) + '</font></th><th><font color="white">' + T('date', Translations) + '</font></th><th><font color="white">' + T('files', Translations) + '</font></th><th><font color="white">' + T('open', Translations) + '</font></th></tr>' +
        TableRows +
        '</table>' +
        '<p>' + BuildNavTargetButton(ARequest, '/', '/' +
          StringReplace(RepoName, '.omi', '', []), 'home-log-latest',
          T('latest', Translations)) + '</p>' +
        '<hr><p><small>Omi Server</small></p>' +
        '</body></html>';
      AResponse.Content := PrettyHtml32(Html);
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
    PendingDeleteRepo := '';
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
          if CreateEmptyRepository(RepoPath, Username, RepoCreateError) then
            RepoMessage := T('repository', Translations) + ' ' + RepoName + ': ' +
              T('create', Translations) + ' OK (repos/' + RepoName + ')'
          else
          begin
            RepoMessage := T('repository-create-failed', Translations) + ': ' + RepoCreateError;
            RepoError := True;
            WriteLn(StdErr, 'Could not create repos/', RepoName, ': ', RepoCreateError);
          end;
        end;
      end
      else if (Action = T('upload', Translations)) or (Action = 'Lähetä') or (Action = 'LÃ¤hetÃ¤') then
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
      end
      else if Action = 'delete_repo_request' then
      begin
        RepoName := NormalizeRepoName(ARequest.ContentFields.Values['repo_name']);
        DownloadPath := GetRepoPath(RepoName);
        if (RepoName = '') or (not FileExists(DownloadPath)) then
        begin
          RepoMessage := T('error', Translations);
          RepoError := True;
        end
        else
          PendingDeleteRepo := RepoName;
      end
      else if Action = 'delete_repo_confirm' then
      begin
        RepoName := NormalizeRepoName(ARequest.ContentFields.Values['repo_name']);
        DownloadPath := GetRepoPath(RepoName);
        if (RepoName = '') or (not FileExists(DownloadPath)) then
        begin
          RepoMessage := T('error', Translations);
          RepoError := True;
        end
        else if DeleteFile(DownloadPath) then
          RepoMessage := T('delete', Translations)
        else
        begin
          RepoMessage := T('error', Translations);
          RepoError := True;
        end;
      end;
    end;

    Repos := GetReposList;
    if Username <> '' then
    begin
      HeaderRight := '';
      MainNav := BuildNavRow([
        BuildActionButton(ARequest, '/', 'nav-home', T('home', Translations)),
        BuildActionButton(ARequest, '/language', 'nav-language', T('language', Translations)),
        BuildActionButton(ARequest, '/settings', 'nav-settings', T('settings', Translations)),
        BuildActionButton(ARequest, '/people', 'nav-people', T('people', Translations)),
        BuildActionButton(ARequest, '/activity', 'nav-activity', T('activity', Translations)),
        BuildActionButton(ARequest, '/backups', 'nav-backups', T('backups', Translations)),
        BuildActionButton(ARequest, '/gitea', 'nav-gitea', T('gitea', Translations)),
        '<strong>' + HtmlEncode(Username) + '</strong>',
        BuildActionButton(ARequest, '/logout', 'nav-logout', T('logout', Translations))
      ]);
      CreateRepoAuth := BuildAuthHiddenFields(ARequest, 'home-create-repo');
      UploadRepoAuth := BuildAuthHiddenFields(ARequest, 'home-upload-repo');
      if PendingDeleteRepo <> '' then
        DeleteConfirmAuth := BuildAuthHiddenFields(ARequest, 'home-delete-repo-confirm-' + StringReplace(PendingDeleteRepo, '.omi', '', []))
      else
        DeleteConfirmAuth := '';
    end
    else
    begin
      HeaderRight := '';
      MainNav := BuildNavRow([
        '<a href="/">' + T('home', Translations) + '</a>',
        '<a href="/sign-in">' + T('login', Translations) + '</a>'
      ]);
      CreateRepoAuth := '';
      UploadRepoAuth := '';
      DeleteConfirmAuth := '';
    end;

    Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
      '<html dir="' + DirAttr + '"><head><meta charset="UTF-8"><title>Omi Server - ' + T('repositories', Translations) + '</title></head>' +
      '<body bgcolor="#f0f0f0" dir="' + DirAttr + '">' +
      '<table width="100%" border="0" cellpadding="5">' +
      '<tr><td><h1>Omi Server - ' + T('repositories', Translations) + '</h1></td><td align="right"><small>' +
      HeaderRight +
      '</small></td></tr></table>' +
      '<p>' + MainNav + '</p>' +
      '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
      '<tr bgcolor="#e8f4f8"><td colspan="4"><strong>' + T('server', Translations) + ':</strong> localhost<br>' +
      '<strong>' + T('protocol', Translations) + ':</strong> HTTP<br>' +
      '<strong>' + T('repositories', Translations) + ':</strong> ' + IntToStr(Length(Repos)) +
      ifthen(Username <> '', GiteaFolderLine(ARequest, Translations), '') + '</td></tr></table>' +
      ifthen(RepoMessage <> '', '<p><font color="' + ifthen(RepoError, 'red', 'green') + '"><strong>' + HtmlEncode(RepoMessage) + '</strong></font></p>', '') +
      ifthen(PendingDeleteRepo <> '', '<div style="border: 2px solid #ff0000; padding: 10px; background-color: #ffcccc; margin-bottom: 10px;"><p><font color="red"><strong>⚠️ ' + T('confirm-delete', Translations) + '</strong></font></p><p>' + T('delete-repository-question', Translations) + ' <strong>' + HtmlEncode(PendingDeleteRepo) + '</strong>?</p><form method="POST" style="display:inline"><input type="hidden" name="action" value="delete_repo_confirm"><input type="hidden" name="repo_name" value="' + HtmlEncode(PendingDeleteRepo) + '">' + DeleteConfirmAuth + '<input type="submit" value="' + T('confirm-delete', Translations) + '"></form> ' + BuildNavTargetButton(ARequest, '/', '/', 'home-delete-repo-cancel', T('cancel', Translations)) + '</div>', '') +
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
        RepoRootPath := '/' + HtmlEncode(StringReplace(Repos[I].Name, '.omi', '', []));
        DeleteRepoAuth := BuildAuthHiddenFields(ARequest, 'home-delete-repo-' + StringReplace(Repos[I].Name, '.omi', '', []));
        Html := Html + '<tr><td>' + BuildNavTargetButton(ARequest, '/', RepoRootPath, 'home-open-repo-' + IntToStr(I), Repos[I].Name) + '</td>' +
          '<td>' + HtmlEncode(SizeText) + '</td>' +
          '<td>' + HtmlEncode(FormatDateTime('yyyy-mm-dd hh:nn:ss', FileDateToDateTime(Repos[I].Modified))) + '</td>' +
          '<td>' + BuildNavTargetButton(ARequest, '/', '/?download=' + HtmlEncode(Repos[I].Name), 'home-download-repo-' + IntToStr(I), T('download', Translations)) +
          ' ' + BuildNavTargetButton(ARequest, '/', '/?log=' + HtmlEncode(Repos[I].Name), 'home-log-repo-' + IntToStr(I), T('log', Translations)) +
          ifthen(Username <> '', ' <form method="POST" style="display:inline"><input type="hidden" name="action" value="delete_repo_request"><input type="hidden" name="repo_name" value="' + HtmlEncode(Repos[I].Name) + '">' + DeleteRepoAuth + '<input type="submit" value="' + T('delete', Translations) + '"></form>', '') + '</td></tr>';
      end;
    end;

    Html := Html + '</table>';

    if Username <> '' then
    begin
      Html := Html + '<h2>' + T('create-repository', Translations) + '</h2>' +
        '<form method="POST"><table border="0" cellpadding="5">' +
        CreateRepoAuth +
        '<tr><td>' + T('repository-name', Translations) + ':</td><td><input type="text" name="repo_name" size="30"> (e.g., wekan.omi)</td></tr>' +
        '<tr><td colspan="2"><input type="hidden" name="action" value="create_repo"><input type="submit" value="' + T('create-repository', Translations) + '"></td></tr>' +
        '</table></form>' +
        '<h2>' + T('upload-repository', Translations) + '</h2>' +
        '<form method="POST" enctype="multipart/form-data">' +
        '<table border="0" cellpadding="5">' +
        UploadRepoAuth +
        '<tr><td>' + T('repository-name', Translations) + ':</td><td><input type="text" name="repo_name" size="30"> (e.g., wekan.omi)</td></tr>' +
        '<tr><td>' + T('file', Translations) + ':</td><td><input type="file" name="repo_file"></td></tr>' +
        '<tr><td colspan="2"><input type="submit" name="action" value="' + T('upload', Translations) + '"></td></tr>' +
        '</table></form>';
    end
    else
      Html := Html + '<p><a href="/sign-in">' + T('sign-in-to-upload', Translations) + '</a></p>';

    Html := Html + '<h2>' + T('api-endpoints', Translations) + '</h2>' +
      '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
      '<tr><td><strong>List repos (JSON):</strong></td><td>GET /?format=json</td></tr>' +
      '<tr><td><strong>Download repo:</strong></td><td>GET /?download=wekan.omi</td></tr>' +
      '<tr><td><strong>Upload repo:</strong></td><td>POST with repo_name, repo_file</td></tr>' +
      '</table>' +
      '<hr><p><small>Omi Server</small></p>' +
      '</body></html>';

    AResponse.Content := PrettyHtml32(Html);
    AResponse.ContentType := 'text/html; charset=UTF-8';
  finally
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

procedure LogoutEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  SessionId: string;
  Username: string;
  PostedAuthAction: string;
begin
  SessionId := GetSessionIdFromRequest(ARequest);
  Username := '';
  if SessionId <> '' then
    Username := Sessions.Values[SessionId];

  if (ARequest.Method = 'POST') and (Username <> '') then
  begin
    PostedAuthAction := GetFormFieldValue(ARequest, 'auth_action');
    if (PostedAuthAction = '') or not VerifyAndConsumeActionToken(ARequest, PostedAuthAction, SessionId, Username) then
    begin
      LogActivity(Username, SessionId, 'logout', 'forbidden', 'invalid token', ARequest, -1);
      RedirectToPublicHome(ARequest, AResponse);
      Exit;
    end;
  end;

  if SessionId <> '' then
  begin
    Sessions.Values[SessionId] := '';
    SessionMeta.Values[SessionId] := '';
    if Username <> '' then
      LogActivity(Username, SessionId, 'logout', 'ok', 'logout success', ARequest, -1);
  end;
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
      '<tr><td colspan="2"><a href="/">' + T('home', Translations) + '</a></td></tr>' +
      '</table>' +
      (ifthen(ErrorMsg <> '', '<p><font color="red"><strong>' + T('error', Translations) + ': ' + HtmlEncode(ErrorMsg) + '</strong></font></p>', '')) +
      (ifthen(SuccessMsg <> '', '<p><font color="green"><strong>' + HtmlEncode(SuccessMsg) + '</strong></font></p><p><a href="/sign-in">' + T('login', Translations) + '</a></p>', '')) +
      FormHtml +
      '</body></html>';
    AResponse.Content := PrettyHtml32(Html);
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
    AResponse.Content := PrettyHtml32(Html);
    AResponse.ContentType := 'text/html; charset=UTF-8';
  finally
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

function GitDescription: string; forward;
function GitFetchOptions(const Current: string): string; forward;

procedure SettingsEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Translations: TJSONObject;
  Html: string;
  Username: string;
  Password: string;
  Otp: string;
  CurrentLanguage: string;
  SettingsMap: TStringList;
  ErrorMsg: string;
  SessionId: string;
  PostedAuthAction: string;
  HeaderRight: string;
  MainNav: string;
  UserPassword: string;
  UserOtp: string;
  UserLang: string;
  SaveAuth: string;
  UsersMap: TStringList;
  GiteaKey: string;
  TokenList: TStringList;
begin
  Username := GetUsernameFromRequest(ARequest);
  SessionId := GetSessionIdFromRequest(ARequest);
  if Username = '' then
  begin
    RedirectToPublicHome(ARequest, AResponse);
    Exit;
  end;

  CurrentLanguage := '';
  UsersMap := LoadUsersMap;
  try
    if not GetUserData(UsersMap, Username, Password, Otp, CurrentLanguage) then
      CurrentLanguage := '';
  finally
    UsersMap.Free;
  end;

  if CurrentLanguage = '' then
    CurrentLanguage := GetBrowserLanguage(ARequest);
  if CurrentLanguage = '' then
    CurrentLanguage := 'en';

  Translations := LoadTranslations(CurrentLanguage);
  try
    SettingsMap := LoadSettingsMap;
    try
      ErrorMsg := '';
      if ARequest.Method = 'POST' then
      begin
        PostedAuthAction := GetFormFieldValue(ARequest, 'auth_action');
        if (PostedAuthAction = '') or not VerifyAndConsumeActionToken(ARequest,
          PostedAuthAction, SessionId, Username) then
        begin
          RedirectToPublicHome(ARequest, AResponse);
          Exit;
        end;
        if ARequest.ContentFields.Values['USERNAME'] <> '' then
          SettingsMap.Values['USERNAME'] := ARequest.ContentFields.Values['USERNAME'];
        if ARequest.ContentFields.Values['PASSWORD'] <> '' then
          SettingsMap.Values['PASSWORD'] := ARequest.ContentFields.Values['PASSWORD'];
        if ARequest.ContentFields.Values['REPOS'] <> '' then
          SettingsMap.Values['REPOS'] := ARequest.ContentFields.Values['REPOS'];
        if ARequest.ContentFields.Values['CURL'] <> '' then
          SettingsMap.Values['CURL'] := ARequest.ContentFields.Values['CURL'];
        if ARequest.ContentFields.Values['BACKUPS_DIR'] <> '' then
          SettingsMap.Values['BACKUPS_DIR'] := Trim(ARequest.ContentFields.Values['BACKUPS_DIR']);
        // The Gitea folder: an empty field clears the setting.
        if ARequest.ContentFields.IndexOfName('GITEA_APP_INI') >= 0 then
          SettingsMap.Values['GITEA_APP_INI'] := Trim(ARequest.ContentFields.Values['GITEA_APP_INI']);
        if ARequest.ContentFields.IndexOfName('GITEA_TREE') >= 0 then
          SettingsMap.Values['GITEA_TREE'] := Trim(ARequest.ContentFields.Values['GITEA_TREE']);
        for GiteaKey in ['GITEA_PID_FILE', 'GITEA_DOER', 'GITEA_BINARY', 'GITHUB_TO_GITEA_DIR',
          'SYNC_EXCLUDE_FILE', 'GIT', 'GIT_FETCH'] do
          if ARequest.ContentFields.IndexOfName(GiteaKey) >= 0 then
            SettingsMap.Values[GiteaKey] := Trim(ARequest.ContentFields.Values[GiteaKey]);
        // The GitHub token goes to its own file (mode 0600), never into
        // settings.ini and never back into a page.
        if Trim(ARequest.ContentFields.Values['GITHUB_TOKEN']) <> '' then
        begin
          TokenList := TStringList.Create;
          try
            TokenList.Text := Trim(ARequest.ContentFields.Values['GITHUB_TOKEN']);
            try
              TokenList.SaveToFile(GetGithubTokenFile);
              GtChmod(GetGithubTokenFile, &600);
            except
              ErrorMsg := T('settings-update-failed', Translations);
            end;
          finally
            TokenList.Free;
          end;
        end;

        if not SaveSettingsMap(SettingsMap) then
          ErrorMsg := T('settings-update-failed', Translations);
      end;

      if SettingsMap.Values['CURL'] = '' then
        SettingsMap.Values['CURL'] := 'curl';

      HeaderRight := '';
      MainNav := BuildNavRow([
        BuildActionButton(ARequest, '/', 'nav-home', T('home', Translations)),
        BuildActionButton(ARequest, '/language', 'nav-language', T('language', Translations)),
        BuildActionButton(ARequest, '/settings', 'nav-settings', T('settings', Translations)),
        BuildActionButton(ARequest, '/people', 'nav-people', T('people', Translations)),
        BuildActionButton(ARequest, '/activity', 'nav-activity', T('activity', Translations)),
        BuildActionButton(ARequest, '/backups', 'nav-backups', T('backups', Translations)),
        BuildActionButton(ARequest, '/gitea', 'nav-gitea', T('gitea', Translations)),
        '<strong>' + HtmlEncode(Username) + '</strong>',
        BuildActionButton(ARequest, '/logout', 'nav-logout', T('logout', Translations))
      ]);
      SaveAuth := BuildAuthHiddenFields(ARequest, 'settings-save');

      Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
        '<html><head><meta charset="UTF-8"><title>' + T('settings', Translations) + ' - Omi Server</title></head>' +
        '<body bgcolor="#f0f0f0">' +
        '<table width="100%" border="0" cellpadding="5">' +
        '<tr><td><h1>' + T('settings', Translations) + '</h1></td>' +
        '<td align="right"><small>' + HeaderRight + '</small></td></tr>' +
        '</table>' +
        '<p>' + MainNav + '</p>' +
        '<hr>' +
        (ifthen(ErrorMsg <> '', '<p><font color="red"><strong>' + HtmlEncode(ErrorMsg) + '</strong></font></p>', '')) +
        '<form method="POST">' +
        SaveAuth +
        '<table border="1" cellpadding="5">' +
        '<tr><td>USERNAME:</td><td><input type="text" name="USERNAME" size="50" value="' + HtmlEncode(SettingsMap.Values['USERNAME']) + '"></td></tr>' +
        '<tr><td>PASSWORD:</td><td><input type="password" name="PASSWORD" size="50" value="' + HtmlEncode(SettingsMap.Values['PASSWORD']) + '"></td></tr>' +
        '<tr><td>REPOS (server URL):</td><td><input type="text" name="REPOS" size="50" value="' + HtmlEncode(SettingsMap.Values['REPOS']) + '"></td></tr>' +
        '<tr><td>CURL executable:</td><td><input type="text" name="CURL" size="50" value="' + HtmlEncode(SettingsMap.Values['CURL']) + '"></td></tr>' +
        '<tr><td>BACKUPS_DIR (' + HtmlEncode(T('backups-directory', Translations)) + '):</td><td><input type="text" name="BACKUPS_DIR" size="50" value="' + HtmlEncode(SettingsMap.Values['BACKUPS_DIR']) + '"></td></tr>' +
        '<tr><td>GITEA_APP_INI (' + HtmlEncode(T('gitea-app-ini', Translations)) + '):</td><td><input type="text" name="GITEA_APP_INI" size="50" value="' + HtmlEncode(SettingsMap.Values['GITEA_APP_INI']) + '"></td></tr>' +
        '<tr><td>GITEA_TREE (' + HtmlEncode(T('gitea-tree', Translations)) + '):</td><td><input type="text" name="GITEA_TREE" size="50" value="' + HtmlEncode(SettingsMap.Values['GITEA_TREE']) + '"></td></tr>' +
        '<tr><td>GITEA_PID_FILE:</td><td><input type="text" name="GITEA_PID_FILE" size="50" value="' + HtmlEncode(SettingsMap.Values['GITEA_PID_FILE']) + '"></td></tr>' +
        '<tr><td>GITEA_DOER (' + HtmlEncode(T('gitea-doer', Translations)) + '):</td><td><input type="text" name="GITEA_DOER" size="50" value="' + HtmlEncode(SettingsMap.Values['GITEA_DOER']) + '"></td></tr>' +
        '<tr><td>GITEA_BINARY:</td><td><input type="text" name="GITEA_BINARY" size="50" value="' + HtmlEncode(SettingsMap.Values['GITEA_BINARY']) + '"></td></tr>' +
        '<tr><td>GIT:</td><td><input type="text" name="GIT" size="50" value="' + HtmlEncode(SettingsMap.Values['GIT']) + '"><br><small>' + HtmlEncode(GitDescription) + '</small></td></tr>' +
        '<tr><td>GIT_FETCH:</td><td><select name="GIT_FETCH">' + GitFetchOptions(SettingsMap.Values['GIT_FETCH']) + '</select></td></tr>' +
        '<tr><td>GITHUB_TO_GITEA_DIR:</td><td><input type="text" name="GITHUB_TO_GITEA_DIR" size="50" value="' + HtmlEncode(SettingsMap.Values['GITHUB_TO_GITEA_DIR']) + '"></td></tr>' +
        '<tr><td>SYNC_EXCLUDE_FILE (' + HtmlEncode(T('gitea-sync-exclude-file', Translations)) + '):</td><td><input type="text" name="SYNC_EXCLUDE_FILE" size="50" value="' + HtmlEncode(SettingsMap.Values['SYNC_EXCLUDE_FILE']) + '"></td></tr>' +
        '<tr><td>GITHUB_TOKEN (' + HtmlEncode(T('gitea-github-token', Translations)) + ': ' + HtmlEncode(ifthen(FileExists(GetGithubTokenFile), T('gitea-token-set', Translations), T('gitea-token-not-set', Translations))) + '):</td><td><input type="password" name="GITHUB_TOKEN" size="50" value=""></td></tr>' +
        '<tr><td colspan="2"><input type="submit" value="' + T('save', Translations) + '"></td></tr>' +
        '</table>' +
        '</form>' +
        // Test the saved token: its own form, beside the settings form.
        ifthen(FileExists(GetGithubTokenFile), '<p>' + BuildActionButton(ARequest, '/gitea/token', 'gitea-token-test',
          T('gitea-token-test', Translations)) + '</p>', '') +
        '<hr>' +
        '<p><small>Omi Server</small></p>' +
        '</body></html>';
    finally
      SettingsMap.Free;
    end;
    AResponse.Content := PrettyHtml32(Html);
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
  UpdatedLanguage: Boolean;
  FormHtml: string;
  SessionId: string;
  PostedAuthAction: string;
  HeaderRight: string;
  MainNav: string;
begin
  Username := GetUsernameFromRequest(ARequest);
  SessionId := GetSessionIdFromRequest(ARequest);
  if Username = '' then
  begin
    RedirectToPublicHome(ARequest, AResponse);
    Exit;
  end;

  UsersMap := LoadUsersMap;
  UpdatedLanguage := False;
  try
    if not GetUserData(UsersMap, Username, Password, Otp, CurrentLanguage) then
      CurrentLanguage := 'en';

    if ARequest.Method = 'POST' then
    begin
      PostedAuthAction := GetFormFieldValue(ARequest, 'auth_action');
      if (PostedAuthAction = '') or not VerifyAndConsumeActionToken(ARequest,
        PostedAuthAction, SessionId, Username) then
      begin
        RedirectToPublicHome(ARequest, AResponse);
        Exit;
      end;
      if ARequest.ContentFields.Values['language'] <> '' then
      begin
        CurrentLanguage := ARequest.ContentFields.Values['language'];
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
    LangData := LoadLanguagesData;
    try
      HeaderRight := '';
      MainNav := BuildNavRow([
        BuildActionButton(ARequest, '/', 'nav-home', T('home', Translations)),
        BuildActionButton(ARequest, '/language', 'nav-language', T('language', Translations)),
        BuildActionButton(ARequest, '/settings', 'nav-settings', T('settings', Translations)),
        BuildActionButton(ARequest, '/people', 'nav-people', T('people', Translations)),
        BuildActionButton(ARequest, '/activity', 'nav-activity', T('activity', Translations)),
        BuildActionButton(ARequest, '/backups', 'nav-backups', T('backups', Translations)),
        BuildActionButton(ARequest, '/gitea', 'nav-gitea', T('gitea', Translations)),
        '<strong>' + HtmlEncode(Username) + '</strong>',
        BuildActionButton(ARequest, '/logout', 'nav-logout', T('logout', Translations))
      ]);

      FormHtml := '<form method="POST">' + BuildAuthHiddenFields(ARequest, 'language-save') + '<table border="1" cellpadding="5">' +
        '<tr bgcolor="#333333"><th><font color="white">' + T('language', Translations) + '</font></th></tr>';

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
        '<input type="submit" value="' + T('save', Translations) + '">' +
        '</form>';

      Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
        '<html>' +
        '<head><meta charset="UTF-8"><title>' + T('language', Translations) + ' - Omi Server</title></head>' +
        '<body bgcolor="#f0f0f0">' +
        '<table width="100%" border="0" cellpadding="5">' +
        '<tr><td><h1>Omi Server</h1></td><td align="right"><small>' + HeaderRight + '</small></td></tr>' +
        '</table>' +
        '<p>' + MainNav + '</p>' +
        '<hr>' +
        '<h2>' + T('language', Translations) + '</h2>' +
        FormHtml +
        '<hr>' +
        '<p><small>Omi Server</small></p>' +
        '</body></html>';
    finally
      LangData.Free;
    end;
    AResponse.Content := PrettyHtml32(Html);
    AResponse.ContentType := 'text/html; charset=UTF-8';
  finally
    if Assigned(Translations) then
      Translations.Free;
  end;
end;

procedure ActivityEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Username: string;
  SessionId: string;
  UsersMap: TStringList;
  UserPassword: string;
  UserOtp: string;
  UserLang: string;
  Translations: TJSONObject;
  PostedAuthAction: string;
  Output: string;
  Lines: TStringArray;
  Parts: TStringArray;
  I: Integer;
  Rows: string;
  Html: string;
begin
  Username := GetUsernameFromRequest(ARequest);
  SessionId := GetSessionIdFromRequest(ARequest);
  if Username = '' then
  begin
    RedirectToPublicHome(ARequest, AResponse);
    Exit;
  end;

  UsersMap := LoadUsersMap;
  try
    UserLang := 'en';
    if GetUserData(UsersMap, Username, UserPassword, UserOtp, UserLang) then
      UserLang := Trim(UserLang);
  finally
    UsersMap.Free;
  end;
  if UserLang = '' then
    UserLang := 'en';
  Translations := LoadTranslations(UserLang);
  try

  if ARequest.Method = 'POST' then
  begin
    PostedAuthAction := GetFormFieldValue(ARequest, 'auth_action');
    if (PostedAuthAction = '') or not VerifyAndConsumeActionToken(ARequest,
      PostedAuthAction, SessionId, Username) then
    begin
      RedirectToPublicHome(ARequest, AResponse);
      Exit;
    end;
  end;

  EnsureActivityDb;
  Output := ExecSqlOnDb(DataPath(ACTIVITY_DB_FILE),
    'SELECT ip, user_agent, COUNT(*), datetime(MIN(event_time), ''unixepoch''), datetime(MAX(event_time), ''unixepoch''), GROUP_CONCAT(DISTINCT username) ' +
    'FROM activity GROUP BY ip, user_agent ORDER BY MAX(event_time) DESC;');

  Rows := '';
  Lines := Output.Split([#10]);
  for I := 0 to High(Lines) do
  begin
    if Trim(Lines[I]) = '' then
      Continue;
    Parts := Lines[I].Split(['|']);
    if Length(Parts) >= 6 then
      Rows := Rows + '<tr><td>' + HtmlEncode(Parts[0]) + '</td><td>' + HtmlEncode(Parts[1]) + '</td><td>' + HtmlEncode(Parts[5]) + '</td><td>' + HtmlEncode(Parts[2]) + '</td><td>' + HtmlEncode(Parts[3]) + '</td><td>' + HtmlEncode(Parts[4]) + '</td></tr>';
  end;
  if Rows = '' then
    Rows := '<tr><td colspan="6">' + TE('no-activity-yet', Translations) + '</td></tr>';

  Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
    '<html><head><meta charset="UTF-8"><title>' + TE('activity', Translations) + ' - Omi Server</title></head><body bgcolor="#f0f0f0">' +
    '<table width="100%" border="0" cellpadding="5"><tr><td><h1>' + TE('activity', Translations) + '</h1></td><td align="right"><small></small></td></tr></table>' +
    BuildNavRow([
      BuildActionButton(ARequest, '/', 'nav-home', T('home', Translations)),
      BuildActionButton(ARequest, '/language', 'nav-language', T('language', Translations)),
      BuildActionButton(ARequest, '/settings', 'nav-settings', T('settings', Translations)),
      BuildActionButton(ARequest, '/people', 'nav-people', T('people', Translations)),
      BuildActionButton(ARequest, '/activity', 'nav-activity', T('activity', Translations)),
      BuildActionButton(ARequest, '/backups', 'nav-backups', T('backups', Translations)),
      BuildActionButton(ARequest, '/gitea', 'nav-gitea', T('gitea', Translations)),
      '<strong>' + HtmlEncode(Username) + '</strong>',
      BuildActionButton(ARequest, '/logout', 'nav-logout', T('logout', Translations))
    ]) +
    '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
    '<tr bgcolor="#333333"><th><font color="white">' + TE('ip-address', Translations) + '</font></th><th><font color="white">' + TE('user-agent', Translations) + '</font></th><th><font color="white">' + TE('users', Translations) + '</font></th><th><font color="white">' + TE('events', Translations) + '</font></th><th><font color="white">' + TE('first-unix', Translations) + '</font></th><th><font color="white">' + TE('last-unix', Translations) + '</font></th></tr>' +
    Rows + '</table><hr><p><small>Omi Server</small></p></body></html>';

  AResponse.ContentType := 'text/html; charset=UTF-8';
  AResponse.Content := PrettyHtml32(Html);
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
  OldUser: string;
  RenamedUser: string;
  NewOtp: string;
  UsersTable: string;
  SelfUser: string;
  SessionId: string;
  PostedAuthAction: string;
  HeaderRight: string;
  MainNav: string;
  UserPassword: string;
  UserOtp: string;
  UserLang: string;
  UserValue: string;

begin
  Username := GetUsernameFromRequest(ARequest);
  SessionId := GetSessionIdFromRequest(ARequest);
  if Username = '' then
  begin
    RedirectToPublicHome(ARequest, AResponse);
    Exit;
  end;

  UsersMap := LoadUsersMap;
  UserLang := 'en';
  if GetUserData(UsersMap, Username, UserPassword, UserOtp, UserLang) then
    UserLang := Trim(UserLang);
  if UserLang = '' then
    UserLang := 'en';
  Translations := LoadTranslations(UserLang);
  try
    SuccessMsg := '';
    ErrorMsg := '';
    Action := ARequest.ContentFields.Values['action'];

    if (ARequest.Method = 'POST') and (Action <> '') then
    begin
      PostedAuthAction := GetFormFieldValue(ARequest, 'auth_action');
      if (PostedAuthAction = '') or not VerifyAndConsumeActionToken(ARequest, PostedAuthAction, SessionId, Username) then
      begin
        RedirectToPublicHome(ARequest, AResponse);
        Exit;
      end;

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
            SuccessMsg := T('save', Translations);
          end
          else
            ErrorMsg := T('error', Translations);
        end
        else
          ErrorMsg := T('error', Translations);
      end
      else if Action = 'update_username' then
      begin
        OldUser := Trim(ARequest.ContentFields.Values['olduser']);
        RenamedUser := Trim(ARequest.ContentFields.Values['renameduser']);
        if (OldUser <> '') and (RenamedUser <> '') and GetUserData(UsersMap, OldUser, Password, Otp, Language) then
        begin
          if SameText(OldUser, RenamedUser) or (UsersMap.Values[RenamedUser] = '') then
          begin
            UserValue := Password + USER_VALUE_SEP + Otp + USER_VALUE_SEP + Language;
            if not SameText(OldUser, RenamedUser) then
              UsersMap.Values[OldUser] := '';
            UsersMap.Values[RenamedUser] := UserValue;
            SaveUsersMap(UsersMap);
            SuccessMsg := T('save', Translations);
          end
          else
            ErrorMsg := T('error', Translations);
        end
        else
          ErrorMsg := T('error', Translations);
      end
      else if Action = 'delete' then
      begin
        DelUser := ARequest.ContentFields.Values['deluser'];
        if UsersMap.Values[DelUser] <> '' then
        begin
          UsersMap.Values[DelUser] := '';
          SaveUsersMap(UsersMap);
          SuccessMsg := T('save', Translations);
        end
        else
          ErrorMsg := T('error', Translations);
      end
      else if Action = 'update_password' then
      begin
        UpUser := ARequest.ContentFields.Values['upuser'];
        UpPass := ARequest.ContentFields.Values['uppass'];
        if (UpUser <> '') and (UpPass <> '') and GetUserData(UsersMap, UpUser, Password, Otp, Language) then
        begin
          UsersMap.Values[UpUser] := UpPass + USER_VALUE_SEP + Otp + USER_VALUE_SEP + Language;
          SaveUsersMap(UsersMap);
          SuccessMsg := T('save', Translations);
        end
        else
          ErrorMsg := T('error', Translations);
      end
      else if Action = 'update_otp' then
      begin
        OtpUser := ARequest.ContentFields.Values['otpuser'];
        NewOtp := Trim(ARequest.ContentFields.Values['newotp']);
        if GetUserData(UsersMap, OtpUser, Password, Otp, Language) then
        begin
          UsersMap.Values[OtpUser] := Password + USER_VALUE_SEP + NewOtp + USER_VALUE_SEP + Language;
          SaveUsersMap(UsersMap);
          SuccessMsg := T('save', Translations);
        end
        else
          ErrorMsg := T('error', Translations);
      end;
    end;

    UsersTable := '';

    for I := 0 to UsersMap.Count - 1 do
    begin
      UserKey := UsersMap.Names[I];
      if UserKey = '' then
        Continue;
      if not GetUserData(UsersMap, UserKey, Password, Otp, Language) then
        Continue;

      UsersTable := UsersTable + '<tr><td>' + HtmlEncode(UserKey) + '<br>' +
        '<form method="POST" style="display:inline">' +
        BuildAuthHiddenFields(ARequest, 'people-update-username-' + UserKey) +
        '<input type="hidden" name="action" value="update_username">' +
        '<input type="hidden" name="olduser" value="' + HtmlEncode(UserKey) + '">' +
        '<input type="text" name="renameduser" size="24" value="' + HtmlEncode(UserKey) + '" required>' +
        '<br><input type="submit" value="' + T('save', Translations) + '"></form></td>' +
        '<td><form method="POST" style="display:inline">' +
        BuildAuthHiddenFields(ARequest, 'people-update-password-' + UserKey) +
        '<input type="hidden" name="action" value="update_password">' +
        '<input type="hidden" name="upuser" value="' + HtmlEncode(UserKey) + '">' +
        '<input type="password" name="uppass" size="24" required>' +
        '<br><input type="submit" value="' + T('save', Translations) + '"></form></td>' +
        '<td>' + ifthen(Otp = '', T('no', Translations), 'Yes') + '<br>' +
        '<form method="POST" style="display:inline">' +
        BuildAuthHiddenFields(ARequest, 'people-update-otp-' + UserKey) +
        '<input type="hidden" name="action" value="update_otp">' +
        '<input type="hidden" name="otpuser" value="' + HtmlEncode(UserKey) + '">' +
        '<input type="text" name="newotp" size="24" value="' + HtmlEncode(Otp) + '">' +
        '<br><input type="submit" value="' + T('save', Translations) + '"></form></td>' +
        '<td><form method="POST" style="display:inline">' +
        BuildAuthHiddenFields(ARequest, 'people-delete-' + UserKey) +
        '<input type="hidden" name="action" value="delete">' +
        '<input type="hidden" name="deluser" value="' + HtmlEncode(UserKey) + '">' +
        '<input type="submit" value="' + T('delete', Translations) + '"></form></td></tr>';
    end;

    HeaderRight := '';
    MainNav := BuildNavRow([
      BuildActionButton(ARequest, '/', 'nav-home', T('home', Translations)),
      BuildActionButton(ARequest, '/language', 'nav-language', T('language', Translations)),
      BuildActionButton(ARequest, '/settings', 'nav-settings', T('settings', Translations)),
      BuildActionButton(ARequest, '/people', 'nav-people', T('people', Translations)),
      BuildActionButton(ARequest, '/activity', 'nav-activity', T('activity', Translations)),
      BuildActionButton(ARequest, '/backups', 'nav-backups', T('backups', Translations)),
      BuildActionButton(ARequest, '/gitea', 'nav-gitea', T('gitea', Translations)),
      '<strong>' + HtmlEncode(Username) + '</strong>',
      BuildActionButton(ARequest, '/logout', 'nav-logout', T('logout', Translations))
    ]);

    Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
      '<html><head><meta charset="UTF-8"><title>' + T('people', Translations) + ' - Omi Server</title></head>' +
      '<body bgcolor="#f0f0f0">' +
      '<table width="100%" border="0" cellpadding="5">' +
      '<tr><td><h1>' + T('people', Translations) + '</h1></td><td align="right"><small>' + HeaderRight + '</small></td></tr>' +
      '</table>' +
      '<p>' + MainNav + '</p>' +
      '<hr>' +
      ifthen(SuccessMsg <> '', '<p><font color="green"><strong>' + HtmlEncode(SuccessMsg) + '</strong></font></p>', '') +
      ifthen(ErrorMsg <> '', '<p><font color="red"><strong>' + HtmlEncode(ErrorMsg) + '</strong></font></p>', '') +
      '<h2>New User</h2>' +
      '<form method="POST"><table border="0" cellpadding="5">' +
      BuildAuthHiddenFields(ARequest, 'people-add-user') +
      '<tr><td>' + T('username', Translations) + ':</td><td><input type="text" name="newuser" size="30" required></td></tr>' +
      '<tr><td>' + T('password', Translations) + ':</td><td><input type="password" name="newpass" size="30" required></td></tr>' +
      '<tr><td colspan="2"><input type="hidden" name="action" value="add"><input type="submit" value="' + T('save', Translations) + '"></td></tr>' +
      '</table></form>' +
      '<h2>Users</h2>' +
      '<table border="1" cellpadding="5" width="100%">' +
      '<tr bgcolor="#333333"><th><font color="white">Users</font></th><th><font color="white">' + T('password', Translations) + '</font></th><th><font color="white">' + T('otp', Translations) + '</font></th><th><font color="white">' + T('actions', Translations) + '</font></th></tr>' +
      UsersTable +
      '</table>' +
      '<hr><p><small>Omi Server</small></p>' +
      '</body></html>';

    AResponse.Content := PrettyHtml32(Html);
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
  J: Integer;
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
  FileSizeText: string;
  FileModifiedText: string;
  FileUploadedText: string;
  FileUploaderText: string;
  NewContent: string;
  MarkdownHtml: string;
  Base64Data: string;
  MimeType: string;
  IsMarkdown: Boolean;
  IsImage: Boolean;
  DirHeader: string;
  IsTextFile: Boolean;
  LowerName: string;
  EditButton: string;
  ParentDirRow: string;
  ParentUrl: string;
  ImgStart: Integer;
  ImgEnd: Integer;
  SrcStart: Integer;
  SrcEnd: Integer;
  ImgUrl: string;
  ResolvedPath: string;
  Base64Img: string;
  DataUri: string;
  ImgContent: string;
  Query: string;
  Output: string;
  FileDir: string;
  FileParentPath: string;
  SessionId: string;
  PostedAuthAction: string;
  HeaderRight: string;
  MainNav: string;
  CurrentPath: string;
  CommitParam: string;
  SelectedCommitId: Int64;
  IsHistoricView: Boolean;

  function WithCommit(const Target: string): string;
  begin
    Result := Target;
    if (SelectedCommitId > 0) and (Pos('commit=', LowerCase(Result)) = 0) then
    begin
      if Pos('?', Result) > 0 then
        Result := Result + '&commit=' + IntToStr(SelectedCommitId)
      else
        Result := Result + '?commit=' + IntToStr(SelectedCommitId);
    end;
  end;

  function RepoToRoot(const Name: string): string;
  begin
    Result := '/' + StringReplace(Name, '.omi', '', []);
  end;

  function PublicReloadTarget: string;
  begin
    Result := PathInfo;
    if ARequest.QueryFields.Values['commit'] <> '' then
      Result := Result + '?commit=' +
        IntToStr(StrToInt64Def(ARequest.QueryFields.Values['commit'], 0));
  end;

  function BuildRepoBreadcrumb(IsFileView: Boolean): string;
  var
    BreadcrumbParts: TStringArray;
    BreadcrumbPath: string;
    BreadcrumbTarget: string;
    K: Integer;
  begin
    Result := '<p>' + BuildNavTargetButton(ARequest, CurrentPath,
      WithCommit(RepoToRoot(RepoName)), 'repo-breadcrumb-root', RepoName);
    if RepoPath <> '' then
    begin
      BreadcrumbParts := RepoPath.Split(['/']);
      BreadcrumbPath := '';
      for K := 0 to High(BreadcrumbParts) do
      begin
        if BreadcrumbParts[K] = '' then
          Continue;
        Result := Result + ' / ';
        if BreadcrumbPath <> '' then
          BreadcrumbPath := BreadcrumbPath + '/';
        BreadcrumbPath := BreadcrumbPath + BreadcrumbParts[K];
        if IsFileView and (K = High(BreadcrumbParts)) then
          Result := Result + HtmlEncode(BreadcrumbParts[K]) + ' (' +
            HtmlEncode(GetFileTypeLabel(BreadcrumbParts[K])) + ')'
        else
        begin
          BreadcrumbTarget := RepoToRoot(RepoName) + '/' + BreadcrumbPath;
          Result := Result + BuildNavTargetButton(ARequest, CurrentPath,
            WithCommit(BreadcrumbTarget), 'repo-breadcrumb-' + IntToStr(K),
            BreadcrumbParts[K]);
        end;
      end;
    end;
    Result := Result + '</p>';
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
    AResponse.Content := T('error', FallbackTranslations);
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
    AResponse.Content := T('error', FallbackTranslations);
    Exit;
  end;

  Username := GetUsernameFromRequest(ARequest);
  SessionId := GetSessionIdFromRequest(ARequest);
  CurrentPath := PathInfo;
  Translations := LoadTranslations('en');
  try
    DownloadFlag := ARequest.QueryFields.Values['download'];
    DeleteFlag := ARequest.QueryFields.Values['delete'];
    EditFlag := ARequest.QueryFields.Values['edit'];
    CommitParam := ARequest.QueryFields.Values['commit'];
    SelectedCommitId := StrToInt64Def(CommitParam, 0);
    IsHistoricView := SelectedCommitId > 0;

    Files := GetLatestFiles(DbPath, RepoPath, SelectedCommitId);
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

    if ARequest.Method = 'POST' then
    begin
      PostedAuthAction := GetFormFieldValue(ARequest, 'auth_action');
      if (PostedAuthAction = '') or not VerifyAndConsumeActionToken(ARequest,
        PostedAuthAction, SessionId, Username) then
      begin
        AResponse.Code := 303;
        AResponse.Location := PublicReloadTarget;
        AResponse.Content := '';
        Exit;
      end;
    end;

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

      ShowDeleteConfirm := (DeleteFlag = '1') and (Username <> '') and not IsHistoricView;

      FileContent := GetFileContentByHash(DbPath, FileHash);
      IsText := IsTextContent(FileContent);
      InEdit := (EditFlag = '1') and (Username <> '') and IsText and not IsHistoricView;

      if (ARequest.Method = 'POST') and (ARequest.ContentFields.Values['save_file'] <> '') and IsText and (Username <> '') and not IsHistoricView then
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
        BuildNavRow([
          BuildActionButton(ARequest, '/', 'nav-home', T('home', Translations)),
          ifthen(Username <> '', BuildActionButton(ARequest, '/language', 'nav-language', T('language', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/settings', 'nav-settings', T('settings', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/people', 'nav-people', T('people', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/activity', 'nav-activity', T('activity', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/backups', 'nav-backups', T('backups', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/gitea', 'nav-gitea', T('gitea', Translations)), ''),
          ifthen(Username <> '', '<strong>' + HtmlEncode(Username) + '</strong>', '<a href="/sign-in">' + T('login', Translations) + '</a>'),
          ifthen(Username <> '', BuildActionButton(ARequest, '/logout', 'nav-logout', T('logout', Translations)), ''),
          BuildNavTargetButton(ARequest, CurrentPath, WithCommit('/?log=' + HtmlEncode(RepoName)), 'repo-nav-log', T('log', Translations)),
          BuildNavTargetButton(ARequest, CurrentPath, WithCommit(RepoToRoot(RepoName)), 'repo-nav-root', T('repository-root', Translations)),
          ifthen(IsHistoricView, BuildNavTargetButton(ARequest, CurrentPath,
            RepoToRoot(RepoName), 'repo-file-latest', T('latest', Translations)), '')
        ]) +
        BuildRepoBreadcrumb(True) +
        ifthen(IsHistoricView, '<p><font color="blue"><strong>' + T('viewing-commit', Translations) + ' ' + IntToStr(SelectedCommitId) + '</strong></font></p>', '');

      if ShowDeleteConfirm then
      begin
        FileParentPath := ExtractFileDir(RepoPath);
        if FileParentPath = '.' then
          FileParentPath := '';
        FileParentPath := RepoToRoot(RepoName) +
          ifthen(FileParentPath <> '', '/' + FileParentPath, '');
        Html := Html + '<div style="border:2px solid #ff0000; padding:10px; background-color:#ffcccc;">' +
          '<p><font color="red"><strong>⚠️ ' + T('confirm-delete', Translations) + '</strong></font></p>' +
          '<p>' + T('delete-file-question', Translations) + ' <strong>' + HtmlEncode(RepoPath) + '</strong>?</p>' +
          '<p>' + T('delete-file-warning', Translations) + '</p>' +
          '<form method="POST" action="' + HtmlEncode(FileParentPath) + '">' +
          BuildAuthHiddenFields(ARequest, 'repo-file-confirm-delete') +
          BuildHiddenInput('action', 'delete_file') +
          BuildHiddenInput('target', ExtractFileName(RepoPath)) +
          '<input type="submit" value="' + T('confirm-delete', Translations) + '"></form> | ' +
          BuildNavTargetButton(ARequest, CurrentPath, CurrentPath,
            'repo-file-cancel-delete', T('cancel', Translations)) +
          '</div><hr>';
      end
      else
      begin
        if (Username <> '') and not IsHistoricView then
        begin
          Html := Html + '<div style="display:flex; align-items:center; justify-content:space-between; gap:12px;">' +
            '<div>' + BuildNavTargetButton(ARequest, CurrentPath, WithCommit(CurrentPath + '?download=1'), 'repo-file-download', T('download', Translations)) +
            ifthen(IsText, BuildNavTargetButton(ARequest, CurrentPath, WithCommit(CurrentPath + '?edit=1'), 'repo-file-edit', T('edit', Translations)), '') +
            '</div><div>' + BuildNavTargetButton(ARequest, CurrentPath, WithCommit(CurrentPath + '?delete=1'), 'repo-file-delete-prompt', T('delete', Translations)) + '</div></div>';
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
          BuildAuthHiddenFields(ARequest, 'repo-file-save') +
          '<textarea name="file_content" rows="20" cols="80" style="width:100%; max-width:800px; font-family:monospace; box-sizing:border-box;">' + HtmlEncode(FileContent) + '</textarea><br><br>' +
          '<input type="submit" name="save_file" value="Save"></form> ' +
          BuildNavTargetButton(ARequest, CurrentPath, CurrentPath,
            'repo-file-cancel-edit', T('cancel', Translations));
      end
      else if IsText then
      begin
        IsMarkdown := IsMarkdownFile(RepoPath);
        if IsMarkdown then
        begin
          MarkdownHtml := MarkdownToHtml(FileContent);
          
          // Embed images in markdown as base64 data URIs
          FileDir := ExtractFileDir(RepoPath);
          try
            SrcEnd := 0;  // Loop counter  
            while SrcEnd < 50 do
            begin
              Inc(SrcEnd);
              
              // Find next <img src="..." tag
              ImgStart := Pos('<img src="', MarkdownHtml);
              if ImgStart = 0 then Break;
              
              // Calculate position of the URL (after '<img src="')
              SrcStart := ImgStart + 10;
              
              // Find closing quote of src value
              ImgEnd := Pos('"', Copy(MarkdownHtml, SrcStart, 500));
              if ImgEnd <= 0 then Break;
              
              // Extract URL
              ImgUrl := Copy(MarkdownHtml, SrcStart, ImgEnd - 1);
              
              // Skip if already embedded or external
              if (Pos('data:', ImgUrl) > 0) or (Pos('http://', ImgUrl) > 0) or (Pos('https://', ImgUrl) > 0) then
                Continue;
              
              // Resolve full path
              if FileDir <> '.' then
                ResolvedPath := FileDir + '/' + ImgUrl
              else
                ResolvedPath := ImgUrl;
              
              // First try with full path, then try just the filename
              Query := 'SELECT hex(b.data) FROM files f JOIN blobs b ON f.hash=b.hash WHERE f.commit_id=(SELECT MAX(id) FROM commits) AND f.filename = ''' + SqlEscape(ResolvedPath) + ''';';
              Output := Trim(ExecSqlOnDb(DbPath, Query));
              
              // If not found, try just the filename
              if Output = '' then
              begin
                Query := 'SELECT hex(b.data) FROM files f JOIN blobs b ON f.hash=b.hash WHERE f.commit_id=(SELECT MAX(id) FROM commits) AND f.filename LIKE ''%' + SqlEscape(ImgUrl) + ''';';
                Output := Trim(ExecSqlOnDb(DbPath, Query));
              end;
              
              if Output = '' then
                Continue;
              
              // Convert to base64
              ImgContent := HexToString(Output);
              Base64Img := Base64Encode(ImgContent);
              MimeType := GetMimeType(ResolvedPath);
              
              if Base64Img = '' then
                Continue;
              
              DataUri := 'data:' + MimeType + ';base64,' + Base64Img;
              
              // Use position-based replacement to be more reliable
              // Build the replacement: everything before src value + new value + everything after
              MarkdownHtml := Copy(MarkdownHtml, 1, SrcStart - 1) + DataUri + Copy(MarkdownHtml, SrcStart + ImgEnd - 1, Length(MarkdownHtml));
            end;
          except
            // Proceed with original HTML if error occurs
          end;
          
          Html := Html + '<div style="font-family: Arial, sans-serif; line-height: 1.6;">' + MarkdownHtml + '</div>';
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
          Html := Html + '<p><strong>' + T('file', Translations) + ' (' + IntToStr(Length(FileContent)) + ' bytes)</strong></p>';
      end;

      Html := Html + '<hr><p><small>Omi Server</small></p></body></html>';
      AResponse.Content := PrettyHtml32(Html);
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

      if (ARequest.Method = 'POST') and (Username <> '') and not IsHistoricView then
      begin
        Action := ARequest.ContentFields.Values['action'];
        if Action = 'delete_dir' then
        begin
          Target := SanitizePathSegment(ARequest.ContentFields.Values['target']);
          EntryPath := JoinRepoPath(RepoPath, Target);
          if DeleteDirectoryFromRepo(DbPath, EntryPath, Username) then
            UploadMsg := T('delete', Translations)
          else
            UploadError := T('error', Translations);
        end
        else if Action = 'rename_dir' then
        begin
          Target := SanitizePathSegment(ARequest.ContentFields.Values['target']);
          NewName := SanitizePathSegment(ARequest.ContentFields.Values['new_name']);
          if (Target <> '') and (NewName <> '') then
          begin
            EntryPath := JoinRepoPath(RepoPath, Target);
            NewName := JoinRepoPath(RepoPath, NewName);
            if RenameDirectoryInRepo(DbPath, EntryPath, NewName, Username) then
              UploadMsg := T('save', Translations)
            else
              UploadError := T('error', Translations);
          end
          else
            UploadError := T('error', Translations);
        end
        else if Action = 'delete_file' then
        begin
          Target := SanitizePathSegment(ARequest.ContentFields.Values['target']);
          EntryPath := JoinRepoPath(RepoPath, Target);
          if DeleteFileFromRepo(DbPath, EntryPath, Username) then
            UploadMsg := T('delete', Translations)
          else
            UploadError := T('file-delete-failed', Translations);
        end
        else if Action = 'rename_file' then
        begin
          Target := SanitizePathSegment(ARequest.ContentFields.Values['target']);
          NewName := SanitizePathSegment(ARequest.ContentFields.Values['new_name']);
          if (Target <> '') and (NewName <> '') then
          begin
            EntryPath := JoinRepoPath(RepoPath, Target);
            NewName := JoinRepoPath(RepoPath, NewName);
            if RenameFileInRepo(DbPath, EntryPath, NewName, Username) then
              UploadMsg := T('save', Translations)
            else
              UploadError := T('error', Translations);
          end
          else
            UploadError := T('error', Translations);
        end
        else if Action = 'create_dir' then
        begin
          DirName := SanitizePathSegment(ARequest.ContentFields.Values['dir_name']);
          if DirName <> '' then
          begin
            EntryPath := JoinRepoPath(RepoPath, DirName + '/.omidir');
            if CommitFile(DbPath, EntryPath, '', Username, 'Create directory') then
              UploadMsg := T('create', Translations)
            else
              UploadError := T('error', Translations);
          end
          else
            UploadError := T('error', Translations);
        end
        else if Action = 'create_file' then
        begin
          FileName := SanitizePathSegment(ARequest.ContentFields.Values['file_name']);
          FileData := ARequest.ContentFields.Values['file_content'];
          if FileName <> '' then
          begin
            EntryPath := JoinRepoPath(RepoPath, FileName);
            if CommitFile(DbPath, EntryPath, FileData, Username, 'Create file') then
              UploadMsg := T('create', Translations)
            else
              UploadError := T('error', Translations);
          end
          else
            UploadError := T('error', Translations);
        end
        else if (ARequest.Files.Count > 0) then
        begin
          UploadFile := ARequest.Files[0];
          FileName := SanitizePathSegment(UploadFile.FileName);
          if FileName <> '' then
          begin
            EntryPath := JoinRepoPath(RepoPath, FileName);
            FileData := ReadFileToString(UploadFile.LocalFileName);
            if CommitFile(DbPath, EntryPath, FileData, Username, 'Upload file') then
              UploadMsg := T('upload', Translations)
            else
              UploadError := T('error', Translations);
          end
          else
            UploadError := T('error', Translations);
        end;

        Files := GetLatestFiles(DbPath, RepoPath, SelectedCommitId);
      end;

      DirList.Clear;
      FileList.Clear;
      for I := 0 to High(Files) do
      begin
        Relative := Files[I].Filename;
        if RepoPath <> '' then
        begin
          if Pos(RepoPath + '/', Relative) = 1 then
            Relative := Copy(Relative, Length(RepoPath) + 2, Length(Relative));
        end;
        // The marker for the directory currently being viewed is hidden, but a
        // nested "name/.omidir" must continue to the slash handling below so
        // its parent directory appears in this listing.
        if Relative = '.omidir' then
          Continue;
        SlashPos := Pos('/', Relative);
        if SlashPos > 0 then
          DirList.Add(Copy(Relative, 1, SlashPos - 1))
        else if Relative <> '' then
          FileList.Add(Relative);
      end;

      TableRows := '';

      for I := 0 to DirList.Count - 1 do
      begin
        DisplayName := DirList[I];
        EntryPath := RepoToRoot(RepoName) + '/' +
          JoinRepoPath(RepoPath, DisplayName);
        RowActions := '-';
        if (Username <> '') and not IsHistoricView then
          RowActions := BuildRepositoryEntryActions(ARequest, DisplayName,
            'dir', '', Translations);
        TableRows := TableRows + '<tr><td>' + BuildNavTargetButton(ARequest, CurrentPath, WithCommit(EntryPath), 'repo-dir-open-' + IntToStr(I), DisplayName + '/') + '</td><td>-</td><td>-</td><td>-</td><td>-</td><td>' + RowActions + '</td></tr>';
      end;

      for I := 0 to FileList.Count - 1 do
      begin
        DisplayName := FileList[I];
        FileSizeText := '-';
        FileModifiedText := '-';
        FileUploadedText := '-';
        FileUploaderText := '-';
        EntryPath := JoinRepoPath(RepoPath, DisplayName);
        for J := 0 to High(Files) do
          if Files[J].Filename = EntryPath then
          begin
            FileSizeText := FormatByteSize(Files[J].Size);
            FileModifiedText := Files[J].DateTimeStr;
            FileUploadedText := Files[J].UploadedAt;
            if Files[J].UploadedBy <> '' then
              FileUploaderText := Files[J].UploadedBy;
            Break;
          end;
        EntryPath := RepoToRoot(RepoName) + '/' +
          EntryPath;
        RowActions := '-';
        if (Username <> '') and not IsHistoricView then
        begin
          // Only show edit button for text files (including markdown)
        IsTextFile := not IsImageFile(DisplayName);
        if not IsTextFile then
        begin
          // Check file extension for common text file types
          LowerName := LowerCase(DisplayName);
          IsTextFile := (Pos('.md', LowerName) > 0) or (Pos('.txt', LowerName) > 0) or 
                        (Pos('.json', LowerName) > 0) or (Pos('.xml', LowerName) > 0) or
                        (Pos('.html', LowerName) > 0) or (Pos('.css', LowerName) > 0) or
                        (Pos('.js', LowerName) > 0) or (Pos('.py', LowerName) > 0) or
                        (Pos('.php', LowerName) > 0) or (Pos('.sql', LowerName) > 0);
        end;
        EditButton := '';
        if IsTextFile then
        begin
          EditButton := BuildNavTargetButton(ARequest, CurrentPath, WithCommit(EntryPath + '?edit=1'), 'repo-file-open-edit-' + IntToStr(I), T('edit', Translations));
        end;
        RowActions := BuildRepositoryEntryActions(ARequest, DisplayName,
          'file', EditButton, Translations);
        end;
        TableRows := TableRows + '<tr><td>' + BuildNavTargetButton(ARequest, CurrentPath, WithCommit(EntryPath), 'repo-file-open-' + IntToStr(I), '[' + GetFileTypeLabel(DisplayName) + '] ' + DisplayName) + '</td><td>' + HtmlEncode(FileSizeText) + '</td><td>' + HtmlEncode(FileModifiedText) + '</td><td>' + HtmlEncode(FileUploadedText) + '</td><td>' + HtmlEncode(FileUploaderText) + '</td><td>' + RowActions + '</td></tr>';
      end;

      if TableRows = '' then
        TableRows := '<tr><td colspan="6">' + T('no-files-directory', Translations) + '</td></tr>';

      DirHeader := RepoPath;
      if DirHeader = '' then
        DirHeader := T('root', Translations);

      // Add parent directory link if not in root
      ParentDirRow := '';
      if RepoPath <> '' then
      begin
        ParentPath := ExtractFilePath(RepoPath);
        if ParentPath <> RepoPath then
        begin
          if (Length(ParentPath) > 0) and (ParentPath[Length(ParentPath)] = '/') then
            ParentPath := Copy(ParentPath, 1, Length(ParentPath) - 1);
          ParentUrl := RepoToRoot(RepoName);
          if ParentPath <> '' then
            ParentUrl := ParentUrl + '/' + ParentPath;
          ParentDirRow := '<tr><td>' + BuildNavTargetButton(ARequest, CurrentPath, WithCommit(ParentUrl), 'repo-parent-row', '..') + '</td><td>-</td><td>-</td><td>-</td><td>-</td><td>-</td></tr>';
        end;
      end;

      Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">' +
        '<html><head><title>' + HtmlEncode(RepoPath) + ' - ' + HtmlEncode(RepoName) + '</title></head>' +
        '<body bgcolor="#f0f0f0">' +
        BuildNavRow([
          BuildActionButton(ARequest, '/', 'nav-home', T('home', Translations)),
          ifthen(Username <> '', BuildActionButton(ARequest, '/language', 'nav-language', T('language', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/settings', 'nav-settings', T('settings', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/people', 'nav-people', T('people', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/activity', 'nav-activity', T('activity', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/backups', 'nav-backups', T('backups', Translations)), ''),
          ifthen(Username <> '', BuildActionButton(ARequest, '/gitea', 'nav-gitea', T('gitea', Translations)), ''),
          ifthen(Username <> '', '<strong>' + HtmlEncode(Username) + '</strong>', '<a href="/sign-in">' + T('login', Translations) + '</a>'),
          ifthen(Username <> '', BuildActionButton(ARequest, '/logout', 'nav-logout', T('logout', Translations)), ''),
          BuildNavTargetButton(ARequest, CurrentPath, WithCommit('/?log=' + HtmlEncode(RepoName)), 'repo-nav-log-list', T('log', Translations)),
          ifthen(IsHistoricView, BuildNavTargetButton(ARequest, CurrentPath,
            RepoToRoot(RepoName), 'repo-list-latest', T('latest', Translations)), '')
        ]) +
        BuildRepoBreadcrumb(False) +
        ifthen(IsHistoricView, '<p><font color="blue"><strong>' + T('viewing-commit', Translations) + ' ' + IntToStr(SelectedCommitId) + '</strong></font></p>', '') +
        '<hr>' +
        '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
        '<tr bgcolor="#333333"><th><font color="white">' + T('name', Translations) + '</font></th><th><font color="white">' + T('size', Translations) + '</font></th><th><font color="white">' + T('last-modified', Translations) + '</font></th><th><font color="white">' + T('uploaded', Translations) + '</font></th><th><font color="white">' + T('uploaded-by', Translations) + '</font></th><th><font color="white">' + T('actions', Translations) + '</font></th></tr>' +
        ParentDirRow +
        TableRows +
        '</table>' +
        '<hr>' +
        ifthen(UploadMsg <> '', '<p><font color="green"><strong>' + HtmlEncode(UploadMsg) + '</strong></font></p>', '') +
        ifthen(UploadError <> '', '<p><font color="red"><strong>' + HtmlEncode(UploadError) + '</strong></font></p>', '') +
        ifthen((Username <> '') and not IsHistoricView,
          '<p><b>' + T('create-directory', Translations) + '</b></p>' +
          '<form method="POST">' + BuildAuthHiddenFields(ARequest, 'repo-create-dir') + '<input type="text" name="dir_name" size="30" placeholder="new-folder">' +
          '<input type="hidden" name="action" value="create_dir">' +
          '<input type="submit" value="' + T('create-directory', Translations) + '"></form>' +
          '<p><b>' + T('create-text-file', Translations) + '</b></p>' +
          '<form method="POST">' + BuildAuthHiddenFields(ARequest, 'repo-create-file') + '<input type="text" name="file_name" size="30" placeholder="notes.txt"><br>' +
          '<textarea name="file_content" rows="6" cols="60" placeholder="' + T('write-file-contents', Translations) + '"></textarea><br>' +
          '<input type="hidden" name="action" value="create_file">' +
          '<input type="submit" value="' + T('create-file', Translations) + '"></form>' +
          '<p><b>' + T('upload-file-directory', Translations) + '</b></p>' +
          '<form method="POST" enctype="multipart/form-data">' + BuildAuthHiddenFields(ARequest, 'repo-upload-file') +
          '<input type="file" name="upload_file" required>' +
          '<input type="submit" value="' + T('upload', Translations) + '"></form>',
          '<p><small><a href="/sign-in">' + T('login', Translations) + '</a> ' + T('login-to-upload-files', Translations) + '</small></p>') +
        '<hr><p><small>Omi Server</small></p>' +
        '</body></html>';

      AResponse.Content := PrettyHtml32(Html);
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

// Free what the program allocated, once, and only what was actually created.
// The error paths and the normal exit both come here, so they cannot disagree
// about what has already been released.
{ ---------------------------------------------------------------------------
  Backups: github-to-gitea backups, <NAME>.db (SQLite) and <NAME>.zip (STORED,
  ZIP64), shown as HTML 4.01 pages and edited in place. See docs/BACKUPS.md;
  reading and writing the two files is in omibackup.pas.

  Every page needs a logged-in user: a backup can hold private repositories.
  As everywhere in Omi, navigation is signed POST buttons; a saving form is
  signed for one action that names its target, so a token for one issue or
  file cannot save another.
  --------------------------------------------------------------------------- }

const
  BACKUP_TEXT_SHOW_LIMIT = 256 * 1024;
  BACKUP_EDIT_LIMIT = 1024 * 1024;
  BACKUP_IMAGE_INLINE_LIMIT = 2 * 1024 * 1024;
  BACKUP_PAGE_SIZE = 500;

type
  TBackupItem = record
    Owner, Stamp, DbPath, ZipPath: string;
  end;
  TBackupItems = array of TBackupItem;

function GetBackupsDir: string;
var
  SettingsMap: TStringList;
  Value: string;
begin
  SettingsMap := LoadSettingsMap;
  try
    Value := Trim(SettingsMap.Values['BACKUPS_DIR']);
  finally
    SettingsMap.Free;
  end;
  Result := '';
  if Value = '' then
    Exit;
  if Copy(Value, 1, 2) = '~/' then
    Value := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + Copy(Value, 3, MaxInt);
  // A relative directory is in the Omi folder (where settings/ and db/ are).
  if not GtIsAbs(Value) then
    Value := IncludeTrailingPathDelimiter(DataPath('..')) + Value;
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(Value));
end;

// An owner folder name: one path segment, never '.', '..', hidden or a path.
function BackupNameIsSafe(const Name: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (Name = '') or (Length(Name) > 200) or (Name[1] = '.') then
    Exit;
  for I := 1 to Length(Name) do
    if (Ord(Name[I]) < 32) or (Ord(Name[I]) = 127) or (Name[I] = '/') or
      (Name[I] = '\') or (Name[I] = ':') then
      Exit;
  Result := True;
end;

// The stamp that names the one backup of an owner, <NAME>/<NAME>.db and
// <NAME>.zip, in the URLs: /backups/<NAME>/current/...
const
  BACKUP_CURRENT = 'current';

// YYYY-MM-DD_HH-MM-SS, optionally -N (gitea_backup.backups); never .partial.
function BackupDatedStampIsValid(const Stamp: string): Boolean;
const
  Pattern = 'dddd-dd-dd_dd-dd-dd';
var
  I: Integer;
begin
  Result := False;
  if (Length(Stamp) < 19) or (Length(Stamp) > 30) then
    Exit;
  for I := 1 to 19 do
    if Pattern[I] = 'd' then
    begin
      if not (Stamp[I] in ['0'..'9']) then
        Exit;
    end
    else if Stamp[I] <> Pattern[I] then
      Exit;
  if Length(Stamp) > 19 then
  begin
    if (Stamp[20] <> '-') or (Length(Stamp) = 20) then
      Exit;
    for I := 21 to Length(Stamp) do
      if not (Stamp[I] in ['0'..'9']) then
        Exit;
  end;
  Result := True;
end;

// A dated backup, or the owner's one backup (BACKUP_CURRENT).
function BackupStampIsValid(const Stamp: string): Boolean;
begin
  Result := (Stamp = BACKUP_CURRENT) or BackupDatedStampIsValid(Stamp);
end;

function ResolveBackup(const Owner, Stamp: string; out DbPath, ZipPath: string): Boolean;
var
  Root, Dir: string;
begin
  Result := False;
  DbPath := '';
  ZipPath := '';
  Root := GetBackupsDir;
  if (Root = '') or not BackupNameIsSafe(Owner) or not BackupStampIsValid(Stamp) then
    Exit;
  if Stamp = BACKUP_CURRENT then
    Dir := IncludeTrailingPathDelimiter(Root) + Owner
  else
    Dir := IncludeTrailingPathDelimiter(Root) + Owner + PathDelim + Stamp;
  DbPath := Dir + PathDelim + Owner + '.db';
  ZipPath := Dir + PathDelim + Owner + '.zip';
  Result := DirectoryExists(Dir) and FileExists(DbPath);
end;

function ListBackups(const Root: string): TBackupItems;
var
  OwnerSr, StampSr: TSearchRec;
  Item, Tmp: TBackupItem;
  I, J: Integer;
begin
  Result := nil;
  if (Root = '') or not DirectoryExists(Root) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Root) + '*', faDirectory, OwnerSr) = 0 then
  try
    repeat
      if ((OwnerSr.Attr and faDirectory) = 0) or not BackupNameIsSafe(OwnerSr.Name) then
        Continue;
      // The owner's one backup, <NAME>/<NAME>.db and .zip.
      if ResolveBackup(OwnerSr.Name, BACKUP_CURRENT, Item.DbPath, Item.ZipPath) then
      begin
        Item.Owner := OwnerSr.Name;
        Item.Stamp := BACKUP_CURRENT;
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Item;
      end;
      // Dated ones that github-to-gitea has not combined into it yet.
      if FindFirst(IncludeTrailingPathDelimiter(Root) + OwnerSr.Name + PathDelim + '*',
        faDirectory, StampSr) = 0 then
      try
        repeat
          if ((StampSr.Attr and faDirectory) = 0) or not BackupDatedStampIsValid(StampSr.Name) then
            Continue;
          if ResolveBackup(OwnerSr.Name, StampSr.Name, Item.DbPath, Item.ZipPath) then
          begin
            Item.Owner := OwnerSr.Name;
            Item.Stamp := StampSr.Name;
            SetLength(Result, Length(Result) + 1);
            Result[High(Result)] := Item;
          end;
        until FindNext(StampSr) <> 0;
      finally
        FindClose(StampSr);
      end;
    until FindNext(OwnerSr) <> 0;
  finally
    FindClose(OwnerSr);
  end;
  // Newest first, then by owner.
  for I := 1 to High(Result) do
  begin
    Tmp := Result[I];
    J := I - 1;
    while (J >= 0) and ((Result[J].Stamp < Tmp.Stamp) or
      ((Result[J].Stamp = Tmp.Stamp) and (Result[J].Owner > Tmp.Owner))) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := Tmp;
  end;
end;

function BkFileSize(const Path: string): Int64;
var
  Sr: TSearchRec;
begin
  Result := -1;
  if FindFirst(Path, faAnyFile, Sr) = 0 then
  begin
    Result := Sr.Size;
    FindClose(Sr);
  end;
end;

function BkUrlPart(const Value: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(Value) do
    if Value[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'] then
      Result := Result + Value[I]
    else
      Result := Result + '%' + IntToHex(Ord(Value[I]), 2);
end;

function BkUrlDecode(const Value: string): string;
var
  I, H: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(Value) do
  begin
    if (Value[I] = '%') and (I + 2 <= Length(Value)) then
    begin
      H := StrToIntDef('$' + Copy(Value, I + 1, 2), -1);
      if H >= 0 then
      begin
        Result := Result + Chr(H);
        Inc(I, 3);
        Continue;
      end;
    end;
    Result := Result + Value[I];
    Inc(I);
  end;
end;

function BkMime(const Name: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(Name));
  if Ext = '.png' then Exit('image/png');
  if (Ext = '.jpg') or (Ext = '.jpeg') then Exit('image/jpeg');
  if Ext = '.gif' then Exit('image/gif');
  if Ext = '.webp' then Exit('image/webp');
  if Ext = '.bmp' then Exit('image/bmp');
  if Ext = '.ico' then Exit('image/x-icon');
  if (Ext = '.txt') or (Ext = '.md') or (Ext = '.log') or (Ext = '.json') or
    (Ext = '.csv') or (Ext = '.yml') or (Ext = '.yaml') or (Ext = '.diff') or
    (Ext = '.patch') then
    Exit('text/plain; charset=UTF-8');
  // Everything else - HTML and SVG included - is only ever a download.
  Result := 'application/octet-stream';
end;

function BkIsInlineImage(const Name: string): Boolean;
begin
  Result := Pos('image/', BkMime(Name)) = 1;
end;

function BkDownloadName(const EntryName: string): string;
var
  I: Integer;
begin
  Result := EntryName;
  I := LastDelimiter('/', Result);
  if I > 0 then
    Result := Copy(Result, I + 1, MaxInt);
  for I := 1 to Length(Result) do
    if not (Result[I] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_']) then
      Result[I] := '_';
  if (Result = '') or (Result[1] = '.') then
    Result := 'file' + Result;
end;

// Escaped text with its line breaks, for a table cell.
function BkTextHtml(const Value: string): string;
begin
  Result := StringReplace(HtmlEncode(Value), #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '<br>' + LineEnding, [rfReplaceAll]);
end;

function BkButton(ARequest: TRequest; const Path, ActionName, LabelText,
  Fields: string): string;
begin
  Result := '<form method="POST" action="' + HtmlEncode(Path) +
    '" style="display:inline; margin:0; padding:0;">' +
    BuildAuthHiddenFields(ARequest, ActionName) + Fields +
    '<input type="submit" value="' + HtmlEncode(LabelText) + '"></form>';
end;

function BkHeaderRow(const Labels: array of string): string;
var
  I: Integer;
begin
  Result := '<tr bgcolor="#333333">';
  for I := Low(Labels) to High(Labels) do
    Result := Result + '<th align="left"><font color="white">' + HtmlEncode(Labels[I]) +
      '</font></th>';
  Result := Result + '</tr>';
end;

function BkStateLabel(const State, Merged: string; Translations: TJSONObject): string;
begin
  if (Merged = '1') or SameText(Merged, 'true') then
    Result := T('merged', Translations)
  else if (State = 'open') or (State = 'closed') then
    Result := T(State, Translations)
  else
    Result := State;
end;

// The text a browser's textarea sent, with the line endings the original had.
function BkNormalizeNewlines(const NewText, OldText: string): string;
begin
  Result := NewText;
  if Pos(#13, OldText) = 0 then
  begin
    Result := StringReplace(Result, #13#10, #10, [rfReplaceAll]);
    Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
  end;
end;

function BkIsDigits(const Value: string): Boolean;
var
  I: Integer;
begin
  Result := (Value <> '') and (Length(Value) <= 18);
  for I := 1 to Length(Value) do
    if not (Value[I] in ['0'..'9']) then
      Exit(False);
end;

procedure BackupsEndpoint(ARequest: TRequest; AResponse: TResponse);
const
  JSON_OF = 'CASE WHEN json_valid(json) THEN json ELSE ''{}'' END';
  // Old data (gitea_backup): a row the newest backup run did not see at the
  // source, or one only an older, combined backup had.
  OLD_SQL = '(seen IS NULL OR seen < (SELECT CAST(value AS INTEGER) FROM meta WHERE key = ''runs''))';
  DATA_TABLES: array[0..10] of string = ('owner', 'teams', 'members', 'repos', 'labels',
    'milestones', 'issues', 'pulls', 'comments', 'releases', 'files');
  DATA_TABLE_KEYS: array[0..10] of string = ('owner', 'teams', 'members', 'repositories', 'labels',
    'milestones', 'issues', 'pull-requests', 'comments', 'releases', 'files');
var
  Username, SessionId, PostedAction, UserLang, Op: string;
  UsersMap: TStringList;
  StoredPassword, StoredOtp, StoredLanguage: string;
  Translations: TJSONObject;
  LangData: TJSONObject;
  IsRtl: Boolean;
  RawParts: TStringArray;
  Segs: array of string;
  I: Integer;
  Owner, Stamp, DbPath, ZipPath, Base, OwnerDir: string;
  RepoName, RepoFull, RepoFolder, RepoDescription, Tab: string;
  Msg, Err: string;
  MarkerState: Integer;

  function Tx(const Key: string): string;
  begin
    Result := T(Key, Translations);
  end;

  function TxE(const Key: string): string;
  begin
    Result := HtmlEncode(T(Key, Translations));
  end;

  function Nav(const Path, LabelText, Fields: string): string;
  begin
    Result := BkButton(ARequest, Path, 'backup-nav', LabelText, Fields);
  end;

  function Q(const Sql: string; const Params: array of string; out Rows: TSqlRows): Boolean;
  var
    E: string;
  begin
    Result := BkSqlQuery(DbPath, Sql, Params, Rows, E);
    if not Result then
      Err := Tx('error') + ': ' + E;
  end;

  // The old data marker - a seen column, and meta runs - is only in an
  // owner's one backup; a dated backup has none.
  function HasMarker: Boolean;
  var
    Rows: TSqlRows;
    E: string;
  begin
    if MarkerState = 0 then
    begin
      MarkerState := 2;
      if BkSqlQuery(DbPath, 'SELECT (SELECT COUNT(*) FROM pragma_table_info(''files'') WHERE name = ''seen''), ' +
        '(SELECT COUNT(*) FROM meta WHERE key = ''runs'')', [], Rows, E) and (Length(Rows) = 1) and
        (Rows[0][0] = '1') and (Rows[0][1] = '1') then
        MarkerState := 1;
    end;
    Result := MarkerState = 1;
  end;

  function TableHasSeen(const Table: string): Boolean;
  var
    Rows: TSqlRows;
    E: string;
  begin
    Result := BkSqlQuery(DbPath, 'SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ''seen''',
      [Table], Rows, E) and (Length(Rows) = 1) and (Rows[0][0] = '1');
  end;

  // The first column of the rows, as a sorted list: which items are old data.
  function OldSet(const Sql: string; const Params: array of string): TStringList;
  var
    Rows: TSqlRows;
    E: string;
    K: Integer;
  begin
    Result := TStringList.Create;
    Result.CaseSensitive := True;
    Result.Sorted := True;
    Result.Duplicates := dupIgnore;
    if HasMarker and BkSqlQuery(DbPath, Sql, Params, Rows, E) then
      for K := 0 to High(Rows) do
        Result.Add(Rows[K][0]);
  end;

  function IsOld(const Sql: string; const Params: array of string): Boolean;
  var
    L: TStringList;
  begin
    L := OldSet(Sql, Params);
    try
      Result := L.Count > 0;
    finally
      L.Free;
    end;
  end;

  // The zip entries of old data: the files of old rows, and the git and wiki
  // bundles of old repositories that no current repository uses.
  function OldEntryNames: TStringList;
  begin
    Result := OldSet('SELECT path FROM files WHERE ' + OLD_SQL + ' UNION ' +
      'SELECT b FROM (SELECT git_bundle AS b, seen FROM repos UNION ALL SELECT wiki_bundle, seen FROM repos) ' +
      'WHERE b IS NOT NULL AND b <> '''' AND ' + OLD_SQL + ' AND b NOT IN (SELECT git_bundle FROM repos ' +
      'WHERE git_bundle IS NOT NULL AND NOT ' + OLD_SQL + ') AND b NOT IN (SELECT wiki_bundle FROM repos ' +
      'WHERE wiki_bundle IS NOT NULL AND NOT ' + OLD_SQL + ')', []);
  end;

  function OldMark: string;
  begin
    Result := ' <font color="#a00000"><b>[' + TxE('old-data') + ']</b></font>';
  end;

  // Every write - into the .db or the .zip - holds the backup lock shared
  // with github-to-gitea, and first finishes or clears a commit that broke off.
  function WriteBegin(out LockContent: string): Boolean;
  var
    Holder, E: string;
  begin
    Result := BkLockAcquire(OwnerDir, LockContent, Holder, E);
    if not Result then
    begin
      if Holder <> '' then
        Err := Tx('backup-locked') + ' ' + Holder
      else
        Err := Tx('error') + ': ' + E;
      Exit;
    end;
    BkRecoverCommit(OwnerDir, Owner);
  end;

  procedure WriteEnd(const LockContent: string);
  begin
    BkLockRelease(OwnerDir, LockContent);
  end;

  function Crumbs(const Items: array of string): string;
  var
    K: Integer;
  begin
    Result := '<p>';
    for K := Low(Items) to High(Items) do
    begin
      if K > Low(Items) then
        Result := Result + ' &gt; ';
      Result := Result + Items[K];
    end;
    Result := Result + '</p>';
  end;

  function BaseCrumbs(const Last: string): string;
  begin
    if Last = '' then
      Result := Crumbs([Nav('/backups', Tx('backups'), ''),
        '<strong>' + HtmlEncode(Owner + ' ' + Stamp) + '</strong>'])
    else
      Result := Crumbs([Nav('/backups', Tx('backups'), ''),
        Nav(Base, Owner + ' ' + Stamp, ''), Last]);
  end;

  function Messages: string;
  begin
    Result := '';
    if Msg <> '' then
      Result := Result + '<p><font color="green"><strong>' + HtmlEncode(Msg) +
        '</strong></font></p>';
    if Err <> '' then
      Result := Result + '<p><font color="red"><strong>' + HtmlEncode(Err) +
        '</strong></font></p>';
  end;

  procedure Send(const Title, CrumbHtml, Body: string);
  var
    Html, LangAttr, DirAttr: string;
  begin
    LangAttr := StringReplace(StringReplace(UserLang, '_', '-', [rfReplaceAll]),
      '@', '-', [rfReplaceAll]);
    if IsRtl then
      DirAttr := 'rtl'
    else
      DirAttr := 'ltr';
    Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" ' +
      '"http://www.w3.org/TR/html4/loose.dtd">' + LineEnding +
      '<html lang="' + HtmlEncode(LangAttr) + '" dir="' + DirAttr + '"><head>' +
      '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">' +
      '<meta name="viewport" content="width=device-width, initial-scale=1">' +
      '<title>' + HtmlEncode(Title) + ' - Omi Server</title></head>' + LineEnding +
      '<body bgcolor="#f0f0f0" dir="' + DirAttr + '">' + LineEnding +
      '<table width="100%" border="0" cellpadding="5"><tr><td><h1>' +
      HtmlEncode(Title) + '</h1></td></tr></table>' + LineEnding +
      BuildNavRow([
        BuildActionButton(ARequest, '/', 'nav-home', Tx('home')),
        BuildActionButton(ARequest, '/language', 'nav-language', Tx('language')),
        BuildActionButton(ARequest, '/settings', 'nav-settings', Tx('settings')),
        BuildActionButton(ARequest, '/people', 'nav-people', Tx('people')),
        BuildActionButton(ARequest, '/activity', 'nav-activity', Tx('activity')),
        BuildActionButton(ARequest, '/backups', 'nav-backups', Tx('backups')),
        BuildActionButton(ARequest, '/gitea', 'nav-gitea', Tx('gitea')),
        '<strong>' + HtmlEncode(Username) + '</strong>',
        BuildActionButton(ARequest, '/logout', 'nav-logout', Tx('logout'))
      ]) + LineEnding + CrumbHtml + LineEnding + '<hr>' + LineEnding +
      Messages + Body + LineEnding + '<hr><p><small>Omi Server</small></p></body></html>' +
      LineEnding;
    AResponse.ContentType := 'text/html; charset=UTF-8';
    AResponse.CustomHeaders.Values['X-Content-Type-Options'] := 'nosniff';
    AResponse.CustomHeaders.Values['Content-Security-Policy'] :=
      'default-src ''none''; img-src data:; style-src ''unsafe-inline''; ' +
      'form-action ''self''; frame-ancestors ''none''';
    AResponse.CustomHeaders.Values['Referrer-Policy'] := 'no-referrer';
    AResponse.CustomHeaders.Values['Cache-Control'] := 'no-store';
    AResponse.Content := Html;
  end;

  procedure NotFound(const Detail: string);
  begin
    AResponse.Code := 404;
    Err := '';
    Send(Tx('backups'), Crumbs([Nav('/backups', Tx('backups'), '')]),
      '<p><font color="red"><strong>' + TxE('not-found') + '</strong></font> ' +
      HtmlEncode(Detail) + '</p>');
  end;

  function DownloadButton(const EntryName: string): string;
  begin
    Result := BkButton(ARequest, Base + '/file', 'backup-download', Tx('download'),
      BuildHiddenInput('entry', EntryName) + BuildHiddenInput('op', 'download'));
  end;

  // A file of the zip, as View and Download buttons.
  function EntryButtons(const EntryName: string): string;
  begin
    Result := Nav(Base + '/file', Tx('view'), BuildHiddenInput('entry', EntryName)) + ' ' +
      DownloadButton(EntryName);
  end;

  // The files the files table lists for one issue, comment or release.
  function AttachedFiles(const Kind, Parent: string): string;
  var
    Rows: TSqlRows;
    K: Integer;
    OldPaths: TStringList;
  begin
    Result := '';
    if not Q('SELECT path, name, size FROM files WHERE repo = ?1 AND kind = ?2 AND parent = ?3 ' +
      'ORDER BY id, path', [RepoFull, Kind, Parent], Rows) or (Length(Rows) = 0) then
      Exit;
    OldPaths := OldSet('SELECT path FROM files WHERE repo = ?1 AND kind = ?2 AND parent = ?3 AND ' +
      OLD_SQL, [RepoFull, Kind, Parent]);
    Result := '<table border="1" cellpadding="3" cellspacing="0">' +
      BkHeaderRow([Tx('attachments'), Tx('size'), '']);
    for K := 0 to High(Rows) do
      Result := Result + '<tr><td>' + HtmlEncode(Rows[K][1]) +
        ifthen(OldPaths.IndexOf(Rows[K][0]) >= 0, OldMark, '') + '</td><td align="right">' +
        HtmlEncode(FormatByteSize(StrToInt64Def(Rows[K][2], -1))) + '</td><td>' +
        EntryButtons(Rows[K][0]) + '</td></tr>';
    Result := Result + '</table>';
    OldPaths.Free;
  end;

  function RepoTabs: string;
    function TabItem(const Key, Name: string): string;
    begin
      if Tab = Name then
        Result := '<strong>' + TxE(Key) + '</strong>'
      else
        Result := Nav(Base + '/' + BkUrlPart(RepoName) + '/' + Name, Tx(Key), '');
    end;
  begin
    Result := '<h2>' + HtmlEncode(RepoFull) + '</h2>';
    if RepoDescription <> '' then
      Result := Result + '<p>' + BkTextHtml(RepoDescription) + '</p>';
    Result := Result + BuildNavRow([TabItem('issues', 'issues'),
      TabItem('pull-requests', 'pulls'), TabItem('releases', 'releases'),
      TabItem('files', 'files'), TabItem('labels', 'labels'), TabItem('old-data', 'old')]);
  end;

  function RepoCrumbs(const Last: string): string;
  begin
    Result := BaseCrumbs(Nav(Base + '/' + BkUrlPart(RepoName), RepoName, '') +
      ifthen(Last <> '', ' &gt; ' + Last, ''));
  end;

  function PageButtons(const Path: string; Offset, Shown: Integer; HasMore: Boolean;
    const Fields: string): string;
  begin
    Result := '';
    if Offset > 0 then
      Result := Result + Nav(Path, '<<', Fields + BuildHiddenInput('offset',
        IntToStr(Max(0, Offset - BACKUP_PAGE_SIZE)))) + ' ';
    if HasMore then
      Result := Result + Nav(Path, '>>', Fields + BuildHiddenInput('offset',
        IntToStr(Offset + Shown)));
    if Result <> '' then
      Result := '<p>' + Result + '</p>';
  end;

  procedure PageList;
  var
    Root, Body, Kind, Complete, Updated, When: string;
    Age: TDateTime;
    Items: TBackupItems;
    Rows: TSqlRows;
    K, R: Integer;
    E: string;
  begin
    Root := GetBackupsDir;
    if Root = '' then
    begin
      Send(Tx('backups'), Crumbs(['<strong>' + TxE('backups') + '</strong>']),
        '<p>' + TxE('no-backups') + '</p><p>BACKUPS_DIR (' + TxE('backups-directory') +
        '): ' + BuildActionButton(ARequest, '/settings', 'nav-settings', Tx('settings')) + '</p>');
      Exit;
    end;
    Items := ListBackups(Root);
    Body := '<p>' + TxE('backups-directory') + ': <tt>' + HtmlEncode(Root) + '</tt></p>';
    if Length(Items) = 0 then
      Body := Body + '<p>' + TxE('no-backups') + '</p>'
    else
    begin
      Body := Body + '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
        BkHeaderRow([Tx('owner'), Tx('type'), Tx('time'), Tx('status'), Tx('size'), '']);
      for K := 0 to High(Items) do
      begin
        Kind := '';
        Complete := '';
        Updated := '';
        if BkSqlQuery(Items[K].DbPath, 'SELECT key, value FROM meta WHERE key IN (''kind'', ''complete'', ' +
          '''updated'')', [], Rows, E) then
          for R := 0 to High(Rows) do
            if Rows[R][0] = 'kind' then
              Kind := Rows[R][1]
            else if Rows[R][0] = 'updated' then
              Updated := Rows[R][1]
            else
              Complete := Rows[R][1];
        if Items[K].Stamp <> BACKUP_CURRENT then
          When := Items[K].Stamp + ' (' + Tx('backup-dated') + ')'
        else if Updated <> '' then
          When := Updated
        else if FileAge(Items[K].DbPath, Age) then
          When := FormatDateTime('yyyy-mm-dd hh:nn:ss', Age)
        else
          When := '';
        Body := Body + '<tr><td>' + HtmlEncode(Items[K].Owner) + '</td><td>' +
          HtmlEncode(Kind) + '</td><td>' + HtmlEncode(When) + '</td><td>' +
          HtmlEncode(Complete) + '</td><td align="right">' +
          HtmlEncode(FormatByteSize(BkFileSize(Items[K].DbPath))) + ' + ' +
          HtmlEncode(FormatByteSize(BkFileSize(Items[K].ZipPath))) + '</td><td>' +
          Nav('/backups/' + BkUrlPart(Items[K].Owner) + '/' + BkUrlPart(Items[K].Stamp),
            Tx('view'), '') + '</td></tr>';
      end;
      Body := Body + '</table>';
    end;
    Send(Tx('backups'), Crumbs(['<strong>' + TxE('backups') + '</strong>']), Body);
  end;

  // Rows of old data in every table that has the marker, and the old zip
  // entries that are in the .zip with their bytes.
  procedure MeasureOld(out RowCount, FileCount: Integer; out Bytes: Int64;
    Names: TStringList; Counts: TStrings);
  var
    Rows: TSqlRows;
    Dir: TZipDirectory;
    K: Integer;
    E: string;
    L: TStringList;
  begin
    RowCount := 0;
    FileCount := 0;
    Bytes := 0;
    if not HasMarker then
      Exit;
    for K := Low(DATA_TABLES) to High(DATA_TABLES) do
      if TableHasSeen(DATA_TABLES[K]) and
        Q('SELECT COUNT(*) FROM ' + DATA_TABLES[K] + ' WHERE ' + OLD_SQL, [], Rows) and
        (Length(Rows) = 1) then
      begin
        Inc(RowCount, StrToIntDef(Rows[0][0], 0));
        if Counts <> nil then
          Counts.Values[DATA_TABLES[K]] := Rows[0][0];
      end;
    L := OldEntryNames;
    try
      if ZipReadDirectory(ZipPath, Dir, E) then
        for K := 0 to High(Dir.Entries) do
          if L.IndexOf(Dir.Entries[K].Name) >= 0 then
          begin
            Inc(FileCount);
            Inc(Bytes, Dir.Entries[K].CompSize);
            if Names <> nil then
              Names.Add(Dir.Entries[K].Name);
          end;
    finally
      L.Free;
    end;
  end;

  procedure PageOverview;
  var
    Body, Members: string;
    Rows: TSqlRows;
    K, OldRows, OldFiles: Integer;
    OldBytes: Int64;
    OldRepos: TStringList;
  begin
    Body := '';
    if Q('SELECT name, kind, json_extract(j, ''$.full_name''), json_extract(j, ''$.description''), ' +
      'json_extract(j, ''$.website'') FROM (SELECT name, kind, ' + JSON_OF + ' AS j FROM owner)',
      [], Rows) and (Length(Rows) > 0) then
    begin
      Body := Body + '<h2>' + HtmlEncode(Rows[0][0]) + '</h2><table border="0" cellpadding="3">' +
        '<tr><td><b>' + TxE('type') + '</b></td><td>' + HtmlEncode(Rows[0][1]) + '</td></tr>';
      if Rows[0][2] <> '' then
        Body := Body + '<tr><td><b>' + TxE('name') + '</b></td><td>' + HtmlEncode(Rows[0][2]) + '</td></tr>';
      if Rows[0][3] <> '' then
        Body := Body + '<tr><td><b>' + TxE('description') + '</b></td><td>' + BkTextHtml(Rows[0][3]) + '</td></tr>';
      if Rows[0][4] <> '' then
        Body := Body + '<tr><td><b>Web</b></td><td>' + HtmlEncode(Rows[0][4]) + '</td></tr>';
      Body := Body + '</table>';
    end;
    if Q('SELECT key, value FROM meta ORDER BY key', [], Rows) then
    begin
      Body := Body + '<h3>' + TxE('backup') + '</h3><table border="1" cellpadding="3" cellspacing="0">';
      for K := 0 to High(Rows) do
        Body := Body + '<tr><td>' + HtmlEncode(Rows[K][0]) + '</td><td>' +
          HtmlEncode(Rows[K][1]) + '</td></tr>';
      Body := Body + '</table>';
    end;
    Body := Body + '<p>' + Nav(Base + '/files', Tx('files'), '');
    if HasMarker then
    begin
      MeasureOld(OldRows, OldFiles, OldBytes, nil, nil);
      Body := Body + ' ' + Nav(Base + '/old', Tx('old-data'), '') + ' ' + TxE('rows') + ': ' +
        IntToStr(OldRows) + ', ' + TxE('files') + ': ' + IntToStr(OldFiles) + ' (' +
        HtmlEncode(FormatByteSize(OldBytes)) + ')';
    end;
    Body := Body + '</p>';
    OldRepos := OldSet('SELECT full_name FROM repos WHERE ' + OLD_SQL, []);
    if Q('SELECT r.name, r.full_name, json_extract(r.j, ''$.description''), ' +
      '(SELECT COUNT(*) FROM issues i WHERE i.repo = r.full_name AND i.is_pull = 0), ' +
      '(SELECT COUNT(*) FROM issues i WHERE i.repo = r.full_name AND i.is_pull = 1), ' +
      '(SELECT COUNT(*) FROM releases x WHERE x.repo = r.full_name) ' +
      'FROM (SELECT name, full_name, ' + JSON_OF + ' AS j FROM repos) r ORDER BY r.name',
      [], Rows) then
    begin
      Body := Body + '<h3>' + TxE('repositories') + '</h3>' +
        '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
        BkHeaderRow([Tx('name'), Tx('description'), Tx('issues'), Tx('pull-requests'),
          Tx('releases'), '']);
      for K := 0 to High(Rows) do
        Body := Body + '<tr><td>' + HtmlEncode(Rows[K][1]) +
          ifthen(OldRepos.IndexOf(Rows[K][1]) >= 0, OldMark, '') + '</td><td>' +
          BkTextHtml(Rows[K][2]) + '</td><td align="right">' + HtmlEncode(Rows[K][3]) +
          '</td><td align="right">' + HtmlEncode(Rows[K][4]) + '</td><td align="right">' +
          HtmlEncode(Rows[K][5]) + '</td><td>' +
          Nav(Base + '/' + BkUrlPart(Rows[K][0]), Tx('view'), '') + '</td></tr>';
      Body := Body + '</table>';
    end;
    if Q('SELECT login FROM members ORDER BY login', [], Rows) and (Length(Rows) > 0) then
    begin
      Members := '';
      for K := 0 to High(Rows) do
        Members := Members + ifthen(K > 0, ', ', '') + HtmlEncode(Rows[K][0]);
      Body := Body + '<h3>' + TxE('members') + '</h3><p>' + Members + '</p>';
    end;
    OldRepos.Free;
    Send(Owner + ' ' + Stamp, BaseCrumbs(''), Body);
  end;

  // Old data: of the whole backup, or of one repository (ForRepo).
  procedure PageOld(ForRepo: Boolean);
  var
    Body, Where, Html: string;
    Rows: TSqlRows;
    K, OldRows, OldFiles: Integer;
    OldBytes: Int64;
    Names: TStringList;
    Dir: TZipDirectory;
    E: string;

    function QR(const Sql: string; out R: TSqlRows): Boolean;
    begin
      if ForRepo then
        Result := Q(Sql, [RepoFull], R)
      else
        Result := Q(Sql, [], R);
    end;

    function RepoCell(const Full, Name: string): string;
    begin
      if Name <> '' then
        Result := Nav(Base + '/' + BkUrlPart(Name), Full, '')
      else
        Result := HtmlEncode(Full);
    end;

    procedure Section(const Key: string; Count: Integer; const Table: string);
    begin
      if Count = 0 then
        Exit;
      Body := Body + '<h3>' + TxE(Key) + ' (' + IntToStr(Count) + ')</h3>' + Table;
    end;
  begin
    if ForRepo then
      Body := RepoTabs
    else
      Body := '';
    if not HasMarker then
    begin
      Body := Body + '<p>' + TxE('old-data-no-marker') + '</p>';
      if ForRepo then
        Send(RepoFull + ' - ' + Tx('old-data'), RepoCrumbs(TxE('old-data')), Body)
      else
        Send(Owner + ' ' + Stamp + ' - ' + Tx('old-data'), BaseCrumbs('<strong>' + TxE('old-data') +
          '</strong>'), Body);
      Exit;
    end;
    Where := ifthen(ForRepo, ' AND repo = ?1', '');
    Body := Body + '<p>' + TxE('old-data-help') + '</p>';
    if not ForRepo then
    begin
      MeasureOld(OldRows, OldFiles, OldBytes, nil, nil);
      Body := Body + '<p>' + TxE('rows') + ': <b>' + IntToStr(OldRows) + '</b>, ' + TxE('files') +
        ': <b>' + IntToStr(OldFiles) + '</b> (' + HtmlEncode(FormatByteSize(OldBytes)) + ')';
      if (Stamp = BACKUP_CURRENT) and (OldRows + OldFiles > 0) then
        Body := Body + ' ' + Nav(Base + '/delete-old', Tx('delete-old-data'), '');
      Body := Body + '</p>';
      if (OldRows + OldFiles = 0) then
        Body := Body + '<p>' + TxE('old-data-none') + '</p>';
      if Q('SELECT full_name, name FROM repos WHERE ' + OLD_SQL + ' ORDER BY full_name', [], Rows) then
      begin
        Html := '<table border="1" cellpadding="3" cellspacing="0">';
        for K := 0 to High(Rows) do
          Html := Html + '<tr><td>' + RepoCell(Rows[K][0], Rows[K][1]) + '</td></tr>';
        Section('repositories', Length(Rows), Html + '</table>');
      end;
      if Q('SELECT login FROM members WHERE ' + OLD_SQL + ' ORDER BY login', [], Rows) then
      begin
        Html := '<p>';
        for K := 0 to High(Rows) do
          Html := Html + ifthen(K > 0, ', ', '') + HtmlEncode(Rows[K][0]);
        Section('members', Length(Rows), Html + '</p>');
      end;
      if Q('SELECT name FROM teams WHERE ' + OLD_SQL + ' ORDER BY name', [], Rows) then
      begin
        Html := '<p>';
        for K := 0 to High(Rows) do
          Html := Html + ifthen(K > 0, ', ', '') + HtmlEncode(Rows[K][0]);
        Section('teams', Length(Rows), Html + '</p>');
      end;
    end;
    if QR('SELECT repo, number, is_pull, title, (SELECT r.name FROM repos r WHERE r.full_name = issues.repo) ' +
      'FROM issues WHERE ' + OLD_SQL + Where + ' ORDER BY repo, number LIMIT ' + IntToStr(BACKUP_PAGE_SIZE), Rows) then
    begin
      Html := '<table border="1" width="100%" cellpadding="3" cellspacing="0">' +
        BkHeaderRow([Tx('repositories'), Tx('number'), Tx('type'), Tx('title')]);
      for K := 0 to High(Rows) do
        Html := Html + '<tr><td>' + RepoCell(Rows[K][0], Rows[K][4]) + '</td><td>' +
          ifthen(Rows[K][4] <> '', Nav(Base + '/' + BkUrlPart(Rows[K][4]) + '/issue/' + Rows[K][1],
            '#' + Rows[K][1], ''), '#' + HtmlEncode(Rows[K][1])) + '</td><td>' +
          HtmlEncode(ifthen(Rows[K][2] = '1', Tx('pull-requests'), Tx('issues'))) + '</td><td>' +
          HtmlEncode(Rows[K][3]) + '</td></tr>';
      Section('issues', Length(Rows), Html + '</table>');
    end;
    if QR('SELECT repo, id, issue_number, json_extract(' + JSON_OF + ', ''$.user.login''), ' +
      '(SELECT r.name FROM repos r WHERE r.full_name = comments.repo) FROM comments WHERE ' + OLD_SQL + Where +
      ' ORDER BY repo, issue_number, id LIMIT ' + IntToStr(BACKUP_PAGE_SIZE), Rows) then
    begin
      Html := '<table border="1" width="100%" cellpadding="3" cellspacing="0">' +
        BkHeaderRow([Tx('repositories'), Tx('number'), Tx('author'), 'id']);
      for K := 0 to High(Rows) do
        Html := Html + '<tr><td>' + RepoCell(Rows[K][0], Rows[K][4]) + '</td><td>' +
          ifthen(Rows[K][4] <> '', Nav(Base + '/' + BkUrlPart(Rows[K][4]) + '/issue/' + Rows[K][2],
            '#' + Rows[K][2], ''), '#' + HtmlEncode(Rows[K][2])) + '</td><td>' +
          HtmlEncode(Rows[K][3]) + '</td><td>' + HtmlEncode(Rows[K][1]) + '</td></tr>';
      Section('comments', Length(Rows), Html + '</table>');
    end;
    if QR('SELECT repo, tag, (SELECT r.name FROM repos r WHERE r.full_name = releases.repo) FROM releases ' +
      'WHERE ' + OLD_SQL + Where + ' ORDER BY repo, id', Rows) then
    begin
      Html := '<table border="1" cellpadding="3" cellspacing="0">' +
        BkHeaderRow([Tx('repositories'), Tx('tag')]);
      for K := 0 to High(Rows) do
        Html := Html + '<tr><td>' + RepoCell(Rows[K][0], Rows[K][2]) + '</td><td>' +
          ifthen(Rows[K][2] <> '', Nav(Base + '/' + BkUrlPart(Rows[K][2]) + '/releases', Rows[K][1], ''),
            HtmlEncode(Rows[K][1])) + '</td></tr>';
      Section('releases', Length(Rows), Html + '</table>');
    end;
    if QR('SELECT repo, name FROM labels WHERE ' + OLD_SQL + Where + ' ORDER BY repo, name', Rows) then
    begin
      Html := '<table border="1" cellpadding="3" cellspacing="0">' + BkHeaderRow([Tx('repositories'), Tx('name')]);
      for K := 0 to High(Rows) do
        Html := Html + '<tr><td>' + HtmlEncode(Rows[K][0]) + '</td><td>' + HtmlEncode(Rows[K][1]) + '</td></tr>';
      Section('labels', Length(Rows), Html + '</table>');
    end;
    if QR('SELECT repo, title FROM milestones WHERE ' + OLD_SQL + Where + ' ORDER BY repo, id', Rows) then
    begin
      Html := '<table border="1" cellpadding="3" cellspacing="0">' + BkHeaderRow([Tx('repositories'), Tx('title')]);
      for K := 0 to High(Rows) do
        Html := Html + '<tr><td>' + HtmlEncode(Rows[K][0]) + '</td><td>' + HtmlEncode(Rows[K][1]) + '</td></tr>';
      Section('milestones', Length(Rows), Html + '</table>');
    end;
    Names := OldEntryNames;
    try
      if ZipReadDirectory(ZipPath, Dir, E) then
      begin
        Html := '<table border="1" width="100%" cellpadding="3" cellspacing="0">' +
          BkHeaderRow([Tx('path'), Tx('size'), '']);
        OldFiles := 0;
        OldBytes := 0;
        for K := 0 to High(Dir.Entries) do
          if (Names.IndexOf(Dir.Entries[K].Name) >= 0) and (not ForRepo or
            (Copy(Dir.Entries[K].Name, 1, Length(RepoFolder) + 1) = RepoFolder + '/')) then
          begin
            Inc(OldFiles);
            Inc(OldBytes, Dir.Entries[K].Size);
            Html := Html + '<tr><td>' + HtmlEncode(Dir.Entries[K].Name) + '</td><td align="right">' +
              HtmlEncode(FormatByteSize(Dir.Entries[K].Size)) + '</td><td>' +
              ifthen(ZipEntryNameIsSafe(Dir.Entries[K].Name) and (Dir.Entries[K].Method = 0),
                EntryButtons(Dir.Entries[K].Name), '-') + '</td></tr>';
          end;
        if OldFiles > 0 then
          Body := Body + '<h3>' + TxE('files') + ' (' + IntToStr(OldFiles) + ', ' +
            HtmlEncode(FormatByteSize(OldBytes)) + ')</h3>' + Html + '</table>';
      end;
    finally
      Names.Free;
    end;
    if ForRepo then
      Send(RepoFull + ' - ' + Tx('old-data'), RepoCrumbs(TxE('old-data')), Body)
    else
      Send(Owner + ' ' + Stamp + ' - ' + Tx('old-data'), BaseCrumbs('<strong>' + TxE('old-data') +
        '</strong>'), Body);
  end;

  // Deleting the old data: the rows from the .db and their entries from the
  // .zip, which is rewritten without them (their bytes are freed), under the
  // backup lock and with the commit protocol shared with github-to-gitea.
  procedure PageDeleteOld;
  var
    Body, Expected, Typed, LockText, E, Summary, DbTmp, ZipTmp: string;
    Names: TStringList;
    Counts: TStringList;
    Statements: TSqlStatements;
    K, OldRows, OldFiles, Dropped, Changes: Integer;
    OldBytes, DroppedBytes, ZipBefore: Int64;
    Committing, Ok: Boolean;
  begin
    if (Stamp <> BACKUP_CURRENT) or not HasMarker then
    begin
      Send(Owner + ' ' + Stamp + ' - ' + Tx('delete-old-data'), BaseCrumbs('<strong>' +
        TxE('delete-old-data') + '</strong>'), '<p>' + TxE('old-data-no-marker') + '</p>');
      Exit;
    end;
    Expected := 'backup-delete-old:' + Owner + '/' + Stamp;
    if Op = 'delete-old' then
    begin
      Typed := GetFormFieldValue(ARequest, 'confirm_name');
      if not SameText(PostedAction, Expected) then
        Err := Tx('error') + ': token'
      else if Typed <> Owner then
        Err := Tx('delete-old-data-wrong-name')
      else if WriteBegin(LockText) then
      try
        Names := TStringList.Create;
        Names.CaseSensitive := True;
        Names.Sorted := True;
        Names.Duplicates := dupIgnore;
        try
          MeasureOld(OldRows, OldFiles, OldBytes, Names, nil);
          if OldRows + OldFiles = 0 then
            Msg := Tx('old-data-none')
          else
          begin
            DbTmp := DbPath + '.tmp';
            ZipTmp := ZipPath + '.tmp';
            ZipBefore := BkFileSize(ZipPath);
            Summary := BkUtcIsoNow + ': ' + IntToStr(OldRows) + ' rows, ' + IntToStr(OldFiles) +
              ' files, ' + IntToStr(OldBytes) + ' bytes';
            Committing := False;
            Ok := BkCopyFile(DbPath, DbTmp, E);
            if Ok then
            begin
              Statements := nil;
              for K := Low(DATA_TABLES) to High(DATA_TABLES) do
                if TableHasSeen(DATA_TABLES[K]) then
                begin
                  SetLength(Statements, Length(Statements) + 1);
                  Statements[High(Statements)] := SqlStmt('DELETE FROM ' + DATA_TABLES[K] +
                    ' WHERE ' + OLD_SQL, []);
                end;
              SetLength(Statements, Length(Statements) + 1);
              Statements[High(Statements)] := SqlStmt('INSERT OR REPLACE INTO meta(key, value) ' +
                'VALUES (''deleted_old_only'', ?1)', [Summary]);
              Ok := BkSqlExecAll(DbTmp, Statements, Changes, E);
            end;
            if Ok then
            begin
              BkSyncFile(DbTmp);
              if Names.Count > 0 then
                Ok := ZipRewriteWithout(ZipPath, ZipTmp, Names, Dropped, DroppedBytes, E);
            end;
            if Ok then
            begin
              Committing := True;
              Ok := BkCommitFiles(OwnerDir, Owner, E);
            end;
            if Ok then
            begin
              Msg := Tx('old-data-deleted') + ' ' + Summary + '. ' + Tx('space-freed') + ': ' +
                FormatByteSize(ZipBefore - BkFileSize(ZipPath));
              LogActivity(Username, SessionId, 'backup-delete-old', 'ok', Owner + '/' + Stamp + ' ' +
                Summary, ARequest, -1);
            end
            else
            begin
              Err := Tx('error') + ': ' + E;
              // Before the commit marker nothing was decided: the copies go.
              if not Committing then
              begin
                DeleteFile(DbTmp);
                DeleteFile(ZipTmp);
              end;
              LogActivity(Username, SessionId, 'backup-delete-old', 'error', Owner + '/' + Stamp + ' ' + E,
                ARequest, -1);
            end;
          end;
        finally
          Names.Free;
        end;
      finally
        WriteEnd(LockText);
      end;
    end;

    Names := TStringList.Create;
    Names.CaseSensitive := True;
    Names.Sorted := True;
    Counts := TStringList.Create;
    try
      MeasureOld(OldRows, OldFiles, OldBytes, Names, Counts);
      Body := '<p>' + TxE('old-data-help') + '</p>';
      if OldRows + OldFiles = 0 then
        Body := Body + '<p>' + TxE('old-data-none') + '</p>'
      else
      begin
        Body := Body + '<table border="1" cellpadding="3" cellspacing="0">' +
          BkHeaderRow([Tx('rows'), '']);
        for K := Low(DATA_TABLES) to High(DATA_TABLES) do
          if StrToIntDef(Counts.Values[DATA_TABLES[K]], 0) > 0 then
            Body := Body + '<tr><td>' + TxE(DATA_TABLE_KEYS[K]) + '</td><td align="right">' +
              HtmlEncode(Counts.Values[DATA_TABLES[K]]) + '</td></tr>';
        Body := Body + '<tr><td><b>' + TxE('rows') + '</b></td><td align="right"><b>' + IntToStr(OldRows) +
          '</b></td></tr></table>';
        if Names.Count > 0 then
        begin
          Body := Body + '<h3>' + TxE('files') + ' (' + IntToStr(OldFiles) + ')</h3><p>';
          for K := 0 to Names.Count - 1 do
            Body := Body + HtmlEncode(Names[K]) + '<br>';
          Body := Body + '</p>';
        end;
        Body := Body + '<p>' + TxE('space-freed') + ': <b>' + HtmlEncode(FormatByteSize(OldBytes)) +
          '</b> (' + IntToStr(OldBytes) + ')</p>' +
          '<form method="POST" action="' + HtmlEncode(Base + '/delete-old') + '">' +
          BuildAuthHiddenFields(ARequest, Expected) + BuildHiddenInput('op', 'delete-old') +
          '<p>' + TxE('delete-old-data-confirm') + ' <b>' + HtmlEncode(Owner) + '</b><br>' +
          '<input type="text" name="confirm_name" size="40" value=""> ' +
          '<input type="submit" value="' + TxE('delete-old-data') + '"></p></form>';
      end;
      Body := Body + '<p>' + Nav(Base + '/old', Tx('old-data'), '') + '</p>';
    finally
      Counts.Free;
      Names.Free;
    end;
    Send(Owner + ' ' + Stamp + ' - ' + Tx('delete-old-data'), BaseCrumbs(Nav(Base + '/old', Tx('old-data'), '') +
      ' &gt; <strong>' + TxE('delete-old-data') + '</strong>'), Body);
  end;

  procedure PageIssues(IsPull: Boolean);
  var
    Body, Path: string;
    Rows: TSqlRows;
    K, Offset, Shown: Integer;
    OldNums: TStringList;
  begin
    Offset := Max(0, StrToIntDef(GetFormFieldValue(ARequest, 'offset'), 0));
    Path := Base + '/' + BkUrlPart(RepoName) + '/' + Tab;
    Body := RepoTabs;
    OldNums := OldSet('SELECT number FROM issues WHERE repo = ?1 AND ' + OLD_SQL, [RepoFull]);
    if Q('SELECT i.number, i.title, i.state, json_extract(i.j, ''$.user.login''), ' +
      'json_extract(i.j, ''$.created_at''), ' +
      '(SELECT COUNT(*) FROM comments c WHERE c.repo = i.repo AND c.issue_number = i.number), ' +
      'COALESCE(json_extract(i.j, ''$.pull_request.merged''), (SELECT json_extract(p.json, ''$.merged'') ' +
      'FROM pulls p WHERE p.repo = i.repo AND p.number = i.number AND json_valid(p.json)), 0) ' +
      'FROM (SELECT repo, number, title, state, ' + JSON_OF + ' AS j FROM issues ' +
      'WHERE repo = ?1 AND is_pull = CAST(?2 AS INTEGER)) i ORDER BY i.number DESC ' +
      'LIMIT CAST(?3 AS INTEGER) OFFSET CAST(?4 AS INTEGER)',
      [RepoFull, ifthen(IsPull, '1', '0'), IntToStr(BACKUP_PAGE_SIZE + 1), IntToStr(Offset)],
      Rows) then
    begin
      Shown := Min(Length(Rows), BACKUP_PAGE_SIZE);
      if Shown = 0 then
        Body := Body + '<p>' + TxE('no-results') + '</p>'
      else
      begin
        Body := Body + '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
          BkHeaderRow([Tx('number'), Tx('title'), Tx('state'), Tx('author'), Tx('created'),
            Tx('comments')]);
        for K := 0 to Shown - 1 do
          Body := Body + '<tr><td>' +
            Nav(Base + '/' + BkUrlPart(RepoName) + '/issue/' + Rows[K][0], '#' + Rows[K][0], '') +
            '</td><td>' + HtmlEncode(Rows[K][1]) + ifthen(OldNums.IndexOf(Rows[K][0]) >= 0, OldMark, '') +
            '</td><td>' +
            HtmlEncode(BkStateLabel(Rows[K][2], ifthen(IsPull, Rows[K][6], ''), Translations)) +
            '</td><td>' + HtmlEncode(Rows[K][3]) + '</td><td>' + HtmlEncode(Rows[K][4]) +
            '</td><td align="right">' + HtmlEncode(Rows[K][5]) + '</td></tr>';
        Body := Body + '</table>' +
          PageButtons(Path, Offset, Shown, Length(Rows) > BACKUP_PAGE_SIZE, '');
      end;
    end;
    OldNums.Free;
    if IsPull then
      Send(RepoFull + ' - ' + Tx('pull-requests'), RepoCrumbs(TxE('pull-requests')), Body)
    else
      Send(RepoFull + ' - ' + Tx('issues'), RepoCrumbs(TxE('issues')), Body);
  end;

  procedure PageIssue(const Number: string);
  var
    Body, Path, Expected, NewTitle, NewBody, OldBody, CommentId, EditComment,
      SaveErr, IssueTitle, LockText: string;
    OldComments: TStringList;
    Rows, CRows: TSqlRows;
    Statements: TSqlStatements;
    Changes, K: Integer;
    IsPull: Boolean;
  const
    ISSUE_SQL = 'SELECT i.number, i.is_pull, i.title, i.state, json_extract(i.j, ''$.user.login''), ' +
      'json_extract(i.j, ''$.created_at''), json_extract(i.j, ''$.body''), ' +
      '(SELECT group_concat(json_extract(value, ''$.name''), '', '') FROM json_each(i.j, ''$.labels'')), ' +
      'json_extract(i.j, ''$.closed_at''), json_extract(i.j, ''$.milestone.title''), ' +
      'COALESCE(json_extract(i.j, ''$.pull_request.merged''), (SELECT json_extract(p.json, ''$.merged'') ' +
      'FROM pulls p WHERE p.repo = i.repo AND p.number = i.number AND json_valid(p.json)), 0), ' +
      '(SELECT json_extract(p.json, ''$.head.label'') || '' -> '' || json_extract(p.json, ''$.base.label'') ' +
      'FROM pulls p WHERE p.repo = i.repo AND p.number = i.number AND json_valid(p.json)) ' +
      'FROM (SELECT repo, number, is_pull, title, state, ' + JSON_OF + ' AS j FROM issues ' +
      'WHERE repo = ?1 AND number = CAST(?2 AS INTEGER)) i';
    COMMENT_SQL = 'SELECT id, json_extract(j, ''$.user.login''), json_extract(j, ''$.created_at''), ' +
      'json_extract(j, ''$.body'') FROM (SELECT id, ' + JSON_OF + ' AS j FROM comments ' +
      'WHERE repo = ?1 AND issue_number = CAST(?2 AS INTEGER)) ORDER BY id';
  begin
    Path := Base + '/' + BkUrlPart(RepoName) + '/issue/' + Number;
    if not Q(ISSUE_SQL, [RepoFull, Number], Rows) then
    begin
      NotFound(Err);
      Exit;
    end;
    if Length(Rows) = 0 then
    begin
      NotFound(RepoFull + ' #' + Number);
      Exit;
    end;
    EditComment := '';

    if Op = 'save-issue' then
    begin
      Expected := 'backup-save-issue:' + Owner + '/' + Stamp + ':' + RepoFull + ':' + Number;
      NewTitle := Trim(ARequest.ContentFields.Values['title']);
      NewBody := BkNormalizeNewlines(ARequest.ContentFields.Values['body'], Rows[0][6]);
      if not SameText(PostedAction, Expected) then
        Err := Tx('error') + ': token'
      else if NewTitle = '' then
        Err := Tx('error') + ': ' + Tx('title')
      else if WriteBegin(LockText) then
      try
        SetLength(Statements, 2);
        Statements[0] := SqlStmt('UPDATE issues SET title = ?1, json = json_set(json, ''$.title'', ?1, ' +
          '''$.body'', ?2) WHERE repo = ?3 AND number = CAST(?4 AS INTEGER)',
          [NewTitle, NewBody, RepoFull, Number]);
        Statements[1] := SqlStmt('UPDATE pulls SET json = json_set(json, ''$.title'', ?1, ' +
          '''$.body'', ?2) WHERE repo = ?3 AND number = CAST(?4 AS INTEGER) AND json_valid(json)',
          [NewTitle, NewBody, RepoFull, Number]);
        if BkSqlExecAll(DbPath, Statements, Changes, SaveErr) and (Changes > 0) then
        begin
          Msg := Tx('saved');
          LogActivity(Username, SessionId, 'backup-save-issue', 'ok',
            Owner + '/' + Stamp + ' ' + RepoFull + '#' + Number, ARequest, -1);
        end
        else
          Err := Tx('error') + ': ' + SaveErr;
        Q(ISSUE_SQL, [RepoFull, Number], Rows);
      finally
        WriteEnd(LockText);
      end;
    end
    else if Op = 'save-comment' then
    begin
      CommentId := GetFormFieldValue(ARequest, 'comment');
      Expected := 'backup-save-comment:' + Owner + '/' + Stamp + ':' + RepoFull + ':' + CommentId;
      if not BkIsDigits(CommentId) or not SameText(PostedAction, Expected) then
        Err := Tx('error') + ': token'
      else if WriteBegin(LockText) then
      try
        OldBody := '';
        if Q('SELECT json_extract(' + JSON_OF + ', ''$.body'') FROM comments WHERE repo = ?1 AND ' +
          'id = CAST(?2 AS INTEGER)', [RepoFull, CommentId], CRows) and (Length(CRows) > 0) then
          OldBody := CRows[0][0];
        NewBody := BkNormalizeNewlines(ARequest.ContentFields.Values['body'], OldBody);
        SetLength(Statements, 1);
        Statements[0] := SqlStmt('UPDATE comments SET json = json_set(json, ''$.body'', ?1) ' +
          'WHERE repo = ?2 AND id = CAST(?3 AS INTEGER) AND issue_number = CAST(?4 AS INTEGER)',
          [NewBody, RepoFull, CommentId, Number]);
        if BkSqlExecAll(DbPath, Statements, Changes, SaveErr) and (Changes > 0) then
        begin
          Msg := Tx('saved');
          LogActivity(Username, SessionId, 'backup-save-comment', 'ok',
            Owner + '/' + Stamp + ' ' + RepoFull + '#' + Number + ' comment ' + CommentId,
            ARequest, -1);
        end
        else if SaveErr <> '' then
          Err := Tx('error') + ': ' + SaveErr
        else
          Err := Tx('not-found');
      finally
        WriteEnd(LockText);
      end;
    end
    else if Op = 'edit-comment' then
    begin
      EditComment := GetFormFieldValue(ARequest, 'comment');
      if not BkIsDigits(EditComment) then
        EditComment := '';
    end;

    IsPull := Rows[0][1] = '1';
    IssueTitle := Rows[0][2];
    Body := RepoTabs + '<h2>' + HtmlEncode(IssueTitle) + ' #' + HtmlEncode(Number) + '</h2>';
    if IsOld('SELECT number FROM issues WHERE repo = ?1 AND number = CAST(?2 AS INTEGER) AND ' + OLD_SQL,
      [RepoFull, Number]) then
      Body := Body + '<p>' + OldMark + ' ' + TxE('old-data-help') + '</p>';
    Body := Body + '<table border="0" cellpadding="3">' +
      '<tr><td><b>' + TxE('state') + '</b></td><td>' +
      HtmlEncode(BkStateLabel(Rows[0][3], ifthen(IsPull, Rows[0][10], ''), Translations)) + '</td></tr>' +
      '<tr><td><b>' + TxE('author') + '</b></td><td>' + HtmlEncode(Rows[0][4]) + '</td></tr>' +
      '<tr><td><b>' + TxE('created') + '</b></td><td>' + HtmlEncode(Rows[0][5]) + '</td></tr>';
    if Rows[0][8] <> '' then
      Body := Body + '<tr><td><b>' + TxE('closed') + '</b></td><td>' + HtmlEncode(Rows[0][8]) + '</td></tr>';
    if Rows[0][7] <> '' then
      Body := Body + '<tr><td><b>' + TxE('labels') + '</b></td><td>' + HtmlEncode(Rows[0][7]) + '</td></tr>';
    if Rows[0][9] <> '' then
      Body := Body + '<tr><td><b>' + TxE('milestones') + '</b></td><td>' + HtmlEncode(Rows[0][9]) + '</td></tr>';
    if IsPull and (Rows[0][11] <> '') then
      Body := Body + '<tr><td><b>' + TxE('pull-requests') + '</b></td><td>' + HtmlEncode(Rows[0][11]) + '</td></tr>';
    Body := Body + '</table>';

    if Op = 'edit-issue' then
      Body := Body + '<form method="POST" action="' + HtmlEncode(Path) + '">' +
        BuildAuthHiddenFields(ARequest, 'backup-save-issue:' + Owner + '/' + Stamp + ':' +
          RepoFull + ':' + Number) +
        BuildHiddenInput('op', 'save-issue') +
        '<table border="1" cellpadding="5" cellspacing="0">' +
        '<tr><td>' + TxE('title') + '</td><td><input type="text" name="title" size="70" value="' +
        HtmlEncode(IssueTitle) + '"></td></tr>' +
        '<tr><td valign="top">' + TxE('description') + '</td><td><textarea name="body" rows="20" cols="80">' +
        LineEnding + HtmlEncode(Rows[0][6]) + '</textarea></td></tr>' +
        '<tr><td colspan="2"><input type="submit" value="' + TxE('save') + '"></td></tr></table></form>' +
        '<p>' + Nav(Path, Tx('cancel'), '') + '</p>'
    else
      Body := Body + '<table border="1" width="100%" cellpadding="5" cellspacing="0"><tr><td>' +
        ifthen(Rows[0][6] <> '', BkTextHtml(Rows[0][6]), '&nbsp;') + '</td></tr></table>' +
        '<p>' + Nav(Path, Tx('edit'), BuildHiddenInput('op', 'edit-issue')) + '</p>';
    Body := Body + AttachedFiles('issues', Number);

    OldComments := OldSet('SELECT id FROM comments WHERE repo = ?1 AND issue_number = CAST(?2 AS INTEGER) AND ' +
      OLD_SQL, [RepoFull, Number]);
    if Q(COMMENT_SQL, [RepoFull, Number], CRows) then
    begin
      Body := Body + '<h3>' + TxE('comments') + ' (' + IntToStr(Length(CRows)) + ')</h3>';
      for K := 0 to High(CRows) do
      begin
        Body := Body + '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
          '<tr bgcolor="#dddddd"><td><b>' + HtmlEncode(CRows[K][1]) + '</b> ' +
          HtmlEncode(CRows[K][2]) + ifthen(OldComments.IndexOf(CRows[K][0]) >= 0, OldMark, '') +
          '</td></tr><tr><td>';
        if CRows[K][0] = EditComment then
          Body := Body + '<form method="POST" action="' + HtmlEncode(Path) + '">' +
            BuildAuthHiddenFields(ARequest, 'backup-save-comment:' + Owner + '/' + Stamp + ':' +
              RepoFull + ':' + CRows[K][0]) +
            BuildHiddenInput('op', 'save-comment') + BuildHiddenInput('comment', CRows[K][0]) +
            '<textarea name="body" rows="12" cols="80">' + LineEnding + HtmlEncode(CRows[K][3]) +
            '</textarea><br><input type="submit" value="' + TxE('save') + '"></form> ' +
            Nav(Path, Tx('cancel'), '')
        else
          Body := Body + ifthen(CRows[K][3] <> '', BkTextHtml(CRows[K][3]), '&nbsp;') +
            '<p>' + Nav(Path, Tx('edit'), BuildHiddenInput('op', 'edit-comment') +
            BuildHiddenInput('comment', CRows[K][0])) + '</p>';
        Body := Body + AttachedFiles('comments', CRows[K][0]) + '</td></tr></table><br>';
      end;
    end;
    OldComments.Free;
    Send(RepoFull + ' #' + Number, RepoCrumbs(Nav(Base + '/' + BkUrlPart(RepoName) + '/' +
      ifthen(IsPull, 'pulls', 'issues'), ifthen(IsPull, Tx('pull-requests'), Tx('issues')), '') +
      ' &gt; <strong>#' + HtmlEncode(Number) + '</strong>'), Body);
  end;

  procedure PageReleases;
  var
    Body: string;
    Rows: TSqlRows;
    K: Integer;
    OldIds: TStringList;
  begin
    Body := RepoTabs;
    OldIds := OldSet('SELECT id FROM releases WHERE repo = ?1 AND ' + OLD_SQL, [RepoFull]);
    if Q('SELECT id, tag, json_extract(j, ''$.name''), ' +
      'COALESCE(json_extract(j, ''$.published_at''), json_extract(j, ''$.created_at'')), ' +
      'json_extract(j, ''$.author.login''), json_extract(j, ''$.body''), json_extract(j, ''$.draft''), ' +
      'json_extract(j, ''$.prerelease'') FROM (SELECT id, tag, ' + JSON_OF + ' AS j FROM releases ' +
      'WHERE repo = ?1) ORDER BY 4 DESC, id DESC', [RepoFull], Rows) then
    begin
      if Length(Rows) = 0 then
        Body := Body + '<p>' + TxE('no-results') + '</p>';
      for K := 0 to High(Rows) do
      begin
        Body := Body + '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
          '<tr bgcolor="#dddddd"><td><b>' + HtmlEncode(Rows[K][1]) + '</b>' +
          ifthen((Rows[K][2] <> '') and (Rows[K][2] <> Rows[K][1]), ' - ' + HtmlEncode(Rows[K][2]), '') +
          ifthen(Rows[K][6] = '1', ' (draft)', '') + ifthen(Rows[K][7] = '1', ' (pre-release)', '') +
          ifthen(OldIds.IndexOf(Rows[K][0]) >= 0, OldMark, '') +
          '<br><small>' + TxE('author') + ': ' + HtmlEncode(Rows[K][4]) + ' &nbsp; ' +
          TxE('date') + ': ' + HtmlEncode(Rows[K][3]) + '</small></td></tr><tr><td>' +
          ifthen(Rows[K][5] <> '', BkTextHtml(Rows[K][5]), '&nbsp;') +
          AttachedFiles('releases', Rows[K][0]) + '</td></tr></table><br>';
      end;
    end;
    OldIds.Free;
    Send(RepoFull + ' - ' + Tx('releases'), RepoCrumbs(TxE('releases')), Body);
  end;

  procedure PageLabels;
  var
    Body, Color: string;
    Rows: TSqlRows;
    K, C: Integer;
    ColorOk: Boolean;
  begin
    Body := RepoTabs;
    if Q('SELECT name, json_extract(j, ''$.color''), json_extract(j, ''$.description'') ' +
      'FROM (SELECT name, ' + JSON_OF + ' AS j FROM labels WHERE repo = ?1) ORDER BY name',
      [RepoFull], Rows) then
    begin
      Body := Body + '<h3>' + TxE('labels') + '</h3><table border="1" cellpadding="5" cellspacing="0">' +
        BkHeaderRow([Tx('name'), Tx('description')]);
      for K := 0 to High(Rows) do
      begin
        Color := Rows[K][1];
        if (Color <> '') and (Color[1] = '#') then
          Delete(Color, 1, 1);
        ColorOk := Length(Color) = 6;
        for C := 1 to Length(Color) do
          if not (Color[C] in ['0'..'9', 'a'..'f', 'A'..'F']) then
            ColorOk := False;
        Body := Body + '<tr><td' + ifthen(ColorOk, ' bgcolor="#' + Color + '"', '') + '>' +
          HtmlEncode(Rows[K][0]) + '</td><td>' + BkTextHtml(Rows[K][2]) + '</td></tr>';
      end;
      Body := Body + '</table>';
    end;
    if Q('SELECT title, json_extract(j, ''$.state''), json_extract(j, ''$.due_on''), ' +
      'json_extract(j, ''$.open_issues''), json_extract(j, ''$.closed_issues''), ' +
      'json_extract(j, ''$.description'') FROM (SELECT id, title, ' + JSON_OF + ' AS j ' +
      'FROM milestones WHERE repo = ?1) ORDER BY id', [RepoFull], Rows) then
    begin
      Body := Body + '<h3>' + TxE('milestones') + '</h3><table border="1" cellpadding="5" cellspacing="0">' +
        BkHeaderRow([Tx('title'), Tx('state'), Tx('date'), Tx('open'), Tx('closed'), Tx('description')]);
      for K := 0 to High(Rows) do
        Body := Body + '<tr><td>' + HtmlEncode(Rows[K][0]) + '</td><td>' +
          HtmlEncode(BkStateLabel(Rows[K][1], '', Translations)) + '</td><td>' +
          HtmlEncode(Rows[K][2]) + '</td><td align="right">' + HtmlEncode(Rows[K][3]) +
          '</td><td align="right">' + HtmlEncode(Rows[K][4]) + '</td><td>' +
          BkTextHtml(Rows[K][5]) + '</td></tr>';
      Body := Body + '</table>';
    end;
    Send(RepoFull + ' - ' + Tx('labels'), RepoCrumbs(TxE('labels')), Body);
  end;

  procedure PageFiles(const Prefix: string);
  var
    Body, Path, E, TitleText, CrumbHtml: string;
    Dir: TZipDirectory;
    K, Offset, Matched, Shown: Integer;
    HasMore: Boolean;
    OldNames: TStringList;
  begin
    OldNames := OldEntryNames;
    Offset := Max(0, StrToIntDef(GetFormFieldValue(ARequest, 'offset'), 0));
    if Prefix = '' then
    begin
      Path := Base + '/files';
      Body := '';
      TitleText := Owner + ' ' + Stamp + ' - ' + Tx('files');
      CrumbHtml := BaseCrumbs('<strong>' + TxE('files') + '</strong>');
    end
    else
    begin
      Path := Base + '/' + BkUrlPart(RepoName) + '/files';
      Body := RepoTabs;
      TitleText := RepoFull + ' - ' + Tx('files');
      CrumbHtml := RepoCrumbs(TxE('files'));
    end;
    if not ZipReadDirectory(ZipPath, Dir, E) then
      Err := Tx('error') + ': ' + ExtractFileName(ZipPath) + ': ' + E
    else
    begin
      Body := Body + '<table border="1" width="100%" cellpadding="5" cellspacing="0">' +
        BkHeaderRow([Tx('path'), Tx('size'), '']);
      Matched := 0;
      Shown := 0;
      HasMore := False;
      for K := 0 to High(Dir.Entries) do
      begin
        if (Prefix <> '') and (Copy(Dir.Entries[K].Name, 1, Length(Prefix)) <> Prefix) then
          Continue;
        if (Dir.Entries[K].Name <> '') and (Dir.Entries[K].Name[Length(Dir.Entries[K].Name)] = '/') then
          Continue;
        Inc(Matched);
        if Matched <= Offset then
          Continue;
        if Shown >= BACKUP_PAGE_SIZE then
        begin
          HasMore := True;
          Break;
        end;
        Inc(Shown);
        Body := Body + '<tr><td>' + HtmlEncode(Dir.Entries[K].Name) +
          ifthen(OldNames.IndexOf(Dir.Entries[K].Name) >= 0, OldMark, '') + '</td><td align="right">' +
          HtmlEncode(FormatByteSize(Dir.Entries[K].Size)) + '</td><td>';
        if not ZipEntryNameIsSafe(Dir.Entries[K].Name) then
          Body := Body + '-'
        else if Dir.Entries[K].Method <> 0 then
          Body := Body + 'compressed'
        else
          Body := Body + EntryButtons(Dir.Entries[K].Name);
        Body := Body + '</td></tr>';
      end;
      if Shown = 0 then
        Body := Body + '<tr><td colspan="3">' + TxE('no-results') + '</td></tr>';
      Body := Body + '</table>' + PageButtons(Path, Offset, Shown, HasMore, '');
    end;
    OldNames.Free;
    Send(TitleText, CrumbHtml, Body);
  end;

  procedure PageFile;
  var
    EntryName, E, Body, Expected, NewText, OldText, Sha, Back, FileRepo, LockText: string;
    OldNames: TStringList;
    Dir: TZipDirectory;
    Idx: Integer;
    Entry: TZipEntry;
    Data, Sample: RawByteString;
    Stream: TStream;
    Rows: TSqlRows;
    Statements: TSqlStatements;
    Changes: Integer;
    IsText, Editable: Boolean;
  begin
    EntryName := GetFormFieldValue(ARequest, 'entry');
    if not ZipEntryNameIsSafe(EntryName) then
    begin
      NotFound(EntryName);
      Exit;
    end;
    if not ZipReadDirectory(ZipPath, Dir, E) then
    begin
      NotFound(E);
      Exit;
    end;
    Idx := ZipFindEntry(Dir, EntryName);
    if Idx < 0 then
    begin
      NotFound(EntryName);
      Exit;
    end;
    Entry := Dir.Entries[Idx];

    if (Op = 'download') and (PostedAction = 'backup-download') then
    begin
      if not ZipOpenEntryStream(ZipPath, Entry, Stream, E) then
      begin
        NotFound(E);
        Exit;
      end;
      AResponse.ContentType := BkMime(EntryName);
      AResponse.CustomHeaders.Values['Content-Disposition'] := 'attachment; filename="' +
        BkDownloadName(EntryName) + '"; filename*=UTF-8''''' +
        BkUrlPart(Copy(EntryName, LastDelimiter('/', EntryName) + 1, MaxInt));
      AResponse.CustomHeaders.Values['X-Content-Type-Options'] := 'nosniff';
      AResponse.CustomHeaders.Values['Content-Security-Policy'] := 'default-src ''none''; sandbox';
      AResponse.CustomHeaders.Values['Cache-Control'] := 'no-store';
      AResponse.FreeContentStream := True;
      AResponse.ContentStream := Stream;
      // ContentLength is a 32-bit Integer in fcl-web: set the header itself.
      AResponse.SetFieldByName('Content-Length', IntToStr(Entry.Size));
      Exit;
    end;

    if Op = 'save' then
    begin
      Expected := 'backup-save-file:' + Owner + '/' + Stamp + ':' + EntryName;
      NewText := ARequest.ContentFields.Values['content'];
      if not SameText(PostedAction, Expected) then
        Err := Tx('error') + ': token'
      else if (Entry.Size > BACKUP_EDIT_LIMIT) or (Length(NewText) > BACKUP_EDIT_LIMIT) then
        Err := Tx('file-too-large-to-edit')
      else if not ZipReadEntryBytes(ZipPath, Entry, BACKUP_EDIT_LIMIT, Data, E) then
        Err := Tx('error') + ': ' + E
      else if not IsValidUtf8(Data) then
        Err := Tx('error') + ': not a text file'
      else if WriteBegin(LockText) then
      try
        OldText := Data;
        NewText := BkNormalizeNewlines(NewText, OldText);
        if not IsValidUtf8(NewText) and (NewText <> '') then
          Err := Tx('error') + ': not UTF-8 text'
        else if not ZipReplaceEntry(ZipPath, EntryName, NewText, E) then
          Err := Tx('error') + ': ' + E
        else
        begin
          SetLength(Statements, 1);
          Statements[0] := SqlStmt('UPDATE files SET size = CAST(?1 AS INTEGER), sha256 = ?2 ' +
            'WHERE path = ?3', [IntToStr(Length(NewText)), Sha256Hex(NewText), EntryName]);
          if not BkSqlExecAll(DbPath, Statements, Changes, E) then
            Err := Tx('error') + ': ' + DbPath + ': ' + E
          else
            Msg := Tx('saved');
          LogActivity(Username, SessionId, 'backup-save-file', ifthen(Err = '', 'ok', 'db-error'),
            Owner + '/' + Stamp + ' ' + EntryName, ARequest, -1);
          if ZipReadDirectory(ZipPath, Dir, E) then
          begin
            Idx := ZipFindEntry(Dir, EntryName);
            if Idx >= 0 then
              Entry := Dir.Entries[Idx];
          end;
        end;
      finally
        WriteEnd(LockText);
      end;
    end;

    Sha := '';
    FileRepo := '';
    Back := '';
    if Q('SELECT f.repo, f.kind, f.parent, f.sha256, r.name, ' +
      '(SELECT c.issue_number FROM comments c WHERE c.repo = f.repo AND f.kind = ''comments'' ' +
      'AND c.id = CAST(f.parent AS INTEGER)) FROM files f LEFT JOIN repos r ON r.full_name = f.repo ' +
      'WHERE f.path = ?1', [EntryName], Rows) and (Length(Rows) > 0) then
    begin
      Sha := Rows[0][3];
      FileRepo := Rows[0][4];
      if FileRepo <> '' then
      begin
        if Rows[0][1] = 'issues' then
          Back := Nav(Base + '/' + BkUrlPart(FileRepo) + '/issue/' + BkUrlPart(Rows[0][2]),
            '#' + Rows[0][2], '')
        else if (Rows[0][1] = 'comments') and (Rows[0][5] <> '') then
          Back := Nav(Base + '/' + BkUrlPart(FileRepo) + '/issue/' + BkUrlPart(Rows[0][5]),
            '#' + Rows[0][5], '')
        else if Rows[0][1] = 'releases' then
          Back := Nav(Base + '/' + BkUrlPart(FileRepo) + '/releases', Tx('releases'), '');
      end;
    end;
    if (FileRepo = '') and (Pos('/', EntryName) > 0) then
    begin
      // A git bundle or another file without a row: its repository by folder.
      if Q('SELECT name FROM repos', [], Rows) then
        for Idx := 0 to High(Rows) do
          if BkSafePart(Rows[Idx][0]) + '/' = Copy(EntryName, 1, Pos('/', EntryName)) then
            FileRepo := Rows[Idx][0];
    end;

    // What is shown: a bounded first part, never the whole of a big entry.
    Sample := '';
    IsText := False;
    if (Entry.Method = 0) and not BkIsInlineImage(EntryName) then
      if ZipReadEntryBytes(ZipPath, Entry, BACKUP_TEXT_SHOW_LIMIT, Sample, E) then
        IsText := (Pos(#0, Sample) = 0) and
          (IsValidUtf8(Sample) or (Entry.Size > BACKUP_TEXT_SHOW_LIMIT));
    Editable := IsText and (Entry.Size <= BACKUP_EDIT_LIMIT) and (Entry.Method = 0);

    OldNames := OldEntryNames;
    Body := '<h2>' + HtmlEncode(EntryName) + '</h2>';
    if OldNames.IndexOf(EntryName) >= 0 then
      Body := Body + '<p>' + OldMark + ' ' + TxE('old-data-help') + '</p>';
    OldNames.Free;
    Body := Body + '<table border="0" cellpadding="3">' +
      '<tr><td><b>' + TxE('size') + '</b></td><td>' + HtmlEncode(FormatByteSize(Entry.Size)) +
      ' (' + IntToStr(Entry.Size) + ')</td></tr>';
    if Sha <> '' then
      Body := Body + '<tr><td><b>SHA256</b></td><td><tt>' + HtmlEncode(Sha) + '</tt></td></tr>';
    Body := Body + '</table><p>' + DownloadButton(EntryName);
    if Editable and (Op <> 'edit') then
      Body := Body + ' ' + Nav(Base + '/file', Tx('edit'), BuildHiddenInput('entry', EntryName) +
        BuildHiddenInput('op', 'edit'));
    if Back <> '' then
      Body := Body + ' ' + Back;
    Body := Body + '</p>';

    if Op = 'edit' then
    begin
      // The form holds the WHOLE file, never the shown first part: saving a
      // part would cut the file short.
      Data := '';
      if Editable then
        Editable := ZipReadEntryBytes(ZipPath, Entry, BACKUP_EDIT_LIMIT, Data, E) and
          (Length(Data) = Entry.Size) and IsValidUtf8(Data);
      if Editable then
        Body := Body + '<form method="POST" action="' + HtmlEncode(Base + '/file') + '">' +
          BuildAuthHiddenFields(ARequest, 'backup-save-file:' + Owner + '/' + Stamp + ':' + EntryName) +
          BuildHiddenInput('entry', EntryName) + BuildHiddenInput('op', 'save') +
          '<textarea name="content" rows="30" cols="100">' + LineEnding + HtmlEncode(Data) +
          '</textarea><br><input type="submit" value="' + TxE('save') + '"></form>' +
          '<p>' + Nav(Base + '/file', Tx('cancel'), BuildHiddenInput('entry', EntryName)) + '</p>'
      else
        Body := Body + '<p>' + TxE('file-too-large-to-edit') + '</p>';
    end
    else if BkIsInlineImage(EntryName) and (Entry.Method = 0) and
      (Entry.Size <= BACKUP_IMAGE_INLINE_LIMIT) then
    begin
      if ZipReadEntryBytes(ZipPath, Entry, BACKUP_IMAGE_INLINE_LIMIT, Data, E) then
        Body := Body + '<p><img src="data:' + BkMime(EntryName) + ';base64,' + Base64Encode(Data) +
          '" alt="' + HtmlEncode(ExtractFileName(EntryName)) + '"></p>';
    end
    else if IsText then
    begin
      Body := Body + '<table border="1" width="100%" cellpadding="5" cellspacing="0"><tr><td><pre>' +
        StringReplace(HtmlEncode(Sample), #13, '', [rfReplaceAll]) + '</pre></td></tr></table>';
      if Entry.Size > BACKUP_TEXT_SHOW_LIMIT then
        Body := Body + '<p><i>' + TxE('file-shown-partly') + '</i></p>';
    end
    else
      Body := Body + '<p>' + HtmlEncode(BkMime(EntryName)) + '</p>';

    if FileRepo <> '' then
      Send(EntryName, BaseCrumbs(Nav(Base + '/' + BkUrlPart(FileRepo), FileRepo, '') + ' &gt; ' +
        Nav(Base + '/' + BkUrlPart(FileRepo) + '/files', Tx('files'), '') + ' &gt; <strong>' +
        HtmlEncode(ExtractFileName(EntryName)) + '</strong>'), Body)
    else
      Send(EntryName, BaseCrumbs(Nav(Base + '/files', Tx('files'), '') + ' &gt; <strong>' +
        HtmlEncode(ExtractFileName(EntryName)) + '</strong>'), Body);
  end;

  function FindRepo(const Name: string): Boolean;
  var
    Rows: TSqlRows;
  begin
    Result := False;
    if not Q('SELECT full_name, name, json_extract(' + JSON_OF + ', ''$.description''), git_bundle ' +
      'FROM repos WHERE name = ?1', [Name], Rows) or (Length(Rows) = 0) then
      Exit;
    RepoName := Rows[0][1];
    RepoFull := Rows[0][0];
    RepoDescription := Rows[0][2];
    // The repository's folder in the zip: where its files are, else
    // safe_part(name) as gitea_backup names it.
    RepoFolder := '';
    if Q('SELECT path FROM files WHERE repo = ?1 LIMIT 1', [RepoFull], Rows) and
      (Length(Rows) > 0) and (Pos('/', Rows[0][0]) > 0) then
      RepoFolder := Copy(Rows[0][0], 1, Pos('/', Rows[0][0]) - 1);
    if RepoFolder = '' then
      RepoFolder := BkSafePart(RepoName);
    Result := True;
  end;

begin
  Username := GetUsernameFromRequest(ARequest);
  SessionId := GetSessionIdFromRequest(ARequest);
  // GET carries no session (no cookies): back to the public home page.
  if (Username = '') or (ARequest.Method <> 'POST') then
  begin
    RedirectToPublicHome(ARequest, AResponse);
    Exit;
  end;
  PostedAction := GetFormFieldValue(ARequest, 'auth_action');
  Op := GetFormFieldValue(ARequest, 'op');
  // A download shows no new page, so its token (signed for this one action
  // only) is checked without being used up: the buttons of the page the
  // browser stays on keep working. Everything else uses its token up.
  if (PostedAction = '') or
    ((PostedAction = 'backup-download') and ((Op <> 'download') or
      (Copy(ARequest.PathInfo, Length(ARequest.PathInfo) - 4, 5) <> '/file'))) or
    ((PostedAction = 'backup-download') and not VerifyActionTokenKeepingCounter(ARequest,
      PostedAction, SessionId, Username)) or
    ((PostedAction <> 'backup-download') and not VerifyAndConsumeActionToken(ARequest,
      PostedAction, SessionId, Username)) then
  begin
    RedirectToPublicHome(ARequest, AResponse);
    Exit;
  end;

  UserLang := '';
  UsersMap := LoadUsersMap;
  try
    if GetUserData(UsersMap, Username, StoredPassword, StoredOtp, StoredLanguage) then
      UserLang := Trim(StoredLanguage);
  finally
    UsersMap.Free;
  end;
  if UserLang = '' then
    UserLang := 'en';
  IsRtl := False;
  LangData := LoadLanguagesData;
  try
    if LangData.Find(UserLang) is TJSONObject then
      IsRtl := JsonGetBool(TJSONObject(LangData.Find(UserLang)), 'rtl', False);
  finally
    LangData.Free;
  end;

  Translations := LoadTranslations(UserLang);
  try
    Msg := '';
    Err := '';
    RawParts := ARequest.PathInfo.Split(['/']);
    Segs := nil;
    for I := 0 to High(RawParts) do
      if RawParts[I] <> '' then
      begin
        SetLength(Segs, Length(Segs) + 1);
        Segs[High(Segs)] := BkUrlDecode(RawParts[I]);
        // Never a path: a decoded segment with a separator, '.' or '..' is refused.
        if (Segs[High(Segs)] = '.') or (Segs[High(Segs)] = '..') or
          (Pos('/', Segs[High(Segs)]) > 0) or (Pos('\', Segs[High(Segs)]) > 0) or
          (Pos(#0, Segs[High(Segs)]) > 0) then
        begin
          NotFound('');
          Exit;
        end;
      end;
    if (Length(Segs) = 0) or (Segs[0] <> 'backups') then
    begin
      NotFound('');
      Exit;
    end;
    if Length(Segs) = 1 then
    begin
      PageList;
      Exit;
    end;
    if Length(Segs) < 3 then
    begin
      NotFound('');
      Exit;
    end;
    Owner := Segs[1];
    Stamp := Segs[2];
    if not ResolveBackup(Owner, Stamp, DbPath, ZipPath) then
    begin
      NotFound(Owner + ' ' + Stamp);
      Exit;
    end;
    Base := '/backups/' + BkUrlPart(Owner) + '/' + BkUrlPart(Stamp);
    OwnerDir := IncludeTrailingPathDelimiter(GetBackupsDir) + Owner;
    MarkerState := 0;
    if Length(Segs) = 3 then
      PageOverview
    else if (Length(Segs) = 4) and (Segs[3] = 'files') then
      PageFiles('')
    else if (Length(Segs) = 4) and (Segs[3] = 'old') then
      PageOld(False)
    else if (Length(Segs) = 4) and (Segs[3] = 'delete-old') then
      PageDeleteOld
    else if (Length(Segs) = 4) and (Segs[3] = 'file') then
      PageFile
    else if not FindRepo(Segs[3]) then
      NotFound(Segs[3])
    else
    begin
      if Length(Segs) = 4 then
        Tab := 'issues'
      else
        Tab := Segs[4];
      if (Length(Segs) <= 5) and (Tab = 'issues') then
        PageIssues(False)
      else if (Length(Segs) = 5) and (Tab = 'pulls') then
        PageIssues(True)
      else if (Length(Segs) = 5) and (Tab = 'releases') then
        PageReleases
      else if (Length(Segs) = 5) and (Tab = 'labels') then
        PageLabels
      else if (Length(Segs) = 5) and (Tab = 'files') then
        PageFiles(RepoFolder + '/')
      else if (Length(Segs) = 5) and (Tab = 'old') then
        PageOld(True)
      else if (Length(Segs) = 6) and (Tab = 'issue') and BkIsDigits(Segs[5]) then
      begin
        Tab := '';
        PageIssue(Segs[5]);
      end
      else
        NotFound(Tab);
    end;
  finally
    Translations.Free;
  end;
end;

{ --- Gitea folder: settings, and the command line ------------------------------ }

// A path setting: '~/' is the home directory, a relative path is beside
// settings.ini. Empty when not set and there is no default.
function SettingPath(const Key, DefaultValue: string): string;
var
  SettingsMap: TStringList;
  Value: string;
begin
  SettingsMap := LoadSettingsMap;
  try
    Value := Trim(SettingsMap.Values[Key]);
  finally
    SettingsMap.Free;
  end;
  if Value = '' then
    Value := DefaultValue;
  Result := '';
  if Value = '' then
    Exit;
  if Copy(Value, 1, 2) = '~/' then
    Value := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + Copy(Value, 3, MaxInt);
  if not ((Value[1] = '/') or (Value[1] = '\') or
    ((Length(Value) > 1) and (Value[2] = ':'))) then
    Value := IncludeTrailingPathDelimiter(DataPath('..')) + Value;
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(Value));
end;

function SettingText(const Key: string): string;
var
  SettingsMap: TStringList;
begin
  SettingsMap := LoadSettingsMap;
  try
    Result := Trim(SettingsMap.Values[Key]);
  finally
    SettingsMap.Free;
  end;
end;

// GIT=: the git program (a name on the PATH or a path); '' finds one.
function GetGitSetting: string;
begin
  Result := SettingText('GIT');
  if (Result <> '') and ((Pos(PathDelim, Result) > 0) or (Pos(DriveSeparator, Result) > 0)) then
    Result := SettingPath('GIT', '');
end;

// The git program, its version and the fetch, as the start and Settings say.
function GitDescription: string;
var
  Git, Version, Mode: string;
begin
  Git := GwFindGit(GetGitSetting);
  Version := GwGitVersion(Git);
  try
    Mode := GwGitFetchMode(SettingText('GIT_FETCH'));
  except
    on E: Exception do
      Mode := E.Message;
  end;
  if Git = '' then
    Result := 'no git program'
  else if Version = '' then
    Result := Git + ' (does not run)'
  else
    Result := Git + ' (' + Version + ')';
  Result := Result + '; fetch: ' + Mode;
end;

// The choices of GIT_FETCH, the current one selected ('' is the default).
function GitFetchOptions(const Current: string): string;
const
  MODES: array[0..1] of string = ('pascal', 'program');
var
  I: Integer;
  Cur: string;
begin
  Result := '';
  try
    Cur := GwGitFetchMode(Current);
  except
    Cur := '';
  end;
  for I := 0 to High(MODES) do
    Result := Result + '<option value="' + MODES[I] + '"' + ifthen(MODES[I] = Cur, ' selected', '') + '>' +
      MODES[I] + '</option>';
end;

function GetGiteaAppIni: string;
begin
  Result := SettingPath('GITEA_APP_INI', '');
end;

function GetGiteaTree: string;
begin
  Result := SettingPath('GITEA_TREE', '');
end;

function GetGiteaIndexPath: string;
begin
  Result := SettingPath('GITEA_INDEX', 'gitea-index.txt');
end;

function GtSize(Value: Int64; Raw: Boolean): string;
begin
  if Raw then
    Result := IntToStr(Value)
  else
    Result := FormatByteSize(Value);
end;

function GtKindName(Kind: Integer): string;
begin
  if Kind = 1 then
    Result := 'organization'
  else
    Result := 'user';
end;

// ./public/server gitea <command> [options]: the same reading as the Gitea
// pages, for scripts and terminals. Read-only; cli/omigitea.py writes.
function GiteaCli: Integer;
var
  I, K, Limit: Integer;
  Cmd, AppIni, Tree, IndexPath, SortKey, OwnerFilter, E: string;
  Raw, Rescan: Boolean;
  P: TGtPaths;
  R: TGtReport;
  Files: Int64;
  Rows: TGtRows;

  procedure Usage;
  begin
    WriteLn('Usage: server gitea <command> [--config app.ini] [--index file] [--tree file]');
    WriteLn('                    [--sort name|total|git|lfs|attachments|packages|repos|db|issues]');
    WriteLn('                    [--owner NAME] [--limit N] [--bytes] [--rescan]');
    WriteLn('Commands: paths, index, owners, sizes, orphans, version');
  end;

begin
  Result := 2;
  Cmd := ParamStr(2);
  AppIni := GetGiteaAppIni;
  Tree := GetGiteaTree;
  IndexPath := GetGiteaIndexPath;
  SortKey := 'total';
  OwnerFilter := '';
  Limit := 0;
  Raw := False;
  Rescan := False;
  I := 3;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '--config') and (I < ParamCount) then
    begin
      AppIni := ExpandFileName(ParamStr(I + 1));
      Inc(I);
    end
    else if (ParamStr(I) = '--index') and (I < ParamCount) then
    begin
      IndexPath := ExpandFileName(ParamStr(I + 1));
      Inc(I);
    end
    else if (ParamStr(I) = '--tree') and (I < ParamCount) then
    begin
      Tree := ExpandFileName(ParamStr(I + 1));
      Inc(I);
    end
    else if (ParamStr(I) = '--sort') and (I < ParamCount) then
    begin
      SortKey := ParamStr(I + 1);
      Inc(I);
    end
    else if (ParamStr(I) = '--owner') and (I < ParamCount) then
    begin
      OwnerFilter := ParamStr(I + 1);
      Inc(I);
    end
    else if (ParamStr(I) = '--limit') and (I < ParamCount) then
    begin
      Limit := StrToIntDef(ParamStr(I + 1), 0);
      Inc(I);
    end
    else if ParamStr(I) = '--bytes' then
      Raw := True
    else if ParamStr(I) = '--rescan' then
      Rescan := True
    else
    begin
      WriteLn(StdErr, 'Unknown option: ', ParamStr(I));
      Usage;
      Exit;
    end;
    Inc(I);
  end;
  if (Cmd = '') or (Cmd = 'help') or (Cmd = '--help') then
  begin
    Usage;
    Exit(0);
  end;
  if AppIni = '' then
  begin
    WriteLn(StdErr, 'No Gitea app.ini: set GITEA_APP_INI in settings.ini or give --config.');
    Exit(1);
  end;
  if not GtResolvePaths(AppIni, P, E) then
  begin
    WriteLn(StdErr, 'Cannot read ', AppIni, ': ', E);
    Exit(1);
  end;
  if Cmd = 'paths' then
  begin
    WriteLn('app.ini'#9, P.AppIni);
    WriteLn('WORK_PATH'#9, P.WorkPath);
    WriteLn('APP_DATA_PATH'#9, P.AppDataPath);
    WriteLn('database'#9, P.DbType, ' ', P.DbPath);
    WriteLn('repositories'#9, P.RepoRoot);
    WriteLn('attachments'#9, P.Attachments);
    WriteLn('lfs'#9, P.Lfs);
    WriteLn('packages'#9, P.Packages);
    WriteLn('avatars'#9, P.Avatars);
    WriteLn('repo-avatars'#9, P.RepoAvatars);
    WriteLn('actions_log'#9, P.ActionsLog);
    WriteLn('actions_artifacts'#9, P.ActionsArtifacts);
    WriteLn('repo-archive'#9, P.RepoArchive);
    WriteLn('http'#9, P.HttpAddr, ':', P.HttpPort);
    if P.NonLocal <> '' then
      WriteLn('not local'#9, P.NonLocal);
    Exit(0);
  end;
  if P.DbType <> 'sqlite3' then
  begin
    WriteLn(StdErr, 'Omi reads Gitea''s SQLite database; this Gitea uses ', P.DbType, '.');
    Exit(1);
  end;
  if Cmd = 'version' then
  begin
    if not GtQuery(P.DbPath, 'SELECT version FROM version', [], Rows, E) or (Length(Rows) = 0) then
    begin
      WriteLn(StdErr, E);
      Exit(1);
    end;
    WriteLn('migration'#9, Rows[0][0]);
    Exit(0);
  end;
  // An index of another Gitea folder (another --config) is measured again,
  // not read against this one's database.
  if FileExists(IndexPath) and (GtIndexAppIni(IndexPath) <> P.AppIni) then
    Rescan := True;
  if (Cmd = 'index') or Rescan or not FileExists(IndexPath) then
  begin
    if not GtBuildIndex(P, Tree, IndexPath, Files, E) then
    begin
      WriteLn(StdErr, 'Cannot index: ', E);
      Exit(1);
    end;
    if Cmd = 'index' then
    begin
      WriteLn('indexed'#9, Files, ' files'#9, IndexPath);
      Exit(0);
    end;
  end;
  if not GtLoadReport(P, IndexPath, R, E) then
  begin
    WriteLn(StdErr, 'Cannot read: ', E);
    GtFreeReport(R);
    Exit(1);
  end;
  try
    if Cmd = 'owners' then
    begin
      GtSortOwners(R, SortKey);
      WriteLn('owner'#9'type'#9'repos'#9'git'#9'wiki'#9'lfs'#9'attachments'#9'packages'#9'avatar'#9'total'#9'db size'#9'mismatches');
      for K := 0 to High(R.Owners) do
      begin
        if (Limit > 0) and (K >= Limit) then
          Break;
        with R.Owners[K] do
          WriteLn(Name, #9, GtKindName(Kind), #9, Repos, #9, GtSize(Git, Raw), #9, GtSize(Wiki, Raw), #9,
            GtSize(Lfs, Raw), #9, GtSize(Attachments, Raw), #9, GtSize(Packages, Raw), #9,
            GtSize(Avatar, Raw), #9, GtSize(Total, Raw), #9, GtSize(DbSize, Raw), #9, Mismatches);
      end;
      WriteLn('# index ', R.IndexTime, ' ', R.IndexSource);
      WriteLn('# total git ', GtSize(R.TotalGit, Raw), ', wiki ', GtSize(R.TotalWiki, Raw), ', lfs ',
        GtSize(R.TotalLfs, Raw), ', attachments ', GtSize(R.TotalAttachments, Raw), ', packages ',
        GtSize(R.TotalPackages, Raw), ', avatars ', GtSize(R.TotalAvatars + R.TotalRepoAvatars, Raw),
        ', actions ', GtSize(R.TotalActionsLog + R.TotalArtifacts, Raw), ', archives ',
        GtSize(R.TotalArchives, Raw), ', other ', GtSize(R.TotalOther, Raw), ', orphans ',
        R.Orphans.Count, ' (', GtSize(R.TotalOrphanBytes, Raw), ')');
      Exit(0);
    end;
    if Cmd = 'sizes' then
    begin
      GtSortRepos(R.Repos, SortKey);
      WriteLn('repository'#9'git'#9'wiki'#9'lfs'#9'attachments'#9'total'#9'db size'#9'db git_size'#9'db lfs_size'#9'issues'#9'pulls'#9'mismatch');
      K := 0;
      for I := 0 to High(R.Repos) do
        with R.Repos[I] do
        begin
          if (OwnerFilter <> '') and not SameText(Owner, OwnerFilter) then
            Continue;
          if (Limit > 0) and (K >= Limit) then
            Break;
          Inc(K);
          WriteLn(Owner, '/', Name, #9, GtSize(DiskGit, Raw), #9, GtSize(DiskWiki, Raw), #9,
            GtSize(LfsDisk, Raw), #9, GtSize(AttDisk, Raw), #9, GtSize(Total, Raw), #9,
            GtSize(DbSize, Raw), #9, GtSize(DbGit, Raw), #9, GtSize(DbLfs, Raw), #9, Issues, #9, Pulls,
            #9, Mismatch);
        end;
      Exit(0);
    end;
    if Cmd = 'orphans' then
    begin
      WriteLn('kind'#9'path'#9'bytes'#9'reason');
      for I := 0 to R.Orphans.Count - 1 do
      begin
        if (Limit > 0) and (I >= Limit) then
          Break;
        WriteLn(R.Orphans[I]);
      end;
      WriteLn('# ', R.Orphans.Count, ' orphans, ', GtSize(R.TotalOrphanBytes, Raw));
      Exit(0);
    end;
    WriteLn(StdErr, 'Unknown command: ', Cmd);
    Usage;
  finally
    GtFreeReport(R);
  end;
end;

{ --- Gitea folder: the writes, in Omi itself (public/omigiteaw.pas) ------------ }

function GetGiteaJobsDir: string;
begin
  Result := SettingPath('GITEA_JOBS_DIR', 'gitea-jobs');
end;

function GetGithubTokenFile: string;
begin
  Result := SettingPath('GITHUB_TOKEN_FILE', 'settings/github-token.ini');
end;

// GitHub's API: OMI_GITHUB_API for the tests' fake GitHub, else GitHub's own.
function GetGithubApi: string;
begin
  Result := GetEnvironmentVariable('OMI_GITHUB_API');
  if Result = '' then
    Result := 'https://api.github.com';
end;

// The repositories no longer synced: one list shared with github-to-gitea,
// github-to-gitea.exclude.txt beside its .ini.
function GetSyncExcludeFile: string;
begin
  Result := SettingPath('SYNC_EXCLUDE_FILE', IncludeTrailingPathDelimiter(
    SettingPath('GITHUB_TO_GITEA_DIR', '../gitea-patches/mirror')) + 'github-to-gitea/github-to-gitea.exclude.txt');
end;

// A job name: letters, digits, '-', '_' and '.', ending in .log.
function GiteaJobNameIsSafe(const Name: string): Boolean;
var
  I: Integer;
begin
  Result := (Length(Name) > 4) and (Length(Name) < 200) and (Copy(Name, Length(Name) - 3, 4) = '.log') and
    (Name[1] <> '.');
  if Result then
    for I := 1 to Length(Name) do
      if not (Name[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.']) then
        Exit(False);
end;

// A job's Stop: <jobs>/<name>.stop beside its log (omigiteaw.pas GwStopFile).
function GiteaJobStopPath(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetGiteaJobsDir) + Copy(Name, 1, Length(Name) - 4) + '.stop';
end;

// Only an import can be stopped: it reads GitHub, and checks for a stop before
// every request. A delete is one short write.
function GiteaJobCanStop(const Name: string): Boolean;
begin
  Result := Pos('-import-', Name) > 0;
end;

// Importing from GitHub into the stopped Gitea, in Omi itself.
function GiteaRunImport(const P: TGtPaths; const Owner, Repos: string; Say: TGwSay): Integer;
var
  J: TJSONObject;
  SettingsMap: TStringList;
  Doer: string;
begin
  SettingsMap := LoadSettingsMap;
  try
    Doer := Trim(SettingsMap.Values['GITEA_DOER']);
  finally
    SettingsMap.Free;
  end;
  J := GwImportFull(P, Owner, Repos, GetGithubTokenFile, GetGithubApi, 'https://github.com', '',
    'https://user-images.githubusercontent.com', Doer, SettingPath('GITEA_BINARY', ''), GetSyncExcludeFile,
    SettingPath('GITEA_PID_FILE', ''), GetGitSetting, SettingText('GIT_FETCH'), Say);
  try
    Say(J.FormatJSON);
  finally
    J.Free;
  end;
  Result := 0;
end;

type
  // A write running in the background, in this process: its log is
  // <jobs>/<name>.log, ending with "exit <code>".
  // Where there are no threads it is a plain object, run inside the request.
  TGiteaJob = class({$IFDEF OMI_NO_THREADS}TObject{$ELSE}TThread{$ENDIF})
  private
    FLog: TFileStream;
  public
    P: TGtPaths;
    Kind, Owner, Repo, Confirm, By, LogPath: string;
    ExcludeSync: Boolean;
    procedure Say(const Line: string);
    procedure Execute; {$IFNDEF OMI_NO_THREADS}override;{$ENDIF}
  end;

procedure TGiteaJob.Say(const Line: string);
var
  S: string;
begin
  S := Line + #10;
  FLog.WriteBuffer(S[1], Length(S));
end;

procedure TGiteaJob.Execute;
var
  J: TJSONObject;
  Code: Integer;
begin
  Code := 1;
  try
    FLog := TFileStream.Create(LogPath, fmCreate or fmShareDenyNone);
  except
    Exit;
  end;
  GwStopFile := ChangeFileExt(LogPath, '.stop');
  try
    try
      if Kind = 'delete' then
      begin
        J := GwDelete(P, Owner, Repo, Confirm, SettingPath('GITEA_PID_FILE', ''), GetSyncExcludeFile, By,
          GetGiteaIndexPath, ExcludeSync, @Say);
        Say(J.FormatJSON);
        J.Free;
        Code := 0;
      end
      else if Kind = 'import' then
        Code := GiteaRunImport(P, Owner, Repo, @Say);
    except
      on E: Exception do
        Say('omi: ' + E.Message);
    end;
    Say('exit ' + IntToStr(Code));
  finally
    FLog.Free;
    if FileExists(GwStopFile) then
      DeleteFile(GwStopFile);
    GwStopFile := '';
  end;
end;

// Starts a write as a job; JobName is its log's name.
function GiteaStartJob(const Kind, Owner, Repo, Confirm, By: string; ExcludeSync: Boolean;
  out JobName, ErrorText: string): Boolean;
var
  Job: TGiteaJob;
  Dir, Who: string;
begin
  Result := False;
  ErrorText := '';
  Dir := GetGiteaJobsDir;
  if not GtForceDirs(Dir) then
  begin
    ErrorText := 'cannot make ' + Dir;
    Exit;
  end;
  Who := Owner;
  if Repo <> '' then
    Who := Owner + '-' + Repo;
  JobName := FormatDateTime('yyyy-mm-dd_hh-nn-ss', Now) + '-' + Kind + '-' + Who + '.log';
  {$IFDEF OMI_NO_THREADS}
  Job := TGiteaJob.Create;
  {$ELSE}
  Job := TGiteaJob.Create(True);
  Job.FreeOnTerminate := True;
  {$ENDIF}
  if not GtResolvePaths(GetGiteaAppIni, Job.P, ErrorText) then
  begin
    Job.Free;
    Exit;
  end;
  Job.Kind := Kind;
  Job.Owner := Owner;
  Job.Repo := Repo;
  Job.Confirm := Confirm;
  Job.By := By;
  Job.ExcludeSync := ExcludeSync;
  Job.LogPath := IncludeTrailingPathDelimiter(Dir) + JobName;
  // The log exists before the page that shows it.
  with TFileStream.Create(Job.LogPath, fmCreate) do
    Free;
  {$IFDEF OMI_NO_THREADS}
  try
    Job.Execute;
  finally
    Job.Free;
  end;
  {$ELSE}
  Job.Start;
  {$ENDIF}
  Result := True;
end;

// A dry run: the plan, and whether Gitea runs.
function GiteaPlan(const Owner, Repo: string; out Json: TJSONObject; out ErrorText: string): Boolean;
var
  P: TGtPaths;
  L: TStringList;
  A: TJSONArray;
  I: Integer;
begin
  Json := nil;
  Result := False;
  if not GtResolvePaths(GetGiteaAppIni, P, ErrorText) then
    Exit;
  try
    Json := GwPlanDelete(P, Owner, Repo);
    L := GwRunning(P, SettingPath('GITEA_PID_FILE', ''));
    try
      A := TJSONArray.Create;
      for I := 0 to L.Count - 1 do
        A.Add(L[I]);
      Json.Add('running', A);
    finally
      L.Free;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      ErrorText := E.Message;
      FreeAndNil(Json);
    end;
  end;
end;

// ./public/server gitea delete-repo|delete-owner|exclude|status ...: the writes,
// in Omi itself (public/omigiteaw.pas). Gitea must be stopped.
type
  TGiteaCliSay = class
    procedure Say(const Line: string);
  end;

procedure TGiteaCliSay.Say(const Line: string);
begin
  WriteLn(StdErr, Line);
end;

function GiteaWriteCli: Integer;
var
  Cmd, AppIni, Owner, Repo, Confirm, PidFile, ExcludeFile, IndexPath, By, AddName, RemoveName, A, E: string;
  TokenFile, GhApi, GhWeb, Doer, AppPath, Repos, GitProgram, FetchMode, StopFile: string;
  TokLogin, TokRemaining, TokLimit, TokDetail, TokOutcome: string;
  DryRun, AsJson, ExcludeSync, HaveAdd, HaveRemove: Boolean;
  I: Integer;
  P: TGtPaths;
  J: TJSONObject;
  L: TStringList;
  Arr: TJSONArray;
  SayObj: TGiteaCliSay;
  N64: Int64;
  IsNewRepo: Boolean;
  Repo_: TGitRepo;

  function Value: string;
  begin
    if Pos('=', A) > 0 then
      Result := Copy(A, Pos('=', A) + 1, MaxInt)
    else
    begin
      Inc(I);
      Result := ParamStr(I);
    end;
  end;

  function Opt(const Name: string): Boolean;
  begin
    Result := (A = Name) or (Copy(A, 1, Length(Name) + 1) = Name + '=');
  end;

  procedure Fail(const Msg: string);
  begin
    WriteLn(StdErr, 'omi: ', Msg);
    if AsJson then
    begin
      // FreeAndNil, not Free: the caller's `finally J.Free` runs after this,
      // and a freed J there was a second free - every failed import ended in
      // "EBusError: Bus error" (exit 217) instead of its own message.
      FreeAndNil(J);
      J := TJSONObject.Create(['error', Msg]);
      WriteLn(J.FormatJSON);
      FreeAndNil(J);
    end;
  end;

begin
  Result := 1;
  J := nil;
  Cmd := ParamStr(2);
  if (Cmd = 'git-fetch') or (Cmd = 'git-index-pack') or (Cmd = 'git-refs') then
  begin
    AsJson := True;
    // git in Pascal, by itself: fetching a repository over smart HTTP into a
    // bare one (OMI_GIT_DIR, made when it is not there, from OMI_GIT_URL), or
    // indexing a pack.
    J := TJSONObject.Create;
    try
      try
        if Cmd = 'git-index-pack' then
        begin
          A := GitIndexPack(ExpandFileName(ParamStr(3)), N64);
          J.Add('pack', A);
          J.Add('objects', N64);
        end
        else if Cmd = 'git-refs' then
        begin
          // Every ref as git in Pascal reads it: its value, the commit it
          // peels to, that commit's time, subject and count.
          A := ParamStr(3);
          if A = '' then
            A := GetEnvironmentVariable('OMI_GIT_DIR');
          Repo_ := TGitRepo.Open(A);
          L := Repo_.Refs;
          try
            Arr := TJSONArray.Create;
            for I := 0 to L.Count - 1 do
            begin
              A := Repo_.PeelToCommit(L.ValueFromIndex[I]);
              if not Repo_.CommitInfo(A, N64, E) then
              begin
                N64 := 0;
                E := '';
              end;
              Arr.Add(TJSONObject.Create(['ref', L.Names[I], 'sha', L.ValueFromIndex[I], 'commit', A,
                'time', N64, 'subject', E, 'count', Repo_.CountCommits(A), 'target',
                Repo_.TagTarget(L.ValueFromIndex[I])]));
            end;
            J.Add('refs', Arr);
          finally
            L.Free;
            Repo_.Free;
          end;
        end
        else
        begin
          A := GetEnvironmentVariable('OMI_GIT_DIR');
          if A = '' then
            raise EGit.Create('set OMI_GIT_DIR to the bare repository');
          IsNewRepo := not DirectoryExists(A);
          if IsNewRepo then
            GitInitBare(A);
          Repo_ := TGitRepo.Open(A);
          try
            N64 := GitFetch(Repo_, GetEnvironmentVariable('OMI_GIT_URL'), '', IsNewRepo, nil);
            Repo_.UpdateServerInfo;
            J.Add('objects', N64);
          finally
            Repo_.Free;
          end;
        end;
        Result := 0;
      except
        on Ex: Exception do
        begin
          J.Add('error', Ex.Message);
          WriteLn(StdErr, 'omi: ', Ex.Message);
        end;
      end;
      WriteLn(J.FormatJSON);
    finally
      J.Free;
    end;
    Exit;
  end;
  AppIni := GetGiteaAppIni;
  Owner := '';
  Repo := '';
  Confirm := '';
  PidFile := SettingPath('GITEA_PID_FILE', '');
  ExcludeFile := GetSyncExcludeFile;
  IndexPath := '';
  By := GetEnvironmentVariable('USER');
  DryRun := False;
  AsJson := False;
  ExcludeSync := False;
  HaveAdd := False;
  HaveRemove := False;
  TokenFile := GetGithubTokenFile;
  GhApi := GetGithubApi;
  GhWeb := 'https://github.com';
  StopFile := '';
  Doer := '';
  AppPath := SettingPath('GITEA_BINARY', '');
  GitProgram := GetGitSetting;
  FetchMode := SettingText('GIT_FETCH');
  Repos := '';
  I := 3;
  while I <= ParamCount do
  begin
    A := ParamStr(I);
    if Opt('--config') then AppIni := ExpandFileName(Value)
    else if Opt('--owner') then Owner := Value
    else if Opt('--repo') then
    begin
      Repo := Value;
      Repos := Repos + ' ' + Repo;
    end
    else if Opt('--token-file') then TokenFile := ExpandFileName(Value)
    else if Opt('--github-api') then GhApi := Value
    else if Opt('--github-web') then GhWeb := Value
    else if Opt('--stop-file') then StopFile := ExpandFileName(Value)
    else if Opt('--doer') then Doer := Value
    else if Opt('--gitea-binary') then AppPath := Value
    else if Opt('--git-fetch') then FetchMode := Value
    else if Opt('--git') then GitProgram := Value
    else if Opt('--confirm') then Confirm := Value
    else if Opt('--pid-file') then PidFile := Value
    else if Opt('--exclude-file') then ExcludeFile := ExpandFileName(Value)
    else if Opt('--index') then IndexPath := ExpandFileName(Value)
    else if Opt('--by') then By := Value
    else if Opt('--add') then begin AddName := Value; HaveAdd := True; end
    else if Opt('--remove') then begin RemoveName := Value; HaveRemove := True; end
    else if A = '--dry-run' then DryRun := True
    else if A = '--json' then AsJson := True
    else if A = '--exclude-from-sync' then ExcludeSync := True
    else
    begin
      Fail('unknown option: ' + A);
      Exit(2);
    end;
    Inc(I);
  end;
  if Cmd = 'test-token' then
  begin
    // What "Test the token" asks GitHub: GET /user with the token file's token.
    TokOutcome := GwTestGithubToken(TokenFile, GhApi, TokLogin, TokRemaining, TokLimit, TokDetail);
    J := TJSONObject.Create(['outcome', TokOutcome, 'login', TokLogin, 'remaining', TokRemaining, 'limit', TokLimit,
      'detail', TokDetail]);
    try
      if AsJson then
        WriteLn(J.FormatJSON)
      else
        WriteLn(TokOutcome, ' ', TokLogin, ' ', TokRemaining, '/', TokLimit, ' ', TokDetail);
    finally
      J.Free;
    end;
    if TokOutcome = 'ok' then
      Result := 0
    else
      Result := 1;
    Exit;
  end;
  if Cmd = 'git' then
  begin
    // The git program and the fetch the import would use.
    A := GwFindGit(GitProgram);
    J := TJSONObject.Create(['git', A, 'version', GwGitVersion(A)]);
    try
      try
        J.Add('fetch', GwGitFetchMode(FetchMode));
        Result := 0;
      except
        on Ex: Exception do
        begin
          J.Add('error', Ex.Message);
          WriteLn(StdErr, 'omi: ', Ex.Message);
        end;
      end;
      if AsJson then
        WriteLn(J.FormatJSON)
      else
        WriteLn('git: ', ifthen(A = '', '(none)', A), #10'version: ', J.Get('version', ''), #10'fetch: ',
          J.Get('fetch', ''));
    finally
      J.Free;
    end;
    Exit;
  end;
  if AppIni = '' then
  begin
    Fail('No Gitea app.ini: set GITEA_APP_INI in settings.ini or give --config.');
    Exit;
  end;
  if not GtResolvePaths(AppIni, P, E) then
  begin
    Fail('Cannot read ' + AppIni + ': ' + E);
    Exit;
  end;
  SayObj := TGiteaCliSay.Create;
  J := nil;
  try
    try
      if Cmd = 'status' then
      begin
        L := GwRunning(P, PidFile);
        try
          J := TJSONObject.Create;
          J.Add('running', L.Count > 0);
          Arr := TJSONArray.Create;
          for I := 0 to L.Count - 1 do
            Arr.Add(L[I]);
          J.Add('reasons', Arr);
          if not AsJson then
            if L.Count > 0 then
              WriteLn('Gitea is running: ', StringReplace(Trim(L.Text), LineEnding, '; ', [rfReplaceAll]))
            else
              WriteLn('Gitea is stopped.');
        finally
          L.Free;
        end;
      end
      else if Cmd = 'exclude' then
      begin
        if HaveAdd then
          GwExcludeAdd(ExcludeFile, AddName);
        if HaveRemove then
          GwExcludeRemove(ExcludeFile, RemoveName);
        L := GwExcludeList(ExcludeFile);
        try
          J := TJSONObject.Create;
          Arr := TJSONArray.Create;
          for I := 0 to L.Count - 1 do
            Arr.Add(L[I]);
          J.Add('excluded', Arr);
          if not AsJson then
            Write(L.Text);
        finally
          L.Free;
        end;
      end
      else if Cmd = 'import' then
      begin
        if Owner = '' then
          raise EGw.Create('--owner is required');
        // --stop-file: stops like the job page's Stop (GwStopFile).
        GwStopFile := StopFile;
        J := GwImportFull(P, Owner, Trim(Repos), TokenFile, GhApi, GhWeb, GetEnvironmentVariable('OMI_GITHUB_GIT_ROOT'),
          ifthen(GetEnvironmentVariable('OMI_GITHUB_FILE_HOSTS') <> '', GetEnvironmentVariable('OMI_GITHUB_FILE_HOSTS'),
          ifthen(GetEnvironmentVariable('OMI_GITHUB_NO_FILE_HOSTS') = '1', '',
          'https://user-images.githubusercontent.com')), Doer, AppPath, ExcludeFile, PidFile, GitProgram, FetchMode,
          @SayObj.Say);
      end
      else if (Cmd = 'delete-repo') or (Cmd = 'delete-owner') or (Cmd = 'delete') then
      begin
        if Owner = '' then
          raise EGw.Create('--owner is required');
        if (Cmd = 'delete-repo') and (Repo = '') then
          raise EGw.Create('--repo is required');
        if Cmd <> 'delete-repo' then
          Repo := '';
        if DryRun then
        begin
          J := GwPlanDelete(P, Owner, Repo);
          L := GwRunning(P, PidFile);
          try
            Arr := TJSONArray.Create;
            for I := 0 to L.Count - 1 do
              Arr.Add(L[I]);
            J.Add('running', Arr);
          finally
            L.Free;
          end;
          if Repo <> '' then
            J.Add('excluded', GwIsExcluded(ExcludeFile, J.Get('owner', '') + '/' + J.Get('repository', '')));
          if not AsJson then
          begin
            WriteLn(J.Get('owner', ''), ifthen(Repo <> '', '/' + J.Get('repository', ''), ''), ': ',
              J.Get('rows', Int64(0)), ' rows, ', J.Get('files', Int64(0)), ' files, ',
              J.Get('bytes', Int64(0)), ' bytes');
            for I := 0 to TJSONObject(J.Find('tables')).Count - 1 do
              WriteLn('  ', TJSONObject(J.Find('tables')).Names[I], #9,
                TJSONObject(J.Find('tables')).Items[I].AsString);
            for I := 0 to TJSONArray(J.Find('running')).Count - 1 do
              WriteLn('  refused: ', TJSONArray(J.Find('running')).Strings[I]);
          end;
        end
        else
          J := GwDelete(P, Owner, Repo, Confirm, PidFile, ExcludeFile, By, IndexPath, ExcludeSync, @SayObj.Say);
      end
      else
      begin
        Fail('unknown command: ' + Cmd);
        Exit(2);
      end;
      if AsJson and Assigned(J) then
        WriteLn(J.FormatJSON);
      Result := 0;
    except
      on Ex: Exception do
        Fail(Ex.Message);
    end;
  finally
    J.Free;
    SayObj.Free;
  end;
end;

{ --- Gitea folder pages ---------------------------------------------------------- }

const
  GITEA_PAGE_SIZE = 500;

procedure GiteaEndpoint(ARequest: TRequest; AResponse: TResponse);
var
  Username, SessionId, PostedAction, UserLang, Op, SortKey: string;
  UsersMap: TStringList;
  StoredPassword, StoredOtp, StoredLanguage: string;
  Translations, LangData: TJSONObject;
  IsRtl: Boolean;
  RawParts: TStringArray;
  Segs: array of string;
  I: Integer;
  Msg, Err, AppIni: string;
  P: TGtPaths;
  Owner, RepoName: string;
  OwnerId, RepoId: string;
  Ok_: Boolean;
  Excluded: TStringList;

  function Tx(const Key: string): string;
  begin
    Result := T(Key, Translations);
  end;

  function TxE(const Key: string): string;
  begin
    Result := HtmlEncode(T(Key, Translations));
  end;

  function Nav(const Path, LabelText, Fields: string): string;
  begin
    Result := BkButton(ARequest, Path, 'gitea-nav', LabelText, Fields);
  end;

  function Q(const Sql: string; const Params: array of string; out Rows: TGtRows; MaxRows: Integer = 0): Boolean;
  var
    E: string;
  begin
    Result := GtQuery(P.DbPath, Sql, Params, Rows, E, MaxRows);
    if not Result then
      Err := Tx('error') + ': ' + E;
  end;

  function Crumbs(const Items: array of string): string;
  var
    K: Integer;
  begin
    Result := '<p>';
    for K := Low(Items) to High(Items) do
    begin
      if K > Low(Items) then
        Result := Result + ' &gt; ';
      Result := Result + Items[K];
    end;
    Result := Result + '</p>';
  end;

  function Home: string;
  begin
    Result := Nav('/gitea', Tx('gitea'), '');
  end;

  function OwnerPath(const AOwner: string): string;
  begin
    Result := '/gitea/o/' + BkUrlPart(AOwner);
  end;

  function RepoPath(const AOwner, ARepo: string): string;
  begin
    Result := OwnerPath(AOwner) + '/' + BkUrlPart(ARepo);
  end;

  function Messages: string;
  begin
    Result := '';
    if Msg <> '' then
      Result := Result + '<p><font color="green"><strong>' + HtmlEncode(Msg) + '</strong></font></p>';
    if Err <> '' then
      Result := Result + '<p><font color="red"><strong>' + HtmlEncode(Err) + '</strong></font></p>';
  end;

  procedure Send(const Title, CrumbHtml, Body: string);
  var
    Html, LangAttr, DirAttr: string;
  begin
    LangAttr := StringReplace(StringReplace(UserLang, '_', '-', [rfReplaceAll]), '@', '-', [rfReplaceAll]);
    if IsRtl then
      DirAttr := 'rtl'
    else
      DirAttr := 'ltr';
    Html := '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" ' +
      '"http://www.w3.org/TR/html4/loose.dtd">' + LineEnding +
      '<html lang="' + HtmlEncode(LangAttr) + '" dir="' + DirAttr + '"><head>' +
      '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">' +
      '<meta name="viewport" content="width=device-width, initial-scale=1">' +
      '<title>' + HtmlEncode(Title) + ' - Omi Server</title></head>' + LineEnding +
      '<body bgcolor="#f0f0f0" dir="' + DirAttr + '">' + LineEnding +
      '<table width="100%" border="0" cellpadding="5"><tr><td><h1>' +
      HtmlEncode(Title) + '</h1></td></tr></table>' + LineEnding +
      BuildNavRow([
        BuildActionButton(ARequest, '/', 'nav-home', Tx('home')),
        BuildActionButton(ARequest, '/language', 'nav-language', Tx('language')),
        BuildActionButton(ARequest, '/settings', 'nav-settings', Tx('settings')),
        BuildActionButton(ARequest, '/people', 'nav-people', Tx('people')),
        BuildActionButton(ARequest, '/activity', 'nav-activity', Tx('activity')),
        BuildActionButton(ARequest, '/backups', 'nav-backups', Tx('backups')),
        BuildActionButton(ARequest, '/gitea', 'nav-gitea', Tx('gitea')),
        '<strong>' + HtmlEncode(Username) + '</strong>',
        BuildActionButton(ARequest, '/logout', 'nav-logout', Tx('logout'))
      ]) + LineEnding + CrumbHtml + LineEnding + '<hr>' + LineEnding +
      Messages + Body + LineEnding + '<hr><p><small>Omi Server</small></p></body></html>' + LineEnding;
    AResponse.ContentType := 'text/html; charset=UTF-8';
    AResponse.CustomHeaders.Values['X-Content-Type-Options'] := 'nosniff';
    AResponse.CustomHeaders.Values['Content-Security-Policy'] :=
      'default-src ''none''; img-src data:; style-src ''unsafe-inline''; ' +
      'form-action ''self''; frame-ancestors ''none''';
    AResponse.CustomHeaders.Values['Referrer-Policy'] := 'no-referrer';
    AResponse.CustomHeaders.Values['Cache-Control'] := 'no-store';
    AResponse.Content := Html;
  end;

  procedure NotFound(const Detail: string);
  begin
    AResponse.Code := 404;
    Err := '';
    Send(Tx('gitea'), Crumbs([Home]), '<p><font color="red"><strong>' + TxE('not-found') +
      '</strong></font> ' + HtmlEncode(Detail) + '</p>');
  end;

  function Sz(Value: Int64): string;
  begin
    Result := HtmlEncode(FormatByteSize(Value));
  end;

  function Cell(const Html: string): string;
  begin
    Result := '<td>' + Html + '</td>';
  end;

  function NumCell(const Html: string): string;
  begin
    Result := '<td align="right">' + Html + '</td>';
  end;

  // A column header that sorts by Key (largest first), or the current one.
  function SortHead(const Path, Key, LabelText, Fields: string): string;
  begin
    if SortKey = Key then
      Result := '<th align="left"><font color="white">' + HtmlEncode(LabelText) + ' &darr;</font></th>'
    else
      Result := '<th align="left">' + Nav(Path, LabelText, Fields + BuildHiddenInput('sort', Key)) + '</th>';
  end;

  function KindName(Kind: Integer): string;
  begin
    if Kind = 1 then
      Result := Tx('gitea-organization')
    else
      Result := Tx('gitea-user');
  end;

  function Offset: Integer;
  begin
    Result := Max(0, StrToIntDef(GetFormFieldValue(ARequest, 'offset'), 0));
  end;

  function PageButtons(const Path: string; AOffset, Shown: Integer; HasMore: Boolean;
    const Fields: string): string;
  begin
    Result := '';
    if AOffset > 0 then
      Result := Result + Nav(Path, '<<', Fields + BuildHiddenInput('offset',
        IntToStr(Max(0, AOffset - GITEA_PAGE_SIZE)))) + ' ';
    if HasMore then
      Result := Result + Nav(Path, '>>', Fields + BuildHiddenInput('offset', IntToStr(AOffset + Shown)));
    if Result <> '' then
      Result := '<p>' + Result + '</p>';
  end;

  function LoadReport(out R: TGtReport): Boolean;
  var
    E: string;
  begin
    Result := GtLoadReport(P, GetGiteaIndexPath, R, E);
    if not Result then
    begin
      if not FileExists(GetGiteaIndexPath) then
        Err := Tx('gitea-no-index')
      else
        Err := Tx('error') + ': ' + E;
    end;
  end;

  function IndexLine(const R: TGtReport): string;
  begin
    Result := '<p>' + TxE('gitea-index') + ': ' + HtmlEncode(R.IndexTime) + ' (' +
      HtmlEncode(R.IndexSource) + ') ' + BkButton(ARequest, '/gitea', 'gitea-rescan', Tx('gitea-rescan'),
      BuildHiddenInput('op', 'rescan')) + '</p>';
    if R.IndexStale <> '' then
      Result := Result + '<p><font color="#a00000">' + TxE('gitea-index-stale') + ' (' +
        HtmlEncode(R.IndexStale) + ')</font></p>';
  end;

  // The repositories no longer synced, lowercase owner/name; read once a request
  // with github-to-gitea's own rules (cli/omigitea.py exclude).
  function IsExcluded(const Full: string): Boolean;
  var
    L: TStringList;
    K: Integer;
  begin
    if Excluded = nil then
    begin
      Excluded := TStringList.Create;
      Excluded.Sorted := True;
      Excluded.Duplicates := dupIgnore;
      L := GwExcludeList(GetSyncExcludeFile);
      try
        for K := 0 to L.Count - 1 do
          Excluded.Add(LowerCase(L[K]));
      finally
        L.Free;
      end;
    end;
    Result := Excluded.IndexOf(LowerCase(Full)) >= 0;
  end;

  function NotSyncedMark: string;
  begin
    Result := '<font color="#a00000">' + TxE('list-sync-source-none') + '</font>';
  end;

  // What was deleted (<APP_DATA_PATH>/omi/deleted-repos.tsv, written by
  // cli/omigitea.py): owner/name, time, bytes freed, who, kind. Shown without
  // links: there is nothing left to open. OnlyOwner: that owner's repositories.
  function DeletedTable(const OnlyOwner: string): string;
  var
    Lines: TStringList;
    Parts: TStringArray;
    K, N: Integer;
    Path, Rows_: string;
  begin
    Result := '';
    Path := P.AppDataPath + '/omi/deleted-repos.tsv';
    if not FileExists(Path) then
      Exit;
    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(Path);
      Rows_ := '';
      N := 0;
      for K := Lines.Count - 1 downto 0 do
      begin
        Parts := Lines[K].Split([#9]);
        if Length(Parts) < 3 then
          Continue;
        if (OnlyOwner <> '') and not SameText(Copy(Parts[0], 1, Pos('/', Parts[0]) - 1), OnlyOwner) then
          Continue;
        Inc(N);
        if N > 2000 then
          Break;
        Rows_ := Rows_ + '<tr><td><s>' + HtmlEncode(Parts[0]) + '</s></td><td><font color="#a00000">' +
          TxE('gitea-deleted') + ' ' + HtmlEncode(Copy(Parts[1], 1, 10)) + ', ' +
          Sz(StrToInt64Def(Parts[2], 0)) + ' ' + TxE('gitea-freed') + '</font></td><td>' +
          HtmlEncode(ifthen(Length(Parts) > 3, Parts[3], '')) + '</td></tr>';
      end;
      if Rows_ <> '' then
        Result := '<h3>' + TxE('gitea-deleted-list') + '</h3><table border="1" cellpadding="4" cellspacing="0">' +
          BkHeaderRow([Tx('name'), Tx('status'), Tx('owner')]) + Rows_ + '</table>';
    finally
      Lines.Free;
    end;
  end;

  // The buttons of the pages that write (cli/omigitea.py).
  function GiteaWriteButtons: string;
  begin
    Result := ' ' + Nav('/gitea/import', Tx('gitea-import'), '') + ' ' + Nav('/gitea/jobs', Tx('gitea-jobs'), '');
  end;

  function GiteaOwnerButtons: string;
  begin
    Result := '<p>' + Nav('/gitea/import', Tx('gitea-update'), BuildHiddenInput('owner', Owner)) + ' ' +
      Nav(OwnerPath(Owner) + '/delete', Tx('gitea-delete'), '') + '</p>';
  end;

  procedure PageOverview;
  var
    Body, E: string;
    Rows: TGtRows;
    R: TGtReport;
    Files: Int64;
    Have: Boolean;

    function Count(const Table: string): string;
    var
      CRows: TGtRows;
      CE: string;
    begin
      if GtQuery(P.DbPath, 'SELECT COUNT(*) FROM "' + Table + '"', [], CRows, CE) and (Length(CRows) = 1) then
        Result := CRows[0][0]
      else
        Result := '-';
    end;

    function PathRow(const Name, Path: string): string;
    begin
      Result := '<tr><td>' + HtmlEncode(Name) + '</td><td><tt>' + HtmlEncode(Path) + '</tt></td><td>' +
        ifthen(DirectoryExists(Path) or FileExists(Path), TxE('yes'), TxE('no')) + '</td></tr>';
    end;

  begin
    if (Op = 'rescan') and (PostedAction = 'gitea-rescan') then
    begin
      if GtBuildIndex(P, GetGiteaTree, GetGiteaIndexPath, Files, E) then
      begin
        Msg := Tx('gitea-indexed') + ' ' + IntToStr(Files);
        LogActivity(Username, SessionId, 'gitea-rescan', 'ok', IntToStr(Files) + ' files', ARequest, 0);
      end
      else
        Err := Tx('error') + ': ' + E;
    end;
    Body := '<p>' + TxE('gitea-read-only') + '</p>' +
      '<table border="1" cellpadding="4" cellspacing="0">' + BkHeaderRow([Tx('name'), Tx('path'), '']) +
      PathRow('app.ini', P.AppIni) + PathRow('WORK_PATH', P.WorkPath) +
      PathRow('APP_DATA_PATH', P.AppDataPath) + PathRow('[database] PATH', P.DbPath) +
      PathRow('[repository] ROOT', P.RepoRoot) + PathRow(Tx('attachments'), P.Attachments) +
      PathRow(Tx('gitea-lfs'), P.Lfs) + PathRow(Tx('gitea-packages'), P.Packages) +
      PathRow(Tx('avatars'), P.Avatars) + PathRow(Tx('avatars') + ' (repo)', P.RepoAvatars) +
      PathRow('actions_log', P.ActionsLog) + PathRow('actions_artifacts', P.ActionsArtifacts) +
      PathRow('repo-archive', P.RepoArchive);
    if GetGiteaTree <> '' then
      Body := Body + PathRow(Tx('gitea-tree'), GetGiteaTree);
    Body := Body + '</table>';
    if P.NonLocal <> '' then
      Body := Body + '<p>' + TxE('gitea-not-local') + ' ' + HtmlEncode(P.NonLocal) + '</p>';
    if P.DbType <> 'sqlite3' then
    begin
      Err := Tx('gitea-not-sqlite') + ' ' + P.DbType;
      Send(Tx('gitea'), Crumbs(['<strong>' + TxE('gitea') + '</strong>']), Body);
      Exit;
    end;
    if GtQuery(P.DbPath, 'SELECT version FROM version', [], Rows, E) and (Length(Rows) > 0) then
      Body := Body + '<p>' + TxE('database-migration') + ': <b>' + HtmlEncode(Rows[0][0]) + '</b></p>'
    else
      Err := Tx('error') + ': ' + E;
    Body := Body + '<table border="1" cellpadding="4" cellspacing="0">' +
      BkHeaderRow([Tx('name'), Tx('stats-count')]) +
      '<tr><td>' + TxE('gitea-owners') + '</td><td align="right">' + Count('user') + '</td></tr>' +
      '<tr><td>' + TxE('repositories') + '</td><td align="right">' + Count('repository') + '</td></tr>' +
      '<tr><td>' + TxE('issues') + ' + ' + TxE('pull-requests') + '</td><td align="right">' + Count('issue') + '</td></tr>' +
      '<tr><td>' + TxE('comments') + '</td><td align="right">' + Count('comment') + '</td></tr>' +
      '<tr><td>' + TxE('releases') + '</td><td align="right">' + Count('release') + '</td></tr>' +
      '<tr><td>' + TxE('attachments') + '</td><td align="right">' + Count('attachment') + '</td></tr>' +
      '<tr><td>' + TxE('gitea-lfs-objects') + '</td><td align="right">' + Count('lfs_meta_object') + '</td></tr>' +
      '<tr><td>' + TxE('gitea-packages') + '</td><td align="right">' + Count('package') + '</td></tr>' +
      '</table>';
    Have := GtLoadReport(P, GetGiteaIndexPath, R, E);
    try
      if Have then
      begin
        Body := Body + IndexLine(R) +
          '<table border="1" cellpadding="4" cellspacing="0">' + BkHeaderRow([Tx('name'), Tx('size')]) +
          '<tr><td>' + 'Git' + '</td>' + NumCell(Sz(R.TotalGit)) + '</tr>' +
          '<tr><td>' + TxE('vcs-wiki') + '</td>' + NumCell(Sz(R.TotalWiki)) + '</tr>' +
          '<tr><td>' + TxE('gitea-lfs') + '</td>' + NumCell(Sz(R.TotalLfs)) + '</tr>' +
          '<tr><td>' + TxE('attachments') + '</td>' + NumCell(Sz(R.TotalAttachments)) + '</tr>' +
          '<tr><td>' + TxE('gitea-packages') + '</td>' + NumCell(Sz(R.TotalPackages)) + '</tr>' +
          '<tr><td>' + TxE('avatars') + '</td>' + NumCell(Sz(R.TotalAvatars + R.TotalRepoAvatars)) + '</tr>' +
          '<tr><td>' + TxE('gitea-actions') + '</td>' + NumCell(Sz(R.TotalActionsLog + R.TotalArtifacts)) + '</tr>' +
          '<tr><td>' + TxE('gitea-archives') + '</td>' + NumCell(Sz(R.TotalArchives)) + '</tr>' +
          '<tr><td>' + TxE('gitea-other') + '</td>' + NumCell(Sz(R.TotalOther)) + '</tr>' +
          '<tr><td><b>' + TxE('billing-total') + '</b></td>' + NumCell('<b>' + Sz(R.TotalGit + R.TotalWiki +
            R.TotalLfs + R.TotalAttachments + R.TotalPackages + R.TotalAvatars + R.TotalRepoAvatars +
            R.TotalActionsLog + R.TotalArtifacts + R.TotalArchives + R.TotalOther) + '</b>') + '</tr>' +
          '<tr><td>' + TxE('gitea-orphans') + '</td>' + NumCell(IntToStr(R.Orphans.Count) + ', ' +
            Sz(R.TotalOrphanBytes)) + '</tr></table>';
      end
      else
        Body := Body + '<p>' + TxE('gitea-no-index') + ' ' + BkButton(ARequest, '/gitea', 'gitea-rescan',
          Tx('gitea-rescan'), BuildHiddenInput('op', 'rescan')) + '</p>';
    finally
      GtFreeReport(R);
    end;
    Body := Body + '<p>' + Nav('/gitea/owners', Tx('gitea-sizes'), '') + ' ' +
      Nav('/gitea/repos', Tx('repositories'), '') + ' ' + Nav('/gitea/orphans', Tx('gitea-orphans'), '') +
      GiteaWriteButtons + '</p>';
    Send(Tx('gitea'), Crumbs(['<strong>' + TxE('gitea') + '</strong>']), Body);
  end;

  procedure PageOwners;
  var
    Body: string;
    R: TGtReport;
    K: Integer;
    Path: string;
  begin
    Path := '/gitea/owners';
    if SortKey = '' then
      SortKey := 'total';
    Body := '';
    if LoadReport(R) then
    begin
      GtSortOwners(R, SortKey);
      Body := IndexLine(R) + '<table border="1" width="100%" cellpadding="4" cellspacing="0"><tr bgcolor="#333333">' +
        SortHead(Path, 'name', Tx('owner'), '') + '<th align="left"><font color="white">' + TxE('type') + '</font></th>' +
        SortHead(Path, 'repos', Tx('repositories'), '') + SortHead(Path, 'git', 'Git', '') +
        SortHead(Path, 'lfs', Tx('gitea-lfs'), '') + SortHead(Path, 'attachments', Tx('attachments'), '') +
        SortHead(Path, 'packages', Tx('gitea-packages'), '') + SortHead(Path, 'total', Tx('billing-total'), '') +
        SortHead(Path, 'db', Tx('gitea-db-size'), '') +
        '<th align="left"><font color="white">' + TxE('gitea-mismatches') + '</font></th></tr>';
      for K := 0 to High(R.Owners) do
        with R.Owners[K] do
          Body := Body + '<tr>' + Cell(Nav(OwnerPath(Name), Name, '')) + Cell(HtmlEncode(KindName(Kind))) +
            NumCell(IntToStr(Repos)) + NumCell(Sz(Git + Wiki)) + NumCell(Sz(Lfs)) + NumCell(Sz(Attachments)) +
            NumCell(Sz(Packages)) + NumCell('<b>' + Sz(Total) + '</b>') + NumCell(Sz(DbSize)) +
            NumCell(ifthen(Mismatches > 0, '<font color="#a00000"><b>' + IntToStr(Mismatches) + '</b></font>', '0')) +
            '</tr>';
      Body := Body + '</table>';
    end;
    GtFreeReport(R);
    Body := Body + DeletedTable('');
    Send(Tx('gitea-sizes'), Crumbs([Home, '<strong>' + TxE('gitea-sizes') + '</strong>']), Body);
  end;

  // Repositories with their sizes: every one, or one owner's.
  function RepoTable(var R: TGtReport; const Path, OnlyOwnerId, Fields: string; AOffset: Integer;
    out Shown: Integer; out HasMore: Boolean): string;
  var
    K, N: Integer;
  begin
    GtSortRepos(R.Repos, SortKey);
    Result := '<table border="1" width="100%" cellpadding="4" cellspacing="0"><tr bgcolor="#333333">' +
      SortHead(Path, 'name', Tx('repository'), Fields) + SortHead(Path, 'git', 'Git', Fields) +
      '<th align="left"><font color="white">' + TxE('vcs-wiki') + '</font></th>' +
      SortHead(Path, 'lfs', Tx('gitea-lfs'), Fields) + SortHead(Path, 'attachments', Tx('attachments'), Fields) +
      SortHead(Path, 'total', Tx('billing-total'), Fields) + SortHead(Path, 'db', Tx('gitea-db-size'), Fields) +
      SortHead(Path, 'issues', Tx('issues') + ' / ' + Tx('pull-requests'), Fields) +
      '<th align="left"><font color="white">' + TxE('gitea-mismatch') + '</font></th>' +
      '<th align="left"><font color="white">' + TxE('list-sync-menu') + '</font></th>' +
      ifthen(OnlyOwnerId <> '', '<th></th>', '') + '</tr>';
    N := 0;
    Shown := 0;
    HasMore := False;
    for K := 0 to High(R.Repos) do
      with R.Repos[K] do
      begin
        if (OnlyOwnerId <> '') and (IntToStr(OwnerId) <> OnlyOwnerId) then
          Continue;
        Inc(N);
        if N <= AOffset then
          Continue;
        if Shown >= GITEA_PAGE_SIZE then
        begin
          HasMore := True;
          Break;
        end;
        Inc(Shown);
        Result := Result + '<tr>' + Cell(Nav(RepoPath(Owner, Name), Owner + '/' + Name, '')) +
          NumCell(Sz(DiskGit)) + NumCell(Sz(DiskWiki)) + NumCell(Sz(LfsDisk)) + NumCell(Sz(AttDisk)) +
          NumCell('<b>' + Sz(Total) + '</b>') + NumCell(Sz(DbSize)) +
          NumCell(IntToStr(Issues) + ' / ' + IntToStr(Pulls)) +
          Cell(ifthen(Mismatch <> '', '<font color="#a00000">' + HtmlEncode(Mismatch) + '</font>', '')) +
          Cell(ifthen(IsExcluded(Owner + '/' + Name), NotSyncedMark, '')) +
          ifthen(OnlyOwnerId <> '', Cell(Nav(RepoPath(Owner, Name) + '/delete', Tx('delete'), '')), '') + '</tr>';
      end;
    Result := Result + '</table>';
  end;

  procedure PageRepos;
  var
    Body: string;
    R: TGtReport;
    Shown: Integer;
    HasMore: Boolean;
  begin
    if SortKey = '' then
      SortKey := 'total';
    Body := '';
    if LoadReport(R) then
      Body := IndexLine(R) + RepoTable(R, '/gitea/repos', '', '', Offset, Shown, HasMore) +
        PageButtons('/gitea/repos', Offset, Shown, HasMore, BuildHiddenInput('sort', SortKey));
    GtFreeReport(R);
    Body := Body + DeletedTable('');
    Send(Tx('repositories'), Crumbs([Home, '<strong>' + TxE('repositories') + '</strong>']), Body);
  end;

  function FindOwner(const Name: string; out Kind, FullName: string): Boolean;
  var
    Rows: TGtRows;
  begin
    Result := Q('SELECT id, name, COALESCE(type, 0), COALESCE(full_name, '''') FROM user WHERE lower_name = ?1 ' +
      'AND COALESCE(type, 0) IN (0, 1)', [LowerCase(Name)], Rows) and (Length(Rows) = 1);
    if Result then
    begin
      OwnerId := Rows[0][0];
      Owner := Rows[0][1];
      Kind := Rows[0][2];
      FullName := Rows[0][3];
    end;
  end;

  procedure PageOwner;
  var
    Body, Kind, FullName, Path: string;
    R: TGtReport;
    Rows: TGtRows;
    K, Shown: Integer;
    HasMore: Boolean;
  begin
    if not FindOwner(Segs[2], Kind, FullName) then
    begin
      NotFound(Segs[2]);
      Exit;
    end;
    if SortKey = '' then
      SortKey := 'total';
    Path := OwnerPath(Owner);
    Body := '<h2>' + HtmlEncode(Owner) + '</h2><p>' + HtmlEncode(KindName(StrToIntDef(Kind, 0))) +
      ifthen(FullName <> '', ' - ' + HtmlEncode(FullName), '') + '</p>';
    if LoadReport(R) then
    begin
      for K := 0 to High(R.Owners) do
        if IntToStr(R.Owners[K].Id) = OwnerId then
          with R.Owners[K] do
            Body := Body + '<table border="1" cellpadding="4" cellspacing="0">' +
              BkHeaderRow(['Git', Tx('vcs-wiki'), Tx('gitea-lfs'), Tx('attachments'),
                Tx('gitea-packages'), Tx('avatars'), Tx('billing-total'), Tx('gitea-db-size')]) + '<tr>' +
              NumCell(Sz(Git)) + NumCell(Sz(Wiki)) + NumCell(Sz(Lfs)) + NumCell(Sz(Attachments)) +
              NumCell(Sz(Packages)) + NumCell(Sz(Avatar)) + NumCell('<b>' + Sz(Total) + '</b>') +
              NumCell(Sz(DbSize)) + '</tr></table>';
      Body := Body + IndexLine(R) + RepoTable(R, Path, OwnerId, '', Offset, Shown, HasMore) +
        PageButtons(Path, Offset, Shown, HasMore, BuildHiddenInput('sort', SortKey));
    end;
    GtFreeReport(R);
    // Packages of the owner.
    if Q('SELECT p.name, p.type, COUNT(DISTINCT pv.id), COALESCE(SUM(pb.size), 0) FROM package p ' +
      'LEFT JOIN package_version pv ON pv.package_id = p.id LEFT JOIN package_file pf ON pf.version_id = pv.id ' +
      'LEFT JOIN package_blob pb ON pb.id = pf.blob_id WHERE p.owner_id = ?1 GROUP BY p.id ORDER BY p.lower_name',
      [OwnerId], Rows) and (Length(Rows) > 0) then
    begin
      Body := Body + '<h3>' + TxE('gitea-packages') + '</h3><table border="1" cellpadding="4" cellspacing="0">' +
        BkHeaderRow([Tx('name'), Tx('type'), Tx('gitea-versions'), Tx('size')]);
      for K := 0 to High(Rows) do
        Body := Body + '<tr>' + Cell(HtmlEncode(Rows[K][0])) + Cell(HtmlEncode(Rows[K][1])) +
          NumCell(HtmlEncode(Rows[K][2])) + NumCell(Sz(StrToInt64Def(Rows[K][3], 0))) + '</tr>';
      Body := Body + '</table>';
    end;
    Body := Body + DeletedTable(Owner) + GiteaOwnerButtons;
    Send(Owner, Crumbs([Home, Nav('/gitea/owners', Tx('gitea-sizes'), ''), '<strong>' + HtmlEncode(Owner) +
      '</strong>']), Body);
  end;

  function FindRepo(const AOwner, ARepo: string): Boolean;
  var
    Rows: TGtRows;
    Kind, FullName: string;
  begin
    Result := FindOwner(AOwner, Kind, FullName) and
      Q('SELECT id, name FROM repository WHERE owner_id = ?1 AND lower_name = ?2', [OwnerId, LowerCase(ARepo)], Rows) and
      (Length(Rows) = 1);
    if Result then
    begin
      RepoId := Rows[0][0];
      RepoName := Rows[0][1];
    end;
  end;

  function RepoCrumbs(const Last: string): string;
  begin
    Result := Crumbs([Home, Nav(OwnerPath(Owner), Owner, ''), Nav(RepoPath(Owner, RepoName), RepoName, ''), Last]);
  end;

  function RepoTabs(const Tab: string): string;
    function TabItem(const Key, Name: string): string;
    begin
      if Tab = Name then
        Result := '<strong>' + TxE(Key) + '</strong>'
      else
        Result := Nav(RepoPath(Owner, RepoName) + '/' + Name, Tx(Key), '');
    end;
  begin
    Result := BuildNavRow([TabItem('issues', 'issues'), TabItem('pull-requests', 'pulls'),
      TabItem('releases', 'releases'), TabItem('attachments', 'attachments'), TabItem('gitea-lfs', 'lfs')]);
  end;

  function Author(const PosterName, OriginalAuthor: string): string;
  begin
    if OriginalAuthor <> '' then
      Result := HtmlEncode(OriginalAuthor) + ' (GitHub)'
    else
      Result := HtmlEncode(PosterName);
  end;

  // On a repository's page: whether it is synced, the button that changes that,
  // and the delete.
  function RepoActions: string;
  var
    Full: string;
  begin
    Full := Owner + '/' + RepoName;
    if IsExcluded(Full) then
      Result := '<p>' + NotSyncedMark + ' ' + BkButton(ARequest, RepoPath(Owner, RepoName) + '/sync',
        'gitea-sync:' + Full, Tx('gitea-sync-again'), BuildHiddenInput('op', 'include'))
    else
      Result := '<p>' + BkButton(ARequest, RepoPath(Owner, RepoName) + '/sync', 'gitea-sync:' + Full,
        Tx('gitea-no-sync'), BuildHiddenInput('op', 'exclude'));
    Result := Result + ' ' + Nav(RepoPath(Owner, RepoName) + '/delete', Tx('gitea-delete-repo'), '') + '</p>';
  end;

  procedure PageRepo(const Tab: string);
  var
    Body: string;
    Rows: TGtRows;
    R: TGtReport;
    K: Integer;
    IsPull: string;
  begin
    Body := '<h2>' + HtmlEncode(Owner + '/' + RepoName) + '</h2>';
    R := Default(TGtReport);
    if (Tab = 'issues') and LoadReport(R) then
    begin
      for K := 0 to High(R.Repos) do
        if IntToStr(R.Repos[K].Id) = RepoId then
          with R.Repos[K] do
            Body := Body + '<table border="1" cellpadding="4" cellspacing="0">' +
              BkHeaderRow(['Git', Tx('vcs-wiki'), Tx('gitea-lfs'), Tx('attachments'), Tx('billing-total'),
                'size', 'git_size', 'lfs_size', Tx('gitea-mismatch')]) + '<tr>' +
              NumCell(Sz(DiskGit)) + NumCell(Sz(DiskWiki)) + NumCell(Sz(LfsDisk) + ' (' + IntToStr(LfsRows) + ')') +
              NumCell(Sz(AttDisk) + ' (' + IntToStr(AttRows) + ')') + NumCell('<b>' + Sz(Total) + '</b>') +
              NumCell(Sz(DbSize)) + NumCell(Sz(DbGit)) + NumCell(Sz(DbLfs)) +
              Cell('<font color="#a00000">' + HtmlEncode(Mismatch) + '</font>') + '</tr></table>';
      Body := Body + IndexLine(R);
    end;
    GtFreeReport(R);
    Err := '';
    if Tab = 'issues' then
      Body := Body + RepoActions;
    Body := Body + RepoTabs(Tab);
    if (Tab = 'issues') or (Tab = 'pulls') then
    begin
      IsPull := ifthen(Tab = 'pulls', '1', '0');
      if Q('SELECT i."index", i.name, i.is_closed, COALESCE(u.name, ''''), COALESCE(i.original_author, ''''), ' +
        'i.created_unix, COALESCE(i.num_comments, 0), ' +
        'COALESCE((SELECT has_merged FROM pull_request pr WHERE pr.issue_id = i.id), 0) ' +
        'FROM issue i LEFT JOIN user u ON u.id = i.poster_id WHERE i.repo_id = ?1 AND i.is_pull = ?2 ' +
        'ORDER BY i."index" DESC LIMIT ' + IntToStr(GITEA_PAGE_SIZE + 1) + ' OFFSET ' + IntToStr(Offset),
        [RepoId, IsPull], Rows) then
      begin
        Body := Body + '<table border="1" width="100%" cellpadding="4" cellspacing="0">' +
          BkHeaderRow(['#', Tx('name'), Tx('state'), Tx('author'), Tx('created'), Tx('comments')]);
        for K := 0 to Min(High(Rows), GITEA_PAGE_SIZE - 1) do
          Body := Body + '<tr>' + NumCell(Nav(RepoPath(Owner, RepoName) + '/issue/' + Rows[K][0], Rows[K][0], '')) +
            Cell(HtmlEncode(Rows[K][1])) +
            Cell(HtmlEncode(ifthen(Rows[K][7] = '1', Tx('merged'), ifthen(Rows[K][2] = '1', Tx('closed'), Tx('open'))))) +
            Cell(Author(Rows[K][3], Rows[K][4])) + Cell(HtmlEncode(GtUnixToText(Rows[K][5]))) +
            NumCell(HtmlEncode(Rows[K][6])) + '</tr>';
        Body := Body + '</table>' + PageButtons(RepoPath(Owner, RepoName) + '/' + Tab, Offset,
          Min(Length(Rows), GITEA_PAGE_SIZE), Length(Rows) > GITEA_PAGE_SIZE, '');
      end;
    end
    else if Tab = 'releases' then
    begin
      if Q('SELECT r.id, COALESCE(r.tag_name, ''''), COALESCE(r.title, ''''), r.is_draft, r.is_prerelease, r.is_tag, ' +
        'r.created_unix, (SELECT COUNT(*) FROM attachment a WHERE a.release_id = r.id), ' +
        '(SELECT COALESCE(SUM(a.size), 0) FROM attachment a WHERE a.release_id = r.id), ' +
        'COALESCE(r.original_author, ''''), COALESCE(u.name, '''') FROM release r LEFT JOIN user u ON u.id = r.publisher_id ' +
        'WHERE r.repo_id = ?1 ORDER BY r.created_unix DESC, r.id DESC LIMIT ' + IntToStr(GITEA_PAGE_SIZE + 1) +
        ' OFFSET ' + IntToStr(Offset), [RepoId], Rows) then
      begin
        Body := Body + '<table border="1" width="100%" cellpadding="4" cellspacing="0">' +
          BkHeaderRow([Tx('tag'), Tx('name'), Tx('type'), Tx('author'), Tx('created'), Tx('attachments'), Tx('size')]);
        for K := 0 to Min(High(Rows), GITEA_PAGE_SIZE - 1) do
          Body := Body + '<tr>' + Cell(Nav(RepoPath(Owner, RepoName) + '/release/' + Rows[K][0], Rows[K][1], '')) +
            Cell(HtmlEncode(Rows[K][2])) +
            Cell(HtmlEncode(ifthen(Rows[K][5] = '1', Tx('tag'), ifthen(Rows[K][3] = '1', 'draft',
              ifthen(Rows[K][4] = '1', 'pre-release', ''))))) + Cell(Author(Rows[K][10], Rows[K][9])) +
            Cell(HtmlEncode(GtUnixToText(Rows[K][6]))) + NumCell(HtmlEncode(Rows[K][7])) +
            NumCell(Sz(StrToInt64Def(Rows[K][8], 0))) + '</tr>';
        Body := Body + '</table>' + PageButtons(RepoPath(Owner, RepoName) + '/releases', Offset,
          Min(Length(Rows), GITEA_PAGE_SIZE), Length(Rows) > GITEA_PAGE_SIZE, '');
      end;
    end
    else if Tab = 'attachments' then
    begin
      if Q('SELECT a.uuid, COALESCE(a.name, ''''), COALESCE(a.size, 0), a.issue_id, a.release_id, a.comment_id, ' +
        'COALESCE((SELECT i."index" FROM issue i WHERE i.id = a.issue_id), ''''), ' +
        'COALESCE((SELECT r.tag_name FROM release r WHERE r.id = a.release_id), ''''), a.created_unix ' +
        'FROM attachment a WHERE a.repo_id = ?1 ORDER BY a.size DESC LIMIT ' + IntToStr(GITEA_PAGE_SIZE + 1) +
        ' OFFSET ' + IntToStr(Offset), [RepoId], Rows) then
      begin
        Body := Body + '<table border="1" width="100%" cellpadding="4" cellspacing="0">' +
          BkHeaderRow([Tx('name'), Tx('size'), Tx('issues') + ' / ' + Tx('releases'), Tx('created'), Tx('path'),
            Tx('gitea-on-disk')]);
        for K := 0 to Min(High(Rows), GITEA_PAGE_SIZE - 1) do
          Body := Body + '<tr>' + Cell(HtmlEncode(Rows[K][1])) + NumCell(Sz(StrToInt64Def(Rows[K][2], 0))) +
            Cell(ifthen(Rows[K][6] <> '', '#' + HtmlEncode(Rows[K][6]), HtmlEncode(Rows[K][7]))) +
            Cell(HtmlEncode(GtUnixToText(Rows[K][8]))) +
            Cell('<tt>' + HtmlEncode(Copy(Rows[K][0], 1, 1) + '/' + Copy(Rows[K][0], 2, 1) + '/' + Rows[K][0]) + '</tt>') +
            Cell(ifthen(FileExists(P.Attachments + '/' + Copy(Rows[K][0], 1, 1) + '/' + Copy(Rows[K][0], 2, 1) + '/' +
              Rows[K][0]), TxE('yes'), TxE('no'))) + '</tr>';
        Body := Body + '</table>' + PageButtons(RepoPath(Owner, RepoName) + '/attachments', Offset,
          Min(Length(Rows), GITEA_PAGE_SIZE), Length(Rows) > GITEA_PAGE_SIZE, '');
      end;
    end
    else if Tab = 'lfs' then
    begin
      if Q('SELECT oid, COALESCE(size, 0), created_unix FROM lfs_meta_object WHERE repository_id = ?1 ' +
        'ORDER BY size DESC LIMIT ' + IntToStr(GITEA_PAGE_SIZE + 1) + ' OFFSET ' + IntToStr(Offset), [RepoId], Rows) then
      begin
        Body := Body + '<table border="1" width="100%" cellpadding="4" cellspacing="0">' +
          BkHeaderRow(['oid', Tx('size'), Tx('created')]);
        for K := 0 to Min(High(Rows), GITEA_PAGE_SIZE - 1) do
          Body := Body + '<tr>' + Cell('<tt>' + HtmlEncode(Rows[K][0]) + '</tt>') +
            NumCell(Sz(StrToInt64Def(Rows[K][1], 0))) + Cell(HtmlEncode(GtUnixToText(Rows[K][2]))) + '</tr>';
        Body := Body + '</table>' + PageButtons(RepoPath(Owner, RepoName) + '/lfs', Offset,
          Min(Length(Rows), GITEA_PAGE_SIZE), Length(Rows) > GITEA_PAGE_SIZE, '');
      end;
    end;
    Send(Owner + '/' + RepoName, RepoCrumbs('<strong>' + TxE(ifthen(Tab = 'pulls', 'pull-requests',
      ifthen(Tab = 'lfs', 'gitea-lfs', Tab))) + '</strong>'), Body);
  end;

  function AttachmentList(const Where, Id: string): string;
  var
    Rows: TGtRows;
    K: Integer;
  begin
    Result := '';
    if not Q('SELECT COALESCE(name, ''''), COALESCE(size, 0), uuid FROM attachment WHERE ' + Where + ' ORDER BY id',
      [Id], Rows) or (Length(Rows) = 0) then
      Exit;
    Result := '<table border="1" cellpadding="3" cellspacing="0">' + BkHeaderRow([Tx('attachments'), Tx('size'), 'uuid']);
    for K := 0 to High(Rows) do
      Result := Result + '<tr>' + Cell(HtmlEncode(Rows[K][0])) + NumCell(Sz(StrToInt64Def(Rows[K][1], 0))) +
        Cell('<tt>' + HtmlEncode(Rows[K][2]) + '</tt>') + '</tr>';
    Result := Result + '</table>';
  end;

  procedure PageIssue(const Number: string);
  var
    Body, IssueId: string;
    Rows, CRows: TGtRows;
    K: Integer;
  begin
    if not Q('SELECT i.id, i.name, COALESCE(i.content, ''''), i.is_closed, i.is_pull, COALESCE(u.name, ''''), ' +
      'COALESCE(i.original_author, ''''), i.created_unix, i.updated_unix, ' +
      'COALESCE(pr.head_branch, ''''), COALESCE(pr.base_branch, ''''), COALESCE(pr.has_merged, 0) ' +
      'FROM issue i LEFT JOIN user u ON u.id = i.poster_id LEFT JOIN pull_request pr ON pr.issue_id = i.id ' +
      'WHERE i.repo_id = ?1 AND i."index" = ?2', [RepoId, Number], Rows) or (Length(Rows) = 0) then
    begin
      NotFound('#' + Number);
      Exit;
    end;
    IssueId := Rows[0][0];
    Body := RepoTabs('') + '<h2>#' + HtmlEncode(Number) + ' ' + HtmlEncode(Rows[0][1]) + '</h2><p>' +
      HtmlEncode(ifthen(Rows[0][11] = '1', Tx('merged'), ifthen(Rows[0][3] = '1', Tx('closed'), Tx('open')))) +
      ' - ' + Author(Rows[0][5], Rows[0][6]) + ' - ' + HtmlEncode(GtUnixToText(Rows[0][7])) +
      ifthen(Rows[0][4] = '1', ' - ' + HtmlEncode(Rows[0][9] + ' -> ' + Rows[0][10]), '') + '</p>' +
      '<table border="1" width="100%" cellpadding="5" cellspacing="0"><tr><td>' + BkTextHtml(Rows[0][2]) +
      '</td></tr></table>' + AttachmentList('issue_id = ?1 AND COALESCE(comment_id, 0) = 0', IssueId);
    if Q('SELECT c.id, COALESCE(u.name, ''''), COALESCE(c.original_author, ''''), c.created_unix, ' +
      'COALESCE(c.content, '''') FROM comment c LEFT JOIN user u ON u.id = c.poster_id ' +
      'WHERE c.issue_id = ?1 AND c.type = 0 ORDER BY c.created_unix, c.id LIMIT 2000', [IssueId], CRows) then
      for K := 0 to High(CRows) do
        Body := Body + '<h3>' + Author(CRows[K][1], CRows[K][2]) + ' - ' + HtmlEncode(GtUnixToText(CRows[K][3])) +
          '</h3><table border="1" width="100%" cellpadding="5" cellspacing="0"><tr><td>' + BkTextHtml(CRows[K][4]) +
          '</td></tr></table>' + AttachmentList('comment_id = ?1', CRows[K][0]);
    Send(Owner + '/' + RepoName + ' #' + Number, RepoCrumbs('<strong>#' + HtmlEncode(Number) + '</strong>'), Body);
  end;

  procedure PageRelease(const Id: string);
  var
    Body: string;
    Rows: TGtRows;
  begin
    if not Q('SELECT r.tag_name, COALESCE(r.title, ''''), COALESCE(r.note, ''''), COALESCE(r.sha1, ''''), ' +
      'r.created_unix, COALESCE(r.original_author, ''''), COALESCE(u.name, '''') FROM release r ' +
      'LEFT JOIN user u ON u.id = r.publisher_id WHERE r.repo_id = ?1 AND r.id = ?2', [RepoId, Id], Rows) or
      (Length(Rows) = 0) then
    begin
      NotFound(Id);
      Exit;
    end;
    Body := RepoTabs('') + '<h2>' + HtmlEncode(Rows[0][0] + ' ' + Rows[0][1]) + '</h2><p>' + Author(Rows[0][6], Rows[0][5]) +
      ' - ' + HtmlEncode(GtUnixToText(Rows[0][4])) + ' - <tt>' + HtmlEncode(Rows[0][3]) + '</tt></p>' +
      '<table border="1" width="100%" cellpadding="5" cellspacing="0"><tr><td>' + BkTextHtml(Rows[0][2]) +
      '</td></tr></table>' + AttachmentList('release_id = ?1', Id);
    Send(Owner + '/' + RepoName + ' ' + Rows[0][0], RepoCrumbs('<strong>' + HtmlEncode(Rows[0][0]) + '</strong>'), Body);
  end;

  procedure PageOrphans;
  var
    Body: string;
    R: TGtReport;
    K: Integer;
    Parts: TStringArray;
  begin
    Body := '';
    if LoadReport(R) then
    begin
      Body := IndexLine(R);
      if R.Orphans.Count = 0 then
        Body := Body + '<p>' + TxE('gitea-no-orphans') + '</p>'
      else
      begin
        Body := Body + '<p>' + IntToStr(R.Orphans.Count) + ', ' + Sz(R.TotalOrphanBytes) + '</p>' +
          '<table border="1" width="100%" cellpadding="4" cellspacing="0">' +
          BkHeaderRow([Tx('type'), Tx('path'), Tx('size'), Tx('reason')]);
        for K := 0 to R.Orphans.Count - 1 do
        begin
          if K >= 5000 then
            Break;
          Parts := R.Orphans[K].Split([#9]);
          if Length(Parts) < 4 then
            Continue;
          Body := Body + '<tr>' + Cell(HtmlEncode(Parts[0])) + Cell('<tt>' + HtmlEncode(Parts[1]) + '</tt>') +
            NumCell(Sz(StrToInt64Def(Parts[2], 0))) + Cell(HtmlEncode(Parts[3])) + '</tr>';
        end;
        Body := Body + '</table>';
      end;
    end;
    GtFreeReport(R);
    Send(Tx('gitea-orphans'), Crumbs([Home, '<strong>' + TxE('gitea-orphans') + '</strong>']), Body);
  end;

  // --- the writes: cli/omigitea.py, run as jobs ---

  function JobButton(const Name: string): string;
  begin
    Result := Nav('/gitea/jobs/' + BkUrlPart(Name), Name, '');
  end;

  // A job's page: how far it is (the newest "progress <done>/<total> <step>"
  // line, as a bar and a percentage), its newest lines, its errors, and the
  // whole log. Refresh reads the log again.
  procedure ShowJob(const Name: string);
  const
    NEWEST_LINES = 15;
  var
    Body, Path, Text, LastLine, StopText, Line, Step, Bar, Newest, Errors, Log: string;
    Lines: TStringList;
    Running: Boolean;
    K, SlashAt, SpaceAt, Shown: Integer;
    Done, Total, Pct: Int64;
  begin
    Path := IncludeTrailingPathDelimiter(GetGiteaJobsDir) + Name;
    if not GiteaJobNameIsSafe(Name) or not FileExists(Path) then
    begin
      NotFound(Name);
      Exit;
    end;
    Text := ReadFileToString(Path);
    if Length(Text) > 262144 then
      Text := '...' + Copy(Text, Length(Text) - 262144, MaxInt);
    Done := 0;
    Total := 0;
    Step := '';
    Newest := '';
    Errors := '';
    Log := '';
    Lines := TStringList.Create;
    try
      Lines.Text := Text;
      LastLine := '';
      if Lines.Count > 0 then
        LastLine := Trim(Lines[Lines.Count - 1]);
      for K := 0 to Lines.Count - 1 do
      begin
        Line := Lines[K];
        if Copy(Line, 1, 9) = 'progress ' then
        begin
          // progress <done>/<total> <step>
          SlashAt := Pos('/', Line);
          SpaceAt := Pos(' ', Copy(Line, 10, MaxInt));
          if (SlashAt > 10) and (SpaceAt > 0) then
          begin
            Done := StrToInt64Def(Copy(Line, 10, SlashAt - 10), 0);
            Total := StrToInt64Def(Copy(Line, SlashAt + 1, 9 + SpaceAt - SlashAt - 1), 0);
            Step := Copy(Line, 10 + SpaceAt, MaxInt);
          end;
          Continue;
        end;
        Log := Log + Line + #10;
        if (Copy(Line, 1, 5) = 'omi: ') or (Pos('error', LowerCase(Line)) > 0) or
          (Pos('failed', LowerCase(Line)) > 0) then
          Errors := Errors + Line + #10;
      end;
      // The newest lines, newest last.
      Shown := 0;
      for K := Lines.Count - 1 downto 0 do
      begin
        if Shown >= NEWEST_LINES then
          Break;
        if Copy(Lines[K], 1, 9) = 'progress ' then
          Continue;
        Newest := Lines[K] + #10 + Newest;
        Inc(Shown);
      end;
    finally
      Lines.Free;
    end;
    Running := Copy(LastLine, 1, 5) <> 'exit ';
    if (not Running) and (LastLine = 'exit 0') and (Total > 0) then
      Done := Total;
    StopText := '';
    if Running and GiteaJobCanStop(Name) then
    begin
      if FileExists(GiteaJobStopPath(Name)) then
        StopText := ' <b>' + TxE('gitea-job-stop-requested') + '</b>'
      else
        StopText := ' ' + Nav('/gitea/jobs/' + BkUrlPart(Name), Tx('gitea-job-stop'), BuildHiddenInput('op', 'stop'));
    end;
    Bar := '';
    if Total > 0 then
    begin
      Pct := (Done * 100) div Total;
      if Pct > 100 then
        Pct := 100;
      // A table, so the bar shows in every browser Omi serves, old ones too.
      Bar := '<p>' + TxE('gitea-job-progress') + ': <b>' + IntToStr(Pct) + ' %</b> (' + IntToStr(Done) + ' / ' +
        IntToStr(Total) + ') ' + HtmlEncode(Step) + '</p>' +
        '<table border="1" width="100%" cellpadding="0" cellspacing="0"><tr>' +
        ifthen(Pct > 0, '<td width="' + IntToStr(Pct) + '%" bgcolor="#3c78d8" class="job-progress-done">&nbsp;</td>', '') +
        ifthen(Pct < 100, '<td width="' + IntToStr(100 - Pct) + '%">&nbsp;</td>', '') + '</tr></table>';
    end;
    Body := '<h2>' + HtmlEncode(Name) + '</h2><p>' +
      ifthen(Running, TxE('gitea-job-running') + ' ' + Nav('/gitea/jobs/' + BkUrlPart(Name), Tx('refresh'), '') +
        StopText,
        TxE('gitea-job-done') + ' <b>' + HtmlEncode(Copy(LastLine, 6, MaxInt)) + '</b>') + '</p>' + Bar;
    if Errors <> '' then
      Body := Body + '<h3><font color="red">' + TxE('gitea-job-errors') + '</font></h3>' +
        '<table border="1" width="100%" cellpadding="5" cellspacing="0"><tr><td><pre><font color="red">' +
        HtmlEncode(Errors) + '</font></pre></td></tr></table>';
    Body := Body + '<h3>' + TxE('gitea-job-newest-lines') + '</h3>' +
      '<table border="1" width="100%" cellpadding="5" cellspacing="0"><tr><td><pre>' + HtmlEncode(Newest) +
      '</pre></td></tr></table><h3>' + TxE('gitea-job') + '</h3>' +
      '<table border="1" width="100%" cellpadding="5" cellspacing="0"><tr><td><pre>' + HtmlEncode(Log) +
      '</pre></td></tr></table>';
    Send(Tx('gitea-job'), Crumbs([Home, Nav('/gitea/jobs', Tx('gitea-jobs'), ''), '<strong>' + HtmlEncode(Name) +
      '</strong>']), Body);
  end;

  procedure PageJobs;
  var
    Body: string;
    Sr: TSearchRec;
    Names: TStringList;
    K: Integer;
  begin
    Names := TStringList.Create;
    try
      if FindFirst(IncludeTrailingPathDelimiter(GetGiteaJobsDir) + '*.log', faAnyFile, Sr) = 0 then
      begin
        repeat
          if GiteaJobNameIsSafe(Sr.Name) then
            Names.Add(Sr.Name);
        until FindNext(Sr) <> 0;
        FindClose(Sr);
      end;
      Names.Sort;
      Body := '<table border="1" cellpadding="4" cellspacing="0">' + BkHeaderRow([Tx('gitea-job'), Tx('size')]);
      for K := Names.Count - 1 downto 0 do
        Body := Body + '<tr>' + Cell(JobButton(Names[K])) +
          NumCell(Sz(BkFileSize(IncludeTrailingPathDelimiter(GetGiteaJobsDir) + Names[K]))) + '</tr>';
      Body := Body + '</table>';
    finally
      Names.Free;
    end;
    Send(Tx('gitea-jobs'), Crumbs([Home, '<strong>' + TxE('gitea-jobs') + '</strong>']), Body);
  end;

  function JsonList(Json: TJSONObject; const Key: string): string;
  var
    A: TJSONData;
    K: Integer;
  begin
    Result := '';
    A := Json.Find(Key);
    if A is TJSONArray then
      for K := 0 to TJSONArray(A).Count - 1 do
        Result := Result + '<li>' + HtmlEncode(TJSONArray(A).Items[K].AsString) + '</li>';
    if Result <> '' then
      Result := '<ul>' + Result + '</ul>';
  end;

  procedure PageDelete;
  var
    Body, Kind, FullName, E, JobName, BackupDb, Updated: string;
    Json: TJSONObject;
    Tables: TJSONData;
    K: Integer;
    Rows: TSqlRows;
    CanDelete: Boolean;
  begin
    if not FindOwner(Segs[2], Kind, FullName) then
    begin
      NotFound(Segs[2]);
      Exit;
    end;
    if Op = 'delete' then
    begin
      // Signed for this one owner, and the name typed exactly.
      if PostedAction <> 'gitea-delete:' + Owner then
      begin
        RedirectToPublicHome(ARequest, AResponse);
        Exit;
      end;
      if GetFormFieldValue(ARequest, 'confirm') <> Owner then
        Err := Tx('gitea-delete-wrong-name')
      else
      begin
        Ok_ := GiteaStartJob('delete', Owner, '', Owner, Username, False, JobName, E);
        if Ok_ then
        begin
          LogActivity(Username, SessionId, 'gitea-delete', 'started', Owner + ' ' + JobName, ARequest, 0);
          Msg := Tx('gitea-job-started');
          ShowJob(JobName);
          Exit;
        end;
        Err := Tx('error') + ': ' + E;
      end;
    end;
    Body := '<h2>' + TxE('gitea-delete') + ': ' + HtmlEncode(Owner) + '</h2><p>' +
      HtmlEncode(KindName(StrToIntDef(Kind, 0))) + ' - ' + TxE('gitea-dry-run') + '</p>';
    CanDelete := False;
    if not GiteaPlan(Owner, '', Json, E) then
      Err := Tx('error') + ': ' + E
    else
      try
        CanDelete := True;
        if JsonList(Json, 'running') <> '' then
        begin
          Body := Body + '<p><font color="red"><b>' + TxE('gitea-running') + '</b></font></p>' + JsonList(Json, 'running');
          CanDelete := False;
        end;
        if JsonList(Json, 'blocked') <> '' then
        begin
          Body := Body + '<p><font color="red"><b>' + TxE('gitea-blocked') + '</b></font></p>' + JsonList(Json, 'blocked');
          CanDelete := False;
        end;
        Body := Body + '<p>' + TxE('gitea-delete-plan') + '</p><table border="1" cellpadding="4" cellspacing="0">' +
          BkHeaderRow([Tx('name'), Tx('rows')]);
        Tables := Json.Find('tables');
        if Tables is TJSONObject then
          for K := 0 to TJSONObject(Tables).Count - 1 do
            Body := Body + '<tr>' + Cell('<tt>' + HtmlEncode(TJSONObject(Tables).Names[K]) + '</tt>') +
              NumCell(HtmlEncode(TJSONObject(Tables).Items[K].AsString)) + '</tr>';
        Body := Body + '<tr>' + Cell('<b>' + TxE('rows') + '</b>') + NumCell('<b>' + HtmlEncode(Json.Get('rows', '0')) +
          '</b>') + '</tr><tr>' + Cell('<b>' + TxE('files') + '</b>') + NumCell('<b>' +
          HtmlEncode(IntToStr(Json.Get('files', Int64(0)))) + '</b>') + '</tr><tr>' + Cell('<b>' + TxE('space-freed') +
          '</b>') + NumCell('<b>' + Sz(Json.Get('bytes', Int64(0))) + '</b>') + '</tr></table>';
        Body := Body + '<p>' + TxE('repositories') + ': ' + JsonList(Json, 'repositories') + '</p>';
      finally
        Json.Free;
      end;
    // The owner's github-to-gitea backup, when BACKUPS_DIR has one.
    BackupDb := '';
    if (GetBackupsDir <> '') and BackupNameIsSafe(Owner) then
      BackupDb := IncludeTrailingPathDelimiter(GetBackupsDir) + Owner + PathDelim + Owner + '.db';
    if (BackupDb <> '') and FileExists(BackupDb) then
    begin
      Updated := '';
      if BkSqlQuery(BackupDb, 'SELECT value FROM meta WHERE key = ''updated''', [], Rows, E) and (Length(Rows) > 0) then
        Updated := Rows[0][0];
      Body := Body + '<p>' + TxE('gitea-backup-existing') + ': ' + HtmlEncode(Updated) + ' ' +
        BuildActionButton(ARequest, '/backups/' + BkUrlPart(Owner) + '/current', 'backup-nav', Tx('view')) + '</p>';
    end
    else
      Body := Body + '<p>' + TxE('gitea-no-backup') + '</p>';
    if CanDelete then
      Body := Body + '<form method="POST" action="' + HtmlEncode(OwnerPath(Owner) + '/delete') + '">' +
        BuildAuthHiddenFields(ARequest, 'gitea-delete:' + Owner) + BuildHiddenInput('op', 'delete') +
        '<p>' + TxE('gitea-delete-confirm') + ' <input type="text" name="confirm" size="30" value=""> ' +
        '<input type="submit" value="' + TxE('delete') + '"></p></form>';
    Send(Tx('gitea-delete'), Crumbs([Home, Nav(OwnerPath(Owner), Owner, ''), '<strong>' + TxE('delete') +
      '</strong>']), Body);
  end;

  // "Test the token": GitHub's answer to GET /user, shown as the message.
  // The token is never shown; nothing is written.
  procedure TestToken;
  var
    Outcome, Login, Remaining, Limit, Detail: string;
  begin
    try
      Outcome := GwTestGithubToken(GetGithubTokenFile, GetGithubApi, Login, Remaining, Limit, Detail);
    except
      on E: Exception do
      begin
        Outcome := 'unreachable';
        Detail := E.Message;
      end;
    end;
    LogActivity(Username, SessionId, 'gitea-token-tested', Outcome, '', ARequest, 0);
    if Outcome = 'ok' then
    begin
      Msg := Tx('gitea-token-works') + ' ' + Login;
      if Remaining <> '' then
        Msg := Msg + '. ' + Tx('gitea-token-requests-left') + ' ' + Remaining + ' / ' + Limit;
    end
    else if Outcome = 'none' then
      Err := Tx('gitea-github-token') + ': ' + Tx('gitea-token-not-set')
    else if Outcome = 'rejected' then
      Err := Tx('gitea-token-rejected')
    else if Outcome = 'refused' then
      Err := Tx('gitea-token-refused') + ' ' + Detail
    else
      Err := Tx('gitea-token-unreachable') + ' ' + Detail;
  end;

  procedure PageImport;
  var
    Running: TStringList;
    Body, GhOwner, Repos, E, JobName: string;
    Json: TJSONObject;
    Parts: TStringArray;
    Args: TStringArray;
    K: Integer;
    Valid: Boolean;
  begin
    GhOwner := Trim(GetFormFieldValue(ARequest, 'owner'));
    Repos := Trim(GetFormFieldValue(ARequest, 'repos'));
    if Op = 'import' then
    begin
      if PostedAction <> 'gitea-import' then
      begin
        RedirectToPublicHome(ARequest, AResponse);
        Exit;
      end;
      Valid := GtNameIsSafe(GhOwner);
      Parts := StringReplace(Repos, ',', ' ', [rfReplaceAll]).Split([' '], TStringSplitOptions.ExcludeEmpty);
      Repos := '';
      for K := 0 to High(Parts) do
      begin
        if not GtNameIsSafe(Parts[K]) then
          Valid := False;
        Repos := Repos + ifthen(Repos <> '', ' ', '') + Parts[K];
      end;
      if not Valid then
        Err := Tx('gitea-bad-name')
      else if GiteaStartJob('import', GhOwner, Repos, '', Username, False, JobName, E) then
      begin
        LogActivity(Username, SessionId, 'gitea-import', 'started', GhOwner + ' ' + Repos + ' ' + JobName, ARequest, 0);
        Msg := Tx('gitea-job-started');
        ShowJob(JobName);
        Exit;
      end
      else
        Err := Tx('error') + ': ' + E;
    end;
    Body := '<p>' + TxE('gitea-import-help') + '</p>';
    Running := GwRunning(P, SettingPath('GITEA_PID_FILE', ''));
    try
      if Running.Count > 0 then
      begin
        Body := Body + '<p><font color="red"><b>' + TxE('gitea-running') + '</b></font></p><ul>';
        for K := 0 to Running.Count - 1 do
          Body := Body + '<li>' + HtmlEncode(Running[K]) + '</li>';
        Body := Body + '</ul>';
      end;
    finally
      Running.Free;
    end;
    Body := Body + '<p>' + TxE('gitea-github-token') + ': <b>' +
      ifthen(FileExists(GetGithubTokenFile), TxE('gitea-token-set'), TxE('gitea-token-not-set')) + '</b> ' +
      ifthen(FileExists(GetGithubTokenFile), BuildActionButton(ARequest, '/gitea/token', 'gitea-token-test',
        Tx('gitea-token-test')) + ' ', '') +
      BuildActionButton(ARequest, '/settings', 'nav-settings', Tx('settings')) + '</p>' +
      '<form method="POST" action="/gitea/import">' + BuildAuthHiddenFields(ARequest, 'gitea-import') +
      BuildHiddenInput('op', 'import') + '<table border="1" cellpadding="4" cellspacing="0">' +
      '<tr><td>' + TxE('gitea-github-owner') + '</td><td><input type="text" name="owner" size="40" value="' +
      HtmlEncode(GhOwner) + '"></td></tr><tr><td>' + TxE('gitea-github-repos') +
      '</td><td><input type="text" name="repos" size="60" value="' + HtmlEncode(Repos) + '"></td></tr>' +
      '<tr><td colspan="2"><input type="submit" value="' + TxE('gitea-import') + '"></td></tr></table></form>';
    Send(Tx('gitea-import'), Crumbs([Home, '<strong>' + TxE('gitea-import') + '</strong>']), Body);
  end;

  // "Do not sync this repository any more" and "Include again": a line in the
  // exclude file shared with github-to-gitea. Gitea itself is not touched, so
  // this needs no stopped Gitea.
  procedure PageSync;
  var
    Full, E: string;
    Json: TJSONObject;
  begin
    Full := Owner + '/' + RepoName;
    if (PostedAction <> 'gitea-sync:' + Full) or ((Op <> 'exclude') and (Op <> 'include')) then
    begin
      RedirectToPublicHome(ARequest, AResponse);
      Exit;
    end;
    E := '';
    try
      if Op = 'exclude' then
        GwExcludeAdd(GetSyncExcludeFile, Full)
      else
        GwExcludeRemove(GetSyncExcludeFile, Full);
    except
      on Ex: Exception do
        E := Ex.Message;
    end;
    if E = '' then
    begin
      FreeAndNil(Excluded);
      LogActivity(Username, SessionId, 'gitea-' + Op, 'ok', Full, ARequest, 0);
      if Op = 'exclude' then
        Msg := Tx('gitea-excluded-saved') + ' ' + Full
      else
        Msg := Tx('gitea-included-saved') + ' ' + Full;
    end
    else
      Err := Tx('error') + ': ' + E;
    PageRepo('issues');
  end;

  procedure PageDeleteRepo;
  var
    Body, E, JobName, Full: string;
    Json: TJSONObject;
    D: TJSONData;
    K: Integer;
    CanDelete: Boolean;
    Args: TStringArray;
  begin
    Full := Owner + '/' + RepoName;
    if Op = 'delete' then
    begin
      // Signed for this one repository, and owner/name typed exactly.
      if PostedAction <> 'gitea-delete-repo:' + Full then
      begin
        RedirectToPublicHome(ARequest, AResponse);
        Exit;
      end;
      if GetFormFieldValue(ARequest, 'confirm') <> Full then
        Err := Tx('gitea-delete-repo-wrong-name')
      else
      begin
        if GiteaStartJob('delete', Owner, RepoName, Full, Username, GetFormFieldValue(ARequest, 'exclude') = '1',
          JobName, E) then
        begin
          LogActivity(Username, SessionId, 'gitea-delete-repo', 'started', Full + ' ' + JobName, ARequest, 0);
          Msg := Tx('gitea-job-started');
          ShowJob(JobName);
          Exit;
        end;
        Err := Tx('error') + ': ' + E;
      end;
    end;
    Body := '<h2>' + TxE('gitea-delete-repo') + ': ' + HtmlEncode(Full) + '</h2><p>' + TxE('gitea-dry-run') + '</p>';
    CanDelete := False;
    if not GiteaPlan(Owner, RepoName, Json, E) then
      Err := Tx('error') + ': ' + E
    else
      try
        CanDelete := True;
        if JsonList(Json, 'running') <> '' then
        begin
          Body := Body + '<p><font color="red"><b>' + TxE('gitea-running') + '</b></font></p>' + JsonList(Json, 'running');
          CanDelete := False;
        end;
        Body := Body + '<p>' + TxE('gitea-delete-plan') + '</p><table border="1" cellpadding="4" cellspacing="0">' +
          BkHeaderRow([Tx('name'), Tx('rows')]);
        D := Json.Find('tables');
        if D is TJSONObject then
          for K := 0 to TJSONObject(D).Count - 1 do
            Body := Body + '<tr>' + Cell('<tt>' + HtmlEncode(TJSONObject(D).Names[K]) + '</tt>') +
              NumCell(HtmlEncode(TJSONObject(D).Items[K].AsString)) + '</tr>';
        Body := Body + '<tr>' + Cell('<b>' + TxE('rows') + '</b>') + NumCell('<b>' + HtmlEncode(Json.Get('rows', '0')) +
          '</b>') + '</tr></table><p></p><table border="1" cellpadding="4" cellspacing="0">' +
          BkHeaderRow([Tx('files'), Tx('size')]);
        D := Json.Find('bytes_by_kind');
        if D is TJSONObject then
          for K := 0 to TJSONObject(D).Count - 1 do
            Body := Body + '<tr>' + Cell(HtmlEncode(TJSONObject(D).Names[K])) +
              NumCell(Sz(TJSONObject(D).Items[K].AsInt64)) + '</tr>';
        Body := Body + '<tr>' + Cell('<b>' + TxE('space-freed') + ' (' + HtmlEncode(IntToStr(Json.Get('files', Int64(0)))) +
          ' ' + TxE('files') + ')</b>') + NumCell('<b>' + Sz(Json.Get('bytes', Int64(0))) + '</b>') + '</tr></table>';
        if Json.Get('packages_unlinked', Int64(0)) > 0 then
          Body := Body + '<p>' + TxE('gitea-packages-unlinked') + ' ' +
            HtmlEncode(IntToStr(Json.Get('packages_unlinked', Int64(0)))) + '</p>';
      finally
        Json.Free;
      end;
    if CanDelete then
      Body := Body + '<form method="POST" action="' + HtmlEncode(RepoPath(Owner, RepoName) + '/delete') + '">' +
        BuildAuthHiddenFields(ARequest, 'gitea-delete-repo:' + Full) + BuildHiddenInput('op', 'delete') +
        '<p><input type="checkbox" name="exclude" value="1" checked> ' + TxE('gitea-exclude-too') + '</p>' +
        '<p>' + TxE('gitea-delete-repo-confirm') + ' <input type="text" name="confirm" size="40" value=""> ' +
        '<input type="submit" value="' + TxE('delete') + '"></p></form>';
    Send(Tx('gitea-delete-repo'), RepoCrumbs('<strong>' + TxE('delete') + '</strong>'), Body);
  end;

  function GiteaWritePages: Boolean;
  begin
    Result := True;
    if (Length(Segs) = 5) and (Segs[1] = 'o') and ((Segs[4] = 'delete') or (Segs[4] = 'sync')) then
    begin
      if not FindRepo(Segs[2], Segs[3]) then
        NotFound(Segs[2] + '/' + Segs[3])
      else if Segs[4] = 'delete' then
        PageDeleteRepo
      else
        PageSync;
    end
    else if (Length(Segs) = 2) and (Segs[1] = 'jobs') then
      PageJobs
    else if (Length(Segs) = 3) and (Segs[1] = 'jobs') then
    begin
      // Stop: a stop file the running import reads before its next request.
      if (Op = 'stop') and GiteaJobNameIsSafe(Segs[2]) and GiteaJobCanStop(Segs[2]) and
        FileExists(IncludeTrailingPathDelimiter(GetGiteaJobsDir) + Segs[2]) then
      begin
        with TFileStream.Create(GiteaJobStopPath(Segs[2]), fmCreate) do
          Free;
        LogActivity(Username, SessionId, 'gitea-job-stop', 'requested', Segs[2], ARequest, 0);
        Msg := Tx('gitea-job-stop-requested');
      end;
      ShowJob(Segs[2]);
    end
    else if (Length(Segs) = 2) and (Segs[1] = 'token') then
    begin
      if PostedAction = 'gitea-token-test' then
        TestToken;
      PageImport;
    end
    else if (Length(Segs) = 2) and (Segs[1] = 'import') then
      PageImport
    else if (Length(Segs) = 4) and (Segs[1] = 'o') and (Segs[3] = 'delete') then
      PageDelete
    else
      Result := False;
  end;

begin
  Username := GetUsernameFromRequest(ARequest);
  SessionId := GetSessionIdFromRequest(ARequest);
  // GET carries no session (no cookies): back to the public home page.
  if (Username = '') or (ARequest.Method <> 'POST') then
  begin
    RedirectToPublicHome(ARequest, AResponse);
    Exit;
  end;
  PostedAction := GetFormFieldValue(ARequest, 'auth_action');
  Op := GetFormFieldValue(ARequest, 'op');
  if (PostedAction = '') or not VerifyAndConsumeActionToken(ARequest, PostedAction, SessionId, Username) then
  begin
    RedirectToPublicHome(ARequest, AResponse);
    Exit;
  end;
  Excluded := nil;
  SortKey := GetFormFieldValue(ARequest, 'sort');
  if (SortKey <> '') and not AnsiMatchText(SortKey, ['name', 'total', 'git', 'lfs', 'attachments', 'packages',
    'repos', 'db', 'issues']) then
    SortKey := '';

  UserLang := '';
  UsersMap := LoadUsersMap;
  try
    if GetUserData(UsersMap, Username, StoredPassword, StoredOtp, StoredLanguage) then
      UserLang := Trim(StoredLanguage);
  finally
    UsersMap.Free;
  end;
  if UserLang = '' then
    UserLang := 'en';
  IsRtl := False;
  LangData := LoadLanguagesData;
  try
    if LangData.Find(UserLang) is TJSONObject then
      IsRtl := JsonGetBool(TJSONObject(LangData.Find(UserLang)), 'rtl', False);
  finally
    LangData.Free;
  end;

  Translations := LoadTranslations(UserLang);
  try
    Msg := '';
    Err := '';
    RawParts := ARequest.PathInfo.Split(['/']);
    Segs := nil;
    for I := 0 to High(RawParts) do
      if RawParts[I] <> '' then
      begin
        SetLength(Segs, Length(Segs) + 1);
        Segs[High(Segs)] := BkUrlDecode(RawParts[I]);
      end;
    if (Length(Segs) = 0) or (Segs[0] <> 'gitea') then
    begin
      NotFound('');
      Exit;
    end;
    // An owner or repository name is one Gitea name, never a path: '..', a
    // separator or anything Gitea does not allow in a name is not found.
    for I := 2 to Min(3, High(Segs)) do
      if (Segs[1] = 'o') and not GtNameIsSafe(Segs[I]) then
      begin
        NotFound('');
        Exit;
      end;
    for I := 0 to High(Segs) do
      if (Segs[I] = '.') or (Segs[I] = '..') or (Pos('/', Segs[I]) > 0) or (Pos('\', Segs[I]) > 0) or
        (Pos(#0, Segs[I]) > 0) then
      begin
        NotFound('');
        Exit;
      end;
    AppIni := GetGiteaAppIni;
    // The token test needs no Gitea folder: Settings offers it too.
    if (AppIni = '') and (Length(Segs) = 2) and (Segs[1] = 'token') then
    begin
      if PostedAction = 'gitea-token-test' then
        TestToken;
      Send(Tx('gitea-token-test'), Crumbs(['<strong>' + TxE('gitea-token-test') + '</strong>']),
        '<p>' + BuildActionButton(ARequest, '/settings', 'nav-settings', Tx('settings')) + '</p>');
      Exit;
    end;
    if AppIni = '' then
    begin
      Send(Tx('gitea'), Crumbs(['<strong>' + TxE('gitea') + '</strong>']),
        '<p>' + TxE('gitea-not-configured') + '</p><p>GITEA_APP_INI: ' +
        BuildActionButton(ARequest, '/settings', 'nav-settings', Tx('settings')) + '</p>');
      Exit;
    end;
    if not GtResolvePaths(AppIni, P, Err) then
    begin
      Err := Tx('error') + ': ' + Err;
      Send(Tx('gitea'), Crumbs(['<strong>' + TxE('gitea') + '</strong>']),
        '<p>GITEA_APP_INI: <tt>' + HtmlEncode(AppIni) + '</tt> ' +
        BuildActionButton(ARequest, '/settings', 'nav-settings', Tx('settings')) + '</p>');
      Exit;
    end;
    if Length(Segs) = 1 then
      PageOverview
    else if (Length(Segs) = 2) and (Segs[1] = 'owners') then
      PageOwners
    else if (Length(Segs) = 2) and (Segs[1] = 'repos') then
      PageRepos
    else if (Length(Segs) = 2) and (Segs[1] = 'orphans') then
      PageOrphans
    // The pages that write are tried once; then the reading ones.
    else if GiteaWritePages then
      // handled
    else if (Length(Segs) >= 3) and (Segs[1] = 'o') then
    begin
      if Length(Segs) = 3 then
        PageOwner
      else if not FindRepo(Segs[2], Segs[3]) then
        NotFound(Segs[2] + '/' + Segs[3])
      else if Length(Segs) = 4 then
        PageRepo('issues')
      else if (Length(Segs) = 5) and AnsiMatchStr(Segs[4], ['issues', 'pulls', 'releases', 'attachments', 'lfs']) then
        PageRepo(Segs[4])
      else if (Length(Segs) = 6) and (Segs[4] = 'issue') and BkIsDigits(Segs[5]) then
        PageIssue(Segs[5])
      else if (Length(Segs) = 6) and (Segs[4] = 'release') and BkIsDigits(Segs[5]) then
        PageRelease(Segs[5])
      else
        NotFound(Segs[4]);
    end
    else
      NotFound(Segs[1]);
  finally
    Translations.Free;
    Excluded.Free;
  end;
end;

procedure CleanupGlobals;
begin
  if Assigned(Users) then FreeAndNil(Users);
  if Assigned(Sessions) then FreeAndNil(Sessions);
  if Assigned(SessionMeta) then FreeAndNil(SessionMeta);
  if Assigned(FallbackTranslations) then FreeAndNil(FallbackTranslations);
end;

// Test the same IPv4 wildcard address the HTTP server will bind. The socket is
// closed immediately; Application.Run performs the real bind below.
function PortAvailable(APort: Integer): Boolean;
var
  ProbeSocket: LongInt;
  Address: TInetSockAddr;
begin
  Result := False;
  ProbeSocket := fpSocket(AF_INET, SOCK_STREAM, 0);
  if ProbeSocket < 0 then Exit;
  try
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := htons(APort);
    Address.sin_addr.s_addr := htonl(INADDR_ANY);
    Result := fpBind(ProbeSocket, @Address, SizeOf(Address)) = 0;
  finally
    CloseSocket(ProbeSocket);
  end;
end;

function FindAvailablePort(PreferredPort: Integer): Integer;
var
  Candidate: Integer;
begin
  if (PreferredPort < 1) or (PreferredPort > 65535) then
    PreferredPort := DEFAULT_PORT;

  for Candidate := PreferredPort to 65535 do
    if PortAvailable(Candidate) then Exit(Candidate);

  // If the preferred port was near the end of the range, wrap to the first
  // unprivileged port and continue until reaching it again.
  for Candidate := 1024 to PreferredPort - 1 do
    if PortAvailable(Candidate) then Exit(Candidate);

  raise Exception.Create('No available TCP port was found');
end;

// Omi's settings are .ini files in settings/ and its own database is in db/
// (2026-11-24), so that .gitignore keeps every one of them - passwords, users,
// the GitHub token, the activity - out of git. Before, they were .txt (or .ini)
// files and activity.db beside public/. An old file is moved once, and never
// over one that already exists; the token file only when GITHUB_TOKEN_FILE
// does not name it.
procedure MigrateFileLayout;
const
  NAMES: array[0..3] of string = ('settings', 'users', 'usersbruteforcelocked', 'github-token');
var
  I, K: Integer;
  OldPath, NewPath, SettingsText: string;
  Olds: array[0..1] of string;
begin
  ForceDirectories(DataPath('../settings'));
  ForceDirectories(DataPath('../db'));
  for I := 0 to High(NAMES) do
  begin
    NewPath := DataPath('../settings/' + NAMES[I] + '.ini');
    if NAMES[I] = 'github-token' then
    begin
      SettingsText := '';
      if FileExists(DataPath(SETTINGS_FILE)) then
        SettingsText := ReadFileToString(DataPath(SETTINGS_FILE));
      if FileExists(DataPath('../settings.ini')) then
        SettingsText := SettingsText + ReadFileToString(DataPath('../settings.ini'));
      if FileExists(DataPath('../settings.txt')) then
        SettingsText := SettingsText + ReadFileToString(DataPath('../settings.txt'));
      if Pos('GITHUB_TOKEN_FILE=', SettingsText) > 0 then
        Continue;
    end;
    Olds[0] := DataPath('../' + NAMES[I] + '.ini');
    Olds[1] := DataPath('../' + NAMES[I] + '.txt');
    for K := 0 to High(Olds) do
    begin
      OldPath := Olds[K];
      if FileExists(OldPath) and not FileExists(NewPath) then
        if RenameFile(OldPath, NewPath) then
          WriteLn('Moved ', OldPath, ' to ', NewPath);
    end;
  end;
  OldPath := DataPath('../activity.db');
  NewPath := DataPath(ACTIVITY_DB_FILE);
  if FileExists(OldPath) and not FileExists(NewPath) then
    if RenameFile(OldPath, NewPath) then
      WriteLn('Moved ', OldPath, ' to ', NewPath);
end;

begin
  DefaultSystemCodePage := CP_UTF8;
  MigrateFileLayout;
  // ./public/server gitea ...: the command line, no web server.
  if ParamStr(1) = 'gitea' then
  begin
    if AnsiMatchStr(ParamStr(2), ['delete-repo', 'delete-owner', 'delete', 'exclude', 'status', 'import', 'git', 'git-fetch', 'git-index-pack', 'git-refs', 'test-token']) then
      ExitCode := GiteaWriteCli
    else
      ExitCode := GiteaCli;
    Exit;
  end;
  FallbackTranslations := LoadTranslations('en');
  Settings := LoadSettings;
  Users := TStringList.Create;
  Sessions := TStringList.Create;
  SessionMeta := TStringList.Create;
  SessionMeta.NameValueSeparator := '=';
  Sessions.NameValueSeparator := '=';
  ActivityDbReady := False;

  // --port N (or -p N) beats settings.ini: when the port is busy, changing it
  // should not need a file edited first.
  for ArgIndex := 1 to ParamCount - 1 do
    if (ParamStr(ArgIndex) = '--port') or (ParamStr(ArgIndex) = '-p') then
      Settings.Port := StrToIntDef(ParamStr(ArgIndex + 1), Settings.Port);

  WriteLn('Omi Server v', VERSION);
  PreferredPort := Settings.Port;
  Settings.Port := FindAvailablePort(Settings.Port);
  if Settings.Port <> PreferredPort then
    WriteLn('Port ', PreferredPort, ' is unavailable; using ', Settings.Port, '.');
  WriteLn('Port: ', Settings.Port);
  WriteLn('SQLite: embedded ', StrPas(sqlite3_libversion));
  WriteLn('Users file: ', DataPath(USERS_FILE));
  WriteLn('Repos dir: ', DataPath(REPOS_DIR));
  if GetGiteaAppIni <> '' then
  begin
    if FileExists(GetGiteaAppIni) then
      WriteLn('Gitea folder: ', GetGiteaAppIni, ' (pages at /gitea, after signing in)')
    else
      WriteLn('Gitea folder: ', GetGiteaAppIni, ' - NOT FOUND: is the disk mounted? Set GITEA_APP_INI in settings.ini.');
  end;
  WriteLn('git: ', GitDescription);
  WriteLn('');
  // A log file or a pipe buffers stdout: the startup lines are there at once.
  Flush(Output);

  Application.Port := Settings.Port;
  Application.Threaded := {$IFDEF OMI_NO_THREADS}False{$ELSE}True{$ENDIF};
  // fphttpapp handles server exceptions inside Application.Run, before the
  // outer try/except below can see them. Make such a startup failure terminate
  // the run loop and return failure instead of printing an error and exiting 0.
  Application.StopOnException := True;
  Application.ExceptionExitCode := 1;

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
  HTTPRouter.RegisterRoute('/activity', rmGet, @ActivityEndpoint);
  HTTPRouter.RegisterRoute('/activity', rmPost, @ActivityEndpoint);
  HTTPRouter.RegisterRoute('/people', rmGet, @PeopleEndpoint);
  HTTPRouter.RegisterRoute('/people', rmPost, @PeopleEndpoint);
  HTTPRouter.RegisterRoute('/backups', rmGet, @BackupsEndpoint);
  HTTPRouter.RegisterRoute('/backups', rmPost, @BackupsEndpoint);
  HTTPRouter.RegisterRoute('/backups/*', rmGet, @BackupsEndpoint);
  HTTPRouter.RegisterRoute('/backups/*', rmPost, @BackupsEndpoint);
  HTTPRouter.RegisterRoute('/gitea', rmGet, @GiteaEndpoint);
  HTTPRouter.RegisterRoute('/gitea', rmPost, @GiteaEndpoint);
  HTTPRouter.RegisterRoute('/gitea/*', rmGet, @GiteaEndpoint);
  HTTPRouter.RegisterRoute('/gitea/*', rmPost, @GiteaEndpoint);
  HTTPRouter.RegisterRoute('/*', rmGet, @RepoEndpoint);
  HTTPRouter.RegisterRoute('/*', rmPost, @RepoEndpoint);

  // A PORT THAT IS ALREADY IN USE IS AN ORDINARY THING, not a crash. Without
  // this, the ESocketError from the bind escaped the program, and what an admin
  // saw was:
  //
  //   Exception at 00000000004F2348: ESocketError:
  //   Binding of socket failed: 3001.
  //   free(): invalid pointer
  //   Aborted (core dumped)
  //
  // - the exception unwound past the objects above, the half-started server was
  // torn down twice, and the shell reported a core dump for "something else is
  // using that port". Say which port, say what to do about it, and exit 1.
  try
    Application.Initialize;
    Application.Run;
  except
    on E: ESocketError do
    begin
      WriteLn(StdErr, '');
      WriteLn(StdErr, 'Omi: cannot listen on port ', Settings.Port, '.');
      WriteLn(StdErr, E.Message);
      WriteLn(StdErr, '');
      WriteLn(StdErr, 'Something else is already using it. To see what:');
      WriteLn(StdErr, '  ss -ltnp | grep :', Settings.Port, '     (or: lsof -i :', Settings.Port, ')');
      WriteLn(StdErr, 'To use another port, put this in settings.ini beside this server:');
      WriteLn(StdErr, '  port=', Settings.Port + 1);
      WriteLn(StdErr, 'or start it with:  ./public/server --port ', Settings.Port + 1);
      // Do not Halt while Pascal is still handling E: that skips the normal
      // exception-frame unwinding and can itself end in free(): invalid pointer.
      // Set the status and fall through to the one cleanup path below instead.
      ExitCode := 1;
    end;
    on E: Exception do
    begin
      WriteLn(StdErr, '');
      WriteLn(StdErr, 'Omi: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;

  CleanupGlobals;
end.
