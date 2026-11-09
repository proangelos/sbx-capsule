# Failure paths: each must exit non-zero, list every problem at once, and
# change nothing.

test_bad_env_lists_every_problem() {
  local before
  before="$(tree_state)"
  cat >> "$TOOL/.env" <<'EOF'
AGENT_GIT_PUSH=maybe
SBX_CREATE_FLAGS="--name x"
EOF
  mk new
  assert_fails "make new with a bad .env"
  assert_contains "AGENT_GIT_PUSH" "AGENT_GIT_PUSH='maybe'"
  assert_contains "reserved flag" "--name"
  assert_contains "nothing changed" "Nothing was created or changed"
  assert_eq "tree unchanged" "$(tree_state)" "$before"
}

test_sbx_create_flags_must_be_flags() {
  local before
  before="$(tree_state)"
  echo 'SBX_CREATE_FLAGS="--cpus 4 /srv/someone --mount /a:/b --skills=readwrite"' >> "$TOOL/.env"
  mk new
  assert_fails "make new"
  assert_contains "a bare word" "'/srv/someone' isn't a flag"
  assert_contains "--mount" "--mount binds a host folder"
  assert_contains "--skills readwrite" "--skills readwrite lets the agent"
  assert_eq "tree unchanged" "$(tree_state)" "$before"
  # Control: flags with values, in both spellings, pass.
  echo 'SBX_CREATE_FLAGS="--cpus 4 -m 8g --skills readonly -e FOO=1 --kit=./k"' >> "$TOOL/.env"
  mk new
  assert_ok "make new with only flags"
}

test_unknown_repo_and_missing_branch_together() {
  local before
  before="$(tree_state)"
  mk new WITH="nope api:no-such-branch"
  assert_fails "make new"
  assert_contains "unknown repo" "unknown repo 'nope'"
  assert_contains "missing branch" "no-such-branch"
  assert_eq "tree unchanged" "$(tree_state)" "$before"
}

test_destroy_keeps_unsaved_work() {
  mk new
  commit_in "$TOOL/1/api" "unpushed"
  echo change > "$TOOL/1/api/new-file"
  git -C "$TOOL/1/api" stash -q -u
  echo change2 > "$TOOL/1/api/other"
  local before
  before="$(tree_state)"
  mk destroy N=1
  assert_fails "make destroy with unsaved work"
  assert_contains "the commit" "1 commit(s) not on origin"
  assert_contains "the stash" "1 stash(es)"
  assert_contains "the change" "uncommitted change(s)"
  assert_contains "how to force" "FORCE=1"
  assert_eq "tree unchanged" "$(tree_state)" "$before"
  mk destroy N=1 FORCE=1
  assert_ok "FORCE=1 removes it"
  assert_missing "gone" "$TOOL/1"
}

test_push_needs_a_target() {
  mk new
  commit_in "$TOOL/1/api" "work"
  mk push N=1 REPO=api YES=1
  assert_fails "make push without PUSH_AS or AS"
  assert_contains "says what to do" "AS=<branch>"
}

test_push_as_must_not_be_the_source_branch() {
  mk new PUSH_AS=main
  assert_fails "make new PUSH_AS=main"
  assert_contains "says why" "source branch"
  assert_missing "nothing made" "$TOOL/1"
}

test_push_as_used_by_another_sandbox() {
  mk new PUSH_AS=feat/a
  mk new PUSH_AS=feat/a
  assert_fails "a second sandbox with the same PUSH_AS"
  assert_contains "names the other" "already used for api by sandbox 1"
  assert_missing "nothing made" "$TOOL/2"
}

test_unknown_sandbox_number() {
  mk destroy N=9
  assert_fails "make destroy of a sandbox that isn't there"
  assert_contains "says so" "no sandbox numbered 9"
}
