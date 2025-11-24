# Gitea Docker → OpenShift Migration (Clean Start)

Clean migration of Gitea from Docker/Podman on Raspberry Pi to OpenShift, avoiding common pitfalls.

## Your Current Setup (from compose.yaml)
- **DB**: PostgreSQL 17, user `giteauser`, password `giteapass`, database `gitea`
- **Data path**: `/volume1/docker/gitea/data` (NFS: `diskstation.home.mburnsfire.net:/volume1/docker`)
- **DB path**: `/volume1/docker/gitea/db`
- **URLs**: 
  - Web: `https://gitea.home.mburnsfire.net`
  - SSH: `gitea-ssh.home.mburnsfire.net:22`

## Prerequisites
- OpenShift cluster with `oc` CLI configured
- Helm 3 installed
- Access to the NFS server (`diskstation.home.mburnsfire.net`)

---

## Step 1: Backup Current Instance

On the Raspberry Pi (or wherever Docker/Podman is running):

```bash
# Stop Gitea (but keep DB running for backup)
docker stop Gitea

# Backup database
docker exec -t Gitea-DB pg_dump -U giteauser -d gitea -F c -f /tmp/gitea.pgdump
docker cp Gitea-DB:/tmp/gitea.pgdump ./gitea.pgdump

# Backup data directory
sudo tar -C /volume1/docker/gitea -czf gitea-data.tar.gz data

# Stop DB
docker stop Gitea-DB
```

**You now have:**
- `gitea.pgdump` (database backup)
- `gitea-data.tar.gz` (all Gitea data: repos, config, avatars, LFS, etc.)

---

## Step 2: Prepare OpenShift

```bash
# Create namespace
oc create namespace gitea

# Apply secrets
oc -n gitea apply -f k8s/gitea/secrets.yaml
oc -n gitea apply -f k8s/gitea/pgpool-custom-users-secret.yaml
```

---

## Step 3: Install Gitea (without starting it yet)

```bash
# Add Helm repo
helm repo add gitea-charts https://dl.gitea.io/charts/
helm repo update

# Install with replicas=0 (don't start yet)
helm install gitea gitea-charts/gitea -n gitea \
  -f k8s/gitea/values.yaml \
  --set replicaCount=0

# Wait for PVCs to bind
oc -n gitea get pvc
```

Expected PVCs:
- `gitea-shared-storage` (50Gi) - for Gitea `/data`
- `data-gitea-postgresql-ha-postgresql-0/1/2` (20Gi each) - for HA Postgres
- `valkey-data-gitea-valkey-cluster-0/1/2` (8Gi each) - for Redis/cache

---

## Step 4: Restore Data to PVCs

### 4a) Restore Gitea /data

```bash
# Create helper pod
cat <<'EOF' | oc -n gitea apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gitea-restore-data
spec:
  restartPolicy: Never
  containers:
    - name: helper
      image: alpine:3.20
      command: ["sleep","3600"]
      volumeMounts:
        - name: gitea-data
          mountPath: /data
  volumes:
    - name: gitea-data
      persistentVolumeClaim:
        claimName: gitea-shared-storage
EOF

# Wait for pod to be Running
oc -n gitea wait --for=condition=Ready pod/gitea-restore-data --timeout=60s

# Copy and extract data
oc -n gitea cp gitea-data.tar.gz gitea-restore-data:/tmp/gitea-data.tar.gz
oc -n gitea exec gitea-restore-data -- sh -lc 'apk add --no-cache tar && tar -xzf /tmp/gitea-data.tar.gz -C /'

# Verify
oc -n gitea exec gitea-restore-data -- ls -la /data/gitea/conf/app.ini

# Cleanup
oc -n gitea delete pod gitea-restore-data
```

### 4b) Fix app.ini for OpenShift

The restored `app.ini` needs adjustments for OpenShift:

```bash
# Create helper pod to edit app.ini
cat <<'EOF' | oc -n gitea apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gitea-fix-appini
spec:
  restartPolicy: Never
  containers:
    - name: helper
      image: alpine:3.20
      command: ["sleep","600"]
      volumeMounts:
        - name: gitea-data
          mountPath: /data
  volumes:
    - name: gitea-data
      persistentVolumeClaim:
        claimName: gitea-shared-storage
EOF

oc -n gitea wait --for=condition=Ready pod/gitea-fix-appini --timeout=60s

# Remove RUN_USER (OpenShift assigns random UID, can't match)
oc -n gitea exec gitea-fix-appini -- sed -i '/^RUN_USER = git/d' /data/gitea/conf/app.ini

# Update DB connection to use HA Postgres primary directly (bypass Pgpool for now)
oc -n gitea exec gitea-fix-appini -- sh -c '
sed -i "s|^HOST = .*|HOST = gitea-postgresql-ha-postgresql-0.gitea-postgresql-ha-postgresql-headless.gitea.svc.cluster.local:5432|" /data/gitea/conf/app.ini
sed -i "s/^USER = .*/USER = giteauser/" /data/gitea/conf/app.ini
sed -i "s/^PASSWD = .*/PASSWD = giteapass/" /data/gitea/conf/app.ini
'

# Verify changes
oc -n gitea exec gitea-fix-appini -- grep -E "^(HOST|USER|PASSWD) =" /data/gitea/conf/app.ini

# Cleanup
oc -n gitea delete pod gitea-fix-appini
```

### 4c) Restore PostgreSQL Database

```bash
# Wait for HA Postgres to be ready
oc -n gitea wait --for=condition=Ready pod/gitea-postgresql-ha-postgresql-0 --timeout=300s

# Get postgres superuser password
PGPASS=$(oc -n gitea get secret gitea-pg-ha-secrets -o jsonpath="{.data.postgres-password}" | base64 -d)

# Copy dump to primary pod
oc -n gitea cp gitea.pgdump gitea-postgresql-ha-postgresql-0:/tmp/gitea.pgdump

# Create database and user
oc -n gitea exec -c postgresql gitea-postgresql-ha-postgresql-0 -- bash -lc "
export PGPASSWORD='$PGPASS'
/opt/bitnami/postgresql/bin/psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 <<EOSQL
-- Create role if not exists
DO \\\$\\\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'giteauser') THEN
      CREATE ROLE giteauser LOGIN PASSWORD 'giteapass';
   END IF;
END
\\\$\\\$;

-- Create database owned by giteauser
SELECT 'CREATE DATABASE gitea OWNER giteauser' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'gitea')\gexec
EOSQL
"

# Restore data
oc -n gitea exec -c postgresql gitea-postgresql-ha-postgresql-0 -- bash -lc \
  "export PGPASSWORD='$PGPASS'; /opt/bitnami/postgresql/bin/pg_restore -h 127.0.0.1 -U postgres --role=giteauser --no-owner --no-privileges -v -d gitea /tmp/gitea.pgdump"

# Verify
oc -n gitea exec -c postgresql gitea-postgresql-ha-postgresql-0 -- bash -lc \
  'export PGPASSWORD="giteapass"; /opt/bitnami/postgresql/bin/psql -h 127.0.0.1 -U giteauser -d gitea -c "SELECT COUNT(*) FROM repository;"'
```

---

## Step 5: Start Gitea

```bash
# Scale Gitea to 1 replica
oc -n gitea scale deploy/gitea --replicas=1

# Watch startup
oc -n gitea get pods -w
```

After the pod is Running, verify:

```bash
# Check main container logs
oc -n gitea logs -l app.kubernetes.io/name=gitea --tail=100

# Apply OpenShift Route for web access
oc -n gitea apply -f k8s/gitea/route.yaml

# Get Route URL
oc -n gitea get route gitea -o jsonpath='{.spec.host}' && echo
```

---

## Step 6: Configure External Access

### Web (via NPM → OpenShift Route)
- In Nginx Proxy Manager:
  - Proxy Host: `gitea.home.mburnsfire.net`
  - Forward to: `http://<openshift-router-node-ip>:80`
  - Preserve Host: **ON**
  - Custom headers: `X-Forwarded-Proto: https`
  - SSL: your certificate

### SSH (via HAProxy)
- DNS: `gitea-ssh.home.mburnsfire.net` → HAProxy VIP
- HAProxy config:
  ```
  frontend fe_gitea_ssh
    bind 0.0.0.0:22
    mode tcp
    default_backend be_gitea_ssh

  backend be_gitea_ssh
    mode tcp
    balance roundrobin
    server worker1 <worker1-ip>:32222 check
    server worker2 <worker2-ip>:32222 check
  ```

---

## Step 7: Verify & Test

```bash
# Web: https://gitea.home.mburnsfire.net
curl -I https://gitea.home.mburnsfire.net

# SSH (once HAProxy is configured):
ssh git@gitea-ssh.home.mburnsfire.net
```

---

## Troubleshooting

### Pod stuck in Init
- Check init logs: `oc -n gitea logs <pod> -c init-directories`
- If chown fails: Set NFS export to "No mapping" on Synology
- If configure-gitea fails on auth: Ensure secrets match DB credentials and app.ini is correct

### DB auth failures
- Verify password: `oc -n gitea get secret gitea-db-app -o jsonpath='{.data.password}' | base64 -d`
- Test direct connection from pg pod (see step 4c verify)

### PVC permissions
- If Gitea can't write to `/data`, ensure NFS export has "No mapping" squash setting on Synology

---

## Post-Migration Cleanup

After verifying everything works:

1. **Rotate secrets** (optional but recommended):
   - Generate new INTERNAL_TOKEN, JWT secrets
   - Update DB password
   - Update secrets.yaml and apply

2. **Remove Docker/Podman containers**:
   ```bash
   docker rm Gitea Gitea-DB
   ```

3. **Archive backups** to safe location

4. **Switch to Pgpool** (optional, for HA):
   - Update `app.ini` HOST to `gitea-postgresql-ha-pgpool:5432`
   - Ensure Pgpool has giteauser in pool_passwd (already wired via pgpool-custom-users-secret.yaml)

---

## Notes

- Values assume your NFS StorageClass dynamically provisions PVCs pointing to your Synology
- If reusing exact NFS paths, create static PVs (see optional section in original MIGRATION_STEPS.md)
- Ensure Synology NFS export has "No mapping" squash setting to allow OpenShift pods to write
- DB connects directly to primary initially; switch to Pgpool after confirming stable operation
- If configure-gitea init still fails, the issue is likely credential mismatch between secrets/app.ini/DB

