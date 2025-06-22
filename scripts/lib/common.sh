#!/usr/bin/env bash
# Common functions and utilities for K3s cluster bootstrap scripts

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_BASE="${SCRIPT_DIR}/../../configs/base"
source "${CONFIG_BASE}/config.env"

# Initialize logging
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/k3s-cluster-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(log "$@")"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(log "$@")"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(log "$@")"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(log "$@")" >&2
}

log_debug() {
    if [[ "${DEBUG_MODE}" == "true" ]]; then
        echo -e "[DEBUG] $(log "$@")"
    fi
}

# Error handling
set_error_trap() {
    trap 'handle_error $? $LINENO' ERR
}

handle_error() {
    local exit_code=$1
    local line_number=$2
    log_error "Script failed with exit code ${exit_code} at line ${line_number}"
    log_error "Check log file: ${LOG_FILE}"
    exit "${exit_code}"
}

# Validation functions
check_command() {
    local cmd=$1
    if ! command -v "${cmd}" &> /dev/null; then
        log_error "Required command '${cmd}' not found"
        return 1
    fi
    log_debug "Command '${cmd}' is available"
    return 0
}

check_os() {
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is designed for macOS only"
        return 1
    fi
    log_debug "Running on macOS $(sw_vers -productVersion)"
    return 0
}

check_disk_space() {
    local required_gb=$1
    local available_gb=$(df -g / | awk 'NR==2 {print $4}')
    
    if [[ ${available_gb} -lt ${required_gb} ]]; then
        log_error "Insufficient disk space. Required: ${required_gb}GB, Available: ${available_gb}GB"
        return 1
    fi
    log_debug "Disk space check passed: ${available_gb}GB available"
    return 0
}

check_ssh_connectivity() {
    local host=$1
    local user=$2
    
    log_info "Checking SSH connectivity to ${user}@${host}"
    
    if ssh ${SSH_OPTIONS} "${user}@${host}" "echo 'SSH connection successful'" &>/dev/null; then
        log_debug "SSH connection to ${host} successful"
        return 0
    else
        log_error "Cannot establish SSH connection to ${user}@${host}"
        return 1
    fi
}

check_port_availability() {
    local host=$1
    local port=$2
    
    if nc -z -w5 "${host}" "${port}" 2>/dev/null; then
        log_debug "Port ${port} on ${host} is open"
        return 0
    else
        log_warning "Port ${port} on ${host} is not accessible"
        return 1
    fi
}

# Retry logic
retry_with_backoff() {
    local max_attempts=$1
    local delay=$2
    local command="${@:3}"
    local attempt=1
    
    while [[ ${attempt} -le ${max_attempts} ]]; do
        log_debug "Attempt ${attempt}/${max_attempts}: ${command}"
        
        if eval "${command}"; then
            return 0
        fi
        
        if [[ ${attempt} -lt ${max_attempts} ]]; then
            log_warning "Command failed, retrying in ${delay} seconds..."
            sleep "${delay}"
            delay=$((delay * 2))  # Exponential backoff
        fi
        
        attempt=$((attempt + 1))
    done
    
    log_error "Command failed after ${max_attempts} attempts: ${command}"
    return 1
}

# Installation state management
save_state() {
    local state_name=$1
    local state_value=$2
    local state_file="${LOG_DIR}/.cluster-state"
    
    echo "${state_name}=${state_value}" >> "${state_file}"
    log_debug "Saved state: ${state_name}=${state_value}"
}

get_state() {
    local state_name=$1
    local state_file="${LOG_DIR}/.cluster-state"
    
    if [[ -f "${state_file}" ]]; then
        grep "^${state_name}=" "${state_file}" 2>/dev/null | cut -d'=' -f2
    fi
}

check_state() {
    local state_name=$1
    local expected_value=$2
    local current_value=$(get_state "${state_name}")
    
    [[ "${current_value}" == "${expected_value}" ]]
}

# Cleanup functions
cleanup_on_exit() {
    local exit_code=$?
    
    if [[ ${exit_code} -ne 0 ]]; then
        log_warning "Script exited with error code ${exit_code}"
        log_info "Log file saved to: ${LOG_FILE}"
    fi
    
    # Remove old log files
    find "${LOG_DIR}" -name "*.log" -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true
}

# Progress indication
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    
    while kill -0 "${pid}" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "${spinstr}"
        spinstr=${temp}${spinstr%"$temp"}
        sleep ${delay}
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Backup functions
backup_file() {
    local file=$1
    local backup_dir="${LOG_DIR}/backups"
    
    if [[ -f "${file}" ]]; then
        mkdir -p "${backup_dir}"
        local backup_file="${backup_dir}/$(basename "${file}").$(date +%Y%m%d-%H%M%S)"
        cp "${file}" "${backup_file}"
        log_debug "Backed up ${file} to ${backup_file}"
    fi
}

# Network validation
validate_ip() {
    local ip=$1
    local valid_ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ ! ${ip} =~ ${valid_ip_regex} ]]; then
        log_error "Invalid IP address: ${ip}"
        return 1
    fi
    
    # Check each octet
    IFS='.' read -ra octets <<< "${ip}"
    for octet in "${octets[@]}"; do
        if [[ ${octet} -gt 255 ]]; then
            log_error "Invalid IP address: ${ip}"
            return 1
        fi
    done
    
    return 0
}

# macOS specific functions
check_macos_firewall() {
    if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate | grep -q "enabled"; then
        log_warning "macOS firewall is enabled. K3s may require firewall exceptions."
        return 0
    fi
    log_debug "macOS firewall is disabled"
    return 0
}

check_sip_status() {
    if csrutil status | grep -q "enabled"; then
        log_warning "System Integrity Protection is enabled. Some operations may be restricted."
    fi
    return 0
}

# Set up signal handlers
trap cleanup_on_exit EXIT
trap 'log_error "Script interrupted"; exit 130' INT TERM

# Export functions for use in subshells
export -f log log_info log_success log_warning log_error log_debug
export -f check_command check_ssh_connectivity retry_with_backoff
export -f save_state get_state check_state