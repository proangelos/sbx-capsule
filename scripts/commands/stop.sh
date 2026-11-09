#!/usr/bin/env bash
# Stop a sandbox's Docker Sandbox (sbx) VM without removing it, or every
# running VM this checkout made. A stopped VM keeps its state (the agent's
# history and settings inside it); `make run N=<n>` starts it again. The
# sandbox's files are on the host and aren't touched either way.
#
# Usage: scripts/commands/stop.sh <sandbox number>    (or: make stop N=3)
#        scripts/commands/stop.sh --all               (or: make stop ALL=1)
#
# --all covers VMs left over from sandboxes that are gone too, but only ever
# this checkout's VMs (tool_vms in scripts/lib/agents.sh).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

arg="${1:-}"
[[ -n "$arg" ]] || die "usage: make stop N=<sandbox number>, or make stop ALL=1"
have_sbx || die "sbx (Docker Sandboxes) isn't installed -- see docs/DOCKER_SANDBOXES.md"

# vm_of: each sandbox folder's VM, as sandbox_vm would pick it (a VM named
# sbx_name beats one under an earlier prefix on the same folder).
# Without an answer from sbx there's nothing to go on: "no VM" would be a guess.
vm_lines="$(tool_vms)" || die "couldn't ask sbx which VMs exist -- check it works (sbx diagnose), then try again"
declare -A vm_status=() vm_of=()
while IFS=$'\t' read -r name status _ ws; do
  [[ -n "$name" ]] || continue
  vm_status[$name]="$status"
  [[ -n "${vm_of[$ws]:-}" && "$name" != "$(sbx_name "$ws")" ]] || vm_of[$ws]="$name"
done <<< "$vm_lines"

if [[ "$arg" == --all ]]; then
  targets=()
  for name in "${!vm_status[@]}"; do
    [[ "${vm_status[$name]}" == stopped ]] || targets+=("$name")
  done
  if (( ${#targets[@]} == 0 )); then
    echo "No running VMs for this checkout's sandboxes."
    exit 0
  fi
  echo "Stopping ${#targets[@]} VM(s): ${targets[*]}"
  sbx stop "${targets[@]}" >/dev/null
  echo "${C_GREEN}Stopped.${C_RESET} Their state is kept: make run N=<n> starts one again."
  exit 0
fi

sandbox_dir="$(find_sandbox_dir "$arg")"
name="${vm_of[$sandbox_dir]:-}"
case "${name:+${vm_status[$name]}}" in
  "")
    echo "Sandbox $arg has no VM, so there's nothing to stop. (make run N=$arg creates one.)" ;;
  stopped)
    echo "Sandbox $arg's VM ($name) is already stopped." ;;
  *)
    echo "Stopping ${C_BOLD}$name${C_RESET}"
    sbx stop "$name" >/dev/null
    echo "${C_GREEN}Stopped.${C_RESET} Its state is kept: make run N=$arg starts it again." ;;
esac
