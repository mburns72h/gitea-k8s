# Gitea Docker → Kubernetes Migration (with PostgreSQL)

These steps migrate your existing Gitea (docker-compose on Raspberry Pi) to Kubernetes using the official Helm chart and an in-cluster PostgreSQL, preserving all data and settings.

## Prerequisites
- kubectl and Helm configured to your cluster
- StorageClass available for PVCs
- DNS/ingress set for `gitea.home.mburnsfire.net`

## 1) Backup current instance (on the Raspberry Pi host)

Database (PostgreSQL 17):

```bash
docker exec -t Gitea-DB pg_dump -U giteauser -d gitea -F c -f /tmp/gitea.pgdump
docker cp Gitea-DB:/tmp/gitea.pgdump ./gitea.pgdump
```

Gitea data volume (`/volume1/docker/gitea/data`):

```bash
sudo tar -C /volume1/docker/gitea -czf gitea-data.tar.gz data
```

This produces:
- `gitea.pgdump`
- `gitea-data.tar.gz` (contains `/data/...` including repositories, app.ini, attachments, avatars, LFS, etc.)

## 2) Install Gitea to Kubernetes

Add chart repo and install:

```bash
helm repo add gitea-charts https://dl.gitea.io/charts/
helm repo update
oc create namespace gitea
helm install gitea gitea-charts/gitea -n gitea -f k8s/gitea/values.yaml
```

Wait for PVCs to bind:

```bash
oc -n gitea get pvc
```

OpenShift note (SCC):
- This repo’s values disable fixed pod/container UIDs so OpenShift can assign a random UID under the `restricted` SCC. No extra SCC changes should be necessary.

Apply Secrets before installing or upgrading:

```bash
oc -n gitea apply -f k8s/gitea/secrets.yaml
oc -n gitea apply -f k8s/gitea/pgpool-custom-users-secret.yaml
```

Temporarily stop Gitea before restoring data (run whichever exists):

```bash
oc -n gitea scale --replicas=0 statefulset/gitea || true
oc -n gitea scale --replicas=0 deploy/gitea || true
```

## 3) Restore Gitea /data into the PVC

Identify the Gitea PVC name (likely `gitea`):

```bash
oc -n gitea get pvc
```

Create a helper pod mounting that PVC (replace CLAIM_NAME if different):

```bash
cat <<'EOF' | oc -n gitea apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gitea-restore
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
```

Copy the tarball and extract it to the mount root (creates `/data/...`):

```bash
oc -n gitea cp /mnt/docker/gitea-data.tar.gz gitea-restore:/tmp/gitea-data.tar.gz
oc -n gitea exec gitea-restore -- sh -lc 'apk add --no-cache tar && tar -xzf /tmp/gitea-data.tar.gz -C /'
oc -n gitea delete pod gitea-restore
```

### Reusing existing NFS storage (optional)
If both Docker and OpenShift share the same NFS server, you can reuse it in two ways:
- Dynamic provisioning via your NFS StorageClass (set `persistence.storageClass` / `postgresql.primary.persistence.storageClass`).
- Static PVs pointing to your existing NFS export paths and binding PVCs that the chart will use.

Important:
- Do NOT mount the same live path from Docker and OpenShift at the same time. Scale down/stop Docker first.
- Prefer a dedicated subdirectory (e.g., `/export/gitea/data-k8s/`) to avoid accidental cross-use.
- Ensure NFS directory permissions allow the randomly assigned OpenShift UID to read/write (often 0777 or group-writable with an appropriate fsGroup strategy).
- For PostgreSQL, do not reuse a running DB’s live data directory. Restore from dump into a fresh PGDATA path/PVC.

Example static PV/PVC (edit server/path/size as needed):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: gitea-data-pv
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: <nfs-server-ip-or-dns>
    path: /export/gitea/data-k8s
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitea-data
  namespace: gitea
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
  volumeName: gitea-data-pv
```

Then set in `values.yaml`:
- For Gitea data: `persistence.existingClaim: gitea-data`
- For Postgres data (if using a separate NFS PV/PVC): `postgresql.primary.persistence.existingClaim: gitea-postgresql`

## 4) Restore PostgreSQL database into the in-cluster DB

Use an existing HA PostgreSQL pod as the client:

```bash
# copy dump into the first Postgres pod
oc -n gitea cp /mnt/docker/gitea.pgdump gitea-postgresql-ha-postgresql-0:/tmp/gitea.pgdump

# run pg_restore from that pod against Pgpool
oc -n gitea exec -c postgresql gitea-postgresql-ha-postgresql-0 -- bash -lc \
  'export PATH="/opt/bitnami/postgresql/bin:$PATH"; PGPASSWORD=giteapass pg_restore -h gitea-postgresql-ha-pgpool -U giteauser -d gitea /tmp/gitea.pgdump'
```

If your pod name differs, list pods and adjust:
```bash
oc -n gitea get pods | grep gitea-postgresql-ha-postgresql-
```
If you still see "pg_restore: command not found", run it with the full path:
```bash
oc -n gitea exec -c postgresql gitea-postgresql-ha-postgresql-0 -- \
  /opt/bitnami/postgresql/bin/pg_restore -h gitea-postgresql-ha-pgpool -U giteauser -d gitea /tmp/gitea.pgdump
```

## 5) Grant anyuid SCC for init chown on NFS

Gitea's init container needs to chown /data on NFS. OpenShift's restricted SCC runs as a random non-root UID, which cannot chown. Grant anyuid to the service account:

```bash
# find the SA (usually "default" if not explicitly set)
SA=$(oc -n gitea get deploy gitea -o jsonpath='{.spec.template.spec.serviceAccountName}')
SA=${SA:-default}
echo "Using service account: $SA"

# grant anyuid
oc adm policy add-scc-to-user anyuid -n gitea -z $SA
```

## 6) Start Gitea and verify

Scale Gitea back up (run whichever exists):

```bash
oc -n gitea scale --replicas=1 statefulset/gitea || true
oc -n gitea scale --replicas=1 deploy/gitea || true
oc -n gitea get pods -w
```

Verify init succeeded and pod is Running:
```bash
oc -n gitea logs -l app.kubernetes.io/name=gitea -c init-directories --tail=20
oc -n gitea get pods
```

Verify services:
- Web (via NPM → OpenShift Route HTTP): `https://gitea.home.mburnsfire.net`
  - In NPM, forward to your OpenShift router on port 80, preserve Host header, and set X-Forwarded-Proto=https.
- SSH: `ssh git@gitea-ssh.home.mburnsfire.net` (port 22) via HAProxy → NodePort 32222:
  - Example HAProxy config (TCP mode):
    ```
    frontend fe_ssh_gitea
      bind 0.0.0.0:22
      mode tcp
      option tcplog
      default_backend be_ssh_gitea

    backend be_ssh_gitea
      mode tcp
      balance roundrobin
      server worker1 <worker1-ip>:32222 check
      server worker2 <worker2-ip>:32222 check
    ```
  - Test: `ssh git@gitea-ssh.home.mburnsfire.net` (port 22). Gitea advertises `gitea-ssh.home.mburnsfire.net:22` in clone URLs.

## Notes
- The Helm values set DB env vars so Gitea connects to the in-cluster PostgreSQL regardless of what `app.ini` contains; you can still keep your existing `app.ini` in `/data/gitea/conf/app.ini`.
- The chart uses multi-arch images and works on Raspberry Pi (ARM).
- OpenShift routing:
  - We disabled Helm Ingress and provide a native Route manifest at `k8s/gitea/route.yaml` (non-TLS). Since NPM terminates TLS, the Route should be HTTP.
    Apply it after install:
    ```bash
    oc -n gitea apply -f k8s/gitea/route.yaml
    ```
    Notes:
    - The Route targets Service `gitea-http` and port name `http` (created by the chart).
    - Verify service names: `oc -n gitea get svc` and adjust `spec.to.name`/`spec.port.targetPort` if needed.
  - For SSH, Routes are not supported (TCP). Use NodePort as above with HAProxy on `gitea-ssh.home.mburnsfire.net`.
- Consider enabling TLS via cert-manager by filling `ingress.tls` in `values.yaml`, or use an OpenShift edge/reencrypt Route with your certificate.
- After migration, rotate secrets (INTERNAL_TOKEN, JWT secrets, DB password) when convenient.


