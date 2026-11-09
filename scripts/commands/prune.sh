#!/usr/bin/env bash
# Remove the sbx VMs left over from this checkout's sandboxes that are gone.
# A sandbox folder removed by hand, or destroyed while sbx was missing,
# leaves its VM behind, and make new skips that number until the VM is
# removed. Lists them, asks once, then removes them. Only ever this
# checkout's VMs (leftover_vms in scripts/lib/agents.sh): VMs from other
# checkouts, or made by hand, are never touched. Each VM's agent history and
# settings go with it; its sandbox's files are already gone.
#
# Usage: scripts/commands/prune.sh        (or: make prune [YES=1])
#   YES=1   don't ask before removing (needed without a terminal).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"

have_sbx || die "sbx (Docker Sandboxes) isn't installed -- see docs/DOCKER_SANDBOXES.md"
# leftover_vms fails when sbx doesn't answer, which mustn't read as "nothing
# left over".
vm_lines="$(leftover_vms)" || die "sbx doesn't answer -- check it works (sbx diagnose), then try again"

names=() folders=() lines=()
while IFS=$'\t' read -r name status _ ws; do
  [[ -n "$name" ]] || continue
  names+=("$name") folders+=("$ws")
  # The folder name came from sbx; printed safely all the same.
  printf -v line '  %-32s %-10s (%s/ is gone)' "$name" "$status" "$(safe_text "${ws##*/}")"
  lines+=("$line")
done <<< "$vm_lines"

if (( ${#names[@]} == 0 )); then
  echo "No leftover VMs: every VM this checkout made still has its sandbox folder."
  exit 0
fi

echo "${C_YELLOW}${C_BOLD}VMs left over from sandboxes that are gone${C_RESET} (this checkout's only):"
printf '%s\n' "${lines[@]}"
echo "Removing one deletes the agent's history and settings inside it."

if [[ -z "${YES:-}" ]]; then
  if [[ ! -t 0 ]] && ! { : < /dev/tty; } 2>/dev/null; then
    die "no terminal to confirm in -- run it in one, or add YES=1"
  fi
  read -r -p "Remove ${#names[@]} VM(s)? [y/N] " answer < /dev/tty || answer=""
  if [[ "${answer,,}" != y && "${answer,,}" != yes ]]; then
    echo "Nothing was removed."
    exit 0
  fi
fi

removed=0 failed=()
for i in "${!names[@]}"; do
  name="${names[$i]}"
  # Checked again: a folder of that name may have come back while we asked.
  if [[ -d "${folders[$i]}" ]]; then
    warn "kept $name: its sandbox folder is back"
    continue
  fi
  echo "removing sbx VM $name"
  if sbx rm --force "$name" >/dev/null; then
    removed=$((removed + 1))
  else
    failed+=("$name")
  fi
done

(( ${#failed[@]} == 0 )) \
  || die "couldn't remove ${failed[*]} -- check sbx works (sbx diagnose), then run make prune again"
echo "${C_GREEN}Removed $removed VM(s).${C_RESET} make new can use their numbers again."
