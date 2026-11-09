# The host safety checks that read sbx's VMs, through the fake sbx: failing
# closed when sbx doesn't answer, and the mounts a VM mustn't have.

sbx_down() { touch "$FAKE_SBX_DIR/fail"; }

test_sbx_not_answering_fails_closed() {
  mk new
  sbx_down
  local before
  before="$(tree_state)"
  mk new
  assert_fails "make new"
  assert_contains "make new says why" "couldn't ask sbx which VMs exist"
  assert_eq "make new changed nothing" "$(tree_state)" "$before"
  mk run N=1
  assert_fails "make run"
  assert_contains "make run says why" "couldn't ask sbx which VMs exist"
  mk code N=1
  assert_fails "make code"
  mk destroy N=1
  assert_fails "make destroy"
  assert_exists "destroy removed nothing" "$TOOL/1/api"
  mk stop N=1
  assert_fails "make stop"
  mk prune YES=1
  assert_fails "make prune"
  mk doctor
  assert_fails "make doctor"
  assert_contains "doctor says why" "couldn't ask sbx which VMs exist"
  mk list
  assert_ok "make list still lists"
  assert_contains "with a warning" "couldn't ask sbx about VMs"
}

test_vm_writing_the_checkout_is_refused() {
  mk new
  fake_vm handmade running shell "$TOOL"
  mk run N=1
  assert_fails "make run"
  assert_contains "says why" "which holds this tool's checkout"
}

test_vm_writing_a_folder_inside_the_checkout_is_refused() {
  mk new
  fake_vm hand1 running shell "$TOOL/scripts"
  fake_vm hand2 running shell "$TOOL/.state"
  fake_vm hand3 running shell "$TOOL/1/.vscode"
  mk run N=1
  assert_fails "make run"
  assert_contains "scripts/" "hand1 can write $TOOL/scripts, inside this tool's checkout"
  assert_contains ".state/" "hand2 can write $TOOL/.state"
  assert_contains "a writable .vscode" "hand3 can write $TOOL/1/.vscode"
  mk doctor
  assert_contains "doctor reports it" "inside this tool's checkout but not a sandbox folder"
}

test_sandbox_vm_mounts_are_allowed() {
  mk new
  mk new
  fake_vm "$(vm_name "$TOOL/2")" running claude "$TOOL/2" "$TOOL/2/.vscode:ro"
  fake_vm readonly running shell "$TOOL/scripts:ro"
  mk run N=1
  assert_ok "make run alongside another sandbox's VM and a read-only mount"
}

test_vm_writing_a_source_checkout_is_refused() {
  mk new
  fake_vm hand running shell "$SRC/api"
  mk run N=1
  assert_fails "make run"
  assert_contains "says why" "can write api's source checkout"
}

test_agent_forwarding_is_refused() {
  mk new
  echo true > "$FAKE_SBX_DIR/agentfwd"
  mk run N=1
  assert_fails "make run with agent forwarding and AGENT_GIT_PUSH=no"
  assert_contains "says why" "ssh.agentForwardingEnabled=true"
  echo 'AGENT_GIT_PUSH=yes' >> "$TOOL/.env"
  mk run N=1
  assert_ok "allowed with AGENT_GIT_PUSH=yes"
}

test_destroy_refuses_while_another_vm_can_write_it() {
  mk new
  fake_vm other running shell "$TOOL/1"
  mk destroy N=1 FORCE=1
  assert_fails "make destroy"
  assert_exists "nothing removed" "$TOOL/1/api"
}

test_code_refuses_a_vm_without_the_readonly_mount() {
  mk new
  fake_vm "$(vm_name "$TOOL/1")" running claude "$TOOL/1"
  mk code N=1
  assert_fails "make code"
  assert_contains "says why" "doesn't mount the sandbox's .vscode read-only"
}

# sbx v0.51.0: a workspace can have its own path in the VM (PATH:TARGET),
# and binds are listed in "mounts" as HOST:TARGET. Either can write the host
# folder; both readers of `sbx ls --json` (jq and the awk fallback) must see
# it.
test_vm_writing_the_checkout_at_another_path_is_refused() {
  mk new
  fake_vm hand1 running shell "/elsewhere" "$TOOL:/work"
  fake_vm hand2 running shell "mount=$SRC/api:/src"
  mk run N=1
  assert_fails "make run"
  assert_contains "a PATH:TARGET workspace" "hand1 can write $TOOL, which holds this tool's checkout"
  assert_contains "a bind in mounts" "hand2 can write api's source checkout"
  hide_jq
  mk run N=1
  assert_fails "make run without jq"
  assert_contains "a PATH:TARGET workspace, without jq" "hand1 can write $TOOL, which holds"
  assert_contains "a bind in mounts, without jq" "hand2 can write api's source checkout"
}

test_readonly_mounts_at_another_path_are_allowed() {
  mk new
  local vm
  vm="$(vm_name "$TOOL/1")"
  fake_vm "$vm" running claude "$TOOL/1" "$TOOL/1/.vscode:ro" "mount=$TOOL/1:$TOOL/1" "mount=$TOOL/1/.vscode:$TOOL/1/.vscode:ro"
  fake_vm readonly running shell "/x" "$TOOL/scripts:/tool:ro" "mount=$SRC/api:/src:ro"
  mk run N=1
  assert_ok "make run with read-only mounts at other paths"
  assert_contains "found the sandbox's own VM" "Reattaching to"
  hide_jq
  mk run N=1
  assert_ok "make run without jq"
  assert_contains "found the sandbox's own VM without jq" "Reattaching to"
}

test_code_refuses_a_readonly_vscode_mounted_elsewhere() {
  mk new
  fake_vm "$(vm_name "$TOOL/1")" running claude "$TOOL/1" "$TOOL/1/.vscode:/other:ro"
  mk code N=1
  assert_fails "make code"
  assert_contains "says why" "doesn't mount the sandbox's .vscode read-only"
}

test_garbled_sbx_answer_fails_closed_without_jq() {
  mk new
  touch "$FAKE_SBX_DIR/garbled"
  hide_jq
  mk run N=1
  assert_fails "make run"
  assert_contains "says why" "couldn't ask sbx which VMs exist"
  # Control: once sbx answers properly, the same command passes.
  rm "$FAKE_SBX_DIR/garbled"
  mk run N=1
  assert_ok "make run once sbx answers"
}

test_writable_skills_store_is_refused() {
  mk new
  mkdir -p "$FAKE_SBX_DIR/settings"
  echo readwrite > "$FAKE_SBX_DIR/settings/skills.defaultMode"
  mk run N=1
  assert_fails "make run with skills.defaultMode=readwrite"
  assert_contains "says why" "skills.defaultMode=readwrite"
  mk doctor
  assert_contains "doctor reports it" "skills.defaultMode=readwrite"
  echo 'SBX_CREATE_FLAGS="--skills readonly"' >> "$TOOL/.env"
  mk run N=1
  assert_ok "make run once SBX_CREATE_FLAGS overrides it"
}

test_doctor_notes_clipboard_copy() {
  mkdir -p "$FAKE_SBX_DIR/settings"
  mk doctor
  assert_not_contains "no note by default" "clipboard.textCopy"
  echo true > "$FAKE_SBX_DIR/settings/clipboard.textCopy"
  mk doctor
  assert_contains "notes it" "clipboard.textCopy"
}
