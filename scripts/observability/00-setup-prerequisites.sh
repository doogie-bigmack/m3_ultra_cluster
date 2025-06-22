#!/usr/bin/env bash
# Setup prerequisites for observability stack (Helm, cert-manager, etc.)

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Set error trap
set_error_trap

# Script information
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PURPOSE="Install prerequisites for OpenTelemetry observability stack"

# Helm repositories
declare -A HELM_REPOS=(
    ["prometheus-community"]="https://prometheus-community.github.io/helm-charts"
    ["grafana"]="https://grafana.github.io/helm-charts"
    ["open-telemetry"]="https://open-telemetry.github.io/opentelemetry-helm-charts"
    ["jetstack"]="https://charts.jetstack.io"
)

# Versions
CERT_MANAGER_VERSION="v1.14.2"
HELM_MIN_VERSION="3.12.0"

# Main function
main() {
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Purpose: ${SCRIPT_PURPOSE}"
    log_info "Log file: ${LOG_FILE}"
    
    # Check prerequisites
    check_prerequisites
    
    # Install/update Helm
    install_helm
    
    # Add Helm repositories
    add_helm_repos
    
    # Install cert-manager
    install_cert_manager
    
    # Create storage class if needed
    setup_storage_class
    
    log_success "Prerequisites installed successfully!"
    log_info "Next step: Run ./00-setup-storage.sh"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check kubectl
    if ! check_command "kubectl"; then
        log_error "kubectl not found. Run: brew install kubectl"
        exit 1
    fi
    
    # Check cluster connectivity
    if ! kubectl --context="${KUBECTL_CONTEXT}" cluster-info &>/dev/null; then
        log_error "Cannot connect to cluster"
        exit 1
    fi
    
    # Check if namespaces exist
    for ns in observability monitoring grafana; do
        if ! kubectl --context="${KUBECTL_CONTEXT}" get namespace ${ns} &>/dev/null; then
            log_error "Namespace ${ns} not found. Run ./00-create-namespaces.sh first"
            exit 1
        fi
    done
    
    log_success "Prerequisites check passed"
}

install_helm() {
    log_info "Checking Helm installation..."
    
    if command -v helm &>/dev/null; then
        local current_version=$(helm version --short | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/v//')
        log_info "Helm installed: ${current_version}"
        
        # Check version
        if [[ "$(printf '%s\n' "${HELM_MIN_VERSION}" "${current_version}" | sort -V | head -n1)" != "${HELM_MIN_VERSION}" ]]; then
            log_warning "Helm version ${current_version} is older than recommended ${HELM_MIN_VERSION}"
            log_info "Upgrading Helm..."
            brew upgrade helm || brew install helm
        fi
    else
        log_info "Installing Helm..."
        if ! brew install helm; then
            log_error "Failed to install Helm"
            exit 1
        fi
    fi
    
    log_success "Helm is ready: $(helm version --short)"
}

add_helm_repos() {
    log_info "Adding Helm repositories..."
    
    for repo_name in "${!HELM_REPOS[@]}"; do
        local repo_url="${HELM_REPOS[$repo_name]}"
        log_info "Adding repository: ${repo_name}"
        
        if helm repo add "${repo_name}" "${repo_url}" &>/dev/null; then
            log_success "Added repository: ${repo_name}"
        else
            log_warning "Repository ${repo_name} might already exist, updating..."
        fi
    done
    
    # Update all repos
    log_info "Updating Helm repositories..."
    if ! helm repo update; then
        log_error "Failed to update Helm repositories"
        exit 1
    fi
    
    log_success "Helm repositories updated"
}

install_cert_manager() {
    log_info "Installing cert-manager (required for OTel Operator)..."
    
    # Check if already installed
    if kubectl --context="${KUBECTL_CONTEXT}" get deployment -n cert-manager cert-manager &>/dev/null; then
        log_info "cert-manager already installed"
        
        # Check version
        local installed_version=$(kubectl --context="${KUBECTL_CONTEXT}" get deployment -n cert-manager cert-manager \
            -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
        
        if [[ "${installed_version}" == "${CERT_MANAGER_VERSION}" ]]; then
            log_success "cert-manager ${installed_version} is already at desired version"
            return 0
        else
            log_info "Upgrading cert-manager from ${installed_version} to ${CERT_MANAGER_VERSION}"
        fi
    fi
    
    # Create namespace
    kubectl --context="${KUBECTL_CONTEXT}" create namespace cert-manager --dry-run=client -o yaml | \
        kubectl --context="${KUBECTL_CONTEXT}" apply -f - &>/dev/null
    
    # Install CRDs
    log_info "Installing cert-manager CRDs..."
    kubectl --context="${KUBECTL_CONTEXT}" apply -f \
        "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml"
    
    # Install cert-manager using Helm
    log_info "Installing cert-manager components..."
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --version ${CERT_MANAGER_VERSION#v} \
        --set installCRDs=false \
        --set global.leaderElection.namespace=cert-manager \
        --wait --timeout 5m
    
    # Wait for cert-manager to be ready
    log_info "Waiting for cert-manager to be ready..."
    kubectl --context="${KUBECTL_CONTEXT}" wait --for=condition=available \
        --timeout=300s deployment/cert-manager -n cert-manager
    kubectl --context="${KUBECTL_CONTEXT}" wait --for=condition=available \
        --timeout=300s deployment/cert-manager-webhook -n cert-manager
    kubectl --context="${KUBECTL_CONTEXT}" wait --for=condition=available \
        --timeout=300s deployment/cert-manager-cainjector -n cert-manager
    
    log_success "cert-manager ${CERT_MANAGER_VERSION} installed successfully"
}

setup_storage_class() {
    log_info "Checking storage class configuration..."
    
    # Check if NFS storage class exists
    if kubectl --context="${KUBECTL_CONTEXT}" get storageclass nfs-storage &>/dev/null; then
        log_success "NFS storage class already exists"
    else
        log_warning "NFS storage class not found"
        log_info "Make sure to run storage setup scripts or create storage class manually"
    fi
    
    # Check default storage class
    local default_sc=$(kubectl --context="${KUBECTL_CONTEXT}" get storageclass \
        -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
    
    if [[ -n "${default_sc}" ]]; then
        log_info "Default storage class: ${default_sc}"
    else
        log_warning "No default storage class set"
    fi
}

# Run main function
main "$@"