#!/bin/bash

# Full-Stack Observability System - Cleanup Script
# This script tears down all resources created by the observability system

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="observability-cluster"
REGION="us-east-1"
NAMESPACES=("observability" "application" "cert-manager" "opentelemetry-operator-system")

echo -e "${BLUE}🧹 Full-Stack Observability System Cleanup${NC}"
echo "=========================================="

# Function to prompt for confirmation
confirm() {
    local message=$1
    echo -e "${YELLOW}$message${NC}"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cleanup cancelled."
        exit 0
    fi
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to cleanup local Docker resources
cleanup_local() {
    echo -e "${BLUE}🐳 Cleaning up local Docker resources...${NC}"

    if [ -f "docker/docker-compose.yml" ]; then
        echo "Stopping and removing Docker Compose services..."
        cd docker && docker-compose down -v --remove-orphans || true
        cd ..
    fi

    echo "Removing dangling Docker images..."
    docker image prune -f || true

    echo "Removing unused Docker volumes..."
    docker volume prune -f || true

    echo -e "${GREEN}✅ Local Docker cleanup completed${NC}"
}

# Function to cleanup Kubernetes resources
cleanup_kubernetes() {
    echo -e "${BLUE}☸️  Cleaning up Kubernetes resources...${NC}"

    if ! command_exists kubectl; then
        echo "kubectl not found, skipping Kubernetes cleanup"
        return
    fi

    # Check if cluster exists and is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo "Kubernetes cluster not accessible, skipping Kubernetes cleanup"
        return
    fi

    # Delete applications first
    echo "Deleting application deployments..."
    kubectl delete -f sample-app/deployment.yaml --ignore-not-found=true || true
    kubectl delete -f chatops-bot/chatops-deployment.yaml --ignore-not-found=true || true
    kubectl delete -f scripts/error-generator.yaml --ignore-not-found=true || true

    # Delete observability stack
    echo "Deleting observability components..."
    kubectl delete -f kubernetes-configs/ --ignore-not-found=true || true

    # Delete Helm releases
    if command_exists helm; then
        echo "Uninstalling Helm releases..."
        helm uninstall prometheus --namespace observability --ignore-not-found || true
        helm uninstall loki --namespace observability --ignore-not-found || true
        helm uninstall grafana --namespace observability --ignore-not-found || true
        helm uninstall jaeger --namespace observability --ignore-not-found || true
        helm uninstall elasticsearch --namespace observability --ignore-not-found || true
        helm uninstall redis --namespace observability --ignore-not-found || true
        helm uninstall mongodb --namespace observability --ignore-not-found || true
    fi

    # Delete namespaces
    echo "Deleting namespaces..."
    for ns in "${NAMESPACES[@]}"; do
        kubectl delete namespace "$ns" --ignore-not-found=true || true
    done

    # Delete cluster roles and bindings
    echo "Deleting cluster roles and bindings..."
    kubectl delete clusterrole observability-role --ignore-not-found=true || true
    kubectl delete clusterrolebinding observability-binding --ignore-not-found=true || true

    echo -e "${GREEN}✅ Kubernetes cleanup completed${NC}"
}

# Function to cleanup AWS resources
cleanup_aws() {
    echo -e "${BLUE}☁️  Cleaning up AWS resources...${NC}"

    if ! command_exists aws; then
        echo "AWS CLI not found, skipping AWS cleanup"
        return
    fi

    # Get AWS Account ID
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

    if [ -z "$ACCOUNT_ID" ]; then
        echo "Unable to get AWS Account ID, skipping AWS cleanup"
        return
    fi

    echo "Using AWS Account: $ACCOUNT_ID"

    # Delete ECR repositories
    echo "Deleting ECR repositories..."
    aws ecr delete-repository --repository-name sample-app --force --region $REGION >/dev/null 2>&1 || true
    aws ecr delete-repository --repository-name chatops-bot --force --region $REGION >/dev/null 2>&1 || true

    # Delete S3 buckets (empty them first)
    echo "Deleting S3 buckets..."
    for bucket in "observability-loki-chunks" "observability-loki-ruler" "observability-loki-admin"; do
        echo "Emptying bucket: $bucket"
        aws s3 rm s3://$bucket --recursive --region $REGION >/dev/null 2>&1 || true
        aws s3api delete-bucket --bucket $bucket --region $REGION >/dev/null 2>&1 || true
    done

    # Delete SNS topics
    echo "Deleting SNS topics..."
    for topic in "DevOpsGuruNotifications" "ChatOpsIncidents" "IncidentManagerNotifications"; do
        topic_arn="arn:aws:sns:$REGION:$ACCOUNT_ID:$topic"
        aws sns delete-topic --topic-arn "$topic_arn" >/dev/null 2>&1 || true
    done

    # Delete CloudWatch Event Rules
    echo "Deleting CloudWatch Event Rules..."
    aws events delete-rule --name "DevOpsGuruToChatOps" --region $REGION >/dev/null 2>&1 || true
    aws events delete-rule --name "EKSEventsToChatOps" --region $REGION >/dev/null 2>&1 || true

    # Delete DevOps Guru resource collection
    echo "Removing DevOps Guru resource collection..."
    aws devops-guru update-resource-collection \
        --action REMOVE \
        --resource-collection '{"CloudFormation": {"StackNames": ["eksctl-observability-cluster"]}}' \
        >/dev/null 2>&1 || true

    # Delete Lambda functions (if any)
    echo "Deleting Lambda functions..."
    aws lambda delete-function --function-name incident-responder --region $REGION >/dev/null 2>&1 || true

    # Delete IAM policies and roles
    echo "Deleting IAM resources..."
    aws iam detach-role-policy \
        --role-name eksctl-observability-cluster-addon-iamserviceaccount-Role1-XXXXX \
        --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/AMPServiceAccountPolicy" \
        >/dev/null 2>&1 || true

    aws iam delete-policy \
        --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/AMPServiceAccountPolicy" \
        >/dev/null 2>&1 || true

    # Delete AMP workspace
    echo "Deleting AMP workspace..."
    WORKSPACE_ID=$(aws amp list-workspaces --region $REGION --query 'workspaces[?alias==`observability-workspace`].arn' --output text 2>/dev/null | awk -F'/' '{print $2}' || echo "")
    if [ -n "$WORKSPACE_ID" ]; then
        aws amp delete-workspace --workspace-id "$WORKSPACE_ID" --region $REGION >/dev/null 2>&1 || true
    fi

    echo -e "${GREEN}✅ AWS resources cleanup completed${NC}"
}

# Function to cleanup Terraform resources
cleanup_terraform() {
    echo -e "${BLUE}🏗️  Cleaning up Terraform resources...${NC}"

    if [ -d "terraform" ] && [ -f "terraform/main.tf" ]; then
        cd terraform

        if command_exists terraform; then
            echo "Running terraform destroy..."
            terraform destroy -auto-approve || true
        else
            echo "Terraform not found, skipping Terraform cleanup"
        fi

        cd ..
    else
        echo "Terraform directory not found, skipping Terraform cleanup"
    fi

    echo -e "${GREEN}✅ Terraform cleanup completed${NC}"
}

# Function to cleanup EKS cluster
cleanup_eks_cluster() {
    echo -e "${BLUE}🚢 Cleaning up EKS cluster...${NC}"

    if ! command_exists eksctl; then
        echo "eksctl not found, skipping EKS cleanup"
        return
    fi

    # Check if cluster exists
    if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
        confirm "This will delete the entire EKS cluster '$CLUSTER_NAME'. This action cannot be undone!"

        echo "Deleting EKS cluster..."
        eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait || true
    else
        echo "EKS cluster '$CLUSTER_NAME' not found"
    fi

    echo -e "${GREEN}✅ EKS cluster cleanup completed${NC}"
}

# Function to cleanup local files
cleanup_local_files() {
    echo -e "${BLUE}🗂️  Cleaning up local files...${NC}"

    echo "Removing Python cache files..."
    find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
    find . -type f -name "*.pyc" -delete 2>/dev/null || true
    find . -type f -name "*.pyo" -delete 2>/dev/null || true

    echo "Removing temporary files..."
    rm -f awscliv2.zip 2>/dev/null || true
    rm -rf aws 2>/dev/null || true

    echo "Removing log files..."
    find . -name "*.log" -type f -delete 2>/dev/null || true

    echo -e "${GREEN}✅ Local files cleanup completed${NC}"
}

# Main cleanup function
main() {
    echo "Available cleanup options:"
    echo "1) Local Docker only"
    echo "2) Kubernetes resources only"
    echo "3) AWS resources only (keeps cluster)"
    echo "4) Full cleanup (everything including EKS cluster)"
    echo "5) Terraform only"
    echo "6) Local files only"
    echo

    read -p "Select cleanup option (1-6): " -n 1 -r
    echo

    case $REPLY in
        1)
            confirm "This will stop all local Docker containers and remove volumes."
            cleanup_local
            ;;
        2)
            confirm "This will delete all Kubernetes resources in the observability namespaces."
            cleanup_kubernetes
            ;;
        3)
            confirm "This will delete AWS resources (ECR, S3, SNS, etc.) but keep the EKS cluster."
            cleanup_aws
            ;;
        4)
            confirm "This will perform a FULL cleanup including the EKS cluster. This is destructive!"
            cleanup_local
            cleanup_kubernetes
            cleanup_aws
            cleanup_eks_cluster
            cleanup_terraform
            cleanup_local_files
            ;;
        5)
            confirm "This will run terraform destroy on the infrastructure."
            cleanup_terraform
            ;;
        6)
            cleanup_local_files
            ;;
        *)
            echo "Invalid option. Exiting."
            exit 1
            ;;
    esac

    echo
    echo -e "${GREEN}🎉 Cleanup completed successfully!${NC}"
    echo
    echo "If you performed a full cleanup, you may want to:"
    echo "- Delete any remaining CloudFormation stacks manually"
    echo "- Check AWS Console for any remaining resources"
    echo "- Remove any manually created IAM users/roles"
    echo "- Clean up Route53 records if you created any"
}

# Run main function
main "$@"