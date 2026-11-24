{
  Omi on AmigaOS 3 (m68k): the embedded SQLite
  ============================================

  releases/amiga/build.sh compiles SQLite 3.53.4 for the 68020 with the
  m68k-amigaos GCC and libnix (gfopensqlite's AmigaDOS patches: the
  "<database>.lck" Lock() of the unix-dotfile VFS, and no seek past the end
  of a file), with WAL kept - Gitea's database is a WAL database - and
  SQLITE_DEFAULT_LOCKING_MODE=1, so WAL's index is in SQLite's own memory
  and no shared memory is needed. This unit links those objects into the
  FreePascal program and gives libnix what its own startup code would: the
  exec.library base in _SysBase, and an _exit.
}

unit omiamiga;

{$MODE OBJFPC}
{$H+}

interface

implementation

{$LINK ../build/amiga/sqlite3.o}
{$LINK ../build/amiga/sqlite_amiga.o}
{$LINK ../build/amiga/omi_amiga.o}

var
  LibnixSysBase: Pointer; cvar; public name '_SysBase';

procedure LibnixExit(Status: LongInt); cdecl; public name '_exit';
begin
  Halt(Status);
end;

initialization
  // AbsExecBase, address 4.
  LibnixSysBase := PPointer(4)^;
end.
