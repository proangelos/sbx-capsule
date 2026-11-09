# shellcheck disable=SC2034  # globals set here are read by the files that source this one
# VS Code helpers for `make code`, which opens a sandbox in VS Code running
# inside the sandbox's sbx VM (Remote-SSH to <vm>.sbx), and for `make
# doctor`'s VS Code checks. README.md, "Reviewing and editing a sandbox",
# has the setup these check.
# Sourced via all.sh, not executed: no shebang, no `set -e`.
#
# Why VS Code runs in the VM: opened on the host, its Git extension, tasks
# and language servers would run whatever the agent wrote in the sandbox.
# What's left to guard is VS Code handing host credentials and ports to the
# VM. Window- and resource-scoped settings for that live in the sandbox's
# own .vscode/settings.json (write_vscode_settings), which make run mounts
# read-only into the VM so the agent can't turn them back on. The
# application-scoped one (Remote-SSH's agent forwarding) can only be set in
# your user settings, so doctor and make code check it there.

# Workspace settings every sandbox gets, all scoped so a workspace can set
# them (checked against VS Code 1.10x and Remote-SSH 0.128).
VSCODE_SANDBOX_SETTINGS='{
  "git.terminalAuthentication": false,
  "git.useIntegratedAskPass": false,
  "github.gitAuthentication": false,
  "remote.autoForwardPorts": false
}'

# write_vscode_settings <dir>  -- writes <dir>/settings.json. <dir> must be
# outside the sandbox, or in a new sandbox no VM has seen yet.
write_vscode_settings() {
  {
    echo "// Written by sbx-capsule. Read-only inside this sandbox's VM, so the agent"
    echo "// can't change it: it stops VS Code passing your credentials and ports"
    echo "// into the VM. See the tool's README, \"Reviewing and editing a sandbox\"."
    echo "$VSCODE_SANDBOX_SETTINGS"
  } > "$1/settings.json"
}

# vscode_dir_problems <sandbox_dir>  -- before a VM is created: the
# sandbox's .vscode must be missing (make run creates it) or a real folder
# holding nothing but settings.json, since the whole folder is mounted
# read-only and VS Code would use anything else in it.
vscode_dir_problems() {
  local d="$1/.vscode" f
  [[ -e "$d" || -L "$d" ]] || return 0
  if [[ -L "$d" || ! -d "$d" ]]; then
    PROBLEMS+=("$d isn't a folder -- remove it; make run puts this tool's VS Code settings there")
    return 0
  fi
  for f in "$d"/* "$d"/.[!.]*; do
    [[ -e "$f" || -L "$f" ]] || continue
    [[ "${f##*/}" == settings.json && -f "$f" && ! -L "$f" ]] && continue
    PROBLEMS+=("$d holds $(safe_text "${f##*/}"), which isn't from this tool -- move it out; the folder is mounted read-only into the VM with just this tool's VS Code settings")
  done
  return 0
}

# ensure_vscode_dir <sandbox_dir>  -- (re)writes the sandbox's
# .vscode/settings.json before its VM is created: the whole folder is built
# in a staging folder and moved in at the sandbox root, never written
# through anything in the sandbox (move_into_sandbox). An existing .vscode
# is first renamed out into staging (a rename moves the entry itself, never
# what a symlink points at) and deleted there; callers ran
# vscode_dir_problems first, so it held only this tool's settings.json.
ensure_vscode_dir() {
  local d="$1/.vscode" staging rc=0
  staging="$(mktemp -d "$SANDBOX_ROOT/.staging.XXXXXX")" || return 1
  if [[ -e "$d" || -L "$d" ]]; then
    mv -- "$d" "$staging/old.vscode" || rc=1
  fi
  (( rc )) || { mkdir "$staging/.vscode" && write_vscode_settings "$staging/.vscode" \
      && move_into_sandbox "$staging/.vscode" "$1"; } || rc=1
  rm -rf -- "$staging"
  return "$rc"
}

# vm_has_vscode_mount <sandbox_dir> <vm>  -- true if the VM mounts the
# sandbox's .vscode read-only, at the same path inside the VM, as every VM
# make run creates does.
vm_has_vscode_mount() {
  local out name ws mode target
  out="$(sbx_vms)" || return 1
  while IFS=$'\t' read -r name _ _ ws mode target; do
    [[ "$name" == "$2" && "$ws" == "$1/.vscode" && "$mode" == ro && "$target" == "$ws" ]] && return 0
  done <<< "$out"
  return 1
}

in_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

# win_env <NAME>  -- a Windows environment variable, from WSL, as a WSL path
# (e.g. win_env APPDATA -> the AppData/Roaming folder under /mnt/c), or nothing.
win_env() {
  local v
  v="$( (cd /mnt/c 2>/dev/null && cmd.exe /c "echo %$1%") 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$v" && "$v" != "%$1%" ]] || return 0
  wslpath -u "$v" 2>/dev/null || true
}

# vscode_user_dir  -- VS Code's user settings folder: VSCODE_USER_DIR, else
# the standard one for this OS (on WSL, Windows' VS Code), if it exists.
vscode_user_dir() {
  local d=""
  if [[ -n "$VSCODE_USER_DIR" ]]; then
    d="$VSCODE_USER_DIR"
  elif in_wsl; then
    d="$(win_env APPDATA)"; [[ -n "$d" ]] && d="$d/Code/User"
  elif [[ "$(uname -s)" == Darwin ]]; then
    d="$HOME/Library/Application Support/Code/User"
  else
    d="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User"
  fi
  [[ -n "$d" && -d "$d" ]] && printf '%s\n' "$d"
  return 0
}

# vscode_setting <settings.json> <key>  -- the key's last value in a VS Code
# settings file (JSON with comments), or nothing if it isn't set.
vscode_setting() {
  [[ -f "$1" ]] || return 0
  grep -v '^[[:space:]]*//' "$1" \
    | grep -o "\"${2//./\\.}\"[[:space:]]*:[[:space:]]*[^,}[:space:]]*" \
    | tail -1 | sed 's/^[^:]*:[[:space:]]*//' || true
}

# vscode_profile_exists <user dir> <name>  -- true if VS Code has a profile
# by that name (profile names are kept in globalStorage/storage.json).
vscode_profile_exists() {
  local f="$1/globalStorage/storage.json"
  [[ -f "$f" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg n "$2" '[.userDataProfiles[]? | select(.name == $n)] | length > 0' "$f" >/dev/null 2>&1
  else
    tr -d '\n' < "$f" | sed 's/":[[:space:]]*"/":"/g' | grep -qF "\"name\":\"$2\""
  fi
}

# vscode_is_flatpak  -- true if the VS Code make code would use is the
# Flatpak (com.visualstudio.code), which isn't supported: Remote-SSH inside
# the Flatpak sandbox can't run the host's sbx as its ProxyCommand without
# flatpak-spawn --host workarounds, and check_sbx_ssh, which asks the
# host's ssh, couldn't tell. True when VSCODE_CMD or VSCODE_USER_DIR points
# at the Flatpak, when `code` resolves to its exported launcher, or when
# there's no `code` and the Flatpak is installed. Linux outside WSL only.
VSCODE_FLATPAK_ID=com.visualstudio.code
vscode_is_flatpak() {
  local c
  [[ "$(uname -s)" == Linux ]] && ! in_wsl || return 1
  case "$VSCODE_CMD" in
    flatpak|*/flatpak|*"/exports/bin/$VSCODE_FLATPAK_ID") return 0 ;;
  esac
  [[ "$VSCODE_USER_DIR" == *"/.var/app/$VSCODE_FLATPAK_ID/"* ]] && return 0
  [[ -n "$VSCODE_CMD" ]] && return 1
  if c="$(command -v code 2>/dev/null)"; then
    c="$(readlink -f "$c" 2>/dev/null || printf '%s\n' "$c")"
    [[ "$c" == *"/exports/bin/$VSCODE_FLATPAK_ID" ]]
    return
  fi
  command -v flatpak >/dev/null 2>&1 && flatpak info "$VSCODE_FLATPAK_ID" >/dev/null 2>&1
}

VSCODE_FLATPAK_MSG="VS Code installed as a Flatpak isn't supported by make code: Remote-SSH inside the Flatpak can't run sbx on the host to reach the VM. Install VS Code from Microsoft's .deb, .rpm or tarball instead (see README.md, \"Reviewing and editing a sandbox\")"

# vscode_launch_cmd  -- sets VSCODE_LAUNCH to the command that opens VS
# Code: VSCODE_CMD, else on WSL Windows' VS Code CLI run directly (what its
# bin/code does outside WSL; the WSL route goes through a remote CLI that
# can't be relied on for --folder-uri and --profile), else `code`. Fails if
# none is found.
vscode_launch_cmd() {
  local base dir vf cli
  VSCODE_LAUNCH=()
  if [[ -n "$VSCODE_CMD" ]]; then
    command -v "$VSCODE_CMD" >/dev/null 2>&1 || return 1
    VSCODE_LAUNCH=("$VSCODE_CMD"); return 0
  fi
  if in_wsl; then
    for base in "$(win_env LOCALAPPDATA)/Programs" "$(win_env ProgramFiles)"; do
      dir="$base/Microsoft VS Code"
      [[ -x "$dir/Code.exe" ]] || continue
      vf="$(sed -n 's/^VERSIONFOLDER="\(.*\)"$/\1/p' "$dir/bin/code" 2>/dev/null)"
      cli="$dir${vf:+/$vf}/resources/app/out/cli.js"
      [[ -f "$cli" ]] || continue
      VSCODE_LAUNCH=(env ELECTRON_RUN_AS_NODE=1 "WSLENV=ELECTRON_RUN_AS_NODE/w:${WSLENV:-}"
                     "$dir/Code.exe" "$(wslpath -m "$cli")")
      return 0
    done
    return 1
  fi
  command -v code >/dev/null 2>&1 || return 1
  VSCODE_LAUNCH=(code)
}

# check_vscode_settings  -- appends to PROBLEMS unless VS Code's user
# settings switch off what a workspace can't (Remote-SSH agent forwarding,
# an application setting, so it's read from the default profile whatever
# VSCODE_PROFILE is), keep Workspace Trust on, and VSCODE_PROFILE names a
# profile that exists.
check_vscode_settings() {
  local udir def v
  udir="$(vscode_user_dir)"
  if [[ -z "$udir" ]]; then
    PROBLEMS+=("couldn't find VS Code's user settings folder -- set VSCODE_USER_DIR in .env (the folder holding your user settings.json)")
    return 0
  fi
  def="$udir/settings.json"
  v="$(vscode_setting "$def" remote.SSH.enableAgentForwarding)"
  [[ "$v" == false ]] || PROBLEMS+=("VS Code's remote.SSH.enableAgentForwarding is ${v:-unset (so true)}: Remote-SSH would hand the VM your SSH agent. Add \"remote.SSH.enableAgentForwarding\": false to your user settings ($def); it applies to every profile")
  v="$(vscode_setting "$def" security.workspace.trust.enabled)"
  [[ "$v" != false ]] || PROBLEMS+=("VS Code's security.workspace.trust.enabled is false, so every folder you open, sandboxes included, is trusted. Remove it from $def")
  if [[ -n "$VSCODE_PROFILE" ]] && ! vscode_profile_exists "$udir" "$VSCODE_PROFILE"; then
    PROBLEMS+=("VS Code has no profile named '$VSCODE_PROFILE' (VSCODE_PROFILE in .env) -- create it (Command Palette: Profiles: New Profile), or empty VSCODE_PROFILE to use the default")
  fi
  return 0
}

# check_sbx_ssh  -- appends to PROBLEMS unless <vm>.sbx resolves, for the
# ssh client VS Code uses (Windows' ssh.exe on WSL), through `sbx ssh proxy`
# with host-key checking on and agent forwarding off. On WSL, also that the
# copied known_hosts holds sbx's current host key. `ssh -G` only resolves
# config; it connects to nothing.
check_sbx_ssh() {
  local ssh=ssh out pc wsl_kh win_kh line setup
  setup="see README.md, \"Reviewing and editing a sandbox\""
  if in_wsl; then ssh=/mnt/c/Windows/System32/OpenSSH/ssh.exe; fi
  if ! command -v "$ssh" >/dev/null 2>&1; then
    PROBLEMS+=("no ssh client at $ssh, which VS Code's Remote-SSH needs -- $setup"); return 0
  fi
  out="$("$ssh" -G sbx-capsule-probe.sbx 2>/dev/null | tr -d '\r' || true)"
  pc="$(sed -n 's/^proxycommand //p' <<< "$out")"
  if [[ "$pc" != *sbx*"ssh proxy"* ]]; then
    PROBLEMS+=("<vm>.sbx doesn't connect through sbx for $ssh -- run sbx setup ssh${WSL_DISTRO_NAME:+, then add the *.sbx block to the Windows SSH config}; $setup")
    return 0
  fi
  grep -qx 'forwardagent no' <<< "$out" \
    || PROBLEMS+=("SSH to <vm>.sbx forwards your agent (ForwardAgent) -- set ForwardAgent no for Host *.sbx")
  grep -qx 'stricthostkeychecking true' <<< "$out" \
    || PROBLEMS+=("SSH to <vm>.sbx doesn't check the host key strictly -- set StrictHostKeyChecking yes for Host *.sbx")
  if in_wsl; then
    wsl_kh="$(ssh -G sbx-capsule-probe.sbx 2>/dev/null | sed -n 's/^userknownhostsfile \([^ ]*\).*/\1/p')"
    win_kh="$(sed -n 's/^userknownhostsfile \([^ ]*\).*/\1/p' <<< "$out")"
    [[ -n "$win_kh" ]] && win_kh="$(wslpath -u "$win_kh" 2>/dev/null || true)"
    if [[ -f "$wsl_kh" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ ! -f "$win_kh" ]] || ! grep -qxF "$line" "$win_kh"; then
          PROBLEMS+=("Windows' known_hosts for *.sbx (${win_kh:-none}) doesn't hold sbx's current host key -- copy it again: cp $wsl_kh ${win_kh:-<that file>}")
          break
        fi
      done < "$wsl_kh"
    fi
  fi
  return 0
}

# uri_path <path>  -- a path escaped for a vscode-remote:// URI.
uri_path() {
  local p="$1"
  p="${p//%/%25}"; p="${p// /%20}"; p="${p//#/%23}"; p="${p//\?/%3F}"
  printf '%s\n' "$p"
}
