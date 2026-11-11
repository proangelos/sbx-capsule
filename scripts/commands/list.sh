#!/usr/bin/env bash
# List this checkout's sandboxes, each with its repos, the state of its
# Docker Sandbox (sbx) VM and its own agent if it has one (saved by AGENT=
# on make new or make run; "-" follows AGENT in .env), then any VMs left
# over from sandboxes that are gone. Read-only. Only VMs this tool made for this checkout are shown
# (tool_vms in scripts/lib/agents.sh), never other sbx VMs on the machine.
#
# Usage: scripts/commands/list.sh        (or: make list)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

# vm_of: each sandbox folder's VM, as sandbox_vm would pick it (a VM named
# sbx_name beats one under an earlier prefix on the same folder).
declare -A vm_status=() vm_agent=() vm_of=()
leftovers=()
# If sbx doesn't answer, list the sandboxes anyway, without their VMs.
vm_lines=""
if have_sbx && ! vm_lines="$(tool_vms)"; then
  warn "couldn't ask sbx about VMs, so their state isn't shown -- check sbx works: sbx diagnose"
fi
while IFS=$'\t' read -r name status agent ws; do
  [[ -n "$name" ]] || continue
  vm_status[$name]="$status" vm_agent[$name]="$agent"
  [[ -n "${vm_of[$ws]:-}" && "$name" != "$(sbx_name "$ws")" ]] || vm_of[$ws]="$name"
  [[ -d "$ws" ]] || leftovers+=("$name"$'\t'"$status")
done <<< "$vm_lines"

# Sandbox folders, by number.
dirs=()
while IFS= read -r d; do
  [[ -n "$d" ]] && dirs+=("$d")
done < <(for d in "$SANDBOX_ROOT"/*/; do
           d="${d%/}"; is_sandbox_dir "$d" && basename "$d"
         done | sort -t- -k1,1n)

if (( ${#dirs[@]} == 0 )); then
  echo "No sandboxes yet. Make one with: make new WITH=\"<repo> ...\""
else
  printf '%s%-4s %-28s %-20s %-14s %s%s\n' "$C_BOLD" N FOLDER VM AGENT REPOS "$C_RESET"
  for folder in "${dirs[@]}"; do
    d="$SANDBOX_ROOT/$folder"
    # Repo folders are the agent's to name, so they're printed safely.
    repos=()
    for r in "$d"/*/; do
      r="${r%/}"
      is_clone "$r" && repos+=("$(safe_text "${r##*/}")")
    done
    name="${vm_of[$d]:-}"
    if ! have_sbx; then
      vm="-"
    elif [[ -n "$name" ]]; then
      vm="${vm_status[$name]}${vm_agent[$name]:+ (${vm_agent[$name]})}"
    else
      vm="no VM yet"
    fi
    # Padded before coloring, so the escape codes don't throw off the column.
    printf -v vm '%-20s' "$vm"
    [[ -n "$name" && "${vm_status[$name]}" == running ]] && vm="${C_GREEN}$vm${C_RESET}"
    read_saved_agent "$d"
    printf '%-4s %-28s %s %-14s %s\n' "${folder%%-*}" "$folder" "$vm" "$(safe_text "${SANDBOX_AGENT:--}")" "${repos[*]:--}"
  done
fi

if ! have_sbx; then
  echo
  echo "(sbx isn't installed, so VM states aren't shown -- see docs/DOCKER_SANDBOXES.md)"
elif (( ${#leftovers[@]} )); then
  echo
  echo "${C_YELLOW}${C_BOLD}VMs left over from sandboxes that are gone${C_RESET} (make new skips their numbers):"
  for l in "${leftovers[@]}"; do
    printf '  %s  %s\n' "${l%%$'\t'*}" "${l#*$'\t'}"
  done
  echo "  Remove them with: make prune"
fi

if (( ${#dirs[@]} )); then
  echo
  echo "make run N=<n> starts or reattaches a sandbox's agent; make stop N=<n> stops its VM."
fi
