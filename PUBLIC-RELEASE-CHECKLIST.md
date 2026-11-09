# Public release checklist (1.0.0)

Everything to do before this repo goes public, kept apart from
[TODO.md](TODO.md) so none of it gets lost among feature work. Work through it
in order: later steps assume the earlier ones are done.

**This file names things that mustn't be public. Deleting it (step 7) comes
before the history wipe, so it never appears in the public repo.**

The plan is to keep this GitHub repo (`proangelos/sbx-capsule`), wipe its git
history, and make it public. A history wipe only cleans git: the files and
commits. GitHub also stores issues, pull requests, refs and name redirects
alongside the repo, and none of those are touched by the wipe. Most of the
steps below are about that.

## 1. Before the wipe: the tree itself

- [ ] **1. Settle the open security findings**
  - Why: anything still open goes public with the code. They're the OWASP
    review findings: `make push` for host-side pushing (#1), the git
    version floor (#3), `PUSH_AS` integrity (#4), `destroy` following
    symlinks (#5), Makefile argument injection (#6), `make new` failing
    open when `sbx ls` errors (#7), FIFO hangs (#8).
  - Done when: each one is fixed, or is written up in SECURITY.md's
    "Security model" as a known limitation. None are left only in an
    issue or a private note.

- [ ] **1a. Check the host safety checks against what sbx v0.51.0 added**
  - Why: `sbx run --help` on v0.51.0 lists options the checks were never
    tested against. Found by reading the help; none of these have been
    seen in a real VM yet.
    - **`PATH[:TARGET][:ro]` workspaces** mount a host folder at a
      different path inside the VM. If `sbx ls --json` lists them as
      `/host/path:/target`, `check_vm_mounts` (`scripts/lib/host_safety.sh`)
      only strips `:ro`, so the path won't match and a hand-made VM
      mounting the checkout or a source checkout this way would pass
      `make run`'s check. `vms_running_on` and `vscode.sh`'s `:ro` match
      read the same field.
    - **`--mount HOST:SANDBOX_PATH`** binds a host folder into a VM for
      kits (creation only). It may not appear in `workspaces` at all, and
      it isn't in `SBX_RESERVED_FLAGS`, so `SBX_CREATE_FLAGS` can pass it.
    - **`--skills readwrite`** (or the `skills.defaultMode` setting) mounts
      the shared skills store, e.g. `~/.claude/skills`, writable into the
      VM. Claude on the host then loads whatever the agent writes there.
      The default is `readonly`.
    - **`clipboard.textCopy`** (new setting, default `false`) lets sandboxed
      processes copy text to the host clipboard.
  - Done when: a throwaway VM in a scratch copy (AGENTS.md, Testing) shows
    how `sbx ls --json` lists a `PATH:TARGET` workspace and a `--mount`
    bind, and `check_vm_mounts` handles both, with `host_safety` tests;
    `--mount` is refused in `SBX_CREATE_FLAGS` or covered by the checks;
    `make doctor` flags `--skills readwrite` / `skills.defaultMode=readwrite`
    and notes `clipboard.textCopy=true`; and docs/DOCKER_SANDBOXES.md
    describes all four. Anything left is written up in SECURITY.md as in
    step 1.

- [ ] **2. Remove pre-1.0 compatibility code**
  - Why: 1.0.0 supports nothing older: no sandboxes, VMs or `.env`
    settings from earlier versions, including removed ones such as `REF`
    and `SOURCE_FROM`. Their refusals, migrations and fallbacks are dead
    code for every public user, and host-side code that has to stay safe
    against a hostile sandbox.
  - Only the maintainer's machine has pre-1.0 sandboxes (no one else gets
    a pre-1.0 version), and the maintainer handles those separately.
  - Done when: the TODO.md item "Remove pre-1.0 compatibility code" is
    done (it lists every path and the check that nothing's left), and that
    item has been deleted from TODO.md.

- [ ] **3. Point SECURITY.md at private vulnerability reporting**
  - Why: the reporting section must describe how the *public* repo takes
    reports. Any wording used during the private phase (issues, direct
    contact) has to go.
  - Done when: it sends reporters to "Report a vulnerability" on the
    Security tab and links to GitHub's current docs page
    (`.../how-tos/report-and-fix-vulnerabilities/report-privately`).

- [ ] **4. Decide on a custom reporting form**
  - Optional. `.github/VULNERABILITY_REPORT.yml` can ask for what this
    tool's triage needs: which `make` command, whether the attack needs the
    agent to write the sandbox folder, the impact (host code execution,
    host file read/write, lost work, escape beyond the sandbox), and the
    OS, bash, git and sbx versions.
  - Done when: it's added, or deliberately left out.

- [ ] **5. Scan the final tree for identifying content**
  - Why: the wipe keeps the files as they are.
  - Done when: these find nothing in tracked files (they find nothing
    today, as long as this file has been deleted):
    ```sh
    git grep -n -i -E 'assethealth|asset health|ah-sandbox|mbrowe'
    git grep -n -E '/home/|/Users/'      # machine paths in examples
    ```
    The README, docs and examples have also been read through for internal
    host names, team conventions and other company detail. That belongs in
    a user's `SANDBOX_NOTES_FILE`, not here.

- [ ] **6. Write the 1.0.0 changelog entry**
  - Done when: `[Unreleased]` is folded into `## [1.0.0]`, with no commit
    SHAs, no links into the old history, and no migration notes for
    anything step 2 removed: nothing before 1.0.0 was public.

- [ ] **6a. Run `make test` on macOS once, in a throwaway repo**
  - Why: the macOS paths (BSD tools, no `mv -T`, Homebrew bash) have
    never run on a Mac, and this repo can't run Actions before it's public
    (step 13). A fork would carry the old history, so use a new repo
    holding only the final tree.
  - How: create a new *private* repo (any name), push the current tree to
    it as a single commit (`git checkout --orphan ci-tmp && git commit`,
    then push), with `.github/workflows-pending/test.yml` moved to
    `.github/workflows/test.yml` in that commit only. Fix anything the
    `macos-latest` and `ubuntu-latest` jobs show here, then delete the
    throwaway repo.
  - Done when: both jobs pass (ubuntu-latest also runs `shellcheck`), the
    throwaway repo is deleted, and TODO.md's "Test the macOS paths" item is
    deleted with a CHANGELOG line.

- [ ] **7. Delete this file**
  - Done when: `test ! -e PUBLIC-RELEASE-CHECKLIST.md` succeeds, and the
    deletion is committed. Keep a copy outside the repo if you want to
    finish the steps below from it.

## 2. The wipe

- [ ] **8. Make a single new root commit from the final tree**
  - Why: the old history has commit messages naming the company, and 4
    commits use a personal email address.
  - Done when: `git checkout --orphan` + commit gives one commit authored
    with the GitHub noreply address, and `git log --format='%an <%ae>'`
    shows nothing else.

- [ ] **9. Replace every ref on GitHub**
  - Why: wiping `master` alone leaves the old history reachable through
    any other branch or tag. Today that's `feat/docker-sandbox-tooling`.
  - Done when: the new `master` is force-pushed, every other branch and tag
    is deleted on GitHub, and `git ls-remote origin` lists only the new
    commit.

- [ ] **10. Ask GitHub Support to purge the old commits**
  - Why: after a force-push, old commits can still be opened on github.com
    by their SHA until GitHub cleans them up, and pull requests keep their
    own copies.
  - Done when: Support confirms that the cached views and any PR refs are
    purged. Don't make the repo public before then.

## 3. GitHub-side, before switching to public

- [ ] **11. No issues left**
  - Done when: `gh issue list --state all` is empty. Delete any issue
    (an admin can, from the issue page), security ones above all.

- [ ] **12. No pull requests left**
  - Why: PRs can't be deleted by you, and they keep the old commits.
  - Done when: `gh pr list --state all` is empty, or any PRs have been
    removed by GitHub Support (step 10). Simplest is to open none on this
    repo before release.

- [ ] **13. Nothing else stored with the repo**
  - Done when releases, Actions runs, Projects (switched on, check it's
    empty or switch it off), wiki and discussions (both off today), and
    commit comments are empty. The repo's description, website and topics
    are company-free too.

- [ ] **14. Deal with the old-name redirect**
  - Why: the repo was renamed from `ah-sandbox-tooling`, and GitHub
    redirects that old URL to it, publicly once the repo is public.
  - Done when: either a private repo named `ah-sandbox-tooling` has been
    created under the account (claiming the name stops the redirect), or
    you've decided to accept the redirect. Local clones point at the new
    URL either way: `git remote set-url origin
    git@github.com:proangelos/sbx-capsule.git`.

- [ ] **15. Confirm no one else has the old history**
  - Why: no one else gets access before 1.0.0, but a clone or fork made by
    anyone who did would still hold the old history, and pushing one of
    its branches would put it back on GitHub.
  - Done when: the repo's collaborators and forks are only yours
    (`gh api repos/proangelos/sbx-capsule/collaborators --jq '.[].login'`,
    `gh api repos/proangelos/sbx-capsule/forks --jq '.[].full_name'`), and
    your own local clones are re-cloned after the wipe.

## 4. Going public

- [ ] **16. Make the repo public**

- [ ] **17. Turn on private vulnerability reporting**
  - Why: it only exists for public repos, so it can't be done earlier.
  - Done when: Settings > Advanced Security > Private vulnerability
    reporting is enabled. You watch the repo with "All Activity" or
    "Security alerts", so reports actually notify you. The "Report a
    vulnerability" button shows for another account or a logged-out
    browser.

- [ ] **17a. Switch on CI**
  - Why: it's parked at `.github/workflows-pending/test.yml` so the repo
    has no Actions runs before it's public (step 13).
  - Done when: `git mv .github/workflows-pending/test.yml
    .github/workflows/test.yml` is committed and pushed, and its first run
    passes on both OSes.

- [ ] **18. Tag and release 1.0.0**
