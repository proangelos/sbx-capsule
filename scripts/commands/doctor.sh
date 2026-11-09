#!/usr/bin/env bash
# Check that this machine and your .env are ready to use: the tools the
# scripts need, Docker Sandboxes (sbx) health, your config, and each repo's
# source checkout, start branch and git host, host safety (what make run
# refuses on, plus settings that widen what a VM can reach), and sbx VMs
# left over from sandboxes that are gone. Read-only: it installs and changes
# nothing.
#
# Usage: scripts/commands/doctor.sh [--tools-only]     (or: make doctor)
#   --tools-only   skip the .env and repo checks (make init uses this right
#                  after copying .env.example, whose repos are placeholders)
#
# Every check runs, and every problem is listed at the end with how to fix
# it; exits 1 if there were any. Notes are worth knowing but don't stop the
# tool working (an sbx update, a git host the VM can't reach while the agent
# isn't meant to push anyway).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

tools_only=""
case "${1:-}" in
  "") ;;
  --tools-only) tools_only=1 ;;
  *) die "usage: $0 [--tools-only]" ;;
esac

FAILS=() NOTES=0

section() { echo; echo "${C_BOLD}$1${C_RESET}"; }
ok()      { echo "  ${C_GREEN}ok${C_RESET}    $1"; }
# fail <what> [<fix>...]  -- printed now, and again in the summary.
fail() {
  local line
  echo "  ${C_RED}FAIL${C_RESET}  $1"
  for line in "${@:2}"; do echo "        ${C_CYAN}->${C_RESET} $line"; done
  FAILS+=("$1")
}
note() {
  local line
  echo "  ${C_YELLOW}note${C_RESET}  $1"
  for line in "${@:2}"; do echo "        $line"; done
  NOTES=$((NOTES + 1))
}

# Shorten paths under $HOME for display.
tilde() { [[ "$1" == "$HOME"/* ]] && echo "~${1#"$HOME"}" || echo "$1"; }

setup_doc="docs/DOCKER_SANDBOXES.md, \"Setup\""

# ---- tools ----

section "Tools"

ok "bash $BASH_VERSION"   # all.sh already refused anything older than 4

# git 2.23+ for `git switch` (clone.sh).
if ! command -v git >/dev/null 2>&1; then
  fail "git isn't installed" "install git 2.23 or newer"
else
  git_version="$(git_version)"
  if version_at_least "$git_version" 2.23; then
    ok "git $git_version"
  else
    fail "git $git_version is too old -- sandboxes need git 2.23 or newer (git switch)" "upgrade git"
  fi
  # The host runs git on clones the VM wrote (make destroy, make push, make
  # doctor), and switching off git's command-running config can't help
  # against a memory-safety bug in parsing what's there. CVE-2022-23521, a
  # heap overflow in reading .gitattributes, was fixed upstream in 2.39.1
  # and in each series from 2.30. Distributions often backport such fixes
  # without changing the version, so this is a note, not a failure.
  if ! git_has_fix "$git_version"; then
    note "git $git_version predates the upstream fix for CVE-2022-23521 (a heap overflow when git reads .gitattributes, which the agent writes)" \
      "if your distribution keeps git patched with security updates you're covered; otherwise upgrade to git 2.39.1 or newer"
  fi
  # make push and make fetch run git upload-pack in the clone (the agent's
  # repo), relying on git keeping that safe for an untrusted repo. Bypasses
  # of that (CVE-2024-32465) were fixed in 2.45.1 and the 2.39-2.44 patch
  # releases. A note for the same reason as above.
  if ! git_has_upload_pack_fix "$git_version"; then
    note "git $git_version predates the upstream fix for CVE-2024-32465 (git upload-pack on an untrusted repo; make push and make fetch run it in the clone, which the agent writes)" \
      "if your distribution keeps git patched with security updates you're covered; otherwise upgrade to git 2.45.1 or newer"
  fi
fi

if command -v make >/dev/null 2>&1; then
  ok "$(make --version 2>/dev/null | head -1)"
else
  fail "make isn't installed" "install make (GNU make), which runs the make new/run/add/destroy commands"
fi

# ---- Docker Sandboxes ----

section "Docker Sandboxes (sbx) -- needed for make run"

if ! have_sbx; then
  fail "sbx isn't installed" "install it: see $setup_doc"
  # Without sbx there's no diagnose to ask, so check the one Linux step
  # people most often miss: KVM access, which needs a fresh login after
  # being added to the kvm group.
  if [[ "$(uname -s)" == Linux ]]; then
    if [[ ! -e /dev/kvm ]]; then
      fail "/dev/kvm doesn't exist -- sbx needs hardware virtualization (KVM)" \
        "on WSL2: use a recent WSL with nested virtualization; on a VM: enable nested virtualization"
    elif [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
      fail "/dev/kvm isn't accessible to you" \
        "sudo usermod -aG kvm \$USER, then log out and in again (on WSL: wsl --shutdown, then reopen)"
    fi
  fi
else
  ok "$(sbx version 2>/dev/null | awk '{ print $1, $3; exit }')"

  # sbx diagnose covers virtualization, the daemon, storage, sign-in and the
  # network policy. Its JSON is pretty-printed one field per line, with
  # "hint" last in each check, so awk can read it without needing jq.
  if diag="$(sbx diagnose --json 2>&1)" || [[ "$diag" == "{"* ]]; then
    passed=0
    while IFS=$'\x1f' read -r status name msg detail hint; do
      case "$status" in
        pass) passed=$((passed + 1)) ;;
        skip) ;;
        warn) note "$name: $msg" ${detail:+"$detail"} ${hint:+"$hint"} ;;
        *)    fail "$name: $msg${detail:+ ($detail)}" "${hint:-see: sbx diagnose}" ;;
      esac
    done < <(awk -v SEP=$'\x1f' '
      function val(line) {
        sub(/^[^:]*: *"?/, "", line); sub(/"?,? *$/, "", line)
        gsub(/\\n/, " ", line); gsub(/\\"/, "\"", line); gsub(/\t/, " ", line)
        return line
      }
      /^ *"name": /    { name = val($0) }
      /^ *"status": /  { status = val($0) }
      /^ *"message": / { msg = val($0) }
      /^ *"detail": /  { detail = val($0) }
      /^ *"hint": /    { print status SEP name SEP msg SEP detail SEP val($0); detail = "" }
    ' <<< "$diag")
    if (( passed )); then
      ok "sbx diagnose: $passed passed"
    else
      fail "couldn't read sbx diagnose's report" "run sbx diagnose yourself"
    fi
  else
    fail "sbx diagnose failed: $(head -1 <<< "$diag")" "run sbx diagnose yourself, and see $setup_doc"
  fi
fi

if [[ -n "$tools_only" ]]; then
  echo
  if (( ${#FAILS[@]} )); then
    echo "${C_RED}${C_BOLD}${#FAILS[@]} problem(s) to fix${C_RESET} (above)."
    exit 1
  fi
  echo "${C_GREEN}${C_BOLD}Tools look good.${C_RESET}"
  exit 0
fi

# ---- config ----

section "Config ($(tilde "$TOOL_ROOT"))"

PROBLEMS=()
check_config
config_ok=1
if (( ${#PROBLEMS[@]} )); then
  config_ok=""
  for p in "${PROBLEMS[@]}"; do fail "$p"; done
else
  ok ".env: ${#REPOS[@]} repo(s): $(known_repos)"
  ok "agent: $AGENT${AGENT_ARGS[$AGENT]:+ (args: ${AGENT_ARGS[$AGENT]})}, AGENT_GIT_PUSH=$AGENT_GIT_PUSH"
  [[ -z "$SANDBOX_NOTES_FILE" ]] || ok "team notes: $(tilde "$SANDBOX_NOTES_FILE")"
fi

# Every make command sources .env.default and .env as bash, as you, so
# nobody else may be able to write them. Group-write is fine when the group
# is your own private group, named after you with no other members: the
# default on Ubuntu and other distros with umask 0002. Without getent
# (macOS, whose umask is 022 anyway) group-write counts as other users.
private_group_file() {
  local me members
  me="$(id -un)"
  [[ -n "$(find "$1" -group "$me" -print 2>/dev/null)" ]] || return 1
  command -v getent >/dev/null 2>&1 || return 1
  members="$(getent group "$me" 2>/dev/null)" || return 1
  members="${members##*:}"
  [[ -z "$members" || "$members" == "$me" ]]
}
for f in "$DEFAULTS_FILE" "$ENV_FILE"; do
  [[ -f "$f" ]] || continue
  if [[ -n "$(find "$f" -perm -002 -print 2>/dev/null)" ]] \
     || { [[ -n "$(find "$f" -perm -020 -print 2>/dev/null)" ]] && ! private_group_file "$f"; }; then
    fail "$(tilde "$f") can be written by other users, and every make command runs it as bash, as you" "chmod go-w $f"
  fi
done

# Environment variables passed to sbx run end up inside the VM.
create_words=()
[[ -n "$SBX_CREATE_FLAGS" ]] && read -r -a create_words <<< "$SBX_CREATE_FLAGS"
for word in ${create_words[@]+"${create_words[@]}"}; do
  case "$word" in
    -e|-e?*|--env|--env=*|--env-file|--env-file=*)
      note "SBX_CREATE_FLAGS passes environment variables into new VMs ($word): the agent can read every one of them" \
        "keep tokens out of them; sbx secret set keeps an API key outside the VM"
      break ;;
  esac
done

# The sbx VM creates a mounted folder's parents as root, which breaks under
# /tmp/claude-<uid> (see docs/DOCKER_SANDBOXES.md).
if [[ "$SANDBOX_ROOT" == /tmp/claude-* ]]; then
  fail "this checkout is under /tmp/claude-*, where sbx VMs can't run Claude" \
    "clone the tool somewhere under your home directory instead"
fi

# ---- repos ----

section "Repos"

if [[ -z "$config_ok" ]]; then
  echo "  (skipped until the config problems above are fixed)"
else
  # endpoint <origin url>  -- host:port the VM would connect to, or nothing
  # for local paths. scp-style and ssh:// default to 22, git:// to 9418.
  endpoint() {
    local url="$1" scheme rest host port=""
    case "$url" in
      file://*|/*|./*|../*) return 0 ;;
      *://*)
        scheme="${url%%://*}" rest="${url#*://}"
        rest="${rest%%/*}"; rest="${rest##*@}"
        host="${rest%%:*}"; [[ "$rest" == *:* ]] && port="${rest##*:}"
        case "$scheme" in
          ssh|git+ssh) port="${port:-22}" ;;
          git)         port="${port:-9418}" ;;
          http)        port="${port:-80}" ;;
          *)           port="${port:-443}" ;;
        esac ;;
      *:*)
        host="${url%%:*}"; host="${host##*@}"; port=22 ;;
      *) return 0 ;;
    esac
    echo "$host:$port"
  }

  declare -gA SPEC_BRANCH=()     # check_start_branches: no requested branches
  declare -A checked_hosts=()
  for repo in $(printf '%s\n' "${!REPOS[@]}" | sort); do
    PROBLEMS=()
    check_start_branches "$repo"
    if (( ${#PROBLEMS[@]} )); then
      for p in "${PROBLEMS[@]}"; do fail "$p"; done
      continue
    fi
    url="$(git -C "${REPOS[$repo]}" remote get-url origin)"
    ok "$repo: $(tilde "${REPOS[$repo]}"), starts from origin/${SOURCE_BRANCHES[$repo]}"

    # Can the agent reach this repo's git host from inside the VM?
    ep="$(endpoint "$url")"
    [[ -n "$ep" && -z "${checked_hosts[$ep]:-}" ]] && have_sbx || continue
    checked_hosts[$ep]=1
    if sbx policy check network "$ep" >/dev/null 2>&1; then
      ok "$ep is on the sbx network allow-list (the agent can fetch and push)"
    elif [[ "$AGENT_GIT_PUSH" == yes ]]; then
      fail "$ep isn't on the sbx network allow-list, but AGENT_GIT_PUSH=yes" \
        "sbx policy allow network ${ep%:*}   (or set AGENT_GIT_PUSH=no and push from the host)"
    else
      note "$ep isn't on the sbx network allow-list: the agent can't fetch or push from the VM." \
        "Fine with AGENT_GIT_PUSH=no (you push from the host). To open it: sbx policy allow network ${ep%:*}"
    fi
  done
fi

# ---- host safety ----

# What make run refuses on (scripts/lib/host_safety.sh), then sbx settings
# that widen what a sandbox can reach. Uses the config's REPOS paths.
section "Host safety"

if [[ -z "$config_ok" ]]; then
  echo "  (skipped until the config problems above are fixed)"
else
  PROBLEMS=()
  check_host_exposure
  for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do fail "$p"; done
  if (( ${#PROBLEMS[@]} == 0 )); then
    ok "no source checkout is inside a sandbox folder"
    if have_sbx; then
      ok "no sbx VM can write this checkout (outside its sandbox folders) or a source checkout"
      [[ "$AGENT_GIT_PUSH" == no ]] && ok "sbx doesn't forward your SSH agent into sandboxes"
      [[ "$(sbx settings get skills.defaultMode 2>/dev/null)" == readwrite ]] \
        || ok "sbx doesn't mount your agent's skills store writable into new sandboxes"
    fi
  fi
  if have_sbx; then
    if [[ "$AGENT_GIT_PUSH" == no ]] && sbx secret ls -q 2>/dev/null | grep -qx github; then
      note "sbx holds a github secret, so the agent can push to GitHub over HTTPS although AGENT_GIT_PUSH=no" \
        "if it shouldn't: sbx secret rm github"
    fi
    if [[ "$(sbx settings get browser.enabled 2>/dev/null)" == true ]]; then
      note "sandboxes can open URLs in your host's browser (sbx setting browser.enabled)" \
        "in-VM logins that redirect to localhost, such as Claude's /login, need it. Once signed in you can turn it off: sbx settings set browser.enabled false"
    fi
    if [[ "$(sbx settings get clipboard.textCopy 2>/dev/null)" == true ]]; then
      note "sandboxes can copy text to your host's clipboard (sbx setting clipboard.textCopy): check what you paste from it into a terminal" \
        "to turn it off: sbx settings set clipboard.textCopy false"
    fi
  fi
fi

# ---- VS Code (make code) ----

# make code opens a sandbox in VS Code running inside its VM
# (scripts/lib/vscode.sh). Optional: without VS Code, or before its one-time
# setup, these are notes. Settings that would hand the VM your credentials
# are failures, since they apply whenever VS Code connects to a VM.
section "VS Code (make code)"

vscode_udir="$(vscode_user_dir)"
if vscode_is_flatpak; then
  note "$VSCODE_FLATPAK_MSG" "make code needs this; nothing else does"
elif [[ -z "$vscode_udir" ]]; then
  note "VS Code's user settings weren't found, so make code's checks were skipped" \
    "if you use VS Code: set VSCODE_USER_DIR in .env to the folder holding your user settings.json"
else
  PROBLEMS=()
  check_vscode_settings
  for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do fail "$p"; done
  (( ${#PROBLEMS[@]} )) \
    || ok "VS Code ($(tilde "$vscode_udir")): Remote-SSH doesn't forward your SSH agent, Workspace Trust is on${VSCODE_PROFILE:+, profile $VSCODE_PROFILE exists}"
  if ! vscode_launch_cmd; then
    if [[ "$(uname -s)" == Darwin ]]; then
      note "couldn't find the code command that opens VS Code" \
        "in VS Code, run Shell Command: Install 'code' command in PATH (Command Palette), or set VSCODE_CMD in .env"
    else
      note "couldn't find the command that opens VS Code" "set VSCODE_CMD in .env"
    fi
  fi
  # Docker's sbx docs recommend this on macOS, against a Remote-SSH
  # reconnect loop.
  if [[ "$(uname -s)" == Darwin ]] \
     && [[ "$(vscode_setting "$vscode_udir/settings.json" remote.SSH.useLocalServer)" != false ]]; then
    note "VS Code's remote.SSH.useLocalServer isn't false; Docker recommends that on macOS, to avoid a Remote-SSH reconnect loop" \
      "add \"remote.SSH.useLocalServer\": false to your user settings ($(tilde "$vscode_udir")/settings.json)"
  fi
fi
if have_sbx; then
  PROBLEMS=()
  check_sbx_ssh
  for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do
    case "$p" in
      *"doesn't connect through sbx"*|"no ssh client"*)
        note "$p" "make code needs this; nothing else does" ;;
      *) fail "$p" ;;
    esac
  done
  (( ${#PROBLEMS[@]} )) || ok "<vm>.sbx connects through sbx, with host-key checking and no agent forwarding"
fi

# ---- sandbox clones ----

# Config and hooks in each clone that would run a command, or send a push
# elsewhere, if git on the host used the clone (audit_clone in
# scripts/lib/host_safety.sh). The tool's own git calls are protected; this
# is for everything else you might point at a clone.
section "Sandbox clones"

clones_checked=0 clones_flagged=0
for sb in "$SANDBOX_ROOT"/*/; do
  sb="${sb%/}"
  is_sandbox_dir "$sb" || continue
  for clone in "$sb"/*/; do
    clone="${clone%/}"
    is_clone "$clone" || continue
    clones_checked=$((clones_checked + 1))
    mapfile -t findings < <(audit_clone "$clone" "${clone##*/}")
    (( ${#findings[@]} )) || continue
    clones_flagged=$((clones_flagged + 1))
    # The agent names the clone's folder, so quote it for the shell first
    # (%q writes control characters as $'...', leaving safe_text nothing to
    # strip) and the suggested commands copy and run exactly as shown.
    printf -v q_clone '%q' "$clone"
    printf -v q_hooks '%q' "$clone/.git/hooks"
    fail "$(safe_text "${sb##*/}/${clone##*/}") has git config or hooks that run on the host if git there uses them:" \
      "${findings[@]}" \
      "this tool's own commands switch all of it off. Before running git or other tools on the clone from the host, look: git -C $(safe_text "$q_clone") config --local --no-includes --list (reading runs nothing), and ls -la $(safe_text "$q_hooks")"
  done
done
if (( clones_checked == 0 )); then
  ok "no sandbox clones to check"
elif (( clones_flagged == 0 )); then
  ok "$clones_checked clone(s): nothing in their git config or hooks that would run on the host"
fi

# ---- sandboxes ----

# A sandbox removed by hand (or destroyed while sbx was missing) leaves its
# VM behind; make new skips that number until the VM is gone. Only this
# checkout's VMs are considered (leftover_vms in scripts/lib/agents.sh).
if have_sbx; then
  section "Sandboxes"
  sandbox_count=0
  for d in "$SANDBOX_ROOT"/*/; do
    is_sandbox_dir "${d%/}" && sandbox_count=$((sandbox_count + 1))
  done
  orphans=0 vm_lines=""
  if ! vm_lines="$(leftover_vms)"; then
    orphans=-1
    fail "couldn't ask sbx which VMs exist, so leftover VMs can't be found (and make new refuses)" \
      "check sbx works: sbx diagnose"
  fi
  while IFS=$'\t' read -r vm _ _ ws; do
    [[ -n "$vm" ]] || continue
    orphans=$((orphans + 1))
    note "sbx VM $vm has no sandbox folder ($(safe_text "$(tilde "$ws")") is gone) -- left over from a sandbox removed by hand, or destroyed while sbx was missing. make new skips its number until it's gone." \
      "remove it (and any other leftovers): make prune"
  done <<< "$vm_lines"
  (( orphans )) || ok "$sandbox_count sandbox(es), no leftover sbx VMs"
fi

# Staging folders (make add, make push) left by a run that was interrupted.
shopt -s nullglob
staging_left=("$SANDBOX_ROOT"/.staging.*)
shopt -u nullglob
if (( ${#staging_left[@]} )); then
  note "${#staging_left[@]} leftover .staging.* folder(s) from an interrupted make add or make push" \
    "if no make command is running, remove them: rm -rf $SANDBOX_ROOT/.staging.*"
fi

# ---- summary ----

echo
if (( ${#FAILS[@]} )); then
  echo "${C_RED}${C_BOLD}${#FAILS[@]} problem(s) to fix:${C_RESET}"
  printf '  - %s\n' "${FAILS[@]}"
  exit 1
fi
if (( NOTES )); then
  echo "${C_GREEN}${C_BOLD}All good${C_RESET} ($NOTES note(s) above)."
else
  echo "${C_GREEN}${C_BOLD}All good.${C_RESET}"
fi
echo "Next: make new WITH=\"<repo> ...\", then make run N=<n>."
