# Query cho Grafana/Prometheus

Tạo một dashboard tên `OpenWhisk K3s Demo`, datasource là Prometheus.

## Node và pod

```promql
sum by (instance) (rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m]))
sum by (namespace,pod) (container_memory_working_set_bytes{namespace="openwhisk"})
sum by (namespace,phase) (kube_pod_status_phase{namespace="openwhisk"})
sum by (namespace,pod,container) (kube_pod_container_status_restarts_total{namespace="openwhisk"})
```

## Invoker/action evidence

```promql
count(kube_pod_status_phase{namespace="openwhisk",phase="Running"})
sum(rate(container_cpu_usage_seconds_total{namespace="openwhisk",pod=~".*invoker.*"}[5m]))
sum(container_memory_working_set_bytes{namespace="openwhisk",pod=~".*invoker.*"})
```

## Panel cần quay

- Node CPU/RAM: cho thấy tải tăng khi concurrency tăng.
- OpenWhisk pod phase: cho thấy action pod được tạo và kết thúc.
- Invoker restart count: phải không tăng trong bài concurrency bình thường.
- Node Ready: đánh dấu thời điểm cordon/drain trong bài failover.
- HTTP latency/error rate: lấy từ K6 summary export hoặc gateway metrics nếu có.
