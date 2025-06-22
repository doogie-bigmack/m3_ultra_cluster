#!/usr/bin/env bash
# Create namespaces for observability stack

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Set error trap
set_error_trap

# Script information
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PURPOSE="Create namespaces for observability components"

# Namespaces to create
declare -A NAMESPACES=(
    ["observability"]="OpenTelemetry collectors and operator"
    ["monitoring"]="Storage backends (Prometheus, Loki, Tempo)"
    ["grafana"]="Visualization and dashboards"
)

# Main function
main() {
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Purpose: ${SCRIPT_PURPOSE}"
    log_info "Log file: ${LOG_FILE}"
    
    # Check cluster connectivity
    check_cluster_connectivity
    
    # Create namespaces
    create_namespaces
    
    # Label namespaces
    label_namespaces
    
    # Create default network policies
    create_network_policies
    
    log_success "Observability namespaces created successfully!"
    log_info "Next step: Run ./00-setup-prerequisites.sh"
}

check_cluster_connectivity() {
    log_info "Checking cluster connectivity..."
    
    if ! kubectl --context="${KUBECTL_CONTEXT}" cluster-info &>/dev/null; then
        log_error "Cannot connect to cluster. Is it running?"
        log_info "Run: ./scripts/operations/test-cluster.sh"
        exit 1
    fi
    
    log_success "Connected to cluster: ${KUBECTL_CONTEXT}"
}

create_namespaces() {
    log_info "Creating namespaces..."
    
    for ns in "${!NAMESPACES[@]}"; do
        local description="${NAMESPACES[$ns]}"
        log_info "Creating namespace: ${ns} (${description})"
        
        # Create namespace with dry-run first
        cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    name: ${ns}
    purpose: observability
    managed-by: k3s-cluster-scripts
  annotations:
    description: "${description}"
EOF
        
        # Wait for namespace to be active
        if kubectl --context="${KUBECTL_CONTEXT}" wait --for=jsonpath='{.status.phase}'=Active \
            namespace/${ns} --timeout=30s &>/dev/null; then
            log_success "Namespace ${ns} created and active"
        else
            log_error "Namespace ${ns} failed to become active"
            exit 1
        fi
    done
}

label_namespaces() {
    log_info "Labeling namespaces for pod security standards..."
    
    # Apply pod security standards
    for ns in "${!NAMESPACES[@]}"; do
        kubectl --context="${KUBECTL_CONTEXT}" label namespace ${ns} \
            pod-security.kubernetes.io/enforce=restricted \
            pod-security.kubernetes.io/audit=restricted \
            pod-security.kubernetes.io/warn=restricted \
            --overwrite &>/dev/null || true
        
        log_success "Applied security labels to namespace: ${ns}"
    done
}

create_network_policies() {
    log_info "Creating default network policies..."
    
    # Allow ingress within observability namespace
    cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: observability
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - podSelector: {}
  - to:
    - namespaceSelector:
        matchLabels:
          name: monitoring
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
  - ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-observability
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: observability
  - from:
    - namespaceSelector:
        matchLabels:
          name: grafana
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-grafana-access
  namespace: grafana
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector: {}
  - ports:
    - protocol: TCP
      port: 3000
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: monitoring
  - to:
    - podSelector: {}
  - ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
EOF
    
    log_success "Network policies created"
}

# Run main function
main "$@"