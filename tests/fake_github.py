"""A fake GitHub for Omi's import tests: one local HTTP server for the API (under
/api) and github.com (file links, avatars), and local bare git repositories,
served under /git by `git http-backend` (git's smart HTTP protocol, as
github.com serves it). No network. Its answers are plain dicts the test can
change between two imports, and it logs every request (path, query, whether a
token came)."""
import http.server
import json
import os
import subprocess
import threading
import urllib.parse

import git_http

ID = ["-c", "user.name=U", "-c", "user.email=u@example.org"]
PNG = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
       b"\x00\x00\x00\rIDATx\x9cc\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99=\x1d\x00\x00\x00\x00IEND\xaeB`\x82")


def git(*args, cwd=None):
    return subprocess.run(["git", *ID, *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class FakeGitHub:
    def __init__(self, work, org="omigh", repo="proj"):
        self.work, self.org, self.repo_name = work, org, repo
        self.git_root = os.path.join(work, "git")
        self.log = []
        self.git_log = []
        self.files = {}  # path -> bytes
        # Rate limits, as GitHub answers them: path -> how many more times it
        # is a secondary limit (403, its message and Retry-After, no
        # X-RateLimit-Remaining: 0); low_remaining puts every answer near the
        # end of the hour's requests.
        self.secondary_limit = {}
        self.low_remaining = False
        # Paths answered 404, as GitHub answers a repository it does not show.
        self.not_found = set()
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                u = urllib.parse.urlsplit(self.path)
                if u.path.startswith("/git/"):
                    git_http.run_backend(self, outer.git_root, urllib.parse.unquote(u.path[4:]), u.query, outer.git_log)
                else:
                    self.send_response(405)
                    self.send_header("Content-Length", "0")
                    self.end_headers()

            def do_GET(self):
                u = urllib.parse.urlsplit(self.path)
                if u.path.startswith("/git/"):
                    git_http.run_backend(self, outer.git_root, urllib.parse.unquote(u.path[4:]), u.query, outer.git_log)
                    return
                q = dict(urllib.parse.parse_qsl(u.query))
                outer.log.append((u.path, q, self.headers.get("Authorization") is not None))
                if outer.secondary_limit.get(u.path, 0) > 0:
                    outer.secondary_limit[u.path] -= 1
                    body = b'{"message": "You have exceeded a secondary rate limit. Please wait a few minutes."}'
                    self.send_response(403)
                    self.send_header("Retry-After", "1")
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                status, ctype, body = outer.answer(u.path, q)
                self.send_response(status)
                if outer.low_remaining and u.path.startswith("/api/"):
                    self.send_header("X-RateLimit-Remaining", "12")
                    self.send_header("X-RateLimit-Limit", "60")
                    self.send_header("X-RateLimit-Reset", str(int(__import__("time").time()) + 1800))
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.api = self.base + "/api"
        # Where git fetches from: github.com/<owner>/<repo>.git.
        self.git_url = self.base + "/git"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.make_git()
        self.make_data()

    def close(self):
        self.httpd.shutdown()

    # --- git ---
    def make_git(self):
        src = os.path.join(self.work, "src")
        os.makedirs(src)
        git("init", "-q", "-b", "main", cwd=src)
        open(os.path.join(src, "README.md"), "w").write("# proj\n")
        git("add", ".", cwd=src)
        git("commit", "-q", "-m", "First commit", cwd=src)
        git("tag", "-a", "v1.0", "-m", "Version 1.0", cwd=src)
        git("checkout", "-q", "-b", "feature", cwd=src)
        open(os.path.join(src, "feature.txt"), "w").write("feature\n")
        git("add", ".", cwd=src)
        git("commit", "-q", "-m", "A feature", cwd=src)
        self.feature_sha = git("rev-parse", "HEAD", cwd=src)
        git("checkout", "-q", "main", cwd=src)
        git("merge", "-q", "--no-ff", "-m", "Merge feature", "feature", cwd=src)
        git("tag", "v0.9-light", "HEAD~1", cwd=src)  # a tag without a release
        self.main_sha = git("rev-parse", "HEAD", cwd=src)
        self.base_sha = git("rev-parse", "HEAD~1", cwd=src)
        bare = os.path.join(self.git_root, self.org, self.repo_name + ".git")
        os.makedirs(os.path.dirname(bare))
        subprocess.run(["git", "clone", "-q", "--bare", src, bare], check=True, capture_output=True)
        # GitHub keeps every pull request's head at refs/pull/<n>/head.
        git("update-ref", "refs/pull/2/head", self.feature_sha, cwd=bare)
        self.src, self.bare = src, bare

    def push_commit(self, message):
        open(os.path.join(self.src, "more.txt"), "a").write(message + "\n")
        git("add", ".", cwd=self.src)
        git("commit", "-q", "-m", message, cwd=self.src)
        git("push", "-q", self.bare, "main", cwd=self.src)

    # --- the API's data ---
    def user(self, login, uid):
        return {"login": login, "id": uid, "type": "User"}

    def make_data(self):
        o, r = self.org, self.repo_name
        full = f"{o}/{r}"
        self.att1 = f"{self.base}/user-attachments/assets/0f1e2d3c-1111-2222-3333-444455556666"
        self.files["/user-attachments/assets/0f1e2d3c-1111-2222-3333-444455556666"] = b"screenshot " * 50
        self.files["/api/repos/omigh/proj/releases/assets/901"] = b"\x7fELF binary " * 300
        self.files["/avatars/omigh"] = PNG
        self.owner = {"login": o, "id": 5000, "type": "Organization", "avatar_url": f"{self.base}/avatars/omigh",
                      "name": "Omi GH", "description": "An organization from the fake GitHub"}
        self.repo = {"id": 7000, "name": r, "full_name": full, "private": False, "html_url": f"{self.base}/{full}",
                     "description": "A <b>fake</b> repository", "homepage": "", "default_branch": "main",
                     "has_wiki": False, "archived": False, "topics": ["omi-import-test", "kanban"],
                     "created_at": "2026-01-01T00:00:00Z", "pushed_at": "2026-01-03T00:00:00Z",
                     "owner": {"login": o}}
        self.labels = [{"id": 801, "name": "bug", "color": "d73a4a", "description": "Something is wrong"},
                       {"id": 802, "name": "feature", "color": "a2eeef", "description": ""}]
        self.milestones = [{"id": 851, "title": "v1", "description": "First", "state": "open",
                            "due_on": "2026-06-01T00:00:00Z", "created_at": "2026-01-01T00:00:00Z",
                            "updated_at": "2026-01-01T00:00:00Z", "closed_at": None}]
        self.issues = [
            {"id": 1001, "number": 1, "title": "Fake issue <one>",
             "body": f"It breaks.\n\n![shot]({self.att1})\n", "state": "open", "locked": False,
             "user": self.user("octocat", 583231), "labels": [{"name": "bug"}], "milestone": {"id": 851},
             "created_at": "2026-01-02T00:00:00Z", "updated_at": "2026-01-02T00:00:00Z", "closed_at": None},
            {"id": 1002, "number": 2, "title": "Add a feature", "body": "Adds feature.txt", "state": "closed",
             "locked": False, "user": self.user("hubot", 3), "labels": [{"name": "feature"}], "milestone": None,
             "created_at": "2026-01-02T01:00:00Z", "updated_at": "2026-01-02T02:00:00Z",
             "closed_at": "2026-01-02T02:00:00Z", "pull_request": {"url": f"{self.api}/repos/{full}/pulls/2"}},
        ]
        self.pulls = {2: {"number": 2, "draft": False, "merged": True, "merged_at": "2026-01-02T02:00:00Z",
                          "merge_commit_sha": self.main_sha,
                          "head": {"ref": "feature", "sha": self.feature_sha, "repo": {"full_name": full}},
                          "base": {"ref": "main", "sha": self.base_sha}}}
        self.comments = [{"id": 2001, "issue_url": f"{self.api}/repos/{full}/issues/1", "body": "Me too.",
                          "user": self.user("hubot", 3), "created_at": "2026-01-02T03:00:00Z",
                          "updated_at": "2026-01-02T03:00:00Z"}]
        self.releases = [{"id": 951, "tag_name": "v1.0", "name": "Version 1.0", "body": "The first release",
                          "draft": False, "prerelease": False, "target_commitish": "main",
                          "created_at": "2026-01-02T04:00:00Z", "published_at": "2026-01-02T04:00:00Z",
                          "updated_at": "2026-01-02T04:00:00Z", "author": self.user("octocat", 583231),
                          "assets": [{"id": 901, "name": "app-linux.bin", "size": 3900, "download_count": 7,
                                      "created_at": "2026-01-02T04:00:00Z", "updated_at": "2026-01-02T04:00:00Z",
                                      "url": f"{self.api}/repos/{full}/releases/assets/901",
                                      "browser_download_url": f"{self.base}/{full}/releases/download/v1.0/app-linux.bin"}]}]

    def since(self, items, q):
        s = q.get("since")
        return [x for x in items if not s or x["updated_at"] >= s]

    def answer(self, path, q):
        full = f"{self.org}/{self.repo_name}"
        if path in self.not_found:
            return 404, "application/json", b'{"message": "Not Found"}'
        if path in self.files:
            return 200, "application/octet-stream", self.files[path]
        if int(q.get("page", "1")) > 1:
            return 200, "application/json", b"[]"
        data = {
            f"/api/users/{self.org}": self.owner,
            f"/api/orgs/{self.org}": self.owner,
            f"/api/orgs/{self.org}/repos": [self.repo],
            f"/api/repos/{full}/labels": self.labels,
            f"/api/repos/{full}/milestones": self.milestones,
            f"/api/repos/{full}/issues": self.since(self.issues, q),
            f"/api/repos/{full}/issues/comments": self.since(self.comments, q),
            f"/api/repos/{full}/releases": self.releases,
            # The list of pull requests, as GET /repos/{full}/pulls?state=all.
            f"/api/repos/{full}/pulls": list(self.pulls.values()),
        }.get(path)
        if data is None and path.startswith(f"/api/repos/{full}/pulls/"):
            data = self.pulls.get(int(path.rsplit("/", 1)[1]))
        if data is None:
            return 404, "application/json", b'{"message": "Not Found"}'
        return 200, "application/json", json.dumps(data).encode()

    def hits(self, path):
        return [q for p, q, _ in self.log if p == path]
