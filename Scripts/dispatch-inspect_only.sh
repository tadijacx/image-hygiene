#!/usr/bin/env bash
set -euo pipefail

ACR_NAME="${ACR_NAME:-acxcr}"

# Mapping CSV 
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Which lookup CSV to use
MAP_FILE="${MAP_FILE:-${REPO_ROOT}/Maps/lookup-service.csv}"

# Age threshold 
STALE_DAYS="${STALE_DAYS:-20}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing '$1' in PATH"; exit 1; }; }

require az
require python3

if [[ ! -f "$MAP_FILE" ]]; then
  echo "❌ Mapping file not found: $MAP_FILE"
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
age_for_repo_prefix() {
  local acr_repo="$1"
  local prefix="$2"   # e.g. dev, stage, master (without trailing '-')

  # Use JMESPath to grab the first tag whose name starts with "<prefix>-"
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

# -------------------------
# Mode selection
# -------------------------

echo "Which environment do you want to inspect?"
echo "  1) dev-like (use dev_prefix column)"
echo "  2) prod-like (use prod_prefix column)"
echo "  3) both"
read -rp "Select [1-3]: " CHOICE

echo
echo "📄 Using mapping file: $MAP_FILE"
echo "🏷  Threshold: ${STALE_DAYS}d"
echo

run_for_mode() {
  local MODE="$1"   # "dev" or "prod"

  echo "🔎 Inspecting ${MODE} images"
  echo

  # Temp file to collect stale entries for summary
  local STALE_TMP
  STALE_TMP="$(mktemp)"

  # Columns: github_repo,acr_repo,chart_dir,prod_prefix,dev_prefix
  # Use process substitution so the while loop runs in current shell (not subshell)
  while IFS=',' read -r GH_REPO ACR_REPO CHART_DIR PROD_PREFIX DEV_PREFIX; do
    # Trim whitespace
    GH_REPO="${GH_REPO//[$'\r\t ']/}"
    ACR_REPO="${ACR_REPO//[$'\r\t ']/}"
    CHART_DIR="${CHART_DIR//[$'\r\t ']/}"
    PROD_PREFIX="${PROD_PREFIX//[$'\r\t ']/}"
    DEV_PREFIX="${DEV_PREFIX//[$'\r\t ']/}"

    # Some rows share the same GitHub repo; empty GH_REPO means "same as above"
    if [[ -z "$GH_REPO" ]]; then
      [[ -z "${LAST_GH_REPO:-}" ]] && continue
      GH_REPO="$LAST_GH_REPO"
    else
      LAST_GH_REPO="$GH_REPO"
    fi

    # Skip completely empty lines
    if [[ -z "$GH_REPO$ACR_REPO$CHART_DIR$PROD_PREFIX$DEV_PREFIX" ]]; then
      continue
    fi

    local PREFIX
    if [[ "$MODE" == "dev" ]]; then
      PREFIX="$DEV_PREFIX"
    else
      PREFIX="$PROD_PREFIX"
    fi

    # If prefix is empty or "/", nothing to check for this env
    if [[ -z "$PREFIX" || "$PREFIX" == "/" ]]; then
      continue
    fi

    local FULL_REPO="beacx/${GH_REPO}"
    echo "➡️  ${FULL_REPO} (acr: ${ACR_REPO}, chart: ${CHART_DIR}, prefix: ${PREFIX}-)"

    local RES
    RES="$(age_for_repo_prefix "$ACR_REPO" "$PREFIX")"

    # no-tags = "seed needed" -> treat as stale
    if [[ "$RES" == "no-tags" ]]; then
      echo "   • No tags found with prefix '${PREFIX}-' → treat as STALE (seed)"
      echo "${FULL_REPO} | acr=${ACR_REPO} | chart=${CHART_DIR} | prefix=${PREFIX}- | age=N/A | tag=<none>" >>"$STALE_TMP"
      echo
      continue
    fi

    local AGE TAG
    AGE="$(awk '{print $1}' <<<"$RES")"
    TAG="$(awk '{print $2}' <<<"$RES")"

    if (( AGE >= STALE_DAYS )); then
      echo "   • Latest tag: ${TAG} → age ${AGE}d → STALE (>= ${STALE_DAYS}d)"
      echo "${FULL_REPO} | acr=${ACR_REPO} | chart=${CHART_DIR} | prefix=${PREFIX}- | age=${AGE} | tag=${TAG}" >>"$STALE_TMP"
    else
      echo "   • Latest tag: ${TAG} → age ${AGE}d → fresh (< ${STALE_DAYS}d)"
    fi
    echo

  done < <(tail -n +2 "$MAP_FILE")

  # Summary of stale ones
  if [[ -s "$STALE_TMP" ]]; then
    echo "📉 Services with STALE ${MODE} images (>= ${STALE_DAYS}d or no-tags):"
    cat "$STALE_TMP"
  else
    echo "📈 No stale ${MODE} images found (all younger than ${STALE_DAYS}d)."
  fi

  rm -f "$STALE_TMP"

  echo
  echo "✅ Done scanning ${MODE}."
  echo
}

case "$CHOICE" in
  1) run_for_mode "dev" ;;
  2) run_for_mode "prod" ;;
  3) run_for_mode "dev"; run_for_mode "prod" ;;
  *) echo "❌ Invalid choice: $CHOICE"; exit 1 ;;
esac