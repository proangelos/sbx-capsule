# shellcheck disable=SC2034  # globals set here are read by the files that source this one
# Cloning a repo into a sandbox, the banner for continuing an existing
# origin/PUSH_AS, and the staging repos make push and make fetch work in.
# Sourced via all.sh, not executed: no shebang, no `set -e`.

# clone_repo <repo> <n> <sandbox_dir> [requested_branch]
#
# Makes <sandbox_dir>/<repo> a full clone of the repo's source checkout and
# puts it on the sandbox branch. Why clones and not worktrees, and why from
# the local checkout: see docs/DESIGN.md.
# Callers run check_start_branches first, so failures here are rare
# (e.g. the network dropping mid-run).
#
# Branch: PUSH_AS if set (tracking origin/PUSH_AS), else sandbox/<n>/<repo>
# with no upstream. Start point, first match wins:
#   1. origin/PUSH_AS, if it already exists (and no different branch was
#      requested -- check_start_branches refuses that) -- continuing it is
#      the only way a bare `git push` can fast-forward it. Callers must
#      announce this loudly (resumed_banner).
#   2. the requested branch (repo:branch), on origin or local-only in the
#      source checkout
#   3. origin/<SOURCE_BRANCHES entry>
#
# Sets CLONE_BRANCH, CLONE_START (what it branched off), CLONE_REQUESTED (1
# for case 2), CLONE_RESUMED (1 for case 1) and CLONE_RESUMED_DETAIL
# (ahead/behind summary for case 1).
clone_repo() {
  local repo="$1" n="$2" sandbox_dir="$3" requested="${4:-}"
  local src="${REPOS[$repo]}" dest="$sandbox_dir/$repo"
  local source_branch="${SOURCE_BRANCHES[$repo]:-}"
  local url branch start_ref ahead behind

  CLONE_BRANCH="" CLONE_START="" CLONE_REQUESTED="" CLONE_RESUMED="" CLONE_RESUMED_DETAIL=""
  [[ -d "$src/.git" ]] || die "$repo source not found or not a git repo at $src"
  [[ -n "$source_branch" ]] || die "no SOURCE_BRANCHES entry for '$repo' in .env"
  [[ ! -e "$dest" ]] || die "$dest already exists"
  url="$(git -C "$src" remote get-url origin 2>/dev/null)" || die "$repo source at $src has no 'origin' remote"

  branch="sandbox/$n/$repo"
  [[ -n "${PUSH_AS:-}" ]] && branch="$PUSH_AS"

  # Seeded from the local checkout's origin/* branches, so history isn't
  # downloaded again; then origin points at the real remote and a fetch
  # pulls only what's newer than the checkout's last fetch. A fetch from a
  # path copies just the objects those branches reach, never hardlinks.
  # Not `git clone <src>`: on one filesystem that hardlinks the checkout's
  # object files, which the VM could then rewrite in place (changing your
  # checkout's history), and it copies every object, unpushed local
  # branches and stashes included. Never --shared/--reference either: they
  # leave the clone depending on a host path the sandbox VM can't see.
  git init --quiet "$dest"
  git -C "$dest" remote add origin "$url"
  git -C "$dest" fetch --quiet --no-tags "$src" '+refs/remotes/origin/*:refs/remotes/origin/*'
  if ! git -C "$dest" fetch --quiet --prune origin; then
    rm -rf "$dest"
    die "failed to fetch $url for $repo (on VPN?)"
  fi

  if [[ -n "${PUSH_AS:-}" ]] && { [[ -z "$requested" || "$requested" == "$PUSH_AS" ]]; } \
     && git -C "$dest" show-ref --verify --quiet "refs/remotes/origin/$PUSH_AS"; then
    start_ref="origin/$PUSH_AS"
    CLONE_START="$start_ref"
    CLONE_RESUMED=1
    if git -C "$dest" show-ref --verify --quiet "refs/remotes/origin/$source_branch"; then
      read -r behind ahead < <(git -C "$dest" rev-list --left-right --count "origin/$source_branch...$start_ref")
      CLONE_RESUMED_DETAIL="$ahead commit(s) ahead of origin/$source_branch, $behind behind"
    fi
  elif [[ -n "$requested" ]]; then
    CLONE_REQUESTED=1
    if git -C "$dest" show-ref --verify --quiet "refs/remotes/origin/$requested"; then
      start_ref="origin/$requested"
      CLONE_START="$start_ref"
    elif git -C "$src" show-ref --verify --quiet "refs/heads/$requested"; then
      git -C "$dest" fetch --quiet "$src" "refs/heads/$requested"
      start_ref="FETCH_HEAD"
      CLONE_START="$requested (local-only branch in $src)"
    else
      rm -rf "$dest"
      die "branch '$requested' for $repo is neither on origin nor local in $src"
    fi
  else
    if ! git -C "$dest" show-ref --verify --quiet "refs/remotes/origin/$source_branch"; then
      rm -rf "$dest"
      die "origin has no branch '$source_branch' for $repo"
    fi
    start_ref="origin/$source_branch"
    CLONE_START="$start_ref"
  fi

  # --no-track: otherwise git would make the branch track its start point
  # (e.g. origin/master), and a bare `git push` could land there.
  git -C "$dest" switch --quiet --no-track -c "$branch" "$start_ref"

  if [[ -n "${PUSH_AS:-}" ]]; then
    # Local and remote names match, so git's default push.default (simple)
    # sends a bare `git push` to origin/PUSH_AS -- creating it on first push.
    git -C "$dest" config "branch.$branch.remote" origin
    git -C "$dest" config "branch.$branch.merge" "refs/heads/$PUSH_AS"
  fi

  CLONE_BRANCH="$branch"
}

# resumed_banner <repo>  -- the loud notice for clone_repo's case 1.
resumed_banner() {
  local repo="$1" source_branch="${SOURCE_BRANCHES[$1]:-}" lines
  lines=(
    "${C_BOLD}NOTICE: origin/$PUSH_AS ALREADY EXISTS for $repo${C_RESET}"
    ""
    "$repo was branched from ${C_BOLD}origin/$PUSH_AS${C_RESET} (the existing remote branch),"
    "NOT from origin/$source_branch."
  )
  [[ -n "$CLONE_RESUMED_DETAIL" ]] && lines+=("origin/$PUSH_AS is $CLONE_RESUMED_DETAIL.")
  lines+=(
    ""
    "Work here continues that branch, so a bare \`git push\` fast-forwards it."
    "If you meant to start fresh: make destroy, then make new with another PUSH_AS."
  )
  banner "$C_YELLOW" "${lines[@]}"
}

# init_staging_repo <path> <source checkout>  -- a bare repo at <path> (in a
# .staging.* folder: outside every sandbox, so no VM can touch it) that
# borrows the source checkout's objects read-only through
# objects/info/alternates. Fetching origin into it, or a sandbox branch out
# of a clone, then copies only what the checkout doesn't already have, and
# the checkout itself isn't changed. Git run in it reads only your config
# and the tool's.
init_staging_repo() {
  local path="$1" src="$2" objects
  git init --quiet --bare "$path"
  objects="$(git -C "$src" rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
             || (cd "$src" && cd "$(git rev-parse --git-common-dir)" && pwd))/objects"
  printf '%s\n' "$objects" > "$path/objects/info/alternates"
}
