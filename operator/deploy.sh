#!/bin/bash
set -e

KUBECONFIG="/home/mburns/src/personal/ocp/new-cluster/auth/kubeconfig"

echo "=== Gitea Operator Deployment ==="
echo

echo "Step 1: Installing Gitea Operator..."
oc apply -k https://github.com/rhpds/gitea-operator/OLMDeploy --kubeconfig="${KUBECONFIG}"
echo

echo "Waiting for operator to be ready..."
sleep 10
oc wait --for=condition=ready pod -l name=gitea-operator -n gitea-operator --timeout=300s --kubeconfig="${KUBECONFIG}" || true
echo

echo "Step 2: Creating ConfigMap with app.ini..."
oc apply -f configmap.yaml --kubeconfig="${KUBECONFIG}"
echo

echo "Step 3: Deploying Gitea instance..."
oc apply -f gitea-cr.yaml --kubeconfig="${KUBECONFIG}"
echo

echo "Step 4: Monitoring deployment..."
echo "Watch with: oc get gitea gitea-prod -n gitea -w --kubeconfig=${KUBECONFIG}"
echo "Check pods: oc get pods -n gitea --kubeconfig=${KUBECONFIG}"
echo

echo "=== Deployment commands executed ==="
echo
echo "Next steps:"
echo "1. Wait for Gitea pod to be created"
echo "2. Identify the new PVC created by operator"
echo "3. Copy repository data from old PVC to new PVC on diskstation"
echo "4. Restart Gitea pods"
echo
echo "See README.md for detailed migration steps."
