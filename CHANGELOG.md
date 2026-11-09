# Changelog

All notable changes to sbx-capsule are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Every change to the `.env` format or the make targets is listed here, with
how to migrate.

## [Unreleased]

### Fixed

- `make test` passes shellcheck: a tracked `.shellcheckrc` lets it follow
  each command's `source` of `scripts/lib/all.sh` and treats the sourced
  helper and test files as bash. The intentional findings left have a
  `# shellcheck disable=` that says why.

## [1.0.0] - YYYY-MM-DD

First public release.

### Added

- `make new WITH="repo repo:branch ..." [TITLE=name] [PUSH_AS=branch]
  [EMPTY=1]` creates a numbered sandbox folder (`<n>/` or `<n>-<TITLE>/`)
  holding a full git clone of each repo, started from fresh `origin` state
  on its `SOURCE_BRANCHES` entry or the branch named after `:`. `PUSH_AS`
  names the branch every repo works on, tracking `origin/<branch>`; it's
  refused if invalid, a source branch, or used by another sandbox. With no
  repos (or `EMPTY=1`) the sandbox starts empty.
- `make run N=<n> [ARGS="..."] [FRESH=1]` starts the configured agent in a
  Docker Sandbox (`sbx`) microVM that mounts only the sandbox folder, or
  reattaches to it. `FRESH=1` recreates the VM from the current `.env`.
- `make code N=<n>` opens a sandbox in VS Code running inside its VM, over
  Remote-SSH, with workspace settings (mounted read-only) that keep your
  credentials and ports out of it.
- `make add N=<n> REPO="repo repo:branch ..."` clones more repos into a
  sandbox and records them in its `README.md`.
- `make fetch N=<n> [REPO="..."]` fetches `origin` from the host and hands
  new commits to the agent as a bundle in the sandbox, so the VM needs no
  network access to your git host.
- `make push N=<n> REPO="repo ..." [AS=branch] [YES=1]` pushes a clone's
  branch from the host without running git in the clone, to the
  sandbox's `PUSH_AS` (or `AS`), never forcing and never to a source
  branch.
- `make destroy N=<n> [FORCE=1]` removes a sandbox's VM, clones and
  generated files, refusing while any repo has uncommitted changes,
  stashes, an operation in progress, or commits on no origin branch, and
  archives leftover notes to `.archive/`.
- `make list`, `make stop N=<n>` / `ALL=1`, `make prune [YES=1]` (remove
  VMs whose sandbox folder is gone), `make init` (create `.env` from
  `.env.example`), `make doctor` (a read-only check of tools, sbx, `.env`,
  repos, host safety and VS Code setup, with a fix for each problem) and
  `make help`.
- Configuration in a personal `.env` (plain bash) over the tracked
  `.env.default`: `REPOS`, `SOURCE_BRANCHES`, `DEFAULT_REPOS`,
  `REPO_GROUP`, `REPO_DESC`, `AGENT` (any sbx built-in agent or a kit
  reference), `AGENT_ARGS`, `SBX_CREATE_FLAGS`, `SBX_NAME_PREFIX`,
  `AGENT_GIT_PUSH`, `SANDBOX_NOTES_FILE`, `VSCODE_CMD`, `VSCODE_PROFILE`
  and `VSCODE_USER_DIR`. Every command validates it first and lists every
  problem at once.
- Each sandbox gets a `README.md` for you, an `AGENTS.md` of rules for the
  agent (with `CLAUDE.md` and `GEMINI.md` shims importing it), and
  `.vscode/settings.json`.
- VM names carry an id derived from the checkout's path, so two checkouts
  of the tool never share a VM, and every command finds a sandbox's VM by
  what it mounts, not by name alone.
- `make test`: a plain-bash test suite run against scratch copies of the
  tool with a fake `sbx`, covering the make targets, failure paths,
  host-side injection payloads and the host safety checks.
- Docs: README, docs/DESIGN.md, docs/DOCKER_SANDBOXES.md, CONTRIBUTING.md,
  SECURITY.md (with a private vulnerability report form) and AGENTS.md for
  agents working on the tool.

### Security

- The sandbox folder is treated as untrusted on the host. No command
  sources or executes a file from it, reads through a symlink or FIFO
  there, or looks through a symlink in place of a clone. Files are read
  from hard-link snapshots outside the sandbox, new clones are built
  outside it and moved in, and names from it are printed with control
  characters replaced.
- Host-side git on a clone switches off everything that could run a
  command (fsmonitor, hooks, filter drivers, signature programs, pagers,
  network transports), refuses a config that isn't a regular file or
  includes other files, and is stopped after 120 seconds. `make destroy`
  stops the sandbox's VM before checking its clones.
- Clones are seeded by fetching the source checkout's `origin/*` branches,
  so no git object files are shared with your checkouts.
- `make push` reads its target from `.state/`, outside the sandbox, and
  fetches the branch out through `upload-pack` instead of running git in
  the clone.
- `make run` and `make code` refuse while any sbx VM can write this
  checkout (outside its sandbox folders) or a source checkout, at its own
  path or another, while sbx forwards your SSH agent with
  `AGENT_GIT_PUSH=no`, or while sbx would mount your agent's skills store
  writable. They fail closed when sbx doesn't answer.
- `SBX_CREATE_FLAGS` takes flags only: the flags the tool manages,
  `--mount`, `--skills readwrite` and bare folders are refused.
- Make variables reach the scripts through the environment, never as shell
  code.
- `make doctor` audits each clone for config and hooks that would run on
  the host, and notes a git below the upstream fixes for CVE-2022-23521
  and CVE-2024-32465; `make push`, `make fetch` and `make destroy` warn
  for a git series that never got them.

### Requirements

- bash 4+, git 2.23+ and make; Docker Sandboxes (`sbx`, checked against
  v0.50.1 and v0.51.0) for `make run` and `make code`; jq is optional.
- macOS, Windows 11 (inside WSL2) or Ubuntu 24.04+. macOS hadn't been
  tested at release: see the README's requirements.

<!-- Version links go here once the public repository and its tags exist:
[Unreleased]: https://github.com/proangelos/sbx-capsule/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/proangelos/sbx-capsule/releases/tag/v1.0.0
-->
