# shellcheck disable=SC2034  # globals set here are read by the files that source this one
# Output helpers: colors, die, warn, banner, safe_text.
# Sourced via all.sh, not executed: no shebang, no `set -e`.

# ---- output: color only when stdout is a terminal and NO_COLOR isn't set ----
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
  C_CYAN=$'\e[36m' C_RESET=$'\e[0m'
else
  C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_RESET=""
fi

# safe_text <text>  -- text the agent could have chosen (file names in a
# sandbox, git's error messages about one), made safe to print: control
# characters, terminal escape sequences included, become '?'.
safe_text() { local s="$*"; printf '%s' "${s//[[:cntrl:]]/?}"; }

die()  { echo "${C_RED}${C_BOLD}error:${C_RESET} $*" >&2; exit 1; }
warn() { echo "${C_YELLOW}${C_BOLD}warning:${C_RESET} $*" >&2; }

# banner <color> <line>...  -- a boxed block meant to be impossible to miss.
banner() {
  local color="$1" bar line
  shift
  bar="$(printf '!%.0s' {1..76})"
  echo
  echo "${color}${C_BOLD}${bar}${C_RESET}"
  for line in "$@"; do
    echo "${color}${C_BOLD}!!${C_RESET} $line"
  done
  echo "${color}${C_BOLD}${bar}${C_RESET}"
  echo
}
