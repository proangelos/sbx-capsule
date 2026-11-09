# PUSH_AS checks: a valid branch, not a source branch, not already used by
# another sandbox. Appends to PROBLEMS (validate.sh).
# Sourced via all.sh, not executed: no shebang, no `set -e`.

# check_push_as <push_as> <repo>...  -- appends to PROBLEMS unless PUSH_AS is
# safe for every repo listed: a valid branch name, not a repo's .env source
# branch, and not already the push target of another sandbox for the same
# repo (two sandboxes pushing to one remote branch would overwrite each
# other's work).
check_push_as() {
  local push_as="$1" repo line
  shift
  if ! git check-ref-format --branch "$push_as" >/dev/null 2>&1; then
    # safe_text: PUSH_AS can come from the command line, as anything.
    PROBLEMS+=("PUSH_AS='$(safe_text "$push_as")' is not a valid branch name")
    return 0
  fi
  for repo in "$@"; do
    [[ "$push_as" == "${SOURCE_BRANCHES[$repo]:-}" ]] \
      && PROBLEMS+=("PUSH_AS='$push_as' is $repo's source branch in .env -- pushes would go straight to it. Pick a feature branch name")
    while IFS= read -r line; do
      [[ -n "$line" ]] && PROBLEMS+=("PUSH_AS=$push_as is already used for $repo by $line -- two sandboxes pushing to one branch would overwrite each other. Destroy that sandbox first, or pick a different PUSH_AS")
    done < <(push_as_users "$push_as" "$repo")
  done
  return 0
}

# push_as_users <push_as> <repo>  -- prints one line per other sandbox whose
# <repo> already tracks origin/<push_as>. Covers sandboxes under this
# checkout's SANDBOX_ROOT; those made by a different checkout of this tool
# aren't visible from here. PUSH_AS_SELF, if
# set, is the sandbox folder the caller is about, which never counts.
push_as_users() {
  local push_as="$1" repo="$2" ref="refs/heads/$1" d out rc err
  for d in "$SANDBOX_ROOT"/*/; do
    d="${d%/}"
    [[ "$d" == "${PUSH_AS_SELF:-}" ]] && continue
    is_sandbox_dir "$d" && is_clone "$d/$repo" || continue
    # git exits 1, saying nothing, when nothing matches. Anything else is a
    # clone sandbox_git refused or gave up on (hostile config, a hang): that
    # sandbox is skipped with a warning rather than failing the caller.
    rc=0 err="$(mktemp)"
    out="$(sandbox_git "$d/$repo" config --no-includes --get-regexp '^branch\..*\.merge$' 2>"$err")" || rc=$?
    if (( rc != 0 )) && [[ rc -ne 1 || -s "$err" ]]; then
      warn "couldn't read $repo's git config in sandbox $(safe_text "$(basename "$d")"), so it's left out of the PUSH_AS check: $(safe_text "$(head -1 "$err")")"
    fi
    rm -f -- "$err"
    [[ -n "$out" ]] || continue
    awk -v r="$ref" -v where="sandbox $(basename "$d") ($d/$repo)" '$2 == r { print where; exit }' <<< "$out"
  done
}
