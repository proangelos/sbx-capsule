# Directory this Makefile itself lives in, regardless of where the repo is
# checked out or what directory `make` was invoked from.
SANDBOX_ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
CMD := $(SANDBOX_ROOT)/scripts/commands

# make's built-in AS is the assembler ("as"); clear it so make push's AS=<branch>
# is empty unless you give one. A command-line AS=... still wins.
AS :=

# Every variable a target takes reaches its script through the
# environment, and recipes read it as "$$VAR", never as $(VAR): make pastes
# $(VAR) into the shell command as text, so a value holding a quote,
# backtick or $( ) would run as shell code.
# Each is defined (empty unless given), so scripts can rely on it being set.
TARGET_VARS := N REPO WITH TITLE PUSH_AS EMPTY ARGS FRESH ALL YES AS FORCE TEST_FILTER
$(foreach v,$(TARGET_VARS),$(eval $(v) ?=))
export $(TARGET_VARS)

# AGENT=<profile or agent> picks a sandbox's own agent (make new, make run).
# It reaches the scripts as CLI_AGENT, and only from the command line: an
# AGENT in your shell's environment never counts, and .env's AGENT (read
# later, by the scripts) is a different setting. Like every variable here,
# it reaches the scripts through the environment, never as recipe text.
CLI_AGENT := $(if $(filter command line,$(origin AGENT)),$(value AGENT))
export CLI_AGENT

.PHONY: help init doctor new list run code stop prune add fetch push destroy test
.DEFAULT_GOAL := help

help: ## Show this help
	@echo "Usage: make <target> [ARGS...]"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*## "}; {printf "  %-10s %s\n", $$1, $$2}'

# First time: make init creates your .env from .env.example and checks your tools.
init: ## First-time setup: create .env from .env.example (if missing) and check your tools
	@"$(CMD)/init.sh"

# Read-only: checks tools, sbx health, .env, and each repo's checkout, start branch and git host.
doctor: ## Check your tools, sbx, .env and repos, and say how to fix anything wrong
	@"$(CMD)/doctor.sh"

# Repos come from your .env (make init creates it); none are included unless named here
# or listed in DEFAULT_REPOS there. A repo can name its start branch after ':'.
# make new WITH="api web"                              those repos, each from its SOURCE_BRANCHES entry
# make new WITH="api web:feat/login"                   web starts from feat/login instead
# make new TITLE=loginFix WITH=api                     dir is "<n>-loginFix" instead of just "<n>"
# make new WITH="api web" PUSH_AS=fix-auth-bug         work on branch fix-auth-bug, pushing to origin/fix-auth-bug
# make new EMPTY=1                                     no repos, even with DEFAULT_REPOS set; make add brings them in later
#                                                      (with no WITH and no DEFAULT_REPOS, plain make new does the same)
# make new WITH=api AGENT=pi                           the sandbox's own agent: profile user-config/agents/pi.env
#                                                      (or a built-in agent or kit ref), kept whatever .env's AGENT says
new: ## Create a new numbered sandbox of clones (WITH="repo repo:branch ...", TITLE=name, PUSH_AS=branch-name, EMPTY=1, AGENT=profile)
	@"$(CMD)/create.sh"

# Only this checkout's sandboxes and the VMs it made; never other sbx VMs.
list: ## List sandboxes, their repos and the state of their VMs
	@"$(CMD)/list.sh"

# The agent is the sandbox's own (AGENT= given to make new or make run), else AGENT in your
# .env (default claude); either is fixed when the VM is created.
# make run N=3                      start the agent in the sandbox's sbx VM, or reattach
# make run N=3 ARGS="--continue"    extra arguments for the agent (after its profile's ARGS or AGENT_ARGS)
# make run N=3 FRESH=1              recreate the VM from the current .env (AGENT, SBX_CREATE_FLAGS);
#                                   the sandbox's files stay, the agent's history inside the VM goes
# make run N=3 AGENT=pi             run profile pi (or a built-in agent or kit ref) and keep it as the
#                                   sandbox's own; on a VM made with another agent, add FRESH=1
run: ## Start or reattach the agent in a sandbox's Docker Sandbox VM (make run N=<n> [ARGS="..."] [FRESH=1] [AGENT=profile])
	@test -n "$$N" || { echo "usage: make run N=<sandbox number>" >&2; exit 1; }
	@"$(CMD)/run.sh" "$$N"

# VS Code runs inside the sandbox's VM (Remote-SSH), so nothing the agent wrote runs on
# the host. One-time setup: README.md, "Reviewing and editing a sandbox".
code: ## Open a sandbox in VS Code running inside its VM (make code N=<n>)
	@test -n "$$N" || { echo "usage: make code N=<sandbox number>" >&2; exit 1; }
	@"$(CMD)/code.sh" "$$N"

# A stopped VM keeps its state; make run N=3 starts it again.
# make stop N=3                     stop that sandbox's VM
# make stop ALL=1                   stop every running VM this checkout made
stop: ## Stop a sandbox's VM, keeping its state (make stop N=<n>, or ALL=1 for all)
	@if [ -n "$$ALL" ]; then "$(CMD)/stop.sh" --all; \
	elif [ -n "$$N" ]; then "$(CMD)/stop.sh" "$$N"; \
	else echo "usage: make stop N=<sandbox number>, or make stop ALL=1" >&2; exit 1; fi

# VMs whose sandbox folder is gone (removed by hand, or destroyed while sbx was missing).
# Only this checkout's VMs; lists them and asks once. YES=1 skips the question.
prune: ## Remove this checkout's sbx VMs whose sandbox folder is gone (make prune [YES=1])
	@"$(CMD)/prune.sh"

# make add N=3 REPO=worker
# make add N=3 REPO="worker web:feat/login"
add: ## Clone more repos into a sandbox (make add N=<n> REPO="repo repo:branch ...")
	@test -n "$$N" -a -n "$$REPO" || { echo "usage: make add N=<sandbox number> REPO=\"<repo>[:<branch>] ...\"" >&2; exit 1; }
	@"$(CMD)/add.sh" "$$N" "$$REPO"

# Fetches origin from the host and leaves a bundle in the sandbox for the agent to apply,
# so the VM needs no network or credentials and git never runs in the clone on the host.
# make fetch N=3                    every clone in the sandbox
# make fetch N=3 REPO=api           just that one
fetch: ## Fetch origin's new commits for a sandbox's clones, as bundles the agent applies (make fetch N=<n> [REPO="repo ..."])
	@test -n "$$N" || { echo "usage: make fetch N=<sandbox number> [REPO=\"<repo> ...\"]" >&2; exit 1; }
	@"$(CMD)/fetch.sh" "$$N" "$$REPO"

# Pushes from the host without running git in the clone (its config is the agent's).
# make push N=3 REPO=api            to the sandbox's PUSH_AS branch
# make push N=3 REPO="api web" AS=fix-login   no PUSH_AS: name the remote branch
push: ## Push a sandbox clone's branch from the host, safely (make push N=<n> REPO="repo ..." [AS=branch] [YES=1])
	@test -n "$$N" -a -n "$$REPO" || { echo "usage: make push N=<sandbox number> REPO=\"<repo> ...\" [AS=<branch>]" >&2; exit 1; }
	@"$(CMD)/push.sh" "$$N" "$$REPO"

# make destroy N=3
# make destroy N=3 FORCE=1          even if a repo has unsaved work
destroy: ## Tear down a sandbox, its clones and its VM (make destroy N=<n> [FORCE=1])
	@test -n "$$N" || { echo "usage: make destroy N=<sandbox number>" >&2; exit 1; }
	@"$(CMD)/destroy.sh" "$$N"

# For working on the tool itself: every script parses, shellcheck (if
# installed) is clean, then tests/run.sh, which uses scratch copies and a
# fake sbx -- your .env, sandboxes and VMs are never touched.
# make test TEST_FILTER=push                           only tests whose names contain "push"
test: ## Run the tool's own checks and tests (for contributors; needs no sbx)
	@cd "$(SANDBOX_ROOT)" && for f in scripts/*/*.sh tests/*.sh tests/fake-sbx/sbx; do bash -n "$$f" || exit 1; done
	@cd "$(SANDBOX_ROOT)" && if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -x scripts/*/*.sh tests/*.sh tests/fake-sbx/sbx; \
	else echo "shellcheck isn't installed; skipped"; fi
	@"$(SANDBOX_ROOT)/tests/run.sh"
