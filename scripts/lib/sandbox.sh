# Sandbox folders: finding them, telling clones from other folders, the
# files create.sh generates in each, and reading them safely from the host.
# Sourced via all.sh (after agents.sh, for AGENT_SHIMS), not executed: no
# shebang, no `set -e`.
#
# Everything in a sandbox folder is writable from inside its sbx VM. The
# host-side commands treat it as untrusted: they never source a file from
# it, and run git in its clones only through sandbox_git.

# Sandbox dirs are "<n>" or "<n>-<title>" directly under SANDBOX_ROOT.
# is_sandbox_name tests the folder name alone (the folder may be gone).
is_sandbox_name() { [[ "$1" != */* && "$1" =~ ^[0-9]+(-.*)?$ ]]; }
is_sandbox_dir() { [[ -d "$1" ]] && is_sandbox_name "$(basename "$1")"; }

# find_sandbox_dir <n>  -- prints the sandbox's directory, or exits. Refuses
# when more than one folder has that number ("3" and "3-loginFix"), rather
# than guessing which one make run/add/destroy should act on.
find_sandbox_dir() {
  local n="$1" candidate matches=()
  [[ "$n" =~ ^[0-9]+$ ]] || die "sandbox number must be a number, got '$n'"
  for candidate in "$SANDBOX_ROOT/$n" "$SANDBOX_ROOT/$n"-*; do
    [[ -d "$candidate" && "$(basename "$candidate")" =~ ^${n}(-.*)?$ ]] && matches+=("$candidate")
  done
  case ${#matches[@]} in
    0) die "no sandbox numbered $n under $SANDBOX_ROOT" ;;
    1) echo "${matches[0]}" ;;
    *) die "more than one folder is sandbox $n: $(printf '%s ' "${matches[@]##*/}")-- move all but one out of $SANDBOX_ROOT first (a sandbox's VM is named after its folder, so a renamed one gets a new VM)" ;;
  esac
}

# is_clone <dir>  -- true if <dir> is a real folder (not a symlink, which
# the tool never makes: one in a sandbox could point at any repo on the
# host) holding a .git directory. A trailing slash is ignored: `-L dir/`
# follows the link.
is_clone() {
  local d="$1"
  while [[ "$d" == */ && "$d" != / ]]; do d="${d%/}"; done
  [[ ! -L "$d" && -d "$d/.git" ]]
}

# has_symlink_under <base> <relative path>  -- true if any part of the
# path below <base> is a symlink, so following it could leave <base>.
has_symlink_under() {
  local p="$1" part rest="$2"
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"
    [[ "$rest" == */* ]] && rest="${rest#*/}" || rest=""
    [[ -n "$part" ]] || continue
    p="$p/$part"
    [[ -L "$p" ]] && return 0
  done
  return 1
}

# Files create.sh writes at a sandbox's root; destroy.sh deletes exactly
# these (anything else there is notes, and gets archived). create.sh and
# run.sh also write .vscode/settings.json (scripts/lib/vscode.sh), which
# destroy.sh removes separately, from a real folder only.
GENERATED_FILES=(README.md AGENTS.md "${AGENT_SHIMS[@]}")

# make fetch leaves one bundle per repo at the sandbox root,
# .fetch-<repo>.bundle; destroy.sh deletes whatever matches this, rather
# than archiving it with the notes.
FETCH_BUNDLE_GLOB='.fetch-*.bundle'

# sandbox_git <dir> <git args>...  -- git in a sandbox clone (or a submodule
# in one), for the host. The VM can write the clone's .git, and plenty of git
# config makes git run commands. Everything that could fire for the commands
# the tool runs (status, rev-parse, rev-list, stash list, ls-files, config)
# is overridden here, and command-line -c beats any config file:
#   core.fsmonitor          run by `git status`. Empty means off to every git
#   hooks                   core.hooksPath=/dev/null; GIT_OPTIONAL_LOCKS=0
#                           also stops status writing the index, which fires
#                           the post-index-change hook
#   filter drivers          run by status to re-read a file; see below
#   gpg.*program            run by `stash list` when log.showSignature is set
#   transports              a lazy fetch (partial clone) could reach ext::,
#                           which runs a command; GIT_ALLOW_PROTOCOL=none
#                           beats every protocol.*.allow and blocks them all
#   pager                   GIT_PAGER beats core.pager and pager.<cmd>
#   core.worktree           --git-dir/--work-tree pin the repo to <dir>, and
#                           stop git searching parent folders for one
# stdin is /dev/null and nothing may prompt (GIT_TERMINAL_PROMPT=0,
# GIT_ASKPASS and SSH_ASKPASS false).
#
# Hangs. The VM can make git block forever without running anything: a
# config include of /dev/tty, a FIFO or /dev/zero, or a FIFO in place of
# .git/config, HEAD or the index. Two defences:
#   - a pre-check (sandbox_git_precheck) refuses, with a clear message, a
#     clone whose git config isn't a regular file or includes other files
#     (the tool never writes either). It reads a hard-link snapshot of the
#     config (snapshot_sandbox_file), so it never opens a FIFO or device.
#   - every git process runs under a watchdog (run_with_timeout, for
#     SANDBOX_GIT_TIMEOUT seconds) and counts as failed if it's stopped, so
#     callers fail closed. That
#     covers what the pre-check can't: a swap between the check and git's
#     read, and the other files git reads.
#
# Filter names are arbitrary, so every filter setting found in the clone's
# config (any scope; the pre-check has shown it has no includes, so they
# aren't followed) is overridden: clean, smudge and
# process with your own global or system value for that setting if there is
# one (git-lfs keeps working), else empty, which is off; required with
# yours, else false. Only settings that appear are touched -- git prefers
# `process` over `clean` even when it's empty, so overriding a `process`
# nobody set would switch off your own clean-only filters. A name -c can't
# express (one with '=' or a control character) makes this fail rather than
# run unprotected.
#
# The filters are listed by one git process and the command runs in
# another, so a config change in between would let a filter through. Only
# `git config` (which never runs a filter) is safe while a VM can change the
# clone; for anything else, stop the VM first (destroy.sh does, through
# vms_running_on in host_safety.sh).
sandbox_git() {
  local dir="$1" rec key name sub val seen=$'\n' overrides=() list rc=0
  shift
  sandbox_git_precheck "$dir" || return 1
  # The listing goes through a file: it's NUL-separated, and its failure
  # (other than 1, nothing matched) must stop this, a timeout above all,
  # rather than run the command with no filters switched off.
  list="$(mktemp)" || return 1
  _sandbox_git_base "$dir" config -z --no-includes --get-regexp '^filter\.' > "$list" 2> "$list.err" || rc=$?
  if (( rc > 1 )); then
    head -1 "$list.err" >&2
    rm -f -- "$list" "$list.err"
    return 1
  fi
  while IFS= read -r -d '' rec; do
    key="${rec%%$'\n'*}" name="${key#filter.}" sub="${name##*.}" name="${name%.*}"
    if [[ "$name" == *=* || "$name" == *[[:cntrl:]]* ]]; then
      echo "a filter driver in its git config has a name that can't be safely switched off -- look at its .git/config" >&2
      rm -f -- "$list" "$list.err"
      return 1
    fi
    case "$sub" in clean|smudge|process|required) ;; *) continue ;; esac
    [[ "$seen" == *$'\n'"$name.$sub"$'\n'* ]] && continue
    seen+="$name.$sub"$'\n'
    val="$(_trusted_git_config "filter.$name.$sub")"
    [[ "$sub" == required && -z "$val" ]] && val=false
    overrides+=(-c "filter.$name.$sub=$val")
  done < "$list"
  rm -f -- "$list" "$list.err"
  _sandbox_git_base "$dir" ${overrides[@]+"${overrides[@]}"} "$@"
}

# How long one git process on a sandbox clone may run before it's stopped
# (see "Hangs" above). Fixed for the whole tool, not a .env setting; long
# enough for `git status` on a big repo's first index refresh.
SANDBOX_GIT_TIMEOUT="${SANDBOX_GIT_TIMEOUT:-120}"

# sandbox_git_precheck <dir>  -- fails, saying why on stderr, if the
# clone's (or submodule's) git config isn't a regular file, includes other
# files, or is joined by a commondir; see "Hangs" above sandbox_git. Also
# used before make push and make fetch run git upload-pack in a clone,
# which reads its config (includes too). Reads
# only hard-link snapshots taken in a .staging.* folder, never the files in
# place. A clean result can go stale (the VM can change the files after);
# run_with_timeout covers that.
sandbox_git_precheck() {
  local dir="$1" tmp gd="" line f msg=""
  if [[ -L "$dir/.git" ]]; then
    echo "its .git is a symlink (the tool never makes one) -- look at it" >&2
    return 1
  fi
  if ! tmp="$(mktemp -d "$SANDBOX_ROOT/.staging.gitcheck.XXXXXX" 2>/dev/null)"; then
    echo "couldn't make a folder in $SANDBOX_ROOT to check its git config in" >&2
    return 1
  fi
  if [[ -d "$dir/.git" ]]; then
    gd="$dir/.git"
  elif snapshot_sandbox_file "$dir/.git" "$tmp/gitfile" \
       && IFS= read -r line < "$tmp/gitfile" && [[ "$line" == "gitdir: "?* ]]; then
    # A submodule: .git is a file naming its git dir.
    gd="${line#gitdir: }"
    [[ "$gd" == /* ]] || gd="$dir/$gd"
  else
    msg="its .git is neither a folder nor a gitdir file"
  fi
  if [[ -z "$msg" && ( -e "$gd/commondir" || -L "$gd/commondir" ) ]]; then
    msg="its git dir has a commondir file, which makes git read another repo's config (the tool never writes one)"
  fi
  for f in config config.worktree; do
    [[ -z "$msg" ]] || break
    [[ "$f" == config.worktree && ! -e "$gd/$f" && ! -L "$gd/$f" ]] && continue
    if ! snapshot_sandbox_file "$gd/$f" "$tmp/$f"; then
      msg="its git $f isn't a regular file you own (a symlink, FIFO or device would hang or redirect git)"
    elif grep -qiE '\[[[:space:]]*include' "$tmp/$f"; then
      msg="its git $f includes other files (the tool never writes that; one naming /dev/tty or a FIFO would hang git)"
    fi
  done
  rm -rf -- "$tmp"
  [[ -z "$msg" ]] && return 0
  echo "$msg -- look at its .git/config" >&2
  return 1
}

# _sandbox_git_base <dir> <git args>...  -- sandbox_git without the
# pre-check or the filter overrides. Used on its own only to list the
# filters (`git config` never runs a filter).
_sandbox_git_base() {
  local dir="$1"
  shift
  run_with_timeout env GIT_PAGER=cat GIT_OPTIONAL_LOCKS=0 GIT_ALLOW_PROTOCOL=none \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false SSH_ASKPASS=false \
    git -C "$dir" --git-dir=.git --work-tree=. \
      -c core.fsmonitor= -c core.hooksPath=/dev/null -c log.showSignature=false \
      -c gpg.program=false -c gpg.ssh.program=false -c gpg.x509.program=false \
      "$@"
}

# run_with_timeout <command> [<args>...]  -- runs an external command (not a
# function: it must be the process that's stopped) with stdin from
# /dev/null, and stops it after SANDBOX_GIT_TIMEOUT seconds, failing with a
# message on stderr. For git that reads a sandbox clone, which the VM can
# make block forever (see "Hangs" above sandbox_git). A process the command
# started itself (git fetch's upload-pack) may outlive it, still blocked,
# but the make command carries on.
run_with_timeout() {
  local pid watcher rc=0 start="$SECONDS"
  "$@" < /dev/null &
  pid=$!
  # Its output goes nowhere: an open copy of a $(...) pipe would keep the
  # caller waiting for the watchdog's sleep.
  _watchdog "$pid" "$SANDBOX_GIT_TIMEOUT" < /dev/null > /dev/null 2>&1 &
  watcher=$!
  wait "$pid" || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  if (( rc != 0 && SECONDS - start >= SANDBOX_GIT_TIMEOUT )); then
    echo "git ran for over ${SANDBOX_GIT_TIMEOUT}s on a sandbox clone and was stopped -- something in its .git may be a FIFO or device (look at it), or the repo is just slow" >&2
  fi
  return "$rc"
}

# _watchdog <pid> <seconds>  -- run in the background by run_with_timeout:
# stops <pid> (TERM, then KILL) once <seconds> have passed. Pure bash and
# sleep, since macOS has no timeout(1). Exits quietly, sleep and all, on
# TERM.
_watchdog() {
  local s
  trap 'kill "$s" 2>/dev/null; exit 0' TERM
  sleep "$2" & s=$!
  wait "$s"
  kill -TERM "$1" 2>/dev/null || exit 0
  sleep 2 & s=$!
  wait "$s"
  kill -KILL "$1" 2>/dev/null
  exit 0
}

# _trusted_git_config <key>  -- the key's value from your own global config,
# else system config, else nothing. Read from $TOOL_ROOT, never from inside
# a sandbox.
_trusted_git_config() {
  git -C "$TOOL_ROOT" config --global --get "$1" 2>/dev/null \
    || git -C "$TOOL_ROOT" config --system --get "$1" 2>/dev/null \
    || true
}

# move_into_sandbox <src> <sandbox_dir>  -- moves a file or folder built
# outside the sandbox (in a .staging.* folder under SANDBOX_ROOT, where the
# VM can't touch it while it's being made) into <sandbox_dir>, under its own
# name. Name it in staging as it should be named in the sandbox.
#
# The VM can put anything at <sandbox_dir>/<name> at any moment. Given
# `mv src dest`, mv first asks whether dest is a folder, following
# symlinks, and if so moves src into it: so a symlink planted at dest would
# send the file into whatever host folder it points at. BSD mv's -h only
# narrows that to a race (it looks with lstat, then the VM swaps a real
# folder for a symlink before the rename). So mv never gets to decide:
#   - GNU mv -T renames onto dest as-is, never into it.
#   - Elsewhere (macOS), mv is pointed at <sandbox_dir> itself, so it is
#     the folder mv moves into, and it renames src to <sandbox_dir>/<name>.
#     The VM can't replace <sandbox_dir> (its entry is in SANDBOX_ROOT,
#     which no VM can write), and rename(2) replaces a symlink in the last
#     place rather than following it, and fails on a folder that isn't
#     empty. src is on the same filesystem, so mv never falls back to
#     copying through whatever is there.
# Fails if <name> didn't end up a real file or folder in the sandbox.
move_into_sandbox() {
  local src="$1" dir="$2" name
  name="${src##*/}"
  [[ -n "$name" && -d "$dir" && ! -L "$dir" ]] || return 1
  if mv --version >/dev/null 2>&1; then   # GNU coreutils
    mv -T -- "$src" "$dir/$name" || return 1
  else
    mv -f -- "$src" "$dir/" || return 1
  fi
  [[ -e "$dir/$name" && ! -L "$dir/$name" ]]
}

# snapshot_sandbox_file <file> <dest>  -- hard-links <file>, in a sandbox, to
# <dest>, in a folder the VM can't see, and succeeds only if what was linked
# is a regular file. Callers then read <dest>, never <file>.
#
# Checking <file> and then opening it by name is a race: in between, the VM
# can swap in a symlink to any host file (whose contents a caller like
# make add would copy back into the sandbox) or a FIFO (which hangs the
# read). A hard link takes whatever is at <file> in one step that doesn't
# follow symlinks (-P), and the VM can't change what <dest> is afterwards,
# only the file's contents, which are untrusted anyway. <dest> must be on
# the sandbox's filesystem and not exist yet: callers use a .staging.*
# folder under SANDBOX_ROOT. Fails closed if the link can't be made (a
# folder, or a file the VM left owned by root).
snapshot_sandbox_file() {
  local file="$1" dest="$2"
  ln -P -- "$file" "$dest" 2>/dev/null || return 1
  [[ -f "$dest" && ! -L "$dest" ]] && return 0
  rm -f -- "$dest"
  return 1
}

# state_dir_of <sandbox_dir>  -- the sandbox's host-side records,
# .state/<sandbox folder>/ under SANDBOX_ROOT, where no VM can write (make
# run refuses while one could). make destroy removes it with the sandbox.
#   push_as   the sandbox's PUSH_AS, or an empty line (create.sh)
#   pushed    "<repo> <sha>" per commit make push sent (push.sh)
state_dir_of() { printf '%s\n' "$SANDBOX_ROOT/.state/$(basename "$1")"; }

# record_push_as <sandbox_dir> <push_as>  -- writes the push_as record.
record_push_as() {
  local d
  d="$(state_dir_of "$1")"
  mkdir -p "$d" && printf '%s\n' "$2" > "$d/push_as"
}

# read_push_as <sandbox_dir>  -- sets SANDBOX_PUSH_AS, the branch the
# sandbox's clones were made to push to, from its push_as record (empty for
# none). Fails if the sandbox has no record: make new writes one for every
# sandbox, so a missing one means the folder wasn't made by this tool.
read_push_as() {
  local f
  f="$(state_dir_of "$1")/push_as"
  SANDBOX_PUSH_AS=""
  [[ -f "$f" ]] || return 1
  IFS= read -r SANDBOX_PUSH_AS < "$f" || true
}
