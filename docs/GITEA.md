# Gitea folder: reading a Gitea installation straight from its files

Omi's FreePascal server can read a Gitea installation directly from its work
directory: `custom/conf/app.ini`, the SQLite database and the storage folders.
It lists the users and organizations, their repositories, issues, pull
requests, comments, releases with their files, attachments, LFS objects and
packages, and it measures how much space each owner and repository takes -
on disk and as the database has it - with the mismatches between the two and
the orphans (files without a database row, rows without a file).

These pages and the `server gitea` command only read. The database is opened
read-only (`file:...?mode=ro`), and no secret column - password hashes, salts,
tokens, keys, two-factor secrets, e-mail addresses - is ever selected.

## Setting it up

Set the app.ini of the Gitea installation in `settings.ini`, or on the Settings
page:

```
GITEA_APP_INI=/srv/gitea/custom/conf/app.ini
```

A relative path is in the Omi folder (where `settings/` is); `~/` is the home directory. Then log
in and press **Gitea folder** in the menu.

Optional settings:

| Setting | Default | What it is |
|---------|---------|------------|
| `GITEA_TREE` | none | The output of `tree -s` (or better `tree -a -s -F`) run in the Gitea work directory. When set, sizes are measured from this listing instead of the disk - for a copy of the database on another machine. |
| `GITEA_INDEX` | `gitea-index.txt` | The cached size index. |

## Where Omi looks: app.ini

Omi reads `app.ini` the way Gitea's `modules/setting` does:

| What | From | Default |
|------|------|---------|
| work directory | `WORK_PATH` (before the first section) | `GITEA_WORK_DIR`, else the directory above `custom/conf/` |
| data | `[server] APP_DATA_PATH` | `<work>/data` |
| database | `[database] DB_TYPE`, `PATH` | `sqlite3`, `<data>/gitea.db` |
| repositories | `[repository] ROOT` | `<data>/gitea-repositories` |
| attachments | `[attachment] PATH` | `<data>/attachments` |
| LFS | `[lfs] PATH`, or the old `[server] LFS_CONTENT_PATH` | `<data>/lfs` |
| packages | `[packages] PATH` | `<data>/packages` |
| avatars | `[avatar] PATH`, or `[picture] AVATAR_UPLOAD_PATH` | `<data>/avatars` |
| repository avatars | `[repo-avatar] PATH`, or `[picture] REPOSITORY_AVATAR_UPLOAD_PATH` | `<data>/repo-avatars` |
| Actions logs | `[storage.actions_log] PATH` | `<data>/actions_log` |
| Actions artifacts | `[actions.artifacts] PATH` | `<data>/actions_artifacts` |
| repository archives | `[repo-archive] PATH` | `<data>/repo-archive` |

A storage without a PATH of its own uses `[storage.<name>] PATH`, else
`[storage] PATH` + `/<name>`, else `<data>/<name>`. A relative ROOT or database
PATH is beside the work directory; a relative storage PATH is beside the data
directory. A storage whose `STORAGE_TYPE` is `minio` or `azureblob` is not on
the local disk; Omi says so and does not measure it. Only a Gitea that uses
SQLite can be read.

Inside those folders Gitea keeps:

```
<ROOT>/<owner>/<repo>.git                git, bare
<ROOT>/<owner>/<repo>.wiki.git           the wiki
<attachments>/<uuid[0]>/<uuid[1]>/<uuid> issue, comment and release files
<lfs>/<oid[0:2]>/<oid[2:4]>/<oid[4:]>    LFS objects (shared between repositories)
<packages>/<sha256[0:2]>/<sha256[2:4]>/<sha256>
<avatars>/<user.avatar>, <repo-avatars>/<repository.avatar>
```

## Sizes and the index

Measuring ~900,000 files takes a while, so the sizes come from a cached index
(`GITEA_INDEX`), made by **Measure again** on the Gitea page or by
`server gitea index`. The index records the size of every git directory
(summed), every attachment, LFS object, package blob and avatar file, and the
rest of the data directory per top-level folder. File sizes are the bytes of
the regular files (as `git_size` counts them); symbolic links are not
followed.

When `GITEA_TREE` is set, the index is made from that `tree -s` listing
instead. With `tree -a -s -F` directories end in `/` and nothing is guessed;
plain `tree -s` shows an empty directory like a file of its own size, so a
leaf of 4096 bytes is taken to be a directory unless its name is a UUID or a
hash.

| Per | Measured |
|-----|----------|
| repository | git directory and wiki on disk; LFS objects it references (on disk); its attachments (on disk); and the database's `size`, `git_size` and `lfs_size` |
| owner | the sum of its repositories; each LFS object and package blob once, however many repositories or versions use it; its avatar |
| everything | git, wiki, LFS, attachments, packages, avatars, Actions, archives, the rest of the data directory, and the orphans |

A repository is flagged when:

- it has no git directory;
- `git_size` and the disk differ by more than 1% and 64 KiB (Gitea measures
  `git_size` when a repository changes);
- `lfs_size` is not the sum of its `lfs_meta_object` rows;
- `size` is not `git_size + lfs_size`;
- an LFS object or an attachment it has a row for has no file;
- the sizes of its attachment rows are not those of the files.

The **orphans** report lists attachment files without an `attachment` row (or
not at `<uuid[0]>/<uuid[1]>/<uuid>`), attachment rows without a file, an
attachment whose file is not the size its row says, LFS files without an
`lfs_meta_object` row and rows without a file, git directories without a
`repository` row, package blobs without a `package_blob` row and rows without a
file, and avatar files that no user or repository has.

## Pages

All pages need a logged-in user. Like the rest of Omi they need no JavaScript
and no cookies: every link is a signed POST button, and reloading a page goes
back to `/`.

| Page | Shows |
|------|-------|
| `/gitea` | the paths read from app.ini (and whether each exists), the migration version, row counts, the sizes of everything, **Measure again** |
| `/gitea/owners` | every user and organization with its repositories, git, LFS, attachments, packages, total, the database's size and its mismatches; sorted by any column, largest first |
| `/gitea/repos` | every repository, sortable, 500 at a time |
| `/gitea/o/<owner>` | the owner's sizes, repositories and packages |
| `/gitea/o/<owner>/<repo>` | the repository's sizes and the database's, and its issues |
| `.../<repo>/pulls` | pull requests (merged ones marked Merged) |
| `.../<repo>/issue/<number>` | an issue or pull request with its comments and attachments |
| `.../<repo>/releases`, `.../release/<id>` | releases and tags; a release with its notes and files |
| `.../<repo>/attachments` | the repository's attachments, largest first, with their path and whether the file is there |
| `.../<repo>/lfs` | the repository's LFS objects, largest first |
| `/gitea/orphans` | the orphans report (its first 5000 lines) |

Authors imported by a migration (`original_author`) are shown as
`<login> (GitHub)`. Bodies are shown as escaped text with their line breaks.

An owner or repository name in an address must be a Gitea name -
`[A-Za-z0-9_.-]`, not starting with `.` or `-`, no `..` - or the page is not
found; a name is never used as a path.

## The command line

The same binary reads from a terminal, without starting the web server:

```
./public/server gitea paths    [--config app.ini]
./public/server gitea version  [--config app.ini]
./public/server gitea index    [--config app.ini] [--tree tree.txt] [--index file]
./public/server gitea owners   [--sort total|name|git|lfs|attachments|packages|repos|db] [--limit N] [--bytes] [--rescan]
./public/server gitea sizes    [--owner NAME] [--sort ...|issues] [--limit N] [--bytes]
./public/server gitea orphans  [--limit N] [--bytes]
```

`--config`, `--tree` and `--index` default to `GITEA_APP_INI`, `GITEA_TREE`
and `GITEA_INDEX` of `settings.ini`. The output is tab-separated with a header
line; `--bytes` prints bytes instead of KB/MB/GB. `owners` and `sizes` make the
index first when there is none (or with `--rescan`).

And git in Pascal by itself, as the import uses it:

```
./public/server gitea git [--git /path/to/git] [--git-fetch pascal|program] [--json]
OMI_GIT_DIR=r.git OMI_GIT_URL=https://github.com/o/r.git ./public/server gitea git-fetch
./public/server gitea git-refs r.git     (or OMI_GIT_DIR=r.git)
./public/server gitea git-index-pack some.pack
```

`git` says which git program was found, its version and the fetch mode.
`git-fetch` fetches into a bare repository (made when it is not there),
`git-refs` lists every ref with the commit it peels to, its time, subject and
commit count, and `git-index-pack` writes a pack's `.idx` and names it
`pack-<sha1>`.

For example, with a copy of a Gitea database and a `tree -a -s -F` listing of
its folder:

```
cat > copy.ini <<EOF
WORK_PATH = /srv/gitea
[database]
PATH = /backup/gitea.db
EOF
./public/server gitea owners --config copy.ini --tree gitea-tree.txt --rescan
./public/server gitea sizes --config copy.ini --owner wekan
./public/server gitea orphans --config copy.ini
```

## Writing: Gitea stopped, one lock, one transaction

Deleting an owner and importing from GitHub write into the Gitea folder.
Omi does both itself, in FreePascal (`public/omigiteaw.pas`), on its embedded
SQLite: only Omi runs - no Gitea server, no gitea binary and no other
interpreter. The pages run a write as a **job** (below). Every
write:

- **refuses while Gitea runs** - when a PID file names a living process
  (`GITEA_PID_FILE`, else `/run/gitea.pid`, `/var/run/gitea.pid`,
  `<work>/gitea.pid`), when a `gitea web` process uses this app.ini (or this
  work directory), when any process has the database open, or when anything
  answers on Gitea's `HTTP_ADDR:HTTP_PORT`;
- **takes the exclusive lock** `<APP_DATA_PATH>/.omi-gitea.lock`, created with
  `O_CREAT|O_EXCL` and holding `<pid> <host> omigitea <UTC time>`. A lock of
  this host whose process is gone is stale and taken over; any other lock
  refuses the write;
- **writes the database in one transaction** (`BEGIN IMMEDIATE` ... `COMMIT`),
  so it is either all done or not at all;
- **keeps the files consistent if interrupted**: new files are written before
  the commit and old ones deleted only after it. The files to delete are first
  written to the journal `<APP_DATA_PATH>/.omi-gitea.journal` (synced). The
  next write that takes the lock finishes a journal left behind: each file in
  it is deleted only when no row of the database refers to it any more - which
  is right whether the transaction that wrote the journal committed or not.

No test ever writes to a real Gitea database: the tests write a fixture and a
copy of the disposable test Gitea.

## Deleting a user or an organization

`/gitea/o/<owner>` has a **Delete this user or organization** button. Its page
is a dry run - nothing is changed - showing the rows per table, the files and
the space that deleting frees, the owner's repositories, whether Gitea is
running, and anything that blocks the deletion (the last administrator; the
last owner of an organization). The form is signed for the action
`gitea-delete:<owner>` and needs the owner's name typed exactly (in the same
case); without it, or with a token for another owner, nothing is deleted.

What goes follows Gitea's own code - `DeleteRepositoryDirectly` for each
repository (`services/repository/delete.go`), `deleteUser` with purge
(`services/user/delete.go`), `deleteOrganization` (`services/org/org.go`) and
`RemoveAllPackages`:

- **files**: `<ROOT>/<owner>/` (every repository and wiki), the attachments of
  its repositories, issues, comments and releases, and its unlinked uploads;
  the LFS objects and package blobs no other owner references; the owner's
  avatar and its repositories' avatars; its Actions logs (and their dbfs rows)
  and artifacts; its repository archives;
- **rows**: every row that refers to the owner or its repositories - the
  repositories, issues, pull requests, comments (and, for a user, the user's
  text comments elsewhere, as Gitea's purge does), labels, milestones,
  releases, attachments, LFS rows, branches, statuses, webhooks and their
  tasks, projects, Actions runs, jobs, tasks, runners, secrets and variables,
  packages, teams, memberships, stars, watches, follows, keys, tokens, two-factor
  and WebAuthn rows, OAuth2 applications and grants, settings, redirects,
  notifications and the rest (the full list is `GW_DELETES` in
  `public/omigiteaw.pas`);
- **counters of other owners** recomputed the way Gitea's `check_repo_stats`
  does: stars, watches and forks of other repositories, followers, organization
  and team members, comment counts of issues that lost a comment, and topics
  (an unused topic is removed). Another owner's fork of a deleted repository
  becomes a repository of its own.

Kept on purpose, as Gitea keeps them (`GW_KEPT` in `public/omigiteaw.pas`, each with
its reason): a deleted user's issues, events, reviews and tracked time in
OTHER owners' repositories, which Gitea shows as by a ghost user, and pull
requests into other repositories whose head was a deleted repository.

`tests/gitea_test.py` fails when a column of Gitea's schema that points at an
owner or a repository is in neither list.

The delete page also shows the owner's existing github-to-gitea backup in
`BACKUPS_DIR`, with a button to open it; make one while Gitea still runs.

After a deletion, `gitea doctor check --all` finds nothing it did not find
before (tested against a copy of the test Gitea).

## Deleting one repository

**Delete this repository and its files** on a repository's page (and the
Delete column of its owner's page) deletes one repository, with Gitea stopped,
following Gitea's `DeleteRepositoryDirectly`: the same `GW_DELETES` as an owner
deletion, for that repository only (the owner's own rows are not touched),
and the same lock, transaction and journal.

Its page is a dry run: the rows per table, and the bytes freed per kind - git,
wiki, the LFS objects only this repository references, attachments, archives,
Actions logs and artifacts. Packages linked to it stay the owner's, unlinked,
as in Gitea. The form is signed for `gitea-delete-repo:<owner>/<name>` and
needs `owner/name` typed exactly. **Also exclude it from sync** is ticked by
default: otherwise the next sync from GitHub brings the repository back.
Afterwards the owner's `num_repos` and its teams' `num_repos` are recounted,
and `gitea doctor check --all` finds nothing new (tested on a copy of the test
Gitea).

```
./public/server gitea delete-repo --config app.ini --owner O --repo R --dry-run [--json]
./public/server gitea delete-repo --config app.ini --owner O --repo R --confirm O/R \
    [--exclude-from-sync --exclude-file FILE] [--by USER] [--index gitea-index.txt]
```

## What was deleted stays visible

Every deletion - of a repository, a user or an organization - is recorded in
`<APP_DATA_PATH>/omi/deleted-repos.tsv`: `owner/name`, UTC time, bytes freed,
the Omi user, and what it was. The Sizes page, the owner's page and the
repository listing show deleted repositories as **Deleted <date>, <size>
freed**, struck through and without links. The size index loses the lines of
the deleted files and is marked out of date (`#stale`), which the pages say,
until **Measure again**.

## Not syncing a repository any more

**Do not sync this repository any more** on a repository's page adds
`owner/name` to the exclude file shared with github-to-gitea,
`SYNC_EXCLUDE_FILE` - by default `github-to-gitea.exclude.txt` beside
github-to-gitea's `.ini` (in `GITHUB_TO_GITEA_DIR`). One `owner/name` a line,
or comma separated, `#` comments; it is read with github-to-gitea's own
`gitea_attachments.parse_exclude_file`, so both read it the same way, and the
`.ini` is never touched. github-to-gitea's sync and backups leave the
repositories in it out of what an organization or user expands to, and so
does Omi's import. The pages show **Not synced** for them, and **Include
again** removes the line (comments and other lines stay). A name that is not
`owner/name` of two Gitea names is refused.

```
./public/server gitea exclude --config app.ini --exclude-file FILE [--add O/R] [--remove O/R]
```

## Importing from GitHub

`/gitea/import` (and **Update from GitHub** on an owner's page) imports a GitHub
organization or user - all its repositories, or the ones named - straight into
the Gitea folder, with Gitea stopped, writing the rows Gitea's own migration
writes (`services/migrations/gitea_uploader.go` and the models it calls). It
runs as a job. From a terminal:

```
./public/server gitea import --config app.ini --owner NAME [--repo R ...] \
    [--token-file github-token.ini] [--doer GITEA_USER] [--gitea-binary /path/to/gitea] \
    [--git-fetch pascal|program] [--git /path/to/git]
```

GitHub's API is read by Omi itself (fphttpclient), the way github-to-gitea's
client does: rate limits are waited out, redirects are followed by hand so the
token goes only to GitHub's own addresses (never to the storage a release file
is redirected to), and a token GitHub refuses is dropped for public reading.
The token is read from its file, never printed and never on a command line.

**Test the token**, on the import page and on Settings beside `GITHUB_TOKEN`,
asks GitHub `GET /user` with it and says what GitHub answered: accepted, with
the login it signs in as and the requests left this hour; not accepted (401:
wrong, expired or revoked - save a new one); refused (403 or 429, with
GitHub's own message, such as a used-up hour); or GitHub out of reach. Nothing
is written, the token is not shown, and each test is in the activity log as
`gitea-token-tested` with its outcome. An import whose log starts with
"GitHub: the token is not accepted; reading without it." had a token GitHub
refuses, and then reads with an anonymous client's 60 requests an hour. From
a terminal:

```
./public/server gitea test-token [--token-file github-token.ini] [--json]
```

Git is fetched and read by Omi itself too (`public/omigit.pas`), so no other
program runs: git's smart HTTP protocol (v0/v1) over fphttpclient - `GET
info/refs?service=git-upload-pack`, then one `POST git-upload-pack` with the
wants (the advertised `refs/heads/*`, `refs/tags/*` and `refs/pull/*` the bare
repository lacks), the haves (its ref tips), `done`, `side-band-64k` and
`ofs-delta`. The pack goes from the network straight to
`objects/pack/pack-<sha1>.pack` and its `.idx` (version 2) is written in
Pascal: every object inflated (paszlib) and hashed (SHA-1) as it is read,
`OFS_DELTA` and `REF_DELTA` resolved, an object a delta needs whole kept in
memory up to 16 MiB (1 MiB on the Amiga) and in a scratch file beside the pack
beyond. `thin-pack` is not asked for, so a pack whose delta base is not in it
is refused and never stored. The refs are written into `packed-refs` as a
mirror fetch does (forced, nothing pruned), a new repository's `HEAD` is the
server's symref, and `info/refs` and `objects/info/packs` are what `git
update-server-info` writes. Sizes are 64-bit; a pack larger than the platform's
files (2 GiB on AmigaOS 3) is refused. With `GIT_FETCH=program` the `git`
program (`GIT`) is run instead, only for the clone or the fetch. The hooks are
written by Omi, calling `GITEA_BINARY`, which is only written into them, never
run.

What is written:

| | |
|---|---|
| owner | when Gitea has no user or organization of that name: an organization (with its Owners team, all team units, and the importing user in it) or a user that cannot log in; the GitHub avatar |
| git | a bare mirror - heads, tags and `refs/pull/*` - made as `git clone --mirror` makes it (`HEAD`, `config`, `description`, `info/exclude`), fetched in Pascal (or by `git clone --mirror` with `GIT_FETCH=program`) into a temporary folder beside `<ROOT>/<owner>/<repo>.git`, no origin remote, Gitea's hooks (`pre-receive`, `update`, `post-receive`, `proc-receive` and their `.d/gitea`, byte for byte as `modules/git/hooks.go` writes them, calling `GITEA_BINARY` with this app.ini), `git-daemon-export-ok` for a public repository of a public owner, server info; renamed into place just before the commit. The wiki likewise, when GitHub has one. No `commit-graph` is written |
| repository | `repository` (`original_service_type` 2, `original_url`, default branch, description, website, private, archived, topics, `is_empty`, object format, sizes), its eight `repo_unit` rows with Gitea's default configs, `topic`/`repo_topic`, `team_repo` and `access` for the teams that have every repository, `watch` for the importing user and those team members, `branch` rows |
| content | `label`, `milestone` (no due date is 9999-01-01, as the migration writes), `issue` and `issue_label`, `pull_request` (merged ones with `merged_commit_id` and `merger_id`; open ones in the Checking state, which Gitea checks at its start), `comment`, `release` (`sha1` and `num_commits` read from git in Pascal; `is_tag` rows for tags without a release), `attachment` for release files and for the GitHub files linked from issue and comment bodies |
| counters | what Gitea's `check_repo_stats` keeps: issue, pull request, milestone, watch and star counts, label and milestone issue counts, comment counts, `issue_index`, `git_size`/`size`, the owner's `num_repos`, team `num_repos` |

Authors: a GitHub user linked to a Gitea user (`external_login_user`, provider
`github`) is that user; anyone else is the importing user (`GITEA_DOER`, else the
first administrator) with `original_author` and `original_author_id`, as Gitea's
migration does - Gitea then shows the GitHub login.

**Incremental.** Run it again to bring in only what is new or changed: git is
fetched into the repository (heads, tags, pull refs), issues, pull requests and
comments are asked with GitHub's `since` (ten minutes before the last import
began), labels, milestones and releases are listed again, and a release file
with the same GitHub id, size and `updated_at` is not downloaded again. Gitea
has no column for GitHub's ids, so the mapping is kept in
`<APP_DATA_PATH>/omi/github-map.db` (`owner_map`, `repo_map`, `item_map`),
written in the same transaction as Gitea's rows (`ATTACH`). Issues also match
by number, labels and milestones by name and releases by tag, so a lost mapping
does not duplicate them. Nothing is deleted from Gitea when it is gone from
GitHub. Deleting an owner removes its mapping too.

New files (attachments, a new git folder) are written before the transaction
and listed in the journal; one that no row uses after it - because the import
failed - is removed. A replaced release file's old file is removed after the
commit.

Not imported: reactions, reviews and review comments on lines, LFS objects,
Actions, and the branches of pull requests from forks (their
`refs/pull/<n>/head` is there).

After an import, `gitea doctor check --all` finds nothing it did not find
before, and Gitea serves the repository, its issues, comments, attachments,
pull request, release files, tags and topics through its API and git over
HTTP (tested against a copy of the test Gitea and a fake GitHub).

## Jobs

A write runs in the background, in a thread of the server, so it outlives the
request (where the server is built without threads - the Amiga - it runs inside
the request that starts it, and the page that follows shows its finished
log). Its output goes to `gitea-jobs/<time>-<kind>-<owner>.log`
in the Omi folder (`GITEA_JOBS_DIR`), which ends with `exit <code>`.
`/gitea/jobs` lists the jobs, newest first, and `/gitea/jobs/<name>` shows a
log. A job name is never a path.

**Progress.** A delete writes `progress <done>/<total> <step>` lines to its
log as it works: one step per table it deletes rows from, one for the commit,
and one per file or folder it removes after that; an import writes one per
repository. A job's page shows the newest of them as a bar and a percentage
with the step, then the job's error lines in red (`omi: ...` and any line with
"error" or "failed"), its 15 newest lines, and the whole log without the
progress lines. **Refresh** reads the log again; while a job runs, each click
shows how far it has got.

**Stop**, on a running import's page, leaves `<name>.stop` beside its log. The
import reads it before every request to GitHub and every second of a rate
limit wait, and stops the way a failed request stops it: the open write is
rolled back, the new files no row uses are removed, and the log ends with
`omi: stopped` and `exit 1`. What was committed before - the repositories
already imported - stays, and the next import brings in the rest. A delete
has no Stop: it is one short write. From a terminal, `gitea import
--stop-file FILE` stops when FILE exists.

## Settings for writing

| Setting | Default | What it is |
|---------|---------|------------|
| `GITEA_PID_FILE` | none | Gitea's PID file, when it is started with `--pid` |
| `GITHUB_TO_GITEA_DIR` | `../gitea-patches/mirror` | github-to-gitea's `mirror` directory, where the shared exclude file is |
| `GITHUB_TOKEN` | - | Typed on the Settings page, saved to `settings/github-token.ini` (`GITHUB_TOKEN_FILE`) with mode 0600; never shown, never in `settings.ini`, never on a command line or in a log |
| `SYNC_EXCLUDE_FILE` | `<GITHUB_TO_GITEA_DIR>/github-to-gitea/github-to-gitea.exclude.txt` | the repositories no longer synced, shared with github-to-gitea |
| `GITEA_DOER`, `GITEA_BINARY` | the first administrator; found from an existing repository's hooks | for importing |
| `GIT_FETCH` | `pascal` | `pascal`: git is fetched and read by Omi itself. `program`: the `git` program runs for the clone and the fetch, and only for them |
| `GIT` | found | the `git` program: on the Amiga the first of `C:git`, `C:amiga-git` and `C:am-git` (Aminet's `dev/misc/amiga-git` and `dev/misc/am-git`), elsewhere `git` on the `PATH`. Its `--version` is printed when the server starts and shown on the Settings page beside the field |

From a terminal:

```
./public/server gitea status --config app.ini
./public/server gitea delete-owner --config app.ini --owner NAME --dry-run [--json]
./public/server gitea delete-owner --config app.ini --owner NAME --confirm NAME
```

## Translations

The pages' strings come from the two places WeKan's prototypes take them
from, copied into Omi's `public/i18n/` catalogs:

- the Gitea folder strings (`gitea-*`) and the general words (`avatars`,
  `stats-count`, `database-migration`, `reason`, `billing-total`, `vcs-wiki`)
  from WeKan's catalogs, `imports/i18n/data/<lang>.i18n.json`, where the
  `gitea-*` strings were added for every WeKan locale;
- Gitea's own terms (`gitea-organization`, `gitea-user`, `gitea-packages`,
  `gitea-versions`, `gitea-lfs`) from gitea-patches'
  `dist/translations/gitea-locale/locale_<lang>.json` (Gitea's keys
  `organization`, `concept_user_user`, `packages.title`, `packages.versions`,
  `repo.settings.lfs`); a language Gitea has no translation for shows them in
  English.

A change to these strings is made in WeKan (or in gitea-patches) and copied
here, never in Omi alone. `tests/gitea_test.py` checks that every language
file has every key the pages use, and that each `gitea-*` value is WeKan's.

## On the Amiga, and what only Omi does

The writes are made to run where only Omi runs - an Amiga with the Gitea
folder on its disk, with no Gitea, no Go, no Python and no git:

- **git in Pascal** (`public/omigit.pas`), the default (`GIT_FETCH=pascal`):
  the fetch over git's smart HTTP protocol, the pack and its `.idx` version 2,
  the refs, and every read the import makes (refs, tags, commit times,
  subjects and counts). The Aminet clients amiga-git and am-git are found
  (`C:git`, `C:amiga-git`, `C:am-git`) and shown, but run only with
  `GIT_FETCH=program`.
- **Paths**: every path of the Gitea folder is built with `GtPath`
  (`PathDelim`, and nothing after a volume name: `Work:` and `gitea` are
  `Work:gitea`, never `Work:/gitea`, which is the parent of the volume). An
  absolute path is `Volume:dir/file`; app.ini's paths must be Amiga paths or
  relative to its work directory (a Unix path such as `/var/lib/gitea` means
  the parent drawer there). Directories are made with `GtForceDirs`:
  SysUtils' `ForceDirectories` asks for `Work:/` and fails.
- **What only Unix has** - lstat, fsync, rename over a file, `O_EXCL`,
  `kill(pid, 0)`, realpath, `/proc`, the port probe and the BaseUnix, Unix
  and Sockets units - is behind `{$IFDEF UNIX}`, with SysUtils' `FindFirst`,
  `RenameFile`, `FileCreate` and `FileFlush` elsewhere. A source scan in
  `tests/gitea_test.py` keeps it so.
- **"Is Gitea running?"** reads `/proc` and asks Gitea's port where there are
  such things (Unix). On every platform it checks the PID file, takes Omi's
  own lock, and refuses a database another program holds locked
  (SQLITE_BUSY). Where nothing tells whether a process lives (the Amiga), a
  Gitea PID file that is there refuses the write - Gitea removes it when it
  stops - and Omi's lock is never taken over by itself: delete it by hand
  when no Omi runs.
- **Big files**: AmigaOS 3's dos.library addresses files of less than 2 GiB.
  A download and a received pack are streamed straight to their files and
  refused, with an error that says so, when they would grow past that; no
  pack or object is ever held whole in memory (an object a delta needs whole
  is in memory only up to 1 MiB there, else in a scratch file).
- **No threads**: the Amiga build has no thread manager (`-dOMI_THREADS`
  would take FreePascal's athreads): the web server answers one request at a
  time, and a Gitea job runs inside the request that starts it.
- **No TLS**: FreePascal has no TLS for the Amiga (no AmiSSL binding), so
  `https://` - GitHub's API and github.com - is refused with why; only
  `http://` addresses can be fetched there (a mirror, or a TLS proxy on
  another machine).
- **SQLite**: Gitea's database is in WAL mode. The Amiga build of SQLite
  keeps WAL and defaults to `locking_mode=EXCLUSIVE`, which SQLite documents
  as making WAL work without shared memory; the journal mode is not changed,
  so Gitea gets its WAL database back. Its VFS is `unix-dotfile`, whose lock
  is an exclusive AmigaDOS `Lock()` on `<database>.lck` (gfopensqlite's
  patch).
- The Amiga file systems Omi can write to (FFS long names, PFS3, SFS) hold
  names of up to 107 characters and are case-insensitive: an import refuses a
  name longer than that, and one that differs from an existing folder only in
  case (this Gitea's longest name is 104 characters).

### Building it

```
OMI_BUILD_ONLY=1 ./freepascalserver.sh     # caches and checks build/sqlite3.c
./releases/amiga/build.sh                  # build/amiga/omi68k
python3 -I tests/amiga_test.py             # runs it in vamos beside the Linux build
```

`releases/amiga/build.sh` needs, outside this repository (`OMI_AMIGA_CROSS`,
by default WeKan's `.tools/tmp/welite-amiga-cross`, as WeLite's
`docs/cross.md` describes): FreePascal 3.2.3's `ppcross68k` and its
m68k-amiga units, vasm and vlink 0.18a, bebbo's m68k-amigaos GCC 16.2 with
libnix (on an ARM host its x86-64 programs run under QEMU, as its own
wrapper runs them), and gfopensqlite's patches. SQLite 3.53.4 is compiled for
the 68020 with a 68881 (or a 68040's FPU), gfopensqlite's AmigaDOS patches
applied, WAL kept, `SQLITE_DEFAULT_LOCKING_MODE=1`, and
`SQLITE_MINIMUM_FILE_DESCRIPTOR=0` (libnix numbers its files from 0, so
SQLite must not open `/dev/null` to keep 0-2 free). `public/omiamiga.pas`
links it and gives libnix `_SysBase` and `_exit`; libnix and libgcc are
linked without their debug sections, which vlink cannot relocate.

FreePascal 3.2.3's `FileCreate` for the Amiga returns an unset handle when
AmigaDOS cannot open the file: Omi refuses a file in a drawer that is not
there before creating it.

### What was verified, and what was not

Verified on Linux (aarch64): everything above in `tests/gitea_test.py`, with
git http-backend serving the repositories and a copy of the test Gitea
checked by `gitea doctor` after imports in both fetch modes.

Verified in vamos (amitools' emulator of a 68040 with its own dos.library, on
this disk), by `tests/amiga_test.py`: the m68k build starts; indexes a
REF_DELTA pack with an `.idx` byte for byte as git index-pack writes it;
reads every ref, peeled tag, commit time, subject and count as the Linux
build does (packed and loose objects); resolves the fixture's paths as
`work:g/data`; reads the fixture's Gitea database with the m68k SQLite and
reports the same sizes; and deletes an owner - lock, one transaction, the
journal, the files - leaving the database and the folder exactly as the
Linux build does, integrity check ok.

Not verified: anything on a real Amiga or under FS-UAE/AROS (none is
installed here); the web server and the fetch over HTTP on the Amiga (vamos
has no TCP/IP stack, `bsdsocket.library`); an import on the Amiga (it needs
the network); Gitea's real WAL database opened there (the fixture's database
is not in WAL mode); files near 2 GiB there (the refusal is tested on Linux
with a lowered limit); the Aminet amiga-git and am-git programs with
`GIT_FETCH=program`; and the threaded build with `-dOMI_THREADS` (vamos does
not create processes).

## Code and tests

- `public/omigitea.pas` - app.ini and the paths, the read-only queries, the
  size index (from the disk or a `tree -s` listing) and the report: sizes,
  mismatches, orphans, sorting.
- `public/server.pas` - `GiteaEndpoint` and its pages, the Gitea menu entry,
  `GITEA_APP_INI` and `GITEA_TREE` on the Settings page, and `GiteaCli`.
- `public/omigiteaw.pas` - the writes: whether Gitea runs, the lock and the
  journal, deleting a repository or an owner (`GW_SETS`, `GW_DELETES`,
  `GW_KEPT`, `GW_RECOUNT`, `GW_AFTER`), the deletion record, the exclude file.
- `public/omigiteai.inc` - importing from GitHub: the GitHub client, the owner,
  git and Gitea's hooks, the rows, the files, the counters, the mapping, and
  `GIT` / `GIT_FETCH`.
- `public/omigit.pas` - git in Pascal: the bare repository, its packs and
  loose objects, its refs, the fetch over smart HTTP, index-pack and
  update-server-info.
- `public/omiamiga.pas`, `releases/amiga/` - the Amiga build: SQLite for
  m68k, the libnix glue, `build.sh`.
- `tests/git_http.py` - git http-backend run as CGI by the test's own web
  server (used by `tests/fake_github.py` under `/git`).
- `tests/amiga_test.py` - the Amiga build in vamos beside the Linux build.
- `tests/fake_github.py` - a fake GitHub (API, file links, avatar, local bare
  repositories) whose answers a test changes between two imports.
- `tests/gitea_live.py` - a copy of the disposable test Gitea on a free port:
  started, stopped, asked through its API, checked with `gitea doctor`.
- `tests/make_gitea_fixture.py` - a small Gitea folder: Gitea's schema copied
  from a Gitea database (schema only, read-only), rows of its own, and files of
  known sizes, with known mismatches and orphans; and a `tree -s` listing of it.
- `tests/gitea_test.py` - app.ini and the storage rules; every size, mismatch
  and orphan of the fixture measured from the disk, from `tree -s` and from
  `tree -a -s -F`; the pages, clicked through like a browser without
  JavaScript (escaping, no secret column shown); refusals (no session, a used
  token, `..`, an encoded `/`, NUL, names Gitea does not allow); and, when
  `.tools/gitea.db` (or `$OMI_REAL_GITEA_DB`) is there, the real database
  opened read-only: every owner and repository listed, sizes from
  `.tools/gitea-tree.txt` (or `$OMI_REAL_GITEA_TREE`), no password hash, salt,
  e-mail address or token in the output, and the database and its WAL
  unchanged. Deleting: the dry run's numbers, refusals (no or a wrong typed
  name, a name in another case, `../` and other names that are not names,
  Gitea's port answering, a living lock), a stale lock taken over, an
  interrupted journal finished, exactly the owner's files and rows gone and
  the others' kept; every owner/repository column of the schema handled; from
  the pages: the dry run, a wrong name, a token for another owner, the job and
  its log; the GitHub token saved write-only. Against a copy of the test Gitea:
  an organization made through the API, the delete refused while Gitea runs,
  then done with it stopped, `gitea doctor check --all` finding nothing new,
  and Gitea answering 404 for it. Importing from the fake GitHub into a copy
  of the test Gitea: refused while Gitea runs (and GitHub not even asked),
  then done, doctor finding nothing new, Gitea serving everything through its
  API (a release file byte for byte) and git; a second import bringing only
  the changed issue, the new issue, the new comment and the new commit, with
  `since`, and not downloading the release file again; then the imported
  organization deleted, with its mapping, doctor still clean; an excluded
  repository left out of the import. Deleting one repository: the dry run per
  kind (a shared LFS object kept), refusals (no, a partial, another case's
  or the owner's name; `../` and other names; Gitea's port answering), the
  owner and the other repository kept with `num_repos` recounted, the record,
  the index marked stale, the exclude; the exclude file read with
  github-to-gitea's rules, malformed names refused, include again keeping
  comments; from the pages: not syncing and including again, a forged token,
  the dry run, a wrong name, the job, and the deleted repository on the Sizes,
  owner and repository pages without a link; on a copy of the test Gitea:
  refused while running, deleted with it stopped, doctor finding nothing new,
  the other repository and the owner kept. git in Pascal against git
  http-backend: a first and an incremental fetch, deltas from the server, the
  `.idx` byte for byte as git index-pack writes it (OFS_DELTA and REF_DELTA),
  a thin pack and a damaged pack refused, every object in a scratch file, a
  pack too large for the platform refused, an empty repository, `info/refs`
  as git update-server-info writes it, every ref read as git says (loose
  ones too); git fsck --full --strict, git log and git ls-remote. The import
  over smart HTTP with no git program running, and again with
  `GIT_FETCH=program`, where git runs once, to clone. `GIT` and `GIT_FETCH`
  with a fake git on the `PATH`, at the start and on Settings. The source
  scan: no path built with a `/` literal, nothing Unix-only outside
  `{$IFDEF UNIX}`, no `ForceDirectories`, in the Gitea units.

```
TMPDIR=/some/scratch python3 -I tests/gitea_test.py
```

Set `OMI_SKIP_BUILD=1` to test the `public/server` that is already built, or
`OMI_KEEP_TEST_DIR=1` to keep the scratch directory.
