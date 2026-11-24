# Backups: github-to-gitea backups in Omi

Omi's FreePascal server shows the backups that github-to-gitea writes (gitea-patches,
`mirror/common/gitea_backup.py`, FORMAT 1) as HTML 4.01 pages: the backups, a
backup's repositories, and each repository's issues, pull requests, comments,
releases, labels, milestones and files. A logged-in user can edit an issue's
title and body and a comment's body - saved into the backup's `.db` - and a text
file of the backup's `.zip`, saved into the `.zip`. It also lists the **old
data** of a backup - what only older backup runs saw - and can delete it.

Like the rest of Omi, the pages need no JavaScript and no cookies: every link is a
signed POST button.

## The backup format

One backup per owner, with no datetime directory:

```
<BACKUPS_DIR>/<NAME>/<NAME>.db    SQLite: every record
<BACKUPS_DIR>/<NAME>/<NAME>.zip   every file, in folders
```

`NAME` is a Gitea organization or user. Every backup run of github-to-gitea -
from Gitea or straight from GitHub - updates this one backup in place: rows are
inserted or updated by their key, files added only when they are new or
changed, and rows and files that disappeared at the source are kept. In Omi's
addresses it is the stamp `current`: `/backups/<NAME>/current/...`.

Backups written before that are **dated** directories, which github-to-gitea
combines into the one backup (and then deletes) the next time it runs for that
owner. Until then Omi lists and opens them too, marked "dated, not combined yet":

```
<BACKUPS_DIR>/<NAME>/YYYY-MM-DD_HH-MM-SS/<NAME>.db
<BACKUPS_DIR>/<NAME>/YYYY-MM-DD_HH-MM-SS/<NAME>.zip
```

A dated directory ending in `.partial` is a backup still being written, or one
that broke off, and Omi never lists or opens it. A stamp may end in `-N` when two
backups were made in the same second. Omi ignores the other things
github-to-gitea may leave in an owner's directory: `.backup.lock`,
`.backup.commit`, `.backup-work/`, `<NAME>.db.tmp`, `<NAME>.zip.tmp` and
`wekan/` (WeKan import files).

The `.db` tables are `meta`, `owner`, `teams`, `members`, `repos`, `labels`,
`milestones`, `issues`, `pulls`, `comments`, `releases` and `files`. Every row
keeps Gitea's own API JSON in its `json` column, so an issue's body is
`json.body`, its author `json.user.login`, and so on.

### The old data marker

In the one backup, every data table (all but `meta`) has a column `seen`: the
number of the backup run in which that row was last seen at the source. `meta`
key `runs` is the number of the newest run. A row is **old data** when

```sql
seen IS NULL OR seen < CAST((SELECT value FROM meta WHERE key = 'runs') AS INTEGER)
```

- it came only from an older, combined backup, or the newest run no longer saw
it at the source (deleted there, or a repository left out). The zip entries of
old data are the `path` of old `files` rows, and the `git_bundle` and
`wiki_bundle` of old `repos` rows that no current repository uses. github-to-gitea
writes the same columns, and its own lists of old data use the same rule. A
dated backup has neither `seen` nor `runs`: it has no old data pages.

Other `meta` keys of the one backup: `created` (the first run), `updated` (the
start of the newest run), `runs`, `sources` (e.g. `gitea,github`), `source` (the
newest run's), `merged` (the dated backups combined into it, as JSON), `kept` (a
sentence saying that rows and files that disappeared at the source are kept),
and after old data was deleted `deleted_old_only` (`<UTC time>: <N> rows, <M>
files, <bytes> bytes`).

The `.zip` holds every file STORED (not compressed), with ZIP64 records:

```
owner/avatar.png
<repo>/git.bundle
<repo>/wiki.bundle
<repo>/releases/<tag>/<file>
<repo>/issues/<number>/<id>-<file>
<repo>/comments/<number>/<comment>/<id>-<file>
```

## Setting it up

Set the directory in `settings.ini`, or on the Settings page:

```
BACKUPS_DIR=/srv/github-to-gitea-backup
```

A relative directory is beside `settings.ini`; `~/` is the home directory. Then
log in and press **Backups** in the menu.

The server needs read access to the backups to show them, and write access to the
`.db`, the `.zip` and the owner's directory (for the lock file and the `.tmp`
files) to save edits and delete old data.

## Pages

All pages need a logged-in user, because a backup can hold private repositories.
Reloading one goes back to `/`, as Omi's other logged-in pages do.

| Page | Shows |
|------|-------|
| `/backups` | every backup: owner, type, time (`meta updated` for the one backup; the stamp for a dated one), complete, sizes |
| `/backups/<NAME>/<stamp>` | the owner, the backup's `meta`, its repositories (with issue, pull request and release counts) and members; for the one backup also how many rows and files are old data, with an **Old data** button |
| `/backups/<NAME>/current/old` | the old data of the backup: repositories, members, teams, issues and pull requests, comments, releases, labels, milestones and files, with counts and sizes; each issue and file opens on its usual page. A **Delete old data** button when there is any |
| `/backups/<NAME>/current/delete-old` | what deleting the old data removes - rows per table, files, the space freed - and the confirmation form |
| `.../<repo>/old` | the repository's old data |
| `/backups/<NAME>/<stamp>/files` | every entry of the `.zip` |
| `/backups/<NAME>/<stamp>/<repo>` | the repository's issues (same as `.../issues`) |
| `.../<repo>/pulls` | pull requests, merged ones marked Merged |
| `.../<repo>/issue/<number>` | an issue or pull request: title, state, author, dates, labels, milestone, body, its files, and every comment with its files |
| `.../<repo>/releases` | releases with their notes and files |
| `.../<repo>/labels` | labels (in their colour) and milestones |
| `.../<repo>/files` | the `.zip` entries in the repository's folder |
| `/backups/<NAME>/<stamp>/file` | one `.zip` entry, chosen by a POST field, never by the URL |

Long lists are shown 500 rows at a time (the old data lists: their first 500).

Old data is marked **[Old data]** wherever it is shown: in the issue and pull
request lists, on an issue page (the issue, a comment, a file), in the release,
repository and file lists, and on a file's page.

A file page shows:

- a **text** file (no NUL bytes, UTF-8) in `<pre>`, escaped. Only its first 256 KiB
  are read and sent, with a note saying so;
- an **image** (PNG, JPEG, GIF, WebP, BMP, ICO) of up to 2 MiB as an image. It is
  sent inside the page as a `data:` URI, because an `<img>` request is a GET and a
  GET carries no session in Omi;
- anything else only as **Download**.

**Download** streams the entry's bytes straight from the `.zip` without reading the
whole entry into memory. It is sent as an attachment with the file's content
type (images and plain text as themselves, HTML, SVG and everything else as
`application/octet-stream`), `X-Content-Type-Options: nosniff` and a sandboxing
`Content-Security-Policy`.

A download shows no new page. Its button is therefore signed for the action
`backup-download`, and that token is checked without being used up, so the
buttons of the page the browser stays on keep working. That token cannot open a
page or save anything.

## The backup lock and the commit, shared with github-to-gitea

Every program that writes a backup - github-to-gitea's backup runs, its
combining and deleting, and every Omi save - first takes the lock file

```
<BACKUPS_DIR>/<NAME>/.backup.lock
```

in the OWNER's directory, for the one backup and the dated ones alike. It is
created with `O_CREAT|O_EXCL` and holds one line, `<pid> <hostname> <program>
<UTC ISO time>` (Omi's program is `omi`). A lock is stale only when its hostname
is this host's and its process is gone (`kill(pid, 0)` fails with `ESRCH`); then
it is removed and taken, once. A lock of a living process, or of another host,
is never taken: Omi refuses the save with "This backup is being updated by
another program" and the lock's line. Omi removes the lock after its write, and
only while it still holds Omi's own line.

A writer that replaces whole files (github-to-gitea's runs, deleting old data)
writes `<NAME>.db.tmp` and/or `<NAME>.zip.tmp` beside the real ones, syncs them,
creates `<NAME>/.backup.commit` (synced), renames `<NAME>.zip.tmp` over
`<NAME>.zip` and `<NAME>.db.tmp` over `<NAME>.db` (each when that `.tmp`
exists), removes the marker and syncs the directory. After taking the lock,
before writing anything, Omi recovers: when `.backup.commit` is there the commit
was decided, so the `.tmp` files still there are renamed into place and the
marker removed; without it, leftover `.tmp` files are a writer that broke off
and are removed. The backup is therefore always either the old one or the new
one.

github-to-gitea also rolls back Omi's own zip journal (`<NAME>.zip.omi-save`,
below) after taking the lock, exactly as Omi does.

## Editing

The edit forms only work for a logged-in user. Each save form is signed for one
action that names its target, such as
`backup-save-issue:<NAME>/<stamp>:<owner/repo>:<number>`. A token for one issue,
comment or file therefore cannot save another, and a navigation token cannot save
at all. Every save is written to Omi's activity log.

When the original text had no carriage returns, the CRLF line ends a browser
sends are turned back into LF.

### An issue or a comment, into the `.db`

```sql
UPDATE issues SET title = ?1, json = json_set(json, '$.title', ?1, '$.body', ?2)
  WHERE repo = ?3 AND number = ?4;
UPDATE pulls  SET json = json_set(json, '$.title', ?1, '$.body', ?2)
  WHERE repo = ?3 AND number = ?4;            -- for a pull request
UPDATE comments SET json = json_set(json, '$.body', ?1)
  WHERE repo = ?2 AND id = ?3 AND issue_number = ?4;
```

The statements run in one transaction, with bound parameters. Everything else in
the JSON is kept. The `.db` is opened read-write but never created, so a missing
file is an error rather than a new empty database.

### A text file, into the `.zip`

A text file of up to 1 MiB that is valid UTF-8 can be edited. The edit form always
holds the whole file, never just the part that is shown. The file must be a STORED
entry.

Saving **appends** to the `.zip`:

1. The `.zip`'s current length is written to `<NAME>.zip.omi-save` (the journal)
   and synced.
2. A new local header (with a ZIP64 extra, like gitea_backup writes) and the new
   bytes are appended after the end of the file.
3. A new central directory is appended, listing every other entry where it already
   was and this entry at its new copy, once. Then the end records: a ZIP64 end
   record and locator when the zip had them or needs them (65535 entries or more,
   or offsets of 4 GiB or more), and the end of central directory record. The
   zip's comment is kept.
4. The `.zip` is synced and the journal removed.
5. The file's row in `files` gets the new `size` and `sha256`.

The old bytes are never overwritten, so the zip stays a valid STORED zip that any
reader (Python's `zipfile`, `unzip -t`) can read. Each edit leaves
the previous copy's bytes in the file, unreferenced.

**If a save is interrupted** (power cut, killed server) between steps 1 and 4, the
journal is still there. The next time Omi opens that `.zip`, it truncates the zip
back to the length in the journal and removes the journal. That length is exactly
the old, valid zip. Until Omi opens the zip again, another program sees a zip
whose end record is not at its end. Saves and directory reads take one lock in the
server, so two saves never interleave.

If the process stops after step 4 and before step 5, the zip has the new content
but the row still has the old size and sha256.

A save holds the backup lock (above) from before the first byte is written until
after the `.db` row is updated. An edit never changes a row's `seen`.

## Deleting old data

`/backups/<NAME>/current/delete-old` shows what goes: the old rows per table, the
old zip entries and the space their bytes take. The form is signed for the
action `backup-delete-old:<NAME>/current` and needs the owner's name typed
exactly; without it, or with a token for another backup, nothing is deleted. A
dated backup has no old data marker and cannot be cleaned this way.

Deleting:

1. takes the backup lock and recovers (above), then measures the old data again;
2. copies `<NAME>.db` to `<NAME>.db.tmp` and there, in one transaction, deletes
   the old rows from every data table and sets `meta deleted_old_only`;
3. writes `<NAME>.zip.tmp` with every entry of `<NAME>.zip` except the old
   ones, each STORED with its own CRC and sizes, a ZIP64 local extra, a new
   central directory and end records. This is a rewrite, not an append: the
   deleted entries' bytes, and stale copies that earlier edits left behind, are
   freed;
4. syncs both and commits them with `.backup.commit` (above).

Data that is not old is never deleted. The deletion is written to the activity
log, and the page says how many rows and files went and how much space was
freed. `meta runs` is left as it was, so the next backup run marks what it sees
as before.

## What is not shown or edited

- Compressed or encrypted zip entries are listed but not shown, downloaded or
  replaced: gitea_backup writes only STORED ones.
- Release notes, labels and milestones are shown but not edited.
- Teams are not shown. Members are listed by login.
- Markdown in bodies is shown as escaped text with its line breaks, not rendered.

## Code and tests

- `public/omibackup.pas` - SQLite with prepared statements, and the zip reader and
  writer (end of central directory, ZIP64 locator and record, central directory,
  local headers, appending a new entry, the journal).
- `public/server.pas` - `BackupsEndpoint` and its pages, the Backups menu entry, and
  `BACKUPS_DIR` on the Settings page.
- `tests/make_backup_fixture.py` - writes test backups: two in the one-backup
  layout (`acme`, `beta`) with `seen`, `meta runs` and old data - an issue with
  its comment and file, a release with its file, a label, a milestone, a member,
  a team and a whole repository with its git bundle - and dated ones: a plain
  one, one with ZIP64 end records, and a `.partial` one.
- `tests/backups_test.py` - builds the server, starts it on a free port in a scratch
  directory and clicks through the pages like a browser without JavaScript.

  It checks:
  - escaping;
  - downloads and Content-Length;
  - saves into the `.db` and the `.zip`, read back with `sqlite3` and `zipfile`;
  - the rollback of an interrupted save;
  - the one-backup layout listed and opened beside dated ones, the old data pages
    (exactly the old rows and files), old issues and files shown and marked;
  - the lock: a live holder refuses a save and keeps its lock, a stale one is
    taken over, another host's never; a commit that broke off is finished, and
    leftover `.tmp` files without a marker are removed, before a write;
  - deleting old data: refused without a session, with a used token, with a
    token for another backup, and without the owner's name typed; then exactly
    the old rows and entries go, every current row and entry stays byte for
    byte, the zip is valid (`zipfile.testzip`, `unzip -t`) and shrank by the old
    entries' bytes, `deleted_old_only` is set and no `.tmp`, marker or lock is
    left;
  - that every language file has the new keys, translated;
  - refusals: no session, a used token, a token for another target, a download
    token, `..` and other unsafe entry names and paths, and `.partial` backups.

  Run it with:

```
TMPDIR=/some/scratch python3 -I tests/backups_test.py
```

Set `OMI_SKIP_BUILD=1` to test the `public/server` that is already built, or
`OMI_KEEP_TEST_DIR=1` to keep the scratch directory.
