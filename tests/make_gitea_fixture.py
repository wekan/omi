#!/usr/bin/env python3
"""A small Gitea folder for Omi's tests: custom/conf/app.ini, data/gitea.db with
Gitea's own schema and a few rows, and the files the rows point at - with a known
size for every owner and repository, and known mismatches and orphans.

The schema is copied (read-only, schema only) from a Gitea database: the
disposable test Gitea's, $OMI_GITEA_SCHEMA_DB, or the one given to make(). No row
of that database is read.

  python3 -I tests/make_gitea_fixture.py <dir> [schema.db]
"""
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))  # .tools
SCHEMA_CANDIDATES = [
    os.environ.get("OMI_GITEA_SCHEMA_DB", ""),
    os.path.join(TOOLS, "tmp", "gitea-backup-test", "data", "gitea.db"),
    os.path.join(TOOLS, "gitea.db"),
]

ATT_BIG = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"      # acme/big, issue 1
ATT_REL = "2c5f39cb-3fb2-42e3-994f-1127e4ddb538"      # acme/big, release v1
ATT_MISSING = "3d6a4adc-4ac3-43f4-aa5a-2238f5eec649"  # acme/small: row, no file
ATT_SIZE = "4e7b5bed-5bd4-44a5-bb6b-3349a6ffd75a"     # bob/tool: file 300, row says 200
ATT_ORPHAN = "5f8c6cfe-6ce5-45b6-8c7c-445ab7aae86b"   # a file, no row
OID_SHARED = "aa" * 32   # acme/big and acme/small
OID_BOB = "bb" * 32      # bob/tool
OID_MISSING = "cc" * 32  # acme/small: row, no file
OID_ORPHAN = "dd" * 32   # a file, no row
PKG_SHA = "ee" * 32      # bob's package blob
AVATAR_ACME = "a1" * 32
AVATAR_ORPHAN = "f0" * 32

# What the tests expect, in bytes.
SIZES = {
    "acme/big.git": 5000 + 1000 + 24,       # pack, idx, HEAD
    "acme/big.wiki.git": 700,
    "acme/small.git": 2000,
    "bob/tool.git": 3000,
    "att_big": 1234, "att_rel": 4321, "att_size_file": 300, "att_orphan": 99,
    "lfs_shared": 10000, "lfs_bob": 2500, "lfs_orphan": 77,
    "pkg": 8192, "avatar_acme": 640, "avatar_orphan": 55,
    "orphan_git": 111,
}


def schema_db():
    for path in SCHEMA_CANDIDATES:
        if path and os.path.isfile(path):
            return path
    raise SystemExit("no Gitea database to copy the schema from (set OMI_GITEA_SCHEMA_DB)")


def copy_schema(src, dst):
    s = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
    sql = [r[0] for r in s.execute("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' "
                                   "ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END, name")]
    version = s.execute("SELECT version FROM version").fetchone()[0]
    s.close()
    d = sqlite3.connect(dst)
    for q in sql:
        d.execute(q)
    d.execute("INSERT INTO version (id, version) VALUES (1, ?)", (version,))
    d.commit()
    return d


def write(path, size, fill=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write((fill * size)[:size])


def insert(db, table, **cols):
    have = {r[1] for r in db.execute(f"PRAGMA table_info(`{table}`)")}
    cols = {k: v for k, v in cols.items() if k in have}
    db.execute(f"INSERT INTO `{table}` ({', '.join('`' + k + '`' for k in cols)}) VALUES ({', '.join('?' * len(cols))})",
               list(cols.values()))
    return db.execute("SELECT last_insert_rowid()").fetchone()[0]


def make(work, schema=None):
    data = os.path.join(work, "data")
    os.makedirs(os.path.join(work, "custom", "conf"), exist_ok=True)
    os.makedirs(data, exist_ok=True)
    with open(os.path.join(work, "custom", "conf", "app.ini"), "w") as f:
        f.write("APP_NAME = fixture\nRUN_MODE = prod\n\n[server]\nHTTP_ADDR = 127.0.0.1\nHTTP_PORT = 1\n\n"
                "[database]\nDB_TYPE = sqlite3\nPATH = data/gitea.db\n\n[repository]\nROOT = data/gitea-repositories\n")
    db = copy_schema(schema or schema_db(), os.path.join(data, "gitea.db"))
    now = 1767225600
    secret = "SECRET-not-to-be-shown"
    acme = insert(db, "user", lower_name="acme", name="acme", full_name="Acme <b>Org</b>", email="", passwd="",
                  type=1, avatar=AVATAR_ACME, avatar_email="", use_custom_avatar=1, visibility=0, created_unix=now,
                  updated_unix=now, is_active=1, num_repos=2, num_teams=0, num_members=0, rands=secret, salt=secret)
    bob = insert(db, "user", lower_name="bob", name="Bob", full_name="Bob B", email="bob-" + secret + "@example.org",
                 passwd=secret, passwd_hash_algo="argon2", type=0, avatar="", avatar_email="bob@example.org",
                 created_unix=now, updated_unix=now, is_active=1, num_repos=1, rands=secret, salt=secret)
    insert(db, "user", lower_name="empty", name="empty", email="", passwd="", type=0, avatar="", avatar_email="",
           created_unix=now, updated_unix=now)

    def repo(owner_id, owner, name, git, lfs):
        return insert(db, "repository", owner_id=owner_id, owner_name=owner, lower_name=name.lower(), name=name,
                      size=git + lfs, git_size=git, lfs_size=lfs, num_issues=0, num_pulls=0, is_private=0,
                      is_empty=0, is_archived=0, is_mirror=0, status=0, created_unix=now, updated_unix=now,
                      original_service_type=2, original_url="https://github.com/" + owner + "/" + name,
                      default_branch="main", topics="null", object_format_name="sha1")

    # acme/big: DB sizes right; acme/small: git_size far off (a mismatch); bob/tool right.
    big = repo(acme, "acme", "big", SIZES["acme/big.git"], SIZES["lfs_shared"])
    small = repo(acme, "acme", "small", 900000, SIZES["lfs_shared"] + 500)
    tool = repo(bob, "Bob", "tool", SIZES["bob/tool.git"], SIZES["lfs_bob"])
    db.execute("UPDATE repository SET num_issues = 1, num_pulls = 1 WHERE id = ?", (big,))

    root = os.path.join(data, "gitea-repositories")
    write(os.path.join(root, "acme", "big.git", "objects", "pack", "pack-1.pack"), 5000)
    write(os.path.join(root, "acme", "big.git", "objects", "pack", "pack-1.idx"), 1000)
    write(os.path.join(root, "acme", "big.git", "HEAD"), 24)
    os.makedirs(os.path.join(root, "acme", "big.git", "refs", "tags"), exist_ok=True)
    write(os.path.join(root, "acme", "big.wiki.git", "objects", "pack", "pack-2.pack"), 700)
    write(os.path.join(root, "acme", "small.git", "objects", "pack", "pack-3.pack"), 2000)
    write(os.path.join(root, "bob", "tool.git", "objects", "pack", "pack-4.pack"), 3000)
    write(os.path.join(root, "ghost", "gone.git", "HEAD"), SIZES["orphan_git"])  # no repository row

    i1 = insert(db, "issue", repo_id=big, index=1, poster_id=bob, original_author="", name="First <i>issue</i>",
                content="Body with <script>x</script>", is_closed=0, is_pull=0, num_comments=1,
                created_unix=now, updated_unix=now)
    i2 = insert(db, "issue", repo_id=big, index=2, poster_id=bob, original_author="octocat", original_author_id=583231,
                name="A pull request", content="PR body", is_closed=1, is_pull=1, num_comments=0,
                created_unix=now, updated_unix=now)
    insert(db, "pull_request", type=0, status=0, issue_id=i2, index=2, head_repo_id=big, base_repo_id=big,
           head_branch="feature", base_branch="main", has_merged=1, merged_unix=now)
    c1 = insert(db, "comment", type=0, poster_id=bob, issue_id=i1, content="A comment", created_unix=now,
                updated_unix=now)
    rel = insert(db, "release", repo_id=big, publisher_id=bob, tag_name="v1", lower_tag_name="v1", title="Version 1",
                 note="Notes", sha1="0" * 40, num_commits=1, is_draft=0, is_prerelease=0, is_tag=0, created_unix=now)

    att = os.path.join(data, "attachments")

    def attachment(uuid, repo_id, size, file_size=None, issue_id=0, release_id=0, comment_id=0, name="f.bin"):
        insert(db, "attachment", uuid=uuid, repo_id=repo_id, issue_id=issue_id, release_id=release_id,
               comment_id=comment_id, uploader_id=0, name=name, size=size, created_unix=now)
        if file_size is not None:
            write(os.path.join(att, uuid[0], uuid[1], uuid), file_size)

    attachment(ATT_BIG, big, SIZES["att_big"], SIZES["att_big"], issue_id=i1, name="notes.txt")
    attachment(ATT_REL, big, SIZES["att_rel"], SIZES["att_rel"], release_id=rel, name="app.zip")
    attachment(ATT_MISSING, small, 50, None, name="lost.png")
    attachment(ATT_SIZE, tool, 200, SIZES["att_size_file"], name="grown.bin")
    write(os.path.join(att, ATT_ORPHAN[0], ATT_ORPHAN[1], ATT_ORPHAN), SIZES["att_orphan"])

    lfs = os.path.join(data, "lfs")

    def lfs_obj(oid, repo_id, size, write_file=True):
        insert(db, "lfs_meta_object", oid=oid, size=size, repository_id=repo_id, created_unix=now)
        if write_file:
            write(os.path.join(lfs, oid[:2], oid[2:4], oid[4:]), size)

    lfs_obj(OID_SHARED, big, SIZES["lfs_shared"])
    lfs_obj(OID_SHARED, small, SIZES["lfs_shared"])
    lfs_obj(OID_MISSING, small, 500, write_file=False)
    lfs_obj(OID_BOB, tool, SIZES["lfs_bob"])
    write(os.path.join(lfs, OID_ORPHAN[:2], OID_ORPHAN[2:4], OID_ORPHAN[4:]), SIZES["lfs_orphan"])

    pkg = insert(db, "package", owner_id=bob, repo_id=0, type="generic", name="toolpkg", lower_name="toolpkg",
                 semver_compatible=0, is_internal=0)
    pv = insert(db, "package_version", package_id=pkg, creator_id=bob, version="1.0", lower_version="1.0",
                created_unix=now, is_internal=0, metadata_json="null", download_count=0)
    blob = insert(db, "package_blob", size=SIZES["pkg"], hash_md5="0" * 32, hash_sha1="0" * 40, hash_sha256=PKG_SHA,
                  hash_sha512="0" * 128, created_unix=now)
    insert(db, "package_file", version_id=pv, blob_id=blob, name="tool.tar", lower_name="tool.tar",
           composite_key="", is_lead=1, created_unix=now)
    write(os.path.join(data, "packages", PKG_SHA[:2], PKG_SHA[2:4], PKG_SHA), SIZES["pkg"])
    write(os.path.join(data, "avatars", AVATAR_ACME), SIZES["avatar_acme"])
    write(os.path.join(data, "avatars", AVATAR_ORPHAN), SIZES["avatar_orphan"])
    db.commit()
    db.close()
    return {"acme": acme, "bob": bob, "big": big, "small": small, "tool": tool, "issue": i1, "pull": i2,
            "comment": c1, "release": rel, "secret": secret}


def fixture_secret_free(text, secret):
    """No password, salt or e-mail address of the fixture's users in text."""
    return secret not in text and "argon2" not in text and "bob@example.org" not in text


def tree_listing(work, slashes=False):
    """What `tree -s` (with slashes: `tree -a -s -F`) prints for work: '├── [  size]  name'
    lines, indented with '│   ' and no-break spaces the way tree writes them."""
    out = [f"[{os.stat(work).st_size:>11}]  ."]
    dirs = files = 0

    def walk(path, prefix):
        nonlocal dirs, files
        names = sorted(os.listdir(path))
        for i, name in enumerate(names):
            full = os.path.join(path, name)
            last = i == len(names) - 1
            st = os.lstat(full)
            is_dir = os.path.isdir(full) and not os.path.islink(full)
            shown = name + ("/" if slashes and is_dir else "")
            # Directories as ext4 shows them: 4096 bytes, empty or not.
            size = 4096 if is_dir else st.st_size
            out.append(f"{prefix}{'└── ' if last else '├── '}[{size:>11}]  {shown}")
            if is_dir:
                dirs += 1
                walk(full, prefix + ("    " if last else "│   "))
            else:
                files += 1

    walk(work, "")
    out += ["", f"{dirs} directories, {files} files"]
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    make(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
