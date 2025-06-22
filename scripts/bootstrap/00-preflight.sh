#!/usr/bin/env bash
# Preflight checks for K3s cluster installation

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Set error trap
set_error_trap

# Script information
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PURPOSE="Run preflight checks before cluster installation"

# Main function
main() {
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Purpose: ${SCRIPT_PURPOSE}"
    log_info "Log file: ${LOG_FILE}"
    
    local checks_passed=true
    
    log_info "=== PREFLIGHT CHECKS ==="
    
    # System checks
    run_system_checks || checks_passed=false
    
    # Configuration checks
    run_config_checks || checks_passed=false
    
    # Network checks
    run_network_checks || checks_passed=false
    
    # SSH connectivity checks
    run_ssh_checks || checks_passed=false
    
    # Security checks
    run_security_checks || checks_passed=false
    
    if [[ "${checks_passed}" == "true" ]]; then
        log_success "All preflight checks passed!"
        log_info "System is ready for K3s installation"
        log_info "Next step: Run ./01-install-deps.sh"
    else
        log_error "Some preflight checks failed"
        log_info "Please resolve the issues above before proceeding"
        exit 1
    fi
}

run_system_checks() {
    log_info "Running system checks..."
    local system_ok=true
    
    # Check OS
    if check_os; then
        log_success "✓ Operating system: macOS $(sw_vers -productVersion)"
    else
        log_error "✗ Operating system check failed"
        system_ok=false
    fi
    
    # Check architecture
    local arch=$(uname -m)
    if [[ "${arch}" == "arm64" ]]; then
        log_success "✓ Architecture: ${arch} (Apple Silicon)"
    else
        log_error "✗ Architecture: ${arch} (Expected arm64/Apple Silicon)"
        system_ok=false
    fi
    
    # Check disk space
    local available_gb=$(df -g / | awk 'NR==2 {print $4}')
    if [[ ${available_gb} -ge ${MIN_DISK_SPACE_GB} ]]; then
        log_success "✓ Disk space: ${available_gb}GB available (minimum: ${MIN_DISK_SPACE_GB}GB)"
    else
        log_error "✗ Disk space: ${available_gb}GB available (minimum: ${MIN_DISK_SPACE_GB}GB)"
        system_ok=false
    fi
    
    # Check memory
    local total_mem_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    if [[ ${total_mem_gb} -ge ${MIN_MEMORY_GB} ]]; then
        log_success "✓ Memory: ${total_mem_gb}GB (minimum: ${MIN_MEMORY_GB}GB)"
    else
        log_error "✗ Memory: ${total_mem_gb}GB (minimum: ${MIN_MEMORY_GB}GB)"
        system_ok=false
    fi
    
    # Check CPU cores
    local cpu_cores=$(sysctl -n hw.ncpu)
    if [[ ${cpu_cores} -ge ${MIN_CPU_CORES} ]]; then
        log_success "✓ CPU cores: ${cpu_cores} (minimum: ${MIN_CPU_CORES})"
    else
        log_error "✗ CPU cores: ${cpu_cores} (minimum: ${MIN_CPU_CORES})"
        system_ok=false
    fi
    
    # Check SIP status
    check_sip_status
    
    # Check firewall status
    check_macos_firewall
    
    return $([ "${system_ok}" == "true" ] && echo 0 || echo 1)
}

run_config_checks() {
    log_info "Running configuration checks..."
    local config_ok=true
    
    # Check if config.env exists
    if [[ -f "${CONFIG_BASE}/config.env" ]]; then
        log_success "✓ Configuration file exists"
    else
        log_error "✗ Configuration file not found: ${CONFIG_BASE}/config.env"
        log_info "  Copy config.env.example to config.env and update values"
        config_ok=false
        return 1
    fi
    
    # Validate control plane IP
    if validate_ip "${CONTROL_PLANE_IP}"; then
        log_success "✓ Control plane IP: ${CONTROL_PLANE_IP}"
    else
        log_error "✗ Invalid control plane IP: ${CONTROL_PLANE_IP}"
        config_ok=false
    fi
    
    # Validate worker IPs
    if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
        log_success "✓ Worker nodes configured: ${#WORKER_IPS[@]}"
        for ip in "${WORKER_IPS[@]}"; do
            if ! validate_ip "${ip}"; then
                log_error "✗ Invalid worker IP: ${ip}"
                config_ok=false
            fi
        done
    else
        log_warning "⚠ No worker nodes configured"
    fi
    
    # Check SSH key
    if [[ -f "${SSH_KEY_PATH}" ]]; then
        log_success "✓ SSH key found: ${SSH_KEY_PATH}"
    else
        log_error "✗ SSH key not found: ${SSH_KEY_PATH}"
        log_info "  Generate with: ssh-keygen -t rsa -b 4096"
        config_ok=false
    fi
    
    return $([ "${config_ok}" == "true" ] && echo 0 || echo 1)
}

run_network_checks() {
    log_info "Running network checks..."
    local network_ok=true
    
    # Check if control plane IP is reachable
    log_info "Checking control plane connectivity..."
    if ping -c 1 -W 2 "${CONTROL_PLANE_IP}" &>/dev/null; then
        log_success "✓ Control plane reachable: ${CONTROL_PLANE_IP}"
    else
        log_error "✗ Cannot reach control plane: ${CONTROL_PLANE_IP}"
        network_ok=false
    fi
    
    # Check worker connectivity
    for ip in "${WORKER_IPS[@]}"; do
        if ping -c 1 -W 2 "${ip}" &>/dev/null; then
            log_success "✓ Worker reachable: ${ip}"
        else
            log_error "✗ Cannot reach worker: ${ip}"
            network_ok=false
        fi
    done
    
    # Check for port conflicts
    log_info "Checking for port conflicts..."
    local k3s_ports=(6443 10250 10251 10252 2379 2380)
    for port in "${k3s_ports[@]}"; do
        if lsof -iTCP:${port} -sTCP:LISTEN &>/dev/null; then
            log_warning "⚠ Port ${port} is already in use"
        fi
    done
    
    return $([ "${network_ok}" == "true" ] && echo 0 || echo 1)
}

run_ssh_checks() {
    log_info "Running SSH connectivity checks..."
    local ssh_ok=true
    
    # Check control plane SSH
    local control_user=$(get_ssh_user "${CONTROL_PLANE_IP}")
    if check_ssh_connectivity "${CONTROL_PLANE_IP}" "${control_user}"; then
        log_success "✓ SSH to control plane: ${control_user}@${CONTROL_PLANE_IP}"
    else
        log_error "✗ Cannot SSH to control plane: ${control_user}@${CONTROL_PLANE_IP}"
        log_info "  Run: ssh-copy-id ${control_user}@${CONTROL_PLANE_IP}"
        ssh_ok=false
    fi
    
    # Check worker SSH
    for ip in "${WORKER_IPS[@]}"; do
        local worker_user=$(get_ssh_user "${ip}")
        if check_ssh_connectivity "${ip}" "${worker_user}"; then
            log_success "✓ SSH to worker: ${worker_user}@${ip}"
        else
            log_error "✗ Cannot SSH to worker: ${worker_user}@${ip}"
            log_info "  Run: ssh-copy-id ${worker_user}@${ip}"
            ssh_ok=false
        fi
    done
    
    return $([ "${ssh_ok}" == "true" ] && echo 0 || echo 1)
}

run_security_checks() {
    log_info "Running security checks..."
    
    # Check for sensitive data in config
    if grep -q "password\|token\|secret" "${CONFIG_BASE}/config.env" 2>/dev/null; then
        log_warning "⚠ Possible sensitive data found in config.env"
        log_info "  Consider using environment variables for secrets"
    fi
    
    # Check SSH key permissions
    if [[ -f "${SSH_KEY_PATH}" ]]; then
        local key_perms=$(stat -f "%A" "${SSH_KEY_PATH}")
        if [[ "${key_perms}" != "600" ]]; then
            log_warning "⚠ SSH key has loose permissions: ${key_perms}"
            log_info "  Fix with: chmod 600 ${SSH_KEY_PATH}"
        fi
    fi
    
    # Check for .env.local
    if [[ ! -f "${CONFIG_BASE}/.env.local" ]]; then
        log_info "ℹ Consider creating .env.local for sensitive values"
    fi
    
    return 0
}

# Run main function
main "$@"