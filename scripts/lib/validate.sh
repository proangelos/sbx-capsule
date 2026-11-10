# Validation: collect everything wrong, then report it all at once. Config
# checks (.env.default, .env), repo:branch spec parsing, start branches.
# Sourced via all.sh, not executed: no shebang, no `set -e`.

# Callers reset PROBLEMS=(), run any of the check_* / parse_* helpers below
# (which append to it), then call report_problems before creating anything.
PROBLEMS=()

# report_problems <title>  -- if PROBLEMS is non-empty, print them all and exit.
report_problems() {
  (( ${#PROBLEMS[@]} )) || return 0
  local p
  echo "${C_RED}${C_BOLD}error:${C_RESET} $1" >&2
  for p in "${PROBLEMS[@]}"; do
    echo "  ${C_RED}-${C_RESET} $p" >&2
  done
  echo "Nothing was created or changed." >&2
  exit 1
}

# known_repos  -- the repo names defined in .env, space-separated, sorted.
known_repos() {
  (( ${#REPOS[@]} )) || { echo "(none)"; return; }
  printf '%s\n' "${!REPOS[@]}" | sort | paste -sd' ' -
}

# validate_config [warn]  -- checks .env.default and .env (see .env.example). Exits listing
# every problem; with "warn", prints them as a warning and carries on (for
# destroy.sh, so old sandboxes can always be torn down).
validate_config() {
  local mode="${1:-}"
  PROBLEMS=()
  check_config
  (( ${#PROBLEMS[@]} )) || return 0
  if [[ "$mode" == warn ]]; then
    warn "problems in your config (.env.default, .env in $TOOL_ROOT) (carrying on):"
    printf '  - %s\n' "${PROBLEMS[@]}" >&2
    PROBLEMS=()
    return 0
  fi
  report_problems "problems in your config (.env.default, .env in $TOOL_ROOT):"
}

# check_config  -- the checks behind validate_config: the agent settings,
# then .env itself. Appends to PROBLEMS (doctor.sh uses it directly, to list
# config problems alongside everything else rather than exiting).
check_config() {
  local r
  check_agent_config
  if [[ ! -f "$ENV_FILE" ]]; then
    PROBLEMS+=("no $ENV_FILE -- nothing is defined by default. Create it with \`make init\`, then define your repos")
  else
    (( ${#REPOS[@]} )) || PROBLEMS+=("no repos defined -- add entries to REPOS")
    # Keys are read a line at a time, not word-split, so a key with a space
    # in it is reported as invalid instead of crashing the check.
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      [[ "$r" =~ ^[A-Za-z0-9._-]+$ ]] || PROBLEMS+=("REPOS key '$r' isn't a valid name (letters, digits, '.', '_' and '-' only)")
      [[ -n "${REPOS[$r]}" ]] || PROBLEMS+=("REPOS[$r] has no path")
      [[ -n "${SOURCE_BRANCHES[$r]:-}" ]] || PROBLEMS+=("REPOS[$r] has no SOURCE_BRANCHES[$r] entry (the branch sandboxes start from)")
    done < <(printf '%s\n' "${!REPOS[@]}" | sort)
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      [[ -n "${REPOS[$r]:-}" ]] || PROBLEMS+=("SOURCE_BRANCHES[$r] is set, but REPOS[$r] isn't")
    done < <(printf '%s\n' "${!SOURCE_BRANCHES[@]}" | sort)
    for r in "${DEFAULT_REPOS[@]}"; do
      [[ -n "${REPOS[$r]:-}" ]] || PROBLEMS+=("DEFAULT_REPOS lists '$r', which isn't in REPOS (defined: $(known_repos))")
    done
  fi
  return 0
}

# check_agent_config  -- the agent settings: defaults from .env.default,
# overridden by .env. Without .env.default they'd all be empty, so that's
# the one problem reported. Appends to PROBLEMS.
check_agent_config() {
  local a f word
  if [[ ! -f "$DEFAULTS_FILE" ]]; then
    PROBLEMS+=("$DEFAULTS_FILE is missing (the tool's tracked defaults) -- restore it: git -C $TOOL_ROOT checkout -- .env.default")
    return 0
  fi
  # AGENT may name a profile (user-config/agents/<name>.env): resolve_agent
  # in profiles.sh checks it, and the profile, whichever it is.
  # A command-line AGENT= is checked by the command that takes it
  # (choose_agent), so it isn't reported twice.
  resolve_agent "$AGENT" "AGENT" || true
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    if is_builtin_agent "$a" || is_kit_ref "$a"; then
      :
    elif has_profile "$a"; then
      PROBLEMS+=("AGENT_ARGS[$a]: '$a' is a profile -- set ARGS in $(profile_file "$a") instead")
    else
      PROBLEMS+=("AGENT_ARGS[$a]: '$a' isn't an sbx agent (built in: ${SBX_AGENTS[*]}) or a kit reference")
    fi
  done < <(printf '%s\n' "${!AGENT_ARGS[@]}" | sort)
  [[ "$AGENT_GIT_PUSH" == yes || "$AGENT_GIT_PUSH" == no ]] \
    || PROBLEMS+=("AGENT_GIT_PUSH='$AGENT_GIT_PUSH' -- use yes or no")
  # Guarded: bash before 4.4 calls an empty array unbound under set -u.
  local i
  if (( ${#AGENT_INSTRUCTIONS[@]} )); then
    for i in "${!AGENT_INSTRUCTIONS[@]}"; do
      [[ "${AGENT_INSTRUCTIONS[$i]}" =~ [^[:space:]] ]] \
        || PROBLEMS+=("AGENT_INSTRUCTIONS[$i] is empty -- remove the entry, or write the instruction")
    done
  fi
  if [[ -n "$SANDBOX_NOTES_FILE" && ! ( -f "$SANDBOX_NOTES_FILE" && -r "$SANDBOX_NOTES_FILE" ) ]]; then
    PROBLEMS+=("SANDBOX_NOTES_FILE='$SANDBOX_NOTES_FILE' isn't a readable file")
  fi
  if [[ -n "$VSCODE_USER_DIR" && ! -d "$VSCODE_USER_DIR" ]]; then
    PROBLEMS+=("VSCODE_USER_DIR='$VSCODE_USER_DIR' isn't a folder -- point it at the folder holding your VS Code user settings.json, or empty it")
  fi
  # Room is left for "-<checkout id>-" and a sandbox folder name: sbx
  # refuses names over SBX_NAME_MAX characters (make new checks the whole
  # name against TITLE).
  if [[ -n "$SBX_NAME_PREFIX" ]]; then
    if [[ ! "$SBX_NAME_PREFIX" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      PROBLEMS+=("SBX_NAME_PREFIX='$SBX_NAME_PREFIX' can't start an sbx VM name -- use lowercase letters, digits and '-' (not at either end), or empty it for no prefix")
    elif (( ${#SBX_NAME_PREFIX} > 32 )); then
      PROBLEMS+=("SBX_NAME_PREFIX is ${#SBX_NAME_PREFIX} characters -- keep it to 32 or fewer: sbx refuses VM names over $SBX_NAME_MAX, and the checkout id and sandbox folder name come after it")
    fi
  fi
  check_sbx_create_flags SBX_CREATE_FLAGS "$SBX_CREATE_FLAGS"
}

# check_sbx_create_flags <label> <flags>  -- SBX_CREATE_FLAGS (or a
# profile's CREATE_FLAGS) goes to `sbx run` before the
# agent and the sandbox folder, so it must hold flags only: a bare word
# there would be one more folder for sbx to mount, writable. Each flag that
# takes a value (SBX_VALUE_FLAGS) consumes the next word; any other bare
# word is refused, so a flag sbx adds later passes as --flag=value. Also
# refused: the flags the tool manages (SBX_RESERVED_FLAGS), --mount (binds
# a host folder into the VM), --skills readwrite (the agent could write
# skills your host agent loads), and a local path for --kit,
# --kit-args-file or --env-file that's missing or inside a sandbox folder
# (check_path_flag in profiles.sh). Paths can't contain spaces: the flags
# are split on whitespace.
check_sbx_create_flags() {
  local label="$1" flags="$2"
  local words=() i=0 word flag val f takes
  read -r -a words <<< "$flags"
  while (( i < ${#words[@]} )); do
    word="${words[i]}"; i=$((i + 1))
    if [[ "$word" != -* ]]; then
      PROBLEMS+=("$label: '$(safe_text "$word")' isn't a flag, and sbx would mount it as another folder the VM can write -- remove it (for a flag sbx added after this tool, write --flag=value)")
      continue
    fi
    flag="${word%%=*}" val=""
    takes=""
    for f in "${SBX_VALUE_FLAGS[@]}"; do [[ "$flag" == "$f" ]] && takes=1; done
    if [[ "$word" == *=* ]]; then
      val="${word#*=}"
    elif [[ -n "$takes" ]] && (( i < ${#words[@]} )); then
      val="${words[i]}"; i=$((i + 1))
    fi
    for f in "${SBX_RESERVED_FLAGS[@]}"; do
      [[ "$flag" == "$f" ]] && PROBLEMS+=("$label: '$f' is managed by this tool and can't be passed through")
    done
    case "$flag" in
      --mount)
        PROBLEMS+=("$label: --mount binds a host folder into the VM, out of reach of the tool's mount checks -- remove it") ;;
      --skills)
        [[ "${val,,}" == readwrite ]] && PROBLEMS+=("$label: --skills readwrite lets the agent write the skills your agent on the host loads -- use readonly or off") ;;
      --kit|--kit-args-file|--env-file)
        if [[ -z "$val" ]]; then
          PROBLEMS+=("$label: $flag needs a value")
        else
          check_path_flag "$label: $flag" "$flag" "$val"
        fi ;;
    esac
  done
  return 0
}

# parse_repo_specs <label> <specs>  -- splits "repo[:branch] ..." (the WITH
# and make add syntax) into SPEC_REPOS (order kept, duplicates merged) and
# SPEC_BRANCH[repo] (the requested start branch, or empty for the .env one).
# ':' can't appear in a git branch name, so the split is never ambiguous.
# Appends to PROBLEMS.
parse_repo_specs() {
  local label="$1" spec repo branch
  SPEC_REPOS=()
  declare -gA SPEC_BRANCH=()
  for spec in $2; do
    repo="${spec%%:*}" branch=""
    [[ "$spec" == *:* ]] && branch="${spec#*:}"
    if [[ "$spec" == *:*:* ]]; then
      PROBLEMS+=("$label: '$spec' has more than one ':' -- use repo or repo:branch"); continue
    elif [[ -z "$repo" ]]; then
      PROBLEMS+=("$label: '$spec' has no repo name before ':'"); continue
    elif [[ -z "${REPOS[$repo]:-}" ]]; then
      PROBLEMS+=("$label: unknown repo '$repo' -- not in your .env (defined: $(known_repos))"); continue
    elif [[ "$spec" == *: ]]; then
      PROBLEMS+=("$label: '$spec' has nothing after ':' -- drop the ':' to start from SOURCE_BRANCHES[$repo] (${SOURCE_BRANCHES[$repo]:-unset})"); continue
    elif [[ -n "$branch" ]] && ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
      PROBLEMS+=("$label: '$branch' (for $repo) isn't a valid branch name"); continue
    fi
    if [[ -v "SPEC_BRANCH[$repo]" ]]; then
      [[ "${SPEC_BRANCH[$repo]}" == "$branch" ]] \
        || PROBLEMS+=("$label: $repo is named twice with different branches ('${SPEC_BRANCH[$repo]:-<.env default>}' and '${branch:-<.env default>}')")
      continue
    fi
    SPEC_REPOS+=("$repo")
    SPEC_BRANCH[$repo]="$branch"
  done
}

# check_start_branches <repo>...  -- before anything is created, checks with
# one `git ls-remote` per repo that each source checkout is usable and its
# start branch (SPEC_BRANCH, else SOURCE_BRANCHES) exists on origin or, for a
# requested branch, locally in the checkout. Also refuses a requested branch
# when origin/<PUSH_AS> already exists and differs from it: a push from the
# sandbox would be rejected. Appends to PROBLEMS.
check_start_branches() {
  local repo src start requested out url
  for repo in "$@"; do
    src="${REPOS[$repo]}"
    requested="${SPEC_BRANCH[$repo]:-}"
    start="${requested:-${SOURCE_BRANCHES[$repo]}}"
    if [[ ! -d "$src/.git" ]]; then
      PROBLEMS+=("$repo: source checkout not found, or not a git repo, at $src"); continue
    fi
    if ! url="$(git -C "$src" remote get-url origin 2>/dev/null)"; then
      PROBLEMS+=("$repo: source checkout at $src has no 'origin' remote"); continue
    fi
    if ! out="$(git -C "$src" ls-remote --heads origin "refs/heads/$start" ${PUSH_AS:+"refs/heads/$PUSH_AS"} 2>&1)"; then
      PROBLEMS+=("$repo: couldn't reach $url (on VPN?)"); continue
    fi
    if ! grep -q $'\trefs/heads/'"$start"'$' <<< "$out"; then
      if [[ -n "$requested" ]] && git -C "$src" show-ref --verify --quiet "refs/heads/$start"; then
        :   # a local-only branch in the source checkout is fine for a requested start
      elif [[ -n "$requested" ]]; then
        PROBLEMS+=("$repo: branch '$start' isn't on origin, or local in $src")
      else
        PROBLEMS+=("$repo: SOURCE_BRANCHES[$repo]='$start' isn't on origin -- fix it in .env, or name a branch with $repo:<branch>")
      fi
    fi
    if [[ -n "$requested" && -n "${PUSH_AS:-}" && "$requested" != "$PUSH_AS" ]] \
       && grep -q $'\trefs/heads/'"$PUSH_AS"'$' <<< "$out"; then
      PROBLEMS+=("$repo: you asked to start from '$requested', but origin/$PUSH_AS already exists, so pushing from this sandbox would be rejected. Drop ':$requested' to continue origin/$PUSH_AS, or pick a different PUSH_AS")
    fi
  done
}
