#!/bin/bash
# Script to deploy Kubernetes resources for OpenClaw
# Run this from your local machine with gcloud and kubectl configured.

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID environment variable}"
REGION="${REGION:-asia-southeast1}"
CLUSTER_NAME="openclaw-cluster"
NAMESPACE="openclaw"

echo "=== 1. Getting credentials for GKE cluster ==="
gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION --project $PROJECT_ID

echo "=== 2. Creating namespace $NAMESPACE ==="
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

echo "=== 3. Applying deployment manifest ==="
kubectl apply -f k8s/deployment.yaml -n $NAMESPACE

echo "=== 4. Checking status ==="
kubectl get pods -n $NAMESPACE
kubectl get pvc -n $NAMESPACE

echo "=== Pod connection command ==="
echo "To connect to the brain pod, run:"
echo "kubectl exec -it deployment/openclaw-brain -n $NAMESPACE -c openclaw -- /bin/bash"
