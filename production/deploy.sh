#!/bin/bash
# Deploy Gitea HA to OpenShift
set -e

NAMESPACE="gitea"
RELEASE_NAME="gitea"
CHART_VERSION="10.6.0"  # Specify version for reproducibility

echo "=== Gitea HA Production Deployment ==="
echo ""

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo "Error: helm is not installed. Please install helm first."
    exit 1
fi

# Check if oc is installed and logged in
if ! command -v oc &> /dev/null; then
    echo "Error: oc (OpenShift CLI) is not installed."
    exit 1
fi

if ! oc whoami &> /dev/null; then
    echo "Error: Not logged in to OpenShift. Please run 'oc login' first."
    exit 1
fi

echo "Logged in as: $(oc whoami)"
echo "Current server: $(oc whoami --show-server)"
echo ""

# Check if secrets have been updated
if grep -q "CHANGE_ME" secrets.yaml; then
    echo "Warning: secrets.yaml contains CHANGE_ME placeholders!"
    echo "Please run './generate-secrets.sh' first to generate secure passwords."
    read -p "Do you want to continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Add Gitea Helm repository
echo "Adding Gitea Helm repository..."
helm repo add gitea-charts https://dl.gitea.com/charts/
helm repo update

# Create namespace
echo "Creating namespace: $NAMESPACE"
oc apply -f namespace.yaml

# Create secrets
echo "Creating secrets..."
oc apply -f secrets.yaml

# Deploy Gitea using Helm
echo "Deploying Gitea with Helm..."
helm upgrade --install $RELEASE_NAME gitea-charts/gitea \
    --namespace $NAMESPACE \
    --version $CHART_VERSION \
    --values values.yaml \
    --wait \
    --timeout 15m

# Create OpenShift Route
echo "Creating OpenShift Route..."
oc apply -f route.yaml

echo ""
echo "=== Deployment Complete! ==="
echo ""
echo "Checking deployment status..."
oc get pods -n $NAMESPACE
echo ""

# Get route URL
ROUTE_URL=$(oc get route gitea -n $NAMESPACE -o jsonpath='{.spec.host}')
echo "Gitea is accessible at: https://$ROUTE_URL"
echo "SSH access: ssh://gitea-ssh.home.mburnsfire.net:22"
echo ""

# Check for admin password in logs
echo "To get the auto-generated admin password, run:"
echo "  oc logs -n $NAMESPACE -l app.kubernetes.io/name=gitea --tail=100 | grep -i password"
echo ""

echo "Useful commands:"
echo "  oc get pods -n $NAMESPACE                    # Check pod status"
echo "  oc logs -n $NAMESPACE <pod-name>              # View logs"
echo "  oc describe pod -n $NAMESPACE <pod-name>      # Pod details"
echo "  helm list -n $NAMESPACE                       # List Helm releases"
echo "  helm status $RELEASE_NAME -n $NAMESPACE       # Deployment status"
