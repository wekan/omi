#!/usr/bin/env python3
"""Writes github-to-gitea backups (gitea_backup.py FORMAT 1) for Omi's tests,
without a Gitea:

  python3 -I tests/make_backup_fixture.py <backups dir>

  <dir>/acme/acme.db, acme.zip                              the owner's one backup:
                                                            seen per row, meta runs,
                                                            and old data (seen < runs)
  <dir>/beta/beta.db, beta.zip                              another one, with old data
  <dir>/sample/2026-01-01_00-00-00/sample.db, sample.zip    a dated one, plain end record
  <dir>/zsixtyfour/2026-02-02_10-20-30/zsixtyfour.db, .zip  dated, ZIP64 end records
  <dir>/sample/2026-03-03_00-00-00.partial/                 unfinished: never listed

A dated backup is what github-to-gitea wrote before it kept one backup per owner;
it has no seen column and no meta runs. The owner's one backup has a seen column
in every data table: the run in which the row was last seen at the source, and
meta runs, the newest run. Rows with seen < runs are old data.

Each .zip is STORED with ZIP64 local extras (zipfile force_zip64=True), as
gitea_backup writes it. The schema is gitea_backup.SCHEMA.
"""
import hashlib
import json
import os
import sqlite3
import struct
import sys
import zipfile

SCHEMA = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE owner(name TEXT PRIMARY KEY, kind TEXT, json TEXT);
CREATE TABLE teams(id INTEGER PRIMARY KEY, name TEXT, json TEXT, members TEXT, repos TEXT);
CREATE TABLE members(login TEXT PRIMARY KEY, json TEXT);
CREATE TABLE repos(full_name TEXT PRIMARY KEY, name TEXT, json TEXT, topics TEXT,
                   git_bundle TEXT, wiki_bundle TEXT, empty INTEGER, collaborators TEXT);
CREATE TABLE labels(repo TEXT, id INTEGER, name TEXT, json TEXT, PRIMARY KEY(repo, id));
CREATE TABLE milestones(repo TEXT, id INTEGER, title TEXT, json TEXT, PRIMARY KEY(repo, id));
CREATE TABLE issues(repo TEXT, number INTEGER, is_pull INTEGER, title TEXT, state TEXT, json TEXT,
                    PRIMARY KEY(repo, number));
CREATE TABLE pulls(repo TEXT, number INTEGER, json TEXT, PRIMARY KEY(repo, number));
CREATE TABLE comments(repo TEXT, id INTEGER, issue_number INTEGER, json TEXT, PRIMARY KEY(repo, id));
CREATE TABLE releases(repo TEXT, id INTEGER, tag TEXT, json TEXT, PRIMARY KEY(repo, id));
CREATE TABLE files(path TEXT PRIMARY KEY, repo TEXT, kind TEXT, parent TEXT, id INTEGER,
                   name TEXT, size INTEGER, sha256 TEXT, uuid TEXT, json TEXT);
CREATE INDEX files_parent ON files(repo, kind, parent);
CREATE INDEX comments_issue ON comments(repo, issue_number);
"""

# A 1x1 PNG.
PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000d49444154789c6360f80f000001010100a5d2f1b40000000049454e44ae426082")
NOTES = b"First line of the notes\nSecond line: <b>not bold</b> & more\n"
BIG = b"".join(b"line %06d of a big text file\n" % i for i in range(40000))  # ~1.2 MB: over the edit limit
MEDIUM = b"".join(b"medium %06d\n" % i for i in range(30000))  # ~400 KB: shown partly, edited whole
BUNDLE = bytes(range(256)) * 64

DATA_TABLES = ("owner", "teams", "members", "repos", "labels", "milestones", "issues", "pulls",
               "comments", "releases", "files")
RUNS = 3
# The old data of a current backup: zip entries only an older run saw.
OLD_FILE = b"an attachment of an issue deleted at the source\n" * 40
OLD_ASSET = bytes(range(256)) * 40
GONE_BUNDLE = b"# v2 git bundle\n" + bytes(range(256)) * 20
OLD_ENTRIES = {"proj/issues/4/12-old.txt": OLD_FILE, "proj/releases/v0.9/old.bin": OLD_ASSET,
               "gone/git.bundle": GONE_BUNDLE}

HOSTILE = "Body of the issue <script>alert(1)</script> & <b>bold</b>\nPäivää!"


def dumps(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def make(root, owner, stamp, zip64_end=False):
    """A backup; stamp None is the owner's one backup (no datetime directory)."""
    current = stamp is None
    d = os.path.join(root, owner) if current else os.path.join(root, owner, stamp)
    os.makedirs(d, exist_ok=True)
    db = sqlite3.connect(os.path.join(d, f"{owner}.db"))
    db.executescript(SCHEMA)
    if current:
        for t in DATA_TABLES:
            db.execute(f"ALTER TABLE {t} ADD COLUMN seen INTEGER")
    z = zipfile.ZipFile(os.path.join(d, f"{owner}.zip"), "w", zipfile.ZIP_STORED, allowZip64=True)

    def row(table, seen=RUNS, **values):
        if current and table != "meta":
            values["seen"] = seen
        db.execute(f"INSERT OR REPLACE INTO {table}({', '.join(values)}) VALUES "
                   f"({', '.join('?' * len(values))})", list(values.values()))

    def add(path, data, repo=None, kind=None, parent=None, fid=None, name=None, seen=RUNS):
        info = zipfile.ZipInfo(path, (2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_STORED
        with z.open(info, "w", force_zip64=True) as out:
            out.write(data)
        if repo is not None:
            row("files", seen=seen, path=path, repo=repo, kind=kind, parent=str(parent), id=fid, name=name,
                size=len(data), sha256=hashlib.sha256(data).hexdigest(), uuid="", json="{}")

    for k, v in {"format": "1", "created": "2026-01-01T00:00:00+00:00", "gitea": "http://gitea.invalid",
                 "owner": owner, "kind": "organization", "complete": "yes"}.items():
        row("meta", key=k, value=v)
    if current:
        for k, v in {"runs": str(RUNS), "updated": "2026-03-01T00:00:00+00:00", "sources": "gitea,github",
                     "source": "github", "merged": '["2026-01-01_00-00-00", "2026-02-01_00-00-00"]',
                     "kept": "Rows and files that disappeared at the source are kept; seen < runs marks them."
                     }.items():
            row("meta", key=k, value=v)
    row("owner", name=owner, kind="organization", json=dumps({"username": owner,
        "full_name": f"The {owner} organization", "description": "Org <i>description</i>"}))
    row("members", login="alice", json=dumps({"login": "alice"}))
    row("members", login="bob", json=dumps({"login": "bob"}))
    add("owner/avatar.png", PNG, "", "avatar", "", 0, "avatar.png")

    full = f"{owner}/proj"
    row("repos", full_name=full, name="proj", json=dumps({"full_name": full, "name": "proj",
        "description": "A sample project"}), topics="[]", git_bundle="proj/git.bundle",
        wiki_bundle=None, empty=0, collaborators="[]")
    row("repos", full_name=f"{owner}/docs", name="docs", json=dumps({"full_name": f"{owner}/docs",
        "name": "docs", "description": "Documentation"}), topics="[]", git_bundle=None,
        wiki_bundle=None, empty=1, collaborators="[]")
    row("labels", repo=full, id=1, name="bug", json=dumps({"id": 1, "name": "bug", "color": "eb4646",
        "description": "Something is broken"}))
    row("milestones", repo=full, id=1, title="v1", json=dumps({"id": 1, "title": "v1", "state": "open",
        "open_issues": 1, "closed_issues": 1, "due_on": "2026-06-01T00:00:00Z"}))
    issues = [(1, 0, "open", "Sample open issue", HOSTILE),
              (2, 1, "closed", "Sample merged PR <em>x</em>", "Merges a feature"),
              (3, 0, "closed", "Sample closed issue", "")]
    for n, pull, state, title, body in issues:
        row("issues", repo=full, number=n, is_pull=pull, title=title, state=state, json=dumps({
            "number": n, "title": title, "body": body, "state": state, "user": {"login": "alice"},
            "labels": [{"id": 1, "name": "bug"}] if n == 1 else [], "created_at": f"2025-12-0{n}T10:00:00Z",
            **({"pull_request": {"merged": True}} if pull else {})}))
    row("pulls", repo=full, number=2, json=dumps({"number": 2, "merged": True, "title": issues[1][3],
        "body": issues[1][4], "head": {"label": "feature"}, "base": {"label": "main"}}))
    row("comments", repo=full, id=10, issue_number=1, json=dumps({
        "id": 10, "body": "Sample comment text", "user": {"login": "bob"}, "created_at": "2025-12-01T12:00:00Z"}))
    row("comments", repo=full, id=11, issue_number=2, json=dumps({
        "id": 11, "body": "Looks good", "user": {"login": "alice"}, "created_at": "2025-12-02T12:00:00Z"}))
    row("releases", repo=full, id=100, tag="v1.0", json=dumps({"id": 100, "tag_name": "v1.0",
        "name": "First release", "body": "Release notes body", "author": {"login": "alice"},
        "published_at": "2025-12-05T10:00:00Z"}))

    add("proj/git.bundle", BUNDLE)
    add("proj/issues/1/5-notes.txt", NOTES, full, "issues", 1, 5, "notes.txt")
    add("proj/issues/1/6-pic.png", PNG, full, "issues", 1, 6, "pic.png")
    add("proj/issues/3/8-päivä.txt", "Päivää maailma\n".encode(), full,
        "issues", 3, 8, "päivä.txt")
    add("proj/comments/1/10/7-log.txt", b"comment log\r\nsecond line\r\n", full, "comments", 10, 7, "log.txt")
    add("proj/releases/v1.0/notes.md", b"# Notes\n\nRelease file\n", full, "releases", 100, 9, "notes.md")
    add("proj/releases/v1.0/big.txt", BIG, full, "releases", 100, 10, "big.txt")
    add("proj/releases/v1.0/medium.txt", MEDIUM, full, "releases", 100, 11, "medium.txt")
    if current:
        # Old data: what an older run saw and the newest did not.
        row("members", seen=1, login="carol", json=dumps({"login": "carol"}))
        row("teams", seen=2, id=3, name="oldteam", json=dumps({"id": 3, "name": "oldteam"}), members="[]", repos="[]")
        row("labels", seen=2, repo=full, id=2, name="wontfix", json=dumps({"id": 2, "name": "wontfix",
            "color": "ffffff"}))
        row("milestones", seen=2, repo=full, id=2, title="v0", json=dumps({"id": 2, "title": "v0", "state": "closed"}))
        row("issues", seen=2, repo=full, number=4, is_pull=0, title="Deleted at the source", state="open",
            json=dumps({"number": 4, "title": "Deleted at the source", "body": "Only an older run saw this.",
                        "state": "open", "user": {"login": "carol"}, "created_at": "2025-12-04T10:00:00Z"}))
        row("comments", seen=2, repo=full, id=12, issue_number=4, json=dumps({
            "id": 12, "body": "An old comment", "user": {"login": "carol"}, "created_at": "2025-12-04T12:00:00Z"}))
        add("proj/issues/4/12-old.txt", OLD_FILE, full, "issues", 4, 12, "old.txt", seen=2)
        row("releases", seen=1, repo=full, id=99, tag="v0.9", json=dumps({"id": 99, "tag_name": "v0.9",
            "name": "Old release", "body": "Gone from the source"}))
        add("proj/releases/v0.9/old.bin", OLD_ASSET, full, "releases", 99, 13, "old.bin", seen=1)
        gone = f"{owner}/gone"
        row("repos", seen=1, full_name=gone, name="gone", json=dumps({"full_name": gone, "name": "gone",
            "description": "A repository gone from the source"}), topics="[]", git_bundle="gone/git.bundle",
            wiki_bundle=None, empty=0, collaborators="[]")
        row("issues", seen=1, repo=gone, number=1, is_pull=0, title="Issue of a gone repository", state="open",
            json=dumps({"number": 1, "title": "Issue of a gone repository", "body": "", "state": "open",
                        "user": {"login": "carol"}}))
        add("gone/git.bundle", GONE_BUNDLE)
    db.commit()
    db.close()
    z.close()
    if zip64_end:
        to_zip64_end(os.path.join(d, f"{owner}.zip"))
    with zipfile.ZipFile(os.path.join(d, f"{owner}.zip")) as check:
        assert check.testzip() is None
    return d


def to_zip64_end(path):
    """Replaces the plain end record with a ZIP64 end record, its locator and an
    end record whose fields say 'see ZIP64', as a zip with more than 65535
    entries or over 4 GiB has."""
    with open(path, "r+b") as f:
        f.seek(-22, os.SEEK_END)
        end = f.read(22)
        sig, _, _, n, total, cd_size, cd_offset, comment = struct.unpack("<IHHHHIIH", end)
        assert sig == 0x06054b50 and comment == 0
        f.seek(-22, os.SEEK_END)
        f.truncate()
        z64 = f.tell()
        f.write(struct.pack("<IQHHIIQQQQ", 0x06064b50, 44, 45, 45, 0, 0, total, total, cd_size, cd_offset))
        f.write(struct.pack("<IIQI", 0x07064b50, 0, z64, 1))
        f.write(struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0))


if __name__ == "__main__":
    root = sys.argv[1]
    make(root, "acme", None)
    make(root, "beta", None)
    make(root, "sample", "2026-01-01_00-00-00")
    make(root, "zsixtyfour", "2026-02-02_10-20-30", zip64_end=True)
    os.makedirs(os.path.join(root, "sample", "2026-03-03_00-00-00.partial"), exist_ok=True)
    make(root, "sample", "2026-03-03_00-00-00.partial")
    print(root)
