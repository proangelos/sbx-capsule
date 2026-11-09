# Docker Sandboxes and this tooling

How this tool uses Docker Sandboxes (`sbx`): setup, how the two fit together, and `sbx` behaviour worth knowing. Checked against `sbx` v0.50.1 and v0.51.0. Parts of Docker Sandboxes are marked Early Access, so details may change. The root [README](../README.md) covers the tool itself, and [DESIGN.md](DESIGN.md) the reasoning behind it.

## Summary

The two solve different halves of the problem. Docker Sandboxes contain the agent, and this tooling sets up the multi-repo workspace it works in.

- **Docker Sandboxes** turn the safety rules in the generated `AGENTS.md` (stay inside the sandbox, leave running containers alone) from requests into enforced limits.
- **This tooling** does what `sbx` doesn't: a clone per repo, a start branch per repo (overridable with `repo:branch`), `PUSH_AS` push tracking, generated instructions for whichever agent you run, and notes archived on teardown.
- **How they meet:** each sandbox is a folder of full git clones, mounted into the VM in `sbx` direct mode. Each clone has its own `.git`, so git works in the VM with nothing else mounted.

## What each one does

|  | This tooling | Docker Sandboxes (`sbx`) |
| --- | --- | --- |
| Main job | Sets up the workspace: a clone per repo, branches, generated `README.md`, `AGENTS.md` and agent shims | Contains the agent: it runs in a microVM and only sees the folders you mount |
| How safety is enforced | Instructions in `AGENTS.md` | Enforced. Nothing outside the mounts is visible, outbound traffic goes through an allow-list proxy, and API keys stay on the host |
| Multiple repos | Built for it: repos from your `.env`, picked per sandbox with `WITH=`, a start branch per repo | One main folder plus extra mounts. Clone mode and its git helpers only cover the main folder |
| Agents | `AGENT` in `.env` picks one for new VMs | Built in: claude, codex, copilot, cursor, devin, docker-agent, droid, gemini, kiro, opencode, shell, plus custom kits |
| Docker access | n/a | Each sandbox has its own Docker engine; host containers are unreachable |
| Lifetime | `make new` / `make destroy N=` | Persists until `sbx rm` (`make destroy` does that too, and `make prune` for a sandbox that's gone) |

## Why clones, not git worktrees

If `sbx` is pointed at a folder of git worktrees, the agent can edit files but can't run `git status`, commit or branch. A worktree's `.git` is a one-line file pointing at `<source>/.git/worktrees/<name>`, which is outside the mount. Docker's [git guide](https://docs.docker.com/ai/sandboxes/workflows/git/) says the same.

Mounting each source repo's `.git` as well would make git work, but it would have to be writable. A writable `.git` exposes `hooks/` and `config`, which run commands on the host the next time you use git there: a narrow path back out of the sandbox. Full clones avoid both problems. The tool makes them from your local checkouts by fetching their `origin/*` branches, so no object files are shared with the checkout (a hardlinked clone would let the VM rewrite your checkout's history through them).

## Setup

Supported hosts are macOS, Windows 11 and Ubuntu 24.04+. Refer to [Docker's install guide](https://docs.docker.com/ai/sandboxes/install/) for up-to-date installation instructions. Once `sbx` is installed:

```bash
sbx login
sbx policy init balanced     # allow-list network policy
sbx diagnose                 # checks KVM, storage, the binary
```

Then, from this repo, `make doctor` runs `sbx diagnose` for you along with the tool's own checks.

`sbx` runs its own VMs and doesn't use the host's Docker Engine, so an existing Docker install stays as it is. On WSL, don't also turn on Docker Desktop's WSL integration for the same distro, since both would claim `/var/run/docker.sock`. WSL isn't an officially listed platform, but it works with `/dev/kvm` available. Windows `sbx` is the fallback: there, repos mount as `\\wsl.localhost\...` paths and git needs a `safe.directory` entry ([troubleshooting](https://docs.docker.com/ai/sandboxes/troubleshooting/)).

**Signing in the agent.** You do this once per agent, not per sandbox:

- **Claude:** run `/login` inside any sandbox. New sandboxes start signed in.
- **Most other agents:** store an API key with the sbx proxy, which uses it on the agent's behalf so the key never enters the VM. Examples: `sbx secret set openai` for codex, `sbx secret set google` for gemini. `sbx secret set --help` lists the services.

## How the day-to-day works

| Area | With this tooling |
| --- | --- |
| Starting the agent | `make run N=<n>` runs `sbx run <AGENT>` on the sandbox root, so its `AGENTS.md` (and `CLAUDE.md`/`GEMINI.md`) load. Running it again reattaches |
| Running the app | Containers on your host run from your source checkouts, not the sandbox. The agent can start its own stack inside the VM; images aren't shared between sandboxes, so expect slow first builds and more disk |
| Network | Allow-list proxy (`balanced` policy). Package registries, GitHub over HTTPS, Docker Hub and the major model APIs are allowed. SSH (port 22, even to GitHub) and private git servers aren't; `sbx policy allow network <host>` opens a host on every port. `make doctor` checks each repo's git host. Admins may manage this centrally |
| Pushing | By default the agent only commits and you push from the host; with `PUSH_AS`, a bare `git push` works. `AGENT_GIT_PUSH=yes` lets the agent push (see README) |
| Agent config | Host settings, memory and plans (`~/.claude`, `~/.codex`, ...) don't carry over into the VM |
| Seeing and stopping VMs | `make list` shows each sandbox's VM state; `make stop N=<n>` (or `ALL=1`) runs `sbx stop`. A stopped VM keeps its state, and `make run` starts it again |
| Cleanup | `make destroy N=<n>` removes the VM too, and refuses if any repo has unsaved work (`FORCE=1` overrides). `make prune` removes VMs whose sandbox folder is gone |

## sbx behaviour worth knowing

- **VM names:** at most 63 characters (`sbx` refuses longer ones), and no underscores. A name may start with a digit (`3e4cf7-1` works). `make new` refuses a `TITLE` that would make the sandbox's VM name too long, and `make doctor` a `SBX_NAME_PREFIX` longer than 32 characters.
- **Creating vs reattaching:** `sbx run --name X` alone only reattaches, reading the agent from the VM's spec. To create one, name the agent and the folder: `sbx run --name X <agent> <path>`. Leaving out the path mounts the current folder, so running it from `~/dev` would mount all of `~/dev` writable. `make run` always passes the sandbox path.
- **Listing:** `sbx ls --json` gives each VM's `name`, `agent`, `status` (`running`, `stopped`) and `workspaces`, the folders it mounts. From v0.51.0 it also gives `mounts`, every bind as `HOST:TARGET[:ro]` (`/path/to/sb/1:/path/to/sb/1`). `make list`, `make stop`, `make prune` and `make doctor` tell this checkout's VMs apart by workspace: a VM is ours if it mounts a sandbox folder directly under this checkout and its name ends in this checkout's id and that folder's name (under any `SBX_NAME_PREFIX`). They read the JSON with jq when it's installed, else with awk, which relies on sbx's pretty-printed layout. The host safety checks read both `workspaces` and `mounts`.
- **Mounting at another path (v0.51.0):** a workspace can be `PATH:TARGET[:ro]`, mounting a host folder at `TARGET` inside the VM. `sbx ls --json` lists it that way in `workspaces` (`/path/to/data:/data`), and writes to `TARGET` reach the host folder. A host path can itself hold `:`, so the tool reads every way an entry could split and checks each one that exists. Read-only single files are allowed too (`<dir>/file:ro`), holding one path out of reach inside a writable workspace.
- **Read-only mounts:** a workspace mounted read-only appears in `sbx ls --json` with `:ro` on the end of its path (`/path/to/src/api:ro`). A VM needs at least one writable workspace: `sbx create` with only `:ro` folders fails, and so does one whose first folder is `:ro` (`sbx create shell <dir>:ro <other>`): the first is the main workspace and must be writable. `make run` always passes the sandbox folder first. A read-only folder can sit inside a writable one (`sbx run ... <dir> <dir>/.vscode:ro`, as `make run` does): writing, deleting, adding to or renaming it from inside the VM all fail, while the rest of `<dir>` stays writable.
- **SSH into a VM:** `sbx setup ssh` (experimental) adds an `Include` to `~/.ssh/config` for `Host *.sbx`, with `ProxyCommand sbx ssh proxy %n`, no client key (the daemon checks your Docker login), and the daemon's host key in its own `known_hosts`. `ssh <vm>.sbx` starts a stopped VM and opens a shell in its workspace; `sbx exec -it <vm> bash` does the same without the setup. VS Code's Remote-SSH uses this for `make code`. `sbx setup ssh remove` undoes it.
- **SSH agent forwarding is on by default.** `ssh.agentForwardingEnabled` (`sbx settings get` / `set`) "allow[s] sandboxes to list SSH agent keys and sign", using the `SSH_AUTH_SOCK` of whoever runs `sbx`. With `AGENT_GIT_PUSH=no`, `make run` refuses until it's `false` (then `sbx daemon restart`).
- **Other settings that reach the host** (`sbx settings ls`): `browser.enabled` (default `true`) lets sandboxed processes open URLs in your browser, which in-VM logins redirecting to localhost need; `clipboard.imagePaste` (default `false`) lets agents read the host clipboard; `clipboard.textCopy` (v0.51.0, default `false`) lets them write text to it, which you might then paste into a terminal. `skills.defaultMode` (v0.51.0, default `readonly`) sets how the agent's shared skills store (e.g. `~/.claude/skills`) is linked into new VMs: `readwrite` mounts it writable, so the agent could write skills that your agent on the host then loads. `make doctor` notes `browser.enabled` and `clipboard.textCopy`, and `make run` refuses `skills.defaultMode=readwrite` unless `SBX_CREATE_FLAGS` sets `--skills readonly` or `off`.
- **Stopping:** `sbx stop <name>...` stops a VM without removing it. Its state is kept, and `sbx run --name <name>` (so `make run`) starts it again.
- **No terminal:** `sbx run` without a terminal (from a script, say) still creates or starts the VM, then exits with "inspect exec: context deadline exceeded" when it can't attach the agent. The VM is fine. `make run` warns first; `sbx create` makes a VM without attaching.
- **Removing:** `sbx rm <name>` asks for confirmation, and without a terminal it fails with "stdin is not a terminal; use --force". `make destroy`, `make run FRESH=1` and `make prune` pass `--force`, after their own checks and confirmation.
- **The agent is fixed per VM.** To switch, remove the VM (`sbx rm`) and create it again, which `make run N=<n> FRESH=1` does. Files in direct mode are on the host and aren't affected.
- **Startup:** the first VM for an agent pulls its image (about 2 minutes for Claude); later creates take about 10 seconds.
- **Git in direct mode:** commits made in the VM land in the host repo immediately, and files stay owned by the host user.
- **Extra context:** `sbx` writes its own instructions file inside the VM, one folder above the mounted folder (for Claude, a ~19 KB `CLAUDE.md`). It covers the proxy, ports, git auth and direct vs clone mode, and never appears on the host. The generated `AGENTS.md` says it wins where they differ.
- **Permissions:** Claude runs in `bypassPermissions` mode by default, since the VM is the boundary.
- **Folder location:** don't mount folders under `/tmp/claude-<uid>`. The VM creates the parent folders as root, and Claude refuses to start. Folders under your home directory are fine.
- **Checked against v0.51.0** for `PATH:TARGET` workspaces, `mounts`, `--mount`, `--skills` and `clipboard.textCopy`, on Linux. How a kit's `--mount` bind is listed wasn't seen (no kit declaring `host-mount@1` was at hand); the checks read it from `mounts` if it's there.
- **No `--branch`:** one Docker page mentions `sbx run claude --branch <name>`, but neither v0.50.1 nor v0.51.0 has such a flag. The only git option is `--clone`.
- **Flags worth knowing** (pass creation-time ones through `SBX_CREATE_FLAGS` in `.env`):
  - `--cpus`, `--memory`: the default is all CPUs and half of host memory.
  - `-p HOST:SANDBOX`: publish a port, set at creation.
  - `-e KEY=VALUE` / `--env-file`: environment for the agent session.
  - `-t <template>`: start from a saved snapshot (`sbx template save`).
  - `--kit <mixin>`: add a kit to a built-in agent.
  - `--skills off|readonly|readwrite` (v0.51.0): the skills store mode for this VM; see above. `readwrite` is refused.
  - `--mount HOST:SANDBOX_PATH` (v0.51.0): binds a host folder to a path a kit declares (`host-mount@1`); without such a kit `sbx` refuses it ("no kit declares host-mount@1"). Refused in `SBX_CREATE_FLAGS`, as are bare words there, which `sbx` would mount as more workspaces.

## Using sbx without this tooling

For reference, these are the three ways `sbx` handles a workspace:

| Mode | Command | Where the agent's files live | How work gets out |
| --- | --- | --- | --- |
| Direct (default) | `sbx run claude <path>` | Your host folder, mounted at the same path and edited in place | Already on the host: commit or push from either side |
| Clone | `sbx run --clone claude <path>` | A private clone in the VM; the host repo is read-only at `/run/sandbox/source` | `git fetch sandbox-<name>` on the host, or the agent pushes |
| Mountless | `sbx create --name <n> claude` (no path) | Inside the VM only; the agent clones what it needs | The agent pushes; deleting the sandbox deletes the files |

This tooling automates direct mode on a folder of dedicated clones. For several repos, direct mode is the only clean option, because clone mode only clones the main folder. Doing it by hand looks like this:

```bash
TASK=~/tasks/login-fix
for r in api web; do
  src=~/dev/$r
  git clone --branch main "$(git -C $src remote get-url origin)" $TASK/$r
  git -C $TASK/$r switch -c login-fix
done

sbx run --name login-fix claude $TASK
```

Don't point `sbx` at the checkout your host stack runs from: the agent would edit that code, and a branch switch on either side affects both. Never mount a worktree, and avoid `git clone --reference` and `--shared`, which point at a host path the VM can't see.

```bash
sbx ls                       # list sandboxes, their agent and state
sbx run --name login-fix     # reattach from anywhere
sbx stop login-fix           # pause; the VM and installed packages are kept
sbx rm login-fix             # delete the VM
```

## Sources

- [Docker Sandboxes overview](https://docs.docker.com/ai/sandboxes/)
- [Get started](https://docs.docker.com/ai/sandboxes/get-started/)
- [Install](https://docs.docker.com/ai/sandboxes/install/)
- [Architecture](https://docs.docker.com/ai/sandboxes/architecture/)
- [Use Git with sandboxes](https://docs.docker.com/ai/sandboxes/workflows/git/)
- [Usage and multiple workspaces](https://docs.docker.com/ai/sandboxes/usage/)
- [Troubleshooting](https://docs.docker.com/ai/sandboxes/troubleshooting/)
