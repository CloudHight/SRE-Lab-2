#!/bin/bash

# AWS EKS Observability Setup Script
# This script sets up the complete observability stack. It is idempotent and can be re-run safely.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
POLICY_NAME="AMPServiceAccountPolicy"

echo "Starting Full-Stack Observability System Setup"

echo "Phase 1: Installing prerequisites..."
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
fi

if ! command -v kubectl &> /dev/null; then
    echo "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
fi

if ! command -v eksctl &> /dev/null; then
    echo "Installing eksctl..."
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
fi

if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    sudo apt-get update
    sudo apt-get install docker.io -y
    sudo systemctl start docker
    sudo usermod -aG docker "$USER"
fi
echo "Prerequisites installed"

echo "Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts --force-update
helm repo add elastic https://helm.elastic.co --force-update
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
helm repo update
echo "Helm repositories added"

echo "Phase 2: Creating EKS Cluster..."
if eksctl get cluster observability-cluster &>/dev/null; then
    echo "EKS cluster 'observability-cluster' already exists. Skipping cluster creation."
else
    eksctl create cluster -f kubernetes-configs/cluster-config.yaml
fi

kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace application --dry-run=client -o yaml | kubectl apply -f -
echo "EKS Cluster ready"

# Check for default StorageClass; if missing, fall back to ephemeral storage for stateful charts
DEFAULT_STORAGE_CLASS=$(kubectl get sc --no-headers 2>/dev/null | awk '$0 ~ "default" {print $1; exit}')
if [ -z "$DEFAULT_STORAGE_CLASS" ]; then
    echo "No default StorageClass detected; using ephemeral storage (persistence disabled) for Elasticsearch/Prometheus/Grafana/Loki/Redis."
    USE_PERSISTENCE=false
else
    echo "Default StorageClass detected: $DEFAULT_STORAGE_CLASS"
    USE_PERSISTENCE=true
fi

echo "Phase 3: Setting up Amazon Managed Prometheus..."
AMP_WORKSPACE_ARN=$(aws amp list-workspaces --alias observability-workspace --region "$AWS_REGION" --query 'workspaces[0].arn' --output text)
if [ "$AMP_WORKSPACE_ARN" = "None" ] || [ -z "$AMP_WORKSPACE_ARN" ]; then
    AMP_WORKSPACE_ARN=$(aws amp create-workspace --alias observability-workspace --region "$AWS_REGION" --query arn --output text)
    echo "Created AMP workspace: $AMP_WORKSPACE_ARN"
else
    echo "Reusing AMP workspace: $AMP_WORKSPACE_ARN"
fi

AMP_WORKSPACE_ID="${AMP_WORKSPACE_ARN##*/}"
AMP_ENDPOINT_URL="https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/"
echo "AMP Workspace ID: $AMP_WORKSPACE_ID"
echo "AMP Endpoint: $AMP_ENDPOINT_URL"

POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" --output text)
if [ "$POLICY_ARN" = "None" ] || [ -z "$POLICY_ARN" ]; then
    POLICY_ARN=$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document file://scripts/amp-iam-policy.json --query Policy.Arn --output text)
    echo "Created IAM policy: $POLICY_ARN"
else
    echo "Reusing IAM policy: $POLICY_ARN"
fi

eksctl create iamserviceaccount \
    --name amp-service-account \
    --namespace observability \
    --cluster observability-cluster \
    --attach-policy-arn "$POLICY_ARN" \
    --approve \
    --override-existing-serviceaccounts

ROLE_ARN=$(aws iam list-roles --query "Roles[?contains(RoleName, 'eksctl-observability-cluster-addon-iamserviceaccount')].Arn | [0]" --output text)
export AMP_ENDPOINT_URL ROLE_ARN

envsubst < kubernetes-configs/prometheus-values.yaml | helm upgrade --install prometheus prometheus-community/prometheus \
    -n observability \
    -f - \
    --set server.persistentVolume.enabled="${USE_PERSISTENCE}" \
    --set alertmanager.persistentVolume.enabled="${USE_PERSISTENCE}"
echo "AMP and Prometheus setup complete"

echo "Phase 4: Setting up Grafana..."
envsubst < kubernetes-configs/grafana-values.yaml | helm upgrade --install grafana grafana/grafana \
    -n observability \
    -f - \
    --set env.GF_SERVER_ROOT_URL="http://grafana.observability.example.com" \
    --set persistence.enabled="${USE_PERSISTENCE}"
echo "Grafana setup complete"

echo "Phase 5: Setting up Elasticsearch..."
helm upgrade --install elasticsearch elastic/elasticsearch \
    -n observability \
    --set clusterName=observability \
    --set persistence.enabled="${USE_PERSISTENCE}" \
    --set persistence.size=50Gi \
    --set antiAffinity=soft \
    --set esJavaOpts="-Xmx2g -Xms2g"
echo "Elasticsearch setup complete"

echo "Phase 6: Setting up Jaeger..."
helm upgrade --install jaeger jaegertracing/jaeger \
    -n observability \
    -f kubernetes-configs/jaeger-values.yaml
echo "Jaeger setup complete"

echo "Phase 7: Setting up Loki..."
echo "Note: Ensure S3 bucket 'observability-loki-chunks8' exists in ${AWS_REGION}"
helm upgrade --install loki grafana/loki \
    -n observability \
    -f kubernetes-configs/loki-values.yaml \
    --set read.persistence.enabled="${USE_PERSISTENCE}" \
    --set write.persistence.enabled="${USE_PERSISTENCE}" \
    --set backend.persistence.enabled="${USE_PERSISTENCE}"
echo "Loki setup complete"

echo "Phase 8: Setting up Redis..."
helm upgrade --install redis bitnami/redis \
    -n observability \
    --set auth.enabled=false \
    --set persistence.enabled="${USE_PERSISTENCE}" \
    --set persistence.size=8Gi
echo "Redis setup complete"

echo "Phase 9: Setting up OpenTelemetry Collector..."
# Install cert-manager CRDs (required for OTel operator certificates)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.crds.yaml
# Install cert-manager (idempotent via upgrade --install)
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
    -n cert-manager \
    --set installCRDs=false
kubectl wait --for=condition=available --timeout=300s -n cert-manager deployment/cert-manager deployment/cert-manager-webhook deployment/cert-manager-cainjector

kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
kubectl wait --for=condition=available --timeout=300s deployment/opentelemetry-operator -n opentelemetry-operator-system
envsubst < kubernetes-configs/otel-collector.yaml | kubectl apply -f -
echo "OpenTelemetry Collector setup complete"

echo "Phase 10: Setting up AWS X-Ray Daemon..."
kubectl apply -f kubernetes-configs/xray-daemon.yaml
echo "X-Ray Daemon setup complete"

echo "Phase 11: Setting up Prometheus Alerting Rules..."
kubectl apply -f kubernetes-configs/prometheus-alerts.yaml
echo "Prometheus Alerting Rules setup complete"

echo "Phase 12: Building and deploying applications..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
aws ecr describe-repositories --repository-names sample-app --region "$AWS_REGION" 2>/dev/null || aws ecr create-repository --repository-name sample-app --region "$AWS_REGION"
aws ecr describe-repositories --repository-names chatops-bot --region "$AWS_REGION" 2>/dev/null || aws ecr create-repository --repository-name chatops-bot --region "$AWS_REGION"

echo "Building sample-app..."
docker build -t sample-app:latest sample-app/
docker tag sample-app:latest "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/sample-app:latest"
docker push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/sample-app:latest"

echo "Building chatops-bot..."
docker build -t chatops-bot:latest chatops-bot/
docker tag chatops-bot:latest "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/chatops-bot:latest"
docker push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/chatops-bot:latest"

if grep -q "<YOUR_ECR_IMAGE_URI>" sample-app/deployment.yaml; then
    sed -i "s|<YOUR_ECR_IMAGE_URI>|$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/sample-app:latest|g" sample-app/deployment.yaml
else
    echo "sample-app deployment already points to an ECR image, skipping placeholder replacement."
fi

if grep -q "<YOUR_CHATOPS_IMAGE>" chatops-bot/chatops-deployment.yaml; then
    sed -i "s|<YOUR_CHATOPS_IMAGE>|$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/chatops-bot:latest|g" chatops-bot/chatops-deployment.yaml
else
    echo "chatops-bot deployment already points to an ECR image, skipping placeholder replacement."
fi

echo "Note: You need to create secrets for chatops-bot:"
echo "kubectl create secret generic slack-credentials --from-literal=SLACK_BOT_TOKEN=your_token --from-literal=SLACK_SIGNING_SECRET=your_secret --from-literal=SLACK_CHANNEL_ID=your_channel -n observability"
echo "kubectl create secret generic openai-credentials --from-literal=API_KEY=your_key -n observability"

kubectl apply -f sample-app/deployment.yaml
kubectl apply -f chatops-bot/chatops-deployment.yaml
echo "Applications deployed"

echo "Phase 13: Validating deployment..."
kubectl wait --for=condition=available --timeout=300s deployment/sample-app -n application
kubectl wait --for=condition=available --timeout=300s deployment/chatops-bot -n observability

echo "Service URLs:"
echo "Grafana: $(kubectl get svc grafana -n observability -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "Jaeger: $(kubectl get svc jaeger-query -n observability -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "Sample App: $(kubectl get svc sample-app -n application -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

echo "Complete observability stack setup finished successfully!"
