#!/bin/bash
# Cleanup/Uninstall Gitea HA deployment
set -e

NAMESPACE="gitea"
RELEASE_NAME="gitea"

echo "=== Gitea HA Cleanup ==="
echo ""
echo "WARNING: This will DELETE all Gitea data including:"
echo "  - All repositories"
echo "  - All user data"
echo "  - All database content"
echo "  - All persistent volumes"
echo ""

read -p "Are you sure you want to continue? Type 'DELETE' to confirm: " -r
if [[ $REPLY != "DELETE" ]]; then
    echo "Cleanup cancelled."
    exit 1
fi

echo ""
echo "Uninstalling Helm release..."
helm uninstall $RELEASE_NAME -n $NAMESPACE || true

echo "Deleting namespace (this will delete all resources and PVCs)..."
oc delete namespace $NAMESPACE --timeout=5m || true

echo ""
echo "Cleanup complete!"
echo ""
echo "Note: Persistent Volumes may still exist if their reclaim policy is 'Retain'."
echo "Check with: oc get pv | grep gitea"
