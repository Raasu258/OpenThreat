#!/usr/bin/env bash
# Merge Dependabot PRs whose "Images" CI run passed on the current head.
#
#   dependabot_automerge.sh <pr-number> <head-sha>   one PR (workflow_run)
#   dependabot_automerge.sh --sweep                  every open Dependabot PR
#
# The sweep exists because workflow_run only fires for runs that finish
# after this workflow is on the default branch; anything missed (workflow
# added late, a GitHub hiccup, a failed merge) is picked up on the next one.
#
#   patch / minor  -> squash-merge, then dispatch Images on the default branch
#   major/unknown  -> label "dependabot:manual-review" + one comment
#   label "no-automerge" opts a PR out.
#
# Env: GH_TOKEN, REPO (owner/name), DEFAULT_BRANCH. Needs gh, jq, python3.
# DRY_RUN=1 prints merges/labels/comments/dispatches instead of doing them.
set -euo pipefail

: "${REPO:?}" "${DEFAULT_BRANCH:?}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
HERE="$(cd "$(dirname "$0")" && pwd)"
merged=0

# Write calls go through here so DRY_RUN can stub them.
write_api() {
  if [ "${DRY_RUN:-0}" = 1 ]; then echo "DRY_RUN: gh api $*" >&2; echo "dry run"; return 0; fi
  gh api "$@"
}

summary() { echo "$*"; echo "- $*" >> "$SUMMARY"; }

# Conclusion of the newest finished Images run on the default branch. PRs are
# tested merged with main as it was when their CI ran; main's own Images run
# re-tests every merge before images are published (the VPS only deploys
# commits that have images). If that build is red, stop merging until fixed.
main_result() {
  gh api "repos/$REPO/actions/workflows/images.yml/runs?branch=$DEFAULT_BRANCH&status=completed&per_page=10" \
    --jq '[.workflow_runs[] | select(.event == "push" or .event == "workflow_dispatch")][0].conclusion // "none"'
}

# Conclusion of the newest Images run for this commit ("" if none finished).
ci_result() {
  gh api "repos/$REPO/actions/workflows/images.yml/runs?head_sha=$1&event=pull_request&per_page=1" \
    --jq '.workflow_runs[0] | select(.status == "completed") | .conclusion'
}

process() { # pr, sha that CI verified
  local pr="$1" verified="$2" json author base sha labels others kind
  json="$(gh api "repos/$REPO/pulls/$pr")"
  author="$(jq -r .user.login <<<"$json")"
  base="$(jq -r .base.ref <<<"$json")"
  sha="$(jq -r .head.sha <<<"$json")"
  labels="$(jq -r '[.labels[].name] | join(",")' <<<"$json")"

  if [ "$(jq -r .state <<<"$json")" != open ]; then summary "#$pr: not open"; return; fi
  if [ "$author" != "dependabot[bot]" ] || [ "$base" != "$DEFAULT_BRANCH" ]; then
    summary "#$pr: not a Dependabot PR into $DEFAULT_BRANCH"; return
  fi
  if [ "$sha" != "$verified" ]; then
    summary "#$pr: head moved on since CI ran ($verified); the newer run decides"; return
  fi
  case ",$labels," in *,no-automerge,*) summary "#$pr: opted out via label"; return ;; esac

  others="$(gh api "repos/$REPO/pulls/$pr/commits" \
    --jq '[.[] | select(.author.login != "dependabot[bot]")] | length')"
  if [ "$others" != 0 ]; then
    summary "#$pr: has commits not made by Dependabot - left for review"; return
  fi

  kind="$(jq -r .body <<<"$json" | python3 "$HERE/dependabot_update_type.py")"
  case "$kind" in
    patch|minor)
      # A merge can fail if main moved and the PR now conflicts; Dependabot
      # rebases it, CI runs again and the next run/sweep merges it.
      if write_api -X PUT "repos/$REPO/pulls/$pr/merge" -f merge_method=squash -f sha="$sha" \
           --jq .message; then
        merged=$((merged + 1)); summary "#$pr: merged ($kind)"
      else
        summary "#$pr: merge failed ($kind) - retried after Dependabot rebases it"
      fi
      ;;
    *)
      case ",$labels," in
        *,dependabot:manual-review,*) ;;
        *)
          write_api "repos/$REPO/issues/$pr/labels" -f "labels[]=dependabot:manual-review" >/dev/null
          write_api "repos/$REPO/issues/$pr/comments" -f body="CI passed, but this is a **$kind** update, so it is not merged automatically. Review the changelog, then merge by hand (the VPS deploys it after the main build)." >/dev/null
          ;;
      esac
      summary "#$pr: left for review ($kind)"
      ;;
  esac
}

main_state="$(main_result)"
case "$main_state" in
  success|none) ;;
  cancelled) echo "last $DEFAULT_BRANCH build was cancelled (superseded); continuing" ;;
  *) summary "last $DEFAULT_BRANCH build: $main_state - auto-merge paused until $DEFAULT_BRANCH is green"; exit 0 ;;
esac

if [ "${1:-}" = --sweep ]; then
  prs="$(gh api --paginate "repos/$REPO/pulls?state=open&base=$DEFAULT_BRANCH&per_page=100" \
    --jq '.[] | select(.user.login == "dependabot[bot]") | "\(.number) \(.head.sha)"')"
  while read -r pr sha; do
    [ -n "$pr" ] || continue
    result="$(ci_result "$sha")"
    case "$result" in
      success) process "$pr" "$sha" || summary "#$pr: error while processing" ;;
      "")      summary "#$pr: CI not finished on ${sha:0:7} yet" ;;
      *)       summary "#$pr: CI $result on ${sha:0:7} - not merged" ;;
    esac
  done <<<"$prs"
else
  process "${1:?pr number}" "${2:?head sha}"
fi

if [ "$merged" -gt 0 ]; then
  # Merges made with GITHUB_TOKEN don't trigger push workflows -> build main explicitly
  write_api -X POST "repos/$REPO/actions/workflows/images.yml/dispatches" -f ref="$DEFAULT_BRANCH"
  summary "started Images on $DEFAULT_BRANCH ($merged merged)"
fi
