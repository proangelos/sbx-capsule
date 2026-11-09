#!/usr/bin/env bash
# Fetch what's new on a repo's origin for a sandbox clone, from the host,
# and hand it to the agent as a git bundle file: without running git in the
# clone (its .git/config and hooks are the agent's, and plain git there
# would run them as you), and without the VM needing network access to your
# git host or your credentials.
#
# Usage: scripts/commands/fetch.sh <sandbox number> ["<repo> ..."]
#        (or: make fetch N=3 [REPO="api web"])
#   REPO   the clones to fetch for; default: every clone in the sandbox
#          that's a repo in your .env.
#
# How, per repo:
#   1. A bare repo in a .staging.* folder outside the sandbox, borrowing the
#      source checkout's objects read-only (init_staging_repo, as make push
#      does), fetches origin's branches with your config and credentials.
#      The source checkout isn't changed.
#   2. `git ls-remote <clone>` lists what the clone has. Like make push's
#      fetch, it runs git upload-pack there, which is safe on an untrusted
#      repo. Those refs are the agent's claim: they only decide what's left
#      out of the bundle, and a false one just makes the bundle fail to
#      apply.
#   3. A bundle of origin's branches that differ from the clone's
#      origin/*, holding only the commits the clone lacks, is built in
#      staging and moved to the sandbox root as .fetch-<repo>.bundle,
#      without following symlinks (move_into_sandbox). It's put together by
#      hand rather than with `git bundle create`, which drops a branch
#      whose new tip the clone already has -- the usual case right after
#      make push. The agent applies it inside the VM:
#        git -C <repo> fetch ../.fetch-<repo>.bundle '+refs/remotes/origin/*:refs/remotes/origin/*'
#
# A bundle holds only commits on origin's branches, nothing local to your
# source checkout. Tags aren't included. make destroy deletes
# .fetch-*.bundle files with the other generated files.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

n="${1:-}" specs="${2:-}"
[[ -n "$n" ]] || die "usage: make fetch N=<sandbox number> [REPO=\"<repo> ...\"]"
validate_config
warn_old_git
sandbox_dir="$(find_sandbox_dir "$n")"

# ---- which clones ----
PROBLEMS=()
repos=()
if [[ -z "$specs" ]]; then
  for d in "$sandbox_dir"/*/; do
    d="${d%/}" r="${d##*/}"
    if [[ -n "${REPOS[$r]:-}" && ! -L "$d" ]] && is_clone "$d"; then repos+=("$r"); fi
  done
  (( ${#repos[@]} )) || PROBLEMS+=("sandbox $n has no clones of repos in your .env (defined: $(known_repos))")
else
  for repo in $specs; do
    if [[ -z "${REPOS[$repo]:-}" ]]; then
      PROBLEMS+=("REPO: unknown repo '$(safe_text "$repo")' -- not in your .env (defined: $(known_repos))"); continue
    fi
    clone="$sandbox_dir/$repo"
    if [[ -L "$clone" || ! -d "$clone" ]] || ! is_clone "$clone"; then
      PROBLEMS+=("REPO: $repo isn't a clone in sandbox $n ($clone)"); continue
    fi
    repos+=("$repo")
  done
fi
for repo in ${repos[@]+"${repos[@]}"}; do
  git -C "${REPOS[$repo]}" remote get-url origin >/dev/null 2>&1 \
    || PROBLEMS+=("$repo: its source checkout (${REPOS[$repo]}) has no 'origin' remote to fetch from")
done
report_problems "can't fetch for sandbox $n:"

staging="$(mktemp -d "$SANDBOX_ROOT/.staging.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT

# git on the staging repo: yours and the tool's config only; the pager off.
# shellcheck disable=SC2209  # GIT_PAGER=cat is an env prefix for git, not an assignment
staging_git() { GIT_PAGER=cat git -C "$staging/fetch.git" "$@"; }

# write_bundle <file> <tip refs> <haves>  -- a v2 bundle (gitformat-bundle):
# a header naming the prerequisite commits (the boundary of what's left
# out) and each "<sha> <ref>", a blank line, then a thin pack of everything
# reachable from the tips but not from the haves (possibly empty, when only
# refs moved). <tip refs> and <haves> are newline-separated.
write_bundle() {
  local out="$1" tips="$2" haves="$3" revs
  revs="$(cut -d' ' -f1 <<< "$tips")"
  # shellcheck disable=SC2001  # prefixes every line; sed says so more plainly
  [[ -z "$haves" ]] || revs+=$'\n'"$(sed 's/^/^/' <<< "$haves")"
  {
    echo '# v2 git bundle'
    staging_git rev-list --boundary --stdin <<< "$revs" | sed -n 's/^-\([0-9a-f]*\)$/-\1 /p'
    printf '%s\n\n' "$tips"
    staging_git pack-objects --revs --stdout --thin --delta-base-offset -q <<< "$revs"
  } > "$out"
}

made=()
for repo in "${repos[@]}"; do
  src="${REPOS[$repo]}" clone="$sandbox_dir/$repo"
  url="$(git -C "$src" remote get-url origin)"
  echo
  echo "${C_BOLD}$repo${C_RESET}: fetching $url"

  rm -rf -- "$staging/fetch.git" "$staging/.fetch-$repo.bundle"
  init_staging_repo "$staging/fetch.git" "$src"
  if ! staging_git fetch --quiet --no-tags "$url" '+refs/heads/*:refs/remotes/origin/*' 2>"$staging/err"; then
    warn "couldn't fetch $url for $repo (on VPN?): $(safe_text "$(head -1 "$staging/err")") -- skipped"
    continue
  fi

  # What the clone has, by its own account. Only well-formed object names
  # that also exist here are used; its ref names are only compared.
  # ls-remote runs upload-pack in the clone, which reads its config: the
  # same pre-check and time limit as sandbox_git keep a hostile one from
  # hanging this.
  if ! sandbox_git_precheck "$clone" 2>"$staging/err" \
     || ! listed="$(run_with_timeout env GIT_PAGER=cat GIT_ALLOW_PROTOCOL=file \
                      git -C "$staging/fetch.git" ls-remote "$clone" 2>"$staging/err")"; then
    warn "couldn't read $repo's clone: $(safe_text "$(head -1 "$staging/err")") -- skipped"
    continue
  fi
  declare -A clone_origin=()
  haves=""
  while IFS=$'\t' read -r sha ref; do
    [[ "$sha" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || continue
    [[ "$ref" == refs/remotes/origin/* ]] && clone_origin[${ref#refs/remotes/origin/}]="$sha"
    staging_git cat-file -e "$sha" 2>/dev/null && haves+="$sha"$'\n'
  done <<< "$listed"
  haves="$(sort -u <<< "$haves" | sed '/^$/d')"

  tips=""
  while read -r sha ref; do
    b="${ref#refs/remotes/origin/}"
    old="${clone_origin[$b]:-}"
    [[ "$old" == "$sha" ]] && continue
    tips+="$sha $ref"$'\n'
    if [[ -z "$old" ]]; then
      echo "  origin/$b: new, at ${sha:0:12}"
    elif ! staging_git cat-file -e "$old^{commit}" 2>/dev/null; then
      echo "  origin/$b: ${old:0:12} -> ${sha:0:12}"
    elif [[ -n "$(staging_git rev-list -1 "$sha..$old")" ]]; then
      echo "  origin/$b: ${old:0:12} -> ${sha:0:12} (rewritten: not a fast-forward)"
    else
      echo "  origin/$b: ${old:0:12} -> ${sha:0:12}, $(staging_git rev-list --count "$old..$sha") new commit(s)"
    fi
  done < <(staging_git for-each-ref --format='%(objectname) %(refname)' refs/remotes/origin/)
  unset clone_origin
  tips="${tips%$'\n'}"
  if [[ -z "$tips" ]]; then
    echo "  the clone's origin/* are up to date -- nothing to hand over"
    continue
  fi

  # Named in staging as it's named in the sandbox (move_into_sandbox).
  bundle="$staging/.fetch-$repo.bundle"
  write_bundle "$bundle" "$tips" "$haves"
  staging_git bundle verify --quiet "$bundle" >/dev/null 2>"$staging/err" \
    || die "the bundle for $repo didn't verify: $(head -1 "$staging/err")"
  dest="$sandbox_dir/.fetch-$repo.bundle"
  move_into_sandbox "$bundle" "$sandbox_dir" \
    || die "couldn't move the bundle into place: something is at $dest that a file can't replace (a folder?) -- look at it, then run make fetch again"
  echo "  ${C_GREEN}ready${C_RESET}: $dest ($(du -h "$dest" | cut -f1))"
  made+=("$repo")
done

if (( ${#made[@]} )); then
  echo
  echo "Tell the agent to apply it inside the VM, from the sandbox folder:"
  for repo in "${made[@]}"; do
    echo "  git -C $repo fetch ../.fetch-$repo.bundle '+refs/remotes/origin/*:refs/remotes/origin/*'"
  done
  echo "Then it can rebase or merge as you agree. Branches deleted on origin stay in the clone."
fi
