#!/bin/bash -eu

: "${NAMESPACE:=continuous-load}"

# deploy_continuous_load - deploys the load injector and target application as well as
# the ServiceMonitor and PodMonitor objects that are used to supply Prometheus with 
# the scrape configuration.
# Params:
#  1) the target of the load generator. See https://k6.io/docs/javascript-api/k6-http/params/
#     for info on accepted parameters
#  2) the number of replicas to run
#  3) the thresholds for pass/failure. See https://k6.io/docs/using-k6/thresholds/
#  4) the number of requests per second to run
#  5) the type of Prometheus operator to use.  (coreos, googleapis, none)
# 
# This implementation uses the podinfo application, which is able to generate 
# metrics that are used in the dashboard.
# 
# This implementation uses k6 to generate the load.  The parameters are defined 
# in continuous-load/charts/k6/load.js.
function deploy_continuous_load() {
  local loadTargetService="$1"
  local replicas="$2"
  local thresholds="$3"
  local reqPerSecond="$4"
  local promOperator="$5"
  echo "===> Deploying Continuous Load"
  helm dependency update ./charts/continuous-load
  helm upgrade -install --wait continuous-load \
  --namespace ${NAMESPACE}  \
  --set "podinfo.replicaCount=${replicas}" \
  --set-json "k6.loadTargetService[0]=${loadTargetService}" \
  --set-json "k6.thresholds=${thresholds}" \
  --set "k6.reqPerSecond=${reqPerSecond}" \
  --set "global.promOperator=${promOperator}" \
  ./charts/continuous-load/
}

function main() {
  local loadTargetService="{ \
      \"method\": \"GET\", \
      \"url\": \"http://continuous-load-podinfo.${NAMESPACE}.svc.cluster.local:9898/status/200\", \
      \"params\": { 
        \"tags\": { 
          \"type\": \"service\"
        } \
      } \
    }"

  local replicas="2"
  local thresholds="{ \
    \"http_req_failed\": [\"rate<0.01\"],
    \"http_req_duration\": [\"p(95)<200\"]
  }"
  local reqPerSecond="3"
  local promOperator="coreos"
  deploy_continuous_load "${loadTargetService}" "${replicas}" "${thresholds}" "${reqPerSecond}" "${promOperator}"
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
      namespace="${NAMESPACE}"
      deploy_monitoring $namespace "http://prometheus-operated.${namespace}.svc.cluster.local:9090"
      ;;
    *) echo "Invalid option: -$flag" ;;
        esac
done

main

exit 0