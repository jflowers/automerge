# automerge

Automatically update branches for open pull requests authored by the current
GitHub user across repositories.

The tool skips draft pull requests by default. It updates a pull request only
when GitHub reports that the branch is `BEHIND` and the pull request is
`MERGEABLE`.

## Usage

Requirements:

- `gh`
- `jq`
- A GitHub token with access to every repository that should be checked

Run a safe local preview:

```sh
GH_TOKEN="$GH_PAT" bash scripts/update-prs.sh --dry-run
```

Use the default merge update method, include drafts, or request rebases:

```sh
bash scripts/update-prs.sh --include-drafts
bash scripts/update-prs.sh --update-method rebase --dry-run
```

The script can also use the local `gh auth login` session when `GH_TOKEN` is
not set. It retries pull requests whose merge state is temporarily `UNKNOWN`
and continues processing when an individual repository or pull request fails.

## GitHub Actions

The workflow runs every 15 minutes and can also be started manually from the
Actions tab. Scheduled runs use the `merge` method and do not include drafts.
Manual runs provide `merge` or `rebase` and a dry-run input.

Create a repository secret named `GH_PAT`. The token must be able to read and
write pull requests and repository contents in every target repository. A
fine-grained PAT generally needs repository access plus `Pull requests: Read
and write` and `Contents: Read and write`; a classic PAT normally uses the
`repo` scope. Use the narrowest token that covers the repositories involved.

The workflow permissions in this repository are also set to write pull
requests and contents, but those permissions do not expand the access granted
by `GH_PAT`.

For pull requests from forks, GitHub may prevent branch updates unless the
head repository permits edits by maintainers. The token also needs access to
the head repository, not only the repository containing the pull request.

## Local Verification

```sh
bash -n scripts/update-prs.sh
bash scripts/update-prs.sh --help
bash scripts/update-prs.sh --dry-run
```

The dry-run performs discovery and state checks but never calls a branch update
endpoint.
