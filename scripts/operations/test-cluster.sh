#!/usr/bin/env bash
# Test K3s cluster functionality

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Script information
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PURPOSE="Test K3s cluster functionality"

# Test results tracking
declare -A TEST_RESULTS
TESTS_PASSED=0
TESTS_FAILED=0

# Main function
main() {
    log_info "Starting ${SCRIPT_NAME}"
    log_info "Purpose: ${SCRIPT_PURPOSE}"
    
    # Set kubeconfig
    export KUBECONFIG="${KUBECONFIG_PATH}"
    KUBECTL="kubectl --context=${KUBECTL_CONTEXT}"
    
    # Run test suites
    log_info "=== CLUSTER TESTS ==="
    
    run_test "cluster_connectivity" test_cluster_connectivity
    run_test "node_health" test_node_health
    run_test "system_pods" test_system_pods
    run_test "workload_deployment" test_workload_deployment
    run_test "service_connectivity" test_service_connectivity
    run_test "pod_scheduling" test_pod_scheduling
    run_test "dns_resolution" test_dns_resolution
    
    if [[ "${ENABLE_NFS}" == "true" ]]; then
        run_test "storage_provisioning" test_storage_provisioning
    fi
    
    # Cleanup test resources
    cleanup_test_resources
    
    # Print summary
    print_test_summary
}

run_test() {
    local test_name=$1
    local test_function=$2
    
    log_info "Running test: ${test_name}"
    
    if ${test_function}; then
        TEST_RESULTS["${test_name}"]="PASSED"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_success "✓ ${test_name} passed"
    else
        TEST_RESULTS["${test_name}"]="FAILED"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "✗ ${test_name} failed"
    fi
}

test_cluster_connectivity() {
    log_debug "Testing cluster API connectivity..."
    
    if ! ${KUBECTL} cluster-info &>/dev/null; then
        log_error "Cannot connect to cluster API"
        return 1
    fi
    
    return 0
}

test_node_health() {
    log_debug "Testing node health..."
    
    # Get node count
    local expected_nodes=$((1 + ${#WORKER_IPS[@]}))  # 1 control + workers
    local actual_nodes=$(${KUBECTL} get nodes --no-headers | wc -l)
    
    if [[ ${actual_nodes} -ne ${expected_nodes} ]]; then
        log_error "Expected ${expected_nodes} nodes, found ${actual_nodes}"
        return 1
    fi
    
    # Check all nodes are Ready
    local not_ready=$(${KUBECTL} get nodes --no-headers | grep -v " Ready " | wc -l)
    if [[ ${not_ready} -gt 0 ]]; then
        log_error "${not_ready} nodes are not Ready"
        ${KUBECTL} get nodes
        return 1
    fi
    
    return 0
}

test_system_pods() {
    log_debug "Testing system pods..."
    
    # Check critical system pods
    local critical_pods=("coredns" "local-path-provisioner" "metrics-server")
    
    for pod_pattern in "${critical_pods[@]}"; do
        local running=$(${KUBECTL} get pods -n kube-system | grep "${pod_pattern}" | grep -c "Running" || true)
        if [[ ${running} -eq 0 ]]; then
            log_error "No running ${pod_pattern} pods found"
            return 1
        fi
    done
    
    # Check for any failed pods
    local failed_pods=$(${KUBECTL} get pods -A --field-selector=status.phase=Failed --no-headers | wc -l)
    if [[ ${failed_pods} -gt 0 ]]; then
        log_error "${failed_pods} failed pods found"
        ${KUBECTL} get pods -A --field-selector=status.phase=Failed
        return 1
    fi
    
    return 0
}

test_workload_deployment() {
    log_debug "Testing workload deployment..."
    
    # Create test deployment
    if ! ${KUBECTL} create deployment test-nginx --image=nginx:alpine --replicas=3 &>/dev/null; then
        log_error "Failed to create test deployment"
        return 1
    fi
    
    # Wait for deployment to be ready
    if ! ${KUBECTL} wait --for=condition=available --timeout=60s deployment/test-nginx &>/dev/null; then
        log_error "Deployment failed to become ready"
        ${KUBECTL} describe deployment test-nginx
        return 1
    fi
    
    # Check pods are distributed across nodes
    local nodes_with_pods=$(${KUBECTL} get pods -l app=test-nginx -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l)
    if [[ ${nodes_with_pods} -lt 2 ]]; then
        log_warning "Pods not well distributed (on ${nodes_with_pods} nodes)"
    fi
    
    return 0
}

test_service_connectivity() {
    log_debug "Testing service connectivity..."
    
    # Create service if deployment exists
    if ! ${KUBECTL} get deployment test-nginx &>/dev/null; then
        log_warning "Skipping service test - no test deployment"
        return 0
    fi
    
    # Expose deployment
    ${KUBECTL} expose deployment test-nginx --port=80 --target-port=80 &>/dev/null || true
    
    # Get service IP
    local service_ip=$(${KUBECTL} get svc test-nginx -o jsonpath='{.spec.clusterIP}')
    if [[ -z "${service_ip}" ]]; then
        log_error "Failed to get service IP"
        return 1
    fi
    
    # Test connectivity from a pod
    if ! ${KUBECTL} run test-curl --image=curlimages/curl --rm -it --restart=Never -- \
        curl -s -o /dev/null -w "%{http_code}" "http://${service_ip}" | grep -q "200"; then
        log_error "Service not reachable"
        return 1
    fi
    
    return 0
}

test_pod_scheduling() {
    log_debug "Testing pod scheduling..."
    
    # Create pod with node selector
    cat <<EOF | ${KUBECTL} apply -f - &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: test-scheduling
spec:
  containers:
  - name: test
    image: busybox
    command: ['sleep', '10']
  restartPolicy: Never
EOF
    
    # Wait for pod to complete
    if ! ${KUBECTL} wait --for=condition=Ready --timeout=30s pod/test-scheduling &>/dev/null; then
        log_error "Pod failed to schedule"
        ${KUBECTL} describe pod test-scheduling
        return 1
    fi
    
    ${KUBECTL} delete pod test-scheduling --ignore-not-found=true &>/dev/null
    return 0
}

test_dns_resolution() {
    log_debug "Testing DNS resolution..."
    
    # Test internal DNS
    local dns_test=$(${KUBECTL} run test-dns --image=busybox --rm -it --restart=Never -- \
        nslookup kubernetes.default.svc.cluster.local 2>&1)
    
    if ! echo "${dns_test}" | grep -q "Address:"; then
        log_error "DNS resolution failed"
        echo "${dns_test}"
        return 1
    fi
    
    return 0
}

test_storage_provisioning() {
    log_debug "Testing storage provisioning..."
    
    # Create test PVC
    cat <<EOF | ${KUBECTL} apply -f - &>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Mi
  storageClassName: nfs-storage
EOF
    
    # Wait for PVC to bind
    local timeout=30
    while [[ ${timeout} -gt 0 ]]; do
        local pvc_status=$(${KUBECTL} get pvc test-pvc -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "${pvc_status}" == "Bound" ]]; then
            return 0
        fi
        sleep 2
        timeout=$((timeout - 2))
    done
    
    log_error "PVC failed to bind"
    ${KUBECTL} describe pvc test-pvc
    return 1
}

cleanup_test_resources() {
    log_info "Cleaning up test resources..."
    
    # Delete test resources
    ${KUBECTL} delete deployment test-nginx --ignore-not-found=true &>/dev/null || true
    ${KUBECTL} delete service test-nginx --ignore-not-found=true &>/dev/null || true
    ${KUBECTL} delete pod test-scheduling --ignore-not-found=true &>/dev/null || true
    ${KUBECTL} delete pvc test-pvc --ignore-not-found=true &>/dev/null || true
}

print_test_summary() {
    log_info "========== TEST SUMMARY =========="
    
    for test_name in "${!TEST_RESULTS[@]}"; do
        local result="${TEST_RESULTS[${test_name}]}"
        if [[ "${result}" == "PASSED" ]]; then
            log_success "✓ ${test_name}: ${result}"
        else
            log_error "✗ ${test_name}: ${result}"
        fi
    done
    
    log_info "================================="
    log_info "Total tests: $((TESTS_PASSED + TESTS_FAILED))"
    log_success "Passed: ${TESTS_PASSED}"
    
    if [[ ${TESTS_FAILED} -gt 0 ]]; then
        log_error "Failed: ${TESTS_FAILED}"
        exit 1
    else
        log_success "All tests passed!"
    fi
}

# Run main function
main "$@"