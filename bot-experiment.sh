#!/bin/sh
# Reference for the GitLab API calls the GlaHiCo bot (bot.hs) will make.
# Experiments on sjakobi/GlaHiCo!3 as @glahico-bot-unofficial, GitLab
# 18.11, bot as Developer; see BOT.md "What the bot can do, by role".
# Every call runs as the bot (token from ~/glahico/bot-token).
#
# Results: reviewer needs Developer (403 as Reporter); start moves the bot
# to REVIEW_STARTED and publish leaves it there, which is enough for the
# author to see the re-request icon; internal is rejected with HTTP 422
# (CSRF); done must be called explicitly, see the to-do race in BOT.md.
#
# Usage:
#   sh bot-experiment.sh IID whoami|reviewer|todos|todos-all|state|start|publish|internal|done TODO_ID
set -eu
PROJ="sjakobi%2FGlaHiCo"
BOT_ID=146625
IID=${1:?MR iid}; CMD=${2:?command}
GITLAB_TOKEN=$(sudo cat ~/glahico/bot-token); export GITLAB_TOKEN
MR="projects/$PROJ/merge_requests/$IID"

state() {
  glab api graphql -f query="query { project(fullPath: \"sjakobi/GlaHiCo\") {
    mergeRequest(iid: \"$IID\") { reviewers { nodes { username
      mergeRequestInteraction { reviewState } } } } } }" \
  | jq -c '.data.project.mergeRequest.reviewers.nodes[] | {username, state: .mergeRequestInteraction.reviewState}'
}

case $CMD in
  whoami)   glab api user | jq -c '{id, username}' ;;
  reviewer) # add the bot to the existing reviewers (PUT replaces the list)
    ids=$(glab api "$MR" | jq -c "[.reviewers[].id] + [$BOT_ID] | unique")
    printf '{"reviewer_ids":%s}' "$ids" | glab api -X PUT "$MR" -H "Content-Type: application/json" --input - \
      | jq -c '[.reviewers[].username]'
    state ;;
  todos)    glab api "todos?type=MergeRequest" \
      | jq -c '.[] | {id, action: .action_name, author: .author.username, mr: .target.references.full, state}' ;;
  state)    state ;;
  todos-all) for st in pending done; do echo "--- $st"; glab api "todos?type=MergeRequest&state=$st&per_page=8" \
      | jq -c '.[] | {id, created: .created_at[11:19], updated: .updated_at[11:19], action: .action_name, author: .author.username, mr: .target.references.full}'; done ;;
  start)    glab api -X POST "$MR/draft_notes" -f note="GlaHiCo bot: draft-note experiment (placeholder)" \
      | jq -c '{id, note}'
    state ;;
  publish)  id=$(glab api "$MR/draft_notes" | jq '.[0].id')
    glab api -X PUT "$MR/draft_notes/$id" -f note="GlaHiCo bot: draft-note experiment (final text)" >/dev/null
    glab api -X POST "$MR/draft_notes/bulk_publish" >/dev/null && echo published
    state ;;
  done)     glab api -X POST "todos/${3:?todo id}/mark_as_done" | jq -c '{id, state}' ;;
  internal) # the browser's publish endpoint; does it accept a PAT? (expect no)
    curl -s -o /tmp/internal.out -w 'HTTP %{http_code}\n' -X POST \
      -H "PRIVATE-TOKEN: $GITLAB_TOKEN" -H "Accept: application/json" \
      -d "reviewer_state=reviewed" \
      "https://gitlab.haskell.org/sjakobi/GlaHiCo/-/merge_requests/$IID/drafts/publish"
    head -c 300 /tmp/internal.out; echo
    state ;;
  *) echo "unknown command $CMD" >&2; exit 2 ;;
esac
