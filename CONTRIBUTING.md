# Contributing

Thanks for helping improve sbx-capsule. Issues and pull requests are
welcome.

## Before you start

- **Bugs:** open an issue with what you ran, what you expected, what
  happened, your OS, and the output of `make doctor`. Leave out anything
  private (repo paths and hosts) from what you paste.
- **Features and behaviour changes:** open an issue first to agree on the
  approach, especially for anything that changes the `.env` format or the
  make targets.
- **Security issues:** don't open a public issue; see
  [SECURITY.md](SECURITY.md).

## Scope

The tool is deliberately small: bash, git, make and `sbx`, nothing else at
runtime. Changes that add a language runtime or a package dependency are
unlikely to be accepted. Anything specific to one team or machine belongs in
a user's `SANDBOX_NOTES_FILE`, not in the tool.

## Making a change

The conventions, invariants and test steps are written down once, in
[AGENTS.md](AGENTS.md). It's addressed to AI agents, but it applies equally
to people. In short:

1. Follow the existing bash style: `set -euo pipefail`, helpers from
   `scripts/lib/`, validate everything before changing anything, report every
   problem at once.
2. Test: `make test` (syntax, `shellcheck` if you have it, and the test
   suite, which needs no `sbx`), with new tests for what you changed.
   CI runs shellcheck, so install it locally to catch findings before you
   push; silence one only with a narrow `# shellcheck disable=` that says
   why. If you changed `make run` or `make code`, also try them against
   real `sbx` in a scratch copy of the repo (see "Testing" in
   [AGENTS.md](AGENTS.md)).
3. Update the docs: [README.md](README.md) for anything users see,
   [docs/DESIGN.md](docs/DESIGN.md) for design changes.
4. Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md),
   saying how to migrate if the change breaks existing setups.
5. Keep commits focused, with imperative summary lines ("Add ...",
   "Refuse ...").

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
