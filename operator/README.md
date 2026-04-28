# Gitea Operator Deployment

This directory contains the configuration for deploying Gitea using the rhpds Gitea operator instead of the Helm chart.

## Why the Operator?

The Helm chart deployment was failing with user permission issues when running in OpenShift's restricted SCC. The Gitea operator is designed specifically for OpenShift and handles security contexts automatically.

## Prerequisites

- Existing PostgreSQL HA cluster (gitea-postgresql-ha-pgpool)
- Existing Redis instance (gitea-redis-master)
- Existing database with imported data
- Repository data on NFS storage

## Deployment Steps

### 1. Install the Gitea Operator

```bash
oc apply -k https://github.com/rhpds/gitea-operator/OLMDeploy --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig
```

This installs the operator cluster-wide in the `gitea-operator` namespace.

### 2. Verify Operator Installation

```bash
oc get pods -n gitea-operator --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig
```

Wait for the operator pod to be Running.

### 3. Create the ConfigMap

Apply the custom app.ini configuration:

```bash
oc apply -f configmap.yaml --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig
```

### 4. Deploy Gitea Instance

```bash
oc apply -f gitea-cr.yaml --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig
```

### 5. Monitor Deployment

```bash
# Watch the Gitea CR status
oc get gitea gitea-prod -n gitea -w --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig

# Check pods
oc get pods -n gitea --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig

# View operator logs
oc logs -n gitea-operator deployment/gitea-operator --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig -f
```

## Post-Deployment: Repository Data Migration

After the operator creates the Gitea deployment and PVC:

### 1. Identify the New PVC

```bash
oc get pvc -n gitea --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig
```

Look for the operator-created PVC (likely named `gitea-prod-data` or similar).

### 2. Find NFS Path on Synology

SSH to diskstation and find the new PVC path:

```bash
ssh mburns@diskstation.home.mburnsfire.net
ls -la /volume7/OCPNew/
```

Find the PVC directory (look for the PVC UUID).

### 3. Copy Repository Data

From diskstation, copy data from old Helm-created PVC to operator-created PVC:

```bash
# On diskstation
cd /volume7/OCPNew/

# Old Helm PVC path
OLD_PVC="pvc-a2779a31-63d8-4cd8-b6aa-ea599bfe8a85"

# New operator PVC path (find from step 2)
NEW_PVC="pvc-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"

# Copy data
rsync -av --progress "${OLD_PVC}/" "${NEW_PVC}/"
```

### 4. Restart Gitea Pods

After copying data:

```bash
oc delete pods -n gitea -l app=gitea --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig
```

## Configuration Notes

### Database Connection

- Uses existing PostgreSQL HA cluster (gitea-postgresql-ha-pgpool)
- Database: `gitea`
- User: `giteauser`
- Password stored in gitea-cr.yaml (from gitea-db-app secret)

### Redis Connection

- Configured in app.ini ConfigMap
- Uses REDIS_PASSWORD placeholder (will need to be substituted)
- Consider creating a secret for Redis password and using envFrom

### Storage

- Storage class: `nfs-default`
- Size: 50Gi
- Access mode: RWX (ReadWriteMany) for NFS

### Networking

- SSL/TLS enabled via OpenShift Route
- Hostname: `gitea.apps.shift.home.mburnsfire.net`
- SSH access: Will need to configure NodePort after deployment

## Files in This Directory

- `app.ini` - Plain text app.ini for reference
- `configmap.yaml` - ConfigMap containing app.ini
- `gitea-cr.yaml` - Gitea custom resource definition
- `README.md` - This file

## Cleanup Old Helm Deployment

After verifying operator deployment works:

```bash
# Uninstall Helm release
helm uninstall gitea -n gitea --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig

# Clean up old PVCs if needed
oc delete pvc gitea-shared-storage -n gitea --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig
```

## Troubleshooting

### Check Operator Logs

```bash
oc logs -n gitea-operator deployment/gitea-operator --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig
```

### Check Gitea CR Status

```bash
oc describe gitea gitea-prod -n gitea --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig
```

### Check Pod Events

```bash
oc get events -n gitea --sort-by='.lastTimestamp' --kubeconfig=/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig
```
