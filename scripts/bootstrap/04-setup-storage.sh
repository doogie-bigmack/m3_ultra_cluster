#!/usr/bin/env bash
# Set up NFS storage for K3s cluster with comprehensive error handling and logging

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Set error trap
set_error_trap

# Script information
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PURPOSE="Configure NFS storage for K3s cluster"

# NFS configuration
NFS_SERVER="${CONTROL_PLANE_IP}"
NFS_CLIENTS=("${WORKER_IPS[@]}")

# Main function
main() {
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Purpose: ${SCRIPT_PURPOSE}"
    log_info "Log file: ${LOG_FILE}"
    
    # Check if NFS is enabled
    if [[ "${ENABLE_NFS}" != "true" ]]; then
        log_info "NFS is disabled in configuration. Skipping setup."
        exit 0
    fi
    
    # Pre-flight checks
    run_preflight_checks
    
    # Setup NFS server
    setup_nfs_server
    
    # Configure NFS clients
    configure_nfs_clients
    
    # Test NFS connectivity
    test_nfs_connectivity
    
    # Deploy NFS provisioner
    deploy_nfs_provisioner
    
    # Verify storage
    verify_storage
    
    log_success "NFS storage setup completed!"
    log_info "NFS export: ${NFS_SERVER}:${NFS_EXPORT_PATH}"
}

run_preflight_checks() {
    log_info "Running pre-flight checks..."
    
    # Check if cluster is initialized
    if ! check_state "control_plane_initialized" "true"; then
        log_error "Control plane not initialized. Run ./01-init-control-plane.sh first"
        exit 1
    fi
    
    # Check SSH connectivity to NFS server
    if ! check_ssh_connectivity "${NFS_SERVER}" "${SSH_USER}"; then
        log_error "Cannot connect to NFS server ${NFS_SERVER}"
        exit 1
    fi
    
    # Check if NFS server is macOS
    log_info "Verifying NFS server OS..."
    if ! ssh ${SSH_OPTIONS} "${SSH_USER}@${NFS_SERVER}" "uname" | grep -q "Darwin"; then
        log_error "NFS server is not running macOS. This script is designed for macOS NFS."
        exit 1
    fi
    
    # Check available disk space on NFS server
    log_info "Checking disk space on NFS server..."
    local available_space=$(ssh ${SSH_OPTIONS} "${SSH_USER}@${NFS_SERVER}" \
        "df -g '${NFS_EXPORT_PATH%/*}' 2>/dev/null || df -g / | awk 'NR==2 {print \$4}'")
    
    if [[ ${available_space} -lt 10 ]]; then
        log_warning "Low disk space on NFS server: ${available_space}GB available"
    fi
    
    # Check kubeconfig
    export KUBECONFIG="${KUBECONFIG_PATH}"
    if ! kubectl --context="${KUBECTL_CONTEXT}" get nodes &>/dev/null; then
        log_error "Cannot connect to cluster"
        exit 1
    fi
    
    log_success "Pre-flight checks completed"
}

setup_nfs_server() {
    log_info "Setting up NFS server on ${NFS_SERVER}..."
    
    # Check if already configured
    if ssh ${SSH_OPTIONS} "${SSH_USER}@${NFS_SERVER}" \
        "grep -q '^${NFS_EXPORT_PATH}' /etc/exports 2>/dev/null"; then
        log_info "NFS export already configured"
        
        if [[ "${FORCE:-false}" != "true" ]]; then
            log_info "Use FORCE=true to reconfigure"
            return 0
        fi
        
        log_warning "Force reconfigure requested"
    fi
    
    # Create NFS export directory
    log_info "Creating NFS export directory..."
    ssh ${SSH_OPTIONS} "${SSH_USER}@${NFS_SERVER}" << EOF
        # Create directory
        sudo mkdir -p "${NFS_EXPORT_PATH}"
        
        # Set permissions
        sudo chmod 755 "${NFS_EXPORT_PATH}"
        
        # Get current user ID and group ID
        USER_ID=\$(id -u)
        GROUP_ID=\$(id -g)
        
        # Set ownership
        sudo chown \${USER_ID}:\${GROUP_ID} "${NFS_EXPORT_PATH}"
        
        echo "Directory created with ownership \${USER_ID}:\${GROUP_ID}"
EOF
    
    # Backup existing exports
    log_info "Backing up existing NFS exports..."
    ssh ${SSH_OPTIONS} "${SSH_USER}@${NFS_SERVER}" \
        "sudo cp /etc/exports /etc/exports.backup.\$(date +%Y%m%d-%H%M%S) 2>/dev/null || true"
    
    # Configure NFS export
    log_info "Configuring NFS export..."
    
    # Build export line with security considerations
    local export_line="${NFS_EXPORT_PATH} -alldirs -mapall=\$(id -u):\$(id -g)"
    
    # Add specific client IPs instead of entire subnet for security
    for client_ip in "${NFS_CLIENTS[@]}"; do
        export_line+=" ${client_ip}"
    done
    
    # Also add control plane IP
    export_line+=" ${NFS_SERVER}"
    
    # Add localhost for testing
    export_line+=" localhost"
    
    log_debug "Export line: ${export_line}"
    
    # Update exports file
    ssh ${SSH_OPTIONS} "${SSH_USER}@${NFS_SERVER}" << EOF
        # Remove existing export for this path
        sudo sed -i.bak "\\|^${NFS_EXPORT_PATH}|d" /etc/exports
        
        # Add new export
        echo "${export_line}" | sudo tee -a /etc/exports
        
        # Verify syntax
        sudo nfsd checkexports || {
            echo "ERROR: Invalid exports file"
            sudo mv /etc/exports.bak /etc/exports
            exit 1
        }
EOF
    
    # Enable and restart NFS
    log_info "Enabling and restarting NFS service..."
    ssh ${SSH_OPTIONS} "${SSH_USER}@${NFS_SERVER}" << 'EOF'
        # Enable NFS
        sudo nfsd enable || {
            echo "Failed to enable NFS"
            exit 1
        }
        
        # Restart NFS to apply changes
        sudo nfsd restart || {
            echo "Failed to restart NFS"
            exit 1
        }
        
        # Verify NFS is running
        sleep 2
        if ! sudo nfsd status | grep -q "is enabled"; then
            echo "NFS is not running"
            exit 1
        fi
        
        # Show current exports
        echo "Current NFS exports:"
        showmount -e localhost
EOF
    
    log_success "NFS server configured successfully"
    save_state "nfs_server_configured" "true"
}

configure_nfs_clients() {
    log_info "Configuring NFS clients..."
    
    local configured_clients=0
    local failed_clients=0
    
    for client_ip in "${NFS_CLIENTS[@]}"; do
        log_info "Configuring NFS client ${client_ip}..."
        
        # Check SSH connectivity
        if ! check_ssh_connectivity "${client_ip}" "${SSH_USER}"; then
            log_warning "Cannot connect to ${client_ip}, skipping"
            failed_clients=$((failed_clients + 1))
            continue
        fi
        
        # Create mount point
        if ssh ${SSH_OPTIONS} "${SSH_USER}@${client_ip}" << EOF
            # Create mount directory
            sudo mkdir -p "${NFS_EXPORT_PATH}"
            
            # Set permissions
            sudo chmod 755 "${NFS_EXPORT_PATH}"
            
            # Test NFS connectivity
            if ! showmount -e ${NFS_SERVER} | grep -q "${NFS_EXPORT_PATH}"; then
                echo "Cannot see NFS export from ${NFS_SERVER}"
                exit 1
            fi
            
            echo "NFS client configured"
EOF
        then
            configured_clients=$((configured_clients + 1))
            log_success "Configured NFS client ${client_ip}"
        else
            failed_clients=$((failed_clients + 1))
            log_error "Failed to configure NFS client ${client_ip}"
        fi
    done
    
    log_info "NFS client configuration summary:"
    log_info "  - Configured: ${configured_clients}"
    log_info "  - Failed: ${failed_clients}"
    
    if [[ ${configured_clients} -eq 0 ]]; then
        log_error "No NFS clients configured successfully"
        exit 1
    fi
}

test_nfs_connectivity() {
    log_info "Testing NFS connectivity..."
    
    # Test from server (localhost)
    log_info "Testing NFS mount on server..."
    if ! ssh ${SSH_OPTIONS} "${SSH_USER}@${NFS_SERVER}" << EOF
        # Create test directory
        TEST_DIR=\$(mktemp -d)
        
        # Test mount
        if sudo mount -t nfs -o ${NFS_MOUNT_OPTIONS} localhost:${NFS_EXPORT_PATH} \${TEST_DIR}; then
            echo "Mount successful"
            
            # Test write
            if touch \${TEST_DIR}/test-file-\$\$ 2>/dev/null; then
                echo "Write test successful"
                rm -f \${TEST_DIR}/test-file-\$\$
            else
                echo "Write test failed"
            fi
            
            # Unmount
            sudo umount \${TEST_DIR}
        else
            echo "Mount failed"
            exit 1
        fi
        
        # Cleanup
        rmdir \${TEST_DIR}
EOF
    then
        log_error "NFS mount test failed on server"
        exit 1
    fi
    
    log_success "NFS server mount test passed"
    
    # Test from one client
    local test_client="${NFS_CLIENTS[0]}"
    if [[ -n "${test_client}" ]]; then
        log_info "Testing NFS mount from client ${test_client}..."
        
        if ssh ${SSH_OPTIONS} "${SSH_USER}@${test_client}" << EOF
            # Create test directory
            TEST_DIR=\$(mktemp -d)
            
            # Test mount
            if sudo mount -t nfs -o ${NFS_MOUNT_OPTIONS} ${NFS_SERVER}:${NFS_EXPORT_PATH} \${TEST_DIR}; then
                echo "Client mount successful"
                
                # Test write
                if touch \${TEST_DIR}/test-client-\$\$ 2>/dev/null; then
                    echo "Client write test successful"
                    rm -f \${TEST_DIR}/test-client-\$\$
                else
                    echo "Client write test failed"
                fi
                
                # Unmount
                sudo umount \${TEST_DIR}
            else
                echo "Client mount failed"
                exit 1
            fi
            
            # Cleanup
            rmdir \${TEST_DIR}
EOF
        then
            log_success "NFS client mount test passed"
        else
            log_warning "NFS client mount test failed - continuing anyway"
        fi
    fi
}

deploy_nfs_provisioner() {
    log_info "Deploying NFS storage provisioner to Kubernetes..."
    
    # Create namespace
    log_info "Creating nfs-provisioner namespace..."
    kubectl --context="${KUBECTL_CONTEXT}" create namespace nfs-provisioner \
        --dry-run=client -o yaml | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
    
    # Create RBAC resources
    log_info "Creating RBAC resources..."
    cat << 'EOF' | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-provisioner
  namespace: nfs-provisioner
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nfs-provisioner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nfs-provisioner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: nfs-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-provisioner
    namespace: nfs-provisioner
EOF
    
    # Create NFS provisioner deployment
    log_info "Creating NFS provisioner deployment..."
    cat << EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-provisioner
  namespace: nfs-provisioner
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-provisioner
  template:
    metadata:
      labels:
        app: nfs-provisioner
    spec:
      serviceAccountName: nfs-provisioner
      containers:
      - name: nfs-provisioner
        image: quay.io/external_storage/nfs-client-provisioner:latest
        env:
          - name: PROVISIONER_NAME
            value: nfs.io/nfs
          - name: NFS_SERVER
            value: "${NFS_SERVER}"
          - name: NFS_PATH
            value: "${NFS_EXPORT_PATH}"
        volumeMounts:
          - name: nfs-root
            mountPath: /persistentvolumes
      volumes:
        - name: nfs-root
          nfs:
            server: ${NFS_SERVER}
            path: ${NFS_EXPORT_PATH}
EOF
    
    # Create storage class
    log_info "Creating NFS storage class..."
    cat << EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: nfs.io/nfs
parameters:
  archiveOnDelete: "true"
EOF
    
    # Wait for provisioner to be ready
    log_info "Waiting for NFS provisioner to be ready..."
    if ! kubectl --context="${KUBECTL_CONTEXT}" -n nfs-provisioner \
        wait --for=condition=available --timeout=300s deployment/nfs-provisioner; then
        log_error "NFS provisioner failed to become ready"
        kubectl --context="${KUBECTL_CONTEXT}" -n nfs-provisioner describe pod
        exit 1
    fi
    
    log_success "NFS provisioner deployed successfully"
    save_state "nfs_provisioner_deployed" "true"
}

verify_storage() {
    log_info "Verifying NFS storage..."
    
    # Create test PVC
    log_info "Creating test PVC..."
    cat << EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: nfs-storage
EOF
    
    # Wait for PVC to be bound
    log_info "Waiting for test PVC to be bound..."
    local timeout=60
    local start_time=$(date +%s)
    
    while true; do
        local pvc_status=$(kubectl --context="${KUBECTL_CONTEXT}" get pvc test-nfs-pvc \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        
        if [[ "${pvc_status}" == "Bound" ]]; then
            log_success "Test PVC bound successfully"
            break
        fi
        
        local elapsed=$(($(date +%s) - start_time))
        if [[ ${elapsed} -gt ${timeout} ]]; then
            log_error "Test PVC failed to bind"
            kubectl --context="${KUBECTL_CONTEXT}" describe pvc test-nfs-pvc
            exit 1
        fi
        
        log_debug "Waiting for PVC to bind... (${elapsed}s/${timeout}s)"
        sleep 5
    done
    
    # Create test pod
    log_info "Creating test pod with NFS volume..."
    cat << EOF | kubectl --context="${KUBECTL_CONTEXT}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-nfs-pod
  namespace: default
spec:
  containers:
  - name: test
    image: busybox:latest
    command: ["sh", "-c", "echo 'NFS test successful' > /mnt/test.txt && cat /mnt/test.txt && sleep 10"]
    volumeMounts:
    - name: nfs
      mountPath: /mnt
  volumes:
  - name: nfs
    persistentVolumeClaim:
      claimName: test-nfs-pvc
EOF
    
    # Wait for pod to complete
    log_info "Waiting for test pod to complete..."
    if kubectl --context="${KUBECTL_CONTEXT}" wait --for=condition=Ready \
        --timeout=60s pod/test-nfs-pod; then
        
        # Check pod logs
        log_info "Test pod output:"
        kubectl --context="${KUBECTL_CONTEXT}" logs test-nfs-pod
        
        log_success "NFS storage test passed"
    else
        log_error "NFS storage test failed"
        kubectl --context="${KUBECTL_CONTEXT}" describe pod test-nfs-pod
    fi
    
    # Cleanup test resources
    log_info "Cleaning up test resources..."
    kubectl --context="${KUBECTL_CONTEXT}" delete pod test-nfs-pod --ignore-not-found=true
    kubectl --context="${KUBECTL_CONTEXT}" delete pvc test-nfs-pvc --ignore-not-found=true
    
    # Show storage classes
    log_info "Available storage classes:"
    kubectl --context="${KUBECTL_CONTEXT}" get storageclass
    
    log_success "NFS storage verification completed"
}

# Run main function
main "$@"