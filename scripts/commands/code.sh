#!/usr/bin/env bash
# Open a sandbox in VS Code, with VS Code itself (its server, extensions,
# Git integration, terminals, language servers) running inside the
# sandbox's sbx VM over Remote-SSH, so nothing the agent wrote runs on the
# host. If the sandbox has no VM yet, this creates one first, the same VM
# make run would create (same agent, workspaces and SBX_CREATE_FLAGS), but
# with `sbx create`, which doesn't attach the agent: the agent stays
# available from make run N=<n> or from a terminal inside the VM.
#
# Usage: scripts/commands/code.sh <sandbox number>    (or: make code N=3)
#
# Needs, once: `sbx setup ssh` (plus, on WSL, the *.sbx block in Windows'
# SSH config) and VS Code's Remote-SSH extension; README.md, "Reviewing and
# editing a sandbox", has the steps. Refuses, listing every problem, when:
#   - make run would refuse (check_host_exposure, scripts/lib/host_safety.sh);
#   - VS Code would hand the VM your SSH agent, or Workspace Trust is off,
#     or VSCODE_PROFILE names no profile (check_vscode_settings);
#   - <vm>.sbx doesn't connect through sbx with host-key checking on and
#     agent forwarding off (check_sbx_ssh);
#   - the VM exists but doesn't mount the sandbox's .vscode read-only (it
#     wasn't made by make run or make code), so the agent could rewrite the
#     workspace settings that stop VS Code passing credentials and ports
#     into it;
#   - no VM exists and the sandbox's .vscode folder can't be used, or the
#     name it would take is held by another VM;
#   - VS Code can't be found.
# All of these are checked before anything is created. It also refuses VS
# Code installed as a Flatpak (vscode_is_flatpak). VSCODE_CMD, VSCODE_PROFILE
# and VSCODE_USER_DIR in .env adjust it.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

n="${1:-}"
[[ -n "$n" ]] || die "usage: make code N=<sandbox number>"
sandbox_dir="$(find_sandbox_dir "$n")"
have_sbx || die "sbx (Docker Sandboxes) isn't installed -- see docs/DOCKER_SANDBOXES.md"
vscode_is_flatpak && die "$VSCODE_FLATPAK_MSG"
rc=0
name="$(sandbox_vm "$sandbox_dir")" || rc=$?

PROBLEMS=()
check_agent_config
check_host_exposure
check_vscode_settings
check_sbx_ssh
if (( rc == 2 )); then
  PROBLEMS+=("couldn't ask sbx for sandbox $n's VM -- check sbx works: sbx diagnose")
elif (( rc == 1 )); then
  # No VM yet: it's created below, once every check has passed. Its name
  # must be free, and the sandbox's .vscode folder usable, as for make run.
  name="$(sbx_name "$sandbox_dir")"
  sbx_exists "$name" \
    && PROBLEMS+=("an sbx VM named $name already exists but doesn't mount $sandbox_dir, so it isn't this sandbox's (made by hand?) -- look at it with sbx ls, and remove it if it's not needed: sbx rm $name")
  vscode_dir_problems "$sandbox_dir"
elif ! vm_has_vscode_mount "$sandbox_dir" "$name"; then
  PROBLEMS+=("$name doesn't mount the sandbox's .vscode read-only (it wasn't made by make run or make code), so the agent could rewrite the settings that keep your credentials out of the VM. Recreate the VM (the sandbox's files stay; the agent's history inside the VM goes): make run N=$n FRESH=1")
fi
vscode_launch_cmd \
  || PROBLEMS+=("couldn't find VS Code${VSCODE_CMD:+ (VSCODE_CMD=$VSCODE_CMD)} -- install it, or set VSCODE_CMD in .env to the command that opens it")
report_problems "can't open sandbox $n in VS Code:"

if (( rc == 1 )); then
  validate_config warn
  vm_create_args "$sandbox_dir" || die "couldn't write $sandbox_dir/.vscode/settings.json"
  echo "Creating ${C_BOLD}$name${C_RESET} ($AGENT) on $sandbox_dir (no agent is started; make run N=$n attaches to it)"
  sbx create --name "$name" ${VM_CREATE_FLAGS[@]+"${VM_CREATE_FLAGS[@]}"} "$AGENT" "${VM_WORKSPACES[@]}" >/dev/null \
    || die "couldn't create $name -- check sbx works (sbx diagnose), then try again"
  # The VM must have the agent make run would give it, and the read-only
  # .vscode mount, or the agent could later rewrite the settings.
  created_agent="$(sbx_agent_of "$name")"
  if is_builtin_agent "$AGENT" && [[ -n "$created_agent" && "$created_agent" != "$AGENT" ]]; then
    die "$name was created with $created_agent, not $AGENT -- remove it (sbx rm $name) and run make code N=$n again"
  fi
  vm_has_vscode_mount "$sandbox_dir" "$name" \
    || die "$name doesn't mount the sandbox's .vscode read-only -- remove it (sbx rm $name), then run make code N=$n again"
fi

args=(--new-window --folder-uri "vscode-remote://ssh-remote+$name.sbx$(uri_path "$sandbox_dir")")
[[ -n "$VSCODE_PROFILE" ]] && args+=(--profile "$VSCODE_PROFILE")
echo "Opening sandbox $n in VS Code, running inside ${C_BOLD}$name${C_RESET}${VSCODE_PROFILE:+ (profile $VSCODE_PROFILE)}"
echo "If VS Code asks whether to trust the folder, trusting it is fine: everything runs in the VM."
"${VSCODE_LAUNCH[@]}" "${args[@]}"
