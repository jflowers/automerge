#!/usr/bin/env bash

set -uo pipefail

UPDATE_METHOD="rebase"
DRY_RUN=false
INCLUDE_DRAFTS=false
SEARCH_LIMIT="${SEARCH_LIMIT:-1000}"
UNKNOWN_RETRIES="${UNKNOWN_RETRIES:-3}"
UNKNOWN_DELAY_SECONDS="${UNKNOWN_DELAY_SECONDS:-3}"

usage() {
  cat <<'USAGE'
Usage: scripts/update-prs.sh [options]

Find open pull requests authored by the current GitHub user and update branches
that are behind and mergeable.

Options:
  --dry-run                 Report updates without changing pull requests.
  --include-drafts           Include draft pull requests (skipped by default).
  --update-method METHOD     Branch update method: merge or rebase (default: rebase).
  -h, --help                Show this help text.

Environment:
  GH_TOKEN                  Token used by gh. A logged-in gh CLI is also supported.
  SEARCH_LIMIT              Maximum search results (default: 1000).
  UNKNOWN_RETRIES           Detail fetch attempts for UNKNOWN state (default: 3).
  UNKNOWN_DELAY_SECONDS     Delay between UNKNOWN retries (default: 3).
USAGE
}

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --include-drafts)
      INCLUDE_DRAFTS=true
      shift
      ;;
    --update-method)
      (($# >= 2)) || die "--update-method requires merge or rebase"
      UPDATE_METHOD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

case "$UPDATE_METHOD" in
  merge|rebase) ;;
  *) die "--update-method must be merge or rebase" ;;
esac

command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

[[ "$SEARCH_LIMIT" =~ ^[1-9][0-9]*$ ]] || die "SEARCH_LIMIT must be a positive integer"
[[ "$UNKNOWN_RETRIES" =~ ^[1-9][0-9]*$ ]] || die "UNKNOWN_RETRIES must be a positive integer"
[[ "$UNKNOWN_DELAY_SECONDS" =~ ^[0-9]+$ ]] || die "UNKNOWN_DELAY_SECONDS must be a non-negative integer"

search_results=""
if ! search_results="$(gh search prs --author '@me' --state open --limit "$SEARCH_LIMIT" --json number,repository,isDraft 2>&1)"; then
  die "unable to search pull requests: $search_results"
fi

if ! jq -e . >/dev/null 2>&1 <<<"$search_results"; then
  die "gh returned invalid search JSON: $search_results"
fi

total=0
skipped=0
not_behind=0
updated=0
would_update=0
failed=0

while IFS=$'\t' read -r number repo is_draft; do
  [[ -n "$number" && -n "$repo" ]] || continue
  total=$((total + 1))

  if [[ "$is_draft" == "true" && "$INCLUDE_DRAFTS" != true ]]; then
    log "skip $repo#$number: draft"
    skipped=$((skipped + 1))
    continue
  fi

  details=""
  merge_state=""
  mergeable=""
  pr_id=""
  head_oid=""
  base_ref=""
  detail_failed=false

  for ((attempt = 1; attempt <= UNKNOWN_RETRIES; attempt++)); do
    if ! details="$(gh pr view "$number" --repo "$repo" --json id,mergeStateStatus,mergeable,headRefOid,baseRefName 2>&1)"; then
      log "skip $repo#$number: unable to read pull request: $details"
      failed=$((failed + 1))
      detail_failed=true
      break
    fi

    if ! jq -e . >/dev/null 2>&1 <<<"$details"; then
      log "skip $repo#$number: gh returned invalid detail JSON: $details"
      failed=$((failed + 1))
      detail_failed=true
      break
    fi

    pr_id="$(jq -r '.id // empty' <<<"$details")"
    head_oid="$(jq -r '.headRefOid // empty' <<<"$details")"
    base_ref="$(jq -r '.baseRefName // empty' <<<"$details")"
    merge_state="$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"$details")"
    mergeable="$(jq -r '.mergeable // "UNKNOWN"' <<<"$details")"

    if [[ "$merge_state" != UNKNOWN && "$mergeable" != UNKNOWN ]]; then
      break
    fi

    if ((attempt < UNKNOWN_RETRIES)); then
      log "retry $repo#$number: merge state is $merge_state/$mergeable"
      sleep "$UNKNOWN_DELAY_SECONDS"
    fi
  done

  [[ "$detail_failed" == false ]] || continue

  if [[ "$mergeable" == UNKNOWN ]]; then
    log "skip $repo#$number: merge state remained $merge_state/$mergeable"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ -z "$pr_id" || -z "$head_oid" || -z "$base_ref" ]]; then
    log "skip $repo#$number: missing pull request ID, head SHA, or base ref"
    failed=$((failed + 1))
    continue
  fi

  compare_output=""
  behind_by=0
  if compare_output="$(gh api "repos/$repo/compare/${base_ref}...${head_oid}" --jq '.behind_by // 0' 2>&1)"; then
    behind_by="${compare_output:-0}"
  fi

  if [[ "$behind_by" == "0" ]]; then
    log "skip $repo#$number: state=$merge_state mergeable=$mergeable (up to date)"
    not_behind=$((not_behind + 1))
    continue
  fi

  if [[ "$mergeable" != MERGEABLE ]]; then
    log "skip $repo#$number: state=$merge_state mergeable=$mergeable behind_by=$behind_by"
    not_behind=$((not_behind + 1))
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "dry-run: would $UPDATE_METHOD update $repo#$number"
    would_update=$((would_update + 1))
    continue
  fi

  if [[ "$UPDATE_METHOD" == merge ]]; then
    update_output=""
    if update_output="$(gh api --method PUT "repos/$repo/pulls/$number/update-branch" -f expected_head_sha="$head_oid" 2>&1)"; then
      log "updated $repo#$number with merge"
      updated=$((updated + 1))
    else
      log "failed $repo#$number with merge: $update_output"
      failed=$((failed + 1))
    fi
  else
    update_output=""
    # GraphQL variables must remain literal for gh api.
    # shellcheck disable=SC2016
    if update_output="$(gh api graphql \
      -f query='mutation($pullRequestId: ID!, $expectedHeadOid: GitObjectID, $updateMethod: PullRequestBranchUpdateMethod) { updatePullRequestBranch(input: { pullRequestId: $pullRequestId, expectedHeadOid: $expectedHeadOid, updateMethod: $updateMethod }) { pullRequest { id } } }' \
      -f pullRequestId="$pr_id" \
      -f expectedHeadOid="$head_oid" \
      -f updateMethod=REBASE \
      2>&1)"; then
      if jq -e '((.errors // []) | length == 0) and (.data.updatePullRequestBranch.pullRequest.id != null)' >/dev/null 2>&1 <<<"$update_output"; then
        log "updated $repo#$number with rebase"
        updated=$((updated + 1))
      else
        log "failed $repo#$number with rebase: $update_output"
        failed=$((failed + 1))
      fi
    else
      log "failed $repo#$number with rebase: $update_output"
      failed=$((failed + 1))
    fi
  fi
done < <(jq -r '.[] | [.number, (if (.repository | type) == "object" then (.repository.nameWithOwner // .repository.fullName) else .repository end), (.isDraft // false)] | @tsv' <<<"$search_results")

log "summary: found=$total updated=$updated would_update=$would_update skipped=$skipped not_behind=$not_behind failed=$failed"

if ((failed > 0)); then
  exit 1
fi
