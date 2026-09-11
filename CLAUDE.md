# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository provides a Helm chart for deploying the [SpiceDB Operator](https://github.com/authzed/spicedb-operator) to Kubernetes.

## Chart Structure

The chart lives under `charts/spicedb-operator/`. Key files:

- `Chart.yaml` — chart version and `appVersion` (the SpiceDB Operator release tag)
- `values.yaml` — default values; `installCRDs: true` puts the CRD in templates (not `crds/`)
- `templates/crds/authzed.com_spicedbclusters.yaml` — SpiceDBCluster CRD, conditionally installed via `installCRDs` value. This is intentionally in `templates/` (not `crds/`) to preserve Helm upgrade behavior from chart 2.0.0.
- `templates/configmap-update-graph.yaml` — large ConfigMap containing the operator's update graph (version compatibility matrix)
- `templates/deployment.yaml` — operator deployment, runs with `--crd=false` since the CRD is managed by Helm
- `README.md.gotmpl` — template for [helm-docs](https://github.com/norwoodj/helm-docs). When this file or `Chart.yaml` changes, run `helm-docs` to regenerate `README.md`.

## Common Commands

```shell
# Lint the chart
helm lint charts/spicedb-operator/

# Template render (dry-run)
helm template my-release charts/spicedb-operator/

# Template with custom values
helm template my-release charts/spicedb-operator/ -f custom-values.yaml

# Package the chart
helm package charts/spicedb-operator/

# Regenerate README.md from README.md.gotmpl (run after changing Chart.yaml or README.md.gotmpl)
helm-docs
```

## Updating to a New SpiceDB Operator Version

This chart is derived from the `bundle.yaml` files published in the [SpiceDB Operator releases](https://github.com/authzed/spicedb-operator/releases). To update the chart, you diff the old and new bundle.yaml files and apply the changes to the Helm templates.

### Automated updates

Most updates are handled automatically. The `.github/workflows/update-operator.yml` workflow runs daily (and on-demand via `workflow_dispatch`), checks for a new operator release, and — if the chart is behind — runs `scripts/update-operator.sh` to:

- regenerate `templates/configmap-update-graph.yaml` from the new bundle,
- bump `Chart.yaml` (`version` minor bump, `appVersion`, source URL),
- regenerate `README.md` via helm-docs,
- verify with `helm lint` / `helm template` (and confirm the rendered update-graph is byte-identical to the bundle),

then opens a PR via `peter-evans/create-pull-request`.

The script encodes the manual runbook below for the common case (only the update-graph ConfigMap and the templated Deployment image tag change). **Drift guard:** if the bundle diff touches anything else (CRD / RBAC / ServiceAccount / Deployment spec), the script still applies the safe parts but marks the PR `needs-manual-review`, embeds the structural diff in the PR body, and fails a check. In that case, follow the manual process below to apply the structural changes to the relevant templates before merging.

You can also run the script locally:

```shell
# Sync to the latest release
scripts/update-operator.sh

# Sync to a specific release
scripts/update-operator.sh v1.25.1
```

### Step-by-step process (manual / drift cases)

1. **Determine the current version.** Read the `appVersion` field from `charts/spicedb-operator/Chart.yaml`. This is the SpiceDB Operator release the chart currently targets (e.g., `v1.23.0`).

2. **Determine the latest version.** Check https://github.com/authzed/spicedb-operator/releases for the most recent release tag (e.g., `v1.24.0`).

3. **Download both bundle.yaml files.** The URL pattern is:
   ```
   https://github.com/authzed/spicedb-operator/releases/download/<version>/bundle.yaml
   ```
   Download the bundle for the current `appVersion` and the new target version.

4. **Diff the two bundle.yaml files.** Compare old vs new to identify all changes. The bundle contains these resources, each of which maps to a file in the chart:

   | Bundle resource | Chart file |
   |---|---|
   | `CustomResourceDefinition` | `templates/crds/authzed.com_spicedbclusters.yaml` |
   | `ConfigMap` (update-graph) | `templates/configmap-update-graph.yaml` |
   | `ClusterRole` / `ClusterRoleBinding` | `templates/rbac.yaml` |
   | `Deployment` | `templates/deployment.yaml` (image tag comes from `appVersion`) |
   | `ServiceAccount` | `templates/serviceaccount.yaml` |

5. **Apply the diff to the chart files.** For each changed resource in the bundle diff:
   - **CRD** (`templates/crds/authzed.com_spicedbclusters.yaml`): Apply the structural changes (new fields, removed fields, description changes). Preserve the `{{- if .Values.installCRDs }}` guard at the top and `{{- end }}` at the bottom.
   - **ConfigMap** (`templates/configmap-update-graph.yaml`): Extract the `update-graph.yaml` data from the new bundle's ConfigMap and replace the content. Preserve the Helm template header (metadata, labels using `include "spicedb-operator.labels"`). The content under `data.update-graph.yaml` must be indented by 4 spaces.
   - **RBAC** (`templates/rbac.yaml`): Add/remove/modify ClusterRole rules as indicated by the diff.
   - **Deployment** (`templates/deployment.yaml`): The image tag is templated via `appVersion`, so usually no changes needed here unless the deployment spec itself changed (args, ports, probes, volume mounts, etc.).
   - **ServiceAccount** (`templates/serviceaccount.yaml`): Rarely changes, but check the diff.

6. **Update `Chart.yaml`:**
   - Set `appVersion` to the new operator release tag
   - Bump the chart `version` (minor version bump for new operator versions)
   - Update the source URL to point to the new release tag

7. **Verify the result.** After applying all changes:
   - Run `helm lint charts/spicedb-operator/` to check for errors
   - Run `helm template test-release charts/spicedb-operator/` and spot-check that:
     - The image tag reflects the new version
     - New CRD fields are present
     - New update graph entries (SpiceDB versions) appear
     - Any RBAC changes are reflected
   - **Cross-check against the new bundle.yaml directly** to ensure the rendered chart output matches the bundle's intent. This catches any pre-existing drift in the chart that might have been carried forward from a previous update. Pay special attention to the CRD, RBAC rules, and deployment spec.

8. **Regenerate docs.** Run `helm-docs` since `Chart.yaml` changed.

## Release Process

Releases are automated via GitHub Actions (`.github/workflows/release.yml`). Pushing to `main` triggers `helm/chart-releaser-action` which packages and publishes the chart to GitHub Pages.
