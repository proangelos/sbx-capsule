# git version checks: the minimum the tool needs, and whether this git
# predates upstream fixes for bugs that matter when the host runs git on
# what an agent wrote. make doctor notes them in full; make push, make
# fetch and make destroy, which run git on a sandbox's clones, warn in one
# line when the release series never got the fix (warn_old_git).
# Sourced via all.sh, not executed: no shebang, no `set -e`.

# git_version  -- this git's version, as dotted numbers (e.g. 2.43.0).
git_version() {
  git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# version_at_least <have> <want>  -- dotted versions, numerically.
version_at_least() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# git_has_fix <version>  -- true if that upstream git release has the fix for
# CVE-2022-23521: 2.39.1 and later, or the patch release of an older series
# that got it (2.30.7 ... 2.38.3, released together in January 2023).
git_has_fix() {
  local v="$1" series="${1%.*}" fixed
  version_at_least "$v" 2.39.1 && return 0
  case "$series" in
    2.30) fixed=2.30.7 ;; 2.31) fixed=2.31.6 ;; 2.32) fixed=2.32.5 ;;
    2.33) fixed=2.33.6 ;; 2.34) fixed=2.34.6 ;; 2.35) fixed=2.35.6 ;;
    2.36) fixed=2.36.4 ;; 2.37) fixed=2.37.5 ;; 2.38) fixed=2.38.3 ;;
    *) return 1 ;;
  esac
  version_at_least "$v" "$fixed"
}

# git_has_upload_pack_fix <version>  -- true if that upstream git release
# has the fix for CVE-2024-32465 (git upload-pack on an untrusted repo could
# be made to run its hooks or config): 2.45.1 and later, or the patch
# release of an older series that got it (2.39.4 ... 2.44.1, released
# together in May 2024).
git_has_upload_pack_fix() {
  local v="$1" series="${1%.*}" fixed
  version_at_least "$v" 2.45.1 && return 0
  case "$series" in
    2.39) fixed=2.39.4 ;; 2.40) fixed=2.40.2 ;; 2.41) fixed=2.41.1 ;;
    2.42) fixed=2.42.2 ;; 2.43) fixed=2.43.4 ;; 2.44) fixed=2.44.1 ;;
    *) return 1 ;;
  esac
  version_at_least "$v" "$fixed"
}

# warn_old_git  -- one warning line if this git's release series never got
# an upstream fix for either CVE above (before 2.30 and 2.39). A version
# number can't show a distribution's backported fix, and distributions
# backport to the series they ship (Ubuntu 24.04's 2.43.0 has both), so a
# patch level below the fix in a fixed series is left to make doctor's
# note rather than warned about on every command. SECURITY.md lists this
# as a known limitation.
warn_old_git() {
  local v missing=()
  v="$(git_version)"
  [[ -n "$v" ]] || return 0
  version_at_least "$v" 2.30 || missing+=(CVE-2022-23521)
  version_at_least "$v" 2.39 || missing+=(CVE-2024-32465)
  (( ${#missing[@]} )) || return 0
  local list="${missing[0]}"
  (( ${#missing[@]} == 1 )) || list+=" and ${missing[1]}"
  warn "git $v is from a release series with no upstream fix for $list, which matters when the host reads what the agent wrote -- unless your distribution backported it, upgrade git (make doctor says more)"
}
