# Loads the tool's config and every helper module, in dependency order. Each
# command sources just this file:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/all.sh"
#
# Sourced, not executed: no shebang, no `set -e` (would leak into the caller).
#
# Sets TOOL_ROOT, the repo's top-level folder: where .env lives and where
# sandboxes are created (SANDBOX_ROOT, in config.sh), wherever the repo is
# checked out and whatever directory `make` was run from.

# First, before anything bash 3 can't parse: the config uses associative
# arrays (bash 4+), and macOS still ships bash 3.2 as /bin/bash.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "error: sbx-capsule needs bash 4 or newer; this is bash $BASH_VERSION." >&2
  echo "  On macOS: brew install bash, then open a new terminal so it's first on PATH." >&2
  exit 1
fi

# On Windows the tool is built and tested inside WSL2 only. From Git Bash,
# MSYS or Cygwin it would find Windows' own sbx, paths, VS Code settings
# folder and ssh.exe, and get each of them wrong, so it refuses up front.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "error: sbx-capsule runs inside WSL2 on Windows, not from Git Bash, MSYS or Cygwin." >&2
    echo "  Open a WSL2 terminal (Ubuntu, say), clone the tool there and run make from it. VS Code on the Windows side works with it." >&2
    exit 1 ;;
esac

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_ROOT="$(cd "$LIB_DIR/../.." && pwd)"

source "$LIB_DIR/config.sh"     # .env.default, then .env; SANDBOX_ROOT
source "$LIB_DIR/output.sh"     # colors, die, warn, banner
source "$LIB_DIR/agents.sh"     # sbx VM helpers, agents, AGENT_SHIMS
source "$LIB_DIR/sandbox.sh"    # sandbox lookup, GENERATED_FILES (uses AGENT_SHIMS)
source "$LIB_DIR/validate.sh"   # PROBLEMS, config and repo-spec checks
source "$LIB_DIR/git_version.sh" # git version checks (uses warn)
source "$LIB_DIR/push_as.sh"    # PUSH_AS checks
source "$LIB_DIR/clone.sh"      # clone_repo, resumed_banner
source "$LIB_DIR/host_safety.sh" # VM mounts and sbx settings that reach the host
source "$LIB_DIR/vscode.sh"     # make code: VS Code in the VM, its settings and checks
