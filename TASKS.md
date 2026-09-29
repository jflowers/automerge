# PR Branch Auto-Update Tasks

## Scope

Build a shell-based tool that finds open pull requests authored by the current
GitHub user across repositories, skips drafts by default, and updates branches
that are behind and mergeable. It must run locally and from GitHub Actions.

## Defaults

- Update method: `rebase`
- Draft pull requests: skipped
- Scheduled workflow: every 15 minutes (`*/15 * * * *`)
- Authentication: `GH_TOKEN`, with `GH_PAT` used by the workflow
- Required tools: `gh`, `jq`

## Checklist

- [x] Verify the REST and GraphQL branch-update API contracts.
- [x] Verify the local `gh` command shapes needed by the script.
- [x] Implement `scripts/update-prs.sh`.
- [x] Support `--dry-run`, `--include-drafts`, and `--update-method merge|rebase`.
- [x] Add scheduled and manual workflow configuration.
- [x] Document setup, token permissions, local usage, and fork limitations.
- [x] Run shell syntax validation.
- [x] Validate workflow YAML and Actions inputs.
- [x] Run a local dry-run that does not update pull requests.
- [x] Review the final diff and record verification results.

## Progress Log

- Repository inspection complete: clean repository with no existing automation.
- `gh pr view` exposes `id`, `mergeStateStatus`, `mergeable`, and `headRefOid`; `gh search prs` supports `--author @me`, open state, JSON output, and repository/number/draft fields.
- REST merge contract verified: `PUT /repos/{owner}/{repo}/pulls/{pull_number}/update-branch` with optional `expected_head_sha`, returning `202` on acceptance.
- GraphQL schema verified with `gh api graphql`: `updatePullRequestBranch` accepts `pullRequestId`, optional `expectedHeadOid`, and `updateMethod` values `MERGE` or `REBASE`.
- Implemented the executable update script with merge and rebase paths, draft filtering,
  transient `UNKNOWN` retries, per-pull-request error continuation, and dry-run support.
- Added the 15-minute scheduled/manual workflow and documented PAT setup, permissions,
  local usage, and fork limitations in `README.md`.
- Changed the default update method to `rebase`; explicit `merge` selection remains supported.
- Verification passed: `bash -n scripts/update-prs.sh`, help and invalid-option checks,
  Ruby YAML parsing, and a live dry-run with `SEARCH_LIMIT=100`, which found four open
  pull requests, performed zero updates, and returned zero failures. A second dry-run
  identified one eligible merge update without invoking an update endpoint. `shellcheck`
  and `git diff --check` also pass.
