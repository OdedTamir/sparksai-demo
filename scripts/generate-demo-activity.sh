#!/usr/bin/env bash
# =============================================================================
# generate-demo-activity.sh
# Generates realistic demo activity in a GitHub repo so that PR Quality
# metrics and DORA metrics get populated. Designed to run inside GitHub
# Actions (uses the built-in GH_TOKEN). No local setup required.
#
# Each run simulates one "work day": a few PRs of varying sizes, each one
# opened -> reviewed -> merged, plus production deployments (mostly success,
# occasionally a failure followed by a recovery deployment).
# =============================================================================

set -euo pipefail

# --- Configuration (you can tune these) --------------------------------------
REPO="${GITHUB_REPOSITORY}"          # auto-filled by GitHub Actions: owner/repo
BASE_BRANCH="${BASE_BRANCH:-main}"   # your default branch
MIN_PRS=1                            # minimum PRs per run
MAX_PRS=3                            # maximum PRs per run
FAILURE_CHANCE=6                     # 1-in-N deployments is a failure+recovery
# -----------------------------------------------------------------------------

# Git identity for the demo commits
git config user.name  "demo-bot"
git config user.email "demo-bot@users.noreply.github.com"

# How many PRs to generate this run
NUM_PRS=$(( (RANDOM % (MAX_PRS - MIN_PRS + 1)) + MIN_PRS ))
echo ">>> This run will generate $NUM_PRS PR(s)."

for i in $(seq 1 "$NUM_PRS"); do
  echo "==================================================================="
  echo ">>> PR cycle $i of $NUM_PRS"

  # 1) Fresh branch off the base branch
  git checkout "$BASE_BRANCH" --quiet
  git pull --quiet origin "$BASE_BRANCH" || true
  BRANCH="demo/$(date +%s)-${i}-${RANDOM}"
  git checkout -b "$BRANCH" --quiet

  # 2) Choose a PR "size" bucket -> number of lines changed (drives PR Size)
  bucket=$(( RANDOM % 3 ))
  case $bucket in
    0) LINES=$(( (RANDOM % 20)  + 5   ));;   # small
    1) LINES=$(( (RANDOM % 120) + 40  ));;   # medium
    2) LINES=$(( (RANDOM % 400) + 200 ));;   # large
  esac
  echo ">>> Size bucket=$bucket -> $LINES lines"

  mkdir -p demo
  FILE="demo/activity_$(( RANDOM % 8 )).txt"
  for n in $(seq 1 "$LINES"); do
    echo "line $n - $(date +%s%N) - $RANDOM" >> "$FILE"
  done

  # 2b) Sometimes rewrite recently-touched lines -> drives Code Churn (rework)
  if (( RANDOM % 3 == 0 )); then
    EXISTING="$(ls demo/*.txt 2>/dev/null | head -n1 || true)"
    if [ -n "${EXISTING:-}" ] && [ "$EXISTING" != "$FILE" ]; then
      sed -i "1,5s/.*/reworked $(date +%s) $RANDOM/" "$EXISTING" || true
      echo ">>> Added some rework/churn to $EXISTING"
    fi
  fi

  # 3) Commit + push the branch
  git add -A
  git commit -m "demo: change set $i (${LINES} lines)" --quiet
  git push --quiet -u origin "$BRANCH"

  # 4) Open the PR (starts the Lead Time clock; counts toward PR volume)
  gh pr create \
    --base "$BASE_BRANCH" \
    --head "$BRANCH" \
    --title "Demo PR $i: update activity (${LINES} lines)" \
    --body "Automated demo PR to populate PR & DORA metrics."
  PR_NUM="$(gh pr list --head "$BRANCH" --base "$BASE_BRANCH" --json number --jq '.[0].number')"
  echo ">>> Opened PR #$PR_NUM"

  # 5) Wait a randomized interval, then leave a review (drives Pickup Time).
  #    NOTE: a bot cannot APPROVE its own PR, so we submit a COMMENT review,
  #    which is allowed and still registers as a review event.
  WAIT=$(( (RANDOM % 180) + 30 ))   # 30-210 seconds
  echo ">>> Waiting ${WAIT}s before review (simulated pickup time)..."
  sleep "$WAIT"
  gh api -X POST "repos/$REPO/pulls/$PR_NUM/reviews" \
    -f event=COMMENT \
    -f body="Reviewed by demo bot — looks good." >/dev/null || true

  # 6) Merge the PR (squash) and clean up the branch (closes Lead Time)
  gh pr merge "$PR_NUM" --squash --delete-branch || \
  gh pr merge "$PR_NUM" --squash --delete-branch --admin || true
  echo ">>> Merged PR #$PR_NUM"

  # 7) Create a production deployment (drives Deployment Frequency / Lead Time)
  git checkout "$BASE_BRANCH" --quiet
  git pull --quiet origin "$BASE_BRANCH" || true
  SHA="$(git rev-parse HEAD)"

  DEP_ID="$(gh api -X POST "repos/$REPO/deployments" --input - --jq '.id' <<JSON || true
{"ref":"$SHA","environment":"production","auto_merge":false,"required_contexts":[]}
JSON
)"

  if [ -n "${DEP_ID:-}" ] && [ "$DEP_ID" != "null" ]; then
    if (( RANDOM % FAILURE_CHANCE == 0 )); then
      # Inject a failed deployment...
      echo ">>> Simulating a FAILED deployment (Change Failure Rate)"
      gh api -X POST "repos/$REPO/deployments/$DEP_ID/statuses" \
        -f state="failure" -f environment="production" >/dev/null || true

      # ...then recover with a successful deployment a few minutes later
      REC=$(( (RANDOM % 180) + 120 ))   # 2-5 min recovery
      echo ">>> Recovering after ${REC}s (Failed Deployment Recovery Time)"
      sleep "$REC"
      REC_ID="$(gh api -X POST "repos/$REPO/deployments" --input - --jq '.id' <<JSON || true
{"ref":"$SHA","environment":"production","auto_merge":false,"required_contexts":[]}
JSON
)"
      if [ -n "${REC_ID:-}" ] && [ "$REC_ID" != "null" ]; then
        gh api -X POST "repos/$REPO/deployments/$REC_ID/statuses" \
          -f state="success" -f environment="production" >/dev/null || true
      fi
    else
      # Normal successful deployment
      gh api -X POST "repos/$REPO/deployments/$DEP_ID/statuses" \
        -f state="success" -f environment="production" >/dev/null || true
      echo ">>> Deployment succeeded"
    fi
  fi
done

echo ">>> Done. Generated $NUM_PRS PR(s) and matching deployments."
