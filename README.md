# github-mirror

A small, single-purpose tool that maintains local **bare mirrors** of every
GitHub repository a token can see. Point it at a directory, give it a
read-only token, and it keeps a complete, offline-restorable copy of your repos
— branches, tags, and notes — so your code survives losing access to GitHub
(account lockout, an outage, or just wanting to leave).

It is intentionally boring: enumerate, clone or update, record what happened,
exit. Failures are reported loudly and never mistaken for success.

## What it does

- Enumerates all repositories the token can see, following API pagination to exhaustion.
- For each repo: `git clone --mirror` on first run, `git remote update --prune` thereafter.
- Skips forks by default; keeps archived repos by default (both configurable).
- Writes a `mirror-state.json` recording per-repo and per-run status.
- Exits non-zero if **any** repo failed, or if enumeration itself failed.

## What it does *not* do

- **It only ever adds and updates.** A repo that disappears upstream (you
  deleted it, or lost account access) is left **dormant** on disk, never
  deleted. The local copy is meant to outlive the remote.
- It mirrors **git data only** — not issues, pull requests, releases, or
  wikis. If you need those, you need a separate API export.
- It is **not a backup by itself.** A mirror protects against losing GitHub; it
  does not protect against losing the disk it lives on. Run a real backup
  (e.g. restic) over the mirror directory separately.

## Quick start

The published image is public and self-contained (git is included). You supply
a token file and a target directory.

```sh
# 1. Put a GitHub token in a file (see "Token" below for scopes)
echo "ghp_xxxxchangeme" > /path/to/token

# 2. Run it
podman run --rm \
  --user 1000:1000 \
  -v /path/to/mirrors:/data \
  -v /path/to/token:/run/gh-pat:ro \
  -e GH_TOKEN_FILE=/run/gh-pat \
  -e MIRROR_DIR=/data \
  -e GIT_TIMEOUT=300 \
  ghcr.io/lillevang/github-mirror:latest
```

The mirror directory must be **writable by uid 1000** (the `backup` user the
image runs as). On first run everything is a fresh clone; subsequent runs are
fast incremental updates.

`docker run` works identically — substitute `docker` for `podman`.

## Configuration

All configuration is via environment variables.

| Variable           | Default   | Meaning                                                              |
|--------------------|-----------|----------------------------------------------------------------------|
| `GH_TOKEN_FILE`    | *(required)* | Path to a file containing the GitHub token. Read from a file, never an arg or inline env, so it stays out of process listings and logs. |
| `MIRROR_DIR`       | `/data`   | Directory the bare mirrors are written into.                         |
| `GIT_TIMEOUT`      | *(none)*  | Per-git-invocation timeout in seconds. A safety net against hung operations; set well above your slowest legitimate clone. `300` is a sane default. |
| `INCLUDE_FORKS`    | `false`   | Mirror repos that are forks.                                         |
| `INCLUDE_ARCHIVED` | `true`    | Mirror archived repos (usually what you want — archived code is exactly what's worth preserving). |
| `FETCH_LFS`        | `false`   | Also fetch Git LFS objects. Requires `git-lfs` in the image (commented out in the Dockerfile by default) — a plain `--mirror` clone only stores LFS *pointers*, not the objects. |
| `GH_AFFILIATION`   | `owner`   | GitHub `affiliation` filter (`owner`, `collaborator`, `organization_member`). |
| `GH_VISIBILITY`    | `all`     | GitHub `visibility` filter (`all`, `public`, `private`).             |

## Token

The token is read from a file and used read-only. The minimum scope is **read
access to repository contents**.

- **Fine-grained PAT** (recommended): *Contents: Read-only* and *Metadata:
  Read-only*. Scoped to your own repos. Note that fine-grained PATs do not see
  organization repos unless the org has explicitly enabled them.
- **Classic PAT**: the `repo` scope works but grants read **and** write, which
  is more than this tool needs. Prefer fine-grained unless you need org repos
  it can't reach.

Set a token expiry you can live with. There is no auto-rotation; when the token
expires, every run fails at enumeration (loudly, non-zero) until you replace it.
Pair a long expiry with failure alerting (see below) so a dead token surfaces.

## State and monitoring

Each run writes `mirror-state.json` into `MIRROR_DIR`:

```json
{
  "repos": {
    "owner/name": {
      "last_attempt": "2026-05-31T12:53:45Z",
      "last_status": "ok",
      "last_success": "2026-05-31T12:53:45Z"
    }
  },
  "last_run": "2026-05-31T12:53:45Z",
  "last_run_repo_count": 67,
  "last_run_failures": 0,
  "last_run_ok": true
}
```

The exit code is the primary signal for automation:

- `0` — all selected repos mirrored cleanly.
- `1` — operational failure (a repo failed, or enumeration failed: bad token, API error).
- `2` — configuration error (no token file, unreadable token file).

For alerting, key off the exit code (catches both a dead token and a failed
repo in one check). On a schedule, a wrapper that POSTs to a webhook on
non-zero exit is enough.

**Active vs. dormant repos:** a repo is *active* in a run if its `last_attempt`
equals the run's `last_run`. A repo whose `last_attempt` has stopped advancing
is *dormant* — it no longer appears upstream and is intentionally left in place.
A staleness check should only consider active repos, so dormant ones don't
alert forever. `last_success` is preserved across failures, so a repo that
worked before and then fails keeps its real last-success timestamp.

## Building

Requires a token with `read:packages` is **not** needed to pull (the image is
public). To build and push your own:

```sh
task build   # builds the static image, tags :<git-sha> and :latest
task push    # build + push both tags (run `podman login ghcr.io` first)
task run     # run locally against a throwaway dir
task test    # crystal spec
```

The image is a multi-stage build: a static, musl-linked binary compiled in an
Alpine Crystal builder, copied into a minimal Alpine runtime with `git` and
`ca-certificates`. Static linking is done in the Alpine builder because Crystal
`--static` is supported on musl and fragile on glibc — don't try to build it on
a glibc host.

For local development, build a **dynamic** binary instead
(`crystal build src/github_mirror.cr`), which links against your host libs and
runs directly. Static is only for the deployment image.

> Note: the binary's entrypoint is guarded by a `PROGRAM_NAME` check so the
> spec can `require` the source without running `main`. This works but is
> brittle to renames; a separate `src/main.cr` entrypoint would be cleaner if
> revisiting.

## Tests

`crystal spec` covers the pure logic: Link-header pagination parsing
(`parse_next_link`) and the fork/archived filter (`select_repos`). The I/O paths
(enumeration, git subprocesses, token reading) are deliberately **not**
unit-tested — they're validated by running against real GitHub and git, since
mocking them would only assert that the mocks behave like the mocks.

## Recommended deployment shape

1. **github-mirror** → mirrors GitHub to a local directory (this tool).
2. **restic** (or equivalent) → backs up that directory off-host, on a schedule.
3. Optionally, a **second independent mirror** pulling directly from GitHub to a
   different machine, so the copies don't share an upstream.

The mirror gives you availability; the off-host backup is what makes it durable.
Don't conflate the two.

## License

MIT.
