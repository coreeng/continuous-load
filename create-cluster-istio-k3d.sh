#!/bin/bash -eu

if ! command -v k3d &> /dev/null
then
    echo "k3d could not be found, installing k3d"
    curl -s https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=v4.4.6 bash
fi

CLUSTER_NAME="istiocluster"
KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
ISTIO_NAMESPACE="istio-system"
NGINX_NAMESPACE="nginx"
GENERATOR_NAMESPACE="continuous-load-generator"
SOURCE_NAMESPACE="continuous-load-source"
TARGET_NAMESPACE="continuous-load-target"
MONITORING_NAMESPACE="monitoring"

# get workstation ip
WORKSTATION_IP=$(ip route get 1.1.1.1 | awk '{print $7}')
PROMETHEUS_URL="prometheus.${WORKSTATION_IP}.nip.io"
GRAFANA_URL="grafana.${WORKSTATION_IP}.nip.io"
SOURCE_PODINFO_URL="source-podinfo.${WORKSTATION_IP}.nip.io"
TARGET_PODINFO_URL="target-podinfo.${WORKSTATION_IP}.nip.io"

echo "===> Delete cluster"
k3d cluster delete ${CLUSTER_NAME}      
echo "===> Cluster creation"

k3d cluster create ${CLUSTER_NAME} --api-port 6443 \
    --servers 1 --agents 2 \
    --port 9443:443@loadbalancer \
    --port 80:80@loadbalancer \
    --k3s-server-arg "--disable=traefik" \
    --image rancher/k3s:v1.19.3-k3s2 \
    --registry-create

echo "===> Istio installation"

if [[ ! -d "istio-1.9.6" ]]; then 
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.9.6 TARGET_ARCH=x86_64 sh -
fi

kubectl --context ${KUBE_CONTEXT} create namespace ${ISTIO_NAMESPACE}

helm install istio-base istio-1.9.6/manifests/charts/base -n ${ISTIO_NAMESPACE} --kube-context ${KUBE_CONTEXT}

helm install istiod istio-1.9.6/manifests/charts/istio-control/istio-discovery \
    -n ${ISTIO_NAMESPACE} --kube-context ${KUBE_CONTEXT}

echo "===> Monitoring stack installation"

kubectl --context ${KUBE_CONTEXT} create namespace ${MONITORING_NAMESPACE}

helm upgrade -i prometheus prometheus-community/kube-prometheus-stack -n ${MONITORING_NAMESPACE} --kube-context ${KUBE_CONTEXT} \
             --set "grafana.ingress.hosts[0]=${GRAFANA_URL}" \
             --set "prometheus.ingress.hosts[0]=${PROMETHEUS_URL}" \
             -f prometheus/values.yml --version 19.0.1 

echo "===> Create dashboard"
kubectl --context ${KUBE_CONTEXT} -n ${MONITORING_NAMESPACE} create cm grafana-continuous-load --from-file=prometheus/continuous-load-dashboard.json
kubectl --context ${KUBE_CONTEXT} -n ${MONITORING_NAMESPACE} label cm grafana-continuous-load grafana_dashboard=continuous-load

echo "===> Nginx community ingress controller installation"

kubectl --context ${KUBE_CONTEXT} create namespace ${NGINX_NAMESPACE}
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --kube-context ${KUBE_CONTEXT} -n ${NGINX_NAMESPACE} \
             --set annotations.traffic.sidecar.istio.io/includeInboundPorts="" \
             --set controller.metrics.enabled=true \
             --set controller.metrics.serviceMonitor.enabled=true \
             --wait --atomic --timeout 360s --version 4.0.3

# done after the nginx controller installation, because a job is blocking during the installation when the sidecar is injected
kubectl --context ${KUBE_CONTEXT} label namespace ${NGINX_NAMESPACE} istio-injection=enabled --overwrite
kubectl --context ${KUBE_CONTEXT} -n ${NGINX_NAMESPACE} scale --replicas=0 deployment/ingress-nginx-controller
kubectl --context ${KUBE_CONTEXT} -n ${NGINX_NAMESPACE} scale --replicas=2 deployment/ingress-nginx-controller

# wait for nginx to be ready
kubectl wait --for=condition=available --timeout=600s deployment/ingress-nginx-controller --context ${KUBE_CONTEXT} -n ${NGINX_NAMESPACE} 

echo "===> Build and push podinfo to local registry"

LocalRegistryNodePort=$(docker ps -f name=${KUBE_CONTEXT}-registry --format "{{.Ports}}" | awk -F : '{ print $2 }' | awk -F - '{ print $1 }' )
echo "LocalRegistryNodePort: ${LocalRegistryNodePort}"

cd podinfo 
docker build -t ${KUBE_CONTEXT}-registry.localhost:${LocalRegistryNodePort}/podinfo:local . 
docker push ${KUBE_CONTEXT}-registry.localhost:${LocalRegistryNodePort}/podinfo:local
cd - 

echo "===> Source podinfo installation"

kubectl --context ${KUBE_CONTEXT} create namespace ${SOURCE_NAMESPACE}
kubectl --context ${KUBE_CONTEXT} label namespace ${SOURCE_NAMESPACE} istio-injection=enabled --overwrite
helm upgrade -i source-podinfo ./podinfo/charts/podinfo -n ${SOURCE_NAMESPACE} --kube-context ${KUBE_CONTEXT} --set replicaCount=3  --set ingress.enabled=true \
   --set "image.repository=${KUBE_CONTEXT}-registry:${LocalRegistryNodePort}/podinfo" \
   --set "image.tag=local" \
   --set "ingress.hosts[0].host=${SOURCE_PODINFO_URL},ingress.hosts[0].paths[0].path=/,ingress.hosts[0].paths[0].pathType=ImplementationSpecific" \
   --set "backendIngress=http://${TARGET_PODINFO_URL}/status/ingress/200" \
   --set "backendService=http://target-podinfo.${TARGET_NAMESPACE}.svc.cluster.local/status/service/200" \
   -f podinfo/charts/podinfo/values-source-podinfo.yaml

kubectl wait --for=condition=available --timeout=600s deployment/source-podinfo --context ${KUBE_CONTEXT} -n ${SOURCE_NAMESPACE} 

echo "===> Target podinfo installation"

kubectl --context ${KUBE_CONTEXT} create namespace ${TARGET_NAMESPACE}
kubectl --context ${KUBE_CONTEXT} label namespace ${TARGET_NAMESPACE} istio-injection=enabled --overwrite
helm upgrade -i target-podinfo ./podinfo/charts/podinfo -n ${TARGET_NAMESPACE} --kube-context ${KUBE_CONTEXT} --set replicaCount=3  --set ingress.enabled=true \
   --set "image.repository=${KUBE_CONTEXT}-registry:${LocalRegistryNodePort}/podinfo" \
   --set "image.tag=local" \
   --set "ingress.hosts[0].host=${TARGET_PODINFO_URL},ingress.hosts[0].paths[0].path=/,ingress.hosts[0].paths[0].pathType=ImplementationSpecific" \
   -f podinfo/charts/podinfo/values-target-podinfo.yaml

kubectl wait --for=condition=available --timeout=600s deployment/target-podinfo --context ${KUBE_CONTEXT} -n ${TARGET_NAMESPACE}

echo "===> Load generator installation"

kubectl --context ${KUBE_CONTEXT} create namespace ${GENERATOR_NAMESPACE}
kubectl --context ${KUBE_CONTEXT} label namespace ${GENERATOR_NAMESPACE} istio-injection=enabled --overwrite

helm upgrade -i k6 ./k6/ -n ${GENERATOR_NAMESPACE} --kube-context ${KUBE_CONTEXT} \
     --set "loadTargetService=http://source-podinfo.${SOURCE_NAMESPACE}.svc.cluster.local/forward/service" \
     --set "loadTargetIngress=http://source-podinfo.${SOURCE_NAMESPACE}.svc.cluster.local/forward/ingress" \


echo "-----------------------------------------"
echo "-----------------------------------------"
echo "Components are ready:"
echo "-----------------------------------------"
echo "-----------------------------------------"
echo "Prometheus URL: http://${PROMETHEUS_URL}"
echo "Grafana URL: http://${GRAFANA_URL} login: admin password: adminadmin"
echo "Source PodInfo URL: http://${SOURCE_PODINFO_URL}"
echo "Source PodInfo forward/service URL: http://${SOURCE_PODINFO_URL}/forward/service"
echo "Source PodInfo forward/ingress URL: http://${SOURCE_PODINFO_URL}/forward/ingress"
echo "Target PodInfo URL: http://${TARGET_PODINFO_URL}"
echo "Target PodInfo status/ingress/200 URL: http://${TARGET_PODINFO_URL}/status/ingress/200"
echo "Target PodInfo status/service/200 URL: http://${TARGET_PODINFO_URL}/status/service/200"
echo "Access to the cluster: kubectl --context ${KUBE_CONTEXT} get ns"
echo "Access Dashboard user=admin pwd=adminadmin http://${GRAFANA_URL}/d/zDpLnqaMz/continuous-load?orgId=1&var-prometheus=Prometheus&var-source_namespace=continuous-load-source&var-target_namespace=continuous-load-target&from=now-5m&to=now"

echo "Wait for load-generator to start based on cronjob max 6 mins"

NUM_PODS=0
until [ "$NUM_PODS" -gt 1 ]; do
  echo "Number of k6 pods running $NUM_PODS, waiting to have 2 pods running" 
  NUM_PODS=$(kubectl --context ${KUBE_CONTEXT} -n ${GENERATOR_NAMESPACE} get pods --no-headers | wc -l)
  sleep 2
done
echo "k6 pods are now running" 