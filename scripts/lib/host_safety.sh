# Host safety checks: ways an sbx VM could reach past its own sandbox
# folder into the host. Shared by `make run`, which refuses to start a VM
# while any of them fails, and `make doctor`. Each appends to PROBLEMS
# (validate.sh).
# Sourced via all.sh, not executed: no shebang, no `set -e`.
#
#   check_vm_mounts         no VM can write this checkout (outside its
#                           sandbox folders) or a source checkout
#   check_repo_paths        no source checkout lives inside a sandbox folder
#   check_agent_forwarding  with AGENT_GIT_PUSH=no, sbx doesn't hand VMs your
#                           SSH agent
#   check_skills_mode       new VMs don't get your agent's skills store
#                           writable
#   audit_clone             what in a clone would run on the host if git
#                           there used it (make doctor only; prints, doesn't
#                           touch PROBLEMS)
#   vms_running_on          VMs that could change a folder right now
#                           (make destroy stops the sandbox's own first)
#
# docs/DESIGN.md, "The sandbox folder is untrusted on the host", has the
# reasoning; README.md, "Reviewing and editing a sandbox", what to do.

# _canon <path>  -- the path without trailing slashes and, if it's a folder
# that exists, with symlinks resolved, so two spellings of one folder
# compare equal.
_canon() {
  local p="$1"
  while [[ "$p" == */ && "$p" != / ]]; do p="${p%/}"; done
  if [[ -d "$p" ]]; then
    (cd "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"
  else
    printf '%s\n' "$p"
  fi
}

# _is_within <path> <dir>  -- true if <path> is <dir> or inside it.
_is_within() {
  [[ "$2" == / || "$1" == "$2" || "$1" == "$2"/* ]]
}

# check_vm_mounts  -- every sbx VM on the machine, not only this checkout's:
# a VM that can write this checkout, or anything in it but a sandbox folder
# itself (scripts/, .env, .state/, .git, a sandbox's .vscode), can change
# what every make command runs or trusts on the host; one that can write a
# source checkout can plant git config and hooks that run when you, or this
# tool, use git there. Read-only mounts can't change anything; sbx_vms
# turns each mount, with or without a path of its own in the VM, into the
# host paths it may name. Needs sbx; without it there are
# no VMs. Fails closed: if sbx is installed but doesn't answer, that's a
# problem, not "no VMs".
check_vm_mounts() {
  local out name ws mode root r src rel
  local -A srcs=()
  have_sbx || return 0
  if ! out="$(sbx_vms)"; then
    PROBLEMS+=("couldn't ask sbx which VMs exist, so it isn't known whether one can write this checkout or a source checkout -- check sbx works: sbx diagnose")
    return 0
  fi
  root="$(_canon "$SANDBOX_ROOT")"
  for r in "${!REPOS[@]}"; do
    [[ -n "${REPOS[$r]}" ]] && srcs[$r]="$(_canon "${REPOS[$r]}")"
  done
  while IFS=$'\t' read -r name _ _ ws mode _; do
    [[ -n "$ws" && "$mode" != ro ]] || continue
    ws="$(_canon "$ws")"
    if _is_within "$root" "$ws"; then
      PROBLEMS+=("sbx VM $name can write $ws, which holds this tool's checkout: anything running in it can change .env or scripts/, which every make command runs on your host. Remove it: sbx rm $name")
    elif _is_within "$ws" "$root"; then
      # Inside the checkout: only a sandbox folder itself is a VM's to write.
      rel="${ws#"$root"/}"
      is_sandbox_name "$rel" \
        || PROBLEMS+=("sbx VM $name can write $(safe_text "$ws"), inside this tool's checkout but not a sandbox folder: it could change files every make command runs or trusts on your host (scripts/, .env, .state/, a sandbox's .vscode). Remove it: sbx rm $name")
    fi
    for r in "${!srcs[@]}"; do
      src="${srcs[$r]}"
      if _is_within "$src" "$ws" || _is_within "$ws" "$src/.git"; then
        PROBLEMS+=("sbx VM $name can write $r's source checkout ($src): it could plant git config or hooks that run when you, or make new/add, use git there. Remove the VM: sbx rm $name")
      fi
    done
  done <<< "$out"
  return 0
}

# check_repo_paths  -- a source checkout inside a sandbox folder is writable
# by that sandbox's VM, and the tool runs plain git in source checkouts.
check_repo_paths() {
  local r src root rel
  root="$(_canon "$SANDBOX_ROOT")"
  for r in "${!REPOS[@]}"; do
    [[ -n "${REPOS[$r]}" ]] || continue
    src="$(_canon "${REPOS[$r]}")"
    _is_within "$src" "$root" && [[ "$src" != "$root" ]] || continue
    rel="${src#"$root"/}"
    if is_sandbox_name "${rel%%/*}"; then
      PROBLEMS+=("REPOS[$r] ($src) is inside sandbox folder ${rel%%/*}, which its VM can write -- point it at your own checkout, outside $root")
    fi
  done
  return 0
}

# check_agent_forwarding  -- sbx forwards your SSH agent into every sandbox
# by default (ssh.agentForwardingEnabled, checked against sbx v0.50.1), so an
# agent can sign with your SSH keys and push even when AGENT_GIT_PUSH=no
# tells it not to. With AGENT_GIT_PUSH=yes that forwarding is how SSH pushes
# work, so it's left alone. Fails closed if sbx can't be asked.
check_agent_forwarding() {
  local v
  have_sbx || return 0
  [[ "$AGENT_GIT_PUSH" == no ]] || return 0
  if ! v="$(sbx settings get ssh.agentForwardingEnabled 2>/dev/null)"; then
    PROBLEMS+=("couldn't read sbx's ssh.agentForwardingEnabled setting, so it isn't known whether sandboxes can use your SSH keys -- check sbx works: sbx diagnose")
    return 0
  fi
  [[ "$v" == false ]] && return 0
  PROBLEMS+=("sbx forwards your SSH agent into sandboxes (ssh.agentForwardingEnabled=$v), so the agent can sign with your SSH keys and push, although AGENT_GIT_PUSH=no. Turn it off: sbx settings set ssh.agentForwardingEnabled false, then sbx daemon restart")
}

# check_skills_mode  -- sbx v0.51.0 links the agent's shared skills store
# (e.g. ~/.claude/skills) into each new VM, read-only by default. With
# skills.defaultMode=readwrite it's mounted writable, so the agent could
# write skills that your agent on the host then loads and runs. A --skills
# flag in SBX_CREATE_FLAGS wins over the setting (check_sbx_create_flags
# refuses --skills readwrite). An sbx without the setting (before v0.51.0)
# has no skills store to mount, so a failed read isn't a problem.
check_skills_mode() {
  local v
  have_sbx || return 0
  [[ " $SBX_CREATE_FLAGS" =~ [[:space:]]--skills([[:space:]=]|$) ]] && return 0
  v="$(sbx settings get skills.defaultMode 2>/dev/null)" || return 0
  [[ "${v,,}" == readwrite ]] || return 0
  PROBLEMS+=("sbx mounts your agent's skills store writable into new sandboxes (skills.defaultMode=readwrite), so the agent could write skills your agent on the host then runs. Turn it off: sbx settings set skills.defaultMode readonly, or add --skills readonly to SBX_CREATE_FLAGS")
}

# audit_clone <clone dir> <repo>  -- prints one line per thing in a sandbox
# clone that would run a command, or send a push somewhere else, if git on
# the host used that clone: what the agent may have planted. make doctor
# reports these; the tool's own git calls are protected (sandbox_git) and
# make push never runs git in the clone, so they matter for anything else
# the user points at it. Reading config runs nothing; --no-includes keeps
# it to the clone's own .git/config. Every printed value is the agent's,
# so it goes through safe_text.
audit_clone() {
  local d="$1" repo="$2" rec key val why f src_url="" restore err
  if [[ -L "$d/.git" ]]; then echo ".git is a symlink"; return 0; fi
  [[ -e "$d/.git/commondir" || -L "$d/.git/commondir" ]] \
    && echo ".git/commondir (makes git read another repo's config)"
  [[ -e "$d/.git/config.worktree" || -L "$d/.git/config.worktree" ]] \
    && echo ".git/config.worktree (more config)"
  [[ -e "$d/.git/objects/info/alternates" || -L "$d/.git/objects/info/alternates" ]] \
    && echo ".git/objects/info/alternates (borrows objects from other folders; clones made by this tool have none)"
  if [[ -L "$d/.git/hooks" ]]; then
    echo ".git/hooks is a symlink"
  else
    restore="$(shopt -p nullglob dotglob || true)"   # exits 1 when either is off
    shopt -s nullglob dotglob
    for f in "$d/.git/hooks"/*; do
      [[ "$f" == *.sample ]] || echo "hook $(safe_text "${f##*/}") (runs on commit, push and more)"
    done
    eval "$restore"
  fi
  if ! err="$(sandbox_git "$d" config --local --no-includes --list 2>&1 >/dev/null)"; then
    err="${err%%$'\n'*}"
    echo "couldn't read its git config${err:+: $(safe_text "$err")}"
    return 0
  fi
  [[ -n "${REPOS[$repo]:-}" ]] && src_url="$(git -C "${REPOS[$repo]}" remote get-url origin 2>/dev/null || true)"
  while IFS= read -r -d '' rec; do
    key="${rec%%$'\n'*}" val=""
    [[ "$rec" == *$'\n'* ]] && val="${rec#*$'\n'}"
    why=""
    case "$key" in
      remote.origin.url)
        [[ -n "$src_url" && "$val" != "$src_url" ]] && why="points origin at $val, not $src_url" ;;
      remote.*.url)
        why="adds a remote ($val)" ;;
      core.fsmonitor)
        case "${val,,}" in ""|true|false|yes|no|on|off|0|1) ;; *) why="runs a command on every git status" ;; esac ;;
      core.hookspath)            why="moves hooks out of .git/hooks, to $val" ;;
      core.pager|pager.*)        why="runs a command as the pager (git log, diff)" ;;
      core.editor|sequence.editor) why="runs a command as the editor (commit, rebase)" ;;
      core.sshcommand|core.gitproxy|core.askpass|remote.*.uploadpack|remote.*.receivepack|remote.*.vcs)
                                 why="runs a command on fetch or push" ;;
      core.alternaterefscommand|uploadpack.packobjectshook)
                                 why="runs a command on fetch" ;;
      core.worktree)             why="points git at another folder ($val)" ;;
      filter.*)                  why="runs a command on status, add and checkout" ;;
      diff.external|diff.*.textconv|diff.*.command)
                                 why="runs a command on diff and log -p" ;;
      merge.*.driver)            why="runs a command on merge" ;;
      gpg.program|gpg.*.program) why="runs a command to check signatures (git log)" ;;
      credential.helper|credential.*.helper)
                                 why="is handed your credentials on fetch and push" ;;
      include.path|includeif.*.path)
                                 why="loads more config, from $val" ;;
      remote.*.pushurl)          why="sends pushes to $val" ;;
      url.*.insteadof|url.*.pushinsteadof)
                                 why="rewrites remote URLs" ;;
      protocol.allow|protocol.*.allow)
                                 why="allows transports such as ext::, which run commands" ;;
      extensions.worktreeconfig) why="loads more config from .git/config.worktree" ;;
      alias.*)
        [[ "$val" == '!'* ]] && why="runs a shell command when you type git ${key#alias.}" ;;
    esac
    [[ -n "$why" ]] && echo "$(safe_text "$key") $(safe_text "$why")"
  done < <(sandbox_git "$d" config --local --no-includes --list -z 2>/dev/null)
  return 0
}

# vms_running_on <dir>  -- the names of sbx VMs, one per line, that aren't
# stopped and can write <dir>: they mount it, something inside it, or a
# folder above it, not read-only. Fails if sbx is installed but doesn't
# answer, so callers can fail closed. Without sbx there are none.
vms_running_on() {
  local dir out name status ws mode seen=$'\n'
  have_sbx || return 0
  out="$(sbx_vms)" || return 1
  dir="$(_canon "$1")"
  while IFS=$'\t' read -r name status _ ws mode _; do
    [[ -n "$ws" && "$mode" != ro && "$status" != stopped ]] || continue
    ws="$(_canon "$ws")"
    _is_within "$ws" "$dir" || _is_within "$dir" "$ws" || continue
    [[ "$seen" == *$'\n'"$name"$'\n'* ]] && continue
    seen+="$name"$'\n'
    printf '%s\n' "$name"
  done <<< "$out"
}

# check_host_exposure  -- the four check_* above: what `make run` and
# `make code` refuse on.
check_host_exposure() {
  check_vm_mounts
  check_repo_paths
  check_agent_forwarding
  check_skills_mode
}
