#!/usr/bin/env python3
"""Omi's server built for AmigaOS 3 (m68k) by releases/amiga/build.sh, run in
vamos (amitools' AmigaOS emulator of a 68040, its dos.library on this disk),
and compared with the Linux build doing the same thing:

  - `gitea git`: no git program, the fetch in Pascal;
  - `gitea git-index-pack`: a REF_DELTA pack indexed by m68k Pascal, its .idx
    byte for byte as git index-pack writes it;
  - `gitea git-refs`: refs (packed and loose), tags peeled, commit times,
    subjects and counts, as the Linux build reads them;
  - `gitea paths` and `gitea owners`: Amiga paths ("work:g/data", never
    "work:/"), the embedded SQLite for the 68020 reading the fixture's Gitea
    database, the same sizes;
  - `gitea delete-owner`: the lock, one transaction, the files - the database
    and the folder exactly as the Linux build leaves them.

  python3 -I tests/amiga_test.py      (OMI_AMIGA_BUILD=0: use build/amiga/omi68k)

Skipped when the cross toolchain or vamos is not there (OMI_AMIGA_CROSS, as
releases/amiga/build.sh). vamos has no TCP/IP stack (bsdsocket.library) and
runs one task: the web server and the fetch over HTTP are not run here.
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
TOOLS = os.path.dirname(os.path.dirname(REPO))
sys.path.insert(0, HERE)
import make_gitea_fixture as fx  # noqa: E402

CROSS = os.environ.get("OMI_AMIGA_CROSS") or os.path.join(TOOLS, "tmp", "welite-amiga-cross")
AMITOOLS = os.path.join(CROSS, "amitools")
BINARY = os.path.join(REPO, "build", "amiga", "omi68k")
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


def vamos(vol, *args):
    """omi68k with args in vamos: the work: volume is vol, the current
    directory work:run (so that a "/..." path of libnix is not the parent of
    the volume, which vamos cannot take)."""
    os.makedirs(os.path.join(vol, "run"), exist_ok=True)
    shutil.copy(BINARY, os.path.join(vol, "omi68k"))
    r = subprocess.run([sys.executable, "-c", "import sys; from amitools.tools.vamos import main; sys.exit(main())",
                        "-C", "68040", "-H", "disable", "-m", "65536", "-s", "512", "-V", f"work:{vol}",
                        "--cwd", "work:run", "--", "work:omi68k", *args],
                       capture_output=True, text=True, timeout=1800,
                       env=dict(os.environ, PYTHONPATH=AMITOOLS))
    return r.returncode, r.stdout, r.stderr


def dump(db):
    c = sqlite3.connect(db)
    try:
        return list(c.iterdump())
    finally:
        c.close()


def tree(d):
    return sorted(os.path.relpath(os.path.join(a, x), d) for a, ds, fs in os.walk(d) for x in ds + fs)


def main():
    if not os.path.isdir(os.path.join(AMITOOLS, "amitools")) or not os.path.isfile(
            os.path.join(CROSS, "install", "lib", "fpc", "3.2.3", "ppcross68k")):
        print(f"skip: no m68k-amiga cross toolchain or vamos under {CROSS}")
        return 0
    if os.environ.get("OMI_AMIGA_BUILD") != "0":
        subprocess.run([os.path.join(REPO, "releases", "amiga", "build.sh")], check=True)
    if os.environ.get("OMI_SKIP_BUILD") != "1":
        subprocess.run(["./build.sh", "build"], cwd=REPO, check=True)
    r = subprocess.run(["file", BINARY], capture_output=True, text=True)
    check("AmigaOS" in r.stdout, f"build/amiga/omi68k is an AmigaOS executable {r.stdout.strip()}")
    work = tempfile.mkdtemp(prefix="omi-amiga-test.", dir=os.environ.get("TMPDIR") or tempfile.gettempdir())
    try:
        vol = os.path.join(work, "vol")
        os.makedirs(vol)
        rc, out, err = vamos(vol, "gitea", "git")
        check(rc == 0 and "fetch: pascal" in out, f"it runs: gitea git, the fetch in Pascal {out.strip()} {err[-300:]}")

        # A REF_DELTA pack (git pack-objects without --delta-base-offset).
        src = os.path.join(work, "src")
        idg = ["-c", "user.name=U", "-c", "user.email=u@example.org"]
        subprocess.run(["git", "init", "-q", "-b", "main", src], check=True)
        lines = [f"line {i}" for i in range(6000)]
        for i in range(10):
            lines[i * 500] = f"changed {i}"
            open(os.path.join(src, "f.txt"), "w").write("\n".join(lines) + "\n")
            subprocess.run(["git", *idg, "add", "."], cwd=src, check=True)
            subprocess.run(["git", *idg, "commit", "-q", "-m", f"Commit {i}"], cwd=src, check=True)
        subprocess.run(["git", *idg, "tag", "-a", "v1", "-m", "Version 1", "HEAD~2"], cwd=src, check=True)
        objs = subprocess.run(["git", "rev-list", "--objects", "--all"], cwd=src, capture_output=True, text=True).stdout
        name = subprocess.run(["git", "pack-objects", "-q", "--window=250", "--depth=50", os.path.join(work, "p")],
                              input=objs, cwd=src, capture_output=True, text=True, check=True).stdout.strip()
        shutil.copy(os.path.join(work, f"p-{name}.pack"), os.path.join(vol, "in.pack"))
        rc, out, err = vamos(vol, "gitea", "git-index-pack", "work:in.pack")
        idx = os.path.join(vol, f"pack-{name}.idx")
        check(rc == 0 and os.path.isfile(idx) and open(idx, "rb").read() ==
              open(os.path.join(work, f"p-{name}.idx"), "rb").read(),
              f"m68k: a REF_DELTA pack's .idx byte for byte as git index-pack {out[-200:]} {err[-200:]}")

        # Refs, packed and loose, read on the 68040 and on Linux.
        bare = os.path.join(vol, "r.git")
        subprocess.run(["git", "clone", "-q", "--bare", src, bare], check=True)
        subprocess.run(["git", "-C", bare, "repack", "-adfq", "--depth=50", "--window=250"], check=True)
        subprocess.run(["git", *idg, "-C", bare, "tag", "-a", "loose", "-m", "a loose tag", "HEAD~5"], check=True)
        rc, out, err = vamos(vol, "gitea", "git-refs", "work:r.git")
        lin = subprocess.run([SERVER, "gitea", "git-refs", bare], capture_output=True, text=True).stdout
        check(rc == 0 and out == lin and len(json.loads(lin)["refs"]) == 3,
              f"m68k: every ref, peeled commit, time, subject and count as the Linux build {err[-200:]}")

        # The Gitea fixture: paths, SQLite, sizes; then a delete.
        g = os.path.join(vol, "g")
        fx.make(g)
        rc, out, err = vamos(vol, "gitea", "paths", "--config", "work:g/custom/conf/app.ini")
        p = dict(l.split("\t", 1) for l in out.splitlines() if "\t" in l)
        check(rc == 0 and p.get("APP_DATA_PATH") == "work:g/data" and p.get("database") == "sqlite3 work:g/data/gitea.db"
              and "work:/" not in out, f"Amiga paths: work:g/data, never work:/ {p}")
        rc, out, err = vamos(vol, "gitea", "owners", "--config", "work:g/custom/conf/app.ini",
                             "--index", "work:idx.txt", "--bytes")
        lin = subprocess.run([SERVER, "gitea", "owners", "--config", os.path.join(g, "custom", "conf", "app.ini"),
                              "--index", os.path.join(work, "idx.txt"), "--bytes"], capture_output=True, text=True).stdout

        def strip(t):
            return [x for x in t.splitlines() if not x.startswith("# index")]
        check(rc == 0 and strip(out) == strip(lin) and "acme" in out,
              f"m68k SQLite reads the Gitea database: the same sizes as on Linux {out[-300:]} {err[-300:]}")
        ga, gl = os.path.join(vol, "ga"), os.path.join(work, "gl")
        shutil.copytree(g, ga)
        shutil.copytree(g, gl)
        rc, out, err = vamos(vol, "gitea", "delete-owner", "--config", "work:ga/custom/conf/app.ini",
                             "--owner", "Bob", "--confirm", "Bob")
        r = subprocess.run([SERVER, "gitea", "delete-owner", "--config", os.path.join(gl, "custom", "conf", "app.ini"),
                            "--owner", "Bob", "--confirm", "Bob"], capture_output=True, text=True)
        check(rc == 0 and r.returncode == 0 and dump(os.path.join(ga, "data", "gitea.db")) ==
              dump(os.path.join(gl, "data", "gitea.db")),
              f"m68k: deleting an owner leaves the database as the Linux build does {out[-200:]} {err[-300:]}")
        check(tree(ga) == tree(gl) and not os.path.exists(os.path.join(ga, "data", ".omi-gitea.lock")),
              "and the same files, the lock released")
        c = sqlite3.connect(os.path.join(ga, "data", "gitea.db"))
        check(c.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "the database written on the 68040 is sound")
        c.close()
    finally:
        if FAILURES or os.environ.get("OMI_KEEP_TEST_DIR") == "1":
            print(f"test directory kept: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)
    print(f"===== amiga test: {PASSES} passed, {len(FAILURES)} failed")
    for f in FAILURES:
        print(f"  FAIL {f}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
