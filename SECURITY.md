# Security

## Reporting a vulnerability

Please report vulnerabilities privately: on the repository's **Security**
tab, choose **Report a vulnerability** (GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately)).
Don't open a public issue or pull request for one. The form asks which
`make` command is involved, whether the attack needs the agent to write
the sandbox folder, the impact, how to reproduce it, and your OS, bash,
git and sbx versions. You should get an acknowledgement within a week.

Only the latest release is supported.

## Security model

It helps to know what this tool does and doesn't enforce:

- **Isolation comes from Docker Sandboxes (`sbx`).** When you use
  `make run`, the agent runs in an `sbx` microVM that sees only the sandbox
  folder, sends traffic through `sbx`'s
  network allow-list, and never sees API keys stored with
  `sbx secret set`. Weaknesses in that isolation are for
  [Docker](https://www.docker.com/trust/security/) to fix.
- **Some sbx defaults reach past the VM, and the tool checks them.**
  `sbx` forwards your SSH agent into every sandbox by default
  (`ssh.agentForwardingEnabled`), so with `AGENT_GIT_PUSH=no` `make run`
  refuses until you turn that off. It also refuses while any sbx VM can
  write this tool's checkout or a source checkout (at its own path or
  another), or while sbx would mount your agent's skills store writable
  (`skills.defaultMode=readwrite`). `SBX_CREATE_FLAGS` can't add folders,
  `--mount` binds or `--skills readwrite`. `make doctor` reports those,
  plus a `github` secret the agent could push with, environment variables
  passed into VMs, and sbx's `browser.enabled` and `clipboard.textCopy`.
- **The generated `AGENTS.md` rules are advisory.** "Only change this
  sandbox", "don't push", "leave running containers alone" are instructions
  to the agent. Inside the VM, `sbx` enforces most of them. If you run an
  agent directly on the host, nothing does.
- **Sandboxes are full clones, not worktrees,** so the VM never needs
  write access to a source repo's `.git` (whose hooks and config would run
  on the host). See [docs/DESIGN.md](docs/DESIGN.md#why-clones-not-worktrees).
- **The sandbox folder is shared with the host.** Anything the agent writes
  there -- including files in a clone's `.git` -- is on your host. The
  tool's own commands treat the folder as untrusted:
  - They never source or execute a file from it, and never write through
    or read from a symlink or FIFO the agent put there.
  - They run git in the clones with everything that could make it run a
    command switched off: fsmonitor, hooks, filter drivers, signature
    programs and network transports.
  - Clones added to a running sandbox are built outside it and moved in
    when finished.
  - Names from the sandbox are printed with control characters replaced.

  - `make push` never runs git in a clone: it fetches the branch out into
    a repo of its own and pushes from there, to your source checkout's
    `origin`.
  - `make code` runs VS Code inside the VM, with workspace settings the
    agent can't change (mounted read-only) keeping your credentials and
    ports out of it.

  Your own git commands on the host get no such protection: a clone's
  `.git/config`, `.git/hooks` and `.gitattributes` can make `git status`,
  `log`, `commit` or `push` run commands, and a git-aware shell prompt
  runs `git status` the moment you `cd` in. Nor do other tools that run a
  folder's project config, such as an editor opened on the host. Review
  inside the VM and push with `make push`; see
  [Reviewing and editing a sandbox](README.md#reviewing-and-editing-a-sandbox).
  `make doctor` audits each clone for config and hooks that would run on
  the host.
- **VS Code in the VM still trusts its server there.** `make code` keeps
  VS Code's own window on your host, talking to a VS Code server inside
  the VM, which the agent can modify. That's a narrower channel than
  running the agent's code on the host, but not a VM boundary: keep the
  extensions in a sandbox window few, or use a separate profile
  (`VSCODE_PROFILE`).
- **The host still runs git on what the VM wrote**, protected from
  config but not from bugs in git's own parsing. Keep git patched;
  `make doctor` notes one older than the upstream fixes for CVE-2022-23521
  and CVE-2024-32465.
- **Your `.env` is executed as bash** by every command. Treat it like a
  script: don't source one you haven't read.

### Known limitations

- **git versions are checked by number.** A distribution's backported fix
  doesn't change the version, so `make doctor` only notes a git below the
  upstream fixes above, and `make push`, `make fetch` and `make destroy`
  warn only for a release series that never got them (before 2.30 for
  CVE-2022-23521, 2.39 for CVE-2024-32465). Keeping git patched is up to
  you.
- **Hangs are cut off by a time limit, not prevented.** A FIFO or device
  the agent puts where git reads (`packed-refs`, the index) makes that git
  call wait until `SANDBOX_GIT_TIMEOUT` (120 seconds) and then fail, so
  the command fails closed but slowly. When `make push` or `make fetch` is
  stopped that way, a `git upload-pack` it started can outlive it until
  its input closes.
- **Without `PUSH_AS`, `make push AS=<branch>` checks other sandboxes'
  clones** for one already pushing to that branch. Their git config is
  their agents' to write, so that check is a warning, not a guarantee.
  Give every sandbox a `PUSH_AS` to avoid relying on it.
- **A VM sbx can't be asked about may be left behind.** If sbx fails
  while `make destroy` checks whether the sandbox's VM exists, the VM is
  left; `make prune` removes it once sbx answers.
- **`--mount` binds were checked by reading sbx's `mounts` list.** How a
  kit's `--mount` bind appears there wasn't seen with a real kit (sbx
  v0.51.0); `SBX_CREATE_FLAGS` refuses `--mount`, so only a VM made by
  hand can have one.

Issues in this tool that could let an agent affect anything outside its
sandbox, or that could lose a user's unpushed work, are in scope.
