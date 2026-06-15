#!/usr/bin/env bash
#
# update-operator.sh — sync the Helm chart to a SpiceDB Operator release.
#
# This codifies the manual runbook in CLAUDE.md ("Updating to a New SpiceDB
# Operator Version"). It is deterministic and idempotent: running it twice for
# the same target version produces no further changes.
#
# What it does:
#   1. Resolves the current chart appVersion and the target operator version.
#   2. Downloads both bundle.yaml files (current + target).
#   3. Regenerates templates/configmap-update-graph.yaml from the target bundle.
#   4. Detects "drift" — any change in the bundle diff OUTSIDE the update-graph
#      ConfigMap and the Deployment image tag (CRD/RBAC/ServiceAccount/Deployment
#      spec). Drift needs a human; the script writes a report and sets an output
#      flag rather than guessing.
#   5. Bumps Chart.yaml (version minor bump, appVersion, source URL).
#   6. Regenerates README.md via helm-docs (if on PATH).
#   7. Verifies with helm lint + helm template.
#
# Intended to run on a GitHub-hosted runner, which provides curl, helm, yq, and
# gh. It is driven by .github/workflows/update-operator.yml but is also safe to
# run by hand on a checkout, provided those tools are installed and gh is authed.
#
# Usage:
#   scripts/update-operator.sh [TARGET_VERSION]
#
#   TARGET_VERSION  Operator release tag (e.g. v1.25.1). If omitted, the latest
#                   release is resolved via `gh release view`.
#
# Outputs (when $GITHUB_OUTPUT is set, for use in GitHub Actions):
#   updated=true|false       whether the chart changed
#   current_version=vX.Y.Z   the chart's appVersion before the run
#   target_version=vX.Y.Z    the operator version synced to
#   chart_version=X.Y.Z      the new chart version
#   drift=true|false         whether structural drift was detected
#
# Artifacts written to $WORKDIR (default: a tmp dir):
#   bundle-current.yaml, bundle-target.yaml, drift-report.txt
#
set -euo pipefail

# --- Configuration -----------------------------------------------------------

REPO="authzed/spicedb-operator"
CHART_DIR="charts/spicedb-operator"
CHART_YAML="${CHART_DIR}/Chart.yaml"
CONFIGMAP_TEMPLATE="${CHART_DIR}/templates/configmap-update-graph.yaml"
BUNDLE_URL_TEMPLATE="https://github.com/${REPO}/releases/download/%s/bundle.yaml"

# Resolve repo root so the script works from any CWD.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORKDIR="${WORKDIR:-$(mktemp -d)}"
mkdir -p "$WORKDIR"

# --- Helpers -----------------------------------------------------------------

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

emit() {
  # emit KEY VALUE -> append to GITHUB_OUTPUT if set, else print.
  local key="$1" val="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$val" >> "$GITHUB_OUTPUT"
  fi
  log "output: ${key}=${val}"
}

require() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# --- Preconditions -----------------------------------------------------------

# This script targets GitHub-hosted runners, where curl, helm, yq, and gh are
# preinstalled. gh authenticates from GITHUB_TOKEN in the environment.
require curl
require helm
require yq
require gh
[ -f "$CHART_YAML" ] || die "not in chart repo root (missing $CHART_YAML)"
[ -f "$CONFIGMAP_TEMPLATE" ] || die "missing $CONFIGMAP_TEMPLATE"

# --- Resolve versions --------------------------------------------------------

# Current appVersion from Chart.yaml (read-only; yq does not rewrite the file).
CURRENT_VERSION="$(yq '.appVersion' "$CHART_YAML")"
[ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" != "null" ] \
  || die "could not parse appVersion from $CHART_YAML"

TARGET_VERSION="${1:-}"
if [ -z "$TARGET_VERSION" ]; then
  log "resolving latest release of ${REPO}..."
  # gh auto-authenticates from GITHUB_TOKEN in the environment.
  TARGET_VERSION="$(gh release view --repo "$REPO" --json tagName --jq '.tagName')"
  [ -n "$TARGET_VERSION" ] || die "could not resolve latest release tag"
fi

log "current appVersion: ${CURRENT_VERSION}"
log "target  appVersion: ${TARGET_VERSION}"

emit current_version "$CURRENT_VERSION"
emit target_version "$TARGET_VERSION"

if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ]; then
  log "chart is already at ${TARGET_VERSION}; nothing to do."
  emit updated false
  emit drift false
  emit chart_version "$(yq '.version' "$CHART_YAML")"
  exit 0
fi

# --- Download bundles --------------------------------------------------------

CURRENT_BUNDLE="${WORKDIR}/bundle-current.yaml"
TARGET_BUNDLE="${WORKDIR}/bundle-target.yaml"

bundle_url() {
  # shellcheck disable=SC2059  # the format string is a trusted constant
  printf "$BUNDLE_URL_TEMPLATE" "$1"
}

log "downloading current bundle (${CURRENT_VERSION})..."
curl -fsSL "$(bundle_url "$CURRENT_VERSION")" -o "$CURRENT_BUNDLE" \
  || die "failed to download bundle for ${CURRENT_VERSION}"
log "downloading target bundle (${TARGET_VERSION})..."
curl -fsSL "$(bundle_url "$TARGET_VERSION")" -o "$TARGET_BUNDLE" \
  || die "failed to download bundle for ${TARGET_VERSION}"

# --- Extract the update-graph ConfigMap data from a bundle -------------------
#
# The bundle is a multi-doc YAML. Exactly one ConfigMap carries the key
# `update-graph.yaml: |`. We extract the literal block scalar that follows it:
# every line until the indentation drops back to the ConfigMap's field level.
#
# The data lines are indented 4 spaces in the bundle (2 for the data: map key's
# child + 2 for the block content). We capture them verbatim — the chart
# template requires exactly this 4-space indent under `update-graph.yaml: |`.

extract_update_graph() {
  local bundle="$1"
  awk '
    # Find the line "  update-graph.yaml: |" (2-space indent, ConfigMap data key)
    /^  update-graph\.yaml: \|[[:space:]]*$/ { capture = 1; next }
    capture {
      # Block scalar content is indented deeper than the key (>= 4 spaces),
      # or is a blank line. Stop at the first line that is not.
      if ($0 ~ /^    / || $0 ~ /^[[:space:]]*$/) {
        print
      } else {
        capture = 0
      }
    }
  ' "$bundle"
}

TARGET_GRAPH="${WORKDIR}/target-graph.txt"
extract_update_graph "$TARGET_BUNDLE" > "$TARGET_GRAPH"
[ -s "$TARGET_GRAPH" ] || die "failed to extract update-graph from target bundle"

# Sanity: the extracted block must start with "    channels:" and contain the
# operator imageName line, otherwise our parse is wrong and we must not write.
head -1 "$TARGET_GRAPH" | grep -qE '^    channels:' \
  || die "extracted update-graph does not start with 'channels:' — parse failed"
grep -qE '^    imageName: ' "$TARGET_GRAPH" \
  || die "extracted update-graph missing 'imageName:' — parse failed"

# --- Regenerate the ConfigMap template ---------------------------------------

NEW_CONFIGMAP="${WORKDIR}/configmap-update-graph.yaml"
{
  cat <<'HEADER'
apiVersion: v1
kind: ConfigMap
metadata:
  name: update-graph
  labels:
    {{- include "spicedb-operator.labels" . | nindent 4 }}
data:
  update-graph.yaml: |
HEADER
  cat "$TARGET_GRAPH"
} > "$NEW_CONFIGMAP"

cp "$NEW_CONFIGMAP" "$CONFIGMAP_TEMPLATE"
log "regenerated ${CONFIGMAP_TEMPLATE}"

# --- Drift detection ---------------------------------------------------------
#
# We classify the bundle diff. Anything OUTSIDE the update-graph ConfigMap and
# the Deployment image tag is "drift" that a human must review (CRD/RBAC/SA/
# Deployment spec changes). We compute this by normalizing both bundles:
# replacing the update-graph block with a placeholder and the operator image
# tag with a placeholder, then diffing what remains.

normalize_bundle() {
  local bundle="$1"
  awk '
    /^  update-graph\.yaml: \|[[:space:]]*$/ { print "  update-graph.yaml: |__GRAPH_ELIDED__"; capture = 1; next }
    capture {
      if ($0 ~ /^    / || $0 ~ /^[[:space:]]*$/) { next }
      capture = 0
    }
    # Elide the operator image tag (templated from appVersion in the chart).
    { gsub(/spicedb-operator:v[0-9]+\.[0-9]+\.[0-9]+/, "spicedb-operator:__TAG__") }
    { print }
  ' "$bundle"
}

DRIFT_REPORT="${WORKDIR}/drift-report.txt"
normalize_bundle "$CURRENT_BUNDLE" > "${WORKDIR}/norm-current.yaml"
normalize_bundle "$TARGET_BUNDLE"  > "${WORKDIR}/norm-target.yaml"

DRIFT=false
if ! diff -u "${WORKDIR}/norm-current.yaml" "${WORKDIR}/norm-target.yaml" > "$DRIFT_REPORT"; then
  DRIFT=true
  log "DRIFT DETECTED: bundle changed outside the update-graph ConfigMap."
  log "  -> see ${DRIFT_REPORT}"
  log "  -> CRD/RBAC/ServiceAccount/Deployment-spec may need manual changes."
else
  log "no structural drift: only the update-graph and image tag changed."
  : > "$DRIFT_REPORT"
fi
emit drift "$DRIFT"

# --- Bump Chart.yaml ---------------------------------------------------------
#
# - version: minor bump (X.Y.Z -> X.(Y+1).0), per CLAUDE.md.
# - appVersion: target version.
# - source URL: point the authzed release-tag line at the target version.

CHART_VERSION="$(yq '.version' "$CHART_YAML")"
IFS='.' read -r CV_MAJOR CV_MINOR _CV_PATCH <<< "$CHART_VERSION"
[ -n "${CV_MAJOR:-}" ] && [ -n "${CV_MINOR:-}" ] || die "could not parse chart version: $CHART_VERSION"
NEW_CHART_VERSION="${CV_MAJOR}.$((CV_MINOR + 1)).0"

# NOTE: We deliberately use line-targeted sed here rather than `yq -i`. yq
# reserializes the whole document, which reflows Chart.yaml's list indentation
# and strips the blank lines between its commented sections — a noisy diff.
# sed changes only the three lines we intend and leaves the rest byte-for-byte
# untouched. tmp file + mv avoids sed -i portability issues.
tmp_chart="$(mktemp)"
sed -E \
  -e "s|^version:[[:space:]]*.*|version: ${NEW_CHART_VERSION}|" \
  -e "s|^appVersion:[[:space:]]*.*|appVersion: \"${TARGET_VERSION}\"|" \
  -e "s|(https://github.com/${REPO//\//\\/}/releases/tag/)v[0-9]+\.[0-9]+\.[0-9]+|\1${TARGET_VERSION}|" \
  "$CHART_YAML" > "$tmp_chart"
mv "$tmp_chart" "$CHART_YAML"
log "bumped chart version ${CHART_VERSION} -> ${NEW_CHART_VERSION}, appVersion -> ${TARGET_VERSION}"
emit chart_version "$NEW_CHART_VERSION"

# --- Regenerate README via helm-docs (best effort) ---------------------------

if command -v helm-docs >/dev/null 2>&1; then
  log "running helm-docs..."
  helm-docs >/dev/null 2>&1 || log "warning: helm-docs failed; README not regenerated"
else
  log "warning: helm-docs not on PATH; README not regenerated"
fi

# --- Verify ------------------------------------------------------------------

log "helm lint..."
helm lint "$CHART_DIR" >&2 || die "helm lint failed"
log "helm template..."
helm template ci-verify "$CHART_DIR" >/dev/null || die "helm template failed"

# Cross-check: the rendered update-graph must be byte-identical to the bundle.
RENDERED="${WORKDIR}/rendered.yaml"
helm template ci-verify "$CHART_DIR" > "$RENDERED"
# Extract the rendered update-graph block (same shape, but the data key is
# under a Source comment and may be release-name-prefixed metadata; the data
# block itself is identical 4-space-indented content).
awk '
  /^  update-graph\.yaml: \|[[:space:]]*$/ { capture = 1; next }
  capture {
    if ($0 ~ /^    / || $0 ~ /^[[:space:]]*$/) { print } else { capture = 0 }
  }
' "$RENDERED" > "${WORKDIR}/rendered-graph.txt"

# Strip trailing blank lines from both sides: Helm appends a trailing newline
# to the rendered block scalar, and our capture may pick up the blank line that
# precedes the next document. That is a rendering artifact, not a content diff.
strip_trailing_blanks() { sed -e :a -e '/^[[:space:]]*$/{$d;N;ba}' "$1"; }
strip_trailing_blanks "$TARGET_GRAPH" > "${WORKDIR}/target-graph.trim"
strip_trailing_blanks "${WORKDIR}/rendered-graph.txt" > "${WORKDIR}/rendered-graph.trim"

if ! diff -q "${WORKDIR}/target-graph.trim" "${WORKDIR}/rendered-graph.trim" >/dev/null; then
  die "rendered update-graph does not match the bundle — regeneration is wrong"
fi
log "verified: rendered update-graph is byte-identical to the bundle."

emit updated true
log "done: chart updated to ${TARGET_VERSION} (chart ${NEW_CHART_VERSION})."
