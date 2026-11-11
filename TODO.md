# TODO

Planned work for sbx-capsule, most important first within each section.

- One item per change, as a checkbox with a short imperative title. Under it:
  why it matters, and what "done" looks like.
- When an item ships, delete it here and add a line to
  [CHANGELOG.md](CHANGELOG.md). Done items don't stay in this file.
- Bugs and security issues go in the issue tracker (security ones privately,
  see [SECURITY.md](SECURITY.md)), not here.

## Next

- [ ] **Confirm `make run` and `make code` with sbx on macOS**
  - Why: there's been no Mac with sbx to try them on. The read-only
    `.vscode` mount inside a writable workspace was only checked with sbx
    on Linux (WSL2), and `remote.SSH.useLocalServer` is Docker's advice,
    not something seen here.
  - Done when: on a Mac with sbx, `make run` starts a VM, writes to
    `.vscode` from inside it fail, and `make code` connects; the README's
    "haven't been tested" line is removed.

- [ ] **Decide whether `make code` should open an existing VM whose saved agent is invalid**
  - Why: `code.sh` calls `choose_agent` every time, so `make code` on a
    sandbox with a VM now refuses when its saved agent no longer resolves
    (a profile in `.state/<n>/agent` whose file was deleted, say). Before
    profiles, `make code` opened such a VM: an existing VM doesn't need the
    agent resolved. `make run` refuses in the same case, so this may be
    wanted.
  - Done when: either `code.sh` keeps `choose_agent`'s problems only when
    it will create a VM (`rc == 1`) or `AGENT=` was given, with a test that
    `make code` opens the VM with a bad saved agent; or the refusal is
    kept on purpose and the `code.sh` header says so.

- [ ] **Save `AGENT=` from `make code` on an existing VM, as `make run` does**
  - Why: `make run N=<n> AGENT=<x>` on a VM already running `<x>` saves
    `<x>` as the sandbox's own agent when it has none
    (`run.sh`: `[[ -n "${CLI_AGENT:-}" && -z "$SANDBOX_AGENT" ]] && save_agent`).
    `make code` saves it only when it creates the VM, so the two commands
    leave different state for the same request.
  - Done when: `code.sh` saves it in that case too, the README's "One
    sandbox, its own agent" bullet still holds for both, and a test covers
    `make code N=<n> AGENT=<x>` on an existing `<x>` VM writing
    `.state/<n>/agent`.

- [ ] **Mention `AGENT=` in the Makefile's `code` help**
  - Why: `make code` accepts `AGENT=<name>`, but its `##` help text shows
    only `make code N=<n>` (`run`'s shows `[AGENT=profile]`).
  - Done when: the `code` target's help reads like
    `(make code N=<n> [AGENT=profile])`.

## Later

## Research

- [ ] **Support agents beyond sbx's built-in list (e.g. Pi)**
  - Why: Pi isn't one of sbx's built-in agents, but it's a good choice for
    local hosting.
  - Done when: it's clear whether sbx kits can run arbitrary agents. If
    they can, plan general support; if not, write down why.
  - Progress: they can. Pi runs as `dhi.io/pi:latest` with the example
    mixin in `user-config.example/` (local models), and profiles plus
    `AGENT=` cover choosing it per sandbox. Left: confirm cloud providers
    work through `sbx secret` for arbitrary hosts, check `CREDENTIALS`
    against `sbx secret ls`, and record what `sbx ls` reports for a kit VM
    in docs/DOCKER_SANDBOXES.md.

- [ ] **Explore sbx templates**
  - Why: `sbx template save` snapshots a VM. A prepared template could cut
    first-run setup (image pulls, sign-in, dependency installs).
  - Done when: there's a recommendation on whether the tool should create
    or use templates, and how they'd fit with `SBX_CREATE_FLAGS` (`-t`).

## Known gaps

- [ ] **Test the macOS paths**
  - Why: the bash 4 and BSD tool paths haven't been run on a Mac. The
    tests cover `move_into_sandbox`'s non-GNU `mv` path only through a
    stand-in for BSD mv on Linux.
  - Done when: `make test` passes on `macos-latest` in CI
    (`.github/workflows/test.yml`), and any failures it shows are fixed. It
    covers `make new/add/destroy/list/stop` and the injection checks with
    a fake sbx; real sbx on a Mac is the separate "Confirm `make run` and
    `make code`" item. The README's "macOS hasn't been tested yet" line
    then narrows to that item.
