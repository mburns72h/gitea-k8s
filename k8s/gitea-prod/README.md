# Gitea HA Production Deployment for OpenShift

This directory contains a production-ready, highly available Gitea deployment for OpenShift using the official Gitea Helm chart in the `gitea` namespace.

## Architecture

**High Availability Components:**
- **Gitea**: 3 replicas (Deployment) with shared storage
- **PostgreSQL HA**: 3 PostgreSQL replicas + 2 Pgpool instances (connection pooling)
- **Redis**: Single instance for session/cache/queue storage
- **Storage**: OpenShift dynamic provisioning (RWX for Gitea data, RWO for PostgreSQL)
- **SSH**: NodePort 32222 (already configured in HAProxy)
- **HTTP**: OpenShift Route with TLS termination

## Prerequisites

1. **OpenShift Cluster**: Logged in with appropriate permissions
2. **Helm 3**: Installed and configured
3. **Storage Class**: RWX-capable storage class (e.g., NFS, CephFS) for Gitea data
4. **HAProxy**: Already configured to forward port 22 to nodeport 32222

## Quick Start

### 1. Generate Secrets

First, generate secure passwords and tokens:

```bash
cd k8s/gitea-prod
chmod +x generate-secrets.sh
./generate-secrets.sh
```

This will:
- Generate random passwords for PostgreSQL, Redis, and Gitea
- Create secure tokens for Gitea (INTERNAL_TOKEN, SECRET_KEY, JWT secrets)
- Optionally update `secrets.yaml` automatically

### 2. Review Configuration

**Important files to review:**

- `values.yaml` - Main Helm configuration
  - Adjust `replicaCount` if you want more/fewer Gitea replicas
  - Set `persistence.storageClass` to your preferred storage class (or leave blank for default)
  - Update `gitea.admin.email` and `gitea.config.mailer` settings as needed

- `secrets.yaml` - Contains all passwords and tokens
  - Verify all `CHANGE_ME` values have been replaced

### 3. Deploy

Deploy everything with a single command:

```bash
chmod +x deploy.sh
./deploy.sh
```

This will:
1. Create the `gitea` namespace
2. Apply all secrets
3. Deploy PostgreSQL HA cluster (3 nodes + 2 pgpool)
4. Deploy Redis
5. Deploy Gitea (3 replicas)
6. Create OpenShift Route for HTTPS access

### 4. Get Admin Password

After deployment, get the auto-generated admin password:

```bash
oc logs -n gitea -l app.kubernetes.io/name=gitea --tail=200 | grep -i password
```

Or check the first Gitea pod:

```bash
POD=$(oc get pods -n gitea -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')
oc logs -n gitea $POD | grep -A 5 -B 5 password
```

### 5. Access Gitea

- **Web UI**: https://gitea.home.mburnsfire.net
- **SSH**: ssh://gitea-ssh.home.mburnsfire.net:22

Login with:
- Username: `gitea_admin`
- Password: (from logs above)

## Storage Configuration

### Using Default Storage Class

If your cluster has a default storage class that supports RWX:

```yaml
persistence:
  storageClass: ""  # Uses default
```

### Using Specific Storage Class

If you need to specify a storage class:

```yaml
persistence:
  storageClass: "nfs-client"  # or "ocs-storagecluster-cephfs", etc.
```

### Checking Available Storage Classes

```bash
oc get storageclass
```

Look for storage classes with `ACCESSMODES` including `RWX` (ReadWriteMany).

## Monitoring Deployment

### Check Pod Status

```bash
oc get pods -n gitea
```

Expected pods:
- `gitea-*` (3 replicas)
- `gitea-postgresql-ha-postgresql-*` (3 replicas)
- `gitea-postgresql-ha-pgpool-*` (2 replicas)
- `gitea-redis-master-*` (1 replica)

### View Logs

```bash
# Gitea logs
oc logs -n gitea -l app.kubernetes.io/name=gitea --tail=100 -f

# PostgreSQL logs
oc logs -n gitea -l app.kubernetes.io/name=postgresql-ha --tail=100 -f

# Redis logs
oc logs -n gitea -l app.kubernetes.io/name=redis --tail=100 -f
```

### Check Services

```bash
oc get svc -n gitea
```

Important services:
- `gitea-http` (ClusterIP) - HTTP service
- `gitea-ssh` (NodePort 32222) - SSH service
- `gitea-postgresql-ha-pgpool` - PostgreSQL connection pooler
- `gitea-redis-master` - Redis service

### Check Route

```bash
oc get route -n gitea
oc describe route gitea -n gitea
```

## Testing HA

### Test Gitea HA

Delete a Gitea pod and verify service continues:

```bash
oc delete pod -n gitea -l app.kubernetes.io/name=gitea --force --grace-period=0
# Kubernetes will automatically recreate the pod
# Service should remain available through the other 2 replicas
```

### Test PostgreSQL HA

Check PostgreSQL cluster status:

```bash
POD=$(oc get pods -n gitea -l app.kubernetes.io/name=postgresql-ha,app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')
oc exec -n gitea $POD -- repmgr cluster show
```

### Test Redis Connection

```bash
POD=$(oc get pods -n gitea -l app.kubernetes.io/name=redis -o jsonpath='{.items[0].metadata.name}')
REDIS_PASSWORD=$(oc get secret gitea-redis -n gitea -o jsonpath='{.data.redis-password}' | base64 -d)
oc exec -n gitea $POD -- redis-cli -a "$REDIS_PASSWORD" ping
```

## Scaling

### Scale Gitea Replicas

```bash
# Edit values.yaml and change replicaCount, then:
helm upgrade gitea gitea-charts/gitea \
    --namespace gitea \
    --values values.yaml \
    --reuse-values
```

Or directly:

```bash
oc scale deployment gitea -n gitea --replicas=5
```

### Scale PostgreSQL Replicas

Edit `values.yaml`:

```yaml
postgresql-ha:
  postgresql:
    replicaCount: 5  # Change this
```

Then upgrade:

```bash
helm upgrade gitea gitea-charts/gitea \
    --namespace gitea \
    --values values.yaml
```

## Backup & Restore

### Backup

1. **Database Backup**:

```bash
POD=$(oc get pods -n gitea -l app.kubernetes.io/name=postgresql-ha,app.kubernetes.io/component=postgresql -o jsonpath='{.items[0].metadata.name}')
DB_PASSWORD=$(oc get secret gitea-db-app -n gitea -o jsonpath='{.data.password}' | base64 -d)

oc exec -n gitea $POD -- bash -c "PGPASSWORD='$DB_PASSWORD' pg_dump -U giteauser gitea" > gitea-db-backup.sql
```

2. **Repository Data Backup**:

```bash
# Get PVC name
PVC=$(oc get pvc -n gitea -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')

# Create a backup pod to copy data
oc run -n gitea backup-pod --image=busybox --restart=Never -- sleep 3600
oc set volume pod/backup-pod -n gitea --add --name=gitea-data --type=pvc --claim-name=$PVC --mount-path=/backup

# Copy data out
oc cp -n gitea backup-pod:/backup ./gitea-data-backup

# Cleanup
oc delete pod backup-pod -n gitea
```

### Restore

See migration documentation for restoring data from your old Gitea instance.

## Troubleshooting

### Pods Not Starting

Check events:

```bash
oc get events -n gitea --sort-by='.lastTimestamp'
oc describe pod -n gitea <pod-name>
```

Common issues:
- **Storage**: No RWX storage class available
- **Security Context**: OpenShift SCC restrictions
- **Secrets**: Missing or incorrect secrets

### Storage Issues

Check PVCs:

```bash
oc get pvc -n gitea
oc describe pvc -n gitea <pvc-name>
```

If PVC is stuck in `Pending`:
- Check if storage class supports RWX (for Gitea) and RWO (for PostgreSQL)
- Verify storage class exists: `oc get storageclass`

### Database Connection Issues

Check PostgreSQL logs:

```bash
oc logs -n gitea -l app.kubernetes.io/name=postgresql-ha --tail=100
```

Test connection from Gitea pod:

```bash
POD=$(oc get pods -n gitea -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')
oc exec -n gitea $POD -- nc -zv gitea-postgresql-ha-pgpool 5432
```

### SSH Not Working

1. Verify HAProxy is forwarding port 22 to nodeport 32222
2. Check SSH service:

```bash
oc get svc gitea-ssh -n gitea
```

3. Test SSH from a node:

```bash
ssh -p 32222 git@<node-ip>
```

## Cleanup

To completely remove the deployment:

```bash
chmod +x cleanup.sh
./cleanup.sh
```

**WARNING**: This will delete ALL data including repositories!

## Configuration Files

- `namespace.yaml` - Namespace definition
- `secrets.yaml` - All passwords and tokens
- `values.yaml` - Helm chart values (main configuration)
- `route.yaml` - OpenShift Route for HTTPS
- `generate-secrets.sh` - Helper to generate secure passwords
- `deploy.sh` - Automated deployment script
- `cleanup.sh` - Cleanup script

## Customization

### Change Admin Email

Edit `values.yaml`:

```yaml
gitea:
  admin:
    email: "your-email@example.com"
```

### Configure SMTP

Edit `values.yaml`:

```yaml
gitea:
  config:
    mailer:
      ENABLED: true
      SMTP_ADDR: your-smtp-server
      SMTP_PORT: 587
      PROTOCOL: smtp+starttls
      FROM: "Gitea <noreply@yourdomain.com>"
      USER: your-smtp-user
      # Add password via secret
```

### Enable OAuth2 Providers

See Gitea documentation: https://docs.gitea.com/usage/oauth2-provider

## Migration from Old Instance

For migrating data from your existing Gitea instance, see the migration documentation in the parent directory.

The migration process will involve:
1. Backup old Gitea database
2. Backup old repositories
3. Restore to new PostgreSQL HA cluster
4. Restore repositories to new storage

## Support

- Gitea Documentation: https://docs.gitea.com/
- Gitea Helm Chart: https://gitea.com/gitea/helm-chart
- OpenShift Documentation: https://docs.openshift.com/
