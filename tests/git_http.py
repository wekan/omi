"""git's smart HTTP protocol for Omi's tests: `git http-backend` run as a CGI
program by a small web server of the test (Python is the test's, never Omi's
runtime). Every request is logged with the service it asked for and the
capabilities of its first want line, so a test can check what Omi asked."""
import http.server
import os
import subprocess
import threading
import urllib.parse


def run_backend(handler, root, path_info, query, log=None):
    """Answers handler's request (GET or POST) with git http-backend for the
    repositories under root."""
    length = int(handler.headers.get("Content-Length") or 0)
    body = handler.rfile.read(length) if length else b""
    if log is not None:
        first = b""
        if body:
            first = body[4:int(body[:4], 16)] if body[:4] not in (b"0000",) else b""
        log.append({"method": handler.command, "path": path_info, "query": query,
                    "want": first.decode("utf-8", "replace"), "body": body,
                    "auth": handler.headers.get("Authorization")})
    env = {
        "PATH": os.environ.get("PATH", ""),
        "GIT_PROJECT_ROOT": root,
        "GIT_HTTP_EXPORT_ALL": "1",
        "REQUEST_METHOD": handler.command,
        "PATH_INFO": path_info,
        "QUERY_STRING": query,
        "CONTENT_TYPE": handler.headers.get("Content-Type", ""),
        "CONTENT_LENGTH": str(len(body)),
        "REMOTE_ADDR": "127.0.0.1",
        "GIT_CONFIG_NOSYSTEM": "1",
        "HOME": root,
    }
    r = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True)
    head, _, data = r.stdout.partition(b"\r\n\r\n")
    if not _:
        head, _, data = r.stdout.partition(b"\n\n")
    status, headers = 200, []
    for line in head.decode("latin-1").splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        if k.lower() == "status":
            status = int(v.strip().split()[0])
        else:
            headers.append((k.strip(), v.strip()))
    handler.send_response(status)
    for k, v in headers:
        handler.send_header(k, v)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


class GitHttp:
    """A web server for the bare repositories under root: <url>/<path>.git."""

    def __init__(self, root):
        self.root = root
        self.log = []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def handle_one(self):
                u = urllib.parse.urlsplit(self.path)
                run_backend(self, outer.root, urllib.parse.unquote(u.path), u.query, outer.log)

            do_GET = handle_one
            do_POST = handle_one

            def log_message(self, *a):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
