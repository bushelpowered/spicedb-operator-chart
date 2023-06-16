# spicedb-operator-chart

A Helm chart to install the [SpiceDB Operator](https://github.com/authzed/spicedb-operator).

# Installation

```shell
helm repo add spicedb-operator-chart https://bushelpowered.github.io/spicedb-operator-chart/
helm repo update
helm repo upgrade --install ... <release> spicedb-operator-chart/spicedb-operator
```