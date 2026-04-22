# spicedb-operator

![Version: 2.6.0](https://img.shields.io/badge/Version-2.6.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: v1.23.0](https://img.shields.io/badge/AppVersion-v1.23.0-informational?style=flat-square)

A Helm chart to install the SpiceDB Operator

## Source Code

* <https://github.com/bushelpowered/spicedb-operator-chart>
* <https://github.com/authzed/spicedb-operator/releases/tag/v1.23.0>

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| clusterRole.annotations | object | `{}` |  |
| clusterRole.create | bool | `true` |  |
| clusterRole.name | string | `""` |  |
| commonLabels | object | `{}` |  |
| deployment.annotations | object | `{}` |  |
| fullnameOverride | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"ghcr.io/authzed/spicedb-operator"` |  |
| image.tag | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| installCRDs | bool | `true` |  |
| nameOverride | string | `""` |  |
| nodeSelector | object | `{}` |  |
| podAnnotations | object | `{}` |  |
| podSecurityContext.runAsGroup | int | `65532` |  |
| podSecurityContext.runAsNonRoot | bool | `true` |  |
| podSecurityContext.runAsUser | int | `65532` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| resources | object | `{}` |  |
| roleBinding.annotations | object | `{}` |  |
| roleBinding.create | bool | `true` |  |
| securityContext.allowPrivilegeEscalation | bool | `false` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.readOnlyRootFilesystem | bool | `true` |  |
| securityContext.runAsGroup | int | `65532` |  |
| securityContext.runAsNonRoot | bool | `true` |  |
| securityContext.runAsUser | int | `65532` |  |
| securityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| spiceDB.allowedImages | list | `[]` | Allowlisted SpiceDB image repositories (paths without tag). When empty, `allowedImages` is omitted from operator global config. |
| spiceDB.disableImageValidation | bool | `false` | When true, sets `disableImageValidation` in operator global config. |
| spiceDB.imageName | string | `"ghcr.io/authzed/spicedb"` | Default SpiceDB container image repository (path without tag). |
| strategy | object | `{}` |  |
| tolerations | list | `[]` |  |
