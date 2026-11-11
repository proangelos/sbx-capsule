# shellcheck disable=SC2034  # globals set here are read by the files that source this one
# Docker Sandboxes (sbx) and agent helpers: VM naming and lookup, the
# built-in agents, flags the tool manages, and the agent instruction shims.
# Sourced via all.sh, not executed: no shebang, no `set -e`.

# sbx_name <sandbox_dir>  -- the Docker Sandbox (`sbx`) VM name a new VM for
# a sandbox gets: "[<SBX_NAME_PREFIX>-]<checkout id>-<sandbox dir>",
# lowercased (SBX_PREFIX), so two checkouts of this tool never share a VM,
# whatever their folders are called and whatever prefix each sets. sbx
# rejects underscores. A VM made under an earlier prefix keeps its name
# (is_tool_vm_name still knows it).
sbx_name() {
  echo "$SBX_PREFIX$(_sbx_part "$(basename "$1")")"
}

# is_tool_vm_name <name> <sandbox_dir>  -- true if <name> is one this
# checkout gives the sandbox's VM, under any SBX_NAME_PREFIX:
# "<checkout id>-<sandbox dir>", with or without "<prefix>-" in front. So
# changing the prefix orphans no VM. The name alone proves nothing (anyone
# can name a VM anything): callers also require the VM to mount the sandbox
# folder, and that is what keeps checkouts apart, since another checkout's
# VMs mount its own folders.
is_tool_vm_name() {
  local tail
  tail="$SBX_CHECKOUT_ID-$(_sbx_part "$(basename "$2")")"
  [[ "$1" == "$tail" || "$1" == *"-$tail" ]]
}

# _sbx_part <text>  -- lowercased, anything but a letter, digit or '-'
# turned into '-'.
_sbx_part() {
  local s="${1,,}"
  echo "${s//[^a-z0-9-]/-}"
}

# SBX_CHECKOUT_ID  -- six hex digits of a checksum of the checkout's
# physical path (cksum: POSIX, so the same on macOS), in every VM name from
# this checkout. It needs nothing stored, and a copy of the checkout
# elsewhere gets its own. Moving a checkout changes it, but that orphans its
# VMs anyway: they mount the old paths.
_sbx_checkout_id() {
  local path crc
  path="$(cd "$SANDBOX_ROOT" 2>/dev/null && pwd -P)" || path="$SANDBOX_ROOT"
  crc="$(printf '%s' "$path" | cksum)"
  printf '%06x\n' $(( ${crc%% *} & 0xffffff ))
}
SBX_CHECKOUT_ID="$(_sbx_checkout_id)"

# SBX_PREFIX  -- the start of every sbx_name from this checkout:
# "<checkout id>-", after "<SBX_NAME_PREFIX>-" if .env sets one.
# check_agent_config refuses a prefix sbx wouldn't accept.
SBX_PREFIX="${SBX_NAME_PREFIX:+$SBX_NAME_PREFIX-}$SBX_CHECKOUT_ID-"

# sbx refuses a VM name longer than this (sbx v0.50.1).
SBX_NAME_MAX=63

have_sbx()   { command -v sbx >/dev/null 2>&1; }
sbx_exists() { have_sbx && sbx ls -q 2>/dev/null | grep -qxF "$1"; }

# sbx_vms  -- every sbx VM, one line per folder or file it mounts: name,
# status, agent, host path, mode (rw or ro) and the path it has inside the
# VM, tab-separated. Read from
# `sbx ls --json`, with jq when it's installed, else awk on the
# pretty-printed form (one field per line, fields 4 spaces in, checked
# against sbx v0.50.1 and v0.51.0). Both its `workspaces` and its `mounts`
# (sbx v0.51.0, every bind as HOST:TARGET[:ro]) are read, and each entry is
# turned into host paths by _mount_hosts. Prints nothing if sbx isn't
# installed; fails, printing nothing, if it doesn't answer (or answers with
# JSON that can't be read).
sbx_vms() {
  local json raw name status agent entry host mode target
  have_sbx || return 0
  json="$(sbx ls --json 2>/dev/null)" || return 1
  if command -v jq >/dev/null 2>&1; then
    raw="$(jq -r '.[]? | .name as $n | (.status // "") as $s | (.agent // "") as $a
           | ((.workspaces // [])[], (.mounts // [])[]) | [$n, $s, $a, .] | @tsv' <<< "$json" 2>/dev/null)" || return 1
  else
    # Anything but a JSON array is an answer this can't read: fail, rather
    # than report no VMs.
    [[ "$json" =~ ^[[:space:]]*\[ ]] || return 1
    raw="$(awk '
      function val(line) {
        sub(/^[^:]*: *"/, "", line); sub(/",? *$/, "", line)
        gsub(/\\"/, "\"", line); return line
      }
      /^  \{/                 { name = status = agent = ""; n = 0 }
      /^    "name": /         { name = val($0) }
      /^    "status": /       { status = val($0) }
      /^    "agent": /        { agent = val($0) }
      /^    "(workspaces|mounts)": \[/ { inws = 1; next }
      inws && /^    \]/       { inws = 0; next }
      inws                    { w = $0; sub(/^ *"/, "", w); sub(/",? *$/, "", w); ws[++n] = w }
      /^  \}/                 { for (i = 1; i <= n; i++) print name "\t" status "\t" agent "\t" ws[i] }
    ' <<< "$json")" || return 1
  fi
  while IFS=$'\t' read -r name status agent entry; do
    [[ -n "$entry" ]] || continue
    while IFS=$'\t' read -r host mode target; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$agent" "$host" "$mode" "$target"
    done < <(_mount_hosts "$entry")
  done <<< "$raw" | awk '!seen[$0]++'
}

# _mount_hosts <entry>  -- the host paths an sbx workspace or mount entry
# may name, one per line with its mode (rw or ro) and its path in the VM,
# tab-separated. Entries
# are PATH[:TARGET][:ro] (workspaces) or HOST:TARGET[:ro] (mounts), TARGET
# an absolute path in the VM, and a host path can itself hold ':' or ':/',
# so the split can be ambiguous. This fails closed: the plain reading
# (':ro' stripped, then everything from the first ':/' on taken as the
# target) is always printed, and every other reading whose path exists on
# the host is printed too, as is the whole entry if a folder by that name
# (ending in ':ro') exists, as writable.
_mount_hosts() {
  local entry="$1" body mode=rw plain p
  body="$entry"
  if [[ "$body" == *:ro ]]; then
    body="${body%:ro}" mode=ro
    [[ -e "$entry" ]] && printf '%s\trw\t%s\n' "$entry" "$entry"
  fi
  plain="${body%%:/*}"
  _mount_line "$plain" "$body" "$mode"
  while IFS= read -r p; do
    [[ "$p" != "$plain" && -e "$p" ]] && _mount_line "$p" "$body" "$mode"
  done < <(_mount_readings "$body")
  return 0
}

# _mount_line <host> <body> <mode>  -- one _mount_hosts line: <body> is
# <host>, or <host>:<target>.
_mount_line() {
  local target="$1"
  [[ "$2" == "$1:"* ]] && target="${2#"$1:"}"
  printf '%s\t%s\t%s\n' "$1" "$3" "$target"
}

# _mount_readings <text>  -- each place in <text> a host path could end:
# just before every ':/', and at the end.
_mount_readings() {
  local t="$1" acc=""
  while [[ "$t" == *:/* ]]; do
    acc+="${t%%:/*}"
    printf '%s\n' "$acc"
    acc+=":"
    t="/${t#*:/}"
  done
  printf '%s\n' "$1"
}

# tool_vms  -- the VMs this checkout made: name, status, agent and sandbox
# folder (which may no longer exist), tab-separated, one line each. A VM
# counts when it mounts a sandbox folder directly under SANDBOX_ROOT and is
# named after it (is_tool_vm_name, under any prefix), so VMs from other
# checkouts of this tool, or made by hand, never show up -- whatever their
# names look like. Fails, printing nothing, if sbx doesn't answer (sbx_vms):
# callers must not read that as "no VMs". Read it as out="$(tool_vms)", not
# through < <(...), which drops the failure.
tool_vms() {
  local out name status agent ws seen=$'\n'
  out="$(sbx_vms)" || return 1
  while IFS=$'\t' read -r name status agent ws _; do
    [[ "${ws%/*}" == "$SANDBOX_ROOT" ]] || continue
    is_sandbox_name "${ws##*/}" || continue
    is_tool_vm_name "$name" "$ws" || continue
    [[ "$seen" == *$'\n'"$name"$'\n'* ]] && continue
    seen+="$name"$'\n'
    printf '%s\t%s\t%s\t%s\n' "$name" "$status" "$agent" "$ws"
  done <<< "$out"
}

# sandbox_vm <sandbox_dir>  -- prints the name of the sandbox's VM, one that
# mounts the folder: named sbx_name if there is one, else under an earlier
# SBX_NAME_PREFIX (is_tool_vm_name). A VM with the right name that mounts
# some other folder isn't the sandbox's: it was made by hand. Returns 1 if
# the sandbox has no VM (or sbx isn't installed), 2 if sbx doesn't answer.
sandbox_vm() {
  local dir="$1" vms name ws want found=""
  have_sbx || return 1
  vms="$(sbx_vms)" || return 2
  want="$(sbx_name "$dir")"
  while IFS=$'\t' read -r name _ _ ws _; do
    [[ "$ws" == "$dir" ]] || continue
    if [[ "$name" == "$want" ]]; then
      echo "$name"
      return 0
    fi
    is_tool_vm_name "$name" "$dir" && found="$name"
  done <<< "$vms"
  [[ -n "$found" ]] || return 1
  echo "$found"
}

# leftover_vms  -- the tool_vms lines whose sandbox folder is gone: left by a
# sandbox removed by hand, or destroyed while sbx was missing. make new
# skips their numbers; make prune removes them. Fails, printing nothing, if
# sbx doesn't answer (tool_vms), since then it can't tell what's left over.
leftover_vms() {
  local out name status agent ws
  out="$(tool_vms)" || return 1
  while IFS=$'\t' read -r name status agent ws; do
    [[ -n "$name" && ! -d "$ws" ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$name" "$status" "$agent" "$ws"
  done <<< "$out"
}

# sbx_agent_of <vm name>  -- prints the agent an existing sbx VM was created
# with (empty if unknown). JSON via jq when available, else the table's
# AGENT column.
sbx_agent_of() {
  if command -v jq >/dev/null 2>&1; then
    sbx ls --json 2>/dev/null | jq -r --arg n "$1" '.[] | select(.name == $n) | .agent // empty' 2>/dev/null || true
  else
    sbx ls 2>/dev/null | awk -v n="$1" 'NR > 1 && $1 == n { print $2; exit }' || true
  fi
}

# vm_create_args <sandbox_dir>  -- for a VM that doesn't exist yet, made by
# make run (sbx run, which then attaches the agent) or make code (sbx
# create, which doesn't). Writes the sandbox's .vscode settings first
# (ensure_vscode_dir), then sets VM_WORKSPACES, the sandbox folder and its
# .vscode read-only, and CREATE_ARGV, .env's SBX_CREATE_FLAGS then the
# resolved agent's CREATE_FLAGS (profile), with relative kit and file paths
# taken from the tool's folder (resolve_create_flags in profiles.sh). Call
# it after choose_agent, so RUN_CREATE_FLAGS holds the agent's flags. Both
# commands pass the same ones, so the VM is the same either way. Returns 1
# if the settings can't be written.
vm_create_args() {
  VM_WORKSPACES=("$1")
  CREATE_ARGV=()
  ensure_vscode_dir "$1" || return 1
  VM_WORKSPACES+=("$1/.vscode:ro")
  resolve_create_flags "$SBX_CREATE_FLAGS"
  resolve_create_flags "${RUN_CREATE_FLAGS:-}"
  return 0
}

# The agents sbx has built in (`sbx run --help`, v0.50.1 and v0.51.0). AGENT may also be
# an sbx kit reference instead -- see is_kit_ref.
SBX_AGENTS=(claude codex copilot cursor devin docker-agent droid gemini kiro opencode shell)

is_builtin_agent() {
  local a
  for a in "${SBX_AGENTS[@]}"; do [[ "$a" == "$1" ]] && return 0; done
  return 1
}

# A kit reference is a path, ZIP, git URL or OCI ref; bare words are agent
# names to sbx, so anything with a '/' (or a .zip) counts as a kit.
is_kit_ref() { [[ "$1" == */* || "$1" == *.zip ]]; }

# Flags the tool sets itself, or that would break naming, reattach or
# teardown if passed through SBX_CREATE_FLAGS.
SBX_RESERVED_FLAGS=(--name --clone --cloud -d --detach --rm)

# The `sbx run` flags that take a value as the next word (sbx v0.51.0),
# so check_sbx_create_flags can tell a value from a stray folder.
SBX_VALUE_FLAGS=(--allow-network --cpus --deny-network --detach-keys -e --env
  --env-file --image-ref --kit --kit-arg --kit-args-file -m --memory --mount
  --name --on-timeout --platform --profile -p --publish --pull --skills
  --static-mcp -t --template --ttl -v --volume -w --workdir)

# The agent shims written next to each sandbox's AGENTS.md: AGENTS.md is the
# one real instructions file; these just import it, for agents that don't
# read AGENTS.md on their own. Part of GENERATED_FILES (sandbox.sh).
AGENT_SHIMS=(CLAUDE.md GEMINI.md)

# write_agent_shims <sandbox_dir> <n>  -- one file per AGENT_SHIMS entry,
# each importing AGENTS.md with `@AGENTS.md` (Claude Code and Gemini CLI
# both support @-imports). Written for every sandbox whatever AGENT is, so
# any agent works on any sandbox.
write_agent_shims() {
  local dir="$1" n="$2" f tool
  for f in "${AGENT_SHIMS[@]}"; do
    case "$f" in
      CLAUDE.md) tool="Claude Code" ;;
      GEMINI.md) tool="Gemini CLI" ;;
      *)         tool="Your agent" ;;
    esac
    cat > "$dir/$f" <<EOF
# Sandbox $n workspace notes

$tool: this workspace's actual instructions live in \`AGENTS.md\`,
imported below rather than duplicated here.

@AGENTS.md
EOF
  done
}

# git_hosts <repo>...  -- the unique hosts of the repos' origin URLs, one
# per line. Understands scp-style (git@host:path), ssh://, https:// and
# git:// URLs; local paths and file:// are skipped.
git_hosts() {
  local repo url host
  for repo in "$@"; do
    url="$(git -C "${REPOS[$repo]}" remote get-url origin 2>/dev/null)" || continue
    case "$url" in
      *://*)
        [[ "$url" == file://* ]] && continue
        host="${url#*://}"; host="${host%%/*}"; host="${host##*@}"; host="${host%%:*}" ;;
      /*|./*|../*) continue ;;
      *:*)
        host="${url%%:*}"; host="${host##*@}" ;;
      *) continue ;;
    esac
    [[ -n "$host" ]] && echo "$host"
  done | sort -u
}
