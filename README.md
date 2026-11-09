# sbx-capsule

Disposable, multi-repo workspaces for AI coding agents, each running in its
own Docker Sandbox microVM.

`make new WITH="api web"` makes a numbered sandbox folder holding a fresh
git clone of each repo, each on its own branch. `make run N=1` starts your
coding agent of choice -- Claude Code, Codex, Gemini CLI, Copilot, Cursor and
others -- on that folder inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/)
(`sbx`) VM. When you're done, `make destroy N=1` tears it all down, refusing
if anything hasn't been pushed.

> **Status:** 1.x. The `.env` format and the make targets only change in
> backwards-compatible ways within 1.x; sandboxes, VMs and `.env` files
> from any 1.x release keep working. See the [changelog](CHANGELOG.md).

## Contents

- [Why](#why)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quickstart](#quickstart)
- [Commands](#commands)
- [Configuration: your `.env`](#configuration-your-env)
- [Choosing an agent](#choosing-an-agent)
- [Reviewing and editing a sandbox](#reviewing-and-editing-a-sandbox)
- [Letting the agent push](#letting-the-agent-push)
- [Pushing from the host](#pushing-from-the-host)
- [Fetching from the host](#fetching-from-the-host)
- [Agent instructions: `AGENT_INSTRUCTIONS`](#agent-instructions-agent_instructions)
- [Team notes: `SANDBOX_NOTES_FILE`](#team-notes-sandbox_notes_file)
- [What's in a sandbox](#whats-in-a-sandbox)
- [Troubleshooting](#troubleshooting)
- [Further reading](#further-reading)

## Why

A coding agent working on a real task often needs more than one repo -- a
backend and its frontend, a service and its shared library. You want it to:

- work on **fresh branches** of those repos, not your own checkouts that are
  mid-change or that your local stack is running from;
- be **contained**: unable to touch anything outside its workspace, reach
  your running containers, or see your credentials;
- be **disposable**: several tasks in parallel, each torn down cleanly when
  done, without losing work that hasn't been pushed.

Docker Sandboxes provide the containment: a microVM that only sees the
folders you mount, behind a network allow-list. sbx-capsule builds the
multi-repo workspace that goes in it, which `sbx` doesn't do on its own.

## How it works

```
 your source checkouts             sandbox 3  (./3-login-fix/)              sbx microVM
 ---------------------             ---------------------------              -----------
 ~/dev/api  ──clone (copied)──────▶ api/   branch fix/login                 
 ~/dev/web  ──clone (copied)──────▶ web/   branch fix/login   ──mounted──▶  your agent
                                    README.md   for you                     (claude, codex, ...)
                                    AGENTS.md   rules for the agent
                                    CLAUDE.md, GEMINI.md → AGENTS.md
```

- Each repo is a **full git clone**, seeded from your local checkout's copy
  of `origin`'s branches, so history isn't downloaded again. Those objects
  are copied, not hardlinked, so nothing in the sandbox shares a file with
  your checkout, and your unpushed branches and stashes don't come across.
  Then it fetches from the real `origin` and branches off fresh remote
  state. Your source checkouts are never modified.
- The sandbox folder is **mounted into the VM at the same path**, so the
  agent edits the clones in place and you can look at (or work on) them
  from the host at the same time.
- Each sandbox gets a **generated `AGENTS.md`** telling the agent where it
  is, what it may touch and how to handle git, plus shims so every agent
  finds it.

The reasoning behind these choices (why clones and not worktrees, why clone
from the local checkout, and so on) is in [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- **bash 4+** (the config uses associative arrays). macOS ships bash 3.2,
  so `brew install bash` there.
- **git 2.23+** and **make**. Keep git patched: the host runs it on clones
  the VM wrote, so `make doctor` notes a git older than the upstream fixes
  for CVE-2022-23521 and CVE-2024-32465 (2.45.1, or the matching 2.39-2.44
  patch release).
- **Docker Sandboxes (`sbx`)**, for `make run`. Supported hosts are macOS,
  Windows 11 and Ubuntu 24.04+; WSL2 works with `/dev/kvm` available. Setup
  steps are in [docs/DOCKER_SANDBOXES.md](docs/DOCKER_SANDBOXES.md#setup).
  `make new`, `add` and `destroy` work without it, if you'd rather run the
  agent on the host.
- **macOS hasn't been tested yet.** The tool is written for it (bash 4
  from Homebrew, BSD tools), and CI runs `make test` there with a fake
  `sbx`, but neither that nor `make run` and `make code` against a real sbx
  VM had been run on a Mac when 1.0.0 was released.
- **On Windows, run it inside WSL2** (VS Code on the Windows side works).
  Git Bash, MSYS and Cygwin aren't supported, and the tool refuses to run
  from them.
- Local checkouts of the repos you want in sandboxes, each with an `origin`
  remote.

Nothing here is installed for you, since `sbx` setup needs `sudo` and
differs per platform. But `make doctor` checks all of it and tells you how
to fix whatever is missing.

## Quickstart

From nothing to a first sandbox. Steps 1 and 2 are once per machine; 3 and
4 are per task. The rest of what you need is under
[Requirements](#requirements).

**1. Install and set up Docker Sandboxes (`sbx`).**

Refer to [Docker's install guide](https://docs.docker.com/ai/sandboxes/install/)
for up-to-date installation instructions. Then:

```sh
sbx login
sbx policy init balanced           # allow-list network policy

# You push, not the agent, so keep your SSH keys out of its VM.
# sbx forwards them by default, and make run refuses until this is off
# (see "Letting the agent push").
sbx settings set ssh.agentForwardingEnabled false
sbx daemon restart
```

**2. Get the tool and describe your repos.**

```sh
git clone <this repo> ~/dev/sbx-capsule
cd ~/dev/sbx-capsule
make init                          # creates .env, checks your tools (installs nothing)
$EDITOR .env                       # your repos, as below
make doctor                        # checks everything, repos included; fix what it flags
```

At minimum, `.env` names each repo's local checkout and the branch
sandboxes start from (more in [Configuration](#configuration-your-env)):

```bash
declare -A REPOS=(
  [api]="$HOME/dev/api"
  [web]="$HOME/dev/web"
)
declare -A SOURCE_BRANCHES=(
  [api]="main"
  [web]="develop"
)
```

**3. Make a sandbox and start the agent on it.**

```sh
make new WITH="api web" TITLE=login-fix PUSH_AS=fix/login   # prints the sandbox's number
make run N=1                       # the agent, in the sandbox's VM; run again to reattach
```

The first `make run` for an agent pulls its image (a couple of minutes for
Claude); later VMs start in seconds. Sign the agent in once and every new
sandbox inherits it: `/login` inside the VM for Claude, `sbx secret set
<service>` on the host for most others (see
[Choosing an agent](#choosing-an-agent)).

**4. Review, push, tear down.**

```sh
make code N=1                      # VS Code running inside the VM (one-time setup below)
make push N=1 REPO="api web"       # shows the commits, asks, pushes to fix/login
make destroy N=1                   # refuses if any repo has unsaved work
```

Review inside the VM, never with git or an editor on the host: `make code`
needs [a one-time setup](#one-time-setup-for-make-code), or use a shell in
the VM (see [Reviewing and editing a sandbox](#reviewing-and-editing-a-sandbox)).
To have the agent push instead, see
[Letting the agent push](#letting-the-agent-push).

## Commands

```sh
make init                                      # first time: create .env, check tools
make doctor                                    # check tools, sbx, .env and repos
make new WITH="repo repo:branch ..." [TITLE=name] [PUSH_AS=branch]   # or EMPTY=1: no repos yet
make run N=<n> [ARGS="..."] [FRESH=1]          # the agent in a Docker Sandbox VM
make code N=<n>                                # VS Code, running inside that VM
make stop N=<n>                                # stop its VM, keeping its state (ALL=1: every VM)
make prune [YES=1]                             # remove VMs whose sandbox folder is gone
make add N=<n> REPO="repo repo:branch ..."     # clone more repos into a sandbox
make push N=<n> REPO="repo ..." [AS=branch]    # push clones' branches from the host, safely
make fetch N=<n> [REPO="repo ..."]             # hand origin's new commits to the agent, safely
make destroy N=<n> [FORCE=1]
make list
make help
```

| Command | What it does |
| --- | --- |
| `make init` | Copies `.env.example` to `.env` if you don't have one, then checks your tools. Never overwrites an existing `.env`. |
| `make doctor` | Read-only check of everything the tool needs, listing every problem with how to fix it: bash, git and make versions; `sbx` installed and healthy (via `sbx diagnose`: virtualization, sign-in, network policy); your `.env`; each repo's checkout, `origin` and start branch; whether the VM can reach each repo's git host; and host safety: no sbx VM can write this checkout (outside its sandbox folders) or a source checkout, sbx doesn't forward your SSH agent while `AGENT_GIT_PUSH=no`, `.env` isn't writable by others, plus notes on secrets and settings that widen what a VM can reach; and each sandbox clone's git config and hooks, for anything that would run on the host if git there used it. |
| `make new` | Creates the next numbered sandbox (`<n>/`, or `<n>-<TITLE>/`) with a clone of each repo. With no repos to clone, or with `EMPTY=1`, the sandbox starts empty, for `make add` to fill. |
| `make run` | Starts `AGENT` in the sandbox's VM, creating the VM on first use and reattaching after. `ARGS` are extra arguments for the agent. `FRESH=1` removes the sandbox's VM first and creates a new one from your current `.env`, to pick up a changed `AGENT` or `SBX_CREATE_FLAGS`: the sandbox's files stay, the agent's history inside the VM goes. Refuses to start while any sbx VM can write this checkout (outside its sandbox folders) or a source checkout, or while sbx forwards your SSH agent with `AGENT_GIT_PUSH=no` or mounts your agent's skills store writable (`skills.defaultMode=readwrite`) (see Troubleshooting). |
| `make code` | Opens the sandbox in VS Code, with VS Code itself (Git, terminals, extensions) running inside its VM, so nothing the agent wrote runs on your host. Needs the VM (`make run` first) and a one-time setup -- see [Reviewing and editing a sandbox](#reviewing-and-editing-a-sandbox). Refuses, listing why, if VS Code or SSH would pass your credentials into the VM. |
| `make stop` | Stops a sandbox's VM without removing it. The agent's history and settings inside the VM are kept, and `make run` starts it again. `ALL=1` stops every running VM this checkout made. The sandbox's files are on the host, so they're never affected. |
| `make prune` | Removes the VMs left over from sandboxes that are gone (a sandbox folder removed by hand, or destroyed while `sbx` wasn't installed), so `make new` can use their numbers again. Lists them and asks once; `YES=1` skips the question. Only ever this checkout's VMs, never other `sbx` VMs on the machine. |
| `make add` | Clones more repos into an existing sandbox, the same way `make new` would. Shows up in a running VM immediately. |
| `make push` | Pushes each named clone's branch to its repo's `origin` from the host, without running git in the clone: fetches it out, shows the commits, asks, then pushes. To `PUSH_AS`, or `AS=<branch>` if the sandbox has none. Never force-pushes or pushes to a source branch. See [Pushing from the host](#pushing-from-the-host). |
| `make fetch` | Fetches what's new on each clone's `origin` from the host, with your credentials, and leaves it in the sandbox as `.fetch-<repo>.bundle` for the agent to apply inside the VM. Never runs git in the clone, and the VM needs no network access. Every clone in the sandbox unless `REPO` names some. See [Fetching from the host](#fetching-from-the-host). |
| `make destroy` | Stops the VM, checks the clones, then removes the VM, the clones and the generated files, and archives any notes. Refuses if any repo has uncommitted changes, stashes, unpushed commits (a detached HEAD's included), a rebase or merge in progress, or can't be read by git, unless `FORCE=1`. |
| `make list` | Lists your sandboxes with their repos and the state of each one's VM (running, stopped, or none yet), plus any VMs left over from sandboxes that are gone. Shows only VMs this checkout made, never other `sbx` VMs on the machine. |
| `make test` | For working on the tool itself: checks every script parses, runs `shellcheck` if installed, then the test suite in scratch copies with a fake `sbx`. Never touches your `.env`, sandboxes or VMs. See [CONTRIBUTING.md](CONTRIBUTING.md). |

**`WITH` and `REPO` syntax.** A space-separated list of repo names from your
`.env`. Add `:<branch>` to start that repo from a different branch than its
`SOURCE_BRANCHES` entry -- on origin, or a local-only branch in the source
checkout: `WITH="api web:feat/login"`.

**Which repos `make new` includes.** The `WITH` repos in the order given,
then any `DEFAULT_REPOS` not already named. Naming a default repo in `WITH`
is fine: it's included once, from `WITH`'s branch if one is given. With
neither, `make new` makes an empty sandbox, and `make add` clones repos
into it later. `EMPTY=1` does the same when you have `DEFAULT_REPOS`: it
skips them (and can't be combined with `WITH`).

**`PUSH_AS=<branch>`** names the branch every repo in the sandbox works on,
tracking `origin/<branch>`, so a bare `git push` just works. Without it,
each repo is on `sandbox/<n>/<repo>` with no upstream. If `origin/<branch>`
already exists, the sandbox continues it (with a loud banner saying so).
Full rules: [docs/DESIGN.md](docs/DESIGN.md#branch-names-and-push_as).

**Sandbox numbers.** `make new` takes the next number up, under a lock, so
several runs at once get different numbers. It skips a number whose sbx VM
is still around (left by a sandbox removed by hand), with a warning;
`make prune` removes such VMs.

**Everything is checked before anything is created**, and every problem is
listed together: unknown repos, malformed `repo:branch` specs, start
branches that don't exist, source checkouts that are missing or have no
`origin`, and an unusable `PUSH_AS` (invalid, a source branch, or already
used by another sandbox). If cloning still fails partway, the half-made
sandbox is removed.

## Configuration: your `.env`

Every user describes their own repos in `.env` (gitignored), and every
command refuses to run until it's valid. The tool's own defaults are in
`.env.default`, which is tracked and read first; your `.env` is read after it
and can override any of them. Leave `.env.default` as it is, so pulling
updates never conflicts with your settings.

[`.env.example`](.env.example) documents each field. In short:

| Variable | Required | Meaning |
| --- | --- | --- |
| `REPOS[name]=path` | yes | Your local source checkout for each repo; `name` is your own short key |
| `SOURCE_BRANCHES[name]=branch` | yes, for every repo | The branch sandboxes start from (fetched fresh from origin) |
| `DEFAULT_REPOS=(name ...)` | no | Repos included in every `make new`; empty means only what `WITH` names |
| `REPO_GROUP[name]`, `REPO_DESC[name]` | no | Only used to group and describe repos in each sandbox's README |
| `AGENT` | no (default `claude`) | The coding agent new sandbox VMs run -- see [Choosing an agent](#choosing-an-agent) |
| `AGENT_ARGS[agent]` | no (default none) | Default arguments for that agent, on every `make run` |
| `SBX_CREATE_FLAGS` | no (default none) | Extra `sbx run` flags used when a VM is created (`--cpus`, `--memory`, `-t`, `--kit`, `-p`, ...) |
| `SBX_NAME_PREFIX` | no (default none) | Put in front of new VMs' names: `<prefix>-<checkout id>-<sandbox>` instead of `<checkout id>-<sandbox>`. Lowercase letters, digits and `-`. Existing VMs keep their names; `make run N=<n> FRESH=1` renames one |
| `AGENT_GIT_PUSH` | no (default `no`) | `yes` lets the agent push its branch -- see [Letting the agent push](#letting-the-agent-push) |
| `AGENT_INSTRUCTIONS=("text" ...)` | no (default none) | Your own instructions, written at the top of every new sandbox's `AGENTS.md` with priority over the tool's rules -- including whether the agent commits. See [Agent instructions](#agent-instructions-agent_instructions) |
| `SANDBOX_NOTES_FILE` | no (default none) | A markdown file copied into every new sandbox's `AGENTS.md` -- see [Team notes](#team-notes-sandbox_notes_file) |
| `VSCODE_CMD` | no (default: found) | The command `make code` opens VS Code with: empty finds it (on WSL, Windows' VS Code; elsewhere `code`); set `code-insiders` or `cursor` for those |
| `VSCODE_PROFILE` | no (default: the default profile) | A VS Code profile to open sandboxes in -- see [Reviewing and editing a sandbox](#reviewing-and-editing-a-sandbox) |
| `VSCODE_USER_DIR` | no (default: found) | The folder holding your VS Code user `settings.json`, which `make doctor` and `make code` check |

The file is **plain bash** (associative arrays), not dotenv `KEY=VALUE`
syntax, because a repo needs several fields. A minimal one:

```bash
declare -A REPOS=(
  [api]="$HOME/dev/api"
  [web]="$HOME/dev/web"
)
declare -A SOURCE_BRANCHES=(
  [api]="main"
  [web]="develop"
)
```

Every command validates it first and lists every problem at once: a repo
with no `SOURCE_BRANCHES` entry, a `DEFAULT_REPOS` name that isn't in
`REPOS`, an invalid repo name, an unknown `AGENT` or `AGENT_ARGS` key, an
`SBX_CREATE_FLAGS` flag the tool manages itself, an `SBX_NAME_PREFIX` sbx
wouldn't accept, a blank `AGENT_INSTRUCTIONS` entry, or a missing
`SANDBOX_NOTES_FILE`.

## Choosing an agent

Set `AGENT` in `.env` to any agent `sbx` has built in -- `claude`, `codex`,
`copilot`, `cursor`, `devin`, `docker-agent`, `droid`, `gemini`, `kiro`,
`opencode`, or `shell` (a plain shell) -- or to an sbx kit reference (a
local path, git URL or OCI ref, for a custom agent image). It defaults to
`claude`.

- **Fixed per VM.** `sbx` sets a VM's agent when it's created, so changing
  `AGENT` only affects VMs created afterwards. `make run` on an existing VM
  always reattaches to the agent it was made with, and warns if that's no
  longer `AGENT`. To switch a sandbox: `make run N=<n> FRESH=1` recreates
  its VM (the clones are on the host, so nothing in them is lost; the
  agent's history inside the old VM is).
- **`AGENT_ARGS[agent]="..."`** -- default arguments for that agent (say
  `--model ...`), passed on every `make run`, before any `ARGS="..."` from
  the command line. Set one entry without redeclaring the map:
  `AGENT_ARGS[codex]="--model ..."`. Keyed by agent so switching `AGENT`
  doesn't carry the wrong flags over.
- **`SBX_CREATE_FLAGS="..."`** -- anything else `sbx run` accepts at
  creation: `--cpus 8 --memory 8g`, `-t <template>`, `--kit <mixin>`,
  `-p 3000`, `--env-file <file>`, ... (see `sbx run --help`). Flags only:
  a value goes after its flag (`--cpus 8` or `--cpus=8`), and any other
  word is refused, since `sbx` would mount it as another folder. `--name`,
  `--clone`, `--cloud`, `--detach` and `--rm` are refused, since the tool
  manages those itself, and so are `--mount` and `--skills readwrite`,
  which reach into the host.
- **Instructions.** Every sandbox gets `AGENTS.md`, which codex, copilot,
  cursor, opencode, droid, devin and kiro read directly, plus `CLAUDE.md`
  and `GEMINI.md` shims that import it for Claude Code and Gemini CLI. For
  other agents (`docker-agent`, a kit), point them at `AGENTS.md`.
- **Signing in.** Once per agent, not per sandbox. Claude: `/login` inside
  any sandbox VM, which carries over to new ones. Most others take an API
  key held by the sbx proxy, never exposed inside the VM:
  `sbx secret set openai` (codex), `sbx secret set google` (gemini), and so
  on (`sbx secret set --help` lists the services).

## Reviewing and editing a sandbox

A sandbox's files are on your host, but the agent wrote all of them,
including each clone's `.git/config` and hooks and any editor config. Git,
a git-aware shell prompt or an editor opened on them from the host would
run what's there as you (see [Pushing from the host](#pushing-from-the-host)).
So look at a sandbox from inside its VM, where all of that only reaches the
VM:

- **VS Code: `make code N=<n>`** opens the sandbox in VS Code running
  inside its VM, over Remote-SSH. Git, terminals, extensions and language
  servers all run there. Needs the one-time setup below. VS Code installed
  as a Flatpak isn't supported (Remote-SSH inside it can't run `sbx` on the
  host), and `make code` refuses it: use Microsoft's .deb, .rpm or tarball.
- **A terminal: `sbx exec -it <vm> bash`** (the VM name is in `make list`),
  or `ssh <vm>.sbx` after `sbx setup ssh`. Review, commit and rebase there.
  On the host, an editor that reads no project config, such as `nano`, is
  fine; `cd` into a clone with a git-aware prompt is not, since the prompt
  runs `git status` there.

To push the result from the host, use `make push` (see
[Pushing from the host](#pushing-from-the-host)), which never runs git in
the clone.

Never attach an editor or shell to a VM made by hand with `sbx create ...
.` from this checkout or a folder above it: that VM can rewrite the tool
itself, and `make run` refuses while one exists.

### One-time setup for `make code`

1. Install VS Code's Remote-SSH extension (`ms-vscode-remote.remote-ssh`).
2. Run `sbx setup ssh` once (experimental in sbx v0.50.1). It adds a
   `Host *.sbx` block to `~/.ssh/config` that connects through `sbx`, with
   no SSH key: your Docker login authenticates you.
3. In your VS Code **user** settings (Command Palette: **Preferences: Open
   User Settings (JSON)**), add:

   ```json
   "remote.SSH.enableAgentForwarding": false
   ```

   Otherwise Remote-SSH hands the VM your SSH agent. Only user settings can
   set this one, and it applies to every profile. The other settings that
   matter are set per sandbox (next section).
4. **Windows with sbx inside WSL only:** Remote-SSH uses Windows' own
   `ssh.exe` and `%USERPROFILE%\.ssh\config`, even when VS Code is started
   from WSL. That config needs its own `*.sbx` block, handing the connection
   to `sbx` in WSL. From the WSL shell:

   ```sh
   win_home="$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")"
   mkdir -p "$win_home/.ssh"
   [ -f "$win_home/.ssh/config" ] && cp "$win_home/.ssh/config" "$win_home/.ssh/config.bak"
   cp ~/.config/sandboxes/sandboxes/ssh/known_hosts "$win_home/.ssh/sbx_known_hosts"
   cat >> "$win_home/.ssh/config" <<EOF

   # Docker Sandboxes: sbx runs in WSL ($WSL_DISTRO_NAME); mirrors the block sbx setup ssh wrote there.
   Host *.sbx
       User _default_user_
       ProxyCommand C:\\Windows\\System32\\wsl.exe -d $WSL_DISTRO_NAME -e $(command -v sbx) ssh proxy %n
       IdentityAgent none
       IdentitiesOnly yes
       PubkeyAuthentication no
       ForwardAgent no
       UserKnownHostsFile ~/.ssh/sbx_known_hosts
       StrictHostKeyChecking yes
   EOF
   ```

   Test it with Windows' client: `/mnt/c/Windows/System32/OpenSSH/ssh.exe
   <vm>.sbx hostname` prints the VM's name (and starts the VM if it's
   stopped). `Permission denied`: delete the `PubkeyAuthentication no`
   line. `Host key verification failed`: copy `known_hosts` again, as
   above. Windows OpenSSH 8.5 or newer is needed (Windows 11 has 9.5).
5. **macOS only:** in VS Code, run **Shell Command: Install 'code' command
   in PATH** from the Command Palette, so `make code` can start VS Code.
   Docker's docs also recommend adding this to your user settings, to
   avoid a Remote-SSH reconnect loop:

   ```json
   "remote.SSH.useLocalServer": false
   ```

   `make code` on macOS hasn't been tested against a real sbx VM yet (see
   [Requirements](#requirements)).
6. Run `make doctor`. Its "VS Code (make code)" section checks all of the
   above.

To undo: `sbx setup ssh remove`; on Windows, restore `config.bak` (or
delete the `*.sbx` block) and delete `sbx_known_hosts`.

### What keeps your credentials out of the VM

VS Code can answer git's credential prompts inside the VM from your host
(its own sign-ins, and the GitHub extension's), and forwards ports it sees
opened there to your `localhost`. Each sandbox's `.vscode/settings.json`,
which the tool writes, switches that off for that sandbox's window:

```json
"git.terminalAuthentication": false,
"git.useIntegratedAskPass": false,
"github.gitAuthentication": false,
"remote.autoForwardPorts": false
```

A workspace's own settings could switch these back on, so `make run` mounts
the sandbox's `.vscode` folder read-only into the VM, where the agent can't
change it. `make code` refuses a VM without that mount (one made by hand);
`make run N=<n> FRESH=1` recreates it (the sandbox's files stay; the
agent's history inside the VM goes). If VS Code asks whether to
trust the folder, trusting it is fine: it's the VM's copy that runs.

These settings apply only to sandbox windows, so your other VS Code work is
unaffected. For full separation, use a dedicated VS Code profile with few
extensions: create it (**Profiles: New Profile**, e.g. `sbx`) and set
`VSCODE_PROFILE="sbx"` in `.env`, and `make code` opens sandboxes in it.
`VSCODE_CMD` and `VSCODE_USER_DIR` cover Insiders, Cursor and non-standard
installs.

### If you open a sandbox in a local window anyway

Choose **Don't Trust**: Restricted Mode keeps the Git extension, tasks and
most extensions off. Trust is inherited, so don't trust this tool's
checkout or any folder above it (check **Workspaces: Manage Workspace
Trust**), and never set `security.workspace.trust.enabled` to `false`;
`make doctor` flags that.

## Letting the agent push

By default (`AGENT_GIT_PUSH=no`) the generated `AGENTS.md` tells the agent
never to push (whether it commits is up to your
[`AGENT_INSTRUCTIONS`](#agent-instructions-agent_instructions)); you review and push from the host, where your
credentials and network already work. That's also the right choice when your
git server isn't reachable from the VM at all (a private host behind a VPN,
say).

`AGENT_GIT_PUSH=yes` tells the agent it may push its own branch (never
force-push, never a source branch). For that to actually work:

- the git host must be on the sbx network allow-list, **on the port your
  remote uses**. The default `balanced` policy allows GitHub over HTTPS
  (443) but not SSH (22), and no private git servers. `sbx policy allow
  network <host>` opens a host on every port. `make doctor` checks each
  repo's host;
- credentials: for SSH remotes, your SSH agent is forwarded into the VM
  (sbx's `ssh.agentForwardingEnabled`, on by default); for HTTPS GitHub,
  `sbx secret set github`.

With `AGENT_GIT_PUSH=no`, "don't push" is only an instruction unless those
credentials stay out of the VM too. `make run` therefore refuses to start
while sbx forwards your SSH agent (turn it off with
`sbx settings set ssh.agentForwardingEnabled false`, then
`sbx daemon restart`), and `make doctor` notes a stored `github` secret.

The setting is written into each sandbox's `AGENTS.md` and `README.md` when
it's created; changing it later doesn't update existing sandboxes.

## Pushing from the host

**Use `make push`.** It pushes a clone's branch without ever running git
with the clone as its repository:

```sh
make push N=3 REPO="api web"            # to the sandbox's PUSH_AS branch
make push N=3 REPO=api AS=fix-login     # sandbox without PUSH_AS: name the remote branch
```

Per repo, it fetches the branch out of the clone into a temporary repo
outside the sandbox (git serves a fetch through `upload-pack`, which runs
none of the clone's hooks or command-running config), shows you the
commits going out, asks, and pushes to the `origin` of your **source
checkout**, with your credentials. It never force-pushes, never pushes to
a repo's source branch, and refuses a push that wouldn't fast-forward
(rebase inside the VM first). `YES=1` skips the question. `make destroy`
counts what it pushed as saved, though the clone's own `origin/*` refs
only learn about it when they next fetch.

The branch it pushes to is the `PUSH_AS` that `make new` recorded outside
the sandbox, in `.state/`, never one the agent can change. A sandbox made
before that record existed asks you to name it once with `AS=<branch>`,
then remembers it.

**Why not plain `git push` in the clone?** Its `.git` was writable from
the VM, so its config and hooks are the agent's to set, and plenty of
them make git run commands as you:

| You run | What the agent can make it run |
| --- | --- |
| `cd` into it with a git-aware prompt, or open it in an editor | `core.fsmonitor` (on `git status`), filter drivers |
| `git log` | `core.pager`; `gpg.program` when `log.showSignature` is set |
| `git diff`, `git show` | `diff.external`, `textconv` drivers chosen by `.gitattributes` |
| `git commit` | hooks, `core.editor`, `gpg.program` |
| `git push` | hooks, `core.sshCommand`, credential helpers, `protocol.*.allow` |
| `git push` | `remote.origin.pushurl` or `url.*.insteadOf`: your code and credentials go to someone else's repo, and nothing visibly runs |

`core.hooksPath` can move hooks out of `.git/hooks`, and `include.path`
can load any of this from a harmless-looking file that
`git config --local --list` doesn't expand. `make doctor` audits every
clone for these and lists what it finds, but the safe habit is not to
run git there at all: review inside the VM (`make code`, or a shell in
it) and push with `make push`.

The same goes for other tools you point at a sandbox from the host. An
editor or agent that runs project config on open, such as Claude Code's
`.claude/settings.json` hooks, VS Code tasks, or direnv's `.envrc`, would run
whatever the agent wrote there. Building or running the agent's code on the
host is the same trust decision as merging it.

## Fetching from the host

The clones hold every `origin/*` branch as of when they were made, so the
agent can read, diff and rebase onto those without any network. For newer
commits it would need the git host on the sbx allow-list and your
credentials in the VM, which `AGENT_GIT_PUSH=no` keeps out (they'd let it
push too). **Use `make fetch`** instead:

```sh
make fetch N=3                # every clone in sandbox 3
make fetch N=3 REPO=api       # just api
```

Per repo, it fetches `origin`'s branches into a temporary repo outside the
sandbox, with your config and credentials, and lists what changed on each
(new, fast-forwarded, or rewritten). Then it writes what the clone doesn't
have yet, and nothing from your source checkout's local branches or stashes,
into `.fetch-<repo>.bundle` at the sandbox root. The agent applies it inside
the VM, which updates its `origin/*` and nothing else:

```sh
git -C api fetch ../.fetch-api.bundle '+refs/remotes/origin/*:refs/remotes/origin/*'
```

then rebases or merges as you agree. Each sandbox's `AGENTS.md` tells the
agent to ask you for this. Like `make push`, it never runs git in the
clone: it reads which commits the clone already has through `git
ls-remote`, which runs `upload-pack` there. Tags aren't included, and
branches deleted on origin stay in the clone. `make destroy` deletes the
bundles.

## Agent instructions: `AGENT_INSTRUCTIONS`

Your own rules for the agent, as a list of plain-text strings in `.env`.
They're written near the top of every new sandbox's `AGENTS.md`, under
"User instructions", ahead of the tool's generated rules, and that section
tells the agent they take priority where the two conflict.

The tool doesn't tell the agent whether to commit, so that's the first
thing to say here:

```bash
AGENT_INSTRUCTIONS=(
  "Don't commit. Leave your changes uncommitted until I've reviewed them and ask you to commit."
  # or: "Commit your work as you go, in small commits with clear messages."
  "Run the repo's tests before saying a change is done."
)
```

Each string becomes one bullet, written exactly as given (nothing in it is
expanded when the sandbox is created). Later lines of a multi-line string
stay inside its bullet. Like team notes, it's a snapshot: edits apply to
sandboxes created afterwards. Instructions are requests; the limits `sbx`
enforces (what the VM can see and reach) apply whatever they say.

## Team notes: `SANDBOX_NOTES_FILE`

Anything specific to your team or machine -- how your repos relate, local
stacks running on the host that the agent must leave alone, branch
conventions -- goes in a markdown file you keep outside this repo. Point
`SANDBOX_NOTES_FILE` at it and its contents are copied into every new
sandbox's `AGENTS.md` under "Team notes". It's a snapshot: edits apply to
sandboxes created afterwards.

## What's in a sandbox

```
3-login-fix/
├── api/            full clone, on its sandbox branch
├── web/            full clone, on its sandbox branch
├── README.md       for you: repos, branches, how to run/add/destroy, push behaviour
├── AGENTS.md       for the agent: your instructions, where it runs, what it may touch, push rules, team notes
├── CLAUDE.md       imports AGENTS.md (Claude Code)
├── GEMINI.md       imports AGENTS.md (Gemini CLI)
├── .fetch-api.bundle   new commits from origin, from make fetch, for the agent to apply
└── .vscode/        settings.json for make code; read-only inside the VM
```

`AGENTS.md` starts with your `AGENT_INSTRUCTIONS`, if any. The tool's own
rules after them tell the agent to change code only in this
sandbox's clones, leave running containers alone, follow your
`AGENT_GIT_PUSH` setting, never force-push, and ask you to run `make add`
when it needs another repo (it can't see your source checkouts from inside
the VM). Inside the VM, `sbx` turns most of those rules from requests into
enforced limits.

Agents are also asked to keep notes and plans as `<KIND>-<topic>.md` files
at the sandbox root. On `make destroy`, anything at the root that the tool
didn't generate is moved to `.archive/<n>-<title>/` instead of being
deleted.

## Troubleshooting

**Start with `make doctor`.** It checks the usual suspects below and says
how to fix each.

**`make run` refuses: sbx forwards your SSH agent.** With
`AGENT_GIT_PUSH=no`, the agent mustn't be able to sign with your SSH keys:
`sbx settings set ssh.agentForwardingEnabled false`, then
`sbx daemon restart`. Or, if the agent should push, set
`AGENT_GIT_PUSH=yes` (see "Letting the agent push").

**`make run` refuses: sbx mounts your agent's skills store writable.**
With `skills.defaultMode=readwrite`, the agent could write skills your
agent on the host then runs: `sbx settings set skills.defaultMode
readonly`, or add `--skills readonly` to `SBX_CREATE_FLAGS`.

**`make run` refuses: a VM can write this checkout or a source checkout.**
Usually a VM made by hand with `sbx create ... .` or `sbx run` from a
parent folder, or one that mounts a folder inside this checkout other than
a sandbox folder, at its own path or another (`PATH:TARGET`). Remove it with `sbx rm <vm>` (the name is in the message).
To give the agent another repo to read, clone it into the sandbox:
`make add N=<n> REPO=<repo>`.

**I changed `AGENT` or `SBX_CREATE_FLAGS` but `make run` still uses the
old one.** Both are fixed when a VM is created. `make run N=<n> FRESH=1`
removes the VM and creates it again; the sandbox's files stay.

**The agent can't fetch or push.** Your git host probably isn't on the sbx
network allow-list. `sbx policy allow network <host>`, or leave
`AGENT_GIT_PUSH=no` and push from the host with `make push`.

**`make push` says origin has commits the clone doesn't, or would be
overwritten.** The remote branch moved on, or the agent rewrote history
that was already pushed. Fetch and rebase inside the VM (if it can reach
origin), then push again. `make push` never force-pushes.

**`make destroy` refuses.** A repo has uncommitted changes, stashes,
commits not on any origin branch, or a rebase or merge in progress, or git
couldn't read it (often files the VM left owned by root); the message lists
which. Push, finish or discard them, or use `FORCE=1` if you really mean to
delete them. `make destroy` stops the sandbox's VM before checking, so the
agent can't change a clone mid-check; `make run` starts it again. It
refuses outright while another running VM can write the sandbox folder,
or when sbx doesn't answer.

**`make new` skips a number, or `make doctor` notes a leftover VM.** A
sandbox folder was removed without `make destroy`, or destroyed while `sbx`
wasn't installed, and its VM is still there. `make prune` removes it, and
any other VMs this checkout left over.

**Claude refuses to start in a sandbox under `/tmp`.** Don't keep this repo
(and so its sandboxes) under `/tmp/claude-<uid>`; the VM creates parent
folders there as root. Anywhere under your home directory is fine.

More `sbx` behaviour worth knowing is in
[docs/DOCKER_SANDBOXES.md](docs/DOCKER_SANDBOXES.md#sbx-behaviour-worth-knowing).

## Further reading

- [docs/DOCKER_SANDBOXES.md](docs/DOCKER_SANDBOXES.md) -- setting up `sbx`,
  how it and this tool fit together, and `sbx` quirks.
- [docs/DESIGN.md](docs/DESIGN.md) -- why the tool works the way it does.
- [CHANGELOG.md](CHANGELOG.md) -- release notes.

**AI agents working on this repo:** start with [AGENTS.md](AGENTS.md).

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md),
and [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

[MIT](LICENSE)
