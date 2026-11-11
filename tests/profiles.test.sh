# Agent profiles (user-config/agents/<name>.env), AGENT= on the command
# line, each sandbox's saved agent, and the paths kit flags take
# (scripts/lib/profiles.sh), with the fake sbx.

# profile <name> <content>  -- writes user-config/agents/<name>.env.
profile() {
  mkdir -p "$TOOL/user-config/agents"
  printf '%s\n' "$2" > "$TOOL/user-config/agents/$1.env"
}

# last_run  -- the last `sbx run` the fake sbx was given, in OUT.
# shellcheck disable=SC2034  # OUT is read by the assert_* helpers (tests/lib.sh)
last_run() { OUT="$(grep '^run ' "$FAKE_SBX_DIR/calls" | tail -1)"; }

test_profile_runs_its_agent_args_and_kit() {
  mkdir -p "$TOOL/user-config/kits/k"
  : > "$TOOL/user-config/k.args"
  profile pi 'AGENT="dhi.io/pi:latest"
ARGS="--model m"
CREATE_FLAGS="--kit user-config/kits/k --kit-args-file=user-config/k.args"
CREDENTIALS="anthropic"'
  echo 'SBX_CREATE_FLAGS="--cpus 2"' >> "$TOOL/.env"
  mk new AGENT=pi
  assert_ok "make new AGENT=pi"
  assert_contains "says it's the sandbox's own" "saved for this sandbox"
  assert_eq "saved outside the sandbox" "$(cat "$TOOL/.state/1/agent")" "pi"
  mk run N=1
  assert_ok "make run"
  assert_contains "names the profile" "pi (profile: dhi.io/pi:latest)"
  assert_contains "reminds about its sbx secrets" "uses these sbx secrets: anthropic"
  last_run
  assert_contains ".env's flags, then the profile's, paths from the tool's folder" \
    "--cpus 2 --kit $TOOL/user-config/kits/k --kit-args-file=$TOOL/user-config/k.args dhi.io/pi:latest $TOOL/1 $TOOL/1/.vscode:ro -- --model m"
  assert_exists "the profile's checksum" "$TOOL/.state/1/agent_sum"
  mk run N=1 ARGS="--extra"
  assert_ok "reattach"
  last_run
  assert_contains "the profile's ARGS on reattach too, then ARGS" "-- --model m --extra"
  assert_not_contains "no kit flags on reattach" "--kit"
}

test_saved_agent_outlasts_env_changes() {
  mk new AGENT=codex
  mk new
  echo 'AGENT="gemini"' >> "$TOOL/.env"
  mk run N=1
  assert_ok "make run N=1"
  last_run
  assert_contains "sandbox 1 keeps its own agent" " codex $TOOL/1 "
  mk run N=2
  last_run
  assert_contains "sandbox 2 follows .env" " gemini $TOOL/2 "
  mk list
  assert_contains "make list shows the saved agent" "codex"
}

test_env_agent_can_name_a_profile() {
  profile mine 'AGENT="codex"
ARGS="--fast"'
  echo 'AGENT="mine"' >> "$TOOL/.env"
  mk new
  mk run N=1
  assert_ok "make run"
  last_run
  assert_contains "the profile's agent and args" " codex $TOOL/1 $TOOL/1/.vscode:ro -- --fast"
  assert_missing "nothing saved: it follows .env" "$TOOL/.state/1/agent"
  mk doctor
  assert_contains "doctor names it" "agent: mine (profile: codex) (args: --fast)"
  assert_contains "and checks the profile" "profile mine: codex"
}

test_switching_agent_needs_fresh() {
  mk new
  mk run N=1
  mk run N=1 AGENT=codex
  assert_fails "a different agent on an existing VM"
  assert_contains "says how" "make run N=1 AGENT=codex FRESH=1"
  assert_missing "nothing saved" "$TOOL/.state/1/agent"
  mk run N=1 AGENT=codex FRESH=1
  assert_ok "with FRESH=1"
  last_run
  assert_contains "the new VM runs it" " codex $TOOL/1 "
  assert_eq "and it's saved" "$(cat "$TOOL/.state/1/agent")" "codex"
  mk run N=1 AGENT=codex
  assert_ok "naming the agent it already runs is fine"
}

test_shell_environment_agent_is_ignored() {
  mk new
  export AGENT=codex
  mk run N=1
  unset AGENT
  assert_ok "make run"
  last_run
  assert_contains "only a command-line AGENT counts" " claude $TOOL/1 "
  assert_missing "nothing saved" "$TOOL/.state/1/agent"
}

test_profile_change_is_noted_on_reattach() {
  profile p 'AGENT="codex"'
  mk new AGENT=p
  mk run N=1
  mk run N=1
  assert_not_contains "unchanged: no note" "changed since"
  profile p 'AGENT="codex"
ARGS="--new"'
  mk run N=1
  assert_contains "notes the change" "changed since"
  last_run
  assert_contains "the new ARGS apply" "-- --new"
}

test_bad_profiles_list_every_problem() {
  local before
  # shellcheck disable=SC2016  # literal profile text
  profile bad 'AGENT="claude"
FOO=1
ARGS=(--a --b)
CREATE_FLAGS="--cpus 2 -e TOKEN=x --name y --mount /a:/b"
CREDENTIALS="anthropic ANTHROPIC_API_KEY=sk-123"'
  profile loop 'AGENT="bad"'
  profile nokit 'AGENT="./user-config/kits/missing"'
  before="$(tree_state)"
  mk new AGENT=bad
  assert_fails "make new AGENT=bad"
  assert_contains "an unknown variable" "sets FOO"
  assert_contains "an array" "makes ARGS an array"
  assert_contains "-e" "can't pass environment variables (-e)"
  assert_contains "a reserved flag" "'--name' is managed by this tool"
  assert_contains "--mount" "--mount binds a host folder"
  assert_contains "a key in CREDENTIALS" "'ANTHROPIC_API_KEY=sk-123' isn't an sbx secret name"
  assert_contains "nothing changed" "Nothing was created or changed"
  assert_eq "tree unchanged" "$(tree_state)" "$before"
  mk new AGENT=loop
  assert_fails "a profile naming a profile"
  assert_contains "says so" "can't name another profile"
  mk new AGENT=nokit
  assert_fails "a missing local kit"
  assert_contains "says so" "doesn't exist (relative paths are taken from $TOOL)"
  mk new AGENT=nosuch
  assert_fails "an unknown name"
  assert_contains "lists the profiles" "isn't a profile (bad loop nokit in"
  assert_eq "still unchanged" "$(tree_state)" "$before"
}

# Anything a VM can write mustn't decide what the next VM is created with:
# kits, args files and profiles in a sandbox folder are refused, through
# symlinks too, and a profile there is never run.
test_paths_inside_a_sandbox_are_refused() {
  mk new
  mkdir -p "$TOOL/1/kit" "$TOOL/user-config/kits" "$TOOL/user-config/agents"
  : > "$TOOL/1/k.args"
  echo 'SBX_CREATE_FLAGS="--kit 1/kit --kit-args-file /dev/null"' >> "$TOOL/.env"
  mk run N=1
  assert_fails "a kit in the sandbox"
  assert_contains "says why" "SBX_CREATE_FLAGS: --kit: 1/kit is inside a sandbox folder"
  assert_contains "the args file isn't a file" "/dev/null isn't a file"
  echo 'SBX_CREATE_FLAGS=""' >> "$TOOL/.env"
  ln -s "$TOOL/1/kit" "$TOOL/user-config/kits/link"
  ln -s "$TOOL/1/k.args" "$TOOL/user-config/k.args"
  profile linked 'CREATE_FLAGS="--kit user-config/kits/link --kit-args-file user-config/k.args"
AGENT=claude'
  mk run N=1 AGENT=linked
  assert_fails "through symlinks"
  assert_contains "the kit" "user-config/kits/link is inside a sandbox folder"
  assert_contains "the args file" "user-config/k.args is inside a sandbox folder"
  local marker="$T/pwned"
  printf 'AGENT=claude\ntouch %q\n' "$marker" > "$TOOL/1/evil.env"
  # Control: run as bash, the planted profile is live.
  bash "$TOOL/1/evil.env"
  assert_exists "control: the payload is live" "$marker"
  rm -f "$marker"
  ln -s "$TOOL/1/evil.env" "$TOOL/user-config/agents/evil.env"
  mk run N=1 AGENT=evil
  assert_fails "a profile in the sandbox"
  assert_contains "says why" "profile evil ($TOOL/user-config/agents/evil.env) is inside a sandbox folder"
  mk doctor
  assert_missing "never run, by make run or make doctor" "$marker"
}

test_init_copies_the_user_config_example() {
  mk init
  assert_exists "the example profile" "$TOOL/user-config/agents/pi.env.example"
  assert_exists "the example kit" "$TOOL/user-config/kits/pi-local-models/pi-local-models.yaml"
  echo "mine" > "$TOOL/user-config/mine"
  mk init
  assert_eq "leaves an existing one alone" "$(cat "$TOOL/user-config/mine")" "mine"
  assert_not_contains "says nothing about creating it" "Created $TOOL/user-config"
  assert_missing "no copy inside it" "$TOOL/user-config/user-config.example"
}
