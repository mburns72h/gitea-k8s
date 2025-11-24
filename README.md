# Gitea HA Deployment for OpenShift

Production-ready, highly available Gitea deployment for OpenShift/Kubernetes using the official Gitea Helm chart.

## Architecture

This deployment provides a fully HA setup with:

- **3 Gitea replicas** (rootless containers for OpenShift SCC compatibility)
- **3 PostgreSQL HA replicas** + 2 Pgpool connection poolers
- **3 Valkey cluster nodes** (Redis replacement) for sessions, cache, and queues
- **OpenShift dynamic storage** (RWX for Gitea, RWO for PostgreSQL)
- **Integrated SMTP** via internal OpenShift smtp-relay service
- **TLS-terminated HTTPS** via OpenShift Route
- **SSH access** via NodePort (port 2222)

## Directory Structure

```
.
├── README.md                    # This file
├── haproxy.cfg                  # HAProxy configuration reference
└── k8s/
    └── production/              # Production deployment
        ├── README.md            # Detailed deployment guide
        ├── namespace.yaml       # Namespace definition
        ├── secrets.yaml.example # Secret template (copy to secrets.yaml)
        ├── values.yaml          # Helm chart values
        ├── route.yaml           # OpenShift Route for HTTPS
        ├── generate-secrets.sh  # Helper to generate secure passwords
        ├── deploy.sh            # Automated deployment script
        └── cleanup.sh           # Cleanup/uninstall script
```

## Quick Start

### 1. Clone and Setup

```bash
cd k8s/production
cp secrets.yaml.example secrets.yaml
./generate-secrets.sh  # Generates secure passwords
```

### 2. Review Configuration

Edit `values.yaml` to customize:
- Storage class (if not using default)
- Admin email
- SMTP settings
- Resource limits

### 3. Deploy

```bash
./deploy.sh
```

This will:
1. Create the `gitea` namespace
2. Apply secrets
3. Deploy PostgreSQL HA, Valkey, and Gitea
4. Create OpenShift Route

### 4. Access Gitea

After deployment:

- **Web UI**: https://gitea.home.mburnsfire.net
- **SSH**: ssh://gitea-ssh.home.mburnsfire.net:2222

Get the admin password:

```bash
oc exec -n gitea -it $(oc get pod -n gitea -l app.kubernetes.io/name=gitea -o name | head -1) -- \
  gitea admin user list
```

Or set a new password:

```bash
oc exec -n gitea -it $(oc get pod -n gitea -l app.kubernetes.io/name=gitea -o name | head -1) -- \
  gitea admin user change-password --username gitea_admin --password "YourPassword"
```

## Features

### High Availability

- **Multiple Gitea replicas**: Continue serving requests if one pod fails
- **PostgreSQL HA**: Automatic failover with repmgr
- **Distributed sessions**: Valkey cluster for session persistence
- **Rolling updates**: Zero-downtime deployments

### OpenShift Compatibility

- **Rootless Gitea**: No privileged containers required
- **SCC compliant**: Works with OpenShift's restricted Security Context Constraints
- **Dynamic provisioning**: Uses OpenShift storage classes
- **Route integration**: Native TLS termination

### Security

- **Encrypted secrets**: All passwords stored in Kubernetes secrets
- **TLS everywhere**: HTTPS via OpenShift Route
- **Non-root containers**: Rootless Gitea image
- **Network policies**: Isolated namespace

## Monitoring

```bash
# Check pod status
oc get pods -n gitea

# View logs
oc logs -n gitea -l app.kubernetes.io/name=gitea -f

# Check services
oc get svc -n gitea

# View route
oc get route gitea -n gitea
```

## Scaling

### Scale Gitea replicas

```bash
oc scale deployment gitea -n gitea --replicas=5
```

### Scale PostgreSQL replicas

Edit `values.yaml`:

```yaml
postgresql-ha:
  postgresql:
    replicaCount: 5
```

Then upgrade:

```bash
helm upgrade gitea gitea-charts/gitea \
  --namespace gitea \
  --values values.yaml
```

## Backup

### Database Backup

```bash
POD=$(oc get pods -n gitea -l app.kubernetes.io/component=postgresql -o name | head -1)
DB_PASSWORD=$(oc get secret gitea-db-app -n gitea -o jsonpath='{.data.password}' | base64 -d)

oc exec -n gitea $POD -- bash -c \
  "PGPASSWORD='$DB_PASSWORD' pg_dump -U giteauser gitea" > gitea-backup.sql
```

### Repository Data Backup

```bash
PVC=$(oc get pvc -n gitea -l app.kubernetes.io/name=gitea -o name)
oc cp -n gitea $(oc get pod -n gitea -l app.kubernetes.io/name=gitea -o name | head -1):/data ./gitea-data-backup
```

## Troubleshooting

### Pods not starting

```bash
oc describe pod -n gitea <pod-name>
oc logs -n gitea <pod-name>
```

### SSH not working

1. Verify HAProxy forwards port 22 to NodePort 32222
2. Check SSH service: `oc get svc gitea-ssh -n gitea`
3. Test from a node: `ssh -p 32222 git@<node-ip>`

### Database issues

```bash
# Check PostgreSQL logs
oc logs -n gitea -l app.kubernetes.io/name=postgresql-ha

# Check cluster status
POD=$(oc get pod -n gitea -l app.kubernetes.io/component=postgresql -o name | head -1)
oc exec -n gitea $POD -- repmgr cluster show
```

## Cleanup

To completely remove the deployment:

```bash
./cleanup.sh
```

**WARNING**: This deletes all data including repositories!

## Documentation

- [Production Deployment Guide](k8s/production/README.md)
- [Gitea Documentation](https://docs.gitea.com/)
- [Gitea Helm Chart](https://gitea.com/gitea/helm-chart)
- [OpenShift Documentation](https://docs.openshift.com/)

## License

This deployment configuration is provided as-is for self-hosting Gitea.
