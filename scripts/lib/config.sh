# shellcheck disable=SC2034  # globals set here are read by the files that source this one
# Loads the tool's config. Sourced first by all.sh, which sets TOOL_ROOT.
# Sourced, not executed: no shebang, no `set -e` (would leak into the caller).
#
# Config is two plain-bash files, sourced in order:
#   .env.default  (tracked)    the tool's defaults: AGENT, AGENT_ARGS,
#                              SBX_CREATE_FLAGS, SBX_NAME_PREFIX, AGENT_GIT_PUSH,
#                              AGENT_INSTRUCTIONS, SANDBOX_NOTES_FILE, VSCODE_CMD,
#                              VSCODE_PROFILE, VSCODE_USER_DIR
#   .env          (gitignored, required)  your repos -- REPOS, SOURCE_BRANCHES,
#                              DEFAULT_REPOS, REPO_GROUP, REPO_DESC -- and any
#                              overrides of those defaults
# See .env.example for the syntax. validate_config (validate.sh) checks both.

# Empty placeholders, not defaults (those are in .env.default): they keep
# `set -u` happy if a file is missing, and make the maps associative before
# either file is read, so `AGENT_ARGS[codex]=...` in .env works without its
# own `declare -A`.
declare -A REPOS=() SOURCE_BRANCHES=() REPO_GROUP=() REPO_DESC=() AGENT_ARGS=()
DEFAULT_REPOS=() AGENT_INSTRUCTIONS=()
AGENT="" SBX_CREATE_FLAGS="" SBX_NAME_PREFIX="" AGENT_GIT_PUSH="" SANDBOX_NOTES_FILE=""
VSCODE_CMD="" VSCODE_PROFILE="" VSCODE_USER_DIR=""

DEFAULTS_FILE="$TOOL_ROOT/.env.default"
ENV_FILE="$TOOL_ROOT/.env"
# shellcheck source=/dev/null
[[ -f "$DEFAULTS_FILE" ]] && source "$DEFAULTS_FILE"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# Sandboxes are created at the top of the repo, next to .env, wherever it's
# checked out. A checksum of its path is also part of every sbx VM name
# (sbx_name in agents.sh), so this must stay the repo root, not scripts/.
SANDBOX_ROOT="$TOOL_ROOT"
