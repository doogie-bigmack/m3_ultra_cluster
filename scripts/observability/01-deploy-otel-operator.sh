#!/usr/bin/env bash
# Deploy OpenTelemetry Operator

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Set error trap
set_error_trap

# Script information
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PURPOSE="Deploy OpenTelemetry Operator for managing collectors"

# Versions
OTEL_OPERATOR_VERSION="0.92.0"

# Main function
main() {
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Purpose: ${SCRIPT_PURPOSE}"
    log_info "Log file: ${LOG_FILE}"
    
    # Check prerequisites
    check_prerequisites
    
    # Deploy OTel Operator
    deploy_otel_operator
    
    # Wait for operator to be ready
    wait_for_operator
    
    # Create operator configuration
    create_operator_config
    
    # Verify installation
    verify_installation
    
    log_success "OpenTelemetry Operator deployed successfully!"
    log_info "Next step: Run ./02-deploy-otel-collectors.sh"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check cert-manager
    if ! kubectl --context="${KUBECTL_CONTEXT}" get deployment -n cert-manager cert-manager &>/dev/null; then
        log_error "cert-manager not found. Run ./00-setup-prerequisites.sh first"
        exit 1
    fi
    
    # Check cert-manager is ready
    local cert_manager_ready=$(kubectl --context="${KUBECTL_CONTEXT}" get deployment -n cert-manager cert-manager \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
    
    if [[ "${cert_manager_ready}" != "True" ]]; then
        log_error "cert-manager is not ready"
        exit 1
    fi
    
    # Check observability namespace
    if ! kubectl --context="${KUBECTL_CONTEXT}" get namespace observability &>/dev/null; then
        log_error "Namespace 'observability' not found. Run ./00-create-namespaces.sh first"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

deploy_otel_operator() {
    log_info "Deploying OpenTelemetry Operator..."
    
    # Check if already installed
    if helm list -n observability | grep -q opentelemetry-operator; then
        log_info "OpenTelemetry Operator already installed, upgrading..."
        local action="upgrade"
    else
        log_info "Installing OpenTelemetry Operator..."
        local action="install"
    fi
    
    # Create values file for ARM64 compatibility
    cat > "${SCRIPT_DIR}/values/otel-operator-values.yaml" <<EOF
# OpenTelemetry Operator Values
manager:
  image:
    repository: ghcr.io/open-telemetry/opentelemetry-operator/opentelemetry-operator
  
  # Resources for operator
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 128Mi
  
  # ARM64 compatibility
  nodeSelector:
    kubernetes.io/arch: arm64
  
  # Pod security context
  podSecurityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault

# Webhook configuration
admissionWebhooks:
  certManager:
    enabled: true
    issuerRef:
      name: selfsigned-issuer
      kind: Issuer

# Create RBAC resources
rbac:
  create: true

# ServiceMonitor for Prometheus
serviceMonitor:
  enabled: true

# Enable leader election for HA
leaderElection:
  enabled: true
EOF
    
    # Deploy operator
    helm ${action} opentelemetry-operator open-telemetry/opentelemetry-operator \
        --namespace observability \
        --version ${OTEL_OPERATOR_VERSION} \
        --values "${SCRIPT_DIR}/values/otel-operator-values.yaml" \
        --wait --timeout 5m
    
    log_success "OpenTelemetry Operator deployment initiated"
}

wait_for_operator() {
    log_info "Waiting for OpenTelemetry Operator to be ready..."
    
    # Wait for deployment to be available
    if ! kubectl --context="${KUBECTL_CONTEXT}" wait --for=condition=available \
        --timeout=300s deployment/opentelemetry-operator-controller-manager -n observability; then
        log_error "OpenTelemetry Operator failed to become ready"
        kubectl --context="${KUBECTL_CONTEXT}" describe deployment opentelemetry-operator-controller-manager -n observability
        exit 1
    fi
    
    # Check webhook is ready
    log_info "Checking webhook configuration..."
    sleep 10  # Give webhook time to initialize
    
    if kubectl --context="${KUBECTL_CONTEXT}" get validatingwebhookconfigurations | grep -q opentelemetry-operator; then
        log_success "Webhook configuration found"
    else
        log_warning "Webhook configuration not found, this may cause issues"
    fi
}

create_operator_config() {
    log_info "Creating operator configuration..."
    
    # Create self-signed issuer for cert-manager
    cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
  namespace: observability
spec:
  selfSigned: {}
EOF
    
    # Create instrumentation resource for auto-instrumentation
    cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: default-instrumentation
  namespace: observability
spec:
  # Instrumentation for different languages
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:latest
  
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:latest
  
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:latest
  
  go:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-go:latest
  
  # Default endpoint
  exporter:
    endpoint: http://otel-node-collector:4317
  
  # Propagators
  propagators:
    - tracecontext
    - baggage
    - b3
  
  # Sampling
  sampler:
    type: parentbased_traceidratio
    argument: "0.1"  # 10% sampling
EOF
    
    log_success "Operator configuration created"
}

verify_installation() {
    log_info "Verifying OpenTelemetry Operator installation..."
    
    # Check CRDs
    log_info "Checking Custom Resource Definitions..."
    local required_crds=(
        "opentelemetrycollectors.opentelemetry.io"
        "instrumentations.opentelemetry.io"
    )
    
    for crd in "${required_crds[@]}"; do
        if kubectl --context="${KUBECTL_CONTEXT}" get crd "${crd}" &>/dev/null; then
            log_success "CRD found: ${crd}"
        else
            log_error "CRD not found: ${crd}"
            exit 1
        fi
    done
    
    # Check operator logs
    log_info "Checking operator logs for errors..."
    local pod_name=$(kubectl --context="${KUBECTL_CONTEXT}" get pods -n observability \
        -l app.kubernetes.io/name=opentelemetry-operator -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -n "${pod_name}" ]]; then
        local error_count=$(kubectl --context="${KUBECTL_CONTEXT}" logs "${pod_name}" -n observability \
            --tail=100 | grep -i error | wc -l || echo "0")
        
        if [[ ${error_count} -gt 0 ]]; then
            log_warning "Found ${error_count} errors in operator logs"
            log_info "Check logs with: kubectl logs -n observability ${pod_name}"
        else
            log_success "No errors found in operator logs"
        fi
    fi
    
    # Test creating a collector
    log_info "Testing collector creation..."
    cat <<EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: test-collector
  namespace: observability
spec:
  mode: deployment
  replicas: 1
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    processors:
      batch:
    exporters:
      debug:
        verbosity: detailed
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug]
EOF
    
    # Wait a moment and check
    sleep 5
    if kubectl --context="${KUBECTL_CONTEXT}" get deployment -n observability test-collector-collector &>/dev/null; then
        log_success "Test collector created successfully"
        
        # Clean up test
        kubectl --context="${KUBECTL_CONTEXT}" delete opentelemetrycollector -n observability test-collector
    else
        log_error "Failed to create test collector"
        exit 1
    fi
    
    log_success "OpenTelemetry Operator verification completed"
}

# Run main function
main "$@"