{
  Omi - git in Pascal
  ===================

  What the GitHub import needs of git, without the git program, so it runs
  where only Omi runs (an Amiga with the Gitea folder on its disk):

  - a bare repository: made as `git clone --mirror` makes it (HEAD, config,
    description, info/exclude, objects/, refs/), its objects read from the
    packs (.idx version 2) and the loose objects, its refs from packed-refs
    and refs/;
  - fetching over git's smart HTTP protocol, version 0/1: GET
    info/refs?service=git-upload-pack, then one POST of git-upload-pack with
    the wants (the advertised refs/heads/*, refs/tags/* and refs/pull/* this
    repository lacks), the haves (its ref tips) and done, the pack received
    on side band 1 of side-band-64k;
  - the received pack stored as objects/pack/pack-<sha1>.pack with its .idx
    version 2 written here: every object inflated (paszlib), hashed (SHA-1),
    OFS_DELTA and REF_DELTA resolved inside the pack. thin-pack is not asked
    for, so a pack whose delta base is not in it is refused, never stored;
  - the refs written into packed-refs as a mirror fetch does (forced, nothing
    pruned), HEAD of a new repository from the server's symref, and
    `git update-server-info`'s info/refs and objects/info/packs.

  Everything is streamed: the pack goes from the network to its file, an
  object that is not a delta is hashed as it is inflated, and an object a
  delta needs whole is kept in memory only up to GIT_MEM_LIMIT bytes, else in
  a scratch file beside the pack. Sizes and offsets are Int64; a file larger
  than the platform can address (2 GiB on AmigaOS 3) is refused.
}

unit omigit;

{$MODE OBJFPC}
{$H+}

interface

uses
  SysUtils, Classes, contnrs, sha1, zbase, zinflate, crc, fphttpclient,
  {$IFNDEF HASAMIGA}
  opensslsockets,
  {$ENDIF}
  Generics.Collections, omigitea;

const
  GIT_COMMIT = 1;
  GIT_TREE = 2;
  GIT_BLOB = 3;
  GIT_TAG = 4;
  GIT_OFS_DELTA = 6;
  GIT_REF_DELTA = 7;

type
  EGit = class(Exception);
  TGitSay = procedure(const Line: string) of object;
  TGitSha = TSHA1Digest;

  // One pack and its .idx version 2, read by seeking.
  TGitPack = class
  public
    PackPath, IdxPath: string;
    Count: Cardinal;
    Fanout: array[0..255] of Cardinal;
    Idx, Pack: TFileStream;
    constructor Open(const AIdxPath: string);
    destructor Destroy; override;
    function Find(const Sha: TGitSha; out Offset: Int64): Boolean;
  end;
  TGitPackList = specialize TObjectList<TGitPack>;
  TGitParents = specialize TDictionary<string, string>;

  TGitRepo = class
  private
    FDir: string;
    FPacks: TGitPackList;
    FParents: TGitParents;
    function ReadPacked(const Sha: TGitSha; out Kind: Integer; Dest: TStream; Depth: Integer): Boolean;
    function ReadLoose(const Hex: string; out Kind: Integer; Dest: TStream): Boolean;
    function ReadInto(const Hex: string; out Kind: Integer; Dest: TStream; Depth: Integer): Boolean;
    procedure LooseRefs(const Dir, Prefix: string; Into: TStringList; Index: TFPStringHashTable);
  public
    constructor Open(const Dir: string);
    destructor Destroy; override;
    // The packs again (after a fetch added one).
    procedure Rescan;
    function Has(const Hex: string): Boolean;
    // A whole object in memory - for commits and tags.
    function Read(const Hex: string; out Kind: Integer; out Data: RawByteString): Boolean;
    function Kind(const Hex: string): Integer;
    // Every ref, "refs/...=<sha>", sorted by name byte for byte; loose refs
    // beat packed ones.
    function Refs: TStringList;
    function RefValue(const Name: string): string;
    // Tags followed to what they point at, until a commit ('' when it is not one).
    function PeelToCommit(const Hex: string): string;
    // Tags followed one level (the tag's object), '' when Hex is not a tag.
    function TagTarget(const Hex: string): string;
    // A commit's committer time and its subject (git's %(contents:subject)).
    function CommitInfo(const Hex: string; out Time: Int64; out Subject: string): Boolean;
    // The commits reachable from Hex (`git rev-list --count`).
    function CountCommits(const Hex: string): Int64;
    // Names set to values ("refs/...=<sha>"), forced, in packed-refs; a loose
    // ref of the same name is removed. Nothing else is touched.
    procedure SetRefs(Changes: TStringList);
    // `git update-server-info`: info/refs and objects/info/packs.
    procedure UpdateServerInfo;
    // 'sha1', or what extensions.objectformat says.
    function ObjectFormat: string;
    property Dir: string read FDir;
  end;

function GitShaToHex(const Sha: TGitSha): string;
function GitHexToSha(const Hex: string; out Sha: TGitSha): Boolean;
function GitIsHex(const S: string): Boolean;

// A bare repository as `git clone --mirror` and `git remote rm origin` leave it.
procedure GitInitBare(const Dir: string);
// The config without its [remote "<Name>"] sections (`git remote rm`).
procedure GitDropRemote(const Dir, Name: string);
// Indexes PackFile (any name, in the pack directory) and renames it to
// pack-<sha1>.pack beside its new pack-<sha1>.idx. Returns the pack's sha1.
// A pack that needs objects from outside it (a thin pack) is refused.
function GitIndexPack(const PackFile: string; out Objects: Int64): string;

// Fetches Url (…/repo.git) into Repo: wants what it lacks of refs/heads/*,
// refs/tags/* and refs/pull/*, sets those refs (forced), and for a NewRepo
// HEAD as the server has it. Auth is an Authorization header value ('' for
// none). Returns the number of objects received.
function GitFetch(Repo: TGitRepo; const Url, Auth: string; NewRepo: Boolean; Say: TGitSay): Int64;

const
  // An object a delta needs whole is in memory up to this size, else in a
  // scratch file.
  {$IFDEF HASAMIGA}
  GIT_MEM_LIMIT = 1024 * 1024;
  {$ELSE}
  GIT_MEM_LIMIT = 16 * 1024 * 1024;
  {$ENDIF}

var
  // GIT_MEM_LIMIT, or what OMI_GIT_MEM_LIMIT says (the tests' scratch files).
  GitMemLimit: Int64 = GIT_MEM_LIMIT;

implementation

type
  PGitCtx = ^TSHA1Context;

const
  BUF_SIZE = 65536;
  KIND_NAMES: array[1..4] of string = ('commit', 'tree', 'blob', 'tag');
  WANTED_PREFIXES: array[0..2] of string = ('refs/heads/', 'refs/tags/', 'refs/pull/');

{ --- small helpers --------------------------------------------------------------- }

function GitShaToHex(const Sha: TGitSha): string;
const
  H: array[0..15] of Char = '0123456789abcdef';
var
  I: Integer;
begin
  SetLength(Result, 40);
  for I := 0 to 19 do
  begin
    Result[I * 2 + 1] := H[Sha[I] shr 4];
    Result[I * 2 + 2] := H[Sha[I] and 15];
  end;
end;

function HexVal(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function GitHexToSha(const Hex: string; out Sha: TGitSha): Boolean;
var
  I, A, B: Integer;
begin
  Result := False;
  FillChar(Sha, SizeOf(Sha), 0);
  if Length(Hex) <> 40 then
    Exit;
  for I := 0 to 19 do
  begin
    A := HexVal(Hex[I * 2 + 1]);
    B := HexVal(Hex[I * 2 + 2]);
    if (A < 0) or (B < 0) then
      Exit;
    Sha[I] := A shl 4 or B;
  end;
  Result := True;
end;

function GitIsHex(const S: string): Boolean;
var
  Sha: TGitSha;
begin
  Result := GitHexToSha(S, Sha);
end;

function BE32(const B: array of Byte; I: Integer): Cardinal;
begin
  Result := Cardinal(B[I]) shl 24 or Cardinal(B[I + 1]) shl 16 or Cardinal(B[I + 2]) shl 8 or B[I + 3];
end;

function ReadBE32(S: TStream): Cardinal;
var
  B: array[0..3] of Byte;
begin
  S.ReadBuffer(B, 4);
  Result := BE32(B, 0);
end;

procedure PutBE32(var B: array of Byte; I: Integer; V: Cardinal);
begin
  B[I] := V shr 24;
  B[I + 1] := (V shr 16) and $FF;
  B[I + 2] := (V shr 8) and $FF;
  B[I + 3] := V and $FF;
end;

function ReadText(const Path: string): string;
var
  F: TFileStream;
begin
  Result := '';
  if not FileExists(Path) then
    Exit;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

// Written beside, then renamed over: never half a file.
procedure WriteText(const Path, Text: string);
begin
  GtForceDirs(ExtractFileDir(Path));
  if not GtWriteSynced(Path + '.lock', Text) then
    raise EGit.Create('cannot write ' + Path);
  if not GtRenameOver(Path + '.lock', Path) then
    raise EGit.Create('cannot rename ' + Path + '.lock');
end;

function HeaderOf(Kind: Integer; Size: Int64): string;
begin
  if (Kind < 1) or (Kind > 4) then
    raise EGit.Create('not an object type: ' + IntToStr(Kind));
  Result := KIND_NAMES[Kind] + ' ' + IntToStr(Size) + #0;
end;

function CompareRefNames(List: TStringList; A, B: Integer): Integer;
begin
  Result := CompareStr(List.Names[A], List.Names[B]);
end;

// A ref set in List ("name=sha"), found through Index (name -> its line), so
// a repository with tens of thousands of refs - every refs/pull/N/head of a
// GitHub mirror - is read and written in linear time: TStringList.Values
// searches the whole list on every call, which made each read quadratic.
procedure PutRef(List: TStringList; Index: TFPStringHashTable; const Name, Value: string);
var
  Node: THTCustomNode;
begin
  Node := Index.Find(Name);
  if Node <> nil then
    List[StrToInt(THTStringNode(Node).Data)] := Name + '=' + Value
  else
  begin
    Index.Add(Name, IntToStr(List.Count));
    List.Add(Name + '=' + Value);
  end;
end;

// The packed-refs file's refs into List.
procedure ReadPackedRefs(const Path: string; List: TStringList; Index: TFPStringHashTable);
var
  Lines: TStringArray;
  I, Sp: Integer;
  L: string;
begin
  Lines := ReadText(Path).Split([#10]);
  for I := 0 to High(Lines) do
  begin
    L := TrimRight(Lines[I]);
    if (L = '') or (L[1] in ['#', '^']) then
      Continue;
    Sp := Pos(' ', L);
    if (Sp = 41) and GitIsHex(System.Copy(L, 1, 40)) then
      PutRef(List, Index, System.Copy(L, 42, MaxInt), LowerCase(System.Copy(L, 1, 40)));
  end;
end;

// A stream for an object of Size bytes: memory, or a scratch file in Dir.
function ScratchStream(Size: Int64; const Dir: string; out Path: string): TStream;
var
  G: TGuid;
begin
  Path := '';
  if Size <= GitMemLimit then
    Exit(TMemoryStream.Create);
  GtCheckSize(Size, 'a git object');
  CreateGUID(G);
  Path := GtPath([Dir, 'tmp_obj_' + LowerCase(System.Copy(GUIDToString(G), 2, 36))]);
  Result := TFileStream.Create(Path, fmCreate);
end;

procedure FreeScratch(var S: TStream; const Path: string);
begin
  FreeAndNil(S);
  if Path <> '' then
    DeleteFile(Path);
end;

{ --- reading a pack byte by byte, with its checksum and each entry's CRC ------- }

type
  TPackIn = class
  public
    F: TStream;
    Buf: array of Byte;
    BufLen, BufPos: Integer;
    BufStart: Int64;
    Hashing, Crcing: Boolean;
    Ctx: TSHA1Context;
    Crc: Cardinal;
    constructor Create(AF: TStream; AHash: Boolean);
    function Position: Int64;
    // At least one byte buffered; False at the end of the stream.
    function Fill: Boolean;
    procedure Consume(N: Integer);
    function Next: Byte;
    procedure ReadBytes(var Dest; N: Integer);
    procedure SeekTo(Pos: Int64);
  end;

constructor TPackIn.Create(AF: TStream; AHash: Boolean);
begin
  inherited Create;
  F := AF;
  SetLength(Buf, BUF_SIZE);
  BufLen := 0;
  BufPos := 0;
  BufStart := F.Position;
  Hashing := AHash;
  Crcing := False;
  if Hashing then
    SHA1Init(Ctx);
end;

function TPackIn.Position: Int64;
begin
  Result := BufStart + BufPos;
end;

function TPackIn.Fill: Boolean;
var
  N: Integer;
begin
  if BufPos < BufLen then
    Exit(True);
  Inc(BufStart, BufLen);
  BufLen := 0;
  BufPos := 0;
  N := F.Read(Buf[0], Length(Buf));
  if N > 0 then
    BufLen := N;
  Result := BufLen > 0;
end;

procedure TPackIn.Consume(N: Integer);
begin
  if N <= 0 then
    Exit;
  if Hashing then
    SHA1Update(Ctx, Buf[BufPos], N);
  if Crcing then
    Crc := crc32(Crc, @Buf[BufPos], N);
  Inc(BufPos, N);
end;

function TPackIn.Next: Byte;
begin
  if not Fill then
    raise EGit.Create('the pack ends too early');
  Result := Buf[BufPos];
  Consume(1);
end;

procedure TPackIn.ReadBytes(var Dest; N: Integer);
var
  P: PByte;
  K: Integer;
begin
  P := @Dest;
  while N > 0 do
  begin
    if not Fill then
      raise EGit.Create('the pack ends too early');
    K := BufLen - BufPos;
    if K > N then
      K := N;
    Move(Buf[BufPos], P^, K);
    Consume(K);
    Inc(P, K);
    Dec(N, K);
  end;
end;

procedure TPackIn.SeekTo(Pos: Int64);
begin
  if (Pos >= BufStart) and (Pos <= BufStart + BufLen) then
  begin
    BufPos := Pos - BufStart;
    Exit;
  end;
  F.Position := Pos;
  BufStart := Pos;
  BufLen := 0;
  BufPos := 0;
end;

// An entry's header: its type and size, and for a delta where its base is.
procedure ReadEntryHeader(R: TPackIn; Offset: Int64; out Kind: Integer; out Size, BaseOff: Int64;
  out BaseSha: TGitSha);
var
  C: Byte;
  Shift: Integer;
  Ofs: Int64;
begin
  BaseOff := -1;
  FillChar(BaseSha, SizeOf(BaseSha), 0);
  C := R.Next;
  Kind := (C shr 4) and 7;
  Size := C and 15;
  Shift := 4;
  while (C and $80) <> 0 do
  begin
    C := R.Next;
    if Shift > 56 then
      raise EGit.Create('an object size that is too large');
    Size := Size or (Int64(C and $7F) shl Shift);
    Inc(Shift, 7);
  end;
  if Kind = GIT_OFS_DELTA then
  begin
    C := R.Next;
    Ofs := C and $7F;
    while (C and $80) <> 0 do
    begin
      C := R.Next;
      if Ofs > (High(Int64) shr 8) then
        raise EGit.Create('a delta offset that is too large');
      Ofs := ((Ofs + 1) shl 7) or (C and $7F);
    end;
    BaseOff := Offset - Ofs;
    if (BaseOff < 12) or (Ofs <= 0) then
      raise EGit.Create('a delta whose base is outside the pack');
  end
  else if Kind = GIT_REF_DELTA then
    R.ReadBytes(BaseSha, 20)
  else if not (Kind in [GIT_COMMIT, GIT_TREE, GIT_BLOB, GIT_TAG]) then
    raise EGit.Create('an unknown object type ' + IntToStr(Kind) + ' at ' + IntToStr(Offset));
end;

// Inflates exactly Size bytes (any number when Size < 0) from R into Dest
// (when not nil), hashing them into Ctx (when not nil).
procedure InflateTo(R: TPackIn; Size: Int64; Dest: TStream; Ctx: PGitCtx);
var
  Z: z_stream;
  Outb: array of Byte;
  Rc, Produced: Integer;
  Avail: Cardinal;
  Total: Int64;
begin
  SetLength(Outb, BUF_SIZE);
  FillChar(Z, SizeOf(Z), 0);
  if inflateInit(Z) <> Z_OK then
    raise EGit.Create('zlib: ' + Z.msg);
  Total := 0;
  try
    repeat
      if not R.Fill then
        raise EGit.Create('the pack ends inside an object');
      Avail := R.BufLen - R.BufPos;
      Z.next_in := @R.Buf[R.BufPos];
      Z.avail_in := Avail;
      Z.next_out := @Outb[0];
      Z.avail_out := Length(Outb);
      Rc := inflate(Z, Z_NO_FLUSH);
      R.Consume(Avail - Z.avail_in);
      Produced := Length(Outb) - Z.avail_out;
      if Produced > 0 then
      begin
        Inc(Total, Produced);
        if (Size >= 0) and (Total > Size) then
          raise EGit.Create('an object larger than its header says');
        if Ctx <> nil then
          SHA1Update(Ctx^, Outb[0], Produced);
        if Dest <> nil then
          Dest.WriteBuffer(Outb[0], Produced);
      end;
      if Rc = Z_STREAM_END then
        Break;
      if (Rc <> Z_OK) and (Rc <> Z_BUF_ERROR) then
        raise EGit.Create('zlib: ' + Z.msg);
    until False;
  finally
    inflateEnd(Z);
  end;
  if (Size >= 0) and (Total <> Size) then
    raise EGit.Create('an object smaller than its header says');
end;

function ReadVarint(S: TStream): Int64;
var
  C: Byte;
  Shift: Integer;
begin
  Result := 0;
  Shift := 0;
  repeat
    C := S.ReadByte;
    if Shift > 56 then
      raise EGit.Create('a delta size that is too large');
    Result := Result or (Int64(C and $7F) shl Shift);
    Inc(Shift, 7);
  until (C and $80) = 0;
end;

// Applies Delta to Base into Dest, hashing the result as an object of Kind.
procedure ApplyDelta(Base, Delta, Dest: TStream; Kind: Integer; Ctx: PGitCtx);
var
  SrcSize, DstSize, Off, Len, Written, Left: Int64;
  C: Byte;
  Buf: array of Byte;
  N: Integer;
  H: string;
begin
  SetLength(Buf, BUF_SIZE);
  Delta.Position := 0;
  SrcSize := ReadVarint(Delta);
  DstSize := ReadVarint(Delta);
  if SrcSize <> Base.Size then
    raise EGit.Create('a delta for a base of another size');
  if Ctx <> nil then
  begin
    H := HeaderOf(Kind, DstSize);
    SHA1Update(Ctx^, H[1], Length(H));
  end;
  Written := 0;
  while Delta.Position < Delta.Size do
  begin
    C := Delta.ReadByte;
    if (C and $80) <> 0 then
    begin
      Off := 0;
      Len := 0;
      if (C and $01) <> 0 then Off := Off or Int64(Delta.ReadByte);
      if (C and $02) <> 0 then Off := Off or (Int64(Delta.ReadByte) shl 8);
      if (C and $04) <> 0 then Off := Off or (Int64(Delta.ReadByte) shl 16);
      if (C and $08) <> 0 then Off := Off or (Int64(Delta.ReadByte) shl 24);
      if (C and $10) <> 0 then Len := Len or Int64(Delta.ReadByte);
      if (C and $20) <> 0 then Len := Len or (Int64(Delta.ReadByte) shl 8);
      if (C and $40) <> 0 then Len := Len or (Int64(Delta.ReadByte) shl 16);
      if Len = 0 then
        Len := $10000;
      if (Off < 0) or (Off + Len > SrcSize) then
        raise EGit.Create('a delta copies from outside its base');
      Base.Position := Off;
      Left := Len;
      while Left > 0 do
      begin
        N := BUF_SIZE;
        if N > Left then
          N := Left;
        Base.ReadBuffer(Buf[0], N);
        if Ctx <> nil then
          SHA1Update(Ctx^, Buf[0], N);
        if Dest <> nil then
          Dest.WriteBuffer(Buf[0], N);
        Dec(Left, N);
      end;
      Inc(Written, Len);
    end
    else if C <> 0 then
    begin
      Delta.ReadBuffer(Buf[0], C);
      if Ctx <> nil then
        SHA1Update(Ctx^, Buf[0], C);
      if Dest <> nil then
        Dest.WriteBuffer(Buf[0], C);
      Inc(Written, C);
    end
    else
      raise EGit.Create('a delta with an unknown instruction');
    if Written > DstSize then
      raise EGit.Create('a delta larger than it says');
  end;
  if Written <> DstSize then
    raise EGit.Create('a delta smaller than it says');
end;

{ --- index-pack ------------------------------------------------------------------ }

type
  TPackEntry = record
    Offset, DataOff, BaseOff, Size: Int64;
    Kind, Final: Byte;
    Done: Boolean;
    Crc: Cardinal;
    Sha: TGitSha;
    FirstChild, NextSibling: Integer;
  end;
  TPackEntries = array of TPackEntry;
  TOffsetMap = specialize TDictionary<Int64, Integer>;
  TShaMap = specialize TDictionary<string, Integer>;

  TIndexer = class
  public
    E: TPackEntries;
    Rand: TPackIn;
    ScratchDir: string;
    RefFirst: TShaMap;
    RefNext: array of Integer;
    RefBase: array of TGitSha;
    Resolved: Int64;
    procedure Materialize(I: Integer; Dest: TStream);
    procedure Resolve(I: Integer; Content: TStream);
  end;

procedure TIndexer.Materialize(I: Integer; Dest: TStream);
begin
  Rand.SeekTo(E[I].DataOff);
  InflateTo(Rand, E[I].Size, Dest, nil);
end;

// The children of I (deltas on it), resolved with I's content (read from the
// pack when Content is nil), then theirs.
procedure TIndexer.Resolve(I: Integer; Content: TStream);
var
  Kids: array of Integer;
  K, N, Kid: Integer;
  Hex, OwnPath, DeltaPath, ChildPath: string;
  Delta, Child: TStream;
  Ctx: TSHA1Context;
  DstSize: Int64;
  Own: Boolean;
begin
  Kids := nil;
  N := 0;
  K := E[I].FirstChild;
  while K >= 0 do
  begin
    SetLength(Kids, N + 1);
    Kids[N] := K;
    Inc(N);
    K := E[K].NextSibling;
  end;
  Hex := GitShaToHex(E[I].Sha);
  if RefFirst.TryGetValue(Hex, K) then
  begin
    RefFirst.Remove(Hex);
    while K >= 0 do
    begin
      SetLength(Kids, N + 1);
      Kids[N] := K;
      Inc(N);
      K := RefNext[K];
    end;
  end;
  if N = 0 then
    Exit;
  Own := Content = nil;
  OwnPath := '';
  if Own then
  begin
    Content := ScratchStream(E[I].Size, ScratchDir, OwnPath);
    try
      Materialize(I, Content);
    except
      FreeScratch(Content, OwnPath);
      raise;
    end;
  end;
  try
    for K := 0 to N - 1 do
    begin
      Kid := Kids[K];
      if E[Kid].Done then
        Continue;
      Delta := nil;
      Child := nil;
      DeltaPath := '';
      ChildPath := '';
      try
        Delta := ScratchStream(E[Kid].Size, ScratchDir, DeltaPath);
        Materialize(Kid, Delta);
        Delta.Position := 0;
        ReadVarint(Delta);
        DstSize := ReadVarint(Delta);
        Child := ScratchStream(DstSize, ScratchDir, ChildPath);
        SHA1Init(Ctx);
        ApplyDelta(Content, Delta, Child, E[I].Final, @Ctx);
        SHA1Final(Ctx, E[Kid].Sha);
        E[Kid].Final := E[I].Final;
        E[Kid].Done := True;
        Inc(Resolved);
        FreeScratch(Delta, DeltaPath);
        Resolve(Kid, Child);
      finally
        FreeScratch(Delta, DeltaPath);
        FreeScratch(Child, ChildPath);
      end;
    end;
  finally
    if Own then
      FreeScratch(Content, OwnPath);
  end;
end;

procedure SortBySha(const E: TPackEntries; var Order: array of Integer; L, R: Integer);
var
  I, J, P, T: Integer;
begin
  while L < R do
  begin
    I := L;
    J := R;
    P := Order[(L + R) shr 1];
    repeat
      while CompareByte(E[Order[I]].Sha, E[P].Sha, 20) < 0 do
        Inc(I);
      while CompareByte(E[Order[J]].Sha, E[P].Sha, 20) > 0 do
        Dec(J);
      if I <= J then
      begin
        T := Order[I];
        Order[I] := Order[J];
        Order[J] := T;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    if J - L < R - I then
    begin
      SortBySha(E, Order, L, J);
      L := I;
    end
    else
    begin
      SortBySha(E, Order, I, R);
      R := J;
    end;
  end;
end;

type
  // Writes and hashes: the .idx's own checksum is over everything before it.
  THashOut = class
    F: TFileStream;
    Ctx: TSHA1Context;
    constructor Create(const Path: string);
    destructor Destroy; override;
    procedure Put(const Buf; N: Integer);
    procedure Put32(V: Cardinal);
  end;

constructor THashOut.Create(const Path: string);
begin
  F := TFileStream.Create(Path, fmCreate);
  SHA1Init(Ctx);
end;

destructor THashOut.Destroy;
begin
  F.Free;
  inherited Destroy;
end;

procedure THashOut.Put(const Buf; N: Integer);
begin
  if N <= 0 then
    Exit;
  SHA1Update(Ctx, Buf, N);
  F.WriteBuffer(Buf, N);
end;

procedure THashOut.Put32(V: Cardinal);
var
  B: array[0..3] of Byte;
begin
  PutBE32(B, 0, V);
  Put(B, 4);
end;

procedure WriteIdx(const Path: string; const E: TPackEntries; const PackSha: TGitSha);
var
  Order: array of Integer;
  I, Large: Integer;
  Fan: array[0..255] of Cardinal;
  O: THashOut;
  Head: array[0..7] of Byte = ($FF, $74, $4F, $63, 0, 0, 0, 2);
  Sum: TGitSha;
  B: array[0..7] of Byte;
  V: Int64;
begin
  Order := nil;
  SetLength(Order, Length(E));
  for I := 0 to High(E) do
    Order[I] := I;
  if Length(E) > 1 then
    SortBySha(E, Order, 0, High(E));
  FillChar(Fan, SizeOf(Fan), 0);
  for I := 0 to High(E) do
    Inc(Fan[E[I].Sha[0]]);
  for I := 1 to 255 do
    Inc(Fan[I], Fan[I - 1]);
  O := THashOut.Create(Path);
  try
    O.Put(Head, 8);
    for I := 0 to 255 do
      O.Put32(Fan[I]);
    for I := 0 to High(Order) do
      O.Put(E[Order[I]].Sha, 20);
    for I := 0 to High(Order) do
      O.Put32(E[Order[I]].Crc);
    Large := 0;
    for I := 0 to High(Order) do
      if E[Order[I]].Offset >= $80000000 then
      begin
        O.Put32($80000000 or Cardinal(Large));
        Inc(Large);
      end
      else
        O.Put32(Cardinal(E[Order[I]].Offset));
    for I := 0 to High(Order) do
      if E[Order[I]].Offset >= $80000000 then
      begin
        V := E[Order[I]].Offset;
        PutBE32(B, 0, Cardinal(V shr 32));
        PutBE32(B, 4, Cardinal(V and $FFFFFFFF));
        O.Put(B, 8);
      end;
    O.Put(PackSha, 20);
    SHA1Final(O.Ctx, Sum);
    O.F.WriteBuffer(Sum, 20);
    FileFlush(O.F.Handle);
  finally
    O.Free;
  end;
end;

function GitIndexPack(const PackFile: string; out Objects: Int64): string;
var
  F: TFileStream;
  R: TPackIn;
  Ix: TIndexer;
  Hdr: array[0..11] of Byte;
  Count: Cardinal;
  I, K, B: Integer;
  ByOffset: TOffsetMap;
  Kind: Integer;
  Size, BaseOff: Int64;
  BaseSha, Sum, Trailer: TGitSha;
  Ctx: TSHA1Context;
  H, Dir, Name, Hex: string;
  Extra: Byte;
begin
  Objects := 0;
  Dir := ExtractFileDir(PackFile);
  F := TFileStream.Create(PackFile, fmOpenRead or fmShareDenyWrite);
  R := nil;
  Ix := TIndexer.Create;
  ByOffset := TOffsetMap.Create;
  Ix.RefFirst := TShaMap.Create;
  try
    GtCheckSize(F.Size, PackFile);
    R := TPackIn.Create(F, True);
    R.ReadBytes(Hdr, 12);
    if (Hdr[0] <> Ord('P')) or (Hdr[1] <> Ord('A')) or (Hdr[2] <> Ord('C')) or (Hdr[3] <> Ord('K')) then
      raise EGit.Create('not a pack: ' + PackFile);
    if not (BE32(Hdr, 4) in [2, 3]) then
      raise EGit.Create('a pack of version ' + IntToStr(BE32(Hdr, 4)));
    Count := BE32(Hdr, 8);
    // Every entry takes at least two bytes: a count beyond that is a lie.
    if Int64(Count) * 2 > F.Size then
      raise EGit.Create('a pack that claims more objects than it can hold');
    SetLength(Ix.E, Count);
    SetLength(Ix.RefNext, Count);
    SetLength(Ix.RefBase, Count);
    // Pass 1: every entry's place, CRC and, for a whole object, its sha1.
    for I := 0 to Integer(Count) - 1 do
    begin
      with Ix.E[I] do
      begin
        Offset := R.Position;
        FirstChild := -1;
        NextSibling := -1;
        Done := False;
      end;
      Ix.RefNext[I] := -1;
      R.Crc := crc32(0, nil, 0);
      R.Crcing := True;
      ReadEntryHeader(R, Ix.E[I].Offset, Kind, Size, BaseOff, BaseSha);
      Ix.E[I].Kind := Kind;
      Ix.E[I].Size := Size;
      Ix.E[I].BaseOff := BaseOff;
      Ix.E[I].DataOff := R.Position;
      if Kind in [GIT_COMMIT..GIT_TAG] then
      begin
        SHA1Init(Ctx);
        H := HeaderOf(Kind, Size);
        SHA1Update(Ctx, H[1], Length(H));
        InflateTo(R, Size, nil, @Ctx);
        SHA1Final(Ctx, Ix.E[I].Sha);
        Ix.E[I].Final := Kind;
        Ix.E[I].Done := True;
      end
      else
      begin
        InflateTo(R, Size, nil, nil);
        if Kind = GIT_OFS_DELTA then
        begin
          if not ByOffset.TryGetValue(BaseOff, B) then
            raise EGit.Create('a delta whose base is not an object of the pack');
          Ix.E[I].NextSibling := Ix.E[B].FirstChild;
          Ix.E[B].FirstChild := I;
        end
        else
        begin
          Ix.RefBase[I] := BaseSha;
          Hex := GitShaToHex(BaseSha);
          if Ix.RefFirst.TryGetValue(Hex, K) then
            Ix.RefNext[I] := K;
          Ix.RefFirst.AddOrSetValue(Hex, I);
        end;
      end;
      R.Crcing := False;
      Ix.E[I].Crc := R.Crc;
      ByOffset.Add(Ix.E[I].Offset, I);
    end;
    SHA1Final(R.Ctx, Sum);
    R.Hashing := False;
    R.ReadBytes(Trailer, 20);
    if CompareByte(Sum, Trailer, 20) <> 0 then
      raise EGit.Create('the pack''s checksum is wrong');
    if R.Fill then
    begin
      Extra := R.Next;
      raise EGit.Create('bytes after the pack''s checksum (' + IntToStr(Extra) + ')');
    end;
    // Pass 2: the deltas, from each whole object down its chains.
    Ix.ScratchDir := Dir;
    Ix.Rand := TPackIn.Create(F, False);
    try
      for I := 0 to Integer(Count) - 1 do
        if Ix.E[I].Kind in [GIT_COMMIT..GIT_TAG] then
          Ix.Resolve(I, nil);
    finally
      Ix.Rand.Free;
    end;
    for I := 0 to Integer(Count) - 1 do
      if not Ix.E[I].Done then
        if Ix.E[I].Kind = GIT_REF_DELTA then
          raise EGit.Create('a thin pack: the delta base ' + GitShaToHex(Ix.RefBase[I]) +
            ' is not in it (thin packs are not asked for and not stored)')
        else
          raise EGit.Create('a delta that could not be resolved at ' + IntToStr(Ix.E[I].Offset));
    Result := GitShaToHex(Sum);
    Name := GtPath([Dir, 'pack-' + Result]);
    FreeAndNil(R);
    FreeAndNil(F);
    Objects := Count;
    if FileExists(Name + '.pack') and FileExists(Name + '.idx') then
    begin
      // The same pack is already there.
      DeleteFile(PackFile);
      Exit;
    end;
    WriteIdx(Name + '.idx.tmp', Ix.E, Sum);
    if (ExpandFileName(PackFile) <> ExpandFileName(Name + '.pack')) and not GtRenameOver(PackFile, Name + '.pack') then
      raise EGit.Create('cannot rename ' + PackFile);
    if not GtRenameOver(Name + '.idx.tmp', Name + '.idx') then
      raise EGit.Create('cannot rename ' + Name + '.idx.tmp');
    GtSyncDir(Dir);
  finally
    R.Free;
    F.Free;
    ByOffset.Free;
    Ix.RefFirst.Free;
    Ix.Free;
  end;
end;

{ --- a pack and its .idx, read ------------------------------------------------- }

constructor TGitPack.Open(const AIdxPath: string);
var
  Head: array[0..7] of Byte;
  Fan: array[0..1023] of Byte;
  I: Integer;
begin
  inherited Create;
  IdxPath := AIdxPath;
  PackPath := ChangeFileExt(AIdxPath, '.pack');
  Idx := TFileStream.Create(IdxPath, fmOpenRead or fmShareDenyNone);
  Idx.ReadBuffer(Head, 8);
  if (Head[0] <> $FF) or (Head[1] <> $74) or (Head[2] <> $4F) or (Head[3] <> $63) or (BE32(Head, 4) <> 2) then
    raise EGit.Create('not a .idx of version 2: ' + IdxPath);
  Idx.ReadBuffer(Fan, 1024);
  for I := 0 to 255 do
    Fanout[I] := BE32(Fan, I * 4);
  Count := Fanout[255];
  Pack := TFileStream.Create(PackPath, fmOpenRead or fmShareDenyNone);
end;

destructor TGitPack.Destroy;
begin
  Idx.Free;
  Pack.Free;
  inherited Destroy;
end;

function TGitPack.Find(const Sha: TGitSha; out Offset: Int64): Boolean;
var
  Lo, Hi, Mid: Int64;
  Cur: TGitSha;
  C: Integer;
  V, Lv: Cardinal;
begin
  Result := False;
  Offset := 0;
  if Sha[0] = 0 then
    Lo := 0
  else
    Lo := Fanout[Sha[0] - 1];
  Hi := Int64(Fanout[Sha[0]]) - 1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    Idx.Position := 1032 + Mid * 20;
    Idx.ReadBuffer(Cur, 20);
    C := CompareByte(Cur, Sha, 20);
    if C = 0 then
    begin
      Idx.Position := 1032 + Int64(Count) * 24 + Mid * 4;
      V := ReadBE32(Idx);
      if (V and $80000000) <> 0 then
      begin
        Idx.Position := 1032 + Int64(Count) * 28 + Int64(V and $7FFFFFFF) * 8;
        V := ReadBE32(Idx);
        Lv := ReadBE32(Idx);
        Offset := (Int64(V) shl 32) or Lv;
      end
      else
        Offset := V;
      Exit(True);
    end;
    if C < 0 then
      Lo := Mid + 1
    else
      Hi := Mid - 1;
  end;
end;

{ --- the repository -------------------------------------------------------------- }

constructor TGitRepo.Open(const Dir: string);
begin
  inherited Create;
  FDir := ExcludeTrailingPathDelimiter(Dir);
  if not FileExists(GtPath([FDir, 'HEAD'])) or not DirectoryExists(GtPath([FDir, 'objects'])) then
    raise EGit.Create('not a git repository: ' + Dir);
  FPacks := TGitPackList.Create(True);
  FParents := TGitParents.Create;
  Rescan;
end;

destructor TGitRepo.Destroy;
begin
  FPacks.Free;
  FParents.Free;
  inherited Destroy;
end;

procedure TGitRepo.Rescan;
var
  Names: TStringList;
  I: Integer;
  PackDir: string;
begin
  FPacks.Clear;
  PackDir := GtPath([FDir, 'objects', 'pack']);
  Names := GtListDir(PackDir);
  try
    Names.Sort;
    for I := 0 to Names.Count - 1 do
      if (System.Copy(Names[I], 1, 5) = 'pack-') and (ExtractFileExt(Names[I]) = '.idx') and
        FileExists(GtPath([PackDir, ChangeFileExt(Names[I], '.pack')])) then
        FPacks.Add(TGitPack.Open(GtPath([PackDir, Names[I]])));
  finally
    Names.Free;
  end;
end;

function TGitRepo.ReadPacked(const Sha: TGitSha; out Kind: Integer; Dest: TStream; Depth: Integer): Boolean;
var
  I: Integer;
  Off: Int64;
  R: TPackIn;
  Pk: TGitPack;

  // The object at Off of this pack, whole, into S.
  procedure AtOffset(At: Int64; S: TStream; out K: Integer; Level: Integer);
  var
    Sz, Bo: Int64;
    Bs: TGitSha;
    B, D: TMemoryStream;
  begin
    if Level > 10000 then
      raise EGit.Create('a delta chain that does not end');
    R.SeekTo(At);
    ReadEntryHeader(R, At, K, Sz, Bo, Bs);
    if K in [GIT_COMMIT..GIT_TAG] then
    begin
      InflateTo(R, Sz, S, nil);
      Exit;
    end;
    D := TMemoryStream.Create;
    B := TMemoryStream.Create;
    try
      InflateTo(R, Sz, D, nil);
      if K = GIT_OFS_DELTA then
        AtOffset(Bo, B, K, Level + 1)
      else if not ReadInto(GitShaToHex(Bs), K, B, Level + 1) then
        raise EGit.Create('the delta base ' + GitShaToHex(Bs) + ' is missing');
      ApplyDelta(B, D, S, K, nil);
    finally
      D.Free;
      B.Free;
    end;
  end;

begin
  Result := False;
  Kind := 0;
  for I := 0 to FPacks.Count - 1 do
  begin
    Pk := FPacks[I];
    if Pk.Find(Sha, Off) then
    begin
      R := TPackIn.Create(Pk.Pack, False);
      try
        R.SeekTo(Off);
        AtOffset(Off, Dest, Kind, Depth);
      finally
        R.Free;
      end;
      Exit(True);
    end;
  end;
end;

function TGitRepo.ReadLoose(const Hex: string; out Kind: Integer; Dest: TStream): Boolean;
var
  Path, Head, Name: string;
  F: TFileStream;
  R: TPackIn;
  Raw: TMemoryStream;
  P: PChar;
  Z, Sp, I: Integer;
begin
  Result := False;
  Kind := 0;
  Path := GtPath([FDir, 'objects', System.Copy(Hex, 1, 2), System.Copy(Hex, 3, 38)]);
  if not FileExists(Path) then
    Exit;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  Raw := TMemoryStream.Create;
  R := TPackIn.Create(F, False);
  try
    // Read whole (commits and tags): its size is in the header it inflates to.
    InflateTo(R, -1, Raw, nil);
    P := Raw.Memory;
    Z := -1;
    for I := 0 to Raw.Size - 1 do
      if P[I] = #0 then
      begin
        Z := I;
        Break;
      end;
    if Z < 0 then
      raise EGit.Create('a loose object without a header: ' + Hex);
    SetString(Head, P, Z);
    Sp := Pos(' ', Head);
    Name := System.Copy(Head, 1, Sp - 1);
    for I := 1 to 4 do
      if KIND_NAMES[I] = Name then
        Kind := I;
    if (Kind = 0) or (StrToInt64Def(System.Copy(Head, Sp + 1, MaxInt), -1) <> Raw.Size - Z - 1) then
      raise EGit.Create('a loose object with a wrong header: ' + Hex);
    if Raw.Size - Z - 1 > 0 then
      Dest.WriteBuffer(P[Z + 1], Raw.Size - Z - 1);
    Result := True;
  finally
    R.Free;
    F.Free;
    Raw.Free;
  end;
end;

function TGitRepo.ReadInto(const Hex: string; out Kind: Integer; Dest: TStream; Depth: Integer): Boolean;
var
  Sha: TGitSha;
begin
  Kind := 0;
  if not GitHexToSha(Hex, Sha) then
    Exit(False);
  Result := ReadPacked(Sha, Kind, Dest, Depth) or ReadLoose(LowerCase(Hex), Kind, Dest);
end;

function TGitRepo.Has(const Hex: string): Boolean;
var
  Sha: TGitSha;
  I: Integer;
  Off: Int64;
begin
  if not GitHexToSha(Hex, Sha) then
    Exit(False);
  for I := 0 to FPacks.Count - 1 do
    if FPacks[I].Find(Sha, Off) then
      Exit(True);
  Result := FileExists(GtPath([FDir, 'objects', System.Copy(LowerCase(Hex), 1, 2), System.Copy(LowerCase(Hex), 3, 38)]));
end;

function TGitRepo.Read(const Hex: string; out Kind: Integer; out Data: RawByteString): Boolean;
var
  M: TMemoryStream;
begin
  Data := '';
  M := TMemoryStream.Create;
  try
    Result := ReadInto(Hex, Kind, M, 0);
    if Result and (M.Size > 0) then
    begin
      SetLength(Data, M.Size);
      Move(M.Memory^, Data[1], M.Size);
    end;
  finally
    M.Free;
  end;
end;

function TGitRepo.Kind(const Hex: string): Integer;
var
  Data: RawByteString;
begin
  if not Read(Hex, Result, Data) then
    Result := 0;
end;

// The value of a header line ("tree ...", "parent ...") of a commit or tag.
function HeaderValues(const Data, Key: string): TStringArray;
var
  Lines: TStringArray;
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  Lines := System.Copy(Data, 1, Pos(#10#10, Data + #10#10) - 1).Split([#10]);
  for I := 0 to High(Lines) do
    if System.Copy(Lines[I], 1, Length(Key) + 1) = Key + ' ' then
    begin
      SetLength(Result, N + 1);
      Result[N] := System.Copy(Lines[I], Length(Key) + 2, MaxInt);
      Inc(N);
    end;
end;

function TGitRepo.TagTarget(const Hex: string): string;
var
  K: Integer;
  Data: RawByteString;
  V: TStringArray;
begin
  Result := '';
  if not Read(Hex, K, Data) or (K <> GIT_TAG) then
    Exit;
  V := HeaderValues(Data, 'object');
  if Length(V) > 0 then
    Result := Trim(V[0]);
end;

function TGitRepo.PeelToCommit(const Hex: string): string;
var
  K, Guard: Integer;
  Data: RawByteString;
  V: TStringArray;
begin
  Result := LowerCase(Hex);
  for Guard := 0 to 100 do
  begin
    if not Read(Result, K, Data) then
      Exit('');
    if K = GIT_COMMIT then
      Exit;
    if K <> GIT_TAG then
      Exit('');
    V := HeaderValues(Data, 'object');
    if Length(V) = 0 then
      Exit('');
    Result := Trim(V[0]);
  end;
  Result := '';
end;

function TGitRepo.CommitInfo(const Hex: string; out Time: Int64; out Subject: string): Boolean;
var
  K, I: Integer;
  Data: RawByteString;
  V, Parts, Lines: TStringArray;
  Msg: string;
begin
  Time := 0;
  Subject := '';
  Result := Read(Hex, K, Data) and (K = GIT_COMMIT);
  if not Result then
    Exit;
  V := HeaderValues(Data, 'committer');
  if Length(V) > 0 then
  begin
    Parts := V[0].Split([' ']);
    if Length(Parts) >= 2 then
      Time := StrToInt64Def(Parts[High(Parts) - 1], 0);
  end;
  I := Pos(#10#10, Data);
  if I = 0 then
    Exit;
  // %(contents:subject): the first paragraph, its lines joined by spaces.
  Msg := System.Copy(Data, I + 2, MaxInt);
  while (Msg <> '') and (Msg[1] in [#10, #13]) do
    Delete(Msg, 1, 1);
  I := Pos(#10#10, Msg);
  if I > 0 then
    Msg := System.Copy(Msg, 1, I - 1);
  Lines := TrimRight(Msg).Split([#10]);
  for I := 0 to High(Lines) do
  begin
    if Subject <> '' then
      Subject := Subject + ' ';
    Subject := Subject + TrimRight(Lines[I]);
  end;
end;

function TGitRepo.CountCommits(const Hex: string): Int64;
var
  Seen: TShaMap;
  Todo: TStringList;
  Cur, Parents: string;
  K, I: Integer;
  Data: RawByteString;
  V: TStringArray;
begin
  Result := 0;
  Seen := TShaMap.Create;
  Todo := TStringList.Create;
  try
    Todo.Add(LowerCase(Hex));
    Seen.Add(LowerCase(Hex), 0);
    while Todo.Count > 0 do
    begin
      Cur := Todo[Todo.Count - 1];
      Todo.Delete(Todo.Count - 1);
      if not FParents.TryGetValue(Cur, Parents) then
      begin
        if not Read(Cur, K, Data) or (K <> GIT_COMMIT) then
          Continue;
        V := HeaderValues(Data, 'parent');
        Parents := '';
        for I := 0 to High(V) do
          Parents := Parents + Trim(V[I]) + ' ';
        FParents.AddOrSetValue(Cur, Parents);
      end;
      Inc(Result);
      V := Trim(Parents).Split([' '], TStringSplitOptions.ExcludeEmpty);
      for I := 0 to High(V) do
        if not Seen.ContainsKey(V[I]) then
        begin
          Seen.Add(V[I], 0);
          Todo.Add(V[I]);
        end;
    end;
  finally
    Seen.Free;
    Todo.Free;
  end;
end;

{ --- refs --------------------------------------------------------------------------- }

procedure TGitRepo.LooseRefs(const Dir, Prefix: string; Into: TStringList; Index: TFPStringHashTable);
var
  Names: TStringList;
  I: Integer;
  Full, V: string;
  Size: Int64;
begin
  Names := GtListDir(Dir);
  try
    for I := 0 to Names.Count - 1 do
    begin
      Full := GtPath([Dir, Names[I]]);
      case GtKind(Full, Size) of
        gkDir: LooseRefs(Full, Prefix + Names[I] + '/', Into, Index);
        gkFile:
          if (ExtractFileExt(Names[I]) <> '.lock') then
          begin
            V := Trim(ReadText(Full));
            if GitIsHex(V) then
              PutRef(Into, Index, Prefix + Names[I], LowerCase(V));
          end;
      end;
    end;
  finally
    Names.Free;
  end;
end;

function TGitRepo.Refs: TStringList;
var
  Index: TFPStringHashTable;
begin
  Result := TStringList.Create;
  Result.NameValueSeparator := '=';
  Index := TFPStringHashTable.Create;
  try
    ReadPackedRefs(GtPath([FDir, 'packed-refs']), Result, Index);
    LooseRefs(GtPath([FDir, 'refs']), 'refs/', Result, Index);
  finally
    Index.Free;
  end;
  Result.CustomSort(@CompareRefNames);
end;

function TGitRepo.RefValue(const Name: string): string;
var
  L: TStringList;
begin
  L := Refs;
  try
    Result := L.Values[Name];
  finally
    L.Free;
  end;
end;

procedure TGitRepo.SetRefs(Changes: TStringList);
var
  Packed_, Text: TStringList;
  Index: TFPStringHashTable;
  I: Integer;
begin
  Packed_ := TStringList.Create;
  Text := TStringList.Create;
  Index := TFPStringHashTable.Create;
  try
    Packed_.NameValueSeparator := '=';
    ReadPackedRefs(GtPath([FDir, 'packed-refs']), Packed_, Index);
    for I := 0 to Changes.Count - 1 do
      PutRef(Packed_, Index, Changes.Names[I], LowerCase(Changes.ValueFromIndex[I]));
    Packed_.CustomSort(@CompareRefNames);
    // No "peeled" trait: git peels these refs itself when it needs to.
    Text.LineBreak := #10;
    Text.Capacity := Packed_.Count + 1;
    Text.Add('# pack-refs with: sorted ');
    for I := 0 to Packed_.Count - 1 do
      Text.Add(Packed_.ValueFromIndex[I] + ' ' + Packed_.Names[I]);
    WriteText(GtPath([FDir, 'packed-refs']), Text.Text);
    // A loose ref would beat its new packed value.
    for I := 0 to Changes.Count - 1 do
      DeleteFile(GtPath([FDir, Changes.Names[I]]));
  finally
    Index.Free;
    Text.Free;
    Packed_.Free;
  end;
end;

procedure TGitRepo.UpdateServerInfo;
var
  L, Names: TStringList;
  I: Integer;
  Text, Peeled, Packs: string;
begin
  L := Refs;
  try
    Text := '';
    for I := 0 to L.Count - 1 do
    begin
      Text := Text + L.ValueFromIndex[I] + #9 + L.Names[I] + #10;
      if Kind(L.ValueFromIndex[I]) = GIT_TAG then
      begin
        // The tag peeled to what is not a tag.
        Peeled := L.ValueFromIndex[I];
        while Kind(Peeled) = GIT_TAG do
          Peeled := TagTarget(Peeled);
        if Peeled <> '' then
          Text := Text + Peeled + #9 + L.Names[I] + '^{}' + #10;
      end;
    end;
    WriteText(GtPath([FDir, 'info', 'refs']), Text);
  finally
    L.Free;
  end;
  Names := GtListDir(GtPath([FDir, 'objects', 'pack']));
  try
    Names.Sort;
    Packs := '';
    for I := 0 to Names.Count - 1 do
      if (System.Copy(Names[I], 1, 5) = 'pack-') and (ExtractFileExt(Names[I]) = '.pack') and
        FileExists(GtPath([FDir, 'objects', 'pack', ChangeFileExt(Names[I], '.idx')])) then
        Packs := Packs + 'P ' + Names[I] + #10;
    WriteText(GtPath([FDir, 'objects', 'info', 'packs']), Packs + #10);
  finally
    Names.Free;
  end;
end;

function TGitRepo.ObjectFormat: string;
var
  Lines: TStringArray;
  I: Integer;
  L: string;
begin
  Result := 'sha1';
  Lines := ReadText(GtPath([FDir, 'config'])).Split([#10]);
  for I := 0 to High(Lines) do
  begin
    L := LowerCase(StringReplace(Trim(Lines[I]), ' ', '', [rfReplaceAll]));
    if System.Copy(L, 1, 13) = 'objectformat=' then
      Result := System.Copy(L, 14, MaxInt);
  end;
end;

{ --- a new bare repository ------------------------------------------------------- }

procedure GitInitBare(const Dir: string);
const
  CONFIG = '[core]'#10#9'repositoryformatversion = 0'#10#9'filemode = true'#10#9'bare = true'#10;
  DESCRIPTION = 'Unnamed repository; edit this file ''description'' to name the repository.'#10;
  EXCLUDE = '# git ls-files --others --exclude-from=.git/info/exclude'#10 +
    '# Lines that start with ''#'' are comments.'#10 +
    '# For a project mostly in C, the following would be a good set of'#10 +
    '# exclude patterns (uncomment them if you want to use them):'#10 +
    '# *.[oa]'#10'# *~'#10;
var
  D: string;
begin
  for D in ['objects', GtPath(['objects', 'info']), GtPath(['objects', 'pack']), 'refs',
    GtPath(['refs', 'heads']), GtPath(['refs', 'tags']), 'info', 'hooks'] do
    if not GtForceDirs(GtPath([Dir, D])) then
      raise EGit.Create('cannot make ' + GtPath([Dir, D]));
  WriteText(GtPath([Dir, 'HEAD']), 'ref: refs/heads/master'#10);
  WriteText(GtPath([Dir, 'config']), CONFIG);
  WriteText(GtPath([Dir, 'description']), DESCRIPTION);
  WriteText(GtPath([Dir, 'info', 'exclude']), EXCLUDE);
end;

procedure GitDropRemote(const Dir, Name: string);
var
  Lines: TStringArray;
  I: Integer;
  L, Text: string;
  Skip: Boolean;
begin
  Lines := ReadText(GtPath([Dir, 'config'])).Split([#10]);
  Text := '';
  Skip := False;
  for I := 0 to High(Lines) do
  begin
    L := Trim(Lines[I]);
    if (L <> '') and (L[1] = '[') then
      Skip := (LowerCase(StringReplace(L, ' ', '', [rfReplaceAll])) = '[remote"' + LowerCase(Name) + '"]');
    if not Skip and ((I < High(Lines)) or (Lines[I] <> '')) then
      Text := Text + Lines[I] + #10;
  end;
  WriteText(GtPath([Dir, 'config']), Text);
end;

{ --- fetching over git's smart HTTP protocol ---------------------------------- }

function Pkt(const S: string): string;
begin
  Result := LowerCase(IntToHex(Length(S) + 4, 4)) + S;
end;

function OriginOf(const Url: string): string;
var
  I, J: Integer;
begin
  I := Pos('://', Url);
  if I = 0 then
    Exit('');
  J := I + 3;
  while (J <= Length(Url)) and (Url[J] <> '/') do
    Inc(J);
  Result := LowerCase(System.Copy(Url, 1, J - 1));
end;

procedure NeedTls(const Url: string);
begin
  {$IFDEF HASAMIGA}
  if Pos('https://', LowerCase(Url)) = 1 then
    raise EGit.Create('cannot fetch ' + Url + ': FreePascal has no TLS on this platform, so https:// cannot be ' +
      'read here; give an http:// address.');
  {$ENDIF}
end;

function NewClient(const Url, Auth, Origin: string): TFPHTTPClient;
begin
  NeedTls(Url);
  Result := TFPHTTPClient.Create(nil);
  Result.AllowRedirect := False;
  Result.IOTimeout := 600000;
  Result.AddHeader('User-Agent', 'git/2.0 (omi)');
  // The token only to the address it was given for.
  if (Auth <> '') and (OriginOf(Url) = Origin) then
    Result.AddHeader('Authorization', Auth);
end;

// GET, following redirects by hand; Url is where it ended.
function HttpGet(var Url: string; const Auth: string; out Body, ContentType: string): Integer;
var
  C: TFPHTTPClient;
  S: TStringStream;
  Hop: Integer;
  Loc, Origin: string;
begin
  Result := 0;
  Body := '';
  ContentType := '';
  Origin := OriginOf(Url);
  for Hop := 0 to 8 do
  begin
    C := NewClient(Url, Auth, Origin);
    S := TStringStream.Create('');
    try
      C.AddHeader('Accept', '*/*');
      try
        C.HTTPMethod('GET', Url, S, []);
      except
        on E: Exception do
          raise EGit.Create('git: ' + Url + ': ' + E.Message);
      end;
      Result := C.ResponseStatusCode;
      if (Result = 301) or (Result = 302) or (Result = 303) or (Result = 307) or (Result = 308) then
      begin
        Loc := C.GetHeader(C.ResponseHeaders, 'Location');
        if Loc = '' then
          Exit;
        if Pos('://', Loc) = 0 then
          Loc := OriginOf(Url) + Loc;
        Url := Loc;
        Continue;
      end;
      Body := S.DataString;
      ContentType := LowerCase(Trim(C.GetHeader(C.ResponseHeaders, 'Content-Type')));
      Exit;
    finally
      S.Free;
      C.Free;
    end;
  end;
end;

// The ref advertisement: Refs gets "name=sha" (HEAD and "...^{}" too), Caps
// the capabilities of the first line.
procedure ParseAdvert(const Body: string; Refs: TStringList; out Caps: string);
var
  P, Len, Nul: Integer;
  Line, Sha, Name: string;
  First: Boolean;
begin
  Caps := '';
  P := 1;
  First := True;
  while P + 3 <= Length(Body) do
  begin
    Len := StrToIntDef('$' + System.Copy(Body, P, 4), -1);
    if Len < 0 then
      raise EGit.Create('a ref advertisement that is not pkt-lines');
    if Len < 4 then
    begin
      Inc(P, 4);
      Continue;
    end;
    Line := System.Copy(Body, P + 4, Len - 4);
    Inc(P, Len);
    if (Line <> '') and (Line[Length(Line)] = #10) then
      SetLength(Line, Length(Line) - 1);
    if System.Copy(Line, 1, 1) = '#' then
      Continue;
    if System.Copy(Line, 1, 4) = 'ERR ' then
      raise EGit.Create('git: ' + System.Copy(Line, 5, MaxInt));
    Nul := Pos(#0, Line);
    if First then
    begin
      First := False;
      if Nul > 0 then
        Caps := ' ' + System.Copy(Line, Nul + 1, MaxInt) + ' ';
    end;
    if Nul > 0 then
      Line := System.Copy(Line, 1, Nul - 1);
    Sha := System.Copy(Line, 1, 40);
    Name := System.Copy(Line, 42, MaxInt);
    // An empty repository advertises only "capabilities^{}".
    // Each name is advertised once: added, not looked up (Values searches
    // the whole list, and a GitHub mirror advertises tens of thousands).
    if GitIsHex(Sha) and (Name <> '') and (Name <> 'capabilities^{}') then
      Refs.Add(Name + '=' + LowerCase(Sha));
  end;
end;

function HasCap(const Caps, Cap: string): Boolean;
begin
  Result := Pos(' ' + Cap + ' ', Caps) > 0;
end;

type
  // The answer to the POST, as it arrives: ACK/NAK lines, then the pack on
  // side band 1 straight into PackOut; band 2 is progress, band 3 an error.
  TPktSink = class(TStream)
  public
    PackOut: TStream;
    Len: array[0..3] of Char;
    LenGot, Remaining, Band: Integer;
    InPack, AtFirst, Ended: Boolean;
    Line, Err: string;
    PackBytes: Int64;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

function TPktSink.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TPktSink.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := PackBytes;
end;

function TPktSink.Write(const Buffer; Count: Longint): Longint;
var
  P: PChar;
  I, N, L: Integer;
  Chunk: string;
begin
  Result := Count;
  P := @Buffer;
  I := 0;
  while I < Count do
  begin
    if Remaining = 0 then
    begin
      // A pkt-line's length.
      Len[LenGot] := P[I];
      Inc(LenGot);
      Inc(I);
      if LenGot < 4 then
        Continue;
      LenGot := 0;
      L := StrToIntDef('$' + string(Len), -1);
      if L < 0 then
        raise EGit.Create('git: an answer that is not pkt-lines');
      if L < 4 then
      begin
        if InPack and (L = 0) then
          Ended := True;
        Continue;
      end;
      Remaining := L - 4;
      AtFirst := True;
      Line := '';
      Continue;
    end;
    if AtFirst then
    begin
      AtFirst := False;
      if not InPack and (Ord(P[I]) in [1, 2, 3]) then
        InPack := True;
      if InPack then
      begin
        Band := Ord(P[I]);
        Inc(I);
        Dec(Remaining);
        Continue;
      end;
    end;
    N := Count - I;
    if N > Remaining then
      N := Remaining;
    if InPack then
    begin
      case Band of
        1:
          begin
            PackOut.WriteBuffer(P[I], N);
            Inc(PackBytes, N);
          end;
        3:
          begin
            SetString(Chunk, PChar(@P[I]), N);
            Err := Err + Chunk;
          end;
      end;
    end
    else
    begin
      SetString(Chunk, PChar(@P[I]), N);
      Line := Line + Chunk;
    end;
    Inc(I, N);
    Dec(Remaining, N);
    if (Remaining = 0) and not InPack then
    begin
      if System.Copy(Line, 1, 4) = 'ERR ' then
        Err := Err + Trim(System.Copy(Line, 5, MaxInt));
    end;
  end;
end;

function GitFetch(Repo: TGitRepo; const Url, Auth: string; NewRepo: Boolean; Say: TGitSay): Int64;
var
  Base, GetUrl, Body, Ct, Caps, Req, Want, Tmp, Head, Origin, Name, V: string;
  Adv, Local, Changes, Wants, Haves: TStringList;
  I, K: Integer;
  C: TFPHTTPClient;
  ReqStream: TStringStream;
  Sink: TPktSink;
  PackFile: TFileStream;
  Limit: TGtLimitStream;
  G: TGuid;
  Status: Integer;
  Wanted: Boolean;
begin
  Result := 0;
  Base := Url;
  while (Base <> '') and (Base[Length(Base)] = '/') do
    SetLength(Base, Length(Base) - 1);
  Origin := OriginOf(Base);
  GetUrl := Base + '/info/refs?service=git-upload-pack';
  Status := HttpGet(GetUrl, Auth, Body, Ct);
  if Status <> 200 then
    raise EGit.Create('git: ' + Base + ' answered ' + IntToStr(Status));
  if Pos('application/x-git-upload-pack-advertisement', Ct) <> 1 then
    raise EGit.Create('git: ' + Base + ' is not a smart HTTP git server (' + Ct + ')');
  // Where the redirects ended.
  I := Pos('/info/refs?', GetUrl);
  if I > 0 then
    Base := System.Copy(GetUrl, 1, I - 1);
  Adv := TStringList.Create;
  Local := nil;
  Changes := TStringList.Create;
  Wants := TStringList.Create;
  Haves := TStringList.Create;
  try
    Adv.NameValueSeparator := '=';
    Changes.NameValueSeparator := '=';
    Wants.Sorted := True;
    Wants.Duplicates := dupIgnore;
    Haves.Sorted := True;
    Haves.Duplicates := dupIgnore;
    ParseAdvert(Body, Adv, Caps);
    for I := 0 to Adv.Count - 1 do
    begin
      Name := Adv.Names[I];
      Wanted := False;
      for K := 0 to High(WANTED_PREFIXES) do
        if System.Copy(Name, 1, Length(WANTED_PREFIXES[K])) = WANTED_PREFIXES[K] then
          Wanted := True;
      if not Wanted or (System.Copy(Name, Length(Name) - 2, 3) = '^{}') then
        Continue;
      V := Adv.ValueFromIndex[I];
      Changes.Add(Name + '=' + V);
      if not Repo.Has(V) then
        Wants.Add(V);
    end;
    Local := Repo.Refs;
    for I := 0 to Local.Count - 1 do
      if Repo.Has(Local.ValueFromIndex[I]) then
        Haves.Add(Local.ValueFromIndex[I]);
    if Wants.Count > 0 then
    begin
      if not HasCap(Caps, 'side-band-64k') and not HasCap(Caps, 'side-band') then
        raise EGit.Create('git: ' + Base + ' does not offer side-band-64k');
      if HasCap(Caps, 'side-band-64k') then
        Want := 'side-band-64k'
      else
        Want := 'side-band';
      if HasCap(Caps, 'ofs-delta') then
        Want := Want + ' ofs-delta';
      if HasCap(Caps, 'no-progress') then
        Want := Want + ' no-progress';
      if Pos(' agent=', Caps) > 0 then
        Want := Want + ' agent=git/2.0-omi';
      // No thin-pack: every delta's base is in the pack.
      Req := '';
      for I := 0 to Wants.Count - 1 do
        if I = 0 then
          Req := Req + Pkt('want ' + Wants[I] + ' ' + Want + #10)
        else
          Req := Req + Pkt('want ' + Wants[I] + #10);
      Req := Req + '0000';
      for I := 0 to Haves.Count - 1 do
        Req := Req + Pkt('have ' + Haves[I] + #10);
      Req := Req + Pkt('done'#10);
      if Assigned(Say) then
        Say('  git: ' + IntToStr(Wants.Count) + ' refs to fetch, ' + IntToStr(Haves.Count) + ' already here');
      CreateGUID(G);
      Tmp := GtPath([Repo.Dir, 'objects', 'pack', 'tmp_pack_' + LowerCase(System.Copy(GUIDToString(G), 2, 36))]);
      GtForceDirs(ExtractFileDir(Tmp));
      PackFile := TFileStream.Create(Tmp, fmCreate);
      Limit := TGtLimitStream.Create(PackFile, 'the pack of ' + Base);
      Sink := TPktSink.Create;
      ReqStream := TStringStream.Create(Req);
      C := NewClient(Base, Auth, Origin);
      try
        try
          Sink.PackOut := Limit;
          C.AddHeader('Content-Type', 'application/x-git-upload-pack-request');
          C.AddHeader('Accept', 'application/x-git-upload-pack-result');
          C.RequestBody := ReqStream;
          try
            C.HTTPMethod('POST', Base + '/git-upload-pack', Sink, []);
          except
            on E: EGtTooLarge do
              raise;
            on E: Exception do
              raise EGit.Create('git: ' + Base + '/git-upload-pack: ' + E.Message);
          end;
          if C.ResponseStatusCode <> 200 then
            raise EGit.Create('git: ' + Base + '/git-upload-pack answered ' + IntToStr(C.ResponseStatusCode));
          if Sink.Err <> '' then
            raise EGit.Create('git: the server says: ' + Trim(Sink.Err));
          if Sink.PackBytes = 0 then
            raise EGit.Create('git: ' + Base + ' sent no pack');
          FileFlush(PackFile.Handle);
        finally
          C.RequestBody := nil;
          C.Free;
          ReqStream.Free;
          Sink.Free;
          Limit.Free;
          PackFile.Free;
        end;
        GitIndexPack(Tmp, Result);
      except
        DeleteFile(Tmp);
        raise;
      end;
      Repo.Rescan;
      for I := 0 to Wants.Count - 1 do
        if not Repo.Has(Wants[I]) then
          raise EGit.Create('git: the server did not send ' + Wants[I]);
    end;
    if Changes.Count > 0 then
      Repo.SetRefs(Changes);
    if NewRepo then
    begin
      // HEAD as the server has it: its symref, else the branch it points at.
      Head := '';
      I := Pos(' symref=HEAD:', Caps);
      if I > 0 then
      begin
        Head := System.Copy(Caps, I + 13, MaxInt);
        Head := System.Copy(Head, 1, Pos(' ', Head) - 1);
      end;
      if (Head = '') and (Adv.Values['HEAD'] <> '') then
        for I := 0 to Adv.Count - 1 do
          if (System.Copy(Adv.Names[I], 1, 11) = 'refs/heads/') and (Adv.ValueFromIndex[I] = Adv.Values['HEAD']) then
          begin
            Head := Adv.Names[I];
            Break;
          end;
      if System.Copy(Head, 1, 5) = 'refs/' then
        WriteText(GtPath([Repo.Dir, 'HEAD']), 'ref: ' + Head + #10);
    end;
  finally
    Adv.Free;
    Local.Free;
    Changes.Free;
    Wants.Free;
    Haves.Free;
  end;
end;

initialization
  if StrToInt64Def(GetEnvironmentVariable('OMI_GIT_MEM_LIMIT'), -1) >= 0 then
    GitMemLimit := StrToInt64Def(GetEnvironmentVariable('OMI_GIT_MEM_LIMIT'), GIT_MEM_LIMIT);

end.
