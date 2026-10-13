# github-mirror

**Keeps a complete, offline-restorable copy of every GitHub repository a token can see. One container, one directory, exit code tells you if it worked.**

[![Release](https://img.shields.io/github/v/release/Lillevang/github_mirror?display_name=tag)](https://github.com/Lillevang/github_mirror/releases/latest)
[![CI](https://github.com/Lillevang/github_mirror/actions/workflows/ci.yml/badge.svg)](https://github.com/Lillevang/github_mirror/actions/workflows/ci.yml)
[![Container](https://img.shields.io/badge/ghcr.io-lillevang%2Fgithub--mirror-blue?logo=docker)](https://github.com/Lillevang/github_mirror/pkgs/container/github-mirror)
[![Crystal](https://img.shields.io/badge/built%20with-Crystal-000000?logo=crystal)](https://crystal-lang.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Point it at a directory, give it a read-only token, and it maintains **bare
mirrors** of your repos, including branches, tags and notes, so your code
survives losing access to GitHub (account lockout, an outage, or just wanting
to leave).

It is intentionally boring: enumerate, clone or update, record what happened,
exit. Failures are reported loudly and never mistaken for success.

```
$ podman run --rm -v ./mirrors:/data -v ./token:/run/gh-pat:ro -e GH_TOKEN_FILE=/run/gh-pat ghcr.io/lillevang/github-mirror
2026-10-13T20:14:02.000000Z   INFO - github-mirror 0.1.0 started
2026-10-13T20:14:02.000000Z   INFO - GitHub token loaded from /run/gh-pat
2026-10-13T20:14:03.000000Z   INFO - Enumeration returned 71 repositories
2026-10-13T20:14:03.000000Z   INFO - Skipped 4 repositories (fork/archived filters)
2026-10-13T20:14:05.000000Z   INFO - OK   update Lillevang/jwtpeek
2026-10-13T20:14:06.000000Z   INFO - OK   update Lillevang/fuzzy_match
2026-10-13T20:14:09.000000Z   INFO - OK   clone  Lillevang/scopeweaver
...
2026-10-13T20:15:41.000000Z   INFO - DONE: 67 repositories mirrored cleanly
```

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
- It mirrors **git data only**: not issues, pull requests, releases, or
  wikis. If you need those, you need a separate API export.
- It is **not a backup by itself.** A mirror protects against losing GitHub; it
  does not protect against losing the disk it lives on. Run a real backup
  (e.g. restic) over the mirror directory separately.

## Installation

### Container image (recommended)

The image is public and self-contained (`git` is included). You supply a token
file and a target directory.

```sh
# 1. Put a GitHub token in a file (see "Token" below for scopes)
echo "ghp_xxxxchangeme" > /path/to/token

# 2. Run it
podman run --rm \
  --user 1000:1000 \
  -v /path/to/mirrors:/data \
  -v /path/to/token:/run/gh-pat:ro \
  -e GH_TOKEN_FILE=/run/gh-pat \
  -e GIT_TIMEOUT=300 \
  ghcr.io/lillevang/github-mirror:latest
```

The mirror directory must be **writable by uid 1000** (the `backup` user the
image runs as). On first run everything is a fresh clone; subsequent runs are
fast incremental updates. `docker run` works identically.

Every release is tagged `ghcr.io/lillevang/github-mirror:<version>`; `:latest`
follows the newest release.

### Prebuilt binary

Each release also ships a static Linux binary (x86_64) with a `.sha256` next
to it. It needs `git` on the host and nothing else.

```sh
curl -fsSL https://github.com/Lillevang/github_mirror/releases/latest/download/github-mirror-linux-amd64 -o github-mirror
chmod +x github-mirror
mv github-mirror ~/.local/bin/   # or anywhere on your PATH

GH_TOKEN_FILE=/path/to/token MIRROR_DIR=/path/to/mirrors github-mirror
```

### From source

Requires [Crystal](https://crystal-lang.org/install/) 1.20 or newer.

```sh
git clone https://github.com/Lillevang/github_mirror.git
cd github_mirror
shards build --release      # produces bin/github-mirror (dynamic, links against host libs)
```

## Configuration

All configuration is via environment variables. `github-mirror --help` prints
the same table.

| Variable           | Default      | Meaning                                                              |
|--------------------|--------------|----------------------------------------------------------------------|
| `GH_TOKEN_FILE`    | *(required)* | Path to a file containing the GitHub token. Read from a file, never an arg or inline env, so it stays out of process listings and logs. |
| `MIRROR_DIR`       | `/data`      | Directory the bare mirrors are written into.                         |
| `GIT_TIMEOUT`      | *(none)*     | Per-git-invocation timeout in seconds. A safety net against hung operations; set well above your slowest legitimate clone. `300` is a sane default. |
| `INCLUDE_FORKS`    | `false`      | Mirror repos that are forks.                                         |
| `INCLUDE_ARCHIVED` | `true`       | Mirror archived repos (usually what you want, since archived code is exactly what's worth preserving). |
| `FETCH_LFS`        | `false`      | Also fetch Git LFS objects. Requires `git-lfs` in the image (commented out in the Dockerfile by default). A plain `--mirror` clone only stores LFS *pointers*, not the objects. |
| `GH_AFFILIATION`   | `owner`      | GitHub `affiliation` filter (`owner`, `collaborator`, `organization_member`). |
| `GH_VISIBILITY`    | `all`        | GitHub `visibility` filter (`all`, `public`, `private`).             |

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

- `0`: all selected repos mirrored cleanly.
- `1`: operational failure (a repo failed, or enumeration failed: bad token, API error).
- `2`: configuration error (no token file, unreadable token file, unwritable mirror directory).

For alerting, key off the exit code (catches both a dead token and a failed
repo in one check). On a schedule, a wrapper that POSTs to a webhook on
non-zero exit is enough.

**Active vs. dormant repos:** a repo is *active* in a run if its `last_attempt`
equals the run's `last_run`. A repo whose `last_attempt` has stopped advancing
is *dormant*: it no longer appears upstream and is intentionally left in place.
A staleness check should only consider active repos, so dormant ones don't
alert forever. `last_success` is preserved across failures, so a repo that
worked before and then fails keeps its real last-success timestamp.

## Recommended deployment shape

1. **github-mirror** → mirrors GitHub to a local directory (this tool).
2. **restic** (or equivalent) → backs up that directory off-host, on a schedule.
3. Optionally, a **second independent mirror** pulling directly from GitHub to a
   different machine, so the copies don't share an upstream.

The mirror gives you availability; the off-host backup is what makes it durable.
Don't conflate the two.

A systemd timer is the simplest scheduler. The service runs the container and
the timer fires it nightly; a failed run shows up in `systemctl --failed`:

```ini
# ~/.config/systemd/user/github-mirror.service
[Service]
Type=oneshot
ExecStart=podman run --rm --user 1000:1000 \
  -v %h/mirrors:/data -v %h/.config/github-mirror/token:/run/gh-pat:ro \
  -e GH_TOKEN_FILE=/run/gh-pat -e GIT_TIMEOUT=300 \
  ghcr.io/lillevang/github-mirror:latest

# ~/.config/systemd/user/github-mirror.timer
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
```

## Development

Every check, build and publish step is a [Task](https://taskfile.dev) command
in `Taskfile.yml`, so what runs on a release runner is exactly what runs on a
laptop.

```sh
task            # same as task verify
task verify     # format check, specs, debug build, smoke test
task test       # just the specs
task fmt        # format sources in place
task image      # build the container image and smoke test it
task run        # run the image against a local dir (DATA_DIR= / TOKEN_FILE= to override)
task dist       # static Linux binary to dist/ plus sha256, built in the Alpine stage
```

The image is a multi-stage build: a static, musl-linked binary compiled in an
Alpine Crystal builder, copied into a minimal Alpine runtime with `git` and
`ca-certificates`. Static linking happens in the Alpine stage because Crystal
`--static` is supported on musl and fragile on glibc, so `task dist` extracts
the release binary from that same stage rather than building it on the host.
For local development `shards build` produces a dynamic binary that runs
directly.

### Tests

`crystal spec` covers the pure logic: Link-header pagination parsing
(`parse_next_link`) and the fork/archived filter (`select_repos`). The I/O
paths (enumeration, git subprocesses, token reading) are deliberately **not**
unit-tested. They're validated by running against real GitHub and git, since
mocking them would only assert that the mocks behave like the mocks. The smoke
test in `task verify` checks the built binary reports its version and refuses
to run without a token.

### Releasing

```sh
task bump                 # 0.1.0 → 0.1.1 (TARGET=minor|major for the others)
git commit -am "Bump to 0.1.1"
task release              # verify, tag v0.1.1, push
```

Pushing the tag triggers `.github/workflows/release.yml`, a thin wrapper that
runs `task verify`, `task dist`, `task image`, `task publish` and
`task image-push`: it attaches the static binary to a GitHub release and pushes
the image to `ghcr.io` tagged `:<version>` and `:latest`. The workflow holds no
logic of its own: the same tasks cut the same release from any machine with
`podman` and `gh`.

`release` refuses to run from a dirty tree, from a branch other than `main`, or
for a tag that already exists. The version lives in `src/version.cr` and is
mirrored in `shard.yml`; `bump` keeps the two in sync and `check-tag` makes
sure the pushed tag matches.

## Planned: relay mode

A second mode is planned for a different topology: a bare git server in a
network zone that cannot reach Azure DevOps, and a host in a trusted zone that
pulls from it over SSH and pushes to Azure DevOps. Azure DevOps owns `main`
and release branches, which flow back the other way. Nothing is initiated from
the untrusted zone. The design and build order are tracked in
[issue #8](https://github.com/Lillevang/github_mirror/issues/8).

## License

[MIT](LICENSE) © [Jeppe Lillevang Salling](https://github.com/Lillevang)
