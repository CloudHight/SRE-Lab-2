#!/bin/bash

# Full-Stack Observability System - Validation Script
# This script validates the deployment status of all components

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🔍 Full-Stack Observability System Validation${NC}"
echo "==============================================="

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check URL accessibility
check_url() {
    local url=$1
    local name=$2
    if curl -s --max-time 5 "$url" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ $name is accessible${NC}"
        return 0
    else
        echo -e "${RED}❌ $name is not accessible${NC}"
        return 1
    fi
}

# Function to check Kubernetes resources
check_kubernetes() {
    echo -e "${BLUE}☸️  Checking Kubernetes resources...${NC}"

    if ! command_exists kubectl; then
        echo -e "${RED}❌ kubectl not found${NC}"
        return 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo -e "${RED}❌ Kubernetes cluster not accessible${NC}"
        return 1
    fi

    local total_checks=0
    local passed_checks=0

    # Check namespaces
    for ns in observability application; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Namespace '$ns' exists${NC}"
            ((passed_checks++))
        else
            echo -e "${RED}❌ Namespace '$ns' not found${NC}"
        fi
        ((total_checks++))
    done

    # Check key deployments
    local deployments=("prometheus-server" "grafana" "otel-collector" "sample-app")
    for deployment in "${deployments[@]}"; do
        local ns="observability"
        if [[ "$deployment" == "sample-app" ]]; then
            ns="application"
        fi

        if kubectl get deployment "$deployment" -n "$ns" >/dev/null 2>&1; then
            # Check if deployment is ready
            local ready=$(kubectl get deployment "$deployment" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local desired=$(kubectl get deployment "$deployment" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

            if [[ "$ready" == "$desired" ]] && [[ "$desired" != "0" ]]; then
                echo -e "${GREEN}✅ Deployment '$deployment' is ready ($ready/$desired)${NC}"
                ((passed_checks++))
            else
                echo -e "${YELLOW}⚠️  Deployment '$deployment' is not fully ready ($ready/$desired)${NC}"
            fi
        else
            echo -e "${RED}❌ Deployment '$deployment' not found${NC}"
        fi
        ((total_checks++))
    done

    echo "Kubernetes checks: $passed_checks/$total_checks passed"
    return $((total_checks - passed_checks))
}

# Function to check AWS resources
check_aws() {
    echo -e "${BLUE}☁️  Checking AWS resources...${NC}"

    if ! command_exists aws; then
        echo -e "${RED}❌ AWS CLI not found${NC}"
        return 1
    fi

    local account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    if [ -z "$account_id" ]; then
        echo -e "${RED}❌ Cannot access AWS account${NC}"
        return 1
    fi

    local region="us-east-1"
    local total_checks=0
    local passed_checks=0

    # Check EKS cluster
    if aws eks describe-cluster --name observability-cluster --region "$region" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ EKS cluster 'observability-cluster' exists${NC}"
        ((passed_checks++))
    else
        echo -e "${RED}❌ EKS cluster 'observability-cluster' not found${NC}"
    fi
    ((total_checks++))

    # Check ECR repositories
    for repo in sample-app chatops-bot; do
        if aws ecr describe-repositories --repository-names "$repo" --region "$region" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ ECR repository '$repo' exists${NC}"
            ((passed_checks++))
        else
            echo -e "${YELLOW}⚠️  ECR repository '$repo' not found${NC}"
        fi
        ((total_checks++))
    done

    # Check S3 buckets
    for bucket in observability-loki-chunks observability-loki-ruler observability-loki-admin; do
        if aws s3api head-bucket --bucket "$bucket" --region "$region" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ S3 bucket '$bucket' exists${NC}"
            ((passed_checks++))
        else
            echo -e "${YELLOW}⚠️  S3 bucket '$bucket' not found${NC}"
        fi
        ((total_checks++))
    done

    echo "AWS checks: $passed_checks/$total_checks passed"
    return $((total_checks - passed_checks))
}

# Function to check local Docker
check_local() {
    echo -e "${BLUE}🐳 Checking local Docker resources...${NC}"

    if ! command_exists docker; then
        echo -e "${RED}❌ Docker not found${NC}"
        return 1
    fi

    if ! command_exists docker-compose; then
        echo -e "${RED}❌ Docker Compose not found${NC}"
        return 1
    fi

    # Check if docker-compose file exists
    if [ ! -f "docker/docker-compose.yml" ]; then
        echo -e "${RED}❌ docker-compose.yml not found${NC}"
        return 1
    fi

    # Check if services are running
    cd docker
    local running_services=$(docker-compose ps -q 2>/dev/null | wc -l)
    cd ..

    if [ "$running_services" -gt 0 ]; then
        echo -e "${GREEN}✅ $running_services Docker services are running${NC}"

        # Check service URLs
        check_url "http://localhost:3000" "Grafana" || true
        check_url "http://localhost:9090" "Prometheus" || true
        check_url "http://localhost:16686" "Jaeger" || true
        check_url "http://localhost:8080" "Sample App" || true
    else
        echo -e "${YELLOW}⚠️  No Docker services are running${NC}"
        echo "Run 'make deploy-local' to start services"
    fi
}

# Function to check Terraform state
check_terraform() {
    echo -e "${BLUE}🏗️  Checking Terraform state...${NC}"

    if [ ! -d "terraform" ]; then
        echo -e "${YELLOW}⚠️  Terraform directory not found${NC}"
        return 1
    fi

    cd terraform

    if command_exists terraform; then
        if [ -f ".terraform/terraform.tfstate" ] || [ -f "terraform.tfstate" ]; then
            echo -e "${GREEN}✅ Terraform state file exists${NC}"

            # Show current state
            terraform state list 2>/dev/null | head -10 || echo "No resources in state"
        else
            echo -e "${YELLOW}⚠️  No Terraform state file found${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  Terraform not installed${NC}"
    fi

    cd ..
}

# Main validation function
main() {
    local exit_code=0

    echo "Select validation scope:"
    echo "1) Local Docker only"
    echo "2) Kubernetes only"
    echo "3) AWS resources only"
    echo "4) Full validation (all components)"
    echo "5) Terraform state only"
    echo

    read -p "Select option (1-5): " -n 1 -r
    echo

    case $REPLY in
        1)
            check_local || exit_code=$?
            ;;
        2)
            check_kubernetes || exit_code=$?
            ;;
        3)
            check_aws || exit_code=$?
            ;;
        4)
            check_local || exit_code=$?
            check_kubernetes || exit_code=$?
            check_aws || exit_code=$?
            check_terraform || exit_code=$?
            ;;
        5)
            check_terraform || exit_code=$?
            ;;
        *)
            echo "Invalid option. Exiting."
            exit 1
            ;;
    esac

    echo
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}🎉 All checks passed!${NC}"
    else
        echo -e "${YELLOW}⚠️  Some checks failed. Review the output above.${NC}"
    fi

    return $exit_code
}

# Run main function
main "$@"