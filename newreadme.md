# Full-Stack Observability Platform with AI-Powered Incident Response

## Project Overview

This project implements a comprehensive observability platform on AWS EKS to reduce Mean Time To Resolution (MTTR) and improve system reliability. By centralizing metrics, logs, and traces, and automating incident response with AI-driven insights, SRE teams can proactively detect and resolve issues.

### Architecture Overview

The architecture consists of:

- **Infrastructure Layer**: AWS EKS cluster with VPC networking, IAM roles, and security groups.
- **Application Layer**: Sample microservices (Service A and Service B) containerized with Docker and deployed via Kubernetes.
- **Observability Layer**:
  - **Metrics**: AWS Managed Prometheus collects and stores metrics.
  - **Logs**: Grafana Loki centralizes log aggregation.
  - **Traces**: OpenTelemetry instruments applications, with data sent to AWS X-Ray and Jaeger for visualization.
- **Incident Management Layer**:
  - AWS DevOps Guru detects anomalies using ML.
  - AWS Incident Manager automates incident creation and response.
- **ChatOps Layer**: Integrates with Slack/Microsoft Teams for notifications and AI-powered suggestions.

Data flow: Applications → OpenTelemetry Collector → Prometheus/Loki/X-Ray/Jaeger → Grafana (visualization) → Incident Manager → ChatOps.

### Learning Objectives

By following this guide, you will learn:

- Provisioning production-grade AWS EKS clusters with best practices.
- Building and deploying microservices with Docker and Kubernetes.
- Implementing end-to-end observability with OpenTelemetry.
- Setting up centralized logging and metrics collection.
- Automating incident detection and response.
- Integrating ChatOps for collaborative incident management.

## Prerequisites

- AWS account with administrative privileges.
- AWS CLI installed and configured (`aws configure`).
- `kubectl` installed.
- `eksctl` installed for EKS management.
- `docker` installed for building images.
- `helm` installed for deploying charts.
- Basic knowledge of Kubernetes, Docker, and AWS services.
- A Slack workspace or Microsoft Teams team (for ChatOps).

**Cost Note**: This setup uses AWS services that may incur costs. Monitor usage and clean up resources as instructed.

## Phase 1: Prerequisites & AWS Account Setup

### 1.1 Create an AWS Account

If you don't have one, sign up at [aws.amazon.com](https://aws.amazon.com). Enable MFA for security.

### 1.2 Configure AWS CLI

```bash
aws configure
# Enter your Access Key ID, Secret Access Key, default region (e.g., us-east-1), and output format (json).
```

### 1.3 Install Required Tools

- **AWS CLI**: Download from AWS website.
- **kubectl**: `aws eks update-kubeconfig` will handle, but install via `choco install kubernetes-cli` on Windows.
- **eksctl**: Download from GitHub releases.
- **Docker**: Install Docker Desktop.
- **Helm**: `choco install kubernetes-helm` or download.

### 1.4 Set Up IAM Permissions

Create an IAM user with the following policies:
- `AmazonEKSClusterPolicy`
- `AmazonEKSWorkerNodePolicy`
- `AmazonEC2ContainerRegistryFullAccess`
- `AmazonPrometheusFullAccess`
- `AWSXRayDaemonWriteAccess`
- `AmazonDevOpsGuruFullAccess`
- `AWSIncidentManagerResolverAccess`

Attach these to your user or a role.

**Best Practice**: Use IAM roles instead of access keys where possible for security.

## Phase 2: Infrastructure Provisioning

### 2.1 Create EKS Cluster with eksctl

eksctl simplifies EKS creation with best practices.

Create a cluster config file `cluster.yaml`:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: observability-cluster
  region: us-east-1
  version: "1.28"

vpc:
  subnets:
    public:
      us-east-1a: { id: subnet-12345678 }  # Replace with actual subnet IDs or let eksctl create
      us-east-1b: { id: subnet-87654321 }
    private:
      us-east-1a: { id: subnet-abcdef12 }
      us-east-1b: { id: subnet-fedcba21 }

managedNodeGroups:
  - name: observability-nodes
    instanceType: t3.medium
    desiredCapacity: 3
    minSize: 1
    maxSize: 5
    volumeSize: 20
    ssh:
      allow: true
      publicKeyName: my-keypair  # Replace with your keypair
    labels: { role: observability }
    tags:
      nodegroup-role: observability
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        externalDNS: true
        certManager: true
        appMesh: true
        appMeshPreview: true
        xRay: true
        cloudWatch: true

addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest

iam:
  withOIDC: true
```

Run:

```bash
eksctl create cluster -f cluster.yaml
```

This creates a VPC, subnets, EKS cluster, and managed node group with necessary IAM policies.

**Why eksctl?** It handles complex networking and IAM setup automatically, following AWS best practices.

**Common Mistake**: Forgetting to enable OIDC for IAM roles for service accounts (IRSA), needed for AWS integrations.

### 2.2 Verify Cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name observability-cluster
kubectl get nodes
kubectl get pods -A
```

## Phase 3: Application Build & Deployment

### 3.1 Build Sample Microservices

We have two simple Flask services:
- Service A: Calls Service B, simulates work.
- Service B: Returns a message.

Located in `app/service-a/` and `app/service-b/`.

### 3.2 Create ECR Repositories

```bash
aws ecr create-repository --repository-name service-a --region us-east-1
aws ecr create-repository --repository-name service-b --region us-east-1
```

### 3.3 Build and Push Docker Images

For Service A:

```bash
cd app/service-a
docker build -t service-a .
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
docker tag service-a:latest <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/service-a:latest
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/service-a:latest
```

Repeat for Service B.

**Best Practice**: Use multi-stage builds for smaller images, but kept simple here.

### 3.4 Deploy to Kubernetes

Update `k8s/deployment-service-a.yaml` and `k8s/deployment-service-b.yaml` with actual ECR URIs.

```bash
kubectl apply -f k8s/service-service-b.yaml
kubectl apply -f k8s/deployment-service-b.yaml
kubectl apply -f k8s/service-service-a.yaml
kubectl apply -f k8s/deployment-service-a.yaml
```

Check:

```bash
kubectl get pods
kubectl get services
```

Get the LoadBalancer URL for Service A.

**Why Kubernetes?** Enables scaling, self-healing, and declarative deployments.

## Phase 4: Observability Setup

### 4.1 Instrument Applications with OpenTelemetry

We added OTEL env vars to deployments. For Python, install `opentelemetry-distro` and `opentelemetry-instrumentation-flask`.

Update `requirements.txt`:

For service-a: flask, requests, opentelemetry-distro, opentelemetry-instrumentation-flask

For service-b: flask, opentelemetry-distro, opentelemetry-instrumentation-flask

In app.py, add:

```python
from opentelemetry.instrumentation.flask import FlaskInstrumentor
FlaskInstrumentor().instrument(app=app)
```

Rebuild and redeploy images.

### 4.2 Deploy OpenTelemetry Collector

Apply `k8s/otel-collector.yaml`.

Update config with your region and Prometheus workspace ID.

### 4.3 Set Up AWS Managed Prometheus

```bash
aws amp create-workspace --alias observability-workspace --region us-east-1
```

Note the workspace ID.

Create IAM role for collector:

```bash
aws iam create-role --role-name AMPIngestRole --assume-role-policy-document '{"Version": "2012-10-17","Statement": [{ "Effect": "Allow", "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>" }, "Action": "sts:AssumeRoleWithWebIdentity", "Condition": { "StringEquals": { "oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>:aud": "sts.amazonaws.com" } } }]}'
aws iam attach-role-policy --role-name AMPIngestRole --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess
```

Annotate the service account in otel-collector.yaml.

### 4.4 Deploy Grafana Loki

Use Helm:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack --set grafana.enabled=true,prometheus.enabled=false
```

This deploys Loki and Grafana.

### 4.5 Set Up Jaeger

```bash
kubectl create namespace observability
kubectl apply -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/crds/jaegertracing.io_jaegers_crd.yaml
kubectl apply -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/service_account.yaml
kubectl apply -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/role.yaml
kubectl apply -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/role_binding.yaml
kubectl apply -f https://raw.githubusercontent.com/jaegertracing/jaeger-operator/master/deploy/operator.yaml
```

Then:

```yaml
apiVersion: jaegertracing.io/v1
kind: Jaeger
metadata:
  name: jaeger
spec:
  strategy: allInOne
```

Apply this.

### 4.6 Enable AWS X-Ray

X-Ray is integrated via the collector.

### 4.7 Deploy Grafana for Visualization

Use the one from Loki Helm or separately.

Access Grafana, add Prometheus and Loki data sources.

## Phase 5: Incident Detection & Automation

### 5.1 Enable AWS DevOps Guru

```bash
aws devops-guru create-notification-channel --config file://notification-config.json
```

Where notification-config.json includes SNS topic for alerts.

### 5.2 Set Up AWS Incident Manager

Create a replication set, response plan.

Integrate with DevOps Guru.

## Phase 6: ChatOps Integration

### 6.1 Set Up Slack Integration

Create a Slack app, add webhooks for Incident Manager.

Use AWS Chatbot for integration.

For AI suggestions, integrate with AWS Q or custom Lambda.

## Validation and Testing

- Access Service A via LoadBalancer, check traces in X-Ray/Jaeger.
- Generate load, check metrics in Prometheus/Grafana.
- Simulate failure, check incident creation.

## Troubleshooting

- Pods not starting: Check logs with `kubectl logs`.
- Permissions issues: Verify IAM roles.
- Collector not exporting: Check config and endpoints.

## Cleanup

```bash
eksctl delete cluster --name observability-cluster
aws ecr delete-repository --repository-name service-a --force
# Delete other resources
```

This ensures no lingering costs.
