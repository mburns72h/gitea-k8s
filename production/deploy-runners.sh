#!/bin/bash
# Deploy Gitea Actions Runners
# This script automates the deployment of act_runner pods for Gitea Actions CI/CD

set -e

NAMESPACE="gitea"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "Gitea Actions Runner Deployment"
echo "========================================"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
if ! command_exists oc; then
    echo "Error: oc CLI not found. Please install OpenShift CLI."
    exit 1
fi

if ! command_exists helm; then
    echo "Error: helm not found. Please install Helm."
    exit 1
fi

# Check if namespace exists
if ! oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: Namespace $NAMESPACE does not exist."
    echo "Please deploy Gitea first using ./deploy.sh"
    exit 1
fi

echo "Step 1: Checking if Gitea Actions is enabled..."
echo ""

# Check if Gitea is running
if ! oc get deployment gitea -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Error: Gitea deployment not found in namespace $NAMESPACE"
    exit 1
fi

echo "✓ Gitea deployment found"
echo ""

echo "========================================"
echo "IMPORTANT: Enable Gitea Actions"
echo "========================================"
echo ""
echo "Before deploying runners, you must enable Gitea Actions:"
echo ""
echo "1. Edit values.yaml and add under gitea.config:"
echo ""
cat <<'EOF'
    actions:
      ENABLED: true
      DEFAULT_ACTIONS_URL: https://github.com

    storage:
      STORAGE_TYPE: local
EOF
echo ""
echo "2. Update Gitea deployment:"
echo "   helm upgrade gitea gitea-charts/gitea \\"
echo "     --namespace $NAMESPACE \\"
echo "     --values values.yaml \\"
echo "     --reuse-values"
echo ""
read -p "Have you enabled Gitea Actions? (y/n): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Please enable Gitea Actions first, then run this script again."
    exit 0
fi

echo ""
echo "Step 2: Getting runner registration token..."
echo ""
echo "You need a runner registration token from Gitea."
echo ""
echo "Option 1 (Web UI):"
echo "  1. Go to https://gitea.home.mburnsfire.net"
echo "  2. Navigate to Site Administration > Actions > Runners"
echo "  3. Click 'Create new runner'"
echo "  4. Copy the registration token"
echo ""
echo "Option 2 (CLI):"
echo "  Run: oc exec -n $NAMESPACE \$(oc get pod -n $NAMESPACE -l app.kubernetes.io/name=gitea -o name | head -1) -- gitea actions generate-runner-token"
echo ""

# Check if secret already exists
if oc get secret gitea-runner-token -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "✓ Runner token secret already exists"
    read -p "Do you want to update it? (y/n): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "Enter the runner registration token: " RUNNER_TOKEN
        oc delete secret gitea-runner-token -n "$NAMESPACE"
        oc create secret generic gitea-runner-token \
            --from-literal=token="$RUNNER_TOKEN" \
            -n "$NAMESPACE"
        echo "✓ Runner token secret updated"
    fi
else
    read -p "Enter the runner registration token: " RUNNER_TOKEN

    if [ -z "$RUNNER_TOKEN" ]; then
        echo "Error: Token cannot be empty"
        exit 1
    fi

    oc create secret generic gitea-runner-token \
        --from-literal=token="$RUNNER_TOKEN" \
        -n "$NAMESPACE"

    echo "✓ Runner token secret created"
fi

echo ""
echo "Step 3: Configuring OpenShift security..."
echo ""

# Check if service account exists
if ! oc get sa gitea-runner -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Creating service account..."
else
    echo "✓ Service account already exists"
fi

# Add SCC permissions for Docker-in-Docker (requires privileged)
echo "Adding Security Context Constraints..."
echo "Note: Docker-in-Docker requires privileged SCC for OpenShift"
oc adm policy add-scc-to-user privileged -z gitea-runner -n "$NAMESPACE" 2>/dev/null || true
echo "✓ SCC permissions configured"

echo ""
echo "Step 4: Deploying runners..."
echo ""

# Apply runner deployment
oc apply -f "$SCRIPT_DIR/gitea-actions-runner.yaml"

echo "✓ Runner deployment created"
echo ""

echo "Step 5: Waiting for runners to start..."
echo ""

# Wait for deployment to be ready
oc rollout status deployment/gitea-runner -n "$NAMESPACE" --timeout=120s

echo ""
echo "========================================"
echo "✓ Deployment Complete!"
echo "========================================"
echo ""

# Get runner pod status
echo "Runner Pods:"
oc get pods -n "$NAMESPACE" -l app=gitea-runner
echo ""

echo "Checking runner logs for registration..."
sleep 5
echo ""

# Show recent logs
RUNNER_POD=$(oc get pod -n "$NAMESPACE" -l app=gitea-runner -o jsonpath='{.items[0].metadata.name}')
if [ -n "$RUNNER_POD" ]; then
    echo "Recent logs from $RUNNER_POD:"
    oc logs -n "$NAMESPACE" "$RUNNER_POD" --tail=20 || true
fi

echo ""
echo "========================================"
echo "Next Steps:"
echo "========================================"
echo ""
echo "1. Verify runners in Gitea UI:"
echo "   https://gitea.home.mburnsfire.net/admin/actions/runners"
echo ""
echo "2. View runner logs:"
echo "   oc logs -n $NAMESPACE -l app=gitea-runner -f"
echo ""
echo "3. Scale runners:"
echo "   oc scale deployment gitea-runner -n $NAMESPACE --replicas=5"
echo ""
echo "4. Create a test workflow in a repository:"
echo "   See ACTIONS-SETUP.md for workflow examples"
echo ""
echo "For detailed documentation, see: $SCRIPT_DIR/ACTIONS-SETUP.md"
echo ""
