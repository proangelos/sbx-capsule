# What an agent can plant in its sandbox folder, which every host-side
# command must treat as data: one payload per path, each with a control
# showing the payload is live (it does fire when plain git uses the clone).
# Each test checks that the marker command never ran and nothing hung.

MARK=""
setup_mark() { MARK="$T/PWNED"; rm -f -- "$MARK"; }
assert_no_mark() { assert_missing "$1: the planted command didn't run" "$MARK"; }
assert_no_hang() { (( RC != 124 )) || _fail "$1 hung"; }

# A filtered file changed without changing its size, so `git status` has
# to read it again, through the filter, to tell whether it changed.
plant_filter() {
  local c="$1"
  git -C "$c" config filter.x.clean "touch $MARK; cat"
  git -C "$c" config filter.x.smudge "touch $MARK; cat"
  echo '* filter=x' > "$c/.git/info/attributes"
  sleep 1
  printf 'xyz\n' > "$c/README"   # same size as "api\n"
}

test_filter_driver_doesnt_run_on_destroy() {
  setup_mark
  mk new
  plant_filter "$TOOL/1/api"
  mk destroy N=1
  assert_fails "destroy sees the change"
  assert_no_mark "filter"
  # Control: plain git status in the clone does run it.
  git -C "$TOOL/1/api" status >/dev/null 2>&1 || true
  assert_exists "control: the filter is live" "$MARK"
}

test_fsmonitor_and_hooks_dont_run() {
  setup_mark
  mk new
  local c="$TOOL/1/api" h
  git -C "$c" config core.fsmonitor "touch $MARK; false"
  for h in post-index-change pre-commit post-checkout reference-transaction pre-push; do
    printf '#!/bin/sh\ntouch %s\n' "$MARK" > "$c/.git/hooks/$h"
    chmod +x "$c/.git/hooks/$h"
  done
  commit_in "$c" "work" 2>/dev/null || true
  rm -f -- "$MARK"
  mk destroy N=1
  assert_no_mark "fsmonitor/hooks on destroy"
  mk push N=1 REPO=api AS=feat/x YES=1
  assert_no_mark "hooks on push"
  mk fetch N=1
  assert_no_mark "hooks on fetch"
  mk doctor
  assert_contains "doctor reports the hook" "hook pre-commit"
  assert_contains "and the fsmonitor" "core.fsmonitor runs a command"
  assert_no_mark "doctor"
  git -C "$c" status >/dev/null 2>&1 || true
  assert_exists "control: fsmonitor is live" "$MARK"
}

test_signature_program_and_pager_dont_run() {
  setup_mark
  mk new
  local c="$TOOL/1/api"
  echo x > "$c/f"
  git -C "$c" stash -q -u
  git -C "$c" config log.showSignature true
  git -C "$c" config gpg.program "$MARK-gpg"
  printf '#!/bin/sh\ntouch %s\n' "$MARK" > "$MARK-gpg"
  chmod +x "$MARK-gpg"
  git -C "$c" config core.pager "touch $MARK; cat"
  mk destroy N=1
  assert_fails "destroy sees the stash"
  assert_contains "the stash" "stash(es)"
  assert_no_mark "gpg.program/pager"
}

test_transports_and_upload_pack_settings_dont_run() {
  setup_mark
  mk new
  local c="$TOOL/1/api"
  git -C "$c" config protocol.ext.allow always
  git -C "$c" config remote.evil.url "ext::sh -c touch% $MARK"
  git -C "$c" config uploadpack.packObjectsHook "touch $MARK; git"
  git -C "$c" config core.sshCommand "touch $MARK; ssh"
  commit_in "$c" "work"
  mk push N=1 REPO=api AS=feat/x YES=1
  assert_ok "push still works"
  mk fetch N=1
  mk destroy N=1 FORCE=1
  assert_no_mark "ext::, packObjectsHook, sshCommand"
}

test_symlinked_and_fifo_git_config_fail_closed() {
  mk new
  mk new
  local c1="$TOOL/1/api" c2="$TOOL/2/api"
  mv "$c1/.git/config" "$T/real-config"
  ln -s "$T/real-config" "$c1/.git/config"
  rm "$c2/.git/config"
  mkfifo "$c2/.git/config"
  mk destroy N=1
  assert_fails "symlinked config: destroy keeps it"
  assert_contains "says why" "isn't a regular file"
  mk destroy N=2
  assert_fails "FIFO config: destroy keeps it"
  assert_no_hang "destroy on a FIFO config"
  mk push N=2 REPO=api AS=feat/x YES=1
  assert_no_hang "push on a FIFO config"
  mk fetch N=2
  assert_no_hang "fetch on a FIFO config"
  mk new PUSH_AS=feat/y
  assert_ok "make new skips the sandbox it can't read"
  assert_contains "with a warning" "left out of the PUSH_AS check"
}

test_config_includes_fail_closed() {
  mk new
  local c="$TOOL/1/api"
  mkfifo "$T/inc.fifo"
  # Written by hand: git config itself would follow the include to add it.
  printf '[include]\n\tpath = %s\n' "$T/inc.fifo" >> "$c/.git/config"
  mk destroy N=1
  assert_fails "destroy keeps it"
  assert_contains "says why" "includes other files"
  assert_no_hang "destroy"
  mk push N=1 REPO=api AS=feat/x YES=1
  assert_contains "push says why" "includes other files"
  assert_no_hang "push"
  mk fetch N=1
  assert_no_hang "fetch"
  mk new PUSH_AS=feat/y
  assert_ok "make new"
  assert_no_hang "make new's PUSH_AS check"
  mk doctor
  assert_contains "doctor says why" "includes other files"
  assert_no_hang "doctor"
  printf '[INCLUDEIF "gitdir:/"]\n\tpath = /dev/tty\n' > "$T/cfg"
  cp "$c/.git/config" "$T/cfg.orig"
  { sed '/\[include\]/,$d' "$T/cfg.orig"; cat "$T/cfg"; } > "$c/.git/config"
  mk destroy N=1
  assert_contains "includeIf, any case" "includes other files"
}

test_fifo_head_is_stopped_by_the_time_limit() {
  mk new
  local c="$TOOL/1/api"
  rm "$c/.git/HEAD"
  mkfifo "$c/.git/HEAD"
  mk destroy N=1
  assert_fails "destroy keeps it"
  assert_contains "says why" "was stopped"
  assert_no_hang "destroy"
  mk push N=1 REPO=api AS=feat/x YES=1
  assert_no_hang "push"
  mk fetch N=1
  assert_no_hang "fetch"
}

test_readme_symlink_and_fifo_on_add() {
  add_repo_to_env web
  mk new
  echo "host secret" > "$T/host-file"
  rm "$TOOL/1/README.md"
  ln -s "$T/host-file" "$TOOL/1/README.md"
  mk add N=1 REPO=web
  assert_no_hang "add"
  assert_eq "the host file is untouched" "$(cat "$T/host-file")" "host secret"
  # shellcheck disable=SC2034  # read by assert_not_contains (tests/lib.sh)
  OUT="$(cat "$TOOL/1/web/README" 2>/dev/null; ls -A "$TOOL/1")"
  assert_not_contains "nothing copied from the host file" "host secret"
  rm -rf -- "$TOOL/1/web" "$TOOL/1/README.md"
  mkfifo "$TOOL/1/README.md"
  mk add N=1 REPO=web
  assert_no_hang "add with a FIFO README"
}

test_hostile_folder_names_are_quoted() {
  mk new
  local bad="x;touch PWNED"$'\e[31m'
  mv "$TOOL/1/api" "$TOOL/1/$bad"
  printf '#!/bin/sh\n' > "$TOOL/1/$bad/.git/hooks/pre-commit"
  mk doctor
  assert_not_contains "no raw escape sequence" $'\e[31m'
  assert_contains "the hint is shell-quoted" "git -C \$'$TOOL/1/x;touch PWNED\\E[31m'"
  mk list
  assert_not_contains "list prints it safely" $'\e[31m'
}

test_vscode_folder_with_extra_files_is_refused() {
  mk new
  mkdir -p "$TOOL/1/.vscode"
  echo '{}' > "$TOOL/1/.vscode/tasks.json"
  mk run N=1
  assert_fails "make run"
  assert_contains "says why" "tasks.json"
  rm -rf -- "$TOOL/1/.vscode"
  ln -s "$T" "$TOOL/1/.vscode"
  mk run N=1
  assert_fails "make run with a symlinked .vscode"
  assert_contains "says why" "isn't a folder"
}

# Make variables reach the scripts through the environment, never pasted
# into a recipe's shell command, so quotes, backticks and $( ) in a value
# stay text.
test_make_variables_are_not_shell_code() {
  mk new
  local marker="$T/pwned" payload v
  payload="1\"; touch '$marker'; \""
  # Control: pasted into a double-quoted shell string, the payload runs.
  sh -c "test -n \"$payload\"" 2>/dev/null || true
  assert_exists "control: the payload is live" "$marker"
  rm -f "$marker"
  for v in "$payload" "\$(touch '$marker')" "\`touch '$marker'\`"; do
    mk run N="$v"
    mk destroy N="$v"
    mk add N=1 REPO="$v"
    mk push N=1 REPO=api AS="$v"
    mk new WITH="$v" TITLE="$v" PUSH_AS="$v"
    mk run N=1 ARGS="$v"
  done
  assert_missing "no value ran as shell code" "$marker"
}

# make destroy and symlinks the agent plants: a "clone" that's a link to a
# repo elsewhere on the host, a submodule path through a link, and a link
# left as a "note". None may be looked into, removed through, or archived.
test_destroy_never_follows_symlinks() {
  mk new
  local host="$T/hostrepo"
  git init -q "$host"
  echo secret > "$host/key"
  echo "keep me" > "$HOME/target-file"
  ln -s "$host" "$TOOL/1/elsewhere"
  ln -s "$HOME/target-file" "$TOOL/1/notes.md"
  echo "a real note" > "$TOOL/1/PLAN-x.md"
  # Control: through the link, git sees the host repo's unsaved work.
  [[ -n "$(git -C "$TOOL/1/elsewhere" status --porcelain)" ]] \
    || _fail "control: the linked host repo should have an uncommitted file"
  mk destroy N=1
  assert_ok "make destroy"
  assert_contains "says it's a symlink" "'elsewhere' is a symlink"
  assert_not_contains "didn't inspect the host repo" "elsewhere has unsaved work"
  assert_exists "host repo kept" "$host/key"
  assert_exists "link target kept" "$HOME/target-file"
  assert_missing "link note not archived" "$TOOL/.archive/1/notes.md"
  assert_exists "real note archived" "$TOOL/.archive/1/PLAN-x.md"
  assert_missing "sandbox gone" "$TOOL/1"
}

test_destroy_doesnt_follow_a_symlinked_submodule_path() {
  mk new
  local host="$T/hostrepo" clone="$TOOL/1/api" sha
  git init -q "$host"
  commit_in "$host" "host commit"
  echo dirty > "$host/dirty"
  sha="$(git -C "$host" rev-parse HEAD)"
  git -C "$clone" update-index --add --cacheinfo "160000,$sha,sub"
  ln -s "$host" "$clone/sub"
  mk destroy N=1
  assert_fails "make destroy refuses an unchecked submodule"
  assert_contains "says why" "couldn't check submodule sub: a symlink"
  assert_not_contains "didn't look in the host repo" "submodule sub: 1 uncommitted"
  assert_exists "host repo kept" "$host/dirty"
}

# bsd_mv  -- an mv first on PATH that, like macOS's, isn't GNU (no
# --version, no -T); otherwise the real mv, whose `mv src dest` onto a
# symlink to a folder moves into it the same way BSD mv does.
bsd_mv() {
  local real
  real="$(command -v mv)"
  # shellcheck disable=SC2016  # $a and $@ belong to the generated script
  printf '#!/bin/sh\nfor a; do case "$a" in --version|-T) exit 1 ;; esac; done\nexec %s "$@"\n' "$real" > "$T/bin/mv"
  chmod +x "$T/bin/mv"
}

test_move_into_sandbox_never_follows_a_planted_symlink_without_gnu_mv() {
  bsd_mv
  mk new
  local host="$T/hostdir" f
  mkdir -p "$host" "$TOOL/.staging.t"
  for f in README.md .fetch-api.bundle; do
    echo "from staging" > "$TOOL/.staging.t/$f"
    rm -f -- "$TOOL/1/$f"
    ln -s "$host" "$TOOL/1/$f"
    # shellcheck disable=SC2016  # $1 and $2 expand in the inner bash
    in_tool bash -c 'source scripts/lib/all.sh; move_into_sandbox "$1" "$2"' _ "$TOOL/.staging.t/$f" "$TOOL/1"
    assert_ok "$f: moved"
    assert_missing "$f: nothing landed in the host folder" "$host/$f"
    assert_eq "$f: the symlink was replaced by the file" "$(cat "$TOOL/1/$f")" "from staging"
  done
  # A folder: .vscode replaced through a symlink, as make run writes it.
  rm -rf -- "$TOOL/1/.vscode"
  ln -s "$host" "$TOOL/1/.vscode"
  # shellcheck disable=SC2016  # $1 and $2 expand in the inner bash
  in_tool bash -c 'source scripts/lib/all.sh; ensure_vscode_dir "$1"' _ "$TOOL/1"
  assert_ok ".vscode: written"
  assert_missing ".vscode: nothing landed in the host folder" "$host/settings.json"
  [[ -d "$TOOL/1/.vscode" && ! -L "$TOOL/1/.vscode" && -f "$TOOL/1/.vscode/settings.json" ]] \
    || _fail ".vscode: a real folder holding settings.json"
  # Control: a plain mv onto the symlinked name (the old fallback) does
  # land in the host folder.
  echo "from staging" > "$TOOL/.staging.t/README.md"
  rm -f -- "$TOOL/1/README.md"
  ln -s "$host" "$TOOL/1/README.md"
  mv -- "$TOOL/.staging.t/README.md" "$TOOL/1/README.md"
  assert_exists "control: plain mv follows the symlink" "$host/README.md"
}
