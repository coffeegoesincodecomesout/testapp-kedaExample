#!/bin/bash
set -euo pipefail

# Logging setup
LOG_DIR="logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

trap 'log "FATAL: deploy aborted at line $LINENO (exit code $?)"' ERR

# Utility functions
oc_create() {
    if ! oc create -f "$1" 2>&1 | tee -a "$LOG_FILE"; then
        if grep -q "AlreadyExists" "$LOG_FILE"; then
            log "Resource already exists, continuing..."
            return 0
        else
            return 1
        fi
    fi
}

wait_for_all_csvs() {
    local namespace=$1
    local timeout=${2:-300}
    log "Waiting for all CSVs in namespace $namespace to reach Succeeded phase..."

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local pending=$(oc get csv -n "$namespace" -o json | jq -r '.items[] | select(.status.phase != "Succeeded") | .metadata.name' | wc -l)
        if [ "$pending" -eq 0 ]; then
            log "All CSVs in $namespace are ready"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    die "Timeout waiting for CSVs in $namespace"
}

wait_for_subscription() {
    local namespace=$1
    local sub_name=$2
    local timeout=${3:-300}
    log "Waiting for subscription $sub_name in namespace $namespace..."

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local csv=$(oc get subscription "$sub_name" -n "$namespace" -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
        if [ -n "$csv" ]; then
            local phase=$(oc get csv "$csv" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ "$phase" = "Succeeded" ]; then
                log "Subscription $sub_name is ready (CSV: $csv)"
                return 0
            fi
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    die "Timeout waiting for subscription $sub_name"
}

wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}
    log "Waiting for pods with label $label in namespace $namespace..."

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local ready=$(oc get pods -n "$namespace" -l "$label" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$ready" == *"True"* ]]; then
            log "Pods with label $label are ready"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    die "Timeout waiting for pods with label $label"
}

# Main deployment
log "Starting KEDA deployment..."

# Phase 1: User Workload Monitoring
log "Phase 1: Enabling User Workload Monitoring"
oc apply -f 02_UserWorkload/01_UserWorkload.yaml
log "Waiting for user workload monitoring to be ready..."
sleep 30
wait_for_pods "openshift-user-workload-monitoring" "app.kubernetes.io/name=prometheus" 180

# Phase 2: KEDA Operator
log "Phase 2: Installing Custom Metrics Autoscaler Operator"
oc apply -f 01_Operators/01_namespace.yaml
oc apply -f 01_Operators/02_operatorgroup.yaml
oc apply -f 01_Operators/03_subscription.yaml
wait_for_subscription "openshift-keda" "openshift-custom-metrics-autoscaler-operator" 600
wait_for_all_csvs "openshift-keda" 300

log "Installing KedaController..."
oc apply -f 01_Operators/04_kedacontroller.yaml
sleep 20
wait_for_pods "openshift-keda" "app=keda-operator" 180

# Phase 3: Test Application
log "Phase 3: Deploying Test Application"
oc apply -f 03_TestApp/01_namespace.yaml
oc apply -f 03_TestApp/02_deployment.yaml
oc apply -f 03_TestApp/03_service.yaml
oc apply -f 03_TestApp/04_route.yaml
oc apply -f 03_TestApp/05_servicemonitor.yaml

log "Waiting for test application to be ready..."
wait_for_pods "testapp-keda" "app=testapp" 180

# Phase 4: Configure KEDA Scaling
log "Phase 4: Configuring KEDA Scaling"
log "Creating service account token for Prometheus authentication..."

# Create service account and get token
oc create sa keda-prometheus-reader -n testapp-keda || true
oc adm policy add-cluster-role-to-user cluster-monitoring-view system:serviceaccount:testapp-keda:keda-prometheus-reader

# Get the token (OpenShift 4.11+ method)
TOKEN=$(oc create token keda-prometheus-reader -n testapp-keda --duration=87600h)

# Update the secret with the token
oc apply -f 03_TestApp/07_triggerauthentication.yaml
oc patch secret thanos-token -n testapp-keda -p "{\"stringData\":{\"token\":\"$TOKEN\"}}"

# Apply ScaledObject
oc apply -f 03_TestApp/06_scaledobject.yaml

log "Waiting for KEDA to initialize scaling..."
sleep 30

# Get route URL
ROUTE_URL=$(oc get route testapp -n testapp-keda -o jsonpath='{.spec.host}')

log "============================================"
log "KEDA Deployment Complete!"
log "============================================"
log "Application URL: http://$ROUTE_URL/ping"
log ""
log "To test autoscaling:"
log "  1. Generate load: while true; do curl http://$ROUTE_URL/ping; sleep 0.1; done"
log "  2. Watch pods scale: oc get pods -n testapp-keda -w"
log "  3. Check HPA: oc get hpa -n testapp-keda"
log "  4. View ScaledObject status: oc get scaledobject -n testapp-keda"
log ""
log "View metrics:"
log "  oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -- promtool query instant http://localhost:9090 'ping_request_count{namespace=\"testapp-keda\"}'"
log "============================================"
