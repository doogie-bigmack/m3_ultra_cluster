# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a production-ready K3s cluster automation framework for Apple M3 Ultra Mac hardware. The project provides comprehensive scripts for bootstrapping, managing, and monitoring a K3s Kubernetes cluster on macOS with a focus on safety, observability, and macOS-specific optimizations.

## Key Architecture Decisions

1. **Script-based Automation**: Uses bash scripts with comprehensive error handling rather than configuration management tools
2. **Modular Design**: Each operation is a separate script that can be run independently
3. **State Tracking**: Installation state is tracked in `${LOG_DIR}/.cluster-state` to enable idempotent operations
4. **Per-node Configuration**: Supports different SSH usernames per node via `get_ssh_user()` function
5. **Safety First**: Every destructive operation has pre-flight checks and automatic backups

## Script Execution Order

### Initial Cluster Setup
```bash
# 1. Validate environment
./scripts/bootstrap/00-preflight.sh

# 2. Install dependencies (k3sup, kubectl)
./scripts/bootstrap/01-install-deps.sh

# 3. Initialize control plane
./scripts/bootstrap/02-init-control.sh

# 4. Join worker nodes
./scripts/bootstrap/03-join-workers.sh

# 5. Setup NFS storage (optional)
./scripts/bootstrap/04-setup-storage.sh
```

### Operational Commands
```bash
# Validate SSH access to all nodes
./scripts/operations/validate-ssh-access.sh

# Check cluster health (when implemented)
./scripts/operations/health-check.sh
```

## Configuration Structure

### Required Configuration Files
1. **`configs/base/config.env`** - Main configuration (create from `config.env.example`)
2. **`configs/base/nodes.conf`** - Node-specific settings (create from `nodes.conf.example`)

### Key Configuration Variables
- `CONTROL_PLANE_IP` - IP address of the control plane node
- `WORKER_IPS` - Array of worker node IP addresses
- `NODE_USERS` - Associative array mapping IPs to SSH usernames
- `K3S_VERSION` - K3s version to install (default: "latest")
- `ENABLE_NFS` - Whether to setup NFS storage (default: true)

### Per-Node Username Support
The framework supports different SSH usernames per node:
```bash
# In config.env:
NODE_USERS["192.168.1.246"]="${NODE_USER_246:-different_username}"
```

## Common Development Tasks

### Adding a New Node
1. Add IP to `WORKER_IPS` array in `config.env`
2. Add username mapping to `NODE_USERS` if different from default
3. Run `./scripts/bootstrap/03-join-workers.sh`

### Updating Scripts
- All scripts source `scripts/lib/common.sh` for shared functionality
- Follow existing patterns for logging, error handling, and state management
- Use `check_state` and `save_state` for idempotent operations

### Testing Changes
Currently no automated tests. Manual testing process:
1. Run preflight checks
2. Test on single node first
3. Verify logs in `~/.k3s-cluster-logs/`

## Script Patterns

### Error Handling
Every script uses:
```bash
set -euo pipefail
set_error_trap
```

### Logging
All scripts use structured logging:
```bash
log_info "Information message"
log_success "Success message"
log_warning "Warning message"
log_error "Error message"
```

### State Management
```bash
# Check if already done
if check_state "control_plane_initialized" "true"; then
    log_info "Already initialized"
    exit 0
fi

# After successful operation
save_state "control_plane_initialized" "true"
```

### Retry Logic
Network operations use exponential backoff:
```bash
retry_with_backoff ${MAX_RETRIES} ${RETRY_DELAY} "command"
```

## macOS-Specific Considerations

1. **Architecture Check**: Scripts verify arm64 (Apple Silicon)
2. **Firewall**: Scripts check but don't modify pfctl rules
3. **NFS**: Uses native macOS NFS server with per-client authorization
4. **SIP**: Scripts check System Integrity Protection status
5. **Sleep Prevention**: Not yet implemented but documented

## Security Patterns

- No hardcoded credentials - all configuration externalized
- SSH key-based authentication only
- Node tokens stored with 600 permissions
- NFS exports restricted to specific IPs, not entire subnet
- Automatic backup before modifications

## Missing Implementations

The following are planned but not yet implemented:
- `Makefile` for build automation
- Rollback/recovery scripts in `scripts/rollback/`
- Monitoring stack deployment in `scripts/observability/`
- Cluster upgrade scripts
- Automated testing framework

## Important Notes

1. **Configuration Files**: Never commit `config.env` or `nodes.conf` - they're git-ignored
2. **Force Flags**: Use `FORCE_REINSTALL=true` or `FORCE=true` to re-run operations
3. **Debug Mode**: Set `DEBUG=true` for verbose output
4. **Log Files**: Check `~/.k3s-cluster-logs/` for detailed operation logs
5. **State Files**: Installation state tracked in `${LOG_DIR}/.cluster-state`

## Network Architecture

- **Pod Network**: 10.42.0.0/16 (Flannel CNI)
- **Service Network**: 10.43.0.0/16
- **K3s API Port**: 6443
- **No Default Ingress**: K3s installed with `--disable=traefik`

## Storage Architecture

- **NFS Server**: Runs on control plane node
- **Export Path**: `/Users/Shared/k3s-nfs`
- **Storage Class**: `nfs-storage` for dynamic provisioning
- **Provisioner**: Uses `nfs-client-provisioner` for PVC support