# OpenShift KEDA Example with User Workload Monitoring

This repository demonstrates Kubernetes Event-Driven Autoscaling (KEDA) on OpenShift with user workload monitoring integration.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    OpenShift Cluster                        │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ User Workload Monitoring (Prometheus)                │  │
│  │  - Scrapes metrics from testapp                      │  │
│  │  - Stores ping_request_count metrics                 │  │
│  └────────────────┬─────────────────────────────────────┘  │
│                   │                                         │
│                   │ Prometheus Query                        │
│                   ▼                                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ KEDA Operator                                        │  │
│  │  - Queries Prometheus for ping_request_count        │  │
│  │  - Scales testapp based on threshold                │  │
│  │  - Threshold: > 5 requests/sec triggers scale-up    │  │
│  └────────────────┬─────────────────────────────────────┘  │
│                   │                                         │
│                   │ HPA Scaling                             │
│                   ▼                                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Test Application (testapp)                           │  │
│  │  - Min replicas: 1                                   │  │
│  │  - Max replicas: 5                                   │  │
│  │  - Exposes /ping endpoint                            │  │
│  │  - Exports ping_request_count metric                 │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Components

### 1. User Workload Monitoring (`02_UserWorkload/`)
- Enables user workload monitoring in OpenShift
- Configures Prometheus to scrape application metrics
- Retention: 24h

### 2. KEDA Operator (`01_Operators/`)
- Namespace: `openshift-keda`
- **Operator**: Custom Metrics Autoscaler (Red Hat supported KEDA)
- Installed from `redhat-operators` catalog (not community-operators)
- KedaController configured to watch all namespaces
- Enables metric-based autoscaling

### 3. Test Application (`03_TestApp/`)
- Namespace: `testapp-keda`
- Container: `quay.io/coffeegoesincodecomesout/testapp-threepilar:latest`
- Endpoints:
  - `/ping` - Generates requests (increments ping_request_count)
  - `/metrics` - Prometheus metrics endpoint
  - `/health` - Liveness probe
  - `/ready` - Readiness probe

### 4. KEDA ScaledObject
- **Metric**: `ping_request_count` (rate over 1 minute)
- **Threshold**: 5 requests/second
- **Scaling**: 1-5 replicas
- **Polling Interval**: 30 seconds
- **Cooldown Period**: 300 seconds (5 minutes)

## Prerequisites

- OpenShift 4.11+ cluster
- Cluster admin access
- `oc` CLI installed and logged in

## Deployment

Run the automated deployment script:

```bash
./00_Deploy.sh
```

The script will:
1. Enable user workload monitoring
2. Install KEDA operator
3. Deploy the test application
4. Configure KEDA autoscaling with Prometheus authentication

## Testing Autoscaling

### 1. Get the application route
```bash
oc get route testapp -n testapp-keda
```

### 2. Generate load to trigger scaling
```bash
ROUTE_URL=$(oc get route testapp -n testapp-keda -o jsonpath='{.spec.host}')
while true; do curl http://$ROUTE_URL/ping; sleep 0.1; done
```

### 3. Watch pods scale up
In another terminal:
```bash
oc get pods -n testapp-keda -w
```

### 4. Monitor KEDA status
```bash
# View HPA created by KEDA
oc get hpa -n testapp-keda

# View ScaledObject status
oc get scaledobject -n testapp-keda -o yaml

# Check KEDA operator logs
oc logs -n openshift-keda -l app=keda-operator -f
```

### 5. View metrics in Prometheus
```bash
# Query current metric value
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -- \
  promtool query instant http://localhost:9090 \
  'sum(rate(ping_request_count{namespace="testapp-keda"}[1m]))'
```

## Expected Behavior

1. **Idle state**: 1 pod running
2. **Load generation**: When `ping_request_count` rate exceeds 5 requests/second
3. **Scale up**: KEDA creates additional pods (up to 5 total)
4. **Scale down**: After 5 minutes of low load, pods scale back down to 1

## Monitoring

### View ServiceMonitor
```bash
oc get servicemonitor -n testapp-keda
```

### Check Prometheus targets
Access the OpenShift console:
1. Navigate to Observe → Metrics
2. Switch to user workload monitoring
3. Query: `ping_request_count{namespace="testapp-keda"}`

### View KEDA metrics
```bash
oc get --raw /apis/custom.metrics.k8s.io/v1beta1 | jq .
```

## Troubleshooting

### KEDA not scaling
```bash
# Check ScaledObject status
oc describe scaledobject testapp-scaler -n testapp-keda

# Check KEDA operator logs
oc logs -n openshift-keda -l app=keda-operator --tail=100

# Verify Prometheus authentication
oc get triggerauthentication -n testapp-keda
oc get secret thanos-token -n testapp-keda -o yaml
```

### Metrics not appearing
```bash
# Check ServiceMonitor
oc get servicemonitor testapp -n testapp-keda -o yaml

# Verify pod is exposing metrics
POD=$(oc get pod -n testapp-keda -l app=testapp -o name | head -1)
oc exec -n testapp-keda $POD -- curl -s localhost:8080/metrics | grep ping_request_count

# Check user workload monitoring is enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml
```

### User workload monitoring not enabled
```bash
# Verify Prometheus pods are running
oc get pods -n openshift-user-workload-monitoring

# Check ConfigMap
oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring
```

## Cleanup

```bash
# Delete test application and KEDA resources
oc delete project testapp-keda

# Delete KEDA operator
oc delete project openshift-keda

# Disable user workload monitoring (optional)
oc delete configmap cluster-monitoring-config -n openshift-monitoring
```

## File Structure

```
.
├── 00_Deploy.sh                          # Automated deployment script
├── 01_Operators/
│   ├── 01_namespace.yaml                 # KEDA operator namespace
│   ├── 02_operatorgroup.yaml             # OperatorGroup for KEDA
│   ├── 03_subscription.yaml              # KEDA operator subscription
│   └── 04_kedacontroller.yaml            # KedaController instance
├── 02_UserWorkload/
│   └── 01_UserWorkload.yaml              # User workload monitoring config
├── 03_TestApp/
│   ├── 01_namespace.yaml                 # Application namespace
│   ├── 02_deployment.yaml                # Application deployment
│   ├── 03_service.yaml                   # Service
│   ├── 04_route.yaml                     # OpenShift route
│   ├── 05_servicemonitor.yaml            # Prometheus ServiceMonitor
│   ├── 06_scaledobject.yaml              # KEDA ScaledObject
│   └── 07_triggerauthentication.yaml     # Prometheus auth for KEDA
└── README.md
```

## References

- [KEDA Documentation](https://keda.sh/)
- [OpenShift Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/monitoring-overview.html)
- [KEDA Prometheus Scaler](https://keda.sh/docs/latest/scalers/prometheus/)
- [OpenShift User Workload Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/enabling-monitoring-for-user-defined-projects.html)
