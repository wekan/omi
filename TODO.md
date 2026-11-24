# TODO

What is not done yet here, and why. When an item is done, remove it from this
file and describe it in the docs and the commit.

## Not verified yet

- Writing into a real Gitea folder: delete and import were run only on copies
  of the disposable test Gitea. The real `gitea.db` is at Gitea migration 369
  while the local Gitea binary is at 368, so `gitea doctor` could not check it.
  Before the first real run: stop Gitea, back it up, and use a matching Gitea
  binary for doctor.
- Import from the real GitHub API: run once by the maintainer (2026-11-24,
  wekan): GitHub refused the saved token (401; "Test the token" says so now),
  the import read on anonymously and ended with a 403 on
  `repos/wekan/charts/milestones` after "few requests left". To run again with
  a new token, and to see whether that 403 was the hour's limit without a
  `X-RateLimit-Remaining: 0` (which is waited out) or a secondary limit, which
  is not waited out yet.
- Stop was tested before an import's first request and on the job page; not
  yet in the middle of a long import from the real GitHub.
- "Back up first" on the delete page is wired to github-to-gitea's backup but
  no test runs it.
- The Amiga build (`releases/amiga/build.sh`) ran only in vamos, which has no
  TCP/IP stack and creates no processes: on a real Amiga (or FS-UAE with
  AmigaOS or AROS) the web server, an import over `http://`, Gitea's real WAL
  database, files near 2 GiB, `-dOMI_THREADS`, and amiga-git or am-git with
  `GIT_FETCH=program` are still to be tried.

## Not done

- The import does not bring reactions, line review comments, LFS objects,
  Actions, or the branches of pull requests from forks.
- A plain `tree -s` listing cannot tell an empty directory from a 4096-byte
  file; use `tree -a -s -F`.
- https:// on the Amiga: FreePascal has no TLS there. An AmiSSL binding for
  fphttpclient would let the Amiga build read GitHub itself; the m68k GCC has
  AmiSSL's stubs (libamisslstubs.a), FreePascal has no unit for them.
- Thin packs: not asked for (a pack whose delta base is outside it is
  refused). Asking for them would save bandwidth on incremental fetches; the
  bases would then be appended to the pack, as index-pack --fix-thin does.

## For the maintainer: needs a person, not code

- Push `main`.
