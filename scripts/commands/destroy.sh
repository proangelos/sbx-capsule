#!/usr/bin/env bash
# Tear down a numbered sandbox: remove its Docker Sandbox (sbx) VM, delete
# each repo, remove the generated files, archive any notes, and remove the
# sandbox dir. Matches by leading index regardless of an optional "-<title>"
# suffix on the dir name (e.g. "3" finds both "3/" and "3-loginFix/").
#
# Usage: scripts/commands/destroy.sh <n>   (or: make destroy N=3)
#   FORCE=1   remove even if some repo has unsaved work
#
# Nothing is removed if any repo has unsaved work: uncommitted changes
# (including untracked files), stashes, commits not on any origin branch
# (including a detached HEAD's), or a rebase/merge/cherry-pick in progress.
# A repo git can't read counts as unsaved too: the check fails closed.
# Deleting a clone deletes its commits, so this errs on the side of keeping.
#
# The clones were writable from the sbx VM, so git runs in them only through
# sandbox_git (scripts/lib/sandbox.sh), which keeps their config from
# running commands on the host, and only once the sandbox's VM is stopped:
# sandbox_git's protection relies on the config not changing while it runs.
# It refuses if some other running VM can write the sandbox folder.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

n="${1:-}"
[[ "$n" =~ ^[0-9]+$ ]] || die "usage: $0 <sandbox number>"
warn_old_git
sandbox_dir="$(find_sandbox_dir "$n")"

# Commits make push sent from this sandbox, by repo: push.sh records them
# outside the sandbox (in .state/, which no VM can write), since the clones'
# own origin/* refs don't show a push made from the host.
state_dir="$(state_dir_of "$sandbox_dir")"
declare -A PUSHED=()
if [[ -f "$state_dir/pushed" && ! -L "$state_dir/pushed" ]]; then
  while read -r r s; do
    [[ "$s" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] && PUSHED[$r]+=" $s"
  done < "$state_dir/pushed"
fi

# unsaved_work <repo dir> [<label> <depth>]  -- prints a short reason per kind
# of unsaved work. Every git call is checked: if git can't answer (files the
# VM left owned by root, a corrupt index, ...), that's printed as a reason
# too, never taken as clean. The caller also checks this ran to the end (see
# CHECK_DONE). Submodules are checked the same way, each through its own
# sandbox_git (their config is the agent's too), with <label> naming them.
unsaved_work() {
  local d="$1" label="${2:-}" depth="${3:-0}" out count git_dir op rec path revs=(HEAD)
  local p="${label:+submodule $label: }"
  if ! out="$(sandbox_git "$d" status --porcelain --ignore-submodules=dirty 2>"$GIT_ERR")"; then
    echo "${p}couldn't check it: $(git_error)"
    return 0
  fi
  [[ -z "$out" ]] || echo "${p}$(grep -c '' <<< "$out") uncommitted change(s)"

  # A stopped rebase, merge or cherry-pick: its commits may be on a detached
  # HEAD only, and `status --porcelain` doesn't mention it.
  if ! git_dir="$(sandbox_git "$d" rev-parse --absolute-git-dir 2>"$GIT_ERR")"; then
    echo "${p}couldn't check it: $(git_error)"
    return 0
  fi
  for op in rebase-merge:rebase rebase-apply:rebase MERGE_HEAD:merge \
            CHERRY_PICK_HEAD:cherry-pick REVERT_HEAD:revert BISECT_LOG:bisect; do
    [[ -e "$git_dir/${op%%:*}" ]] && echo "${p}a ${op#*:} in progress"
  done

  if is_clone "$d"; then
    if ! out="$(sandbox_git "$d" stash list 2>"$GIT_ERR")"; then
      echo "${p}couldn't check it: $(git_error)"
      return 0
    fi
    [[ -z "$out" ]] || echo "${p}$(grep -c '' <<< "$out") stash(es)"
    revs=(--branches HEAD)
  fi
  # HEAD as well as every branch: a detached HEAD's commits are on no branch.
  # Absorbed submodules (whose .git is a file) keep their branches and
  # stashes in the outer repo's .git, so only what's checked out is judged.
  # Commits make push sent from this clone count as saved too (PUSHED); a
  # recorded commit the clone no longer has is left out, not an error.
  local pushed=() s
  if [[ -z "$label" ]]; then
    for s in ${PUSHED[${d##*/}]:-}; do
      sandbox_git "$d" cat-file -e "$s^{commit}" 2>/dev/null && pushed+=("$s")
    done
  fi
  if ! count="$(sandbox_git "$d" rev-list --count "${revs[@]}" --not --remotes ${pushed[@]+"${pushed[@]}"} 2>"$GIT_ERR")"; then
    echo "${p}couldn't check it: $(git_error)"
    return 0
  fi
  (( count )) && echo "${p}$count commit(s) not on origin"

  # Submodules: status above didn't look inside them (that would run git
  # there with only the outer repo's filters switched off). Paths come from
  # the index, which the agent can write, so odd ones aren't followed.
  if ! out="$(sandbox_git "$d" ls-files --stage 2>"$GIT_ERR")"; then
    echo "${p}couldn't list its submodules: $(git_error)"
    return 0
  fi
  while IFS= read -r rec; do
    [[ "$rec" == 160000\ * ]] || continue
    path="${rec#*$'\t'}"
    if [[ "$path" == \"* || "$path" == /* || "/$path/" == */../* ]] || (( depth >= 5 )); then
      echo "${p}couldn't check submodule $(safe_text "$path")"
      continue
    fi
    if has_symlink_under "$d" "$path"; then
      echo "${p}couldn't check submodule $(safe_text "$path"): a symlink on its path (the tool never makes one)"
      continue
    fi
    [[ -e "$d/$path/.git" ]] || continue
    unsaved_work "$d/$path" "${label:+$label/}$(safe_text "$path")" $(( depth + 1 ))
  done <<< "$out"
  return 0
}

# git_error  -- the first line the failing sandbox_git call wrote to
# $GIT_ERR, for the "couldn't check it" reason. Read from the call itself,
# not by running git again: a clone that made git time out would cost a
# second timeout.
GIT_ERR="$(mktemp)"
trap 'rm -f -- "$GIT_ERR"' EXIT
git_error() {
  local msg=""
  IFS= read -r msg < "$GIT_ERR" || true
  safe_text "${msg:-git failed}"
}

# Printed after unsaved_work returns. If it's missing, the check died partway
# (errexit in the subshell), so the repo counts as unchecked, not clean.
# Random, so nothing the agent names (a submodule path, say) can fake it.
CHECK_DONE="-- unsaved_work done $RANDOM$RANDOM$RANDOM --"

# ---- 0. nothing may change the clones while they're checked ----
# sandbox_git reads a clone's config to switch its filters off, then runs
# git again for the check itself. A VM rewriting the config in between
# would slip a filter command through, to run on the host -- so the
# sandbox's own VM is stopped first (it's removed in step 2 anyway, and
# make run restarts it if the checks stop the teardown), and any other VM
# that can write the folder makes this refuse.
# The sandbox's own VM: sandbox_vm, so a VM merely named like it but not
# mounting this folder counts as another VM.
rc=0
name="$(sandbox_vm "$sandbox_dir")" || rc=$?
(( rc != 2 )) \
  || die "couldn't ask sbx for sandbox $n's VM, so the clones can't be checked safely -- check sbx works (sbx diagnose), then try again. Nothing was removed."
(( rc == 0 )) || name=""
running="$(vms_running_on "$sandbox_dir")" \
  || die "couldn't ask sbx which VMs are running on $sandbox_dir, so the clones can't be checked safely -- check sbx works (sbx diagnose), then try again. Nothing was removed."
others=()
stop_own=""
while IFS= read -r vm; do
  [[ -n "$vm" ]] || continue
  if [[ -n "$name" && "$vm" == "$name" ]]; then stop_own=1; else others+=("$vm"); fi
done <<< "$running"
(( ${#others[@]} == 0 )) \
  || die "running sbx VM(s) other than this sandbox's can write $sandbox_dir: ${others[*]} -- stop them (sbx stop <name>), then run make destroy again. Nothing was removed."
if [[ -n "$stop_own" ]]; then
  echo "stopping sbx VM $name first, so nothing changes the clones while they're checked"
  sbx stop "$name" >/dev/null
fi

# ---- 1. check every repo before touching anything ----
repo_dirs=()
links=()
blocked=0
for dest in "$sandbox_dir"/*/; do
  dest="${dest%/}"
  [[ -d "$dest" ]] || continue
  repo="$(basename "$dest")"
  # A symlink could point at any folder on the host: never look into it
  # or remove what it points at, only the link.
  if [[ -L "$dest" ]]; then
    warn "'$(safe_text "$repo")' is a symlink (the tool never makes one) -- only the link will be removed, not what it points at"
    links+=("$dest")
    continue
  fi
  if ! is_clone "$dest"; then
    warn "'$(safe_text "$repo")' isn't a git repo -- it will be left in place"
    continue
  fi
  repo_dirs+=("$dest")
  # `;`, not `&&`: errexit must stay on inside unsaved_work, so a failure
  # there ends the subshell before CHECK_DONE is printed.
  mapfile -t reasons < <(unsaved_work "$dest"; echo "$CHECK_DONE")
  last=$(( ${#reasons[@]} - 1 ))
  if (( last >= 0 )) && [[ "${reasons[$last]}" == "$CHECK_DONE" ]]; then
    unset "reasons[$last]"
  else
    reasons+=("couldn't finish checking it")
  fi
  if (( ${#reasons[@]} )); then
    blocked=1
    printf -v joined '%s; ' "${reasons[@]}"
    echo "${C_YELLOW}${C_BOLD}$(safe_text "$repo")${C_RESET} has unsaved work: $(safe_text "${joined%; }")"
  fi
done

if (( blocked )) && [[ -z "${FORCE:-}" ]]; then
  echo
  echo "${C_RED}${C_BOLD}Nothing was removed.${C_RESET} Push or discard that work first, or run:"
  echo "  make destroy N=$n FORCE=1"
  [[ -z "$stop_own" ]] || echo "Its VM was stopped for the check; make run N=$n starts it again."
  exit 1
fi
(( blocked )) && warn "FORCE=1 set -- removing anyway"

# ---- 2. the sbx VM ----
if ! have_sbx; then
  # Left behind, the VM would be picked up by a future sandbox with this
  # number (create.sh skips numbers whose VM still exists, and warns), so
  # the warning points at make prune.
  warn "sbx isn't installed, so this sandbox's VM ($(sbx_name "$sandbox_dir")), if it has one, wasn't removed -- once sbx is back, make prune removes it"
elif [[ -n "$name" ]] && sbx_exists "$name"; then
  echo "removing sbx VM $name"
  sbx rm --force "$name" >/dev/null
fi

# ---- 3. the repos ----
for dest in "${repo_dirs[@]}"; do
  repo="$(basename "$dest")"
  shown="$(safe_text "$repo")"   # folder names are the agent's to choose
  echo "removing clone $shown"
  rm -rf -- "$dest" || warn "couldn't fully remove $shown (files created as root inside the VM?)"
done
for dest in ${links[@]+"${links[@]}"}; do
  rm -f -- "$dest"
done

# Any subdirectory still here failed to remove or isn't a repo. Leave the
# whole sandbox in place, notes included, rather than archiving the notes
# away from what they're about.
remaining=()
for dest in "$sandbox_dir"/*/; do
  [[ -d "$dest" ]] && remaining+=("$(safe_text "$(basename "$dest")")")
done
if (( ${#remaining[@]} )); then
  echo "note: $sandbox_dir still has folder(s) that weren't removed (${remaining[*]}) -- left in place, notes included"
  exit 0
fi

# ---- 4. generated files and notes ----
# create.sh drops GENERATED_FILES (scripts/lib/sandbox.sh: README.md, AGENTS.md, the agent
# shims) at the sandbox root; those are regenerated per
# sandbox, so just delete them.
for f in "${GENERATED_FILES[@]}"; do rm -f "$sandbox_dir/$f"; done
# make fetch's bundles (FETCH_BUNDLE_GLOB, sandbox.sh): history from
# origin, not notes. rm -f on a symlink removes the link, not its target.
shopt -s nullglob dotglob
for f in "$sandbox_dir"/$FETCH_BUNDLE_GLOB; do rm -f -- "$f"; done
shopt -u nullglob dotglob

# .vscode/settings.json is generated too (scripts/lib/vscode.sh). Only
# removed from a real folder: the VM is gone by now, but a symlinked
# .vscode would point rm at a host folder. Anything else in it is kept and
# archived with the notes.
if [[ -d "$sandbox_dir/.vscode" && ! -L "$sandbox_dir/.vscode" ]]; then
  rm -f "$sandbox_dir/.vscode/settings.json"
  rmdir "$sandbox_dir/.vscode" 2>/dev/null || true
fi

# A symlink at the root isn't a note, and archiving it would leave a link
# to wherever the agent pointed it (~/.ssh, say) in .archive/: remove the
# link, never its target.
shopt -s dotglob nullglob
for f in "$sandbox_dir"/*; do
  if [[ -L "$f" ]]; then
    rm -f -- "$f"
    echo "removed symlink $(safe_text "${f##*/}") (not archived; what it pointed at is untouched)"
  fi
done
shopt -u dotglob nullglob

# Anything else left at the root is notes written during the work
# (PLAN-*.md, VERIFY-*.md, ... -- see the generated AGENTS.md), so archive it
# instead of deleting it.
shopt -s dotglob nullglob
leftovers=("$sandbox_dir"/*)
shopt -u dotglob nullglob
if (( ${#leftovers[@]} )); then
  archive_dir="$SANDBOX_ROOT/.archive/$(basename "$sandbox_dir")"
  # Sandbox numbers get reused once the highest one is destroyed, so never
  # merge into an older sandbox's archive.
  [[ -e "$archive_dir" ]] && archive_dir="$archive_dir-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$archive_dir"
  mv -- "${leftovers[@]}" "$archive_dir"/
  echo
  echo "${C_CYAN}${C_BOLD}ARCHIVED ${#leftovers[@]} item(s) from the sandbox root (not deleted):${C_RESET}"
  for f in "${leftovers[@]}"; do
    name="$(basename "$f")"
    [[ -d "$archive_dir/$name" ]] && name="$name/"
    echo "  - $(safe_text "$name")"
  done
  echo "  -> $archive_dir"
  echo
fi

if rmdir "$sandbox_dir" 2>/dev/null; then
  rm -rf -- "$state_dir"   # make push's record, now that its commits are pushed or gone
  rmdir "$SANDBOX_ROOT/.state" 2>/dev/null || true
  echo "${C_GREEN}sandbox $n destroyed${C_RESET}"
else
  echo "note: $sandbox_dir not empty -- left in place"
fi
