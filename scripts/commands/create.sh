#!/usr/bin/env bash
# Create a new numbered sandbox: a full git clone of each requested repo,
# made from your local source checkouts. Repos come from your .env (see
# .env.example); nothing is included unless you ask for it.
#
# Usage:
#   WITH="api web" scripts/commands/create.sh                    # those repos (plus DEFAULT_REPOS, if your .env sets any)
#   WITH="api web:feat/login" scripts/commands/create.sh         # web starts from feat/login instead of SOURCE_BRANCHES[web]
#   TITLE=loginFix WITH=api scripts/commands/create.sh           # dir is "<n>-loginFix" instead of just "<n>"
#   PUSH_AS=fix-auth-bug WITH=api scripts/commands/create.sh     # work on branch fix-auth-bug, pushing to origin/fix-auth-bug
#   scripts/commands/create.sh                                   # no WITH and no DEFAULT_REPOS: an empty sandbox
#   EMPTY=1 scripts/commands/create.sh                           # an empty sandbox, even with DEFAULT_REPOS set
#   CLI_AGENT=pi scripts/commands/create.sh                      # make new AGENT=pi: the sandbox's own agent
#
# Then `make run N=<n>` starts the agent in a Docker Sandbox (sbx) VM on it:
# AGENT in .env, or the one named with AGENT=<spec> (a profile in
# user-config/agents/, a built-in agent or a kit reference), which is saved
# as the sandbox's own so later .env changes don't affect it
# (scripts/lib/profiles.sh).
#
# Repos: WITH's repos in the order given, then any DEFAULT_REPOS not already
# named. A default repo named in WITH uses WITH's branch, if it gives one.
# With none of either, or with EMPTY, the sandbox starts with no repos, for
# `make add` to bring in later (EMPTY with WITH is refused).
# `repo:branch` names the start branch for that repo -- on origin, or a
# local-only branch in the source checkout. ':' can't appear in a git branch
# name, so it always splits cleanly.
#
# TITLE is cosmetic only -- `make run/add/destroy N=<n>` key off the leading
# number, so "3-loginFix" is still sandbox 3.
#
# Branches: with PUSH_AS, each clone's branch is named PUSH_AS and tracks
# origin/PUSH_AS, so a bare `git push` goes there. Without it, the branch is
# sandbox/<n>/<repo> with no upstream. Each clone has its own branches, so
# the same name in several repos (or in your source checkouts) never clashes.
#
# Start point, per repo: origin/PUSH_AS if it already exists (announced with
# a banner -- continuing it is the only way a push can fast-forward it), else
# the branch named in WITH, else a fresh fetch of SOURCE_BRANCHES[repo].
#
# Everything is checked before anything is created, and every problem is
# listed at once: your .env, unknown repos, malformed repo:branch specs,
# start branches that don't exist, a requested branch that conflicts with an
# existing origin/PUSH_AS, and PUSH_AS itself (invalid, a repo's source
# branch, or already used by another sandbox for the same repo). If cloning
# still fails partway, the half-made sandbox is removed.
#
# The number is claimed under a lock (.new.lock), so concurrent runs get
# different numbers, and a number whose sbx VM still exists is skipped.
#
# Every sandbox also gets README.md (for you), AGENTS.md (rules for AI agents,
# plus SANDBOX_NOTES_FILE if .env sets one), CLAUDE.md and GEMINI.md (which
# just import AGENTS.md, for agents that don't read it on their own) at its
# root. Its PUSH_AS is recorded outside the sandbox, in
# .state/<sandbox>/push_as, which the VM can't write. destroy.sh removes
# those files (GENERATED_FILES in scripts/lib/sandbox.sh) on teardown and
# archives any notes left there.
#
# Why clones and not worktrees: see docs/DESIGN.md. The cloning itself is
# clone_repo in scripts/lib/clone.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

# ---- everything that can be checked without creating anything ----
validate_config
[[ "${TITLE:-}" != */* ]] || die "TITLE cannot contain '/'"

PROBLEMS=()
WITH="${WITH:-}"
if [[ -n "${EMPTY:-}" && -n "${WITH//[[:space:]]/}" ]]; then
  PROBLEMS+=("EMPTY=1 makes a sandbox with no repos, so it can't take WITH -- drop one of them")
fi
parse_repo_specs "WITH" "${WITH:-}"
# AGENT= on the command line: checked now, saved once the sandbox exists.
choose_agent || true
# WITH's repos first, in its order; then DEFAULT_REPOS not already named.
# None at all (or EMPTY) is an empty sandbox, for make add to fill.
requested=(${SPEC_REPOS[@]+"${SPEC_REPOS[@]}"})
if [[ -z "${EMPTY:-}" ]]; then
  for r in ${DEFAULT_REPOS[@]+"${DEFAULT_REPOS[@]}"}; do
    [[ -v "SPEC_BRANCH[$r]" ]] && continue
    # shellcheck disable=SC2004  # SPEC_BRANCH is associative (validate.sh); $r is a repo name
    SPEC_BRANCH[$r]=""
    requested+=("$r")
  done
fi
# The VM name (sbx_name) has to fit sbx's limit; the number is at most 4
# digits in practice, so that's what's allowed for.
if [[ -n "${TITLE:-}" ]] && (( ${#SBX_PREFIX} + 5 + ${#TITLE} > SBX_NAME_MAX )); then
  PROBLEMS+=("TITLE is ${#TITLE} characters -- keep it to $(( SBX_NAME_MAX - ${#SBX_PREFIX} - 5 )) or fewer, or the sandbox's VM name would be longer than sbx allows ($SBX_NAME_MAX)")
fi
# Branch checks run on the repos that parsed cleanly, so a typo elsewhere and
# a missing branch are reported together.
(( ${#requested[@]} )) && check_start_branches "${requested[@]}"
[[ -z "${PUSH_AS:-}" ]] || check_push_as "$PUSH_AS" ${requested[@]+"${requested[@]}"}

# VMs that already exist: a sandbox removed by hand (or destroyed while sbx
# was missing) leaves its VM behind, and a new sandbox with the same folder
# name would reattach to it -- old agent, old mounts, old history. Those are
# this checkout's VMs still mounting that path (tool_vms). Any other VM that
# merely has the name would make make run fail, so its number is skipped too.
# If sbx is installed but doesn't answer, neither is known, so refuse rather
# than risk handing out a number that has a VM. Without sbx there are none.
existing_vms="" tool_vm_lines=""
if have_sbx; then
  if ! existing_vms="$(sbx ls -q 2>/dev/null)" || ! tool_vm_lines="$(tool_vms)"; then
    PROBLEMS+=("couldn't ask sbx which VMs exist, so a new sandbox could reuse a number whose VM is left over -- check sbx works (sbx diagnose), then try again")
  fi
fi
report_problems "can't create the sandbox:"

# ---- claim the next sandbox number (dirs are "<n>" or "<n>-<title>") ----
# Under a lock, so two `make new` runs at once can't pick the same number --
# and one's cleanup_partial can't delete the other's sandbox. The lock is a
# directory (mkdir is atomic; no flock on macOS) holding its owner's PID, so
# one left behind by a killed run is broken instead of blocking forever.
lock_dir="$SANDBOX_ROOT/.new.lock"
take_lock() {
  local tries=0 pid
  until mkdir "$lock_dir" 2>/dev/null; do
    pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf -- "$lock_dir"
      continue
    fi
    (( ++tries < 150 )) \
      || die "another make new has held $lock_dir for 15s -- if none is running, remove it: rm -rf $lock_dir"
    sleep 0.1
  done
  echo "$$" > "$lock_dir/pid"
}

# Which numbers those VMs (listed above, before report_problems) rule out.
declare -A tool_vm_of=()
while IFS=$'\t' read -r vm_name _ _ vm_ws; do
  [[ -n "$vm_ws" ]] && tool_vm_of[$vm_ws]="$vm_name"
done <<< "$tool_vm_lines"

take_lock
trap 'rm -rf -- "$lock_dir"' EXIT

next=1
for d in "$SANDBOX_ROOT"/*/; do
  [[ -d "$d" ]] || continue
  name="$(basename "$d")"
  [[ "$name" =~ ^([0-9]+)(-.*)?$ ]] || continue
  num="${BASH_REMATCH[1]}"
  (( 10#$num >= next )) && next=$(( 10#$num + 1 ))
done

while :; do
  sandbox_name="$next"
  [[ -n "${TITLE:-}" ]] && sandbox_name="$next-$TITLE"
  sandbox_dir="$SANDBOX_ROOT/$sandbox_name"
  vm="$(sbx_name "$sandbox_dir")"
  if [[ -n "${tool_vm_of[$sandbox_dir]:-}" ]]; then
    warn "skipping sandbox number $next: sbx VM ${tool_vm_of[$sandbox_dir]} is left over from an earlier sandbox $next. Remove it with: make prune"
  elif grep -qxF "$vm" <<< "$existing_vms"; then
    warn "skipping sandbox number $next: an sbx VM named $vm already exists, but it isn't this checkout's (made by hand?)"
  elif mkdir "$sandbox_dir" 2>/dev/null; then
    break
  elif [[ ! -e "$sandbox_dir" ]]; then
    die "couldn't create $sandbox_dir"
  fi
  next=$(( next + 1 ))
done

echo "Creating sandbox $next at $sandbox_dir"
# Host-side records (.state/) left by an earlier sandbox of this name
# (removed by hand, not destroyed) aren't about this one.
rm -rf -- "$SANDBOX_ROOT/.state/$sandbox_name"

# If anything below fails (say the network drops mid-clone), don't leave a
# half-made sandbox behind: it's all fresh clones, nothing of value yet.
# Armed only now that this run has created the folder itself.
cleanup_partial() {
  local rc=$?
  (( rc == 0 )) && return
  rm -rf -- "$sandbox_dir" "$SANDBOX_ROOT/.state/$sandbox_name"
  echo "${C_RED}${C_BOLD}Sandbox creation failed${C_RESET} -- removed the partial $sandbox_dir" >&2
}
trap cleanup_partial EXIT
rm -rf -- "$lock_dir"

# ---- group requested repos by REPO_GROUP (.env), preserving first-seen
# order, so the sandbox's own README can explain how they relate instead of
# just listing them flat.
group_order=()
declare -A group_seen=()
declare -A group_members=()
for repo in ${requested[@]+"${requested[@]}"}; do
  g="${REPO_GROUP[$repo]:-$repo}"
  if [[ -z "${group_seen[$g]:-}" ]]; then
    group_seen[$g]=1
    group_order+=("$g")
  fi
  group_members[$g]+="$repo"$'\n'
done

# repo -> "branch X off Y" line, filled in as each clone is made; assembled
# into the README after the loop. resumed = repos that continue origin/PUSH_AS;
# requested_from = repos started from a branch named in WITH.
declare -A repo_branch_line=()
resumed=()
requested_from=()

for repo in ${requested[@]+"${requested[@]}"}; do
  echo "  cloning $repo ..."
  clone_repo "$repo" "$next" "$sandbox_dir" "${SPEC_BRANCH[$repo]}"
  echo "    ${C_GREEN}$repo${C_RESET}: branch $CLONE_BRANCH off $CLONE_START"
  repo_branch_line[$repo]="branch \`$CLONE_BRANCH\` off \`$CLONE_START\`"
  if [[ -n "$CLONE_REQUESTED" ]]; then
    requested_from+=("$repo")
    repo_branch_line[$repo]+=" (requested in \`WITH\`; \`.env\` default is \`${SOURCE_BRANCHES[$repo]}\`)"
  fi
  if [[ -n "$CLONE_RESUMED" ]]; then
    resumed+=("$repo")
    repo_branch_line[$repo]+=" -- **continues the existing remote branch**${CLONE_RESUMED_DETAIL:+ ($CLONE_RESUMED_DETAIL)}"
    resumed_banner "$repo"
  fi
done

# ---- PUSH_AS, recorded where the agent can't change it: make push pushes
# there, and make add makes new clones track it (read_push_as, sandbox.sh).
record_push_as "$sandbox_dir" "${PUSH_AS:-}"
[[ -z "${CLI_AGENT:-}" ]] || save_agent "$sandbox_dir" "$CLI_AGENT"

# ---- repos `make add` could still bring in: defined in .env but not in
# this sandbox, alphabetically. Listed in README.md and AGENTS.md because the
# agent can't read .env from inside the VM. A snapshot: repos defined later
# still work with `make add`, they just aren't listed here.
declare -A in_sandbox=()
for r in ${requested[@]+"${requested[@]}"}; do in_sandbox[$r]=1; done
addable_lines=""
for r in $(printf '%s\n' "${!REPOS[@]}" | sort); do
  [[ -n "${in_sandbox[$r]:-}" ]] && continue
  addable_lines+="- \`$r\` -- starts from \`${SOURCE_BRANCHES[$r]}\` unless you name a branch"
  [[ -n "${REPO_DESC[$r]:-}" ]] && addable_lines+="; ${REPO_DESC[$r]}"
  addable_lines+=$'\n'
done
[[ -n "$addable_lines" ]] || addable_lines="- _(none: every repo in .env is already here)_"$'\n'
addable_lines="${addable_lines%$'\n'}"
undefined_repo_note="A repo that isn't listed has to be defined first, by the user on the host:
a \`REPOS\` path and a \`SOURCE_BRANCHES\` entry in \`$SANDBOX_ROOT/.env\`
(\`.env.example\` there shows the syntax). Then \`make add\` accepts it."

# ---- assemble the grouped "## Repos" body: a header per group with >1
# requested member (to name the relationship), a plain bullet otherwise.
readme_repo_lines=""
for g in ${group_order[@]+"${group_order[@]}"}; do
  members=()
  while IFS= read -r m; do [[ -n "$m" ]] && members+=("$m"); done <<< "${group_members[$g]}"
  (( ${#members[@]} > 1 )) && readme_repo_lines+="**$g:**"$'\n'
  for m in "${members[@]}"; do
    desc="${REPO_DESC[$m]:-}"
    readme_repo_lines+="- **$m** -- ${desc:+$desc; }${repo_branch_line[$m]}"$'\n'
  done
  readme_repo_lines+=$'\n'
done
# Not "_None yet._": make add deletes that line wherever it is.
[[ -n "$readme_repo_lines" ]] \
  || readme_repo_lines="_None at creation: this sandbox started empty. See \"Repos added after creation\" below._"$'\n'

# ---- assemble the "## Branch tracking" body, since how a bare `git push`
# behaves here depends on whether PUSH_AS was set at creation.
if [[ -n "${PUSH_AS:-}" ]]; then
  branch_tracking_body="Every repo is on a local branch named \`$PUSH_AS\` that tracks
\`origin/$PUSH_AS\` (set in each clone's own \`.git/config\`). A bare \`git push\`
from any repo here goes there, creating the remote branch on first push."
  if (( ${#resumed[@]} )); then
    branch_tracking_body+="

**\`origin/$PUSH_AS\` already existed for: ${resumed[*]}.** Those repos were
branched from it instead of their source branch, so work here continues that
branch and a push fast-forwards it."
  fi
else
  branch_tracking_body="Every repo is on a local branch named \`sandbox/$next/<repo>\` with no
upstream, so a bare \`git push\` is rejected. Push with an explicit target:
\`git push -u origin HEAD:<remote-branch>\`."
fi

# ---- git: hosts the repos push to, and whether the agent may push (.env
# AGENT_GIT_PUSH). Whether a host is reachable depends on the sbx network
# policy, so AGENTS.md hedges rather than promising either way.
# make push needs AS=<branch> when there's no PUSH_AS to push to.
push_as_arg=""
[[ -n "${PUSH_AS:-}" ]] || push_as_arg=" AS=<branch>"
# shellcheck disable=SC2016  # literal backticks: Markdown code spans
hosts="$(git_hosts ${requested[@]+"${requested[@]}"} | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')"
# Newer commits from origin, whichever the push setting: make fetch on the
# host hands them over as a bundle. Never git run in the clone on the host.
fetch_rule="- **Newer commits from origin:** ask the user to run
  \`make fetch N=$next REPO=\"<repo>\"\` on the host. It leaves
  \`.fetch-<repo>.bundle\` in this folder; apply it with
  \`git -C <repo> fetch ../.fetch-<repo>.bundle '+refs/remotes/origin/*:refs/remotes/origin/*'\`,
  then rebase or merge as agreed. Never ask the user to run git in a clone
  on the host: its config and hooks are yours, and would run as them."
if [[ "$AGENT_GIT_PUSH" == yes ]]; then
  readme_push_note="The agent may push its own branch (\`AGENT_GIT_PUSH=yes\` in \`.env\`), if
the git host is on the sbx network allow-list and credentials are set up
(see the tool's README). You can push from the host too, with
\`make push N=$next REPO=\"<repo>\"$push_as_arg\`."
  network_note="Pushing and fetching only work if the git host${hosts:+ ($hosts)} is on the allow-list and credentials are set up; if they fail, use \`make fetch\` (below) or ask the user, rather than working around it."
  if [[ -n "${PUSH_AS:-}" ]]; then
    push_how="a bare \`git push\` goes to \`origin/$PUSH_AS\`"
  else
    push_how="use \`git push -u origin HEAD:<remote-branch>\` with a feature-branch name the user agrees to"
  fi
  git_rule="- **Git: you may push your branch.** Work on the branch each clone is
  on (see README.md); $push_how. Never force-push, never push to a repo's
  source branch, and don't change remotes or branch tracking."
else
  readme_push_note="You push from the host (\`AGENT_GIT_PUSH=no\` in \`.env\`)
with \`make push N=$next REPO=\"<repo>\"$push_as_arg\`, which never runs git in
the clone. Review the work inside the VM (\`make code N=$next\`), not with git
or an editor on the host: the agent wrote each clone's git config and hooks
(see the tool's README, \"Reviewing and editing a sandbox\")."
  network_note="The git host${hosts:+ ($hosts)} may not be on it, so \`git fetch\`, \`pull\` and \`push\` may not work -- use \`make fetch\` (below) for newer commits, and you shouldn't push anyway."
  git_rule="- **Git: never push.** Work on the branch each clone is on (see
  README.md). Don't push, and don't change remotes or branch tracking --
  the user pushes from the host."
fi

# shellcheck disable=SC2016  # literal backticks: Markdown code spans
generated_list="$(printf '`%s`\n' "${GENERATED_FILES[@]}" | paste -sd, - | sed 's/,/, /g')"

# ---- user instructions (.env AGENT_INSTRUCTIONS): one bullet each, near
# the top of AGENTS.md and ahead of the tool's own rules. Only expanded,
# never evaluated, so the text comes out as written. Later lines of a
# multi-line entry are indented to stay inside their bullet.
user_instructions=""
if (( ${#AGENT_INSTRUCTIONS[@]} )); then
  user_instructions="
## User instructions

_From \`AGENT_INSTRUCTIONS\` in the user's \`.env\`. These take priority over
everything else in this file: where they conflict with the rules below,
follow these._
"
  for instruction in "${AGENT_INSTRUCTIONS[@]}"; do
    user_instructions+="
- ${instruction//$'\n'/$'\n'  }"
  done
  user_instructions+=$'\n'
fi

# ---- team notes (.env SANDBOX_NOTES_FILE), copied in as they are now.
team_notes=""
if [[ -n "$SANDBOX_NOTES_FILE" ]]; then
  team_notes="
## Team notes

_From \`$SANDBOX_NOTES_FILE\` on the host (\`SANDBOX_NOTES_FILE\` in \`.env\`),
copied when this sandbox was created._

$(cat "$SANDBOX_NOTES_FILE")
"
fi

cat > "$sandbox_dir/README.md" <<EOF
# Sandbox $next${TITLE:+ ($TITLE)}

Created by \`create.sh\`. Each repo below is a full git clone made from its
source checkout (see your \`.env\`), with \`origin\` pointing at the real
remote. Your source checkouts weren't changed, and untracked files in them
(an app's own \`.env\`, say) don't come across.

Repos are grouped below by how they relate (shared stack, frontend/backend
pair, etc -- \`REPO_GROUP\` in \`.env\`). Inside this sandbox every repo is a
flat sibling directly under this directory, even ones that normally live
nested inside another repo's tree.

## Commands

Run these from the tool's folder, \`$SANDBOX_ROOT\`:

\`\`\`
make run N=$next                  # start the agent ($AGENT_SPEC) in a Docker Sandbox VM on this folder; again to reattach
make add N=$next REPO="<repo>[:<branch>] ..."   # clone more repos into this sandbox (see "Repos added after creation")
make fetch N=$next [REPO="<repo>"]  # fetch origin's new commits; leaves .fetch-<repo>.bundle here for the agent to apply
make stop N=$next                 # stop the VM, keeping its state; make run starts it again
make destroy N=$next              # tear down (see "Tear down")
\`\`\`

$readme_push_note

## Repos

$readme_repo_lines
## Repos added after creation

\`make add N=$next REPO="<repo>[:<branch>] ..."\` clones more repos into this
sandbox with the same \`PUSH_AS\` settings, and records them below. A repo
starts from its \`.env\` source branch unless you name one after a \`:\`
(for example \`REPO="web:feat/login"\`). Repos that could be added when this
sandbox was created:

$addable_lines

$undefined_repo_note

**Added so far:**

_None yet._
<!-- make add inserts entries above this line -->

## Post-creation base changes

_None recorded._ If any repo's base branch changes after creation (rebase,
fast-forward, or switch onto a different source branch), record it here:
repo, old base + SHA, new base + SHA, date, reason, and which branch the pull request
should target.

## Branch tracking

$branch_tracking_body

## Notes

Plans, verification steps, and other notes about this work live as \`.md\`
files here at the sandbox root, not inside the repos (see \`AGENTS.md\` for
the naming convention).

## Tear down

\`\`\`
make destroy N=$next
\`\`\`

This removes the sandbox's VM and deletes the clones -- but first it checks
every clone, and if any has uncommitted changes, stashes, commits that
aren't on origin, a rebase or merge in progress, or can't be read by git,
it stops without removing anything (\`FORCE=1\` overrides).
Notes files are moved to \`$SANDBOX_ROOT/.archive/$sandbox_name/\` rather than
deleted.
EOF

# ---- AGENTS.md (source of truth) + the AGENT_SHIMS (CLAUDE.md, GEMINI.md:
# they import it, for agents that don't auto-load AGENTS.md; codex, copilot,
# cursor, opencode and most others read it directly) -- the AI-agent-facing workspace
# notes. Repo/branch/tracking detail already lives in README.md above, so
# these just point there instead of duplicating it.
if (( ${#requested[@]} == 0 )); then
  start_branch_note="**This sandbox started empty.** If there's no repo here yet for the task, ask the user to clone it in with \`make add N=$next REPO=\"<repo>[:<branch>]\"\` (see \"Adding a repo\" below). A repo added that way starts from its \`.env\` source branch unless the user names another; README.md records which, under \"Repos added after creation\"."
elif (( ${#requested_from[@]} )); then
  start_branch_note="**Started from a branch named in \`WITH\`, not their \`.env\` source branch:** ${requested_from[*]}. See the branch lines in README.md; pull requests from these usually target that branch, not the \`.env\` default."
else
  start_branch_note="Every repo started from its usual \`.env\` source branch (see README.md)."
fi
if (( ${#resumed[@]} )); then
  start_branch_note+="

**These repos continue an existing \`origin/$PUSH_AS\` instead:** ${resumed[*]}. They already had commits on that branch when the sandbox was created; check them before assuming you're starting from the source branch."
fi

cat > "$sandbox_dir/AGENTS.md" <<EOF
# Sandbox $next workspace notes

**Read this before making any changes.** This directory (\`$sandbox_dir\`) is
an isolated sandbox: each subdirectory here is a full git clone of a real
repo, made for this task.
$user_instructions
## Where you're running

Usually inside a Docker Sandbox (\`sbx\`) VM, started with \`make run N=$next\`:

- Only this folder is visible. Nothing else on the host is.
- Network goes through an allow-list proxy. $network_note
- You have your own Docker engine. The host's containers aren't reachable.
- \`sbx\` may add its own instructions file one folder up describing the VM.
  Where it differs from this file (pushing, for example), this file wins.

The user may also run you directly on the host. The rules below apply
either way. On the host, the folder one up is the sandbox tool's own repo:
its \`AGENTS.md\`/\`CLAUDE.md\` are for maintaining that tool and don't apply
to you here.

## Ground rules

- **This sandbox's clones are the only place to make code changes.** Do not
  touch the repos' source checkouts, other sandboxes, or anywhere else
  without the user's explicit approval. If a change genuinely requires touching something outside this
  directory, stop and ask the user first.
- **Running containers do not use this sandbox's code, and that's
  intentional.** Whatever's already running on the host (docker compose
  stacks and the like) was started from the source checkouts. The user
  tests this work by checking the branch out there themselves -- it never
  happens automatically, and it isn't something you should do.
- **Do not run commands against running containers** (\`docker exec\`,
  restarts, rebuilds, and the like) without the user's explicit approval.
$git_rule
$fetch_rule

See \`README.md\` next to this file for the repo list, branches, and
push-tracking (\`PUSH_AS\`) details.

## Start branches

$start_branch_note

## Post-creation base changes

**If you change any repo's base branch after creation** (rebase,
fast-forward, or switch onto a different source branch), record it in
\`README.md\` under "Post-creation base changes" *and* in this section:
repo, old base + SHA, new base + SHA, date, reason, and which branch the pull request
should target. The branch lines in \`README.md\` only reflect what
\`create.sh\` did, so without this note the next person (or agent) will
assume the original base and target the wrong branch.

_None recorded._

## Adding a repo

You can't add repos yourself: the source checkouts aren't visible from the
VM, and clones must be made the same way as the others. Ask the user to run
\`make add N=$next REPO="<repo>[:<branch>]"\` on the host (\`:<branch>\` only if it
should start from something other than its \`.env\` source branch). It uses this sandbox's branch and
tracking settings and records the repo in README.md under "Repos added
after creation". The new folder shows up here right away.

Repos that could be added when this sandbox was created:

$addable_lines

$undefined_repo_note

## Notes and docs for this sandbox

**Write notes about this work as \`.md\` files at the root of this sandbox**
(\`$sandbox_dir\`), never inside a repo clone. That covers plans,
testing/verification steps, investigation notes, and handoff notes --
anything *about* the work. Docs that are *part of the deliverable* (repo
docs, ADRs, changelogs, READMEs the pull request should include) still belong in
the repo.

- **Naming:** \`<KIND>-<topic>.md\`, where \`<KIND>\` is \`PLAN\`, \`VERIFY\`,
  \`NOTES\`, or \`HANDOFF\` and \`<topic>\` is short kebab-case (e.g.
  \`VERIFY-login-redirect.md\`). If a file for that topic already exists,
  update it instead of creating a near-duplicate. Never overwrite
  $generated_list, and other agents
  may be working in this sandbox too -- don't overwrite a notes file you
  didn't create without asking the user.
- **When:** testing/verification steps, setup or run instructions, anything
  else the user will follow step by step, and any other output longer than
  about 15 lines go in a file -- without being asked. In chat, give a 1-2
  line summary plus the file's absolute path, so the user knows it exists.
- **Plans:** if your tool keeps plans outside this folder (Claude Code's
  \`~/.claude/plans/\`, for example), they're lost with the VM. Once a plan
  is approved, write it here as \`PLAN-<topic>.md\`.
- **No secrets:** never write tokens, passwords, API keys, credentialed
  connection strings, or customer or personal data into these files -- that
  includes commands inside verification steps. Use a placeholder like
  \`<API_TOKEN>\` and say where the user gets the real value.

\`make destroy N=$next\` moves these files to
\`$SANDBOX_ROOT/.archive/$sandbox_name/\` instead of deleting them.
$team_notes
## About this file

Generated by \`create.sh\` when this sandbox was created
($(date '+%Y-%m-%d %H:%M %Z')) -- not kept in sync with anything done
afterward, apart from the post-creation base changes recorded above.
EOF

write_agent_shims "$sandbox_dir" "$next"

# VS Code workspace settings for `make code`: no VM has seen this folder
# yet, so they're written in place; make run mounts .vscode read-only.
mkdir "$sandbox_dir/.vscode"
write_vscode_settings "$sandbox_dir/.vscode"

# Created: from here on, a failure must not delete the sandbox.
trap - EXIT

echo
echo "${C_GREEN}${C_BOLD}Sandbox $next ready:${C_RESET} $sandbox_dir"
if (( ${#requested[@]} )); then
  echo "Repos: ${requested[*]}"
else
  echo "Repos: none yet -- add them with ${C_BOLD}make add N=$next REPO=\"<repo>[:<branch>] ...\"${C_RESET}"
fi
echo "Workspace notes written: README.md, AGENTS.md, $(printf '%s, ' "${AGENT_SHIMS[@]}" | sed 's/, $//')"
echo "Start the agent ($(run_agent_label)${CLI_AGENT:+, saved for this sandbox}): ${C_BOLD}make run N=$next${C_RESET}"

# Repeat the resumed-branch notice last, so it can't scroll away unseen.
if (( ${#resumed[@]} )); then
  banner "$C_YELLOW" \
    "${C_BOLD}REMINDER: ${#resumed[@]} repo(s) continue the EXISTING origin/$PUSH_AS${C_RESET}" \
    "" \
    "  ${resumed[*]}" \
    "" \
    "They were branched from origin/$PUSH_AS, not their source branch." \
    "See README.md in the sandbox for details."
fi
