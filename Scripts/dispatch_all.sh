#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------
# Config
# -----------------------------------

# path to the dispatcher workflow in the repo
WORKFLOW_PATH=".github/workflows/dispatcher.yaml"

ACR_NAME="${ACR_NAME:-acxcr}"

# Mapping CSV 
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MAP_FILE="${MAP_FILE:-${REPO_ROOT}/Maps/lookup-service-non-ml.csv}"

# Age threshold to consider stale
STALE_DAYS="${STALE_DAYS:-30}"

# 1 = print 0 = actually dispatch 
DRY_RUN="${DRY_RUN:-1}"

# Optional reason for the dispatch 
INPUT_REASON="${1:-bulk refresh}"

# -----------------------------------
# Helpers
# -----------------------------------

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1' in PATH"; exit 1; }; }

require gh
require az
require python3

gh auth status >/dev/null

if [[ ! -f "$MAP_FILE" ]]; then
  echo "Mapping file not found: $MAP_FILE"
  exit 1
fi

# Convert ACR ISO timestamp -> age in days
age_from_ts() {
  local ts="$1"
  python3 - "$ts" <<'PY'
from datetime import datetime, timezone
import sys

s = sys.argv[1]
if '.' in s:
    head, tail = s.split('.', 1)
    tz = 'Z'
    for ch in ('+', '-'):
        if ch in tail:
            tz = tail[tail.rfind(ch):]
            break
    s = head + tz

s = s.replace('Z', '+00:00')
dt = datetime.fromisoformat(s)
now = datetime.now(timezone.utc)
print((now - dt).days)
PY
}

# Get age + tag for newest tag with given prefix in an ACR repo.
# Returns:
#   "no-tags"           if none
#   "<age> <tagname>"   if found
age_for_repo_prefix() {
  local acr_repo="$1"
  local prefix="$2"   # e.g. dev, stage, master, dev-api-service, ...

  local row
  row=$(
    az acr repository show-tags \
      -n "$ACR_NAME" \
      --repository "$acr_repo" \
      --orderby time_desc \
      --detail \
      --query "[?starts_with(@.name, '${prefix}-')]|[0].{name:name,time:lastUpdateTime}" \
      -o tsv 2>/dev/null || true
  )

  if [[ -z "$row" ]]; then
    echo "no-tags"
    return 0
  fi

  local tag ts
  tag="${row%%$'\t'*}"
  ts="${row#*$'\t'}"

  if [[ -z "$tag" || -z "$ts" ]]; then
    echo "no-tags"
    return 0
  fi

  local age
  age="$(age_from_ts "$ts")"
  echo "${age} ${tag}"
}

# Get repo default branch (where the workflow file is expected to live)
default_branch_for_repo() {
  local full_repo="$1" 
  gh repo view "$full_repo" --json defaultBranchRef -q .defaultBranchRef.name
}

# Derive the branch to build from based on the ACR tag prefix.
# For simple prefixes (dev, stage, staging, master, main) the prefix IS the branch.
# For compound prefixes like dev-api-service or master-api-interop, strip the suffix
# so the dispatcher receives the actual branch name (dev, master) as its ref input.
ref_branch_from_prefix() {
  local prefix="$1"
  echo "$prefix" | sed -E 's/-api-(service|interop)$//'
}

# -----------------------------------
# Mode selection
# dev = check dev-like prefixes (e.g. dev-, stage-, staging-) and build from that branch
# prod = check prod-like prefixes (e.g. master-, main-) and build from that branch
# -----------------------------------

echo "Which environment do you want to process?"
echo "  1) dev-like"
echo "  2) prod-like"
echo "  3) both"
read -rp "Select [1-3]: " CHOICE

echo
echo "Using mapping file: $MAP_FILE"
echo "Threshold: ${STALE_DAYS}d"
echo "DRY_RUN=${DRY_RUN} (0 = real dispatch, anything else = just print)"
echo "WORKFLOW_PATH=${WORKFLOW_PATH}"
echo

run_for_mode() {
  local MODE="$1"

  echo "Checking ${MODE} images"
  echo

  # Tracks (FULL_REPO:REF_BRANCH) pairs already dispatched this run.
  # Written to disk so the pipe subshell can share state with us.
  local DISPATCHED_FILE
  DISPATCHED_FILE="$(mktemp)"

  local LAST_GH_REPO=""

  tail -n +2 "$MAP_FILE" | \
  while IFS=',' read -r GH_REPO ACR_REPO CHART_DIR PROD_PREFIX DEV_PREFIX; do
    GH_REPO="${GH_REPO//[$'\r\t ']/}"
    ACR_REPO="${ACR_REPO//[$'\r\t ']/}"
    CHART_DIR="${CHART_DIR//[$'\r\t ']/}"
    PROD_PREFIX="${PROD_PREFIX//[$'\r\t ']/}"
    DEV_PREFIX="${DEV_PREFIX//[$'\r\t ']/}"

    if [[ -z "$GH_REPO" ]]; then
      [[ -z "$LAST_GH_REPO" ]] && continue
      GH_REPO="$LAST_GH_REPO"
    else
      LAST_GH_REPO="$GH_REPO"
    fi

    if [[ -z "$GH_REPO$ACR_REPO$CHART_DIR$PROD_PREFIX$DEV_PREFIX" ]]; then
      continue
    fi

    local PREFIX
    if [[ "$MODE" == "dev" ]]; then
      PREFIX="$DEV_PREFIX"
    else
      PREFIX="$PROD_PREFIX"
    fi

    if [[ -z "$PREFIX" || "$PREFIX" == "/" ]]; then
      continue
    fi

    # Branch to pass as ref input to the dispatcher (what to build from).
    # Derived from the ACR prefix: for most services prefix == branch name;
    # for compound prefixes (e.g. dev-api-service) strip the service suffix.
    local REF_BRANCH
    REF_BRANCH="$(ref_branch_from_prefix "$PREFIX")"

    local FULL_REPO="beacx/${GH_REPO}"
    echo "->   ${FULL_REPO} (acr: ${ACR_REPO}, chart: ${CHART_DIR}, prefix: ${PREFIX}-)"

    local DEFAULT_BRANCH
    DEFAULT_BRANCH="$(default_branch_for_repo "$FULL_REPO" 2>/dev/null || true)"
    if [[ -z "$DEFAULT_BRANCH" ]]; then
      echo "   Could not determine default branch for ${FULL_REPO} — skipping"
      echo
      continue
    fi
    echo "   • Using workflow from default branch: ${DEFAULT_BRANCH}"

    local RES
    RES="$(age_for_repo_prefix "$ACR_REPO" "$PREFIX")"

    local NEEDS_DISPATCH=0

    if [[ "$RES" == "no-tags" ]]; then
      echo "   • No tags found with prefix '${PREFIX}-' → STALE (seed)"
      NEEDS_DISPATCH=1
    else
      local AGE TAG
      AGE="$(awk '{print $1}' <<<"$RES")"
      TAG="$(awk '{print $2}' <<<"$RES")"

      if (( AGE >= STALE_DAYS )); then
        echo "   • Latest tag: ${TAG} → age ${AGE}d → STALE (>= ${STALE_DAYS}d)"
        NEEDS_DISPATCH=1
      else
        echo "   • Latest tag: ${TAG} → age ${AGE}d → fresh (< ${STALE_DAYS}d) — skipping"
      fi
    fi

    if (( NEEDS_DISPATCH )); then
      # Dedup key: one dispatch per (repo, ref_branch) regardless of how many
      # CSV rows the repo has (e.g. internal-api has 2 rows, one per k8s chart).
      local DISPATCH_KEY="${FULL_REPO}:${REF_BRANCH}"

      if grep -qF "$DISPATCH_KEY" "$DISPATCHED_FILE" 2>/dev/null; then
        echo "   • Already dispatched for ${FULL_REPO} ref=${REF_BRANCH} this run — skipping duplicate"
      else
        if [[ "$DRY_RUN" -eq 0 ]]; then
          echo "   Dispatching..."
          gh workflow run "$WORKFLOW_PATH" \
            -R "$FULL_REPO" \
            -r "$DEFAULT_BRANCH" \
            -f ref="$REF_BRANCH" \
            -f reason="$INPUT_REASON"
          echo "$DISPATCH_KEY" >> "$DISPATCHED_FILE"
        else
          echo "   DRY_RUN: would dispatch workflow for ${FULL_REPO} (use-workflow-from=${DEFAULT_BRANCH}, ref=${REF_BRANCH})"
          echo "$DISPATCH_KEY" >> "$DISPATCHED_FILE"  # dedup applies in dry-run too
        fi
      fi
    fi

    echo
  done

  rm -f "$DISPATCHED_FILE"
  echo "Done scanning ${MODE}."
  echo
}


case "$CHOICE" in
  1) run_for_mode "dev" ;;
  2) run_for_mode "prod" ;;
  3) run_for_mode "dev"; run_for_mode "prod" ;;
  *) echo "Invalid choice: $CHOICE"; exit 1 ;;
esac
