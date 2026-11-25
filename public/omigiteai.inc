{ --- importing from GitHub (included by omigiteaw.pas) ------------------------- }
{
  A GitHub organization or user - all its repositories, or the ones named -
  straight into the STOPPED Gitea, as the rows Gitea's own migration writes
  (services/migrations/gitea_uploader.go) and the git repository as Gitea makes
  it, and later only what is missing or changed:

    git          a bare mirror (heads, tags, refs/pull/*) fetched in Pascal
                 (public/omigit.pas, git's smart HTTP protocol) into a folder
                 beside <ROOT>/<owner>/<repo>.git - or with GIT_FETCH=program
                 by `git clone --mirror` - origin removed, Gitea's hooks byte
                 for byte, git-daemon-export-ok, server info; renamed into
                 place just before the commit. Later fetched into.
    rows         repository, repo_unit, topic/repo_topic, team_repo, access,
                 watch, branch, label, milestone, issue, issue_label,
                 pull_request, comment, release (and is_tag rows), attachment,
                 issue_index, and the counters check_repo_stats keeps.
    files        release assets and the GitHub files linked from issue and
                 comment bodies, as attachments.

  Authors: a GitHub user linked to a Gitea user (external_login_user, provider
  github) is that user; anyone else is the importing user with
  original_author and original_author_id, as Gitea's migration does.

  Incremental: issues, pull requests and comments only when updated since the
  last import began (GitHub's `since`); labels, milestones and releases listed
  again; a release file with the same GitHub id, size and updated_at is not
  downloaded again. GitHub's ids are kept in <APP_DATA_PATH>/omi/github-map.db,
  written in the SAME transaction (ATTACH); issues also match by number,
  labels and milestones by name and releases by tag. Nothing is deleted when
  it is gone from GitHub. The repositories in the sync exclude file are left
  out. Not imported: reactions, reviews, LFS objects, Actions, and the branches
  of pull requests from forks (their refs/pull/<n>/head is there).

  No other program runs: git is read and fetched in Pascal. Only with
  GIT_FETCH=program does the git program (GIT) run, and only for the fetch.
}

const
  GW_ISSUES_CONFIG = '{"EnableTimetracker":true,"AllowOnlyContributorsToTrackTime":true,"EnableDependencies":true}';
  GW_PULLS_CONFIG = '{"IgnoreWhitespaceConflicts":false,"AllowMerge":true,"AllowRebase":true,"AllowRebaseMerge":true,' +
    '"AllowSquash":true,"AllowFastForwardOnly":true,"AllowManualMerge":false,"AutodetectManualMerge":false,' +
    '"AllowMergeUpdate":true,"AllowRebaseUpdate":true,"DefaultUpdateStyle":"merge",' +
    '"DefaultDeleteBranchAfterMerge":true,"DefaultMergeStyle":"merge","DefaultSquashMergeMessage":"PR_BODY",' +
    '"DefaultAllowMaintainerEdit":true,"DefaultTargetBranch":""}';
  GW_PROJECTS_CONFIG = '{"ProjectsMode":"all"}';
  GW_NO_DEADLINE = '253370757600';
  GW_GITHUB_SERVICE = '2';

function sqlite3_last_insert_rowid(Db: Pointer): Int64; cdecl; external name GT_C + 'sqlite3_last_insert_rowid';

{ --- helpers --- }

function UnixNow: Int64;
begin
  Result := DateTimeToUnix(LocalTimeToUniversal(Now));
end;

// GitHub's 2026-01-02T03:04:05Z as Unix seconds; Default when empty or bad.
function IsoToUnix(const S: string; Default: Int64): Int64;
var
  Y, Mo, D, H, Mi, Se: Integer;
begin
  Result := Default;
  if Length(S) < 19 then
    Exit;
  Y := StrToIntDef(Copy(S, 1, 4), 0);
  Mo := StrToIntDef(Copy(S, 6, 2), 0);
  D := StrToIntDef(Copy(S, 9, 2), 0);
  H := StrToIntDef(Copy(S, 12, 2), -1);
  Mi := StrToIntDef(Copy(S, 15, 2), -1);
  Se := StrToIntDef(Copy(S, 18, 2), -1);
  if (Y < 1970) or (Mo < 1) or (Mo > 12) or (D < 1) or (D > 31) or (H < 0) or (Mi < 0) or (Se < 0) then
    Exit;
  try
    Result := DateTimeToUnix(EncodeDateTime(Y, Mo, D, H, Mi, Se, 0));
  except
    Result := Default;
  end;
end;

function JStr(O: TJSONData; const Key: string): string;
var
  D: TJSONData;
begin
  Result := '';
  if not (O is TJSONObject) then
    Exit;
  D := TJSONObject(O).Find(Key);
  if (D <> nil) and not (D is TJSONNull) and not (D is TJSONObject) and not (D is TJSONArray) then
    Result := D.AsString;
end;

function JObj(O: TJSONData; const Key: string): TJSONObject;
var
  D: TJSONData;
begin
  Result := nil;
  if O is TJSONObject then
  begin
    D := TJSONObject(O).Find(Key);
    if D is TJSONObject then
      Result := TJSONObject(D);
  end;
end;

function JArr(O: TJSONData; const Key: string): TJSONArray;
var
  D: TJSONData;
begin
  Result := nil;
  if O is TJSONObject then
  begin
    D := TJSONObject(O).Find(Key);
    if D is TJSONArray then
      Result := TJSONArray(D);
  end;
end;

function JBool(O: TJSONData; const Key: string): Boolean;
var
  D: TJSONData;
begin
  Result := False;
  if O is TJSONObject then
  begin
    D := TJSONObject(O).Find(Key);
    if (D <> nil) and (D.JSONType = jtBoolean) then
      Result := D.AsBoolean;
  end;
end;

function B01(V: Boolean): string;
begin
  if V then
    Result := '1'
  else
    Result := '0';
end;

function OriginOf(const Url: string): string;
var
  I, J: Integer;
begin
  Result := '';
  I := Pos('://', Url);
  if I = 0 then
    Exit;
  J := I + 3;
  while (J <= Length(Url)) and (Url[J] <> '/') and (Url[J] <> '?') and (Url[J] <> '#') do
    Inc(J);
  Result := LowerCase(Copy(Url, 1, J - 1));
end;

function UrlEncodeValue(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'] then
      Result := Result + S[I]
    else
      Result := Result + '%' + IntToHex(Ord(S[I]), 2);
end;

function UrlDecodeValue(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '%') and (I + 2 <= Length(S)) and (StrToIntDef('$' + Copy(S, I + 1, 2), -1) >= 0) then
    begin
      Result := Result + Chr(StrToInt('$' + Copy(S, I + 1, 2)));
      Inc(I, 3);
    end
    else
    begin
      Result := Result + S[I];
      Inc(I);
    end;
  end;
end;

// modules/util/shellquote.go ShellEscape, for the paths in Gitea's hooks.
function ShellEscape(const S: string): string;
const
  Needs = ' '#9#10'|&;()<>${}[]*?!"''`\';
var
  Start, Idx, I: Integer;
  Rest, Q: string;

  function AnyOf(const T, Chars: string): Boolean;
  var
    K: Integer;
  begin
    Result := False;
    for K := 1 to Length(T) do
      if Pos(T[K], Chars) > 0 then
        Exit(True);
  end;

begin
  if S = '' then
    Exit(S);
  Start := 0;
  if S[1] = '~' then
  begin
    Idx := Pos('/', S);
    if Idx = 0 then
      Idx := Length(S);
    if not AnyOf(Copy(S, 1, Idx), Needs) then
      Start := Idx;
  end;
  Rest := Copy(S, Start + 1, MaxInt);
  if not AnyOf(Rest, Needs) and (S[1] <> '#') then
    Exit(S);
  if AnyOf(Rest, '!'#10) then
  begin
    Q := '''' + StringReplace(Rest, '''', '''\''''', [rfReplaceAll]) + '''';
    Q := StringReplace(Q, '''''\''', '\''', [rfReplaceAll]);
    Q := StringReplace(Q, '\''''''', '\''', [rfReplaceAll]);
    Exit(Copy(S, 1, Start) + Q);
  end;
  Q := '';
  for I := 1 to Length(Rest) do
    case Rest[I] of
      '\', '$', '`', '"': Q := Q + '\' + Rest[I];
    else
      Q := Q + Rest[I];
    end;
  Result := Copy(S, 1, Start) + '"' + Q + '"';
end;

{ --- Gitea's hooks (modules/git/hooks.go), byte for byte: gitea doctor compares them --- }

procedure WriteHooks(const GitDir, ScriptType, AppPath, CustomConf: string);
const
  LF = #10;
var
  Receive, Update, Head, A, C: string;
  Names, Hooks, Giteas: array[0..3] of string;
  I: Integer;
  Dir: string;

  procedure Put(const Path, Text: string);
  begin
    if GtExists(Path) then
      DeleteFile(Path);
    WriteSynced(Path, Text);
    GtChmod(Path, &755);
  end;

begin
  Receive := '#!/usr/bin/env ' + ScriptType + LF +
    '# AUTO GENERATED BY GITEA, DO NOT MODIFY' + LF +
    'data=$(cat)' + LF +
    'exitcodes=""' + LF +
    'hookname=$(basename $0)' + LF +
    'GIT_DIR=${GIT_DIR:-$(dirname $0)/..}' + LF + LF +
    'for hook in ${GIT_DIR}/hooks/${hookname}.d/*; do' + LF +
    '  test -x "${hook}" && test -f "${hook}" || continue' + LF +
    '  echo "${data}" | "${hook}"' + LF +
    '  exitcodes="${exitcodes} $?"' + LF +
    'done' + LF + LF +
    'for i in ${exitcodes}; do' + LF +
    '  [ ${i} -eq 0 ] || exit ${i}' + LF +
    'done' + LF;
  Update := '#!/usr/bin/env ' + ScriptType + LF +
    '# AUTO GENERATED BY GITEA, DO NOT MODIFY' + LF +
    'exitcodes=""' + LF +
    'hookname=$(basename $0)' + LF +
    'GIT_DIR=${GIT_DIR:-$(dirname $0/..)}' + LF + LF +
    'for hook in ${GIT_DIR}/hooks/${hookname}.d/*; do' + LF +
    '  test -x "${hook}" && test -f "${hook}" || continue' + LF +
    '  "${hook}" $1 $2 $3' + LF +
    '  exitcodes="${exitcodes} $?"' + LF +
    'done' + LF + LF +
    'for i in ${exitcodes}; do' + LF +
    '  [ ${i} -eq 0 ] || exit ${i}' + LF +
    'done' + LF;
  A := ShellEscape(AppPath);
  C := ShellEscape(CustomConf);
  Head := '#!/usr/bin/env ' + ScriptType + LF + '# AUTO GENERATED BY GITEA, DO NOT MODIFY' + LF;
  Names[0] := 'pre-receive';
  Hooks[0] := Receive;
  Giteas[0] := Head + A + ' hook --config=' + C + ' pre-receive' + LF;
  Names[1] := 'update';
  Hooks[1] := Update;
  Giteas[1] := Head + A + ' hook --config=' + C + ' update $1 $2 $3' + LF;
  Names[2] := 'post-receive';
  Hooks[2] := Receive;
  Giteas[2] := Head + A + ' hook --config=' + C + ' post-receive' + LF;
  Names[3] := 'proc-receive';
  Hooks[3] := Head + A + ' hook --config=' + C + ' proc-receive' + LF;
  Giteas[3] := '';
  GtForceDirs(GtPath([GitDir, 'hooks']));
  for I := 0 to 3 do
  begin
    Dir := GtPath([GitDir, 'hooks', Names[I] + '.d']);
    GtForceDirs(Dir);
    GtChmod(Dir, &755);
    Put(GtPath([GitDir, 'hooks', Names[I]]), Hooks[I]);
    Put(GtPath([Dir, 'gitea']), Giteas[I]);
  end;
end;

// The gitea binary the hooks call: GITEA_BINARY, else what an existing
// repository's hooks call. It is written into the hooks, never run here.
function FindAppPath(const P: TGtPaths; const Given: string): string;
var
  Od, Rd: TSearchRec;
  Lines: TStringList;
  Hook: string;
  K: Integer;
begin
  if Given <> '' then
    Exit(ExpandFileName(Given));
  Result := '';
  if FindFirst(GtPath([P.RepoRoot, '*']), faDirectory, Od) = 0 then
  begin
    repeat
      if (Od.Name = '.') or (Od.Name = '..') or (Result <> '') then
        Continue;
      if FindFirst(GtPath([P.RepoRoot, Od.Name, '*']), faDirectory, Rd) = 0 then
      begin
        repeat
          Hook := GtPath([P.RepoRoot, Od.Name, Rd.Name, 'hooks', 'pre-receive.d', 'gitea']);
          if (Result = '') and FileExists(Hook) then
          begin
            Lines := TStringList.Create;
            try
              Lines.Text := ReadSmallFile(Hook);
              if (Lines.Count >= 3) and (Pos(' hook --config=', Lines[2]) > 0) then
              begin
                Result := Copy(Lines[2], 1, Pos(' hook --config=', Lines[2]) - 1);
                K := Length(Result);
                if (K >= 2) and (Result[1] in ['"', '''']) then
                  Result := Copy(Result, 2, K - 2);
              end;
            finally
              Lines.Free;
            end;
          end;
        until FindNext(Rd) <> 0;
        FindClose(Rd);
      end;
    until FindNext(Od) <> 0;
    FindClose(Od);
  end;
  if Result = '' then
    raise EGw.Create('Which gitea binary do the hooks call? Set GITEA_BINARY.');
end;

{ --- git --- }

type
  TGitResult = record
    Code: Integer;
    Output: string;
  end;

var
  // The git program the import runs (GwImportFull sets it).
  GitExe: string = 'git';

const
  // git in Pascal (public/omigit.pas): no other program runs.
  GW_FETCH_DEFAULT = 'pascal';

function GwGitFetchMode(const Value: string): string;
begin
  Result := LowerCase(Trim(Value));
  if Result = '' then
    Result := GW_FETCH_DEFAULT;
  if (Result <> 'pascal') and (Result <> 'program') then
    raise EGw.Create('GIT_FETCH is ''' + Value + '''; it can be pascal or program.');
end;

function GwFindGit(const Given: string): string;
{$IFDEF HASAMIGA}
const
  CANDIDATES: array[0..2] of string = ('C:git', 'C:amiga-git', 'C:am-git');
var
  I: Integer;
{$ENDIF}
begin
  Result := Trim(Given);
  if Result <> '' then
    Exit;
  {$IFDEF HASAMIGA}
  for I := 0 to High(CANDIDATES) do
    if FileExists(CANDIDATES[I]) then
      Exit(CANDIDATES[I]);
  {$ELSE}
  Result := ExeSearch('git' + ExtractFileExt(ParamStr(0)), GetEnvironmentVariable('PATH'));
  {$ENDIF}
end;

function GwGitVersion(const Git: string): string;
var
  Proc: TProcess;
  Buf: array[0..1023] of Char;
  N: LongInt;
  Outp, Chunk: string;
begin
  Result := '';
  if Git = '' then
    Exit;
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := Git;
    Proc.Parameters.Add('--version');
    Proc.Options := [poUsePipes, poStderrToOutPut];
    try
      Proc.Execute;
    except
      Exit;
    end;
    Outp := '';
    repeat
      N := Proc.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        SetString(Chunk, PChar(@Buf[0]), N);
        Outp := Outp + Chunk;
      end;
    until ((N <= 0) and not Proc.Running) or (Length(Outp) > 4096);
    Proc.WaitOnExit;
    if Proc.ExitStatus = 0 then
      Result := Trim(Copy(Outp, 1, Pos(#10, Outp + #10) - 1));
  finally
    Proc.Free;
  end;
end;

function RunGit(const Args: array of string; const Cwd: string; Env: TStrings): TGitResult;
var
  Proc: TProcess;
  I: Integer;
  Buf: array[0..65535] of Char;
  N: LongInt;
  Outp, Chunk: string;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := GitExe;
    for I := 0 to High(Args) do
      Proc.Parameters.Add(Args[I]);
    if Cwd <> '' then
      Proc.CurrentDirectory := Cwd;
    for I := 1 to GetEnvironmentVariableCount do
      Proc.Environment.Add(GetEnvironmentString(I));
    Proc.Environment.Add('GIT_TERMINAL_PROMPT=0');
    if Env <> nil then
      for I := 0 to Env.Count - 1 do
        Proc.Environment.Add(Env[I]);
    Proc.Options := [poUsePipes, poStderrToOutPut];
    Proc.Execute;
    Outp := '';
    repeat
      N := Proc.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
        begin
          SetString(Chunk, PChar(@Buf[0]), N);
          Outp := Outp + Chunk;
        end;
    until (N <= 0) and not Proc.Running;
    while Proc.Output.NumBytesAvailable > 0 do
    begin
      N := Proc.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
        begin
          SetString(Chunk, PChar(@Buf[0]), N);
          Outp := Outp + Chunk;
        end;
    end;
    Proc.WaitOnExit;
    Result.Code := Proc.ExitStatus;
    Result.Output := Outp;
  finally
    Proc.Free;
  end;
end;

function GitOk(const Args: array of string; const Cwd: string; Env: TStrings): string;
var
  R: TGitResult;
begin
  R := RunGit(Args, Cwd, Env);
  if R.Code <> 0 then
    raise EGw.Create('git ' + Args[0] + ' failed: ' + Copy(Trim(R.Output), 1, 500));
  Result := R.Output;
end;

// What `git for-each-ref` gives for the refs under Prefix, read in Pascal,
// NUL-separated: for branches (Tags False) refname, objectname,
// committerdate:unix, contents:subject; for tags refname, objectname,
// *objectname, committerdate:unix, *committerdate:unix.
function RefLines(const GitDir, Prefix: string; Tags: Boolean): TStringArray;
var
  Repo: TGitRepo;
  L: TStringList;
  I, N: Integer;
  Sha, Target, Subject, Dummy: string;
  Time, TargetTime: Int64;

  function TimeText(T: Int64; Ok: Boolean): string;
  begin
    if Ok then
      Result := IntToStr(T)
    else
      Result := '';
  end;

begin
  Result := nil;
  Repo := TGitRepo.Open(GitDir);
  L := Repo.Refs;
  try
    N := 0;
    for I := 0 to L.Count - 1 do
    begin
      if Copy(L.Names[I], 1, Length(Prefix)) <> Prefix then
        Continue;
      Sha := L.ValueFromIndex[I];
      SetLength(Result, N + 1);
      if not Tags then
      begin
        if not Repo.CommitInfo(Sha, Time, Subject) then
        begin
          Time := 0;
          Subject := '';
        end;
        Result[N] := L.Names[I] + #0 + Sha + #0 + TimeText(Time, Time <> 0) + #0 + Subject;
      end
      else
      begin
        Target := Repo.TagTarget(Sha);
        Result[N] := L.Names[I] + #0 + Sha + #0 + Target + #0 +
          TimeText(Time, Repo.CommitInfo(Sha, Time, Dummy)) + #0 +
          TimeText(TargetTime, (Target <> '') and Repo.CommitInfo(Target, TargetTime, Dummy));
      end;
      Inc(N);
    end;
  finally
    L.Free;
    Repo.Free;
  end;
end;

// `git update-server-info`, in Pascal.
procedure ServerInfo(const GitDir: string);
var
  Repo: TGitRepo;
begin
  Repo := TGitRepo.Open(GitDir);
  try
    Repo.UpdateServerInfo;
  finally
    Repo.Free;
  end;
end;

{ --- GitHub --- }

type
  TGhClient = class
  public
    Api, Web, GitBase, Token: string;
    FileHosts: TStringList;
    Anonymous: Boolean;
    LoginCache: string;
    HaveLogin: Boolean;
    Say: TGwSay;
    // The rate limit of the newest answer (X-RateLimit-Remaining / -Limit /
    // -Reset, Retry-After).
    LastRemaining, LastLimit, LastReset, LastRetryAfter: string;
    // The status GitHub really answered: Fetch reports a rate limit as 429.
    LastHttpStatus: Integer;
    // "Few requests left" is said once per hour's window, not on every answer.
    RateWarned: Boolean;
    // Seconds to wait before asking again, after a rate-limit answer.
    function RateWaitSeconds: Integer;
    // Local HH:MM of a Unix time.
    function ClockOf(UnixTime: Int64): string;
    constructor Create(const AToken, AApi, AWeb, AGitRoot, AHosts: string; ASay: TGwSay);
    destructor Destroy; override;
    function Headers(const Url, Accept: string): TStringList;
    // One HTTP GET, following redirects (the token only to GitHub's own
    // addresses); Body gets the answer, or the file into Dest.
    function Fetch(const Url, Accept: string; Dest: TStream; out Status: Integer; out Body: string;
      out ContentType, Disposition: string): Boolean;
    function Get(const Path, Params: string; out Status: Integer): TJSONData;
    function One(const Path, Params: string): TJSONData;
    function All(const Path, Params: string): TJSONArray;
    function Login: string;
    function GitUrl(const Full: string; Wiki: Boolean): string;
    function GitEnv(const Url: string): TStringList;
    function GitAuth(const Url: string): string;
    function FileLinks(const Text: string): TStringList;
  end;

constructor TGhClient.Create(const AToken, AApi, AWeb, AGitRoot, AHosts: string; ASay: TGwSay);
var
  Parts: TStringArray;
  I: Integer;
begin
  inherited Create;
  Token := Trim(AToken);
  Api := ExcludeTrailingPathDelimiter(AApi);
  Web := ExcludeTrailingPathDelimiter(AWeb);
  if AGitRoot <> '' then
    GitBase := ExcludeTrailingPathDelimiter(AGitRoot)
  else
    GitBase := Web;
  FileHosts := TStringList.Create;
  Parts := AHosts.Split([' ', ','], TStringSplitOptions.ExcludeEmpty);
  for I := 0 to High(Parts) do
    FileHosts.Add(ExcludeTrailingPathDelimiter(Parts[I]));
  Say := ASay;
end;

destructor TGhClient.Destroy;
begin
  FileHosts.Free;
  inherited Destroy;
end;

function TGhClient.Headers(const Url, Accept: string): TStringList;
begin
  Result := TStringList.Create;
  Result.Add('Accept: ' + Accept);
  Result.Add('User-Agent: omi-github-import');
  if (Token <> '') and not Anonymous and ((OriginOf(Url) = OriginOf(Api)) or (OriginOf(Url) = OriginOf(Web))) then
    Result.Add('Authorization: token ' + Token);
end;

function TGhClient.Fetch(const Url, Accept: string; Dest: TStream; out Status: Integer; out Body: string;
  out ContentType, Disposition: string): Boolean;
var
  C: TFPHTTPClient;
  H: TStringList;
  Cur, Loc: string;
  Hop, I: Integer;
  Mem: TStringStream;
  Into: TStream;
  Start: Int64;
begin
  Result := False;
  Status := 0;
  Body := '';
  ContentType := '';
  Disposition := '';
  Cur := Url;
  Start := 0;
  if Dest <> nil then
    Start := Dest.Position;
  for Hop := 0 to 8 do
  begin
    C := TFPHTTPClient.Create(nil);
    H := Headers(Cur, Accept);
    Mem := TStringStream.Create('');
    // A file goes straight to Dest (never all in memory), refused past what
    // this platform's files can hold; an answer that is not the file is cut
    // off again below.
    if Dest <> nil then
    begin
      Dest.Size := Start;
      Dest.Position := Start;
      Into := TGtLimitStream.Create(Dest, Cur);
    end
    else
      Into := Mem;
    try
      C.AllowRedirect := False;
      C.IOTimeout := 600000;
      for I := 0 to H.Count - 1 do
        C.AddHeader(Copy(H[I], 1, Pos(':', H[I]) - 1), Trim(Copy(H[I], Pos(':', H[I]) + 1, MaxInt)));
      if Pos('https://', LowerCase(Cur)) = 1 then
        GwNeedTls(Cur);
      try
        C.HTTPMethod('GET', Cur, Into, []);
      except
        on E: Exception do
        begin
          Body := E.Message;
          if Dest <> nil then
            Dest.Size := Start;
          Exit;
        end;
      end;
      Status := C.ResponseStatusCode;
      if (Dest <> nil) and (Status <> 200) then
      begin
        // Not the file: its body is the answer, and Dest is as it was.
        Dest.Position := Start;
        Mem.CopyFrom(Dest, Min(Dest.Size - Start, 65536));
        Dest.Size := Start;
        Dest.Position := Start;
      end;
      // Not `Status in [301, ...]`: a Pascal set holds 0..255, and Free Pascal
      // takes 301 as 301 mod 256 without a word - so no redirect was ever
      // followed here (a release asset is a 302 to GitHub's file host).
      if (Status = 301) or (Status = 302) or (Status = 303) or (Status = 307) or (Status = 308) then
      begin
        Loc := C.GetHeader(C.ResponseHeaders, 'Location');
        if Loc = '' then
          Exit;
        if Pos('://', Loc) = 0 then
          Loc := OriginOf(Cur) + Loc;
        Cur := Loc;
        Continue;
      end;
      ContentType := C.GetHeader(C.ResponseHeaders, 'Content-Type');
      Disposition := C.GetHeader(C.ResponseHeaders, 'Content-Disposition');
      LastRemaining := C.GetHeader(C.ResponseHeaders, 'X-RateLimit-Remaining');
      LastLimit := C.GetHeader(C.ResponseHeaders, 'X-RateLimit-Limit');
      LastReset := C.GetHeader(C.ResponseHeaders, 'X-RateLimit-Reset');
      LastRetryAfter := C.GetHeader(C.ResponseHeaders, 'Retry-After');
      if (Dest = nil) or (Status <> 200) then
        Body := Mem.DataString;
      // Rate limits: wait them out, as github_backup does. Said ONCE per hour's
      // window, with the numbers: it used to be a line on every answer, fifty
      // lines that said nothing new.
      if (Status = 200) and (LastRemaining <> '') then
      begin
        if (StrToIntDef(LastRemaining, 1000) < 50) and not RateWarned then
        begin
          RateWarned := True;
          if Assigned(Say) then
            Say('  GitHub: ' + LastRemaining + ' of ' + LastLimit + ' requests left until ' +
              ClockOf(StrToInt64Def(LastReset, 0)) + '; then the import waits for the limit to reset.');
        end
        else if StrToIntDef(LastRemaining, 0) >= 100 then
          RateWarned := False;
      end;
      // A used-up hour is 403 with X-RateLimit-Remaining: 0; a secondary limit
      // is 403 or 429 with Retry-After, or only its message. This was
      // `Status in [403, 429]`, which a 403 never matched (see the redirect
      // above), so every rate limit ended the import ("pulls/885: 403").
      LastHttpStatus := Status;
      if ((Status = 403) or (Status = 429)) and ((LastRetryAfter <> '') or (LastRemaining = '0') or
        (Pos('rate limit', LowerCase(Body)) > 0)) then
        Status := 429;
      Result := True;
      Exit;
    finally
      if Into <> Mem then
        Into.Free;
      Mem.Free;
      H.Free;
      C.Free;
    end;
  end;
end;

// Stop asked for (GwStopFile, the job page's Stop button): raised like a
// failed request, so every open write is rolled back on the way out.
procedure GwCheckStop;
begin
  if (GwStopFile <> '') and FileExists(GwStopFile) then
    raise EGw.Create('stopped');
end;

function TGhClient.ClockOf(UnixTime: Int64): string;
begin
  if UnixTime <= 0 then
    Exit('the next hour');
  Result := FormatDateTime('hh:nn', UniversalTimeToLocal(UnixToDateTime(UnixTime)));
end;

function TGhClient.RateWaitSeconds: Integer;
var
  Reset, NowUnix: Int64;
begin
  // Retry-After first (a secondary limit), then the hour's reset time, else a
  // minute. A few seconds past the reset, for clocks that disagree.
  Result := StrToIntDef(Trim(LastRetryAfter), 0);
  if Result <= 0 then
  begin
    Reset := StrToInt64Def(LastReset, 0);
    NowUnix := DateTimeToUnix(LocalTimeToUniversal(Now));
    if (LastRemaining = '0') and (Reset > NowUnix) then
      Result := Reset - NowUnix + 5;
  end;
  if Result <= 0 then
    Result := 60;
  if Result > 3700 then
    Result := 3700;
end;

function TGhClient.Get(const Path, Params: string; out Status: Integer): TJSONData;
var
  Url, Body, Ct, Cd: string;
  Attempt, Second, Wait: Integer;
begin
  Result := nil;
  Url := Api + '/' + Path;
  if Params <> '' then
    Url := Url + '?' + Params;
  Attempt := 0;
  while Attempt <= 20 do
  begin
    GwCheckStop;
    Inc(Attempt);
    if not Fetch(Url, 'application/vnd.github+json', nil, Status, Body, Ct, Cd) then
    begin
      if Attempt < 4 then
      begin
        Sleep(2000 * (Attempt + 1));
        Continue;
      end;
      Status := 0;
      Exit;
    end;
    if Status = 429 then
    begin
      // Waited out however long it takes - until the hour's limit resets, as
      // GitHub says - and not counted as a failed attempt: an import of a big
      // repository without a token waits many times, and gave up after 21.
      Wait := RateWaitSeconds;
      if Assigned(Say) then
        Say('  GitHub rate limit reached; waiting until ' +
          ClockOf(DateTimeToUnix(LocalTimeToUniversal(Now)) + Wait) + ' (' + IntToStr((Wait + 59) div 60) + ' min).');
      // A second at a time, so Stop does not wait for the hour.
      for Second := 1 to Wait do
      begin
        GwCheckStop;
        Sleep(1000);
      end;
      Dec(Attempt);
      Continue;
    end;
    if (Status >= 500) and (Attempt < 4) then
    begin
      Sleep(2000 * (Attempt + 1));
      Continue;
    end;
    if (Status = 401) and (Token <> '') and not Anonymous then
    begin
      // A token that is wrong or expired: public repositories are read without it.
      Anonymous := True;
      if Assigned(Say) then
        Say('  GitHub: the token is not accepted; reading without it, 60 requests an hour. ' +
          'Check it with Settings / Test GitHub token.');
      Continue;
    end;
    try
      if Trim(Body) <> '' then
        Result := GetJSON(Body);
    except
      Result := nil;
    end;
    Exit;
  end;
end;

function TGhClient.One(const Path, Params: string): TJSONData;
var
  S: Integer;
begin
  Result := Get(Path, Params, S);
  if S <> 200 then
  begin
    FreeAndNil(Result);
    raise EGw.Create('GitHub ' + Path + ': ' + IntToStr(S));
  end;
end;

function TGhClient.All(const Path, Params: string): TJSONArray;
var
  Page, K, N: Integer;
  D: TJSONData;
  Q: string;
begin
  Result := TJSONArray.Create;
  Page := 1;
  repeat
    Q := Params;
    if Q <> '' then
      Q := Q + '&';
    Q := Q + 'per_page=100&page=' + IntToStr(Page);
    D := One(Path, Q);
    N := 0;
    try
      if D is TJSONArray then
      begin
        N := TJSONArray(D).Count;
        for K := 0 to N - 1 do
          Result.Add(TJSONArray(D).Items[K].Clone);
      end;
    finally
      D.Free;
    end;
    // A big repository is hundreds of pages (wekan/wekan's comments): say how
    // far it is, every ten pages, or the job page shows nothing for an hour.
    if (N = 100) and (Page mod 10 = 0) and Assigned(Say) then
      Say('  GitHub: ' + Path + ': ' + IntToStr(Result.Count) + ' so far (page ' + IntToStr(Page) + ')');
    Inc(Page);
  until N < 100;
  if (Page > 2) and Assigned(Say) then
    Say('  GitHub: ' + Path + ': ' + IntToStr(Result.Count));
end;

function TGhClient.Login: string;
var
  S: Integer;
  D: TJSONData;
begin
  if not HaveLogin then
  begin
    HaveLogin := True;
    LoginCache := '';
    if Token <> '' then
    begin
      D := Get('user', '', S);
      if (S = 200) and (D is TJSONObject) then
        LoginCache := JStr(D, 'login');
      D.Free;
    end;
  end;
  Result := LoginCache;
end;

function TGhClient.GitUrl(const Full: string; Wiki: Boolean): string;
begin
  Result := GitBase + '/' + Full;
  if Wiki then
    Result := Result + '.wiki';
  Result := Result + '.git';
end;

// The token as HTTP basic authentication, in git's environment - never on its
// command line - and only for GitHub's own address.
// The token as git's HTTP basic authentication, for the fetch in Pascal: only
// for GitHub's own address.
function TGhClient.GitAuth(const Url: string): string;
begin
  Result := '';
  if (Token <> '') and not Anonymous and (Copy(Url, 1, 8) = 'https://') and (OriginOf(Url) = OriginOf(Web)) then
    Result := 'Basic ' + EncodeStringBase64('x-access-token:' + Token);
end;

function TGhClient.GitEnv(const Url: string): TStringList;
begin
  Result := TStringList.Create;
  if (Token <> '') and not Anonymous and (Copy(Url, 1, 8) = 'https://') and (OriginOf(Url) = OriginOf(Web)) then
  begin
    Result.Add('GIT_CONFIG_COUNT=1');
    Result.Add('GIT_CONFIG_KEY_0=http.extraHeader');
    Result.Add('GIT_CONFIG_VALUE_0=Authorization: Basic ' + EncodeStringBase64('x-access-token:' + Token));
  end;
end;

// The links in a body to files GitHub keeps: github.com/user-attachments/...,
// github.com/<owner>/<repo>/files|assets/<n>/..., and the file hosts.
function TGhClient.FileLinks(const Text: string): TStringList;
var
  R: TRegExpr;
  Pat, Stop, Link, Hosts: string;
  I: Integer;
begin
  Result := TStringList.Create;
  Stop := '[^\s)"''<>\]]+';
  Hosts := '';
  for I := 0 to FileHosts.Count - 1 do
    Hosts := Hosts + ifthen_(Hosts <> '', '|', '') + QuoteRegExprMetaChars(FileHosts[I]);
  Pat := '(?:' + QuoteRegExprMetaChars(Web) + '/(?:user-attachments/(?:assets|files)/' + Stop +
    '|[\w.-]+/[\w.-]+/(?:files|assets)/\d+/' + Stop + ')';
  if Hosts <> '' then
    Pat := Pat + '|(?:' + Hosts + ')/' + Stop;
  Pat := Pat + ')';
  R := TRegExpr.Create(Pat);
  try
    if R.Exec(Text) then
      repeat
        Link := R.Match[0];
        while (Link <> '') and (Link[Length(Link)] in ['.', ',', ';', ':', '!', '?']) do
          SetLength(Link, Length(Link) - 1);
        if Result.IndexOf(Link) < 0 then
          Result.Add(Link);
      until not R.ExecNext;
  finally
    R.Free;
  end;
end;

// github_backup.file_id: a link's id, below 2**53.
function FileId(const Url: string): Int64;
begin
  Result := StrToInt64('$' + Copy(Sha256Hex(Url), 1, 13));
end;

function NameOf(const Disposition, Url: string): string;
var
  I: Integer;
  S: string;
begin
  Result := '';
  I := Pos('filename*=UTF-8''''', Disposition);
  if I > 0 then
  begin
    S := Copy(Disposition, I + 17, MaxInt);
    if Pos(';', S) > 0 then
      S := Copy(S, 1, Pos(';', S) - 1);
    Result := Trim(UrlDecodeValue(S));
  end
  else
  begin
    I := Pos('filename=', Disposition);
    if I > 0 then
    begin
      S := Copy(Disposition, I + 9, MaxInt);
      if Pos(';', S) > 0 then
        S := Copy(S, 1, Pos(';', S) - 1);
      Result := Trim(UrlDecodeValue(StringReplace(S, '"', '', [rfReplaceAll])));
    end;
  end;
  if Result = '' then
  begin
    S := Url;
    if Pos('?', S) > 0 then
      S := Copy(S, 1, Pos('?', S) - 1);
    while (S <> '') and (S[Length(S)] = '/') do
      SetLength(S, Length(S) - 1);
    Result := UrlDecodeValue(Copy(S, LastDelimiter('/', S) + 1, MaxInt));
  end;
  if (Result = '') or (Pos('/', Result) > 0) then
    Result := 'file';
end;

// The Amiga file systems Omi can write to (FFS long names, PFS3, SFS) hold
// names of up to 107 characters, and they are case-insensitive: a name longer
// than that, or one that differs from an existing one only in case, is refused
// everywhere, so a Gitea folder Omi writes can be copied there.
const
  GW_MAX_NAME = 107;

procedure CheckFolderName(const Dir, Name: string);
var
  Sr: TSearchRec;
begin
  if Length(Name) > GW_MAX_NAME then
    raise EGw.Create('the name ' + Name + ' is longer than ' + IntToStr(GW_MAX_NAME) +
      ' characters, which the Amiga file systems cannot hold');
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile or faDirectory, Sr) = 0 then
  begin
    try
      repeat
        if (Sr.Name <> Name) and SameText(Sr.Name, Name) then
          raise EGw.Create('the name ' + Name + ' differs only in case from ' + Sr.Name + ' in ' + Dir +
            ', which a case-insensitive file system cannot hold');
      until FindNext(Sr) <> 0;
    finally
      FindClose(Sr);
    end;
  end;
end;

{ --- the importer --- }

type
  TGwFile = record
    Uuid, Name, Kind, Key, ParentKind: string;
    Size, GithubId, Release, Parent, Downloads, Created: Int64;
    Number: Int64;
  end;
  TGwFiles = array of TGwFile;

  TGwImporter = class
  public
    P: TGtPaths;
    Gh: TGhClient;
    W: TGwWriter;
    Say: TGwSay;
    DoerName, AppPath, ExcludeFile, FetchMode: string;
    DoerId: string;
    Stats: TJSONObject;
    // The Gitea repository being imported into, when it already exists: rows
    // already in it that Omi did not write are adopted (AdoptedIssue,
    // AdoptedComment, AdoptedAsset) - kept as Gitea has them, not copied again.
    AdoptRepoId: string;
    // The tags of the releases whose files are kept (RELEASE_ASSETS_KEEP);
    // nil keeps every release's files.
    KeptTags: TStringList;
    // The newest release whose files Gitea had when the import began, when it
    // is not a kept one: its files stay until the kept releases' files are all
    // fetched (KeptIncomplete false), so there is always one release's files.
    KeepUntilDone: TStringList;
    KeptIncomplete: Boolean;
    procedure DecideKeptTags(Releases: TJSONArray);
    procedure FreeReleaseSpace(const RepoId, Full: string; Releases: TJSONArray);
    function AdoptedIssue(Db: TGwDb; Number: Int64): string;
    function AdoptedComment(Db: TGwDb; Number: Int64; const CreatedAt: string): string;
    function AdoptedAsset(Db: TGwDb; const Tag, Name: string): string;
    constructor Create(const AP: TGtPaths; AGh: TGhClient; AW: TGwWriter; ASay: TGwSay);
    destructor Destroy; override;
    procedure Count(const What: string; N: Int64 = 1);
    function OpenDb: TGwDb;
    function Insert(Db: TGwDb; const Table: string; const Pairs: array of string): Int64;
    procedure Update(Db: TGwDb; const Table, Id: string; const Pairs: array of string);
    function Mapped(Db: TGwDb; const Kind: string; GithubId: Int64; out Updated: string): string;
    procedure Remember(Db: TGwDb; const Kind: string; GithubId: Int64; const RepoId, GiteaId, Updated: string);
    procedure Poster(Db: TGwDb; User: TJSONData; out PosterId, OrigAuthor, OrigAuthorId: string);
    function Run(const Name, OnlyRepos: string): TJSONObject;
    procedure EnsureOwner(Db: TGwDb; Info: TJSONObject; IsOrg: Boolean; out OwnerId, OwnerType: string;
      NewFiles: TJSONArray);
    procedure ImportRepo(Gr: TJSONObject; const OwnerId, OwnerType, OwnerName: string);
    function PrepareGit(const GitDir, Url: string; Wiki: Boolean; out IsNew: Boolean): string;
    function Download(Releases, Issues, Comments: TJSONArray): TGwFiles;
    function RepoRows(Db: TGwDb; Gr: TJSONObject; const OwnerId, OwnerType, OwnerName, GitDir,
      Existing: string): string;
    procedure ContentRows(Db: TGwDb; const RepoId, GitDir: string; Labels, Milestones, Issues, Comments: TJSONArray;
      Pulls: TJSONObject; Releases: TJSONArray; const Files: TGwFiles; OldFiles: TJSONArray);
    procedure FetchPulls(const Full: string; Issues: TJSONArray; Pulls: TJSONObject);
    function FetchReleases(const Full, Since: string): TJSONArray;
    procedure PullRow(Db: TGwDb; const RepoId, IssueId: string; Number: Int64; Pr: TJSONObject; const GitDir: string);
    procedure Counters(Db: TGwDb; const RepoId, OwnerId: string);
  end;

constructor TGwImporter.Create(const AP: TGtPaths; AGh: TGhClient; AW: TGwWriter; ASay: TGwSay);
begin
  inherited Create;
  P := AP;
  Gh := AGh;
  W := AW;
  Say := ASay;
  Stats := TJSONObject.Create;
end;

destructor TGwImporter.Destroy;
begin
  KeptTags.Free;
  KeepUntilDone.Free;
  Stats.Free;
  inherited Destroy;
end;

procedure TGwImporter.Count(const What: string; N: Int64);
begin
  if Stats.Find(What) = nil then
    Stats.Add(What, N)
  else
    Stats.Int64s[What] := Stats.Int64s[What] + N;
end;

function TGwImporter.OpenDb: TGwDb;
var
  MapPath: string;
begin
  MapPath := GtPath([P.AppDataPath, 'omi', 'github-map.db']);
  GtForceDirs(ExtractFileDir(MapPath));
  // An empty file is an empty SQLite database; ATTACH on a connection opened
  // without SQLITE_OPEN_CREATE cannot make one.
  if not FileExists(MapPath) then
    WriteSynced(MapPath, '');
  Result := TGwDb.Open(P.DbPath, False);
  Result.Exec('ATTACH DATABASE ?1 AS omimap', [MapPath]);
  Result.Exec('CREATE TABLE IF NOT EXISTS omimap.owner_map (github_id INTEGER PRIMARY KEY, gitea_id INTEGER, login TEXT)', []);
  Result.Exec('CREATE TABLE IF NOT EXISTS omimap.repo_map (github_id INTEGER PRIMARY KEY, gitea_id INTEGER, ' +
    'full_name TEXT, since TEXT)', []);
  Result.Exec('CREATE TABLE IF NOT EXISTS omimap.item_map (kind TEXT, github_id INTEGER, repo_id INTEGER, ' +
    'gitea_id INTEGER, updated TEXT, PRIMARY KEY (kind, github_id))', []);
end;

// Every column, the given ones and the zero value of the others - as xorm
// inserts a Go struct - so no column Gitea reads is NULL. Pairs: name, value, ...
function TGwImporter.Insert(Db: TGwDb; const Table: string; const Pairs: array of string): Int64;
var
  Cols: TGtRows;
  I, K: Integer;
  Names, Marks: string;
  Values: array of string;
  Found: Boolean;
  Typ, V: string;
begin
  Cols := Db.Query('SELECT name, upper(COALESCE(type, '''')), pk FROM pragma_table_info(?1)', [Table]);
  Names := '';
  Marks := '';
  Values := nil;
  for I := 0 to High(Cols) do
  begin
    Found := False;
    V := '';
    K := 0;
    while K < High(Pairs) do
    begin
      if Pairs[K] = Cols[I][0] then
      begin
        Found := True;
        V := Pairs[K + 1];
      end;
      Inc(K, 2);
    end;
    if not Found then
    begin
      if Cols[I][2] <> '0' then
        Continue;
      Typ := Cols[I][1];
      if (Pos('INT', Typ) > 0) or (Pos('BOOL', Typ) > 0) or (Pos('REAL', Typ) > 0) or (Pos('NUM', Typ) > 0) then
        V := '0'
      else if (Pos('CHAR', Typ) > 0) or (Pos('TEXT', Typ) > 0) or (Pos('UUID', Typ) > 0) or (Pos('CLOB', Typ) > 0) then
        V := ''
      else
        Continue;
    end;
    Names := Names + ifthen_(Names <> '', ', ', '') + '`' + Cols[I][0] + '`';
    SetLength(Values, Length(Values) + 1);
    Values[High(Values)] := V;
    Marks := Marks + ifthen_(Marks <> '', ', ', '') + '?' + IntToStr(Length(Values));
  end;
  Db.Exec('INSERT INTO `' + Table + '` (' + Names + ') VALUES (' + Marks + ')', Values);
  Result := sqlite3_last_insert_rowid(Db.Db);
end;

procedure TGwImporter.Update(Db: TGwDb; const Table, Id: string; const Pairs: array of string);
var
  Have: TGtRows;
  Sets: string;
  Values: array of string;
  K, I: Integer;
  Ok: Boolean;
begin
  Have := Db.Query('SELECT name FROM pragma_table_info(?1)', [Table]);
  Sets := '';
  Values := nil;
  K := 0;
  while K < High(Pairs) do
  begin
    Ok := False;
    for I := 0 to High(Have) do
      if Have[I][0] = Pairs[K] then
        Ok := True;
    if Ok then
    begin
      SetLength(Values, Length(Values) + 1);
      Values[High(Values)] := Pairs[K + 1];
      Sets := Sets + ifthen_(Sets <> '', ', ', '') + '`' + Pairs[K] + '` = ?' + IntToStr(Length(Values));
    end;
    Inc(K, 2);
  end;
  if Sets = '' then
    Exit;
  SetLength(Values, Length(Values) + 1);
  Values[High(Values)] := Id;
  Db.Exec('UPDATE `' + Table + '` SET ' + Sets + ' WHERE id = ?' + IntToStr(Length(Values)), Values);
end;

function TGwImporter.Mapped(Db: TGwDb; const Kind: string; GithubId: Int64; out Updated: string): string;
var
  Rows: TGtRows;
begin
  Rows := Db.Query('SELECT gitea_id, COALESCE(updated, '''') FROM omimap.item_map WHERE kind = ?1 AND github_id = ?2',
    [Kind, IntToStr(GithubId)]);
  if Length(Rows) > 0 then
  begin
    Result := Rows[0][0];
    Updated := Rows[0][1];
  end
  else
  begin
    Result := '';
    Updated := '';
  end;
end;

procedure TGwImporter.Remember(Db: TGwDb; const Kind: string; GithubId: Int64; const RepoId, GiteaId, Updated: string);
begin
  Db.Exec('INSERT OR REPLACE INTO omimap.item_map (kind, github_id, repo_id, gitea_id, updated) VALUES (?1, ?2, ?3, ?4, ?5)',
    [Kind, IntToStr(GithubId), RepoId, GiteaId, Updated]);
end;

// gitea_uploader.go remapUser.
procedure TGwImporter.Poster(Db: TGwDb; User: TJSONData; out PosterId, OrigAuthor, OrigAuthorId: string);
var
  Gid, Uid: string;
begin
  Gid := JStr(User, 'id');
  if Gid <> '' then
  begin
    Uid := Db.Scalar('SELECT user_id FROM external_login_user WHERE provider = ''github'' AND external_id = ?1', [Gid]);
    if (Uid <> '') and Db.Has('SELECT id FROM user WHERE id = ?1', [Uid]) then
    begin
      PosterId := Uid;
      OrigAuthor := '';
      OrigAuthorId := '0';
      Exit;
    end;
  end;
  PosterId := DoerId;
  OrigAuthor := JStr(User, 'login');
  if OrigAuthor = '' then
    OrigAuthor := 'ghost';
  if Gid = '' then
    Gid := '0';
  OrigAuthorId := Gid;
end;

function RandHex: string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to 16 do
    Result := Result + IntToHex(Random(256), 2);
  Result := LowerCase(Result);
end;

procedure TGwImporter.EnsureOwner(Db: TGwDb; Info: TJSONObject; IsOrg: Boolean; out OwnerId, OwnerType: string;
  NewFiles: TJSONArray);
var
  Login, T, Team: string;
  Rows: TGtRows;
  U: Integer;
  F: TFileStream;
  St, Body, Ct, Cd, AvName, AvPath: string;
  S: Integer;
  Mem: TMemoryStream;
  Data: RawByteString;
begin
  Login := JStr(Info, 'login');
  if not GtNameIsSafe(Login) then
    raise EGw.Create('not a Gitea name: ''' + Login + '''');
  Rows := Db.Query('SELECT id, type FROM user WHERE lower_name = ?1', [LowerCase(Login)]);
  if Length(Rows) > 0 then
  begin
    if (Rows[0][1] <> '0') and (Rows[0][1] <> '1') then
      raise EGw.Create(Login + ' in Gitea is neither a user nor an organization');
    OwnerId := Rows[0][0];
    OwnerType := Rows[0][1];
    Exit;
  end;
  T := IntToStr(UnixNow);
  OwnerId := IntToStr(Insert(Db, 'user', ['lower_name', LowerCase(Login), 'name', Login, 'full_name', JStr(Info, 'name'),
    'email', '', 'keep_email_private', '0', 'passwd', '', 'passwd_hash_algo', '', 'type', B01(IsOrg),
    'location', JStr(Info, 'location'), 'website', JStr(Info, 'blog'),
    'description', ifthen_(JStr(Info, 'bio') <> '', JStr(Info, 'bio'), JStr(Info, 'description')),
    'rands', RandHex, 'salt', RandHex, 'is_active', '1', 'prohibit_login', B01(not IsOrg),
    'max_repo_creation', '-1', 'allow_create_organization', '0', 'visibility', '0', 'created_unix', T,
    'updated_unix', T, 'num_teams', B01(IsOrg), 'num_members', B01(IsOrg), 'avatar', '', 'avatar_email', '',
    'email_notifications_preference', ifthen_(IsOrg, '', 'enabled'), 'language', '']));
  OwnerType := B01(IsOrg);
  Db.Exec('DELETE FROM user_redirect WHERE lower_name = ?1', [LowerCase(Login)]);
  if IsOrg then
  begin
    // models/organization CreateOrganization: the Owners team, its units, the doer in it.
    Team := IntToStr(Insert(Db, 'team', ['org_id', OwnerId, 'lower_name', 'owners', 'name', 'Owners',
      'description', '', 'authorize', '4', 'num_repos', '0', 'num_members', '1', 'includes_all_repositories', '1',
      'can_create_org_repo', '1', 'visibility', '1']));
    for U := 1 to 10 do
      Insert(Db, 'team_unit', ['org_id', OwnerId, 'team_id', Team, 'type', IntToStr(U),
        'access_mode', ifthen_(U in [6, 7], '1', '4')]);
    Insert(Db, 'org_user', ['uid', DoerId, 'org_id', OwnerId, 'is_public', '0']);
    Insert(Db, 'team_user', ['org_id', OwnerId, 'team_id', Team, 'uid', DoerId]);
  end;
  Count('owners created');
  // The GitHub avatar, when it can be fetched.
  if JStr(Info, 'avatar_url') <> '' then
  begin
    Mem := TMemoryStream.Create;
    try
      if Gh.Fetch(JStr(Info, 'avatar_url'), '*/*', Mem, S, Body, Ct, Cd) and (S = 200) and (Mem.Size > 0) and
        (Mem.Size < 5 * 1024 * 1024) then
      begin
        SetLength(Data, Mem.Size);
        Mem.Position := 0;
        Mem.ReadBuffer(Data[1], Mem.Size);
        AvName := Sha256Hex(OwnerId + '-' + Data);
        AvPath := GtPath([P.Avatars, AvName]);
        GtForceDirs(P.Avatars);
        F := TFileStream.Create(AvPath, fmCreate);
        try
          F.WriteBuffer(Data[1], Length(Data));
        finally
          F.Free;
        end;
        AddEntry(NewFiles, AvPath, 'avatar', AvName);
        Update(Db, 'user', OwnerId, ['avatar', AvName, 'use_custom_avatar', '1']);
      end;
    finally
      Mem.Free;
    end;
  end;
  St := '';
end;

// A new repository: cloned into a folder beside it (renamed into place before
// the commit). An existing one: fetched into. Returns the folder git is in, or
// '' when a wiki has nothing to clone.
function TGwImporter.PrepareGit(const GitDir, Url: string; Wiki: Boolean; out IsNew: Boolean): string;
var
  Env: TStringList;
  Tmp: string;
  R: TGitResult;
  N: Int64;
  Repo: TGitRepo;
  Pascal: Boolean;

  procedure FetchPascal(const Dir: string; NewRepo: Boolean);
  begin
    Repo := TGitRepo.Open(Dir);
    try
      if Repo.ObjectFormat <> 'sha1' then
        raise EGw.Create('git in Pascal reads only sha1 repositories; ' + Dir + ' is ' + Repo.ObjectFormat +
          ' (set GIT_FETCH=program)');
      N := GitFetch(Repo, Url, Gh.GitAuth(Url), NewRepo, Say);
      if Assigned(Say) and (N > 0) then
        Say('  git: ' + IntToStr(N) + ' objects');
    finally
      FreeAndNil(Repo);
    end;
  end;

begin
  IsNew := False;
  Pascal := FetchMode = 'pascal';
  Env := Gh.GitEnv(Url);
  try
    if DirectoryExists(GitDir) then
    begin
      if Pascal then
      begin
        try
          FetchPascal(GitDir, False);
        except
          on E: Exception do
          begin
            if not Wiki then
              raise EGw.Create('git fetch failed: ' + E.Message);
            Exit(GitDir);
          end;
        end;
      end
      else
      begin
        R := RunGit(['fetch', '--quiet', '--no-write-fetch-head', Url, '+refs/heads/*:refs/heads/*',
          '+refs/tags/*:refs/tags/*', '+refs/pull/*:refs/pull/*'], GitDir, Env);
        if R.Code <> 0 then
        begin
          if not Wiki then
            raise EGw.Create('git fetch failed: ' + Copy(Trim(R.Output), 1, 500));
          Exit(GitDir);
        end;
      end;
      ServerInfo(GitDir);
      Exit(GitDir);
    end;
    Tmp := GtPath([ExtractFileDir(GitDir), '.omi-new-' + ExtractFileName(GitDir)]);
    N := 0;
    if DirectoryExists(Tmp) then
      RemoveTree(Tmp, N);
    GtForceDirs(ExtractFileDir(GitDir));
    try
      if Pascal then
      begin
        // `git clone --mirror`: a bare repository, everything fetched into it.
        GitInitBare(Tmp);
        FetchPascal(Tmp, True);
      end
      else
      begin
        R := RunGit(['clone', '--mirror', '--quiet', '--', Url, Tmp], '', Env);
        if R.Code <> 0 then
          raise EGw.Create('git clone failed: ' + Copy(Trim(R.Output), 1, 500));
        // `git remote rm origin`, in Pascal: git is run only for the fetch.
        GitDropRemote(Tmp, 'origin');
      end;
    except
      on E: Exception do
      begin
        if DirectoryExists(Tmp) then
          RemoveTree(Tmp, N);
        if Wiki then
          Exit('');
        if E is EGw then
          raise;
        raise EGw.Create('git clone failed: ' + E.Message);
      end;
    end;
    WriteHooks(Tmp, P.ScriptType, AppPath, P.AppIni);
    ServerInfo(Tmp);
    IsNew := True;
    Result := Tmp;
  finally
    Env.Free;
  end;
end;

// Release assets and the files linked from bodies, new or changed, written to
// new attachment files before anything is committed.
// The newest version's files of one release, as github-to-gitea's
// newest_version_files: a release like a nightly holds the same files over and
// over with different version numbers (app-1.2.0-x86_64.deb ... app-1.4.3-
// x86_64.deb). When a name, its version number (the first \d+(\.\d+)+ in it)
// taken out, appears with more than one version, only the files of the newest
// version are kept, and the files without a version number. Any other release
// keeps every file: the result is then False and Wanted holds every name.
// Versions compare as numbers, part by part, a shorter one first when equal.
type
  TGwVersion = array of Int64;

function GwCompareVersion(const A, B: TGwVersion): Integer;
var
  I: Integer;
begin
  for I := 0 to Min(High(A), High(B)) do
    if A[I] <> B[I] then
      Exit(ifthen(A[I] < B[I], -1, 1));
  Result := ifthen(Length(A) < Length(B), -1, ifthen(Length(A) > Length(B), 1, 0));
end;

function GwNewestVersionFiles(Assets: TJSONArray; Wanted: TStringList; out Newest: string): Boolean;
var
  R: TRegExpr;
  I, K, Count_: Integer;
  Names, Stems: TStringList;
  Vers: array of TGwVersion;
  Has: array of Boolean;
  Parts: TStringArray;
  Best: TGwVersion;
  Many: Boolean;
begin
  Result := False;
  Newest := '';
  Wanted.Clear;
  Names := TStringList.Create;
  Stems := TStringList.Create;
  R := TRegExpr.Create('\d+(?:\.\d+)+');
  try
    for I := 0 to Assets.Count - 1 do
      Names.Add(JStr(Assets.Items[I], 'name'));
    Count_ := Names.Count;
    SetLength(Vers, Count_);
    SetLength(Has, Count_);
    for I := 0 to Count_ - 1 do
    begin
      Stems.Add('');
      Has[I] := R.Exec(Names[I]);
      if Has[I] then
      begin
        Parts := R.Match[0].Split(['.']);
        SetLength(Vers[I], Length(Parts));
        for K := 0 to High(Parts) do
          Vers[I][K] := StrToInt64Def(Parts[K], 0);
        Stems[I] := Copy(Names[I], 1, R.MatchPos[0] - 1) + #0 + Copy(Names[I], R.MatchPos[0] + R.MatchLen[0], MaxInt);
      end;
    end;
    // Is any name there with more than one version?
    Many := False;
    for I := 0 to Count_ - 1 do
      if Has[I] and not Many then
        for K := I + 1 to Count_ - 1 do
          if Has[K] and (Stems[K] = Stems[I]) and (GwCompareVersion(Vers[I], Vers[K]) <> 0) then
          begin
            Many := True;
            Break;
          end;
    if not Many then
    begin
      Wanted.AddStrings(Names);
      Exit;
    end;
    Best := nil;
    for I := 0 to Count_ - 1 do
      if Has[I] and ((Best = nil) or (GwCompareVersion(Vers[I], Best) > 0)) then
        Best := Vers[I];
    for I := 0 to Count_ - 1 do
      if not Has[I] or (GwCompareVersion(Vers[I], Best) = 0) then
        Wanted.Add(Names[I]);
    for K := 0 to High(Best) do
      Newest := Newest + ifthen_(K > 0, '.', '') + IntToStr(Best[K]);
    Result := True;
  finally
    R.Free;
    Stems.Free;
    Names.Free;
  end;
end;

// A repository Gitea's own GitHub migration made has the issues, comments and
// release files already, keyed by number, by GitHub's creation time and by
// name - but not in Omi's map, so an import added every comment and file a
// second time. These find them; the import keeps them as they are and maps them.
function TGwImporter.AdoptedIssue(Db: TGwDb; Number: Int64): string;
begin
  Result := '';
  if AdoptRepoId <> '' then
    Result := Db.Scalar('SELECT id FROM issue WHERE repo_id = ?1 AND `index` = ?2', [AdoptRepoId, IntToStr(Number)]);
end;

function TGwImporter.AdoptedComment(Db: TGwDb; Number: Int64; const CreatedAt: string): string;
var
  Iid: string;
begin
  Result := '';
  Iid := AdoptedIssue(Db, Number);
  if Iid = '' then
    Exit;
  // The first plain comment of that issue made in that second that no other
  // GitHub comment is mapped to.
  Result := Db.Scalar('SELECT id FROM comment WHERE issue_id = ?1 AND type = 0 AND created_unix = ?2 ' +
    'AND id NOT IN (SELECT gitea_id FROM omimap.item_map WHERE kind = ''comment'') ORDER BY id LIMIT 1',
    [Iid, IntToStr(IsoToUnix(CreatedAt, 0))]);
end;

function TGwImporter.AdoptedAsset(Db: TGwDb; const Tag, Name: string): string;
begin
  Result := '';
  if AdoptRepoId <> '' then
    Result := Db.Scalar('SELECT a.id FROM attachment a JOIN `release` r ON a.release_id = r.id ' +
      'WHERE r.repo_id = ?1 AND r.tag_name = ?2 AND a.name = ?3 LIMIT 1', [AdoptRepoId, Tag, Name]);
end;

function TGwImporter.Download(Releases, Issues, Comments: TJSONArray): TGwFiles;
var
  Db: TGwDb;
  I, K, L: Integer;
  Rel, A, It: TJSONObject;
  Assets: TJSONArray;
  Have, Upd, Key, Body, Link, ParentKind: string;
  Links: TStringList;
  Fid, Gid, Number: Int64;
  F: TGwFile;
  Versioned: Boolean;
  Wanted: TStringList;
  Version: string;
  BodyFiles: Integer;
  FetchedFiles, FetchedBytes: Int64;

  function Fetch_(const Url, Accept, Name: string; out Fl: TGwFile): Boolean;
  var
    U, Path, Bd, Ct, Cd: string;
    G: TGuid;
    Fs: TFileStream;
    S: Integer;
  begin
    Result := False;
    GwCheckStop;
    CreateGUID(G);
    U := LowerCase(Copy(GUIDToString(G), 2, 36));
    Path := GtPath([P.Attachments, U[1], U[2], U]);
    GtForceDirs(ExtractFileDir(Path));
    Fs := TFileStream.Create(Path, fmCreate);
    try
      if not Gh.Fetch(Url, Accept, Fs, S, Bd, Ct, Cd) or (S <> 200) or (Pos('text/html', Ct) = 1) then
      begin
        if Assigned(Say) then
          Say('  file ' + Url + ' not fetched (' + IntToStr(S) + ')');
        FreeAndNil(Fs);
        DeleteFile(Path);
        Exit;
      end;
      Fl.Size := Fs.Size;
    finally
      Fs.Free;
    end;
    Inc(FetchedFiles);
    Inc(FetchedBytes, Fl.Size);
    GwStatus(Say, 'fetched', IntToStr(FetchedFiles) + ' ' + IntToStr(FetchedBytes));
    Fl.Uuid := U;
    if Name <> '' then
      Fl.Name := Name
    else
      Fl.Name := NameOf(Cd, Url);
    Result := True;
  end;

begin
  Result := nil;
  BodyFiles := 0;
  FetchedFiles := 0;
  FetchedBytes := 0;
  Wanted := TStringList.Create;
  Wanted.CaseSensitive := True;
  Db := OpenDb;
  try
    for I := 0 to Releases.Count - 1 do
    begin
      Rel := TJSONObject(Releases.Items[I]);
      Assets := JArr(Rel, 'assets');
      if Assets = nil then
        Continue;
      // A kept release of several versions of the same files: only the newest
      // version's (GwNewestVersionFiles), unless every release is kept in full.
      Versioned := (KeptTags <> nil) and (KeptTags.IndexOf(JStr(Rel, 'tag_name')) >= 0) and
        GwNewestVersionFiles(Assets, Wanted, Version);
      if Versioned and Assigned(Say) then
        Say('  ' + JStr(Rel, 'tag_name') + ': ' + IntToStr(Assets.Count) + ' files of several versions; only version ' +
          Version + '''s, ' + IntToStr(Wanted.Count) + ' files');
      for K := 0 to Assets.Count - 1 do
      begin
        A := TJSONObject(Assets.Items[K]);
        if Versioned and (Wanted.IndexOf(JStr(A, 'name')) < 0) then
          Continue;
        Gid := StrToInt64Def(JStr(A, 'id'), 0);
        Have := Mapped(Db, 'asset', Gid, Upd);
        Key := JStr(A, 'size') + '|' + JStr(A, 'updated_at');
        if (Have <> '') and (Upd = Key) and Db.Has('SELECT id FROM attachment WHERE id = ?1', [Have]) then
          Continue;
        // Already in this Gitea under its release and name: not fetched again.
        if (Have = '') and (AdoptedAsset(Db, JStr(Rel, 'tag_name'), JStr(A, 'name')) <> '') then
          Continue;
        // An older release than RELEASE_ASSETS_KEEP keeps: no files.
        if (KeptTags <> nil) and (KeptTags.IndexOf(JStr(Rel, 'tag_name')) < 0) then
          Continue;
        F := Default(TGwFile);
        // A release file can be hundreds of MB: each is said, or minutes pass
        // with nothing in the log.
        if Assigned(Say) then
          Say('  fetching ' + JStr(Rel, 'tag_name') + '/' + JStr(A, 'name') + ' (' +
            IntToStr(StrToInt64Def(JStr(A, 'size'), 0) div 1048576) + ' MB)');
        if not Fetch_(JStr(A, 'url'), 'application/octet-stream', ifthen_(JStr(A, 'name') <> '', JStr(A, 'name'),
          'file'), F) then
        begin
          // A kept release not fetched whole: the older release's files stay.
          if (KeptTags <> nil) and (KeptTags.IndexOf(JStr(Rel, 'tag_name')) >= 0) then
            KeptIncomplete := True;
          Continue;
        end;
        F.Kind := 'asset';
        F.GithubId := Gid;
        F.Release := StrToInt64Def(JStr(Rel, 'id'), 0);
        F.Key := Key;
        F.Downloads := StrToInt64Def(JStr(A, 'download_count'), 0);
        F.Created := IsoToUnix(JStr(A, 'created_at'), 0);
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := F;
      end;
    end;
    for L := 0 to Issues.Count + Comments.Count - 1 do
    begin
      if L < Issues.Count then
      begin
        It := TJSONObject(Issues.Items[L]);
        ParentKind := 'issue';
        Number := StrToInt64Def(JStr(It, 'number'), 0);
      end
      else
      begin
        It := TJSONObject(Comments.Items[L - Issues.Count]);
        ParentKind := 'comment';
        Body := JStr(It, 'issue_url');
        Number := StrToInt64Def(Copy(Body, LastDelimiter('/', Body) + 1, MaxInt), 0);
      end;
      // An adopted issue or comment keeps Gitea's own text, whose files Gitea
      // already has: its GitHub links are not fetched again.
      Have := Mapped(Db, ParentKind, StrToInt64Def(JStr(It, 'id'), 0), Upd);
      if ((Have <> '') and (Copy(Upd, 1, 8) = 'adopted:')) or ((Have = '') and
        (((ParentKind = 'issue') and (AdoptedIssue(Db, Number) <> '')) or
         ((ParentKind = 'comment') and (AdoptedComment(Db, Number, JStr(It, 'created_at')) <> '')))) then
        Continue;
      Body := JStr(It, 'body');
      Links := Gh.FileLinks(Body);
      try
        for K := 0 to Links.Count - 1 do
        begin
          Link := Links[K];
          Fid := FileId(Link);
          Have := Mapped(Db, 'file', Fid, Upd);
          if (Have <> '') and Db.Has('SELECT id FROM attachment WHERE id = ?1', [Have]) then
            Continue;
          F := Default(TGwFile);
          if not Fetch_(Link, '*/*', '', F) then
            Continue;
          Inc(BodyFiles);
          if (BodyFiles mod 50 = 0) and Assigned(Say) then
            Say('  files of issues and comments: ' + IntToStr(BodyFiles) + ' fetched');
          F.Kind := 'file';
          F.GithubId := Fid;
          F.ParentKind := ParentKind;
          F.Parent := StrToInt64Def(JStr(It, 'id'), 0);
          F.Number := Number;
          F.Key := Link;
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := F;
        end;
      finally
        Links.Free;
      end;
    end;
  finally
    Db.Free;
    Wanted.Free;
  end;
  Count('files downloaded', Length(Result));
end;

function TGwImporter.RepoRows(Db: TGwDb; Gr: TJSONObject; const OwnerId, OwnerType, OwnerName, GitDir,
  Existing: string): string;
var
  T, Topics, Desc, Name, ObjectFormat, IsEmpty, IsPrivate, RepoId, Tid, Mode, Bname, Bid: string;
  TopicList, OldTopics: TStringList;
  Arr: TJSONArray;
  I, K: Integer;
  Teams, Members, Rows, Refs: TGtRows;
  Watchers: TStringList;
  Pub: Boolean;
  Lines: TStringArray;
  Parts: TStringArray;
  Seen: string;
  Repo: TGitRepo;
  L: TStringList;
begin
  T := IntToStr(UnixNow);
  Name := JStr(Gr, 'name');
  TopicList := TStringList.Create;
  OldTopics := TStringList.Create;
  Watchers := TStringList.Create;
  try
    TopicList.Sorted := True;
    TopicList.Duplicates := dupIgnore;
    Arr := JArr(Gr, 'topics');
    if Arr <> nil then
      for I := 0 to Arr.Count - 1 do
        if Length(Arr.Strings[I]) <= 50 then
          TopicList.Add(Arr.Strings[I]);
    if TopicList.Count = 0 then
      Topics := 'null'
    else
    begin
      Topics := '[';
      for I := 0 to TopicList.Count - 1 do
        Topics := Topics + ifthen_(I > 0, ',', '') + '"' + StringToJSONString(TopicList[I]) + '"';
      Topics := Topics + ']';
    end;
    Repo := TGitRepo.Open(GitDir);
    try
      L := Repo.Refs;
      try
        IsEmpty := B01(L.Count = 0);
      finally
        L.Free;
      end;
      ObjectFormat := Repo.ObjectFormat;
    finally
      Repo.Free;
    end;
    IsPrivate := B01(JBool(Gr, 'private'));
    Desc := JStr(Gr, 'description');
    if Existing <> '' then
    begin
      Update(Db, 'repository', Existing, ['description', Desc, 'website', JStr(Gr, 'homepage'),
        'original_url', JStr(Gr, 'html_url'), 'original_service_type', GW_GITHUB_SERVICE,
        'default_branch', ifthen_(JStr(Gr, 'default_branch') <> '', JStr(Gr, 'default_branch'), 'main'),
        'is_private', IsPrivate, 'is_archived', B01(JBool(Gr, 'archived')), 'is_empty', IsEmpty, 'status', '0',
        'object_format_name', ObjectFormat, 'topics', Topics,
        'updated_unix', IntToStr(IsoToUnix(ifthen_(JStr(Gr, 'pushed_at') <> '', JStr(Gr, 'pushed_at'),
        JStr(Gr, 'updated_at')), UnixNow))]);
      RepoId := Existing;
    end
    else
    begin
      RepoId := IntToStr(Insert(Db, 'repository', ['owner_id', OwnerId, 'owner_name', OwnerName,
        'lower_name', LowerCase(Name), 'name', Name, 'description', Desc, 'website', JStr(Gr, 'homepage'),
        'original_url', JStr(Gr, 'html_url'), 'original_service_type', GW_GITHUB_SERVICE,
        'default_branch', ifthen_(JStr(Gr, 'default_branch') <> '', JStr(Gr, 'default_branch'), 'main'),
        'default_wiki_branch', 'main', 'is_private', IsPrivate, 'is_archived', B01(JBool(Gr, 'archived')),
        'is_empty', IsEmpty, 'is_mirror', '0', 'is_fork', '0', 'fork_id', '0', 'is_template', '0', 'template_id', '0',
        'is_fsck_enabled', '1', 'trust_model', '0', 'status', '0', 'object_format_name', ObjectFormat,
        'topics', Topics, 'avatar', '', 'archived_unix', '0', 'latest_release_id', '0',
        'created_unix', IntToStr(IsoToUnix(JStr(Gr, 'created_at'), UnixNow)),
        'updated_unix', IntToStr(IsoToUnix(ifthen_(JStr(Gr, 'pushed_at') <> '', JStr(Gr, 'pushed_at'),
        JStr(Gr, 'updated_at')), UnixNow))]));
      Db.Exec('DELETE FROM repo_redirect WHERE owner_id = ?1 AND lower_name = ?2', [OwnerId, LowerCase(Name)]);
      Update(Db, 'user', OwnerId, ['last_repo_visibility', IsPrivate]);
      Count('repositories created');
    end;
    // Units, with Gitea's default configs.
    Rows := Db.Query('SELECT type FROM repo_unit WHERE repo_id = ?1', [RepoId]);
    for K in [1, 2, 3, 4, 5, 8, 9, 10] do
    begin
      Seen := '';
      for I := 0 to High(Rows) do
        if Rows[I][0] = IntToStr(K) then
          Seen := 'yes';
      if Seen <> '' then
        Continue;
      case K of
        2: Mode := GW_ISSUES_CONFIG;
        3: Mode := GW_PULLS_CONFIG;
        8: Mode := GW_PROJECTS_CONFIG;
      else
        Mode := GW_NULL;
      end;
      Insert(Db, 'repo_unit', ['repo_id', RepoId, 'type', IntToStr(K), 'config', Mode, 'created_unix', T,
        'anonymous_access_mode', '0', 'everyone_access_mode', '0']);
    end;
    // Topics: topic rows with their counts, repo_topic, repository.topics.
    Rows := Db.Query('SELECT topic_id FROM repo_topic WHERE repo_id = ?1', [RepoId]);
    for I := 0 to High(Rows) do
      OldTopics.Add(Rows[I][0]);
    Db.Exec('DELETE FROM repo_topic WHERE repo_id = ?1', [RepoId]);
    for I := 0 to TopicList.Count - 1 do
    begin
      Tid := Db.Scalar('SELECT id FROM topic WHERE name = ?1', [TopicList[I]]);
      if Tid = '' then
        Tid := IntToStr(Insert(Db, 'topic', ['name', TopicList[I], 'repo_count', '0', 'created_unix', T,
          'updated_unix', T]));
      Insert(Db, 'repo_topic', ['repo_id', RepoId, 'topic_id', Tid]);
      OldTopics.Add(Tid);
    end;
    for I := 0 to OldTopics.Count - 1 do
      if Db.Scalar('SELECT COUNT(*) FROM repo_topic WHERE topic_id = ?1', [OldTopics[I]]) <> '0' then
        Db.Exec('UPDATE topic SET repo_count = (SELECT COUNT(*) FROM repo_topic WHERE topic_id = ?1) WHERE id = ?1',
          [OldTopics[I]])
      else
        Db.Exec('DELETE FROM topic WHERE id = ?1', [OldTopics[I]]);
    // Who can see it: the organization's teams with every repository, and watches.
    Watchers.Add(DoerId);
    if OwnerType = '1' then
    begin
      Teams := Db.Query('SELECT id, authorize FROM team WHERE org_id = ?1 AND includes_all_repositories = 1', [OwnerId]);
      for I := 0 to High(Teams) do
      begin
        if not Db.Has('SELECT id FROM team_repo WHERE team_id = ?1 AND repo_id = ?2', [Teams[I][0], RepoId]) then
          Insert(Db, 'team_repo', ['org_id', OwnerId, 'team_id', Teams[I][0], 'repo_id', RepoId]);
        Members := Db.Query('SELECT uid FROM team_user WHERE team_id = ?1', [Teams[I][0]]);
        for K := 0 to High(Members) do
        begin
          Mode := Db.Scalar('SELECT mode FROM access WHERE user_id = ?1 AND repo_id = ?2', [Members[K][0], RepoId]);
          if Mode = '' then
            Insert(Db, 'access', ['user_id', Members[K][0], 'repo_id', RepoId, 'mode', Teams[I][1]])
          else if StrToIntDef(Mode, 0) < StrToIntDef(Teams[I][1], 0) then
            Db.Exec('UPDATE access SET mode = ?1 WHERE user_id = ?2 AND repo_id = ?3', [Teams[I][1], Members[K][0], RepoId]);
          Watchers.Add(Members[K][0]);
        end;
      end;
      Db.Exec('UPDATE team SET num_repos = (SELECT COUNT(*) FROM team_repo WHERE team_repo.team_id = team.id) ' +
        'WHERE org_id = ?1', [OwnerId]);
    end;
    if Existing = '' then
      for I := 0 to Watchers.Count - 1 do
        if not Db.Has('SELECT id FROM watch WHERE user_id = ?1 AND repo_id = ?2', [Watchers[I], RepoId]) then
          Insert(Db, 'watch', ['user_id', Watchers[I], 'repo_id', RepoId, 'mode', '1', 'include_pull_requests', '1',
            'include_issues', '1', 'include_releases', '1', 'created_unix', T, 'updated_unix', T]);
    // git-daemon-export-ok: a public repository of a public owner.
    Pub := (IsPrivate = '0') and (Db.Scalar('SELECT visibility FROM user WHERE id = ?1', [OwnerId]) = '0');
    if Pub and not FileExists(GtPath([GitDir, 'git-daemon-export-ok'])) then
      WriteSynced(GtPath([GitDir, 'git-daemon-export-ok']), '')
    else if not Pub and FileExists(GtPath([GitDir, 'git-daemon-export-ok'])) then
      DeleteFile(GtPath([GitDir, 'git-daemon-export-ok']));
    // Branches.
    Lines := RefLines(GitDir, 'refs/heads/', False);
    for I := 0 to High(Lines) do
    begin
      Parts := Lines[I].Split([#0]);
      if Length(Parts) < 3 then
        Continue;
      Bname := Copy(Parts[0], Length('refs/heads/') + 1, MaxInt);
      Bid := Db.Scalar('SELECT id FROM branch WHERE repo_id = ?1 AND name = ?2', [RepoId, Bname]);
      if Length(Parts) < 4 then
      begin
        SetLength(Parts, 4);
        Parts[3] := '';
      end;
      if Bid <> '' then
        Update(Db, 'branch', Bid, ['commit_id', Parts[1], 'commit_message', Parts[3], 'commit_time', Parts[2],
          'is_deleted', '0', 'updated_unix', T])
      else
        Insert(Db, 'branch', ['repo_id', RepoId, 'name', Bname, 'commit_id', Parts[1], 'commit_message', Parts[3],
          'commit_time', ifthen_(Parts[2] <> '', Parts[2], '0'), 'pusher_id', OwnerId, 'is_deleted', '0',
          'created_unix', T, 'updated_unix', T]);
    end;
    Refs := nil;
    Result := RepoId;
  finally
    TopicList.Free;
    OldTopics.Free;
    Watchers.Free;
  end;
end;

// The pull requests among Issues, into Pulls by number. One request each was
// about 1800 requests for wekan/wekan - the whole hour of a token, and 30 hours
// without one. The list (100 a page, newest change first) has every field
// PullRow reads (draft, head, base, merged_at, merge_commit_sha), so a sync of
// many is read from it, stopping once all are found; a few, or any the list did
// not reach, one by one.
// The releases, newest first (as GitHub lists them). With Since, paging stops
// at the first page whose oldest release was made before it: ten years of
// releases are not read again on every import. A release older than Since is
// in Gitea already (imported, or adopted by its tag).
// RELEASE_ASSETS_KEEP, as gitea-patches' mirrors read release_assets_keep:
// 'newest' or empty is the newest release, a number that many of the newest,
// 'all' every one. WeKan's releases are dozens of 300 MB bundles each, ten
// years of them: an import that fetched the files of every release missing
// them in Gitea - which keeps only the newest - would have filled the disk.
// The tag of the release with GitHub id Id among Releases.
function ReleaseTag(Releases: TJSONArray; Id: Int64): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Releases.Count - 1 do
    if StrToInt64Def(JStr(Releases.Items[I], 'id'), -1) = Id then
      Exit(JStr(Releases.Items[I], 'tag_name'));
end;

procedure TGwImporter.DecideKeptTags(Releases: TJSONArray);
var
  V: string;
  N, I: Integer;
begin
  FreeAndNil(KeptTags);
  V := LowerCase(Trim(GwReleaseAssetsKeep));
  if V = 'all' then
    Exit;
  N := StrToIntDef(V, 1);
  if N < 1 then
    N := 1;
  KeptTags := TStringList.Create;
  KeptTags.CaseSensitive := True;
  // GitHub lists the newest first; a draft is not a release yet.
  for I := 0 to Releases.Count - 1 do
  begin
    if KeptTags.Count >= N then
      Break;
    if not JBool(Releases.Items[I], 'draft') then
      KeptTags.Add(JStr(Releases.Items[I], 'tag_name'));
  end;
  // No published release on GitHub: nothing kept, and nothing removed either
  // (FreeReleaseSpace and the write keep their hands off then), as
  // github-to-gitea deletes files only of releases GitHub lists.
  // ifthen_ evaluates both of its values, so KeptTags[0] is read only when
  // there is one: with none it was "List index (0) out of bounds".
  if Assigned(Say) then
  begin
    if KeptTags.Count = 0 then
      Say('  release files: GitHub has no release, Gitea''s are left as they are')
    else if KeptTags.Count = 1 then
      Say('  release files kept: ' + KeptTags[0])
    else
      Say('  release files kept: ' + IntToStr(KeptTags.Count) + ' newest releases');
  end;
end;

// FIRST, before git and before a single file is fetched: the disk is made
// room on. Every release's files go except the kept releases' and the newest
// release that has files in Gitea now - committed on their own, the files
// deleted by the journal at once. That newest one goes only later, in the
// import's own transaction, once the kept releases' files are all fetched.
procedure TGwImporter.FreeReleaseSpace(const RepoId, Full: string; Releases: TJSONArray);
var
  Db: TGwDb;
  Rows: TGtRows;
  Entries: TJSONArray;
  Newest, Version: string;
  I, K: Integer;
  Freed: Int64;
  Wanted: TStringList;
  Assets: TJSONArray;
  Bytes: Int64;
begin
  Bytes := 0;
  FreeAndNil(KeepUntilDone);
  KeptIncomplete := False;
  if (KeptTags = nil) or (KeptTags.Count = 0) or (RepoId = '') then
    Exit;
  if Assigned(Say) then
    Say('  release files: looking for those of older releases and older versions in Gitea');
  GwStatus(Say, 'phase', 'space-freed');
  Entries := TJSONArray.Create;
  try
    Db := OpenDb;
    try
      Db.Exec('BEGIN IMMEDIATE', []);
      try
        Newest := Db.Scalar('SELECT r.tag_name FROM `release` r WHERE r.repo_id = ?1 AND EXISTS ' +
          '(SELECT 1 FROM attachment a WHERE a.release_id = r.id) ORDER BY r.created_unix DESC, r.id DESC LIMIT 1',
          [RepoId]);
        if (Newest <> '') and (KeptTags.IndexOf(Newest) < 0) then
        begin
          KeepUntilDone := TStringList.Create;
          KeepUntilDone.CaseSensitive := True;
          KeepUntilDone.Add(Newest);
        end;
        Rows := Db.Query('SELECT a.id, a.uuid, r.tag_name, COALESCE(a.size, 0) FROM attachment a ' +
          'JOIN `release` r ON a.release_id = r.id WHERE r.repo_id = ?1', [RepoId]);
        for I := 0 to High(Rows) do
          if (KeptTags.IndexOf(Rows[I][2]) < 0) and (Rows[I][2] <> Newest) then
          begin
            Inc(Bytes, StrToInt64Def(Rows[I][3], 0));
            Db.Exec('DELETE FROM attachment WHERE id = ?1', [Rows[I][0]]);
            if Rows[I][1] <> '' then
              AddEntry(Entries, GtPath([P.Attachments, Rows[I][1][1], Rows[I][1][2], Rows[I][1]]), 'attachment', Rows[I][1]);
            Count('release files removed');
          end;
        // In a kept release, the files of its older versions go too
        // (GwNewestVersionFiles), as github-to-gitea deletes them before it
        // uploads the newest version's.
        Wanted := TStringList.Create;
        try
          Wanted.CaseSensitive := True;
          for K := 0 to Releases.Count - 1 do
          begin
            if KeptTags.IndexOf(JStr(Releases.Items[K], 'tag_name')) < 0 then
              Continue;
            Assets := JArr(Releases.Items[K], 'assets');
            if (Assets = nil) or not GwNewestVersionFiles(Assets, Wanted, Version) then
              Continue;
            Rows := Db.Query('SELECT a.id, a.uuid, a.name, COALESCE(a.size, 0) FROM attachment a ' +
              'JOIN `release` r ON a.release_id = r.id WHERE r.repo_id = ?1 AND r.tag_name = ?2',
              [RepoId, JStr(Releases.Items[K], 'tag_name')]);
            for I := 0 to High(Rows) do
              if Wanted.IndexOf(Rows[I][2]) < 0 then
              begin
                Inc(Bytes, StrToInt64Def(Rows[I][3], 0));
                Db.Exec('DELETE FROM attachment WHERE id = ?1', [Rows[I][0]]);
                if Rows[I][1] <> '' then
                  AddEntry(Entries, GtPath([P.Attachments, Rows[I][1][1], Rows[I][1][2], Rows[I][1]]), 'attachment', Rows[I][1]);
                Count('release files removed');
              end;
          end;
        finally
          Wanted.Free;
        end;
        if Entries.Count > 0 then
          W.WriteJournal('older release files ' + Full, Entries);
        Db.Exec('COMMIT', []);
      except
        Db.Exec('ROLLBACK', []);
        raise;
      end;
    finally
      Db.Free;
    end;
    if Entries.Count > 0 then
    begin
      if Assigned(Say) then
        Say('  release files: removing ' + IntToStr(Entries.Count) + ' files of older releases first');
      GwStatus(Say, 'toremove', IntToStr(Entries.Count) + ' ' + IntToStr(Bytes));
      // The job page's bar follows these (progress N/M lines).
      W.ProgressDone := 0;
      W.ProgressBytes := 0;
      W.ProgressTotal := Entries.Count;
      try
        Freed := W.FinishJournal;
      finally
        W.ProgressTotal := 0;
      end;
      if Assigned(Say) then
        Say('  release files: ' + IntToStr(Entries.Count) + ' of older releases removed first (' + IntToStr(Freed) +
          ' files freed)' + ifthen_(Newest <> '', '; ' + Newest + '''s stay until the newer ones are fetched', ''));
    end;
  finally
    Entries.Free;
  end;
end;

function TGwImporter.FetchReleases(const Full, Since: string): TJSONArray;
var
  Page, K, N: Integer;
  D: TJSONData;
  Oldest: string;
begin
  if Since = '' then
    Exit(Gh.All('repos/' + Full + '/releases', ''));
  Result := TJSONArray.Create;
  Page := 1;
  try
    repeat
      D := Gh.One('repos/' + Full + '/releases', 'per_page=100&page=' + IntToStr(Page));
      N := 0;
      Oldest := '';
      try
        if D is TJSONArray then
        begin
          N := TJSONArray(D).Count;
          for K := 0 to N - 1 do
          begin
            Result.Add(TJSONArray(D).Items[K].Clone);
            Oldest := JStr(TJSONArray(D).Items[K], 'created_at');
          end;
        end;
      finally
        D.Free;
      end;
      Inc(Page);
    until (N < 100) or ((Oldest <> '') and (Oldest < Since));
  except
    Result.Free;
    raise;
  end;
  if Assigned(Say) then
    Say('  GitHub: releases since ' + Since + ': ' + IntToStr(Result.Count) + ' read');
end;

procedure TGwImporter.FetchPulls(const Full: string; Issues: TJSONArray; Pulls: TJSONObject);
var
  Wanted: TStringList;
  I, K, Page, N, Done: Integer;
  D: TJSONData;
  Num: string;
begin
  Wanted := TStringList.Create;
  try
    Wanted.Sorted := True;
    Wanted.Duplicates := dupIgnore;
    for I := 0 to Issues.Count - 1 do
      if JObj(Issues.Items[I], 'pull_request') <> nil then
        Wanted.Add(JStr(Issues.Items[I], 'number'));
    if Wanted.Count = 0 then
      Exit;
    if Assigned(Say) then
      Say('  GitHub: ' + IntToStr(Wanted.Count) + ' pull requests');
    // OMI_GITHUB_PULLS_ONE_BY_ONE_MAX: how many are still read one by one
    // (default 20; 0 always reads the list - the tests use it).
    if Wanted.Count > StrToIntDef(GetEnvironmentVariable('OMI_GITHUB_PULLS_ONE_BY_ONE_MAX'), 20) then
    begin
      Page := 1;
      repeat
        D := Gh.One('repos/' + Full + '/pulls', 'state=all&sort=updated&direction=desc&per_page=100&page=' + IntToStr(Page));
        N := 0;
        try
          if D is TJSONArray then
          begin
            N := TJSONArray(D).Count;
            for K := 0 to N - 1 do
            begin
              Num := JStr(TJSONArray(D).Items[K], 'number');
              if (Wanted.IndexOf(Num) >= 0) and (Pulls.Find(Num) = nil) then
                Pulls.Add(Num, TJSONArray(D).Items[K].Clone);
            end;
          end;
        finally
          D.Free;
        end;
        if (Page mod 10 = 0) and Assigned(Say) then
          Say('  GitHub: pull requests: ' + IntToStr(Pulls.Count) + ' of ' + IntToStr(Wanted.Count));
        Inc(Page);
      until (N < 100) or (Pulls.Count >= Wanted.Count);
    end;
    Done := 0;
    for I := 0 to Wanted.Count - 1 do
      if Pulls.Find(Wanted[I]) = nil then
      begin
        Pulls.Add(Wanted[I], Gh.One('repos/' + Full + '/pulls/' + Wanted[I], ''));
        Inc(Done);
        if (Done mod 50 = 0) and Assigned(Say) then
          Say('  GitHub: pull requests: ' + IntToStr(Pulls.Count) + ' of ' + IntToStr(Wanted.Count));
      end;
  finally
    Wanted.Free;
  end;
end;

procedure TGwImporter.PullRow(Db: TGwDb; const RepoId, IssueId: string; Number: Int64; Pr: TJSONObject;
  const GitDir: string);
var
  Head, Base: TJSONObject;
  Merged: Boolean;
  Pid, HeadSha: string;
  Repo: TGitRepo;
  Changes: TStringList;
begin
  Head := JObj(Pr, 'head');
  Base := JObj(Pr, 'base');
  Merged := (JStr(Pr, 'merged_at') <> '') or JBool(Pr, 'merged');
  Pid := Db.Scalar('SELECT id FROM pull_request WHERE issue_id = ?1', [IssueId]);
  if Pid <> '' then
    Update(Db, 'pull_request', Pid, ['type', '0', 'status', ifthen_(Merged, '0', '1'), 'issue_id', IssueId,
      'index', IntToStr(Number), 'head_repo_id', RepoId, 'base_repo_id', RepoId, 'head_branch', JStr(Head, 'ref'),
      'base_branch', JStr(Base, 'ref'), 'merge_base', JStr(Base, 'sha'), 'has_merged', B01(Merged),
      'merged_commit_id', ifthen_(Merged, JStr(Pr, 'merge_commit_sha'), ''), 'merger_id', ifthen_(Merged, DoerId, '0'),
      'merged_unix', IntToStr(ifthen_i(Merged, IsoToUnix(JStr(Pr, 'merged_at'), 0), 0))])
  else
    Insert(Db, 'pull_request', ['type', '0', 'status', ifthen_(Merged, '0', '1'), 'issue_id', IssueId,
      'index', IntToStr(Number), 'head_repo_id', RepoId, 'base_repo_id', RepoId, 'head_branch', JStr(Head, 'ref'),
      'base_branch', JStr(Base, 'ref'), 'merge_base', JStr(Base, 'sha'), 'has_merged', B01(Merged),
      'merged_commit_id', ifthen_(Merged, JStr(Pr, 'merge_commit_sha'), ''), 'merger_id', ifthen_(Merged, DoerId, '0'),
      'merged_unix', IntToStr(ifthen_i(Merged, IsoToUnix(JStr(Pr, 'merged_at'), 0), 0)),
      'allow_maintainer_edit', '0', 'flow', '0', 'commits_ahead', '0', 'commits_behind', '0',
      'conflicted_files', 'null', 'changed_protected_files', 'null']);
  // refs/pull/N/head: from the mirror clone; else the head commit, when the repository has it.
  HeadSha := JStr(Head, 'sha');
  // refs/pull/<n>/head when GitHub's fetch did not bring it but has its commit.
  Repo := TGitRepo.Open(GitDir);
  Changes := TStringList.Create;
  try
    if (HeadSha <> '') and (Repo.RefValue('refs/pull/' + IntToStr(Number) + '/head') = '') and
      (Repo.Kind(HeadSha) = GIT_COMMIT) then
    begin
      Changes.Values['refs/pull/' + IntToStr(Number) + '/head'] := LowerCase(HeadSha);
      Repo.SetRefs(Changes);
    end;
  finally
    Changes.Free;
    Repo.Free;
  end;
end;

procedure TGwImporter.ContentRows(Db: TGwDb; const RepoId, GitDir: string; Labels, Milestones, Issues,
  Comments: TJSONArray; Pulls: TJSONObject; Releases: TJSONArray; const Files: TGwFiles; OldFiles: TJSONArray);
var
  T, Lid, Mid, Iid, Cid, Rid, Upd, Color, Title, Tag, Sha, NCommits, CTime, Poster_, Oa, Oaid, Created, Aid,
    Uuid, U: string;
  LabelIds, MsIds, IssueIds, ReleaseIds: TStringList;
  I, K: Integer;
  O, Pr, Ms: TJSONObject;
  Arr: TJSONArray;
  Closed, Draft, Adopted: Boolean;
  Number: Int64;
  IssueIdx, ReleaseIdx, LinkI, LinkR, LinkC: string;
  Lines, Parts: TStringArray;
  Rows: TGtRows;
  Whole: Boolean;
  Repo: TGitRepo;
  CTime64: Int64;
  Subject: string;

  function Valid(const C: string): Boolean;
  var
    J: Integer;
  begin
    Result := Length(C) = 7;
    for J := 2 to Length(C) do
      if not (C[J] in ['0'..'9', 'a'..'f']) then
        Exit(False);
  end;

begin
  T := IntToStr(UnixNow);
  LabelIds := TStringList.Create;
  MsIds := TStringList.Create;
  IssueIds := TStringList.Create;
  ReleaseIds := TStringList.Create;
  Repo := TGitRepo.Open(GitDir);
  try
    // Labels, by GitHub id, else by name.
    for I := 0 to Labels.Count - 1 do
    begin
      O := TJSONObject(Labels.Items[I]);
      Lid := Mapped(Db, 'label', StrToInt64Def(JStr(O, 'id'), 0), Upd);
      if (Lid = '') or not Db.Has('SELECT id FROM label WHERE id = ?1 AND repo_id = ?2', [Lid, RepoId]) then
        Lid := Db.Scalar('SELECT id FROM label WHERE repo_id = ?1 AND name = ?2', [RepoId, JStr(O, 'name')]);
      Color := '#' + LowerCase(StringReplace(ifthen_(JStr(O, 'color') <> '', JStr(O, 'color'), 'ffffff'), '#', '', []));
      if not Valid(Color) then
        Color := '#ffffff';
      if Lid <> '' then
        Update(Db, 'label', Lid, ['name', JStr(O, 'name'), 'color', Color, 'description', JStr(O, 'description'),
          'updated_unix', T])
      else
      begin
        Lid := IntToStr(Insert(Db, 'label', ['repo_id', RepoId, 'org_id', '0', 'name', JStr(O, 'name'), 'exclusive', '0',
          'exclusive_order', '0', 'description', JStr(O, 'description'), 'color', Color, 'archived_unix', '0',
          'created_unix', T, 'updated_unix', T]));
        Count('labels');
      end;
      Remember(Db, 'label', StrToInt64Def(JStr(O, 'id'), 0), RepoId, Lid, '');
      LabelIds.Values[JStr(O, 'name')] := Lid;
    end;
    // Milestones.
    for I := 0 to Milestones.Count - 1 do
    begin
      O := TJSONObject(Milestones.Items[I]);
      Mid := Mapped(Db, 'milestone', StrToInt64Def(JStr(O, 'id'), 0), Upd);
      if (Mid = '') or not Db.Has('SELECT id FROM milestone WHERE id = ?1 AND repo_id = ?2', [Mid, RepoId]) then
        Mid := Db.Scalar('SELECT id FROM milestone WHERE repo_id = ?1 AND name = ?2', [RepoId, JStr(O, 'title')]);
      Closed := JStr(O, 'state') = 'closed';
      if Mid <> '' then
        Update(Db, 'milestone', Mid, ['name', JStr(O, 'title'), 'content', JStr(O, 'description'), 'is_closed', B01(Closed),
          'deadline_unix', IntToStr(IsoToUnix(JStr(O, 'due_on'), StrToInt64(GW_NO_DEADLINE))),
          'closed_date_unix', IntToStr(IsoToUnix(JStr(O, 'closed_at'), 0)),
          'created_unix', IntToStr(IsoToUnix(JStr(O, 'created_at'), UnixNow)),
          'updated_unix', IntToStr(IsoToUnix(JStr(O, 'updated_at'), UnixNow))])
      else
      begin
        Mid := IntToStr(Insert(Db, 'milestone', ['repo_id', RepoId, 'num_issues', '0', 'num_closed_issues', '0',
          'completeness', '0', 'name', JStr(O, 'title'), 'content', JStr(O, 'description'), 'is_closed', B01(Closed),
          'deadline_unix', IntToStr(IsoToUnix(JStr(O, 'due_on'), StrToInt64(GW_NO_DEADLINE))),
          'closed_date_unix', IntToStr(IsoToUnix(JStr(O, 'closed_at'), 0)),
          'created_unix', IntToStr(IsoToUnix(JStr(O, 'created_at'), UnixNow)),
          'updated_unix', IntToStr(IsoToUnix(JStr(O, 'updated_at'), UnixNow))]));
        Count('milestones');
      end;
      Remember(Db, 'milestone', StrToInt64Def(JStr(O, 'id'), 0), RepoId, Mid, '');
      MsIds.Values[JStr(O, 'id')] := Mid;
    end;
    // Issues and pull requests, by GitHub id, else by number.
    for I := 0 to Issues.Count - 1 do
    begin
      O := TJSONObject(Issues.Items[I]);
      Number := StrToInt64Def(JStr(O, 'number'), 0);
      Iid := Mapped(Db, 'issue', StrToInt64Def(JStr(O, 'id'), 0), Upd);
      // Adopted once, adopted for good: the map says so ("adopted:<time>").
      Adopted := (Iid <> '') and (Copy(Upd, 1, 8) = 'adopted:');
      if (Iid = '') or not Db.Has('SELECT id FROM issue WHERE id = ?1 AND repo_id = ?2', [Iid, RepoId]) then
      begin
        Iid := Db.Scalar('SELECT id FROM issue WHERE repo_id = ?1 AND `index` = ?2', [RepoId, IntToStr(Number)]);
        Adopted := Iid <> '';
      end;
      Pr := nil;
      if (Pulls <> nil) and (Pulls.Find(IntToStr(Number)) is TJSONObject) then
        Pr := TJSONObject(Pulls.Find(IntToStr(Number)));
      Poster(Db, JObj(O, 'user'), Poster_, Oa, Oaid);
      Closed := JStr(O, 'state') = 'closed';
      Title := JStr(O, 'title');
      if (Pr <> nil) and JBool(Pr, 'draft') and (Copy(Title, 1, 4) <> 'WIP:') then
        Title := 'WIP: ' + Title;
      Created := IntToStr(IsoToUnix(JStr(O, 'created_at'), UnixNow));
      Ms := JObj(O, 'milestone');
      Mid := '0';
      if (Ms <> nil) and (MsIds.Values[JStr(Ms, 'id')] <> '') then
        Mid := MsIds.Values[JStr(Ms, 'id')];
      if Adopted then
      begin
        // Gitea has it from elsewhere (its own GitHub migration): its text and
        // files stay as Gitea has them; what GitHub says about its state is taken.
        Update(Db, 'issue', Iid, ['name', Copy(Title, 1, 255), 'is_closed', B01(Closed),
          'is_locked', B01(JBool(O, 'locked')), 'milestone_id', Mid,
          'closed_unix', IntToStr(ifthen_i(Closed, IsoToUnix(JStr(O, 'closed_at'), 0), 0))]);
        Count('issues adopted');
      end
      else if Iid <> '' then
      begin
        Update(Db, 'issue', Iid, ['name', Copy(Title, 1, 255), 'content', JStr(O, 'body'), 'is_closed', B01(Closed),
          'is_locked', B01(JBool(O, 'locked')), 'milestone_id', Mid, 'created_unix', Created,
          'updated_unix', IntToStr(IsoToUnix(JStr(O, 'updated_at'), StrToInt64(Created))),
          'closed_unix', IntToStr(ifthen_i(Closed, IsoToUnix(JStr(O, 'closed_at'), 0), 0))]);
        Count('issues updated');
      end
      else
      begin
        Iid := IntToStr(Insert(Db, 'issue', ['repo_id', RepoId, 'index', IntToStr(Number), 'poster_id', Poster_,
          'original_author', Oa, 'original_author_id', Oaid, 'is_pull', B01(Pr <> nil), 'num_comments', '0',
          'priority', '0', 'deadline_unix', '0', 'content_version', '0', 'time_estimate', '0', 'ref', '',
          'name', Copy(Title, 1, 255), 'content', JStr(O, 'body'), 'is_closed', B01(Closed),
          'is_locked', B01(JBool(O, 'locked')), 'milestone_id', Mid, 'created_unix', Created,
          'updated_unix', IntToStr(IsoToUnix(JStr(O, 'updated_at'), StrToInt64(Created))),
          'closed_unix', IntToStr(ifthen_i(Closed, IsoToUnix(JStr(O, 'closed_at'), 0), 0))]));
        if Pr <> nil then
          Count('pull requests')
        else
          Count('issues');
      end;
      Remember(Db, 'issue', StrToInt64Def(JStr(O, 'id'), 0), RepoId, Iid,
        ifthen_(Adopted, 'adopted:', '') + JStr(O, 'updated_at'));
      IssueIds.Values[IntToStr(Number)] := Iid;
      Db.Exec('DELETE FROM issue_label WHERE issue_id = ?1', [Iid]);
      Arr := JArr(O, 'labels');
      if Arr <> nil then
        for K := 0 to Arr.Count - 1 do
          if LabelIds.Values[JStr(Arr.Items[K], 'name')] <> '' then
            Insert(Db, 'issue_label', ['issue_id', Iid, 'label_id', LabelIds.Values[JStr(Arr.Items[K], 'name')]]);
      if Pr <> nil then
        PullRow(Db, RepoId, Iid, Number, Pr, GitDir);
    end;
    // Comments, by GitHub id.
    for I := 0 to Comments.Count - 1 do
    begin
      O := TJSONObject(Comments.Items[I]);
      U := JStr(O, 'issue_url');
      Number := StrToInt64Def(Copy(U, LastDelimiter('/', U) + 1, MaxInt), 0);
      Iid := IssueIds.Values[IntToStr(Number)];
      if Iid = '' then
        Iid := Db.Scalar('SELECT id FROM issue WHERE repo_id = ?1 AND `index` = ?2', [RepoId, IntToStr(Number)]);
      if Iid = '' then
        Continue;
      Cid := Mapped(Db, 'comment', StrToInt64Def(JStr(O, 'id'), 0), Upd);
      if (Cid <> '') and not Db.Has('SELECT id FROM comment WHERE id = ?1', [Cid]) then
        Cid := '';
      // Adopted before: Gitea's text stays.
      if (Cid <> '') and (Copy(Upd, 1, 8) = 'adopted:') then
        Continue;
      Created := IntToStr(IsoToUnix(JStr(O, 'created_at'), UnixNow));
      if Cid = '' then
      begin
        // Already in Gitea from elsewhere: kept as it is, and mapped.
        Cid := Db.Scalar('SELECT id FROM comment WHERE issue_id = ?1 AND type = 0 AND created_unix = ?2 ' +
          'AND id NOT IN (SELECT gitea_id FROM omimap.item_map WHERE kind = ''comment'') ORDER BY id LIMIT 1',
          [Iid, Created]);
        if Cid <> '' then
        begin
          Count('comments adopted');
          Remember(Db, 'comment', StrToInt64Def(JStr(O, 'id'), 0), RepoId, Cid, 'adopted:' + JStr(O, 'updated_at'));
          Continue;
        end;
      end;
      if Cid <> '' then
        Update(Db, 'comment', Cid, ['content', JStr(O, 'body'),
          'updated_unix', IntToStr(IsoToUnix(JStr(O, 'updated_at'), StrToInt64(Created)))])
      else
      begin
        Poster(Db, JObj(O, 'user'), Poster_, Oa, Oaid);
        Cid := IntToStr(Insert(Db, 'comment', ['type', '0', 'poster_id', Poster_, 'original_author', Oa,
          'original_author_id', Oaid, 'issue_id', Iid, 'content', JStr(O, 'body'), 'created_unix', Created,
          'updated_unix', IntToStr(IsoToUnix(JStr(O, 'updated_at'), StrToInt64(Created)))]));
        Count('comments');
      end;
      Remember(Db, 'comment', StrToInt64Def(JStr(O, 'id'), 0), RepoId, Cid, JStr(O, 'updated_at'));
    end;
    // Releases, by GitHub id, else by tag.
    for I := 0 to Releases.Count - 1 do
    begin
      O := TJSONObject(Releases.Items[I]);
      Tag := JStr(O, 'tag_name');
      Rid := Mapped(Db, 'release', StrToInt64Def(JStr(O, 'id'), 0), Upd);
      if (Rid = '') or not Db.Has('SELECT id FROM release WHERE id = ?1 AND repo_id = ?2', [Rid, RepoId]) then
        Rid := Db.Scalar('SELECT id FROM release WHERE repo_id = ?1 AND tag_name = ?2', [RepoId, Tag]);
      Sha := '';
      NCommits := '0';
      CTime := '0';
      if Tag <> '' then
      begin
        Sha := Repo.RefValue('refs/tags/' + Tag);
        if Sha <> '' then
          Sha := Repo.PeelToCommit(Sha);
      end;
      if Sha <> '' then
      begin
        NCommits := IntToStr(Repo.CountCommits(Sha));
        if Repo.CommitInfo(Sha, CTime64, Subject) then
          CTime := IntToStr(CTime64);
      end;
      Poster(Db, JObj(O, 'author'), Poster_, Oa, Oaid);
      Draft := JBool(O, 'draft');
      if StrToInt64Def(CTime, 0) = 0 then
        CTime := IntToStr(IsoToUnix(JStr(O, 'created_at'), UnixNow));
      if Rid <> '' then
        Update(Db, 'release', Rid, ['tag_name', Tag, 'lower_tag_name', LowerCase(Tag),
          'target', JStr(O, 'target_commitish'), 'title', JStr(O, 'name'), 'note', JStr(O, 'body'), 'sha1', Sha,
          'num_commits', ifthen_(NCommits <> '', NCommits, '0'), 'is_draft', B01(Draft),
          'is_prerelease', B01(JBool(O, 'prerelease')), 'is_tag', '0', 'created_unix', CTime,
          'published_unix', IntToStr(ifthen_i(Draft, 0, IsoToUnix(ifthen_(JStr(O, 'published_at') <> '',
          JStr(O, 'published_at'), JStr(O, 'created_at')), UnixNow)))])
      else
      begin
        Rid := IntToStr(Insert(Db, 'release', ['repo_id', RepoId, 'publisher_id', Poster_, 'original_author', Oa,
          'original_author_id', Oaid, 'tag_name', Tag, 'lower_tag_name', LowerCase(Tag),
          'target', JStr(O, 'target_commitish'), 'title', JStr(O, 'name'), 'note', JStr(O, 'body'), 'sha1', Sha,
          'num_commits', ifthen_(NCommits <> '', NCommits, '0'), 'is_draft', B01(Draft),
          'is_prerelease', B01(JBool(O, 'prerelease')), 'is_tag', '0', 'created_unix', CTime,
          'published_unix', IntToStr(ifthen_i(Draft, 0, IsoToUnix(ifthen_(JStr(O, 'published_at') <> '',
          JStr(O, 'published_at'), JStr(O, 'created_at')), UnixNow)))]));
        Count('releases');
      end;
      Remember(Db, 'release', StrToInt64Def(JStr(O, 'id'), 0), RepoId, Rid,
        ifthen_(JStr(O, 'updated_at') <> '', JStr(O, 'updated_at'), JStr(O, 'published_at')));
      ReleaseIds.Values[JStr(O, 'id')] := Rid;
    end;
    // The files of the releases RELEASE_ASSETS_KEEP does not keep go, in this
    // transaction: their rows now, their files by the journal once nothing
    // refers to them. Only this repository's releases, only with a kept set.
    if (KeptTags <> nil) and (KeptTags.Count > 0) then
    begin
      // The release kept until now (KeepUntilDone) goes only when every kept
      // release was fetched whole and has files - in Gitea or fetched now. A
      // release GitHub is still attaching files to has none yet.
      Whole := not KeptIncomplete;
      for K := 0 to KeptTags.Count - 1 do
        if Whole and not Db.Has('SELECT 1 FROM attachment a JOIN `release` r ON a.release_id = r.id ' +
          'WHERE r.repo_id = ?1 AND r.tag_name = ?2', [RepoId, KeptTags[K]]) then
        begin
          Whole := False;
          for I := 0 to High(Files) do
            if (Files[I].Kind = 'asset') and (ReleaseTag(Releases, Files[I].Release) = KeptTags[K]) then
              Whole := True;
        end;
      if not Whole and (KeepUntilDone <> nil) and Assigned(Say) then
        Say('  release files: ' + KeepUntilDone[0] + '''s kept - the newest release''s files are not all here yet');
      Rows := Db.Query('SELECT a.id, a.uuid, r.tag_name FROM attachment a JOIN `release` r ON a.release_id = r.id ' +
        'WHERE r.repo_id = ?1', [RepoId]);
      for K := 0 to High(Rows) do
        if (KeptTags.IndexOf(Rows[K][2]) < 0) and
          (Whole or (KeepUntilDone = nil) or (KeepUntilDone.IndexOf(Rows[K][2]) < 0)) then
        begin
          Db.Exec('DELETE FROM attachment WHERE id = ?1', [Rows[K][0]]);
          if Rows[K][1] <> '' then
            AddEntry(OldFiles, GtPath([P.Attachments, Rows[K][1][1], Rows[K][1][2], Rows[K][1]]), 'attachment', Rows[K][1]);
          Count('release files removed');
        end;
    end;
    // Files: release assets and the files linked from bodies.
    for I := 0 to High(Files) do
    begin
      if Files[I].Kind = 'asset' then
      begin
        LinkR := ReleaseIds.Values[IntToStr(Files[I].Release)];
        if LinkR = '' then
          Continue;
        LinkI := '0';
        LinkC := '0';
      end
      else
      begin
        LinkR := '0';
        LinkI := IssueIds.Values[IntToStr(Files[I].Number)];
        if LinkI = '' then
          LinkI := Db.Scalar('SELECT id FROM issue WHERE repo_id = ?1 AND `index` = ?2', [RepoId, IntToStr(Files[I].Number)]);
        LinkC := '0';
        if Files[I].ParentKind = 'comment' then
        begin
          LinkC := Mapped(Db, 'comment', Files[I].Parent, Upd);
          if LinkC = '' then
            LinkC := '0';
        end;
        if LinkI = '' then
          Continue;
      end;
      Aid := Mapped(Db, Files[I].Kind, Files[I].GithubId, Upd);
      if Aid <> '' then
      begin
        Uuid := Db.Scalar('SELECT uuid FROM attachment WHERE id = ?1', [Aid]);
        if Uuid <> '' then
        begin
          Db.Exec('DELETE FROM attachment WHERE id = ?1', [Aid]);
          AddEntry(OldFiles, GtPath([P.Attachments, Uuid[1], Uuid[2], Uuid]), 'attachment', Uuid);
        end;
      end;
      Aid := IntToStr(Insert(Db, 'attachment', ['uuid', Files[I].Uuid, 'repo_id', RepoId, 'uploader_id', '0',
        'name', Files[I].Name, 'download_count', IntToStr(Files[I].Downloads), 'size', IntToStr(Files[I].Size),
        'created_unix', ifthen_(Files[I].Created > 0, IntToStr(Files[I].Created), T),
        'release_id', LinkR, 'issue_id', LinkI, 'comment_id', LinkC]));
      Remember(Db, Files[I].Kind, Files[I].GithubId, RepoId, Aid, Files[I].Key);
      Count('attachments');
    end;
    // Tags without a release: Gitea's SyncReleasesWithTags.
    Lines := RefLines(GitDir, 'refs/tags/', True);
    for I := 0 to High(Lines) do
    begin
      Parts := Lines[I].Split([#0]);
      if Length(Parts) < 2 then
        Continue;
      // Split leaves out empty fields at the end (a lightweight tag has no *objectname).
      while Length(Parts) < 5 do
      begin
        SetLength(Parts, Length(Parts) + 1);
        Parts[High(Parts)] := '';
      end;
      Tag := Copy(Parts[0], Length('refs/tags/') + 1, MaxInt);
      if Db.Has('SELECT id FROM release WHERE repo_id = ?1 AND lower_tag_name = ?2', [RepoId, LowerCase(Tag)]) then
        Continue;
      Sha := ifthen_(Parts[2] <> '', Parts[2], Parts[1]);
      CTime := ifthen_(Parts[4] <> '', Parts[4], ifthen_(Parts[3] <> '', Parts[3], '0'));
      Insert(Db, 'release', ['repo_id', RepoId, 'publisher_id', '0', 'tag_name', Tag, 'lower_tag_name', LowerCase(Tag),
        'original_author', '', 'original_author_id', '0', 'target', '', 'title', '', 'note', '', 'sha1', Sha,
        'num_commits', '-1', 'is_draft', '0', 'is_prerelease', '0', 'is_tag', '1', 'created_unix', CTime,
        'published_unix', CTime]);
      Count('tags');
    end;
    IssueIdx := '';
    ReleaseIdx := '';
  finally
    LabelIds.Free;
    MsIds.Free;
    IssueIds.Free;
    ReleaseIds.Free;
    Repo.Free;
  end;
end;

procedure TGwImporter.Counters(Db: TGwDb; const RepoId, OwnerId: string);
var
  Mx, GitDir: string;
  GitSize, Lfs: Int64;
begin
  Db.Exec('UPDATE issue SET num_comments = (SELECT COUNT(*) FROM comment WHERE comment.issue_id = issue.id ' +
    'AND comment.type IN (0, 22)) WHERE repo_id = ?1', [RepoId]);
  Db.Exec('UPDATE label SET num_issues = (SELECT COUNT(*) FROM issue_label WHERE label_id = label.id), ' +
    'num_closed_issues = (SELECT COUNT(*) FROM issue_label il JOIN issue i ON i.id = il.issue_id ' +
    'WHERE il.label_id = label.id AND i.is_closed = 1) WHERE repo_id = ?1', [RepoId]);
  Db.Exec('UPDATE milestone SET num_issues = (SELECT COUNT(*) FROM issue WHERE milestone_id = milestone.id), ' +
    'num_closed_issues = (SELECT COUNT(*) FROM issue WHERE milestone_id = milestone.id AND is_closed = 1) ' +
    'WHERE repo_id = ?1', [RepoId]);
  Db.Exec('UPDATE milestone SET completeness = CASE WHEN num_issues = 0 THEN (CASE WHEN is_closed = 1 THEN 100 ' +
    'ELSE 0 END) ELSE 100 * num_closed_issues / num_issues END WHERE repo_id = ?1', [RepoId]);
  Db.Exec('UPDATE repository SET ' +
    'num_issues = (SELECT COUNT(*) FROM issue WHERE repo_id = repository.id AND is_pull = 0), ' +
    'num_closed_issues = (SELECT COUNT(*) FROM issue WHERE repo_id = repository.id AND is_pull = 0 AND is_closed = 1), ' +
    'num_pulls = (SELECT COUNT(*) FROM issue WHERE repo_id = repository.id AND is_pull = 1), ' +
    'num_closed_pulls = (SELECT COUNT(*) FROM issue WHERE repo_id = repository.id AND is_pull = 1 AND is_closed = 1), ' +
    'num_milestones = (SELECT COUNT(*) FROM milestone WHERE repo_id = repository.id), ' +
    'num_closed_milestones = (SELECT COUNT(*) FROM milestone WHERE repo_id = repository.id AND is_closed = 1), ' +
    'num_watches = (SELECT COUNT(*) FROM watch WHERE repo_id = repository.id AND mode <> 2), ' +
    'num_stars = (SELECT COUNT(*) FROM star WHERE repo_id = repository.id) WHERE id = ?1', [RepoId]);
  Mx := Db.Scalar('SELECT COALESCE(MAX(`index`), 0) FROM issue WHERE repo_id = ?1', [RepoId]);
  if not Db.Has('SELECT group_id FROM issue_index WHERE group_id = ?1', [RepoId]) then
    Db.Exec('INSERT INTO issue_index (group_id, max_index) VALUES (?1, ?2)', [RepoId, Mx])
  else
    Db.Exec('UPDATE issue_index SET max_index = MAX(max_index, ?1) WHERE group_id = ?2', [Mx, RepoId]);
  GitDir := GtPath([P.RepoRoot, Db.Scalar('SELECT lower(owner_name) FROM repository WHERE id = ?1', [RepoId]),
    Db.Scalar('SELECT lower_name FROM repository WHERE id = ?1', [RepoId]) + '.git']);
  GitSize := PathBytes(GitDir);
  Lfs := StrToInt64Def(Db.Scalar('SELECT COALESCE(SUM(size), 0) FROM lfs_meta_object WHERE repository_id = ?1',
    [RepoId]), 0);
  Db.Exec('UPDATE repository SET git_size = ?1, lfs_size = ?2, size = ?3 WHERE id = ?4',
    [IntToStr(GitSize), IntToStr(Lfs), IntToStr(GitSize + Lfs), RepoId]);
  Db.Exec('UPDATE user SET num_repos = (SELECT COUNT(*) FROM repository WHERE owner_id = user.id) WHERE id = ?1', [OwnerId]);
end;

procedure TGwImporter.ImportRepo(Gr: TJSONObject; const OwnerId, OwnerType, OwnerName: string);
var
  Full, Name, LowerOwner, GitDir, WikiDir, Since, Existing, Src, WikiSrc, Params, CParams, Started: string;
  Db: TGwDb;
  Rows: TGtRows;
  Labels, Milestones, Issues, Comments, Releases, NewFiles, OldFiles, Both: TJSONArray;
  Pulls: TJSONObject;
  I, K: Integer;
  IsNew, WikiNew, Committed: Boolean;
  Files: TGwFiles;
  RepoId: string;
  N: Int64;
begin
  Committed := True;
  Files := nil;
  Full := JStr(Gr, 'full_name');
  Name := JStr(Gr, 'name');
  if not GtNameIsSafe(Name) then
    raise EGw.Create('not a Gitea repository name: ''' + Name + '''');
  LowerOwner := LowerCase(OwnerName);
  GitDir := GtPath([P.RepoRoot, LowerOwner, LowerCase(Name) + '.git']);
  WikiDir := GtPath([P.RepoRoot, LowerOwner, LowerCase(Name) + '.wiki.git']);
  if Assigned(Say) then
    Say(Full + ':');
  CheckFolderName(GtPath([P.RepoRoot, LowerOwner]), LowerCase(Name) + '.wiki.git');
  CheckFolderName(GtPath([P.RepoRoot, LowerOwner]), LowerCase(Name) + '.git');
  Db := OpenDb;
  try
    Rows := Db.Query('SELECT gitea_id, COALESCE(since, '''') FROM omimap.repo_map WHERE github_id = ?1', [JStr(Gr, 'id')]);
    Since := '';
    if Length(Rows) > 0 then
      Since := Rows[0][1];
    Existing := Db.Scalar('SELECT id FROM repository WHERE owner_id = ?1 AND lower_name = ?2', [OwnerId, LowerCase(Name)]);
    if Existing = '' then
      Since := ''
    else if Since = '' then
    begin
      // In Gitea already, from elsewhere (its own GitHub migration), and never
      // imported by Omi: start from the newest issue or comment Gitea has, a
      // day earlier for clocks and late edits - not from ten years of history.
      // What overlaps is adopted (AdoptedIssue, AdoptedComment).
      N := StrToInt64Def(Db.Scalar('SELECT MAX(m) FROM (' +
        'SELECT MAX(updated_unix) AS m FROM issue WHERE repo_id = ?1 UNION ALL ' +
        'SELECT MAX(c.updated_unix) FROM comment c JOIN issue i ON c.issue_id = i.id WHERE i.repo_id = ?1)',
        [Existing]), 0);
      if N > 86400 then
      begin
        Since := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', UnixToDateTime(N - 86400));
        if Assigned(Say) then
          Say('  Gitea has this repository already: what changed on GitHub since ' + Since);
      end;
    end;
  finally
    Db.Free;
  end;
  // Ten minutes before this import began: an item changed while it is read is read again.
  Started := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', LocalTimeToUniversal(Now) - 10 / (24 * 60));
  // GitHub first, outside the transaction: nothing of Gitea is changed yet.
  if Assigned(Say) then
    Say('  GitHub: labels, milestones, issues and comments');
  GwStatus(Say, 'phase', 'issues');
  Labels := Gh.All('repos/' + Full + '/labels', '');
  Milestones := Gh.All('repos/' + Full + '/milestones', 'state=all');
  Params := 'state=all&sort=updated&direction=asc';
  CParams := 'sort=updated&direction=asc';
  if Since <> '' then
  begin
    Params := Params + '&since=' + UrlEncodeValue(Since);
    CParams := CParams + '&since=' + UrlEncodeValue(Since);
  end;
  Issues := Gh.All('repos/' + Full + '/issues', Params);
  GwStatus(Say, 'phase', 'comments');
  Comments := Gh.All('repos/' + Full + '/issues/comments', CParams);
  Pulls := TJSONObject.Create;
  NewFiles := TJSONArray.Create;
  OldFiles := TJSONArray.Create;
  Releases := nil;
  Src := '';
  WikiSrc := '';
  try
    GwStatus(Say, 'phase', 'pull-requests');
    FetchPulls(Full, Issues, Pulls);
    GwStatus(Say, 'phase', 'releases');
    Releases := FetchReleases(Full, Since);
    DecideKeptTags(Releases);
    FreeReleaseSpace(Existing, Full, Releases);
    try
      GwStatus(Say, 'phase', 'git');
      Src := PrepareGit(GitDir, Gh.GitUrl(Full, False), False, IsNew);
      // Stop is asked before every GitHub request, and here too: after the
      // API, git and the files are fetched with no request of its own, and a
      // Stop pressed then used to go on to write Gitea's database.
      GwCheckStop;
      WikiNew := False;
      if JBool(Gr, 'has_wiki') then
        WikiSrc := PrepareGit(WikiDir, Gh.GitUrl(Full, True), True, WikiNew);
      GwCheckStop;
      // Rows that are already in this Gitea - a repository Gitea's own GitHub
      // migration made - are adopted, not copied again (Adopt* below).
      AdoptRepoId := Existing;
      GwStatus(Say, 'phase', 'attachments');
      Files := Download(Releases, Issues, Comments);
      GwCheckStop;
      for I := 0 to High(Files) do
        AddEntry(NewFiles, GtPath([P.Attachments, Files[I].Uuid[1], Files[I].Uuid[2], Files[I].Uuid]),
          'attachment', Files[I].Uuid);
      Committed := False;
      GwStatus(Say, 'phase', 'save');
      if Assigned(Say) then
        Say('  writing to Gitea: ' + IntToStr(Issues.Count) + ' issues and pull requests, ' + IntToStr(Comments.Count) +
          ' comments, ' + IntToStr(Releases.Count) + ' releases, ' + IntToStr(Length(Files)) + ' files');
      Db := OpenDb;
      try
        Db.Exec('BEGIN IMMEDIATE', []);
        try
          // Folders and files that end up unused are removed by the journal.
          if IsNew then
            AddEntry(NewFiles, GitDir, 'repo', LowerOwner + '/' + LowerCase(Name));
          if WikiNew then
            AddEntry(NewFiles, WikiDir, 'repo', LowerOwner + '/' + LowerCase(Name));
          W.WriteJournal('import ' + Full, NewFiles);
          if IsNew and not GtRenameDir(Src, GitDir) then
            raise EGw.Create('cannot move ' + Src + ' to ' + GitDir);
          if WikiNew and not GtRenameDir(WikiSrc, WikiDir) then
            raise EGw.Create('cannot move ' + WikiSrc + ' to ' + WikiDir);
          RepoId := RepoRows(Db, Gr, OwnerId, OwnerType, OwnerName, GitDir, Existing);
          ContentRows(Db, RepoId, GitDir, Labels, Milestones, Issues, Comments, Pulls, Releases, Files, OldFiles);
          Counters(Db, RepoId, OwnerId);
          Db.Exec('INSERT OR REPLACE INTO omimap.repo_map (github_id, gitea_id, full_name, since) VALUES (?1, ?2, ?3, ?4)',
            [JStr(Gr, 'id'), RepoId, Full, Started]);
          if OldFiles.Count > 0 then
          begin
            Both := TJSONArray(NewFiles.Clone);
            try
              for K := 0 to OldFiles.Count - 1 do
                Both.Add(OldFiles.Items[K].Clone);
              W.WriteJournal('import ' + Full, Both);
            finally
              Both.Free;
            end;
          end;
          Db.Exec('COMMIT', []);
          Committed := True;
          if Assigned(Say) then
            Say('  written to Gitea');
        except
          // A new folder renamed into place has no row now: the journal removes it.
          Db.Exec('ROLLBACK', []);
          raise;
        end;
      finally
        Db.Free;
      end;
    finally
      // Files fetched for rows that were never written: not left behind.
      if not Committed then
        for I := 0 to High(Files) do
          if Files[I].Uuid <> '' then
            DeleteFile(GtPath([P.Attachments, Files[I].Uuid[1], Files[I].Uuid[2], Files[I].Uuid]));
      N := 0;
      if (Src <> '') and (Pos('/.omi-new-', Src) > 0) and DirectoryExists(Src) then
        RemoveTree(Src, N);
      if (WikiSrc <> '') and (Pos('/.omi-new-', WikiSrc) > 0) and DirectoryExists(WikiSrc) then
        RemoveTree(WikiSrc, N);
      W.FinishJournal;
    end;
  finally
    Labels.Free;
    Milestones.Free;
    Issues.Free;
    Comments.Free;
    Releases.Free;
    Pulls.Free;
    NewFiles.Free;
    OldFiles.Free;
  end;
  Count('repositories');
end;

function TGwImporter.Run(const Name, OnlyRepos: string): TJSONObject;
var
  S, I, K: Integer;
  Info, Org: TJSONData;
  IsOrg: Boolean;
  Login, Path, Q, OwnerId, OwnerType, OwnerName, Full: string;
  All_, Repos: TJSONArray;
  Want, Skip, Missing: TStringList;
  Parts: TStringArray;
  Db: TGwDb;
  NewFiles: TJSONArray;
  Gr: TJSONObject;
  Names: TJSONArray;
begin
  if not GtNameIsSafe(Name) then
    raise EGw.Create('not a GitHub or Gitea name: ''' + Name + '''');
  CheckFolderName(P.RepoRoot, LowerCase(Name));
  Want := TStringList.Create;
  Skip := GwExcludeList(ExcludeFile);
  Missing := TStringList.Create;
  Info := nil;
  All_ := nil;
  Repos := TJSONArray.Create;
  try
    Parts := OnlyRepos.Split([' ', ','], TStringSplitOptions.ExcludeEmpty);
    for I := 0 to High(Parts) do
    begin
      if not GtNameIsSafe(Parts[I]) then
        raise EGw.Create('not a repository name: ''' + Parts[I] + '''');
      Want.Add(LowerCase(Parts[I]));
    end;
    for I := 0 to Skip.Count - 1 do
      Skip[I] := LowerCase(Skip[I]);
    Info := Gh.Get('users/' + Name, '', S);
    if (S <> 200) or not (Info is TJSONObject) then
      raise EGw.Create(Name + ': no such organization or user on GitHub (' + IntToStr(S) + ')');
    IsOrg := JStr(Info, 'type') = 'Organization';
    Login := JStr(Info, 'login');
    if IsOrg then
    begin
      Org := Gh.Get('orgs/' + Login, '', S);
      if (S = 200) and (Org is TJSONObject) then
        for I := 0 to TJSONObject(Org).Count - 1 do
          if TJSONObject(Info).Find(TJSONObject(Org).Names[I]) = nil then
            TJSONObject(Info).Add(TJSONObject(Org).Names[I], TJSONObject(Org).Items[I].Clone);
      Org.Free;
      Path := 'orgs/' + Login + '/repos';
      Q := 'type=all&sort=full_name';
    end
    else if SameText(Gh.Login, Login) then
    begin
      // The token's own user: its private repositories too.
      Path := 'user/repos';
      Q := 'affiliation=owner&visibility=all&sort=full_name';
    end
    else
    begin
      Path := 'users/' + Login + '/repos';
      Q := 'type=owner&sort=full_name';
    end;
    All_ := Gh.All(Path, Q);
    for I := 0 to All_.Count - 1 do
    begin
      Gr := TJSONObject(All_.Items[I]);
      if not SameText(JStr(JObj(Gr, 'owner'), 'login'), Login) then
        Continue;
      Full := JStr(Gr, 'full_name');
      if (Want.Count > 0) and (Want.IndexOf(LowerCase(JStr(Gr, 'name'))) < 0) then
        Continue;
      // The repositories no longer synced (the exclude file, shared with
      // github-to-gitea): left out, even when asked for by name.
      if Skip.IndexOf(LowerCase(Full)) >= 0 then
      begin
        if Assigned(Say) then
          Say(Full + ': not synced any more (in ' + ExcludeFile + '), left out');
        Count('left out');
        if Want.IndexOf(LowerCase(JStr(Gr, 'name'))) >= 0 then
          Want.Delete(Want.IndexOf(LowerCase(JStr(Gr, 'name'))));
        Continue;
      end;
      Repos.Add(Gr.Clone);
      if Want.IndexOf(LowerCase(JStr(Gr, 'name'))) >= 0 then
        Want.Delete(Want.IndexOf(LowerCase(JStr(Gr, 'name'))));
    end;
    if (Length(Parts) > 0) and (Want.Count > 0) then
      raise EGw.Create('not on GitHub under ' + Name + ': ' + StringReplace(Trim(Want.Text), LineEnding, ', ',
        [rfReplaceAll]));
    Db := OpenDb;
    NewFiles := TJSONArray.Create;
    try
      if DoerName <> '' then
      begin
        DoerId := Db.Scalar('SELECT id FROM user WHERE lower_name = ?1 AND type = 0', [LowerCase(DoerName)]);
        if DoerId = '' then
          raise EGw.Create('no Gitea user ' + DoerName + ' to import as (GITEA_DOER)');
      end
      else
      begin
        DoerId := Db.Scalar('SELECT id FROM user WHERE is_admin = 1 AND type = 0 ORDER BY id LIMIT 1', []);
        if DoerId = '' then
          raise EGw.Create('no Gitea administrator to import as; set GITEA_DOER');
      end;
      AppPath := FindAppPath(P, AppPath);
      Db.Exec('BEGIN IMMEDIATE', []);
      try
        EnsureOwner(Db, TJSONObject(Info), IsOrg, OwnerId, OwnerType, NewFiles);
        W.WriteJournal('import owner ' + Name, NewFiles);
        Db.Exec('INSERT OR REPLACE INTO omimap.owner_map (github_id, gitea_id, login) VALUES (?1, ?2, ?3)',
          [JStr(Info, 'id'), OwnerId, Login]);
        Db.Exec('COMMIT', []);
      except
        Db.Exec('ROLLBACK', []);
        W.FinishJournal;
        raise;
      end;
      W.FinishJournal;
      OwnerName := Db.Scalar('SELECT name FROM user WHERE id = ?1', [OwnerId]);
    finally
      NewFiles.Free;
      Db.Free;
    end;
    Names := TJSONArray.Create;
    for I := 0 to Repos.Count - 1 do
    begin
      GwProgress(Say, I, Repos.Count, 'repository: ' + JStr(Repos.Items[I], 'full_name'));
      GwStatus(Say, 'repos', IntToStr(I + 1) + '/' + IntToStr(Repos.Count));
      GwStatus(Say, 'repo', JStr(Repos.Items[I], 'full_name'));
      ImportRepo(TJSONObject(Repos.Items[I]), OwnerId, OwnerType, OwnerName);
      Names.Add(JStr(Repos.Items[I], 'name'));
    end;
    GwProgress(Say, Repos.Count, Repos.Count, 'repositories imported');
    Result := TJSONObject.Create;
    Result.Add('owner', OwnerName);
    Result.Add('repositories', Names);
    Result.Add('stats', Stats.Clone);
    if Assigned(Say) then
      Say('Imported ' + Name + ': ' + Stats.AsJSON);
    K := 0;
    if K = 0 then;
  finally
    Want.Free;
    Skip.Free;
    Missing.Free;
    Info.Free;
    All_.Free;
    Repos.Free;
  end;
end;

function GwTestGithubToken(const TokenFile, Api: string; out Login, Remaining, Limit, Detail: string): string;
var
  Gh: TGhClient;
  Token, Body, Ct, Cd: string;
  Status: Integer;
  D: TJSONData;
begin
  Login := '';
  Remaining := '';
  Limit := '';
  Detail := '';
  Token := '';
  if (TokenFile <> '') and FileExists(TokenFile) then
    Token := Trim(ReadSmallFile(TokenFile));
  if Token = '' then
    Exit('none');
  Gh := TGhClient.Create(Token, Api, Api, '', '', nil);
  try
    try
      if not Gh.Fetch(Gh.Api + '/user', 'application/vnd.github+json', nil, Status, Body, Ct, Cd) then
      begin
        Detail := Body;
        Exit('unreachable');
      end;
    except
      on E: Exception do
      begin
        Detail := E.Message;
        Exit('unreachable');
      end;
    end;
    Remaining := Gh.LastRemaining;
    Limit := Gh.LastLimit;
    if Status = 401 then
      Exit('rejected');
    D := nil;
    try
      try
        if Trim(Body) <> '' then
          D := GetJSON(Body);
      except
        D := nil;
      end;
      if (Status = 200) and (D is TJSONObject) then
      begin
        Login := JStr(D, 'login');
        Exit('ok');
      end;
      // 403 / 429: the hour's requests used up, or a blocked token. GitHub's
      // own message says which; it never carries the token.
      // What GitHub answered (403 for a used-up hour), not Fetch's 429.
      Detail := IntToStr(Gh.LastHttpStatus);
      if (D is TJSONObject) and (JStr(D, 'message') <> '') then
        Detail := Detail + ' ' + Copy(JStr(D, 'message'), 1, 300);
      Result := 'refused';
    finally
      D.Free;
    end;
  finally
    Gh.Free;
  end;
end;

function GwImportFull(const P: TGtPaths; const Owner, Repos, TokenFile, Api, Web, GitRoot, FileHosts, Doer,
  AppPath, ExcludeFile, PidFile, GitProgram, GitFetch: string; Say: TGwSay): TJSONObject;
var
  Gh: TGhClient;
  W: TGwWriter;
  Imp: TGwImporter;
  Token, Mode: string;
begin
  Token := '';
  Mode := GwGitFetchMode(GitFetch);
  GitExe := GwFindGit(GitProgram);
  if (Mode = 'program') and (GitExe = '') then
    raise EGw.Create('GIT_FETCH=program, and no git program: set GIT, or install git.');
  if (TokenFile <> '') and FileExists(TokenFile) then
    Token := Trim(ReadSmallFile(TokenFile));
  // Without a token GitHub answers 60 requests an hour: a big repository is
  // then many hours of waiting, and the log should say why from the start.
  GwStatus(Say, 'started', IntToStr(DateTimeToUnix(LocalTimeToUniversal(Now))));
  if (Token = '') and Assigned(Say) then
    Say('GitHub: no token - 60 requests an hour, so a big repository takes hours. Set GITHUB_TOKEN in Settings.');
  Gh := TGhClient.Create(Token, Api, Web, GitRoot, FileHosts, Say);
  try
    W := TGwWriter.Enter(P, PidFile, Say);
    try
      Imp := TGwImporter.Create(P, Gh, W, Say);
      try
        Imp.DoerName := Doer;
        Imp.AppPath := AppPath;
        Imp.ExcludeFile := ExcludeFile;
        Imp.FetchMode := Mode;
        Result := Imp.Run(Owner, Repos);
      finally
        Imp.Free;
      end;
    finally
      W.Free;
    end;
  finally
    Gh.Free;
  end;
end;
