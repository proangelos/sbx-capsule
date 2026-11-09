#!/usr/bin/env bash
# Push a sandbox clone's branch to its repo's origin from the host, without
# ever running git with the clone as its repository: the clone's
# .git/config and hooks are the agent's, and plain git there would run them
# as you.
#
# Usage: scripts/commands/push.sh <sandbox number> "<repo> ..."
#        (or: make push N=3 REPO="api web" [AS=<branch>] [YES=1])
#   AS=<branch>  the remote branch to push to. Required when the sandbox has
#                no PUSH_AS (its clones are on sandbox/<n>/<repo>); with
#                PUSH_AS it's that branch, and AS may only repeat it. PUSH_AS
#                is read from .state/<sandbox>/push_as, never from the
#                sandbox, so the agent can't pick where you push.
#   YES=1        don't ask before pushing (needed without a terminal).
#
# How, per repo:
#   1. A bare repo in a .staging.* folder outside the sandbox, borrowing the
#      source checkout's objects read-only (objects/info/alternates), so
#      only new commits are copied and the source checkout isn't touched.
#   2. `git fetch <clone> <branch>` into it. A fetch from a path runs
#      git upload-pack in the clone, which Git keeps safe for untrusted
#      repos: it runs none of the clone's hooks or command-running config.
#      The bare repo has no working tree, so no filters run either, and
#      received objects are checked (transfer.fsckObjects).
#   3. The commits going out, shown from the bare repo (your config only),
#      and a confirmation. A push that wouldn't fast-forward is refused:
#      never a force push.
#   4. Push to the origin push URL of the SOURCE checkout, never the
#      clone's (the agent can rewrite that).
#   5. Record the pushed commit in .state/<sandbox>/pushed, outside the
#      sandbox, so make destroy counts it as saved: the clone's own
#      origin/* refs don't know about the push.
#
# Everything is checked first, and every problem listed, before anything
# is fetched or pushed.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

n="${1:-}" specs="${2:-}"
[[ -n "$n" && -n "$specs" ]] || die "usage: make push N=<sandbox number> REPO=\"<repo> ...\" [AS=<branch>] [YES=1]"
validate_config
warn_old_git
sandbox_dir="$(find_sandbox_dir "$n")"

PROBLEMS=()
# The target must never be the agent's choice: PUSH_AS comes from the
# sandbox's host-side record.
read_push_as "$sandbox_dir" \
  || die "sandbox $n has no record of its PUSH_AS ($(state_dir_of "$sandbox_dir")/push_as), so it wasn't made by make new here"
AS="${AS:-}" target="" trusted=""
if [[ -n "$SANDBOX_PUSH_AS" ]]; then
  target="$SANDBOX_PUSH_AS" trusted=1
  [[ -z "$AS" || "$AS" == "$target" ]] \
    || PROBLEMS+=("AS: sandbox $n pushes to its PUSH_AS, $target; AS can't name another branch")
elif [[ -z "$AS" ]]; then
  PROBLEMS+=("AS: sandbox $n has no PUSH_AS, so name the remote branch to push to: make push N=$n REPO=\"...\" AS=<branch>")
else
  target="$AS"
fi
if [[ -n "$target" ]] && ! git check-ref-format --branch "$target" >/dev/null 2>&1; then
  PROBLEMS+=("'$(safe_text "$target")' isn't a valid branch name")
  target=""
fi

repos=()
for repo in $specs; do
  if [[ -z "${REPOS[$repo]:-}" ]]; then
    PROBLEMS+=("REPO: unknown repo '$(safe_text "$repo")' -- not in your .env (defined: $(known_repos))"); continue
  fi
  clone="$sandbox_dir/$repo"
  if [[ -L "$clone" || ! -d "$clone" ]] || ! is_clone "$clone"; then
    PROBLEMS+=("REPO: $repo isn't a clone in sandbox $n ($clone)"); continue
  fi
  if ! git -C "${REPOS[$repo]}" remote get-url --push origin >/dev/null 2>&1; then
    PROBLEMS+=("$repo: its source checkout (${REPOS[$repo]}) has no 'origin' remote to push to"); continue
  fi
  if [[ -n "$target" && "$target" == "${SOURCE_BRANCHES[$repo]:-}" ]]; then
    PROBLEMS+=("$repo: $target is its source branch in .env -- make push never pushes there. Push to a feature branch")
    continue
  fi
  repos+=("$repo")
done
# A target that wasn't recorded at creation mustn't be another sandbox's
# push target (a recorded PUSH_AS was checked when the sandbox was made).
if [[ -n "$target" && -z "$trusted" ]] && (( ${#repos[@]} )); then
  PUSH_AS_SELF="$sandbox_dir" check_push_as "$target" "${repos[@]}"
fi
report_problems "can't push from sandbox $n:"

local_branch="$target"
[[ -n "$SANDBOX_PUSH_AS" ]] || local_branch=""   # set per repo below

staging="$(mktemp -d "$SANDBOX_ROOT/.staging.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
state_dir="$(state_dir_of "$sandbox_dir")"

# git on the bare repo: yours and the tool's config only; the pager off.
bare_git() { GIT_PAGER=cat git -C "$staging/push.git" "$@"; }

for repo in "${repos[@]}"; do
  src="${REPOS[$repo]}" clone="$sandbox_dir/$repo"
  branch="${local_branch:-sandbox/$n/$repo}"
  url="$(git -C "$src" remote get-url --push origin)"
  echo
  echo "${C_BOLD}$repo${C_RESET}: $branch -> $(safe_text "$url") as ${C_BOLD}$target${C_RESET}"

  rm -rf -- "$staging/push.git"
  init_staging_repo "$staging/push.git" "$src"

  # The fetch: upload-pack in the clone; only the file transport allowed.
  # upload-pack reads the clone's config, so the same pre-check and time
  # limit as sandbox_git keep a hostile one from hanging this.
  if ! sandbox_git_precheck "$clone" 2>"$staging/fetch.err" \
     || ! run_with_timeout env GIT_PAGER=cat GIT_ALLOW_PROTOCOL=file \
            git -C "$staging/push.git" -c transfer.fsckObjects=true \
            fetch --quiet --no-tags "$clone" "+refs/heads/$branch:refs/sandbox/push" 2>"$staging/fetch.err"; then
    warn "couldn't read $branch from $repo's clone: $(safe_text "$(head -1 "$staging/fetch.err")")"
    continue
  fi
  sha="$(bare_git rev-parse --verify 'refs/sandbox/push^{commit}')"

  # Where the remote branch is now (asked through the source checkout,
  # whose origin and credentials are yours).
  if ! remote="$(git -C "$src" ls-remote --heads origin "refs/heads/$target" 2>"$staging/ls.err")"; then
    warn "couldn't reach origin for $repo: $(safe_text "$(head -1 "$staging/ls.err")") -- skipped"
    continue
  fi
  remote_sha="${remote%%$'\t'*}"
  if [[ "$remote_sha" == "$sha" ]]; then
    echo "  origin/$target is already at ${sha:0:12} -- nothing to push"
    continue
  fi
  if [[ -n "$remote_sha" ]]; then
    if ! bare_git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
      # Not in the clone's history or the source checkout's: the remote
      # moved on in ways this sandbox never saw.
      warn "origin/$target has commits the clone doesn't (${remote_sha:0:12}) -- fetch and rebase inside the VM first. Not pushed."
      continue
    fi
    if ! bare_git merge-base --is-ancestor "$remote_sha" "$sha"; then
      warn "pushing would overwrite origin/$target (it isn't an ancestor of ${sha:0:12}), and make push never force-pushes -- rebase onto it inside the VM first. Not pushed."
      continue
    fi
    range=("$remote_sha..$sha")
  else
    # A new remote branch: show what isn't on any origin branch you know of.
    mapfile -t known < <(git -C "$src" for-each-ref --format='%(objectname)' refs/remotes/origin)
    range=("$sha" ${known[@]+--not "${known[@]}"})
  fi

  count="$(bare_git rev-list --count "${range[@]}")"
  what="creates"; [[ -n "$remote_sha" ]] && what="updates"
  echo "  $what origin/$target, $count commit(s):"
  # Commit messages are the agent's: printed through safe_text.
  while IFS= read -r line; do
    echo "    $(safe_text "$line")"
  done < <(bare_git log --format='%h %an: %s' --max-count=30 "${range[@]}")
  (( count <= 30 )) || echo "    ... and $(( count - 30 )) more"

  if [[ -z "${YES:-}" ]]; then
    if [[ ! -t 0 ]] && ! { : < /dev/tty; } 2>/dev/null; then
      die "no terminal to confirm in -- run it in one, or add YES=1"
    fi
    read -r -p "  Push? [y/N] " answer < /dev/tty || answer=""
    if [[ "${answer,,}" != y && "${answer,,}" != yes ]]; then
      echo "  skipped"
      continue
    fi
  fi

  if ! bare_git push --quiet "$url" "$sha:refs/heads/$target"; then
    warn "push of $repo failed (above) -- nothing recorded"
    continue
  fi
  mkdir -p "$state_dir"
  printf '%s %s\n' "$repo" "$sha" >> "$state_dir/pushed"
  echo "  ${C_GREEN}pushed${C_RESET} ${sha:0:12} to origin/$target"
  pushed_any=1
done

if [[ -n "${pushed_any:-}" ]]; then
  echo
  echo "The clones' own origin/* don't know about these pushes until they fetch (inside the VM, if it can reach origin)."
  echo "make destroy counts pushed commits as saved either way."
fi
