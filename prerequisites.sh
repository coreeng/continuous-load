#!/bin/bash -eu

function create_namespace() {
  local namespace="$1"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespace}
  labels:
    name: ${namespace}
EOF
}

function deploy_monitoring() {
    local namespace="$1"
    local prometheusUrl="$2"
    helm upgrade -install grafana-operator oci://ghcr.io/grafana-operator/helm-charts/grafana-operator \
    --namespace ${namespace} \
    --version v5.0.0
    helm dependency build ./monitoring/
    helm upgrade -install --wait monitoring \
    --namespace ${namespace}  \
    --set "grafana.prometheusUrl=${prometheusUrl}" \
    ./monitoring/
}

