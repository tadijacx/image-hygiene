#!/usr/bin/env bash
set -euo pipefail

# Config
ACR_NAME="${ACR_NAME:-acxcr}"
DEVOPS_REPO="${DEVOPS_REPO:-beacx/acx-kubernetes-app}"

# Mapping CSV
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MAP_FILE="${MAP_FILE:-${REPO_ROOT}/Maps/lookup_service-dev.csv}"

# How many tags per env to keep (current + backups)
KEEP_COUNT="${KEEP_COUNT:-3}"

# 1 - no delete; 0 = delete
DRY_RUN="${DRY_RUN:-1}"

# must manually flip to 1 to delete
ALLOW_REAL_DELETE=0

# Which k8s branches to read
K8S_BRANCH_DEVLIKE="${K8S_BRANCH_DEVLIKE:-dev}"
K8S_BRANCH_DEV_EASTUS="${K8S_BRANCH_DEV_EASTUS:-dev-eastus}"
K8S_BRANCH_PRODLIKE="${K8S_BRANCH_PRODLIKE:-master}"

# Helpers
require() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing '$1' in PATH"; exit 1; }; }

require az
require gh
require git

if [[ ! -f "$MAP_FILE" ]]; then
  echo "❌ Mapping file not found: $MAP_FILE"
  exit 1
fi

gh auth status >/dev/null 2>&1 || { echo "❌ gh not authenticated"; exit 1; }

# Read the first "tag:" value from yaml content (stdin)
read_current_tag_from_stdin() {
  grep -E '^[[:space:]]*tag:[[:space:]]*' \
    | head -n 1 \
    | awk -F'tag:' '{print $2}' \
    | tr -d ' "' \
    | tr -d $'\r' \
    || true
}

# Read the first "tag:" value from a yaml file (working tree)
read_current_tag() {
  local values_path="$1"
  [[ -f "$values_path" ]] || { echo ""; return 0; }
  read_current_tag_from_stdin < "$values_path"
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

# --- Read values files in another git ref (no checkout needed) ---
# Returns relative path like charts/<chart_dir>/values-xxx.yaml
find_values_file_for_mode_in_ref() {
  local chart_dir="$1"
  local mode="$2"     # dev or prod
  local ref="$3"      # e.g. origin/dev, origin/master

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
    if git cat-file -e "${ref}:${f}" 2>/dev/null; then
      echo "$f"
      return 0
    fi
  done

  # last resort: first values-*.yaml in that ref (if any)
  local any
  any="$(
    git ls-tree -r --name-only "$ref" "${base}" 2>/dev/null \
      | grep -E "^${base}/values-.*\.ya?ml$" \
      | head -n 1 || true
  )"
  [[ -n "$any" ]] && { echo "$any"; return 0; }

  return 1
}

# Read tag from a file in another git ref
read_current_tag_from_ref() {
  local ref="$1"         # e.g. origin/master
  local values_path="$2" # relative path in repo

  git cat-file -e "${ref}:${values_path}" 2>/dev/null || { echo ""; return 0; }
  git show "${ref}:${values_path}" 2>/dev/null | read_current_tag_from_stdin
}

# Derive the prefix from a tag (expects: <prefix>-<7sha>[-vN])
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

# List tags for ACR repo + prefix, newest → oldest
list_tags_for_prefix() {
  local acr_repo="$1"
  local prefix="$2"
  az acr repository show-tags \
    -n "$ACR_NAME" \
    --repository "$acr_repo" \
    --orderby time_desc \
    -o tsv 2>/dev/null \
  | awk -v p="${prefix}-" '$1 ~ "^"p {print $1}'
}

# ---------- Choose env ----------
echo "Which environment do you want to clean up?"
echo "  1) dev-like"
echo "  2) prod-like"
echo "  3) both"
read -rp "Select [1-3]: " CHOICE

echo
echo "📄 Using mapping file: $MAP_FILE"
echo "🧪 DRY_RUN=$DRY_RUN, KEEP_COUNT=$KEEP_COUNT"
echo "🔒 ALLOW_REAL_DELETE=$ALLOW_REAL_DELETE (must be 1 + DRY_RUN=0 to delete)"
echo "🌍 ACR_NAME=$ACR_NAME"
echo "📦 DEVOPS_REPO=$DEVOPS_REPO"
echo "🌿 Protecting tags from branches: $K8S_BRANCH_PRODLIKE, $K8S_BRANCH_DEVLIKE, $K8S_BRANCH_DEV_EASTUS"
echo

# ---------- Clone k8s repo once ----------
WORKDIR="$(mktemp -d)"
echo "📁 Working in $WORKDIR"
gh repo clone "$DEVOPS_REPO" "$WORKDIR/repo" >/dev/null 2>&1
cd "$WORKDIR/repo"

# Pre-fetch branches so we can read tags by ref
git fetch origin "$K8S_BRANCH_DEVLIKE" >/dev/null 2>&1 || true
git fetch origin "$K8S_BRANCH_DEV_EASTUS" >/dev/null 2>&1 || true
git fetch origin "$K8S_BRANCH_PRODLIKE" >/dev/null 2>&1 || true

# Helper: read the "current tag" for a chart from a given branch ref,
# using a mode-specific values-file preference.
read_tag_for_branch() {
  local chart_dir="$1"
  local branch="$2"   # e.g. dev, dev-eastus, master
  local ref="origin/${branch}"

  local mode="dev"
  if [[ "$branch" == "$K8S_BRANCH_PRODLIKE" ]]; then
    mode="prod"
  fi

  local values_path tag
  values_path="$(find_values_file_for_mode_in_ref "$chart_dir" "$mode" "$ref" || true)"
  [[ -z "$values_path" ]] && { echo ""; return 0; }

  tag="$(read_current_tag_from_ref "$ref" "$values_path")"
  [[ -n "$tag" ]] && echo "$tag" || echo ""
}

cleanup_for_mode() {
  local MODE="$1"        # dev or prod
  local K8S_BRANCH="$2"  # branch to checkout for the run (display/baseline)

  echo
  echo "=============================="
  echo "🔎 ${MODE}-like cleanup (k8s branch: ${K8S_BRANCH})"
  echo "   (protecting tags referenced by: ${K8S_BRANCH_PRODLIKE}, ${K8S_BRANCH_DEVLIKE}, ${K8S_BRANCH_DEV_EASTUS})"
  echo "=============================="
  echo

  git checkout "$K8S_BRANCH" >/dev/null 2>&1 || true
  git pull origin "$K8S_BRANCH" >/dev/null 2>&1 || true

  local LAST_GH_REPO=""

  tail -n +2 "$MAP_FILE" | \
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

    # skip empty
    if [[ -z "$GH_REPO$ACR_REPO$CHART_DIR$PROD_PREFIX$DEV_PREFIX" ]]; then
      continue
    fi

    local FULL_REPO="beacx/${GH_REPO}"

    # Primary current tag (from the branch you're "running" against)
    local VALUES_PATH CURRENT_TAG
    if ! VALUES_PATH="$(find_values_file_for_mode "$CHART_DIR" "$MODE")"; then
      echo "➡️  ${FULL_REPO} (acr: ${ACR_REPO})"
      echo "   ⚠️  No values-*.yaml found under charts/${CHART_DIR} — skipping"
      echo
      continue
    fi

    CURRENT_TAG="$(read_current_tag "$VALUES_PATH")"
    if [[ -z "$CURRENT_TAG" ]]; then
      echo "➡️  ${FULL_REPO} (acr: ${ACR_REPO})"
      echo "   ⚠️  Could not read current tag from ${VALUES_PATH} — skipping"
      echo
      continue
    fi

    # Derive prefix from the CURRENT_TAG (this controls which ACR tag-set we clean)
    local DERIVED_PREFIX
    DERIVED_PREFIX="$(derive_prefix_from_tag "$CURRENT_TAG")"
    if [[ -z "$DERIVED_PREFIX" ]]; then
      echo "➡️  ${FULL_REPO} (acr: ${ACR_REPO})"
      echo "   ⚠️  Could not derive prefix from current tag '${CURRENT_TAG}' (file: $(basename "$VALUES_PATH")) — skipping"
      echo
      continue
    fi

    echo "➡️  ${FULL_REPO} (acr: ${ACR_REPO}, prefix: ${DERIVED_PREFIX}-)"
    echo "   • Current tag in k8s (${K8S_BRANCH}, $(basename "$VALUES_PATH")): ${CURRENT_TAG}"

    # Read referenced tags from ALL protected branches
    local TAG_DEV TAG_EASTUS TAG_PROD
    TAG_DEV="$(read_tag_for_branch "$CHART_DIR" "$K8S_BRANCH_DEVLIKE")"
    TAG_EASTUS="$(read_tag_for_branch "$CHART_DIR" "$K8S_BRANCH_DEV_EASTUS")"
    TAG_PROD="$(read_tag_for_branch "$CHART_DIR" "$K8S_BRANCH_PRODLIKE")"

    # Print order: master, dev, dev-eastus
    echo "   • k8s referenced tags:"
    echo "       - ${K8S_BRANCH_PRODLIKE}:    ${TAG_PROD:-<not found>}"
    echo "       - ${K8S_BRANCH_DEVLIKE}:     ${TAG_DEV:-<not found>}"
    echo "       - ${K8S_BRANCH_DEV_EASTUS}:  ${TAG_EASTUS:-<not found>}"

    # Pull all ACR tags for this prefix
    local ALL_TAGS=()
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      ALL_TAGS+=("$tag")
    done < <(list_tags_for_prefix "$ACR_REPO" "$DERIVED_PREFIX" || true)

    if (( ${#ALL_TAGS[@]} == 0 )); then
      echo "   • Found 0 tags for ${ACR_REPO} with prefix '${DERIVED_PREFIX}-'"
      echo "   ℹ️  Nothing to clean."
      echo
      continue
    fi

    echo "   • Found ${#ALL_TAGS[@]} tags for ${ACR_REPO} with prefix '${DERIVED_PREFIX}-'"

        # ---- PROTECTED tags (ALWAYS init; safe under set -u) ----
    local -a PROTECTED
    PROTECTED=()

    add_protected() {
      local val="$1"
      [[ -z "$val" ]] && return 0

      # If PROTECTED has entries, enforce uniqueness
      if (( ${#PROTECTED[@]} > 0 )); then
        local x
        for x in "${PROTECTED[@]}"; do
          [[ "$x" == "$val" ]] && return 0
        done
      fi

      PROTECTED+=("$val")
    }

    # Always protect CURRENT_TAG if it matches the prefix-set we are cleaning
    [[ "$CURRENT_TAG" == "${DERIVED_PREFIX}-"* ]] && add_protected "$CURRENT_TAG"

    # Protect other branches IF they share the same prefix
    [[ -n "${TAG_PROD:-}"   && "$TAG_PROD"   == "${DERIVED_PREFIX}-"* ]] && add_protected "$TAG_PROD"
    [[ -n "${TAG_DEV:-}"    && "$TAG_DEV"    == "${DERIVED_PREFIX}-"* ]] && add_protected "$TAG_DEV"
    [[ -n "${TAG_EASTUS:-}" && "$TAG_EASTUS" == "${DERIVED_PREFIX}-"* ]] && add_protected "$TAG_EASTUS"

    if (( ${#PROTECTED[@]} == 0 )); then
      echo "   ⚠️  No protected tags matched prefix '${DERIVED_PREFIX}-' — skipping deletion for safety"
      echo
      continue
    fi

    echo "   • Protected tags: ${PROTECTED[*]}"

    # (1) Change behavior: warn if protected tag not present in ACR list, but DO NOT skip
    local p found t
    for p in "${PROTECTED[@]}"; do
      found=0
      for t in "${ALL_TAGS[@]}"; do
        [[ "$t" == "$p" ]] && found=1 && break
      done
      if (( found == 0 )); then
        echo "   ⚠️  Protected tag '${p}' not found in ACR tag list for prefix '${DERIVED_PREFIX}-' — continuing anyway"
      fi
    done

    # KEEP_TAGS:
    #  1) include PROTECTED tags (only those that exist in ALL_TAGS)
    #  2) fill with newest tags until KEEP_COUNT
    local KEEP_TAGS=()
    local DELETE_TAGS=()

    # include protected (only if present in ACR list)
    for p in "${PROTECTED[@]}"; do
      for t in "${ALL_TAGS[@]}"; do
        if [[ "$t" == "$p" ]]; then
          KEEP_TAGS+=("$t")
          break
        fi
      done
    done

    # fill newest until KEEP_COUNT
    for t in "${ALL_TAGS[@]}"; do
      local already=0
      local k
      for k in "${KEEP_TAGS[@]}"; do
        [[ "$k" == "$t" ]] && already=1 && break
      done
      (( already == 1 )) && continue

      KEEP_TAGS+=("$t")
      (( ${#KEEP_TAGS[@]} >= KEEP_COUNT )) && break
    done

    # delete is ALL - KEEP
    for t in "${ALL_TAGS[@]}"; do
      local keep=0
      local k
      for k in "${KEEP_TAGS[@]}"; do
        [[ "$k" == "$t" ]] && keep=1 && break
      done
      (( keep == 0 )) && DELETE_TAGS+=("$t")
    done

    echo "   ✅ Keeping (${#KEEP_TAGS[@]}): ${KEEP_TAGS[*]}"

    if (( ${#DELETE_TAGS[@]} == 0 )); then
      echo "   ℹ️ Nothing to delete."
      echo
      continue
    fi

    echo "   🗑  Would delete (${#DELETE_TAGS[@]}): ${DELETE_TAGS[*]}"

    if [[ "$DRY_RUN" -ne 0 ]]; then
      echo "   💡 DRY_RUN=1, not actually deleting anything."
      echo
      continue
    fi

    if [[ "$ALLOW_REAL_DELETE" -ne 1 ]]; then
      echo "   🔒 Real deletion disabled (ALLOW_REAL_DELETE=0). Edit script to enable."
      echo
      continue
    fi

    for t in "${DELETE_TAGS[@]}"; do
      echo "   🔥 Deleting ${ACR_REPO}:${t} ..."
      az acr repository delete \
        -n "$ACR_NAME" \
        --image "${ACR_REPO}:${t}" \
        --yes >/dev/null
    done

    echo "   ✅ Cleanup done."
    echo
  done

  echo "✅ Finished ${MODE}-like simulated cleanup for k8s branch '${K8S_BRANCH}'."
  echo
}

case "$CHOICE" in
  1) cleanup_for_mode "dev"  "$K8S_BRANCH_DEVLIKE" ;;
  2) cleanup_for_mode "prod" "$K8S_BRANCH_PRODLIKE" ;;
  3)
    cleanup_for_mode "dev"  "$K8S_BRANCH_DEVLIKE"
    cleanup_for_mode "prod" "$K8S_BRANCH_PRODLIKE"
    ;;
  *) echo "❌ Invalid choice: $CHOICE"; exit 1 ;;
esac