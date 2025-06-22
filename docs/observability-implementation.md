# OpenTelemetry Observability Implementation Guide

This guide provides step-by-step instructions for deploying the OpenTelemetry-based observability stack on the M3 Ultra K3s cluster.

## Prerequisites

### System Requirements
- K3s cluster running (all 6 nodes healthy)
- NFS storage configured and tested
- At least 20GB free space on each node
- kubectl configured with cluster access

### Required Tools
- Helm 3.12+ (`brew install helm`)
- kubectl 1.28+ (`brew install kubectl`)
- jq (`brew install jq`)
- yq (`brew install yq`)

### Pre-deployment Checklist
- [ ] All nodes are running and healthy
- [ ] NFS storage class is available
- [ ] Network connectivity between all nodes
- [ ] Firewall allows required ports
- [ ] Time synchronized across all nodes (NTP)

## Implementation Phases

## Phase 1: Foundation Setup

### Step 1.1: Create Namespaces
```bash
./scripts/observability/00-create-namespaces.sh
```
Creates:
- `observability` - For OTel components
- `monitoring` - For storage backends
- `grafana` - For visualization

### Step 1.2: Install Prerequisites
```bash
./scripts/observability/00-setup-prerequisites.sh
```
Installs:
- Helm repositories
- cert-manager (for OTel Operator)
- Required CRDs

### Step 1.3: Configure Storage
```bash
./scripts/observability/00-setup-storage.sh
```
Creates:
- PersistentVolumeClaims for each component
- ConfigMaps for retention policies
- Storage class configuration

## Phase 2: OpenTelemetry Deployment

### Step 2.1: Deploy OTel Operator
```bash
./scripts/observability/01-deploy-otel-operator.sh
```

Verify deployment:
```bash
kubectl -n observability get pods -l app.kubernetes.io/name=opentelemetry-operator
kubectl -n observability logs -l app.kubernetes.io/name=opentelemetry-operator
```

### Step 2.2: Deploy Node Collectors
```bash
./scripts/observability/02-deploy-node-collectors.sh
```

Verify DaemonSet:
```bash
# Should see one pod per node (6 total)
kubectl -n observability get pods -l app.kubernetes.io/name=otel-node-collector
kubectl -n observability get ds otel-node-collector
```

### Step 2.3: Deploy Gateway Collectors
```bash
./scripts/observability/02-deploy-gateway-collectors.sh
```

Verify Deployment:
```bash
# Should see 2 replicas
kubectl -n observability get pods -l app.kubernetes.io/name=otel-gateway-collector
kubectl -n observability get deploy otel-gateway-collector
```

## Phase 3: Storage Backends

### Step 3.1: Deploy Prometheus
```bash
./scripts/observability/03-deploy-prometheus.sh
```

Verify and test:
```bash
# Check pod is running
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus

# Port-forward to test
kubectl -n monitoring port-forward svc/prometheus 9090:9090
# Open http://localhost:9090
```

### Step 3.2: Deploy Loki
```bash
./scripts/observability/04-deploy-loki.sh
```

Verify and test:
```bash
# Check pod is running
kubectl -n monitoring get pods -l app.kubernetes.io/name=loki

# Check if receiving logs
kubectl -n monitoring logs -l app.kubernetes.io/name=loki | grep "ingester"
```

### Step 3.3: Deploy Tempo
```bash
./scripts/observability/05-deploy-tempo.sh
```

Verify and test:
```bash
# Check pod is running
kubectl -n monitoring get pods -l app.kubernetes.io/name=tempo

# Check tempo status
kubectl -n monitoring exec -it deploy/tempo -- tempo-cli status
```

## Phase 4: Visualization and Alerting

### Step 4.1: Deploy Grafana
```bash
./scripts/observability/06-deploy-grafana.sh
```

Get admin password:
```bash
kubectl -n grafana get secret grafana -o jsonpath="{.data.admin-password}" | base64 --decode
```

### Step 4.2: Configure Data Sources
```bash
./scripts/observability/07-configure-datasources.sh
```

This automatically configures:
- Prometheus datasource
- Loki datasource  
- Tempo datasource
- Correlations between them

### Step 4.3: Import Dashboards
```bash
./scripts/observability/08-import-dashboards.sh
```

Imports:
- K3s Cluster Overview
- Node Performance
- Pod Resources
- Log Explorer
- Trace Analytics
- macOS Monitoring

### Step 4.4: Setup Alerting
```bash
./scripts/observability/09-setup-alerting.sh
```

Configures:
- Alert rules in Prometheus
- Notification channels in Grafana
- AlertManager integration

## Phase 5: macOS Integration

### Step 5.1: Deploy macOS Collectors
```bash
./scripts/observability/10-deploy-macos-collectors.sh
```

This deploys custom collectors for:
- CPU temperature monitoring
- Power consumption metrics
- Memory pressure
- Thermal throttling

### Step 5.2: Configure macOS Dashboards
```bash
./scripts/observability/11-configure-macos-dashboards.sh
```

## Validation and Testing

### Test 1: Metrics Collection
```bash
# Generate test metrics
kubectl run test-metrics --image=nginx --port=80
kubectl expose pod test-metrics --port=80

# Check in Prometheus
kubectl -n monitoring port-forward svc/prometheus 9090:9090
# Query: up{job="kubernetes-pods"}
```

### Test 2: Log Collection
```bash
# Generate test logs
kubectl run test-logs --image=busybox -- sh -c "while true; do echo 'Test log message'; sleep 5; done"

# Check in Grafana Explore
# Select Loki datasource
# Query: {pod="test-logs"}
```

### Test 3: Trace Collection
```bash
# Deploy test app with tracing
kubectl apply -f examples/traced-app.yaml

# Generate traffic
kubectl port-forward svc/traced-app 8080:8080
curl http://localhost:8080/api/test

# Check in Grafana Explore
# Select Tempo datasource
```

### Test 4: macOS Metrics
```bash
# Check custom metrics in Prometheus
# Query: macos_cpu_temperature_celsius
# Query: macos_power_consumption_watts
```

## Troubleshooting

### Collector Issues

#### Collector not starting
```bash
# Check logs
kubectl -n observability logs -l app.kubernetes.io/name=otel-node-collector

# Common issues:
# - Permissions: Check RBAC
# - Resources: Increase memory limits
# - Config: Validate YAML syntax
```

#### No metrics/logs/traces
```bash
# Check collector pipeline
kubectl -n observability exec -it ds/otel-node-collector -- curl localhost:8888/metrics

# Check exporter errors
kubectl -n observability logs ds/otel-node-collector | grep ERROR
```

### Storage Backend Issues

#### Prometheus not receiving metrics
```bash
# Check remote write endpoint
kubectl -n monitoring logs deploy/prometheus | grep "remote write"

# Verify network connectivity
kubectl -n observability exec -it ds/otel-node-collector -- curl -v http://prometheus.monitoring:9090/api/v1/write
```

#### Loki not receiving logs
```bash
# Check Loki distributor
kubectl -n monitoring logs deploy/loki | grep "distributor"

# Test push endpoint
kubectl -n observability exec -it ds/otel-node-collector -- curl -v http://loki.monitoring:3100/loki/api/v1/push
```

### Grafana Issues

#### Cannot access Grafana
```bash
# Check service
kubectl -n grafana get svc grafana

# Check ingress/nodeport
kubectl -n grafana describe svc grafana
```

#### No data in dashboards
```bash
# Test data source connectivity
kubectl -n grafana exec -it deploy/grafana -- curl http://prometheus.monitoring:9090/api/v1/query?query=up

# Check data source configuration
kubectl -n grafana get cm grafana-datasources -o yaml
```

## Performance Tuning

### Collector Optimization

#### Reduce Memory Usage
```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 256  # Reduce from 512
    spike_limit_mib: 64  # Reduce from 128
```

#### Adjust Batch Processing
```yaml
processors:
  batch:
    timeout: 30s  # Increase for better batching
    send_batch_size: 2048  # Increase for fewer exports
```

### Storage Optimization

#### Prometheus Retention
```yaml
storage:
  tsdb:
    retention.time: 15d  # Reduce from 30d
    retention.size: 50GB  # Add size limit
```

#### Loki Compaction
```yaml
compactor:
  working_directory: /loki/compactor
  shared_store: s3
  compaction_interval: 2h  # More frequent compaction
```

## Maintenance Procedures

### Daily Tasks
1. Check dashboard for anomalies
2. Verify all collectors are running
3. Monitor storage usage

### Weekly Tasks
1. Review and acknowledge alerts
2. Check for OTel Operator updates
3. Analyze performance metrics
4. Clean up test resources

### Monthly Tasks
1. Update collector configurations
2. Rotate credentials
3. Review retention policies
4. Performance baseline review

## Backup and Recovery

### Backup Components
```bash
# Backup Grafana dashboards
./scripts/observability/backup-dashboards.sh

# Backup Prometheus data
./scripts/observability/backup-prometheus.sh

# Backup configurations
./scripts/observability/backup-configs.sh
```

### Recovery Procedure
1. Restore configurations first
2. Redeploy storage backends
3. Restore data from backups
4. Redeploy collectors
5. Verify data flow

## Security Hardening

### Enable mTLS
```bash
./scripts/observability/enable-mtls.sh
```

### Configure RBAC
```bash
./scripts/observability/configure-rbac.sh
```

### Enable Audit Logging
```bash
./scripts/observability/enable-audit-logging.sh
```

## Next Steps

1. **Custom Instrumentation**: Add OTel SDK to your applications
2. **SLO Definition**: Create Service Level Objectives
3. **Advanced Dashboards**: Build team-specific views
4. **Cost Optimization**: Implement sampling strategies
5. **Integration**: Connect to external systems

## References

- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [Grafana Tempo Documentation](https://grafana.com/docs/tempo/latest/)
- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [Prometheus Operator](https://prometheus-operator.dev/)