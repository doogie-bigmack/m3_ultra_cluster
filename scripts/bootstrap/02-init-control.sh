#!/usr/bin/env bash
# Initialize K3s control plane with comprehensive error handling and logging

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Set error trap
set_error_trap

# Script information
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PURPOSE="Initialize K3s control plane node"

# Main function
main() {
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Purpose: ${SCRIPT_PURPOSE}"
    log_info "Log file: ${LOG_FILE}"
    
    # Pre-flight checks
    run_preflight_checks
    
    # Validate configuration
    validate_configuration
    
    # Check if control plane already exists
    if check_existing_control_plane; then
        log_warning "Control plane already exists"
        if [[ "${FORCE_REINSTALL:-false}" != "true" ]]; then
            log_info "Use FORCE_REINSTALL=true to reinitialize"
            exit 0
        fi
        log_warning "Force reinstall requested - proceeding with caution"
    fi
    
    # Initialize control plane
    init_control_plane
    
    # Verify installation
    verify_control_plane
    
    # Save cluster information
    save_cluster_info
    
    log_success "Control plane initialized successfully!"
    log_info "Cluster context: ${KUBECTL_CONTEXT}"
    log_info "Next step: Run ./02-join-workers.sh to add worker nodes"
}

run_preflight_checks() {
    log_info "Running pre-flight checks..."
    
    # Check OS
    check_os || exit 1
    
    # Check required commands
    for cmd in k3sup kubectl ssh; do
        check_command "$cmd" || exit 1
    done
    
    # Validate IP address
    validate_ip "${CONTROL_PLANE_IP}" || exit 1
    
    # Check SSH connectivity
    check_ssh_connectivity "${CONTROL_PLANE_IP}" "${SSH_USER}" || {
        log_error "Cannot connect to control plane node"
        log_info "Ensure:"
        log_info "  1. SSH keys are configured: ssh-copy-id ${SSH_USER}@${CONTROL_PLANE_IP}"
        log_info "  2. The node is reachable: ping ${CONTROL_PLANE_IP}"
        log_info "  3. SSH is enabled on the target node"
        exit 1
    }
    
    # Check if node is macOS
    log_info "Checking target node OS..."
    if ! ssh ${SSH_OPTIONS} "${SSH_USER}@${CONTROL_PLANE_IP}" "uname" | grep -q "Darwin"; then
        log_error "Target node is not running macOS"
        exit 1
    fi
    
    # Check disk space on target
    log_info "Checking disk space on target node..."
    local available_space=$(ssh ${SSH_OPTIONS} "${SSH_USER}@${CONTROL_PLANE_IP}" \
        "df -g / | awk 'NR==2 {print \$4}'")
    
    if [[ ${available_space} -lt ${MIN_DISK_SPACE_GB} ]]; then
        log_error "Insufficient disk space on target. Required: ${MIN_DISK_SPACE_GB}GB, Available: ${available_space}GB"
        exit 1
    fi
    
    # Check firewall on target
    log_info "Checking firewall status on target node..."
    if ssh ${SSH_OPTIONS} "${SSH_USER}@${CONTROL_PLANE_IP}" \
        "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate" | grep -q "enabled"; then
        log_warning "Firewall is enabled on target node. K3s requires ports 6443, 10250 to be open"
    fi
    
    # Backup existing kubeconfig
    backup_file "${KUBECONFIG_PATH}"
    
    log_success "Pre-flight checks completed"
}

validate_configuration() {
    log_info "Validating configuration..."
    
    # Check required environment variables
    if [[ -z "${CONTROL_PLANE_IP}" ]]; then
        log_error "CONTROL_PLANE_IP is not set"
        exit 1
    fi
    
    if [[ -z "${SSH_USER}" ]]; then
        log_error "SSH_USER is not set"
        exit 1
    fi
    
    # Ensure kubeconfig directory exists
    local kube_dir=$(dirname "${KUBECONFIG_PATH}")
    if [[ ! -d "${kube_dir}" ]]; then
        log_info "Creating ${kube_dir} directory..."
        mkdir -p "${kube_dir}"
        chmod 700 "${kube_dir}"
    fi
    
    log_success "Configuration validated"
}

check_existing_control_plane() {
    log_info "Checking for existing control plane..."
    
    # Check if k3s is already running on target
    if ssh ${SSH_OPTIONS} "${SSH_USER}@${CONTROL_PLANE_IP}" \
        "pgrep -f 'k3s server' > /dev/null 2>&1"; then
        log_info "K3s server is already running on ${CONTROL_PLANE_IP}"
        return 0
    fi
    
    # Check if we have a working kubeconfig for this cluster
    if [[ -f "${KUBECONFIG_PATH}" ]] && \
       kubectl --kubeconfig="${KUBECONFIG_PATH}" --context="${KUBECTL_CONTEXT}" \
       get nodes &>/dev/null; then
        log_info "Existing cluster context found: ${KUBECTL_CONTEXT}"
        return 0
    fi
    
    return 1
}

init_control_plane() {
    log_info "Initializing K3s control plane on ${CONTROL_PLANE_IP}..."
    
    # Build k3sup install command
    local k3sup_cmd="k3sup install"
    k3sup_cmd+=" --ip ${CONTROL_PLANE_IP}"
    k3sup_cmd+=" --user ${SSH_USER}"
    k3sup_cmd+=" --local-path ${KUBECONFIG_PATH}"
    k3sup_cmd+=" --context ${KUBECTL_CONTEXT}"
    
    # Add K3s version if specified
    if [[ "${K3S_VERSION}" != "latest" ]]; then
        k3sup_cmd+=" --k3s-version ${K3S_VERSION}"
    fi
    
    # Add K3s extra args for macOS compatibility
    k3sup_cmd+=" --k3s-extra-args '--disable=traefik'"
    k3sup_cmd+=" --k3s-extra-args '--cluster-cidr=${POD_CIDR}'"
    k3sup_cmd+=" --k3s-extra-args '--service-cidr=${SERVICE_CIDR}'"
    k3sup_cmd+=" --k3s-extra-args '--write-kubeconfig-mode=644'"
    
    # SSH key if specified
    if [[ -n "${SSH_KEY_PATH}" ]] && [[ -f "${SSH_KEY_PATH}" ]]; then
        k3sup_cmd+=" --ssh-key ${SSH_KEY_PATH}"
    fi
    
    log_info "Running k3sup command..."
    log_debug "Command: ${k3sup_cmd}"
    
    # Run k3sup with retry logic
    if ! retry_with_backoff ${MAX_RETRIES} ${RETRY_DELAY} "${k3sup_cmd}"; then
        log_error "Failed to initialize control plane"
        
        # Get logs from target node
        log_info "Fetching K3s logs from target node..."
        ssh ${SSH_OPTIONS} "${SSH_USER}@${CONTROL_PLANE_IP}" \
            "sudo journalctl -u k3s -n 50 --no-pager" || true
        
        exit 1
    fi
    
    log_success "K3s control plane initialized"
    
    # Save installation state
    save_state "control_plane_initialized" "true"
    save_state "control_plane_ip" "${CONTROL_PLANE_IP}"
    save_state "k3s_version" "${K3S_VERSION}"
}

verify_control_plane() {
    log_info "Verifying control plane installation..."
    
    # Set kubeconfig for verification
    export KUBECONFIG="${KUBECONFIG_PATH}"
    
    # Wait for API server to be ready
    log_info "Waiting for API server to be ready..."
    local attempts=0
    local max_attempts=30
    
    while [[ ${attempts} -lt ${max_attempts} ]]; do
        if kubectl --context="${KUBECTL_CONTEXT}" get nodes &>/dev/null; then
            break
        fi
        
        attempts=$((attempts + 1))
        log_debug "Waiting for API server... (${attempts}/${max_attempts})"
        sleep 5
    done
    
    if [[ ${attempts} -eq ${max_attempts} ]]; then
        log_error "API server failed to become ready"
        exit 1
    fi
    
    log_success "API server is ready"
    
    # Get node status
    log_info "Checking node status..."
    kubectl --context="${KUBECTL_CONTEXT}" get nodes
    
    # Wait for node to be ready
    log_info "Waiting for node to be ready..."
    if ! kubectl --context="${KUBECTL_CONTEXT}" wait --for=condition=Ready \
         node --all --timeout=300s; then
        log_error "Node failed to become ready"
        exit 1
    fi
    
    log_success "Control plane node is ready"
    
    # Check system pods
    log_info "Checking system pods..."
    kubectl --context="${KUBECTL_CONTEXT}" get pods -n kube-system
    
    # Get cluster info
    log_info "Cluster information:"
    kubectl --context="${KUBECTL_CONTEXT}" cluster-info
}

save_cluster_info() {
    log_info "Saving cluster information..."
    
    # Get node token for joining workers
    log_info "Retrieving node token..."
    local node_token=$(ssh ${SSH_OPTIONS} "${SSH_USER}@${CONTROL_PLANE_IP}" \
        "sudo cat /var/lib/rancher/k3s/server/node-token")
    
    if [[ -z "${node_token}" ]]; then
        log_error "Failed to retrieve node token"
        exit 1
    fi
    
    # Save token securely
    local token_file="${LOG_DIR}/.k3s-node-token"
    echo "${node_token}" > "${token_file}"
    chmod 600 "${token_file}"
    
    log_success "Node token saved to ${token_file}"
    
    # Save cluster summary
    local summary_file="${LOG_DIR}/cluster-summary.txt"
    {
        echo "Cluster Name: ${CLUSTER_NAME}"
        echo "Control Plane IP: ${CONTROL_PLANE_IP}"
        echo "Context: ${KUBECTL_CONTEXT}"
        echo "Kubeconfig: ${KUBECONFIG_PATH}"
        echo "Token File: ${token_file}"
        echo "K3s Version: ${K3S_VERSION}"
        echo "Pod CIDR: ${POD_CIDR}"
        echo "Service CIDR: ${SERVICE_CIDR}"
        echo "Initialized: $(date)"
    } > "${summary_file}"
    
    log_info "Cluster summary saved to ${summary_file}"
    
    # Create convenience script for kubectl
    local kubectl_script="${SCRIPT_DIR}/kubectl-${CLUSTER_NAME}.sh"
    cat > "${kubectl_script}" << EOF
#!/usr/bin/env bash
# Convenience script for kubectl with ${CLUSTER_NAME} context
export KUBECONFIG="${KUBECONFIG_PATH}"
kubectl --context="${KUBECTL_CONTEXT}" "\$@"
EOF
    chmod +x "${kubectl_script}"
    
    log_info "Created kubectl convenience script: ${kubectl_script}"
}

# Run main function
main "$@"