#!/usr/bin/env bash
# Install k3sup and kubectl on macOS with comprehensive error handling and logging

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Set error trap
set_error_trap

# Script information
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PURPOSE="Install k3sup and kubectl for K3s cluster management"

# Main installation function
main() {
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Purpose: ${SCRIPT_PURPOSE}"
    log_info "Log file: ${LOG_FILE}"
    
    # Pre-flight checks
    log_info "Running pre-flight checks..."
    
    # Check OS
    check_os || exit 1
    
    # Check disk space
    check_disk_space 5 || exit 1
    
    # Check if already installed
    if check_state "k3sup_installed" "true" && check_state "kubectl_installed" "true"; then
        log_info "k3sup and kubectl are already installed"
        
        if [[ "${FORCE_REINSTALL:-false}" != "true" ]]; then
            log_success "Installation already complete. Use FORCE_REINSTALL=true to reinstall."
            exit 0
        fi
        
        log_warning "Force reinstall requested"
    fi
    
    # Check for Homebrew
    log_info "Checking for Homebrew..."
    if ! check_command "brew"; then
        log_error "Homebrew is not installed"
        log_info "Please install Homebrew first: https://brew.sh"
        log_info "Run: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
    
    log_success "Homebrew is installed: $(brew --version | head -n1)"
    
    # Update Homebrew
    log_info "Updating Homebrew..."
    if ! brew update &>/dev/null; then
        log_warning "Failed to update Homebrew, continuing anyway"
    else
        log_success "Homebrew updated successfully"
    fi
    
    # Install k3sup
    install_k3sup
    
    # Install kubectl
    install_kubectl
    
    # Verify installations
    verify_installations
    
    # Configure kubectl
    configure_kubectl
    
    log_success "Installation completed successfully!"
    log_info "Next steps:"
    log_info "  1. Run ./01-init-control-plane.sh to initialize the control plane"
    log_info "  2. Run ./02-join-workers.sh to add worker nodes"
}

install_k3sup() {
    log_info "Installing k3sup..."
    
    # Check if already installed
    if command -v k3sup &>/dev/null; then
        local current_version=$(k3sup version 2>/dev/null || echo "unknown")
        log_info "k3sup is already installed (version: ${current_version})"
        
        # Check if it's from Homebrew
        if brew list k3sup &>/dev/null; then
            log_info "Upgrading k3sup via Homebrew..."
            retry_with_backoff ${MAX_RETRIES} ${RETRY_DELAY} "brew upgrade k3sup || brew install k3sup"
        else
            log_warning "k3sup was not installed via Homebrew, reinstalling..."
            retry_with_backoff ${MAX_RETRIES} ${RETRY_DELAY} "brew install k3sup"
        fi
    else
        # Fresh installation
        log_info "Installing k3sup via Homebrew..."
        retry_with_backoff ${MAX_RETRIES} ${RETRY_DELAY} "brew install k3sup"
    fi
    
    # Verify installation
    if ! command -v k3sup &>/dev/null; then
        log_error "Failed to install k3sup"
        return 1
    fi
    
    local installed_version=$(k3sup version 2>/dev/null || echo "unknown")
    log_success "k3sup installed successfully (version: ${installed_version})"
    save_state "k3sup_installed" "true"
    save_state "k3sup_version" "${installed_version}"
    
    # Log k3sup path
    log_debug "k3sup path: $(which k3sup)"
}

install_kubectl() {
    log_info "Installing kubectl..."
    
    # Check if already installed
    if command -v kubectl &>/dev/null; then
        local current_version=$(kubectl version --client --short 2>/dev/null || kubectl version --client -o yaml | grep gitVersion | head -1 | awk '{print $2}')
        log_info "kubectl is already installed (version: ${current_version})"
        
        # Check if it's from Homebrew
        if brew list kubectl &>/dev/null; then
            log_info "Upgrading kubectl via Homebrew..."
            retry_with_backoff ${MAX_RETRIES} ${RETRY_DELAY} "brew upgrade kubectl || brew install kubectl"
        else
            log_warning "kubectl was not installed via Homebrew, reinstalling..."
            retry_with_backoff ${MAX_RETRIES} ${RETRY_DELAY} "brew install kubectl"
        fi
    else
        # Fresh installation
        log_info "Installing kubectl via Homebrew..."
        retry_with_backoff ${MAX_RETRIES} ${RETRY_DELAY} "brew install kubectl"
    fi
    
    # Verify installation
    if ! command -v kubectl &>/dev/null; then
        log_error "Failed to install kubectl"
        return 1
    fi
    
    local installed_version=$(kubectl version --client --short 2>/dev/null || kubectl version --client -o yaml | grep gitVersion | head -1 | awk '{print $2}')
    log_success "kubectl installed successfully (version: ${installed_version})"
    save_state "kubectl_installed" "true"
    save_state "kubectl_version" "${installed_version}"
    
    # Log kubectl path
    log_debug "kubectl path: $(which kubectl)"
}

verify_installations() {
    log_info "Verifying installations..."
    
    local all_good=true
    
    # Test k3sup
    log_info "Testing k3sup..."
    if k3sup version &>/dev/null; then
        log_success "k3sup is working correctly"
    else
        log_error "k3sup is not functioning properly"
        all_good=false
    fi
    
    # Test kubectl
    log_info "Testing kubectl..."
    if kubectl version --client &>/dev/null; then
        log_success "kubectl is working correctly"
    else
        log_error "kubectl is not functioning properly"
        all_good=false
    fi
    
    if [[ "${all_good}" != "true" ]]; then
        log_error "Installation verification failed"
        exit 1
    fi
    
    log_success "All installations verified successfully"
}

configure_kubectl() {
    log_info "Configuring kubectl..."
    
    # Create .kube directory if it doesn't exist
    local kube_dir="${HOME}/.kube"
    if [[ ! -d "${kube_dir}" ]]; then
        log_info "Creating ${kube_dir} directory..."
        mkdir -p "${kube_dir}"
        chmod 700 "${kube_dir}"
        log_success "Created ${kube_dir} with secure permissions"
    else
        log_debug "${kube_dir} already exists"
    fi
    
    # Set up kubectl autocompletion
    log_info "Setting up kubectl autocompletion..."
    
    # Detect shell
    local shell_name=$(basename "${SHELL}")
    local completion_configured=false
    
    case "${shell_name}" in
        bash)
            if [[ -f "${HOME}/.bash_profile" ]] || [[ -f "${HOME}/.bashrc" ]]; then
                local profile_file="${HOME}/.bash_profile"
                [[ -f "${HOME}/.bashrc" ]] && profile_file="${HOME}/.bashrc"
                
                if ! grep -q "kubectl completion bash" "${profile_file}" 2>/dev/null; then
                    echo 'source <(kubectl completion bash)' >> "${profile_file}"
                    log_success "Added kubectl completion to ${profile_file}"
                    completion_configured=true
                else
                    log_debug "kubectl completion already configured in ${profile_file}"
                fi
            fi
            ;;
        zsh)
            if [[ -f "${HOME}/.zshrc" ]]; then
                if ! grep -q "kubectl completion zsh" "${HOME}/.zshrc" 2>/dev/null; then
                    echo 'source <(kubectl completion zsh)' >> "${HOME}/.zshrc"
                    log_success "Added kubectl completion to ${HOME}/.zshrc"
                    completion_configured=true
                else
                    log_debug "kubectl completion already configured in ${HOME}/.zshrc"
                fi
            fi
            ;;
        *)
            log_warning "Unknown shell: ${shell_name}. Skipping autocompletion setup."
            ;;
    esac
    
    if [[ "${completion_configured}" == "true" ]]; then
        log_info "Please run 'source ~/.${shell_name}rc' or start a new shell for autocompletion"
    fi
    
    # Add kubectl alias
    log_info "Setting up kubectl alias..."
    local alias_configured=false
    
    case "${shell_name}" in
        bash)
            local profile_file="${HOME}/.bash_profile"
            [[ -f "${HOME}/.bashrc" ]] && profile_file="${HOME}/.bashrc"
            
            if [[ -f "${profile_file}" ]] && ! grep -q "alias k=kubectl" "${profile_file}" 2>/dev/null; then
                echo 'alias k=kubectl' >> "${profile_file}"
                log_success "Added 'k' alias for kubectl"
                alias_configured=true
            fi
            ;;
        zsh)
            if [[ -f "${HOME}/.zshrc" ]] && ! grep -q "alias k=kubectl" "${HOME}/.zshrc" 2>/dev/null; then
                echo 'alias k=kubectl' >> "${HOME}/.zshrc"
                log_success "Added 'k' alias for kubectl"
                alias_configured=true
            fi
            ;;
    esac
    
    log_success "kubectl configuration completed"
}

# Run main function
main "$@"