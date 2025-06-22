#!/usr/bin/env bash
# Setup storage for observability components

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Set error trap
set_error_trap

# Script information
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PURPOSE="Configure persistent storage for observability stack"

# Storage configurations
declare -A STORAGE_CONFIGS=(
    ["prometheus-data"]="monitoring:50Gi:Prometheus time-series data"
    ["loki-data"]="monitoring:100Gi:Loki log chunks"
    ["tempo-data"]="monitoring:50Gi:Tempo trace data"
    ["grafana-data"]="grafana:10Gi:Grafana dashboards and config"
)

# Main function
main() {
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Purpose: ${SCRIPT_PURPOSE}"
    log_info "Log file: ${LOG_FILE}"
    
    # Check storage class
    check_storage_class
    
    # Create PVCs
    create_pvcs
    
    # Create config maps for retention
    create_retention_configs
    
    # Setup MinIO for object storage (optional)
    if [[ "${ENABLE_MINIO:-false}" == "true" ]]; then
        setup_minio
    fi
    
    log_success "Storage setup completed successfully!"
    log_info "Next step: Run ./01-deploy-otel-operator.sh"
}

check_storage_class() {
    log_info "Checking storage class availability..."
    
    # Get available storage classes
    local storage_classes=$(kubectl --context="${KUBECTL_CONTEXT}" get storageclass -o name | sed 's/storageclass.storage.k8s.io\///')
    
    if [[ -z "${storage_classes}" ]]; then
        log_error "No storage classes found in cluster"
        log_info "Please set up NFS or other storage first"
        exit 1
    fi
    
    log_info "Available storage classes:"
    echo "${storage_classes}" | while read -r sc; do
        log_info "  - ${sc}"
    done
    
    # Check for preferred storage class
    local storage_class="${STORAGE_CLASS:-nfs-storage}"
    if kubectl --context="${KUBECTL_CONTEXT}" get storageclass "${storage_class}" &>/dev/null; then
        log_success "Using storage class: ${storage_class}"
    else
        log_warning "Preferred storage class '${storage_class}' not found"
        
        # Use default or first available
        storage_class=$(kubectl --context="${KUBECTL_CONTEXT}" get storageclass \
            -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
        
        if [[ -z "${storage_class}" ]]; then
            storage_class=$(echo "${storage_classes}" | head -n1)
        fi
        
        log_info "Using storage class: ${storage_class}"
        STORAGE_CLASS="${storage_class}"
    fi
}

create_pvcs() {
    log_info "Creating Persistent Volume Claims..."
    
    for pvc_name in "${!STORAGE_CONFIGS[@]}"; do
        local config="${STORAGE_CONFIGS[$pvc_name]}"
        IFS=':' read -r namespace size description <<< "${config}"
        
        log_info "Creating PVC: ${pvc_name} (${size}) in namespace ${namespace}"
        log_debug "Purpose: ${description}"
        
        # Create PVC
        cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: ${pvc_name%-data}
    app.kubernetes.io/part-of: observability-stack
    managed-by: k3s-cluster-scripts
  annotations:
    description: "${description}"
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${size}
  storageClassName: ${STORAGE_CLASS:-nfs-storage}
EOF
        
        # Wait for PVC to be bound (with timeout)
        log_info "Waiting for PVC ${pvc_name} to be bound..."
        local timeout=60
        local bound=false
        
        while [[ ${timeout} -gt 0 ]]; do
            local status=$(kubectl --context="${KUBECTL_CONTEXT}" get pvc ${pvc_name} -n ${namespace} \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            
            if [[ "${status}" == "Bound" ]]; then
                bound=true
                break
            fi
            
            sleep 2
            timeout=$((timeout - 2))
        done
        
        if [[ "${bound}" == "true" ]]; then
            log_success "PVC ${pvc_name} is bound"
        else
            log_warning "PVC ${pvc_name} is not bound yet (status: ${status})"
            log_info "This may be normal if using dynamic provisioning"
        fi
    done
}

create_retention_configs() {
    log_info "Creating retention configuration..."
    
    # Prometheus retention config
    cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-retention-config
  namespace: monitoring
  labels:
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/part-of: observability-stack
data:
  retention.time: "30d"
  retention.size: "45GB"
  wal.compression: "true"
EOF
    
    # Loki retention config
    cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-retention-config
  namespace: monitoring
  labels:
    app.kubernetes.io/name: loki
    app.kubernetes.io/part-of: observability-stack
data:
  retention.period: "168h"  # 7 days
  retention.deletes.enabled: "true"
  compaction.interval: "10m"
  compaction.retention: "24h"
EOF
    
    # Tempo retention config
    cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-retention-config
  namespace: monitoring
  labels:
    app.kubernetes.io/name: tempo
    app.kubernetes.io/part-of: observability-stack
data:
  retention.period: "72h"  # 3 days
  max.block.duration: "2h"
  compaction.window: "1h"
EOF
    
    log_success "Retention configurations created"
}

setup_minio() {
    log_info "Setting up MinIO for S3-compatible object storage..."
    
    # Create MinIO namespace
    kubectl --context="${KUBECTL_CONTEXT}" create namespace minio --dry-run=client -o yaml | \
        kubectl --context="${KUBECTL_CONTEXT}" apply -f -
    
    # Create MinIO PVC
    cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
  namespace: minio
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 200Gi
  storageClassName: ${STORAGE_CLASS:-nfs-storage}
EOF
    
    # Deploy MinIO (basic single-node for now)
    cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args:
        - server
        - /data
        - --console-address
        - ":9001"
        env:
        - name: MINIO_ROOT_USER
          value: "minioadmin"
        - name: MINIO_ROOT_PASSWORD
          value: "minioadmin123"  # Change in production!
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-data
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    app: minio
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
EOF
    
    log_success "MinIO deployed for object storage"
    log_info "MinIO credentials: minioadmin / minioadmin123 (CHANGE IN PRODUCTION!)"
}

# Run main function
main "$@"