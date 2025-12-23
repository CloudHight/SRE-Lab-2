# Full-Stack Observability System with AI-Powered Incident Response

This project implements a comprehensive observability platform on AWS EKS with AI-powered incident management.

## Architecture Overview

- **AWS EKS**: Kubernetes cluster for container orchestration
- **Amazon Managed Prometheus**: Metrics collection and storage
- **Grafana Loki**: Log aggregation
- **OpenTelemetry**: Distributed tracing
- **AWS X-Ray**: Additional tracing capabilities
- **Jaeger**: Distributed tracing UI
- **Grafana**: Visualization dashboard
- **AWS DevOps Guru**: ML-powered anomaly detection
- **AWS Systems Manager Incident Manager**: Incident response coordination
- **Slack ChatOps Bot**: AI-powered incident communication

## Project Structure

```
.
├── sample-app/                 # Sample instrumented application
│   ├── app.py                 # Flask app with OpenTelemetry
│   ├── requirements.txt       # Python dependencies
│   ├── Dockerfile            # Container definition
│   └── deployment.yaml       # Kubernetes deployment
├── chatops-bot/               # AI-powered Slack bot
│   ├── app.py                 # Bot application
│   ├── requirements.txt       # Python dependencies
│   ├── Dockerfile            # Container definition
│   └── chatops-deployment.yaml # Kubernetes deployment
├── kubernetes-configs/        # K8s configuration files
│   ├── cluster-config.yaml    # EKS cluster config
│   ├── prometheus-values.yaml # Prometheus Helm values
│   ├── loki-values.yaml       # Loki Helm values
│   ├── otel-collector.yaml    # OpenTelemetry collector
│   ├── xray-daemon.yaml       # X-Ray daemon
│   ├── grafana-values.yaml    # Grafana Helm values
│   ├── jaeger-values.yaml     # Jaeger Helm values
│   ├── prometheus-alerts.yaml # Prometheus alerting rules
│   └── kubernetes-dashboard.json # Sample Grafana dashboard
├── scripts/                   # Setup and utility scripts
│   ├── setup-observability.sh # Main setup script
│   ├── amp-iam-policy.json    # IAM policy for AMP
│   ├── incident-responder.py  # AWS Lambda for incident response
│   ├── runbook-automation.json # SSM automation document
│   ├── response-plan.json     # Incident Manager response plan
│   ├── load-test.py          # Load testing script
│   └── error-generator.yaml   # Test error generation
├── terraform/                 # Infrastructure as Code
│   ├── main.tf               # Terraform configuration
│   └── variables.tf          # Terraform variables
├── docker/                    # Local development with Docker
│   ├── docker-compose.yml    # Local stack with Docker Compose
│   ├── otel-config.yaml      # OpenTelemetry config for local
│   └── prometheus.yml        # Prometheus config for local
├── .env.example              # Environment variables template
├── README.md                 # This file
└── note.txt                  # Complete implementation guide
```

## Quick Start

1. **Prerequisites**: Install AWS CLI, kubectl, eksctl, Helm, Docker
2. **Configure AWS**: Run `aws configure` with your credentials
3. **Make scripts executable**: `chmod +x scripts/*.sh`
4. **Run Setup Script**: `./scripts/setup-observability.sh`
5. **Deploy Applications**: Apply the Kubernetes manifests
6. **Configure Monitoring**: Set up Grafana dashboards and alerts

## Local Development

For local testing and development, you can use Docker Compose to run a simplified version of the observability stack:

1. **Copy environment file**: `cp .env.example .env`
2. **Edit .env**: Fill in your API keys and configuration
3. **Start services**: `cd docker && docker-compose up -d`
4. **Access services**:
   - Grafana: http://localhost:3000 (admin/admin)
   - Prometheus: http://localhost:9090
   - Jaeger: http://localhost:16686
   - Sample App: http://localhost:8080

## Cleanup

The project includes a comprehensive cleanup script for tearing down resources:

### **Interactive Cleanup**
```bash
# Run interactive cleanup (recommended)
make cleanup
# OR
./scripts/cleanup.sh
```

### **Cleanup Options**
1. **Local Docker only** - Stop containers and remove volumes
2. **Kubernetes resources only** - Delete K8s deployments and services
3. **AWS resources only** - Delete ECR, S3, SNS (keeps EKS cluster)
4. **Full cleanup** - Everything including EKS cluster (destructive!)
5. **Terraform only** - Run terraform destroy
6. **Local files only** - Remove cache and temporary files

### **Quick Cleanup Commands**
```bash
# Clean up local development
make cleanup-local

# Clean up Kubernetes resources
make k8s-delete

# Clean up AWS resources (use with caution)
make cleanup-aws

# Full destructive cleanup
make cleanup-full
```

**⚠️ WARNING**: Full cleanup (option 4) will delete the entire EKS cluster and all associated resources. This action cannot be undone!

### Sample Application
A Flask-based microservice instrumented with OpenTelemetry for distributed tracing and metrics.

### ChatOps Bot
An AI-powered Slack bot that:
- Receives incident notifications
- Provides AI-generated resolution suggestions
- Learns from past incidents
- Integrates with AWS services

### Observability Stack
- **Metrics**: Prometheus + Grafana
- **Logs**: Loki + Promtail
- **Traces**: OpenTelemetry + Jaeger + X-Ray
- **Alerts**: Prometheus Alertmanager
- **AI Insights**: DevOps Guru

## Development Commands

This project includes a Makefile with common development tasks:

```bash
make help          # Show available commands
make setup         # Install Python dependencies
make build         # Build Docker images
make deploy-local  # Start local Docker Compose stack
make stop-local    # Stop local deployment
make terraform-plan   # Show Terraform changes
make terraform-apply  # Apply infrastructure changes
make k8s-deploy    # Deploy to Kubernetes
make load-test     # Run load testing
make lint          # Lint Python code
make format        # Format Python code
make cleanup       # Interactive cleanup script
make validate       # Interactive validation script
```

## Validation

Check the status of your deployment with the validation script:

### **Interactive Validation**
```bash
# Run interactive validation (recommended)
make validate
# OR
./scripts/validate.sh
```

### **Validation Options**
1. **Local Docker only** - Check Docker containers and services
2. **Kubernetes only** - Validate K8s deployments and namespaces
3. **AWS resources only** - Check ECR, S3, EKS cluster
4. **Full validation** - Check all components
5. **Terraform state only** - Review infrastructure state

### **Quick Validation Commands**
```bash
# Validate local setup
make validate-local

# Validate Kubernetes resources
make validate-k8s

# Validate AWS resources
make validate-aws
```

## Cleanup

The project includes a comprehensive cleanup script for tearing down resources:

### **Interactive Cleanup**
```bash
# Run interactive cleanup (recommended)
make cleanup
# OR
./scripts/cleanup.sh
```

### **Cleanup Options**
1. **Local Docker only** - Stop containers and remove volumes
2. **Kubernetes resources only** - Delete K8s deployments and services
3. **AWS resources only** - Delete ECR, S3, SNS (keeps EKS cluster)
4. **Full cleanup** - Everything including EKS cluster (destructive!)
5. **Terraform only** - Run terraform destroy
6. **Local files only** - Remove cache and temporary files

### **Quick Cleanup Commands**
```bash
# Clean up local development
make cleanup-local

# Clean up Kubernetes resources
make k8s-delete

# Clean up AWS resources (use with caution)
make cleanup-aws

# Full destructive cleanup
make cleanup-full
```

**⚠️ WARNING**: Full cleanup (option 4) will delete the entire EKS cluster and all associated resources. This action cannot be undone!

## Security Considerations

- Use IAM roles with least privilege
- Enable encryption for data at rest and in transit
- Regularly rotate API keys and tokens
- Implement network segmentation
- Enable audit logging

## Cost Optimization

- Use spot instances for non-production workloads
- Configure appropriate retention periods
- Scale resources based on usage
- Monitor and optimize resource utilization

## Validation Checklist

- [ ] EKS cluster running with 3+ nodes
- [ ] Prometheus scraping metrics
- [ ] Loki collecting logs
- [ ] Jaeger receiving traces
- [ ] Grafana accessible with datasources
- [ ] DevOps Guru detecting anomalies
- [ ] Incident Manager configured
- [ ] Slack bot responding to incidents

For detailed implementation steps, see `note.txt`.