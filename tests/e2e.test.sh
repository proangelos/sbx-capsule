# End to end: the main make targets in a scratch copy, with the fake sbx.

test_new_writes_the_sandbox_files() {
  mk new
  assert_ok "make new"
  assert_exists "the clone" "$TOOL/1/api/.git"
  local f
  for f in README.md AGENTS.md CLAUDE.md GEMINI.md; do
    assert_exists "generated $f" "$TOOL/1/$f"
  done
  assert_exists "the PUSH_AS record, outside the sandbox" "$TOOL/.state/1/push_as"
  assert_missing "no .sandbox.env (pre-1.0)" "$TOOL/1/.sandbox.env"
  assert_eq "the clone is on its sandbox branch" \
    "$(git -C "$TOOL/1/api" symbolic-ref --short HEAD)" "sandbox/1/api"
  assert_eq "no object files shared with the checkout" \
    "$(find "$TOOL/1/api/.git/objects" -type f -links +1 | head -1)" ""
}

test_agents_md_has_user_instructions_first_and_no_commit_rule() {
  cat >> "$TOOL/.env" <<'EOF'
AGENT_INSTRUCTIONS=(
  "Don't commit until I say so."
  'Keep `$HOME` and $(date) as written
across lines.'
)
EOF
  mk new
  assert_ok "make new"
  OUT="$(cat "$TOOL/1/AGENTS.md")"
  assert_contains "the section" "## User instructions"
  assert_contains "the first entry" "- Don't commit until I say so."
  # shellcheck disable=SC2016  # the literal text is the point
  assert_contains "text kept literally" '- Keep `$HOME` and $(date) as written'
  assert_contains "later lines stay in the bullet" $'\n  across lines.'
  assert_eq "before the tool's rules" \
    "$(grep -n -e '^## User instructions' -e "^## Where you're running" "$TOOL/1/AGENTS.md" | cut -d: -f2 | head -1)" \
    "## User instructions"
  assert_not_contains "no commit rule from the tool" "Git: commit"
  assert_contains "the push rule stays" "Git: never push."
}

test_agents_md_without_user_instructions() {
  echo 'AGENT_GIT_PUSH=yes' >> "$TOOL/.env"
  mk new
  assert_ok "make new"
  OUT="$(cat "$TOOL/1/AGENTS.md")"
  assert_not_contains "no empty section" "User instructions"
  assert_not_contains "no commit rule from the tool" "Git: commit"
  assert_contains "the push rule" "Git: you may push your branch."
}

test_new_with_title_and_empty() {
  mk new TITLE=login EMPTY=1
  assert_ok "make new EMPTY=1 TITLE=login"
  assert_exists "titled folder" "$TOOL/1-login/README.md"
  assert_missing "no clone in an empty sandbox" "$TOOL/1-login/api"
}

test_add_records_the_repo() {
  add_repo_to_env web
  mk new
  mk add N=1 REPO=web
  assert_ok "make add"
  assert_exists "the added clone" "$TOOL/1/web/.git"
  OUT="$(cat "$TOOL/1/README.md")"
  assert_contains "README records it" "web"
  assert_contains "under its heading" "Repos added after creation"
}

test_fetch_leaves_a_bundle() {
  mk new
  commit_in "$SRC/api" "upstream work"
  git -C "$SRC/api" push -q origin main
  mk fetch N=1
  assert_ok "make fetch"
  assert_exists "the bundle" "$TOOL/1/.fetch-api.bundle"
  git -C "$TOOL/1/api" fetch -q ../.fetch-api.bundle '+refs/remotes/origin/*:refs/remotes/origin/*'
  assert_eq "the bundle applies in the clone" \
    "$(git -C "$TOOL/1/api" rev-parse origin/main)" "$(git -C "$SRC/api" rev-parse main)"
}

test_push_sends_the_branch() {
  mk new PUSH_AS=feat/x
  commit_in "$TOOL/1/api" "agent work"
  mk push N=1 REPO=api YES=1
  assert_ok "make push"
  assert_eq "origin has the agent's commit" \
    "$(git -C "$SRC/api.git" rev-parse feat/x)" "$(git -C "$TOOL/1/api" rev-parse HEAD)"
  assert_exists "the push is recorded outside the sandbox" "$TOOL/.state/1/pushed"
  mk destroy N=1
  assert_ok "pushed work counts as saved on destroy"
}

test_destroy_leaves_only_the_archive() {
  mk new
  echo "my notes" > "$TOOL/1/notes.md"
  local vm
  vm="$(vm_name "$TOOL/1")"
  fake_vm "$vm" running claude "$TOOL/1" "$TOOL/1/.vscode:ro"
  mk destroy N=1
  assert_ok "make destroy"
  assert_missing "sandbox folder gone" "$TOOL/1"
  assert_missing "state gone" "$TOOL/.state/1"
  assert_exists "notes archived" "$TOOL/.archive/1/notes.md"
  OUT="$(cat "$FAKE_SBX_DIR/vms")"
  assert_not_contains "its VM removed" "$vm"
  OUT="$(ls -A "$TOOL/.archive/1")"
  assert_eq "only the note is archived" "$OUT" "notes.md"
}

test_list_shows_sandboxes_and_leftovers() {
  mk new
  local vm1 vm7
  vm1="$(vm_name "$TOOL/1")" vm7="$(vm_name "$TOOL/7")"
  fake_vm "$vm1" running claude "$TOOL/1"
  fake_vm "$vm7" stopped claude "$TOOL/7"
  fake_vm "someone-elses" running claude "/elsewhere/1"
  mk list
  assert_ok "make list"
  assert_contains "sandbox 1's VM" "running (claude)"
  assert_contains "the leftover VM" "$vm7"
  assert_not_contains "never other VMs" "someone-elses"
}

test_run_creates_the_vm_with_a_readonly_vscode() {
  mk new
  mk run N=1
  assert_ok "make run"
  OUT="$(cat "$FAKE_SBX_DIR/calls")"
  assert_contains "sbx run with both mounts" "$TOOL/1 $TOOL/1/.vscode:ro"
  OUT="$(cat "$T/out")"
  assert_contains "warns that there's no terminal" "context deadline exceeded"
  assert_exists "the VS Code settings" "$TOOL/1/.vscode/settings.json"
  mk run N=1
  assert_ok "make run again reattaches"
  assert_contains "reattaching" "Reattaching to"
  assert_contains "warns on reattach too" "context deadline exceeded"
}

test_stop_and_prune() {
  mk new
  local vm1 vm5
  vm1="$(vm_name "$TOOL/1")" vm5="$(vm_name "$TOOL/5")"
  fake_vm "$vm1" running claude "$TOOL/1"
  fake_vm "$vm5" running claude "$TOOL/5"
  mk stop N=1
  assert_ok "make stop"
  OUT="$(cat "$FAKE_SBX_DIR/vms")"
  assert_contains "stopped" "$vm1"$'\t'stopped
  mk prune YES=1
  assert_ok "make prune"
  OUT="$(cat "$FAKE_SBX_DIR/vms")"
  assert_not_contains "the leftover is gone" "$vm5"
  assert_contains "sandbox 1's VM stays" "$vm1"
}

test_new_skips_a_number_with_a_leftover_vm() {
  fake_vm "$(vm_name "$TOOL/1")" stopped claude "$TOOL/1"
  mk new
  assert_ok "make new"
  assert_contains "says why" "skipping sandbox number 1"
  assert_exists "uses the next number" "$TOOL/2/api"
}

test_doctor_checks_pass() {
  mk new
  echo 'AGENT_INSTRUCTIONS=("one" "two")' >> "$TOOL/.env"
  mk doctor
  # The scratch copy can fail checks that depend on where it lives (under
  # /tmp/claude-*, say) or on VS Code, so look at the ones the tool owns.
  assert_contains "repos" "api: $SRC/api, starts from origin/main"
  assert_contains "host safety" "no sbx VM can write this checkout"
  assert_contains "clones" "1 clone(s): nothing in their git config or hooks"
  assert_not_contains "nothing about sbx failing" "couldn't ask sbx"
  assert_contains "the instructions" "agent instructions: 2"
}

test_doctor_flags_a_config_others_can_write() {
  chmod o+w "$TOOL/.env"
  mk doctor
  assert_contains "world-writable .env" ".env can be written by other users"
  chmod o-w,g+w "$TOOL/.env"
  mk doctor
  local me members
  me="$(id -un)"
  members="$(getent group "$me" 2>/dev/null)" || members="none:"
  members="${members##*:}"
  if [[ "$(id -gn)" == "$me" ]] && command -v getent >/dev/null 2>&1 \
     && [[ -z "$members" || "$members" == "$me" ]]; then
    assert_not_contains "group-write by your private group is fine" ".env can be written by other users"
  else
    assert_contains "group-write by a shared group" ".env can be written by other users"
  fi
}

# A git from a release series that never got the upstream CVE fixes gets a
# one-line warning from the commands that run git on a sandbox's clones
# (and a note in make doctor); a current one gets none.
test_old_git_is_warned_about() {
  mk new
  mk destroy N=1
  assert_not_contains "no warning with this git" "no upstream fix for"
  mk new
  local real
  real="$(command -v git)"
  # shellcheck disable=SC2016  # $1 and $@ belong to the generated script
  printf '#!/bin/sh\n[ "$1" = --version ] && { echo "git version 2.29.2"; exit 0; }\nexec "%s" "$@"\n' "$real" > "$T/bin/git"
  chmod +x "$T/bin/git"
  mk destroy N=1
  assert_ok "make destroy still runs"
  assert_contains "warns" "git 2.29.2 is from a release series with no upstream fix for CVE-2022-23521 and CVE-2024-32465"
  mk doctor
  assert_contains "doctor notes it" "predates the upstream fix for CVE-2024-32465"
}
