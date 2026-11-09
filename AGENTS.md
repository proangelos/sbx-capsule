# AGENTS.md -- working on sbx-capsule

Instructions for AI coding agents changing **this tool**. Humans: the
[README](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md) cover the same
ground for you.

> **Scope check first.** Sandboxes are created *inside* this repo, as
> numbered folders (`3/`, `3-login-fix/`, ...). If your working directory is
> inside one of those, **these instructions don't apply to you.** You are
> working on a task in a sandbox: follow the `AGENTS.md` in that sandbox's
> root and ignore this file. Never edit the tool's files from inside a
> sandbox.

## What this is

A handful of bash scripts, driven by `make`, that create numbered sandbox
folders of git clones from a user's local checkouts and run a coding agent
on them inside a Docker Sandbox (`sbx`) microVM. The user-facing docs are
in [README.md](README.md), the reasoning behind the design is in
[docs/DESIGN.md](docs/DESIGN.md), and `sbx` specifics are in
[docs/DOCKER_SANDBOXES.md](docs/DOCKER_SANDBOXES.md). Read the relevant one
before changing behaviour.

## Repo map

```
Makefile                 entry point: make init / doctor / new / run / code / stop / prune / add / fetch / push / destroy / list / help / test
.env.default             tracked tool defaults (users override in .env, never edit this)
.env.example             annotated template for a user's .env
.shellcheckrc            shellcheck settings for make test: follow sources from each script's directory, sourced files are bash
scripts/
├── commands/            one executable per make target
│   ├── create.sh        make new: validate, clone, write the sandbox's README/AGENTS/shims and .state/<n>/push_as
│   ├── add.sh           make add: clone more repos into a sandbox, record them in its README
│   ├── run.sh           make run: create or reattach the sandbox's sbx VM
│   ├── code.sh          make code: open a sandbox in VS Code running inside its VM (Remote-SSH to <vm>.sbx)
│   ├── stop.sh          make stop: stop a sandbox's sbx VM (or all of this checkout's), keeping its state
│   ├── prune.sh         make prune: remove this checkout's VMs whose sandbox folder is gone
│   ├── list.sh          make list: sandboxes, their repos and VM state, plus leftover VMs
│   ├── fetch.sh         make fetch: fetch origin into a staging repo, hand new commits to the agent as a bundle
│   ├── push.sh          make push: fetch a clone's branch out into a staging repo, push it from there; record it in .state/
│   ├── destroy.sh       make destroy: unsaved-work check, remove VM and clones, archive notes
│   ├── doctor.sh        make doctor: read-only check of tools, sbx, .env and repos
│   └── init.sh          make init: create .env from .env.example, then run doctor
└── lib/                 sourced helpers, never executed
    ├── all.sh           the one file commands source; sets TOOL_ROOT, loads the rest in order
    ├── config.sh        declares config vars, sources .env.default then .env; SANDBOX_ROOT
    ├── output.sh        colors, die, warn, banner, safe_text
    ├── agents.sh        sbx VM naming/lookup (sbx_name, sandbox_vm, sbx_vms + _mount_hosts, tool_vms, leftover_vms), built-in agents, SBX_RESERVED_FLAGS, SBX_VALUE_FLAGS, AGENT_SHIMS, git_hosts
    ├── sandbox.sh       is_sandbox_dir, find_sandbox_dir, is_clone (never a symlink), has_symlink_under, GENERATED_FILES, FETCH_BUNDLE_GLOB, sandbox_git, snapshot_sandbox_file, state_dir_of, read_push_as, move_into_sandbox
    ├── validate.sh      PROBLEMS/report_problems, validate_config/check_config, check_sbx_create_flags, parse_repo_specs, check_start_branches
    ├── git_version.sh   git_version, version_at_least, git_has_fix/git_has_upload_pack_fix (CVE floors), warn_old_git
    ├── push_as.sh       check_push_as, push_as_users
    ├── clone.sh         clone_repo, resumed_banner, init_staging_repo
    ├── host_safety.sh   check_host_exposure: VM mounts, source checkout paths, SSH agent forwarding, skills store mode (make run refuses on these); audit_clone; vms_running_on
    └── vscode.sh        make code: the sandbox's read-only .vscode settings, VS Code and *.sbx SSH checks, finding VS Code
docs/                    DESIGN.md (rationale), DOCKER_SANDBOXES.md (sbx setup and behaviour)
tests/                   make test: run.sh (runner), lib.sh (scratch copies, assertions), *.test.sh, fake-sbx/sbx
```

Each command starts with `source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"`.
A new helper module goes in `scripts/lib/` and gets a line in `all.sh`, after
the modules it uses at load time (only top-level code matters: `sandbox.sh`
builds `GENERATED_FILES` from `AGENT_SHIMS`, so it loads after `agents.sh`).
A new command goes in `scripts/commands/` with a Makefile target.

**Paths.** `TOOL_ROOT` (= `SANDBOX_ROOT`) is the repo root, not `scripts/`:
`.env` lives there, sandboxes are created there, and a checksum of its
path (`SBX_CHECKOUT_ID`) is part of every sbx VM name (`sbx_name`). Moving
it would orphan users' existing VMs and sandboxes. Find a sandbox's VM with
`sandbox_vm`, never by name alone: a VM named like it may not mount it, and
one made under an earlier `SBX_NAME_PREFIX` has a different name
(`is_tool_vm_name` matches any prefix).

The text written *into* each sandbox lives in `scripts/commands/create.sh`
(the `README.md` and `AGENTS.md` heredocs) and `scripts/lib/agents.sh`
(`write_agent_shims`). Those have different readers from this file: the
sandbox `README.md` is for the user, the sandbox `AGENTS.md` is for an agent
doing a task. Keep repo/branch detail in the sandbox `README.md` and have its
`AGENTS.md` point there.

## Invariants -- don't break these

- **Validate before acting, report everything at once.** Checks append to
  `PROBLEMS` and `report_problems` prints them all and exits before anything
  is created or removed. Don't add a check that dies on the first problem,
  and don't create anything before the checks are done.
- **A sandbox folder is untrusted on the host.** The VM can write all of
  it, `.git` included. Never `source` or execute anything from it; parse
  what you need from it as data, and read a file from it only through
  `snapshot_sandbox_file`, never by name in place: checking that it's a
  regular file and then opening it is a race the VM can win. Run git in its clones only through `sandbox_git <dir> ...`, which
  switches off everything that makes git run commands. Write into it by
  building outside and moving in (`move_into_sandbox`). Print names from it
  through `safe_text`. docs/DESIGN.md, "The sandbox folder is untrusted on
  the host", has the reasoning.
- **Source checkouts are read-only to the tool.** Clone from them, fetch
  from them; never create branches, write config or run hooks in them.
- **`GENERATED_FILES` (`sandbox.sh`) is a contract with `destroy.sh`.** Every
  file `create.sh` writes at a sandbox root must be listed there, or it
  gets archived as a "note" on teardown (make fetch's bundles match
  `FETCH_BUNDLE_GLOB` instead). Anything else must not be deleted.
- **`destroy.sh` never deletes unsaved work** without `FORCE=1`.
- **Make variables never become shell code.** A target's variables are
  listed in the Makefile's `TARGET_VARS` (exported), and recipes read them
  as `"$$VAR"`, never `$(VAR)`, which make pastes into the command as text.
  A new variable goes in `TARGET_VARS`.
- **`SBX_RESERVED_FLAGS`** are managed by the tool and must stay refused in
  `SBX_CREATE_FLAGS`.
- **Config is plain bash.** `.env.default` holds every default; `.env` is
  the user's. A new setting gets a default in `.env.default`, an empty
  placeholder in `config.sh`, validation in `validate_config` or
  `check_agent_config`, a commented example in `.env.example`, and a row in
  the README's configuration table.
- **Removed settings fail loudly.** When a variable or option is retired,
  using it should stop with a message saying what replaced it, not be
  silently ignored: a check in `validate_config` (or the command that took
  it) that appends that message to `PROBLEMS`.
- **Headings referenced by name stay put.** `.env.default`, `.env.example`
  and the generated sandbox files point at README sections ("Choosing an
  agent", "Letting the agent push", "Reviewing and editing a sandbox", the
  last also from the scripts' messages and each sandbox's
  `.vscode/settings.json`) and at sandbox README sections ("Repos
  added after creation", "Post-creation base changes"). Rename one and you
  must update every reference. `add.sh` also depends on the
  `<!-- make add inserts entries above this line -->` marker.
- **`make doctor` knows every requirement.** A new external dependency,
  minimum version or setup step gets a check in `doctor.sh` with a fix
  hint, and stays out of anything that installs software: the tool never
  installs anything itself. Checks reuse the `check_*` helpers (which
  append to `PROBLEMS`) rather than duplicating their logic.
- **Old sandboxes keep working.** From 1.0.0 on, sandboxes, VMs and
  `.env` files made by any earlier 1.x release must still `run`, `add`,
  `fetch`, `push` and `destroy` after any change. (Nothing before 1.0.0 is
  supported: it was never public.)

## Bash conventions

- Commands start with `#!/usr/bin/env bash` and `set -euo pipefail`.
  Everything in `scripts/lib/` is sourced: no shebang, no `set -e`.
- Target bash 4+ (associative arrays, `${var,,}`). Don't use bash 5-only
  features. `all.sh` refuses older bash before loading anything else.
- Expand possibly-empty arrays as `${arr[@]+"${arr[@]}"}`, since `nounset`
  treats an empty array as unset on older bash.
- Use `die`, `warn` and `banner` from `output.sh` for output. Color only goes
  to a TTY and honours `NO_COLOR`.
- Each script and helper starts with a comment saying what it does and why;
  keep those accurate when changing behaviour.
- No new runtime dependencies beyond bash, git, make, coreutils and `sbx`.

## Testing

Before calling a change done:

1. `make test` passes. It checks that every script parses, runs
   `shellcheck -x` if it's installed (settings in `.shellcheckrc`; CI
   runs it on Linux, so it must come back clean), then runs `tests/*.test.sh`
   (`tests/run.sh`): each test gets a scratch copy of the tool, a
   throwaway source repo and a fake `sbx` (`tests/fake-sbx/sbx`), so it
   needs no VM and never touches a real `.env` or sandbox. Add tests for
   what you change: `e2e` for the make targets, `failures` for refusals,
   `injection` for anything that reads a sandbox from the host (one
   payload per path, with a control showing the payload is live),
   `host_safety` for checks that read sbx's VMs.
2. The fake `sbx` can't run a VM, so if you changed `make run`, `make code`
   or anything else that talks to sbx, also run it against real `sbx`,
   **in a scratch copy of this repo**, never in a user's working
   checkout with real sandboxes in it: make a throwaway git repo with an
   `origin` (a bare repo works), write a `.env` pointing at it, and run
   the path you changed. `make doctor` there should pass, and still report
   what you broke if you break it on purpose.

## Docs and changelog

- User-visible change → update [README.md](README.md) and add a line under
  `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) (Added / Changed /
  Deprecated / Removed / Fixed / Security). Breaking changes say how to
  migrate.
- Design change → update [docs/DESIGN.md](docs/DESIGN.md).
- `sbx` behaviour change → update
  [docs/DOCKER_SANDBOXES.md](docs/DOCKER_SANDBOXES.md), including the `sbx`
  version it was checked against.
- Keep docs free of company-, team- or machine-specific content; that
  belongs in a user's `SANDBOX_NOTES_FILE`.

## Git

- Commit messages: an imperative, sentence-case summary line without a type
  prefix (e.g. "Remove the sbx VM on destroy and keep repos with unsaved
  work"), then a body explaining why if it isn't obvious.
- Never commit `.env`, numbered sandbox folders or `.archive/` (all are
  gitignored -- don't force-add them).
- Don't push or open PRs unless asked.
