#!/bin/bash
set -e

# Configuration — set these for your environment
REGION="${REGION:-asia-southeast1}"
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID environment variable}"
REPOSITORY="openclaw-sandbox"
IMAGE_NAME="openclaw"
TAG="latest"
SERVICE_ACCOUNT="openclaw-cloudbuild@${PROJECT_ID}.iam.gserviceaccount.com"

IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:${TAG}"

echo "Building and pushing image using Cloud Build..."
gcloud builds submit \
  --config=/dev/stdin \
  --service-account="projects/${PROJECT_ID}/serviceAccounts/${SERVICE_ACCOUNT}" \
  --default-buckets-behavior=regional-user-owned-bucket . <<EOF
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '--no-cache', '-t', '$IMAGE_URI', '.']
images: ['$IMAGE_URI']
EOF

echo "Done! Image pushed to $IMAGE_URI"
