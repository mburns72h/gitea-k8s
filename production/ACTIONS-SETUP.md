# Gitea Actions CI/CD Setup Guide

This guide walks you through setting up Gitea Actions runners for automated CI/CD in your HA Gitea deployment on OpenShift.

## Overview

**Gitea Actions** is Gitea's built-in CI/CD system, compatible with GitHub Actions workflows. It consists of:
- **Gitea server** - manages jobs, stores logs and artifacts
- **act_runner** - executes jobs (similar to GitHub Actions runners)

## Prerequisites

- Gitea HA deployment running on OpenShift
- `oc` CLI configured and authenticated
- Admin access to Gitea web UI

## Step 1: Enable Gitea Actions

### 1.1 Update Gitea Configuration

Edit `k8s/production/values.yaml` and add the following under `gitea.config:`:

```yaml
gitea:
  config:
    # ... existing config ...

    # Add this section
    actions:
      ENABLED: true
      DEFAULT_ACTIONS_URL: https://github.com  # Allows using actions from GitHub

    storage:
      STORAGE_TYPE: local  # Store artifacts in /data volume
```

### 1.2 Apply Configuration Update

```bash
cd k8s/production

# Update the Helm release
helm upgrade gitea gitea-charts/gitea \
  --namespace gitea \
  --values values.yaml \
  --reuse-values
```

### 1.3 Verify Actions are Enabled

1. Log into Gitea web UI as admin: https://gitea.home.mburnsfire.net
2. Go to **Site Administration** (top right menu)
3. Click **Actions** in the sidebar
4. You should see the "Runners" page

## Step 2: Generate Runner Registration Token

### Option A: Via Web UI (Recommended)

1. In Gitea web UI, go to **Site Administration > Actions > Runners**
2. Click **Create new runner**
3. Copy the registration token (starts with something like `D0g...`)
4. Save this token securely - you'll need it in the next step

### Option B: Via CLI

```bash
# Get a Gitea pod name
GITEA_POD=$(oc get pod -n gitea -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')

# Generate registration token
oc exec -n gitea $GITEA_POD -- gitea actions generate-runner-token

# Copy the output token
```

## Step 3: Create Runner Token Secret

```bash
# Replace YOUR_TOKEN_HERE with the token from Step 2
oc create secret generic gitea-runner-token \
  --from-literal=token=YOUR_TOKEN_HERE \
  -n gitea
```

## Step 4: Choose Runner Deployment Strategy

You have two options for running Docker-based CI jobs:

### Option A: Host Docker Socket (Simpler, Less Secure)

Mounts the host's Docker socket into runner pods. Simpler but requires elevated permissions.

**Pros:**
- Faster (uses node's Docker cache)
- Simpler configuration
- Lower resource usage

**Cons:**
- Requires privileged access
- Security risk (containers can access host Docker)
- Not isolated

### Option B: Docker-in-Docker (More Secure, More Complex)

Runs a Docker daemon inside each runner pod.

**Pros:**
- Better isolation
- More secure
- Each runner has its own Docker environment

**Cons:**
- Higher resource usage
- Requires privileged containers
- More complex

**For OpenShift, I recommend starting with Option A and adjusting security policies.**

## Step 5: Adjust OpenShift Security (for Docker Socket Access)

OpenShift's default Security Context Constraints (SCC) won't allow Docker socket access. You need to grant permissions:

```bash
# Create a new SCC or use 'privileged' for testing
oc adm policy add-scc-to-user privileged -z gitea-runner -n gitea

# For production, create a custom SCC with minimal required permissions
cat <<EOF | oc apply -f -
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: gitea-runner-scc
allowHostDirVolumePlugin: true
allowPrivilegedContainer: false
allowedCapabilities:
  - SETUID
  - SETGID
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: RunAsAny
fsGroup:
  type: RunAsAny
users:
  - system:serviceaccount:gitea:gitea-runner
EOF
```

## Step 6: Deploy Runners

```bash
cd k8s/production

# Deploy the runners
oc apply -f gitea-actions-runner.yaml
```

## Step 7: Verify Runners are Connected

### Check Pod Status

```bash
oc get pods -n gitea -l app=gitea-runner
```

You should see 2 runner pods in "Running" state.

### Check Runner Logs

```bash
# View runner logs
oc logs -n gitea -l app=gitea-runner -f
```

You should see output like:
```
INFO Registering runner with Gitea instance
INFO Runner registered successfully
INFO Listening for jobs...
```

### Verify in Web UI

1. Go to **Site Administration > Actions > Runners**
2. You should see 2 runners listed with status "Idle"
3. Each runner shows labels like `ubuntu-latest`, `ubuntu-22.04`

## Step 8: Test with a Workflow

Create a test workflow in any repository:

```bash
# In a Gitea repository, create .gitea/workflows/test.yml
mkdir -p .gitea/workflows
cat > .gitea/workflows/test.yml <<'EOF'
name: Test CI

on:
  push:
    branches: [ main ]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run tests
        run: |
          echo "Running tests..."
          echo "Node version: $(node --version)"
          echo "npm version: $(npm --version)"

      - name: Build
        run: |
          echo "Building project..."
          # Add your build commands here
EOF

git add .gitea/workflows/test.yml
git commit -m "Add CI workflow"
git push
```

## Monitoring and Scaling

### View Active Jobs

```bash
# Check runner logs for active jobs
oc logs -n gitea -l app=gitea-runner --tail=100 -f
```

### Scale Runners

```bash
# Increase to 5 runners for more parallelism
oc scale deployment gitea-runner -n gitea --replicas=5

# Decrease to 1 runner
oc scale deployment gitea-runner -n gitea --replicas=1
```

### Resource Monitoring

```bash
# Check resource usage
oc top pods -n gitea -l app=gitea-runner

# View resource limits
oc describe deployment gitea-runner -n gitea
```

## Troubleshooting

### Runners Not Registering

**Issue:** Runners can't connect to Gitea

```bash
# Check if runners can reach Gitea service
oc exec -n gitea deployment/gitea-runner -- curl -I http://gitea-http:3000

# Check runner logs
oc logs -n gitea -l app=gitea-runner --tail=50
```

**Common fixes:**
- Verify token is correct: `oc get secret gitea-runner-token -n gitea -o yaml`
- Check Gitea Actions is enabled in configuration
- Ensure network policies allow communication

### Jobs Failing with Docker Errors

**Issue:** Docker socket permission denied

```bash
# Check SCC assignment
oc describe pod -n gitea -l app=gitea-runner | grep scc

# Verify Docker socket is accessible
oc exec -n gitea deployment/gitea-runner -- ls -la /var/run/docker.sock
```

**Fixes:**
- Ensure correct SCC is applied (see Step 5)
- Check Docker socket exists on nodes: `ssh node 'ls -la /var/run/docker.sock'`
- Consider switching to Docker-in-Docker approach

### Runner Pods Crash

```bash
# Check pod events
oc describe pod -n gitea -l app=gitea-runner

# View full logs
oc logs -n gitea -l app=gitea-runner --previous
```

### Out of Resources

**Issue:** Runners fail due to insufficient memory/CPU

```bash
# Check resource usage
oc top pods -n gitea -l app=gitea-runner

# Increase limits in gitea-actions-runner.yaml:
# resources:
#   limits:
#     cpu: 4
#     memory: 4Gi
```

## Advanced Configuration

### Custom Runner Labels

Edit `gitea-actions-runner.yaml` to add custom labels:

```yaml
env:
  - name: GITEA_RUNNER_LABELS
    value: "ubuntu-latest:docker://node:20-bullseye,python:docker://python:3.11,rust:docker://rust:latest"
```

Then workflows can specify:
```yaml
jobs:
  build:
    runs-on: python  # Uses python:3.11 image
```

### Persistent Runner Data

For caching dependencies between builds:

```yaml
# Replace emptyDir with PVC in gitea-actions-runner.yaml
volumes:
  - name: runner-data
    persistentVolumeClaim:
      claimName: gitea-runner-cache
```

### Node Affinity

Pin runners to specific nodes:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/worker
              operator: In
              values:
                - ci
```

## Security Best Practices

1. **Limit Runner Permissions**: Use a custom SCC with minimal required capabilities
2. **Network Policies**: Restrict runner network access
3. **Resource Limits**: Set appropriate CPU/memory limits to prevent resource exhaustion
4. **Secrets Management**: Use Kubernetes secrets for sensitive data in workflows
5. **Image Scanning**: Scan Docker images used in workflows
6. **Audit Logs**: Enable Gitea audit logging for Actions

## Resources

- [Gitea Actions Documentation](https://docs.gitea.com/usage/actions/overview)
- [act_runner Documentation](https://gitea.com/gitea/act_runner)
- [GitHub Actions Syntax](https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions) (compatible)
- [OpenShift SCC Documentation](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)

## Next Steps

1. Create workflows for your repositories
2. Set up automated testing and deployments
3. Configure GitHub Actions marketplace actions
4. Set up artifact storage and retention policies
5. Implement security scanning in CI pipelines
