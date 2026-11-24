#!/usr/bin/env python3
"""Tests of Omi's Gitea folder: reading app.ini and the paths, the size index and
the sizes, mismatches and orphans (public/omigitea.pas, `server gitea ...`), the
Gitea pages (public/server.pas) and their refusals.

  python3 -I tests/gitea_test.py              builds with ./freepascalserver.sh first
  OMI_SKIP_BUILD=1 python3 -I tests/gitea_test.py

It writes a small Gitea folder with tests/make_gitea_fixture.py (Gitea's schema
copied from a Gitea database, read-only, and rows of its own), measures it from
the disk and from `tree -s` output and checks every number. When the real copy of
a Gitea database is there (.tools/gitea.db, or $OMI_REAL_GITEA_DB), it also opens
that one read-only and lists its owners and sizes - and checks that nothing was
written to it and that no secret column reaches the output. Nothing is written to
any database but the fixture's.
"""
import hashlib
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
TOOLS = os.path.dirname(os.path.dirname(REPO))
sys.path.insert(0, HERE)
import make_gitea_fixture as fx  # noqa: E402
from backups_test import Browser, free_port  # noqa: E402
import gitea_live  # noqa: E402


SERVER = os.path.join(REPO, "public", "server")
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


def cli(*args, cwd=None):
    r = subprocess.run([SERVER, "gitea", *args], capture_output=True, text=True, cwd=cwd)
    return r.returncode, r.stdout, r.stderr


def table(text):
    """Tab-separated output (header first, '#' lines skipped) as dicts."""
    lines = [l for l in text.splitlines() if l and not l.startswith("#")]
    head = lines[0].split("\t")
    return [dict(zip(head, l.split("\t"))) for l in lines[1:]]


def paths_of(ini):
    rc, out, err = cli("paths", "--config", ini)
    return dict(l.split("\t", 1) for l in out.splitlines() if "\t" in l) if rc == 0 else {"error": err}


def test_paths(work):
    def ini(name, text):
        d = os.path.join(work, name, "custom", "conf")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "app.ini"), "w") as f:
            f.write(text)
        return os.path.join(d, "app.ini"), os.path.join(work, name)

    # Defaults: the work directory from custom/conf, everything under data/.
    path, w = ini("defaults", "APP_NAME = x\n[server]\nHTTP_PORT = 3456\n")
    p = paths_of(path)
    check(p.get("WORK_PATH") == w and p.get("APP_DATA_PATH") == w + "/data", "work dir from custom/conf, data/")
    check(p.get("database") == f"sqlite3 {w}/data/gitea.db", "database default data/gitea.db")
    check(p.get("repositories") == w + "/data/gitea-repositories", "repository ROOT default")
    for name in ("attachments", "lfs", "packages", "avatars", "repo-avatars", "actions_log", "actions_artifacts",
                 "repo-archive"):
        check(p.get(name) == f"{w}/data/{name}", f"storage default {name}")
    check(p.get("http") == "127.0.0.1:3456", "HTTP port")

    # WORK_PATH, APP_DATA_PATH, relative ROOT and database PATH, the storage rules.
    path, w = ini("custom", "WORK_PATH = /srv/g\n[server]\nAPP_DATA_PATH = /var/gd\nLFS_CONTENT_PATH = lfs-old\n"
                  "HTTP_ADDR = 0.0.0.0\n[database]\nDB_TYPE = sqlite3\nPATH = \"db/x.db\"\n"
                  "[repository]\nROOT = repos\n[storage]\nPATH = /mnt/store\n"
                  "[storage.packages]\nPATH = pk\n[attachment]\nPATH = /att\n"
                  "[picture]\nAVATAR_UPLOAD_PATH = pics\nREPOSITORY_AVATAR_UPLOAD_PATH = /rpics\n"
                  "[repo-archive]\nSTORAGE_TYPE = minio\n")
    p = paths_of(path)
    check(p.get("WORK_PATH") == "/srv/g" and p.get("APP_DATA_PATH") == "/var/gd", "WORK_PATH and APP_DATA_PATH")
    check(p.get("database") == "sqlite3 /srv/g/db/x.db", "relative database PATH is beside WORK_PATH, quotes removed")
    check(p.get("repositories") == "/srv/g/repos", "relative ROOT is beside WORK_PATH")
    check(p.get("attachments") == "/att", "[attachment] PATH wins")
    check(p.get("lfs") == "/var/gd/lfs-old", "[server] LFS_CONTENT_PATH, relative to APP_DATA_PATH")
    check(p.get("packages") == "/var/gd/pk", "[storage.packages] PATH, relative to APP_DATA_PATH")
    check(p.get("avatars") == "/var/gd/pics" and p.get("repo-avatars") == "/rpics", "[picture] upload paths")
    check(p.get("actions_log") == "/mnt/store/actions_log", "[storage] PATH/<name>")
    check(p.get("http") == "127.0.0.1:3000", "0.0.0.0 is asked on 127.0.0.1, port default 3000")
    check("repo-archive" in p.get("not local", ""), "a minio storage is marked not local")
    rc, _, err = cli("paths", "--config", os.path.join(work, "nope.ini"))
    check(rc != 0 and "nope.ini" in err, "a missing app.ini is an error")


def owners_by_name(text):
    return {r["owner"]: r for r in table(text)}


def repos_by_name(text):
    return {r["repository"]: r for r in table(text)}


def test_sizes(work, source):
    ini = os.path.join(work, "custom", "conf", "app.ini")
    index = os.path.join(work, "index-" + source + ".txt")
    args = ["--config", ini, "--index", index]
    if source != "disk":
        tree = os.path.join(work, "tree-" + source + ".txt")
        with open(tree, "w", encoding="utf-8") as f:
            f.write(fx.tree_listing(work, slashes=(source == "tree-F")))
        args += ["--tree", tree]
    rc, out, err = cli("index", *args)
    check(rc == 0 and "indexed" in out, f"[{source}] index built {err.strip()}")
    S = fx.SIZES
    rc, out, err = cli("owners", "--bytes", *args)
    o = owners_by_name(out)
    acme_git = S["acme/big.git"] + S["acme/small.git"]
    check(o.get("acme", {}).get("git") == str(acme_git) and o["acme"].get("wiki") == str(S["acme/big.wiki.git"]),
          f"[{source}] acme git and wiki bytes")
    check(o.get("acme", {}).get("lfs") == str(S["lfs_shared"]), f"[{source}] an LFS object two repositories share counts once")
    check(o.get("acme", {}).get("attachments") == str(S["att_big"] + S["att_rel"]), f"[{source}] acme attachments")
    check(o.get("acme", {}).get("avatar") == str(S["avatar_acme"]), f"[{source}] acme avatar")
    acme_total = acme_git + S["acme/big.wiki.git"] + S["lfs_shared"] + S["att_big"] + S["att_rel"] + S["avatar_acme"]
    check(o.get("acme", {}).get("total") == str(acme_total), f"[{source}] acme total")
    bob_total = S["bob/tool.git"] + S["lfs_bob"] + S["att_size_file"] + S["pkg"]
    check(o.get("Bob", {}).get("packages") == str(S["pkg"]) and o["Bob"].get("total") == str(bob_total),
          f"[{source}] Bob's package and total")
    check(o.get("empty", {}).get("total") == "0" and o["empty"].get("repos") == "0", f"[{source}] an owner with nothing")
    check(list(o)[:2] == ["acme", "Bob"], f"[{source}] owners largest first")
    check(o.get("acme", {}).get("type") == "organization" and o.get("Bob", {}).get("type") == "user",
          f"[{source}] user and organization")
    check(o.get("acme", {}).get("mismatches") == "1", f"[{source}] acme has one repository with a mismatch")
    rc, out, _ = cli("owners", "--bytes", "--sort", "name", *args)
    check(list(owners_by_name(out)) == ["acme", "Bob", "empty"], f"[{source}] owners sorted by name")

    rc, out, _ = cli("sizes", "--bytes", *args)
    r = repos_by_name(out)
    check(list(r) == ["acme/big", "acme/small", "Bob/tool"], f"[{source}] repositories largest first {list(r)}")
    big = r.get("acme/big", {})
    check(big.get("git") == str(S["acme/big.git"]) and big.get("wiki") == str(S["acme/big.wiki.git"])
          and big.get("lfs") == str(S["lfs_shared"]) and big.get("attachments") == str(S["att_big"] + S["att_rel"]),
          f"[{source}] acme/big sizes")
    check(big.get("mismatch") == "", f"[{source}] acme/big has no mismatch")
    small = r.get("acme/small", {})
    check("git_size 900000 <> disk 2000" in small.get("mismatch", "") and "1 LFS files missing" in small["mismatch"]
          and "1 attachment files missing" in small["mismatch"], f"[{source}] acme/small mismatches flagged")
    check(small.get("db git_size") == "900000" and small.get("db lfs_size") == str(S["lfs_shared"] + 500),
          f"[{source}] the database's stored sizes are shown")
    check("attachment rows 200 <> files 300" in r.get("Bob/tool", {}).get("mismatch", ""),
          f"[{source}] an attachment whose file is larger than its row")
    rc, out, _ = cli("sizes", "--bytes", "--owner", "acme", "--sort", "name", *args)
    check(list(repos_by_name(out)) == ["acme/big", "acme/small"], f"[{source}] one owner's repositories, by name")

    rc, out, _ = cli("orphans", "--bytes", *args)
    rows = table(out)
    kinds = sorted((x["kind"], x["path"]) for x in rows)
    want = sorted([
        ("attachment-file", f"{fx.ATT_ORPHAN[0]}/{fx.ATT_ORPHAN[1]}/{fx.ATT_ORPHAN}"),
        ("attachment-row", fx.ATT_MISSING),
        ("attachment-size", f"{fx.ATT_SIZE[0]}/{fx.ATT_SIZE[1]}/{fx.ATT_SIZE}"),
        ("lfs-row", fx.OID_MISSING),
        ("lfs-file", f"{fx.OID_ORPHAN[:2]}/{fx.OID_ORPHAN[2:4]}/{fx.OID_ORPHAN[4:]}"),
        ("git-directory", "ghost/gone.git"),
        ("avatar-file", fx.AVATAR_ORPHAN),
    ])
    check(kinds == want, f"[{source}] orphans: files without rows and rows without files {kinds}")
    orphan_bytes = S["att_orphan"] + 50 + S["att_size_file"] + 500 + S["lfs_orphan"] + S["orphan_git"] + S["avatar_orphan"]
    check(f"# 7 orphans, {orphan_bytes}" in out, f"[{source}] orphan count and bytes")
    return index


def test_real(work):
    real = os.environ.get("OMI_REAL_GITEA_DB") or os.path.join(TOOLS, "gitea.db")
    if not os.path.isfile(real):
        print(f"skip the real database: no {real}")
        return
    before = {p: (os.stat(p).st_size, os.stat(p).st_mtime_ns) for p in (real, real + "-wal") if os.path.exists(p)}
    d = os.path.join(work, "real", "custom", "conf")
    os.makedirs(d)
    ini = os.path.join(d, "app.ini")
    with open(ini, "w") as f:
        f.write(f"WORK_PATH = /srv/gitea-real\n[database]\nDB_TYPE = sqlite3\nPATH = {real}\n")
    index = os.path.join(work, "real", "index.txt")
    args = ["--config", ini, "--index", index]
    tree = os.environ.get("OMI_REAL_GITEA_TREE") or os.path.join(TOOLS, "gitea-tree.txt")
    if os.path.isfile(tree):
        args += ["--tree", tree]
    t = time.time()
    rc, out, err = cli("owners", "--bytes", "--rescan", *args)
    check(rc == 0, f"the real database opens read-only and lists its owners {err.strip()[:200]}")
    owners = table(out)
    db = sqlite3.connect(f"file:{real}?mode=ro", uri=True)
    n = db.execute("SELECT COUNT(*) FROM user WHERE COALESCE(type, 0) IN (0, 1)").fetchone()[0]
    check(len(owners) == n, f"every user and organization is listed ({len(owners)} of {n}) in {time.time() - t:.1f} s")
    rc, sizes, _ = cli("sizes", "--bytes", *args)
    repos = table(sizes)
    check(len(repos) == db.execute("SELECT COUNT(*) FROM repository").fetchone()[0], "every repository is listed")
    check(sum(int(r["db size"]) for r in repos) == db.execute("SELECT COALESCE(SUM(size), 0) FROM repository").fetchone()[0],
          "repository sizes stored in the database are shown")
    if "--tree" in args:
        totals = [int(r["total"]) for r in owners]
        check(totals == sorted(totals, reverse=True) and totals[0] > 0, "owners sorted largest first, measured from the tree")
        rc, orph, _ = cli("orphans", *args)
        check(rc == 0 and "# " in orph, "the orphan report of the real folder")
    # No secret column reaches the output: compare in memory, print only a count.
    text = out + sizes
    leaked = 0
    for col in ("passwd", "salt", "rands", "email"):
        for (v,) in db.execute(f"SELECT {col} FROM user WHERE length({col}) >= 8"):
            if v and v in text:
                leaked += 1
    for (v,) in db.execute("SELECT token_hash FROM access_token WHERE length(token_hash) >= 8"):
        if v in text:
            leaked += 1
    check(leaked == 0, f"no password hash, salt, e-mail address or token in the output ({leaked})")
    db.close()
    after = {p: (os.stat(p).st_size, os.stat(p).st_mtime_ns) for p in before}
    check(before == after, "the real database and its WAL are unchanged")


FAKE_GIT_VERSION = "git version 9.9.9-omi-fake"


def make_fake_git(d):
    """A git program on a PATH of its own: `--version` answers FAKE_GIT_VERSION,
    everything else is logged to <d>/calls.log and run by the real git."""
    os.makedirs(d, exist_ok=True)
    real = shutil.which("git")
    path = os.path.join(d, "git")
    with open(path, "w") as f:
        f.write(f'#!/bin/sh\necho "$*" >> "{d}/calls.log"\n'
                f'if [ "$1" = "--version" ]; then echo "{FAKE_GIT_VERSION}"; exit 0; fi\n'
                f'exec "{real}" "$@"\n')
    os.chmod(path, 0o755)
    return path


def test_git_setting(work):
    """GIT= and GIT_FETCH=: the git program found on the PATH (or given), its
    --version, and the fetch mode; a mode that is not one is refused."""
    import json as _json
    fake = make_fake_git(os.path.join(work, "fakegit"))
    env = dict(os.environ, PATH=os.path.dirname(fake) + os.pathsep + os.environ.get("PATH", ""))
    r = subprocess.run([SERVER, "gitea", "git", "--json"], env=env, capture_output=True, text=True)
    j = _json.loads(r.stdout) if r.returncode == 0 else {}
    check(j.get("git") == fake and j.get("version") == FAKE_GIT_VERSION, f"git is found on the PATH, with its --version {j}")
    check(j.get("fetch") in ("pascal", "program"), f"and a fetch mode {j}")
    other = make_fake_git(os.path.join(work, "othergit"))
    r = subprocess.run([SERVER, "gitea", "git", "--json", "--git", other], env=env, capture_output=True, text=True)
    j = _json.loads(r.stdout) if r.returncode == 0 else {}
    check(j.get("git") == other, f"GIT (--git) names another git program {j}")
    r = subprocess.run([SERVER, "gitea", "git", "--json", "--git", os.path.join(work, "no-such-git")], env=env,
                       capture_output=True, text=True)
    j = _json.loads(r.stdout) if r.stdout.strip() else {}
    check(j.get("version") == "", f"a git program that does not run has no version {j}")
    r = subprocess.run([SERVER, "gitea", "git", "--json", "--git-fetch", "rsync"], env=env, capture_output=True, text=True)
    check(r.returncode != 0 and "GIT_FETCH" in r.stdout + r.stderr, "a GIT_FETCH that is not pascal or program is refused")
    r = subprocess.run([SERVER, "gitea", "git", "--json", "--git-fetch", "program"], env=env, capture_output=True, text=True)
    check(r.returncode == 0 and _json.loads(r.stdout).get("fetch") == "program", "GIT_FETCH=program")


class FakeUserApi:
    """GitHub's GET /user, as "Test the token" asks it: the token "good" is
    octo's, "limited" has used up its hour, any other is not accepted."""

    def __init__(self):
        import http.server
        import json as _json
        import threading

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                auth = self.headers.get("Authorization", "")
                if self.path == "/api/user" and auth == "token good":
                    status, body = 200, _json.dumps({"login": "octo"}).encode()
                elif auth == "token limited":
                    status, body = 403, b'{"message": "API rate limit exceeded"}'
                else:
                    status, body = 401, b'{"message": "Bad credentials"}'
                self.send_response(status)
                self.send_header("X-RateLimit-Remaining", "4987")
                self.send_header("X-RateLimit-Limit", "5000")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.api = f"http://127.0.0.1:{self.httpd.server_address[1]}/api"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()


def test_token_cli(work):
    """server gitea test-token: what the "Test the token" button asks GitHub."""
    import json as _json
    os.makedirs(work, exist_ok=True)
    fake = FakeUserApi()
    tok = os.path.join(work, "token")
    try:
        def run(token, api=None):
            if token is None:
                if os.path.exists(tok):
                    os.remove(tok)
            else:
                with open(tok, "w") as f:
                    f.write(token + "\n")
            r = subprocess.run([SERVER, "gitea", "test-token", "--token-file", tok, "--github-api", api or fake.api,
                                "--json"], capture_output=True, text=True)
            return r.returncode, _json.loads(r.stdout), r.stdout + r.stderr
        rc, j, out = run("good")
        check(rc == 0 and j["outcome"] == "ok" and j["login"] == "octo" and j["remaining"] == "4987"
              and j["limit"] == "5000", f"test-token: a working token names its login and the hour's requests {j}")
        rc, j, out = run("ghp_wrongTOKEN")
        check(rc == 1 and j["outcome"] == "rejected" and "ghp_wrongTOKEN" not in out,
              f"negative: a token GitHub does not accept is rejected, and never printed {j}")
        rc, j, out = run("limited")
        check(rc == 1 and j["outcome"] == "refused" and "403" in j["detail"] and "rate limit" in j["detail"],
              f"negative: a used-up hour is refused, with GitHub's answer {j}")
        rc, j, out = run(None)
        check(rc == 1 and j["outcome"] == "none", f"negative: no token file is no token {j}")
        rc, j, out = run("good", "http://127.0.0.1:1/api")
        check(rc == 1 and j["outcome"] == "unreachable", f"negative: GitHub out of reach {j}")
    finally:
        fake.close()


def test_file_layout(work):
    """Settings are .ini files in settings/, Omi's database is in db/: an old
    settings.txt, users.txt or settings.ini beside public/, and activity.db, are
    moved there when the server starts, never over a file already there."""
    import json as _json
    for old in ("txt", "ini"):
        d = os.path.join(work, f"layout-{old}")
        os.makedirs(os.path.join(d, "public"))
        shutil.copy2(SERVER, os.path.join(d, "public", "server"))
        shutil.copytree(os.path.join(REPO, "public", "i18n"), os.path.join(d, "public", "i18n"))
        shutil.copy2(os.path.join(REPO, "public", "languages.json"), os.path.join(d, "public"))
        for name, text in (("settings", "SQLITE=sqlite3\n"), ("users", "u:p::en\n"), ("github-token", "old\n")):
            with open(os.path.join(d, f"{name}.{old}"), "w") as f:
                f.write(text)
        with open(os.path.join(d, "activity.db"), "wb") as f:
            f.write(b"")
        os.makedirs(os.path.join(d, "settings"))
        with open(os.path.join(d, "settings", "github-token.ini"), "w") as f:
            f.write("keep\n")
        r = subprocess.run([os.path.join(d, "public", "server"), "gitea", "status"], cwd=d,
                           capture_output=True, text=True, timeout=60)
        check(os.path.isfile(os.path.join(d, "settings", "settings.ini"))
              and os.path.isfile(os.path.join(d, "settings", "users.ini"))
              and not os.path.exists(os.path.join(d, f"settings.{old}"))
              and not os.path.exists(os.path.join(d, f"users.{old}")),
              f"settings.{old} and users.{old} are moved into settings/ {sorted(os.listdir(d))}")
        check(os.path.isfile(os.path.join(d, "db", "activity.db")) and not os.path.exists(os.path.join(d, "activity.db")),
              "activity.db is moved into db/")
        check(open(os.path.join(d, "settings", "github-token.ini")).read() == "keep\n"
              and os.path.isfile(os.path.join(d, f"github-token.{old}")),
              f"negative: an existing settings/github-token.ini is kept, github-token.{old} left as it is")
    ignored = subprocess.run(["git", "check-ignore", "--no-index", "settings/settings.ini", "settings/users.ini",
                              "settings/github-token.ini", "db/activity.db"], cwd=REPO, capture_output=True, text=True)
    check(len(ignored.stdout.split()) == 4, f"settings/*.ini and db/ are in .gitignore {ignored.stdout.split()}")
    kept = subprocess.run(["git", "check-ignore", "--no-index", "settings/settings.example.ini",
                           "settings/users.example.ini"], cwd=REPO, capture_output=True, text=True)
    check(kept.stdout.strip() == "", "negative: the two examples are not ignored")


def test_web(work, fixture_ids):
    srv = os.path.join(work, "srv")
    os.makedirs(os.path.join(srv, "public"))
    shutil.copy2(SERVER, os.path.join(srv, "public", "server"))
    shutil.copytree(os.path.join(REPO, "public", "i18n"), os.path.join(srv, "public", "i18n"))
    shutil.copy2(os.path.join(REPO, "public", "languages.json"), os.path.join(srv, "public"))
    os.makedirs(os.path.join(srv, "settings"), exist_ok=True)
    with open(os.path.join(srv, "settings", "settings.ini"), "w") as f:
        f.write(f"GITEA_APP_INI={os.path.join(work, 'custom', 'conf', 'app.ini')}\nGITEA_INDEX=gitea-index.txt\n"
                f"GITHUB_TO_GITEA_DIR={MIRROR}\nSYNC_EXCLUDE_FILE=sync-exclude.txt\n")
    with open(os.path.join(srv, "settings", "users.ini"), "w") as f:
        f.write("tester:secret::en\n")
    port = free_port()
    log = open(os.path.join(srv, "server.log"), "w")
    fake_git = make_fake_git(os.path.join(work, "web-fakegit"))
    user_api = FakeUserApi()
    server = subprocess.Popen([os.path.join(srv, "public", "server"), "--port", str(port)], cwd=srv, stdout=log,
                              stderr=subprocess.STDOUT,
                              env=dict(os.environ, PATH=os.path.dirname(fake_git) + os.pathsep + os.environ.get("PATH", ""),
                                       OMI_GITHUB_API=user_api.api))
    try:
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=1).close()
                break
            except OSError:
                time.sleep(0.1)
        b = Browser(port)
        status, headers, _ = b.request("GET", "/gitea")
        check(status in (302, 303) and headers.get("location") == "/", "GET /gitea without a session goes home")
        status, headers, _ = b.request("POST", "/gitea/owners", {})
        check(status in (302, 303) and headers.get("location") == "/", "POST /gitea without a session goes home")
        b.post("/sign-in", {"username": "tester", "password": "secret"})
        b.click(action="/")
        check('action="/gitea"' in b.page, "home page has the Gitea menu entry")
        # The start page names the configured folder, so its data is found
        # (a maintainer saw only Omi's own repositories and no Gitea at all).
        check(os.path.join(work, 'custom', 'conf', 'app.ini') in b.page and 'home-gitea' in b.page,
              "the start page names the Gitea folder and opens it")
        log.flush()
        check('Gitea folder: ' + os.path.join(work, 'custom', 'conf', 'app.ini') in open(os.path.join(srv, "server.log")).read(),
              "the startup output names the Gitea folder")
        check(f"git: {fake_git} ({FAKE_GIT_VERSION}); fetch: " in open(os.path.join(srv, "server.log")).read(),
              "the startup output names the git program, its --version and the fetch")
        b.click(action="/settings")
        check('name="GITEA_APP_INI"' in b.page and 'name="GITEA_TREE"' in b.page, "settings has GITEA_APP_INI and GITEA_TREE")
        check('name="GIT"' in b.page and 'name="GIT_FETCH"' in b.page and FAKE_GIT_VERSION in b.page
              and '<option value="program"' in b.page, "settings has GIT, with the --version found, and GIT_FETCH")
        # Negative: a size index of ANOTHER Gitea folder (left by the command
        # line's --config) is not read against this one: every row and file
        # would look orphaned - 98642 orphans of 516 GB on a real folder.
        with open(os.path.join(srv, "gitea-index.txt"), "w") as f:
            f.write("#omi-gitea-index 1\n#source\tdisk\n#time\t2026-01-01T00:00:00Z\n"
                    "#appini\t/elsewhere/custom/conf/app.ini\nA\t0/0/00000000-0000-0000-0000-000000000000\t1\n")
        b.click(action="/gitea")
        check("HTML 4.01 Transitional" in b.page and "database migration" in b.page.lower(), "overview page")
        check("not been measured yet" in b.page, "another folder's index is not used: the folders are not measured yet")
        check("Orphans" not in b.page.split("Size index")[0] or "not been measured yet" in b.page,
              "no orphans from another folder's index")
        os.remove(os.path.join(srv, "gitea-index.txt"))
        b.click(action="/gitea", label="Measure again")
        check("Files measured:" in b.page and "Total" in b.page, "measuring from the page")
        b.click(action="/gitea/owners")
        page = b.page
        check(page.find(">acme<") < page.find(">Bob<") or ('value="acme"' in page and page.find('value="acme"') < page.find('value="Bob"')),
              "sizes page lists owners largest first")
        check(fx.fixture_secret_free(page, fixture_ids["secret"]), "no secret column on the sizes page")
        b.click(action="/gitea/owners", sort="name")
        check("&darr;" in b.page, "a sorted column is marked")
        b.click(action="/gitea/o/acme")
        check("Acme &lt;b&gt;Org&lt;/b&gt;" in b.page and "<b>Org" not in b.page, "owner page, full name escaped")
        check("git_size 900000" in b.page, "owner page flags the mismatch")
        b.click(action="/gitea/o/acme/big")
        check("First &lt;i&gt;issue&lt;/i&gt;" in b.page and "A pull request" not in b.page, "repository issues, escaped")
        b.click(action="/gitea/o/acme/big/pulls")
        check("A pull request" in b.page and "octocat (GitHub)" in b.page and "Merged" in b.page,
              "pull requests, with the GitHub author")
        b.click(action="/gitea/o/acme/big/issues")
        b.click(action="/gitea/o/acme/big/issue/1")
        check("Body with &lt;script&gt;x&lt;/script&gt;" in b.page and "<script" not in b.page.lower()
              and "A comment" in b.page and "notes.txt" in b.page, "issue page: body escaped, comment, attachment")
        b.click(action="/gitea/o/acme/big/releases")
        check("v1" in b.page and "Version 1" in b.page, "releases")
        b.click(action=f"/gitea/o/acme/big/release/{fixture_ids['release']}")
        check("app.zip" in b.page and "Notes" in b.page, "a release with its attachment")
        b.click(action="/gitea/o/acme/big/attachments")
        check("notes.txt" in b.page and "app.zip" in b.page, "a repository's attachments")
        b.click(action="/gitea/o/acme/big/lfs")
        check(fx.OID_SHARED in b.page, "a repository's LFS objects")
        b.click(action="/gitea")
        b.click(action="/gitea/repos")
        check("acme/small" in b.page and "Bob/tool" in b.page, "all repositories")
        b.click(action="/gitea")
        b.click(action="/gitea/orphans")
        check("ghost/gone.git" in b.page and fx.ATT_ORPHAN in b.page, "orphans page")
        # Refusals: names that are not Gitea names are never paths.
        for bad in ["/gitea/o/..", "/gitea/o/%2e%2e", "/gitea/o/acme/..%2F..%2Fetc", "/gitea/o/a%2Fb",
                    "/gitea/o/acme/big%00", "/gitea/o/.hidden", "/gitea/o/acme/-x"]:
            a, fields = b.find(action="/gitea")
            status, _, _ = b.post(bad, fields)
            check(status == 404, f"{bad} is not found")
        a, fields = b.find(action="/gitea")
        status, _, _ = b.post("/gitea/o/nobody", fields)
        check(status == 404, "an owner that is not there is not found")
        status, headers, _ = b.post("/gitea/owners", fields)
        check(status in (302, 303), "a used token goes home")
        # --- the token, write-only ---
        b.post("/sign-in", {"username": "tester", "password": "secret"})
        b.click(action="/")
        b.click(action="/settings")
        check('name="GITHUB_TOKEN"' in b.page and "not set" in b.page, "settings: the GitHub token is not set")
        check("Test the token" not in b.page, "negative: no token, no Test the token button")
        a, fields = b.find(label="Save")
        fields.update({"GITHUB_TOKEN": "ghp_test_TOKEN_never_shown"})
        b.post("/settings", fields)
        tok = os.path.join(srv, "settings", "github-token.ini")
        check(os.path.isfile(tok) and open(tok).read().strip() == "ghp_test_TOKEN_never_shown"
              and (os.stat(tok).st_mode & 0o077) == 0, "the token is saved to its own file, mode 0600")
        check("ghp_test_TOKEN" not in b.page and "ghp_test_TOKEN" not in open(os.path.join(srv, "settings", "settings.ini")).read(),
              "the token is not shown and not in settings.ini")
        # --- Test the token: GitHub's GET /user, from Settings and the import page ---
        b.click(action="/settings")
        b.click(label="Test the token")
        check("GitHub does not accept the token" in b.page and "ghp_test_TOKEN" not in b.page,
              "Test the token: a token GitHub does not accept says so, and is not shown")
        with open(tok, "w") as f:
            f.write("good\n")
        b.click(action="/gitea/import")
        b.click(label="Test the token")
        check("GitHub accepts the token. Signed in as octo" in b.page and "4987 / 5000" in b.page
              and "Import from GitHub" in b.page, "Test the token on the import page: the login and the hour's requests")
        act = sqlite3.connect(os.path.join(srv, "db", "activity.db"))
        tested = [r[0] for r in act.execute(
            "SELECT status_text FROM activity WHERE action_name = 'gitea-token-tested' ORDER BY rowid")]
        act.close()
        check(tested == ["rejected", "ok"], f"each test is in the activity log, without the token {tested}")
        with open(tok, "w") as f:
            f.write("ghp_test_TOKEN_never_shown\n")
        # --- Stop: a running import job gets a Stop button; it leaves a stop file ---
        jobs = os.path.join(srv, "gitea-jobs")
        os.makedirs(jobs, exist_ok=True)
        running = "2026-01-01_00-00-00-import-omigh.log"
        with open(os.path.join(jobs, running), "w") as f:
            f.write("omigh/proj:\n  GitHub: few requests left this hour.\n")
        for name, text in (("2026-01-01_00-00-01-import-done.log", "done\nexit 0\n"),
                           ("2026-01-01_00-00-02-delete-Someone.log", "deleting\n")):
            with open(os.path.join(jobs, name), "w") as f:
                f.write(text)
        b.click(action="/gitea")
        b.click(action="/gitea/jobs")
        b.click(action="/gitea/jobs/2026-01-01_00-00-01-import-done.log")
        check("Stop" not in b.page.split("<pre>")[0], "negative: a finished import has no Stop")
        b.click(action="/gitea/jobs")
        b.click(action="/gitea/jobs/2026-01-01_00-00-02-delete-Someone.log")
        check("Still running" in b.page, "a running delete is running")
        check('value="Stop"' not in b.page, "negative: a delete cannot be stopped half way")
        b.click(action="/gitea/jobs")
        b.click(action="/gitea/jobs/" + running)
        check('value="Stop"' in b.page, "a running import has a Stop button")
        stopf = os.path.join(jobs, running[:-4] + ".stop")
        b.click(label="Stop")
        check(os.path.isfile(stopf) and "Stopping" in b.page and 'value="Stop"' not in b.page,
              "Stop leaves the stop file the import reads, and says it is stopping")
        os.remove(stopf)
        check("Progress" not in b.page and "job-progress-done" not in b.page,
              "negative: a job whose log has no progress lines shows no progress bar")
        # --- progress, newest lines and errors of a running delete ---
        prog = "2026-01-01_00-00-03-delete-Big.log"
        with open(os.path.join(jobs, prog), "w") as f:
            f.write("Planning the delete of Big: the rows and the files it removes.\n"
                    "progress 0/10 rows\nprogress 3/10 rows: issue 120\n"
                    "warning: cannot remove /data/x: error 13\n"
                    "progress 4/10 rows committed: 340\n")
        b.click(action="/gitea/jobs")
        b.click(action="/gitea/jobs/" + prog)
        check("Progress: <b>40 %</b> (4 / 10) rows committed: 340" in b.page and 'width="40%"' in b.page
              and "job-progress-done" in b.page, "a running delete shows its progress bar, percentage and step")
        check("Errors" in b.page and "cannot remove /data/x" in b.page.split("Newest log lines")[0],
              "and its errors, above the newest lines")
        check("Newest log lines" in b.page and "Planning the delete of Big" in b.page
              and "progress 3/10" not in b.page, "and its newest lines, without the progress lines")
        with open(os.path.join(jobs, prog), "a") as f:
            f.write("progress 7/10 files: repository /data/big.git\n")
        b.click(label="Refresh")
        check("Progress: <b>70 %</b> (7 / 10)" in b.page, "Refresh shows the new progress")
        with open(os.path.join(jobs, prog), "a") as f:
            f.write("Deleted Big: 340 rows, 6 files, 1000 bytes freed.\nexit 0\n")
        b.click(action="/gitea/jobs")
        b.click(action="/gitea/jobs/" + prog)
        check("Progress: <b>100 %</b>" in b.page and "Finished with exit code" in b.page,
              "a finished delete shows 100 %")
        # --- deleting from the pages ---
        b.click(action="/gitea")
        b.click(action="/gitea/owners")
        b.click(action="/gitea/o/Bob")
        b.click(action="/gitea/o/Bob/delete")
        check("Deleting it removes" in b.page and "package_blob" not in b.page and "repository" in b.page
              and "tool" in b.page, "the delete page shows the dry run")
        check("no github-to-gitea backup" in b.page, "and that there is no backup of Bob")
        a, fields = b.find(action="/gitea/o/Bob/delete", label="Delete")
        status, _, _ = b.post(a, dict(fields, confirm="bob"))
        check("Nothing was deleted" in b.page, "a wrong name (another case) deletes nothing")
        a, fields = b.find(action="/gitea/o/Bob/delete", label="Delete")
        forged = dict(fields, confirm="Bob", auth_action="gitea-delete:acme")
        status, headers, _ = b.post(a, forged)
        check(status in (302, 303), "a delete token for another owner goes home")
        b.post("/sign-in", {"username": "tester", "password": "secret"})
        b.click(action="/")
        b.click(action="/gitea")
        b.click(action="/gitea/owners")
        b.click(action="/gitea/o/Bob")
        b.click(action="/gitea/o/Bob/delete")
        a, fields = b.find(action="/gitea/o/Bob/delete", label="Delete")
        b.post(a, dict(fields, confirm="Bob"))
        check("Started" in b.page and "-delete-Bob.log" in b.page, "the delete runs as a job")
        act = sqlite3.connect(os.path.join(srv, "db", "activity.db"))
        started = act.execute("SELECT COUNT(*) FROM activity WHERE action_name = 'gitea-delete' AND status_text = 'started'").fetchone()[0]
        act.close()
        check(started == 1, f"one request starts one job ({started})")
        job = re.search(r"([0-9_-]+-delete-Bob\.log)", b.page).group(1)
        for _ in range(100):
            if "exit " in open(os.path.join(srv, "gitea-jobs", job)).read():
                break
            time.sleep(0.2)
        log_text = open(os.path.join(srv, "gitea-jobs", job)).read()
        check(log_text.rstrip().endswith("exit 0") and "ghp_test_TOKEN" not in log_text, f"the job finished {log_text[-300:]}")
        progress = re.findall(r"^progress (\d+)/(\d+) ", log_text, re.M)
        check(progress and progress[0][0] == "0" and progress[-1][0] == progress[-1][1]
              and all(int(a) <= int(b) for a, b in progress)
              and [int(a) for a, _ in progress] == sorted(int(a) for a, _ in progress),
              f"the delete writes its progress, counting up to its total {progress[:3]}...{progress[-2:]}")
        b.click(action="/gitea")
        b.click(action="/gitea/jobs")
        check(job in b.page, "the jobs page lists it")
        b.click(action="/gitea/jobs/" + job)
        check("Finished with exit code" in b.page, "the job page")
        c = sqlite3.connect(os.path.join(work, "data", "gitea.db"))
        check(c.execute("SELECT COUNT(*) FROM user WHERE lower_name = 'bob'").fetchone()[0] == 0, "Bob is deleted")
        c.close()
        a, fields = b.find(action="/gitea")
        status, _, _ = b.post("/gitea/jobs/..%2Fsettings.ini", fields)
        check(status == 404, "a job name is never a path")
        # --- one repository: not synced any more, then deleted ---
        exf = os.path.join(srv, "sync-exclude.txt")
        b.click(action="/gitea")
        b.click(action="/gitea/owners")
        b.click(action="/gitea/o/acme")
        check('action="/gitea/o/acme/small/delete"' in b.page and "Sync" in b.page,
              "the owner page has a delete action and a sync column for each repository")
        b.click(action="/gitea/o/acme/small")
        b.click(label="Do not sync this repository any more")
        check("Not synced" in b.page and "Include again" in b.page and os.path.isfile(exf)
              and "acme/small" in open(exf).read(), "do not sync this repository any more: in the shared exclude file")
        a, fields = b.find(label="Include again")
        forged = dict(fields, auth_action="gitea-sync:acme/big")
        status, _, _ = b.post(a, forged)
        check(status in (302, 303) and "acme/small" in open(exf).read(), "a sync token for another repository goes home")
        b.post("/sign-in", {"username": "tester", "password": "secret"})
        b.click(action="/")
        b.click(action="/gitea")
        b.click(action="/gitea/repos")
        check("Not synced" in b.page, "the repository listing shows it is not synced")
        b.click(action="/gitea/o/acme/small")
        b.click(label="Include again")
        check("Do not sync this repository any more" in b.page and "acme/small" not in open(exf).read(),
              "include again removes the line")
        b.click(label="Delete this repository and its files")
        check("Deleting it removes" in b.page and "Space freed" in b.page and 'name="exclude" value="1" checked' in b.page,
              "the repository delete page: the dry run, and exclude from sync ticked")
        a, fields = b.find(action="/gitea/o/acme/small/delete", label="Delete")
        b.post(a, dict(fields, confirm="acme/Small", exclude="1"))
        check("Nothing was deleted" in b.page, "a wrong owner/name deletes nothing")
        a, fields = b.find(action="/gitea/o/acme/small/delete", label="Delete")
        b.post(a, dict(fields, confirm="acme/small", exclude="1"))
        check("Started" in b.page and "-delete-acme-small.log" in b.page, "the repository delete runs as a job")
        job = re.search(r"([0-9_-]+-delete-acme-small\.log)", b.page).group(1)
        for _ in range(100):
            if "exit " in open(os.path.join(srv, "gitea-jobs", job)).read():
                break
            time.sleep(0.2)
        check(open(os.path.join(srv, "gitea-jobs", job)).read().rstrip().endswith("exit 0"), "the job finished")
        check("acme/small" in open(exf).read(), "the deleted repository is excluded from sync")
        b.click(action="/gitea")
        b.click(action="/gitea/owners")
        check("<s>acme/small</s>" in b.page and "freed" in b.page, "the Sizes page lists it as deleted, with the space freed")
        b.click(action="/gitea/o/acme")
        check("<s>acme/small</s>" in b.page and 'action="/gitea/o/acme/small"' not in b.page
              and "Out of date since a deletion" in b.page, "the owner page: deleted, without a link; the index is stale")
        b.click(action="/gitea")
        b.click(action="/gitea/repos")
        check("<s>acme/small</s>" in b.page, "the repository listing lists it as deleted")
        b.click(action="/gitea")
        b.click(action="/gitea/import")
        check("Import from GitHub" in b.page and ">set<" in b.page, "the import page, with the token set")
        a, fields = b.find(action="/gitea/import", label="Import from GitHub")
        b.post(a, dict(fields, owner="../x", repos=""))
        check("not a valid owner" in b.page, "an import of a name that is not a name is refused")
        check(server.poll() is None, "the server is still running")
    finally:
        user_api.close()
        server.terminate()
        try:
            server.wait(10)
        except subprocess.TimeoutExpired:
            server.kill()


# Options only the old Python reference took; Omi itself does not need them.
_PY_ONLY = ("--mirror-dir", "--token-file", "--backups-dir", "--github-api", "--github-web", "--gitea-binary")


def omigitea(*args):
    """A write, by Omi itself: ./public/server gitea delete-repo|delete-owner|exclude|status."""
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
            continue
        if a in _PY_ONLY:
            skip = True
            continue
        if a.split("=", 1)[0] in _PY_ONLY:
            continue
        out.append(a)
    if out and out[0] == "delete":
        out[0] = "delete-owner"
    r = subprocess.run([SERVER, "gitea", *out], capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def pascal_lists():
    """GW_SETS, GW_DELETES, GW_KEPT and GW_REF_COLUMNS of public/omigiteaw.pas."""
    src = open(os.path.join(REPO, "public", "omigiteaw.pas"), encoding="utf-8").read()

    def pairs(name):
        block = src[src.index(f"  {name}: array"):]
        block = block[:block.index("  );")]
        return [(a.replace("''", "'"), b.replace("''", "'"))
                for a, b in re.findall(r"\(A: '((?:[^']|'')*)'; B: '((?:[^']|'')*)'\)", block)]

    class L:
        pass
    lists = L()
    lists.SETS = pairs("GW_SETS")
    lists.DELETES = pairs("GW_DELETES")
    lists.KEPT = {tuple(a.split(".", 1)): b for a, b in pairs("GW_KEPT")}
    lists.REF_COLUMNS = set(re.search(r"GW_REF_COLUMNS = '([^']*)'", src).group(1).split())
    return lists


def test_delete_fixture(work):
    """Deleting an owner of the fixture: the dry run, the refusals, what goes and what stays."""
    g = os.path.join(work, "gdel")
    ids = fx.make(g)
    ini = os.path.join(g, "custom", "conf", "app.ini")
    S = fx.SIZES
    rc, out, err = omigitea("delete", "--config", ini, "--owner", "acme", "--dry-run", "--json")
    import json as _json
    plan = _json.loads(out) if rc == 0 else {}
    acme_bytes = (S["acme/big.git"] + S["acme/big.wiki.git"] + S["acme/small.git"] + S["att_big"] + S["att_rel"]
                  + S["lfs_shared"] + S["avatar_acme"])
    check(plan.get("bytes") == acme_bytes and plan.get("repositories") == ["big", "small"],
          f"dry run: acme's repositories and the bytes freed ({plan.get('bytes')})")
    check(plan.get("tables", {}).get("repository") == 2 and plan["tables"].get("lfs_meta_object") == 3
          and plan["tables"].get("issue") == 2, "dry run: rows per table")
    dbp = os.path.join(g, "data", "gitea.db")

    def repos():
        # Opened and closed each time: an open database counts as Gitea running.
        c = sqlite3.connect(dbp)
        try:
            return c.execute("SELECT COUNT(*) FROM repository").fetchone()[0]
        finally:
            c.close()

    before = repos()
    for confirm, what in ((None, "without the typed name"), ("acm", "with a wrong name"), ("ACME", "with the name in another case")):
        args = ["delete", "--config", ini, "--owner", "acme"] + (["--confirm", confirm] if confirm else [])
        rc, out, err = omigitea(*args)
        check(rc != 0 and repos() == before,
              f"a delete {what} is refused and deletes nothing")
    for bad in ("../acme", "acme/..", "a/b", ".hidden", "-x", "a b", "acme%2f"):
        rc, out, err = omigitea("delete", "--config", ini, "--owner=" + bad, "--confirm=" + bad)
        check(rc != 0 and "not a Gitea owner name" in err, f"owner name {bad!r} is refused")
    # Gitea "running": something answers on its HTTP port.
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    s.listen(1)
    port = s.getsockname()[1]
    text = open(ini).read().replace("HTTP_PORT = 1\n", f"HTTP_PORT = {port}\n")
    open(ini, "w").write(text)
    rc, out, err = omigitea("delete", "--config", ini, "--owner", "acme", "--confirm", "acme")
    check(rc != 0 and "Gitea is running" in err and repos() == before,
          "a delete while Gitea's port answers is refused")
    s.close()
    open(ini, "w").write(text.replace(f"HTTP_PORT = {port}\n", "HTTP_PORT = 1\n"))
    # A lock of a living program refuses; a stale one is taken over.
    lock = os.path.join(g, "data", ".omi-gitea.lock")
    with open(lock, "w") as f:
        f.write(f"{os.getpid()} {socket.gethostname()} other 2026-01-01T00:00:00Z\n")
    rc, out, err = omigitea("delete", "--config", ini, "--owner", "acme", "--confirm", "acme")
    check(rc != 0 and "another program" in err and os.path.exists(lock), "a lock held by a living program refuses")
    with open(lock, "w") as f:
        f.write(f"999999999 {socket.gethostname()} other 2026-01-01T00:00:00Z\n")
    # An interrupted earlier delete: its journal names a file whose row is gone, and one still used.
    orphan_att = os.path.join(g, "data", "attachments", fx.ATT_ORPHAN[0], fx.ATT_ORPHAN[1], fx.ATT_ORPHAN)
    kept_att = os.path.join(g, "data", "attachments", fx.ATT_SIZE[0], fx.ATT_SIZE[1], fx.ATT_SIZE)
    with open(os.path.join(g, "data", ".omi-gitea.journal"), "w") as f:
        _json.dump({"op": "test", "entries": [{"path": orphan_att, "kind": "attachment", "key": fx.ATT_ORPHAN},
                                              {"path": kept_att, "kind": "attachment", "key": fx.ATT_SIZE}]}, f)
    rc, out, err = omigitea("delete", "--config", ini, "--owner", "acme", "--confirm", "acme")
    check(rc == 0, f"delete with the typed name {err.strip()[-300:]}")
    check(not os.path.exists(lock) and not os.path.exists(os.path.join(g, "data", ".omi-gitea.journal")),
          "a stale lock was taken over; no lock or journal is left")
    check(not os.path.exists(orphan_att) and os.path.exists(kept_att),
          "an interrupted write's journal was finished: only the file no row uses was removed")
    data = os.path.join(g, "data")
    gone = [os.path.join(data, "gitea-repositories", "acme"),
            os.path.join(data, "attachments", fx.ATT_BIG[0], fx.ATT_BIG[1], fx.ATT_BIG),
            os.path.join(data, "lfs", fx.OID_SHARED[:2], fx.OID_SHARED[2:4], fx.OID_SHARED[4:]),
            os.path.join(data, "avatars", fx.AVATAR_ACME)]
    check(not any(os.path.exists(x) for x in gone), "acme's git folders, attachments, LFS objects and avatar are gone")
    kept = [os.path.join(data, "gitea-repositories", "bob", "tool.git"),
            os.path.join(data, "lfs", fx.OID_BOB[:2], fx.OID_BOB[2:4], fx.OID_BOB[4:]),
            os.path.join(data, "packages", fx.PKG_SHA[:2], fx.PKG_SHA[2:4], fx.PKG_SHA)]
    check(all(os.path.exists(x) for x in kept), "Bob's files stay")
    db = sqlite3.connect(dbp)
    left = {t: db.execute(f"SELECT COUNT(*) FROM `{t}` WHERE {w}", {"uid": ids["acme"]}).fetchone()[0]
            for t, w in (("user", "id = :uid"), ("repository", "owner_id = :uid"),
                         ("issue", f"repo_id IN ({ids['big']}, {ids['small']})"),
                         ("attachment", f"repo_id IN ({ids['big']}, {ids['small']})"),
                         ("lfs_meta_object", f"repository_id IN ({ids['big']}, {ids['small']})"))}
    check(not any(left.values()), f"no row of acme or its repositories is left {left}")
    check(db.execute("SELECT COUNT(*) FROM repository").fetchone()[0] == 1, "Bob's repository stays")
    db.close()
    # Bob, a user with a package.
    rc, out, err = omigitea("delete", "--config", ini, "--owner", "Bob", "--confirm", "Bob")
    check(rc == 0 and not os.path.exists(os.path.join(data, "packages", fx.PKG_SHA[:2], fx.PKG_SHA[2:4], fx.PKG_SHA)),
          "deleting a user with a package removes its blob")
    db = sqlite3.connect(os.path.join(g, "data", "gitea.db"))
    check(db.execute("SELECT COUNT(*) FROM package").fetchone()[0] == 0
          and db.execute("SELECT COUNT(*) FROM package_blob").fetchone()[0] == 0, "and its package rows")
    db.close()


def test_no_python_or_gitea_at_runtime():
    """Only Omi runs: no page and no command of the server starts Python or the
    gitea binary (git, as Gitea itself runs it, is allowed)."""
    bad = []
    for name in ("server.pas", "omigitea.pas", "omigiteaw.pas"):
        path = os.path.join(REPO, "public", name)
        if not os.path.isfile(path):
            continue
        for n, line in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
            code = re.sub(r"//.*$", "", line)
            if re.search(r"python|omigitea\.py|omigitea_import", code, re.I) and "'.py'" not in code:
                bad.append(f"{name}:{n}: {line.strip()[:80]}")
            if re.search(r"(Executable|RunCommand|Parameters\.Add)\b.*\b(GITEA_BINARY|gitea-binary|GetGiteaBinary)", code):
                bad.append(f"{name}:{n}: {line.strip()[:80]}")
    check(not bad, f"no Python and no gitea binary is executed by the server {bad[:5]}")


GITEA_UNITS = ("omigitea.pas", "omigiteaw.pas", "omigiteai.inc", "omigit.pas")
# What only a Unix system has: these units, calls and constants must be inside
# {$IFDEF UNIX} (or the {$ELSE} of an {$IFNDEF UNIX}) in the Gitea units.
UNIX_ONLY = re.compile(r"\b(BaseUnix|Unix|Sockets|cthreads|fp(?:Open|Read|Write|Close|Fsync|Rename|LStat|Stat|"
                       r"OpenDir|ReadDir|CloseDir|Kill|GetPid|ReadLink|Chmod|GetErrno|Unlink|Rmdir|Socket|Connect|"
                       r"Bind|S_IS[A-Z]+)|O_(?:EXCL|CREAT|TRUNC|APPEND|RDONLY|WRONLY|RDWR)|ESys[A-Z]+|cint|TSsize|"
                       r"c_realpath|GetHostName|TInetSockAddr|StrToNetAddr|htons)\b|/proc\b")
# A path variable followed by a '/' literal: a path built with '/' instead of
# GtPath (PathDelim, and no '/' after an Amiga volume name).
SLASH_JOIN = re.compile(r"\b(P\.[A-Z]\w*|Paths\.\w+|\w*(?:Dir|Root|Path|Paths)|Tmp|Cwd)\s*\+\s*'/")


def unix_guarded_lines(text):
    """The line numbers that are compiled only on Unix."""
    stack, out = [], set()
    for n, line in enumerate(text.splitlines(), 1):
        m = re.match(r"\s*\{\$(IFDEF|IFNDEF|IF|ELSE|ENDIF|IFEND)\b\s*([^}]*)\}", line, re.I)
        if m:
            kind, arg = m.group(1).upper(), m.group(2).strip().upper()
            if kind in ("IFDEF", "IFNDEF", "IF"):
                unix = (kind == "IFDEF" and arg == "UNIX") or (kind == "IF" and re.fullmatch(r"DEFINED\(UNIX\)", arg))
                stack.append("unix" if unix else ("notunix" if kind == "IFNDEF" and arg == "UNIX" else "other"))
            elif kind == "ELSE" and stack:
                stack[-1] = {"unix": "notunix", "notunix": "unix"}.get(stack[-1], "other")
            elif stack:
                stack.pop()
            continue
        if "unix" in stack:
            out.add(n)
    return out


def test_portable_source():
    """The Gitea units build their paths with GtPath and keep what only Unix has
    behind {$IFDEF UNIX}: they compile for the Amiga, where only Omi runs."""
    slash, unix, forced = [], [], []
    for name in GITEA_UNITS:
        path = os.path.join(REPO, "public", name)
        if not os.path.isfile(path):
            continue
        text = open(path, encoding="utf-8").read()
        guarded = unix_guarded_lines(text)
        in_brace = False
        for n, line in enumerate(text.splitlines(), 1):
            code = line
            # Comments: { ... } (possibly over lines, not {$...}) and //.
            if in_brace:
                if "}" not in code:
                    continue
                code = code[code.index("}") + 1:]
                in_brace = False
            code = re.sub(r"\{(?!\$)[^}]*\}", "", code)
            if re.search(r"\{(?!\$)", code):
                code = code[:re.search(r"\{(?!\$)", code).start()]
                in_brace = True
            code = re.sub(r"//.*$", "", re.sub(r"'(?:[^']|'')*'", lambda m: m.group(0) if m.group(0).startswith("'/") else "''", code))
            if re.match(r"\s*\{\$", code) or n in guarded:
                continue
            if SLASH_JOIN.search(code):
                slash.append(f"{name}:{n}: {line.strip()[:90]}")
            if UNIX_ONLY.search(code):
                unix.append(f"{name}:{n}: {line.strip()[:90]}")
            if re.search(r"\bForceDirectories\(", code):
                forced.append(f"{name}:{n}: {line.strip()[:90]}")
    check(not slash, f"no path of the Gitea units is built with a '/' literal {slash[:5]}")
    check(not unix, f"no Unix-only unit or call outside {{$IFDEF UNIX}} in the Gitea units {unix[:5]}")
    # SysUtils' ForceDirectories asks the Amiga for "Work:/" and fails.
    check(not forced, f"directories are made with GtForceDirs, not ForceDirectories {forced[:5]}")
    # And the scan itself finds what it is for.
    probe = "uses BaseUnix;\n{$IFDEF UNIX}\nfpFsync(Fd);\n{$ELSE}\nX := fpRename(A, B);\n{$ENDIF}\n"
    g = unix_guarded_lines(probe)
    check(g == {3} and SLASH_JOIN.search("Path := P.RepoRoot + '/' + Name") and SLASH_JOIN.search("GitDir + '/hooks'")
          and not SLASH_JOIN.search("Key := Owner + '/' + Name"), "the scan sees an unguarded call, a guarded one and a '/' join")


def test_delete_coverage():
    """Every column of Gitea's schema that points at an owner or a repository is
    deleted by GW_DELETES of public/omigiteaw.pas or kept, with a reason, in GW_KEPT."""
    og = pascal_lists()
    check(len(og.DELETES) > 100 and len(og.SETS) > 15 and len(og.KEPT) > 20, "the Pascal lists are read")
    schemas = [p for p in (os.path.join(gitea_live.SOURCE, "data", "gitea.db"), os.path.join(TOOLS, "gitea.db"))
               if os.path.isfile(p)]
    for path in schemas:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
        deletes = {}
        for t, w in og.DELETES:
            deletes.setdefault(t, "")
            deletes[t] += " " + w
        sets = dict(og.SETS)
        missing = []
        for t in tables:
            for col in (r[1] for r in db.execute(f"PRAGMA table_info(`{t}`)")):
                if col not in og.REF_COLUMNS or (t, col) in og.KEPT:
                    continue
                where = deletes.get(t, "")
                # "id IN d_x" deletes by a set made from this table's own column.
                for name in re.findall(r"\bid IN (d_\w+)", where):
                    where += " " + sets.get(name, "")
                if not re.search(r"\b" + col + r"\b", where):
                    missing.append(f"{t}.{col}")
        check(not missing, f"every owner/repository column of {os.path.basename(os.path.dirname(path)) or path} "
              f"is deleted or kept with a reason {missing}")
        unknown = [t for t, _ in og.DELETES if t not in tables]
        check(not unknown, f"every table Omi deletes from exists {unknown}")
        db.close()
    check(all(len(r) > 10 for r in og.KEPT.values()), "every kept column says why")


def test_delete_live(work):
    """Against a copy of the test Gitea: make an organization with a repository,
    issues, a comment, a label, a milestone, attachments and a release through
    Gitea's API; refuse the delete while Gitea runs; delete it with Gitea stopped;
    then `gitea doctor check --all` finds nothing new, and Gitea no longer has it."""
    if not gitea_live.available():
        print("skip the live Gitea: no test Gitea at " + gitea_live.SOURCE)
        return
    g = gitea_live.GiteaCopy(os.path.join(work, "live-delete"))
    g.start()
    try:
        _, me = g.api("GET", "/api/v1/user")
        doer = me.get("login") if isinstance(me, dict) else None
        check(bool(doer), "the test Gitea's token works")
        s, _ = g.api("POST", "/api/v1/orgs", {"username": "omidel", "visibility": "public"})
        s2, repo = g.api("POST", "/api/v1/orgs/omidel/repos", {"name": "proj", "auto_init": True})
        s3, _ = g.api("POST", "/api/v1/repos/omidel/proj/labels", {"name": "bug", "color": "#ee0701"})
        s4, _ = g.api("POST", "/api/v1/repos/omidel/proj/milestones", {"title": "v1"})
        s5, issue = g.api("POST", "/api/v1/repos/omidel/proj/issues", {"title": "To be deleted", "body": "x"})
        s6, _ = g.api("POST", "/api/v1/repos/omidel/proj/issues/1/comments", {"body": "a comment"})
        s7, att = g.upload("/api/v1/repos/omidel/proj/issues/1/assets", "attachment", "note.txt", b"note " * 100)
        s8, rel = g.api("POST", "/api/v1/repos/omidel/proj/releases", {"tag_name": "v1.0", "name": "One"})
        s9, ratt = g.upload(f"/api/v1/repos/omidel/proj/releases/{rel.get('id') if isinstance(rel, dict) else 0}/assets",
                            "attachment", "app.bin", os.urandom(3000))
        g.api("PUT", "/api/v1/repos/omidel/proj/topics", {"topics": ["omi-delete-test"]})
        g.api("PUT", "/api/v1/user/starred/omidel/proj")
        check([s, s2, s3, s4, s5, s6, s7, s8, s9] == [201] * 9, f"made omidel/proj through the API {[s, s2, s3, s4, s5, s6, s7, s8, s9]}")
        att_paths = [os.path.join(g.work, "data", "attachments", u[0], u[1], u)
                     for u in (att.get("uuid", "x"), ratt.get("uuid", "x"))] if isinstance(att, dict) and isinstance(ratt, dict) else []
        check(len(att_paths) == 2 and all(os.path.isfile(x) for x in att_paths), "the attachment files are there")
        rc, out, err = omigitea("delete", "--config", g.ini, "--owner", "omidel", "--dry-run", "--json")
        check(rc == 0 and __import__("json").loads(out).get("running") and "omidel" in out, "a dry run works while Gitea runs and says it runs")
        rc, out, err = omigitea("delete", "--config", g.ini, "--owner", "omidel", "--confirm", "omidel")
        check(rc != 0 and "Gitea is running" in err, "the delete is refused while Gitea runs")
        check(g.api("GET", "/api/v1/repos/omidel/proj")[0] == 200, "and Gitea still has the repository")
    finally:
        g.stop()
    rc, before, text = g.doctor()
    check(rc == 0, "gitea doctor check --all before")
    rc, out, err = omigitea("delete", "--config", g.ini, "--owner", "omidel", "--confirm", "omidel", "--json")
    check(rc == 0, f"the delete with Gitea stopped {err.strip()[-300:]}")
    check(not os.path.exists(os.path.join(g.repo_root, "omidel")) and not any(os.path.exists(x) for x in att_paths),
          "the repository folder and the attachment files are gone")
    rc, after, text = g.doctor()
    new = [x for x in after if x not in before]
    check(rc == 0 and not new, f"gitea doctor check --all after the delete finds nothing new {new}")
    g.start()
    try:
        check(g.api("GET", "/api/v1/orgs/omidel")[0] == 404 and g.api("GET", "/api/v1/repos/omidel/proj")[0] == 404,
              "Gitea no longer has the organization or its repository")
        s, _ = g.api("POST", "/api/v1/orgs", {"username": "omidel", "visibility": "public"})
        s2, _ = g.api("POST", "/api/v1/orgs/omidel/repos", {"name": "proj", "auto_init": True})
        check(s == 201 and s2 == 201, "and the same names can be made again")
    finally:
        g.stop()


def refs_of(git_dir):
    """A bare repository's refs/heads, refs/tags and refs/pull, as git sees them."""
    r = subprocess.run(["git", "-C", git_dir, "for-each-ref", "--format=%(objectname) %(refname)",
                        "refs/heads", "refs/tags", "refs/pull"], capture_output=True, text=True)
    return sorted(r.stdout.split("\n")[:-1]) if r.returncode == 0 else ["error " + r.stderr]


def remote_refs(url):
    """What `git ls-remote` says of the same refs (no HEAD, no peeled tags)."""
    r = subprocess.run(["git", "ls-remote", url], capture_output=True, text=True)
    out = []
    for line in r.stdout.splitlines():
        sha, name = line.split("\t")
        if name.startswith(("refs/heads/", "refs/tags/", "refs/pull/")) and not name.endswith("^{}"):
            out.append(f"{sha} {name}")
    return sorted(out)


def test_pascal_git(work):
    """git in Pascal (public/omigit.pas) against git http-backend: a first fetch
    into a new bare repository, an incremental one, deltas (OFS_DELTA from the
    server, REF_DELTA and its .idx byte for byte as git index-pack writes it), a
    thin pack refused, objects in scratch files, a pack too large for the
    platform refused, and an empty repository; checked with git fsck --full,
    git log and git ls-remote."""
    import json as _json
    import git_http
    idg = ["-c", "user.name=U", "-c", "user.email=u@example.org"]

    def git(*a, cwd=None):
        return subprocess.run(["git", *idg, *a], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()

    root = os.path.join(work, "served")
    src = os.path.join(work, "src")
    os.makedirs(root)
    git("init", "-q", "-b", "main", src)
    with open(os.path.join(src, "big.txt"), "w") as f:
        f.write("".join(f"line {i}\n" for i in range(20000)))
    for i in range(12):
        lines = open(os.path.join(src, "big.txt")).read().split("\n")
        lines[i * 700] = f"changed {i}"
        open(os.path.join(src, "big.txt"), "w").write("\n".join(lines))
        git("add", ".", cwd=src)
        git("commit", "-q", "-m", f"Commit {i}\n\nThe body of {i}.", cwd=src)
    git("tag", "-a", "v1", "-m", "Version 1", cwd=src)
    git("tag", "light", "HEAD~3", cwd=src)
    bare = os.path.join(root, "r.git")
    subprocess.run(["git", "clone", "-q", "--bare", src, bare], check=True, capture_output=True)
    git("update-ref", "refs/pull/1/head", "HEAD~2", cwd=bare)
    # Deltas the server sends as they are (OFS_DELTA).
    git("repack", "-adfq", "--depth=50", "--window=250", cwd=bare)
    srv = git_http.GitHttp(root)
    try:
        def fetch(d, **env):
            r = subprocess.run([SERVER, "gitea", "git-fetch"], capture_output=True, text=True,
                               env=dict(os.environ, OMI_GIT_DIR=d, OMI_GIT_URL=f"{srv.url}/r.git", **env))
            try:
                return r.returncode, _json.loads(r.stdout)
            except ValueError:
                return r.returncode, {"error": r.stdout + r.stderr}

        def fsck(d):
            return subprocess.run(["git", "-C", d, "fsck", "--full", "--strict"], capture_output=True, text=True)

        dst = os.path.join(work, "dst.git")
        rc, j = fetch(dst)
        deltas = [l for l in git("verify-pack", "-v", *[os.path.join(dst, "objects", "pack", x) for x in
                                 os.listdir(os.path.join(dst, "objects", "pack")) if x.endswith(".idx")]).splitlines()
                  if len(l.split()) == 7]
        check(rc == 0 and j.get("objects", 0) > 30 and len(deltas) >= 10,
              f"the first fetch into a new bare repository, with deltas {j} {len(deltas)}")
        check(fsck(dst).returncode == 0, f"git fsck --full --strict {fsck(dst).stderr[-300:]}")
        check(refs_of(dst) == remote_refs(f"{srv.url}/r.git"), "the refs are what git ls-remote says")
        check(open(os.path.join(dst, "HEAD")).read() == "ref: refs/heads/main\n", "HEAD is the server's symref")
        check(git("log", "--format=%s", "main", cwd=dst).splitlines()[:2] == ["Commit 11", "Commit 10"], "git log")
        info = open(os.path.join(dst, "info", "refs")).read()
        theirs = os.path.join(work, "theirs.git")
        subprocess.run(["git", "clone", "-q", "--mirror", bare, theirs], check=True, capture_output=True)
        git("update-server-info", cwd=theirs)
        check(info == open(os.path.join(theirs, "info", "refs")).read(),
              "info/refs is what git update-server-info writes (the peeled tag too)")
        packs = open(os.path.join(dst, "objects", "info", "packs")).read()
        check(packs.startswith("P pack-") and packs.endswith(".pack\n\n"), "objects/info/packs")
        for x in ("config", "description", os.path.join("info", "exclude")):
            check(open(os.path.join(dst, x)).read() == open(os.path.join(theirs, x)).read()
                  or (x == "config" and "[remote" not in open(os.path.join(dst, x)).read()),
                  f"{x} as `git clone --mirror` writes it")
        # The .idx git would write for the same pack.
        pk = [x for x in os.listdir(os.path.join(dst, "objects", "pack")) if x.endswith(".pack")][0]
        cp = os.path.join(work, "copy.pack")
        shutil.copy(os.path.join(dst, "objects", "pack", pk), cp)
        subprocess.run(["git", "index-pack", "-o", os.path.join(work, "copy.idx"), cp], check=True, capture_output=True)
        check(open(os.path.join(work, "copy.idx"), "rb").read() ==
              open(os.path.join(dst, "objects", "pack", pk[:-5] + ".idx"), "rb").read(),
              "the .idx is byte for byte what git index-pack writes (OFS_DELTA)")
        # Nothing new: no POST, nothing changed.
        srv.log.clear()
        rc, j = fetch(dst)
        check(rc == 0 and j.get("objects") == 0 and not [x for x in srv.log if x["method"] == "POST"],
              f"a fetch with nothing new asks for nothing {j}")
        # An incremental fetch: a new commit on main, a new branch, a moved pull ref.
        with open(os.path.join(src, "big.txt"), "a") as f:
            f.write("more\n")
        git("commit", "-q", "-am", "Commit 12", cwd=src)
        git("push", "-q", bare, "main", cwd=src)
        git("checkout", "-q", "-b", "feature", "HEAD~5", cwd=src)
        with open(os.path.join(src, "new.txt"), "w") as f:
            f.write("new\n")
        git("add", ".", cwd=src)
        git("commit", "-q", "-m", "Feature", cwd=src)
        git("push", "-q", bare, "feature", cwd=src)
        git("update-ref", "refs/pull/1/head", "feature", cwd=bare)
        srv.log.clear()
        rc, j = fetch(dst)
        posts = [x for x in srv.log if x["method"] == "POST"]
        check(rc == 0 and 0 < j.get("objects", 0) < 12 and posts and posts[0]["body"].count(b"have ") >= 3,
              f"an incremental fetch: only the new objects, with what it has said {j}")
        check(fsck(dst).returncode == 0 and refs_of(dst) == remote_refs(f"{srv.url}/r.git"),
              f"after it: git fsck --full and the refs of git ls-remote {fsck(dst).stderr[-200:]}")
        check(len([x for x in os.listdir(os.path.join(dst, "objects", "pack")) if x.endswith(".idx")]) == 2
              and not [x for x in os.listdir(os.path.join(dst, "objects", "pack")) if x.startswith("tmp_")],
              "a second pack beside the first, and no scratch file left")
        # Reading in Pascal what the import reads: refs (packed and loose),
        # tags peeled, commit times, subjects and counts - from packs, and from
        # loose objects (as Gitea's own pushes leave them).
        tree = git("rev-parse", "main^{tree}", cwd=dst)
        loose = git("commit-tree", tree, "-p", "main", "-m", "A loose commit\nwith two lines\n\nand a body", cwd=dst)
        git("update-ref", "refs/heads/loose", loose, cwd=dst)
        git("tag", "-a", "loose-tag", "-m", "a loose tag", loose, cwd=dst)
        check(os.path.isfile(os.path.join(dst, "objects", loose[:2], loose[2:])), "a loose commit, a loose ref, a loose tag")
        r = subprocess.run([SERVER, "gitea", "git-refs"], capture_output=True, text=True, env=dict(os.environ, OMI_GIT_DIR=dst))
        mine = {x["ref"]: x for x in _json.loads(r.stdout).get("refs", [])} if r.returncode == 0 else {}
        fer = git("for-each-ref", "--format=%(refname)%00%(objectname)%00%(*objectname)", cwd=dst).splitlines()
        bad = []
        for line in fer:
            ref, sha, target = line.split("\0")
            c = git("rev-parse", ref + "^{commit}", cwd=dst)
            want = {"sha": sha, "target": target, "commit": c, "time": int(git("log", "-1", "--format=%ct", c, cwd=dst)),
                    "count": int(git("rev-list", "--count", c, cwd=dst)),
                    "subject": git("for-each-ref", "--format=%(contents:subject)", ref, cwd=dst) if not target else
                    git("log", "-1", "--format=%s", c, cwd=dst)}
            got = {k: mine.get(ref, {}).get(k) for k in want}
            if got != want:
                bad.append((ref, got, want))
        check(fer and not bad and set(mine) == {l.split("\0")[0] for l in fer},
              f"every ref, peeled commit, time, subject and count as git says {bad[:2]}")
        # Every object in a scratch file instead of memory.
        rc, j = fetch(os.path.join(work, "scratch.git"), OMI_GIT_MEM_LIMIT="0")
        check(rc == 0 and fsck(os.path.join(work, "scratch.git")).returncode == 0
              and not [x for x in os.listdir(os.path.join(work, "scratch.git", "objects", "pack")) if x.startswith("tmp_")],
              f"objects a delta needs whole, in scratch files: fetched, git fsck, none left {j}")
        # A pack larger than the platform's files is refused, not stored.
        rc, j = fetch(os.path.join(work, "large.git"), OMI_TEST_MAX_FILE="1000")
        check(rc != 0 and "most 1000 bytes" in j.get("error", "")
              and not [x for x in os.listdir(os.path.join(work, "large.git", "objects", "pack"))],
              f"a pack larger than the platform addresses is refused, and nothing is left {j}")
        # REF_DELTA (git pack-objects without --delta-base-offset), indexed by
        # Omi and by git index-pack.
        refd = os.path.join(work, "refd")
        os.makedirs(refd)
        objs = git("rev-list", "--objects", "--all", cwd=src)
        name = subprocess.run(["git", "pack-objects", "-q", "--window=250", "--depth=50", os.path.join(refd, "p")],
                              input=objs + "\n", cwd=src, capture_output=True, text=True, check=True).stdout.strip()
        gpack = os.path.join(refd, f"p-{name}.pack")
        n_ref = len([l for l in git("verify-pack", "-v", gpack).splitlines() if len(l.split()) == 7])
        mine = os.path.join(refd, "mine")
        os.makedirs(mine)
        shutil.copy(gpack, os.path.join(mine, "in.pack"))
        r = subprocess.run([SERVER, "gitea", "git-index-pack", os.path.join(mine, "in.pack")], capture_output=True, text=True)
        out = _json.loads(r.stdout) if r.returncode == 0 else {}
        check(out.get("pack") == name and n_ref >= 10 and open(os.path.join(mine, f"pack-{name}.idx"), "rb").read() ==
              open(os.path.join(refd, f"p-{name}.idx"), "rb").read(),
              f"REF_DELTA: the pack's name and its .idx byte for byte as git index-pack {out} {n_ref}")
        # A thin pack (deltas on objects it does not carry) is refused.
        thin = os.path.join(refd, "thin")
        os.makedirs(thin)
        revs = git("rev-parse", "main", cwd=src) + "\n^" + git("rev-parse", "main~1", cwd=src) + "\n"
        data = subprocess.run(["git", "pack-objects", "-q", "--revs", "--thin", "--stdout"], input=revs.encode(),
                              cwd=src, capture_output=True, check=True).stdout
        with open(os.path.join(thin, "in.pack"), "wb") as f:
            f.write(data)
        r = subprocess.run([SERVER, "gitea", "git-index-pack", os.path.join(thin, "in.pack")], capture_output=True, text=True)
        check(r.returncode != 0 and "thin pack" in r.stdout and not [x for x in os.listdir(thin) if x.startswith("pack-")],
              f"a thin pack is refused and not stored {r.stdout[-200:]}")
        # A damaged pack is refused.
        bad = bytearray(open(gpack, "rb").read())
        bad[len(bad) // 2] ^= 0xFF
        with open(os.path.join(thin, "bad.pack"), "wb") as f:
            f.write(bad)
        r = subprocess.run([SERVER, "gitea", "git-index-pack", os.path.join(thin, "bad.pack")], capture_output=True, text=True)
        check(r.returncode != 0 and not [x for x in os.listdir(thin) if x.startswith("pack-")], "a damaged pack is refused")
        # An empty repository: nothing to fetch, nothing broken.
        subprocess.run(["git", "init", "-q", "--bare", os.path.join(root, "empty.git")], check=True)
        r = subprocess.run([SERVER, "gitea", "git-fetch"], capture_output=True, text=True,
                           env=dict(os.environ, OMI_GIT_DIR=os.path.join(work, "empty.git"), OMI_GIT_URL=f"{srv.url}/empty.git"))
        check(r.returncode == 0 and fsck(os.path.join(work, "empty.git")).returncode == 0
              and refs_of(os.path.join(work, "empty.git")) == [], f"an empty repository {r.stdout[-200:]}")
        r = subprocess.run([SERVER, "gitea", "git-fetch"], capture_output=True, text=True,
                           env=dict(os.environ, OMI_GIT_DIR=os.path.join(work, "none.git"), OMI_GIT_URL=f"{srv.url}/none.git"))
        check(r.returncode != 0, "a repository that is not there is an error")
    finally:
        srv.close()


def test_import_live(work):
    """GitHub (a fake one) into a copy of the test Gitea, with Gitea stopped; then
    Gitea serves it through its API, `gitea doctor check --all` finds nothing new,
    and a second import brings only what is new or changed."""
    import json as _json
    import fake_github
    mirror = os.environ.get("OMI_GITHUB_TO_GITEA_DIR") or os.path.join(TOOLS, "w", "gitea-patches", "mirror")
    if not gitea_live.available() or not os.path.isfile(os.path.join(mirror, "common", "github_backup.py")):
        print("skip the import: no test Gitea or no github-to-gitea")
        return
    fake = fake_github.FakeGitHub(os.path.join(work, "fake-github"))
    g = gitea_live.GiteaCopy(os.path.join(work, "live-import"))
    tok = os.path.join(work, "github-token")
    with open(tok, "w") as f:
        f.write("fake-secret-token\n")
    # git as github.com serves it: smart HTTP, from git http-backend. A fake
    # git program is on the PATH: with the default GIT_FETCH (pascal) it must
    # never run.
    env = dict(os.environ, OMI_GITHUB_GIT_ROOT=fake.git_url, OMI_GITHUB_FILE_HOSTS="")
    fake_git = make_fake_git(os.path.join(work, "import-fakegit"))
    calls = os.path.join(os.path.dirname(fake_git), "calls.log")
    env["PATH"] = os.path.dirname(fake_git) + os.pathsep + env.get("PATH", "")

    def imp(*extra):
        # Omi itself: ./public/server gitea import.
        r = subprocess.run([SERVER, "gitea", "import", "--config", g.ini, "--owner", "omigh",
                            "--token-file", tok, "--github-api", fake.api, "--github-web", fake.base,
                            "--gitea-binary", gitea_live.BINARY, "--json", *extra],
                           env=dict(env, OMI_GITHUB_NO_FILE_HOSTS="1"), capture_output=True, text=True)
        return r.returncode, r.stdout, r.stderr

    try:
        g.start()
        try:
            rc, out, err = imp()
            check(rc != 0 and "Gitea is running" in out, "an import while Gitea runs is refused")
            check(not fake.hits("/api/users/omigh"), "and nothing was asked from GitHub")
        finally:
            g.stop()
        rc, before, _ = g.doctor()
        rc, out, err = imp("--owner=../omigh")
        check(rc != 0 and "not a" in out, "an import of a name that is not a name is refused")
        # Stop (the job page's button): the stop file is read before every
        # request to GitHub, so this import stops before its first one.
        stopf = os.path.join(work, "import.stop")
        open(stopf, "w").close()
        rc, out, err = imp("--stop-file", stopf)
        check(rc != 0 and "stopped" in out and not fake.hits("/api/users/omigh"),
              f"a stopped import stops before asking GitHub anything {out[-200:]}")
        rc, after, _ = g.doctor()
        check(after == before, "and leaves Gitea as it was")
        os.remove(stopf)
        rc, out, err = imp()
        res = _json.loads(out) if rc == 0 else {}
        check(rc == 0 and res.get("repositories") == ["proj"], f"the import {err.strip()[-500:]}")
        check("fake-secret-token" not in out + err, "the token is not printed")
        check(not os.path.exists(calls), "GIT_FETCH=pascal (the default): no git program ran")
        check([x["query"] for x in fake.git_log if x["method"] == "GET"] == ["service=git-upload-pack"]
              and all("thin-pack" not in x["want"] and "side-band-64k" in x["want"] for x in fake.git_log
                      if x["method"] == "POST"), "git's smart HTTP: info/refs, then upload-pack, side-band-64k, no thin-pack "
              f"{[(x['method'], x['path'], x['query'], x['want'][:120]) for x in fake.git_log]}")
        git_dir0 = os.path.join(g.repo_root, "omigh", "proj.git")
        r = subprocess.run(["git", "-C", git_dir0, "fsck", "--full"], capture_output=True, text=True)
        check(r.returncode == 0, f"git fsck --full of the repository fetched in Pascal {r.stderr[-300:]}")
        check(refs_of(git_dir0) == remote_refs(fake.bare), "its refs are the remote's (git ls-remote)")
        st = res.get("stats", {})
        check(st.get("issues") == 1 and st.get("pull requests") == 1 and st.get("comments") == 1
              and st.get("releases") == 1 and st.get("attachments") == 2 and st.get("tags") == 1,
              f"issues, a pull request, a comment, a release, its file, a body file, a tag {st}")
        git_dir = os.path.join(g.repo_root, "omigh", "proj.git")
        check(os.path.isfile(os.path.join(git_dir, "hooks", "pre-receive.d", "gitea"))
              and os.path.isfile(os.path.join(git_dir, "git-daemon-export-ok")), "the bare repository with Gitea's hooks")
        rc, after, text = g.doctor()
        new = [x for x in after if x not in before]
        check(rc == 0 and not new, f"gitea doctor check --all after the import finds nothing new {new}")
        g.start()
        try:
            s, repo = g.api("GET", "/api/v1/repos/omigh/proj")
            check(s == 200 and repo.get("default_branch") == "main" and repo.get("description") == "A <b>fake</b> repository"
                  and repo.get("original_url", "").endswith("/omigh/proj"), "Gitea serves the repository")
            s, issues = g.api("GET", "/api/v1/repos/omigh/proj/issues?state=all&type=issues")
            i1 = next((i for i in issues if i["number"] == 1), {}) if s == 200 else {}
            check(i1.get("title") == "Fake issue <one>" and [l["name"] for l in i1.get("labels", [])] == ["bug"]
                  and (i1.get("milestone") or {}).get("title") == "v1" and i1.get("user", {}).get("login") == "octocat",
                  "the issue with its label, milestone and GitHub author")
            s, comments = g.api("GET", "/api/v1/repos/omigh/proj/issues/1/comments")
            check(s == 200 and [c["body"] for c in comments] == ["Me too."], "its comment")
            s, assets = g.api("GET", "/api/v1/repos/omigh/proj/issues/1/assets")
            check(s == 200 and len(assets) == 1 and assets[0]["size"] == 550, "the file linked from the issue is its attachment")
            s, pr = g.api("GET", "/api/v1/repos/omigh/proj/pulls/2")
            check(s == 200 and pr.get("merged") and pr["head"]["ref"] == "feature" and pr["base"]["ref"] == "main",
                  f"the merged pull request {s} {pr if s != 200 else (pr.get('merged'), pr['head'].get('ref'), pr['base'].get('ref'))}")
            s, rels = g.api("GET", "/api/v1/repos/omigh/proj/releases")
            rel = next((r for r in rels if r["tag_name"] == "v1.0"), {}) if s == 200 else {}
            check(rel.get("name") == "Version 1.0" and [a["name"] for a in rel.get("assets", [])] == ["app-linux.bin"],
                  "the release with its file")
            if rel.get("assets"):
                req = urllib.request.Request(rel["assets"][0]["browser_download_url"])
                data = urllib.request.urlopen(req, timeout=30).read()
                check(data == fake.files["/api/repos/omigh/proj/releases/assets/901"], "the release file downloads, byte for byte")
            s, tags = g.api("GET", "/api/v1/repos/omigh/proj/tags")
            check(s == 200 and {t["name"] for t in tags} == {"v1.0", "v0.9-light"}, "the tags")
            s, topics = g.api("GET", "/api/v1/repos/omigh/proj/topics")
            check(s == 200 and sorted(topics.get("topics", [])) == ["kanban", "omi-import-test"], "the topics")
            r = subprocess.run(["git", "ls-remote", f"{g.url}/omigh/proj.git"], capture_output=True, text=True)
            check(fake.main_sha in r.stdout and "refs/pull/2/head" in r.stdout, "git serves the branches and refs/pull")
        finally:
            g.stop()
        # --- a second import: only what is new or changed ---
        fake.log.clear()
        fake.issues[0]["title"] = "Fake issue, renamed"
        fake.issues[0]["updated_at"] = "2099-01-01T00:00:00Z"
        fake.issues.append({"id": 1003, "number": 3, "title": "A new issue", "body": "new", "state": "open",
                            "locked": False, "user": fake.user("octocat", 583231), "labels": [], "milestone": None,
                            "created_at": "2099-01-01T00:00:00Z", "updated_at": "2099-01-01T00:00:00Z", "closed_at": None})
        fake.comments.append({"id": 2002, "issue_url": f"{fake.api}/repos/omigh/proj/issues/3", "body": "A new comment",
                              "user": fake.user("hubot", 3), "created_at": "2099-01-01T00:00:00Z",
                              "updated_at": "2099-01-01T00:00:00Z"})
        fake.push_commit("Second commit")
        fake.git_log.clear()
        rc, out, err = imp()
        st = _json.loads(out).get("stats", {}) if rc == 0 else {}
        check(rc == 0 and st.get("issues") == 1 and st.get("issues updated") == 1 and st.get("comments") == 1
              and "attachments" not in st and "releases" not in st, f"the second import brings only the new and changed {st}")
        check(all("since" in q for q in fake.hits("/api/repos/omigh/proj/issues")), "issues are asked with since")
        posts = [x for x in fake.git_log if x["method"] == "POST"]
        check(len(posts) == 1 and b"have " in posts[0]["body"] and posts[0]["body"].count(b"want ") == 1,
              "the second fetch wants only the new commit and says what it has")
        r = subprocess.run(["git", "-C", git_dir0, "fsck", "--full"], capture_output=True, text=True)
        check(r.returncode == 0 and refs_of(git_dir0) == remote_refs(fake.bare),
              f"after the incremental fetch: git fsck --full, and the refs are the remote's {r.stderr[-300:]}")
        r = subprocess.run(["git", "-C", git_dir0, "log", "-1", "--format=%s", "main"], capture_output=True, text=True)
        check(r.stdout.strip() == "Second commit", "git log shows the new commit")
        check(not os.path.exists(calls), "and still no git program ran")
        check(not fake.hits("/api/repos/omigh/proj/releases/assets/901"), "a release file not changed is not downloaded again")
        rc, after2, _ = g.doctor()
        new = [x for x in after2 if x not in before]
        check(rc == 0 and not new, f"gitea doctor check --all after the second import {new}")
        g.start()
        try:
            s, issues = g.api("GET", "/api/v1/repos/omigh/proj/issues?state=all&type=issues")
            titles = sorted(i["title"] for i in issues) if s == 200 else []
            check(titles == ["A new issue", "Fake issue, renamed"], f"Gitea has the new issue and the new title {titles}")
            s, comments = g.api("GET", "/api/v1/repos/omigh/proj/issues/1/comments")
            check(s == 200 and len(comments) == 1, "no comment twice")
            s, commits = g.api("GET", "/api/v1/repos/omigh/proj/commits?sha=main&limit=1")
            check(s == 200 and commits and commits[0]["commit"]["message"].strip() == "Second commit", "the new commit")
        finally:
            g.stop()
        # --- and deleting what was imported ---
        rc, out, err = omigitea("delete", "--config", g.ini, "--owner", "omigh", "--confirm", "omigh")
        rc2, after3, _ = g.doctor()
        new = [x for x in after3 if x not in before]
        check(rc == 0 and rc2 == 0 and not new, f"deleting the imported organization; doctor finds nothing new {new}")
        # --- GIT_FETCH=program: the git program, only for the fetch ---
        rc, out, err = imp("--git-fetch", "program")
        rc2, after4, _ = g.doctor()
        new = [x for x in after4 if x not in before]
        ran = open(calls).read().split("\n") if os.path.isfile(calls) else []
        check(rc == 0 and rc2 == 0 and not new, f"an import with GIT_FETCH=program; doctor finds nothing new {new} {err[-300:]}")
        check([l.split()[0] for l in ran if l] == ["clone"], f"the git program ran once, to clone {ran}")
        check(refs_of(git_dir0) == remote_refs(fake.bare) and "[remote" not in open(os.path.join(git_dir0, "config")).read(),
              "the refs are the remote's and the remote was removed")
        rc, out, err = omigitea("delete", "--config", g.ini, "--owner", "omigh", "--confirm", "omigh")
        check(rc == 0, "and it is deleted again")
        exf = os.path.join(work, "import-exclude.txt")
        with open(exf, "w") as f:
            f.write("# no longer synced\nomigh/proj\n")
        rc, out, err = imp("--exclude-file", exf)
        st = _json.loads(out).get("stats", {}) if rc == 0 else {}
        c = sqlite3.connect(g.db)
        n = c.execute("SELECT COUNT(*) FROM repository WHERE lower(owner_name) = 'omigh'").fetchone()[0]
        c.close()
        check(rc == 0 and st.get("left out") == 1 and n == 0, f"an excluded repository is left out of the import {st}")
        m = sqlite3.connect(os.path.join(g.work, "data", "omi", "github-map.db"))
        check(m.execute("SELECT COUNT(*) FROM item_map").fetchone()[0] == 0
              and m.execute("SELECT COUNT(*) FROM repo_map").fetchone()[0] == 0, "and its GitHub mapping")
        m.close()
    finally:
        g.stop()
        fake.close()


def test_translations():
    """The Gitea folder keys are in every language file of Omi, copied from the two
    sources only: WeKan's catalogs (imports/i18n/data) and, for Gitea's own terms,
    gitea-patches' gitea-locale."""
    import json as _json
    i18n = os.path.join(REPO, "public", "i18n")
    en = _json.load(open(os.path.join(i18n, "en.i18n.json"), encoding="utf-8"))
    used = set(re.findall(r"Tx?E?\('((?:gitea|avatars|stats-count|database-migration|reason|billing-total|vcs-wiki|list-sync-menu|list-sync-source-none)[a-z-]*)'",
                          open(os.path.join(REPO, "public", "server.pas"), encoding="utf-8").read()))
    check(used and all(k in en for k in used), f"every key the Gitea pages use is in en.i18n.json {sorted(k for k in used if k not in en)}")
    wekan = os.path.join(os.path.dirname(TOOLS), "imports", "i18n", "data")
    missing, differ = [], []
    for name in sorted(os.listdir(i18n)):
        d = _json.load(open(os.path.join(i18n, name), encoding="utf-8"))
        missing += [f"{name}:{k}" for k in used if not d.get(k)]
        wpath = os.path.join(wekan, name)
        if os.path.isfile(wpath):
            w = _json.load(open(wpath, encoding="utf-8"))
            differ += [f"{name}:{k}" for k in used if k.startswith("gitea") and k in w and w[k] != d.get(k)]
    check(not missing, f"every language file has the Gitea folder keys {missing[:5]}")
    if os.path.isdir(wekan):
        check(not differ, f"the Gitea folder keys are WeKan's translations, copied {differ[:5]}")


MIRROR = os.environ.get("OMI_GITHUB_TO_GITEA_DIR") or os.path.join(TOOLS, "w", "gitea-patches", "mirror")


def test_delete_repo_fixture(work):
    """Deleting one repository of the fixture, and the sync exclude file."""
    import json as _json
    g = os.path.join(work, "grepo")
    ids = fx.make(g)
    ini = os.path.join(g, "custom", "conf", "app.ini")
    data = os.path.join(g, "data")
    ex = os.path.join(work, "github-to-gitea.exclude.txt")
    index = os.path.join(work, "grepo-index.txt")
    subprocess.run([SERVER, "gitea", "index", "--config", ini, "--index", index], check=True, capture_output=True)
    common = ["--config", ini, "--mirror-dir", MIRROR, "--exclude-file", ex]
    S = fx.SIZES
    rc, out, err = omigitea("delete-repo", *common, "--owner", "acme", "--repo", "big", "--dry-run", "--json")
    plan = _json.loads(out) if rc == 0 else {}
    check(plan.get("bytes_by_kind") == {"git": S["acme/big.git"], "wiki": S["acme/big.wiki.git"],
                                        "attachment": S["att_big"] + S["att_rel"]},
          f"repository dry run: git, wiki, attachments; the LFS object acme/small also has is kept {plan.get('bytes_by_kind')}")
    check(plan.get("tables", {}).get("repository") == 1 and "user" not in plan.get("tables", {})
          and plan.get("excluded") is False, "only the repository's rows, not the owner's")
    dbp = os.path.join(data, "gitea.db")

    def count(sql):
        c = sqlite3.connect(dbp)
        try:
            return c.execute(sql).fetchone()[0]
        finally:
            c.close()

    for confirm, what in ((None, "without the typed name"), ("big", "with only the name"), ("acme/BIG", "in another case"),
                          ("acme", "with the owner's name")):
        args = ["delete-repo", *common, "--owner", "acme", "--repo", "big"] + (["--confirm", confirm] if confirm else [])
        rc, out, err = omigitea(*args)
        check(rc != 0 and count("SELECT COUNT(*) FROM repository") == 3, f"a repository delete {what} is refused")
    for owner, repo in (("acme", "../big"), ("..", "big"), ("acme", "big/../../x"), ("acme", ".git"), ("acme", "-x")):
        rc, out, err = omigitea("delete-repo", *common, "--owner=" + owner, "--repo=" + repo, f"--confirm={owner}/{repo}")
        check(rc != 0 and "not a Gitea" in err, f"{owner}/{repo} is refused as a name")
    s_ = socket.socket()
    s_.bind(("127.0.0.1", 0))
    s_.listen(1)
    text = open(ini).read()
    open(ini, "w").write(text.replace("HTTP_PORT = 1\n", f"HTTP_PORT = {s_.getsockname()[1]}\n"))
    rc, out, err = omigitea("delete-repo", *common, "--owner", "acme", "--repo", "big", "--confirm", "acme/big")
    check(rc != 0 and "Gitea is running" in err and count("SELECT COUNT(*) FROM repository") == 3,
          "a repository delete while Gitea runs is refused")
    s_.close()
    open(ini, "w").write(text)
    rc, out, err = omigitea("delete-repo", *common, "--owner", "acme", "--repo", "big", "--confirm", "acme/big",
                            "--exclude-from-sync", "--by", "tester", "--index", index, "--json")
    res = _json.loads(out) if rc == 0 else {}
    check(rc == 0 and res.get("excluded") is True, f"the repository delete {err.strip()[-300:]}")
    check(not os.path.exists(os.path.join(data, "gitea-repositories", "acme", "big.git"))
          and not os.path.exists(os.path.join(data, "gitea-repositories", "acme", "big.wiki.git"))
          and os.path.exists(os.path.join(data, "gitea-repositories", "acme", "small.git"))
          and os.path.exists(os.path.join(data, "lfs", fx.OID_SHARED[:2], fx.OID_SHARED[2:4], fx.OID_SHARED[4:]))
          and not os.path.exists(os.path.join(data, "attachments", fx.ATT_BIG[0], fx.ATT_BIG[1], fx.ATT_BIG)),
          "its git, wiki and attachments are gone; the other repository and the shared LFS object stay")
    check(count(f"SELECT COUNT(*) FROM repository WHERE id = {ids['big']}") == 0
          and count(f"SELECT COUNT(*) FROM issue WHERE repo_id = {ids['big']}") == 0
          and count(f"SELECT COUNT(*) FROM user WHERE id = {ids['acme']}") == 1
          and count(f"SELECT num_repos FROM user WHERE id = {ids['acme']}") == 1,
          "its rows are gone; the owner stays, with num_repos recounted")
    rec = open(os.path.join(data, "omi", "deleted-repos.tsv")).read().split("\t")
    check(rec[0] == "acme/big" and int(rec[2]) == plan["bytes"] and rec[3] == "tester" and rec[4].strip() == "repository",
          "the deletion is recorded: owner/name, time, bytes freed, who")
    idx = open(index).read()
    check("#stale\t" in idx and "big.git" not in idx and fx.ATT_BIG not in idx and "small.git" in idx,
          "the size index loses the deleted lines and is marked stale")
    check(open(ex).read().splitlines()[-1] == "acme/big", "and it is excluded from sync")
    # Names an Amiga file system cannot hold are refused before anything is asked or written.
    long = "a" * 108
    rc, out, err = omigitea("import", "--config", ini, "--owner", long, "--github-api", "http://127.0.0.1:1")
    check(rc != 0 and "longer than 107" in err, "an owner name over 107 characters is refused")
    os.makedirs(os.path.join(data, "gitea-repositories", "OmiX"))
    rc, out, err = omigitea("import", "--config", ini, "--owner", "omix", "--github-api", "http://127.0.0.1:1")
    check(rc != 0 and "differs only in case" in err, "a name that differs from a folder only in case is refused")
    os.rmdir(os.path.join(data, "gitea-repositories", "OmiX"))
    # The exclude file, shared with github-to-gitea.
    with open(ex, "a") as f:
        f.write("# a comment stays\nwekan/a, wekan/b   # two on a line\n")
    rc, out, err = omigitea("exclude", *common, "--json")
    check(rc == 0 and _json.loads(out)["excluded"] == ["acme/big", "wekan/a", "wekan/b"],
          "the exclude file is read with github-to-gitea's rules")
    for bad in ("acme", "a/b/c", "../x", "acme/..", "a/.b", "a b/c", ""):
        rc, out, err = omigitea("exclude", *common, "--add=" + bad)
        check(rc != 0 and "not an owner/name" in err, f"exclude of a malformed name {bad!r} is refused")
    rc, out, err = omigitea("exclude", *common, "--remove", "wekan/A", "--json")
    lines = open(ex).read().splitlines()
    check(rc == 0 and _json.loads(out)["excluded"] == ["acme/big", "wekan/b"] and "# a comment stays" in lines,
          "include again removes it (in any case), comments stay")
    sys.path.insert(0, os.path.join(MIRROR, "common"))
    import gitea_attachments as ga
    check(ga.parse_exclude_file(open(ex).read()) == ["acme/big", "wekan/b"], "github-to-gitea reads the same list")


def test_delete_repo_live(work):
    """One repository of an organization, deleted from a copy of the test Gitea:
    doctor finds nothing new, the other repository stays."""
    if not gitea_live.available():
        return
    g = gitea_live.GiteaCopy(os.path.join(work, "live-delete-repo"))
    g.start()
    try:
        g.api("POST", "/api/v1/orgs", {"username": "omirepo", "visibility": "public"})
        s1, _ = g.api("POST", "/api/v1/orgs/omirepo/repos", {"name": "big", "auto_init": True})
        s2, _ = g.api("POST", "/api/v1/orgs/omirepo/repos", {"name": "keep", "auto_init": True})
        g.api("POST", "/api/v1/repos/omirepo/big/issues", {"title": "x", "body": "y"})
        s3, att = g.upload("/api/v1/repos/omirepo/big/issues/1/assets", "attachment", "a.txt", b"attachment text " * 100)
        s4, rel = g.api("POST", "/api/v1/repos/omirepo/big/releases", {"tag_name": "v1", "name": "v1"})
        g.api("PUT", "/api/v1/repos/omirepo/big/topics", {"topics": ["omi-repo-delete"]})
        g.api("PUT", "/api/v1/user/starred/omirepo/big")
        check([s1, s2, s3, s4] == [201] * 4, f"made omirepo/big and omirepo/keep through the API {[s1, s2, s3, s4]}")
        rc, out, err = omigitea("delete-repo", "--config", g.ini, "--owner", "omirepo", "--repo", "big",
                                "--confirm", "omirepo/big", "--mirror-dir", MIRROR)
        check(rc != 0 and "Gitea is running" in err, "refused while Gitea runs")
    finally:
        g.stop()
    rc, before, _ = g.doctor()
    rc, out, err = omigitea("delete-repo", "--config", g.ini, "--owner", "omirepo", "--repo", "big",
                            "--confirm", "omirepo/big", "--mirror-dir", MIRROR)
    check(rc == 0, f"the repository delete with Gitea stopped {err.strip()[-300:]}")
    rc, after, text = g.doctor()
    new = [x for x in after if x not in before]
    check(rc == 0 and not new, f"gitea doctor check --all after the repository delete finds nothing new {new}")
    g.start()
    try:
        check(g.api("GET", "/api/v1/repos/omirepo/big")[0] == 404 and g.api("GET", "/api/v1/repos/omirepo/keep")[0] == 200
              and g.api("GET", "/api/v1/orgs/omirepo")[0] == 200, "Gitea: the repository is gone, the other and the owner stay")
        s, _ = g.api("POST", "/api/v1/orgs/omirepo/repos", {"name": "big", "auto_init": True})
        check(s == 201, "and the name can be used again")
    finally:
        g.stop()


def main():
    tmp_root = os.environ.get("TMPDIR") or tempfile.gettempdir()
    if os.environ.get("OMI_SKIP_BUILD") != "1":
        subprocess.run(["./freepascalserver.sh"], cwd=REPO, env=dict(os.environ, OMI_BUILD_ONLY="1"), check=True)
    work = tempfile.mkdtemp(prefix="omi-gitea-test.", dir=tmp_root)
    try:
        test_translations()
        test_token_cli(os.path.join(work, "token"))
        test_file_layout(os.path.join(work, "layout"))
        test_paths(os.path.join(work, "ini"))
        test_git_setting(os.path.join(work, "git-setting"))
        g = os.path.join(work, "gitea")
        ids = fx.make(g)
        for source in ("disk", "tree", "tree-F"):
            test_sizes(g, source)
        test_web(g, ids)
        test_real(work)
        test_no_python_or_gitea_at_runtime()
        test_portable_source()
        test_delete_coverage()
        test_delete_fixture(work)
        test_delete_live(work)
        test_pascal_git(os.path.join(work, "pascal-git"))
        test_import_live(work)
        test_delete_repo_fixture(work)
        test_delete_repo_live(work)
    finally:
        if FAILURES or os.environ.get("OMI_KEEP_TEST_DIR") == "1":
            print(f"test directory kept: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)
    print(f"===== gitea test: {PASSES} passed, {len(FAILURES)} failed")
    for f in FAILURES:
        print(f"  FAIL {f}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
