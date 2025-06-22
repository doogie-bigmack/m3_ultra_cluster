#!/usr/bin/env bash
# Validate SSH access to all cluster nodes with correct usernames

set -euo pipefail

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../configs/base/config.env"

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Validating SSH access to all cluster nodes..."
echo "============================================"

# Function to test SSH connection
test_ssh() {
    local ip=$1
    local user=$2
    local role=$3
    
    printf "%-15s %-15s %-12s " "$ip" "$user" "$role"
    
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "${user}@${ip}" "echo 'SSH OK' >/dev/null 2>&1" &>/dev/null; then
        echo -e "${GREEN}✓ Connected${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed${NC}"
        return 1
    fi
}

# Header
printf "%-15s %-15s %-12s %s\n" "IP Address" "Username" "Role" "Status"
printf "%-15s %-15s %-12s %s\n" "----------" "--------" "----" "------"

# Test control plane
CONTROL_USER=$(get_ssh_user "${CONTROL_PLANE_IP}")
test_ssh "${CONTROL_PLANE_IP}" "${CONTROL_USER}" "control-plane"

# Test workers
for ip in "${WORKER_IPS[@]}"; do
    WORKER_USER=$(get_ssh_user "$ip")
    test_ssh "$ip" "$WORKER_USER" "worker"
done

echo ""
echo "SSH Key Setup Instructions:"
echo "=========================="
echo "If any connections failed, run these commands for each failed node:"
echo ""
echo "# For control plane (${CONTROL_PLANE_IP}):"
echo "ssh-copy-id ${CONTROL_USER}@${CONTROL_PLANE_IP}"
echo ""

for ip in "${WORKER_IPS[@]}"; do
    WORKER_USER=$(get_ssh_user "$ip")
    echo "# For worker ($ip):"
    echo "ssh-copy-id ${WORKER_USER}@${ip}"
done

echo ""
echo "Note: The .246 node uses username 'damonmcdougdl' (with typo)"