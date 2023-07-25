#!/bin/bash -eu

function deploy_monitoring() {
    local namespace="$1"
    local prometheusUrl="$2"
    helm upgrade --install grafana-operator oci://ghcr.io/grafana-operator/helm-charts/grafana-operator \
    --namespace ${namespace} \
    --version v5.0.0 \
    --create-namespace 
    
    helm dependency build ./charts/monitoring/
    helm upgrade -install --wait monitoring \
    --namespace ${namespace}  \
    --set "grafana.prometheusUrl=${prometheusUrl}" \
    ./charts/monitoring/
}

