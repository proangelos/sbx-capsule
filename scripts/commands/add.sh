#!/usr/bin/env bash
# Add repos to an existing sandbox, cloned the same way create.sh clones
# (same PUSH_AS branch and tracking), and record each in the sandbox's
# README.md under "Repos added after creation".
#
# Usage: scripts/commands/add.sh <sandbox number> "<repo>[:<branch>] ..."
#        (or: make add N=3 REPO="worker web:fix/retry")
#
# A repo starts from SOURCE_BRANCHES[repo] in your .env unless you name a
# branch after ':'. Everything is checked first, and every problem listed at
# once, before any repo is cloned.
#
# Run it on the host: an agent inside the sbx VM can't see the source
# checkouts. New folders appear in a running VM right away, since the whole
# sandbox folder is mounted -- which is why each clone is built in a staging
# folder outside the sandbox and only moved in once it's finished.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

n="${1:-}" specs="${2:-}"
[[ -n "$n" && -n "$specs" ]] || die "usage: make add N=<sandbox number> REPO=\"<repo>[:<branch>] ...\""
validate_config
sandbox_dir="$(find_sandbox_dir "$n")"
read_push_as "$sandbox_dir" \
  || die "sandbox $n has no record of its PUSH_AS ($(state_dir_of "$sandbox_dir")/push_as), so it wasn't made by make new here -- make a new sandbox with make new"

PROBLEMS=()
PUSH_AS="$SANDBOX_PUSH_AS"
parse_repo_specs "REPO" "$specs"
for repo in "${SPEC_REPOS[@]}"; do
  [[ ! -e "$sandbox_dir/$repo" ]] || PROBLEMS+=("REPO: $repo is already in sandbox $n ($sandbox_dir/$repo)")
done
(( ${#SPEC_REPOS[@]} )) && check_start_branches "${SPEC_REPOS[@]}"
[[ -z "$PUSH_AS" ]] || check_push_as "$PUSH_AS" ${SPEC_REPOS[@]+"${SPEC_REPOS[@]}"}
report_problems "can't add to sandbox $n:"

readme="$sandbox_dir/README.md"
marker="<!-- make add inserts entries above this line -->"

# Clones are built here, outside the sandbox, and moved in once finished: a
# running VM sees the sandbox folder live, and an agent could otherwise edit
# a half-made clone's .git/config before this script's own git commands on
# it (fetch, switch) ran -- core.sshCommand, say, which fetch would run.
staging="$(mktemp -d "$SANDBOX_ROOT/.staging.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT

resumed=()
for repo in "${SPEC_REPOS[@]}"; do
  echo "Adding $repo to sandbox $n"
  clone_repo "$repo" "$n" "$staging" "${SPEC_BRANCH[$repo]}"
  dest="$sandbox_dir/$repo"
  [[ ! -e "$dest" && ! -L "$dest" ]] \
    || die "something named $repo appeared in sandbox $n while it was being cloned -- the new clone was left out. Check $dest, then run make add again"
  move_into_sandbox "$staging/$repo" "$sandbox_dir" \
    || die "couldn't move the $repo clone into place: something appeared at $dest while it moved -- check $dest, then run make add again"
  echo "  ${C_GREEN}$repo${C_RESET}: branch $CLONE_BRANCH off $CLONE_START"

  entry="- **$repo** -- ${REPO_DESC[$repo]:+${REPO_DESC[$repo]}; }branch \`$CLONE_BRANCH\` off \`$CLONE_START\`"
  [[ -n "$CLONE_REQUESTED" ]] && entry+=" (requested; \`.env\` default is \`${SOURCE_BRANCHES[$repo]}\`)"
  if [[ -n "$CLONE_RESUMED" ]]; then
    resumed+=("$repo")
    entry+=" -- **continues the existing remote branch**${CLONE_RESUMED_DETAIL:+ ($CLONE_RESUMED_DETAIL)}"
  fi
  entry+=" (added $(date '+%Y-%m-%d'))"

  # The README is the agent's to edit too, so it's never opened by name in
  # the sandbox: snapshot_sandbox_file links it into staging first, and only
  # if it's a regular file (a symlink could point at any host file, a FIFO
  # would hang). The new version is built in staging and moved over it,
  # never written through whatever is there now.
  rm -f -- "$staging/README.orig"
  if snapshot_sandbox_file "$readme" "$staging/README.orig" \
     && grep -qF "$marker" "$staging/README.orig" \
     && awk -v entry="$entry" -v marker="$marker" '
          /^_None yet\._$/ { next }   # the placeholder line only, not the instructions above it
          index($0, marker) == 1 { print entry }
          { print }
        ' "$staging/README.orig" > "$staging/README.md" \
     && move_into_sandbox "$staging/README.md" "$sandbox_dir"; then
    echo "  recorded in README.md under \"Repos added after creation\""
  else
    warn "couldn't update the \"Repos added after creation\" list in $readme -- record this by hand:"
    echo "  $entry"
  fi

  [[ -n "$CLONE_RESUMED" ]] && resumed_banner "$repo"
done
exit 0
