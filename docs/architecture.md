# M3 Ultra K3s Cluster Architecture

## Overview

This document describes the architecture of the M3 Ultra K3s cluster deployment framework.

## Design Principles

1. **Safety First** - Every operation must be reversible
2. **macOS Native** - Leverage macOS features (APFS, Keychain, etc.)
3. **Production Ready** - Enterprise-grade logging, monitoring, and security
4. **GitOps Compatible** - Prepared for ArgoCD/Flux integration
5. **Modular Design** - Each component can be deployed independently

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Control Plane                         │
│                    (<CONTROL_PLANE_IP>)                     │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐   │
│  │   etcd      │  │  API Server  │  │  Controller     │   │
│  │            │  │              │  │  Manager        │   │
│  └─────────────┘  └──────────────┘  └─────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ 6443
                              │
┌─────────────────────────────┴─────────────────────────────┐
│                        Worker Nodes                         │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐             │
│  │  Worker 1 │  │  Worker 2 │  │  Worker 3 │   ...       │
│  │  kubelet  │  │  kubelet  │  │  kubelet  │             │
│  │  kube-    │  │  kube-    │  │  kube-    │             │
│  │  proxy    │  │  proxy    │  │  proxy    │             │
│  └───────────┘  └───────────┘  └───────────┘             │
└───────────────────────────────────────────────────────────┘
```

## Network Architecture

### Cluster Networking
- **Pod Network**: 10.42.0.0/16 (Flannel CNI)
- **Service Network**: 10.43.0.0/16
- **Node Network**: <YOUR_SUBNET>

### Required Ports
- **6443**: Kubernetes API server
- **10250**: Kubelet API
- **10251**: kube-scheduler
- **10252**: kube-controller-manager
- **2379-2380**: etcd server client API
- **30000-32767**: NodePort Services

## Storage Architecture

### NFS Storage
- **Server**: Control plane node
- **Export Path**: /Users/Shared/k3s-nfs
- **Access**: All cluster nodes
- **Use Cases**: Shared persistent volumes

### Local Storage
- **Path**: /var/lib/rancher/k3s/storage
- **Type**: hostPath volumes
- **Use Cases**: Node-specific data

## Security Architecture

### Authentication & Authorization
- **Authentication**: x509 certificates
- **Authorization**: RBAC policies
- **Service Accounts**: Per-namespace isolation

### Network Security
- **Firewall**: macOS pfctl rules
- **Network Policies**: Calico/Cilium CNI
- **TLS**: Automatic certificate rotation

### Secret Management
- **etcd Encryption**: Encryption at rest
- **Sealed Secrets**: GitOps-friendly secrets
- **Keychain Integration**: macOS native credential storage

## Observability Architecture

### Metrics
- **Prometheus**: Time-series metrics
- **Node Exporter**: System metrics
- **kube-state-metrics**: Kubernetes metrics

### Logging
- **Loki**: Log aggregation
- **Promtail**: Log shipping
- **Grafana**: Unified dashboards

### Alerting
- **AlertManager**: Alert routing
- **Notification Channels**: Slack, Email, PagerDuty

## Deployment Patterns

### GitOps Workflow
```
GitHub Repo → ArgoCD → K3s Cluster → Monitoring
     ↑                                      ↓
     └──────────── Alerts ←─────────────────┘
```

### Rolling Updates
1. Drain node
2. Update K3s
3. Rejoin cluster
4. Verify health
5. Proceed to next node

## Disaster Recovery

### Backup Strategy
- **etcd Snapshots**: Every 6 hours
- **Persistent Volumes**: Daily backups
- **Configuration**: Git versioned

### Recovery Procedures
1. **Node Failure**: Automatic rescheduling
2. **Control Plane Failure**: Restore from etcd snapshot
3. **Complete Failure**: Rebuild from Git + backups

## Performance Considerations

### macOS Optimizations
- **Sleep Prevention**: caffeinate for critical nodes
- **mDNS Conflicts**: Disabled for cluster subnet
- **File Descriptors**: Increased limits

### Resource Allocation
- **Control Plane**: 4 CPU, 8GB RAM minimum
- **Workers**: 2 CPU, 4GB RAM minimum
- **Reserved Resources**: 10% for system pods

## Future Enhancements

1. **Multi-cluster Federation**
2. **Service Mesh Integration**
3. **GPU Support for ML Workloads**
4. **Advanced Autoscaling**
5. **Cost Optimization Tracking**