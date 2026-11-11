# shellcheck disable=SC2034  # globals set here are read by the files that source this one
# Agent profiles, the user-config/ folder, paths in kit flags, and each
# sandbox's saved agent. Sourced via all.sh (after sandbox.sh, for
# is_sandbox_name and state_dir_of), not executed: no shebang, no `set -e`.
#
# user-config/ (gitignored, next to .env) holds the user's own files: agent
# profiles in user-config/agents/<name>.env, local kits, kit args files. No
# VM mounts it, so no agent can change what the next VM is created with.
# user-config.example/ (tracked) shows the layout.
#
# A profile is plain bash, like .env, setting only PROFILE_VARS:
#   AGENT         a built-in sbx agent or a kit reference (what .env's AGENT is)
#   ARGS          the agent's arguments (what AGENT_ARGS[<agent>] is in .env)
#   CREATE_FLAGS  sbx run flags for creating its VM, added after
#                 SBX_CREATE_FLAGS; never -e/--env/--env-file (see below)
#   CREDENTIALS   names of the sbx secrets it needs (never their values)
# It's read in a subshell, and anything else it sets is refused by name.
#
# The agent a sandbox runs is, first to last: AGENT=<spec> on the make
# command line (CLI_AGENT, from the Makefile), the sandbox's saved agent
# (.state/<n>/agent, written when one was named on the command line), then
# AGENT in .env. A spec is a profile name, a built-in agent or a kit ref
# (resolve_agent).

USER_CONFIG_DIR="$TOOL_ROOT/user-config"
PROFILES_DIR="$USER_CONFIG_DIR/agents"
PROFILE_VARS=(AGENT ARGS CREATE_FLAGS CREDENTIALS)

# The sbx run flags whose value is a local path, made absolute against
# TOOL_ROOT and kept out of sandbox folders. --kit's value may also be a
# remote kit (an OCI ref or git URL), which is left alone (is_local_ref).
PATH_FLAGS=(--kit --kit-args-file --env-file)

# tool_path <path>  -- an absolute path: relative ones are taken from
# TOOL_ROOT, never from the directory make was run in.
tool_path() {
  local p="$1"
  [[ "$p" == /* ]] && { printf '%s\n' "$p"; return; }
  printf '%s/%s\n' "$TOOL_ROOT" "${p#./}"
}

# is_local_ref <ref>  -- true if a kit reference is a path on this machine:
# absolute, ./ or ../, or a relative path that exists under TOOL_ROOT.
# Anything else (dhi.io/pi:latest, a git URL) is for sbx to fetch.
is_local_ref() {
  [[ "$1" == /* || "$1" == ./* || "$1" == ../* ]] && return 0
  [[ "$1" != *://* && -e "$TOOL_ROOT/$1" ]]
}

# real_path <path>  -- tool_path with every symlink resolved, through to the
# last component, so a link can't hide where a path really points. Parts
# that don't exist are kept as written.
real_path() {
  local p d hops=0 t
  p="$(tool_path "$1")"
  while :; do
    d="$(dirname "$p")"
    [[ -d "$d" ]] && d="$(cd "$d" && pwd -P)"
    p="${d%/}/$(basename "$p")"
    if [[ ! -L "$p" ]] || (( hops++ >= 20 )); then break; fi
    t="$(readlink "$p")"
    [[ "$t" == /* ]] && p="$t" || p="$d/$t"
  done
  [[ -d "$p" ]] && p="$(cd "$p" && pwd -P)"
  printf '%s\n' "$p"
}

# in_sandbox_folder <path>  -- true if the path is in (or is) a sandbox
# folder, which its VM can write.
in_sandbox_folder() {
  local p root first
  p="$(real_path "$1")"
  root="$(cd "$SANDBOX_ROOT" && pwd -P)"
  [[ "$p" == "$root"/* ]] || return 1
  first="${p#"$root"/}"
  is_sandbox_name "${first%%/*}"
}

# check_local_path <label> <path> [file|dir|any]  -- a local path the tool
# hands to sbx: it must exist, and not be in a sandbox folder. Appends to
# PROBLEMS.
check_local_path() {
  local label="$1" p="$2" kind="${3:-any}" abs
  abs="$(tool_path "$p")"
  if in_sandbox_folder "$abs"; then
    PROBLEMS+=("$label: $(safe_text "$p") is inside a sandbox folder, which its VM can write, so the agent could change what the next VM is created with -- move it to $USER_CONFIG_DIR")
  elif [[ ! -e "$abs" ]]; then
    PROBLEMS+=("$label: $(safe_text "$p") doesn't exist (relative paths are taken from $TOOL_ROOT)")
  elif [[ "$kind" == file && ! -f "$abs" ]]; then
    PROBLEMS+=("$label: $(safe_text "$p") isn't a file")
  fi
  return 0
}

# check_path_flag <label> <flag> <value>  -- check_local_path for one of
# PATH_FLAGS, skipping a remote --kit.
check_path_flag() {
  case "$2" in
    --kit) is_local_ref "$3" && check_local_path "$1" "$3" ;;
    --kit-args-file|--env-file) check_local_path "$1" "$3" file ;;
  esac
  return 0
}

# resolve_create_flags <flags>  -- appends the words of <flags> to
# CREATE_ARGV, with every PATH_FLAGS value made absolute (tool_path), in
# both spellings (--kit x and --kit=x). Run after check_sbx_create_flags.
CREATE_ARGV=()
resolve_create_flags() {
  local words=() i=0 word flag f
  [[ -n "$1" ]] || return 0
  read -r -a words <<< "$1"
  while (( i < ${#words[@]} )); do
    word="${words[i]}"; i=$((i + 1))
    flag="${word%%=*}"
    for f in "${PATH_FLAGS[@]}"; do
      [[ "$flag" == "$f" ]] || continue
      if [[ "$word" == *=* ]]; then
        { [[ "$f" != --kit ]] || is_local_ref "${word#*=}"; } && word="$f=$(tool_path "${word#*=}")"
      elif (( i < ${#words[@]} )); then
        CREATE_ARGV+=("$word")
        word="${words[i]}"; i=$((i + 1))
        { [[ "$f" != --kit ]] || is_local_ref "$word"; } && word="$(tool_path "$word")"
      fi
    done
    CREATE_ARGV+=("$word")
  done
}

# ---- profiles ----

is_profile_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
profile_file() { printf '%s/%s.env\n' "$PROFILES_DIR" "$1"; }
has_profile() { is_profile_name "$1" && [[ -f "$(profile_file "$1")" ]]; }

# list_profiles  -- the profile names in user-config/agents/, sorted.
list_profiles() {
  local f
  for f in "$PROFILES_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    f="${f##*/}"; f="${f%.env}"
    is_profile_name "$f" && printf '%s\n' "$f"
  done | LC_ALL=C sort
}

# _read_profile <file>  -- run in $( ), so in a subshell: sources the
# profile (into locals, so nothing it sets reaches the caller) and prints
# its PROFILE_VARS as P_<var>=<%q-quoted value> lines, plus P_UNKNOWN (the
# other variables it set) and P_ARRAYS (PROFILE_VARS it made arrays), for
# load_profile to eval. Exits 3 if sourcing fails.
_read_profile() {
  local before="" after="" v="" unknown="" arrays=""
  local AGENT="" ARGS="" CREATE_FLAGS="" CREDENTIALS=""
  before="$(compgen -v | LC_ALL=C sort)"
  # shellcheck source=/dev/null
  source "$1" > /dev/null 2>&1 || exit 3
  after="$(compgen -v | LC_ALL=C sort)"
  unknown="$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") \
             | grep -v -E '^(_|BASH.*|PIPESTATUS|OPTARG|OPTIND|REPLY|COLUMNS|LINES)$' | paste -sd' ' -)"
  for v in "${PROFILE_VARS[@]}"; do
    [[ "$(declare -p "$v" 2>/dev/null)" == "declare -"[aA]* ]] && arrays+="$v "
    printf 'P_%s=%q\n' "$v" "${!v}"
  done
  printf 'P_UNKNOWN=%q\nP_ARRAYS=%q\n' "$unknown" "${arrays% }"
}

# load_profile <name>  -- reads and checks user-config/agents/<name>.env.
# Sets PROFILE_AGENT, PROFILE_ARGS, PROFILE_CREATE_FLAGS,
# PROFILE_CREDENTIALS and PROFILE_FILE; appends to PROBLEMS and returns 1
# if anything is wrong.
load_profile() {
  local name="$1" f label out err word n0
  local P_AGENT="" P_ARGS="" P_CREATE_FLAGS="" P_CREDENTIALS="" P_UNKNOWN="" P_ARRAYS=""
  f="$(profile_file "$name")"
  label="profile $name ($f)"
  PROFILE_AGENT="" PROFILE_ARGS="" PROFILE_CREATE_FLAGS="" PROFILE_CREDENTIALS="" PROFILE_FILE="$f"
  n0=${#PROBLEMS[@]}
  if in_sandbox_folder "$f"; then
    PROBLEMS+=("$label is inside a sandbox folder, which its VM can write -- keep $USER_CONFIG_DIR a real folder at the top of $TOOL_ROOT")
    return 1
  fi
  if ! err="$(bash -n "$f" 2>&1)"; then
    PROBLEMS+=("$label isn't valid bash: $(head -1 <<< "$err")")
    return 1
  fi
  if ! out="$(_read_profile "$f")"; then
    PROBLEMS+=("$label failed when read (it's run as bash, like .env) -- run it with bash to see why: bash $f")
    return 1
  fi
  eval "$out"
  [[ -z "$P_UNKNOWN" ]] \
    || PROBLEMS+=("$label sets $P_UNKNOWN -- a profile may only set ${PROFILE_VARS[*]}")
  [[ -z "$P_ARRAYS" ]] \
    || PROBLEMS+=("$label makes $P_ARRAYS an array -- use a plain string, e.g. ARGS=\"--model x\"")
  if [[ -z "$P_AGENT" ]]; then
    PROBLEMS+=("$label sets no AGENT -- set it to a built-in sbx agent (${SBX_AGENTS[*]}) or a kit reference")
  elif ! is_builtin_agent "$P_AGENT" && ! is_kit_ref "$P_AGENT"; then
    PROBLEMS+=("$label: AGENT='$(safe_text "$P_AGENT")' isn't a built-in sbx agent (${SBX_AGENTS[*]}) or a kit reference (a path, git URL or OCI ref); a profile can't name another profile")
  elif is_kit_ref "$P_AGENT" && is_local_ref "$P_AGENT"; then
    check_local_path "$label: AGENT" "$P_AGENT"
  fi
  check_sbx_create_flags "$label: CREATE_FLAGS" "$P_CREATE_FLAGS"
  # -e/--env/--env-file hand their values to the agent: credentials belong
  # in sbx secrets (CREDENTIALS), which the agent can't read.
  local words=()
  [[ -n "$P_CREATE_FLAGS" ]] && read -r -a words <<< "$P_CREATE_FLAGS"
  for word in ${words[@]+"${words[@]}"}; do
    case "$word" in
      -e|-e?*|--env|--env=*|--env-file|--env-file=*)
        PROBLEMS+=("$label: CREATE_FLAGS can't pass environment variables ($(safe_text "${word%%=*}")): the agent can read every one. Put API keys in sbx secrets (sbx secret set <service>) and list the names in CREDENTIALS") ;;
    esac
  done
  for word in $P_CREDENTIALS; do
    [[ "$word" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
      || PROBLEMS+=("$label: CREDENTIALS entry '$(safe_text "$word")' isn't an sbx secret name -- list names only (e.g. anthropic), never a key")
  done
  PROFILE_AGENT="$P_AGENT" PROFILE_ARGS="$P_ARGS" PROFILE_CREATE_FLAGS="$P_CREATE_FLAGS" PROFILE_CREDENTIALS="$P_CREDENTIALS"
  (( ${#PROBLEMS[@]} == n0 ))
}

# resolve_agent <spec> <where it came from>  -- what a spec (a profile name,
# built-in agent or kit ref) runs. Sets RUN_SPEC, RUN_PROFILE (the profile
# name, or empty), RUN_AGENT (what sbx runs), RUN_ARGS, RUN_CREATE_FLAGS
# (the profile's, added after SBX_CREATE_FLAGS) and RUN_CREDENTIALS.
# A profile wins over a built-in of the same name. Appends to PROBLEMS and
# returns 1 if it can't be run.
resolve_agent() {
  local spec="$1" from="$2"
  RUN_SPEC="$spec" RUN_PROFILE="" RUN_AGENT="" RUN_ARGS="" RUN_CREATE_FLAGS="" RUN_CREDENTIALS=""
  if [[ -z "$spec" ]]; then
    PROBLEMS+=("$from is empty -- set it to a profile in $PROFILES_DIR, or one of: ${SBX_AGENTS[*]}")
    return 1
  fi
  if [[ "$spec" != */* ]] && has_profile "$spec"; then
    load_profile "$spec" || return 1
    RUN_PROFILE="$spec" RUN_AGENT="$PROFILE_AGENT" RUN_ARGS="$PROFILE_ARGS"
    RUN_CREATE_FLAGS="$PROFILE_CREATE_FLAGS" RUN_CREDENTIALS="$PROFILE_CREDENTIALS"
  elif is_builtin_agent "$spec" || is_kit_ref "$spec"; then
    if is_kit_ref "$spec" && is_local_ref "$spec"; then
      local n0=${#PROBLEMS[@]}
      check_local_path "$from" "$spec"
      (( ${#PROBLEMS[@]} == n0 )) || return 1
    fi
    RUN_AGENT="$spec" RUN_ARGS="${AGENT_ARGS[$spec]:-}"
  else
    local known
    known="$(list_profiles | paste -sd' ' -)"
    PROBLEMS+=("$from: '$(safe_text "$spec")' isn't a profile (${known:-none} in $PROFILES_DIR), a built-in sbx agent (${SBX_AGENTS[*]}), or a kit reference (a path, git URL or OCI ref)")
    return 1
  fi
}

# choose_agent [sandbox_dir]  -- picks a sandbox's agent spec: AGENT= on
# the command line (CLI_AGENT), else the sandbox's saved agent, else AGENT
# from .env. Sets SANDBOX_AGENT (the saved one, or empty), AGENT_SPEC,
# AGENT_FROM (where it came from, for messages), and the RUN_* values
# (resolve_agent). Problems with .env's AGENT are already reported by
# check_agent_config, so they aren't added twice. Returns 1 if it can't run.
choose_agent() {
  local n0
  SANDBOX_AGENT=""
  [[ -n "${1:-}" ]] && read_saved_agent "$1"
  if [[ -n "${CLI_AGENT:-}" ]]; then
    AGENT_SPEC="$CLI_AGENT" AGENT_FROM="AGENT=$(safe_text "$CLI_AGENT") (command line)"
  elif [[ -n "$SANDBOX_AGENT" ]]; then
    AGENT_SPEC="$SANDBOX_AGENT" AGENT_FROM="the sandbox's saved agent ($(state_dir_of "$1")/agent)"
  else
    AGENT_SPEC="$AGENT" AGENT_FROM="AGENT"
  fi
  n0=${#PROBLEMS[@]}
  resolve_agent "$AGENT_SPEC" "$AGENT_FROM" && return 0
  [[ "$AGENT_SPEC" == "$AGENT" ]] && PROBLEMS=("${PROBLEMS[@]:0:n0}")
  return 1
}

# run_agent_label  -- how to name the resolved agent in messages.
run_agent_label() {
  if [[ -n "$RUN_PROFILE" ]]; then
    printf '%s (profile: %s)\n' "$RUN_PROFILE" "$RUN_AGENT"
  else
    printf '%s\n' "$RUN_AGENT"
  fi
}

# ---- the sandbox's saved agent (.state/<n>/agent) ----

# read_saved_agent <sandbox_dir>  -- sets SANDBOX_AGENT to the spec saved
# for the sandbox, or empty: it then follows AGENT in .env.
read_saved_agent() {
  local f
  f="$(state_dir_of "$1")/agent"
  SANDBOX_AGENT=""
  [[ -f "$f" ]] && { IFS= read -r SANDBOX_AGENT < "$f" || true; }
  return 0
}

# save_agent <sandbox_dir> <spec>  -- saves the sandbox's agent.
save_agent() {
  local d
  d="$(state_dir_of "$1")"
  mkdir -p "$d" && printf '%s\n' "$2" > "$d/agent"
}

# profile_sum <file>  -- a checksum of a profile, saved when a VM is
# created from it, so make run can say when it changed since.
profile_sum() { cksum < "$1" | awk '{ print $1 "-" $2 }'; }

# save_profile_sum <sandbox_dir>  -- records RUN_PROFILE's checksum for the
# VM being created, or removes the record if it isn't from a profile.
save_profile_sum() {
  local d
  d="$(state_dir_of "$1")"
  mkdir -p "$d"
  if [[ -n "$RUN_PROFILE" ]]; then
    profile_sum "$(profile_file "$RUN_PROFILE")" > "$d/agent_sum"
  else
    rm -f -- "$d/agent_sum"
  fi
}

# profile_changed <sandbox_dir>  -- true if RUN_PROFILE differs from the
# checksum saved when the sandbox's VM was created from it.
profile_changed() {
  local f saved=""
  f="$(state_dir_of "$1")/agent_sum"
  [[ -n "$RUN_PROFILE" && -f "$f" ]] || return 1
  IFS= read -r saved < "$f" || true
  [[ "$saved" != "$(profile_sum "$(profile_file "$RUN_PROFILE")")" ]]
}
