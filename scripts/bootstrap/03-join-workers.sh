#!/usr/bin/env bash
# Join worker nodes to K3s cluster with comprehensive error handling and logging

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Set error trap
set_error_trap

# Script information
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PURPOSE="Join worker nodes to K3s cluster"

# Track join results
declare -A JOIN_RESULTS

# Main function
main() {
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Purpose: ${SCRIPT_PURPOSE}"
    log_info "Log file: ${LOG_FILE}"
    
    # Pre-flight checks
    run_preflight_checks
    
    # Validate control plane
    validate_control_plane
    
    # Get node token
    get_node_token
    
    # Check worker nodes
    check_worker_nodes
    
    # Join workers
    join_all_workers
    
    # Verify cluster
    verify_cluster
    
    # Print summary
    print_summary
    
    log_success "Worker join process completed!"
}

run_preflight_checks() {
    log_info "Running pre-flight checks..."
    
    # Check OS
    check_os || exit 1
    
    # Check required commands
    for cmd in k3sup kubectl ssh; do
        check_command "$cmd" || exit 1
    done
    
    # Check if control plane is initialized
    if ! check_state "control_plane_initialized" "true"; then
        log_error "Control plane not initialized. Run ./01-init-control-plane.sh first"
        exit 1
    fi
    
    # Validate configuration
    if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
        log_error "No worker IPs configured in config.env"
        exit 1
    fi
    
    log_info "Found ${#WORKER_IPS[@]} worker nodes to join"
    
    # Check kubeconfig
    if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
        log_error "Kubeconfig not found at ${KUBECONFIG_PATH}"
        exit 1
    fi
    
    export KUBECONFIG="${KUBECONFIG_PATH}"
    
    log_success "Pre-flight checks completed"
}

validate_control_plane() {
    log_info "Validating control plane..."
    
    # Check if we can connect to cluster
    if ! kubectl --context="${KUBECTL_CONTEXT}" get nodes &>/dev/null; then
        log_error "Cannot connect to cluster. Is the control plane running?"
        exit 1
    fi
    
    # Get control plane status
    local control_status=$(kubectl --context="${KUBECTL_CONTEXT}" get nodes \
        -l node-role.kubernetes.io/master -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
    
    if [[ "${control_status}" != "True" ]]; then
        log_error "Control plane is not ready"
        exit 1
    fi
    
    log_success "Control plane is ready"
}

get_node_token() {
    log_info "Retrieving node join token..."
    
    # Check for saved token
    local token_file="${LOG_DIR}/.k3s-node-token"
    
    if [[ -f "${token_file}" ]]; then
        NODE_TOKEN=$(cat "${token_file}")
        log_debug "Using saved node token"
    else
        # Retrieve from control plane
        log_info "Fetching token from control plane..."
        NODE_TOKEN=$(ssh ${SSH_OPTIONS} "${SSH_USER}@${CONTROL_PLANE_IP}" \
            "sudo cat /var/lib/rancher/k3s/server/node-token")
        
        if [[ -z "${NODE_TOKEN}" ]]; then
            log_error "Failed to retrieve node token"
            exit 1
        fi
        
        # Save for future use
        echo "${NODE_TOKEN}" > "${token_file}"
        chmod 600 "${token_file}"
    fi
    
    log_success "Node token retrieved"
}

check_worker_nodes() {
    log_info "Checking worker nodes..."
    
    local available_nodes=0
    local already_joined=0
    
    for ip in "${WORKER_IPS[@]}"; do
        log_info "Checking node ${ip}..."
        
        # Validate IP
        if ! validate_ip "${ip}"; then
            log_error "Invalid IP address: ${ip}"
            JOIN_RESULTS["${ip}"]="invalid_ip"
            continue
        fi
        
        # Check SSH connectivity
        if ! check_ssh_connectivity "${ip}" "${SSH_USER}"; then
            log_warning "Cannot connect to ${ip} via SSH"
            JOIN_RESULTS["${ip}"]="ssh_failed"
            continue
        fi
        
        # Check if already joined
        if kubectl --context="${KUBECTL_CONTEXT}" get node "${ip}" &>/dev/null; then
            log_info "Node ${ip} is already part of the cluster"
            JOIN_RESULTS["${ip}"]="already_joined"
            already_joined=$((already_joined + 1))
            continue
        fi
        
        # Check if K3s is already running
        if ssh ${SSH_OPTIONS} "${SSH_USER}@${ip}" \
            "pgrep -f 'k3s agent' > /dev/null 2>&1"; then
            log_warning "K3s agent already running on ${ip} but not in cluster"
            JOIN_RESULTS["${ip}"]="orphaned"
        else
            JOIN_RESULTS["${ip}"]="ready"
            available_nodes=$((available_nodes + 1))
        fi
    done
    
    log_info "Node check summary:"
    log_info "  - Ready to join: ${available_nodes}"
    log_info "  - Already joined: ${already_joined}"
    log_info "  - Unavailable: $((${#WORKER_IPS[@]} - available_nodes - already_joined))"
    
    if [[ ${available_nodes} -eq 0 ]] && [[ "${FORCE:-false}" != "true" ]]; then
        log_warning "No nodes available to join. Use FORCE=true to retry failed nodes"
        exit 0
    fi
}

join_worker() {
    local worker_ip=$1
    local status="${JOIN_RESULTS[${worker_ip}]}"
    
    # Skip if already joined (unless forced)
    if [[ "${status}" == "already_joined" ]] && [[ "${FORCE:-false}" != "true" ]]; then
        log_info "Skipping ${worker_ip} - already joined"
        return 0
    fi
    
    # Skip if SSH failed
    if [[ "${status}" == "ssh_failed" ]] || [[ "${status}" == "invalid_ip" ]]; then
        log_warning "Skipping ${worker_ip} - ${status}"
        return 1
    fi
    
    log_info "Joining worker node ${worker_ip}..."
    
    # Clean up orphaned K3s if needed
    if [[ "${status}" == "orphaned" ]]; then
        log_info "Cleaning up orphaned K3s installation on ${worker_ip}..."
        ssh ${SSH_OPTIONS} "${SSH_USER}@${worker_ip}" \
            "sudo /usr/local/bin/k3s-uninstall.sh || true" &>/dev/null || true
    fi
    
    # Build k3sup join command
    local k3sup_cmd="k3sup join"
    k3sup_cmd+=" --ip ${worker_ip}"
    k3sup_cmd+=" --user ${SSH_USER}"
    k3sup_cmd+=" --server-ip ${CONTROL_PLANE_IP}"
    k3sup_cmd+=" --server-user ${SSH_USER}"
    
    # SSH key if specified
    if [[ -n "${SSH_KEY_PATH}" ]] && [[ -f "${SSH_KEY_PATH}" ]]; then
        k3sup_cmd+=" --ssh-key ${SSH_KEY_PATH}"
    fi
    
    # K3s version if specified
    if [[ "${K3S_VERSION}" != "latest" ]]; then
        k3sup_cmd+=" --k3s-version ${K3S_VERSION}"
    fi
    
    log_debug "Join command: ${k3sup_cmd}"
    
    # Execute join with retry
    if retry_with_backoff ${MAX_RETRIES} ${RETRY_DELAY} "${k3sup_cmd}"; then
        log_success "Successfully joined ${worker_ip}"
        JOIN_RESULTS["${worker_ip}"]="joined"
        save_state "worker_${worker_ip}_joined" "true"
        return 0
    else
        log_error "Failed to join ${worker_ip}"
        JOIN_RESULTS["${worker_ip}"]="join_failed"
        
        # Get logs from failed node
        log_debug "Fetching logs from failed node..."
        ssh ${SSH_OPTIONS} "${SSH_USER}@${worker_ip}" \
            "sudo journalctl -u k3s-agent -n 30 --no-pager" 2>/dev/null || true
        
        return 1
    fi
}

join_all_workers() {
    log_info "Starting worker join process..."
    
    local successful_joins=0
    local failed_joins=0
    
    # Check if parallel joining is enabled
    if [[ "${PARALLEL_JOIN:-false}" == "true" ]]; then
        log_info "Joining workers in parallel..."
        
        # Create temporary directory for job tracking
        local job_dir=$(mktemp -d)
        
        for ip in "${WORKER_IPS[@]}"; do
            {
                if join_worker "${ip}"; then
                    touch "${job_dir}/${ip}.success"
                else
                    touch "${job_dir}/${ip}.failed"
                fi
            } &
        done
        
        # Wait for all jobs
        wait
        
        # Count results
        successful_joins=$(find "${job_dir}" -name "*.success" | wc -l | tr -d ' ')
        failed_joins=$(find "${job_dir}" -name "*.failed" | wc -l | tr -d ' ')
        
        rm -rf "${job_dir}"
    else
        # Sequential joining
        log_info "Joining workers sequentially..."
        
        for ip in "${WORKER_IPS[@]}"; do
            if join_worker "${ip}"; then
                successful_joins=$((successful_joins + 1))
            else
                failed_joins=$((failed_joins + 1))
            fi
            
            # Add delay between joins to avoid overloading control plane
            if [[ ${successful_joins} -gt 0 ]]; then
                log_debug "Waiting before next join..."
                sleep 5
            fi
        done
    fi
    
    log_info "Join process completed:"
    log_info "  - Successful: ${successful_joins}"
    log_info "  - Failed: ${failed_joins}"
    
    if [[ ${failed_joins} -gt 0 ]] && [[ ${successful_joins} -eq 0 ]]; then
        log_error "All worker joins failed"
        exit 1
    fi
}

verify_cluster() {
    log_info "Verifying cluster state..."
    
    # Wait for nodes to appear in cluster
    log_info "Waiting for nodes to register..."
    sleep 10
    
    # Get all nodes
    log_info "Current cluster nodes:"
    kubectl --context="${KUBECTL_CONTEXT}" get nodes -o wide
    
    # Wait for nodes to be ready
    log_info "Waiting for all nodes to be ready..."
    local ready_timeout=300
    local start_time=$(date +%s)
    
    while true; do
        local not_ready=$(kubectl --context="${KUBECTL_CONTEXT}" get nodes \
            -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status!="True")].metadata.name}')
        
        if [[ -z "${not_ready}" ]]; then
            log_success "All nodes are ready"
            break
        fi
        
        local elapsed=$(($(date +%s) - start_time))
        if [[ ${elapsed} -gt ${ready_timeout} ]]; then
            log_warning "Timeout waiting for nodes to be ready"
            log_warning "Not ready nodes: ${not_ready}"
            break
        fi
        
        log_debug "Waiting for nodes: ${not_ready}"
        sleep 5
    done
    
    # Check system pods
    log_info "Checking system pods..."
    kubectl --context="${KUBECTL_CONTEXT}" get pods -n kube-system
    
    # Run cluster diagnostics
    log_info "Running cluster diagnostics..."
    
    # Check node resources
    kubectl --context="${KUBECTL_CONTEXT}" top nodes || log_warning "Metrics server not installed"
    
    # Check for any issues
    local problem_pods=$(kubectl --context="${KUBECTL_CONTEXT}" get pods -A \
        --field-selector=status.phase!=Running,status.phase!=Succeeded -o name | wc -l | tr -d ' ')
    
    if [[ ${problem_pods} -gt 0 ]]; then
        log_warning "Found ${problem_pods} pods not in Running state"
        kubectl --context="${KUBECTL_CONTEXT}" get pods -A \
            --field-selector=status.phase!=Running,status.phase!=Succeeded
    fi
}

print_summary() {
    log_info "========== Cluster Join Summary =========="
    
    # Print results for each node
    for ip in "${WORKER_IPS[@]}"; do
        local status="${JOIN_RESULTS[${ip}]}"
        case "${status}" in
            "joined")
                log_success "✓ ${ip}: Successfully joined"
                ;;
            "already_joined")
                log_info "• ${ip}: Already in cluster"
                ;;
            "join_failed")
                log_error "✗ ${ip}: Join failed"
                ;;
            "ssh_failed")
                log_error "✗ ${ip}: SSH connection failed"
                ;;
            "invalid_ip")
                log_error "✗ ${ip}: Invalid IP address"
                ;;
            *)
                log_warning "? ${ip}: Unknown status"
                ;;
        esac
    done
    
    log_info "========================================"
    
    # Save summary to file
    local summary_file="${LOG_DIR}/worker-join-summary-$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "Worker Join Summary - $(date)"
        echo "================================"
        for ip in "${WORKER_IPS[@]}"; do
            echo "${ip}: ${JOIN_RESULTS[${ip}]}"
        done
        echo ""
        echo "Cluster State:"
        kubectl --context="${KUBECTL_CONTEXT}" get nodes
    } > "${summary_file}"
    
    log_info "Summary saved to: ${summary_file}"
    
    # Next steps
    log_info "Next steps:"
    log_info "  1. Run ./03-nfs-setup.sh to configure shared storage"
    log_info "  2. Run ./validate-cluster.sh to verify cluster health"
}

# Run main function
main "$@"