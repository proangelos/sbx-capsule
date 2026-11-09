# Helpers for the test files (tests/*.test.sh), sourced by tests/run.sh.
# Plain bash, no test framework: AGENTS.md rules out new dependencies.
#
# Each test is a function named test_*. The runner gives each one a fresh
# scratch copy of the tool (make_scratch) and runs it in a subshell from
# there, so tests can't affect each other or the checkout they run from.
# A test fails if any assertion in it fails.
#
# What a test can use, after make_scratch:
#   $T        the scratch folder: tool/, src/, home/, sbx/, bin/
#   $TOOL     the scratch copy of the tool (also SANDBOX_ROOT)
#   $SRC      folder of source checkouts: $SRC/api (origin $SRC/api.git)
#   mk        runs make in the scratch copy, with a time limit; sets OUT, RC
#   fake_vm   adds a VM to the fake sbx (tests/fake-sbx/sbx)
#   vm_name   the VM name the tool gives a sandbox folder
#   assert_*  see below

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# Host-side git calls on clones give up after this many seconds (the tool
# uses 120); short, so the hang tests finish quickly.
export SANDBOX_GIT_TIMEOUT=3
# Every make command is stopped after this long: a hang is a failure.
TEST_CMD_TIMEOUT="${TEST_CMD_TIMEOUT:-60}"

FAILS_FILE=""

# ---- assertions ----

_fail() {
  echo "    FAIL: $*" >&2
  [[ -n "$FAILS_FILE" ]] && echo "$*" >> "$FAILS_FILE"
  return 0
}

_show_out() { [[ -n "${OUT:-}" ]] && printf '%s\n' "$OUT" | sed 's/^/      | /' >&2; return 0; }

assert_ok()   { (( RC == 0 )) || { _fail "$1 (exit $RC)"; _show_out; }; }
assert_fails() {
  if (( RC == 0 )); then _fail "$1 (expected a failure)"; _show_out
  elif (( RC == 124 )); then _fail "$1 (timed out)"; _show_out
  fi
}
assert_contains() {
  [[ "$OUT" == *"$2"* ]] || { _fail "$1 (output lacks: $2)"; _show_out; }
}
assert_not_contains() {
  [[ "$OUT" != *"$2"* ]] || { _fail "$1 (output has: $2)"; _show_out; }
}
assert_exists()  { [[ -e "$2" || -L "$2" ]] || _fail "$1 ($2 doesn't exist)"; }
assert_missing() { [[ ! -e "$2" && ! -L "$2" ]] || _fail "$1 ($2 exists)"; }
assert_eq()      { [[ "$2" == "$3" ]] || _fail "$1 (got '$2', want '$3')"; }

# ---- running things ----

# bounded <seconds> <command>...  -- runs an external command, stopping it
# after <seconds>; exits 124 then, like timeout(1), which macOS lacks.
bounded() {
  local secs="$1" pid w rc=0
  shift
  "$@" < /dev/null &
  pid=$!
  ( trap 'kill $s 2>/dev/null; exit 0' TERM
    sleep "$secs" & s=$!; wait $s
    kill -TERM "$pid" 2>/dev/null && touch "$T/.timed-out.$pid"
    sleep 2 & s=$!; wait $s
    kill -KILL "$pid" 2>/dev/null ) < /dev/null > /dev/null 2>&1 &
  w=$!
  wait "$pid" || rc=$?
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
  if [[ -e "$T/.timed-out.$pid" ]]; then
    rm -f -- "$T/.timed-out.$pid"
    return 124
  fi
  return "$rc"
}

# mk <make args>...  -- make in the scratch copy; output in OUT, exit in RC.
mk() {
  RC=0
  bounded "$TEST_CMD_TIMEOUT" make --no-print-directory -C "$TOOL" "$@" > "$T/out" 2>&1 || RC=$?
  OUT="$(cat "$T/out")"
  (( RC == 124 )) && OUT+=$'\n'"[timed out after ${TEST_CMD_TIMEOUT}s]"
  return 0
}

# in_tool <command>...  -- a command run from the scratch copy, time-limited,
# with OUT and RC like mk. For calling the scripts' helpers directly.
in_tool() {
  RC=0
  (cd "$TOOL" && bounded "$TEST_CMD_TIMEOUT" "$@") > "$T/out" 2>&1 || RC=$?
  OUT="$(cat "$T/out")"
  return 0
}

# tree_state  -- a listing of everything under the scratch copy (names and
# types), to show a failing command changed nothing.
tree_state() {
  (cd "$TOOL" && find . -path ./.git -prune -o -print | LC_ALL=C sort)
}

# ---- scratch setup ----

# make_scratch  -- a throwaway copy of the tool (its tracked and new,
# non-ignored files, as in the working tree), a source checkout `api` with
# a bare origin, a .env for it, an isolated HOME and git identity, and the
# fake sbx first on PATH.
make_scratch() {
  local f
  T="$(mktemp -d "${TMPDIR:-/tmp}/sbxc-test.XXXXXX")"
  T="$(cd "$T" && pwd -P)"
  TOOL="$T/tool" SRC="$T/src"
  mkdir -p "$TOOL" "$SRC" "$T/home" "$T/sbx" "$T/bin"

  while IFS= read -r -d '' f; do
    [[ -f "$REPO_DIR/$f" && ! -L "$REPO_DIR/$f" ]] || continue
    mkdir -p "$TOOL/$(dirname "$f")"
    cp -p "$REPO_DIR/$f" "$TOOL/$f"
  done < <(git -C "$REPO_DIR" ls-files -z --cached --others --exclude-standard)

  export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  export FAKE_SBX_DIR="$T/sbx"
  ln -s "$TESTS_DIR/fake-sbx/sbx" "$T/bin/sbx"
  export PATH="$T/bin:$PATH"
  unset NO_COLOR
  export NO_COLOR=1

  (cd "$TOOL" && git init -q && git add -A && git commit -q -m scratch)
  make_source api

  cat > "$TOOL/.env" <<EOF
declare -A REPOS=([api]="$SRC/api")
declare -A SOURCE_BRANCHES=([api]=main)
DEFAULT_REPOS=(api)
EOF
  chmod go-w "$TOOL/.env" "$TOOL/.env.default"
}

# make_source <repo>  -- a source checkout $SRC/<repo> on main, one commit,
# with a bare origin $SRC/<repo>.git.
make_source() {
  git init -q --bare "$SRC/$1.git"
  git -C "$SRC/$1.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$SRC/$1.git" "$SRC/$1" 2>/dev/null
  git -C "$SRC/$1" checkout -q -b main 2>/dev/null || true
  echo "$1" > "$SRC/$1/README"
  git -C "$SRC/$1" add README
  git -C "$SRC/$1" commit -q -m "initial $1"
  git -C "$SRC/$1" push -q origin main 2>/dev/null
  git -C "$SRC/$1" fetch -q origin
}

# add_repo_to_env <repo>  -- makes a source checkout and adds it to .env.
add_repo_to_env() {
  make_source "$1"
  printf 'REPOS[%s]="%s"\nSOURCE_BRANCHES[%s]=main\n' "$1" "$SRC/$1" "$1" >> "$TOOL/.env"
}

# vm_name <sandbox folder>  -- the name make run gives its VM.
vm_name() {
  (cd "$TOOL" && bash -c 'source scripts/lib/all.sh; sbx_name "$1"' _ "$1")
}

# fake_vm <name> <status> <agent> <workspace>...  -- a VM the fake sbx lists.
fake_vm() {
  (IFS=$'\t'; printf '%s\n' "$*") >> "$FAKE_SBX_DIR/vms"
}

# hide_jq  -- PATH without jq, so the scripts read `sbx ls --json` with
# their awk fallback: a folder of links to every other command on PATH.
hide_jq() {
  local d p f
  mkdir -p "$T/nojq"
  IFS=: read -r -a p <<< "$PATH"
  for d in "${p[@]}"; do
    for f in "$d"/*; do
      [[ -x "$f" && "${f##*/}" != jq && ! -e "$T/nojq/${f##*/}" ]] && ln -s "$f" "$T/nojq/${f##*/}"
    done
  done
  export PATH="$T/nojq"
}

# commit_in <dir> <message>  -- an empty commit, as the agent would make.
commit_in() { git -C "$1" commit -q --allow-empty -m "$2"; }

# ---- running a test file ----

# run_tests  -- runs every test_* function defined so far, each in its own
# subshell with its own scratch copy. Prints one line per test and returns
# non-zero if any failed. TEST_FILTER, if set, picks tests by name
# (substring).
run_tests() {
  local fn rc=0 failed=0 passed=0
  for fn in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    [[ -z "${TEST_FILTER:-}" || "$fn" == *"$TEST_FILTER"* ]] || continue
    if (
      set -uo pipefail
      make_scratch
      FAILS_FILE="$T/fails"
      : > "$FAILS_FILE"
      cd "$TOOL"
      "$fn"
      [[ ! -s "$FAILS_FILE" ]] || exit 1
      [[ -n "${KEEP_SCRATCH:-}" ]] || rm -rf -- "$T"
    ); then
      echo "  ok    $fn"
      passed=$((passed + 1))
    else
      echo "  FAIL  $fn"
      failed=$((failed + 1))
    fi
  done
  echo "$passed $failed" >> "${RESULTS_FILE:-/dev/null}"
  (( failed == 0 ))
}
