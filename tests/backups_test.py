#!/usr/bin/env python3
"""End-to-end test of Omi's Backups pages (public/server.pas, public/omibackup.pas).

  python3 -I tests/backups_test.py            builds with ./build.sh build first
  OMI_SKIP_BUILD=1 python3 -I tests/backups_test.py   uses the public/server already built

It makes a scratch Omi (public/server, i18n, settings/settings.ini with BACKUPS_DIR,
settings/users.ini) under $TMPDIR, writes backups with tests/make_backup_fixture.py,
starts the server on a free port, and drives it the way a browser without
JavaScript or cookies does: it logs in and then only clicks the signed POST
buttons the pages contain. It checks what the pages show and what saving
wrote into the .db and the .zip, and that saving is refused without a
session, with a used or another action's token, and for a path with '..'.
"""
import hashlib
import html
import http.client
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import make_backup_fixture as fixture  # noqa: E402

UA = "omi-backups-test/1"
NEW_KEYS = ["backup-dated", "backup-locked", "old-data", "old-data-help", "old-data-none", "old-data-no-marker",
            "delete-old-data", "delete-old-data-confirm", "delete-old-data-wrong-name", "old-data-deleted",
            "space-freed", "rows"]
FAILURES = []
PASSES = 0


def check(cond, what):
    global PASSES
    if cond:
        PASSES += 1
        print(f"ok   {what}")
    else:
        FAILURES.append(what)
        print(f"FAIL {what}")


class Browser:
    def __init__(self, port):
        self.port = port
        self.page = ""

    def request(self, method, path, fields=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        body = urllib.parse.urlencode(fields or {}, doseq=True) if method == "POST" else None
        headers = {"User-Agent": UA}
        if body is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        conn.request(method, path, body=body, headers=headers)
        r = conn.getresponse()
        data = r.read()
        result = (r.status, {k.lower(): v for k, v in r.getheaders()}, data)
        conn.close()
        return result

    def post(self, path, fields):
        status, headers, data = self.request("POST", path, fields)
        if headers.get("content-type", "").startswith("text/html"):
            self.page = data.decode("utf-8", "replace")
        return status, headers, data

    def forms(self):
        out = []
        for m in re.finditer(r'<form method="POST"(?: action="([^"]*)")?[^>]*>(.*?)</form>', self.page, re.S):
            action = html.unescape(m.group(1) or "")
            inner = m.group(2)
            fields = {}
            for i in re.finditer(r'<input type="hidden" name="([^"]*)" value="([^"]*)">', inner):
                fields[html.unescape(i.group(1))] = html.unescape(i.group(2))
            labels = [html.unescape(x) for x in re.findall(r'<input type="submit" value="([^"]*)"', inner)]
            out.append((action, fields, labels, inner))
        return out

    def find(self, action=None, label=None, **want):
        for a, fields, labels, inner in self.forms():
            if action is not None and a != action:
                continue
            if label is not None and label not in labels:
                continue
            if any(fields.get(k) != v for k, v in want.items()):
                continue
            return a, dict(fields)
        raise AssertionError(f"no button action={action} label={label} {want} on page:\n{self.page[:3000]}")

    def all_files(self, base):
        """The backup's Files page, through the backup's overview (a breadcrumb on every page)."""
        if not any(f[0] == base + "/files" for f in self.forms()):
            if not any(f[0] == base for f in self.forms()):
                self.click(action="/backups")
            self.click(action=base)
        return self.click(action=base + "/files")

    def click(self, action=None, label=None, extra=None, **want):
        a, fields = self.find(action, label, **want)
        fields.update(extra or {})
        return self.post(a or "/", fields)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    tmp_root = os.environ.get("TMPDIR") or tempfile.gettempdir()
    if os.environ.get("OMI_SKIP_BUILD") != "1":
        subprocess.run(["./build.sh", "build"], cwd=REPO, check=True)
    work = tempfile.mkdtemp(prefix="omi-backups-test.", dir=tmp_root)
    server = None
    try:
        os.makedirs(os.path.join(work, "public"))
        shutil.copy2(os.path.join(REPO, "public", "server"), os.path.join(work, "public", "server"))
        shutil.copytree(os.path.join(REPO, "public", "i18n"), os.path.join(work, "public", "i18n"))
        shutil.copy2(os.path.join(REPO, "public", "languages.json"), os.path.join(work, "public"))
        os.makedirs(os.path.join(work, "settings"), exist_ok=True)
        with open(os.path.join(work, "settings", "settings.ini"), "w") as f:
            f.write("BACKUPS_DIR=backups\n")
        with open(os.path.join(work, "settings", "users.ini"), "w") as f:
            f.write("tester:secret::en\n")
        backups = os.path.join(work, "backups")
        fixture.make(backups, "acme", None)
        fixture.make(backups, "beta", None)
        # What github-to-gitea may leave in an owner's directory: never listed.
        for extra in (".backup-work", "wekan", "2026-04-04_00-00-00.partial"):
            os.makedirs(os.path.join(backups, "acme", extra))
        fixture.make(backups, "sample", "2026-01-01_00-00-00")
        fixture.make(backups, "zsixtyfour", "2026-02-02_10-20-30", zip64_end=True)
        fixture.make(backups, "sample", "2026-03-03_00-00-00.partial")
        sample_dir = os.path.join(backups, "sample", "2026-01-01_00-00-00")
        sample_db = os.path.join(sample_dir, "sample.db")
        sample_zip = os.path.join(sample_dir, "sample.zip")
        z64_dir = os.path.join(backups, "zsixtyfour", "2026-02-02_10-20-30")

        port = free_port()
        log = open(os.path.join(work, "server.log"), "w")
        server = subprocess.Popen([os.path.join(work, "public", "server"), "--port", str(port)],
                                  cwd=work, stdout=log, stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=1).close()
                break
            except OSError:
                time.sleep(0.1)
        b = Browser(port)

        # --- not logged in ---------------------------------------------------------
        status, headers, _ = b.request("GET", "/backups")
        check(status in (302, 303) and headers.get("location") == "/", "GET /backups without a session goes home")
        status, headers, _ = b.request("POST", "/backups/sample/2026-01-01_00-00-00", {})
        check(status == 303 and headers.get("location") == "/", "POST without a session goes home")

        # --- log in and open the list ------------------------------------------------
        status, _, _ = b.post("/sign-in", {"username": "tester", "password": "secret"})
        check(status == 200 and "tester" in b.page, "login")
        b.click(action="/")
        check('action="/backups"' in b.page, "home page has the Backups menu entry")
        b.click(action="/settings")
        check('name="BACKUPS_DIR"' in b.page and "Backups directory" in b.page, "settings has BACKUPS_DIR")
        b.click(action="/backups")
        check("HTML 4.01 Transitional" in b.page, "backups page is HTML 4.01")
        check("sample" in b.page and "2026-01-01_00-00-00" in b.page and "zsixtyfour" in b.page,
              "backups list shows both backups")
        check(".partial" not in b.page and "2026-03-03" not in b.page, "a .partial backup is not listed")
        check('action="/backups/acme/current"' in b.page and 'action="/backups/beta/current"' in b.page,
              "backups list shows each owner's one backup")
        check("2026-03-01T00:00:00+00:00" in b.page, "the one backup's time is meta updated")
        check("2026-01-01_00-00-00 (dated, not combined yet)" in b.page, "a dated backup is still listed, marked")
        check("wekan" not in re.sub(r"<[^>]*>", " ", b.page).split() and ".backup-work" not in b.page
              and "2026-04-04" not in b.page, "what else is in the owner's directory is not listed")
        check("organization" in b.page, "backups list shows the kind")

        # --- overview, repository, issues ------------------------------------------
        b.click(action="/backups/sample/2026-01-01_00-00-00")
        check("sample/proj" in b.page and "sample/docs" in b.page, "overview lists the repositories")
        check("Org &lt;i&gt;description&lt;/i&gt;" in b.page and "<i>description" not in b.page,
              "owner description is escaped")
        check("alice" in b.page and "bob" in b.page, "overview lists members")
        overview = b.page
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj")
        check("Sample open issue" in b.page and "Sample closed issue" in b.page, "issues list")
        check("Sample merged PR" not in b.page, "issues list has no pull requests")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/pulls")
        check("Sample merged PR &lt;em&gt;x&lt;/em&gt;" in b.page and "<em>x" not in b.page,
              "pull requests list, title escaped")
        check("Merged" in b.page, "a merged pull request says Merged")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/2")
        check("Merges a feature" in b.page and "Looks good" in b.page and "feature -&gt; main" in b.page,
              "pull request page: body, comment, branches")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issues")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1")
        page = b.page
        check("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &lt;b&gt;bold&lt;/b&gt;" in page, "issue body is escaped")
        check("<script" not in page.lower() and "<b>bold" not in page, "no HTML from the body reaches the page")
        check("Päivää!" in page, "UTF-8 body is shown")
        check("alice" in page and "2025-12-01T10:00:00Z" in page and "bug" in page,
              "issue page shows author, date and label")
        check("Sample comment text" in page and "bob" in page, "issue page shows the comment")
        check("notes.txt" in page and "pic.png" in page, "issue page lists its files")
        check("log.txt" in page, "comment's file is listed")

        # --- releases, labels, files -------------------------------------------------
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/releases")
        check("v1.0" in b.page and "First release" in b.page and "Release notes body" in b.page
              and "notes.md" in b.page and "big.txt" in b.page, "releases page with its files")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/labels")
        check("bug" in b.page and 'bgcolor="#eb4646"' in b.page and "v1" in b.page, "labels and milestones")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/files")
        check("proj/git.bundle" in b.page and "proj/issues/1/5-notes.txt" in b.page
              and "owner/avatar.png" not in b.page, "repository files page lists the repository's zip entries")
        status, headers, _ = b.click(action="/backups/sample/2026-01-01_00-00-00/file", label="View",
                                     entry="proj/issues/1/5-notes.txt")
        check(status == 200 and "First line of the notes" in b.page
              and "&lt;b&gt;not bold&lt;/b&gt; &amp; more" in b.page, "a text file is shown, escaped")
        check(headers.get("x-content-type-options") == "nosniff", "pages send nosniff")
        check("default-src 'none'" in headers.get("content-security-policy", ""), "pages send a CSP")
        check("5" in b.page and sha(fixture.NOTES) in b.page, "file page shows the sha256 from the .db")

        status, headers, data = b.click(action="/backups/sample/2026-01-01_00-00-00/file", label="Download",
                                        entry="proj/issues/1/5-notes.txt")
        check(status == 200 and data == fixture.NOTES, "download returns the entry's bytes")
        check(headers.get("x-content-type-options") == "nosniff"
              and headers.get("content-disposition", "").startswith("attachment;")
              and headers.get("content-type", "").startswith("text/plain"), "download headers")
        check(headers.get("content-length") == str(len(fixture.NOTES)), "download Content-Length")

        # A download shows no new page: the buttons of the page the browser stays on
        # still work, so the same page can download twice and then navigate.
        status, headers, data = b.click(action="/backups/sample/2026-01-01_00-00-00/file", label="Download",
                                        entry="proj/issues/1/5-notes.txt")
        check(data == fixture.NOTES, "a second download from the same page")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/files")
        check("proj/git.bundle" in b.page, "the page's buttons still work after a download")
        status, headers, data = b.click(action="/backups/sample/2026-01-01_00-00-00/file", label="Download",
                                        entry="proj/git.bundle")
        check(data == fixture.BUNDLE and headers.get("content-type") == "application/octet-stream",
              "binary download is exact")
        # A download token only downloads: it cannot open a page or save.
        a, fields = b.find(action="/backups/sample/2026-01-01_00-00-00/file", label="Download",
                           entry="proj/git.bundle")
        status, _, _ = b.request("POST", "/backups/sample/2026-01-01_00-00-00", fields)
        check(status == 303, "a download token cannot open a page")
        status, _, _ = b.request("POST", a, dict(fields, op="save", content="x"))
        check(status == 303, "a download token cannot save")
        b.all_files("/backups/sample/2026-01-01_00-00-00")
        check("owner/avatar.png" in b.page and "proj/issues/3/8-päivä.txt" in b.page,
              "backup files page lists every entry, UTF-8 names too")
        b.click(action="/backups/sample/2026-01-01_00-00-00/file", label="View", entry="proj/issues/1/6-pic.png")
        check("data:image/png;base64," in b.page, "an image is shown as an image")
        b.all_files("/backups/sample/2026-01-01_00-00-00")
        b.click(action="/backups/sample/2026-01-01_00-00-00/file", label="View", entry="proj/issues/3/8-päivä.txt")
        check("Päivää maailma" in b.page, "a file with a UTF-8 name is shown")
        b.all_files("/backups/sample/2026-01-01_00-00-00")
        status, _, data = b.click(action="/backups/sample/2026-01-01_00-00-00/file", label="View",
                                  entry="proj/releases/v1.0/big.txt")
        check("Only the beginning of this file is shown" in b.page, "a big text file is shown partly")
        check(len(data) < 400 * 1024 and "line 000000" in b.page and "line 039999" not in b.page,
              "only a bounded first part of a big file is sent")
        check(not [f for f in b.forms() if f[1].get("op") == "edit"], "a file over the edit limit has no Edit")
        status, _, _ = b.post(*b.find(action="/backups/sample/2026-01-01_00-00-00/file", label="Download",
                                      entry="proj/releases/v1.0/big.txt"))
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/releases")
        b.click(action="/backups/sample/2026-01-01_00-00-00/file", label="View",
                entry="proj/releases/v1.0/medium.txt")
        check("Only the beginning of this file is shown" in b.page and "medium 029999" not in b.page,
              "a medium file is shown partly")
        b.click(action="/backups/sample/2026-01-01_00-00-00/file", label="Edit",
                entry="proj/releases/v1.0/medium.txt", op="edit")
        check("medium 000000" in b.page and "medium 029999" in b.page,
              "but its edit form holds the whole file")
        b.click(action="/backups/sample/2026-01-01_00-00-00/file", label="Save",
                entry="proj/releases/v1.0/medium.txt", op="save",
                extra={"content": fixture.MEDIUM.decode() + "added\n"})
        with zipfile.ZipFile(sample_zip) as z:
            check(z.read("proj/releases/v1.0/medium.txt") == fixture.MEDIUM + b"added\n",
                  "saving a medium file keeps all of it")

        # --- editing an issue into the .db -----------------------------------------
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1", label="Edit", op="edit-issue")
        check('<textarea name="body"' in b.page and "&lt;script&gt;" in b.page, "issue edit form, escaped")
        edit_page = b.page
        new_body = "Edited <b>body</b>\r\nwith two lines & Ünïcödé"
        status, _, _ = b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1", label="Save",
                               op="save-issue", extra={"title": "Edited title", "body": new_body})
        check(status == 200 and "Saved." in b.page, "issue save says Saved.")
        check("Edited &lt;b&gt;body&lt;/b&gt;" in b.page and "Edited title" in b.page, "saved issue is shown")
        db = sqlite3.connect(sample_db)
        title, body_json = db.execute("SELECT title, json FROM issues WHERE repo='sample/proj' AND number=1").fetchone()
        j = json.loads(body_json)
        check(title == "Edited title" and j["title"] == "Edited title", "issue title saved in column and json")
        check(j["body"] == "Edited <b>body</b>\nwith two lines & Ünïcödé", "issue body saved in json, LF line ends")
        check(j["user"]["login"] == "alice" and j["labels"][0]["name"] == "bug", "the rest of the json is kept")
        db.close()

        # Replaying the same signed save (the token was used) changes nothing.
        saved_page = b.page
        b.page = edit_page
        status, headers, _ = b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1", label="Save",
                                     op="save-issue", extra={"title": "Replayed", "body": "x"})
        check(status == 303, "a used save token is refused")
        db = sqlite3.connect(sample_db)
        check(db.execute("SELECT title FROM issues WHERE number=1").fetchone()[0] == "Edited title",
              "a refused save leaves the .db as it was")
        db.close()
        b.page = saved_page  # the page the browser really shows

        # The edit form of issue 1 cannot save issue 3 (the token names its target).
        b.click(action="/backups")
        b.click(action="/backups/sample/2026-01-01_00-00-00")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1", label="Edit", op="edit-issue")
        a, fields = b.find(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1", label="Save")
        fields.update({"title": "Wrong target", "body": "x"})
        b.post("/backups/sample/2026-01-01_00-00-00/proj/issue/3", fields)
        check("Saved." not in b.page and "Error" in b.page, "a save token for one issue cannot save another")
        db = sqlite3.connect(sample_db)
        check(db.execute("SELECT title FROM issues WHERE number=3").fetchone()[0] == "Sample closed issue",
              "the other issue is unchanged")
        db.close()

        # A navigation token cannot save.
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj")
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1")
        a, fields = b.find(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1", label="Edit", op="edit-issue")
        fields.update({"op": "save-issue", "title": "Nav token", "body": "x"})
        b.post(a, fields)
        check("Saved." not in b.page, "a navigation token cannot save")
        db = sqlite3.connect(sample_db)
        check(db.execute("SELECT title FROM issues WHERE number=1").fetchone()[0] == "Edited title",
              "navigation-token save left the .db as it was")
        db.close()

        # --- editing a comment ------------------------------------------------------
        b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1", label="Edit", op="edit-comment",
                comment="10")
        status, _, _ = b.click(action="/backups/sample/2026-01-01_00-00-00/proj/issue/1", label="Save",
                               op="save-comment", comment="10", extra={"body": "Edited comment <i>x</i>"})
        check("Saved." in b.page and "Edited comment &lt;i&gt;x&lt;/i&gt;" in b.page, "comment saved and shown")
        db = sqlite3.connect(sample_db)
        cj = json.loads(db.execute("SELECT json FROM comments WHERE id=10").fetchone()[0])
        check(cj["body"] == "Edited comment <i>x</i>" and cj["user"]["login"] == "bob", "comment json updated")
        db.close()

        # --- editing a text file in the .zip ----------------------------------------
        def edit_file(base, entry, text, zip_path, db_path):
            b.all_files(base)
            b.click(action=base + "/file", label="View", entry=entry)
            b.click(action=base + "/file", label="Edit", entry=entry, op="edit")
            check('<textarea name="content"' in b.page, f"file edit form for {entry}")
            return b.click(action=base + "/file", label="Save", entry=entry, op="save",
                           extra={"content": text})

        base = "/backups/sample/2026-01-01_00-00-00"
        before_pic = zipfile.ZipFile(sample_zip).read("proj/issues/1/6-pic.png")
        new_text = "Edited notes <b>x</b>\r\nsecond line ä\r\n"
        expect = new_text.replace("\r\n", "\n").encode()
        status, _, _ = edit_file(base, "proj/issues/1/5-notes.txt", new_text, sample_zip, sample_db)
        check(status == 200 and "Saved." in b.page and "Edited notes &lt;b&gt;x&lt;/b&gt;" in b.page,
              "zip file saved and shown")
        with zipfile.ZipFile(sample_zip) as z:
            check(z.testzip() is None, "the edited zip is valid for Python's zipfile")
            check(z.read("proj/issues/1/5-notes.txt") == expect, "Python reads the new content")
            check(z.read("proj/issues/1/6-pic.png") == before_pic and z.read("proj/git.bundle") == fixture.BUNDLE,
                  "other entries are unchanged")
            info = z.getinfo("proj/issues/1/5-notes.txt")
            check(info.compress_type == zipfile.ZIP_STORED, "the new entry is STORED")
            check(len([i for i in z.infolist() if i.filename == "proj/issues/1/5-notes.txt"]) == 1,
                  "the central directory names the file once")
            check(len(z.infolist()) == 9, "the central directory keeps every entry")
        db = sqlite3.connect(sample_db)
        size, digest = db.execute("SELECT size, sha256 FROM files WHERE path='proj/issues/1/5-notes.txt'").fetchone()
        check(size == len(expect) and digest == sha(expect), "files row has the new size and sha256")
        db.close()
        check(not os.path.exists(sample_zip + ".omi-save"), "no save journal is left behind")
        if shutil.which("unzip"):
            r = subprocess.run(["unzip", "-tq", sample_zip], capture_output=True, text=True)
            check(r.returncode == 0, "unzip -t accepts the edited zip")
        # A second edit of the same file, and a file whose original has CRLF.
        edit_file(base, "proj/issues/1/5-notes.txt", "Third version\n", sample_zip, sample_db)
        edit_file(base, "proj/comments/1/10/7-log.txt", "comment log\r\nedited\r\n", sample_zip, sample_db)
        with zipfile.ZipFile(sample_zip) as z:
            check(z.testzip() is None and z.read("proj/issues/1/5-notes.txt") == b"Third version\n",
                  "a second edit of the same file")
            check(z.read("proj/comments/1/10/7-log.txt") == b"comment log\r\nedited\r\n",
                  "CRLF is kept where the original had CRLF")
        status, _, data = b.click(action=base + "/file", label="Download", entry="proj/comments/1/10/7-log.txt")
        check(data == b"comment log\r\nedited\r\n", "Omi downloads the edited entry")

        # ZIP64 end records: read, edit, still ZIP64 and valid.
        z64_zip = os.path.join(z64_dir, "zsixtyfour.zip")
        base64_ = "/backups/zsixtyfour/2026-02-02_10-20-30"
        b.click(action="/backups")
        b.click(action=base64_)
        b.all_files(base64_)
        check("proj/issues/1/5-notes.txt" in b.page, "a zip with ZIP64 end records is listed")
        edit_file(base64_, "proj/releases/v1.0/notes.md", "# Edited in ZIP64\n", z64_zip,
                  os.path.join(z64_dir, "zsixtyfour.db"))
        check("Saved." in b.page and "# Edited in ZIP64" in b.page, "ZIP64 zip file saved and shown")
        with zipfile.ZipFile(z64_zip) as z:
            check(z.testzip() is None and z.read("proj/releases/v1.0/notes.md") == b"# Edited in ZIP64\n",
                  "Python reads the edited ZIP64 zip")
        with open(z64_zip, "rb") as f:
            f.seek(-22 - 20, os.SEEK_END)
            check(f.read(4) == b"PK\x06\x07", "the ZIP64 locator is kept after saving")

        # An interrupted save: the journal makes Omi roll the zip back.
        with open(sample_zip, "rb") as f:
            whole = f.read()
        with open(sample_zip + ".omi-save", "w") as f:
            f.write(f"{len(whole)}\n")
        with open(sample_zip, "ab") as f:
            f.write(b"PK\x03\x04 half-written entry")
        b.all_files(base)
        check("proj/git.bundle" in b.page, "an interrupted save is rolled back when the zip is opened")
        with open(sample_zip, "rb") as f:
            check(f.read() == whole, "the zip is exactly what it was before the interrupted save")
        check(not os.path.exists(sample_zip + ".omi-save"), "the journal is removed after the rollback")

        # --- refused: no session, '..', other paths -------------------------------
        with open(sample_zip, "rb") as f:
            zip_before = f.read()
        status, headers, _ = b.request("POST", base + "/file", {"entry": "proj/issues/1/5-notes.txt",
                                                                 "op": "save", "content": "hacked"})
        check(status == 303 and headers.get("location") == "/", "save without a session is refused")
        status, headers, _ = b.request("POST", base + "/proj/issue/1", {"op": "save-issue", "title": "hacked",
                                                                         "body": "hacked"})
        check(status == 303, "issue save without a session is refused")
        with open(sample_zip, "rb") as f:
            check(f.read() == zip_before, "the zip is unchanged by the refused saves")
        db = sqlite3.connect(sample_db)
        check(db.execute("SELECT title FROM issues WHERE number=1").fetchone()[0] == "Edited title",
              "the .db is unchanged by the refused saves")
        db.close()

        for entry in ["../../etc/passwd", "proj/../../x", "/etc/passwd", "proj//x", "proj\\x", "./proj/x"]:
            b.all_files(base)
            status, _, _ = b.click(action=base + "/file", label="View", entry="proj/git.bundle",
                                   extra={"entry": entry})
            check(status == 404 and "Not found." in b.page and "root:" not in b.page,
                  f"zip entry {entry!r} is refused")
        b.all_files(base)
        status, _, _ = b.click(action=base + "/file", label="Download", entry="proj/git.bundle",
                               extra={"entry": "../sample.db"})
        check(status == 404, "download of '../sample.db' is refused")
        for path in ["/backups/..%2F..%2Fetc/x", "/backups/sample/..", "/backups/sample/2026-03-03_00-00-00.partial",
                     "/backups/sample/2026-01-01_00-00-00%2F..%2F..", "/backups/.hidden/2026-01-01_00-00-00",
                     "/backups/sample/2026-01-01_00-00-00/nosuchrepo"]:
            b.all_files(base)
            a, fields = b.find(action="/backups")
            status, _, _ = b.post(path, fields)
            check(status == 404, f"path {path} is refused")

        # --- the owner's one backup, and its old data --------------------------------
        acme_dir = os.path.join(backups, "acme")
        acme_db = os.path.join(acme_dir, "acme.db")
        acme_zip = os.path.join(acme_dir, "acme.zip")
        cur = "/backups/acme/current"
        lock = os.path.join(acme_dir, ".backup.lock")
        b.click(action="/backups")
        b.click(action=cur)
        check("acme/proj" in b.page and "acme/gone" in b.page, "the one backup opens: its repositories")
        check("acme/gone</td>" not in b.page and "[Old data]" in b.page, "a repository gone from the source is marked")
        check("Rows: 11, Files: 3" in b.page, "the overview counts the old data")
        b.click(action=cur + "/proj")
        check("Sample open issue" in b.page and "Deleted at the source" in b.page, "issues of the one backup")
        b.click(action=cur)
        b.click(action=cur + "/old")
        page = b.page
        for want in ["Deleted at the source", "Issue of a gone repository", "v0.9", "wontfix", "v0", "carol",
                     "oldteam", "acme/gone", "proj/issues/4/12-old.txt", "proj/releases/v0.9/old.bin",
                     "gone/git.bundle", "An old comment" if False else "#4"]:
            check(want in page, f"old data page lists {want}")
        for not_want in ["Sample open issue", "proj/issues/1/5-notes.txt", "proj/git.bundle", "alice, ", ">bug<"]:
            check(not_want not in page, f"old data page does not list current {not_want}")
        old_bytes = sum(len(v) for v in fixture.OLD_ENTRIES.values())
        check("Files (3," in page, "old data page counts the old files")
        b.click(action=cur + "/proj")
        b.click(action=cur + "/proj/old")
        check("Deleted at the source" in b.page and "acme/gone" not in b.page
              and "proj/releases/v0.9/old.bin" in b.page and "gone/git.bundle" not in b.page,
              "a repository's old data page lists only that repository's")
        b.click(action=cur + "/proj/issue/4")
        check("[Old data]" in b.page and "Only an older run saw this." in b.page and "An old comment" in b.page
              and "old.txt" in b.page, "an old issue is shown, marked, with its comment and file")
        b.click(action=cur + "/file", label="View", entry="proj/issues/4/12-old.txt")
        check("[Old data]" in b.page and "an attachment of an issue deleted at the source" in b.page,
              "an old file is shown, marked")
        b.click(action=cur + "/proj")
        b.click(action=cur + "/proj/issue/1")
        check("[Old data]" not in b.page, "a current issue is not marked")
        b.click(action="/backups")
        b.click(action="/backups/sample/2026-01-01_00-00-00")
        check('action="/backups/sample/2026-01-01_00-00-00/old"' not in b.page, "a dated backup has no Old data button")
        a, fields = b.find(action="/backups/sample/2026-01-01_00-00-00/files")
        b.post("/backups/sample/2026-01-01_00-00-00/old", fields)
        check("has no old data marker" in b.page, "a dated backup has no old data")

        # Saving into the one backup: the .db and the .zip, seen left as it was.
        b.click(action="/backups")
        b.click(action=cur)
        b.click(action=cur + "/proj")
        b.click(action=cur + "/proj/issue/1")
        b.click(action=cur + "/proj/issue/1", label="Edit", op="edit-issue")
        b.click(action=cur + "/proj/issue/1", label="Save", op="save-issue",
                extra={"title": "Acme edited", "body": "acme body"})
        db = sqlite3.connect(acme_db)
        check("Saved." in b.page and db.execute("SELECT title, seen FROM issues WHERE repo='acme/proj' AND number=1"
                                                ).fetchone() == ("Acme edited", 3), "an issue of the one backup is saved, seen kept")
        db.close()
        check(not os.path.exists(lock), "the lock is removed after the save")

        # A lock held by a live program: the save is refused and nothing changes.
        holder = f"{os.getpid()} {socket.gethostname()} gitea-backup 2026-11-22T00:00:00+00:00"
        with open(lock, "w") as f:
            f.write(holder + "\n")
        b.click(action=cur + "/proj/issue/1", label="Edit", op="edit-issue")
        b.click(action=cur + "/proj/issue/1", label="Save", op="save-issue", extra={"title": "Locked out", "body": "x"})
        db = sqlite3.connect(acme_db)
        check("being updated by another program" in b.page and holder in b.page
              and db.execute("SELECT title FROM issues WHERE repo='acme/proj' AND number=1").fetchone()[0] == "Acme edited",
              "a held lock refuses the save and names its holder")
        db.close()
        check(open(lock).read().strip() == holder, "a lock that is not Omi's is left as it is")
        # A stale lock (this host, a process that is gone) is taken over.
        dead = subprocess.Popen(["true"])
        dead.wait()
        with open(lock, "w") as f:
            f.write(f"{dead.pid} {socket.gethostname()} gitea-backup 2026-11-22T00:00:00+00:00\n")
        b.click(action=cur + "/proj/issue/1", label="Edit", op="edit-issue")
        b.click(action=cur + "/proj/issue/1", label="Save", op="save-issue", extra={"title": "After stale", "body": "x"})
        db = sqlite3.connect(acme_db)
        check("Saved." in b.page and db.execute("SELECT title FROM issues WHERE repo='acme/proj' AND number=1"
                                                ).fetchone()[0] == "After stale" and not os.path.exists(lock),
              "a stale lock is taken over")
        db.close()
        # A lock of another host is never taken as stale.
        with open(lock, "w") as f:
            f.write(f"{dead.pid} another-host.invalid gitea-backup 2026-11-22T00:00:00+00:00\n")
        b.click(action=cur + "/proj/issue/1", label="Edit", op="edit-issue")
        b.click(action=cur + "/proj/issue/1", label="Save", op="save-issue", extra={"title": "Other host", "body": "x"})
        check("being updated by another program" in b.page and os.path.exists(lock),
              "a lock of another host is not taken over")
        os.remove(lock)

        # A commit that broke off after its marker is finished before the next write;
        # one that broke off before it is cleared.
        shutil.copy2(acme_db, acme_db + ".tmp")
        db = sqlite3.connect(acme_db + ".tmp")
        db.execute("UPDATE issues SET title = 'Recovered' WHERE repo='acme/proj' AND number=3")
        db.commit()
        db.close()
        with open(os.path.join(acme_dir, ".backup.commit"), "w") as f:
            f.write("gitea-backup\n")
        with open(acme_zip + ".tmp", "wb") as f:
            f.write(open(acme_zip, "rb").read())
        b.click(action=cur + "/proj/issue/1", label="Edit", op="edit-issue")
        b.click(action=cur + "/proj/issue/1", label="Save", op="save-issue", extra={"title": "After recovery", "body": "x"})
        db = sqlite3.connect(acme_db)
        check(db.execute("SELECT title FROM issues WHERE repo='acme/proj' AND number=3").fetchone()[0] == "Recovered"
              and db.execute("SELECT title FROM issues WHERE repo='acme/proj' AND number=1").fetchone()[0] == "After recovery",
              "a commit that broke off is finished before a write, then the write is made")
        db.close()
        check(not any(os.path.exists(p) for p in (acme_db + ".tmp", acme_zip + ".tmp",
                                                    os.path.join(acme_dir, ".backup.commit"))),
              "no commit marker or .tmp is left after the recovery")
        with open(acme_zip + ".tmp", "wb") as f:
            f.write(b"half a zip")
        with open(acme_zip, "rb") as f:
            acme_zip_bytes = f.read()
        b.click(action=cur + "/proj/issue/1", label="Edit", op="edit-issue")
        b.click(action=cur + "/proj/issue/1", label="Save", op="save-issue", extra={"title": "Acme edited", "body": "x"})
        check(not os.path.exists(acme_zip + ".tmp") and open(acme_zip, "rb").read() == acme_zip_bytes,
              "a .tmp without a commit marker is removed, the zip left as it was")

        # --- deleting the old data ---------------------------------------------------
        def snapshot(dbp, zp):
            con = sqlite3.connect(dbp)
            rows = {}
            for t in fixture.DATA_TABLES:
                rows[t] = sorted(map(repr, con.execute(f"SELECT * FROM {t}").fetchall()))
            meta = dict(con.execute("SELECT key, value FROM meta").fetchall())
            con.close()
            with zipfile.ZipFile(zp) as z:
                entries = {n: z.read(n) for n in z.namelist()}
            return rows, meta, entries

        acme_before = snapshot(acme_db, acme_zip)
        con = sqlite3.connect(acme_db)
        current_before = {t: sorted(map(repr, con.execute(f"SELECT * FROM {t} WHERE seen = 3").fetchall()))
                          for t in fixture.DATA_TABLES}
        con.close()
        beta_before = snapshot(os.path.join(backups, "beta", "beta.db"), os.path.join(backups, "beta", "beta.zip"))
        old_compressed = 0
        with zipfile.ZipFile(acme_zip) as z:
            for n in fixture.OLD_ENTRIES:
                old_compressed += z.getinfo(n).compress_size
        zip_size_before = os.path.getsize(acme_zip)
        b.click(action=cur)
        b.click(action=cur + "/old")
        b.click(action=cur + "/delete-old")
        check("Delete old data" in b.page and f"({old_compressed})" in b.page and "proj/releases/v0.9/old.bin" in b.page
              and 'name="confirm_name"' in b.page, "the delete page shows what goes and the space freed")
        a, fields = b.find(action=cur + "/delete-old", label="Delete old data", op="delete-old")
        # Not signed in: refused.
        status, headers, _ = b.request("POST", cur + "/delete-old", {"op": "delete-old", "confirm_name": "acme"})
        check(status == 303, "delete old data without a session is refused")
        # A token for another backup's deletion cannot delete that one.
        b.post("/backups/beta/current/delete-old", dict(fields, confirm_name="beta"))
        check("Old data deleted" not in b.page and "Error" in b.page, "a delete token for one backup cannot delete another's")
        check(snapshot(os.path.join(backups, "beta", "beta.db"), os.path.join(backups, "beta", "beta.zip")) == beta_before,
              "the other backup is unchanged")
        # The wrong name typed: nothing is deleted.
        b.click(action="/backups")
        b.click(action=cur)
        b.click(action=cur + "/old")
        b.click(action=cur + "/delete-old")
        b.click(action=cur + "/delete-old", label="Delete old data", op="delete-old",
                extra={"confirm_name": "Acme"})
        check("Nothing was deleted" in b.page and snapshot(acme_db, acme_zip) == acme_before,
              "the wrong name typed deletes nothing")
        b.click(action=cur + "/delete-old", label="Delete old data", op="delete-old",
                extra={"confirm_name": ""})
        check("Nothing was deleted" in b.page and snapshot(acme_db, acme_zip) == acme_before,
              "no name typed deletes nothing")
        # A used token deletes nothing.
        shown = b.page
        status, _, _ = b.post(a, dict(fields, confirm_name="acme"))
        check(status == 303 and snapshot(acme_db, acme_zip) == acme_before, "a used delete token is refused")
        b.page = shown
        # The owner's name typed: deleted.
        b.click(action=cur + "/delete-old", label="Delete old data", op="delete-old",
                extra={"confirm_name": "acme"})
        check("Old data deleted" in b.page and "No old data." in b.page, "the owner's name typed deletes the old data")
        rows_after, meta_after, entries_after = snapshot(acme_db, acme_zip)
        rows_before, meta_before, entries_before = acme_before
        con = sqlite3.connect(acme_db)
        left_old = sum(con.execute(f"SELECT COUNT(*) FROM {t} WHERE seen IS NULL OR seen < 3").fetchone()[0]
                       for t in fixture.DATA_TABLES)
        con.close()
        check(left_old == 0, "no old row is left in any table")
        check(all(set(current_before[t]) == set(rows_after[t]) for t in fixture.DATA_TABLES)
              and all(set(rows_after[t]) <= set(rows_before[t]) for t in fixture.DATA_TABLES)
              and sum(len(rows_before[t]) - len(rows_after[t]) for t in fixture.DATA_TABLES) == 11,
              "every current row is kept as it was; exactly the 11 old rows are gone")
        check(set(entries_after) == set(entries_before) - set(fixture.OLD_ENTRIES)
              and all(entries_after[n] == entries_before[n] for n in entries_after),
              "every current zip entry is kept byte for byte; the old entries are gone")
        with zipfile.ZipFile(acme_zip) as z:
            check(z.testzip() is None and all(i.compress_type == zipfile.ZIP_STORED for i in z.infolist()),
                  "the rewritten zip is valid and STORED")
        if shutil.which("unzip"):
            r = subprocess.run(["unzip", "-tq", acme_zip], capture_output=True, text=True)
            check(r.returncode == 0, "unzip -t accepts the rewritten zip")
        zip_size_after = os.path.getsize(acme_zip)
        freed = zip_size_before - zip_size_after
        print(f"     zip {zip_size_before} -> {zip_size_after} bytes: {freed} freed, old entries {old_compressed}")
        # Their bytes, and their local headers and central directory records (about 140 bytes each).
        check(old_compressed <= freed <= old_compressed + 200 * len(fixture.OLD_ENTRIES),
              "the zip shrank by the old entries' bytes")
        check(meta_after.get("deleted_old_only", "").endswith(f": 11 rows, 3 files, {old_compressed} bytes")
              and meta_after.get("runs") == "3", "meta deleted_old_only records it; runs is kept")
        check(not any(os.path.exists(p) for p in (acme_db + ".tmp", acme_zip + ".tmp", lock,
                                                    os.path.join(acme_dir, ".backup.commit"))),
              "no .tmp, commit marker or lock is left")
        b.click(action=cur + "/old")
        check("No old data." in b.page and "Rows: <b>0</b>" in b.page, "the old data page is empty after the delete")
        b.click(action=cur)
        b.click(action=cur + "/proj")
        b.click(action=cur + "/proj/issue/1")
        check("Acme edited" in b.page, "the backup still opens after the delete")

        # Every language has the new keys.
        missing = []
        for name in sorted(os.listdir(os.path.join(REPO, "public", "i18n"))):
            with open(os.path.join(REPO, "public", "i18n", name), encoding="utf-8") as f:
                d = json.load(f)
            for key in ["backups", "backups-directory", "no-backups", "backup", "issues", "pull-requests",
                        "releases", "files", "milestones", "author", "state", "created", "tag", "merged",
                        "saved", "not-found", "file-shown-partly", "file-too-large-to-edit"] + NEW_KEYS:
                if not d.get(key):
                    missing.append(f"{name}:{key}")
        check(not missing, f"every language file has the Backups keys {missing[:5]}")
        with open(os.path.join(REPO, "public", "i18n", "en.i18n.json"), encoding="utf-8") as f:
            en = json.load(f)
        english = []
        for name in sorted(os.listdir(os.path.join(REPO, "public", "i18n"))):
            if name.startswith("en"):
                continue
            with open(os.path.join(REPO, "public", "i18n", name), encoding="utf-8") as f:
                d = json.load(f)
            english += [f"{name}:{k}" for k in NEW_KEYS if d.get(k) == en[k]]
        check(not english, f"the Old data keys are translated, not English {english[:5]}")
        b.click(action="/backups")
        check(server.poll() is None, "the server is still running")
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(10)
            except subprocess.TimeoutExpired:
                server.kill()
        if FAILURES or os.environ.get("OMI_KEEP_TEST_DIR") == "1":
            print(f"test directory kept: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)
    print(f"===== backups test: {PASSES} passed, {len(FAILURES)} failed")
    for f in FAILURES:
        print(f"  FAIL {f}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
