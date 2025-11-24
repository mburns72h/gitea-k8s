# Gitea Docker → OpenShift Migration (Final Guide)

**Hybrid approach**: Reuse Gitea data via NFS + Restore DB to HA PostgreSQL

## Current Setup
- **NFS Server**: `diskstation.home.mburnsfire.net`
- **Gitea data**: `/volume1/docker/gitea/data` (reuse via NFS)
- **PostgreSQL**: Backup and restore to HA cluster
- **DB Credentials**: user `giteauser`, password `giteapass`, database `gitea`
- **URLs**: 
  - Web: `https://gitea.home.mburnsfire.net`
  - SSH: `gitea-ssh.home.mburnsfire.net:22`

---

## Step 1: Backup Database

On the Raspberry Pi (while Docker is still running):

```bash
# Backup PostgreSQL database
docker exec -t Gitea-DB pg_dump -U giteauser -d gitea -F c -f /tmp/gitea.pgdump
docker cp Gitea-DB:/tmp/gitea.pgdump ./gitea.pgdump

# Copy backup to a safe location (you'll need it later)
# Example: scp gitea.pgdump user@workstation:/tmp/
```

---

## Step 2: Stop Docker Containers

```bash
docker stop Gitea Gitea-DB
# Optionally remove them:
# docker rm Gitea Gitea-DB
```

---

## Step 3: Prepare OpenShift

```bash
# Create namespace
oc create namespace gitea

# Apply static PV/PVC for Gitea data (reuses existing NFS path)
oc apply -f k8s/gitea/nfs-pvs.yaml

# Add Helm ownership labels to the Gitea data PVC
oc -n gitea label pvc gitea-shared-storage app.kubernetes.io/managed-by=Helm
oc -n gitea annotate pvc gitea-shared-storage meta.helm.sh/release-name=gitea
oc -n gitea annotate pvc gitea-shared-storage meta.helm.sh/release-namespace=gitea

# Apply secrets
oc -n gitea apply -f k8s/gitea/secrets.yaml
oc -n gitea apply -f k8s/gitea/pgpool-custom-users-secret.yaml

# Verify PVC is bound
oc -n gitea get pvc gitea-shared-storage
```

---

## Step 4: Fix app.ini for OpenShift

Your existing `/volume1/docker/gitea/data/gitea/conf/app.ini` needs adjustments.

**Option A: Edit on NFS server directly**

SSH to your Synology or mount the NFS share, then:

```bash
cd /volume1/docker/gitea/data/gitea/conf

# Backup original
cp app.ini app.ini.backup

# Remove RUN_USER (OpenShift can't match user 'git')
sed -i '/^RUN_USER = git/d' app.ini

# Update DB host to point to HA Postgres Pgpool
sed -i 's|^HOST = .*|HOST = gitea-postgresql-ha-pgpool:5432|' app.ini

# Verify
grep "^HOST = " app.ini
# Should show: HOST = gitea-postgresql-ha-pgpool:5432
```

**Option B: Edit via OpenShift helper pod** (if you can't access NFS server directly)

```bash
# Create helper pod
cat <<'EOF' | oc -n gitea apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gitea-fix-appini
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: helper
      image: alpine:3.20
      command: ["sleep","600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: gitea-data
          mountPath: /data
  volumes:
    - name: gitea-data
      persistentVolumeClaim:
        claimName: gitea-shared-storage
EOF

# Wait for pod to be ready
oc -n gitea wait --for=condition=Ready pod/gitea-fix-appini --timeout=60s

# Remove RUN_USER and update DB host
oc -n gitea exec gitea-fix-appini -- sh -c '
sed -i.bak "/^RUN_USER = git/d" /data/gitea/conf/app.ini
sed -i "s|^HOST = .*|HOST = gitea-postgresql-ha-pgpool:5432|" /data/gitea/conf/app.ini
'

# Verify changes
oc -n gitea exec gitea-fix-appini -- grep "^HOST = " /data/gitea/conf/app.ini

# Cleanup
oc -n gitea delete pod gitea-fix-appini
```

---

## Step 5: Install Gitea with HA PostgreSQL

```bash
# Add Helm repo
helm repo add gitea-charts https://dl.gitea.io/charts/
helm repo update

# Install (with replicas=0 initially so we can restore DB first)
helm install gitea gitea-charts/gitea -n gitea \
  -f k8s/gitea/values.yaml \
  --set replicaCount=0

# Watch HA PostgreSQL and Valkey start
oc -n gitea get pods -w
```

Wait for:
- `gitea-postgresql-ha-postgresql-0/1/2` → Running
- `gitea-postgresql-ha-pgpool-...` → Running
- `gitea-valkey-cluster-0/1/2` → Running

Press Ctrl+C once all are Running.

---

## Step 6: Restore Database to HA PostgreSQL

```bash
# Get postgres superuser password
PGPASS=$(oc -n gitea get secret gitea-pg-ha-secrets -o jsonpath="{.data.postgres-password}" | base64 -d)

# Wait for primary to be ready
oc -n gitea wait --for=condition=Ready pod/gitea-postgresql-ha-postgresql-0 --timeout=300s

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

# Verify restore
oc -n gitea exec -c postgresql gitea-postgresql-ha-postgresql-0 -- bash -lc \
  'export PGPASSWORD="giteapass"; /opt/bitnami/postgresql/bin/psql -h 127.0.0.1 -U giteauser -d gitea -c "SELECT COUNT(*) FROM repository;"'
```

Expected: Should show count of your repositories.

---

## Step 7: Start Gitea

```bash
# Scale Gitea to 1 replica
oc -n gitea scale deploy/gitea --replicas=1

# Watch startup
oc -n gitea get pods -w
```

Wait for `gitea-...` pod to reach Running (may take 1-2 minutes).

Check logs:

```bash
oc -n gitea logs -l app.kubernetes.io/name=gitea --tail=100
```

---

## Step 8: Apply OpenShift Route

```bash
oc -n gitea apply -f k8s/gitea/route.yaml

# Get route hostname
oc -n gitea get route gitea -o jsonpath='{.spec.host}' && echo
```

---

## Step 9: Configure External Access

### Web Access (via Nginx Proxy Manager)

In NPM, create/update Proxy Host:
- **Domain**: `gitea.home.mburnsfire.net`
- **Forward to**: `http://<openshift-router-node-ip>:80`
- **Preserve Host**: ✅ ON
- **Custom Headers**: Add `X-Forwarded-Proto: https`
- **SSL**: Use your certificate

### SSH Access (via HAProxy)

DNS: Point `gitea-ssh.home.mburnsfire.net` → HAProxy VIP

HAProxy config:
```
frontend fe_gitea_ssh
  bind 0.0.0.0:22
  mode tcp
  option tcplog
  default_backend be_gitea_ssh

backend be_gitea_ssh
  mode tcp
  balance roundrobin
  server worker1 <worker1-ip>:32222 check
  server worker2 <worker2-ip>:32222 check
  server worker3 <worker3-ip>:32222 check
```

Replace `<workerN-ip>` with your OpenShift worker node IPs.

---

## Step 10: Verify & Test

```bash
# Test web access
curl -I https://gitea.home.mburnsfire.net

# Check Gitea logs
oc -n gitea logs -l app.kubernetes.io/name=gitea --tail=50

# Test SSH (after HAProxy configured)
ssh git@gitea-ssh.home.mburnsfire.net
# Should show: Hi there, You've successfully authenticated...
```

Login via web:
- URL: `https://gitea.home.mburnsfire.net`
- Use your existing credentials

---

## Troubleshooting

### Gitea pod Init:CrashLoopBackOff

Check which init container is failing:

```bash
oc -n gitea describe pod -l app.kubernetes.io/name=gitea | grep -A20 "Init Containers:"
oc -n gitea logs -l app.kubernetes.io/name=gitea -c init-directories --tail=50
```

**Common issue**: `chown: /data: Operation not permitted`

**Fix**: Ensure Synology NFS export has "No mapping" squash setting:
- DSM → Control Panel → File Services → NFS
- Edit rule for `/volume1/docker`
- Squash: **No mapping**
- Apply

### PostgreSQL pods CrashLoopBackOff

```bash
oc -n gitea logs gitea-postgresql-ha-postgresql-0 -c postgresql --tail=100
```

**Common issues**:
- Permission denied on NFS: Set `chmod 777` on PVC paths
- Secret mismatch: Verify `gitea-pg-ha-secrets` applied correctly

### DB auth failures

```bash
# Test direct connection
oc -n gitea exec -c postgresql gitea-postgresql-ha-postgresql-0 -- bash -lc \
  'export PGPASSWORD="giteapass"; /opt/bitnami/postgresql/bin/psql -h gitea-postgresql-ha-pgpool -U giteauser -d gitea -c "SELECT 1;"'
```

If this fails:
- Verify Pgpool custom users secret: `oc -n gitea get secret gitea-pgpool-custom-users -o yaml`
- Restart Pgpool: `oc -n gitea rollout restart deployment/gitea-postgresql-ha-pgpool`

### Gitea can't connect to DB

Check configure-gitea init logs:

```bash
oc -n gitea logs -l app.kubernetes.io/name=gitea -c configure-gitea --tail=100
```

If auth fails, verify:
1. app.ini has correct HOST: `gitea-postgresql-ha-pgpool:5432`
2. Secret `gitea-db-app` has `giteauser/giteapass`
3. DB actually has user `giteauser` (test via psql above)

---

## Post-Migration

### Cleanup Docker

After verifying everything works:

```bash
# On Raspberry Pi
docker rm Gitea Gitea-DB

# Optionally archive old DB data
sudo mv /volume1/docker/gitea/db /volume1/docker/gitea/db.old
```

### Security Improvements

1. **Rotate secrets** (optional):
   - Generate new INTERNAL_TOKEN, JWT secrets
   - Update DB password
   - Update `k8s/gitea/secrets.yaml` and reapply

2. **Restrict trusted proxies** in app.ini:
   ```ini
   [security]
   REVERSE_PROXY_TRUSTED_PROXIES = <HAProxy-IP>,<NPM-IP>
   ```

3. **Enable metrics** (optional):
   ```ini
   [metrics]
   ENABLED = true
   ```

---

## Architecture Summary

**What's running where:**

- **Gitea data** (`/data`): Reused from NFS `/volume1/docker/gitea/data`
- **PostgreSQL HA**: 3 replicas + 2 Pgpool instances (fresh PVCs, restored from dump)
- **Valkey (Redis)**: 3-node cluster for sessions/cache
- **Web access**: NPM (TLS) → OpenShift Route (HTTP) → Gitea pod
- **SSH access**: HAProxy (port 22) → OpenShift NodePort 32222 → Gitea pod

**Benefits:**
- ✅ All your repos, users, settings preserved
- ✅ HA database with automatic failover
- ✅ Distributed cache for better performance
- ✅ Easy to scale Gitea horizontally (if needed, switch to RWX PVC + multiple replicas)

---

## Notes

- Your original `/volume1/docker/gitea/data` is mounted read-write; any changes in OpenShift persist to NFS
- HA Postgres data is on new PVCs (not NFS); ensure your StorageClass has backups enabled
- If you need to roll back to Docker, restore `app.ini.backup` and restart Docker containers
- The `gitea.pgdump` backup file is your safety net; keep it until you're confident in the migration

