# SRE Full-Stack Observability & AI Incident Response (eksctl path)

This repo scaffolds everything you need to stand up a full-stack observability stack with AI-assisted incident response on AWS using `eksctl` and Helm. Follow the numbered sections in order. Replace bracketed placeholders like `<ACCOUNT_ID>` and `<REGION>`.

## 0) Repo layout
- `infra/cluster/eks-cluster.yaml` — eksctl cluster + VPC + nodegroups + OIDC.
- `infra/addons/` — Helm values/manifests for core addons (metrics-server, Cluster Autoscaler, ALB Controller).
- `observability/` — Helm values for Loki, Promtail, OpenTelemetry Collector, Jaeger.
- `app/sample/` — Sample app (Deployment/Service/Ingress) with OTEL env vars.
- `incident-automation/` — SNS/Incident Manager wiring stubs, Lambda skeleton for AI suggestions, SSM runbook example.
- `scripts/` — Helper commands (optional; currently not added).

## 1) Workstation setup
Install the CLI tools: AWS CLI v2, Docker, kubectl, eksctl, helm, jq, kubectx/kubens.
- Windows (Chocolatey): `choco install awscli kubernetes-cli eksctl helm jq kubectx-ps`
- Verify: `aws sts get-caller-identity`, `eksctl version`, `kubectl version --client`, `helm version`
- Configure AWS: `aws configure sso` (preferred) or `aws configure` → set `<REGION>` (e.g., `us-east-1`), output `json`.

## 2) AWS account/IAM bootstrap
- Create an admin role assumable by your SRE user; enforce MFA.
- (Optional) S3 bucket + DynamoDB table for IaC state if you later add Terraform.
- Create or pick an EC2 key pair for debugging: `aws ec2 create-key-pair --key-name sre-key --query KeyMaterial --output text > sre-key.pem`

## 3) VPC + EKS + nodegroups + OIDC (eksctl)
Edit `infra/cluster/eks-cluster.yaml` as needed (CIDRs/instance types/region).
- Create cluster: `eksctl create cluster -f infra/cluster/eks-cluster.yaml`
- Export kubeconfig: `aws eks update-kubeconfig --name sre-observability --region <REGION>`
- Verify: `kubectl get nodes`, `kubectl get pods -A`

## 4) Core addons
Metrics Server, Cluster Autoscaler, and AWS Load Balancer Controller.

### Metrics Server
```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ && helm repo update
helm upgrade -i metrics-server metrics-server/metrics-server -n kube-system -f infra/addons/metrics-server-values.yaml
```

### Cluster Autoscaler (with IRSA already via eksctl config)
```bash
CLUSTER=sre-observability
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/cluster-autoscaler-1.28.0/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml
kubectl -n kube-system patch deployment cluster-autoscaler -p '{"spec":{"template":{"spec":{"containers":[{"name":"cluster-autoscaler","command":["./cluster-autoscaler","--cloud-provider=aws","--cluster-name='${CLUSTER}'","--balance-similar-node-groups","--skip-nodes-with-system-pods=false","--skip-nodes-with-local-storage=false","--namespace=kube-system","--scale-down-delay-after-add=10m","--scale-down-unneeded-time=10m","--scan-interval=10s"]}]}}}}'
kubectl -n kube-system annotate deployment cluster-autoscaler cluster-autoscaler.kubernetes.io/safe-to-evict="false"
```

### AWS Load Balancer Controller
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
curl -o /tmp/alb-iam.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.6.2/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file:///tmp/alb-iam.json
eksctl create iamserviceaccount \
  --cluster sre-observability \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
helm repo add eks https://aws.github.io/eks-charts
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"
helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=sre-observability \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=<REGION> \
  -f infra/addons/aws-load-balancer-controller-values.yaml
```

## 5) ECR + CI/CD bootstrap
- Create repos: `aws ecr create-repository --repository-name app-api`, `aws ecr create-repository --repository-name app-frontend`, etc.
- Set up CI/CD (GitHub Actions/GitLab CI/CodePipeline): build → push to ECR → deploy to EKS with OIDC-based IAM role (no static keys).
- Sample ECR login/push:
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=<REGION>
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
docker build -t $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/app-api:dev .
docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/app-api:dev
```

## 6) Namespaces + sample app + ingress
```bash
kubectl create ns app
kubectl create ns observability
kubectl create ns ops
kubectl apply -f app/sample/deployment.yaml
kubectl apply -f app/sample/ingress.yaml
```
Replace the container image with your ECR image; sample uses `public.ecr.aws/docker/library/nginx:alpine` as placeholder.

## 7) Loki + Promtail
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm upgrade -i loki grafana/loki -n observability -f observability/loki-values.yaml
helm upgrade -i promtail grafana/promtail -n observability -f observability/promtail-values.yaml
```
Ensure the S3 bucket and region in `loki-values.yaml` exist and are writable.

## 8) Managed Prometheus (AMP) + Managed Grafana (AMG)
- Create AMP workspace: `aws amp create-workspace --alias sre-amp` → note the workspace ID.
- Create AMG workspace (console or CLI) and enable SSO/IAM auth. Add AMP as a data source (endpoint from workspace). Later add Loki.
- Create IAM policy for AMP remote-write/read and attach to the IRSA used by the OTel Collector (`observability` namespace).

## 9) OpenTelemetry Collector
- Create IRSA: `eksctl create iamserviceaccount --cluster sre-observability --namespace observability --name otel-collector --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AMPRemoteWriteRead --approve`
- Install Collector: `helm repo add aws-otel https://aws-observability.github.io/aws-otel-helm-chart && helm repo update`
- Apply: `helm upgrade -i otel-collector aws-otel/aws-otel-collector -n observability -f observability/otel-values.yaml`
- Update `otel-values.yaml` with your AMP endpoint, region, and Loki endpoint if changed.
- Create AMP IAM policy (example):
```bash
cat > /tmp/amp-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "aps:RemoteWrite",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata"
      ],
      "Resource": "arn:aws:aps:<REGION>:<ACCOUNT_ID>:workspace/<AMP_WORKSPACE_ID>"
    }
  ]
}
EOF
aws iam create-policy --policy-name AMPRemoteWriteRead --policy-document file:///tmp/amp-policy.json
```

## 10) App instrumentation (OTEL)
- Add env vars to services:
  - `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4317`
  - `OTEL_RESOURCE_ATTRIBUTES=service.name=<svc>,service.namespace=app,env=prod`
  - Enable W3C context propagation in HTTP/gRPC clients.
- Include OTEL SDK/auto-instrumentation per language and emit runtime metrics/logs.

## 11) X-Ray + Jaeger
- X-Ray via Collector `awsxray` exporter (already in otel-values). Check sampling rules in console (start 5–10%).
- Deploy Jaeger UI: `helm repo add jaegertracing https://jaegertracing.github.io/helm-charts && helm upgrade -i jaeger jaegertracing/jaeger -n observability -f observability/jaeger-values.yaml`

## 12) Dashboards + alerts
- In AMG, add data sources: AMP (metrics) and Loki (logs). Link traces via exemplars to X-Ray/Jaeger.
- Create dashboards: Golden signals per service, infra health, trace latency histograms.
- Define alert routes via PrometheusRule/Alertmanager (agent mode) or OTel → SNS topic (`sre-incidents`).

## 13) DevOps Guru
- Enable in region: `aws devops-guru start-resource-coverage --resource-collection CloudFormation={StackNames=[sre-observability-*]}` or enable organization-wide in console.
- Verify insights surface.

## 14) Incident Manager
- Create replication set: `aws ssm-incidents create-replication-set --regions <REGION>`
- Create contacts and rotation: `aws ssm-contacts create-contact ...`
- Create response plan (sample in `incident-automation/response-plan.json`). Wire SNS topic (alerts/DevOps Guru) and Chatbot channel. Attach SSM Automation runbook (example in `incident-automation/runbooks/restart-pod.json`).
- Create SNS topic: `aws sns create-topic --name sre-incidents`
- Create Chatbot config in console and subscribe topic: `aws sns subscribe --topic-arn arn:aws:sns:<REGION>:<ACCOUNT_ID>:sre-incidents --protocol chatbot --notification-endpoint <CHATBOT_CHANNEL_ARN>`
- Create the response plan: `aws ssm-incidents create-response-plan --cli-input-json file://incident-automation/response-plan.json`

## 15) ChatOps (AWS Chatbot)
- Configure Chatbot for Slack/Teams in console. Select SNS topic `sre-incidents`. Attach IAM role with read-only + needed actions (CloudWatch/APS/Logs/X-Ray).
- Validate by publishing a test SNS message to `sre-incidents`; confirm message appears in chat.

## 16) AI suggestion Lambda
- Deploy the Lambda in `incident-automation/lambda/` (zip with `requirements.txt`). Triggered by `sre-incidents` SNS topic.
- It fetches incident context (placeholder hooks), calls Bedrock (stubbed), and posts to Chatbot via SNS (placeholder). Add Bedrock and DynamoDB permissions to its IAM role.
- Quick deploy example:
```bash
cd incident-automation/lambda
pip install -r requirements.txt -t ./pkg
cp main.py pkg/
cd pkg && zip -r ../incident-ai.zip .
aws lambda create-function \
  --function-name incident-ai-suggestions \
  --handler main.handler \
  --runtime python3.11 \
  --role arn:aws:iam::<ACCOUNT_ID>:role/<LAMBDA_ROLE_WITH_BEDROCK_AND_SNS> \
  --timeout 30 \
  --memory-size 512 \
  --environment Variables="{SNS_TOPIC_ARN=arn:aws:sns:<REGION>:<ACCOUNT_ID>:sre-incidents,BEDROCK_MODEL=anthropic.claude-v2}" \
  --zip-file fileb://incident-ai.zip
aws lambda add-permission --function-name incident-ai-suggestions --statement-id sns --action lambda:InvokeFunction --principal sns.amazonaws.com
aws sns subscribe --topic-arn arn:aws:sns:<REGION>:<ACCOUNT_ID>:sre-incidents --protocol lambda --notification-endpoint arn:aws:lambda:<REGION>:<ACCOUNT_ID>:function:incident-ai-suggestions
```

## 17) Fault injection + validation
- Deploy a load generator (k6/locust) or a chaos pod.
- Inject failures: pod crash loop, latency spike, 5xx burst.
- Validate end-to-end: metrics in AMP, logs in Loki, traces in X-Ray/Jaeger, alerts → Incident Manager → ChatOps, Lambda posts suggestions, runbook (manual/auto) executes.

## Cleanup
- `helm uninstall ...` for charts, `eksctl delete cluster -f infra/cluster/eks-cluster.yaml`, delete ECR images, S3 buckets, AMP/AMG workspaces, SNS topics, and IAM roles to avoid costs.

## Next steps
- Fill in AWS account-specific IDs in the value files.
- Swap the sample app image for your services; wire OTEL SDKs.
- Harden IAM policies to least privilege before production.
