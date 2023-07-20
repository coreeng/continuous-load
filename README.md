## Continuous Load

Continuous Load is a project designed to run load 24/7 across an infrastructure and monitor the network health even in production. 

### What will continuous load try to solve ?

- Exercise full network flow to gain visibility and rely on metrics and alerts to assess the impact of a change.

- Gain Confidence when introducing change not to affect tenants on the platform. 
Become aware of issues before a tenant reports it.

- Reproduce what applications are doing on the cluster for example DNS/UDP and HTTP/GRPC/TCP flow through the main network paths like pod to pod communication through service IPs.

### Components

This project relies on: 
 - [k6](https://k6.io/) and statsd-exporter: acting as a load-injector
 - podinfo: [golang application](https://github.com/stefanprodan/podinfo)
 - monitoring stack [link](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
 - docker

### Architecture 

![Continuous Load](./docs/Continuous%20Load%20Diagram.png)

The load-injector sends load to target-podinfo. 

### Monitoring

Each component creates a ServiceMonitor or PodMonitor resource to configure prometheus automatically.

### Alerts

Each component creates PrometheusRule resources to configure alerts on prometheus automatically.
Those alerts follow the [Golden Signal principles](https://sysdig.com/blog/golden-signals-kubernetes/). 

### Dashboard 

The Continuous Load dashboard is created automatically.

### Run 


```
./deploy.sh -i
```

### Improvements

- [Chaos testing] Use a controller like [pod-reaper](https://github.com/target/pod-reaper) to graceful shutdown target podinfo  pods to exercise graceful shutdown/rolling deployment
