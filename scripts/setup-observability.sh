#!/bin/bash

# AWS EKS Observability Setup Script
# This script sets up the complete observability stack

set -e

echo "🚀 Starting Full-Stack Observability System Setup"

# Phase 1: Prerequisites
echo "📋 Phase 1: Installing prerequisites..."

# Install AWS CLI (if not installed)
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
fi

# Install kubectl
if ! command -v kubectl &> /dev/null; then
    echo "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
fi

# Install eksctl
if ! command -v eksctl &> /dev/null; then
    echo "Installing eksctl..."
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
fi

# Install Helm
if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Install Docker
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    sudo apt-get update
    sudo apt-get install docker.io -y
    sudo systemctl start docker
    sudo usermod -aG docker $USER
fi

echo "✅ Prerequisites installed"

# Phase 2: Create EKS Cluster
echo "🏗️ Phase 2: Creating EKS Cluster..."

# Configure AWS CLI (user needs to do this manually)
echo "Please run: aws configure"
echo "Then press Enter to continue..."
read

# Create cluster
eksctl create cluster -f cluster-config.yaml

# Verify cluster
kubectl get nodes
eksctl get cluster

# Configure namespaces
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace application --dry-run=client -o yaml | kubectl apply -f -

echo "✅ EKS Cluster created"

# Phase 3: Setup AMP
echo "📊 Phase 3: Setting up Amazon Managed Prometheus..."

# Create AMP workspace
AMP_WORKSPACE=$(aws amp create-workspace --alias observability-workspace --region us-east-1 --query arn --output text)
AMP_WORKSPACE_ID=$(echo $AMP_WORKSPACE | awk -F'/' '{print $2}')
AMP_ENDPOINT_URL="https://aps-workspaces.us-east-1.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/"

echo "AMP Workspace ID: $AMP_WORKSPACE_ID"
echo "AMP Endpoint: $AMP_ENDPOINT_URL"

# Create IAM policy and role
aws iam create-policy \
    --policy-name AMPServiceAccountPolicy \
    --policy-document file://amp-iam-policy.json

eksctl create iamserviceaccount \
    --name amp-service-account \
    --namespace observability \
    --cluster observability-cluster \
    --attach-policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AMPServiceAccountPolicy \
    --approve \
    --override-existing-serviceaccounts

# Install Prometheus
helm install prometheus prometheus-community/prometheus \
    -n observability \
    -f prometheus-values.yaml

echo "✅ AMP and Prometheus setup complete"

# Continue with other phases...
echo "🎯 Setup script completed. Please continue with manual steps for remaining phases."