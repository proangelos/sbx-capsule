#!/usr/bin/env bash
# First-time setup: create your .env from .env.example if you don't have one
# yet, then check this machine with doctor.sh. Installs nothing, and never
# touches an existing .env.
#
# Usage: scripts/commands/init.sh        (or: make init)
#
# A new .env still holds the example's placeholder repos, so only the tools
# are checked then; edit .env and run `make doctor` for the full check. With
# an existing .env, init runs the full doctor straight away.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"
doctor="$(dirname "${BASH_SOURCE[0]}")/doctor.sh"

if [[ -f "$ENV_FILE" ]]; then
  echo "You already have $ENV_FILE -- leaving it as it is."
  exec "$doctor"
fi

cp "$TOOL_ROOT/.env.example" "$ENV_FILE"
echo "${C_GREEN}Created${C_RESET} $ENV_FILE from .env.example."

rc=0
"$doctor" --tools-only || rc=$?

cat <<EOF

${C_BOLD}Next:${C_RESET}
  1. Edit .env: replace the example repos with yours -- a REPOS path and a
     SOURCE_BRANCHES entry for each (.env.example explains every setting).
  2. make doctor     checks your repos too
  3. make new WITH="<repo> ..."   then   make run N=<n>
EOF
(( rc == 0 )) || echo "Fix the problems above first; make run needs sbx working."
exit "$rc"
