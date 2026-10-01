# GlaHiCo bot — working notes

Bot account on gitlab.haskell.org: `@glahico-bot-unofficial`.
Purpose: let GHC MR authors request GlaHiCo reviews without pinging Simon.

## Status (2026-10-01)

- Workflow below is accepted as the plan.
- Account created: https://gitlab.haskell.org/glahico-bot-unofficial,
  user id 146625, display name "GlaHiCo Bot". Primary email
  simon.t.jakobi+glahico-bot@proton.me (see "Email for the bot account").
  Developer on sjakobi/GlaHiCo since 2026-10-01 (was Reporter for the
  first experiments). Developer on ghc/ghc requested from a GHC
  maintainer 2026-10-01 (initially asked for Reporter, then upgraded the
  ask so the bot gets the full reviewer experience: can mark itself
  reviewed, re-request icon appears). No answer yet.
- Bot personal access token (`api` scope) created 2026-10-01, stored
  root-owned at `~/glahico/bot-token`. Expires 2027-10-01.
- Instance: GitLab 18.11.12-ee. ghc group does not require 2FA.
- No code yet. Decision 2026-10-01: the bot is a separate program,
  `bot.hs` in this repo (same cabal-script style as glahico.hs), not
  part of glahico.hs. It shells out to glahico.hs for generating and
  publishing and reads the snippet URL from the run's `snippet.json`.
  Rationale: the pipeline stays stateless, the bot token and the only
  code that writes to MRs live in one small program, and the two stay
  versioned together because the bot depends on glahico.hs's CLI and
  run-directory layout. Implementation waits for the Developer answer.

## Requesting a review

The author comments the quick action

    /request_review @glahico-bot-unofficial

on the MR, for the first review and for every subsequent one. Aliases:
`/assign_reviewer`, `/reviewer`. If the bot is not yet a reviewer this
adds it; if it is, GitLab re-requests the review. Both produce a
`review_requested` to-do for the bot, a notification, and a system note
"requested review from @glahico-bot-unofficial". Adding the bot via the
Reviewers sidebar is equivalent for the first review.

Why the quick action and not the sidebar's re-request icon: the icon is
hidden for reviewers in state UNREVIEWED (frontend
`uncollapsed_reviewer_list.vue`, `showRequestReviewButton`), and the bot
can never leave that state (see below). The backend
`MergeRequests::RequestReviewService` has no such guard: it resets the
state, notifies, creates the to-do and the system note regardless of the
previous state. The quick action and the GraphQL mutation
`mergeRequestReviewerRereview` both go through that service.

A mention (`@glahico-bot-unofficial review`) also works and yields a
`directly_addressed`/`mentioned` to-do; keep accepting it, but document
the quick action as the way.

Requests are honoured **only from the MR author** (enforced by the bot;
GitLab lets anyone with update rights on the MR issue the quick action).
Rationale: keeps cost opt-in and controlled by the person who owns the MR.

To verify on sjakobi/GlaHiCo!3: author comments the quick action while
the bot is already a reviewer; expect a new pending `review_requested`
to-do.

## What the bot can do, by role (verified 2026-10-01 on sjakobi/GlaHiCo!3, GitLab 18.11)

What matters: learning about a request and being able to post a review,
and with Developer also the normal reviewer UX.

As Reporter:

- Author adds the bot as reviewer, or uses `/request_review` -> pending
  to-do (`action_name: review_requested`) + system note "requested
  review from @glahico-bot-unofficial".
- Comment mentioning the bot -> to-do with `action_name:
  directly_addressed` (mention at the start) or `mentioned` (elsewhere);
  accept both. The to-do's `body` carries the comment text. List with
  REST `GET /todos?type=MergeRequest` (default: pending only).
- Bot posts a comment on the MR under its own name (REST `POST .../notes`
  or draft notes + `bulk_publish`).
- Bot cannot set reviewers (PUT on the MR -> 403) and cannot change its
  reviewer state; it stays "awaiting review", and the sidebar then shows
  the author no re-request icon.

As Developer (decided role; the bot was raised to Developer on
sjakobi/GlaHiCo for these checks):

- Bot can set reviewers via REST PUT (`reviewer_ids`), so it can add
  itself after a mention-triggered review.
- Creating a draft note moves the bot to REVIEW_STARTED ("review in
  progress" icon).
- Browser "Submit review" (plain Comment, never Approve/Request changes)
  moves it to REVIEWED, system note "left review comments", and the
  author's sidebar shows the re-request icon.
- Author clicks re-request -> state back to UNREVIEWED, system note, new
  `review_requested` to-do. Confirmed.
- Still no API route to REVIEWED on 18.11; see "GitLab 19.2 data point"
  in References. The browser's internal endpoint
  (`POST /<proj>/-/merge_requests/:iid/drafts/publish` with
  `reviewer_state=reviewed`) rejects the access token with HTTP 422
  (Rails CSRF: "The change you requested was rejected"), so it needs a
  logged-in browser session. Until the instance upgrades, submitting the
  batch of reviews happens in a browser logged in as the bot.
- But REVIEWED is probably unnecessary (source check 2026-10-02, to
  verify on !3): the sidebar shows the re-request icon for every state
  except UNREVIEWED (`showRequestReviewButton`), and REST
  `bulk_publish` leaves the state untouched in 18.11
  (`DraftNotes::PublishService` and the `ProcessDraftNotePublishedWorker`
  only handle to-dos and notifications; only `DraftsController#publish`
  calls `UpdateReviewerStateService`). So draft note + `bulk_publish`
  via REST as Developer should leave the bot at REVIEW_STARTED
  ("Reviewer started review") with the re-request icon visible. The
  only loss is cosmetic: "started review" instead of "left review
  comments". Test: `bot-experiment.sh 3 start`, then `publish`, then
  check the author's sidebar.

To-do semantics that shape the implementation:

- GitLab keeps at most one *pending* to-do per (MR, action) for a user
  (`TodoService#excluded_user_ids`). A re-request while an older
  `review_requested` to-do is still pending creates nothing.
- The reviewer's own to-dos are marked done when the review is
  published, but asynchronously (`ProcessDraftNotePublishedWorker`).
  Observed: a re-request 47 s after the bot's submit was swallowed, the
  old to-do was completed afterwards, net result no pending to-do.
- Therefore `bot post` must mark the request's to-do done itself,
  immediately after posting, and must do so on skip paths as well.
- The REST to-do JSON has `created_at` and `updated_at` (done time).

Reviewer state: the bot cannot change its own. Every path (GraphQL,
REST `bulk_publish`, the browser's "Submit review") ends in
`MergeRequests::UpdateReviewerStateService`, whose first line requires
`update_merge_request` on the MR. That permission goes to the MR's
author/assignees and to Developers, not Reporters. So REVIEW_STARTED is
not set when the bot creates a draft note, and REVIEWED is not set on
publish, which matches the experiment. The browser would not help
either: same service, same check.

What would make the sidebar icon appear (not planned):
- Developer on ghc/ghc (also unlocks approving, editing any MR, pushing
  to non-protected branches), plus
- GitLab >= 19.2, where REST `bulk_publish` gained `reviewer_state`
  (`reviewed`|`requested_changes`, deliberately no `approved`; added for
  GitLab's own Duo review agents, gitlab-org/gitlab!237813). On 18.11
  the browser's internal `drafts/publish` endpoint is the only caller.
- Oddity: making the bot an *assignee* would also grant
  `update_merge_request`. Wrong semantics, not worth it.

APPROVED and REQUESTED_CHANGES are reachable in principle but off
limits: approvals feed merge rules, and reviews are labelled tool output
(see DESIGN.md). The bot therefore stays UNREVIEWED ("awaiting review")
on every MR. Cosmetic only, given the quick action above.

Related upstream issues: gitlab-org/gitlab#583745 (Duo: re-request icon
shown while review in progress), #517909 (submit/re-request emit no
webhook events), #543648 (show previous state after re-request).

Read-side: GraphQL
`mergeRequest.reviewers.nodes.mergeRequestInteraction.reviewState`, or
REST `GET .../merge_requests/:iid/reviewers`.

glab notes: `glab api graphql` turns any `__type` query into a full
`__schema` dump; pipe through jq. `--input` bodies need an explicit
`-H "Content-Type: application/json"`.

## Workflow (phase 1: human in the loop)

### Learning about requests

- Set the bot account's notification email to an address Simon reads:
  GitLab mails on every reviewer assignment and mention.
- `bot.hs poll` (bot token): reads the bot's pending to-dos.
  Assignment -> action `review_requested`; comment trigger ->
  `mentioned` / `directly_addressed`. For each, fetch the MR, check the
  requester is the MR author, and print a table: MR, title, trigger,
  head SHA, diff size, previous reviews of that MR.

### State

One JSON file per request in `~/glahico/bot/requests/<todo-id>.json`.
The to-do id is the key: each request creates a fresh to-do, and the
to-do stays pending in GitLab until the bot marks it done, so nothing is
lost if a local file goes missing. Fields: MR iid, head SHA, trigger,
requester, status, and once known the run dir and models/effort used.

Status: `pending` -> `running` -> `generated` -> `posted`, or `skipped`
(with a reason: non-author, duplicate SHA, diff too large, ...).

### Deciding models and effort, then running

Per-request human decision, driven by the poll table.

`bot.hs run TODO_ID [--finder-model ID] [--finder-effort L]
[--verifier-model ID] [--verifier-effort L]`, `--all` for every pending
request with defaults.

Defaults for the bot path are pinned full model IDs, never aliases, so
the models don't drift by accident; the bot path refuses bare aliases.

- verifier: `claude-fable-5-1`, medium
- finder: opus at high effort (pinned full ID of the current opus).
  Most cost data is for this configuration.

Fable has a track record of better findings in some cases, at least one
typechecker MR. Eventually a simple rule-based choice (e.g. by touched
subsystem or diff size) may pick fable for the finder; not now. Until
then, per-request overrides on `bot run`.

The interactive `--finder-model`/`--verifier-model` flags keep their
`opus` alias defaults.

`bot run` creates a placeholder draft note on the MR (moves the bot to
REVIEW_STARTED, visible to the author), records the run dir in the
request file, and marks `generated` on success.

### Push

`bot.hs post TODO_ID` or `--all` for everything in `generated`:

1. Publish the snippet (existing code path; snippet.json guards
   against double publish).
2. (Dropped: the bot cannot add itself as reviewer at Reporter. The
   footer text covers it instead.)
3. Post one MR comment: review H1, snippet link, models/effort used, and
   a fixed footer: "To request another review after pushing, click the
   re-request icon next to @glahico-bot-unofficial in the Reviewers
   list, or comment `/request_review @glahico-bot-unofficial`."
4. Mark the request's to-do done explicitly (do not rely on GitLab's
   asynchronous cleanup; see to-do semantics above). Status `posted`.
5. Reviewer state: posting via draft note + `bulk_publish` leaves the
   bot at REVIEW_STARTED, which already shows the author the re-request
   icon (see "What the bot can do, by role"; verify on !3). REVIEWED is
   cosmetic. If wanted anyway before the instance runs GitLab >= 19.2,
   the cheapest route is not a browser but curl with the bot's session
   cookie and the page's CSRF token against the internal publish
   endpoint (see "Browser-free REVIEWED" below). From 19.2 on,
   `bulk_publish` with `reviewer_state=reviewed` does it from `bot post`.

Ordered so that a crash midway is recoverable by re-running; the request
status says where it stopped.

Open: link only (current plan) vs. embedding the full review in the MR
comment. Linking keeps the thread short; embedding puts feedback in the
MR.

### Dedupe on head SHA

At poll time, if the MR head matches the last posted review for that MR,
mark `skipped`; `bot post` leaves a one-line comment pointing at the
previous review and closes the to-do. Consider the same for pure rebases
with an unchanged diff.

### Non-author requests

Marked `skipped` at poll time. Initially reply nothing (avoid noise);
reconsider if people are confused.

### Token

Bot token needs `api` scope. Store like the snippet token: root-owned,
`~/glahico/bot-token`.

### Phase 2

Unattended polling with a per-day run cap, once the queue is quiet
enough to trust.

## Email for the bot account

Current thinking (2026-10-01). What the address does, by job:

1. Registration + account recovery: rare mail, but the mailbox must stay
   under control for years. Dormant free mailboxes get deleted (Proton,
   Disroot after ~1 year; Gmail after 2), so a dedicated never-visited
   mailbox is a liability. Use an address on a mailbox Simon actively
   uses; a plus-address on the current personal account is fine (GitLab
   treats it as distinct and verifies it). Changing the account email
   later is trivial.
2. Notifications as wake-up signal: redundant with the to-do API; only
   useful if they land in an inbox Simon already reads. GitLab allows a
   separate notification email, so route via filter into the main inbox.
   Keep the global level at Participate (default): it is the only level
   that delivers review requests and comments on reviewed MRs. Custom
   only *adds* events on top of Participate, and On mention drops both.
   The price is mail for every push/merge/close on every reviewed MR;
   prune those with client-side filters, not in GitLab.
3. Follow-up discussion on posted reviews: participants get mail but no
   to-do unless mentioned. Email is the free feedback archive here; the
   alternative is polling notes on each reviewed MR.
4. IMAP / scripted consumption: not a requirement. Mail as trigger is
   wrong (spoofable; API must re-verify anyway). Possible later for
   archiving feedback. Webhooks are out (need Maintainer on ghc/ghc).

Conclusion: no separate mailbox, no paid provider. Durable address on
the active inbox + filter. Check whether the ghc group enforces 2FA for
members; if so, store recovery codes safely.

### Browser-free REVIEWED (only if the cosmetic state matters)

The internal endpoint needs a Rails session, not a browser. Options,
cheapest first:

1. curl with a cookie jar: GET `/users/sign_in`, extract
   `authenticity_token`, POST username/password (bot has no 2FA), then
   GET the MR page, read `<meta name="csrf-token">`, and POST
   `/<proj>/-/merge_requests/:iid/drafts/publish` with
   `reviewer_state=reviewed` and header `X-CSRF-Token`. About 15 lines
   of shell; password stored root-owned like the token. Risks: sign-in
   notification mails, instance rate limits or captcha on sign-in,
   session expiry (default 7 days idle; the remember-me cookie renews).
   Alternative to logging in: copy `_gitlab_session` and
   `remember_user_token` out of the bot Firefox profile's
   `cookies.sqlite`.
2. Playwright with headless Chromium and a saved storage state from one
   manual login. Heavier (Node), breaks on UI changes.
3. A browser-using agent. Slow, non-deterministic, not worth it for one
   POST.

All of this is throwaway once the instance reaches 19.2, so invest
minimally.

## Edge cases

- Bot removed as reviewer mid-run: treat as cancel, suppress the post.
- Draft MRs: reviewed like any other; say so in the docs.
- Optional later: a mention comment may carry `--prompt`-style hints
  ("pay attention to the FFI changes"). Leave out of the first announcement.

## References

GitLab source, branch `18-11-stable-ee` (what gitlab.haskell.org runs,
18.11.12 as of 2026-10-01):

- Re-request service, no state guard:
  https://gitlab.com/gitlab-org/gitlab/-/blob/18-11-stable-ee/app/services/merge_requests/request_review_service.rb
- Reviewer-state service, requires `update_merge_request`:
  https://gitlab.com/gitlab-org/gitlab/-/blob/18-11-stable-ee/app/services/merge_requests/update_reviewer_state_service.rb
- Draft note creation sets REVIEW_STARTED (`after_execute`):
  https://gitlab.com/gitlab-org/gitlab/-/blob/18-11-stable-ee/app/services/draft_notes/create_service.rb
- Browser publish endpoint with `reviewer_state` param:
  https://gitlab.com/gitlab-org/gitlab/-/blob/18-11-stable-ee/app/controllers/projects/merge_requests/drafts_controller.rb
- REST draft notes API (no `reviewer_state` in 18.11):
  https://gitlab.com/gitlab-org/gitlab/-/blob/18-11-stable-ee/lib/api/draft_notes.rb
- `update_merge_request` granted to author/assignees (IssuablePolicy)
  and Developers (ProjectPolicy):
  https://gitlab.com/gitlab-org/gitlab/-/blob/18-11-stable-ee/app/policies/issuable_policy.rb
- Sidebar hides the re-request icon for UNREVIEWED
  (`showRequestReviewButton`):
  https://gitlab.com/gitlab-org/gitlab/-/blob/18-11-stable-ee/app/assets/javascripts/sidebar/components/reviewers/uncollapsed_reviewer_list.vue
- Quick action `/request_review` (aliases `/assign_reviewer`,
  `/reviewer`):
  https://gitlab.com/gitlab-org/gitlab/-/blob/18-11-stable-ee/lib/gitlab/quick_actions/merge_request_actions.rb

GitLab 19.2 data point:

- REST `POST .../draft_notes/bulk_publish` gained `reviewer_state`
  (`reviewed`|`requested_changes`, no `approved`), `note`, `internal`.
  Added for Duo review agents; first shipped in v19.2.0 (June 2026
  commits, milestone 19.2):
  https://gitlab.com/gitlab-org/gitlab/-/merge_requests/237813
  Docs: https://docs.gitlab.com/api/draft_notes/
  Still needs `update_merge_request`, i.e. Developer.
- Once gitlab.haskell.org is on >= 19.2, `bot post` can set REVIEWED
  via the API; until then the browser is the only route to REVIEWED.

Docs and issues:

- Quick actions: https://docs.gitlab.com/user/project/quick_actions/
- MR reviews (reviewer states, re-request):
  https://docs.gitlab.com/user/project/merge_requests/reviews/
- To-dos API: https://docs.gitlab.com/api/todos/
- Duo Code Review (GitLab's own reviewer bot, for comparison):
  https://docs.gitlab.com/user/gitlab_duo/code_review/
- gitlab-org/gitlab#583745 Duo: re-request icon shown while review in
  progress. #517909 submit/re-request emit no webhook events. #543648
  show previous state after re-request.

## Open items

- Developer on ghc/ghc: requested 2026-10-01, awaiting the maintainer's
  answer. Start implementing `bot.hs` once it is in.
- `bot.hs run`: run glahico.hs synchronously, or only prepare state and
  print the command for a manual batch kick-off? Leaning to manual.
- Leave notification level at Participate; decide whether notifications
  go to Proton or Gmail, and set up client filters for push/merge noise.
- Where to document for GHC devs: wiki page first; MR template comment once proven.
