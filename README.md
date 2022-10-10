## Continuous Load

Continuous Load is a project design to run load 24/7 across an infrastructure and monitor the network health even in production. 
We have rolled out various versions at clients.

### What will continuous load try to solve ?

Exercise full network flow to gain visibility and rely on metrics and alerts to assess the impact of a change.

Confidence when introducing change to not affect tenants on the platform. 
Being aware of issues before tenants report it.

Reproduce what applications are doing on the cluster for example DNS/UDP and HTTP/GRPC/TCP flow through the main network paths like internal, external ingresses and pod to pod communication through service ip.

Exercise DNS/UDP network path (service ip CoreDNS) test-client-load-injector and test-backend-service resolving kubernetes and ingress hostname.

Chaos testing in the background (resilient to failures):
  - deleting test-backend-service (pod ip churn, graceful shutdown, recycle TCP connections: the load injector will be forced to create new connection)
  - delete of nodes (exercising autoscaling or node termination)

### Components

This project relies on: 
 - [k6](https://k6.io/) and statsd-exporter: acting as a load-injector
 - podinfo: [golang application](https://github.com/stefanprodan/podinfo), we are using a modified version available [here](https://github.com/rewiko/podinfo)
 - nginx ingress controller [link](https://github.com/kubernetes/ingress-nginx/)
 - istio [link](https://istio.io/latest/docs/)
 - monitoring stack [link](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
 - docker and [k3d](https://k3d.io/) to create local k8s cluster

### Architecture 

![Continuous Load](./docs/Continuous%20Load%20Diagram.png)

The load-injector send load to source-podinfo and not to the ingress directly because load-injectors like k6 or gatling are design to retry on connection reset which can hide issues. It is also interresting to own a golang application to go further and add functional validation like JWT secret rotation, MTLS or talking to a database. 

### Monitoring

Each component creates a ServiceMonitor or PodMonitor resource to configure prometheus automatically.

### Alerts

Each component creates PrometheusRule resources to configure alerts on prometheus automatically.
Those alerts follow the [Golden Signal principles](https://sysdig.com/blog/golden-signals-kubernetes/). 

### Dashboard 

Continuous dashboard is create automatically and the link will be available within the console after running the script below.

### Run 

```
./create-cluster-istio-k3d.sh
```

## Integration tests 

Integration tests have been created [here](podinfo/test/integration/integration_test.go) but will not work for the local version, it needs a bit of work.

```
cd podinfo ; make integration prometheus_url=$prometheus_url source_url=$source_url target_url=$target_url region=$region cluster=$cluster
```

### Improvements

- [Chaos testing] Use a controller like [pod-reaper](https://github.com/target/pod-reaper) to graceful shutdown target podinfo and nginx pods to exercise graceful shutdown/rolling deployment
