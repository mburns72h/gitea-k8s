# Gitea Docker → OpenShift Migration (Reusing NFS Paths)

Simplest migration: reuse your existing NFS paths directly via static PVs/PVCs. No backup/restore needed.

## Current Setup
- **NFS Server**: `diskstation.home.mburnsfire.net`
- **Gitea data**: `/volume1/docker/gitea/data` (NFS mount on Pi)
- **PostgreSQL data**: `/volume1/docker/gitea/db` (NFS mount on Pi)
- **DB**: PostgreSQL 17, user `giteauser`, password `giteapass`, database `gitea`

## Prerequisites
- OpenShift cluster ready
- Ensure Synology NFS export `/volume1/docker` has **"No mapping"** squash setting
- Stop Docker/Podman containers before starting (don't mount same paths from both)

---

## Step 1: Stop Docker Containers

On the Raspberry Pi:

```bash
docker stop Gitea Gitea-DB
# optionally: docker rm Gitea Gitea-DB
```

**Important**: Do NOT delete `/volume1/docker/gitea/data` or `/volume1/docker/gitea/db` - we're reusing them!

---

## Step 2: Create Namespace and Apply Static PVs/PVCs

```bash
# Create namespace
oc create namespace gitea

# Apply static PVs pointing to existing NFS paths
oc apply -f k8s/gitea/nfs-pvs.yaml

# Verify PVs/PVCs are Bound
oc -n gitea get pv,pvc
```

Expected output:
- PV `gitea-data-pv` → PVC `gitea-shared-storage` (Bound)
- PV `gitea-db-pv` → PVC `gitea-postgresql-data` (Bound)

---

## Step 3: Fix app.ini for OpenShift

Your existing `/volume1/docker/gitea/data/gitea/conf/app.ini` needs small adjustments:

```bash
# SSH into your NFS server or mount the path locally, then:
# Remove RUN_USER line (OpenShift can't match user 'git')
sed -i.bak '/^RUN_USER = git/d' /volume1/docker/gitea/data/gitea/conf/app.ini

# Update DB host to point to the new PostgreSQL service
sed -i 's|^HOST = .*|HOST = gitea-postgresql:5432|' /volume1/docker/gitea/data/gitea/conf/app.ini

# Verify changes
grep -E "^HOST = " /volume1/docker/gitea/data/gitea/conf/app.ini
# Should show: HOST = gitea-postgresql:5432
```

---

## Step 4: Apply Secrets

```bash
# Apply Kubernetes secrets (DB creds, Gitea tokens)
oc -n gitea apply -f k8s/gitea/secrets.yaml
```

---

## Step 5: Install Gitea via Helm

```bash
# Add Helm repo
helm repo add gitea-charts https://dl.gitea.io/charts/
helm repo update

# Install Gitea (will use existing NFS data)
helm install gitea gitea-charts/gitea -n gitea -f k8s/gitea/values.yaml

# Watch pods come up
oc -n gitea get pods -w
```

Expected pods:
- `gitea-...` (main Gitea app)
- `gitea-postgresql-...` (single PostgreSQL)
- `gitea-valkey-cluster-...` (Redis for sessions/cache)

---

## Step 6: Apply OpenShift Route

```bash
oc -n gitea apply -f k8s/gitea/route.yaml

# Get route hostname
oc -n gitea get route gitea -o jsonpath='{.spec.host}' && echo
```

---

## Step 7: Configure External Access

### Web (via NPM)
- NPM Proxy Host: `gitea.home.mburnsfire.net`
- Forward to: `http://<openshift-router-node-ip>:80`
- Preserve Host: **ON**
- Custom header: `X-Forwarded-Proto: https`

### SSH (via HAProxy)
- DNS: `gitea-ssh.home.mburnsfire.net` → HAProxy VIP
- HAProxy TCP frontend/backend to forward port 22 → NodePort 32222

---

## Step 8: Verify

```bash
# Check Gitea logs
oc -n gitea logs -l app.kubernetes.io/name=gitea --tail=100

# Test web access
curl -I https://gitea.home.mburnsfire.net

# Test SSH (after HAProxy config)
ssh git@gitea-ssh.home.mburnsfire.net
```

---

## Troubleshooting

### Gitea pod CrashLoopBackOff
- Check logs: `oc -n gitea logs -l app.kubernetes.io/name=gitea --tail=200`
- Common: init-directories chown fails → ensure NFS "No mapping" and volumePermissions enabled

### PostgreSQL won't start
- Check if DB data is compatible: PostgreSQL 17 on both sides ✓
- Verify PVC bound: `oc -n gitea get pvc gitea-postgresql-data`
- Check logs: `oc -n gitea logs -l app.kubernetes.io/name=postgresql`

### DB auth failures
- Verify credentials match: DB has `giteauser/giteapass`
- Secret correct: `oc -n gitea get secret gitea-db-app -o yaml | grep -A2 data`
- app.ini correct: check USER/PASSWD in `[database]` section

### Can't access web
- Verify Route: `oc -n gitea get route`
- Check NPM forwards to correct OpenShift router IP/port
- Test directly: `curl http://<router-node-ip>:80 -H "Host: gitea.home.mburnsfire.net"`

---

## Benefits of This Approach

✅ **No data migration** - reuses existing files  
✅ **No DB dump/restore** - PostgreSQL data stays in place  
✅ **Fast** - just point PVCs to existing NFS paths  
✅ **Reversible** - can go back to Docker easily (unmount, restart containers)

## Important Notes

- **DO NOT** run Docker and OpenShift Gitea at the same time on the same NFS paths
- Your app.ini is preserved; only small edits needed (RUN_USER removal, DB host update)
- PostgreSQL version must match (both are Postgres 17 ✓)
- After verifying everything works, you can delete the Docker containers permanently

---

## Rolling Back

If you need to go back to Docker:

```bash
# Stop OpenShift Gitea
oc delete ns gitea

# Revert app.ini changes
cd /volume1/docker/gitea/data/gitea/conf
mv app.ini.bak app.ini

# Restart Docker containers
docker start Gitea-DB Gitea
```

