#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# bump.sh 
# 
# Reads lookup_service CSV rows: github_repo,acr_repo,chart_dir,prod_prefix,dev_prefix
# For each row, finds the current k8s referenced tag in the chart values file, derives
# the prefix from that tag, then bumps to the newest ACR tag for that prefix.
#
# Creates a PR in the k8s repo for the selected environment(s).
# ------------------------------------------------------------

# -----------------------
# Config
# -----------------------
ACR_NAME="${ACR_NAME:-acxcr}"
DEVOPS_REPO="${DEVOPS_REPO:-beacx/acx-kubernetes-app}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MAP_FILE="${MAP_FILE:-${REPO_ROOT}/Maps/lookup-service.csv}"

# Bump behavior
DRY_RUN="${DRY_RUN:-0}"          # 1 = no changes/PR, 0 = create PR
DEFAULT_BASE_BRANCH_DEV="dev"
DEFAULT_BASE_BRANCH_PROD="master"

# -----------------------
# Helpers
# -----------------------
require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1' in PATH"; exit 1; }; }

require gh
require az
require git
require python3

gh auth status >/dev/null 2>&1 || { echo "gh not authenticated"; exit 1; }

if [[ ! -f "$MAP_FILE" ]]; then
  echo "Mapping file not found: $MAP_FILE"
  exit 1
fi

read_current_tag() {
  local values_path="$1"
  [[ -f "$values_path" ]] || { echo ""; return 0; }
  grep -E '^[[:space:]]*tag:[[:space:]]*' "$values_path" \
    | head -n 1 \
    | awk -F'tag:' '{print $2}' \
    | tr -d ' "' \
    | tr -d $'\r' \
    || true
}

# Find a values file for a chart for a given MODE (dev-like or prod-like)
# Preference order:
#   dev-like:  values-dev.yaml, values-stage.yaml, values-staging.yaml, values-master.yaml, values-prod.yaml
#   prod-like: values-prod.yaml, values-master.yaml, values-stage.yaml, values-staging.yaml, values-dev.yaml
find_values_file_for_mode() {
  local chart_dir="$1"
  local mode="$2"   # dev or prod

  local base="charts/${chart_dir}"

  local candidates=()
  if [[ "$mode" == "dev" ]]; then
    candidates=(
      "${base}/values-dev.yaml"
      "${base}/values-stage.yaml"
      "${base}/values-staging.yaml"
      "${base}/values-master.yaml"
      "${base}/values-prod.yaml"
    )
  else
    candidates=(
      "${base}/values-prod.yaml"
      "${base}/values-master.yaml"
      "${base}/values-stage.yaml"
      "${base}/values-staging.yaml"
      "${base}/values-dev.yaml"
    )
  fi

  local f
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done

  # last resort: first values-*.yaml
  local any
  any="$(ls -1 "${base}"/values-*.yaml 2>/dev/null | head -n 1 || true)"
  [[ -n "$any" ]] && { echo "$any"; return 0; }

  return 1
}

# Derive prefix from current tag using your convention: <prefix>-<7sha>[-vN]
derive_prefix_from_tag() {
  local tag="$1"
  local s="$tag"

  # Strip optional version suffix like -v2, -v10
  s="$(echo "$s" | sed -E 's/-v[0-9]+$//')"

  # Strip trailing short sha (7 hex) if present
  local no_sha
  no_sha="$(echo "$s" | sed -E 's/-[0-9a-fA-F]{7}$//')"

  if [[ "$no_sha" != "$s" ]]; then
    echo "$no_sha"
    return 0
  fi

  echo ""
  return 0
}

# Latest tag in ACR for a given repo + derived prefix
latest_acr_tag_for_prefix() {
  local acr_repo="$1"
  local prefix="$2"

  az acr repository show-tags \
    -n "$ACR_NAME" \
    --repository "$acr_repo" \
    --orderby time_desc \
    -o tsv 2>/dev/null \
  | awk -v p="${prefix}-" '$1 ~ "^"p {print $1}' \
  | head -n 1 || true
}

# Update tag line in-place using python 
# Replaces the FIRST matching tag line that contains CURRENT_TAG.
update_values_tag_in_place() {
  local file="$1"
  local current_tag="$2"
  local new_tag="$3"

  python3 - <<PY
from pathlib import Path
import re

path = Path(r"""$file""")
current = r"""$current_tag"""
new = r"""$new_tag"""

txt = path.read_text()

# Handles: tag: abc, tag: "abc", tag: 'abc' (preserves indentation + quote style)
pattern = r'(^[ \t]*tag:[ \t]*)(["\']?)' + re.escape(current) + r'\\2([ \t]*$)'
out, n = re.subn(pattern, r'\\1\\2' + new + r'\\2\\3', txt, count=1, flags=re.M)

if n == 0:
    raise SystemExit(f"Could not find tag line matching current tag '{current}' in {path}")

path.write_text(out)
PY
}

# -----------------------
# Main bump function
# -----------------------
bump_for_mode() {
  local MODE="$1"         # dev or prod
  local BASE_BRANCH="$2"  # dev or master

  echo
  echo "=============================="
  echo "Bump mode: ${MODE}-like  (k8s branch: ${BASE_BRANCH})"
  echo "DRY_RUN=${DRY_RUN}"
  echo "MAP_FILE=${MAP_FILE}"
  echo "=============================="
  echo

  # temporary workdir to clone k8s repo and create PR
  local WORKDIR
  WORKDIR="$(mktemp -d)"
  cd "$WORKDIR"

  gh repo clone "$DEVOPS_REPO" repo -- --quiet
  cd repo

  git checkout "$BASE_BRANCH" >/dev/null 2>&1
  git pull origin "$BASE_BRANCH" -q || true

  local -a CHANGED_FILES=()
  local -a CHANGE_SUMMARY=()

  local LAST_GH_REPO=""

  # do NOT pipe into while (subshell) — use process substitution
  while IFS=',' read -r GH_REPO ACR_REPO CHART_DIR PROD_PREFIX DEV_PREFIX; do
    GH_REPO="${GH_REPO//[$'\r\t ']/}"
    ACR_REPO="${ACR_REPO//[$'\r\t ']/}"
    CHART_DIR="${CHART_DIR//[$'\r\t ']/}"
    PROD_PREFIX="${PROD_PREFIX//[$'\r\t ']/}"
    DEV_PREFIX="${DEV_PREFIX//[$'\r\t ']/}"

    # fill-down github_repo
    if [[ -z "$GH_REPO" ]]; then
      [[ -z "$LAST_GH_REPO" ]] && continue
      GH_REPO="$LAST_GH_REPO"
    else
      LAST_GH_REPO="$GH_REPO"
    fi

    # skip empty line
    if [[ -z "$GH_REPO$ACR_REPO$CHART_DIR$PROD_PREFIX$DEV_PREFIX" ]]; then
      continue
    fi

    local FULL_REPO="beacx/${GH_REPO}"

    local VALUES_PATH
    if ! VALUES_PATH="$(find_values_file_for_mode "$CHART_DIR" "$MODE")"; then
      echo "->  ${FULL_REPO} (acr: ${ACR_REPO}, chart: ${CHART_DIR})"
      echo "   No values-*.yaml found under charts/${CHART_DIR} — skipping"
      echo
      continue
    fi

    local CURRENT_TAG
    CURRENT_TAG="$(read_current_tag "$VALUES_PATH")"
    if [[ -z "$CURRENT_TAG" ]]; then
      echo "->  ${FULL_REPO} (acr: ${ACR_REPO}, chart: ${CHART_DIR})"
      echo "   Could not read current tag from ${VALUES_PATH} — skipping"
      echo
      continue
    fi

    local PREFIX
    PREFIX="$(derive_prefix_from_tag "$CURRENT_TAG")"
    if [[ -z "$PREFIX" ]]; then
      echo "->  ${FULL_REPO} (acr: ${ACR_REPO}, chart: ${CHART_DIR})"
      echo "   Could not derive prefix from current tag '${CURRENT_TAG}' (file: $(basename "$VALUES_PATH")) — skipping"
      echo
      continue
    fi

    echo "->  ${FULL_REPO} (acr: ${ACR_REPO}, chart: ${CHART_DIR}, prefix: ${PREFIX}-)"
    echo "   • Current tag in k8s ($(basename "$VALUES_PATH")): ${CURRENT_TAG}"

    local LATEST_TAG
    LATEST_TAG="$(latest_acr_tag_for_prefix "$ACR_REPO" "$PREFIX")"

    if [[ -z "$LATEST_TAG" ]]; then
      echo "   No tags found in ACR for prefix '${PREFIX}-' — skipping"
      echo
      continue
    fi

    echo "   • Latest tag in ACR: ${LATEST_TAG}"

    if [[ "$CURRENT_TAG" == "$LATEST_TAG" ]]; then
      echo "   Already up to date — skipping"
      echo
      continue
    fi

    if [[ "$DRY_RUN" -ne 0 ]]; then
      echo "   DRY_RUN: would update $(basename "$VALUES_PATH") → ${CURRENT_TAG} -> ${LATEST_TAG}"
      echo
      continue
    fi

    echo "   Updating ${VALUES_PATH}..."
    update_values_tag_in_place "$VALUES_PATH" "$CURRENT_TAG" "$LATEST_TAG"

    CHANGED_FILES+=("$VALUES_PATH")
    CHANGE_SUMMARY+=("- ${GH_REPO} (${CHART_DIR}): ${CURRENT_TAG} -> ${LATEST_TAG}")

    echo "   Updated"
    echo
  done < <(tail -n +2 "$MAP_FILE")

  if [[ "${#CHANGED_FILES[@]}" -eq 0 ]]; then
    echo "No services needed bumps for ${MODE}-like (${BASE_BRANCH})."
    return 0
  fi

  if [[ "$DRY_RUN" -ne 0 ]]; then
    echo "DRY_RUN complete. Would change:"
    printf ' - %s\n' "${CHANGE_SUMMARY[@]}"
    return 0
  fi

  local BRANCH_NAME="image-bump/${MODE}-$(date -u +%Y%m%d-%H%M%S)"
  echo "Creating branch: $BRANCH_NAME"
  git checkout -b "$BRANCH_NAME" >/dev/null 2>&1

  git add "${CHANGED_FILES[@]}"

  git -c user.name="image-updater-bot" \
      -c user.email="image-updater@example.com" \
      commit -q -m "chore: bump ${MODE}-like image tags ($(date -u +%Y-%m-%d))"

  git push -q --set-upstream origin "$BRANCH_NAME"
  echo "⬆ Pushed branch: $BRANCH_NAME"

  local PR_TITLE="chore: bump ${MODE}-like image tags"
  local PR_BODY
  PR_BODY=$(
    cat <<EOF
Automated image tag bumps for ${MODE}-like (${BASE_BRANCH}).

Updated charts:
$(printf '%s\n' "${CHANGE_SUMMARY[@]}")

Generated by bump.sh (map-driven). Review and merge to roll out via Argo CD.
EOF
  )

  echo "Creating PR..."
  local PR_OUTPUT
  if ! PR_OUTPUT=$(gh pr create \
        --base "$BASE_BRANCH" \
        --head "$BRANCH_NAME" \
        --title "$PR_TITLE" \
        --body "$PR_BODY" 2>&1); then
    echo "Failed to create PR:"
    echo "$PR_OUTPUT"
    return 1
  fi

  local PR_URL
  PR_URL=$(grep -Eo 'https://github.com[^\s]+' <<<"$PR_OUTPUT" | tail -1 || true)

  if [[ -n "$PR_URL" ]]; then
    echo "Done. PR created: $PR_URL"
  else
    echo "Done. PR created against ${DEVOPS_REPO}:${BASE_BRANCH}."
  fi
}

# -----------------------
# Menu
# -----------------------
echo "Which environment do you want to bump?"
echo "  1) dev-like   (k8s branch: ${DEFAULT_BASE_BRANCH_DEV})"
echo "  2) prod-like  (k8s branch: ${DEFAULT_BASE_BRANCH_PROD})"
echo "  3) both"
read -rp "Select [1-3]: " CHOICE

case "$CHOICE" in
  1) bump_for_mode "dev"  "$DEFAULT_BASE_BRANCH_DEV" ;;
  2) bump_for_mode "prod" "$DEFAULT_BASE_BRANCH_PROD" ;;
  3) bump_for_mode "dev"  "$DEFAULT_BASE_BRANCH_DEV"
     bump_for_mode "prod" "$DEFAULT_BASE_BRANCH_PROD" ;;
  *) echo "Invalid choice: $CHOICE"; exit 1 ;;
esac