# Design notes

Why sbx-capsule works the way it does. The [README](../README.md) covers
how to use it; this file covers the reasoning behind the choices, for anyone
changing the tool or wondering why it doesn't do something simpler.

## Repo layout: why `REPOS` is a per-repo path map

Repos aren't always laid out the same way: some are top-level checkouts
under `~/dev/`, others may be cloned *inside* another repo's tree by some
other tool (a local-dev orchestrator that syncs app repos into its own
`repos/` folder, say). `REPOS` maps each name to its own path, rather than
deriving paths from one shared parent, so any mix works. If a repo moves,
update its `REPOS` path in your `.env` -- there's no path convention to
lean on instead. Explaining how your particular repos relate is a good use
of `SANDBOX_NOTES_FILE`.

The config file is plain bash (associative arrays) rather than dotenv
`KEY=VALUE` syntax because a repo needs several fields (path, start branch,
group, description), which a flat format can't hold cleanly.

## Why clones, not worktrees

Each repo in a sandbox is a full `git clone` of the matching source
checkout. Early versions of the tool used `git worktree` instead.

Agents run inside a Docker Sandbox (`sbx`) microVM that only sees the
folders mounted into it. A worktree's `.git` is a one-line file pointing
back at `<source>/.git/worktrees/<name>`, which isn't mounted, so git fails
inside the VM. Mounting the source repos' `.git` folders too would make git
work, but writably -- and a writable `.git` exposes `hooks/` and `config`,
which run commands on the host the next time you use git there: a narrow
path back out of the sandbox.

A clone carries its own `.git`, so git works in the VM with nothing else
mounted, and your source checkouts are never touched: no sandbox branches,
no config, nothing to clean up in them.

## Why clone from the local checkout, not the server

`create.sh` seeds each clone from the path in `REPOS`, not from the remote
URL: it fetches the checkout's `refs/remotes/origin/*` into an empty repo,
so history isn't downloaded again. It then points `origin` at the real
remote URL and fetches, which only transfers commits newer than the
checkout's own last fetch.

It isn't `git clone <checkout>`, which would be faster (on a large
monolith, about 0.2 s to clone) and used no extra disk, because on one
filesystem git hardlinks the checkout's object files. That's the problem:
a hardlink is the same file, so the VM, which can write everything in the
sandbox, could rewrite your checkout's history in place -- change the blob
a commit you trust points at, and the next checkout there writes the
agent's code. It also copies every object, so your unpushed local branches,
stashes and anything dangling were readable in the sandbox. A fetch from a
path copies only the objects the fetched branches reach, into files of the
clone's own, at the cost of disk (a copy of the history per sandbox) and
the time to pack it. A branch named with `WITH=repo:branch` that exists
only in the checkout is fetched too, since you asked for it.

Untracked files in the source checkout (an app's own `.env`, unrelated to
this tool's `.env`) don't come across, and neither do git hooks or
repo-local git config.

## Why not `--shared` or `--reference`

Both make the clone borrow objects from the source repo by absolute path
instead of owning them. That path isn't visible inside the VM, and `git gc`
in the source repo can delete objects the clone still depends on. They'd
also hand the VM your checkout's whole object store, the same exposure
hardlinks had.

## Start branches

After the fetch, each clone branches off `origin/<branch>`, where `<branch>`
is the one named in `WITH` (`repo:branch`) or else that repo's
`SOURCE_BRANCHES` entry. Sandboxes always start from fresh remote state,
whatever the source checkout happens to be on. A branch named in `WITH` may
also be local-only in the source checkout; it's fetched from there.

Every repo needs its own `SOURCE_BRANCHES` entry. There's no fallback
guessing, since repos' long-lived branches often differ (one on `main`,
another on `develop` or a feature trunk).

`:` can't appear in a git branch name, so `repo:branch` always splits
cleanly.

## Branch names and `PUSH_AS`

Each clone has its own branches, so names can't collide across sandboxes or
with your source checkouts.

- **With `PUSH_AS=<name>`,** every repo's local branch is `<name>`,
  tracking `origin/<name>` (set in the clone's own `.git/config`). Local and
  remote names match, so git's default `push.default` (`simple`) sends a
  bare `git push` there, creating the remote branch on first push.
- **Without it,** the branch is `sandbox/<n>/<repo>` with no upstream, so a
  bare `git push` is rejected; push with `git push -u origin HEAD:<branch>`.
- Branches are created with `--no-track`. Otherwise git's
  `branch.autoSetupMerge` default would make the branch track its start
  point (e.g. `origin/main`) -- a live wire for a bare `git push`.

**`PUSH_AS` that already exists on origin.** For each repo where
`origin/<name>` already exists, the clone branches off *it* instead of the
source branch: continuing the branch is the only way a bare push can
fast-forward it. This is announced with a yellow banner per repo (with how
far it is ahead of/behind the source branch), repeated at the end of the
run, and recorded in the sandbox's `README.md` and `AGENTS.md`. Naming a
*different* start branch for such a repo (`repo:other-branch`) is refused
before anything is created, since a push from it would be rejected; naming
the `PUSH_AS` branch itself is fine.

**`PUSH_AS` is refused** (nothing is created) when it isn't a valid branch
name, when it's a repo's source branch, or when another sandbox already
tracks `origin/<name>` for the same repo -- two sandboxes pushing to one
branch would overwrite each other. That check covers the sandboxes in
this checkout; those in a *different* checkout of this tool aren't visible
to it.

## Validate first, then act

Every command checks everything it can before changing anything, and lists
every problem at once rather than stopping at the first. A typo in `.env`
or `WITH` costs one run, not one run per typo. If cloning still fails
partway (the network drops, say), `make new` removes the half-made sandbox.

## Sandbox numbers

`make new` takes the next number after the highest existing sandbox. It
does that under a short lock (a `.new.lock` directory, since `mkdir` is
atomic and `flock` isn't on macOS), so two runs at once get different
numbers and one's cleanup can never remove the other's sandbox. The lock
holds its owner's PID, and one left by a killed run is broken. A number
whose VM still exists (its folder was removed by hand, say) is skipped with
a warning: reusing the name would reattach the new sandbox to the old VM,
with the old agent, mounts and history. `make doctor` lists such leftover
VMs, and `make prune` removes them. If two folders ever share a number, `make run/add/destroy` refuse
rather than pick one.

## The sandbox folder is untrusted on the host

The whole sandbox folder is writable from the VM, so the host-side commands
treat what's in it as data, never as code:

- **Files.** `make add` reads the sandbox's `README.md` (to record a new
  repo) only if it's a regular file, so a symlink can't point the read at a
  host file and a FIFO can't hang it. Checking a file and then opening it
  by name would leave a gap the VM could swap a symlink into, so it's
  first hard-linked into a
  `.staging.*` folder outside the sandbox (`snapshot_sandbox_file`). The
  link takes whatever is there in one step without following symlinks, and
  only the staged link is checked and read.
  The updated README is built outside the sandbox and renamed over the old
  one, so nothing is written through a symlink.
- **Git.** Every git command on a sandbox clone goes through `sandbox_git`
  (`scripts/lib/sandbox.sh`). Command-line `-c` beats any config file, and
  it uses that to switch off everything that could make git run a command:
  - `core.fsmonitor`
  - hooks, plus `GIT_OPTIONAL_LOCKS=0`, so `status` never writes the index
    and fires the post-index-change hook
  - every filter driver named in the clone's config, reset to your own
    global value (git-lfs keeps working) or to off
  - the signature programs `stash list` runs when `log.showSignature` is
    set
  - all transports, via `GIT_ALLOW_PROTOCOL=none`, since a partial clone's
    lazy fetch could reach `ext::`
  - the pager

  It also pins `--git-dir`/`--work-tree`, so `core.worktree` can't point git
  at a host folder. A filter name `-c` can't express makes it fail, and
  `destroy.sh` treats any failure as unsaved work. Submodules are checked
  one by one, each through its own `sandbox_git`.

  Filters are named by the clone's config, so `sandbox_git` has to read it
  (one git process) before running the command (another). A VM rewriting
  the config in between slips a filter through: a test that swapped it in
  a loop got one to run within a few calls. So `make destroy` stops the
  sandbox's VM before running git in its clones (`vms_running_on`), and
  refuses while any other VM can write the folder or sbx can't say. Only
  `git config`, which never runs a filter, is used while a VM may be
  running (`make add`, `make doctor`).
- **Hangs.** Without running anything, the VM can make git block forever:
  a config `include.path` of `/dev/tty`, a FIFO or `/dev/zero`, or a FIFO
  in place of `.git/config`, `HEAD` or the index. That would hang `make
  destroy`, and `make new`, `add` and `push` too, since their `PUSH_AS`
  check reads every sandbox's clones. So `sandbox_git` first takes a
  hard-link snapshot of the clone's config (never opening a FIFO or device
  in place) and refuses one that isn't a regular file or that includes
  other files, which the tool never writes. That covers the clear cases
  with a clear message. The backstop is a time limit: every git process on
  a clone, including the `upload-pack` that `make push` and `make fetch`
  run there, is stopped after 120 seconds (`run_with_timeout`, pure bash
  since macOS has no `timeout`), and a stopped one counts as a failure, so
  callers fail closed. What's left: a genuinely slow repo can hit the
  limit, which then reads as "couldn't check it", and a process git started
  itself may stay blocked in the background after the command moves on.
- **Adding a clone.** A running VM sees the sandbox live. `make add`
  therefore builds each clone in a `.staging.*` folder outside it, so the
  agent can't edit a half-made clone's config before the tool's own git
  commands (fetch, which runs `core.sshCommand`) touch it. The finished
  clone is moved in with `move_into_sandbox`, which never lets `mv` decide
  whether the destination is a folder to move into: a symlink planted
  there would send the file wherever it points. GNU `mv -T` renames onto
  the destination as it is. Without GNU mv (macOS, whose `mv -h` only
  narrows this to a race), `mv` is given the sandbox folder itself as the
  folder to move into. The VM can't replace that folder, and the rename
  replaces a symlink at the name rather than following it. Files written
  at the sandbox root (`README.md` from `make add`, `make fetch`'s
  bundles, `.vscode`) go in the same way.
- **Output.** File names and git errors from a sandbox are printed with
  control characters replaced (`safe_text`), so they can't carry terminal
  escape sequences.

Anything new that reads a sandbox from the host must keep to this.

The same boundary breaks if something other than a sandbox folder is
writable from a VM, so `make run` refuses to start one while any of these
holds (`check_host_exposure`, `scripts/lib/host_safety.sh`), and `make
doctor` reports them:

- **A VM can write this checkout**, or a folder above it (`sbx create ...
  .` run from here, say). Every `make` command sources `.env` and runs
  `scripts/`, so that VM could run anything on the host. A writable mount
  of anything *inside* the checkout counts too, unless it's a sandbox
  folder itself: `scripts/`, `.env`, `.state/` (where `PUSH_AS` and a
  sandbox's own agent are kept), `user-config/` (agent profiles and kits) or
  a sandbox's `.vscode` (mounted read-only by `make run`). Only a VM made
  by hand can have one, so this is defence in depth.
- **A VM can write a source checkout.** The tool runs plain git there
  (cloning, `ls-remote`), and so do you. A read-only mount can't change
  anything, so it isn't refused, but it lets the agent read the whole
  checkout, `.git` and untracked files included, which is why the tool
  never makes one (see below).
  A `REPOS` path inside a sandbox folder counts too.
- **sbx forwards your SSH agent while `AGENT_GIT_PUSH=no`.**
  `ssh.agentForwardingEnabled` is on by default and lets the VM sign with
  your keys, which makes "don't push" advisory. With `AGENT_GIT_PUSH=yes`
  that forwarding is how SSH pushes work, so it's allowed.

These look at every sbx VM on the machine, not only this checkout's, since
any of them could hold the mount. If sbx can't be asked, every one of
them fails closed.

## Agent profiles, `user-config/` and each sandbox's own agent

Choosing an agent per sandbox needs two things `.env` can't give: a place
for agent setups other than the default, and a record of which one a
sandbox uses that outlives edits to `.env`.

- **`user-config/` is outside every VM.** Profiles are run as bash and kit
  files decide what a VM is created with, so they live in a gitignored
  folder at the top of the checkout, next to `.env`, which no VM mounts.
  Its name can't be mistaken for a sandbox's (those start with a digit,
  `is_sandbox_name`). For the same reason, a kit, args file, env file or
  profile that resolves (through symlinks too) into a sandbox folder is
  refused before anything reads it: the VM could otherwise change what the
  next VM gets, or have a profile run on the host. Relative paths are taken
  from the checkout, never from where make was run, so a profile means the
  same thing wherever it's used.
- **A profile is a short allow-list, read in a subshell.** It's bash like
  `.env`, for the same reason (one familiar syntax), but only `AGENT`,
  `ARGS`, `CREATE_FLAGS` and `CREDENTIALS` may be set, anything else is
  named in the error, and the values come back to the caller as quoted
  data. `-e`/`--env`/`--env-file` are refused in it: what they pass, the
  agent can read. Credentials belong in sbx secrets, which the proxy adds on
  the way out, so a profile only names them.
- **The sandbox saves the profile's name, not a copy.** `.state/<n>/agent`
  (host side, like `push_as`) holds what `AGENT=` named, so later `.env`
  edits don't move the sandbox, but an edit to the profile itself does, as
  the user would expect from naming it. A checksum taken when the VM was
  created lets `make run` say when the profile changed since, so that's
  never silent. Only an explicit `AGENT=` is saved: a sandbox made without
  one keeps following `.env`, as every sandbox did before profiles.
- **Only a command-line `AGENT=` counts.** The Makefile passes it on as
  `CLI_AGENT`, and only when `$(origin AGENT)` is `command line`, so an
  `AGENT` exported in the user's shell can't pick an agent by accident.
- **A VM keeps its agent.** `sbx` fixes it at creation, so naming a
  different one for a sandbox that has a VM is refused unless `FRESH=1`
  recreates it, rather than saving a choice the VM doesn't follow.

## Pushing from the host: fetch out, never run git in the clone

With `AGENT_GIT_PUSH=no` you push, and the obvious way, `git push` in the
clone, runs git with the agent's config and hooks. `sandbox_git` can't
help: a push needs transports, credentials and hooks, exactly what it
switches off, and a blocklist of dangerous keys falls behind as git adds
more. So `make push` never opens the clone as a repository. It treats it
as a remote:

1. A bare repo in a `.staging.*` folder, borrowing the source checkout's
   objects through `objects/info/alternates` (read-only, so the source
   checkout stays untouched, and only new commits are copied).
2. `git fetch <clone> refs/heads/<branch>` into it, with only the `file`
   transport allowed and `transfer.fsckObjects` on. A fetch from a path
   runs `git upload-pack` in the clone, and upload-pack is Git's one
   command built to serve an untrusted repository: it runs no hooks, and
   ignores repo-level settings that would run commands
   (`uploadpack.packObjectsHook` is only read from your own config). The
   bare repo has no working tree, so filters never run.
3. The log and the fast-forward check run in the bare repo, under your
   config only. Commit messages are the agent's, so they're printed
   through `safe_text`.
4. The push URL comes from the source checkout's `origin`, never from the
   clone's config, which could point anywhere.

The clone's `origin/*` refs don't learn about the push, and writing them
would mean running git in the clone. So the pushed commit is recorded in
`.state/<sandbox>/pushed`, under this checkout where no VM can write
(`make run` refuses while one could), and `make destroy` adds those commits
to `--not` when counting unpushed work. A recorded commit the clone no
longer has is skipped.

The target branch is the sandbox's `PUSH_AS`, from `.state/<sandbox>/push_as`,
which `make new` writes outside the sandbox, or, without one,
`AS=<branch>`, checked like a new `PUSH_AS`. It's never read from the
sandbox: a copy there is the agent's to rewrite, and it could aim your
push at any branch but the repo's source branch (`main`, when you start
from `develop`, say) and build commits that fast-forward it, since the
clone holds every `origin/*` branch. `make add` reads the same record, for
the branch new clones track.

## Fetching from the host: a bundle the agent applies

`make fetch` is `make push` in reverse, under the same rule: git never runs
with the clone as its repository on the host. That rules out writing the
new commits into the clone from the host, whether by `git fetch` there
(the clone's config and hooks run) or by pushing into it (`receive-pack`
runs its hooks). So the host only produces a file, and the agent, in the
VM, does the git work:

1. A bare repo in `.staging.*`, borrowing the source checkout's objects
   read-only (`init_staging_repo`, shared with `make push`), fetches
   `origin`'s branches with your config and credentials. The source
   checkout isn't changed: the tool never writes to it, refs included.
2. `git ls-remote <clone>` says which commits the clone has, through
   `upload-pack`, as `make push` reads it. Those refs are the agent's: only
   well-formed names of objects the staging repo has are used, and only to
   leave commits out. A false claim makes the bundle fail to apply, which
   hurts nobody but the agent.
3. A bundle of the branches that differ from the clone's `origin/*`, with
   the commits it lacks, is built in staging, checked with `git bundle
   verify`, and moved to the sandbox root with `move_into_sandbox`. It
   only holds what's reachable from `origin`'s branches, so nothing local
   to your checkout leaks. It's written by hand (header, then
   `pack-objects --thin`) because `git bundle create` drops a branch whose
   new tip the clone already has -- `origin/<PUSH_AS>` right after `make
   push` -- and refuses a bundle with no new objects.

The bundles sit at the sandbox root, not in the clone: writing into a
`.git` folder the agent controls would mean following paths it could turn
into symlinks. `make destroy` deletes them (`FETCH_BUNDLE_GLOB`) rather
than archiving them as notes.

Mounting a mirror read-only into the VM would avoid the file, but mounts
are fixed when a VM is created.

## No read-only source mounts

Mounting a source checkout read-only into the VM, for reference, would
keep it safe from changes, but the agent could read all of it: its `.git` (unpushed branches, stashes, dangling commits)
and untracked files such as an app's `.env`. A clone covers the same need
without that: `make add` brings in any repo from `.env`, `repo:branch`
starts it from a local-only branch, and `make fetch` keeps it current. The
one thing lost is uncommitted work in your checkout; commit it to a local
branch and `make add` that.

## Editing in VS Code: inside the VM, with read-only workspace settings

VS Code opened on a sandbox from the host runs what the agent wrote: its
Git extension runs `git status` (so `core.fsmonitor`), tasks can run on
folder open, and language extensions run the sandbox's own interpreters and
plugins. Hardening each of those is a losing game, so `make code` moves VS
Code into the VM instead (Remote-SSH to `<vm>.sbx`, which `sbx setup ssh`
routes through the sbx daemon).

What's left is VS Code reaching back to the host: answering git's credential
prompts from your host's sign-ins, forwarding your SSH agent, and
forwarding the VM's ports to your `localhost`. Settings control each, but a
workspace's `.vscode/settings.json` overrides window- and resource-scoped
ones, and the agent writes the workspace. So the tool writes that file
itself and `make run` mounts the sandbox's `.vscode` read-only into the VM
(sbx keeps a read-only mount inside a writable one: writes, deletes and
renames from inside all fail). The one application-scoped setting,
`remote.SSH.enableAgentForwarding`, can only live in user settings, so
`make code` and `make doctor` check it there. `make code` also refuses a
VM without the read-only mount (one made by hand under the sandbox's name),
since its workspace settings are the agent's to change.

The `.vscode` folder must hold nothing else: VS Code would use a
`tasks.json` or `launch.json` there too, so `make run` refuses to mount
one with files it didn't write. `make destroy` removes the generated file
only from a real folder, never through a symlink.

## VM naming

`make run` names each VM `<checkout id>-<sandbox dir>`, lowercased (e.g.
`4f0c2a-3-loginfix`), or `<prefix>-<checkout id>-<sandbox dir>` when
`.env` sets `SBX_NAME_PREFIX`. The checkout id is six hex digits of a
checksum of the checkout's path, so two checkouts of this tool -- each with
its own sandbox 3 -- never share a VM, whatever their folders are called
and whatever prefix each sets. Without it, `make destroy N=3` in one
removed the other's VM, and `make run N=3` attached to it. The id is
derived, not stored: there's nothing to lose, and a copy of the checkout
(with its `.state/`) still gets its own. Moving a checkout changes the id,
but that already orphans its VMs, which mount the old paths. `sbx` rejects
underscores, so any character in the sandbox folder name other than a
letter, digit or `-` becomes `-`; the prefix is checked instead
(`check_agent_config`), since it's yours to pick.

There's no prefix by default. The tool makes, finds and removes these VMs
itself, so a name has to be unique before it has to be readable, and the
sandbox folder at its end says which one it is. A prefix is for telling
them apart from other VMs in `sbx ls`.

The name alone doesn't prove a VM is this checkout's: anyone can name a VM
anything. So every command goes by what the VM mounts as well. A sandbox's
VM (`sandbox_vm`) is one that mounts its folder and whose name ends in the
checkout id and that folder's name (`is_tool_vm_name`), preferring the
current `sbx_name`. A VM that only has the name makes `make run` refuse
rather than attach to it. `make list`, `make stop`, `make prune` and
`make doctor` list this checkout's VMs the same way (`tool_vms`): a VM
counts when its workspace is a sandbox folder directly under this checkout
and its name ends that way. The mount is what keeps checkouts apart:
another checkout's VMs mount that checkout's own folders.

Any prefix is accepted when matching, so changing `SBX_NAME_PREFIX`
orphans nothing. It only names new VMs, like a changed `AGENT`: an
existing VM keeps its name and keeps working, `make run` notes the
difference when it reattaches, and `make run N=<n> FRESH=1` recreates it
under the new name. A VM whose folder is gone is reported as left over, and only those are what
`make prune` removes. Other VMs on the machine are never listed, stopped or
removed. When one of them is in the way (`make run` refuses while a VM can
write this checkout or a source checkout, and `make destroy` while another
running VM can write the sandbox), the message names the `sbx rm` or
`sbx stop` to run rather than a make target. Such a VM was made by hand,
often from a parent folder, and may hold an agent's history or a session
in use. Removing or stopping it is your call, made with the tool you made it
with.

The VM mounts the sandbox folder at the same path ("direct mode"): the agent
edits the clones in place, and you can work on them from the host at the
same time. Mounts and the agent are fixed when the VM is created, which is
why `SBX_CREATE_FLAGS` only applies on first run, and why switching
`AGENT` means recreating the VM.

## Generated instructions: one source, thin shims

Each sandbox gets one real instructions file, `AGENTS.md`, which most agents
read directly. Claude Code and Gemini CLI don't, so they get `CLAUDE.md` and
`GEMINI.md` shims that import it with `@AGENTS.md`. All are written whatever
`AGENT` is, so any agent works in any sandbox. The sandbox's `README.md` is
for the human and holds the repo/branch detail; `AGENTS.md` points there
instead of repeating it.

What the agent should do beyond the tool's safety rules is the user's
call, so it isn't hard-coded. `AGENT_INSTRUCTIONS` in `.env` goes in a "User
instructions" section ahead of the generated rules and is marked as taking
priority over them. Committing is the main example: the generated git rule
covers only pushing (tied to `AGENT_GIT_PUSH`, which the host-safety checks
also use), and whether the agent commits on its own or waits is left to
the user's instructions.

This repo follows the same pattern for its own maintainer instructions.

## Teardown and the archive

`destroy.sh` refuses to remove anything if any repo has unsaved work:
uncommitted changes (including untracked files), stashes, commits not on
any origin branch (a detached HEAD's included), or a rebase, merge,
cherry-pick, revert or bisect in progress. The check fails closed: if git
can't read a repo, or the check dies partway, that repo counts as unsaved.
`FORCE=1` overrides. Deleting a clone deletes its commits, so the check
errs on the side of keeping.

Then it removes the sandbox's VM, the clones and exactly the files
`create.sh` generated (`GENERATED_FILES` in `scripts/lib/sandbox.sh`).
Anything else left at the sandbox root -- notes files, dotfiles -- is moved to
`.archive/<n>-<title>/` rather than deleted. Sandbox numbers are reused
once the highest is destroyed, so an existing archive dir is never merged
into; the new one gets a `-<YYYYmmdd-HHMMSS>` suffix. If any folder couldn't
be removed, the notes stay in place with it.
