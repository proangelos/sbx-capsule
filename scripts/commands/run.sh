#!/usr/bin/env bash
# Start the coding agent (AGENT in .env, default claude) in a Docker Sandbox
# (sbx) VM on a sandbox, or reattach if its VM already exists. The sandbox
# folder is mounted at the same path inside the VM ("direct mode"), so the
# clones are edited in place on the host.
#
# Usage: scripts/commands/run.sh <sandbox number>             (or: make run N=3)
#   ARGS="--continue"             extra arguments for the agent, after
#                                 AGENT_ARGS[<agent>] from .env
#   FRESH=1                       remove the sandbox's VM first, if it has
#                                 one, and create a new one from the
#                                 current .env (make run N=3 FRESH=1)
#
# The agent is fixed when the VM is created: changing AGENT later only
# affects new VMs, and reattaching always runs the VM's own agent. Likewise
# SBX_CREATE_FLAGS only applies at creation. FRESH=1 recreates the VM to
# pick up either: the sandbox's files are on the host and stay, while the
# agent's history and anything else inside the old VM go. The VM is only
# removed once every check below has passed.
#
# Refuses to start while any sbx VM can write this checkout or a source
# checkout, or while sbx forwards your SSH agent with AGENT_GIT_PUSH=no
# (check_host_exposure in scripts/lib/host_safety.sh).
#
# A new VM also gets the sandbox's .vscode folder mounted read-only, holding
# only this tool's workspace settings for `make code` (scripts/lib/vscode.sh).
#
# sbx run attaches the agent to this terminal. Without one, sbx still
# creates or starts the VM, then fails to attach ("context deadline
# exceeded"); the VM is fine, so this warns first rather than refusing:
# creating a VM without a terminal is useful before `make code`.
#
# VM name: see sbx_name and sandbox_vm in scripts/lib/agents.sh. destroy.sh
# removes the VM.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

n="${1:-}"
[[ -n "$n" ]] || die "usage: $0 <sandbox number>"
sandbox_dir="$(find_sandbox_dir "$n")"
have_sbx || die "sbx (Docker Sandboxes) isn't installed -- see docs/DOCKER_SANDBOXES.md"

# Agent settings are checked strictly (a bad AGENT or flag would only fail
# later, inside sbx, less helpfully); the rest of .env only warns, below,
# once those pass. So are the host safety checks (scripts/lib/host_safety.sh):
# no VM starts while another can write this checkout or a source checkout,
# or while sbx would hand it your SSH agent against AGENT_GIT_PUSH=no.
PROBLEMS=()
check_agent_config
check_host_exposure
# The sandbox's VM is the one named after it that mounts it (sandbox_vm);
# a VM that only has its name is someone else's, and would make creating
# one fail.
name="$(sbx_name "$sandbox_dir")"
vm_exists=""
rc=0
vm="$(sandbox_vm "$sandbox_dir")" || rc=$?
case "$rc" in
  0) vm_exists=1 name="$vm" ;;
  2) PROBLEMS+=("couldn't ask sbx whether sandbox $n already has a VM -- check sbx works: sbx diagnose") ;;
  *) sbx_exists "$name" \
       && PROBLEMS+=("an sbx VM named $name already exists but doesn't mount $sandbox_dir, so it isn't this sandbox's (made by hand?) -- look at it with sbx ls, and remove it if it's not needed: sbx rm $name") ;;
esac
# A new VM gets the sandbox's .vscode folder read-only (scripts/lib/vscode.sh).
# FRESH=1: the existing VM is removed once the checks pass, so they're the
# checks for creating one.
fresh=""
if [[ -n "${FRESH:-}" ]]; then
  fresh="$vm_exists"
  vm_exists=""
fi
[[ -n "$vm_exists" ]] || vscode_dir_problems "$sandbox_dir"
report_problems "can't start sandbox $n:"
validate_config warn

if [[ -n "$fresh" ]]; then
  echo "Removing ${C_BOLD}$name${C_RESET} to create it again (the sandbox's files stay; the agent's history inside the VM goes)"
  sbx rm --force "$name" >/dev/null \
    || die "couldn't remove $name -- check sbx works (sbx diagnose), then try again"
  # The old VM may have had an earlier SBX_NAME_PREFIX; its replacement
  # gets the current one.
  name="$(sbx_name "$sandbox_dir")"
elif [[ -n "${FRESH:-}" ]]; then
  echo "note: sandbox $n has no VM yet, so FRESH=1 has nothing to remove."
fi

# agent_args <agent>  -- fills AGENT_ARGV: AGENT_ARGS[<agent>] from .env,
# then ARGS from the command line.
agent_args() {
  local extra=()
  AGENT_ARGV=()
  [[ -n "${AGENT_ARGS[$1]:-}" ]] && read -r -a AGENT_ARGV <<< "${AGENT_ARGS[$1]}"
  [[ -n "${ARGS:-}" ]] && read -r -a extra <<< "$ARGS"
  AGENT_ARGV+=(${extra[@]+"${extra[@]}"})
}

# warn_without_terminal  -- see the header: sbx run's attach needs a terminal.
warn_without_terminal() {
  [[ -t 0 && -t 1 ]] && return 0
  warn "no terminal: sbx will start $name, then fail to attach the agent (\"context deadline exceeded\"). The VM is fine; to use it, run make run N=$n from a terminal, or make code N=$n"
}

if [[ -n "$vm_exists" ]]; then
  [[ -z "$SBX_CREATE_FLAGS" ]] || echo "note: SBX_CREATE_FLAGS only applies when a VM is created; $name already exists. To apply it: make run N=$n FRESH=1"
  new_name="$(sbx_name "$sandbox_dir")"
  [[ "$name" == "$new_name" ]] || echo "note: $name keeps the name it was created with; new VMs are named like $new_name (SBX_NAME_PREFIX). To rename it, recreate it: make run N=$n FRESH=1"
  vm_agent="$(sbx_agent_of "$name")"
  if [[ -n "$vm_agent" ]] && is_builtin_agent "$AGENT" && [[ "$vm_agent" != "$AGENT" ]]; then
    warn "$name was created with $vm_agent, but AGENT is now $AGENT -- reattaching to $vm_agent. To switch, recreate the VM (the sandbox's files stay; the agent's history inside the VM goes): make run N=$n FRESH=1"
  fi
  agent_args "${vm_agent:-$AGENT}"
  echo "Reattaching to ${C_BOLD}$name${C_RESET}${vm_agent:+ ($vm_agent)}"
  warn_without_terminal
  exec sbx run --name "$name" ${AGENT_ARGV[@]+-- "${AGENT_ARGV[@]}"}
fi

# The sandbox's VS Code workspace settings, mounted read-only so the agent
# can't switch credential and port forwarding back on (make code).
vm_create_args "$sandbox_dir" || die "couldn't write $sandbox_dir/.vscode/settings.json"
agent_args "$AGENT"
echo "Creating ${C_BOLD}$name${C_RESET} ($AGENT) on $sandbox_dir"
warn_without_terminal
exec sbx run --name "$name" ${VM_CREATE_FLAGS[@]+"${VM_CREATE_FLAGS[@]}"} "$AGENT" "${VM_WORKSPACES[@]}" ${AGENT_ARGV[@]+-- "${AGENT_ARGV[@]}"}
