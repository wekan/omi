"""A disposable copy of the test Gitea for Omi's write tests: its work directory
copied to a scratch directory, app.ini pointed there and at a free port, started
and stopped, asked through its API and checked with `gitea doctor check --all`.

The original test Gitea (.tools/tmp/gitea-backup-test, port 3399) is only copied,
never written. Its API token is read from its `token` file and never printed.
"""
import json
import os
import re
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
SOURCE = os.environ.get("OMI_TEST_GITEA_DIR") or os.path.join(TOOLS, "tmp", "gitea-backup-test")
BINARY = os.environ.get("OMI_TEST_GITEA_BINARY") or os.path.join(TOOLS, "w", "gitea", "gitea")


def available():
    return (os.path.isfile(os.path.join(SOURCE, "custom", "conf", "app.ini")) and os.path.isfile(BINARY)
            and os.path.isfile(os.path.join(SOURCE, "token")))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class GiteaCopy:
    def __init__(self, work):
        self.work = work
        self.port = free_port()
        self.proc = None
        self.log = os.path.join(work, "web.log")
        shutil.copytree(os.path.join(SOURCE, "custom"), os.path.join(work, "custom"))
        shutil.copytree(os.path.join(SOURCE, "data"), os.path.join(work, "data"), symlinks=True)
        self.ini = os.path.join(work, "custom", "conf", "app.ini")
        text = open(self.ini).read().replace(SOURCE, work)
        text = re.sub(r"(?m)^HTTP_PORT\s*=.*$", f"HTTP_PORT = {self.port}", text)
        text = re.sub(r"(?m)^ROOT_URL\s*=.*$", f"ROOT_URL = http://127.0.0.1:{self.port}/", text)
        with open(self.ini, "w") as f:
            f.write(text)
        with open(os.path.join(SOURCE, "token")) as f:
            self._token = f.read().strip()
        self.url = f"http://127.0.0.1:{self.port}"
        self.db = os.path.join(work, "data", "gitea.db")
        self.repo_root = os.path.join(work, "data", "repos")

    def env(self):
        return dict(os.environ, GITEA_WORK_DIR=self.work, HOME=os.path.join(self.work, "data", "home"))

    def start(self):
        out = open(self.log, "a")
        self.proc = subprocess.Popen([BINARY, "--config", self.ini, "web"], cwd=self.work, env=self.env(),
                                     stdout=out, stderr=subprocess.STDOUT)
        for _ in range(300):
            try:
                s, _ = self.api("GET", "/api/v1/version")
                if s == 200:
                    return
            except OSError:
                pass
            if self.proc.poll() is not None:
                raise RuntimeError("Gitea did not start: " + open(self.log).read()[-2000:])
            time.sleep(0.2)
        raise RuntimeError("Gitea did not answer")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc = None
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.2).close()
                time.sleep(0.1)
            except OSError:
                return

    def api(self, method, path, data=None, raw=None, content_type=None):
        headers = {"Authorization": f"token {self._token}", "Accept": "application/json"}
        body = None
        if data is not None:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
        elif raw is not None:
            body = raw
            headers["Content-Type"] = content_type
        req = urllib.request.Request(self.url + path, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                text = r.read()
                return r.status, (json.loads(text) if text.strip() and text.strip()[:1] in b"[{" else text)
        except urllib.error.HTTPError as e:
            text = e.read()
            try:
                return e.code, json.loads(text)
            except ValueError:
                return e.code, text

    def upload(self, path, field, name, content):
        boundary = uuid.uuid4().hex
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{name}\"\r\n"
                f"Content-Type: application/octet-stream\r\n\r\n").encode() + content + f"\r\n--{boundary}--\r\n".encode()
        return self.api("POST", path, raw=body, content_type=f"multipart/form-data; boundary={boundary}")

    def doctor(self):
        r = subprocess.run([BINARY, "--config", self.ini, "doctor", "check", "--all"], cwd=self.work, env=self.env(),
                           capture_output=True, text=True, timeout=600)
        text = r.stdout + r.stderr
        problems = sorted(set(re.sub(r"\d+", "N", l.strip()) for l in text.splitlines()
                              if l.strip().startswith(("- [W]", "- [E]", "- [C]"))))
        return r.returncode, problems, text
