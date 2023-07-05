#!/bin/bash -eu

# deploy_continuous_load - deploys the load injector and target application as well as
# the ServiceMonitor and PodMonitor objects that are used to supply Prometheus with 
# the scrape configuration.
# Params:
#  1) the namespace in which to deploy the monitors
#  2) the target of the load generator. See https://k6.io/docs/javascript-api/k6-http/params/
#     for into on accepted parameters
#  3) the number of replicas to run
#  4) the number of requests per second to run
# 
# This implementation uses the podinfo application, which is able to generate 
# metrics that are used in the dashboard.
# 
# This implementation uses k6 to generate the load.  The parameters are defined 
# in continuous-load/charts/k6/load.js.
function deploy_continuous_load() {
  local namespace="$1"
  local loadTargetService="$2"
  local replicas="$3"
  local reqPerSecond="$4"
  echo "===> Deploying Continuous Load"
  helm dependency build ./continuous-load
  helm upgrade -install --wait continuous-load \
  --namespace ${namespace}  \
  --set "podinfo.replicaCount=${replicas}" \
  --set-json "k6.loadTargetService[0]=${loadTargetService}" \
  --set "k6.reqPerSecond=${reqPerSecond}" \
  ./continuous-load/
}

# deploy_dashboard - deploys the Grafana dashboard for monitoring the health of 
# the synthetic load.
# Params:
#  1) the namespace in which to deploy the dashboard
# 
# The json from the Grafana dashboard is saved in continuous-load-dashboard.yaml
function deploy_dashboard() {
  local namespace="$1"
  echo "===> Deploying Dashboard"
  # Can't put this into a helm chart due to the difficulty in escaping Grafana variables
  kubectl -n ${namespace} apply -f continuous-load-dashboard.yaml
}

function main() {
  local namespace="continuous-load"
  local loadTargetService="{ \
      \"method\": \"GET\", \
      \"url\": \"http://continuous-load-podinfo.${namespace}.svc.cluster.local:9898/status/200\", \
      \"params\": { 
        \"tags\": { 
          \"type\": \"service\"
        } \
      } \
    }"

  local replicas="2"
  local reqPerSecond="3"
  deploy_continuous_load "${namespace}" "${loadTargetService}" "${replicas}" "${reqPerSecond}"
  deploy_dashboard "${namespace}"
  echo "-----------------------------------------"
  echo "-----------------------------------------"
  echo "Components are ready:"
  echo "-----------------------------------------"
  echo "-----------------------------------------" 
}

while getopts 'i' flag; do
  case "${flag}" in
    i)  
      source ./prerequisites.sh
      namespace="continuous-load"
      create_namespace $namespace
      deploy_monitoring $namespace "http://prometheus-operated.${namespace}.svc.cluster.local:9090"
      ;;
    *) echo "Invalid option: -$flag" ;;
        esac
done

main

exit 0